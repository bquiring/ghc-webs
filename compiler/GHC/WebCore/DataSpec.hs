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
  4. Rewrite: T P(ss) is T' ss in every type, and a constructor occurrence
     K @P(ss) is K' @ss.

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
      Cast e _    -> go e acc
      Tick _ e    -> go e acc
      Type t      -> go_ty t acc
      _           -> acc

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
    patterns = [ (tc, p)
               | (tc, u) <- zip tcs (listSplitUniqSupply us1)
               , Just (idxs, True) <- [lookupUFM uses tc]
               , Just p@(tvs, pat) <- [antiUnify u idxs]
               , not (length tvs == length pat && all isTyVarTy pat)
               , recursive_ok tc p ]

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
            | tc' == tc -> TyConApp tycon (mkTyVarTys tvs)   -- recursive_ok: tys = pat'
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
      Coercion {} -> expr
      App f a     -> App (rw f) (rw a)
      Lam b e     -> Lam (rw_id b) (rw e)
      Let bind e  -> Let (rw_bind bind) (rw e)
      Case e b t alts
        -> Case (rw e) (rw_id b) (ty t)
                [ Alt (rw_con con) (map rw_id bs) (rw rhs) | Alt con bs rhs <- alts ]
      Cast e co   -> Cast (rw e) co
      Tick t e    -> Tick t (rw e)
      _           -> expr

    rw_con (DataAlt dc)
      | Just (_, _, _, cons) <- lookupUFM specs (dataConTyCon dc)
      , Just dc' <- lookupUFM cons dc = DataAlt dc'
    rw_con con = con

    dump = vcat [ ppr tc <> colon <+> text "specialised to" <+> ppr tc' <+> hsep (map ppr tvs)
                  <+> text "=" <+> ppr pat
                | tc <- tcs, Just (tc', tvs, pat, _) <- [lookupUFM specs tc] ]
