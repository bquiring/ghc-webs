-- | Copies of data types, for splitting data types by data flow.
--
-- See Note [Splitting data types] in GHC.WebCore.DataSplit.
module GHC.WebCore.DataCopy
  ( Copies
  , copyOriginal
  , eraseCopies
  , copyPairs
  , UnboxOpts(..)
  ) where

import GHC.Prelude

import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.TyCo.Rep

import GHC.Types.Unique.FM

import GHC.Data.Bag

-- | Options for unboxing (Note [Bounding unboxing] in GHC.WebCore.DataFlatten)
data UnboxOpts = UnboxOpts
  { uo_eager      :: Bool              -- ^ -fcore-webs-data-unbox-eager
  , uo_nested     :: Bool              -- ^ -fcore-webs-unbox-nested
  , uo_strict_elim :: Bool             -- ^ not -fcore-webs-no-strict-elim
  , uo_max_size   :: Int               -- ^ -fcore-webs-max-unbox-size
  , uo_rounds     :: Int               -- ^ -fcore-webs-unbox-rounds
  , uo_trust_demands :: Bool           -- ^ demands are fresh (the early run):
                                       --   Note [Unboxing in the late run]
  , uo_orig_sizes :: [(String, Int)] } -- ^ the split constructors' original sizes, by name

-- | Every copy, mapped to the type constructor it is a copy of
type Copies = UniqFM TyCon TyCon

-- | The type constructor a copy is a copy of (itself if it is not a copy)
copyOriginal :: Copies -> TyCon -> TyCon
copyOriginal cs tc = case lookupUFM cs tc of
  Just tc' -> tc'
  Nothing  -> tc

-- | Replace every copy by its original
eraseCopies :: Copies -> Type -> Type
eraseCopies cs
  | isNullUFM cs = id
  | otherwise    = go
  where
    go ty = case ty of
      TyConApp tc tys -> TyConApp (copyOriginal cs tc) (map go tys)
      FunTy { ft_arg = a, ft_res = r } -> ty { ft_arg = go a, ft_res = go r }
      AppTy t1 t2  -> AppTy (go t1) (go t2)
      ForAllTy b t -> ForAllTy b (go t)
      CastTy t co  -> CastTy (go t) co
      _            -> ty

-- | Given two types that are equal once their copies are erased, the pairs
-- of type constructors (copies, or a copy and its original) that must be
-- the same for them to be equal.  Pairs of identical type constructors are
-- not returned.  Like 'GHC.WebCore.Compare.collectWebPairs'.
copyPairs :: Copies -> Type -> Type -> Bag (TyCon, TyCon)
copyPairs cs ty1 ty2
  | isNullUFM cs = emptyBag
  | otherwise    = go ty1 ty2 emptyBag
  where
    go :: Type -> Type -> Bag (TyCon, TyCon) -> Bag (TyCon, TyCon)
    go t1 t2 acc
      | TyConApp tc1 ts1 <- t1
      , TyConApp tc2 ts2 <- t2
      , copyOriginal cs tc1 == copyOriginal cs tc2
      , length ts1 == length ts2
      = let acc' = gos ts1 ts2 acc
        in if tc1 == tc2 then acc' else (tc1, tc2) `consBag` acc'

      | Just t1' <- coreView t1 = go t1' t2 acc
      | Just t2' <- coreView t2 = go t1 t2' acc

    go (FunTy { ft_arg = a1, ft_res = r1 }) (FunTy { ft_arg = a2, ft_res = r2 }) acc
      = go r1 r2 (go a1 a2 acc)

    go (AppTy f1 a1) t2 acc
      | Just (f2, a2) <- splitAppTyNoView_maybe t2
      = go a1 a2 (go f1 f2 acc)
    go t1 (AppTy f2 a2) acc
      | Just (f1, a1) <- splitAppTyNoView_maybe t1
      = go a1 a2 (go f1 f2 acc)

    go (ForAllTy _ b1) (ForAllTy _ b2) acc = go b1 b2 acc
    go (CastTy t1 _) t2 acc = go t1 t2 acc
    go t1 (CastTy t2 _) acc = go t1 t2 acc

    go _ _ acc = acc

    gos (t1:ts1) (t2:ts2) acc = gos ts1 ts2 (go t1 t2 acc)
    gos _        _        acc = acc
