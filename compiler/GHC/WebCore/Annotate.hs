-- | Initial annotation: give every value lambda, value call, and term-level
-- arrow of a Core program its own fresh web.
--
-- See Note [Initial annotation].
module GHC.WebCore.Annotate
  ( annotateProgram
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion.Axiom
import GHC.Core.DataCon
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprType, mkLamType )

import GHC.Types.Id
import GHC.Types.Id.Info ( isEmptyRuleInfo, RecSelParent(..) )
import GHC.Types.Tickish
import GHC.Types.Unique.Supply
import GHC.Types.Unique.Set ( nonDetEltsUniqSet, mkUniqSet, unionManyUniqSets )
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Core.FVs ( rulesFreeVars, stableUnfoldingVars )
import GHC.Types.Web

import GHC.Utils.Misc ( HasDebugCallStack )
import GHC.Utils.Outputable
import GHC.Utils.Panic

import GHC.WebCore.Sigs
import GHC.Types.Name ( Name, getName, nameModule_maybe, nameOccName, occNameString )
import GHC.Unit.Module ( moduleName, moduleNameString )
import GHC.WebCore.Traverse ( typeWebs )

import Data.Array ( bounds, listArray )
import Data.Maybe ( fromMaybe )
import Control.Monad ( when )

{- Note [Initial annotation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Annotation turns ordinary Core into web-annotated Core:

  * every value lambda  (Lam x e, x an Id)       becomes  WebLam w x e
  * every value call    (App f a, a not a type)  becomes  WebApp w f a
  * every term-level arrow in a type             gets     a web w

each with a fresh web w.  Web Lint (GHC.WebCore.Lint) then finds out which
webs must be the same.

Details:

  * Binders: every Id binder gets a new type with fresh webs (setIdType, which
    keeps the Unique and the IdInfo).  Occurrences are replaced using an IdEnv,
    so the binder and its occurrences have the same type.  Type variables are
    unchanged: webs never appear in kinds.

  * Types: every FunTy gets a fresh web, including FunTys in type arguments,
    e.g. the arrow in (Maybe (Int -> Int)).  Type synonyms whose right-hand
    side, once applied, contains an arrow are expanded so that the arrow can
    carry a web; other synonyms are kept.  Arrows in kinds are left alone.
    Arrows that only appear after instantiation, e.g. (cat b c) with
    cat := (->), cannot get webs; see Note [Arrows without webs] in
    GHC.WebCore.Lint.

  * Coercions: FunCos get fresh webs; the types inside coercions are annotated.

  * Global entities (imported Ids, data constructors, coercion axioms) use
    exposed signatures.  See Note [Exposed webs] in GHC.WebCore.Sigs.

  * Coercion arguments and coercion lambdas: a coercion argument is a value
    argument when the function's type at that point is an arrow (rather than a
    forall over a coercion variable).  We decide by looking at the type.

  * Not annotated: RULES and unfoldings.  Web Lint does not look at them.
-}

-- | Annotate a program.  The webs in the types of the binders whose
-- unfoldings or rules must survive (keptIds) are exposed.
-- See Note [Exposed webs] in GHC.WebCore.Sigs
annotateProgram :: Bool   -- ^ Keep stable unfoldings (the early run; see
                          --   Note [Early webs] in GHC.WebCore.Pipeline)
                -> (TyCon -> Bool)   -- ^ Types with hidden fields: Note [Hidden fields]
                -> UniqSupply -> [CoreRule] -> CoreProgram -> (CoreProgram, WebSigs)
annotateProgram keep_stable hidden us rules binds
  = case unAnnM (ann_top binds) us init_sigs of
      (binds', _, sigs) -> (binds', sigs)
  where
    init_sigs = emptyWebSigs { ws_interface_ids = keptIds keep_stable hidden rules binds
                             , ws_hidden_fields = hidden }

    ann_top bs
      = do { -- All top-level binders are in scope everywhere
             -- c.f. lintCoreBindings
             (env, _) <- annBndrs emptyVarEnv (bindersOfBinds bs)
           ; mapM (ann_top_bind env) bs }

    ann_top_bind env (NonRec b rhs)
      = NonRec (lookupBndr env b) <$> annExpr env rhs
    ann_top_bind env (Rec prs)
      = Rec <$> sequence [ (,) (lookupBndr env b) <$> annExpr env rhs | (b, rhs) <- prs ]

