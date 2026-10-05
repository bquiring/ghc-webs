-- | Result raising over webs (web CPR): return a product's components in an
-- unboxed tuple instead of the product.
--
-- See Note [Result raising] and WEBS-RESULT-RAISING.md.
module GHC.WebCore.Transform.ResultRaise
  ( resultRaiseRound
  ) where

import GHC.Prelude

import GHC.Builtin.Types ( mkTupleTy, tupleDataCon )
import GHC.Core
import GHC.Core.Coercion
import GHC.Core.DataCon
import GHC.Core.TyCon ( TyCon )
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.Make ( mkCoreUnboxedTuple, mkCoreConApps )
import GHC.Core.Opt.Arity ( exprIsDeadEnd )
import GHC.Core.TyCo.Rep
import GHC.Core.Type
import GHC.Core.Utils ( exprType )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Basic ( Boxity(..) )
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
import GHC.Utils.Panic ( pprPanic )

import GHC.WebCore.Transform.ArityRaise ( productCon, productOf, components
                                        , splitArgCo, componentsTupleCo )
import GHC.WebCore.Transform.Common
import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )
import Data.Maybe ( fromMaybe, isJust )

{- Note [Result raising]
~~~~~~~~~~~~~~~~~~~~~~~~
A web w whose arrows all return a product (a single-constructor data type
without existentials), and whose lambdas all construct their result,
returns the product's components in an unboxed tuple instead:

    A -{w}-> T ts          becomes   A -{w}-> (# c1, .., cn #)
    \^w x. ... K es ...    becomes   \^w x. ... (# es #) ...      (tails)
    f @^w a                becomes   case f @^w a of (# ys #) -> K ys
    case f @^w a of b { K ys -> rhs }
                           becomes   case f @^w a of (# ys #) -> [let b = K ys in] rhs

This is GHC's CPR worker/wrapper (GHC.Core.Opt.CprAnal, WorkWrap) for every
function value of the web, at unknown calls too, without a wrapper.

The tails of a lambda's body are found through let, case alternatives,
ticks, and join points bound in tail position (whose result type changes
too).  A lambda qualifies if each tail constructs the product, is a dead end
(e.g. error), is a jump to such a join point, or is a tail call of w itself
(which, rewritten, already returns the tuple).  Any other tail (a variable,
a call of another function) rejects the web, as in GHC's CPR: it would have
to be taken apart, which costs more than the boxing it saves.  Dead ends are
taken apart anyway (case error .. of K ys -> (# ys #)), which costs nothing.

Laziness: none.  Returning the components unboxed evaluates nothing (they
stay lazy in the tuple), and a call in a lazy position stays lazy (the case
that re-boxes it is inside the thunk).  Webs of join-point lambdas are
rejected: their calls are jumps, which cannot be scrutinised.
-}

data Verdict = Raised | Rejected Reason

data Reason = Exposed | NotProduct | RepPoly | Coercion' | JoinLam
            | Unconstructed | NoConstruction

instance Outputable Verdict where
  ppr Raised       = text "raised"
  ppr (Rejected r) = text "rejected" <+> parens (ppr r)

instance Outputable Reason where
  ppr Exposed        = text "exposed"
  ppr NotProduct     = text "result not a product"
  ppr RepPoly        = text "representation-polymorphic component"
  ppr Coercion'      = text "complex coercion"
  ppr JoinLam        = text "join point"
  ppr Unconstructed  = text "a tail does not construct the result"
  ppr NoConstruction = text "no tail constructs the result"

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Info = Info
  { i_lams      :: [Id]
  , i_join      :: Bool
  , i_not_prod  :: Bool
  , i_tycons    :: [TyCon]
  , i_rep_poly  :: Bool
  , i_coercion  :: Bool
  , i_bad_tail  :: Bool
  , i_con_tails :: Int }

noInfo :: Info
noInfo = Info [] False False [] False False False 0

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams      = i_lams a ++ i_lams b
                    , i_join      = i_join a     || i_join b
                    , i_not_prod  = i_not_prod a || i_not_prod b
                    , i_tycons    = i_tycons a ++ i_tycons b
                    , i_rep_poly  = i_rep_poly a || i_rep_poly b
                    , i_coercion  = i_coercion a || i_coercion b
                    , i_bad_tail  = i_bad_tail a || i_bad_tail b
                    , i_con_tails = i_con_tails a + i_con_tails b }

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

-- | The outermost web of an application spine, if it is one
spineWeb :: CoreExpr -> Maybe WebId
spineWeb (WebApp w _ _) = Just w
spineWeb (Tick _ e)     = spineWeb e
spineWeb _              = Nothing

-- | A saturated application of a data constructor's worker
conApp :: CoreExpr -> Maybe (DataCon, [CoreExpr], [CoreExpr])
conApp e = case collectWebArgs e of
  (Var v, args)
    | Just dc <- isDataConWorkId_maybe v
    , let (ty_args, vals) = span isTypeArg args
    , length vals == dataConRepArity dc
    -> Just (dc, ty_args, vals)
  _ -> Nothing
  where
    collectWebArgs ex = go ex []
      where go (App f a)      as = go f (a:as)
            go (WebApp _ f a) as = go f (a:as)
            go (Tick t f) as | not (tickishIsCode t) = go f as
            go f              as = (f, as)

-- | Classify the tails of a lambda of web w: (number of constructed tails,
-- whether some tail is neither constructed, a dead end, a jump to a join
-- point bound in tail position, nor a tail call of w)
tailInfo :: WebId -> CoreExpr -> (Int, Bool)
tailInfo w = go emptyVarSet
  where
    go joins expr = case expr of
      Let (NonRec j rhs) body
        | isJoinId j -> go joins (joinBody rhs) `plus` go (extendVarSet joins j) body
      Let (Rec prs) body
        | all (isJoinId . fst) prs
        -> let joins' = extendVarSetList joins (map fst prs)
           in foldr (plus . go joins' . joinBody . snd) (go joins' body) prs
      Let _ body -> go joins body
      Case _ _ _ alts -> foldr (plus . (\(Alt _ _ rhs) -> go joins rhs)) (0, False) alts
      Tick _ e -> go joins e
      _ | isJust (conApp expr)                 -> (1, False)
        | exprIsDeadEnd (stripWebForms expr)   -> (0, False)
        | Just j <- jumpTo expr, j `elemVarSet` joins -> (0, False)
        | spineWeb expr == Just w              -> (0, False)
        | otherwise                            -> (0, True)

    plus (a, b) (c, d) = (a + c, b || d)

-- | The body of a join point's right-hand side, after its lambdas
joinBody :: CoreExpr -> CoreExpr
joinBody (Lam _ e)      = joinBody e
joinBody (WebLam _ _ e) = joinBody e
joinBody e              = e

-- | The join point a jump jumps to
jumpTo :: CoreExpr -> Maybe Id
jumpTo e = case e of
  App f _      -> jumpTo f
  WebApp _ f _ -> jumpTo f
  Tick _ f     -> jumpTo f
  Var v | isJoinId v -> Just v
  _            -> Nothing

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | isJoinId b = go_join e acc
      | otherwise  = go e acc

    -- The lambdas of a join point's right-hand side
    go_join (Lam b e)      acc = go_bndr b (go_join e acc)
    go_join (WebLam w p e) acc = go_bndr p $ note w (noInfo { i_lams = [p], i_join = True })
                                           (go_join e acc)
    go_join e              acc = go e acc

    go :: CoreExpr -> Infos -> Infos
    go (Var {}) acc = acc
    go (Lit {}) acc = acc
    go (App f a) acc = go f (go a acc)
    go (WebApp _ f a) acc = go f (go a acc)
    go (Lam b e) acc = go_bndr b (go e acc)
    go (WebLam w p e) acc
      = go_bndr p $ go e $
        let (n, bad) = tailInfo w e
        in note w (noInfo { i_lams = [p], i_bad_tail = bad, i_con_tails = n }) acc
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

    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        -> let acc' = go_ty a (go_ty r acc)
           in case productCon (coreFullView r) of
                Just (tc, args, dc)
                  | all typeHasFixedRuntimeRep (components dc args)
                  -> note w (noInfo { i_tycons = [tc] }) acc'
                  | otherwise
                  -> note w (noInfo { i_tycons = [tc], i_rep_poly = True }) acc'
                Nothing -> note w (noInfo { i_not_prod = True }) acc'
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
        | Nothing <- splitArgCo c2
        -> note w (noInfo { i_coercion = True }) (go_co c1 (go_co c2 acc))
        | otherwise
        -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      _                      -> acc   -- complexCoWebs deals with the others

verdict :: WebSet -> WebSet -> WebId -> Info -> Verdict
verdict exposed complex w i
  | w `elementOfUniqSet` exposed  = Rejected Exposed
  | i_join i                      = Rejected JoinLam
  | w `elementOfUniqSet` complex  = Rejected Coercion'
  | i_coercion i                  = Rejected Coercion'
  | i_not_prod i                  = Rejected NotProduct
  | not (same_tycon (i_tycons i)) = Rejected NotProduct
  | i_rep_poly i                  = Rejected RepPoly
  | i_bad_tail i                  = Rejected Unconstructed
  | i_con_tails i == 0            = Rejected NoConstruction
  | otherwise                     = Raised
  where
    same_tycon (tc:tcs) = all (== tc) tcs
    same_tycon []       = False

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse the program and raise the results of the webs that qualify.  A
-- raised web no longer returns a product, so it is not raised again.
resultRaiseRound :: UniqSupply -> WebSet -> UnfoldingPolicy -> WebSet -> CoreProgram
                 -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
resultRaiseRound us exposed pol done binds
  | isEmptyUniqSet todo = (Nothing, dump)
  | otherwise           = (Just (initUs_ us (rewriteProgram todo pol binds), todo), dump)
  where
    infos    = analyse binds
    complex  = complexCoWebs binds
    verdicts = [ (w, verdict exposed complex w i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (i_lams i))
               , not (w `elementOfUniqSet` done) ]
    todo = mkUniqSet [ w | (w, Raised, _) <- verdicts ]
    dump = [ (w, ppr v, w `elementOfUniqSet` todo, i_lams i) | (w, v, i) <- verdicts ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

-- | The unboxed tuple of a product type's components
tupleOf :: Type -> Type
tupleOf ty = let (args, dc) = productOf ty in mkTupleTy Unboxed (components dc args)

raiseType :: WebSet -> Type -> Type
raiseType todo = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_mult = m, ft_arg = a, ft_res = r }
        | w `elementOfUniqSet` todo
        , Just (_, args, dc) <- productCon (coreFullView r)
        -> let a'  = go a
               tup = mkTupleTy Unboxed (components dc (map go args))
           in mkWebFunTy w (chooseFunTyFlag a' tup) m a' tup
        | otherwise -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) (raiseCo todo co)
      CoercionTy co   -> CoercionTy (raiseCo todo co)
      _               -> ty

raiseCo :: WebSet -> Coercion -> Coercion
raiseCo todo = go
  where
    goTy = raiseType todo
    go co = case co of
      Refl t              -> Refl (goTy t)
      GRefl r t mco       -> GRefl r (goTy t) mco
      TyConAppCo r tc cos -> TyConAppCo r tc (map go cos)
      AppCo c1 c2         -> AppCo (go c1) (go c2)
      ForAllCo { fco_body = c } -> co { fco_body = go c }
      FunCo { fco_role = r, fco_web = w, fco_mult = m, fco_arg = ca, fco_res = cr }
        | w `elementOfUniqSet` todo
        , Just (_, res_cos) <- splitArgCo cr
        , Just (_, _, dc) <- productCon (coercionLKind cr)
        -> let ca'  = go ca
               tup  = componentsTupleCo r dc (map go res_cos)
               Pair la ra = coercionKind ca'
               Pair lt rt = coercionKind tup
           in mkWebFunCo2 w r (chooseFunTyFlag la lt) (chooseFunTyFlag ra rt) m ca' tup
        | otherwise -> co { fco_arg = go ca, fco_res = go cr }
      AxiomCo ax cos      -> AxiomCo ax (map go cos)
      SymCo c             -> SymCo (go c)
      TransCo c1 c2       -> TransCo (go c1) (go c2)
      SubCo c             -> SubCo (go c)
      _                   -> co

type Env = IdEnv Id

rewriteProgram :: WebSet -> UnfoldingPolicy -> CoreProgram -> UniqSM CoreProgram
rewriteProgram todo pol binds
  = do { let env = mkVarEnv [ (b, rw_bndr b) | b <- bindersOfBinds binds ]
       ; mapM (rw_top env) binds }
  where
    upTy = raiseType todo
    upCo = raiseCo todo
    is_todo w = w `elementOfUniqSet` todo

    rw_top env (NonRec b e) = NonRec (lookup_bndr env b) <$> rw env e
    rw_top env (Rec prs)    = Rec <$> sequence [ (,) (lookup_bndr env b) <$> rw env e
                                               | (b, e) <- prs ]

    lookup_bndr env v = fromMaybe v (lookupVarEnv env v)

    rw_bndr :: Var -> Var
    rw_bndr b
      | not (isId b)         = b
      | not (changed old_ty) = fixUnfolding pol changed_set b
      | otherwise            = fixUnfolding pol changed_set $
                               fixBinderInfo b new_ty (\_ n -> n) (argFates (\_ _ -> KeepArg) old_ty)
      where
        old_ty = idType b
        new_ty = upTy old_ty

    -- See Note [Unfoldings and rules after a transformation]
    changed_set = changedBinders changed binds

    changed ty = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r } -> is_todo w || changed a || changed r
      TyConApp _ tys -> any changed tys
      AppTy t1 t2    -> changed t1 || changed t2
      ForAllTy _ t   -> changed t
      CastTy t _     -> changed t
      _              -> False

    rw_bndr1 env b = (extendVarEnv env b b', b') where b' = rw_bndr b

    rw_bndrs env bs = (extendVarEnvList env (zip bs bs'), bs')
      where bs' = map rw_bndr bs

    ---------------
    rw :: Env -> CoreExpr -> UniqSM CoreExpr
    rw env expr = case expr of
      Var v        -> return (Var (lookup_bndr env v))
      Lit l        -> return (Lit l)
      Lam b e      -> let (env', b') = rw_bndr1 env b in Lam b' <$> rw env' e

      WebLam w p e
        | is_todo w  -> let (env', p') = rw_bndr1 env p in WebLam w p' <$> rw_tail env' e
        | otherwise  -> let (env', p') = rw_bndr1 env p in WebLam w p' <$> rw env' e

      App {}       -> rw_spine env expr
      WebApp w _ _
        | is_todo w  -> rw_spine env expr >>= rebox (upTy (exprType expr))
        | otherwise  -> rw_spine env expr

      Let bind body -> do { (env', bind') <- rw_bind env bind; Let bind' <$> rw env' body }

      -- case f @^w a of b { K ys -> rhs }  ==>  case f @^w a of (# ys #) -> rhs
      Case scrut b ty [Alt (DataAlt dc) ys rhs]
        | Just w <- spineWeb scrut, is_todo w
        -> do { scrut' <- rw_spine env scrut
              ; let (env1, b')  = rw_bndr1 env b
                    (env2, ys') = rw_bndrs env1 ys
              ; rhs' <- rw env2 rhs
              ; let ty_args = map Type (tyConAppArgs (idType b'))
                    alias | b `elemVarSet` exprOccurrences rhs
                          = [NonRec b' (mkCoreConApps dc (ty_args ++ map Var ys'))]
                          | otherwise = []
              ; wild <- mkWild (exprType scrut')
              ; return (Case scrut' wild (upTy ty)
                          [Alt (DataAlt (tupleDataCon Unboxed (length ys'))) ys'
                               (mkLets alias rhs')]) }

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

    rw_bind env (NonRec b rhs)
      = do { rhs' <- rw env rhs
           ; let (env', b') = rw_bndr1 env b
           ; return (env', NonRec b' rhs') }
    rw_bind env (Rec prs)
      = do { let (env', bs') = rw_bndrs env (map fst prs)
           ; rhss' <- mapM (rw env' . snd) prs
           ; return (env', Rec (zip bs' rhss')) }

    -- An application spine, not re-boxed
    rw_spine env expr = case expr of
      WebApp w f x -> WebApp w <$> rw_spine env f <*> rw env x
      App f a      -> App <$> rw_spine env f <*> rw env a
      Tick t e     -> Tick (rw_tick env t) <$> rw_spine env e
      _            -> rw env expr

    -- A raised call returns the tuple; outside a raised tail, re-box it:
    -- case call of (# ys #) -> K ys.  prod_ty is the call's type before
    -- raising, with its arguments raised.
    rebox prod_ty call
      = do { let (args, dc) = productOf prod_ty
                 comps = components dc args
           ; ys <- mapM (fresh "y") comps
           ; wild <- mkWild (mkTupleTy Unboxed comps)
           ; return (Case call wild prod_ty
                       [Alt (DataAlt (tupleDataCon Unboxed (length ys))) ys
                            (mkCoreConApps dc (map Type args ++ map Var ys))]) }

    rw_tick env t@(Breakpoint { breakpointFVs = ids })
      = t { breakpointFVs = map (lookup_bndr env) ids }
    rw_tick _ t = t

    fresh :: String -> Type -> UniqSM Id
    fresh s ty = do { u <- getUniqueM; return (mkSysLocal (fsLit s) u ManyTy ty) }

    ---------------
    -- A tail of a raised lambda (or of a join point bound in tail position):
    -- return the tuple
    rw_tail :: Env -> CoreExpr -> UniqSM CoreExpr
    rw_tail env expr = case expr of
      Let (NonRec j rhs) body
        | isJoinId j
        -> do { let j' = raise_join j
                    env' = extendVarEnv env j j'
              ; rhs' <- rw_join_rhs env rhs
              ; Let (NonRec j' rhs') <$> rw_tail env' body }
      Let (Rec prs) body
        | all (isJoinId . fst) prs
        -> do { let js' = map (raise_join . fst) prs
                    env' = extendVarEnvList env (zip (map fst prs) js')
              ; rhss' <- mapM (rw_join_rhs env' . snd) prs
              ; Let (Rec (zip js' rhss')) <$> rw_tail env' body }
      Let bind body
        -> do { (env', bind') <- rw_bind env bind; Let bind' <$> rw_tail env' body }
      Case scrut b ty alts
        -> do { scrut' <- rw env scrut
              ; let (env', b') = rw_bndr1 env b
              ; alts' <- sequence [ Alt con bs' <$> rw_tail env'' rhs
                                  | Alt con bs rhs <- alts
                                  , let (env'', bs') = rw_bndrs env' bs ]
              ; return (Case scrut' b' (tupleOf (upTy ty)) alts') }
      Tick t e | not (tickishIsCode t) -> Tick (rw_tick env t) <$> rw_tail env e
      _ | Just (_, _, vals) <- conApp expr
        -> mkCoreUnboxedTuple <$> mapM (rw env) vals
        | Just j <- jumpTo expr, isJust (lookupVarEnv env j), isJoinId j
        , is_raised_join env j
        -> rw_spine env expr
        | Just w <- spineWeb expr, is_todo w
        -> rw_spine env expr          -- already returns the tuple
        | otherwise
        -> do { e' <- rw env expr
              ; unbox e' }

    is_raised_join env j = case lookupVarEnv env j of
      Just j' -> not (idType j' `eqType` idType j)
      Nothing -> False

    -- case e of K ys -> (# ys #)
    unbox e
      = do { let ty = exprType e
                 (args, dc) = productOf ty
                 comps = components dc args
           ; ys <- mapM (fresh "y") comps
           ; wild <- mkWild ty
           ; return (Case e wild (mkTupleTy Unboxed comps)
                       [Alt (DataAlt dc) ys (mkCoreUnboxedTuple (map Var ys))]) }

    rw_join_rhs env (Lam b e)      = let (env', b') = rw_bndr1 env b in Lam b' <$> rw_join_rhs env' e
    rw_join_rhs env (WebLam w b e) = let (env', b') = rw_bndr1 env b in WebLam w b' <$> rw_join_rhs env' e
    rw_join_rhs env e              = rw_tail env e

    -- A join point bound in a raised tail returns the tuple too
    raise_join j = case idJoinPointHood j of
      JoinPoint ar -> let j1 = rw_bndr j
                      in setIdType j1 (replaceResult ar (idType j1))
      NotJoinPoint -> j

    replaceResult :: Int -> Type -> Type
    replaceResult 0 ty = tupleOf ty
    replaceResult n ty = case ty of
      ForAllTy b t       -> ForAllTy b (replaceResult (n - 1) t)
      ft@FunTy { ft_res = r } -> let r' = replaceResult (n - 1) r
                                 in ft { ft_res = r', ft_af = chooseFunTyFlag (ft_arg ft) r' }
      _ | Just ty' <- coreView ty -> replaceResult n ty'
      _ -> pprPanic "ResultRaise.replaceResult" (ppr ty)
