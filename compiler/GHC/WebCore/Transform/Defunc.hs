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
    -- exprFreeVars does not look into the types of free variables, and a
    -- field's type can mention a type variable the body does not
    tycovars l = fvs l `unionVarSet`
                 tyCoVarsOfTypes (map idType (fields l) ++ [arg_ty l, res_ty l])
    tyvars l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (tycovars l), isTyVar v ]

    lam_problem l
      | any isCoVar (nonDetEltsUniqSet (tycovars l)) = Just "free coercion variables"
      | isCoVar (l_bndr l)                       = Just "coercion parameter"
      | not (all ok_field (fields l))            = Just "unsuitable free variable"
      | not (all (closed . tyVarKind) (tyvars l)) = Just "kind-polymorphic"
      | otherwise                                = Nothing

    ok_field v = let t = idType v
                 in typeHasFixedRuntimeRep t && not (isUnboxedTupleType t)
                    && not (isUnboxedSumType t) && not (isJoinId v)

    plan l = LamPlan (fields l) (tyvars l) (arg_ty l) (res_ty l)
    arg_ty l = idType (l_bndr l)
    res_ty l = exprType (lam_body (l_expr l))
    lam_body (WebLam _ _ e) = e
    lam_body e              = e

    firstJust (Just x : _) = Just x
    firstJust (_ : xs)     = firstJust xs
    firstJust []           = Nothing

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
  , lf_x    :: Id           -- ^ its parameter, renamed
  , lf_res  :: Type         -- ^ its result type
  , lf_webs :: [WebId]      -- ^ the webs of $lam_i's arrows
  , lf_c1   :: CoVar        -- ^ in $apply_w's alternative:  a ~# A_i
  , lf_c2   :: CoVar        -- ^                             b ~# B_i
  }

