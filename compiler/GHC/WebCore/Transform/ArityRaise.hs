-- | Arity raising over webs: pass a product argument as its components.
--
-- See Note [Arity raising] and WEBS-ARITY-RAISING.md.
module GHC.WebCore.Transform.ArityRaise
  ( arityRaiseRound
    -- * Products, shared with result raising
  , productCon, productOf, components, splitArgCo, componentsTupleCo, knownHead
  , isStrictIn, onlyScrutinised, replaceCases
  ) where

import GHC.Prelude

import GHC.Builtin.Types ( mkTupleTy, tupleDataCon, tupleTyCon )
import GHC.Core
import GHC.Core.Coercion
import GHC.Core.DataCon
import GHC.Core.Make ( mkCoreUnboxedTuple, mkCoreConApps )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprType )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Basic ( Boxity(..) )
import GHC.Types.Demand ( isStrUsedDmd )
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

import GHC.WebCore.Transform.Common
import GHC.WebCore.Sigs ( FieldTys )
import GHC.WebCore.Traverse ( typeWebs )

import Data.List ( sortOn )
import Data.Maybe ( fromMaybe, isJust )

{- Note [Early arity raising]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In the early run (-fcore-webs-early), worker/wrapper runs after the web
pipeline.  For a known function it does what arity raising does, and more:
it unboxes a strict product argument into its fields, and then the fields
themselves (an Int into an Int#).  It does not unbox the components of an
unboxed-tuple argument, so once a web is raised, its components stay boxed.
So the early run raises only webs with an unknown call, which worker/wrapper
cannot help; a web whose calls are all known is left to worker/wrapper.
(Raising them all doubled the allocation of nofib spectral/dom-lt and
spectral/mate.)
-}

{- Note [Arity raising]
~~~~~~~~~~~~~~~~~~~~~~~
A web w whose arrows all take a product (a single-constructor data type
without existentials), and whose lambdas are all strict in that argument,
passes the product's components instead:

    T ts -{w}-> C         becomes   c1 -> .. -> cn -{w}-> C
                                     where c1..cn are the constructor's
                                     representation argument types
    \^w p. e              becomes   \x1 .. \^w xn. e
                                       with  case p of K ys -> rhs
                                       replaced by  let ys = xs in rhs,
                                       and  let p = K xs  if p is still used
    f @^w (K es)          becomes   f e1 .. @^w en
    f @^w x               becomes   case x of K ys -> f y1 .. @^w yn

The components are passed curried, one argument each (Note [Raised
arguments are curried]).

Laziness (WEBS-ARITY-RAISING.md §2): the caller now evaluates the argument,
so every lambda of the web must be strict in it (its demand, from the demand
analysis that runs just before the web pipeline, is strict).  A lambda that
is lazy, or strict only on some paths, rejects the web.  So does a lambda
that uses the product other than by taking it apart (Note
[Early arity raising]): it would have to rebuild it.  So does a lambda
whose body is another lambda (unless it is a join point's): the demand on its
argument describes full applications, but a partial application  f undefined
is a value that never forces the argument, and raising would force it at the
call.  The components stay
lazy: building and matching an unboxed tuple evaluates nothing.

A web is also rejected if it is exposed, if some arrow's argument is not a
product (e.g. a type variable), if the product type differs between arrows,
if a component has no fixed representation, or if the web appears in a
coercion we cannot rewrite.
-}

{- Note [Raised arguments are curried]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A raised product argument becomes its components as separate, curried
arguments, as worker/wrapper does, not one unboxed-tuple argument.  The web
keeps the last arrow (so its result is still C, for result raising); the
others get fresh webs, the same wherever the web occurs (Web Lint wants a
web on every lambda).  A later round may raise those too (nested raising).
The binder's arity grows by k - 1 for each raised argument with k
components that it covers, and its demand signature gives each component
the demand it had inside the product's demand (SplitArg, Note [Demand
signatures after a transformation] in GHC.WebCore.Transform.Common).

Unboxed-tuple arguments cost at the back end: Tidy gives no CBV marks to a
function whose argument unarises to several, so every match on a strict
component paid an evaluatedness check; and Unarise types the components'
binders by their representation only (Any), so the code generator could
not tell that a Float is not a function, and evaluating one became a slow
call through stg_ap_0_fast (nofib spectral/hartel/nucleic2, in the late
run: +11% instructions).  Curried arguments keep their types and get
ordinary marks.  An unknown call  f x y  of a function of arity 2 is no
slower: the generic apply checks the arity at run time.

A product with no components still becomes one (# #) argument, so that a
function never loses its last lambda (and its work is not shared).
-}

{- Note [Recursive products]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A web stored in a hidden field of the type it takes (Note [Hidden fields]
in GHC.WebCore.Sigs),

    data T = T Int (T ->{w} Int)

cannot be raised: its product's components are (Int, T ->{w} Int), the
second is w itself, and w's new type would be  Int -> w -> Int,  an infinite
type.  So a web whose product's components mention a web that would be
raised in the same round is not raised (nor is that one, if it is the same
web).  Raising both of two webs whose components mention each other would
loop the same way.  A web raised in an earlier round is no problem: the
type rewrite then reaches the components too.  Mentioning the type itself
is no problem either (T = (Int, (T, Int) ->{w} Int)): T is nominal, and its
field changes with w.  A named type for the web (a newtype) would let it be
raised: see WEBS-BACKLOG.md.  Result raising does the same (Note [Result
raising]).
-}

data Verdict = Raised | Rejected Reason

data Reason = Exposed | NotProduct | Lazy | Curried | RepPoly | Coercion' | CoVarParam
            | KnownCalls | BoxNeeded | Recursive

instance Outputable Verdict where
  ppr Raised       = text "raised"
  ppr (Rejected r) = text "rejected" <+> parens (ppr r)

instance Outputable Reason where
  ppr Exposed    = text "exposed"
  ppr NotProduct = text "argument not a product"
  ppr Lazy       = text "lazy in its argument"
  ppr Curried    = text "curried: may be partially applied"
  ppr RepPoly    = text "representation-polymorphic component"
  ppr Coercion'  = text "complex coercion"
  ppr CoVarParam = text "coercion parameter"
  ppr KnownCalls = text "only known calls (early: left to worker/wrapper)"
  ppr BoxNeeded  = text "the product is used boxed"
  ppr Recursive  = text "a component mentions a raised web"

-- | The product types we raise: boxed, single-constructor data types without
-- existentials or constraints, that are not classes
productCon :: Type -> Maybe (TyCon, [Type], DataCon)
productCon ty
  | Just (tc, args) <- splitTyConApp_maybe ty
  , isAlgTyCon tc
  , not (isNewTyCon tc)
  , not (isClassTyCon tc)
  , not (isUnboxedTupleTyCon tc)
  , not (isUnboxedSumTyCon tc)
  , Just dc <- tyConSingleDataCon_maybe tc
  , isVanillaDataCon dc
  = Just (tc, args, dc)
  | otherwise
  = Nothing

-- | The type arguments and data constructor of a type that analysis has
-- found to be a product
productOf :: Type -> ([Type], DataCon)
productOf ty = case productCon (coreFullView ty) of
  Just (_, args, dc) -> (args, dc)
  Nothing            -> pprPanic "ArityRaise.productOf" (ppr ty)

-- | The component types of a product type
components :: DataCon -> [Type] -> [Type]
components dc args = map scaledThing (dataConInstArgTys dc args)

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Info = Info
  { i_lams      :: [Id]
  , i_lazy      :: Bool
  , i_curried   :: Bool   -- A (non-join) lambda whose body is another lambda
  , i_covar     :: Bool
  , i_not_prod  :: Bool
  , i_tycons    :: [TyCon]
  , i_rep_poly  :: Bool
  , i_coercion  :: Bool
  , i_unknown   :: Bool    -- Some call of the web is not a known call
  , i_boxed     :: Bool    -- Some lambda needs its parameter boxed
  , i_comp_webs :: WebSet } -- The webs in the product's components

noInfo :: Info
noInfo = Info [] False False False False [] False False False False emptyUniqSet

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams     = i_lams a ++ i_lams b
                    , i_lazy     = i_lazy a     || i_lazy b
                    , i_curried  = i_curried a  || i_curried b
                    , i_covar    = i_covar a    || i_covar b
                    , i_not_prod = i_not_prod a || i_not_prod b
                    , i_tycons   = i_tycons a ++ i_tycons b
                    , i_rep_poly = i_rep_poly a || i_rep_poly b
                    , i_coercion = i_coercion a || i_coercion b
                    , i_unknown  = i_unknown a  || i_unknown b
                    , i_boxed    = i_boxed a    || i_boxed b
                    , i_comp_webs = i_comp_webs a `unionUniqSets` i_comp_webs b }

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

