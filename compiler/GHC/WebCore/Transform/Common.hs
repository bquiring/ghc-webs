{-# LANGUAGE PatternSynonyms #-}

-- | Utilities shared by the web transformations (GHC.WebCore.Transform.*).
module GHC.WebCore.Transform.Common
  ( programOccurrences, exprOccurrences
  , complexCoWebs
  , fixBinderInfo, zapLocalUnfolding
  , pprWebVerdicts
  , mkWild
  , splitLeadingLams
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion ( coercionKind )
import GHC.Core.Type ( pattern ManyTy )
import GHC.Types.Var ( isCoVar, varType )
import GHC.Core.TyCo.Rep

import GHC.Data.FastString ( fsLit )

import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Id
import GHC.Types.Id.Info ( emptyRuleInfo )
import GHC.Types.Tickish
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Data.Pair
import GHC.Utils.Outputable

import GHC.WebCore.Traverse ( typeWebs )

import Data.List ( sortOn )

-- | All the variables that occur in the program (not binders), including in
-- breakpoint ticks
programOccurrences :: CoreProgram -> VarSet
programOccurrences binds = foldr occBind emptyVarSet binds

-- | All the variables that occur in an expression (not binders)
exprOccurrences :: CoreExpr -> VarSet
exprOccurrences e = occExpr e emptyVarSet

occBind :: CoreBind -> VarSet -> VarSet
occBind (NonRec _ e) acc = occExpr e acc
occBind (Rec prs)    acc = foldr (occExpr . snd) acc prs

occExpr :: CoreExpr -> VarSet -> VarSet
occExpr = go
  where
    go_bind = occBind

    go (Var v)          acc = extendVarSet acc v
    go (Lit {})         acc = acc
    go (App f a)        acc = go f (go a acc)
    go (WebApp _ f a)   acc = go f (go a acc)
    go (Lam _ e)        acc = go e acc
    go (WebLam _ _ e)   acc = go e acc
    go (Let bind body)  acc = go_bind bind (go body acc)
    go (Case e _ _ as)  acc = go e (foldr (\(Alt _ _ rhs) -> go rhs) acc as)
    go (Cast e _)       acc = go e acc
    go (Tick t e)       acc = go e (go_tick t acc)
    go (Type {})        acc = acc
    go (Coercion {})    acc = acc

    go_tick (Breakpoint { breakpointFVs = ids }) acc = extendVarSetList acc ids
    go_tick _ acc = acc

-- | The webs that appear inside coercions that cannot be rewritten
-- structurally.  The structural ones are Refl, GRefl, TyConAppCo, AppCo,
-- ForAllCo, FunCo, AxiomCo, SymCo, TransCo and SubCo; the others are SelCo, LRCo, KindCo, the argument of InstCo, UnivCo,
-- coercion variables and holes.  A transformation must leave these webs
-- alone.
complexCoWebs :: CoreProgram -> WebSet
complexCoWebs binds = foldr go_bind emptyUniqSet binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go e) acc prs

    go_bndr b acc
      | isCoVar b = typeWebs (varType b) `unionUniqSets` acc
      | otherwise = acc

    go (Var {})           acc = acc
    go (Lit {})           acc = acc
    go (App f a)          acc = go f (go a acc)
    go (WebApp _ f a)     acc = go f (go a acc)
    go (Lam b e)          acc = go_bndr b (go e acc)
    go (WebLam _ b e)     acc = go_bndr b (go e acc)
    go (Let bind body)    acc = go_bind bind (go body acc)
    go (Case e b _ alts)  acc = go e $ go_bndr b $
                                foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
    go (Cast e co)        acc = go e (go_co co acc)
    go (Tick _ e)         acc = go e acc
    go (Type t)           acc = go_ty t acc
    go (Coercion co)      acc = go_co co acc

    go_ty ty acc = case ty of
      FunTy { ft_arg = a, ft_res = r } -> go_ty a (go_ty r acc)
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t co    -> go_ty t (go_co co acc)
      CoercionTy co  -> go_co co acc
      _              -> acc

    go_co :: Coercion -> WebSet -> WebSet
    go_co co acc = case co of
      Refl t                 -> go_ty t acc
      GRefl _ t _            -> go_ty t acc
      TyConAppCo _ _ cos     -> foldr go_co acc cos
      AppCo c1 c2            -> go_co c1 (go_co c2 acc)
      ForAllCo { fco_body = c } -> go_co c acc
      FunCo { fco_arg = c1, fco_res = c2 } -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      SelCo _ c              -> kind_webs c (go_co c acc)
      LRCo _ c               -> kind_webs c (go_co c acc)
      KindCo c               -> kind_webs c (go_co c acc)
      InstCo c arg           -> kind_webs arg (go_co c (go_co arg acc))
      UnivCo {}              -> kind_webs co acc
      CoVarCo {}             -> kind_webs co acc
      HoleCo {}              -> kind_webs co acc

    kind_webs c acc = case coercionKind c of
      Pair l r -> typeWebs l `unionUniqSets` typeWebs r `unionUniqSets` acc

-- | Fix up the IdInfo of a binder whose type a transformation changed:
-- set the new type and arity (and join arity), and zap the demand and CPR
-- signatures, which describe the old calling convention.
fixBinderInfo :: Id
              -> Type                 -- ^ New type
              -> (Bool -> Int -> Int) -- ^ New arity, given whether it is a
                                      --   join arity, and the old arity
              -> Id
fixBinderInfo b new_ty new_arity
  = setIdCprSig (zapIdDmdSig (fix_join (setIdArity b' (new_arity False (idArity b))))) topCprSig
  where
    b' = setIdType b new_ty
    fix_join b'' = case idJoinPointHood b of
      JoinPoint ar -> asJoinId b'' (new_arity True ar)
      NotJoinPoint -> b''

-- | Zap the unfolding and rules of a local binder, unless it is one whose
-- unfolding may reach the interface.
-- See Note [Exposed webs] in GHC.WebCore.Sigs
zapLocalUnfolding :: VarSet -> Id -> Id
zapLocalUnfolding keep b
  | b `elemVarSet` keep = b
  | isLocalId b         = setIdSpecialisation (zapIdUnfolding b) emptyRuleInfo
  | otherwise           = b

-- | One line per web, without uniques: the verdict and the names of the
-- web's lambda binders.  Sorted, so tests can check it.
pprWebVerdicts :: Outputable v => [(v, [Id])] -> SDoc
pprWebVerdicts vs
  = vcat [ doc | (_, doc) <- sortOn fst [ (showSDocUnsafe (line v bs), line v bs) | (v, bs) <- vs ] ]
  where
    line v bs = ppr v <> colon <+> hsep (map (ppr . idName) bs)

-- | Split off the lambdas at the top of an expression.  Transformations put
-- the unpacking of an unboxed-tuple parameter under them: matching an unboxed
-- tuple costs nothing, and a join point's lambdas must stay together (its
-- join arity counts them).
splitLeadingLams :: CoreExpr -> (CoreExpr -> CoreExpr, CoreExpr)
splitLeadingLams (Lam b e)      = case splitLeadingLams e of
                                    (wrap, body) -> (Lam b . wrap, body)
splitLeadingLams (WebLam w b e) = case splitLeadingLams e of
                                    (wrap, body) -> (WebLam w b . wrap, body)
splitLeadingLams e              = (id, e)

-- | A fresh case binder
mkWild :: Type -> UniqSM Id
mkWild ty = do { u <- getUniqueM; return (mkSysLocal (fsLit "wild") u ManyTy ty) }
