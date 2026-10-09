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
import GHC.Unit.Module ( Module )
import GHC.Core.TyCon ( TyCon, tyConName, tyConDataCons, isAlgTyCon, isNewTyCon, isClassTyCon
                       , isFamInstTyCon )
import GHC.Core.DataCon ( dataConName, dataConFieldLabels, isVanillaDataCon, dataConWrapId_maybe, dataConTyCon )
import GHC.Types.Avail ( availsToNameSet )
import GHC.Types.FieldLabel ( flSelector )
import GHC.Types.Name.Set ( elemNameSet )
import GHC.Types.Id.Info ( ruleInfoRules )
import GHC.Types.Unique ( getUnique )

import GHC.Data.Bag
import GHC.Utils.Error ( DiagOpts, MessageClass(..), pprMessageBag, ghcExit )
import GHC.Utils.Logger
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Types.SrcLoc ( noSrcSpan )

import GHC.WebCore.Annotate
import GHC.WebCore.Boundary ( splitBoundary )
import GHC.WebCore.DataSplit ( DataSplitResult(..), splitDataTypes, nonParametric )
import GHC.Core.TyCo.FVs ( tyConsOfType )
import GHC.Core.DataCon ( dataConRepArgTys )
import GHC.WebCore.DataCopy ( UnboxOpts(..) )
import qualified GHC.WebCore.DataLint as DL
import GHC.WebCore.Erase
import GHC.WebCore.HiddenFields
import GHC.WebCore.Lint
import GHC.WebCore.Rename
import GHC.WebCore.Sigs
import GHC.WebCore.Solve
import GHC.WebCore.Transform.ArityRaise
import GHC.WebCore.Transform.Common ( pprWebVerdicts, UnfoldingPolicy(..), reorderTopBinds )
import GHC.WebCore.Transform.DeadParams ( deadParamsRound, Verdict(..) )
import GHC.WebCore.Transform.Uncurry
import GHC.WebCore.Transform.Strictness ( strictnessRound )
import GHC.WebCore.Transform.ResultRaise ( resultRaiseRound )
import GHC.WebCore.Transform.ConstProp ( constPropRound )
import GHC.WebCore.Transform.Inline ( inlineRound )
import GHC.WebCore.Transform.Defunc ( defuncProgram )
import GHC.WebCore.Transform.SpecIndex ( Indexed(..), specialiseIndexed )
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
-- before worker/wrapper (-fcore-webs-early); see Note [Early webs].
webPass :: Bool -> ModGuts -> CoreM ModGuts
webPass early guts
  = do { dflags <- getDynFlags
       ; logger <- getLogger
       ; us     <- liftIO (mkSplitUniqSupply webUniqueTag)

       ; us0    <- liftIO (mkSplitUniqSupply webUniqueTag)

         -- Split data types (early run only)
         -- See Note [Splitting data types] in GHC.WebCore.DataSplit
       ; (binds_d, split_tcs) <-
           -- In the early run, or in the late run if there is no early one
           -- (Note [Unboxing in the late run] in GHC.WebCore.DataFlatten)
           if gopt Opt_CoreWebsDataSplit dflags && (early || not (gopt Opt_CoreWebsEarly dflags))
           then runDataSplit early logger dflags (mg_module guts) (mg_rules guts) (mg_binds guts)
           else return (mg_binds guts, [])

       ; let -- 0. Split exposed webs at the module boundary (early run only)
             -- See Note [Splitting webs at the boundary] in GHC.WebCore.Boundary
             binds0 | early, gopt Opt_CoreWebsBoundary dflags
                    = splitBoundary (unfoldingOpts dflags) us0 (mg_rules guts) binds_d
                    | otherwise
                    = binds_d
             cfg    = webLintConfig dflags

             -- 1. Annotation
             hidden | gopt Opt_CoreWebsNoHiddenFields dflags = const False
                    | otherwise = hiddenFields guts split_tcs binds0
             (binds1, sigs1) = annotateProgram early hidden us (mg_rules guts) binds0

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

         -- Transformations, with the constructor signatures with hidden
         -- fields in the program (Note [Signatures in the program] in
         -- GHC.WebCore.HiddenFields)
       ; us_sig <- liftIO (mkSplitUniqSupply webUniqueTag)
       ; let (binds2s, sig_bndrs) = addSigBinders us_sig sigs2 binds2
       ; (binds_t1, sigs_t, transformed0) <- runTransforms early logger dflags cfg sigs2 binds2s
       ; let binds_t0 = removeSigBinders sig_bndrs binds_t1

         -- Defunctionalisation runs last: it changes the arrow types of the
         -- webs it handles into new data types
         -- See Note [Defunctionalisation] in GHC.WebCore.Transform.Defunc
       ; (binds_t, new_ixs, defunced) <-
           if gopt Opt_CoreWebsDefunc dflags
           -- Hidden-field webs are left alone (Note [Signatures follow the
           -- transformations] in GHC.WebCore.HiddenFields)
           then runDefunc early logger dflags cfg (mg_module guts)
                          (addExposedWebs (hiddenFieldWebs sigs_t) sigs_t) binds_t0
           else return (binds_t0, [], False)
       ; let transformed = transformed0 || defunced

       ; dump logger Opt_D_dump_webs_summary "Webs: summary" $
           pprWebSummary (ws_exposed sigs_t) binds_t

       ; dump logger Opt_D_dump_webs_stats "Webs: statistics" $
           pprWebStats (sizeUniqSet (programWebs binds1)) (sizeUniqSet (programWebs binds2))
                       (ws_exposed sigs1)
                       (lengthBag pairs) sol
           $$ pprHiddenStats sigs2 binds2
           $$ pprTypeStats guts split_tcs binds0

         -- 4. Erasure
       ; let binds3a | transformed = reorderTopBinds (eraseProgram sigs_t binds_t)
                     | otherwise   = eraseProgram sigs_t binds_t
             -- Types whose hidden fields changed are rebuilt in place
             (binds3, rebuilt) = rebuildHiddenTypes sigs_t binds3a
             replace tc = maybe tc id (lookup tc rebuilt)

         -- If a transformation changed the program, it is not the original;
         -- Core Lint (endPass, with -dcore-lint) still checks the result
       ; when (gopt Opt_DoCoreLinting dflags && not transformed) $
           checkRoundTrip binds0 binds3

         -- Specialise the new types to their uses
         -- See Note [Specialising indexed types] in GHC.WebCore.Transform.SpecIndex
       ; us_s <- liftIO (mkSplitUniqSupply webUniqueTag)
       ; let (binds4, replaced, spec_dump)
               | null new_ixs = (binds3, [], [])
               | otherwise    = specialiseIndexed us_s [ Indexed tc ap | (tc, ap) <- new_ixs ] binds3
             new_tcs = [ maybe tc id (lookup tc replaced) | (tc, _) <- new_ixs ]
       ; unless (null spec_dump) $
           dump logger Opt_D_dump_webs_defunc "Webs: specialising defunctionalised types" (vcat spec_dump)

       ; return (guts { mg_binds = binds4
                      , mg_tcs = map replace (mg_tcs guts ++ split_tcs) ++ new_tcs }) }

