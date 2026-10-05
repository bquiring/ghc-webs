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
import GHC.Types.Unique.FM ( sizeUFM, emptyUFM, lookupUFM, addToUFM, addToUFM_C, nonDetEltsUFM )
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
import GHC.WebCore.Transform.ArityRaise
import GHC.WebCore.Transform.Common ( pprWebVerdicts, UnfoldingPolicy(..) )
import GHC.WebCore.Transform.DeadParams ( deadParamsRound, Verdict(..) )
import GHC.WebCore.Transform.Uncurry
import GHC.Types.Unique.Supply ( UniqSupply )
import GHC.WebCore.Traverse ( programWebs, typeWebs )
import GHC.Core.TyCo.Rep
import GHC.Types.Var ( VarBndr(..), isTyVar )

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

-- | Run the web pipeline.  The Bool says whether this is the early run,
-- before the main simplifier (-fcore-webs-early); see Note [Early webs].
webPass :: Bool -> ModGuts -> CoreM ModGuts
webPass early guts
  = do { dflags <- getDynFlags
       ; logger <- getLogger
       ; us     <- liftIO (mkSplitUniqSupply webUniqueTag)

       ; let binds0 = mg_binds guts
             cfg    = webLintConfig dflags

             -- 1. Annotation
             (binds1, sigs1) = annotateProgram early us (mg_rules guts) binds0

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
       ; checkSolved "renaming" res2

         -- Transformations
       ; (binds_t, transformed) <- runTransforms early logger dflags cfg sigs2 binds2

       ; dump logger Opt_D_dump_webs_summary "Webs: summary" $
           pprWebSummary (ws_exposed sigs2) binds_t

       ; dump logger Opt_D_dump_webs_stats "Webs: statistics" $
           pprWebStats (sizeUniqSet (programWebs binds1)) (sizeUniqSet (programWebs binds2))
                       (ws_exposed sigs1)
                       (lengthBag pairs) sol

         -- 4. Erasure
       ; let binds3 = eraseProgram sigs2 binds_t

         -- If a transformation changed the program, it is not the original;
         -- Core Lint (endPass, with -dcore-lint) still checks the result
       ; when (gopt Opt_DoCoreLinting dflags && not transformed) $
           checkRoundTrip binds0 binds3

       ; return (guts { mg_binds = binds3 }) }


-- | After renaming, the only constraints left must be with arrows without
-- webs, whose classes are exposed (Note [Arrows without webs] in
-- GHC.WebCore.Lint)
checkSolved :: String -> WebLintResult -> CoreM ()
checkSolved what res
  = unless (isEmptyBag unsolved) $
      pprPanic ("webPass: web constraints left after " ++ what)
               (ppr (bagToList unsolved))
  where
    unsolved = filterBag (\(w1, w2) -> not (isPlaceholderWeb w1 || isPlaceholderWeb w2))
                         (wlr_pairs res)

-- | One round of a web transformation: given a unique supply, the webs it
-- has already handled, and the program, return the new program and the webs
-- it handled this round (or Nothing if nothing changed), and one verdict per
-- web for the dump: the verdict, whether it changed the program, and the
-- web's lambda binders.
type TransformRound = UniqSupply -> WebSet -> CoreProgram
                   -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])

-- | Run a web transformation in rounds until nothing changes, running Web
-- Lint after each round: the transformation must keep the program
-- well-typed.  Returns whether the program changed.
runTransform :: String -> DumpFlag -> TransformRound
             -> Logger -> DynFlags -> LintConfig -> WebSigs
             -> CoreProgram -> CoreM (CoreProgram, Bool)
