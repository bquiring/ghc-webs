-- | Unboxing the fields of split data types: a product field that every
-- construction fills with a value, and every match only takes apart, holds
-- the product's components instead.
--
-- See Note [Flattening fields].
module GHC.WebCore.DataFlatten
  ( flattenFields
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Make ( mkCoreConApps )
import GHC.Core.Multiplicity ( Scaled(..), scaledThing )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprIsHNF, exprType, mkSingleAltCase )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env

import GHC.Unit.Module ( Module )
import GHC.Utils.Outputable
import GHC.Utils.Panic ( panic )

import GHC.WebCore.DataSplit ( mapTyCons )
import GHC.WebCore.Transform.ArityRaise ( productCon, onlyScrutinised, replaceCases )

import Control.Monad ( forM, foldM )
import Data.Functor.Identity ( runIdentity )
import Data.Maybe ( isNothing, fromMaybe )

{- Note [Flattening fields]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-data-unbox, after splitting (Note [Splitting data types] in
GHC.WebCore.DataSplit), a field of a split type S's constructor K whose type
is a product P (one constructor P, no existentials, no wrapper: Int, a pair,
...) holds P's components instead, when

  * every occurrence of K's worker is saturated, and passes a value (exprIsHNF:
    a constructor application, or a variable bound to one) in the field; and
  * every case alternative on K uses the field only as the scrutinee of
    cases (onlyScrutinised): nothing needs the boxed value.

Then
    K .. e ..                      ==>  case e of P ys -> K' .. ys ..
    case x of K .. f .. -> rhs     ==>  case x of K' .. ys .. -> rhs[ys/case f of P zs]

Taking e apart evaluates nothing (it is a value), and no match rebuilds the
box, so nothing is evaluated or allocated that was not before; each K value
holds one box fewer.  This is the field version of constructed-argument
raising (Note [Arity raising] in GHC.WebCore.Transform.ArityRaise).  An Int
field becomes an Int# field; a pair field becomes two fields.

S is local and not exposed, so no other code builds or matches it.  Fields
whose type mentions S itself (recursive fields) are not flattened.
-}

-- | What happens to a field
data Field = Keep | Flatten DataCon [Type]   -- ^ P's constructor and type arguments

-- | Per split type: its constructors' field plans (by tag), if any is flattened
type Plans = UniqFM TyCon [(DataCon, [Field])]

flattenFields :: Module -> UniqSupply -> [TyCon] -> CoreProgram
              -> (CoreProgram, [TyCon], SDoc)
