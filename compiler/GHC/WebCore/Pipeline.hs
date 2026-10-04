-- | The web pipeline: annotation, Web Lint, solving, renaming and erasure.
--
-- See Note [The web pipeline].
module GHC.WebCore.Pipeline
  ( webPass
  ) where

import GHC.Prelude

import GHC.Driver.DynFlags
import GHC.Driver.Config.Diagnostic ( initDiagOpts )

import GHC.Core
import GHC.Core.Map.Expr ( eqCoreExpr )
import GHC.Core.Opt.Monad
import GHC.Core.Ppr ( pprCoreBindings )
import GHC.Core.TyCo.Compare ( eqType )

import GHC.Platform ( Platform )
import GHC.Types.Id
import GHC.Types.Unique.FM ( sizeUFM )
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply ( mkSplitUniqSupply )
import GHC.Types.Web

import GHC.Unit.Module.ModGuts

import GHC.Data.Bag
import GHC.Utils.Error ( DiagOpts, MessageClass(..), pprMessageBag, ghcExit )
import GHC.Utils.Logger
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Types.SrcLoc ( noSrcSpan )

import GHC.WebCore.Annotate
import GHC.WebCore.Erase
import GHC.WebCore.Lint
import GHC.WebCore.Rename
import GHC.WebCore.Sigs
import GHC.WebCore.Solve
import GHC.WebCore.Traverse ( programWebs )

import Control.Monad

{- Note [The web pipeline]
~~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs, this pass runs after all Core optimisations
(GHC.Core.Opt.Pipeline.getCoreToDo).  See Note [Webs] in GHC.Types.Web.

  1. Annotation (GHC.WebCore.Annotate): every value lambda becomes a WebLam,
     every value call a WebApp, and every term-level arrow gets a web, each with
     a fresh web.  Global entities get exposed signatures
     (Note [Exposed webs] in GHC.WebCore.Sigs).

  2. Web Lint (GHC.WebCore.Lint): type-check the annotated program, collecting
     a pair (w1, w2) whenever the typing rules require webs w1 and w2 to be the
     same.  Union-find over the pairs (GHC.WebCore.Solve) gives a
     representative for each class of webs.

  3. Renaming (GHC.WebCore.Rename): rewrite every web to its representative.
     Web Lint runs again; it must collect no pairs.

  4. Erasure (GHC.WebCore.Erase): back to ordinary Core.

The pipeline does not change the program: erasure undoes annotation.  With
-dcore-lint we check that (Note [Web round trip]).  It is the place to add
web-based transformations, between steps 3 and 4.

Note [Web round trip]
~~~~~~~~~~~~~~~~~~~~~
Annotation only adds webs (and expands type synonyms that hide arrows), so
erasing the annotated program gives back the original program.  With
-dcore-lint we check this: the erased program must have the same binders, with
equal types, and alpha-equivalent right-hand sides, and must contain no webs.
-}

webPass :: ModGuts -> CoreM ModGuts
webPass guts
  = do { dflags <- getDynFlags
       ; logger <- getLogger
       ; us     <- liftIO (mkSplitUniqSupply webUniqueTag)

       ; let binds0 = mg_binds guts
             cfg    = webLintConfig dflags

             -- 1. Annotation
             (binds1, sigs1) = annotateProgram us binds0

       ; dump logger Opt_D_dump_webs "Webs: annotated program" $
           pprCoreBindings binds1 $$ blankLine $$ pprWebSigs sigs1

         -- 2. Web Lint, collecting web constraints; then solve
       ; let res1 = lintWebProgram cfg sigs1 binds1
       ; reportWebLint logger dflags "annotation" binds1 res1
       ; let pairs = wlr_pairs res1
             sol   = solveWebs (ws_exposed sigs1) pairs

         -- 3. Renaming.  Classes joined with an arrow without a web are now
         -- exposed too; see Note [Arrows without webs] in GHC.WebCore.Lint
             sigs2  = addExposedWebs (ws_exposed_reps sol) $
                      renameSigs (ws_subst sol) sigs1
             binds2 = renameProgram (ws_subst sol) sigs2 binds1

       ; dump logger Opt_D_dump_webs_solved "Webs: program after renaming" $
           pprCoreBindings binds2 $$ blankLine $$ pprWebClasses sol

       ; let res2 = lintWebProgram cfg sigs2 binds2
       ; reportWebLint logger dflags "renaming" binds2 res2
         -- After renaming, the only constraints left are with arrows without
         -- webs, whose classes are exposed
       ; let unsolved = filterBag (\(w1, w2) -> not (isPlaceholderWeb w1 || isPlaceholderWeb w2))
                                  (wlr_pairs res2)
       ; unless (isEmptyBag unsolved) $
           pprPanic "webPass: renamed program still has web constraints"
                    (ppr (bagToList unsolved))

       ; dump logger Opt_D_dump_webs_stats "Webs: statistics" $
           pprWebStats (sizeUniqSet (programWebs binds1)) (sizeUniqSet (programWebs binds2))
                       (ws_exposed sigs1)
                       (lengthBag pairs) sol

         -- 4. Erasure
       ; let binds3 = eraseProgram sigs2 binds2

       ; when (gopt Opt_DoCoreLinting dflags) $
           checkRoundTrip binds0 binds3

       ; return (guts { mg_binds = binds3 }) }

