
import GHC.Core
import Data.Map.Strict as Map

type var = Id
type env = (Map.Map Id Id, Map.Map Core.DataCon Core.DataCon, Map.Map Core.TyCon Core.TyCon, Map.Map Core.CoVar Core.CoVar)


findDataCon :: env -> Core.DataCon -> Core.DataCon
findDataCon (_, _, dcmap, _, _) dc = Map.lookup dcmap dc
findTyCon :: env -> Core.TyCon -> Core.TyCon
findDataCon (_, tcmap, _, _, _) tc = Map.lookup tcmap tc
findVar :: env -> var -> var
findDataCon (idmap, _, _, _, _) id = Map.lookup idmap id
findCoVar :: env -> Core.CoVar -> WebCore.CoVar
findCoVar (_, _, _, cvmap, _) cv = Map.lookup cvmap cv
findTyVar :: env -> Core.Var -> WebCore.Var
findTyVar (_, _, _, _, tvmap) tv = Map.lookup tvmap tv

extendVar :: env -> var -> var -> env
extendVar (idmap, tcmap, dcmap, cvmap, tvmap) x x' = (Map.insert idmap x x', tcmap, dcmap, cvmap, tvmap)
extendDataCon :: env -> Core.DataCon -> WebCore.DataCon -> env
extendDataCon (idmap, tcmap, dcmap, cvmap, tvmap) dc dc' = (idmap, tcmap, Map.insert dcmap dc dc', cvmap, tvmap)

extendVars :: env -> [var] -> [var] -> env
extendVars env xs xs' = List.foldr (\ (x, x') env -> extendVar env x x') env (zip xs xs')

nextWeb :: int -> (int, WebId)
nextWeb n = (n+1, mkWeb n)

freshExp :: int -> env -> Core.Expr b -> (int, WebCore.Expr b)
freshExp n env (Core.Var x) = (n, WebCore.Var (findVar env x))
freshExp n env (Core.Literal lit) = (n, WebCore.Literal lit)
freshExp n env (Core.App f arg) = (n''', WebCore.App web f' arg')
  where
    (n', f') = freshExp n f
    (n'', arg') = freshExp n' arg
    (n''', web) = nextWeb n''
