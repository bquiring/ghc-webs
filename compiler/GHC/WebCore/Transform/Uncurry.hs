-- | Uncurrying over webs.
--
-- See Note [Uncurrying] and WEBS-UNCURRYING.md.
module GHC.WebCore.Transform.Uncurry
  ( uncurryRound
  ) where

import GHC.Prelude

import GHC.Builtin.Types ( mkTupleTy, tupleDataCon, tupleTyCon, manyDataConTy )
import GHC.Core
import GHC.Core.Coercion
import GHC.Core.DataCon ( isUnboxedTupleDataCon )
import GHC.Core.Make ( mkCoreUnboxedTuple )
import GHC.Core.TyCo.Rep
import GHC.Core.Type
import GHC.Core.Utils ( exprType, exprIsTrivial, exprIsHNF )
import GHC.Types.Demand ( isStrUsedDmd )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Basic ( Boxity(..), TypeOrConstraint(..) )
import GHC.Types.Id
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Data.Pair
import GHC.Utils.Outputable
import GHC.Utils.Panic

import GHC.WebCore.Transform.ArityRaise ( knownHead )
import GHC.WebCore.Transform.Common
import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )
import Data.Maybe ( fromMaybe )

{- Note [Uncurrying]
~~~~~~~~~~~~~~~~~~~~
A web w1 whose lambdas are all directly lambdas of a web w2,
    \^w1 a. \^w2 b. e
is uncurried:
    A -{w1}-> (B -{w2}-> C)   becomes   (# A, B #) -{w1}-> C
    \^w1 a. \^w2 b. e         becomes   \^w1 t. case t of (# a, b #) -> e
    (f @^w1 x) @^w2 y         becomes   f @^w1 (# x, y #)
    f @^w1 x  (partial)       becomes   case f of g { __DEFAULT ->
                                          let v = x in \^w2 b. g @^w1 (# v, b #) }
The unboxed-tuple argument encodes a two-argument arrow that must be fully
applied: Unarise turns it into two arguments.

At a saturated call, a component that every lambda of the web is strict in
is evaluated first:  case x of x' -> f @^w1 (# x', y #).  The callee would
force it anyway, and it restores call-by-value, which CorePrep would have
done from the callee's demand signature for an ordinary argument but does not
do for the components of an unboxed tuple (see Note [Demand signatures after
a transformation] in GHC.WebCore.Transform.Common, and Note [No early
uncurrying] in GHC.WebCore.Pipeline).  The partial application is
eta-expanded; the argument is let-bound so that it is evaluated at most once
(or case-bound if unlifted), and the function is evaluated first, exactly as
the original partial application would.  Only w1's arrows change; w2's
arrows elsewhere (e.g. the types of partial applications) are unchanged.

Laziness and sharing (see WEBS-UNCURRYING.md §2) are why every w1 lambda must
be directly a w2 lambda: work between them would no longer be shared by
partial applications, and a partial application that used to diverge would
become a lambda.  "Directly" allows only cases on unboxed tuples bound by
earlier uncurrying, which cost nothing: that is how chains of three or more
lambdas are uncurried over several rounds.

A web is rejected if it is exposed, if some w1 arrow's result is not an arrow
(e.g. hidden behind a type variable), if A or B has no fixed representation,
if it appears in a coercion we cannot rewrite, or if some lambda binds a
coercion variable.  In one round, a web is not uncurried if it is the inner
web of another web being uncurried; it can be uncurried in the next round.
-}

data Verdict = Uncurried
             | Rejected Reason

data Reason = Exposed | NotDirect | HiddenResult | RepPoly | Coercion' | CoVarParam
            | ConstraintArg | JoinResult | KnownCalls

instance Outputable Verdict where
  ppr Uncurried    = text "uncurried"
  ppr (Rejected r) = text "rejected" <+> parens (ppr r)

instance Outputable Reason where
  ppr Exposed      = text "exposed"
  ppr NotDirect    = text "not directly a lambda"
  ppr KnownCalls   = text "only known calls (left to GHC)"
  ppr HiddenResult = text "result not an arrow"
  ppr RepPoly      = text "representation-polymorphic argument"
  ppr Coercion'    = text "complex coercion"
  ppr CoVarParam   = text "coercion parameter"
  ppr ConstraintArg = text "constraint argument"
  ppr JoinResult = text "join point returns a function"

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Info = Info
  { i_lams       :: [Id]
  , i_inner      :: WebSet  -- Webs of the inner lambdas
  , i_not_direct :: Bool
  , i_covar      :: Bool
  , i_hidden     :: Bool
  , i_rep_poly   :: Bool
  , i_coercion   :: Bool
  , i_constraint :: Bool    -- An argument is a constraint (a dictionary)
  , i_join_res   :: Bool    -- A lambda is the last of a join point's lambdas
  , i_lazy_a     :: Bool    -- Some lambda is lazy in its first parameter
  , i_lazy_b     :: Bool    -- Some lambda is lazy in its second parameter
  , i_unknown    :: Bool }  -- Some call of the web is not a known call

noInfo :: Info
noInfo = Info [] emptyUniqSet False False False False False False False False False False

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams       = i_lams a ++ i_lams b
                    , i_inner      = i_inner a `unionUniqSets` i_inner b
                    , i_not_direct = i_not_direct a || i_not_direct b
                    , i_covar      = i_covar a      || i_covar b
                    , i_hidden     = i_hidden a     || i_hidden b
                    , i_rep_poly   = i_rep_poly a   || i_rep_poly b
                    , i_coercion   = i_coercion a   || i_coercion b
                    , i_constraint = i_constraint a || i_constraint b
                    , i_join_res   = i_join_res a   || i_join_res b
                    , i_lazy_a     = i_lazy_a a     || i_lazy_a b
                    , i_lazy_b     = i_lazy_b a     || i_lazy_b b
                    , i_unknown    = i_unknown a    || i_unknown b }

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

-- | Peel the unboxed-tuple cases that earlier rounds put between two lambdas,
-- and find the inner lambda.  Returns the cases (scrutinee, case binder,
-- data constructor, binders, result type) from the outside in.
type Frame = (Var, Id, AltCon, [Var])

innerLam :: CoreExpr -> Maybe ([Frame], WebId, Id, CoreExpr)
innerLam = go []
  where
    go frames (WebLam w b e) = Just (reverse frames, w, b, e)
    go frames (Case (Var x) wild _ [Alt con@(DataAlt dc) bs rhs])
      | isUnboxedTupleDataCon dc
      = go ((x, wild, con, bs) : frames) rhs
    go _ _ = Nothing

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | JoinPoint arity <- idJoinPointHood b = go_join arity e acc
      | otherwise                            = go e acc

    -- A join point's lambdas.  Jumps supply exactly the join arity's
    -- arguments, so a web whose lambda is the last of them cannot be
    -- uncurried: the jumps would become partial applications of the join
    -- point, which cannot be eta-expanded (a join point is not a value).
    go_join :: Int -> CoreExpr -> Infos -> Infos
    go_join 0 e acc = go e acc
    go_join n (Lam b e) acc = go_bndr b (go_join (n-1) e acc)
    go_join n (WebLam w a e) acc
      = go_lam (n == 1) w a e (go_join (n-1) e acc)
    go_join _ e acc = go e acc

    go_lam last_join w a e acc
      = go_bndr a $
        note w (case innerLam e of
                  Just (_, w2, b, _) -> noInfo { i_lams = [a], i_inner = unitUniqSet w2
                                               , i_covar = isCoVar a
                                               , i_join_res = last_join
                                               , i_lazy_a = not (isStrUsedDmd (idDemandInfo a))
                                               , i_lazy_b = not (isStrUsedDmd (idDemandInfo b))
                                                 -- The binders become the components
                                                 -- of an unboxed tuple; the arrow
                                                 -- types may not be visible anywhere
                                               , i_constraint = not (isTypeLike (idType a)
                                                                     && isTypeLike (idType b))
                                               , i_rep_poly = not (typeHasFixedRuntimeRep (idType a)
                                                                   && typeHasFixedRuntimeRep (idType b)) }
                  Nothing            -> noInfo { i_lams = [a], i_not_direct = True
                                               , i_covar = isCoVar a }) acc

    go :: CoreExpr -> Infos -> Infos
    go (Var {}) acc = acc
    go (Lit {}) acc = acc
    go (App f (Type t)) acc = go f (go_ty t acc)
    go (App f a) acc = go f (go a acc)
    go (WebApp w f a) acc
      | knownHead f = go f (go a acc)
      | otherwise   = note w (noInfo { i_unknown = True }) (go f (go a acc))
    go (Lam b e) acc = go_bndr b (go e acc)
    go (WebLam w a e) acc = go_lam False w a e (go e acc)
    go (Let bind body) acc = go_bind bind (go body acc)
    go (Case scrut b ty alts) acc
      = go scrut $ go_bndr b $ go_ty ty $
        foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
    go (Cast e co) acc = go e (go_co co acc)
    go (Tick _ e) acc = go e acc
    go (Type t) acc = go_ty t acc
    go (Coercion co) acc = go_co co acc

    go_bndr b acc
      | isId b    = go_ty (idType b) acc
      | otherwise = acc

    -- Every arrow of a web must have an arrow result, and arguments with a
    -- fixed representation
    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        -> let acc' = go_ty a (go_ty r acc)
           in case coreFullView r of
                FunTy { ft_arg = b }
                  | not (isTypeLike a && isTypeLike b)
                  -> note w (noInfo { i_constraint = True }) acc'
                  | typeHasFixedRuntimeRep a, typeHasFixedRuntimeRep b -> acc'
                  | otherwise -> note w (noInfo { i_rep_poly = True }) acc'
                _ -> note w (noInfo { i_hidden = True }) acc'
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t co    -> go_ty t (go_co co acc)
      CoercionTy co  -> go_co co acc
      _              -> acc

    go_co :: Coercion -> Infos -> Infos
    go_co co acc = case co of
      Refl t                 -> go_ty t acc
      GRefl _ t _            -> go_ty t acc
      TyConAppCo _ _ cos     -> foldr go_co acc cos
      AppCo c1 c2            -> go_co c1 (go_co c2 acc)
      ForAllCo { fco_body = c } -> go_co c acc
      FunCo { fco_web = w, fco_arg = c1, fco_res = c2 }
        | Nothing <- splitInnerCo c2
        -> note w (noInfo { i_coercion = True }) (go_co c1 (go_co c2 acc))
        | otherwise
        -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      _                      -> acc   -- complexCoWebs deals with the others

-- | Can this type be a component of an unboxed tuple?  Constraints
-- (dictionaries) cannot: the components must have kind TYPE r.
isTypeLike :: Type -> Bool
isTypeLike ty = typeTypeOrConstraint ty == TypeLike

-- | Split the coercion between the results of an uncurried arrow into the
-- coercions between the inner arrow's argument and result
splitInnerCo :: Coercion -> Maybe (Coercion, Coercion)
splitInnerCo co = case co of
  FunCo { fco_arg = cb, fco_res = cc } -> Just (cb, cc)
  Refl t | FunTy { ft_arg = b, ft_res = c } <- coreFullView t
         -> Just (mkNomReflCo b, mkNomReflCo c)
  GRefl r t MRefl | FunTy { ft_arg = b, ft_res = c } <- coreFullView t
         -> Just (mkReflCo r b, mkReflCo r c)
  _ -> Nothing

{- Note [Uncurrying known calls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A web whose calls are all known calls is not uncurried.  GHC already makes a
known saturated call of a curried function a direct call with all its
arguments; uncurrying such a web (typically worker/wrapper's workers, in the
late run) gains nothing and, on nofib, cost up to a third more instructions
(shootout/binary-trees +34%, spectral/fft2 +30%: all of the late run's big
regressions).  Arity and result raising leave such webs to GHC in the same
way (Note [Early arity raising] in GHC.WebCore.Transform.ArityRaise).
-fcore-webs-uncurry-known uncurries them anyway (the uncurrying tests use
it, to exercise the rewrite).
-}

verdict :: Bool -> WebSet -> WebSet -> WebId -> Info -> Verdict
verdict known_ok exposed complex w i
  | w `elementOfUniqSet` exposed = Rejected Exposed
  | i_covar i                    = Rejected CoVarParam
  | w `elementOfUniqSet` complex = Rejected Coercion'
  | i_coercion i                 = Rejected Coercion'
  | i_hidden i                   = Rejected HiddenResult
  | i_join_res i                 = Rejected JoinResult
  | i_constraint i               = Rejected ConstraintArg
  | i_rep_poly i                 = Rejected RepPoly
  | i_not_direct i               = Rejected NotDirect
  | not known_ok, not (i_unknown i) = Rejected KnownCalls -- Note [Uncurrying known calls]
  | otherwise                    = Uncurried

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse the program and uncurry the webs that qualify.  Returns Nothing
-- if nothing changed, and the verdicts (for the dump).
uncurryRound :: Bool        -- ^ uncurry webs with only known calls too
             -> UniqSupply
             -> WebSet      -- ^ Exposed webs
             -> UnfoldingPolicy
             -> CoreProgram
             -> (Maybe (CoreProgram, Type -> Type), [(WebId, SDoc, Bool, [Id])])
uncurryRound known_ok us exposed pol binds
  | isEmptyUniqSet todo = (Nothing, dump)
  | otherwise           = (Just (initUs_ us (rewriteProgram todo strict pol binds), uncurryType todo), dump)
  where
    infos   = analyse binds
    complex = complexCoWebs binds
    verdicts = [ (mkWebId u, verdict known_ok exposed complex (mkWebId u) i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , not (null (i_lams i)) ]
    candidates = mkUniqSet [ w | (w, Uncurried, _) <- verdicts ]
    -- Uncurry the outer web of a chain first; see Note [Uncurrying]
    inners = unionManyUniqSets [ i_inner i | (w, Uncurried, i) <- verdicts
                                           , w `elementOfUniqSet` candidates ]
    todo = candidates `minusUniqSet` inners
    -- Whether all the lambdas of a web are strict in each parameter
    strict = listToUFM [ (w, (not (i_lazy_a i), not (i_lazy_b i)))
                       | (w, Uncurried, i) <- verdicts, w `elementOfUniqSet` todo ]
    dump = [ (w, if deferred then text "deferred (inner web)" else ppr v
               , w `elementOfUniqSet` todo, i_lams i)
           | (w, v, i) <- verdicts
           , let deferred = w `elementOfUniqSet` inners && w `elementOfUniqSet` candidates ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

type Env = IdEnv Id

-- | The new type of an uncurried web's arrows
uncurryType :: WebSet -> Type -> Type
uncurryType todo = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        | w `elementOfUniqSet` todo
        , FunTy { ft_arg = b, ft_res = c } <- coreFullView r
        -> let tup = mkTupleTy Unboxed [go a, go b]
               c'  = go c
           in mkWebFunTy w (chooseFunTyFlag tup c') manyDataConTy tup c'
        | otherwise -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) (uncurryCo todo co)
      CoercionTy co   -> CoercionTy (uncurryCo todo co)
      _               -> ty

uncurryCo :: WebSet -> Coercion -> Coercion
uncurryCo todo = go
  where
    goTy = uncurryType todo
    go co = case co of
      Refl t              -> Refl (goTy t)
      GRefl r t mco       -> GRefl r (goTy t) mco
      TyConAppCo r tc cos -> TyConAppCo r tc (map go cos)
      AppCo c1 c2         -> AppCo (go c1) (go c2)
      ForAllCo { fco_body = c } -> co { fco_body = go c }
      FunCo { fco_role = r, fco_web = w, fco_arg = ca, fco_res = cr }
        | w `elementOfUniqSet` todo
        , Just (cb, cc) <- splitInnerCo cr
        -> let ca' = go ca; cb' = go cb; cc' = go cc
               rep c = mkNomReflCo (getRuntimeRep (coercionLKind c))
               tup = mkTyConAppCo r (tupleTyCon Unboxed 2) [rep ca', rep cb', ca', cb']
               Pair lt rt = coercionKind tup
               Pair lc rc = coercionKind cc'
           in mkWebFunCo2 w r (chooseFunTyFlag lt lc) (chooseFunTyFlag rt rc)
                          (mkNomReflCo manyDataConTy) tup cc'
        | otherwise -> co { fco_arg = go ca, fco_res = go cr }
      AxiomCo ax cos      -> AxiomCo ax (map go cos)
      SymCo c             -> SymCo (go c)
      TransCo c1 c2       -> TransCo (go c1) (go c2)
      SubCo c             -> SubCo (go c)
      _                   -> co

rewriteProgram :: WebSet
               -> UniqFM WebId (Bool, Bool) -- ^ Strict in each parameter?
               -> UnfoldingPolicy -> CoreProgram -> UniqSM CoreProgram
rewriteProgram todo strict pol binds
  = do { let env = mkVarEnv [ (b, rw_bndr b) | b <- bindersOfBinds binds ]
       ; mapM (rw_top env) binds }
  where
    upTy = uncurryType todo
    upCo = uncurryCo todo
    is_todo w = w `elementOfUniqSet` todo

    rw_top env (NonRec b e) = NonRec (lookup_bndr env b) <$> rw env e
    rw_top env (Rec prs)    = Rec <$> sequence [ (,) (lookup_bndr env b) <$> rw env e
                                               | (b, e) <- prs ]

    lookup_bndr env v = fromMaybe v (lookupVarEnv env v)

    -- A binder with its type and IdInfo fixed up
    rw_bndr :: Var -> Var
    rw_bndr b
      | not (isId b) = b
      | not (changed old_ty) = fixUnfolding pol changed_set b
      | otherwise = fixUnfolding pol changed_set $
                    fixBinderInfo b new_ty (\is_join n -> n - uncurried is_join n old_ty)
                                 (argFates (\w r -> if is_todo w && isFunTy r then MergeWithNext else KeepArg) old_ty)
      where
        old_ty = idType b
        new_ty = upTy old_ty

    -- See Note [Unfoldings and rules after a transformation]
    -- in GHC.WebCore.Transform.Common
    changed_set = changedBinders changed binds

    changed ty = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r } -> is_todo w || changed a || changed r
      TyConApp _ tys -> any changed tys
      AppTy t1 t2    -> changed t1 || changed t2
      ForAllTy _ t   -> changed t
      CastTy t _     -> changed t
      _              -> False

    -- How many arguments among the first n are merged by uncurrying?
    uncurried :: Bool -> Int -> Type -> Int
    uncurried count_foralls = go_n
      where
        go_n 0 _ = 0
        go_n n ty
          | Just ty' <- coreView ty = go_n n ty'
        go_n n (ForAllTy _ ty)
          | count_foralls = go_n (n-1) ty
          | otherwise     = go_n n ty
        go_n n (FunTy { ft_web = w, ft_res = r })
          | is_todo w, n >= 2, FunTy { ft_res = c } <- coreFullView r = 1 + go_n (n-2) c
          | otherwise = go_n (n-1) r
        go_n _ _ = 0

    rw_bndr1 env b = (extendVarEnv env b b', b') where b' = rw_bndr b

    rw_bndrs env bs = (extendVarEnvList env (zip bs bs'), bs')
      where bs' = map rw_bndr bs

    ---------------
    rw :: Env -> CoreExpr -> UniqSM CoreExpr
    rw env expr = case expr of
      Var v        -> return (Var (lookup_bndr env v))
      Lit l        -> return (Lit l)
      App {}       -> do { (wrap, e') <- rw_spine env expr; return (wrap e') }
      WebApp {}    -> do { (wrap, e') <- rw_spine env expr; return (wrap e') }
      Lam b e      -> let (env', b') = rw_bndr1 env b in Lam b' <$> rw env' e

      WebLam w a body
        | is_todo w, Just (frames, w2, b, e) <- innerLam body
        -> rw_uncurried_lam env w a frames w2 b e
        | otherwise
        -> let (env', a') = rw_bndr1 env a in WebLam w a' <$> rw env' body

      Let (NonRec b rhs) body
        -> do { rhs' <- rw env rhs
              ; let (env', b') = rw_bndr1 env b
              ; Let (NonRec b' rhs') <$> rw env' body }
      Let (Rec prs) body
        -> do { let (env', bs') = rw_bndrs env (map fst prs)
              ; rhss' <- mapM (rw env' . snd) prs
              ; Let (Rec (zip bs' rhss')) <$> rw env' body }

      Case scrut b ty alts
        -> do { scrut' <- rw env scrut
              ; let (env', b') = rw_bndr1 env b
              ; alts' <- sequence [ Alt con bs' <$> rw env'' rhs
                                  | Alt con bs rhs <- alts
                                  , let (env'', bs') = rw_bndrs env' bs ]
              ; return (Case scrut' b' (upTy ty) alts') }

      Cast e co    -> (\e' -> Cast e' (upCo co)) <$> rw env e
      Tick t e     -> Tick (rw_tick env t) <$> rw env e
      Type t       -> return (Type (upTy t))
      Coercion co  -> return (Coercion (upCo co))

    -- An application spine.  Returns a wrapper (the cases that evaluate
    -- strict components, which must wrap the whole spine so that a jump
    -- stays in tail position) and the call.
    rw_spine :: Env -> CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    rw_spine env expr = case expr of
      -- A saturated call:  (f @^w1 x) @^w2 y  ==>  f @^w1 (# x, y #)
      WebApp _ (WebApp w1 f x) y
        | is_todo w1
        -> do { (wrap, f') <- rw_spine env f
              ; x' <- rw env x
              ; y' <- rw env y
              ; let (strict_a, strict_b) = lookupWithDefaultUFM strict (False, False) w1
              ; (wrap_x, x'') <- eval_if strict_a x'
              ; (wrap_y, y'') <- eval_if strict_b y'
              ; return (wrap . wrap_x . wrap_y, WebApp w1 f' (mkCoreUnboxedTuple [x'', y''])) }

      -- A partial call:  f @^w1 x
      WebApp w1 f x
        | is_todo w1
        -> do { e' <- rw_partial env w1 f x; return (id, e') }

      WebApp w f a
        -> do { (wrap, f') <- rw_spine env f; a' <- rw env a; return (wrap, WebApp w f' a') }
      App f a
        -> do { (wrap, f') <- rw_spine env f; a' <- rw env a; return (wrap, App f' a') }
      _ -> do { e' <- rw env expr; return (id, e') }

    -- Evaluate a component that every lambda of the web is strict in, so
    -- that it is passed evaluated rather than as a thunk: CorePrep does not
    -- look inside unboxed-tuple arguments.  See Note [Uncurrying]
    eval_if :: Bool -> CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    eval_if is_strict arg
      | is_strict
      , mightBeLiftedType ty
      , not (exprIsHNF (stripWebForms arg))
      = do { v <- mkWild ty
           ; return (\body -> Case arg v (exprType body) [Alt DEFAULT [] body], Var v) }
      | otherwise
      = return (id, arg)
      where ty = exprType arg

    rw_tick env t@(Breakpoint { breakpointFVs = ids })
      = t { breakpointFVs = map (lookup_bndr env) ids }
    rw_tick _ t = t

    -- \^w1 a. <frames> \^w2 b. e   ==>   \^w1 t. case t of (# a, b #) -> <frames> e
    rw_uncurried_lam env w a frames _w2 b e
      = do { let (env1, a') = rw_bndr1 env a
                 (env2, frames') = rw_frames env1 frames
                 (env3, b') = rw_bndr1 env2 b
           ; e' <- rw env3 e
             -- Unpack under any further lambdas; see splitLeadingLams
           ; let (lams, body) = splitLeadingLams e'
                 inner = foldr wrap_frame body frames'
                 tup_ty = mkTupleTy Unboxed [idType a', idType b']
           ; u <- getUniqueM
           ; let t = mkSysLocal (fsLit "ut") u ManyTy tup_ty
           ; wild <- mkWild tup_ty
           ; return (WebLam w t (lams (Case (Var t) wild (exprType inner)
                                        [Alt (DataAlt (tupleDataCon Unboxed 2)) [a', b'] inner]))) }

    rw_frames env [] = (env, [])
    rw_frames env ((x, wild, con, bs) : frames)
      = let (env1, wild') = rw_bndr1 env wild
            (env2, bs')   = rw_bndrs env1 bs
            (env3, fs')   = rw_frames env2 frames
        in (env3, (lookup_bndr env x, wild', con, bs') : fs')

    wrap_frame (x, wild, con, bs) body
      = Case (Var x) wild (exprType body) [Alt con bs body]

    -- f @^w1 x  ==>  case f of g { __DEFAULT ->
    --                  let v = x in \^w2 b. g @^w1 (# v, b #) }
    rw_partial env w1 f x
      = do { f' <- rw env f
           ; x' <- rw env x
           ; let (w2, b_ty, _) = inner_arrow (exprType f)
                 b_ty' = upTy b_ty
           ; g <- mkWild (exprType f')
           ; ub <- getUniqueM
           ; let b = mkSysLocal (fsLit "eta") ub ManyTy b_ty'
           ; with_arg x' $ \v ->
               Case f' g (exprType (mk_eta w1 w2 g v b)) [Alt DEFAULT [] (mk_eta w1 w2 g v b)] }

    mk_eta w1 w2 g v b
      = WebLam w2 b (WebApp w1 (Var g) (mkCoreUnboxedTuple [v, Var b]))

    -- Bind the argument so it is evaluated at most once: let-bound if
    -- lifted, case-bound if unlifted, used directly if trivial
    with_arg :: CoreExpr -> (CoreExpr -> CoreExpr) -> UniqSM CoreExpr
    with_arg x' k
      | exprIsTrivial (stripWebForms x') = return (k x')
      | otherwise
      = do { u <- getUniqueM
           ; let ty = exprType x'
                 v  = mkSysLocal (fsLit "arg") u ManyTy ty
           ; if mightBeUnliftedType ty
             then do { let body = k (Var v)
                     ; return (Case x' v (exprType body) [Alt DEFAULT [] body]) }
             else return (Let (NonRec v x') (k (Var v))) }

    -- The inner arrow of an uncurried web's arrow, in the original type
    inner_arrow fun_ty = case coreFullView fun_ty of
      FunTy { ft_res = r } | FunTy { ft_web = w2, ft_arg = b, ft_res = c } <- coreFullView r
        -> (w2, b, c)
      _ -> pprPanic "Uncurry.inner_arrow" (ppr fun_ty)