runTransform name dump_flag do_round logger dflags cfg sigs binds0
  = go (1 :: Int) emptyUniqSet binds0 emptyUFM False
  where
    max_rounds = 10

    go n done binds verdicts changed
      | n > max_rounds = finish binds verdicts changed
      | otherwise
      = do { us <- liftIO (mkSplitUniqSupply webUniqueTag)
           ; case do_round us done binds of
               (Nothing, vs) -> finish binds (record vs verdicts) changed
               (Just (binds', handled), vs) ->
                 do { let what = name ++ ", round " ++ show n
                          res  = lintWebProgram cfg sigs binds'
                    ; reportWebLint logger dflags what binds' res
                    ; checkSolved what res
                    ; go (n + 1) (done `unionUniqSets` handled) binds'
                         (record vs verdicts) True } }

    -- The last verdict for each web wins, except that a verdict that changed
    -- the program is not overwritten by a later one that did not (e.g. an
    -- uncurried web is no longer curried in the next round)
    record vs acc = foldl' (\m (w, v, ch, bs) -> addToUFM_C keep m w (v, ch, bs)) acc vs
    keep old@(_, old_ch, _) new@(_, new_ch, _)
      | old_ch && not new_ch = old
      | otherwise            = new

    finish binds verdicts changed
      = do { dump logger dump_flag ("Webs: " ++ name) $
               pprWebVerdicts [ (v, bs) | (v, _, bs) <- nonDetEltsUFM verdicts ]
           ; return (binds, changed) }

-- | Did a dead-parameter verdict change the program?
changes :: Verdict -> Bool
changes Delete   = True
changes (Unit _) = True
changes _        = False

-- | The web transformations, in the order they run
-- See GHC.WebCore.Transform.*
runTransforms :: Bool -> Logger -> DynFlags -> LintConfig -> WebSigs
              -> CoreProgram -> CoreM (CoreProgram, Bool)
runTransforms early logger dflags cfg sigs binds0
  = foldM step (binds0, False) transforms
  where
    exposed = ws_exposed sigs
    keep    = UnfoldingPolicy { up_keep = ws_interface_ids sigs, up_early = early }

    transforms =
      [ ( Opt_CoreWebsArityRaise, "arity raising", Opt_D_dump_webs_arity_raise
        , \us done b -> arityRaiseRound us exposed keep done b )
      , ( Opt_CoreWebsDeadParams, "dead parameters", Opt_D_dump_webs_dead_params
        , \us done b -> case deadParamsRound us exposed keep done b of
                          (r, vs) -> (r, [ (w, ppr v, changes v, bs) | (w, v, bs) <- vs ]) )
      , ( Opt_CoreWebsUncurry, "uncurrying", Opt_D_dump_webs_uncurry
        , \us _ b -> case uncurryRound us exposed keep b of
                       (r, vs) -> (fmap (\b' -> (b', emptyUniqSet)) r, vs) ) ]

    step (binds, changed) (flag, name, dump_flag, do_round)
      | early, flag == Opt_CoreWebsUncurry
      = return (binds, changed)   -- See Note [No early uncurrying]
      | gopt flag dflags
      = do { (binds', changed') <- runTransform name dump_flag do_round
                                                logger dflags cfg sigs binds
           ; return (binds', changed || changed') }
      | otherwise
      = return (binds, changed)

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

-- | The types of the top-level binders, with each arrow labelled by its web
-- class: @-{E}->@ for an exposed class, @-{n}->@ for local class n, where
-- classes are numbered in order of first appearance.  When the right-hand
-- side is a cast of web-annotated lambdas (so the binder's type does not show
-- their webs), their webs are shown too:  @= (\ -{E}-> ...) |> co@.
-- Contains no Uniques, so tests can use it.
pprWebSummary :: WebSet -> CoreProgram -> SDoc
pprWebSummary exposed binds
  = vcat (go emptyUFM (1 :: Int) [ pr | pr@(b, rhs) <- flattenBinds binds
                                      , has_webs (idType b) || not (null (cast_lams rhs)) ])
  where
    has_webs ty = not (isEmptyUniqSet (typeWebs ty))

    go _   _ []     = []
    go env n ((b, rhs):prs)
      = case ppr_ty env n (idType b) of
          (doc, env1, n1) -> case ppr_lams env1 n1 (cast_lams rhs) of
            (lam_docs, env2, n2) ->
              (hang (ppr b <+> dcolon <+> doc) 2 lam_docs) : go env2 n2 prs

    -- The webs of the lambdas under a cast at the top of a right-hand side
    cast_lams (Tick _ e)        = cast_lams e
    cast_lams (Lam v e)
      | isTyVar v               = cast_lams e
    cast_lams (Cast e _)        = top_lams e
    cast_lams _                 = []

    top_lams (Tick _ e)         = top_lams e
    top_lams (WebLam w _ e)     = w : top_lams e
    top_lams _                  = []

    ppr_lams env n [] = (empty, env, n)
    ppr_lams env n ws = let (lbls, env1, n1) = labels env n ws
                        in ( text "= (" <> hsep [ text ("\\ -{" ++ l ++ "}->") | l <- lbls ]
                             <+> text "...) |> co"
                           , env1, n1 )

    labels env n []     = ([], env, n)
    labels env n (w:ws) = let (l, env1, n1)  = label env n w
                              (ls, env2, n2) = labels env1 n1 ws
                          in (l:ls, env2, n2)

    -- Returns the document, and the updated numbering
    ppr_ty env n ty = case ty of
      FunTy { ft_web = w, ft_arg = arg, ft_res = res }
        -> let (lbl, env1, n1) = label env n w
               (d_arg, env2, n2) = ppr_ty env1 n1 arg
               (d_res, env3, n3) = ppr_ty env2 n2 res
           in (sep [ paren_if (is_compound arg) d_arg <+> text ("-{" ++ lbl ++ "}->"), d_res ]
              , env3, n3)
      ForAllTy (Bndr tv _) body
        -> let (d, env1, n1) = ppr_ty env n body
           in (text "forall" <+> ppr tv <> dot <+> d, env1, n1)
      TyConApp tc tys
        -> let (ds, env1, n1) = ppr_args env n tys
           in (if null tys then ppr tc else ppr tc <+> sep ds, env1, n1)
      AppTy t1 t2
        -> let (ds, env1, n1) = ppr_args env n [t1, t2]
           in (sep ds, env1, n1)
      CastTy t _ -> ppr_ty env n t
      _          -> (ppr ty, env, n)

    ppr_args env n []     = ([], env, n)
    ppr_args env n (t:ts) = let (d, env1, n1)  = ppr_ty env n t
                                (ds, env2, n2) = ppr_args env1 n1 ts
                            in (paren_if (is_compound t || is_app t) d : ds, env2, n2)

    label env n w
      | isPlaceholderWeb w || w `elementOfUniqSet` exposed = ("E", env, n)
      | Just k <- lookupUFM env w                         = (show k, env, n)
      | otherwise                                          = (show n, addToUFM env w n, n + 1)

    is_compound (FunTy {})    = True
    is_compound (ForAllTy {}) = True
    is_compound _             = False
    is_app (TyConApp _ (_:_)) = True
    is_app (AppTy {})         = True
    is_app _                  = False

    paren_if True  d = parens d
    paren_if False d = d

dump :: Logger -> DumpFlag -> String -> SDoc -> CoreM ()
dump logger flag hdr doc
  = liftIO $ putDumpFileMaybe logger flag hdr FormatCore doc

{- Note [No early uncurrying]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The early run does not uncurry.  Uncurrying before demand analysis loses
GHC's call-by-value for strict arguments: the simplifier evaluates a strict
argument before a call (using the callee's demand signature), but not a
strict *component* of an unboxed-tuple argument.  So after uncurrying the
accumulator loop
    go (x:xs) acc = go xs (if x > acc then x else acc)
into  go (# xs, acc #), each call builds a thunk for the accumulator, and the
chain overflows the stack when forced (testsuite: simplCore/should_run/T10830,
maximumBy over [1..10000] with a 100k stack).  After demand analysis and
worker/wrapper (the late run) the arguments are already evaluated where they
need to be.
-}

{- Note [Early webs]
~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-early the web pipeline also runs before the main simplifier
phases (GHC.Core.Opt.Pipeline.getCoreToDo), so that the simplifier, the
inliner and worker/wrapper see the transformed program.

Demand analysis has not run yet at that point, so arity raising only finds
the lambdas whose strictness is evident syntactically (see isStrictIn in
GHC.WebCore.Transform.ArityRaise).  We deliberately do not run demand
analysis just for this pass: it would change what the rest of the pipeline
sees, and confound the experiment (does an early web pass change what the
inliner does?).

Before the simplifier, INLINE and INLINABLE functions have stable unfoldings
that the inliner relies on.  Annotation treats them as interface Ids
(ws_interface_ids), so their types never change and their unfoldings are
kept.
-}