analyse :: FieldTys -> CoreProgram -> Infos
analyse fields binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | JoinPoint arity <- idJoinPointHood b = go_join arity e acc
      | otherwise                            = go e acc

    -- The first 'arity' lambdas of a join point: jumps are always saturated,
    -- so these lambdas may be curried
    go_join :: Int -> CoreExpr -> Infos -> Infos
    go_join 0 e acc = go e acc
    go_join n (Lam b e) acc = go_bndr b (go_join (n-1) e acc)
    go_join n (WebLam w p e) acc = go_lam False w p e (go_join (n-1) e acc)
    go_join _ e acc = go e acc

    -- A lambda that returns another lambda may be partially applied, and
    -- its argument's demand describes full applications only; raising would
    -- force the argument of a partial application.  See Note [Arity raising]
    go_lam can_be_partial w p e acc
      = go_bndr p $
        note w (noInfo { i_lams    = [p]
                       , i_lazy    = not (isStrictIn p e)
                       , i_curried = can_be_partial && is_lam e
                       , i_covar   = isCoVar p
                       , i_boxed   = not (onlyScrutinised p e) }) acc

    is_lam (Tick _ e)     = is_lam e
    is_lam (Lam {})       = True
    is_lam (WebLam {})    = True
    is_lam _              = False

    go :: CoreExpr -> Infos -> Infos
    go (Var {}) acc = acc
    go (Lit {}) acc = acc
    go (App f (Type t)) acc = go f (go_ty t acc)
    go (App f a) acc = go f (go a acc)
    go (WebApp w f a) acc
      | knownHead f = go f (go a acc)
      | otherwise   = note w (noInfo { i_unknown = True }) (go f (go a acc))
    go (Lam b e) acc = go_bndr b (go e acc)
    go (WebLam w p e) acc = go_lam True w p e (go e acc)
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
           in case productCon (coreFullView a) of
                Just (tc, args, dc)
                  | let comps = fields dc args
                        cws   = unionManyUniqSets (map typeWebs comps)
                  -> if all typeHasFixedRuntimeRep comps
                     then note w (noInfo { i_tycons = [tc], i_comp_webs = cws }) acc'
                     else note w (noInfo { i_tycons = [tc], i_rep_poly = True }) acc'
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
        | Nothing <- splitArgCo c1
        -> note w (noInfo { i_coercion = True }) (go_co c1 (go_co c2 acc))
        | otherwise
        -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      _                      -> acc   -- complexCoWebs deals with the others