-- | The local Ids whose types must not change, because unannotated Core that
-- the web transformations do not rewrite refers to them:
--
--   * the exported Ids (their types are in the interface), except the record
--     selectors of types with hidden fields: GHC marks every selector
--     exported, but these are not, and their types follow the fields
--     (Note [Hidden fields] in GHC.WebCore.Sigs)
--   * the Ids free in the RULES for imported Ids
--   * the binders, at any level, that have rules of their own, and the local
--     Ids free in those rules (Tidy may keep the rules of top-level Ids,
--     e.g. with -fkeep-auto-rules, and Core Lint checks all of them)
--   * in the early run (keep_stable), the binders that have stable unfoldings
--     (INLINE and INLINABLE functions, which the simplifier that runs
--     afterwards relies on)
--
-- closed over the local Ids free in their stable unfoldings and rules.  Their
-- unfoldings and rules are kept (see zapLocalUnfolding).  Vanilla unfoldings
-- need no care: Tidy rebuilds them from the final right-hand side, i.e. from
-- the transformed program (see tidyTopUnfolding in GHC.Iface.Tidy), and the
-- simplifier rebuilds them too.  In the late run nothing inlines afterwards,
-- so zapping other unfoldings is harmless.
keptIds :: Bool -> (TyCon -> Bool) -> [CoreRule] -> CoreProgram -> VarSet
keptIds keep_stable hidden rules binds = go emptyVarSet roots
  where
    bndrs = allLetBinders binds
    roots = filter (\b -> isExportedId b && not (hidden_selector b)) (bindersOfBinds binds)
         ++ filter (not . isEmptyRuleInfo . idSpecialisation) bndrs
         ++ filter isLocalId (nonDetEltsUniqSet (rulesFreeVars rules))
         ++ (if keep_stable then filter (isStableUnfolding . realIdUnfolding) bndrs else [])

    hidden_selector b = case recordSelectorTyCon_maybe b of
      Just (RecSelData tc) -> hidden tc
      _                    -> False

    -- Look at the binders' own IdInfo: occurrences may carry stale copies.
    -- Several binders can share a Unique (shadowing; e.g. a join point the
    -- simplifier duplicated into several branches, each copy with its own
    -- rules), so keep them all.
    bndr_env = foldr (\b env -> extendVarEnv_C (++) env b [b]) emptyVarEnv bndrs

    go acc []     = acc
    go acc (v:vs)
      | v `elemVarSet` acc = go acc vs
      | otherwise
      = go (acc `extendVarSet` v) (filter isLocalId (deps v) ++ vs)

    -- The free variables of the binder's rules and stable unfolding,
    -- recomputed from the rules (the cached ruleInfoFreeVars can be stale)
    deps v = concat [ nonDetEltsUniqSet (rulesFreeVars (idCoreRules b))
                      ++ maybe [] nonDetEltsUniqSet (stableUnfoldingVars (realIdUnfolding b))
                    | b <- lookupVarEnv bndr_env v `orElse` [] ]

-- | All the let-bound (and top-level) binders of a program
allLetBinders :: CoreProgram -> [Id]
allLetBinders binds = foldr go_bind [] binds
  where
    go_bind bind acc = foldr go_pair acc (flattenBinds [bind])
    go_pair (b, rhs) acc = b : go rhs acc

    go :: CoreExpr -> [Id] -> [Id]
    go expr acc = case expr of
      Let bind body -> go_bind bind (go body acc)
      Lam _ e       -> go e acc
      WebLam _ _ e  -> go e acc
      App f a       -> go f (go a acc)
      WebApp _ f a  -> go f (go a acc)
      Case e _ _ as -> go e (foldr (\(Alt _ _ rhs) -> go rhs) acc as)
      Cast e _      -> go e acc
      Tick _ e      -> go e acc
      _             -> acc

------------------------------------------------------------------
--      The annotation monad
------------------------------------------------------------------

-- | A state monad over a unique supply (for fresh webs) and the exposed
-- signatures created so far.
newtype AnnM a = AnnM { unAnnM :: UniqSupply -> WebSigs -> (a, UniqSupply, WebSigs) }

instance Functor AnnM where
  fmap f (AnnM m) = AnnM $ \us sigs -> case m us sigs of (a, us', sigs') -> (f a, us', sigs')

