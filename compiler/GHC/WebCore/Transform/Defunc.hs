-- | Defunctionalisation over webs: the function values of a web become the
-- values of a new data type, one constructor per lambda, and its calls
-- become calls of an apply function.
--
-- See Note [Defunctionalisation] and WEBS-DEFUNC.md.
module GHC.WebCore.Transform.Defunc
  ( defuncProgram
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion ( coercionKind, mkNomReflCo, mkSymCo, mkSubCo, mkCoVarCo )
import GHC.Core.DataCon
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.Predicate ( mkNomEqPred )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprType )
import GHC.Core.TyCo.Compare ( eqType )

import GHC.Data.FastString ( fsLit, mkFastString )
import GHC.Data.Pair ( Pair(..) )

import GHC.Types.Basic ( Arity )
import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Demand ( Demand(..), splitDmdSig, mkClosedDmdSig, nopSig, topSubDmd )
import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey, getUnique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var ( isCoVar, mkTyVar, mkCoVar )
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web
import GHC.Unit.Module ( Module )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( pprPanic )

import GHC.WebCore.Transform.ArityRaise ( knownHead )
import GHC.WebCore.Transform.Common ( UnfoldingPolicy, changedBinders, fixUnfolding )
import GHC.WebCore.Traverse ( typeWebs )

import Control.Monad ( forM )
import Data.List ( sortOn, nub )
import Data.Maybe ( isJust )