-- | Does the body use p only as the scrutinee of a case?  Otherwise the
-- raised lambda must rebuild the product (let p = K xs), which allocates it
-- at every call: in nofib spectral/dom-lt, a 46-field state record passed
-- to a continuation was rebuilt on every call, doubling the allocation.
-- Worker/wrapper's boxity analysis avoids the same trap.
onlyScrutinised :: Id -> CoreExpr -> Bool
onlyScrutinised p = go
  where
    go expr = case expr of
      Var v             -> v /= p
      Lit {}            -> True
      App f a           -> go f && go a
      WebApp _ f a      -> go f && go a
      Lam _ e           -> go e
      WebLam _ _ e      -> go e
      Let bind body     -> all go (rhssOfBind bind) && go body
      Case (Var v) b _ alts
        | v == p        -> all (\(Alt _ _ rhs) -> go rhs && not (b `elemVarSet` exprOccurrences rhs)) alts
      Case e _ _ alts   -> go e && all (\(Alt _ _ rhs) -> go rhs) alts
      Cast e _          -> go e
      Tick t e          -> go e && not (tick_mentions t)
      Type {}           -> True
      Coercion {}       -> True

    tick_mentions (Breakpoint { breakpointFVs = ids }) = p `elem` ids
    tick_mentions _ = False

-- | Is the function of a call (the head of the spine) a known function: a
-- variable with an arity, or a join point?
knownHead :: CoreExpr -> Bool
knownHead e = case e of
  App f _      -> knownHead f
  WebApp _ f _ -> knownHead f
  Tick _ f     -> knownHead f
  Var v        -> isJoinId v || idArity v > 0
  _            -> False

