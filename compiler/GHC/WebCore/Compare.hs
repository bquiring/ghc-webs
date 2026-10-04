-- | Collecting web constraints from type equalities.
--
-- See Note [Web Lint] in GHC.WebCore.Lint.
module GHC.WebCore.Compare
  ( collectWebPairs
  ) where

import GHC.Prelude

import GHC.Core.Type
import GHC.Core.TyCo.Rep

import GHC.Types.Web

import GHC.Data.Bag

-- | Given two types that are equal modulo webs (as checked by 'eqType'),
-- return the pairs of webs that must be the same for them to be equal.
--
-- A pair may involve 'placeholderWeb', when an arrow with a web meets an
-- arrow without one; see Note [Arrows without webs] in GHC.WebCore.Lint.
-- Pairs of identical webs are not returned.
collectWebPairs :: Type -> Type -> Bag (WebId, WebId)
collectWebPairs ty1 ty2 = go ty1 ty2 emptyBag
  where
    go :: Type -> Type -> Bag (WebId, WebId) -> Bag (WebId, WebId)
    go t1 t2 acc
      | TyConApp tc1 ts1 <- t1
      , TyConApp tc2 ts2 <- t2
      , tc1 == tc2
      , ts1 `equalLength` ts2
      = gos ts1 ts2 acc

      | Just t1' <- coreView t1 = go t1' t2 acc
      | Just t2' <- coreView t2 = go t1 t2' acc

    go (FunTy { ft_web = w1, ft_arg = a1, ft_res = r1 })
       (FunTy { ft_web = w2, ft_arg = a2, ft_res = r2 }) acc
      = let acc' = go r1 r2 (go a1 a2 acc)
        in if w1 == w2 then acc' else (w1, w2) `consBag` acc'

    go (AppTy f1 a1) t2 acc
      | Just (f2, a2) <- splitAppTyNoView_maybe t2
      = go a1 a2 (go f1 f2 acc)
    go t1 (AppTy f2 a2) acc
      | Just (f1, a1) <- splitAppTyNoView_maybe t1
      = go a1 a2 (go f1 f2 acc)

    go (ForAllTy _ b1) (ForAllTy _ b2) acc = go b1 b2 acc
    go (CastTy t1 _) t2 acc = go t1 t2 acc
    go t1 (CastTy t2 _) acc = go t1 t2 acc

    -- TyVarTy, LitTy, CoercionTy, and anything that 'eqType' accepted
    -- without lining up FunTys: no webs to compare
    go _ _ acc = acc

    gos (t1:ts1) (t2:ts2) acc = gos ts1 ts2 (go t1 t2 acc)
    gos _        _        acc = acc

    equalLength xs ys = length xs == length ys
