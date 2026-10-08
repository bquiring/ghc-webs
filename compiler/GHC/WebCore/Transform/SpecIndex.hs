-- | Specialising the indices of a type made by a web transformation to the
-- most general unifier of its uses.
--
-- See Note [Specialising indexed types].
module GHC.WebCore.Transform.SpecIndex
  ( Indexed(..)
  , specialiseIndexed
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion ( coercionKind, mkNomReflCo, mkCoVarCo, liftCoSubstWith )
import GHC.Core.DataCon
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.Predicate ( mkNomEqPred, getEqPredTys_maybe )
import GHC.Core.Subst
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.TyCo.FVs ( tyCoVarsOfTypeList )
import GHC.Core.Unify ( tcMatchTys )

import GHC.Data.FastString ( fsLit )
import GHC.Data.Pair ( Pair(..) )

import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Unique ( Unique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set ( elementOfUniqSet )
import GHC.Types.Unique.Supply
import GHC.Types.Var ( mkTyVar, mkCoVar )
import GHC.Types.Var.Env
import GHC.Types.Var.Set

import GHC.Utils.Outputable
import GHC.Utils.Panic ( pprPanic )

import Data.List ( nub )
import Data.Maybe ( fromMaybe )

{- Note [Specialising indexed types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Defunctionalisation (Note [Defunctionalisation] in
GHC.WebCore.Transform.Defunc) makes a type indexed by the argument and result
types of the web's arrow, D_w a b, whose constructors fix the indices with
equalities.  Often the uses agree more than that.  If every use of D_w is
D_w Int Int, D_w needs no parameters; if every use is D_w t t, one.  This
post-pass, run after the web pipeline (on erased Core), specialises such a
type to the most general unifier of its uses:

  1. Collect the index tuples of every use of T: in the types of binders,
     type arguments, case types and coercions, and at constructor
     applications; not in its eliminator (the apply function), which is
     rewritten instead.
  2. Anti-unify them into a pattern P(as) (as in GHC.WebCore.Transform.Defunc:
     each pair of disagreeing subterms, and each type variable, becomes a
     pattern variable).  If P is just distinct variables, T stays.
  3. Make T' as.  Each constructor C_i of T, whose indices are P(ts_i):
     where ts_ij is one of its existentials, used nowhere else in ts_i, that
     existential becomes the parameter a_j (no equality); otherwise keep
     the equality  a_j ~# ts_ij.
  4. Rewrite: T P(ss) becomes T' ss in every type; a constructor
     application gets the new type arguments and reflexive coercions; a case
     alternative binds the new existentials and coercions, and the old
     coercions are rebuilt from them by lifting P (liftCoSubst); the
     eliminator  forall a b. T a b -> ..  becomes  forall as. T' as -> ..,
     instantiated at P(as).

When the constructors' indices are all instances of P at distinct
existentials, no equality is left at all.  Vanilla unfoldings that mention
the old type are zapped; the simplifier, or Tidy, rebuilds them.
-}

-- | A type made by a web transformation, and its eliminator, if any:
-- a function  forall as. T as -> ...  whose type parameters are T's indices
data Indexed = Indexed { ix_tycon :: TyCon, ix_elim :: Maybe Id }

------------------------------------------------------------------
--      Anti-unification
------------------------------------------------------------------

newtype AU a = AU { runAU :: ([(Type, Type, TyVar)], [Unique])
                           -> Maybe (a, ([(Type, Type, TyVar)], [Unique])) }

instance Functor AU where
  fmap f (AU m) = AU $ \s -> fmap (\(a, s') -> (f a, s')) (m s)
instance Applicative AU where
  pure a = AU $ \s -> Just (a, s)
  AU mf <*> AU ma = AU $ \s -> case mf s of
    Nothing      -> Nothing
    Just (f, s1) -> fmap (\(a, s2) -> (f a, s2)) (ma s1)
instance Monad AU where
  AU m >>= k = AU $ \s -> case m s of
    Nothing      -> Nothing
    Just (a, s1) -> runAU (k a) s1

-- | The least general generalisation of some index tuples, with its
-- variables.  Every type variable becomes a pattern variable.
antiUnify :: UniqSupply -> [[Type]] -> Maybe ([TyVar], [Type])
antiUnify _ [] = Nothing
antiUnify us (t0 : ts)
  = do { (pat, (pairs, _)) <- runAU (foldl step (gens t0 t0) ts) ([], uniqsFromSupply us)
       ; let fresh = [ tv | (_, _, tv) <- pairs ]
             tvs   = nub [ tv | tv <- concatMap tyCoVarsOfTypeList pat, tv `elem` fresh ]
       ; if all (`elem` fresh) (concatMap tyCoVarsOfTypeList pat) then Just (tvs, pat) else Nothing }
  where
    step acc t = do { p <- acc; gens p t }
    gens ps qs | length ps == length qs = sequence (zipWith gen ps qs)
               | otherwise              = AU (const Nothing)

    gen :: Type -> Type -> AU Type
    gen p t
      | Just p' <- coreView p = gen p' t
      | Just t' <- coreView t = gen p t'
    gen p t = case (p, t) of
      (TyConApp tc1 ps, TyConApp tc2 ts')
        | tc1 == tc2, length ps == length ts'
        -> TyConApp tc1 <$> sequence (zipWith gen ps ts')
      (FunTy { ft_af = af1, ft_mult = m1, ft_arg = a1, ft_res = r1 }
        , FunTy { ft_af = af2, ft_mult = m2, ft_arg = a2, ft_res = r2 })
        | af1 == af2, m1 `eqType` m2
        -> (\a r -> p { ft_arg = a, ft_res = r }) <$> gen a1 a2 <*> gen r1 r2
      (AppTy f1 a1, AppTy f2 a2) -> AppTy <$> gen f1 f2 <*> gen a1 a2
      (LitTy l1, LitTy l2) | l1 == l2 -> return p
      (ForAllTy {}, _)   -> AU (const Nothing)
      (_, ForAllTy {})   -> AU (const Nothing)
      (CoercionTy {}, _) -> AU (const Nothing)
      (_, CoercionTy {}) -> AU (const Nothing)
      _                  -> var p t

    var p t = AU $ \(pairs, us') ->
      case [ tv | (p', t', tv) <- pairs, p' `eqType` p, t' `eqType` t ] of
        (tv : _) -> Just (mkTyVarTy tv, (pairs, us'))
        [] | let k = typeKind t
           , typeKind p `eqType` k
           , isEmptyVarSet (tyCoVarsOfType k)
           , (u : us'') <- us'
           -> let tv = mkTyVar (mkSystemName u (mkTyVarOccFS (fsLit "t"))) k
              in Just (mkTyVarTy tv, ((p, t, tv) : pairs, us''))
           | otherwise -> Nothing

------------------------------------------------------------------
--      Uses
------------------------------------------------------------------

-- | Every index tuple of a use of the type constructor, and whether every
-- use can be rewritten (it does not appear inside a coercion other than a
-- reflexive one, and its constructors are applied to all their type and
-- coercion arguments)
uses :: TyCon -> Maybe Id -> CoreProgram -> ([[Type]], Bool)
uses tc elim binds = foldr go_bind ([], True) binds
  where
    is_elim b = Just b == elim
    cons = tyConDataCons tc
    n_pre dc = length (dataConUnivTyVars dc) + length (dataConExTyCoVars dc)
               + length (dataConOtherTheta dc)

    go_bind (NonRec b e) acc = go_pair (b, e) acc
    go_bind (Rec prs)    acc = foldr go_pair acc prs
    go_pair (b, e) acc
      | is_elim b = acc
      | otherwise = go_ty (idType b) (go e acc)

    go :: CoreExpr -> ([[Type]], Bool) -> ([[Type]], Bool)
    go expr acc = case expr of
      Var v
        | Just dc <- isDataConWorkId_maybe v, dc `elem` cons, n_pre dc > 0
        -> bad acc                            -- not applied (see App below)
        | otherwise -> acc
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v, dc `elem` cons
        -> if length args >= n_pre dc
           then let idx = [ t | Type t <- take (length (dataConUnivTyVars dc)) args ]
                in add idx (foldr go acc (drop (n_pre dc) args))
           else bad acc
      App f a      -> go f (go a acc)
      Lam b e      -> go_bndr b (go e acc)
      Let bind e   -> go_bind bind (go e acc)
      Case e b t as -> go e $ go_bndr b $ go_ty t $
                       foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc as
      Cast e co    -> go e (go_co co acc)
      Tick _ e     -> go e acc
      Type t       -> go_ty t acc
      Coercion co  -> go_co co acc
      _            -> acc

    go_bndr b acc | isId b    = go_ty (idType b) acc
                  | otherwise = acc

    go_ty ty acc = case ty of
      TyConApp tc' tys
        | tc' == tc -> add tys (foldr go_ty acc tys)
        | otherwise -> foldr go_ty acc tys
      FunTy { ft_arg = a, ft_res = r } -> go_ty a (go_ty r acc)
      AppTy t1 t2  -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t -> go_ty t acc
      CastTy t _   -> go_ty t acc
      _            -> acc

    -- A coercion that mentions the type must be reflexive
    go_co co acc
      | Pair l r <- coercionKind co
      , mentions l || mentions r
      = case co of
          Refl t -> go_ty t acc
          _      -> bad acc
      | otherwise = acc
    mentions t = tc `elementOfUniqSet` tyConsOfType t

    add idx (ts, ok) = (idx : ts, ok)
    bad (ts, _) = (ts, False)

------------------------------------------------------------------
--      The new type
------------------------------------------------------------------

-- | A constructor of the specialised type, and how its old one maps to it
data NewCon = NewCon
  { nc_dc     :: DataCon
  , nc_elim   :: [(TyVar, Int)]   -- ^ old existentials that became parameter j
  , nc_eqs    :: [Int]            -- ^ parameters with an equality, in order
  , nc_old    :: DataCon }

data Spec = Spec
  { sp_old   :: TyCon
  , sp_new   :: TyCon
  , sp_tvs   :: [TyVar]       -- ^ the pattern's variables (T''s parameters)
  , sp_pat   :: [Type]        -- ^ the pattern: one type per old index
  , sp_cons  :: UniqFM DataCon NewCon }

-- | Match the pattern against an index tuple
instPat :: Spec -> [Type] -> [Type]
instPat sp idx = case tcMatchTys (sp_pat sp) idx of
  Just s  -> map (substTyVar s) (sp_tvs sp)
  Nothing -> pprPanic "SpecIndex: not an instance of the pattern" (ppr idx $$ ppr (sp_pat sp))

-- | Rewrite the uses of the old types in a type
mapT :: UniqFM TyCon Spec -> Type -> Type
mapT specs = go
  where
    go ty = case ty of
      TyConApp tc tys
        | Just sp <- lookupUFM specs tc -> mkTyConApp (sp_new sp) (map go (instPat sp tys))
        | otherwise                     -> TyConApp tc (map go tys)
      FunTy { ft_arg = a, ft_res = r } -> ty { ft_arg = go a, ft_res = go r }
      AppTy t1 t2  -> AppTy (go t1) (go t2)
      ForAllTy b t -> ForAllTy b (go t)
      CastTy t co  -> CastTy (go t) co
      _            -> ty

-- | Build the specialised type.  Lazy in 'specs' (field types may mention
-- other specialised types).
mkSpec :: UniqFM TyCon Spec -> UniqSupply -> TyCon -> [TyVar] -> [Type] -> Maybe Spec
mkSpec specs us tc tvs pat
  = do { ncs <- mapM mk_newcon (zip3 [1 ..] (tyConDataCons tc) (listSplitUniqSupply us2))
       ; let spec = Spec { sp_old = tc, sp_new = tycon, sp_tvs = tvs, sp_pat = pat
                         , sp_cons = listToUFM [ (nc_old nc, nc) | nc <- ncs ] }
             tycon = mkAlgTyCon tc_name (mkAnonTyConBinders tvs) liftedTypeKind
                                (map (const Nominal) tvs) Nothing []
                                (mkDataTyConRhs (map nc_dc ncs))
                                (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
       ; return spec }
  where
    (us1, us2) = splitUniqSupply us
    tc_name = setNameUnique (tyConName tc) (uniqFromSupply us1)

    -- The old constructor's indices are P(ts)
    mk_newcon (tag, dc, us_c) = do
      { idx <- mapM eq_rhs (zip (dataConUnivTyVars dc) (dataConOtherTheta dc))
      ; s   <- tcMatchTys pat idx
      ; let ts   = map (substTyVar s) tvs
            exs  = dataConExTyCoVars dc
            -- Existentials that appear alone, once, become parameters
            elim = [ (ex, j) | (j, TyVarTy ex) <- zip [0 ..] ts, ex `elem` exs
                             , length [ () | t <- ts, ex `elemVarSet` tyCoVarsOfType t ] == 1 ]
            exs' = filter (`notElem` map fst elim) exs
            esub = zipTvSubst (map fst elim) [ mkTyVarTy (tvs !! j) | (_, j) <- elim ]
            sty  = substTyUnchecked esub
            eqs  = [ j | j <- [0 .. length tvs - 1], j `notElem` map snd elim ]
            theta = [ mkNomEqPred (mkTyVarTy (tvs !! j)) (mapT specs (sty (ts !! j)))
                    | j <- eqs ]
            arg_tys = map (mapT specs . sty . scaledThing) (dataConOrigArgTys dc)
            us_c'   = uniqsFromSupply us_c
            dc_name = setNameUnique (dataConName dc) (head us_c')
            wk_name = mkExternalName (us_c' !! 1) (nameModule (dataConName dc))
                                     (mkDataConWorkerOcc (getOccName dc)) noSrcSpan
            no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
            dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                    (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
                    (map (const NotMarkedStrict) arg_tys)
                    [] tvs exs' emptyNameEnv
                    (mkTyVarBinders Specified (tvs ++ exs')) [] theta
                    (map unrestricted arg_tys)
                    (mkTyConApp (sp_new (lookup_self)) (mkTyVarTys tvs))
                    NoPromInfo (sp_new lookup_self) tag [] (mkDataConWorkId wk_name dc') NoDataConRep
      ; return (NewCon dc' elim eqs dc) }

    lookup_self = fromMaybe (pprPanic "SpecIndex: self" (ppr tc)) (lookupUFM specs tc)

    -- An equality  a ~# t  of the old constructor's context
    eq_rhs (tv, pred_ty) = case getEqPredTys_maybe pred_ty of
      Just (_, l, r) | l `eqType` mkTyVarTy tv -> Just r
      _                                        -> Nothing

------------------------------------------------------------------
--      The pass
------------------------------------------------------------------

-- | Specialise the indexed types to their uses.  Returns the new program and
-- the old and new type constructors, and a line per type for the dump.
specialiseIndexed :: UniqSupply -> [Indexed] -> CoreProgram
                  -> (CoreProgram, [(TyCon, TyCon)], [SDoc])
specialiseIndexed us ixs binds
  | isNullUFM specs = (binds, [], dump)
  | otherwise       = (map rw_bind binds, [ (sp_old sp, sp_new sp) | sp <- nonDetEltsUFM specs ], dump)
  where
    plans = [ (ix, mb)
            | (ix, u) <- zip ixs (listSplitUniqSupply us)
            , let tc = ix_tycon ix
                  (idxs, ok) = uses tc (ix_elim ix) binds
                  (u1, u2) = splitUniqSupply u
                  mb | not ok = Nothing
                     | otherwise = do { (tvs, pat) <- antiUnify u1 idxs
                                      ; if general tvs pat then Nothing else Just ()
                                      ; return (tvs, pat, u2) } ]
    general tvs pat = length tvs == length pat && all isTyVarTy pat

    specs :: UniqFM TyCon Spec
    specs = listToUFM [ (ix_tycon ix, sp)
                      | (ix, Just (tvs, pat, u)) <- plans
                      , Just sp <- [mkSpec specs u (ix_tycon ix) tvs pat] ]

    dump = [ ppr (ix_tycon ix) <> colon <+>
             (case lookupUFM specs (ix_tycon ix) of
                Just sp -> text "specialised to" <+> ppr (sp_new sp) <+> hsep (map ppr (sp_tvs sp))
                           <+> text "=" <+> ppr (sp_pat sp)
                Nothing -> text "not specialised")
           | (ix, _) <- plans ]

    elims = [ (e, sp) | Indexed { ix_tycon = tc, ix_elim = Just e } <- ixs
                      , Just sp <- [lookupUFM specs tc] ]

    ty = mapT specs

    rw_bind (NonRec b e) = NonRec (rw_bndr b) (rw_rhs b e)
    rw_bind (Rec prs)    = Rec [ (rw_bndr b, rw_rhs b e) | (b, e) <- prs ]

    -- Binders: new types; vanilla unfoldings may mention the old types.  The
    -- eliminator's type  forall as_old. T as_old -> ..  becomes
    -- forall as. T' as -> ..  (instantiated at the pattern)
    rw_bndr b
      | isId b, Just sp <- lookup b elims
      , (old_tvs, body) <- splitForAllTyCoVars (idType b)
      = zap (setIdType b (mkSpecForAllTys (sp_tvs sp)
                            (ty (substTyUnchecked (zipTvSubst old_tvs (sp_pat sp)) body))))
      | isId b    = zap (setIdType b (ty (idType b)))
      | otherwise = b
    zap b | isStableUnfolding (realIdUnfolding b) = b
          | otherwise                             = zapIdUnfolding b

    -- The eliminator:  /\ as_old. e   becomes   /\ as. e[P(as)/as_old]
    rw_rhs b e
      | Just sp <- lookup b elims
      , (old_tvs, body) <- collectTyBinders e
      , length old_tvs == length (sp_pat sp)
      = let s = extendTvSubstList (mkEmptySubst (mkInScopeSet (exprFreeVars e)))
                                  (zip old_tvs (sp_pat sp))
        in mkLams (sp_tvs sp) (rw (substExpr s body))
      | otherwise = rw e

    rw :: CoreExpr -> CoreExpr
    rw expr = case expr of
      Var v -> Var (if isLocalId v then rw_bndr v else v)
      Lit {} -> expr
      Type t -> Type (ty t)
      Coercion co -> Coercion (rw_co co)
      App {}
        | (Var v, args) <- collectArgs expr
        -> rw_app v args
      App f a -> App (rw f) (rw a)
      Lam b e -> Lam (rw_bndr b) (rw e)
      Let bind e -> Let (rw_bind bind) (rw e)
      Case e b t alts -> Case (rw e) (rw_bndr b) (ty t) (map (rw_alt (idType b)) alts)
      Cast e co -> Cast (rw e) (rw_co co)
      Tick t e -> Tick t (rw e)
      WebLam {} -> pprPanic "SpecIndex: web form (runs after erasure)" (ppr expr)
      WebApp {} -> pprPanic "SpecIndex: web form (runs after erasure)" (ppr expr)

    -- Coercions that mention the types are reflexive (see 'uses')
    rw_co co = case co of
      Refl t -> Refl (ty t)
      _      -> co

    rw_app v args
      -- A constructor of a specialised type
      | Just dc <- isDataConWorkId_maybe v
      , Just sp <- lookupUFM specs (dataConTyCon dc)
      , Just nc <- lookupUFM (sp_cons sp) dc
      = let n_univ = length (dataConUnivTyVars dc)
            n_ex   = length (dataConExTyCoVars dc)
            n_eq   = length (dataConOtherTheta dc)
            idx    = [ t | Type t <- take n_univ args ]
            ex_tys = [ t | Type t <- take n_ex (drop n_univ args) ]
            rest   = drop (n_univ + n_ex + n_eq) args
            ss     = instPat sp idx
            ex_kept = [ t | (ex, t) <- zip (dataConExTyCoVars dc) ex_tys
                          , ex `notElem` map fst (nc_elim nc) ]
            cos    = [ Coercion (mkNomReflCo (ty (ss !! j))) | j <- nc_eqs nc ]
        in mkApps (Var (dataConWorkId (nc_dc nc)))
                  (map (Type . ty) ss ++ map (Type . ty) ex_kept ++ cos ++ map rw rest)
      -- The eliminator: its type arguments are the old indices
      | Just sp <- lookup v elims
      , let n = length (sp_pat sp)
      , length args >= n
      , all isTypeArg (take n args)
      = mkApps (Var (rw_bndr v))
               (map (Type . ty) (instPat sp [ t | Type t <- take n args ]) ++ map rw (drop n args))
      | otherwise
      = mkApps (rw (Var v)) (map rw args)

    -- A case alternative on a constructor of a specialised type: bind the
    -- new existentials and coercions; rebuild the old coercions by lifting
    -- the pattern (Note [Specialising indexed types])
    rw_alt scrut_ty (Alt (DataAlt dc) bs rhs)
      | Just sp <- lookupUFM specs (dataConTyCon dc)
      , Just nc <- lookupUFM (sp_cons sp) dc
      , Just (_, idx) <- splitTyConApp_maybe scrut_ty
      = let ss     = instPat sp idx
            n_ex   = length (dataConExTyCoVars dc)
            n_eq   = length (dataConOtherTheta dc)
            (ex_bs, rest1)  = splitAt n_ex bs
            (co_bs, fld_bs) = splitAt n_eq rest1
            elim_bs = [ (b, j) | (b, ex) <- zip ex_bs (dataConExTyCoVars dc)
                               , Just j <- [lookup ex (nc_elim nc)] ]
            kept_bs = [ b | b <- ex_bs, b `notElem` map fst elim_bs ]
            -- Eliminated existentials are the scrutinee's indices
            tsub  = [ (b, ss !! j) | (b, j) <- elim_bs ]
            s0    = extendTvSubstList (mkEmptySubst (mkInScopeSet (exprFreeVars rhs `unionVarSet` mkVarSet bs)))
                                      tsub
            new_cos = [ mkCoVar (getName c) (mkNomEqPred (ss !! j) (eq_rhs_of sp nc j ss kept_bs))
                      | (j, c) <- zip (nc_eqs nc) [ co_bs !! j | j <- nc_eqs nc ] ]
            lift_cos = [ case lookup j (zip (nc_eqs nc) new_cos) of
                           Just c  -> mkCoVarCo c
                           Nothing -> mkNomReflCo (ss !! j)
                       | j <- [0 .. length (sp_tvs sp) - 1] ]
            -- The old coercion for index i:  P_i(ss) ~# P_i(ts)
            old_co i = liftCoSubstWith Nominal (sp_tvs sp) lift_cos (sp_pat sp !! i)
            s1 = foldl (\s (c, i) -> extendCvSubst s c (old_co i)) s0 (zip co_bs [0 ..])
        in Alt (DataAlt (nc_dc nc)) (kept_bs ++ new_cos ++ map rw_bndr fld_bs)
               (rw (substExpr s1 rhs))
    rw_alt _ (Alt con bs rhs) = Alt con (map rw_bndr bs) (rw rhs)

    -- The right-hand side of the new constructor's equality for parameter
    -- j, at the scrutinee's indices and the alternative's existentials
    eq_rhs_of sp nc j ss kept_bs
      = case lookup j (zip (nc_eqs nc) (dataConOtherTheta (nc_dc nc))) of
          Just pred_ty
            | Just (_, _, r) <- getEqPredTys_maybe pred_ty
            -> substTyUnchecked (zipTvSubst (sp_tvs sp ++ dataConExTyCoVars (nc_dc nc))
                                            (ss ++ mkTyVarTys kept_bs)) r
          _ -> pprPanic "SpecIndex: equality" (ppr (nc_dc nc))