-- | Split the coercion between two product types into the coercions between
-- their type arguments: a Refl, or a TyConAppCo of the product type
splitArgCo :: Coercion -> Maybe (TyCon, [Coercion])
splitArgCo co = case co of
  TyConAppCo _ tc cos | isJust (productCon (mkTyConApp tc (map coercionLKind cos)))
                      -> Just (tc, cos)
  Refl t | Just (tc, args, _) <- productCon (coreFullView t)
         -> Just (tc, map mkNomReflCo args)
  GRefl r t MRefl | Just (tc, args, _) <- productCon (coreFullView t)
         -> Just (tc, zipWith mkReflCo (tyConRoleListX r tc) args)
  _ -> Nothing

verdict :: Bool -> WebSet -> WebSet -> WebId -> Info -> Verdict
verdict early exposed complex w i
  | w `elementOfUniqSet` exposed = Rejected Exposed
  | early, not (i_unknown i)     = Rejected KnownCalls   -- Note [Early arity raising]
  | i_covar i                    = Rejected CoVarParam
  | w `elementOfUniqSet` complex = Rejected Coercion'
  | i_coercion i                 = Rejected Coercion'
  | i_not_prod i                 = Rejected NotProduct
  | not (same_tycon (i_tycons i)) = Rejected NotProduct
  | i_rep_poly i                 = Rejected RepPoly
  | i_lazy i                     = Rejected Lazy
  | i_curried i                  = Rejected Curried
  | i_boxed i                    = Rejected BoxNeeded
  | otherwise                    = Raised
  where
    same_tycon (tc:tcs) = all (== tc) tcs
    same_tycon []       = False

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse the program and raise the webs that qualify.  Each raised web
-- loses its product arrows, so one round is enough; webs in 'done' have
-- already been raised and are not considered again.
arityRaiseRound :: FieldTys    -- ^ Components' types (Note [Signatures follow
                               --   the transformations] in GHC.WebCore.HiddenFields)
                -> UniqSupply
                -> WebSet      -- ^ Exposed webs
                -> UnfoldingPolicy
                -> WebSet      -- ^ Webs already raised
                -> CoreProgram
                -> (Maybe (CoreProgram, WebSet, Type -> Type), [(WebId, SDoc, Bool, [Id])])
arityRaiseRound fields us exposed pol done binds
  | isEmptyUniqSet todo = (Nothing, dump)
  | otherwise           = ( Just ( initUs_ us1 (rewriteProgram fields todo inner pol binds), todo
                                 , raiseType fields todo inner )
                          , dump )
  where
    infos   = analyse fields binds
    complex = complexCoWebs binds
    verdicts0 = [ (w, verdict (up_early pol) exposed complex w i, i)
                | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
                , let w = mkWebId u
                , not (null (i_lams i))
                , not (w `elementOfUniqSet` done) ]
    -- Note [Recursive products]
    candidates = mkUniqSet [ w | (w, Raised, _) <- verdicts0 ]
    verdicts = [ (w, v', i)
               | (w, v, i) <- verdicts0
               , let v' | Raised <- v
                        , not (isEmptyUniqSet (i_comp_webs i `intersectUniqSets` candidates))
                        = Rejected Recursive
                        | otherwise = v ]
    todo = mkUniqSet [ w | (w, Raised, _) <- verdicts ]
    -- Fresh webs for the new arrows, per raised web
    (us1, us2) = splitUniqSupply us
    inner_map  = listToUFM [ (w, map mkWebId (uniqsFromSupply s))
                           | ((w, Raised, _), s) <- zip verdicts (listSplitUniqSupply us2) ]
    inner w    = lookupWithDefaultUFM inner_map [] w
    dump = [ (w, ppr v, w `elementOfUniqSet` todo, i_lams i) | (w, v, i) <- verdicts ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

type Env = IdEnv Id

raiseType :: FieldTys -> WebSet -> InnerWebs -> Type -> Type
raiseType fields todo inner = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_mult = m, ft_arg = a, ft_res = r }
        | w `elementOfUniqSet` todo
        , Just (_, args, dc) <- productCon (coreFullView a)
        -> curriedTy w (inner w) m (fields dc (map go args)) (go r)
        | otherwise -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) (raiseCo fields todo inner co)
      CoercionTy co   -> CoercionTy (raiseCo fields todo inner co)
      _               -> ty

-- | The webs of the new arrows of a raised web (all but its last), the same
-- wherever the web occurs.  See Note [Raised arguments are curried]
type InnerWebs = WebId -> [WebId]