-- | Lambda classes (classes with a lambda: what a transformation can act
-- on), how many are internal, and the hidden fields (Note [Hidden fields]
-- in GHC.WebCore.Sigs).  For a renamed program.
pprHiddenStats :: WebSigs -> CoreProgram -> SDoc
pprHiddenStats sigs binds
  = vcat [ text "Lambda classes:"           <+> int (sizeUniqSet lams)
         , text "Internal lambda classes:"  <+> int (sizeUniqSet (lams `minusUniqSet` ws_exposed sigs))
         , text "Types with hidden fields:" <+> int (sizeUniqSet hidden_tcs)
         , text "Webs in hidden fields:"    <+> int (sizeUniqSet (hiddenFieldWebs sigs)) ]
  where
    lams = mkUniqSet (concatMap (lamWebs . snd) (flattenBinds binds))
    hidden_tcs = mkUniqSet [ getUnique (dataConTyCon dc) | (dc, _) <- nonDetEltsUFM (ws_dcs sigs)
                                                       , ws_hidden_fields sigs (dataConTyCon dc) ]
    lamWebs e = case e of
      WebLam w _ x  -> w : lamWebs x
      Lam _ x       -> lamWebs x
      App f a       -> lamWebs f ++ lamWebs a
      WebApp _ f a  -> lamWebs f ++ lamWebs a
      Let b x       -> concatMap lamWebs (rhssOfBind b) ++ lamWebs x
      Case x _ _ as -> lamWebs x ++ concat [ lamWebs r | Alt _ _ r <- as ]
      Cast x _      -> lamWebs x
      Tick _ x      -> lamWebs x
      _             -> []