freshExp n env (Core.Lam x e) = (n''', WebCore.Lam web x' e')
  where
    (n', x') = freshVar n env? x
    env' = extendVar env x x'
    (n'', e') = freshExp n' env' e
    (n''', e') = nextWeb n''
freshExp n env (Core.Let bnd e) = (n'', WebCore.Let bnd' e')
  where
    (n', bnd', env') = freshBind n env bnd
    (n'', e') = freshExp n' env' e
freshExp n env (Core.Case e x ty alts) = (n'''', WebCore.Case e' x' ty' alts')
  where
    (n', e') = freshExp n env e
    (n'', x') = freshVar n' env? x
    (n''', ty') = freshTy n'' env? ty
    env' = extendVar env x x'
    (n'''', alts) = freshAlts n''' env' alts
freshExp n env (Core.Cast e co) = (n'', WebCore.Cast e' co')
  where
    (n', e') = freshExp n env e
    (n'', co') = freshCoercion n' env? co
freshExp n env (Core.Tick tick e) = (n', WebCore.Tick tick? e')
  where
    (n', e') = freshExp n env e
freshExp n env (Core.Type ty) = (n', WebCore.Type ty')
  where
    (n', ty') = freshTy n env ty
freshExp n env (Core.Coercion co) = (n', WebCore.Coercion co')
  where
    (n', co') = freshCoercion n env co

freshTy :: int -> env? -> Core.Type -> (int, WebCore.Type)
freshTy n env (Core.TyVarTy a) = (n, WebCore.TyVarTy a')
  where
    a' = findTyVar env a
freshTy n env (Core.AppTy ty1 ty2) = (n'', WebCore.AppTy ty1' ty2')
  where
    (n', ty1') = freshTy n env ty1
    (n'', ty2') = freshTy n' env ty2
freshTy n env (Core.TyConApp tycon kot_list) = (n, WebCore.TyConApp tycon' kot_list')
  tycon' = findTyCon env tycon
  kot_list' = foldr (\ kot (n, kot_list') ->
                       let kot' = freshKindOrType n env in
                       (n', kot' : kot_list))
                    (n, []) kot_list
freshTy n env (Core.FunTy {ft_af, ft_mult, ft_arg, ft_res}) = (n''', WebCore.FunTy {ft_af=ft_af, web=web, ft_arg=ft_arg', ft_res=ft_res'})
  where
    (n', ft_arg') = freshTy n env ft_arg
    (n'', ft_res) = freshTy n' env ft_res
    (n''', web) = nextWeb n''
-- TODO: need to map TyLit as well?
freshTy n env (Core.LitTy tylit) = (n, tylit)
freshTy n env (Core.CastTy ty kind_co) = (n'', WebCore.CastTy ty' kind_co')
  where
    (n', ty') = freshTy n env ty
    (n'', kind_co') = freshKindCoercion n' kind_co
freshTy n env (Core.CoercionTy co) = (n', WebCore.CoercionTy co')
  where
    (n', co') = freshCoercion n env co
freshKindOrType n env (Core.ForAllTy xs ty) = (n, WebCore.ForAllTy xs' ty')
  where
    (n', xs') = freshVars n env xs
    env' =
    (n'', ty') = freshTy n' env' ty

freshCoercion :: int -> env? -> Core.Coercion -> WebCore.Coercion
freshCoercion n env (Core.Refl ty) = (n', WebCore.Refl ty')
  where
    (n', ty') = freshTy n env ty
freshCoercion n env (Core.GRefl role ty co) = (n'', WebCore.GRefl role ty' co')
  where
    (n', ty') = freshTy n env ty
    (n'', co') = freshCoercion n' env co
freshCoercion n env (Core.TyConAppCo role tycon co_list) = (n', WebCore.TyConAppCo role tycon' co_list')
  where
    tycon' = findTyCon env tycon
    (n', co_list') = foldr (\ co (n, co_list') ->
                             let (n', co') = freshCoercion n env co in
                             (n', co' : co_list'))
                           (n', []) co_list
freshCoercion n env (Core.AppCo co1 co2) = (n'', WebCore.AppCo co1' co2')
  where
    (n', co1') = freshCoercion n env co1
    (n'', co2') = freshCoercion n' env co2
freshCoercion n env (Core.ForallCo {fco_tcv, fco_visL, fco_visR, fco_kind, fco_body}) = WebCore.ForallCo {fco_tcv', fco_visL', fco_visR', fco_kind', fco_body'}
  env'
freshCoercion n env (Core.FunCo record) = (WebCore.FunCo (record {fco_arg=fco_arg', fco_res=fco_res'}))
  {- {fco_role, fco_afl, fco_afr, fco_mult, fco_arg, fco_res} -}
  where
    (n', fco_arg') = freshCoercion n env (fco_arg record)
    (n'', fco_res') = freshCoercion n' env (fco_res record)
  
freshCoercion n env (Core.CoVarCo covar) = (n, WebCore.CoVarCo covar')
  where
    covar' = findCoVar covar
freshCoercion n env (Core.AxiomCo rule co_list) = (n'', WebCore.AxiomCo co_rule' co_list'')
  where
    (n', co_rule') = freshCoercionRule n env co_rule
    (n'', co_list') = foldr (\ co (n, co_list') ->
                                let (n', co') = freshCoercion n env co in
                                (n', co' : co_list'))
                      (n', []) co_list
freshCoercion n env (Core.UnivCo record) = (n''', WebCore.UnivCo (record {uco_lty=uco_lty', uco_ty=uco_rty', uco_deps=uco_deps'}))
  {- {uco_prov, uco_role, uco_lty, uco_rty, uco_deps} -}
  where
    (n', uco_lty') = freshCoercion n env (uco_lty record)
    (n'', uco_rty') = freshCoercion n env (uco_rty record)
    (n''', uco_deps) = foldr (\ co (n, uco_deps') ->
                              l et (n' co') = freshCoercion n env co in
                               (n', co' : uco_deps'))
                             (n'', []) (uco_deps record)
                               
freshCoercion n env (Core.SymCo co) = (n', Core.SymCo co')
  where
    (n', co') = freshCoercion n env co
freshCoercion n env (Core.TransCo co1 co2) = (n', WebCore.TransCo co1' co2')
  where
    (n', co1') = freshCoercion n env co1
    (n'', co2') = freshCoercion n' env co2
freshCoercion n env (Core.SelCo cosel co) = (n', WebCore.SelCo cosel co')
  where
    (n', co') = freshCoercion n env co
freshCoercion n env (Core.LRCo lor co) = (n', WebCore.LRCo lor co')
  where
    (n', co') = freshCoercion n env co
freshCoercion n env (Core.InstCo co1 co2) = (n', WebCore.InstCo co1' co2')
  where
    (n', co1') = freshCoercion n env co1
    (n'', co2') = freshCoercion n' env co2
freshCoercion n env (Core.KindCo co) = (n', WebCore.KindCo co')
  where
    (n', co') = freshCoercion n env co
freshCoercion n env (Core.SubCo co) = (n', WebCore.SubCo co')
  where
    (n', co') = freshCoercion n env co
freshCoercion n env (Core.HoleCo co_hole) = TODO
{- TODO: can we assume this case is an error? -}

{- freshCoercionHole n env (Core.CoercionHole {ch_co_var, ch_ref}) -}

{-
data CoercionHole
  = CoercionHole { ch_co_var  :: CoVar
                       -- See Note [CoercionHoles and coercion free variables]

                 , ch_ref :: IORef (Maybe Coercion)
                 }
-}

freshCoAxiomRule :: int -> env -> Core.CoAxiom -> (int, WebCore.CoAxiom)
{-
data CoAxiom br
  = CoAxiom                   -- Type equality axiom.
    { co_ax_unique   :: Unique        -- Unique identifier
    , co_ax_name     :: Name          -- Name for pretty-printing
    , co_ax_role     :: Role          -- Role of the axiom's equality
    , co_ax_tc       :: TyCon         -- The head of the LHS patterns
                                      -- e.g.  the newtype or family tycon
    , co_ax_branches :: Branches br   -- The branches that form this axiom
    , co_ax_implicit :: Bool          -- True <=> the axiom is "implicit"
                                      -- See Note [Implicit axioms]
         -- INVARIANT: co_ax_implicit == True implies length co_ax_branches == 1.
    }

data CoAxiomRule
  = BuiltInFamRew  BuiltInFamRewrite                   -- Built-in type-family rewrites
                                                       --    e.g.  3+5 ~ 7

  | BuiltInFamInj  BuiltInFamInjectivity               -- Built-in type-family deductions
                                                       --    e.g.  a+b~0 ==>  a~0
                                                       -- Always unary

  | BranchedAxiom      (CoAxiom Branched) BranchIndex  -- Closed type family

  | UnbranchedAxiom    (CoAxiom Unbranched)            -- Open type family instance,
-}

freshKindCoercion :: int -> env -> Core.KindCoercion -> WebCore.KindCoercion
freshKindCoercion = freshCoercion

freshVar :: int -> env? -> var -> (int, var)
freshVars :: int -> env? -> [var] -> (int [var])

{- additionally returns the updated environment -}
freshBind :: int -> env -> Core.Bind var -> (int, WebCore.Bind var, env)
freshBind n env (NonRec x e) = (n'', NonRec x' e', env')
  where
    (n', x') = freshVar n env x
    env' = extendVar env x x'
    (n'', e') = freshExp n' env' e
freshBind n env (Rec bnds) = (n'', bnds', env')
  where
    (n', env') = List.foldr (\ (x, _) (n, env') ->
                              let (n', x') = freshVar n env x in -- use the original environment
                              (n', updateVar env' x x'))
                           (n, env) bnds
    (n'', bnds') = List.foldr (\ (x, rhs) (n, bnds') ->
                               let x' = findVar env x in
                               let (n', rhs') = freshExp n env' rhs in
                               (n', (x', rhs') : bnds'))
                            (n', []) bnds

freshAlts :: int -> env? -> [Core.Alt var] -> (int, [WebCore.Alt var])
freshAlts n env [] = (n, [])
freshAlts n env (alt : alts) = (n'', alt' : alts')
  where
   (n', alt') = freshAlt n env alt
   (n'', alts') = freshAlts n' env alts

freshAlt :: int -> env -> Core.Alt var -> (int, WebCore.Alt var)
freshAlt n env (Core.Alt altc xs e) = (WebCore.Alt altc' xs' e')
  where 
    (n', altc') = freshAltCon n env altc
    (n'', xs') = freshVars n' env xs
    env' = extendVars env xs xs'
    (n''', e') = freshExp n'' env' e'

freshAltCon :: int -> env -> Core.AltCon -> (int, WebCore.AltCon)
freshAltCon n env (Core.DataAlt dc) = (n, WebCore.DataAlt dc')
  where
    dc' = findDataCon env dc
freshAltCon n env (Core.LitAlt lit) = (n, WebCore.LitAlt lit')
  where
    lit' = lit
freshAltCon n env DEFAULT = (n, DEFAULT)

data Expr b
  = Var   Id
  | Lit   Literal
  | App   Web (Expr b) (Arg b)
  | Lam   Web b (Expr b)
  | Let   (Bind b) (Expr b)
  | Case  (Expr b) b Type [Alt b]   -- See Note [Case expression invariants]
                                    -- and Note [Why does Case have a 'Type' field?]
  | Cast  (Expr b) CoercionR        -- The Coercion has Representational role
  | Tick  CoreTickish (Expr b)
  | Type  Type
  | Coercion Coercion