-- | The arrows that take a raised product's components, one by one; the
-- last one is the web's.  A product with no components becomes one (# #)
-- argument.  See Note [Raised arguments are curried]
curriedTy :: WebId -> [WebId] -> Mult -> [Type] -> Type -> Type
curriedTy w ws m comps r = case comps of
  [] -> let tup = mkTupleTy Unboxed [] in mkWebFunTy w (chooseFunTyFlag tup r) m tup r
  _  -> foldr arrow (mkWebFunTy w (chooseFunTyFlag cn r) m cn r) (zip ws (init comps))
  where
    cn = last comps
    arrow (wi, c) t = mkWebFunTy wi (chooseFunTyFlag c t) m c t

-- | The coercion version of 'curriedTy', from the components' coercions
curriedCo :: WebId -> [WebId] -> Role -> Coercion -> [Coercion] -> Coercion -> Coercion
curriedCo w ws r m comp_cos res_co = case comp_cos of
  [] -> let tup = mkTyConAppCo r (tupleTyCon Unboxed 0) [] in fun_co (mkWebFunCo2 w) tup res_co
  _  -> foldr (\(wi, c) t -> fun_co (mkWebFunCo2 wi) c t)
              (fun_co (mkWebFunCo2 w) (last comp_cos) res_co)
              (zip ws (init comp_cos))
  where
    fun_co mk a b = let Pair la ra = coercionKind a
                        Pair lb rb = coercionKind b
                    in mk r (chooseFunTyFlag la lb) (chooseFunTyFlag ra rb) m a b

raiseCo :: FieldTys -> WebSet -> InnerWebs -> Coercion -> Coercion
raiseCo fields todo inner = go
  where
    goTy = raiseType fields todo inner
    go co = case co of
      Refl t              -> Refl (goTy t)
      GRefl r t mco       -> GRefl r (goTy t) mco
      TyConAppCo r tc cos -> TyConAppCo r tc (map go cos)
      AppCo c1 c2         -> AppCo (go c1) (go c2)
      ForAllCo { fco_body = c } -> co { fco_body = go c }
      FunCo { fco_role = r, fco_web = w, fco_mult = m, fco_arg = ca, fco_res = cr }
        | w `elementOfUniqSet` todo
        , Just (_, arg_cos) <- splitArgCo ca
        , Just (_, _, dc) <- productCon (coercionLKind ca)
        -> curriedCo w (inner w) r m (componentCos r dc (map go arg_cos)) (go cr)
        | otherwise -> co { fco_arg = go ca, fco_res = go cr }
      AxiomCo ax cos      -> AxiomCo ax (map go cos)
      SymCo c             -> SymCo (go c)
      TransCo c1 c2       -> TransCo (go c1) (go c2)
      SubCo c             -> SubCo (go c)
      _                   -> co

-- | The coercion between the unboxed tuples of the components of two
-- instances of a product type, given the coercions between their type
-- arguments: lift the components' types over those coercions
componentsTupleCo :: Role -> DataCon -> [Coercion] -> Coercion
componentsTupleCo r dc arg_cos
  = mkTyConAppCo r (tupleTyCon Unboxed (length comp_cos)) (reps ++ comp_cos)
  where
    comp_cos = componentCos r dc arg_cos
    reps     = map (mkNomReflCo . getRuntimeRep . coercionLKind) comp_cos

-- | The coercions between the components of two instances of a product type
componentCos :: Role -> DataCon -> [Coercion] -> [Coercion]
componentCos r dc arg_cos
  = map (liftCoSubstWith r (dataConUnivTyVars dc) arg_cos)
        (map scaledThing (dataConRepArgTys dc))

rewriteProgram :: FieldTys -> WebSet -> InnerWebs -> UnfoldingPolicy -> CoreProgram
               -> UniqSM CoreProgram