flattenFields this_mod us tcs binds
  | isNullUFM plans = (binds, tcs, dump)
  | otherwise       = (initUs_ us2 (mapM rw_bind binds), map new_tc tcs, dump)
  where
    (us1, us2) = splitUniqSupply us
    cands = mkUniqSet tcs

    -- Candidate fields: products, not recursive
    candidate :: DataCon -> Int -> Bool
    candidate dc i = case drop i (dataConOrigArgTys dc) of
      (Scaled _ t : _)
        | Just (ptc, _, pdc) <- productCon (coreFullView t)
        , not (ptc `elementOfUniqSet` cands)
        , isNothing (dataConWrapId_maybe pdc)
        , all (typeHasFixedRuntimeRep . scaledThing) (dataConOrigArgTys pdc)
        -> True
      _ -> False

    -- Bad (constructor, field) pairs, and constructors with a bad occurrence
    bad :: UniqFM DataCon [Int]
    bad = foldr go_bind emptyUFM binds

    is_cand_con dc = dataConTyCon dc `elementOfUniqSet` cands
    all_fields dc = [0 .. dataConRepArity dc - 1]
    mark dc is m = addToUFM_C (++) m dc is

    go_bind bind acc = foldr (\(_, e) -> go e) acc (flattenBinds [bind])

    go :: CoreExpr -> UniqFM DataCon [Int] -> UniqFM DataCon [Int]
    go expr acc = case expr of
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        -> let vals = [ a | a <- args, not (isTypeArg a) ]
               acc' = foldr go acc args
           in if length vals == dataConRepArity dc
              then mark dc [ i | (i, a) <- zip [0 ..] vals, not (exprIsHNF a) ] acc'
              else mark dc (all_fields dc) acc'
      Var v
        | Just dc <- isDataConWorkId_maybe v, is_cand_con dc
        , dataConRepArity dc > 0
        -> mark dc (all_fields dc) acc
      App f a     -> go f (go a acc)
      Lam _ e     -> go e acc
      Let bind e  -> go_bind bind (go e acc)
      Case e _ _ alts
        -> go e $ foldr (\(Alt con bs rhs) a -> go rhs (alt con bs rhs a)) acc alts
      Cast e _    -> go e acc
      Tick _ e    -> go e acc
      _           -> acc

    alt (DataAlt dc) bs rhs acc
      | is_cand_con dc
      = mark dc [ i | (i, b) <- zip [0 ..] (filter isId bs), not (onlyScrutinised b rhs) ] acc
    alt _ _ _ acc = acc

    plans :: Plans
    plans = listToUFM
      [ (tc, cons)
      | tc <- tcs
      , let cons = [ (dc, [ plan dc i | i <- all_fields dc ]) | dc <- tyConDataCons tc ]
      , any (\(_, fs) -> any is_flat fs) cons ]
    plan dc i
      | candidate dc i, i `notElem` lookupWithDefaultUFM bad [] dc
      , Scaled _ t : _ <- drop i (dataConOrigArgTys dc)
      , Just (_, args, pdc) <- productCon (coreFullView t)
      = Flatten pdc args
      | otherwise = Keep
    is_flat (Flatten {}) = True
    is_flat Keep         = False

    -- The new types: S' with the flattened constructors (same tags)
    news :: UniqFM TyCon (TyCon, UniqFM DataCon DataCon)
    news = listToUFM [ (tc, rebuild u tc cons) | (tc, u) <- zip tcs (listSplitUniqSupply us1)
                                               , Just cons <- [lookupUFM plans tc] ]
    new_tc tc = maybe tc fst (lookupUFM news tc)
    new_con dc = lookupUFM news (dataConTyCon dc) >>= \(_, m) -> lookupUFM m dc
    field_plan dc = lookupUFM plans (dataConTyCon dc) >>= lookup dc

    rebuild u tc cons = (tycon, listToUFM (zip (map fst cons) dcs'))
      where
        (u1, u2) = splitUniqSupply u
        tc_name = setNameUnique (tyConName tc) (uniqFromSupply u1)
        tycon = mkAlgTyCon tc_name (tyConBinders tc) (tyConResKind tc) (tyConRoles tc)
                           Nothing [] (mkDataTyConRhs dcs')
                           (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
        self = runIdentity . mapTyCons (== tc) (\_ -> return tycon)
        dcs' = [ mk_con dc fs uc | ((dc, fs), uc) <- zip cons (listSplitUniqSupply u2) ]
        mk_con dc fs uc = dc'
          where
            (u_dc, u_wk) = case uniqsFromSupply uc of
                             (a : b : _) -> (a, b)
                             _           -> panic "flattenFields"
            dc_name = setNameUnique (dataConName dc) u_dc
            wk_name = mkExternalName u_wk this_mod (mkDataConWorkerOcc (getOccName dc)) noSrcSpan
            arg_tys = concat [ case f of
                                 Keep           -> [Scaled m (self t)]
                                 Flatten pdc as -> map (\(Scaled m' t') -> Scaled m' (self t'))
                                                       (dataConInstArgTys pdc as)
                             | (Scaled m t, f) <- zip (dataConOrigArgTys dc) fs ]
            no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
            univs   = dataConUnivTyVars dc
            dc' = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
                    (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
                    (map (const NotMarkedStrict) arg_tys)
                    [] univs [] emptyNameEnv (dataConUserTyVarBinders dc) [] []
                    arg_tys (mkTyConApp tycon (mkTyVarTys univs))
                    NoPromInfo tycon (dataConTag dc) [] (mkDataConWorkId wk_name dc') NoDataConRep

    ty :: Type -> Type
    ty = runIdentity . mapTyCons (`elemUFM` news) (return . new_tc)

    ---------------------------------------------------------------
    rw_bind (NonRec b e) = NonRec (rw_id b) <$> rw e
    rw_bind (Rec prs)    = Rec <$> forM prs (\(b, e) -> (,) (rw_id b) <$> rw e)

    rw_id b | isId b    = setIdType b (ty (idType b))
            | otherwise = b

    rw :: CoreExpr -> UniqSM CoreExpr
    rw expr = case expr of
      Var v
        | Just dc <- isDataConWorkId_maybe v, Just dc' <- new_con dc -> return (Var (dataConWorkId dc'))
        | otherwise -> return (Var (rw_id v))
      Lit {}       -> return expr
      Type t       -> return (Type (ty t))
      Coercion {}  -> return expr
      App {}
        | (Var v, args) <- collectArgs expr
        , Just dc <- isDataConWorkId_maybe v
        , Just dc' <- new_con dc
        , Just fs <- field_plan dc
        -> do { args' <- mapM rw args
              ; let (tys, vals) = span isTypeArg args'
                    ty_args = [ t | Type t <- tys ]
              ; build dc' ty_args fs vals }
      App f a      -> App <$> rw f <*> rw a
      Lam b e      -> Lam (rw_id b) <$> rw e
      Let bind e   -> Let <$> rw_bind bind <*> rw e
      Case e b t alts
        -> do { e' <- rw e
              ; let b' = rw_id b
              ; alts' <- forM alts (rw_alt (idType b'))
              ; return (Case e' b' (ty t) alts') }
      Cast e co    -> (`Cast` co) <$> rw e
      Tick t e     -> Tick t <$> rw e
      _            -> return expr

    -- K' tys es, taking apart the flattened fields' values
    build dc' ty_args fs vals
      = do { (wrap, vals') <- foldM step (id, []) (zip fs vals)
           ; return (wrap (mkCoreConApps dc' (map Type ty_args ++ reverse vals'))) }
      where
        sub = zipTvSubst (dataConUnivTyVars dc') ty_args
        step (wrap, acc) (Keep, v) = return (wrap, v : acc)
        step (wrap, acc) (Flatten pdc as, v)
          = do { let comps = map scaledThing (dataConInstArgTys pdc (substTys sub as))
               ; ys <- mapM (fresh "y") comps
               ; b  <- fresh "p" (mkTyConApp (dataConTyCon pdc) (substTys sub as))
               ; let wrap' e = wrap (mkSingleAltCase v b (DataAlt pdc) ys e)
               ; return (wrap', reverse (map Var ys) ++ acc) }

    -- An alternative: bind the components, and replace the cases on the field
    rw_alt scrut_ty (Alt (DataAlt dc) bs rhs)
      | Just dc' <- new_con dc, Just fs <- field_plan dc
      = do { rhs' <- rw rhs
           ; let ty_args = fromMaybe [] (tyConAppArgs_maybe scrut_ty)
                 sub = zipTvSubst (dataConUnivTyVars dc') ty_args
           ; (bs', body) <- foldM (field sub) ([], rhs') (zip fs (map rw_id bs))
           ; return (Alt (DataAlt dc') (reverse bs') body) }
    rw_alt _ (Alt con bs rhs) = Alt con (map rw_id bs) <$> rw rhs

    field _ (acc, body) (Keep, b) = return (b : acc, body)
    field sub (acc, body) (Flatten pdc as, b)
      = do { let comps = map scaledThing (dataConInstArgTys pdc (substTys sub as))
           ; ys <- mapM (fresh "y") comps
           ; let body1 = replaceCases b pdc ys body
                 body2 | b `elemVarSet'` body1
                       = Let (NonRec b (mkCoreConApps pdc (map Type (substTys sub as) ++ map Var ys))) body1
                       | otherwise = body1
           ; return (reverse ys ++ acc, body2) }

    elemVarSet' b e = b `elementOfUniqSet` exprFreeIdsSet e
    exprFreeIdsSet e = mkUniqSet (freeIds e)
    freeIds e = case e of
      Var v -> [v]
      App f a -> freeIds f ++ freeIds a
      Lam _ x -> freeIds x
      Let bind x -> concatMap (freeIds . snd) (flattenBinds [bind]) ++ freeIds x
      Case s _ _ as -> freeIds s ++ concat [ freeIds r | Alt _ _ r <- as ]
      Cast x _ -> freeIds x
      Tick _ x -> freeIds x
      _ -> []

    fresh fs t = do { u <- getUniqueM; return (mkSysLocal (fsLit fs) u ManyTy t) }

    dump = vcat [ ppr tc <> colon <+> hsep (punctuate comma
                    [ ppr dc <+> text "field" <+> int i <+> text "unboxed"
                    | (dc, fs) <- cons, (i, Flatten {}) <- zip [0 :: Int ..] fs ])
                | (tc, cons) <- [ (tc, c) | tc <- tcs, Just c <- [lookupUFM plans tc] ] ]