-- | The data types defined here, by whether their representation is visible
-- outside the module (Note [Hidden fields] in GHC.WebCore.Sigs)
pprTypeStats :: ModGuts -> [TyCon] -> CoreProgram -> SDoc
pprTypeStats guts split_tcs binds
  = vcat $ [ text "Data types defined:"            <+> int (length datas)
           , text "Representation exported:"       <+> int (length [ () | ExportedRep <- cls ])
           , text "Internal data types:"           <+> int (length internals)
           , text "Internal, exported abstractly:" <+> int (length [ () | (True, _) <- internals ]) ]
        ++ [ text ("Internal, " ++ label w ++ ":") <+> int (length [ () | (_, w') <- internals, w' == w ])
           | w <- [minBound .. maxBound] ]
        ++ [ text "Data splitting copies:"         <+> int (length split_tcs)
           , text "Classes and empty types:"       <+> int (length [ () | NotData <- cls ]) ]
  where
    classify  = classifyTyCon guts binds
    cls       = map classify (mg_tcs guts)
    datas     = [ c | c <- cls, not (isNotData c) ]
    internals = [ (abs_, w) | Internal abs_ w <- cls ]
    isNotData NotData = True
    isNotData _       = False
    label w = case w of
      HiddenFields -> "hidden fields"
      Pinned       -> "in rules or stable unfoldings"
      UnsafeCo     -> "unsafe coercion"
      NewtypeTc    -> "newtype"
      FamInst      -> "data family instance"
      Existential  -> "existential or GADT"
      Wrapper      -> "constructor wrapper"

-- | The types defined here whose fields other modules cannot see
-- See Note [Hidden fields] in GHC.WebCore.Sigs
hiddenFields :: ModGuts -> [TyCon] -> CoreProgram -> TyCon -> Bool
hiddenFields guts split_tcs binds = \tc -> getUnique tc `elementOfUniqSet` hidden
  where
    classify = classifyTyCon guts binds
    -- The types defined here, and the copies data splitting made
    hidden   = mkUniqSet [ getUnique t | t <- mg_tcs guts ++ split_tcs
                                     , Internal _ HiddenFields <- [classify t] ]

-- | Whose representation is visible outside the module, and for an internal
-- type, whether its fields are hidden (Note [Hidden fields] in
-- GHC.WebCore.Sigs) or what keeps them exposed
data TyConClass
  = NotData              -- ^ a class, a type without constructors, not algebraic
  | ExportedRep          -- ^ a constructor or record field is exported
  | Internal Bool Why    -- ^ internal (exported abstractly?)

data Why = HiddenFields | Pinned | UnsafeCo | NewtypeTc | FamInst | Existential | Wrapper
  deriving (Eq, Ord, Show, Enum, Bounded)

-- The program-wide sets (pinned constructors, unsafely coerced types) are
-- computed once per module
classifyTyCon :: ModGuts -> CoreProgram -> TyCon -> TyConClass
classifyTyCon guts binds = classify
  where
    classify t
      | not (isAlgTyCon t) || isClassTyCon t || null dcs = NotData
      | any visible dcs = ExportedRep
      | otherwise       = Internal (tyConName t `elemNameSet` exported) why
      where
        dcs = tyConDataCons t
        why | any (\dc -> getUnique dc `elementOfUniqSet` pinned) dcs = Pinned
            | getUnique t `elementOfUniqSet` unsafe                = UnsafeCo
            | isNewTyCon t                                         = NewtypeTc
            | isFamInstTyCon t                                     = FamInst
            | not (all isVanillaDataCon dcs)                       = Existential
            | not (all (null . dataConWrapId_maybe) dcs)           = Wrapper  -- rebuilt without one
            | otherwise                                            = HiddenFields

    exported = availsToNameSet (mg_exports guts)
    visible dc = dataConName dc `elemNameSet` exported
              || any ((`elemNameSet` exported) . flSelector) (dataConFieldLabels dc)

    -- Types an unsafe coercion relates to another, and the types reachable
    -- through their fields (Note [Hidden fields] in GHC.WebCore.Sigs)
    unsafe = close emptyUniqSet (concatMap exprUnsafeTyCons (concatMap rhssOfBind binds))
    close acc [] = acc
    close acc (t : ts)
      | getUnique t `elementOfUniqSet` acc = close acc ts
      | otherwise = close (addOneToUniqSet acc (getUnique t))
                          (concat [ nonDetEltsUniqSet (tyConsOfType (scaledThing f))
                                  | dc <- tyConDataCons t, f <- dataConRepArgTys dc ] ++ ts)

    -- Constructors in Core the transformations do not rewrite: the RULES,
    -- and the binders' own rules and stable unfoldings (which Tidy may put
    -- in the interface, in either run)
    pinned = mkUniqSet (map getUnique (concatMap ruleCons (mg_rules guts)
                                       ++ concatMap bndrCons (allBinders binds)))
    ruleCons r = case r of
      Rule { ru_args = args, ru_rhs = rhs } -> concatMap exprCons (rhs : args)
      BuiltinRule {}                        -> []
    bndrCons b = concatMap ruleCons (ruleInfoRules (idSpecialisation b))
              ++ case realIdUnfolding b of
                   u | isStableUnfolding u, Just e <- maybeUnfoldingTemplate u -> exprCons e
                   _ -> []

    allBinders bs = concat [ b : inner e | (b, e) <- flattenBinds bs ]
      where inner e = case e of
              Let bind body -> allBinders [bind] ++ inner body
              Lam _ x       -> inner x
              App f a       -> inner f ++ inner a
              Case x _ _ as -> inner x ++ concat [ inner r | Alt _ _ r <- as ]
              Cast x _      -> inner x
              Tick _ x      -> inner x
              _             -> []