rewriteProgram fields todo inner pol binds
  = do { let env = mkVarEnv [ (b, rw_bndr b) | b <- bindersOfBinds binds ]
       ; mapM (rw_top env) binds }
  where
    upTy = raiseType fields todo inner
    upCo = raiseCo fields todo inner
    is_todo w = w `elementOfUniqSet` todo

    rw_top env (NonRec b e) = NonRec (lookup_bndr env b) <$> rw env e
    rw_top env (Rec prs)    = Rec <$> sequence [ (,) (lookup_bndr env b) <$> rw env e
                                               | (b, e) <- prs ]

    lookup_bndr env v = fromMaybe v (lookupVarEnv env v)

    -- A product argument becomes its components, curried: the arity grows
    -- by the number of components less one, for each raised argument it
    -- covers (Note [Raised arguments are curried])
    rw_bndr :: Var -> Var
    rw_bndr b
      | not (isId b)         = b
      | not (changed old_ty) = fixUnfolding pol changed_set b
      | otherwise            = fixUnfolding pol changed_set $
                               fixBinderInfo b new_ty (\_ n -> reshapeArity fates n) fates
      where
        old_ty = idType b
        new_ty = upTy old_ty
        fates  = raisedFates old_ty

    -- The fate of each value argument of a type: a raised product with k > 0
    -- components is split into k arguments
    raisedFates ty = case coreFullView ty of
      ForAllTy _ t -> raisedFates t
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        | is_todo w
        , Just (_, args, dc) <- productCon (coreFullView a)
        , let k = length (fields dc args)
        , k > 0
        -> SplitArg k : raisedFates r
        | otherwise -> KeepArg : raisedFates r
      _ -> []

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

    rw_bndr1 env b = (extendVarEnv env b b', b') where b' = rw_bndr b

    rw_bndrs env bs = (extendVarEnvList env (zip bs bs'), bs')
      where bs' = map rw_bndr bs

    ---------------
    rw :: Env -> CoreExpr -> UniqSM CoreExpr
    rw env expr = case expr of
      Var v        -> return (Var (lookup_bndr env v))
      Lit l        -> return (Lit l)
      App f a      -> App <$> rw env f <*> rw env a
      Lam b e      -> let (env', b') = rw_bndr1 env b in Lam b' <$> rw env' e

      WebLam w p e
        | is_todo w  -> rw_raised_lam env w p e
        | otherwise  -> let (env', p') = rw_bndr1 env p in WebLam w p' <$> rw env' e

      WebApp {}    -> do { (wrap, e') <- rw_spine env expr; return (wrap e') }

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

    -- An application spine.  The cases that take raised arguments apart
    -- wrap the whole spine, so that a jump stays in tail position:
    --   jump j x y  ==>  case x of K ys -> jump j (# ys #) y
    rw_spine :: Env -> CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    rw_spine env expr = case expr of
      WebApp w f x
        -> do { (wrap, f') <- rw_spine env f
              ; x' <- rw env x
              ; if is_todo w
                then do { (wrap', call) <- rw_raised_call w f' x'
                        ; return (wrap . wrap', call) }
                else return (wrap, WebApp w f' x') }
      App f a
        -> do { (wrap, f') <- rw_spine env f
              ; a' <- rw env a
              ; return (wrap, App f' a') }
      _ -> do { e' <- rw env expr; return (id, e') }

    rw_tick env t@(Breakpoint { breakpointFVs = ids })
      = t { breakpointFVs = map (lookup_bndr env) ids }
    rw_tick _ t = t

    -- \^w p. e  ==>  \x1 .. \^w xn. [let p = K xs in] e'
    -- where e' replaces  case p of b { K ys -> rhs }  by  let ys = xs in rhs
    -- (with no components:  \^w t. case t of (# #) -> e')
    rw_raised_lam env w p e
      = do { let (env1, p') = rw_bndr1 env p
                 p_ty = idType p'
                 (args, dc) = productOf p_ty
                 comp_tys = fields dc args
           ; xs <- mapM (\ty -> do { u <- getUniqueM
                                   ; return (mkSysLocal (fsLit "x") u ManyTy ty) }) comp_tys
           ; e1 <- rw env1 e
             -- Unpack under any further lambdas; see splitLeadingLams
           ; let (lams, body) = splitLeadingLams e1
                 e2 = replaceCases p' dc xs body
                 e3 | p' `elemVarSet` exprOccurrences e2
                    = Let (NonRec p' (mkCoreConApps dc (map Type args ++ map Var xs))) e2
                    | otherwise = e2
                 tup_ty = mkTupleTy Unboxed comp_tys
           ; case xs of
               [] -> do { u <- getUniqueM
                        ; let t = mkSysLocal (fsLit "ut") u ManyTy tup_ty
                        ; wild <- mkWild tup_ty
                        ; return (WebLam w t (lams (Case (Var t) wild (exprType e3)
                                                     [Alt (DataAlt (tupleDataCon Unboxed 0)) [] e3]))) }
               _  -> return (foldr (\(wi, x) b -> WebLam wi x b)
                                   (WebLam w (last xs) (lams e3))
                                   (zip (inner w) (init xs))) }

    -- f @^w (K es)  ==>  f @^w (# es #)
    -- f @^w x       ==>  case x of b { K ys -> f @^w (# ys #) }
    -- Returns the case (to wrap around the whole spine) and the call
    rw_raised_call w f' x'
      | Just (dc, _, vals) <- conApp x'
      , Just (_, _, dc') <- productCon (coreFullView (exprType x'))
      , dc == dc'
      = return (id, curriedCall w f' vals)
      | otherwise
      = do { let x_ty = exprType x'
                 (args, dc) = productOf x_ty
           ; ys <- mapM (\ty -> do { u <- getUniqueM
                                   ; return (mkSysLocal (fsLit "y") u ManyTy ty) })
                        (fields dc args)
           ; b <- mkWild x_ty
           ; let call = curriedCall w f' (map Var ys)
                 wrap body = Case x' b (exprType body) [Alt (DataAlt dc) ys body]
           ; return (wrap, call) }

    -- f @^w (# es #), with the components passed one by one
    curriedCall w f' vals = case vals of
      [] -> WebApp w f' (mkCoreUnboxedTuple [])
      _  -> WebApp w (foldl (\g (wi, v) -> WebApp wi g v) f' (zip (inner w) (init vals)))
                     (last vals)

    -- A saturated application of a data constructor's worker
    conApp e = case collectArgs e of
      (Var v, args)
        | Just dc <- isDataConWorkId_maybe v
        , let (ty_args, vals) = span isTypeArg args
        , length vals == dataConRepArity dc
        -> Just (dc, ty_args, vals)
      _ -> Nothing

-- | Is a lambda strict in its parameter p?  Yes if demand analysis says so,
-- or if the body evidently evaluates p first: it is a case on p, perhaps
-- under ticks and lets.  The second test matters when demand analysis has not
-- run (the early web pipeline; see Note [Early webs] in GHC.WebCore.Pipeline).
isStrictIn :: Id -> CoreExpr -> Bool
isStrictIn p body = isStrUsedDmd (idDemandInfo p) || go body
  where
    go (Case (Var v) _ _ _) = v == p
    go (Case scrut _ _ _)   = go scrut
    go (Tick _ e)           = go e
    go (Let _ e)            = go e
    go (Cast e _)           = go e
    go _                    = False

-- | Replace  case p of b { K ys -> rhs }  by  let b = p; ys = xs in rhs
-- (and  case p of b { DEFAULT -> rhs }  by  let b = p in rhs)
replaceCases :: Id -> DataCon -> [Id] -> CoreExpr -> CoreExpr
replaceCases p dc xs = go
  where
    go expr = case expr of
      Case (Var v) b _ [Alt (DataAlt dc') ys rhs]
        | v == p, dc' == dc
        -> let rhs' = go rhs
           in mkLets (alias b rhs' ++ zipWith (\y x -> NonRec y (Var x)) ys xs) rhs'
      Case (Var v) b _ [Alt DEFAULT [] rhs]
        | v == p
        -> let rhs' = go rhs in mkLets (alias b rhs') rhs'
      Var {}            -> expr
      Lit {}            -> expr
      App f a           -> App (go f) (go a)
      WebApp w f a      -> WebApp w (go f) (go a)
      Lam b e           -> Lam b (go e)
      WebLam w b e      -> WebLam w b (go e)
      Let bind body     -> Let (go_bind bind) (go body)
      Case e b ty alts  -> Case (go e) b ty [ Alt con bs (go rhs) | Alt con bs rhs <- alts ]
      Cast e co         -> Cast (go e) co
      Tick t e          -> Tick t (go e)
      Type {}           -> expr
      Coercion {}       -> expr

    go_bind (NonRec b e) = NonRec b (go e)
    go_bind (Rec prs)    = Rec [ (b, go e) | (b, e) <- prs ]

    -- The case binder is p itself; bind it only if it is used, so that p
    -- need not be re-boxed
    alias b rhs | b `elemVarSet` exprOccurrences rhs = [NonRec b (Var p)]
                | otherwise                          = []
