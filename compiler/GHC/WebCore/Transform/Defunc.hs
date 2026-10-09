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
import GHC.Core.Utils ( exprType, exprIsTrivial )
import GHC.Core.TyCo.Compare ( eqType )

import GHC.Data.FastString ( fsLit, mkFastString )
import GHC.Data.Pair ( Pair(..) )

import GHC.Types.Basic ( Arity )
import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Demand ( Demand(..), isAbs, splitDmdSig, mkClosedDmdSig, nopSig, topSubDmd, topDmd, topDiv )
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
import GHC.Types.Var ( CoVar, isCoVar, mkTyVar, mkCoVar )
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web
import GHC.Unit.Module ( Module )

import GHC.Utils.Outputable
import GHC.Utils.Panic ( pprPanic )

import GHC.WebCore.Transform.ArityRaise ( knownHead )
import GHC.WebCore.Transform.Common ( UnfoldingPolicy, changedBinders, fixUnfolding )
import GHC.WebCore.Traverse ( typeWebs, stripWebForms )

import Control.Monad ( forM )
import Data.List ( sortOn, nub, zip5 )
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
  * At least two lambdas.  A web with one lambda gains only known calls,
    which GHC's specialisation gets anyway when the lambda is passed into a
    recursive function -- and specialises better on the lambda than on its
    constructor: in nofib real/eff/CS (continuations of a Church-encoded
    state monad), defunctionalising one-lambda webs left an unknown call
    in a loop that GHC otherwise reduces to a counter (+156% instructions),
    and spectral/hartel/event lost 6%.  mate and solid keep their gains.
  * A curried web only with the web it returns (Note [Curried lambdas]),
    or together with it, at once (Note [Defunctionalising whole arities]).
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
  , i_block   :: Maybe String    -- ^ Why the web cannot be defunctionalised
  , i_parents :: [WebId]         -- ^ Per occurrence of the arrow type that is the
                                 --   result of another arrow: that arrow's web
  , i_heads   :: [Maybe WebId] } -- ^ Per call: the web of the call it applies, if
                                 --   its function is a call
                                 --   (Note [Defunctionalising whole arities])

noInfo :: Info
noInfo = Info [] [] 0 0 Nothing [] []

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_occs a ++ i_occs b)
                    (i_known a + i_known b) (i_unknown a + i_unknown b)
                    (i_block a `orElse'` i_block b)
                    (i_parents a ++ i_parents b) (i_heads a ++ i_heads b)
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
        | knownHead f -> note w (noInfo { i_known = 1, i_heads = [head_web f] })   (go f (go a acc))
        | otherwise   -> note w (noInfo { i_unknown = 1, i_heads = [head_web f] }) (go f (go a acc))
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

    head_web f = case f of
      WebApp w' _ _ -> Just w'
      _             -> Nothing

    -- Record every occurrence of an arrow (for its kinds)
    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
                     -> note w (noInfo { i_occs = [ty] }) $
                        go_ty a $
                        (case r of
                           FunTy { ft_web = w2 } -> note w2 (noInfo { i_parents = [w] })
                           _                     -> id) $
                        go_ty r acc
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
  , lp_args   :: [Type]     -- ^ Its argument types (one per web of the chain)
  , lp_res    :: Type }     -- ^ Its result type

-- | The binders and body of a lambda of a chain of n webs:
--   \^w1 x1. .. \^wn xn. e  (Note [Defunctionalising whole arities])
chainLam :: Int -> CoreExpr -> ([Id], CoreExpr)
chainLam 0 e = ([], e)
chainLam n (WebLam _ x e) = let (xs, b) = chainLam (n - 1) e in (x : xs, b)
chainLam _ e = pprPanic "Defunc.chainLam" (ppr e)

-- | The web of the lambda a web lambda's body is, directly
directInner :: CoreExpr -> Maybe WebId
directInner (WebLam _ _ (WebLam w2 _ _)) = Just w2
directInner _                            = Nothing