-- | The type constructors an expression relates by unsafe coercion: in the
-- type arguments of a non-parametric function, and in the types of a UnivCo
exprUnsafeTyCons :: CoreExpr -> [TyCon]
exprUnsafeTyCons e = case e of
  App {} | (Var v, args) <- collectArgs e, nonParametric v
         -> concat [ tcs t | Type t <- args ] ++ concatMap exprUnsafeTyCons args
  Var _         -> []
  App f a       -> exprUnsafeTyCons f ++ exprUnsafeTyCons a
  Lam _ x       -> exprUnsafeTyCons x
  Let bind body -> concatMap exprUnsafeTyCons (rhssOfBind bind) ++ exprUnsafeTyCons body
  Case x _ _ as -> exprUnsafeTyCons x ++ concat [ exprUnsafeTyCons r | Alt _ _ r <- as ]
  Cast x co     -> exprUnsafeTyCons x ++ coUnsafe co
  Tick _ x      -> exprUnsafeTyCons x
  Coercion co   -> coUnsafe co
  _             -> []
  where
    tcs t = nonDetEltsUniqSet (tyConsOfType t)
    coUnsafe co = case co of
      UnivCo { uco_lty = l, uco_rty = r, uco_deps = ds } -> tcs l ++ tcs r ++ concatMap coUnsafe ds
      TyConAppCo _ _ cs -> concatMap coUnsafe cs
      AppCo a b         -> coUnsafe a ++ coUnsafe b
      ForAllCo { fco_body = b } -> coUnsafe b
      FunCo { fco_arg = a, fco_res = r } -> coUnsafe a ++ coUnsafe r
      AxiomCo _ cs      -> concatMap coUnsafe cs
      SymCo c           -> coUnsafe c
      TransCo a b       -> coUnsafe a ++ coUnsafe b
      SelCo _ c         -> coUnsafe c
      LRCo _ c          -> coUnsafe c
      InstCo a b        -> coUnsafe a ++ coUnsafe b
      SubCo c           -> coUnsafe c
      _                 -> []