{- Note [Defunctionalisation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A non-exposed web w knows every lambda that can reach its calls, and every
call those lambdas can reach.  Defunctionalisation replaces w's function
values by the values of a new data type D_w, and w's calls by calls of a new
apply function.  Like the arrow it replaces, D_w has two parameters, the
argument and result types:

    data D_w a b where                       -- one constructor per lambda
      C_i :: forall ds. (a ~# A_i, b ~# B_i) => t_i1 -> .. -> t_ik -> D_w a b

    A -{w}-> B        ==>   D_w A B                          (in every type)
    Li = \^w x. ei    ==>   C_i @A_i @B_i @ds <A_i> <B_i> vi1 .. vik
    f @^w a           ==>   $apply_w @A @B f a                (f :: A -{w}-> B)

    $apply_w :: forall a b. D_w a b -> a -> b
    $apply_w = /\a b. \fd x. case fd of
                 C_i ds (c1 :: a ~# A_i) (c2 :: b ~# B_i) yi1 .. yik
                   -> let xi = x |> c1 in ei[yij/vij] |> sym c2

Lambda Li has type A_i -> B_i, and free type variables ds (bound by type
lambdas around it, e.g. in a polymorphic function) and free variables
vi1 .. vik.  The ds become the constructor's existentials; the equalities
say which instance of D_w it builds.  At the lambda the equalities are
reflexive, and where $apply_w is inlined at a known constructor the casts
cancel; coercions have no runtime representation.  A post-pass may
specialise D_w (its parameters, and so its equalities) to the most general
unifier of its uses.

Every call of w becomes a known call of $apply_w: GHC can inline it, take the
case apart where the constructor is known (case-of-known-constructor), and
specialise a higher-order function on it (SpecConstr).  An unknown call
(stg_ap_p, an indirect jump) becomes a case on a tag and a direct jump.

Conditions, checked per web:

  * Not exposed, and no join-point lambdas (a jump is not a call).
  * Every call is unknown.  Defunctionalisation would turn a known call of a
    let-bound function into a call of $apply_w and a case, which is slower
    -- and in a recursive function, the case cannot be resolved statically
    (the function is a loop breaker, so its constructor is not visible).
  * At most 'maxLambdas' lambdas: $apply_w has one alternative per lambda.
  * The argument and result kinds are the same at every occurrence of the
    arrow, closed, and the argument's has a fixed runtime representation;
    the lambdas' free type variables have closed kinds.
  * w appears in no coercion (we do not rewrite coercions), and no lambda
    has a free coercion variable.
  * Every free variable of a lambda can be a field: fixed runtime
    representation, not an unboxed tuple or sum.
  * The lambdas' binders are distinct (they key the constructors).

The equalities are primitive (~#) constraints in the constructor's context,
not a GADT equality spec: a data constructor with an equality spec needs a
wrapper, which only the typechecker builds.  The worker takes them as
coercion arguments, like a GADT worker.

Laziness and sharing: a lambda is a value, and so is a constructor
application; a variable of the arrow type that is a thunk is a thunk of
type D_w.  The body of each lambda moves into $apply_w unchanged (but for
renaming and the casts), and runs exactly when the call did.

Binders whose types change get their IdInfo fixed: a binder bound to a
lambda of w is now bound to a constructor (arity 0, no demand signature);
call demands on values of the arrow type lose their call structure (they
are data now), keeping their strictness and cardinality; CPR signatures and
stale unfoldings go (Note [Unfoldings and rules after a transformation]).
-}

maxLambdas :: Int
maxLambdas = 8

data Verdict = Defunc Int | NoDefunc String

instance Outputable Verdict where
  ppr (Defunc n)     = text "defunctionalised" <+> parens (int n <+> text "constructors")
  ppr (NoDefunc why) = text "not defunctionalised" <+> parens (text why)

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Lam = Lam' { l_bndr :: Id, l_expr :: CoreExpr }

data Info = Info
  { i_lams    :: [Lam]
  , i_occs    :: [Type]          -- ^ Occurrences of the web's arrow type
  , i_known   :: Int
  , i_unknown :: Int
  , i_block   :: Maybe String }  -- ^ Why the web cannot be defunctionalised

noInfo :: Info
noInfo = Info [] [] 0 0 Nothing

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_occs a ++ i_occs b)
                    (i_known a + i_known b) (i_unknown a + i_unknown b)
                    (i_block a `orElse'` i_block b)
  where orElse' (Just r) _ = Just r
        orElse' Nothing r  = r

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

block :: String -> Info
block why = noInfo { i_block = Just why }

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | isJoinId b = go_join e acc
      | otherwise  = go e acc

    go_join (Lam _ e)        acc = go_join e acc
    go_join (WebLam w p e)   acc = note w (block "join point") (go_bndr p (go_join e acc))
    go_join e                acc = go e acc

    go :: CoreExpr -> Infos -> Infos
    go expr acc = case expr of
      WebLam w p e  -> note w (noInfo { i_lams = [Lam' p expr] }) (go_bndr p (go e acc))
      Lam b e       -> go_bndr b (go e acc)
      WebApp w f a
        | knownHead f -> note w (noInfo { i_known = 1 })   (go f (go a acc))
        | otherwise   -> note w (noInfo { i_unknown = 1 }) (go f (go a acc))
      App f a       -> go f (go a acc)
      Let bind body -> go_bind bind (go body acc)
      Case e b ty alts
        -> go e $ go_bndr b $ go_ty ty $
           foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
      Cast e co     -> go e (go_co co acc)
      Tick _ e      -> go e acc
      Type t        -> go_ty t acc
      Coercion co   -> go_co co acc
      _             -> acc

    go_bndr b acc
      | isId b    = go_ty (idType b) acc
      | otherwise = acc

    -- Record every occurrence of an arrow (for its kinds)
    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
                     -> note w (noInfo { i_occs = [ty] }) (go_ty a (go_ty r acc))
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t _     -> go_ty t acc
      _              -> acc

    -- Every web in a coercion is left alone
    go_co co acc = foldr (\w -> note w (block "in a coercion")) acc
                         (nonDetEltsUniqSet (coWebs co))

-- | The webs mentioned in a coercion (in its kind)
coWebs :: Coercion -> WebSet
coWebs co = case coercionKind co of
  Pair l r -> typeWebs l `unionUniqSets` typeWebs r

------------------------------------------------------------------
--      Verdicts
------------------------------------------------------------------

-- | What we know about a lambda of a web we defunctionalise
data LamPlan = LamPlan
  { lp_fields :: [Id]       -- ^ Its free local variables, in order
  , lp_tvs    :: [TyVar]    -- ^ Its free type variables (the existentials)
  , lp_arg    :: Type       -- ^ Its argument type
  , lp_res    :: Type }     -- ^ Its result type

verdict :: VarSet -> WebSet -> WebId -> Info -> (Verdict, Maybe (Kind, Kind, [LamPlan]))
verdict tops exposed w i
  | w `elementOfUniqSet` exposed  = no "exposed"
  | Just why <- i_block i          = no why
  | null lams                     = no "no lambdas"
  | i_unknown i == 0              = no "no unknown calls"
  | i_known i > 0                 = no "known calls"
  | length lams > maxLambdas      = no "too many lambdas"
  | length (nub (map (getUnique . l_bndr) lams)) /= length lams
                                  = no "shared lambda binders"
  | Nothing <- kinds              = no "representation-polymorphic"
  | Just why <- firstJust (map lam_problem lams) = no why
  | Just (ka, kb) <- kinds        = (Defunc (length lams), Just (ka, kb, map plan lams))
  where
    lams   = i_lams i
    no why = (NoDefunc why, Nothing)

    -- The argument and result kinds: the same everywhere, and closed
    kinds = case [ (typeKind a, typeKind r) | FunTy { ft_arg = a, ft_res = r } <- i_occs i ] of
      ((ka, kb) : rest)
        | all (\(ka', kb') -> ka' `eqType` ka && kb' `eqType` kb) rest
        , closed ka, closed kb
        , typeHasFixedRuntimeRep (head [ a | FunTy { ft_arg = a } <- i_occs i ])
        -> Just (ka, kb)
      _ -> Nothing
    closed k = isEmptyVarSet (tyCoVarsOfType k)

    fvs l = exprFreeVars (l_expr l)
    fields l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (fvs l), isId v, not (v `elemVarSet` tops) ]
    tyvars l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (fvs l), isTyVar v ]

    lam_problem l
      | any isCoVar (nonDetEltsUniqSet (fvs l))  = Just "free coercion variables"
      | isCoVar (l_bndr l)                       = Just "coercion parameter"
      | not (all ok_field (fields l))            = Just "unsuitable free variable"
      | not (all (closed . tyVarKind) (tyvars l)) = Just "kind-polymorphic"
      | otherwise                                = Nothing

    ok_field v = let t = idType v
                 in typeHasFixedRuntimeRep t && not (isUnboxedTupleType t)
                    && not (isUnboxedSumType t) && not (isJoinId v)

    plan l = LamPlan (fields l) (tyvars l) (idType (l_bndr l)) (exprType (lam_body (l_expr l)))
    lam_body (WebLam _ _ e) = e
    lam_body e              = e

    firstJust (Just x : _) = Just x
    firstJust (_ : xs)     = firstJust xs
    firstJust []           = Nothing

------------------------------------------------------------------
--      The new types
------------------------------------------------------------------

-- | What we build for a web
data DWeb = DWeb
  { d_tycon :: TyCon
  , d_cons  :: UniqFM Id (DataCon, LamPlan)  -- ^ lambda binder -> constructor
  , d_apply :: Id                            -- ^ $apply_w
  , d_atvs  :: [TyVar]                       -- ^ its type parameters, a and b
  , d_fd    :: Id                            -- ^ its first parameter (D_w a b)
  , d_x     :: Id                            -- ^ its second parameter (a)
  , d_w1    :: WebId                         -- ^ the webs of its arrows
  , d_w2    :: WebId
  , d_wild  :: Id                            -- ^ the case binder in $apply_w
  }

-- | Rewrite the arrows of the defunctionalised webs to their data types
mapTy :: UniqFM WebId DWeb -> Type -> Type
mapTy todo = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        | Just d <- lookupUFM todo w -> mkTyConApp (d_tycon d) [go a, go r]
        | otherwise                  -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) co
      _               -> ty

-- | Make the data type, constructors and apply function of a web.  Lazy in
-- 'todo' (field types may mention other new types): see the knot in
-- 'defuncProgram'
mkDWeb :: Module -> UniqFM WebId DWeb -> UniqSupply -> Int -> Kind -> Kind -> [Lam] -> [LamPlan]
       -> DWeb
mkDWeb this_mod todo us n ka kb lams plans
  = DWeb { d_tycon = tycon
         , d_cons = listToUFM (zip (map l_bndr lams) (zip cons plans))
         , d_apply = apply, d_atvs = [aa, ab], d_fd = fd, d_x = x, d_w1 = w1, d_w2 = w2
         , d_wild = wild }
  where
    k = show n
    (us1, us2) = splitUniqSupply us
    uniqs = uniqsFromSupply us1
    nth i = uniqs !! i
    (u_tc, u_ap, u_fd, u_x, u_w1)          = (nth 0, nth 1, nth 2, nth 3, nth 4)
    (u_w2, u_wild, u_ta, u_tb, u_aa, u_ab) = (nth 5, nth 6, nth 7, nth 8, nth 9, nth 10)

    -- The type constructor:  D_w (a :: ka) (b :: kb)
    ta = mkTyVar (mkSystemName u_ta (mkTyVarOccFS (fsLit "a"))) ka
    tb = mkTyVar (mkSystemName u_tb (mkTyVarOccFS (fsLit "b"))) kb
    tc_name = mkExternalName u_tc this_mod (mkTcOcc ("Defun" ++ k)) noSrcSpan
    tycon   = mkAlgTyCon tc_name (mkAnonTyConBinders [ta, tb]) liftedTypeKind
                         [Nominal, Nominal] Nothing [] (mkDataTyConRhs cons)
                         (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
    cons    = [ mk_con tag us_c p
              | (tag, p, us_c) <- zip3 [1 ..] plans (listSplitUniqSupply us2) ]

    mk_con :: Int -> UniqSupply -> LamPlan -> DataCon
    mk_con tag us_c p = dc
      where
        us_c'  = uniqsFromSupply us_c
        u_dc   = head us_c'
        u_wk   = us_c' !! 1
        us_ex  = drop 2 us_c'
        dc_occ  = mkDataOcc ("Defun" ++ k ++ "_" ++ show tag)
        dc_name = mkExternalName u_dc this_mod dc_occ noSrcSpan
        wk_name = mkExternalName u_wk this_mod (mkDataConWorkerOcc dc_occ) noSrcSpan
        no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
        -- The lambda's free type variables become the existentials
        exs     = [ mkTyVar (mkSystemName u (getOccName tv)) (tyVarKind tv)
                  | (tv, u) <- zip (lp_tvs p) us_ex ]
        sub     = zipTvSubst (lp_tvs p) (mkTyVarTys exs)
        inst t  = mapTy todo (substTyUnchecked sub t)
        theta   = [ mkNomEqPred (mkTyVarTy ta) (inst (lp_arg p))
                  , mkNomEqPred (mkTyVarTy tb) (inst (lp_res p)) ]
        arg_tys = [ inst (idType v) | v <- lp_fields p ]
        dc = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
               (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
               (map (const NotMarkedStrict) arg_tys)
               [] [ta, tb] exs emptyNameEnv
               (mkTyVarBinders Specified ([ta, tb] ++ exs)) [] theta
               (map unrestricted arg_tys) (mkTyConApp tycon [mkTyVarTy ta, mkTyVarTy tb])
               NoPromInfo tycon tag [] (mkDataConWorkId wk_name dc) NoDataConRep

    -- The apply function:  forall a b. D_w a b -> a -> b
    aa = mkTyVar (mkSystemName u_aa (mkTyVarOccFS (fsLit "a"))) ka
    ab = mkTyVar (mkSystemName u_ab (mkTyVarOccFS (fsLit "b"))) kb
    d_ty = mkTyConApp tycon [mkTyVarTy aa, mkTyVarTy ab]
    w1 = mkWebId u_w1
    w2 = mkWebId u_w2
    fd   = mkSysLocal (fsLit "fd") u_fd ManyTy d_ty
    wild = mkSysLocal (fsLit "wild") u_wild ManyTy d_ty
    x    = mkSysLocal (fsLit "x") u_x ManyTy (mkTyVarTy aa)
    apply_ty = mkSpecForAllTys [aa, ab] $
               setFunTyWeb w1 (mkVisFunTyMany d_ty
                 (setFunTyWeb w2 (mkVisFunTyMany (mkTyVarTy aa) (mkTyVarTy ab))))
    apply = mkSysLocal (mkFastString ("$apply" ++ k)) u_ap ManyTy apply_ty

------------------------------------------------------------------
--      The program
------------------------------------------------------------------

-- | Defunctionalise the webs that qualify.  Returns the new program (if
-- anything changed), the new type constructors, and the verdicts.
defuncProgram :: Module -> UnfoldingPolicy -> UniqSupply -> WebSet -> CoreProgram
              -> (Maybe (CoreProgram, [TyCon]), [(WebId, SDoc, Bool, [Id])])
defuncProgram this_mod pol us exposed binds
  | isNullUFM todo = (Nothing, dump)
  | otherwise      = (Just (binds' ++ [Rec applies], map d_tycon (nonDetEltsUFM todo)), dump)
  where
    (us1, us2) = splitUniqSupply us
    tops  = mkVarSet (bindersOfBinds binds)
    infos = analyse binds
    verdicts = [ (w, v, mb, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (i_lams i))
               , let (v, mb) = verdict tops exposed w i ]
    dump = [ (w, ppr v, isJust mb, map l_bndr (i_lams i)) | (w, v, mb, i) <- verdicts ]

    -- The knot: field types may mention any of the new types
    todo :: UniqFM WebId DWeb
    todo = listToUFM [ (w, mkDWeb this_mod todo u n ka kb (i_lams i) plans)
                     | (n, (w, _, Just (ka, kb, plans), i), u)
                         <- zip3 [1 ..] [ v | v@(_, _, Just _, _) <- verdicts ]
                                 (listSplitUniqSupply us1) ]

    changed = changedBinders (\ty -> any (`elemUFM` todo) (nonDetEltsUniqSet (typeWebs ty))) binds

    (binds', alts) = initUs_ us2 (rewrite pol todo changed binds)

    applies = [ (d_apply d, mk_apply d (lookupWithDefaultUFM alts [] (mkWebId u)))
              | (u, d) <- nonDetUFMToList todo ]

    mk_apply d as
      = mkLams (d_atvs d) $
        WebLam (d_w1 d) (d_fd d) $ WebLam (d_w2 d) (d_x d) $
        Case (Var (d_fd d)) (d_wild d) (mkTyVarTy (d_atvs d !! 1))
             (sortOn alt_tag [ Alt (DataAlt dc) bs rhs | (dc, bs, rhs) <- as ])
    alt_tag (Alt (DataAlt dc) _ _) = dataConTag dc
    alt_tag _                      = 0

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

-- | For each web, the alternatives of its apply function
type Alts = UniqFM WebId [(DataCon, [Var], CoreExpr)]

-- | The rewrite's environment: the new versions of binders, and a type
-- substitution (inside a lambda body moved into $apply_w, the lambda's free
-- type variables become the alternative's existentials)
data Env = Env { e_ids :: VarEnv Id, e_tsub :: Subst }

rewrite :: UnfoldingPolicy -> UniqFM WebId DWeb -> VarSet -> CoreProgram
        -> UniqSM (CoreProgram, Alts)
rewrite pol todo changed binds
  = do { let env0 = Env (mkVarEnv [ (b, fixBndr (mapTy todo (idType b)) b)
                                  | b <- bindersOfBinds binds ]) emptySubst
       ; rs <- mapM (rw_top env0) binds
       ; return (map fst rs, foldr (plusUFM_C (++) . snd) emptyUFM rs) }
  where
    rw_top env (NonRec b e) = do { (e', as) <- rw env e; return (NonRec (lk env b) e', as) }
    rw_top env (Rec prs)
      = do { rs <- mapM (\(b, e) -> do { (e', as) <- rw env e; return ((lk env b, e'), as) }) prs
           ; return (Rec (map fst rs), foldr (plusUFM_C (++) . snd) emptyUFM rs) }

    lk env v = lookupVarEnv (e_ids env) v `orElse` v
    orElse (Just x) _ = x
    orElse Nothing  y = y

    -- Types: substitute, then rewrite the arrows
    sty env = substTyUnchecked (e_tsub env)
    ty env  = mapTy todo . sty env

    -- A binder with its new type; see Note [Defunctionalisation]
    fixBndr new_ty b
      | not (isId b)                   = b
      | b `elemVarSet` changed         = fixChanged new_ty b
      | not (new_ty `eqType` idType b) = zapIdUnfolding (setIdType b new_ty)
      | otherwise                      = fixUnfolding pol changed b

    fixChanged new_ty b
      = fixUnfolding pol changed $
        setIdType b new_ty
           `setIdArity` new_arity
           `setIdDmdSig` new_sig
           `setIdCprSig` topCprSig
           `setIdDemandInfo` data_dmd (idDemandInfo b)
           `setIdCallArity` min (idCallArity b) new_arity
      where
        new_arity = min (idArity b) (arrows new_ty)
        new_sig
          | new_arity < idArity b = nopSig
          | otherwise = case splitDmdSig (idDmdSig b) of
              (dmds, div) -> mkClosedDmdSig (zipWith fix_arg dmds
                                                     (map Just (arg_tys (idType b)) ++ repeat Nothing)) div
        fix_arg d (Just t) | any (`elemUFM` todo) (nonDetEltsUniqSet (typeWebs t)) = data_dmd d
        fix_arg d _        = d

    -- A demand on a function value that is now data: keep how strict and how
    -- often, drop the call structure
    data_dmd (n :* _) = n :* topSubDmd

    arrows t = case coreFullView t of
      ForAllTy _ r         -> arrows r
      FunTy { ft_res = r } -> 1 + arrows r
      _                    -> 0 :: Arity
    arg_tys t = case coreFullView t of
      ForAllTy _ r                     -> arg_tys r
      FunTy { ft_arg = a, ft_res = r } -> a : arg_tys r
      _                                -> []

    bndr env b
      | isId b    = let b' = fixBndr (ty env (idType b)) b
                    in return (env { e_ids = extendVarEnv (e_ids env) b b' }, b')
      | otherwise = return (env, b)

    bndrs env [] = return (env, [])
    bndrs env (b : bs) = do { (env1, b') <- bndr env b; (env2, bs') <- bndrs env1 bs
                            ; return (env2, b' : bs') }

    fresh_tv tv = do { u <- getUniqueM
                     ; return (mkTyVar (mkSystemName u (getOccName tv)) (tyVarKind tv)) }

    rw :: Env -> CoreExpr -> UniqSM (CoreExpr, Alts)
    rw env expr = case expr of
      Var v -> return (Var (lk env v), emptyUFM)
      Lit {} -> return (expr, emptyUFM)
      Type t -> return (Type (ty env t), emptyUFM)
      Coercion co -> return (Coercion (substCoUnchecked (e_tsub env) co), emptyUFM)
      App f a -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
                    ; return (App f' a', plus as1 as2) }
      WebApp w f a
        | Just d <- lookupUFM todo w
        -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
              ; let fun_ty = sty env (exprType f)
                    (arg_t, res_t) = case coreFullView fun_ty of
                      FunTy { ft_arg = at, ft_res = rt } -> (at, rt)
                      t -> pprPanic "Defunc: call of a non-function" (ppr t)
                    apply_at = mkTyApps (Var (d_apply d)) [mapTy todo arg_t, mapTy todo res_t]
              ; return ( WebApp (d_w2 d) (WebApp (d_w1 d) apply_at f') a'
                       , plus as1 as2 ) }
        | otherwise
        -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
              ; return (WebApp w f' a', plus as1 as2) }
      WebLam w x e
        | Just d <- lookupUFM todo w
        , Just (dc, p) <- lookupUFM (d_cons d) x
        -> do { -- The alternative of $apply_w: fresh existentials,
                -- coercions and fields.  See Note [Defunctionalisation]
                exs <- mapM fresh_tv (lp_tvs p)
              ; let body_env0 = Env (e_ids env) (zipTvSubst (lp_tvs p) (mkTyVarTys exs))
                    arg_i = ty body_env0 (lp_arg p)
                    res_i = ty body_env0 (lp_res p)
                    (ta, tb) = case d_atvs d of
                      [a', b'] -> (mkTyVarTy a', mkTyVarTy b')
                      _        -> pprPanic "Defunc: apply parameters" (ppr (d_atvs d))
              ; u1 <- getUniqueM; u2 <- getUniqueM; u3 <- getUniqueM
              ; let c1 = mkCoVar (mkSystemName u1 (mkVarOccFS (fsLit "co"))) (mkNomEqPred ta arg_i)
                    c2 = mkCoVar (mkSystemName u2 (mkVarOccFS (fsLit "co"))) (mkNomEqPred tb res_i)
                    xi = mkSysLocal (occNameFS (getOccName x)) u3 ManyTy arg_i
              ; ys <- forM (lp_fields p) $ \v ->
                        do { u <- getUniqueM
                           ; return (mkSysLocal (occNameFS (getOccName v)) u ManyTy
                                                (ty body_env0 (idType v))) }
              ; let body_env = body_env0 { e_ids = extendVarEnvList (e_ids env)
                                                     ((x, xi) : zip (lp_fields p) ys) }
              ; (e', as) <- rw body_env e
              ; let x_in  = Cast (Var (d_x d)) (mkSubCo (mkCoVarCo c1))
                    bound | isUnliftedType arg_i = Case x_in xi res_i [Alt DEFAULT [] e']
                          | otherwise            = Let (NonRec xi x_in) e'
                    rhs   = Cast bound (mkSubCo (mkSymCo (mkCoVarCo c2)))
                -- The constructor, where the lambda was
                    arg_l = ty env (lp_arg p)
                    res_l = ty env (lp_res p)
                    con0  = mkTyApps (Var (dataConWorkId dc))
                                     ([arg_l, res_l] ++ map (ty env . mkTyVarTy) (lp_tvs p))
                    con1  = foldl (\f co -> WebApp placeholderWeb f (Coercion co)) con0
                                  [mkNomReflCo arg_l, mkNomReflCo res_l]
                    con   = foldl (\f v -> WebApp placeholderWeb f (Var (lk env v))) con1 (lp_fields p)
              ; return (con, plus as (unitUFM w [(dc, exs ++ [c1, c2] ++ ys, rhs)])) }
        | otherwise
        -> do { (env', x') <- bndr env x; (e', as) <- rw env' e
              ; return (WebLam w x' e', as) }
      Lam b e -> do { (env', b') <- bndr env b; (e', as) <- rw env' e
                    ; return (Lam b' e', as) }
      Let (NonRec b rhs) body
        -> do { (rhs', as1) <- rw env rhs
              ; (env', b') <- bndr env b
              ; (body', as2) <- rw env' body
              ; return (Let (NonRec b' rhs') body', plus as1 as2) }
      Let (Rec prs) body
        -> do { (env', bs') <- bndrs env (map fst prs)
              ; rs <- mapM (rw env' . snd) prs
              ; (body', as2) <- rw env' body
              ; return ( Let (Rec (zip bs' (map fst rs))) body'
                       , foldr (plus . snd) as2 rs ) }
      Case scrut b t alts
        -> do { (scrut', as1) <- rw env scrut
              ; (env', b') <- bndr env b
              ; rs <- forM alts $ \(Alt c bs rhs) ->
                        do { (env'', bs') <- bndrs env' bs
                           ; (rhs', as) <- rw env'' rhs
                           ; return (Alt c bs' rhs', as) }
              ; return (Case scrut' b' (ty env t) (map fst rs), foldr (plus . snd) as1 rs) }
      Cast e co -> do { (e', as) <- rw env e
                      ; return (Cast e' (substCoUnchecked (e_tsub env) co), as) }
      Tick t e  -> do { (e', as) <- rw env e; return (Tick (rw_tick env t) e', as) }

    rw_tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lk env) ids }
    rw_tick _ t = t

    plus = plusUFM_C (++)
