-- | Specialising split data types to the most general instance of their uses.
--
-- See Note [Specialising split types].
module GHC.WebCore.DataSpec
  ( specialiseSplit
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Multiplicity ( Scaled(..) )
import GHC.Core.TyCo.Compare ( eqTypes )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Unify ( tcMatchTys )

import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Core.Coercion ( coercionLKind, coercionRKind, coercionRole, mkSelCo, liftCoSubstWith, downgradeRole, tyConRoleListX )
import GHC.Types.Unique.Supply
import GHC.Types.Var ( mkTyVar )

import GHC.Unit.Module ( Module )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic, pprPanic )

import GHC.WebCore.Transform.SpecIndex ( antiUnify )


{- Note [Specialising split types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A split type (Note [Splitting data types] in GHC.WebCore.DataSplit) is used
by one class of occurrences only, which often all instantiate it the same
way: a local [(Int, Int)] gives a copy List_s3 that is only ever used at
(Int, Int).  Its fields then have type parameters where the uses have
concrete types, and nothing can be unboxed (Note [Flattening fields]).

So, for each split type T with parameters as:

  1. Collect the type arguments of every use of T: every T ts in a type (of
     a binder, a type argument, a case), and the type arguments of every
     occurrence of T's constructors.
  2. Anti-unify them (GHC.WebCore.Transform.SpecIndex.antiUnify) into a
     pattern P(bs), the least general type of which every use is an
     instance.  If P is just distinct variables, T stays.
  3. Make T' bs, whose constructors have T's fields at as := P(bs).  A
     recursive field T us must come out as T P(bs) (as it does for a regular
     type); otherwise T stays.
  4. Rewrite: T P(ss) is T' ss in every type and coercion, and a constructor
     occurrence K @P(ss) is K' @ss.

Coercions mention split types too (Note [Copies in coercions] in
GHC.WebCore.DataSplit): their kinds count as uses in step 1, and step 4
rewrites them (rw_co).

T is local and not exposed, so it has no other uses.
-}

specialiseSplit :: Module -> UniqSupply -> [TyCon] -> CoreProgram -> (CoreProgram, [TyCon], SDoc)
specialiseSplit this_mod us tcs binds
  | isNullUFM specs = (binds, tcs, dump)
  | otherwise       = (map rw_bind binds, map new_tc tcs, dump)
  where
    (us1, us2) = splitUniqSupply us
    cand_set = listToUFM [ (tc, ()) | tc <- tcs ]
    is_cand tc = tc `elemUFM` cand_set

    -- 1. Uses: argument lists per type, and whether every constructor
    -- occurrence is applied to all its type arguments
    uses :: UniqFM TyCon ([[Type]], Bool)
    uses = foldr go_bind emptyUFM binds

    add tc tys = addToUFM_C plus_use `flip` tc `flip` ([tys], True)
    plus_use (a, ok1) (b, ok2) = (a ++ b, ok1 && ok2)
    bad tc = addToUFM_C plus_use `flip` tc `flip` ([], False)

    go_bind bind acc = foldr (\(b, e) -> go_bndr b . go e) acc (flattenBinds [bind])

    go :: CoreExpr -> UniqFM TyCon ([[Type]], Bool) -> UniqFM TyCon ([[Type]], Bool)
    go expr acc = case expr of
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v, is_cand (dataConTyCon dc)
        -> let n = length (dataConUnivTyVars dc)
               tys = [ t | Type t <- take n args ]
               acc' = foldr go acc (drop n args)
           in if length tys == n then add (dataConTyCon dc) tys (foldr go_ty acc' tys)
              else bad (dataConTyCon dc) acc'
      Var v
        | Just dc <- isDataConWorkId_maybe v, is_cand (dataConTyCon dc)
        , not (null (dataConUnivTyVars dc))
        -> bad (dataConTyCon dc) acc
      App f a     -> go f (go a acc)
      Lam b e     -> go_bndr b (go e acc)
      Let bind e  -> go_bind bind (go e acc)
      Case e b t alts
        -> go e $ go_bndr b $ go_ty t $
           foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
      Cast e co   -> go e (go_co co acc)
      Tick _ e    -> go e acc
      Type t      -> go_ty t acc
      Coercion co -> go_co co acc
      _           -> acc

    -- A coercion's kinds are uses too (Note [Specialising split types])
    go_co co acc = go_ty (coercionLKind co) (go_ty (coercionRKind co) acc)

    go_bndr b acc | isId b    = go_ty (idType b) acc
                  | otherwise = acc

    go_ty ty acc = case ty of
      TyConApp tc tys
        | is_cand tc -> add tc tys (foldr go_ty acc tys)
        | otherwise  -> foldr go_ty acc tys
      FunTy { ft_arg = a, ft_res = r } -> go_ty a (go_ty r acc)
      AppTy t1 t2  -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t -> go_ty t acc
      CastTy t _   -> go_ty t acc
      _            -> acc

    -- 2. Patterns
    patterns :: [(TyCon, ([TyVar], [Type]))]
    spec_patterns = [ (tc, p)
                    | (tc, u) <- zip tcs (listSplitUniqSupply us1)
                    , rewritable tc
                    , Just (idxs, _) <- [lookupUFM uses tc]
                    , Just p@(tvs, pat) <- [antiUnify u idxs]
                    , not (length tvs == length pat && all isTyVarTy pat)
                    , recursive_ok tc p ]
    rewritable tc = case lookupUFM uses tc of
      Just (_, ok) -> ok
      Nothing      -> True     -- no uses at all

    -- A type whose fields mention a specialised type is rebuilt too, at its
    -- own parameters, or its constructors would still mention the old type.
    -- A type that cannot be rewritten blocks every specialisation it reaches.
    mentions tc = [ tc' | dc <- tyConDataCons tc, Scaled _ t <- dataConOrigArgTys dc
                        , tc' <- nonDetEltsUniqSet (tyConsOfType t), is_cand tc', tc' /= tc ]
    reach tc = go_r [] (mentions tc)
      where go_r seen [] = seen
            go_r seen (t : ts) | t `elem` seen = go_r seen ts
                               | otherwise     = go_r (t : seen) (mentions t ++ ts)
    blocked = concat [ reach tc | tc <- tcs, not (rewritable tc) ]
    seeds   = [ tc | (tc, _) <- spec_patterns, tc `notElem` blocked ]
    patterns = [ (tc, p) | (tc, p) <- spec_patterns, tc `elem` seeds ] ++
               [ (tc, (tvs, mkTyVarTys tvs))
               | tc <- tcs, tc `notElem` seeds, rewritable tc
               , any (`elem` seeds) (reach tc)
               , let tvs = tyConTyVars tc ]

    -- 3. A recursive field must be T P(bs) after the substitution
    recursive_ok tc (_, pat) = and
      [ args' `eqTypes` pat
      | dc <- tyConDataCons tc
      , let sub = zipTvSubst (dataConUnivTyVars dc) pat
      , Scaled _ t <- dataConOrigArgTys dc
      , args' <- self_args tc (substTy sub t) ]
    self_args tc ty = case ty of
      TyConApp tc' tys | tc' == tc -> tys : concatMap (self_args tc) tys
                       | otherwise -> concatMap (self_args tc) tys
      FunTy { ft_arg = a, ft_res = r } -> self_args tc a ++ self_args tc r
      AppTy t1 t2  -> self_args tc t1 ++ self_args tc t2
      ForAllTy _ t -> self_args tc t
      CastTy t _   -> self_args tc t
      _            -> []

    specs :: UniqFM TyCon (TyCon, [TyVar], [Type], UniqFM DataCon DataCon)
    specs = listToUFM [ (tc, build u tc tvs pat)
                      | ((tc, (tvs, pat)), u) <- zip patterns (listSplitUniqSupply us2) ]

    build u tc tvs0 pat = (tycon, tvs, pat', listToUFM (zip (tyConDataCons tc) dcs))
      where
        (u1, u23) = splitUniqSupply u
        (u2, u3)  = splitUniqSupply u23
        -- Fresh, named parameters (the pattern's are system names)
        tvs = [ mkTyVar (mkSystemName v (mkTyVarOccFS (occNameFS (mkTyVarOcc ("t" ++ show i)))))
                        (tyVarKind tv)
              | (i, tv, v) <- zip3 [1 :: Int ..] tvs0 (uniqsFromSupply u3) ]
        pat' = substTys (zipTvSubst tvs0 (mkTyVarTys tvs)) pat
        tc_name = setNameUnique (tyConName tc) (uniqFromSupply u1)
        tycon = mkAlgTyCon tc_name (mkAnonTyConBinders tvs) (tyConResKind tc)
                           (map (const Nominal) tvs) Nothing [] (mkDataTyConRhs dcs)
                           (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
        self ty = case ty of
          TyConApp tc' tys
            | tc' == tc -> TyConApp tycon (map self (inst tvs pat' tys))
            | otherwise -> TyConApp tc' (map self tys)
          FunTy { ft_arg = a, ft_res = r } -> ty { ft_arg = self a, ft_res = self r }
          AppTy t1 t2  -> AppTy (self t1) (self t2)
          ForAllTy b t -> ForAllTy b (self t)
          CastTy t co  -> CastTy (self t) co
          _            -> ty
        dcs = [ mk_con dc uc | (dc, uc) <- zip (tyConDataCons tc) (listSplitUniqSupply u2) ]
        mk_con dc uc = dc'
          where
            (u_dc, u_wk) = case uniqsFromSupply uc of
                             (a : b : _) -> (a, b)
                             _           -> panic "specialiseSplit"
            dc_name = setNameUnique (dataConName dc) u_dc
            wk_name = mkExternalName u_wk this_mod (mkDataConWorkerOcc (getOccName dc)) noSrcSpan
            sub = zipTvSubst (dataConUnivTyVars dc) pat'
            -- Other specialised types in the fields are rewritten too (lazily:
            -- 'ty' looks at all the specialisations)
            arg_tys = [ Scaled m (ty (self (substTy sub t))) | Scaled m t <- dataConOrigArgTys dc ]
            no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
            dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                    (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
                    (map (const NotMarkedStrict) arg_tys)
                    [] tvs [] emptyNameEnv (mkTyVarBinders Specified tvs) [] []
                    arg_tys (mkTyConApp tycon (mkTyVarTys tvs))
                    NoPromInfo tycon (dataConTag dc) [] (mkDataConWorkId wk_name dc') NoDataConRep

    new_tc tc = maybe tc (\(t, _, _, _) -> t) (lookupUFM specs tc)

    -- The new type arguments for a use of T at tys
    inst :: [TyVar] -> [Type] -> [Type] -> [Type]
    inst tvs pat tys = case tcMatchTys pat tys of
      Just s  -> map (substTyVar s) tvs
      Nothing -> pprPanic "specialiseSplit: not an instance" (ppr tys $$ ppr pat)

    -- 4. Rewrite
    ty :: Type -> Type
    ty t = case t of
      TyConApp tc tys
        | Just (tc', tvs, pat, _) <- lookupUFM specs tc -> TyConApp tc' (map ty (inst tvs pat tys))
        | otherwise -> TyConApp tc (map ty tys)
      FunTy { ft_arg = a, ft_res = r } -> t { ft_arg = ty a, ft_res = ty r }
      AppTy t1 t2  -> AppTy (ty t1) (ty t2)
      ForAllTy b t' -> ForAllTy b (ty t')
      CastTy t' co -> CastTy (ty t') co
      _            -> t

    rw_bind (NonRec b e) = NonRec (rw_id b) (rw e)
    rw_bind (Rec prs)    = Rec [ (rw_id b, rw e) | (b, e) <- prs ]
    rw_id b | isId b    = setIdType b (ty (idType b))
            | otherwise = b

    rw :: CoreExpr -> CoreExpr
    rw expr = case expr of
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v
        , Just (_, tvs, pat, cons) <- lookupUFM specs (dataConTyCon dc)
        , Just dc' <- lookupUFM cons dc
        -> let n = length (dataConUnivTyVars dc)
               tys = [ t | Type t <- take n args ]
           in mkApps (Var (dataConWorkId dc'))
                     (map (Type . ty) (inst tvs pat tys) ++ map rw (drop n args))
      Var v       -> Var (rw_id v)
      Lit {}      -> expr
      Type t      -> Type (ty t)
      Coercion co -> Coercion (rw_co co)
      App f a     -> App (rw f) (rw a)
      Lam b e     -> Lam (rw_id b) (rw e)
      Let bind e  -> Let (rw_bind bind) (rw e)
      Case e b t alts
        -> Case (rw e) (rw_id b) (ty t)
                [ Alt (rw_con con) (map rw_id bs) (rw rhs) | Alt con bs rhs <- alts ]
      Cast e co   -> Cast (rw e) (rw_co co)
      Tick t e    -> Tick t (rw e)
      _           -> expr

    -- Coercions: T P(ss) is T' ss on both sides.  A TyConAppCo of T gives each
    -- pattern variable the coercion at its first position in the pattern,
    -- selected out of the argument coercion (mkSelCo simplifies the Refl and
    -- TyConAppCo cases); a SelCo out of T lifts the pattern over the
    -- variables' coercions (as in GHC.WebCore.Transform.SpecIndex).
    rw_co :: Coercion -> Coercion
    rw_co co = case co of
      Refl t        -> Refl (ty t)
      GRefl r t m   -> GRefl r (ty t) m
      TyConAppCo r tc cos
        | Just (tc', tvs, pat, _) <- lookupUFM specs tc
        -> let cos' = map rw_co cos
           in TyConAppCo r tc' [ var_co r tc pat cos' tv | tv <- tvs ]
        | otherwise -> TyConAppCo r tc (map rw_co cos)
      SelCo (SelTyCon i r) c
        | Just (tc, _) <- splitTyConApp_maybe (coercionLKind c)
        , Just (tc', tvs, pat, _) <- lookupUFM specs tc
        , Just p_i <- index i pat
        -> let c' = rw_co c
               roles = tyConRoleListX (coercionRole c') tc'
               tv_cos = [ mkSelCo (SelTyCon j rj) c' | (j, rj) <- zip [0 ..] roles, j < length tvs ]
           in downgrade r (liftCoSubstWith (coercionRole c') tvs tv_cos p_i)
      AppCo c1 c2   -> AppCo (rw_co c1) (rw_co c2)
      ForAllCo { fco_body = b } -> co { fco_body = rw_co b }
      FunCo { fco_arg = a, fco_res = r } -> co { fco_arg = rw_co a, fco_res = rw_co r }
      AxiomCo ax cos -> AxiomCo ax (map rw_co cos)
      UnivCo { uco_lty = l, uco_rty = r, uco_deps = ds }
                    -> co { uco_lty = ty l, uco_rty = ty r, uco_deps = map rw_co ds }
      SymCo c       -> SymCo (rw_co c)
      TransCo c1 c2 -> TransCo (rw_co c1) (rw_co c2)
      SelCo cs c    -> SelCo cs (rw_co c)
      LRCo lr c     -> LRCo lr (rw_co c)
      InstCo c a    -> InstCo (rw_co c) (rw_co a)
      SubCo c       -> SubCo (rw_co c)
      _             -> co

    -- The coercion for pattern variable tv: at its first position in the
    -- pattern, selected out of that argument's coercion
    var_co r tc pat cos' tv
      = case [ sel_path (tyConRoleListX r tc !! i) (cos' !! i) path
             | (i, p) <- zip [0 ..] pat, Just path <- [path_to tv p] ] of
          (c : _) -> c
          []      -> pprPanic "specialiseSplit: pattern variable not in pattern" (ppr tv)
    -- The path to a variable in a pattern type: argument positions
    path_to tv p = case p of
      TyVarTy v | v == tv -> Just []
      TyConApp ptc ts ->
        case [ (j, rest) | (j, t) <- zip [0 ..] ts, Just rest <- [path_to tv t] ] of
          ((j, rest) : _) -> Just ((ptc, j) : rest)
          []              -> Nothing
      _ -> Nothing
    sel_path _ c [] = c
    sel_path r c ((ptc, j) : rest)
      = let rj = tyConRoleListX r ptc !! j
        in sel_path rj (mkSelCo (SelTyCon j rj) c) rest
    downgrade r c | coercionRole c == r = c
                  | otherwise           = downgradeRole r (coercionRole c) c
    index i xs = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

    rw_con (DataAlt dc)
      | Just (_, _, _, cons) <- lookupUFM specs (dataConTyCon dc)
      , Just dc' <- lookupUFM cons dc = DataAlt dc'
    rw_con con = con

    dump = vcat [ ppr tc <> colon <+> text "specialised to" <+> ppr tc' <+> hsep (map ppr tvs)
                  <+> text "=" <+> ppr pat
                | tc <- tcs, Just (tc', tvs, pat, _) <- [lookupUFM specs tc] ]