instance Applicative AnnM where
  pure a = AnnM $ \us sigs -> (a, us, sigs)
  AnnM mf <*> AnnM ma = AnnM $ \us sigs ->
    case mf us sigs of
      (f, us1, sigs1) -> case ma us1 sigs1 of
        (a, us2, sigs2) -> (f a, us2, sigs2)

instance Monad AnnM where
  AnnM m >>= k = AnnM $ \us sigs ->
    case m us sigs of (a, us1, sigs1) -> unAnnM (k a) us1 sigs1

freshWeb :: AnnM WebId
freshWeb = AnnM $ \us sigs -> case takeUniqFromSupply us of
                                (u, us') -> (mkWebId u, us', sigs)

getSigs :: AnnM WebSigs
getSigs = AnnM $ \us sigs -> (sigs, us, sigs)

modifySigs :: (WebSigs -> WebSigs) -> AnnM ()
modifySigs f = AnnM $ \us sigs -> ((), us, f sigs)

-- | Maps each local binder (by Unique) to its annotated version
type AnnEnv = IdEnv Id

------------------------------------------------------------------
--      Binders
------------------------------------------------------------------

annBndr :: AnnEnv -> Var -> AnnM (AnnEnv, Var)
annBndr env b
  | isId b
  = do { ty' <- annType env (idType b)
       ; let b' = setIdType b ty'
         -- The webs of kept binders are exposed; see keptIds
       ; sigs <- getSigs
       ; when (b `elemVarSet` ws_interface_ids sigs) $
           modifySigs (addInflowWebs (mkUniqSet (polarWebs False ty')) .
                       addExposedWebsFrom (if isExportedId b then "exported binder"
                                           else "kept binder (rules, stable unfoldings)")
                                          (typeWebs ty'))
       ; return (extendVarEnv env b b', b') }
  | otherwise   -- Type variable: unchanged
  = return (env, b)

annBndrs :: AnnEnv -> [Var] -> AnnM (AnnEnv, [Var])
annBndrs env []     = return (env, [])
annBndrs env (b:bs) = do { (env1, b')  <- annBndr env b
                         ; (env2, bs') <- annBndrs env1 bs
                         ; return (env2, b':bs') }

lookupBndr :: AnnEnv -> Var -> Var
lookupBndr env v = lookupVarEnv env v `orElse` v

------------------------------------------------------------------
--      Expressions
------------------------------------------------------------------

annExpr :: AnnEnv -> CoreExpr -> AnnM CoreExpr
annExpr env expr = case expr of
  Var v
    | isGlobalId v -> Var <$> annGlobalId v
    | otherwise    -> return (Var (lookupBndr env v))

  Lit l -> return (Lit l)

  App f (Type ty)
    -> App <$> annExpr env f <*> (Type <$> annType env ty)

  App f (Coercion co)
    -> do { f'  <- annExpr env f
          ; co' <- annCo env co
          ; if isFunTy (exprType f')
            then do { w <- freshWeb; return (WebApp w f' (Coercion co')) }
            else return (App f' (Coercion co')) }

  App f a
    -> do { f' <- annExpr env f
          ; a' <- annExpr env a
          ; w  <- freshWeb
          ; return (WebApp w f' a') }

  Lam b e
    | isTyVar b
    -> Lam b <$> annExpr env e
    | otherwise
    -> do { (env', b') <- annBndr env b
          ; e' <- annExpr env' e
          ; if isCoVar b && not (isFunTy (mkLamType b' (exprType e')))
            then return (Lam b' e')    -- A forall over a coercion variable
            else do { w <- freshWeb; return (WebLam w b' e') } }

  Let (NonRec b rhs) body
    -> do { rhs' <- annExpr env rhs
          ; (env', b') <- annBndr env b
          ; body' <- annExpr env' body
          ; return (Let (NonRec b' rhs') body') }

  Let (Rec prs) body
    -> do { (env', bs') <- annBndrs env (map fst prs)
          ; rhss' <- mapM (annExpr env' . snd) prs
          ; body' <- annExpr env' body
          ; return (Let (Rec (zip bs' rhss')) body') }

  Case scrut b ty alts
    -> do { scrut' <- annExpr env scrut
          ; (env', b') <- annBndr env b
          ; ty' <- annType env ty
          ; alts' <- mapM (annAlt env') alts
          ; return (Case scrut' b' ty' alts') }

  Cast e co -> Cast <$> annExpr env e <*> annCo env co

  Tick t e -> Tick (annTick env t) <$> annExpr env e

  Type ty -> Type <$> annType env ty

  Coercion co -> Coercion <$> annCo env co

  WebLam {} -> pprPanic "annExpr: already annotated" (ppr expr)
  WebApp {} -> pprPanic "annExpr: already annotated" (ppr expr)

annAlt :: AnnEnv -> CoreAlt -> AnnM CoreAlt
annAlt env (Alt con bs rhs)
  = do { case con of
           DataAlt dc -> () <$ annDataCon dc  -- Make sure Web Lint can find its signature
           _          -> return ()
       ; (env', bs') <- annBndrs env bs
       ; rhs' <- annExpr env' rhs
       ; return (Alt con bs' rhs') }

annTick :: AnnEnv -> CoreTickish -> CoreTickish
annTick env t@(Breakpoint { breakpointFVs = ids })
  = t { breakpointFVs = map (lookupBndr env) ids }
annTick _ t = t

------------------------------------------------------------------
--      Types and coercions
------------------------------------------------------------------

annType :: AnnEnv -> Type -> AnnM Type
annType env = go
  where
    go ty@(TyVarTy {}) = return ty
    go ty@(LitTy {})   = return ty
    go (AppTy t1 t2)   = AppTy <$> go t1 <*> go t2
    go ty@(TyConApp tc tys)
      | isTypeSynonymTyCon tc
      , Just ty' <- coreView ty
      , hasArrow ty'
      = go ty'    -- Expand synonyms that hide arrows, such as (->) itself
                  -- (type (->) = FUN 'Many), or (type Endo a = a -> a)
      | otherwise
      = TyConApp tc <$> mapM go tys
    go (ForAllTy bndr ty) = ForAllTy bndr <$> go ty
    go ty@(FunTy { ft_arg = arg, ft_res = res })
      = do { w <- freshWeb
           ; arg' <- go arg
           ; res' <- go res
           ; return (ty { ft_web = w, ft_arg = arg', ft_res = res' }) }
    go (CastTy ty co)  = (\ty' -> CastTy ty' co) <$> go ty   -- Kind coercion: unchanged
    go (CoercionTy co) = CoercionTy <$> annCo env co

-- | Does this type contain an arrow, looking through synonyms?
hasArrow :: Type -> Bool
hasArrow ty
  | Just ty' <- coreView ty = hasArrow ty'
hasArrow (FunTy {})         = True
hasArrow (TyConApp _ tys)   = any hasArrow tys
hasArrow (AppTy t1 t2)      = hasArrow t1 || hasArrow t2
hasArrow (ForAllTy _ ty)    = hasArrow ty
hasArrow (CastTy ty _)      = hasArrow ty
hasArrow _                  = False

annCo :: AnnEnv -> Coercion -> AnnM Coercion
annCo env = go
  where
    goTy = annType env

    go (Refl ty)             = Refl <$> goTy ty
    go (GRefl r ty mco)      = (\ty' -> GRefl r ty' mco) <$> goTy ty
    go (TyConAppCo r tc cos) = TyConAppCo r tc <$> mapM go cos
    go (AppCo co1 co2)       = AppCo <$> go co1 <*> go co2
    go co@(ForAllCo { fco_body = body })
                             = (\body' -> co { fco_body = body' }) <$> go body
    go co@(FunCo { fco_arg = arg, fco_res = res })
      = do { w <- freshWeb
           ; arg' <- go arg
           ; res' <- go res
           ; return (co { fco_web = w, fco_arg = arg', fco_res = res' }) }
    go (CoVarCo cv)          = return (CoVarCo (lookupBndr env cv))
    go (AxiomCo ax cos)      = AxiomCo <$> annAxiomRule ax <*> mapM go cos
    go co@(UnivCo { uco_lty = lty, uco_rty = rty, uco_deps = deps })
      = do { lty' <- goTy lty
           ; rty' <- goTy rty
           ; deps' <- mapM go deps
           ; return (co { uco_lty = lty', uco_rty = rty', uco_deps = deps' }) }
    go (SymCo co)            = SymCo <$> go co
    go (TransCo co1 co2)     = TransCo <$> go co1 <*> go co2
    go (SelCo sel co)        = SelCo sel <$> go co
    go (LRCo lr co)          = LRCo lr <$> go co
    go (InstCo co arg)       = InstCo <$> go co <*> go arg
    go (KindCo co)           = KindCo <$> go co
    go (SubCo co)            = SubCo <$> go co
    go co@(HoleCo {})        = return co

------------------------------------------------------------------
--      Exposed signatures
------------------------------------------------------------------

-- | The clone of a global Id whose type is its exposed signature
-- See Note [Exposed webs] in GHC.WebCore.Sigs
annGlobalId :: Id -> AnnM Id
annGlobalId v
  = do { sigs <- getSigs
       ; case lookupGlobalIdSig sigs v of
           Just (_, clone) -> return clone
           Nothing ->
             do { ty <- case isDataConWorkId_maybe v of
                          -- A data constructor worker shares the signature
                          -- of its data constructor
                          Just dc -> annDataCon dc
                          Nothing -> do { t <- annExposedType ("imported " ++ originName (idName v)) (idType v)
                                        ; modifySigs (addInflowWebs (mkUniqSet (polarWebs True t)))
                                        ; return t }
                ; let clone = setIdType v ty
                ; modifySigs (addGlobalIdSig v clone)
                ; return clone } }

-- | The signature of a data constructor's 'dataConRepType': exposed, or for
-- a type with hidden fields, with only its own arrows exposed
-- See Note [Hidden fields]
annDataCon :: DataCon -> AnnM Type
annDataCon dc
  = do { sigs <- getSigs
       ; case lookupDataConSig sigs dc of
           Just ty -> return ty
           Nothing
             | ws_hidden_fields sigs (dataConTyCon dc)
             -> do { ty <- annType emptyVarEnv (dataConRepType dc)
                   ; modifySigs (addExposedWebsFrom ("constructor arrows " ++ originName (dataConName dc))
                                                    (mkUniqSet (spineWebs ty)) . addDataConSig dc ty)
                   ; return ty }
             | otherwise
             -> do { ty <- annExposedType ("constructor " ++ originName (dataConName dc)) (dataConRepType dc)
                   ; modifySigs (addInflowWebs (typeWebs ty))
                   ; modifySigs (addDataConSig dc ty)
                   ; return ty } }
  where
    -- The webs of the constructor's own arrows, one per field
    spineWebs ty = case ty of
      ForAllTy _ t                   -> spineWebs t
      FunTy { ft_web = w, ft_res = r } -> w : spineWebs r
      _                              -> []

annAxiomRule :: CoAxiomRule -> AnnM CoAxiomRule
annAxiomRule (UnbranchedAxiom ax) = UnbranchedAxiom . toUnbranchedAxiom <$> annAxiom (toBranchedAxiom ax)
annAxiomRule (BranchedAxiom ax i) = (\ax' -> BranchedAxiom ax' i) <$> annAxiom ax
annAxiomRule rule                 = return rule   -- Built-in rules: no arrows

-- | The clone of a coercion axiom whose branches have exposed signatures
annAxiom :: CoAxiom Branched -> AnnM (CoAxiom Branched)
annAxiom ax
  = do { sigs <- getSigs
       ; case lookupAxiomSig sigs ax of
           Just (_, clone) -> return clone
           Nothing ->
             do { let MkBranches arr = co_ax_branches ax
                ; branches' <- mapM ann_branch (fromBranches (co_ax_branches ax))
                ; let clone = ax { co_ax_branches = MkBranches (listArray (bounds arr) branches') }
                ; modifySigs (addAxiomSig ax clone)
                ; return clone } }
  where
    why = "axiom " ++ originName (getName ax)
    ann_branch br@(CoAxBranch { cab_lhs = lhs, cab_rhs = rhs })
      = do { lhs' <- mapM (annExposedType why) lhs
           ; rhs' <- annExposedType why rhs
           ; modifySigs (addInflowWebs (unionManyUniqSets (map typeWebs (rhs' : lhs'))))
           ; return (br { cab_lhs = lhs', cab_rhs = rhs' }) }

-- | Annotate a closed type, exposing all its webs
annExposedType :: HasDebugCallStack => String -> Type -> AnnM Type
annExposedType why ty
  = do { ty' <- annType emptyVarEnv ty
       ; modifySigs (addExposedWebsFrom why (typeWebs ty'))
       ; return ty' }

-- | A name with its module, for -ddump-webs-stats
originName :: Name -> String
originName n = maybe "" (\m -> moduleNameString (moduleName m) ++ ".") (nameModule_maybe n)
             ++ occNameString (nameOccName n)

------------------------------------------------------------------
--      Utilities
------------------------------------------------------------------

orElse :: Maybe a -> a -> a
orElse = flip fromMaybe
