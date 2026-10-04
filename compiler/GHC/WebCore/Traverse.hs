-- | Generic traversals over the webs of a Core program.
--
-- Used by renaming (GHC.WebCore.Rename) and erasure (GHC.WebCore.Erase).
-- See Note [Webs] in GHC.Types.Web.
module GHC.WebCore.Traverse
  ( WebMapper(..)
  , mapWebsProgram, mapWebsExpr, mapWebsType, mapWebsCo, mapWebsId
  , stripWebForms
  , typeWebs, programWebs
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion.Axiom
import GHC.Core.TyCo.Rep

import GHC.Types.Id
import GHC.Types.Tickish
import GHC.Types.Unique.Set
import GHC.Types.Web

-- | What to do to the webs of a program.
data WebMapper = WebMapper
  { wm_web       :: WebId -> WebId
      -- ^ Applied to every web: on arrows, 'FunCo's, 'WebLam's and 'WebApp's
  , wm_axiom     :: CoAxiomRule -> CoAxiomRule
      -- ^ Applied to the axiom of every 'AxiomCo'
  , wm_global_id :: Id -> Maybe Id
      -- ^ Replacement for a global Id occurrence.  If 'Nothing', its type is mapped.
  , wm_erase     :: Bool
      -- ^ Turn 'WebLam' into 'Lam' and 'WebApp' into 'App'
  }

mapWebsProgram :: WebMapper -> CoreProgram -> CoreProgram
mapWebsProgram wm = map (mapWebsBind wm)

mapWebsBind :: WebMapper -> CoreBind -> CoreBind
mapWebsBind wm (NonRec b e) = NonRec (mapWebsBndr wm b) (mapWebsExpr wm e)
mapWebsBind wm (Rec prs)    = Rec [ (mapWebsBndr wm b, mapWebsExpr wm e) | (b, e) <- prs ]

mapWebsExpr :: WebMapper -> CoreExpr -> CoreExpr
mapWebsExpr wm = go
  where
    go (Var v)            = Var (mapWebsOcc wm v)
    go (Lit l)            = Lit l
    go (App f a)          = App (go f) (go a)
    go (Lam b e)          = Lam (mapWebsBndr wm b) (go e)
    go (WebApp w f a)
      | wm_erase wm       = App (go f) (go a)
      | otherwise         = WebApp (wm_web wm w) (go f) (go a)
    go (WebLam w b e)
      | wm_erase wm       = Lam (mapWebsBndr wm b) (go e)
      | otherwise         = WebLam (wm_web wm w) (mapWebsBndr wm b) (go e)
    go (Let bind body)    = Let (mapWebsBind wm bind) (go body)
    go (Case e b ty alts) = Case (go e) (mapWebsBndr wm b) (mapWebsType wm ty)
                                 [ Alt con (map (mapWebsBndr wm) bs) (go rhs)
                                 | Alt con bs rhs <- alts ]
    go (Cast e co)        = Cast (go e) (mapWebsCo wm co)
    go (Tick t e)         = Tick (mapWebsTick wm t) (go e)
    go (Type ty)          = Type (mapWebsType wm ty)
    go (Coercion co)      = Coercion (mapWebsCo wm co)

mapWebsTick :: WebMapper -> CoreTickish -> CoreTickish
mapWebsTick wm t@(Breakpoint { breakpointFVs = ids })
  = t { breakpointFVs = map (mapWebsOcc wm) ids }
mapWebsTick _ t = t

-- | Map the webs in the type of a binder.  Type variables are left alone:
-- webs never appear in kinds.
mapWebsBndr :: WebMapper -> Var -> Var
mapWebsBndr wm v
  | isId v    = mapWebsId wm v
  | otherwise = v

-- | Map an occurrence of a variable
mapWebsOcc :: WebMapper -> Var -> Var
mapWebsOcc wm v
  | isId v, isGlobalId v, Just v' <- wm_global_id wm v = v'
  | otherwise = mapWebsBndr wm v

mapWebsId :: WebMapper -> Id -> Id
mapWebsId wm v = setIdType v (mapWebsType wm (idType v))

mapWebsType :: WebMapper -> Type -> Type
mapWebsType wm = go
  where
    go ty@(TyVarTy {})          = ty
    go ty@(LitTy {})            = ty
    go (AppTy t1 t2)            = AppTy (go t1) (go t2)
    go (TyConApp tc tys)        = TyConApp tc (map go tys)
    go (ForAllTy bndr ty)       = ForAllTy bndr (go ty)
    go ty@(FunTy { ft_web = w, ft_arg = arg, ft_res = res })
                                = ty { ft_web = wm_web wm w, ft_arg = go arg, ft_res = go res }
    go (CastTy ty co)           = CastTy (go ty) (mapWebsCo wm co)
    go (CoercionTy co)          = CoercionTy (mapWebsCo wm co)

mapWebsCo :: WebMapper -> Coercion -> Coercion
mapWebsCo wm = go
  where
    goTy = mapWebsType wm

    go (Refl ty)                = Refl (goTy ty)
    go (GRefl r ty mco)         = GRefl r (goTy ty) mco
    go (TyConAppCo r tc cos)    = TyConAppCo r tc (map go cos)
    go (AppCo co1 co2)          = AppCo (go co1) (go co2)
    go co@(ForAllCo { fco_body = body })
                                = co { fco_body = go body }
    go co@(FunCo { fco_web = w, fco_arg = arg, fco_res = res })
                                = co { fco_web = wm_web wm w, fco_arg = go arg, fco_res = go res }
    go (CoVarCo cv)             = CoVarCo (mapWebsBndr wm cv)
    go (AxiomCo ax cos)         = AxiomCo (wm_axiom wm ax) (map go cos)
    go co@(UnivCo { uco_lty = lty, uco_rty = rty, uco_deps = deps })
                                = co { uco_lty = goTy lty, uco_rty = goTy rty
                                     , uco_deps = map go deps }
    go (SymCo co)               = SymCo (go co)
    go (TransCo co1 co2)        = TransCo (go co1) (go co2)
    go (SelCo sel co)           = SelCo sel (go co)
    go (LRCo lr co)             = LRCo lr (go co)
    go (InstCo co arg)          = InstCo (go co) (go arg)
    go (KindCo co)              = KindCo (go co)
    go (SubCo co)               = SubCo (go co)
    go co@(HoleCo {})           = co

-- | Turn 'WebLam' into 'Lam' and 'WebApp' into 'App', leaving types alone.
-- Used to run ordinary Core utilities (which do not handle the web forms)
-- on web-annotated expressions.
stripWebForms :: CoreExpr -> CoreExpr
stripWebForms = go
  where
    go e@(Var {})         = e
    go e@(Lit {})         = e
    go (App f a)          = App (go f) (go a)
    go (Lam b e)          = Lam b (go e)
    go (WebApp _ f a)     = App (go f) (go a)
    go (WebLam _ b e)     = Lam b (go e)
    go (Let bind body)    = Let (go_bind bind) (go body)
    go (Case e b ty alts) = Case (go e) b ty [ Alt con bs (go rhs) | Alt con bs rhs <- alts ]
    go (Cast e co)        = Cast (go e) co
    go (Tick t e)         = Tick t (go e)
    go e@(Type {})        = e
    go e@(Coercion {})    = e

    go_bind (NonRec b e) = NonRec b (go e)
    go_bind (Rec prs)    = Rec [ (b, go e) | (b, e) <- prs ]

-- | All the (non-placeholder) webs on the arrows of a type
typeWebs :: Type -> WebSet
typeWebs ty = go ty emptyUniqSet
  where
    go (TyVarTy {})       acc = acc
    go (LitTy {})         acc = acc
    go (AppTy t1 t2)      acc = go t1 (go t2 acc)
    go (TyConApp _ tys)   acc = foldr go acc tys
    go (ForAllTy _ t)     acc = go t acc
    go (FunTy { ft_web = w, ft_arg = a, ft_res = r }) acc
      = add w (go a (go r acc))
    go (CastTy t _)       acc = go t acc
    go (CoercionTy _)     acc = acc

    add w acc | isPlaceholderWeb w = acc
              | otherwise          = addOneToUniqSet acc w

-- | All the (non-placeholder) webs of a program: on 'WebLam's, 'WebApp's, and
-- the arrows in the types of binders.  Used for statistics.
programWebs :: CoreProgram -> WebSet
programWebs binds = foldr go_bind emptyUniqSet binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go e) acc prs

    go_bndr b acc
      | isId b    = typeWebs (idType b) `unionUniqSets` acc
      | otherwise = acc

    go (Var {})           acc = acc
    go (Lit {})           acc = acc
    go (App f a)          acc = go f (go a acc)
    go (Lam b e)          acc = go_bndr b (go e acc)
    go (WebApp w f a)     acc = addOneToUniqSet (go f (go a acc)) w
    go (WebLam w b e)     acc = addOneToUniqSet (go_bndr b (go e acc)) w
    go (Let bind body)    acc = go_bind bind (go body acc)
    go (Case e b ty alts) acc = go e $ go_bndr b $ (typeWebs ty `unionUniqSets`) $
                                foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
    go (Cast e _)         acc = go e acc
    go (Tick _ e)         acc = go e acc
    go (Type ty)          acc = typeWebs ty `unionUniqSets` acc
    go (Coercion _)       acc = acc
