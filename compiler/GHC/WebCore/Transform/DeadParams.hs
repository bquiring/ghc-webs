-- | Dead-parameter elimination over webs.
--
-- See Note [Dead-parameter elimination] and WEBS-DEAD-PARAMS.md.
module GHC.WebCore.Transform.DeadParams
  ( deadParamsRound
  , Verdict(..), UnitReason(..), RejectReason(..)
  , pprVerdicts
  ) where

import GHC.Prelude

import GHC.Builtin.Types ( unboxedUnitTy, unboxedUnitDataCon )
import GHC.Core
import GHC.Core.Coercion
import GHC.Core.DataCon ( dataConWorkId )
import GHC.Core.TyCo.Rep

import GHC.Core.Type
import GHC.Core.Utils ( exprType, exprOkForSpeculation )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Id
import GHC.Types.Id.Info ( emptyRuleInfo )
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

import GHC.WebCore.Traverse ( stripWebForms, typeWebs )
import GHC.WebCore.Transform.Common ( UnfoldingPolicy(..), changedBinders, fixUnfolding
                                    , fixBinderInfo, ArgFate(..), argFates )

import Data.List ( sortOn )
import Data.Maybe ( fromMaybe )

{- Note [Dead-parameter elimination]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If every lambda of a (non-exposed) web ignores its parameter, the parameter
can be removed from every arrow, lambda and call of the web, keeping the
program well-typed.  We do it in one of two ways, chosen per web:

  * Delete:  A -{w}-> B  becomes  B;  \^w x. e  becomes  e;  f @^w a  becomes  f
  * Unit:    A -{w}-> B  becomes  (# #) -{w}-> B;
             \^w x. e    becomes  \^w (x :: (# #)). e;
             f @^w a     becomes  f @^w (# #)

Deletion turns a lambda into (possibly) a thunk, so it is only allowed when
that cannot be observed: the result B must be definitely lifted, and no value
of the web may be forced without being applied (scrutinised by a case, or
passed as a type argument to polymorphic code that might seq it).  Join
points are exempt: they are never values.  Unit keeps every value a lambda,
so it needs neither condition.

In both cases a dropped unlifted argument that is not ok-for-speculation is
still evaluated:  case a of _ { __DEFAULT -> ... }.

A web is rejected if it is exposed, if some lambda uses its parameter or binds
a coercion variable, if it appears in a coercion we cannot rewrite
structurally (SelCo, LRCo, KindCo, InstCo, UnivCo, coercion variables), or if
an effectful dropped argument has an unboxed tuple or sum type.

The pipeline (GHC.WebCore.Pipeline) runs rounds until nothing changes, since
dropping one parameter can make another dead, and runs Web Lint after each
round: the rewrite must keep the program well-typed.  Webs that were turned
into unit webs are not considered again.

IdInfo: binders whose types change get a new arity (and join arity), and
their demand and CPR signatures are zapped.  Stale unfoldings and rules are
handled as in Note [Unfoldings and rules after a transformation] in
GHC.WebCore.Transform.Common.
-}

{- Note [Early dead parameters]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In the early run (-fcore-webs-early), a dead parameter that is a function's
last one is turned into (# #), not deleted.  Deleting it turns the function
into a plain value (\_ -> e  becomes  e), and the passes that run afterwards
(SpecConstr, eta-expansion in the simplifier) rely on the lambda.  In nofib
real/eff/CS, constant propagation made the argument of a continuation
\a s -> (a, s) constant, deleting it left a value of type Integer -> ...,
and the state loop around it was no longer eta-expanded: 4x the allocation.
-}

------------------------------------------------------------------
--      Verdicts
------------------------------------------------------------------

data Verdict = Delete | Unit UnitReason | Reject RejectReason

data UnitReason = UnitForced | UnitTypeArg | UnitUnliftedResult | UnitLastArg

data RejectReason = RejectExposed | RejectUsed | RejectCoVar
                  | RejectCoercion | RejectEffectfulTuple

instance Outputable Verdict where
  ppr Delete       = text "deleted"
  ppr (Unit r)     = text "unit" <+> parens (ppr r)
  ppr (Reject r)   = text "rejected" <+> parens (ppr r)

instance Outputable UnitReason where
  ppr UnitForced         = text "forced"
  ppr UnitTypeArg        = text "in type argument"
  ppr UnitUnliftedResult = text "unlifted result"
  ppr UnitLastArg        = text "last argument, early"

instance Outputable RejectReason where
  ppr RejectExposed        = text "exposed"
  ppr RejectUsed           = text "used parameter"
  ppr RejectCoVar          = text "coercion parameter"
  ppr RejectCoercion       = text "complex coercion"
  ppr RejectEffectfulTuple = text "effectful unboxed-tuple argument"

-- | One line per web, without uniques: the verdict and the names of the
-- web's lambda binders.  Sorted, so tests can check it.
pprVerdicts :: [(Verdict, [Id])] -> SDoc
pprVerdicts vs
  = vcat [ doc | (_, doc) <- sortOn fst [ (showSDocUnsafe (line v bs), line v bs) | (v, bs) <- vs ] ]
  where
    line v bs = ppr v <> colon <+> hsep (map (ppr . idName) bs)

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

-- | What we know about a web
data WebInfo = WI
  { wi_lams          :: [Id]   -- Binders of its lambdas
  , wi_used          :: Bool   -- Some lambda uses its parameter
  , wi_covar         :: Bool   -- Some lambda binds a coercion variable
  , wi_non_join      :: Bool   -- Some lambda is not a join-point lambda
  , wi_forced        :: Bool   -- Some value of the web is scrutinised
  , wi_type_arg      :: Bool   -- The web appears in a type argument
  , wi_unlifted_res  :: Bool   -- Some arrow of the web has a result that
                               -- is not definitely lifted
  , wi_coercion      :: Bool   -- Appears in a coercion we can't rewrite
  , wi_eff_tuple     :: Bool   -- An effectful unboxed-tuple argument
  , wi_last_arg      :: Bool   -- Some arrow's result is not a function:
                               -- deleting would leave no lambda
  }

noInfo :: WebInfo
noInfo = WI [] False False False False False False False False False

plusInfo :: WebInfo -> WebInfo -> WebInfo
plusInfo a b = WI { wi_lams         = wi_lams a ++ wi_lams b
                  , wi_used         = wi_used a         || wi_used b
                  , wi_covar        = wi_covar a        || wi_covar b
                  , wi_non_join     = wi_non_join a     || wi_non_join b
                  , wi_forced       = wi_forced a       || wi_forced b
                  , wi_type_arg     = wi_type_arg a     || wi_type_arg b
                  , wi_unlifted_res = wi_unlifted_res a || wi_unlifted_res b
                  , wi_coercion     = wi_coercion a     || wi_coercion b
                  , wi_eff_tuple    = wi_eff_tuple a    || wi_eff_tuple b
                  , wi_last_arg     = wi_last_arg a     || wi_last_arg b }

type Infos = UniqFM WebId WebInfo

note :: WebId -> WebInfo -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

noteAll :: WebSet -> WebInfo -> Infos -> Infos
noteAll ws i infos = nonDetStrictFoldUniqSet (\w acc -> note w i acc) infos ws

-- | Collect what we know about every web of the program
analyse :: CoreProgram -> Infos
analyse binds = foldr go_top_bind emptyUFM binds
  where
    occs = programOccurrences binds

    go_top_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_top_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | JoinPoint arity <- idJoinPointHood b = go_join arity e acc
      | otherwise                            = go e acc

    -- The first 'arity' lambdas of a join point's right-hand side
    go_join :: Int -> CoreExpr -> Infos -> Infos
    go_join 0 e acc = go e acc
    go_join n (Lam b e) acc = go_bndr b (go_join (n-1) e acc)
    go_join n (WebLam w x e) acc = go_lam False w x (go_join (n-1) e acc)
    go_join _ e acc = go e acc

    go_lam non_join w x acc
      = go_bndr x $
        note w (noInfo { wi_lams     = [x]
                       , wi_used     = x `elemVarSet` occs
                       , wi_covar    = isCoVar x
                       , wi_non_join = non_join }) acc

    go :: CoreExpr -> Infos -> Infos
    go (Var {}) acc = acc
    go (Lit {}) acc = acc
    go (App f (Type t)) acc = go f (go_ty_arg t acc)
    go (App f a) acc = go f (go a acc)
    go (WebApp w f a) acc = go f (go a (go_arg w a acc))
    go (Lam b e) acc = go_bndr b (go e acc)
    go (WebLam w x e) acc = go_lam True w x (go e acc)
    go (Let (NonRec b (Type t)) body) acc
      | isTyVar b = go_ty_arg t (go body acc)
    go (Let bind body) acc = go_top_bind bind (go body acc)
    go (Case scrut b ty alts) acc
      = go scrut $ go_bndr b $ go_ty ty $ go_forced (idType b) $
        foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
    go (Cast e co) acc = go e (go_co co acc)
    go (Tick _ e) acc = go e acc
    go (Type t) acc = go_ty_arg t acc
    go (Coercion co) acc = go_co co acc

    -- A dropped argument that must still be evaluated, but cannot be
    -- scrutinised with a DEFAULT alternative
    go_arg w a acc
      | needsEval a, isUnboxedTupleType ty || isUnboxedSumType ty
      = note w (noInfo { wi_eff_tuple = True }) acc
      | otherwise
      = acc
      where ty = exprType a

    -- Scrutinising a value of function type forces it
    go_forced ty acc = case coreFullView ty of
      FunTy { ft_web = w } -> note w (noInfo { wi_forced = True }) acc
      _                    -> acc

    go_bndr b acc
      | isCoVar b = noteAll (typeWebs (varType b)) (noInfo { wi_coercion = True }) acc
      | isId b    = go_ty (idType b) acc
      | otherwise = acc

    go_ty_arg t acc = noteAll (typeWebs t) (noInfo { wi_type_arg = True }) (go_ty t acc)

    -- Arrows whose result is not definitely lifted
    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        -> let acc' = go_ty a (go_ty r acc)
               last_arg = not (isFunTy (coreFullView r))
           in if definitelyLiftedType r
              then (if last_arg then note w (noInfo { wi_last_arg = True }) acc' else acc')
              else note w (noInfo { wi_unlifted_res = True, wi_last_arg = last_arg }) acc'
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
      FunCo { fco_arg = c1, fco_res = c2 } -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      -- Coercions we do not rewrite structurally
      SelCo _ c              -> complex c (go_co c acc)
      LRCo _ c               -> complex c (go_co c acc)
      KindCo c               -> complex c (go_co c acc)
      InstCo c arg           -> complex arg (go_co c (go_co arg acc))
      UnivCo {}              -> complex co acc
      CoVarCo {}             -> complex co acc
      HoleCo {}              -> complex co acc

    complex c acc = case coercionKind c of
      Pair l r -> noteAll (typeWebs l `unionUniqSets` typeWebs r)
                          (noInfo { wi_coercion = True }) acc

-- | All the variables that occur in the program (not binders)
programOccurrences :: CoreProgram -> VarSet
programOccurrences binds = foldr go_bind emptyVarSet binds
  where
    go_bind (NonRec _ e) acc = go e acc
    go_bind (Rec prs)    acc = foldr (go . snd) acc prs

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

needsEval :: CoreExpr -> Bool
-- Is this an unlifted argument whose evaluation we must keep?
needsEval a = mightBeUnliftedType (exprType a)
           && not (exprOkForSpeculation (stripWebForms a))

verdict :: Bool -> WebSet -> WebId -> WebInfo -> Verdict
verdict early exposed w i
  | w `elementOfUniqSet` exposed = Reject RejectExposed
  | wi_covar i                   = Reject RejectCoVar
  | wi_used i                    = Reject RejectUsed
  | wi_coercion i                = Reject RejectCoercion
  | wi_eff_tuple i               = Reject RejectEffectfulTuple
  | not (wi_non_join i)          = Delete   -- Only join points: never values
  | wi_forced i                  = Unit UnitForced
  | wi_type_arg i                = Unit UnitTypeArg
  | wi_unlifted_res i            = Unit UnitUnliftedResult
  | early, wi_last_arg i         = Unit UnitLastArg   -- Note [Early dead parameters]
  | otherwise                    = Delete

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse the program and rewrite it.  Webs in the 'done' set (already
-- turned into unit webs) are not considered again.
--
-- Returns Nothing if no web was deleted or turned into a unit web, and
-- otherwise the rewritten program, the webs that became unit webs, and the
-- verdicts for every web with a lambda.
deadParamsRound :: UniqSupply
                -> WebSet      -- ^ Exposed webs
                -> UnfoldingPolicy
                -> WebSet      -- ^ Done: webs already turned into unit webs
                -> CoreProgram
                -> ( Maybe (CoreProgram, WebSet, Type -> Type)
                   , [(WebId, Verdict, [Id])] )
deadParamsRound us exposed pol done binds
  | isEmptyUniqSet del && isEmptyUniqSet unit = (Nothing, verdicts)
  | otherwise = ( Just (initUs_ us (rewriteProgram del unit pol binds), unit, dropType del unit)
                , verdicts )
  where
    infos    = analyse binds
    verdicts = [ (w, verdict (up_early pol) exposed w i, wi_lams i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (wi_lams i))
               , not (w `elementOfUniqSet` done) ]
    del  = mkUniqSet [ w | (w, Delete, _)   <- verdicts ]
    unit = mkUniqSet [ w | (w, Unit {}, _)  <- verdicts ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

type DropEnv = IdEnv Id

rewriteProgram :: WebSet   -- ^ Webs to delete
               -> WebSet   -- ^ Webs to turn into unit webs
               -> UnfoldingPolicy
               -> CoreProgram -> UniqSM CoreProgram
rewriteProgram del unit pol binds
  = do { let env = foldr (\b e -> extendVarEnv e b (rw_bndr b)) emptyVarEnv
                         (bindersOfBinds binds)
       ; mapM (rw_top env) binds }
  where
    rw_top env (NonRec b e) = NonRec (lookup_bndr env b) <$> rw env e
    rw_top env (Rec prs)    = Rec <$> sequence [ (,) (lookup_bndr env b) <$> rw env e
                                               | (b, e) <- prs ]

    lookup_bndr env v = fromMaybe v (lookupVarEnv env v)

    dropTy :: Type -> Type
    dropTy = dropType del unit

    changesType ty = not (isEmptyUniqSet (typeWebs ty `intersectUniqSets` (del `unionUniqSets` unit)))

    -- See Note [Unfoldings and rules after a transformation]
    -- in GHC.WebCore.Transform.Common
    changed_set = changedBinders changesType binds

    dropCo' :: Coercion -> Coercion
    dropCo' = dropCo del unit

    ---------------
    -- A binder with its type and IdInfo fixed up
    rw_bndr :: Var -> Var
    rw_bndr b
      | not (isId b) = b
      | otherwise
      = fixUnfolding pol changed_set $
        if changed then fix_info (setIdType b new_ty) else b
      where
        old_ty  = idType b
        new_ty  = dropTy old_ty
        changed = changesType old_ty

        fix_info b' = fixBinderInfo b' (idType b') new_arity
                                    (argFates fate old_ty)

        new_arity is_join n = n - deletedArrows is_join n old_ty

        fate w _ | w `elementOfUniqSet` del  = DropArg
                 | w `elementOfUniqSet` unit = AbsentArg
                 | otherwise                 = KeepArg


    -- How many of the first n arrows (and foralls, if count_foralls) of a
    -- type are deleted?
    deletedArrows :: Bool -> Int -> Type -> Int
    deletedArrows count_foralls = go_n
      where
        go_n 0 _ = 0
        go_n n ty
          | Just ty' <- coreView ty = go_n n ty'
        go_n n (ForAllTy _ ty)
          | count_foralls = go_n (n-1) ty
          | otherwise     = go_n n ty
        go_n n (FunTy { ft_web = w, ft_res = r })
          | w `elementOfUniqSet` del = 1 + go_n (n-1) r
          | otherwise                = go_n (n-1) r
        go_n _ _ = 0

    rw_bndr1 :: DropEnv -> Var -> (DropEnv, Var)
    rw_bndr1 env b = (extendVarEnv env b b', b')
      where b' = rw_bndr b

    rw_bndrs :: DropEnv -> [Var] -> (DropEnv, [Var])
    rw_bndrs env bs = (extendVarEnvList env (zip bs bs'), bs')
      where bs' = map rw_bndr bs

    ---------------
    rw :: DropEnv -> CoreExpr -> UniqSM CoreExpr
    rw env expr = case expr of
      Var v        -> return (Var (lookup_bndr env v))
      Lit l        -> return (Lit l)
      App f a      -> App <$> rw env f <*> rw env a
      Lam b e      -> let (env', b') = rw_bndr1 env b in Lam b' <$> rw env' e

      WebLam w x e
        | w `elementOfUniqSet` del  -> rw env e
        | w `elementOfUniqSet` unit -> WebLam w (setIdType x unboxedUnitTy) <$> rw env e
        | otherwise -> let (env', x') = rw_bndr1 env x in WebLam w x' <$> rw env' e

      WebApp w f a
        | w `elementOfUniqSet` del
        -> do { f' <- rw env f; keepEval env a f' }
        | w `elementOfUniqSet` unit
        -> do { f' <- rw env f; keepEval env a (WebApp w f' unboxedUnitExpr) }
        | otherwise
        -> WebApp w <$> rw env f <*> rw env a

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
              ; return (Case scrut' b' (dropTy ty) alts') }

      Cast e co    -> (\e' -> Cast e' (dropCo' co)) <$> rw env e
      Tick t e     -> Tick (rw_tick env t) <$> rw env e
      Type t       -> return (Type (dropTy t))
      Coercion co  -> return (Coercion (dropCo' co))

    rw_tick env t@(Breakpoint { breakpointFVs = ids })
      = t { breakpointFVs = map (lookup_bndr env) ids }
    rw_tick _ t = t

    -- Keep the evaluation of a dropped unlifted argument that might have
    -- an effect or diverge:  case a of _ { __DEFAULT -> body }
    keepEval :: DropEnv -> CoreExpr -> CoreExpr -> UniqSM CoreExpr
    keepEval env a body
      | needsEval a
      = do { a' <- rw env a
           ; u  <- getUniqueM
           ; let wild = mkSysLocal (fsLit "wild") u ManyTy (exprType a')
           ; return (Case a' wild (exprType body) [Alt DEFAULT [] body]) }
      | otherwise
      = return body

unboxedUnitExpr :: CoreExpr
unboxedUnitExpr = Var (dataConWorkId unboxedUnitDataCon)

-- | Drop the deleted webs' arrows from a type, and replace the argument of
-- the unit webs' arrows with (# #)
dropType :: WebSet -> WebSet -> Type -> Type
dropType del unit = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_mult = m, ft_arg = a, ft_res = r }
        | w `elementOfUniqSet` del  -> go r
        | w `elementOfUniqSet` unit -> mkWebFunTy w (chooseFunTyFlag unboxedUnitTy r') m
                                                  unboxedUnitTy r'
        | otherwise                 -> ty { ft_arg = go a, ft_res = r' }
        where r' = go r
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) (dropCo del unit co)
      CoercionTy co   -> CoercionTy (dropCo del unit co)
      _               -> ty

-- | The coercion version of 'dropType'.  Only the structural coercions can
-- contain the arrows of a dead web; see 'analyse'.
dropCo :: WebSet -> WebSet -> Coercion -> Coercion
dropCo del unit = go
  where
    goTy = dropType del unit
    go co = case co of
      Refl t              -> Refl (goTy t)
      GRefl r t mco       -> GRefl r (goTy t) mco
      TyConAppCo r tc cos -> TyConAppCo r tc (map go cos)
      AppCo c1 c2         -> AppCo (go c1) (go c2)
      ForAllCo { fco_body = c } -> co { fco_body = go c }
      FunCo { fco_role = r, fco_web = w, fco_mult = m, fco_res = c2 }
        | w `elementOfUniqSet` del  -> go c2
        | w `elementOfUniqSet` unit
        -> let c2' = go c2
               Pair lres rres = coercionKind c2'
           in mkWebFunCo2 w r (chooseFunTyFlag unboxedUnitTy lres)
                              (chooseFunTyFlag unboxedUnitTy rres)
                              m (mkReflCo r unboxedUnitTy) c2'
        | otherwise -> co { fco_arg = go (fco_arg co), fco_res = go c2 }
      AxiomCo ax cos      -> AxiomCo ax (map go cos)
      SymCo c             -> SymCo (go c)
      TransCo c1 c2       -> TransCo (go c1) (go c2)
      SubCo c             -> SubCo (go c)
      -- Coercions containing dead webs are never these; see 'analyse'
      _                   -> co