-- | What we build for a web
data DWeb = DWeb
  { d_tycon :: TyCon
  , d_lams  :: UniqFM Id LamFun   -- ^ lambda binder -> its constructor and body
  , d_order :: [LamFun]           -- ^ in constructor order
  , d_apply :: Id                 -- ^ $apply_w (unless the bodies are lifted)
  , d_atvs  :: [TyVar]            -- ^ its type parameters, a and b
  , d_fd    :: Id                 -- ^ its first parameter (D_w a b)
  , d_x     :: Id                 -- ^ its second parameter (a)
  , d_w1    :: WebId              -- ^ the webs of its arrows
  , d_w2    :: WebId
  , d_wild  :: Id                 -- ^ the case binder in $apply_w
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

-- | Make the data type, constructors, lifted bodies and apply function of a
-- web.  Lazy in 'todo' (field types may mention other new types): see the
-- knot in 'defuncProgram'
mkDWeb :: Module -> UniqFM WebId DWeb -> UniqSupply -> Int -> Kind -> Kind -> [Lam] -> [LamPlan]
       -> DWeb
mkDWeb this_mod todo us n ka kb lams plans
  = DWeb { d_tycon = tycon
         , d_lams  = listToUFM (zip (map l_bndr lams) funs)
         , d_order = funs
         , d_apply = apply, d_atvs = [aa, ab], d_fd = fd, d_x = x, d_w1 = w1, d_w2 = w2
         , d_wild = wild }
  where
    k = show n
    (us1, us23) = splitUniqSupply us
    (us2, us3)  = splitUniqSupply us23
    uniqs = uniqsFromSupply us1
    nth i = uniqs !! i
    (u_tc, u_ta, u_tb, u_ap, u_fd)    = (nth 0, nth 1, nth 2, nth 3, nth 4)
    (u_x, u_w1, u_w2, u_wild, u_aa)   = (nth 5, nth 6, nth 7, nth 8, nth 9)
    u_ab = nth 10

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

    -- The bodies:  $lam_i :: forall ds. t_i1 -> .. -> t_ik -> A_i -> B_i
    funs = [ mk_fun tag l p dc us_f
           | (tag, l, p, dc, us_f) <- zip5 [1 :: Int ..] lams plans cons (listSplitUniqSupply us3) ]

    mk_fun tag l p dc us_f
      = LamFun { lf_dc = dc, lf_plan = p, lf_id = fun, lf_tvs = tvs', lf_ys = ys, lf_x = x'
               , lf_res = res, lf_webs = webs, lf_c1 = c1, lf_c2 = c2 }
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
        -- The argument keeps the lambda's demand on it, and the lifted
        -- function gets a demand signature built from it: demand analysis
        -- has run already, and CorePrep and worker/wrapper read signatures
        x'   = mkSysLocal (occNameFS (getOccName (l_bndr l))) (uf2 !! 0) ManyTy (inst (lp_arg p))
                 `setIdDemandInfo` idDemandInfo (l_bndr l)
        res  = inst (lp_res p)
        c1   = mkCoVar (mkSystemName (uf2 !! 1) (mkVarOccFS (fsLit "co")))
                       (mkNomEqPred (mkTyVarTy aa) (idType x'))
        c2   = mkCoVar (mkSystemName (uf2 !! 2) (mkVarOccFS (fsLit "co")))
                       (mkNomEqPred (mkTyVarTy ab) res)
        webs = map mkWebId (take (length ys + 1) (drop 4 uf2))
        fun_ty = mkSpecForAllTys tvs' $
                 foldr (\(w, t) r -> setFunTyWeb w (mkVisFunTyMany t r)) res
                       (zip webs (map idType (ys ++ [x'])))
        fun  = mkSysLocal (mkFastString ("$lam" ++ k ++ "_" ++ show tag)) (uf2 !! 3) ManyTy fun_ty
                 `setIdArity` (length ys + 1)
                 `setIdDmdSig` mkClosedDmdSig (map (const topDmd) ys ++ [idDemandInfo (l_bndr l)])
                                              topDiv

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

    (binds', bodies) = initUs_ us2 (rewrite lifted pol todo changed binds)

    -- $lam_i = /\ds. \ys x. body
    mk_lifted lf body
      = mkLams (lf_tvs lf) $
        foldr (\(w, v) e -> WebLam w v e) body (zip (lf_webs lf) (lf_ys lf ++ [lf_x lf]))

    -- $apply_w = /\a b. \fd x. case fd of { C_i ds c1 c2 ys -> let xi = x |> c1 in body |> sym c2 }
    mk_apply d u
      = mkLams (d_atvs d) $
        WebLam (d_w1 d) (d_fd d) $ WebLam (d_w2 d) (d_x d) $
        Case (Var (d_fd d)) (d_wild d) (mkTyVarTy (d_atvs d !! 1))
             [ Alt (DataAlt (lf_dc lf)) (lf_tvs lf ++ [lf_c1 lf, lf_c2 lf] ++ lf_ys lf)
                   (Cast (bind_x lf (Cast (Var (d_x d)) (mkSubCo (mkCoVarCo (lf_c1 lf)))) body)
                         (mkSubCo (mkSymCo (mkCoVarCo (lf_c2 lf)))))
             | (w, lf, body) <- sortOn (\(_, lf, _) -> dataConTag (lf_dc lf)) bodies
             , w == mkWebId u ]

    bind_x lf arg body
      | isUnliftedType (idType (lf_x lf)) = Case arg (lf_x lf) (lf_res lf) [Alt DEFAULT [] body]
      | otherwise                         = Let (NonRec (lf_x lf) arg) body

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
      WebApp w f a
        | Just d <- lookupUFM todo w
        -> do { (f', bs1) <- rw env f; (a', bs2) <- rw env a
              ; let fun_ty = sty env (exprType f)
                    (arg_t, res_t) = case coreFullView fun_ty of
                      FunTy { ft_arg = at, ft_res = rt } -> (mapTy todo at, mapTy todo rt)
                      t -> pprPanic "Defunc: call of a non-function" (ppr t)
              ; call <- if lifted then dispatch d f' a' arg_t res_t
                        else return (WebApp (d_w2 d)
                                       (WebApp (d_w1 d) (mkTyApps (Var (d_apply d)) [arg_t, res_t]) f')
                                       a')
              ; return (call, bs1 ++ bs2) }
        | otherwise
        -> do { (f', bs1) <- rw env f; (a', bs2) <- rw env a
              ; return (WebApp w f' a', bs1 ++ bs2) }
      WebLam w x e
        | Just d <- lookupUFM todo w
        , Just lf <- lookupUFM (d_lams d) x
        -> do { -- The body, over the lifted function's parameters
                -- (Note [Defunctionalisation], Note [Lifted bodies])
                let p = lf_plan lf
                    body_env = Env (extendVarEnvList (e_ids env) ((x, lf_x lf) : zip (lp_fields p) (lf_ys lf)))
                                   (zipTvSubst (lp_tvs p) (mkTyVarTys (lf_tvs lf)))
              ; (e', bs) <- rw body_env e
                -- The constructor, where the lambda was
              ; let arg_l = ty env (lp_arg p)
                    res_l = ty env (lp_res p)
                    con0  = mkTyApps (Var (dataConWorkId (lf_dc lf)))
                                     ([arg_l, res_l] ++ map (ty env . mkTyVarTy) (lp_tvs p))
                    con1  = foldl (\f co -> WebApp placeholderWeb f (Coercion co)) con0
                                  [mkNomReflCo arg_l, mkNomReflCo res_l]
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
    dispatch d f a arg_t res_t
      = do { (bind, arg) <- if exprIsTrivial (stripWebForms a) then return (id, a)
                            else do { x0 <- fresh_id (fsLit "x") arg_t
                                    ; let b | isUnliftedType arg_t
                                            = \e -> Case a x0 res_t [Alt DEFAULT [] e]
                                            | otherwise
                                            = \e -> Let (NonRec x0 a) e
                                    ; return (b, Var x0) }
           ; scrut_b <- fresh_id (fsLit "wild") (mkTyConApp (d_tycon d) [arg_t, res_t])
           ; alts <- forM (d_order d) $ \lf ->
               do { exs <- mapM fresh_tv (lf_tvs lf)
                  ; let s = zipTvSubst (lf_tvs lf) (mkTyVarTys exs)
                        inst = substTyUnchecked s
                        arg_i = inst (idType (lf_x lf))
                        res_i = inst (lf_res lf)
                  ; c1 <- fresh_co (mkNomEqPred arg_t arg_i)
                  ; c2 <- fresh_co (mkNomEqPred res_t res_i)
                  ; zs <- mapM (\y -> fresh_id (occNameFS (getOccName y)) (inst (idType y))) (lf_ys lf)
                  ; let args = map Var zs ++ [Cast arg (mkSubCo (mkCoVarCo c1))]
                        call = foldl (\g (w, v) -> WebApp w g v)
                                     (mkTyApps (Var (lf_id lf)) (mkTyVarTys exs))
                                     (zip (lf_webs lf) args)
                  ; return (Alt (DataAlt (lf_dc lf)) (exs ++ [c1, c2] ++ zs)
                                (Cast call (mkSubCo (mkSymCo (mkCoVarCo c2))))) }
           ; return (bind (Case f scrut_b res_t alts)) }

    rw_tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lk env) ids }
    rw_tick _ t = t