-- | Split data types (Note [Splitting data types] in GHC.WebCore.DataSplit);
-- stop if Data Lint finds a type error in the annotated program
runDataSplit :: Bool -> Logger -> DynFlags -> Module -> [CoreRule] -> CoreProgram
             -> CoreM (CoreProgram, [TyCon])
runDataSplit early logger dflags this_mod rules binds
  = do { us <- liftIO (mkSplitUniqSupply webUniqueTag)
       ; let unbox | gopt Opt_CoreWebsDataUnbox dflags
                   = Just (UnboxOpts { uo_eager      = gopt Opt_CoreWebsDataUnboxEager dflags
                                     , uo_nested     = gopt Opt_CoreWebsUnboxNested dflags
                                     , uo_strict_elim = not (gopt Opt_CoreWebsNoStrictElim dflags)
                                     , uo_max_size   = websMaxUnboxSize dflags
                                     , uo_rounds     = websUnboxRounds dflags
                                     , uo_trust_demands = early
                                     , uo_orig_sizes = [] })
                   | otherwise = Nothing
             -- Note [Keeping only useful splits] in GHC.WebCore.DataSplit
             split keep = splitDataTypes unbox keep (dataLintConfig dflags) this_mod us rules binds
             res0 = split Nothing
             res | Just _ <- unbox, dsr_changed res0 = split (Just (dsr_useful res0))
                 | otherwise                         = res0
             errs = DL.dlr_errs (dsr_lint res)
       ; unless (isEmptyBag errs) $ liftIO $
           do { logMsg logger MCInfo noSrcSpan $ withPprStyle defaultDumpStyle $
                  vcat [ text "*** Data Lint errors: after annotating copies ***"
                       , pprMessageBag errs ]
              ; ghcExit logger 1 }
       ; dump logger Opt_D_dump_webs_data "Webs: splitting data types" (dsr_dump res)
       ; return (dsr_binds res, dsr_tycons res) }

dataLintConfig :: DynFlags -> DL.LintConfig
dataLintConfig dflags
  = DL.LintConfig { DL.l_diagOpts = initDiagOpts dflags
                  , DL.l_platform = targetPlatform dflags
                  , DL.l_flags    = flags
                  , DL.l_vars     = [] }
  where
    flags = DL.LF { DL.lf_check_global_ids           = False
                  , DL.lf_check_inline_loop_breakers = False
                  , DL.lf_check_static_ptrs          = DL.AllowAnywhere
                  , DL.lf_report_unsat_syns          = True
                  , DL.lf_check_linearity            = gopt Opt_DoLinearCoreLinting dflags
                  , DL.lf_check_fixed_rep            = True }

-- | Defunctionalise, check the result with Web Lint, and dump the verdicts.
-- Returns the new program, the new type constructors, and whether anything
-- changed.
runDefunc :: Bool -> Logger -> DynFlags -> LintConfig -> Module -> WebSigs -> CoreProgram
          -> CoreM (CoreProgram, [(TyCon, Maybe Id)], Bool)