verdict :: VarSet -> WebSet -> Int -> WebId -> Info -> (Verdict, Maybe ([Kind], Kind, [LamPlan]))
verdict tops exposed n w i
  | w `elementOfUniqSet` exposed  = no "exposed"
  | Just why <- i_block i          = no why
  | null lams                     = no "no lambdas"
  | i_unknown i == 0              = no "no unknown calls"
  | i_known i > 0                 = no "known calls"
  | length lams > maxLambdas      = no "too many lambdas"
  | [_] <- lams                   = no "one lambda"
  | length (nub (map (getUnique . l_bndr) lams)) /= length lams
                                  = no "shared lambda binders"
  | Nothing <- kinds              = no "representation-polymorphic"
  | Just why <- firstJust (map lam_problem lams) = no why
  | Just (kas, kb) <- kinds       = (Defunc (length lams), Just (kas, kb, map plan lams))
  where
    lams   = i_lams i
    no why = (NoDefunc why, Nothing)

    -- The argument and result kinds (n arguments, along the chain): the
    -- same everywhere, and closed
    kinds = case [ (map typeKind as, typeKind r, as) | Just (as, r) <- map (peelArrows n) (i_occs i) ] of
      ((kas, kb, as) : rest)
        | length rest + 1 == length (i_occs i)
        , all (\(kas', kb', _) -> and (zipWith eqType kas' kas) && kb' `eqType` kb) rest
        , all closed (kb : kas)
        , all typeHasFixedRuntimeRep as
        -> Just (kas, kb)
      _ -> Nothing
    closed k = isEmptyVarSet (tyCoVarsOfType k)

    fvs l = exprFreeVars (l_expr l)
    fields l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (fvs l), isId v, not (v `elemVarSet` tops) ]
    -- exprFreeVars does not look into the types of free variables, and a
    -- field's type can mention a type variable the body does not
    tycovars l = fvs l `unionVarSet`
                 tyCoVarsOfTypes (map idType (fields l) ++ arg_tys_l l ++ [res_ty l])
    tyvars l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (tycovars l), isTyVar v ]

    lam_problem l
      | any isCoVar (nonDetEltsUniqSet (tycovars l)) = Just "free coercion variables"
      | any isCoVar (lam_xs l)                   = Just "coercion parameter"
      | not (all ok_field (fields l))            = Just "unsuitable free variable"
      | not (all (closed . tyVarKind) (tyvars l)) = Just "kind-polymorphic"
      | otherwise                                = Nothing

    ok_field v = let t = idType v
                 in typeHasFixedRuntimeRep t && not (isUnboxedTupleType t)
                    && not (isUnboxedSumType t) && not (isJoinId v)

    plan l = LamPlan (fields l) (tyvars l) (map idType (lam_xs l)) (res_ty l)
    lam_xs l = fst (chainLam n (l_expr l))
    arg_tys_l l = map idType (lam_xs l)
    res_ty l = exprType (snd (chainLam n (l_expr l)))





    firstJust (Just x : _) = Just x
    firstJust (_ : xs)     = firstJust xs
    firstJust []           = Nothing

-- | The n argument types and the result of a chain of n arrows
peelArrows :: Int -> Type -> Maybe ([Type], Type)
peelArrows 0 t = Just ([], t)
peelArrows n t = case t of
  FunTy { ft_arg = a, ft_res = r } -> do { (as, b) <- peelArrows (n - 1) r; return (a : as, b) }
  _                                -> Nothing

------------------------------------------------------------------
--      The new types
------------------------------------------------------------------

-- | A lambda's body, and the variables it is rewritten over: the lifted
-- function's parameters (or, with an apply function, the alternative's
-- binders, which are the same variables)
data LamFun = LamFun
  { lf_dc   :: DataCon      -- ^ the lambda's constructor
  , lf_plan :: LamPlan
  , lf_id   :: Id           -- ^ the lifted function $lam_i
  , lf_tvs  :: [TyVar]      -- ^ the lambda's free type variables, renamed
  , lf_ys   :: [Id]         -- ^ its free variables, renamed
  , lf_xs   :: [Id]         -- ^ its parameters (one per web of the chain), renamed
  , lf_res  :: Type         -- ^ its result type
  , lf_webs :: [WebId]      -- ^ the webs of $lam_i's arrows
  , lf_cs   :: [CoVar]      -- ^ in $apply_w's alternative:  a_j ~# A_ij
  , lf_cres :: CoVar        -- ^                             b ~# B_i
  }

-- | What we build for a web
data DWeb = DWeb
  { d_tycon :: TyCon
  , d_lams  :: UniqFM Id LamFun   -- ^ lambda binder -> its constructor and body
  , d_order :: [LamFun]           -- ^ in constructor order
  , d_apply :: Id                 -- ^ $apply_w (unless the bodies are lifted)
  , d_atvs  :: [TyVar]            -- ^ its type parameters, a_1 .. a_n and b
  , d_fd    :: Id                 -- ^ its first parameter (D_w a_1 .. a_n b)
  , d_xs    :: [Id]               -- ^ its other parameters (a_1 .. a_n)
  , d_ws    :: [WebId]            -- ^ the webs of its arrows (n + 1)
  , d_wild  :: Id                 -- ^ the case binder in $apply_w
  , d_chain :: [WebId]            -- ^ the webs it replaces, outermost first
  }