-- | Lint configuration for Web Lint
webLintConfig :: DynFlags -> LintConfig
webLintConfig dflags
  = LintConfig { l_diagOpts = initDiagOpts dflags :: DiagOpts
               , l_platform = targetPlatform dflags :: Platform
               , l_flags    = flags
               , l_vars     = [] }
  where
    flags = LF { lf_check_global_ids           = False
               , lf_check_inline_loop_breakers = False
               , lf_check_static_ptrs          = AllowAnywhere
               , lf_report_unsat_syns          = True
               , lf_check_linearity            = gopt Opt_DoLinearCoreLinting dflags
               , lf_check_fixed_rep            = True }

-- | Report Web Lint errors (and warnings, with -dcore-lint) and stop if
-- there were errors
reportWebLint :: Logger -> DynFlags -> String -> CoreProgram -> WebLintResult -> CoreM ()
reportWebLint logger dflags what binds res
  | not (isEmptyBag (wlr_errors res))
  = liftIO $
    do { logMsg logger MCInfo noSrcSpan $ withPprStyle defaultDumpStyle $
           vcat [ banner "errors", pprMessageBag (wlr_errors res)
                , text "*** Offending Program ***"
                , pprCoreBindings binds
                , text "*** End of Offense ***" ]
       ; ghcExit logger 1 }
  | not (isEmptyBag (wlr_warnings res))
  , gopt Opt_DoCoreLinting dflags
  , log_enable_debug (logFlags logger)
  = liftIO $ logMsg logger MCInfo noSrcSpan $ withPprStyle defaultDumpStyle $
      banner "warnings" $$ pprMessageBag (wlr_warnings res)
  | otherwise
  = return ()
  where
    banner s = text "*** Web Lint" <+> text s <> text ": after" <+> text what <+> text "***"

-- | Check that the web pipeline did not change the program.
-- See Note [Web round trip]
checkRoundTrip :: CoreProgram -> CoreProgram -> CoreM ()
checkRoundTrip before after
  = do { unless (isEmptyUniqSet (programWebs after)) $
           pprPanic "Webs: webs left after erasure" (pprCoreBindings after)
       ; unless (length before == length after) $
           pprPanic "Webs: erasure changed the number of bindings" empty
       ; zipWithM_ check_bind before after }
  where
    check_bind (NonRec b1 e1) (NonRec b2 e2) = check_pair (b1, e1) (b2, e2)
    check_bind (Rec prs1) (Rec prs2)
      | length prs1 == length prs2 = zipWithM_ check_pair prs1 prs2
    check_bind b1 b2 = round_trip_failure (ppr b1) (ppr b2)

    check_pair (b1, e1) (b2, e2)
      | b1 == b2
      , idType b1 `eqType` idType b2
      , eqCoreExpr e1 e2
      = return ()
      | otherwise
      = round_trip_failure (ppr b1 <+> dcolon <+> ppr (idType b1) $$ ppr e1)
                           (ppr b2 <+> dcolon <+> ppr (idType b2) $$ ppr e2)

    round_trip_failure d1 d2
      = pprPanic "Webs: erasure did not give back the original program"
                 (vcat [ text "Before:", nest 2 d1, text "After:", nest 2 d2 ])

pprWebClasses :: WebSolution -> SDoc
pprWebClasses sol
  = vcat [ text "Web classes (representative first; * = exposed):"
         , nest 2 $ vcat [ hsep (map ppr_web cls) | cls <- ws_classes sol ]
         , text "Webs renamed:" <+> int (sizeUFM (ws_subst sol)) ]
  where
    ppr_web w | w `elementOfUniqSet` ws_exposed_reps sol = ppr w <> char '*'
              | otherwise                                = ppr w

dump :: Logger -> DumpFlag -> String -> SDoc -> CoreM ()
dump logger flag hdr doc
  = liftIO $ putDumpFileMaybe logger flag hdr FormatCore doc