runDefunc early logger dflags cfg this_mod sigs binds
  = do { us <- liftIO (mkSplitUniqSupply webUniqueTag)
       ; let pol = UnfoldingPolicy { up_keep = ws_interface_ids sigs, up_early = early }
             (res, vs) = defuncProgram (gopt Opt_CoreWebsDefuncLifted dflags)
                                       this_mod pol us (ws_exposed sigs) binds
       ; dump logger Opt_D_dump_webs_defunc "Webs: defunctionalisation" $
           pprWebVerdicts [ (v, bs) | (_, v, _, bs) <- vs ]
       ; case res of
           Nothing -> return (binds, [], False)
           Just (binds', tcs) ->
             do { let what = "defunctionalisation"
                      lres = lintWebProgram cfg sigs binds'
                ; reportWebLint logger dflags what binds' lres
                ; checkSolved what lres
                ; return (binds', tcs, True) } }


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
--
-- A round that changes types also returns the type rewrite it applied, for
-- the signatures of constructors with hidden fields (Note [Signatures follow
-- the transformations] in GHC.WebCore.HiddenFields); it reads the current
-- ones from the WebSigs.
type TransformRound = WebSigs -> UniqSupply -> WebSet -> CoreProgram
                   -> (Maybe (CoreProgram, WebSet, Type -> Type), [(WebId, SDoc, Bool, [Id])])

-- | Run a web transformation in rounds until nothing changes, running Web
-- Lint after each round: the transformation must keep the program
-- well-typed.  Returns whether the program changed.
runTransform :: String -> DumpFlag -> TransformRound
             -> Logger -> DynFlags -> LintConfig -> WebSigs
             -> CoreProgram -> CoreM (CoreProgram, WebSigs, Bool)
runTransform name dump_flag do_round logger dflags cfg sigs0 binds0
  = go (1 :: Int) emptyUniqSet sigs0 binds0 emptyUFM False
  where
    max_rounds = 10

    go n done sigs binds verdicts changed
      | n > max_rounds = finish sigs binds verdicts changed
      | otherwise
      = do { us <- liftIO (mkSplitUniqSupply webUniqueTag)
           ; case do_round sigs us done binds of
               (Nothing, vs) -> finish sigs binds (record vs verdicts) changed
               (Just (binds0', handled, rw_ty), vs) ->
                 do { let what   = name ++ ", round " ++ show n
                          sigs'  = updateDataConSigs rw_ty sigs
                          binds' = refreshWorkers sigs' binds0'
                          res    = lintWebProgram cfg sigs' binds'
                    ; reportWebLint logger dflags what binds' res
                    ; checkSolved what res
                    ; go (n + 1) (done `unionUniqSets` handled) sigs' binds'
                         (record vs verdicts) True } }

    -- The last verdict for each web wins, except that a verdict that changed
    -- the program is not overwritten by a later one that did not (e.g. an
    -- uncurried web is no longer curried in the next round)
    record vs acc = foldl' (\m (w, v, ch, bs) -> addToUFM_C keep m w (v, ch, bs)) acc vs
    keep old@(_, old_ch, _) new@(_, new_ch, _)
      | old_ch && not new_ch = old
      | otherwise            = new

    finish sigs binds verdicts changed
      = do { dump logger dump_flag ("Webs: " ++ name) $
               pprWebVerdicts [ (v, bs) | (v, _, bs) <- nonDetEltsUFM verdicts ]
           ; return (binds, sigs, changed) }

-- | Did a dead-parameter verdict change the program?
changes :: Verdict -> Bool
changes Delete   = True
changes (Unit _) = True
changes _        = False

-- | The web transformations, in the order they run
-- See GHC.WebCore.Transform.*
runTransforms :: Bool -> Logger -> DynFlags -> LintConfig -> WebSigs
              -> CoreProgram -> CoreM (CoreProgram, WebSigs, Bool)
runTransforms early logger dflags cfg sigs0 binds0
  = foldM step (binds0, sigs0, False) transforms
  where
    exposed = ws_exposed sigs0
    keep    = UnfoldingPolicy { up_keep = ws_interface_ids sigs0, up_early = early }

    -- A round that does not change types
    same r = case r of
      (Just (b, ws), vs) -> (Just (b, ws, id), vs)
      (Nothing, vs)      -> (Nothing, vs)

    transforms =
      [ ( Opt_CoreWebsInline, "super-beta inlining", Opt_D_dump_webs_inline
        , \_ us done b -> same (inlineRound (unfoldingOpts dflags) us exposed done b) )
      , ( Opt_CoreWebsConstProp, "constant propagation", Opt_D_dump_webs_const_prop
        , \_ us done b -> same (constPropRound us exposed done b) )
      , ( Opt_CoreWebsArityRaise, "arity raising", Opt_D_dump_webs_arity_raise
        , \sigs us done b -> arityRaiseRound (fieldTys sigs) us exposed keep done b )
      , ( Opt_CoreWebsDeadParams, "dead parameters", Opt_D_dump_webs_dead_params
        , \_ us done b -> case deadParamsRound us exposed keep done b of
                            (r, vs) -> (r, [ (w, ppr v, changes v, bs) | (w, v, bs) <- vs ]) )
      , ( Opt_CoreWebsUncurry, "uncurrying", Opt_D_dump_webs_uncurry
        , \_ us _ b -> case uncurryRound (gopt Opt_CoreWebsUncurryKnown dflags) us exposed keep b of
                         (r, vs) -> (fmap (\(b', rw) -> (b', emptyUniqSet, rw)) r, vs) )
      , ( Opt_CoreWebsResultRaise, "result raising", Opt_D_dump_webs_result_raise
        , \sigs us done b -> resultRaiseRound (fieldTys sigs) us exposed keep done b )
      , ( Opt_CoreWebsStrictness, "strictness", Opt_D_dump_webs_strictness
        , \_ us done b -> same (strictnessRound us exposed done b) ) ]

    step (binds, sigs, changed) (flag, name, dump_flag, do_round)
      | early, flag == Opt_CoreWebsUncurry
      = return (binds, sigs, changed)   -- See Note [No early uncurrying]
      | gopt flag dflags
      = do { (binds', sigs', changed') <- runTransform name dump_flag do_round
                                                       logger dflags cfg sigs binds
           ; return (binds', sigs', changed || changed') }
      | otherwise
      = return (binds, sigs, changed)

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

{- Note [Early webs]
~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-early the web pipeline runs in the middle of the Core
pipeline (GHC.Core.Opt.Pipeline.getCoreToDo): after the main simplifier
phases, call arity and demand analysis, and before CPR analysis and
worker/wrapper.  So the transformations see a program that the inliner has
already contracted, with demand information on its binders; and
worker/wrapper, and the simplifier runs after it, see their result.  The
experiment (WEBS-EXPERIMENTS.md) asks whether they then have less to do.

Earlier versions ran before the main simplifier, with only syntactic
strictness (isStrictIn).

Note [No early uncurrying]
~~~~~~~~~~~~~~~~~~~~~~~~~~
The early run does not uncurry.  Worker/wrapper runs after it, and does not
unbox the components of an unboxed-tuple argument.  So after uncurrying

    make :: Int -> Int -> Tree      into      make :: (# Int, Int #) -> Tree

worker/wrapper no longer turns make into $wmake :: Int# -> Int# -> Tree, and
every call boxes its Ints: shootout/binary-trees allocated 2.2x as much.
(Before demand analysis, uncurrying also lost call-by-value for strict
arguments: simplCore/should_run/T10830 overflowed its stack.)  Uncurrying
belongs after worker/wrapper: the late run (-fcore-webs).

The simplifier runs afterwards, so INLINE and INLINABLE functions, whose
stable unfoldings it relies on, are treated as interface Ids
(ws_interface_ids): their types never change and their unfoldings are kept.
Stale vanilla unfoldings are zapped (Note [Unfoldings and rules after a
transformation] in GHC.WebCore.Transform.Common).
-}