-- | The number of arguments a defunctionalised web's calls take
dArity :: DWeb -> Int
dArity = length . d_chain

-- | Rewrite the arrows of the defunctionalised webs to their data types
mapTy :: UniqFM WebId DWeb -> Type -> Type
mapTy todo = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        | Just d <- lookupUFM todo w
        , Just (as, b) <- peelArrows (dArity d) ty
        -> mkTyConApp (d_tycon d) (map go as ++ [go b])
        | otherwise -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) co
      _               -> ty

-- | Make the data type, constructors, lifted bodies and apply function of a
-- web.  Lazy in 'todo' (field types may mention other new types): see the
-- knot in 'defuncProgram'
mkDWeb :: Module -> UniqFM WebId DWeb -> UniqSupply -> Int -> [WebId] -> [Kind] -> Kind -> [Lam]
       -> [LamPlan] -> DWeb
mkDWeb this_mod todo us n chain kas kb lams plans
  = DWeb { d_tycon = tycon
         , d_lams  = listToUFM (zip (map l_bndr lams) funs)
         , d_order = funs
         , d_apply = apply, d_atvs = aas ++ [ab], d_fd = fd, d_xs = xs, d_ws = ws
         , d_wild = wild, d_chain = chain }
  where
    k = show n
    arity = length chain
    (us1, us234) = splitUniqSupply us
    (us2, us34)  = splitUniqSupply us234
    (us3, us4)   = splitUniqSupply us34
    uniqs = uniqsFromSupply us1
    nth i = uniqs !! i
    (u_tc, u_tb, u_ap, u_fd, u_wild, u_ab) = (nth 0, nth 1, nth 2, nth 3, nth 4, nth 5)
    -- per argument: the type constructor's parameter, $apply_w's type
    -- variable and parameter, and the web of its arrow
    arg_us = chunks 4 (uniqsFromSupply us4)
    chunks m xs' = take m xs' : chunks m (drop m xs')
    per_arg = take arity arg_us

    -- The type constructor:  D_w (a_1 :: ka_1) .. (a_n :: ka_n) (b :: kb)
    tas = [ mkTyVar (mkSystemName (u !! 0) (mkTyVarOccFS (fsLit ("a" ++ show j)))) ka
          | (j, ka, u) <- zip3 [1 :: Int ..] kas per_arg ]
    tb = mkTyVar (mkSystemName u_tb (mkTyVarOccFS (fsLit "b"))) kb
    tparams = tas ++ [tb]
    tc_name = mkExternalName u_tc this_mod (mkTcOcc ("Defun" ++ k)) noSrcSpan
    tycon   = mkAlgTyCon tc_name (mkAnonTyConBinders tparams) liftedTypeKind
                         (map (const Nominal) tparams) Nothing [] (mkDataTyConRhs cons)
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
        theta   = [ mkNomEqPred (mkTyVarTy ta) (inst t) | (ta, t) <- zip tas (lp_args p) ]
                  ++ [ mkNomEqPred (mkTyVarTy tb) (inst (lp_res p)) ]
        arg_tys = [ inst (idType v) | v <- lp_fields p ]
        dc = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
               (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
               (map (const NotMarkedStrict) arg_tys)
               [] tparams exs emptyNameEnv
               (mkTyVarBinders Specified (tparams ++ exs)) [] theta
               (map unrestricted arg_tys) (mkTyConApp tycon (mkTyVarTys tparams))
               NoPromInfo tycon tag [] (mkDataConWorkId wk_name dc) NoDataConRep

    -- The bodies:  $lam_i :: forall ds. t_i1 -> .. -> t_ik -> A_i -> B_i
    funs = [ mk_fun tag l p dc us_f
           | (tag, l, p, dc, us_f) <- zip5 [1 :: Int ..] lams plans cons (listSplitUniqSupply us3) ]

    mk_fun tag l p dc us_f
      = LamFun { lf_dc = dc, lf_plan = p, lf_id = fun, lf_tvs = tvs', lf_ys = ys, lf_xs = xs'
               , lf_res = res, lf_webs = webs, lf_cs = cs, lf_cres = cres }
      where
        uf = uniqsFromSupply us_f
        tvs' = [ mkTyVar (mkSystemName u (getOccName tv)) (tyVarKind tv)
               | (tv, u) <- zip (lp_tvs p) uf ]
        uf1  = drop (length tvs') uf
        sub  = zipTvSubst (lp_tvs p) (mkTyVarTys tvs')
        inst t = mapTy todo (substTyUnchecked sub t)
        ys   = [ mkSysLocal (occNameFS (getOccName v)) u ManyTy (inst (idType v))
               | (v, u) <- zip (lp_fields p) uf1 ]
        uf2  = drop (length ys) uf1
        -- The arguments keep the lambda's demands on them, and the lifted
        -- function gets a demand signature built from them: demand analysis
        -- has run already, and CorePrep and worker/wrapper read signatures
        orig_xs = fst (chainLam arity (l_expr l))
        uf3  = drop 3 uf2
        xs'  = [ mkSysLocal (occNameFS (getOccName x0)) u ManyTy (inst t)
                   `setIdDemandInfo` idDemandInfo x0
               | (x0, t, u) <- zip3 orig_xs (lp_args p) uf3 ]
        uf4  = drop arity uf3
        res  = inst (lp_res p)
        cs   = [ mkCoVar (mkSystemName u (mkVarOccFS (fsLit "co")))
                         (mkNomEqPred (mkTyVarTy a) (idType x1))
               | (a, x1, u) <- zip3 aas xs' uf4 ]
        uf5  = drop arity uf4
        cres = mkCoVar (mkSystemName (uf2 !! 1) (mkVarOccFS (fsLit "co")))
                       (mkNomEqPred (mkTyVarTy ab) res)
        webs = map mkWebId (take (length ys + arity) uf5)
        fun_ty = mkSpecForAllTys tvs' $
                 foldr (\(w, t) r -> setFunTyWeb w (mkVisFunTyMany t r)) res
                       (zip webs (map idType (ys ++ xs')))
        fun  = mkSysLocal (mkFastString ("$lam" ++ k ++ "_" ++ show tag)) (uf2 !! 2) ManyTy fun_ty
                 `setIdArity` (length ys + arity)
                 `setIdDmdSig` mkClosedDmdSig (map (const topDmd) ys ++ map idDemandInfo orig_xs)
                                              topDiv

    -- The apply function:  forall a_1 .. a_n b. D_w a_1 .. a_n b -> a_1 -> .. -> a_n -> b
    aas = [ mkTyVar (mkSystemName (u !! 1) (mkTyVarOccFS (fsLit ("a" ++ show j)))) ka
          | (j, ka, u) <- zip3 [1 :: Int ..] kas per_arg ]
    ab = mkTyVar (mkSystemName u_ab (mkTyVarOccFS (fsLit "b"))) kb
    d_ty = mkTyConApp tycon (mkTyVarTys (aas ++ [ab]))
    ws = mkWebId (head (uniqsFromSupply us3)) : [ mkWebId (u !! 3) | u <- per_arg ]
    fd   = mkSysLocal (fsLit "fd") u_fd ManyTy d_ty
    wild = mkSysLocal (fsLit "wild") u_wild ManyTy d_ty
    xs   = [ mkSysLocal (fsLit "x") (u !! 2) ManyTy (mkTyVarTy a) | (a, u) <- zip aas per_arg ]
    apply_ty = mkSpecForAllTys (aas ++ [ab]) $
               foldr (\(w, t) r -> setFunTyWeb w (mkVisFunTyMany t r)) (mkTyVarTy ab)
                     (zip ws (d_ty : mkTyVarTys aas))
    apply = mkSysLocal (mkFastString ("$apply" ++ k)) u_ap ManyTy apply_ty

------------------------------------------------------------------
--      The program
------------------------------------------------------------------

-- | Defunctionalise the webs that qualify.  The Bool says whether to lift
-- the lambdas' bodies (Note [Lifted bodies]) rather than put them in an
-- apply function.  Returns the new program (if anything changed), the new
-- type constructors with their apply functions (if any), and the verdicts.
defuncProgram :: Bool -> Module -> UnfoldingPolicy -> UniqSupply -> WebSet -> CoreProgram
              -> (Maybe (CoreProgram, [(TyCon, Maybe Id)]), [(WebId, SDoc, Bool, [Id])])
defuncProgram lifted this_mod pol us exposed binds
  | isNullUFM todo = (Nothing, dump)
  | lifted
  = ( Just (binds' ++ [Rec [ (lf_id lf, mk_lifted lf body) | (_, lf, body) <- bodies ]]
           , [ (d_tycon d, Nothing) | d <- nonDetEltsUFM todo ])
    , dump )
  | otherwise
  = ( Just (binds' ++ [Rec [ (d_apply d, mk_apply d u) | (u, d) <- nonDetUFMToList todo ]]
           , [ (d_tycon d, Just (d_apply d)) | d <- nonDetEltsUFM todo ])
    , dump )
  where
    (us1, us2) = splitUniqSupply us
    tops  = mkVarSet (bindersOfBinds binds)
    infos = analyse binds
    info w = lookupWithDefaultUFM infos noInfo w

    -- Chains (Note [Defunctionalising whole arities]): w's lambdas all
    -- return lambdas of w2, which has no others, whose calls all apply calls
    -- of w and whose arrow occurs only as the result of w's.  Then w and w2
    -- are defunctionalised together, with calls of arity two (and so on).
    next w
      | lams@(_ : _) <- i_lams (info w)
      , Just w2 : rest <- map (directInner . l_expr) lams
      , all (== Just w2) rest
      , w2 /= w
      , let i2 = info w2
      , not (w2 `elementOfUniqSet` exposed)
      , Nothing <- i_block i2
      , length (i_lams i2) == length lams
      , not (null (i_heads i2)), all (== Just w) (i_heads i2)
      , length (i_heads i2) == length (i_heads (info w))
      , length (i_parents i2) == length (i_occs i2), all (== w) (i_parents i2)
      = Just w2
      | otherwise = Nothing
    chain w = w : maybe [] chain (next w)   -- finite: each web is next of one web at most

    -- Walk each chain from its root: a web whose chain is accepted absorbs
    -- the rest of it; a rejected one leaves the next web to try its own
    has_pred = mkUniqSet [ w2 | (u, _) <- nonDetUFMToList infos, Just w2 <- [next (mkWebId u)] ]
    walk w
      | (Defunc _, _) <- verdict tops exposed (length ch) w (info w)
      = (w, ch) : [ (w2, []) | w2 <- drop 1 ch ]
      | otherwise
      = (w, [w]) : maybe [] walk (next w)
      where ch = chain w
    -- each web's chain if it heads one ([] if absorbed)
    chains = listToUFM (concat [ walk w | (u, _) <- nonDetUFMToList infos
                                        , let w = mkWebId u
                                        , not (w `elementOfUniqSet` has_pred) ])
    chain_of w = lookupWithDefaultUFM chains [w] w

    verdicts0 = [ (w, v, mb, i, ch)
                | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
                , let w = mkWebId u
                , not (null (i_lams i))
                , let ch = chain_of w
                , let (v, mb) | null ch
                              = (NoDefunc "absorbed: called only with the web whose lambdas return it", Nothing)
                              | otherwise
                              = verdict tops exposed (length ch) w i ]

    -- Curried lambdas (Note [Curried lambdas]): a web whose lambdas return
    -- lambdas of another web is defunctionalised only with that web
    -- (for a chain, the lambdas of its last web)
    accepted = fix (mkUniqSet [ w | (w, _, Just _, _, _) <- verdicts0 ])
    fix acc | sizeUniqSet acc' == sizeUniqSet acc = acc
            | otherwise                           = fix acc'
      where acc' = filterUniqSet (\w -> all (inner_ok acc) (lams_of (last (chain_of w)))) acc
    lams_of w = i_lams (info w)
    inner_ok acc l = case innerWeb (l_expr l) of
      Just w2 -> w2 `elementOfUniqSet` acc
      Nothing -> True
    verdicts = [ if isJust mb && not (w `elementOfUniqSet` accepted)
                 then (w, NoDefunc "curried: the web it returns is not defunctionalised", Nothing, i, ch)
                 else (w, v, mb, i, ch)
               | (w, v, mb, i, ch) <- verdicts0 ]
    dump = [ (w, ppr v <+> arity_note mb ch, isJust mb, map l_bndr (i_lams i))
           | (w, v, mb, i, ch) <- verdicts ]
    arity_note mb ch | isJust mb, length ch > 1 = text "arity" <+> int (length ch)
                     | otherwise                = empty

    -- The knot: field types may mention any of the new types
    todo :: UniqFM WebId DWeb
    todo = listToUFM [ (w, mkDWeb this_mod todo u n ch kas kb (i_lams i) plans)
                     | (n, (w, _, Just (kas, kb, plans), i, ch), u)
                         <- zip3 [1 ..] [ v | v@(_, _, Just _, _, _) <- verdicts ]
                                 (listSplitUniqSupply us1) ]

    changed = changedBinders (\ty -> any (`elemUFM` todo) (nonDetEltsUniqSet (typeWebs ty))) binds

    (binds', bodies) = initUs_ us2 (rewrite lifted pol todo changed binds)

    -- $lam_i = /\ds. \ys x1 .. xn. body
    mk_lifted lf body
      = mkLams (lf_tvs lf) $
        foldr (\(w, v) e -> WebLam w v e) body (zip (lf_webs lf) (lf_ys lf ++ lf_xs lf))

    -- $apply_w = /\a1 .. an b. \fd x1 .. xn. case fd of
    --              { C_i ds cs cres ys -> let xij = xj |> cj in body |> sym cres }
    mk_apply d u
      = mkLams (d_atvs d) $
        foldr (\(w, v) e -> WebLam w v e)
          (Case (Var (d_fd d)) (d_wild d) (mkTyVarTy (last (d_atvs d)))
             [ Alt (DataAlt (lf_dc lf)) (lf_tvs lf ++ lf_cs lf ++ [lf_cres lf] ++ lf_ys lf)
                   (Cast (foldr (\(x_i, x, c) e -> bind_x lf x_i (Cast (Var x) (mkSubCo (mkCoVarCo c))) e)
                                body (zip3 (lf_xs lf) (d_xs d) (lf_cs lf)))
                         (mkSubCo (mkSymCo (mkCoVarCo (lf_cres lf)))))
             | (w, lf, body) <- sortOn (\(_, lf, _) -> dataConTag (lf_dc lf)) bodies
             , w == mkWebId u ])
          (zip (d_ws d) (d_fd d : d_xs d))

    bind_x lf x arg body
      | isUnliftedType (idType x) = Case arg x (lf_res lf) [Alt DEFAULT [] body]
      | otherwise                 = Let (NonRec x arg) body

-- | A call spine  f @^w1 a1 .. @^wn an, given the webs innermost last
-- (reversed: wn first); returns f and a1 .. an
callSpine :: [WebId] -> CoreExpr -> Maybe (CoreExpr, [CoreExpr])
callSpine []         e = Just (e, [])
callSpine (w : ws) e = case e of
  WebApp w' f a | w' == w -> do { (g, as) <- callSpine ws f; return (g, as ++ [a]) }
  _                       -> Nothing

-- | The web of the lambda a web lambda returns, if its body is one
innerWeb :: CoreExpr -> Maybe WebId
innerWeb (WebLam _ _ body) = go body
  where
    go e = case e of
      WebLam w2 _ _ -> Just w2
      Lam b e' | not (isId b) -> go e'
      Tick _ e'     -> go e'
      Cast e' _     -> go e'
      _             -> Nothing
innerWeb _ = Nothing

{- Note [Defunctionalising whole arities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
GHC's arrows have no arity, but webs say which curried arrows always go
together.  A web w1 whose lambdas all return lambdas of one web w2,

    \^w1 a. \^w2 x. e

is a chain if w2 has no other lambdas, every call of w2 applies a call of
w1 (no partial application ever escapes), and w2's arrow occurs only as the
result of w1's.  Then the two are defunctionalised together, at arity two:

    A -{w1}-> X -{w2}-> B   ==>   D_w1 A X B
    \^w1 a. \^w2 x. e       ==>   C_i @A @X @B .. <A> <X> <B> vs
    f @^w1 a @^w2 x          ==>   $apply_w1 @A @X @B f a x

and likewise for longer chains (w2 returning w3's lambdas, ...).  The
lambdas stay one constructor each, $apply_w1 takes all the arguments at
once, and the intermediate value the first application returned -- a
constructor of D_w2, allocated at every call when w1 and w2 were
defunctionalised separately -- is gone, with its second dispatch.  In nofib
spectral/constraints, foldTree's  f a (map (foldTree f) cs)  allocated one
per tree node (+2.3% allocation against no defunctionalisation).

The chain stops at the first web that some lambda does not continue into,
or that has partial applications; a longer lambda's remaining lambdas are
another web, defunctionalised on its own (Note [Curried lambdas]).  The
webs of a chain after the first are reported as absorbed.
-}

{- Note [Curried lambdas]
~~~~~~~~~~~~~~~~~~~~~~~~~~
A lambda  \^w a. \^w2 s. e  (a curried function) called with both
arguments is one unknown call of a function of arity two: no allocation.
If w is defunctionalised but w2 is not (say its calls are known), the first
application goes through $apply_w, which returns the inner lambda -- a
closure it allocates at every call -- and the second is an unknown call of
that closure.  In nofib real/eff/CS (a Church-encoded state monad whose
continuations take the state as a second argument) this more than doubled
the instructions.  So such a web is defunctionalised only if w2 is too
(then the first application returns a constructor of D_w2, and the second
is a call of $apply_w2).  Computed as a fixpoint over the verdicts.
-}

{- Note [Lifted bodies]
~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-defunc-lifted, no apply function is made.  Each lambda's
body becomes a top-level function of its free variables and its argument,

    $lam_i = /\ds. \yi1 .. yik x. ei

and each call does the dispatch itself:

    f @^w a   ==>   let x = a in
                    case f of { C_i ds c1 c2 zs -> $lam_i @ds zs (x |> c1) |> sym c2 ; ... }

The case is small, so copying it to every call costs little, and each
alternative is a known call, which GHC inlines body by body.  With an apply
function, the bodies are all inside $apply_w: inlining it copies every body
to every call, and GHC does so only when that is small.  ($lam_i's
argument keeps the lambda's demand on it, and $lam_i a demand signature
built from it, since demand analysis has already run.)
-}

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

-- | The rewritten bodies of the lambdas
type Bodies = [(WebId, LamFun, CoreExpr)]

-- | The rewrite's environment: the new versions of binders, and a type
-- substitution (inside a lambda body, the lambda's free type variables
-- become the lifted function's, or the alternative's)
data Env = Env { e_ids :: VarEnv Id, e_tsub :: Subst }

rewrite :: Bool -> UnfoldingPolicy -> UniqFM WebId DWeb -> VarSet -> CoreProgram
        -> UniqSM (CoreProgram, Bodies)
rewrite lifted pol todo changed binds
  = do { let env0 = Env (mkVarEnv [ (b, fixBndr (mapTy todo (idType b)) b)
                                  | b <- bindersOfBinds binds ]) emptySubst
       ; rs <- mapM (rw_top env0) binds
       ; return (map fst rs, concatMap snd rs) }
  where
    rw_top env (NonRec b e) = do { (e', bs) <- rw env e; return (NonRec (lk env b) e', bs) }
    rw_top env (Rec prs)
      = do { rs <- mapM (\(b, e) -> do { (e', bs) <- rw env e; return ((lk env b, e'), bs) }) prs
           ; return (Rec (map fst rs), concatMap snd rs) }

    lk env v = lookupVarEnv (e_ids env) v `orElse` v

    -- The last web of each chain, to its data type: a call of it is the
    -- end of a whole call spine
    last_webs = listToUFM [ (last (d_chain d), d) | d <- nonDetEltsUFM todo ]
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
    -- often, drop the call structure.  (An absent demand has none.)
    data_dmd d@(n :* _) | isAbs n   = d
                        | otherwise = n :* topSubDmd

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
    fresh_id fs t = do { u <- getUniqueM; return (mkSysLocal fs u ManyTy t) }
    fresh_co t = do { u <- getUniqueM
                    ; return (mkCoVar (mkSystemName u (mkVarOccFS (fsLit "co"))) t) }

    rw :: Env -> CoreExpr -> UniqSM (CoreExpr, Bodies)
    rw env expr = case expr of
      Var v -> return (Var (lk env v), [])
      Lit {} -> return (expr, [])
      Type t -> return (Type (ty env t), [])
      Coercion co -> return (Coercion (substCoUnchecked (e_tsub env) co), [])
      App f a -> do { (f', bs1) <- rw env f; (a', bs2) <- rw env a
                    ; return (App f' a', bs1 ++ bs2) }
      WebApp w f0 a0
        | Just d <- lookupUFM last_webs w
          -- the whole spine  f a1 .. an  (Note [Defunctionalising whole arities])
        , Just (f, as) <- callSpine (reverse (d_chain d)) expr
        -> do { (f', bs1) <- rw env f
              ; rs <- mapM (rw env) as
              ; let fun_ty = sty env (exprType f)
                    (arg_ts, res_t) = case peelArrows (dArity d) (coreFullView fun_ty) of
                      Just (ats, rt) -> (map (mapTy todo) ats, mapTy todo rt)
                      Nothing -> pprPanic "Defunc: call of a non-function" (ppr fun_ty)
                    as' = map fst rs
              ; call <- if lifted then dispatch d f' as' arg_ts res_t
                        else return (foldl (\g (w', a') -> WebApp w' g a')
                                           (mkTyApps (Var (d_apply d)) (arg_ts ++ [res_t]))
                                           (zip (d_ws d) (f' : as')))
              ; return (call, bs1 ++ concatMap snd rs) }
        | otherwise
        -> do { (f', bs1) <- rw env f0; (a', bs2) <- rw env a0
              ; return (WebApp w f' a', bs1 ++ bs2) }
      WebLam w x e
        | Just d <- lookupUFM todo w
        , Just lf <- lookupUFM (d_lams d) x
        -> do { -- The body, over the lifted function's parameters
                -- (Note [Defunctionalisation], Note [Lifted bodies])
                let p = lf_plan lf
                    (xs, body) = chainLam (dArity d) (WebLam w x e)
                    body_env = Env (extendVarEnvList (e_ids env)
                                      (zip xs (lf_xs lf) ++ zip (lp_fields p) (lf_ys lf)))
                                   (zipTvSubst (lp_tvs p) (mkTyVarTys (lf_tvs lf)))
              ; (e', bs) <- rw body_env body
                -- The constructor, where the lambda was
              ; let args_l = map (ty env) (lp_args p)
                    res_l = ty env (lp_res p)
                    con0  = mkTyApps (Var (dataConWorkId (lf_dc lf)))
                                     (args_l ++ [res_l] ++ map (ty env . mkTyVarTy) (lp_tvs p))
                    con1  = foldl (\f co -> WebApp placeholderWeb f (Coercion co)) con0
                                  (map mkNomReflCo (args_l ++ [res_l]))
                    con   = foldl (\f v -> WebApp placeholderWeb f (Var (lk env v))) con1 (lp_fields p)
              ; return (con, (w, lf, e') : bs) }
        | otherwise
        -> do { (env', x') <- bndr env x; (e', bs) <- rw env' e
              ; return (WebLam w x' e', bs) }
      Lam b e -> do { (env', b') <- bndr env b; (e', bs) <- rw env' e
                    ; return (Lam b' e', bs) }
      Let (NonRec b rhs) body
        -> do { (rhs', bs1) <- rw env rhs
              ; (env', b') <- bndr env b
              ; (body', bs2) <- rw env' body
              ; return (Let (NonRec b' rhs') body', bs1 ++ bs2) }
      Let (Rec prs) body
        -> do { (env', bs') <- bndrs env (map fst prs)
              ; rs <- mapM (rw env' . snd) prs
              ; (body', bs2) <- rw env' body
              ; return ( Let (Rec (zip bs' (map fst rs))) body'
                       , concatMap snd rs ++ bs2 ) }
      Case scrut b t alts
        -> do { (scrut', bs1) <- rw env scrut
              ; (env', b') <- bndr env b
              ; rs <- forM alts $ \(Alt c bs rhs) ->
                        do { (env'', bs') <- bndrs env' bs
                           ; (rhs', bds) <- rw env'' rhs
                           ; return (Alt c bs' rhs', bds) }
              ; return (Case scrut' b' (ty env t) (map fst rs), bs1 ++ concatMap snd rs) }
      Cast e co -> do { (e', bs) <- rw env e
                      ; return (Cast e' (substCoUnchecked (e_tsub env) co), bs) }
      Tick t e  -> do { (e', bs) <- rw env e; return (Tick (rw_tick env t) e', bs) }

    -- A call, with the dispatch in place (Note [Lifted bodies]):
    --   let x = a in case f of { C_i ds c1 c2 zs -> $lam_i @ds zs (x |> c1) |> sym c2 ; .. }
    dispatch d f as arg_ts res_t
      = do { bound <- forM (zip as arg_ts) $ \(a, arg_t) ->
               if exprIsTrivial (stripWebForms a) then return (id, a)
               else do { x0 <- fresh_id (fsLit "x") arg_t
                       ; let b | isUnliftedType arg_t
                               = \e -> Case a x0 res_t [Alt DEFAULT [] e]
                               | otherwise
                               = \e -> Let (NonRec x0 a) e
                       ; return (b, Var x0) }
           ; let bind e = foldr fst e bound
                 args0  = map snd bound
           ; scrut_b <- fresh_id (fsLit "wild") (mkTyConApp (d_tycon d) (arg_ts ++ [res_t]))
           ; alts <- forM (d_order d) $ \lf ->
               do { exs <- mapM fresh_tv (lf_tvs lf)
                  ; let s = zipTvSubst (lf_tvs lf) (mkTyVarTys exs)
                        inst = substTyUnchecked s
                        res_i = inst (lf_res lf)
                  ; cs <- forM (zip arg_ts (lf_xs lf)) $ \(arg_t, x) ->
                            fresh_co (mkNomEqPred arg_t (inst (idType x)))
                  ; cres <- fresh_co (mkNomEqPred res_t res_i)
                  ; zs <- mapM (\y -> fresh_id (occNameFS (getOccName y)) (inst (idType y))) (lf_ys lf)
                  ; let args = map Var zs ++ [ Cast a (mkSubCo (mkCoVarCo c)) | (a, c) <- zip args0 cs ]
                        call = foldl (\g (w, v) -> WebApp w g v)
                                     (mkTyApps (Var (lf_id lf)) (mkTyVarTys exs))
                                     (zip (lf_webs lf) args)
                  ; return (Alt (DataAlt (lf_dc lf)) (exs ++ cs ++ [cres] ++ zs)
                                (Cast call (mkSubCo (mkSymCo (mkCoVarCo cres))))) }
           ; return (bind (Case f scrut_b res_t alts)) }

    rw_tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lk env) ids }
    rw_tick _ t = t
