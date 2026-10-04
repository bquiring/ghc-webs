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
import GHC.Types.Id.Info ( isEmptyRuleInfo )
import GHC.Types.Tickish
import GHC.Types.Unique.Supply
import GHC.Types.Unique.Set ( unionManyUniqSets, nonDetEltsUniqSet )
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Core.FVs ( rulesFreeVars, bndrRuleAndUnfoldingVarsDSet )
import GHC.Types.Web

import GHC.Utils.Misc ( HasDebugCallStack )
import GHC.Utils.Outputable
import GHC.Utils.Panic

import GHC.WebCore.Sigs
import GHC.WebCore.Traverse ( typeWebs )

import Data.Array ( bounds, listArray )
import Data.Maybe ( fromMaybe )

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

-- | Annotate a program.  The webs in the types of exported binders, and of
-- binders whose unfoldings or rules may reach the interface, are exposed.
-- See Note [Exposed webs] in GHC.WebCore.Sigs
annotateProgram :: UniqSupply -> [CoreRule] -> CoreProgram -> (CoreProgram, WebSigs)
annotateProgram us rules binds
  = case unAnnM (ann_top binds) us emptyWebSigs of
      (binds', _, sigs) -> (binds', sigs)
  where
    iface_ids = interfaceIds rules binds

    ann_top bs
      = do { -- All top-level binders are in scope everywhere
             -- c.f. lintCoreBindings
             (env, _) <- annBndrs emptyVarEnv (bindersOfBinds bs)
           ; bs' <- mapM (ann_top_bind env) bs
           ; exposeExported bs'
           ; modifySigs (\sigs -> sigs { ws_interface_ids = iface_ids })
           ; return bs' }

    ann_top_bind env (NonRec b rhs)
      = NonRec (lookupBndr env b) <$> annExpr env rhs
    ann_top_bind env (Rec prs)
      = Rec <$> sequence [ (,) (lookupBndr env b) <$> annExpr env rhs | (b, rhs) <- prs ]

    exposeExported bs'
      = modifySigs $ addExposedWebs $
        unionManyUniqSets [ typeWebs (idType b) | b <- bindersOfBinds bs'
                                                , b `elemVarSet` iface_ids ]

-- | The local top-level Ids whose unfoldings or rules may reach the interface
-- file: the exported Ids, the Ids free in the RULES, and the top-level Ids
-- that have rules of their own (Tidy may keep those, e.g. with
-- -fkeep-auto-rules), closed over the Ids free in their stable unfoldings and
-- rules.  Vanilla unfoldings need no care: Tidy rebuilds them from the final
-- right-hand side, i.e. from the transformed program (see tidyTopUnfolding
-- in GHC.Iface.Tidy), so they agree with the new calling conventions.
interfaceIds :: [CoreRule] -> CoreProgram -> VarSet
interfaceIds rules binds = go emptyVarSet roots
  where
    top_bndrs = mkVarSet (bindersOfBinds binds)
    roots     = filter isExportedId (bindersOfBinds binds)
             ++ filter (not . isEmptyRuleInfo . idSpecialisation) (bindersOfBinds binds)
             ++ nonDetEltsUniqSet (rulesFreeVars rules `intersectVarSet` top_bndrs)

    go acc []     = acc
    go acc (v:vs)
      | v `elemVarSet` acc = go acc vs
      | otherwise
      = go (acc `extendVarSet` v)
           (dVarSetElems (bndrRuleAndUnfoldingVarsDSet v) `filter_top` vs)

    filter_top new vs = [ v | v <- new, v `elemVarSet` top_bndrs ] ++ vs

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
                          Nothing -> annExposedType (idType v)
                ; let clone = setIdType v ty
                ; modifySigs (addGlobalIdSig v clone)
                ; return clone } }

-- | The exposed signature of a data constructor's 'dataConRepType'
annDataCon :: DataCon -> AnnM Type
annDataCon dc
  = do { sigs <- getSigs
       ; case lookupDataConSig sigs dc of
           Just ty -> return ty
           Nothing -> do { ty <- annExposedType (dataConRepType dc)
                         ; modifySigs (addDataConSig dc ty)
                         ; return ty } }

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
    ann_branch br@(CoAxBranch { cab_lhs = lhs, cab_rhs = rhs })
      = do { lhs' <- mapM annExposedType lhs
           ; rhs' <- annExposedType rhs
           ; return (br { cab_lhs = lhs', cab_rhs = rhs' }) }

-- | Annotate a closed type, exposing all its webs
annExposedType :: HasDebugCallStack => Type -> AnnM Type
annExposedType ty
  = do { ty' <- annType emptyVarEnv ty
       ; modifySigs (addExposedWebs (typeWebs ty'))
       ; return ty' }

------------------------------------------------------------------
--      Utilities
------------------------------------------------------------------

orElse :: Maybe a -> a -> a
orElse = flip fromMaybe
