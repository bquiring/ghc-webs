-- | Useless elimination over webs: a liveness fixpoint over variables, web
-- parameters and web result components, and the rewrite that deletes the
-- dead ones.
--
-- See Note [Useless elimination].
module GHC.WebCore.Transform.Useless
  ( uselessRound
  , liveness
  ) where

import GHC.Prelude

import GHC.Builtin.Types ( unboxedUnitTy, mkTupleTy, tupleDataCon )
import GHC.Core
import GHC.Core.Coercion
import GHC.Core.DataCon ( DataCon, isUnboxedTupleDataCon, dataConRepArity, dataConRepStrictness
                        , isMarkedStrict, dataConTyCon, isVanillaDataCon )
import GHC.Core.FVs ( exprFreeIds )
import GHC.Core.Make ( mkCoreUnboxedTuple, mkCoreConApps, mkAbsentErrorApp )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon ( TyCon, isUnboxedTupleTyCon, tyConDataCons )
import GHC.Core.Type
import GHC.Core.Utils ( exprType )
import GHC.Core.TyCo.Compare ( eqType )


import GHC.Types.Basic ( Boxity(..) )
import GHC.Types.Name ( getOccString )
import GHC.Types.Id
import GHC.Types.Id.Info ( ruleInfoFreeVars, RecSelParent(..) )
import GHC.Data.Pair
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey, getUnique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable
import GHC.Utils.Panic ( pprPanic )

import GHC.WebCore.Traverse ( typeWebs )
import GHC.WebCore.Transform.Common ( UnfoldingPolicy(..), changedBinders, fixUnfolding
                                    , fixBinderInfo, ArgFate(..), argFates, mkWild, exprOccurrences )
import GHC.WebCore.Transform.Inline ( cloneExpr )
import GHC.WebCore.Transform.DeadParams ( Verdict(..), WebInfo(..), analyse, verdictUsed
                                        , needsEval, unboxedUnitExpr )

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List ( sortOn )
import Data.Maybe ( fromMaybe, isJust )
import Data.Word ( Word64 )

{- Note [Useless elimination]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-fcore-webs-useless deletes what no live computation uses, as one least
fixpoint over booleans (the user's design: the dissertation's
"Constraint-Fixpoint Useless Elimination", and useless-elimination.sml in
3cps).  The elements are

  EVar x     a local variable (let-bound, join point, lambda- or case-bound)
  EArg w     the parameter of web w
  ERes w i   component i of web w's result, when w returns an unboxed tuple
             (after result raising, Note [Result raising])

Every element starts dead; it becomes live only with a witness.  The analysis
walks the program with a *live dependency path*: the elements that must all
be live for the current position to be live.  The right-hand side of
let x = rhs is under [x] (if x is dead, so is everything in rhs); the
argument of a call f @^w a is under EArg w : path; component i of a tail
(# e1 .. en #) of a lambda of web w is under ERes w i : path.  Lambda bodies
keep the path (a function can lose every parameter and still run).  Then

  * a use of x under path p:                  x is live if p is
  * \^w x -> ..:                              EArg w is live if x is
  * case (f @^w a) of b { (# y1 .. yn #) -> } ERes w i is live if yi (or b) is
  * a call of w in tail position of a lambda
    of w', returning its result:              ERes w i is live if ERes w' i is
  * a let binder is live only if its own path is (its guard)

and roots (always live): top-level binders, variables in breakpoints and in
the unfoldings and rules of live binders, the parameters and results of
exposed webs, of webs that bind coercion variables or appear in coercions,
and of calls whose result goes anywhere else (an argument, a cast).

Dead lets are deleted.  A web whose parameter is dead loses it, deleted or
turned into (# #) exactly as in dead-parameter elimination (Note
[Dead-parameter elimination]: the same conditions decide between the two).
A web whose result components are partly dead returns only the live ones:
its arrows' result types, its lambdas' tails, the cases on its calls, and
the join points bound in its tails change (as in result raising).  A tail
that returns more components than its lambda now does (a call of a web with
more live components, or anything else of the old tuple type) is adapted:
case e of (# ys #) -> (# live ys #).

Laziness: a dropped lifted argument or component was a thunk that nothing
evaluates; a dropped unlifted one that is not ok for speculation keeps its
evaluation (case e of _ -> ..), and is analysed under the current path, not
the parameter's.  Nothing is evaluated that was not.

Unlike dead-parameter elimination, which runs in rounds over syntactic
occurrences, the fixpoint sees through uses that are themselves dead: two
parameters that only pass each other along, a variable used only in the
argument of a dead parameter.
-}

------------------------------------------------------------------
--      Elements and constraints
------------------------------------------------------------------

data Elem = EVar !Id | EArg !WebId | ERes !WebId !Int
          | EField !DataCon !Int   -- ^ field i of an internal constructor:
                                   --   Note [Dead fields of internal types]

elemKey :: Elem -> (Int, Word64, Int)
elemKey (EVar v)   = (0, getKey (getUnique v), 0)
elemKey (EArg w)   = (1, getKey (getUnique w), 0)
elemKey (ERes w i) = (2, getKey (getUnique w), i)
elemKey (EField dc i) = (3, getKey (getUnique dc), i)

instance Eq Elem where
  a == b = elemKey a == elemKey b

instance Ord Elem where
  compare a b = compare (elemKey a) (elemKey b)

type Path = [Elem]

-- | Root: always live.  Guard: the element is live only if all of these
-- are.  Use: the element is live if all of these are (one witness).
data Con = Root !Elem | Guard !Elem Path | Use !Elem Path

type Cs = [Con] -> [Con]

-- | Is the current expression a tail of a lambda of a web that returns an
-- unboxed tuple?
data Tail = NoTail | Tail !WebId
          | Scrut !DataCon [Id]   -- ^ a tail of the scrutinee of a case with one
                                  --   alternative K xs, whose binder is unused:
                                  --   see Note [Scrutinised constructions]
          | ScrutTup [Id]         -- ^ the same, for an unboxed tuple (# xs #)

-- | The least fixpoint: the live elements
solve :: [Con] -> S.Set Elem
solve cons = loop (S.toList elems) S.empty
  where
    roots  = S.fromList [ e | Root e <- cons ]
    guards = M.fromListWith (++) [ (e, p) | Guard e p <- cons ]
    uses   = M.fromListWith (++) [ (e, [p]) | Use e p <- cons ]
    elems  = S.unions [ roots, M.keysSet guards, M.keysSet uses ]
    -- who mentions whom
    deps = M.fromListWith (++)
             ([ (d, [e]) | (e, p) <- M.toList guards, d <- p ] ++
              [ (d, [e]) | (e, ps) <- M.toList uses, p <- ps, d <- p ])

    holds live e
      =  e `S.member` roots
      || (all (`S.member` live) (M.findWithDefault [] e guards)
          && any (all (`S.member` live)) (M.findWithDefault [] e uses))

    loop [] live = live
    loop (e : rest) live
      | e `S.member` live = loop rest live
      | holds live e      = loop (M.findWithDefault [] e deps ++ rest) (S.insert e live)
      | otherwise         = loop rest live

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

-- | Webs whose result (the result of their arrow) is an unboxed tuple, with
-- its number of components: from every type in the program
resultWebs :: CoreProgram -> UniqFM WebId Int
resultWebs binds = foldr go_bind emptyUFM binds
  where
    go_bind b acc = foldr go_pair acc (flattenBinds [b])
    go_pair (b, e) acc = go_ty (idType b) (go e acc)

    go :: CoreExpr -> UniqFM WebId Int -> UniqFM WebId Int
    go e acc = case e of
      Var v          -> go_ty (idType v) acc
      Lit {}         -> acc
      App f a        -> go f (go a acc)
      WebApp _ f a   -> go f (go a acc)
      Lam b x        -> go_b b (go x acc)
      WebLam _ b x   -> go_b b (go x acc)
      Let b x        -> go_bind b (go x acc)
      Case s b t as  -> go s (go_b b (go_ty t (foldr (\(Alt _ bs r) a -> foldr go_b (go r a) bs) acc as)))
      Cast x _       -> go x acc
      Tick _ x       -> go x acc
      Type t         -> go_ty t acc
      Coercion {}    -> acc

    go_b b acc | isId b    = go_ty (idType b) acc
               | otherwise = acc

    go_ty :: Type -> UniqFM WebId Int -> UniqFM WebId Int
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        -> let acc' = go_ty a (go_ty r acc)
           in case tupleComps r of
                Just cs | not (isPlaceholderWeb w) -> addToUFM acc' w (length cs)
                _ -> acc'
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t _     -> go_ty t acc
      _              -> acc

-- | The components of an unboxed tuple type
tupleComps :: Type -> Maybe [Type]
tupleComps ty = case splitTyConApp_maybe (coreFullView ty) of
  Just (tc, args) | isUnboxedTupleTyCon tc -> Just (drop (length args `div` 2) args)
  _ -> Nothing

-- | Webs that appear in a coercion, or in the type of a coercion variable:
-- their results are not changed (a coercion variable's occurrences in
-- coercions keep its old type; hashable's unsafeIOToST, useless020)
coercionWebs :: CoreProgram -> WebSet
coercionWebs binds = foldr go_bind emptyUniqSet binds
  where
    go_bind b acc = foldr (\(x, e) -> go_b x . go e) acc (flattenBinds [b])
    go e acc = case e of
      App f a        -> go f (go a acc)
      WebApp _ f a   -> go f (go a acc)
      Lam b x        -> go_b b (go x acc)
      WebLam _ b x   -> go_b b (go x acc)
      Let b x        -> go_bind b (go x acc)
      Case s b _ as  -> go_b b (go s (foldr (\(Alt _ bs r) a -> foldr go_b (go r a) bs) acc as))
      Cast x co      -> go x (co_webs co acc)
      Tick _ x       -> go x acc
      Coercion co    -> co_webs co acc
      _              -> acc
    go_b b acc | isCoVar b = acc `unionUniqSets` typeWebs (varType b)
               | otherwise = acc
    co_webs co acc = let Pair l r = coercionKind co
                     in acc `unionUniqSets` typeWebs l `unionUniqSets` typeWebs r

-- | The constraints of the program
constraints :: (DataCon -> Bool) -> UniqFM WebId Int -> CoreProgram -> [Con]
constraints eligible res binds = foldr top [] binds
  where
    arity w = lookupUFM res w

    top bind acc = foldr (\(b, rhs) -> (Root (EVar b) :) . go_rhs b rhs) acc (flattenBinds [bind])

    -- The right-hand side of a binding, under [b]
    go_rhs :: Id -> CoreExpr -> Cs
    go_rhs b rhs = unf_uses b . case idJoinPointHood b of
      JoinPoint n -> go_join n [EVar b] rhs
      NotJoinPoint -> go [EVar b] NoTail rhs

    -- The free variables of a binder's stable unfolding and rules are used
    -- if it is
    unf_uses b = foldr (\v k -> (Use (EVar v) [EVar b] :) . k) id (unf_fvs ++ rule_fvs)
      where unf = realIdUnfolding b
            unf_fvs | isStableUnfolding unf = maybe [] (nonDetEltsUniqSet . exprFreeIds) (maybeUnfoldingTemplate unf)
                    | otherwise             = []
            rule_fvs = filter isLocalId (dVarSetElems (ruleInfoFreeVars (idSpecialisation b)))

    -- A join point's lambdas, then its body, a tail of the enclosing tail
    -- (the caller passes it in go_bind)
    go_join :: Int -> Path -> CoreExpr -> Cs
    go_join n p e = go_join' n p NoTail e

    go_join' :: Int -> Path -> Tail -> CoreExpr -> Cs
    go_join' 0 p tl e              = go p tl e
    go_join' n p tl (Lam _ e)      = go_join' (n - 1) p tl e
    go_join' n p tl (WebLam w x e) = (Use (EArg w) [EVar x] :) . go_join' (n - 1) p tl e
    go_join' _ p tl e              = go p tl e

    go_bind :: Path -> Tail -> CoreBind -> Cs
    go_bind p tl bind = foldr (\(b, rhs) k -> one b rhs . k) id (flattenBinds [bind])
      where
        one b rhs
          | not (isId b) = id
          | otherwise    = (Guard (EVar b) p :) . unf_uses b .
                           case idJoinPointHood b of
                             JoinPoint n  -> go_join' n [EVar b] tl rhs
                             NotJoinPoint -> go [EVar b] NoTail rhs

    tail_of w | isJust (arity w) = Tail w
              | otherwise        = NoTail

    go :: Path -> Tail -> CoreExpr -> Cs
    go p tl expr = case expr of
      Var v | isLocalId v -> (Use (EVar v) p :)
            | Just (RecSelData tc) <- recordSelectorTyCon_maybe v
            , any eligible (tyConDataCons tc)
            -> foldr (.) id [ (Root (EField dc i) :) | dc <- tyConDataCons tc
                                                     , i <- [0 .. dataConRepArity dc - 1] ]
            | otherwise   -> id
      Lit {}       -> id
      Type {}      -> id
      Coercion {}  -> id
      Tick t e
        | tickishIsCode t -> ticks t . go p NoTail e
        | otherwise       -> ticks t . go p tl e
      Cast e _     -> go p NoTail e
      Lam _ e      -> go p NoTail e
      WebLam w x e -> (Use (EArg w) [EVar x] :) . go p (tail_of w) e
      Let bind body -> go_bind p tl bind . go p tl body

      Case scrut b _ alts
        -> scrut_cs . foldr (\(Alt _ _ rhs) k -> go p tl rhs . k) id alts
           . foldr (.) id [ (Use (EField dc i) [EVar x] :)
                          | Alt (DataAlt dc) xs _ <- alts, eligible dc, (i, x) <- zip [0..] xs ]
        where
          scrut_cs
            | Just w <- callWeb scrut, Just n <- arity w
            = go_spine p scrut
              . foldr (.) id [ (Use (ERes w i) [EVar y] :) | Alt (DataAlt _) ys _ <- alts
                                                           , (i, y) <- zip [0..] ys ]
              . foldr (.) id [ (Use (ERes w i) [EVar b] :) | i <- [0 .. n - 1] ]
            | Just (dc, xs) <- scrutCtx scrut b alts
            = go p (Scrut dc xs) scrut
            | Just xs <- scrutTupCtx b alts
            = go p (ScrutTup xs) scrut
            | otherwise
            = go p NoTail scrut

      _ | Scrut dc xs <- tl
        , Just (dc', _, vals) <- conApp expr
        , dc' == dc, length vals == length xs
        -> foldr (.) id [ if fillable dc i v then go (EVar x : p) NoTail v else go p NoTail v
                        | (i, x, v) <- zip3 [0..] xs vals ]
        | ScrutTup xs <- tl
        , Just (_, vals) <- tupleApp expr
        , length vals == length xs
        -> foldr (.) id [ tup_component (EVar x) (Root (EVar x) :) v | (x, v) <- zip xs vals ]
        | Tail tw <- tl
        , Just (_, vals) <- tupleApp expr
        , Just n <- arity tw, length vals == n
        -> foldr (.) id [ component tw i v | (i, v) <- zip [0..] vals ]
        | Just (dc, _, vals) <- conApp expr, eligible dc
        -> foldr (.) id [ if fillable dc i v then go (EField dc i : p) NoTail v else go p NoTail v
                        | (i, v) <- zip [0..] vals ]
        | Just w <- callWeb expr, Just n <- arity w
        -> (case tl of
              Tail tw | arity tw == Just n -> foldr (.) id [ (Use (ERes w i) [ERes tw i] :) | i <- [0 .. n - 1] ]
              ScrutTup xs | length xs == n -> foldr (.) id [ (Use (ERes w i) [EVar x] :) | (i, x) <- zip [0..] xs ]
              _ -> foldr (.) id [ (Root (ERes w i) :) | i <- [0 .. n - 1] ])
           . go_spine p expr
        | otherwise
        -> go_spine p expr
      where
        component tw i v = tup_component (ERes tw i) (Root (ERes tw i) :) v

        -- A component of a returned or scrutinised tuple, under e; one
        -- that must be evaluated is kept (root, if it cannot be evaluated
        -- with a DEFAULT alternative)
        tup_component e root v
          | needsEval v
          = (if isUnboxedTupleType (exprType v) || isUnboxedSumType (exprType v)
             then root else id)
            . go p NoTail v
          | otherwise
          = go (e : p) NoTail v

    -- An application spine: the head, and each argument under its web
    go_spine :: Path -> CoreExpr -> Cs
    go_spine p expr = case expr of
      WebApp w f a -> go_spine p f . go_arg w a
      App f a      -> go_spine p f . go p NoTail a
      Tick t e     -> ticks t . go_spine p e
      _            -> go p NoTail expr
      where
        go_arg w a | needsEval a = go p NoTail a
                   | otherwise   = go (EArg w : p) NoTail a

    ticks t = case t of
      Breakpoint { breakpointFVs = ids } -> foldr (\v k -> (Root (EVar v) :) . k) id ids
      _                                  -> id

-- | The web of a call (not a jump)
callWeb :: CoreExpr -> Maybe WebId
callWeb e = case e of
  WebApp w _ _ | Nothing <- jumpTo e -> Just w
  Tick t e' | not (tickishIsCode t) -> callWeb e'
  _ -> Nothing

jumpTo :: CoreExpr -> Maybe Id
jumpTo e = case e of
  App f _      -> jumpTo f
  WebApp _ f _ -> jumpTo f
  Tick _ f     -> jumpTo f
  Var v | isJoinId v -> Just v
  _            -> Nothing

-- | A saturated unboxed tuple: its type arguments and components
tupleApp :: CoreExpr -> Maybe (DataCon, [CoreExpr])
tupleApp e = case collect e [] of
  (Var v, args)
    | Just dc <- isDataConWorkId_maybe v
    , isUnboxedTupleDataCon dc
    , let vals = dropWhile isTypeArg args
    , length vals == dataConRepArity dc
    -> Just (dc, vals)
  _ -> Nothing
  where
    collect (App f a) as      = collect f (a : as)
    collect (WebApp _ f a) as = collect f (a : as)
    collect (Tick t f) as | not (tickishIsCode t) = collect f as
    collect f as              = (f, as)

{- Note [Dead fields of internal types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A type whose constructors other modules cannot see (hidden fields: the
copies data splitting makes and internal types, Note [Hidden fields] in
GHC.WebCore.Sigs) has all its matches in this module.  So field i of such
a constructor K is an element too, EField K i: it is live if some match on
K binds field i to a live variable, or a record selector of the type
occurs (its match is not in the program).  Each construction of K analyses
its field i under EField K i.  A dead field that is lazy, lifted and needs
no evaluation is replaced by an absent filler (absentError) at every
construction: K's type does not change, but the thunk is not built and what
it would have kept alive is not (a later data unboxing could drop the
slot).  Strict, unlifted and must-evaluate fields are analysed under the
current path and keep their value.
-}

{- Note [Fresh binders for useless elimination]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The elements EVar x are keyed by x's unique.  But Core may bind the same
unique twice, in scopes that do not overlap (GHC's own Core does: nofib
imaginary/gen_regexps binds go1 in two case branches).  The two binding
sites would share an element: a guard from one and uses from the other, and
a live let could be deleted while its uses stay (Web Lint: out of scope).
So each round first copies every top-level right-hand side with fresh
binders (cloneExpr, from super-beta inlining), and analyses and rewrites
the copy.
-}

{- Note [Scrutinised constructions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Result raising re-boxes a raised call that is not scrutinised directly, and
the box is often taken apart at once:

    case (case y of I# y' -> case f y' of (# a, b #) -> (a, b)) of (p, _) -> rhs

The pair's second field is never read, but it is an argument of a data
constructor, a live use, so b and f's second component would stay live.  So
a case with one alternative K xs whose case binder is unused analyses its
scrutinee in a context: a tail of the scrutinee that builds K es (through
lets, cases and join points) passes its value only to this case, and field
i is used only if xs_i is.  Field i is under EVar xs_i.  The rewrite
replaces a dead field with an absent filler (absentError); only lazy,
lifted fields that need no evaluation are treated this way, the others stay
live.  K's type does not change.  The simplifier, after the web pass,
removes the box and the filler (case of known constructor).

A case on an unboxed tuple, (# xs #), does the same, and since the tuple is
not a value anyone else sees, its dead components go instead of being
filled: the scrutinee's tails return only the live ones (as the tails of a
lambda whose result components are dead, Note [Useless elimination]: a
call of a web in such a tail makes ERes w i live if xs_i is, and is adapted
to the live components).  Arity raising wraps calls this way:
case (case x of I# n -> f n) of (# a, _ #) -> ..
-}

-- | The context for the scrutinee of this case, if any
-- See Note [Scrutinised constructions]
scrutCtx :: CoreExpr -> Id -> [CoreAlt] -> Maybe (DataCon, [Id])
scrutCtx _ b [Alt (DataAlt dc) xs rhs]
  | not (isUnboxedTupleDataCon dc)
  , all isId xs
  , not (b `elemVarSet` exprOccurrences rhs)
  = Just (dc, xs)
scrutCtx _ _ _ = Nothing

-- | The context for the scrutinee of a case on an unboxed tuple, if any
-- See Note [Scrutinised constructions]
scrutTupCtx :: Id -> [CoreAlt] -> Maybe [Id]
scrutTupCtx b [Alt (DataAlt dc) xs rhs]
  | isUnboxedTupleDataCon dc
  , not (b `elemVarSet` exprOccurrences rhs)
  = Just xs
scrutTupCtx _ _ = Nothing

-- | The pattern variables of the cases that give their scrutinee a context
scrutVars :: CoreProgram -> [Id]
scrutVars binds = concatMap (go . snd) (flattenBinds binds)
  where
    go e = case e of
      App f a        -> go f ++ go a
      WebApp _ f a   -> go f ++ go a
      Lam _ x        -> go x
      WebLam _ _ x   -> go x
      Let b x        -> concatMap (go . snd) (flattenBinds [b]) ++ go x
      Case s b _ as  -> maybe [] snd (scrutCtx s b as) ++ fromMaybe [] (scrutTupCtx b as)
                        ++ go s ++ concat [ go r | Alt _ _ r <- as ]
      Cast x _       -> go x
      Tick _ x       -> go x
      _              -> []

-- | Can field i of this construction be replaced by an absent filler?
fillable :: DataCon -> Int -> CoreExpr -> Bool
fillable dc i v
  =  not (isMarkedStrict (dataConRepStrictness dc !! i))
  && definitelyLiftedType (exprType v)
  && not (needsEval v)

-- | A saturated application of a data constructor's worker
conApp :: CoreExpr -> Maybe (DataCon, [CoreExpr], [CoreExpr])
conApp e = case collect e [] of
  (Var v, args)
    | Just dc <- isDataConWorkId_maybe v
    , let (ty_args, vals) = span isTypeArg args
    , length vals == dataConRepArity dc
    -> Just (dc, ty_args, vals)
  _ -> Nothing
  where
    collect (App f a) as      = collect f (a : as)
    collect (WebApp _ f a) as = collect f (a : as)
    collect (Tick t f) as | not (tickishIsCode t) = collect f as
    collect f as              = (f, as)

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse the program, solve, and rewrite it.  Webs in 'done' (already
-- turned into unit webs) keep their parameter.
uselessRound :: (TyCon -> Bool)   -- ^ Types with hidden fields
             -> UniqSupply
             -> WebSet            -- ^ Exposed webs
             -> UnfoldingPolicy
             -> WebSet            -- ^ Done: webs already turned into unit webs
             -> CoreProgram
             -> ( Maybe (CoreProgram, WebSet, Type -> Type)
                , [(WebId, SDoc, Bool, [Id])] )
uselessRound hidden us0 exposed pol done binds0
  | isEmptyUniqSet del && isEmptyUniqSet unit && sizeUFM masks == 0 && isEmptyVarSet dead_lets
  , isEmptyVarSet dead_fields, sizeUFM dead_cfields == 0
  = (Nothing, verdicts)
  | otherwise
  = ( Just (initUs_ us (rewriteProgram del unit masks dead_lets dead_fields dead_cfields pol binds), unit
           , dropType del unit masks)
    , verdicts )
  where
    -- Every local binder gets a fresh unique: GHC's Core may bind the same
    -- unique twice in disjoint scopes (two branches), and the elements are
    -- keyed by unique (Note [Fresh binders for useless elimination])
    (us, us1) = splitUniqSupply us0
    binds = initUs_ us1 (mapM fresh_bind binds0)
    fresh_bind (NonRec b e) = NonRec b <$> cloneExpr e
    fresh_bind (Rec prs)    = Rec <$> mapM (\(b, e) -> (,) b <$> cloneExpr e) prs

    early  = up_early pol
    infos  = analyse binds
    res    = resultWebs binds
    co_ws  = coercionWebs binds

    -- A web whose parameter is not deleted even if dead must be live: its
    -- arguments stay, and so must what they use.  So: exposed webs, webs
    -- without lambdas, and webs dead parameters would reject anyway.
    arg_root w = case lookupUFM infos w of
      Just i | not (null (wi_lams i))
        ->  w `elementOfUniqSet` exposed || w `elementOfUniqSet` done
         || wi_covar i || wi_coercion i || wi_eff_tuple i
      _ -> True
    -- Results that stay: exposed webs, webs in coercions, and webs of join
    -- points (a join point bound in a tail returns what that tail does)
    res_root w =  w `elementOfUniqSet` exposed || w `elementOfUniqSet` co_ws
               || case lookupUFM infos w of
                    Just i -> not (null (wi_lams i)) && not (wi_non_join i)
                    Nothing -> False

    eligible dc = hidden (dataConTyCon dc) && isVanillaDataCon dc && not (isUnboxedTupleDataCon dc)
    cons0 = constraints eligible res binds
    arg_webs = mkUniqSet [ w | EArg w <- concatMap con_elems cons0 ] :: WebSet
    con_elems c = case c of
      Root e    -> [e]
      Guard e p -> e : p
      Use e p   -> e : p
    roots =  [ Root (EArg w) | w <- nonDetEltsUniqSet arg_webs, arg_root w ]
          ++ [ Root (ERes w k) | (u, n) <- nonDetUFMToList res, let w = mkWebId u
                               , res_root w, k <- [0 .. n - 1] ]
    cons = roots ++ cons0
    live = solve cons
    is_live e = e `S.member` live

    -- Webs whose parameter is dead
    arg_verdicts = [ (w, v, wi_lams i)
                   | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
                   , let w = mkWebId u
                   , not (null (wi_lams i))
                   , not (w `elementOfUniqSet` done)
                   , let v = verdictUsed early exposed w i (is_live (EArg w)) ]
    del  = mkUniqSet [ w | (w, Delete, _)  <- arg_verdicts ]
    unit = mkUniqSet [ w | (w, Unit {}, _) <- arg_verdicts ]

    -- Webs whose result components are partly dead
    masks :: UniqFM WebId [Bool]
    masks = listToUFM [ (w, m) | (u, n) <- nonDetUFMToList res
                               , let w = mkWebId u
                               , not (res_root w)
                               , let m = [ is_live (ERes w k) | k <- [0 .. n - 1] ]
                               , not (and m) ]

    -- Dead local lets
    dead_lets = mkVarSet [ b | Guard (EVar b) _ <- cons, not (is_live (EVar b)) ]
    -- Dead pattern variables of scrutinised constructions whose field could
    -- be filled (Note [Scrutinised constructions])
    dead_fields = mkVarSet [ x | x <- scrutVars binds, not (is_live (EVar x)) ]
    -- Dead fields of internal constructors (Note [Dead fields of internal types])
    dead_cfields :: UniqFM DataCon [Int]
    dead_cfields = listToUFM_C (++) [ (dc, [i]) | (dc, i) <- dead_list ]
    dead_list = sortOn (\(dc, i) -> (getOccString dc, i))
                  [ (dc, i) | EField dc i <- S.toList all_fields, not (is_live (EField dc i)) ]
    all_fields = S.fromList [ e | c <- cons0, e@(EField {}) <- con_elems c ]

    verdicts = [ (w, ppr v <> res_doc w, changed v || isJust (lookupUFM masks w), bs)
               | (w, v, bs) <- arg_verdicts ]
               ++ [ (placeholderWeb, text "dead fields:" <+> hsep [ ppr dc <> char '#' <> int i | (dc, i) <- dead_list ]
                    , True, [])
                  | not (null dead_list) ]
    res_doc w = case lookupUFM masks w of
      Just m  -> text ", dead results" <+> hsep [ int k | (k, False) <- zip [0 :: Int ..] m ]
                 <+> text "of" <+> int (length m)
      Nothing -> empty
    changed Delete   = True
    changed (Unit _) = True
    changed _        = False

-- | Liveness alone, for other passes: is the parameter of this web live,
-- and is field i of this constructor live?  Elements without a constraint
-- (a constructor of a type that is not internal) count as live.
-- See Note [Strict and live] in GHC.WebCore.Transform.Strictness
liveness :: (TyCon -> Bool)   -- ^ Types with hidden fields
         -> WebSet            -- ^ Exposed webs
         -> UniqSupply -> CoreProgram
         -> (WebId -> Bool, DataCon -> Int -> Bool)
liveness hidden exposed us0 binds0 = (live_arg, live_field)
  where
    binds = initUs_ us0 (mapM fresh_bind binds0)   -- Note [Fresh binders for useless elimination]
    fresh_bind (NonRec b e) = NonRec b <$> cloneExpr e
    fresh_bind (Rec prs)    = Rec <$> mapM (\(b, e) -> (,) b <$> cloneExpr e) prs
    infos = analyse binds
    res   = resultWebs binds
    co_ws = coercionWebs binds
    eligible dc = hidden (dataConTyCon dc) && isVanillaDataCon dc && not (isUnboxedTupleDataCon dc)
    cons0 = constraints eligible res binds
    con_elems c = case c of
      Root e    -> [e]
      Guard e p -> e : p
      Use e p   -> e : p
    arg_webs = mkUniqSet [ w | EArg w <- concatMap con_elems cons0 ] :: WebSet
    arg_root w = case lookupUFM infos w of
      Just i | not (null (wi_lams i))
        -> w `elementOfUniqSet` exposed || wi_covar i || wi_coercion i || wi_eff_tuple i
      _ -> True
    res_root w = w `elementOfUniqSet` exposed || w `elementOfUniqSet` co_ws
    roots =  [ Root (EArg w) | w <- nonDetEltsUniqSet arg_webs, arg_root w ]
          ++ [ Root (ERes (mkWebId u) k) | (u, n) <- nonDetUFMToList res
                                         , res_root (mkWebId u), k <- [0 .. n - 1] ]
    live = solve (roots ++ cons0)
    known = S.fromList (concatMap con_elems cons0)
    live_arg w = not (EArg w `S.member` known) || EArg w `S.member` live
    live_field dc i = not (EField dc i `S.member` known) || EField dc i `S.member` live

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

type Env = IdEnv Id

-- | Drop the deleted webs' arrows, replace the unit webs' arguments with
-- (# #), and keep only the live components of masked webs' results
dropType :: WebSet -> WebSet -> UniqFM WebId [Bool] -> Type -> Type
dropType del unit masks = go
  where
    go ty = case ty of
      FunTy { ft_web = w, ft_mult = m, ft_arg = a, ft_res = r }
        | w `elementOfUniqSet` del  -> r'
        | w `elementOfUniqSet` unit -> mkWebFunTy w (chooseFunTyFlag unboxedUnitTy r') m unboxedUnitTy r'
        | otherwise                 -> ty { ft_arg = go a, ft_res = r' }
        where r' = mask_res w (go r)
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) (dropCo del unit co)
      CoercionTy co   -> CoercionTy (dropCo del unit co)
      _               -> ty

    mask_res w r = case lookupUFM masks w of
      Just m | Just cs <- tupleComps r -> mkTupleTy Unboxed [ c | (c, True) <- zip cs m ]
      _ -> r

-- | Coercions: only deleted and unit webs' arrows change (masked webs do
-- not appear in coercions: see res_root)
dropCo :: WebSet -> WebSet -> Coercion -> Coercion
dropCo del unit = go
  where
    goTy = dropType del unit emptyUFM
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
      _                   -> co

rewriteProgram :: WebSet -> WebSet -> UniqFM WebId [Bool] -> VarSet -> VarSet -> UniqFM DataCon [Int]
               -> UnfoldingPolicy -> CoreProgram -> UniqSM CoreProgram
rewriteProgram del unit masks dead_lets dead_fields dead_cfields pol binds
  = do { let env = mkVarEnv [ (b, rw_bndr b) | b <- bindersOfBinds binds ]
       ; mapM (rw_top env) binds }
  where
    is_del w  = w `elementOfUniqSet` del
    is_unit w = w `elementOfUniqSet` unit
    mask w    = lookupUFM masks w

    dropTy = dropType del unit masks
    dropCo' = dropCo del unit

    changesType ty = not (isEmptyUniqSet (typeWebs ty `intersectUniqSets` touched))
    touched = del `unionUniqSets` unit `unionUniqSets` mkUniqSet (map mkWebId (nonDetKeysUFM masks))

    -- See Note [Unfoldings and rules after a transformation]
    -- in GHC.WebCore.Transform.Common
    changed_set = changedBinders changesType binds

    rw_top env (NonRec b e) = NonRec (lookup_bndr env b) <$> rw env e
    rw_top env (Rec prs)    = Rec <$> sequence [ (,) (lookup_bndr env b) <$> rw env e | (b, e) <- prs ]

    lookup_bndr env v = fromMaybe v (lookupVarEnv env v)

    ---------------
    rw_bndr :: Var -> Var
    rw_bndr b
      | not (isId b) = b
      | otherwise
      = fixUnfolding pol changed_set $
        if changesType old_ty then fix_info (setIdType b (dropTy old_ty)) else b
      where
        old_ty = idType b
        fix_info b' = fixBinderInfo b' (idType b') new_arity (argFates fate old_ty)
        new_arity is_join n = n - deletedArrows is_join n old_ty
        fate w _ | is_del w  = DropArg
                 | is_unit w = AbsentArg
                 | otherwise = KeepArg

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
          | is_del w  = 1 + go_n (n-1) r
          | otherwise = go_n (n-1) r
        go_n _ _ = 0

    rw_bndr1 env b = (extendVarEnv env b b', b') where b' = rw_bndr b
    rw_bndrs env bs = (extendVarEnvList env (zip bs bs'), bs') where bs' = map rw_bndr bs

    ---------------
    rw :: Env -> CoreExpr -> UniqSM CoreExpr
    rw env expr
      | Just (dc, _, vals) <- conApp expr
      , Just dead <- lookupUFM dead_cfields dc
      , or [ i `elem` dead && fillable dc i v | (i, v) <- zip [0..] vals ]
      = rw_con env dc dead expr
    rw env expr = case expr of
      Var v        -> return (Var (lookup_bndr env v))
      Lit l        -> return (Lit l)
      App f a      -> App <$> rw env f <*> rw env a
      Lam b e      -> let (env', b') = rw_bndr1 env b in Lam b' <$> rw env' e
      WebLam w x e
        | Just _ <- mask w -> rw_lam env w x e (\env' e' -> rw_tail env' w e')
        | otherwise        -> rw_lam env w x e rw
      WebApp w f a -> rw_app env w f a
      Let bind body -> do { (env', mb) <- rw_bind env bind; mkLets mb <$> rw env' body }
      Case scrut b ty alts -> rw_case env scrut b ty alts (dropTy ty) rw
      Cast e co    -> (\e' -> Cast e' (dropCo' co)) <$> rw env e
      Tick t e     -> Tick (rw_tick env t) <$> rw env e
      Type t       -> return (Type (dropTy t))
      Coercion co  -> return (Coercion (dropCo' co))

    -- A web lambda: deleted, unit, or kept; its body rewritten by k
    rw_lam env w x e k
      | is_del w  = k env e
      | is_unit w = WebLam w (setIdType x unboxedUnitTy) <$> k env e
      | otherwise = let (env', x') = rw_bndr1 env x in WebLam w x' <$> k env' e

    rw_app env w f a
      | is_del w  = do { f' <- rw env f; keepEval env a f' }
      | is_unit w = do { f' <- rw env f; keepEval env a (WebApp w f' unboxedUnitExpr) }
      | otherwise = WebApp w <$> rw env f <*> rw env a

    -- Dead lets go
    rw_bind :: Env -> CoreBind -> UniqSM (Env, [CoreBind])
    rw_bind env (NonRec b rhs)
      | b `elemVarSet` dead_lets = return (env, [])
      | otherwise
      = do { rhs' <- rw_rhs env b rhs
           ; let (env', b') = rw_bndr1 env b
           ; return (env', [NonRec b' rhs']) }
    rw_bind env (Rec prs)
      = do { let prs1 = [ pr | pr@(b, _) <- prs, not (b `elemVarSet` dead_lets) ]
                 (env', bs') = rw_bndrs env (map fst prs1)
           ; rhss' <- sequence [ rw_rhs env' b rhs | (b, rhs) <- prs1 ]
           ; return (env', [ Rec (zip bs' rhss') | not (null prs1) ]) }

    rw_rhs env b rhs = case idJoinPointHood b of
      JoinPoint n -> rw_join_rhs n env (\env' e -> rw env' e) rhs
      NotJoinPoint -> rw env rhs

    -- A join point's lambdas, then its body with k
    rw_join_rhs :: Int -> Env -> (Env -> CoreExpr -> UniqSM CoreExpr) -> CoreExpr -> UniqSM CoreExpr
    rw_join_rhs 0 env k e = k env e
    rw_join_rhs n env k (Lam b e) = let (env', b') = rw_bndr1 env b in Lam b' <$> rw_join_rhs (n - 1) env' k e
    rw_join_rhs n env k (WebLam w x e) = rw_lam env w x e (\env' e' -> rw_join_rhs (n - 1) env' k e')
    rw_join_rhs _ env k e = k env e

    -- A case; for a case on a masked call, only the live components are bound
    rw_case env scrut b _ty alts new_ty k
      | Just w <- callWeb scrut, Just m <- mask w
      = do { scrut' <- rw env scrut
           ; let new_tup = exprType scrut'
           ; wild <- mkWild new_tup
           ; alts' <- sequence
               [ case con of
                   DataAlt _ -> do { let ys1 = [ y | (y, True) <- zip ys m ]
                                         (env', ys') = rw_bndrs env ys1
                                   ; Alt (DataAlt (tupleDataCon Unboxed (length ys'))) ys' <$> k env' rhs }
                   _         -> Alt con [] <$> k env rhs
               | Alt con ys rhs <- alts ]
           ; return (Case scrut' wild new_ty alts') }
      | Just xs <- scrutTupCtx b alts
      , let m = [ not (x `elemVarSet` dead_fields) | x <- xs ]
      , not (and m)
      = do { scrut' <- rw_tail_m env m scrut
           ; wild <- mkWild (exprType scrut')
           ; alts' <- sequence
               [ case con of
                   DataAlt _ -> do { let (env', ys') = rw_bndrs env [ y | (y, True) <- zip ys m ]
                                   ; Alt (DataAlt (tupleDataCon Unboxed (length ys'))) ys' <$> k env' rhs }
                   _         -> Alt con [] <$> k env rhs
               | Alt con ys rhs <- alts ]
           ; return (Case scrut' wild new_ty alts') }
      | otherwise
      = do { scrut' <- case scrutCtx scrut b alts of
                         Just (dc, xs) | any (`elemVarSet` dead_fields) xs -> rw_scrut env dc xs scrut
                         _ -> rw env scrut
           ; let (env', b') = rw_bndr1 env b
           ; alts' <- sequence [ Alt con bs' <$> k env'' rhs
                               | Alt con bs rhs <- alts
                               , let (env'', bs') = rw_bndrs env' bs ]
           ; return (Case scrut' b' new_ty alts') }

    -- A tail of a scrutinee in the context of K xs: dead fields of K's
    -- constructions become absent fillers (Note [Scrutinised constructions])
    rw_scrut :: Env -> DataCon -> [Id] -> CoreExpr -> UniqSM CoreExpr
    rw_scrut env dc xs expr = case expr of
      Let bind body
        -> do { (env', mb) <- rw_bind_with env (rw_scrut `flip3` (dc, xs)) bind
              ; mkLets mb <$> rw_scrut env' dc xs body }
      Case scrut b ty alts
        -> rw_case env scrut b ty alts (dropTy ty) (\env' e -> rw_scrut env' dc xs e)
      Tick t e | not (tickishIsCode t) -> Tick (rw_tick env t) <$> rw_scrut env dc xs e
      _ | Just (dc', ty_args, vals) <- conApp expr
        , dc' == dc, length vals == length xs
        -> do { ty_args' <- mapM (rw env) ty_args
              ; vals' <- sequence [ if x `elemVarSet` dead_fields && fillable dc i v
                                    then return (mkAbsentErrorApp (dropTy (exprType v)) "useless field")
                                    else rw env v
                                  | (i, x, v) <- zip3 [0..] xs vals ]
              ; return (mkCoreConApps dc (ty_args' ++ vals')) }
        | otherwise -> rw env expr

    flip3 f (dc, xs) env e = f env dc xs e

    -- A construction of K whose dead fields become absent fillers, keeping
    -- the application spine (and its webs)
    rw_con :: Env -> DataCon -> [Int] -> CoreExpr -> UniqSM CoreExpr
    rw_con env dc dead expr = fst <$> go_spine expr
      where
        n = dataConRepArity dc
        -- returns the rewritten spine and the number of value arguments in it
        go_spine e = case e of
          App f a | isTypeArg a -> do { (f', k) <- go_spine f; a' <- rw env a; return (App f' a', k) }
          App f a     -> do { (f', k) <- go_spine f; a' <- field k a; return (App f' a', k + 1) }
          WebApp w f a -> do { (f', k) <- go_spine f; a' <- field k a; return (WebApp w f' a', k + 1) }
          Tick t f    -> do { (f', k) <- go_spine f; return (Tick (rw_tick env t) f', k) }
          _           -> do { e' <- rw env e; return (e', 0) }
        field k a
          | k < n, k `elem` dead, fillable dc k a
          = return (mkAbsentErrorApp (dropTy (exprType a)) "useless field")
          | otherwise = rw env a

    -- A binding whose join points' bodies are rewritten with k
    rw_bind_with env k bind = case bind of
      NonRec j rhs
        | isJoinId j, not (j `elemVarSet` dead_lets)
        -> do { rhs' <- rw_join_rhs (join_arity j) env k rhs
              ; let (env', j') = rw_bndr1 env j
              ; return (env', [NonRec j' rhs']) }
      Rec prs
        | all (isJoinId . fst) prs
        -> do { let prs1 = [ pr | pr@(j, _) <- prs, not (j `elemVarSet` dead_lets) ]
                    (env', js') = rw_bndrs env (map fst prs1)
              ; rhss' <- sequence [ rw_join_rhs (join_arity j) env' k rhs | (j, rhs) <- prs1 ]
              ; return (env', [ Rec (zip js' rhss') | not (null prs1) ]) }
      _ -> rw_bind env bind

    rw_tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lookup_bndr env) ids }
    rw_tick _ t = t

    keepEval :: Env -> CoreExpr -> CoreExpr -> UniqSM CoreExpr
    keepEval env a body
      | needsEval a
      = do { a' <- rw env a
           ; wild <- mkWild (exprType a')
           ; return (Case a' wild (exprType body) [Alt DEFAULT [] body]) }
      | otherwise
      = return body

    ---------------
    -- A tail of a lambda of the masked web tw: returns only its live
    -- components
    rw_tail :: Env -> WebId -> CoreExpr -> UniqSM CoreExpr
    rw_tail env tw = rw_tail_m env (fromMaybe (pprPanic "Useless.rw_tail" (ppr tw)) (mask tw))

    -- A tail that returns only the components live in m
    rw_tail_m :: Env -> [Bool] -> CoreExpr -> UniqSM CoreExpr
    rw_tail_m env m expr = case expr of
      Let bind body
        -> do { (env', mb) <- rw_tail_bind env m bind; mkLets mb <$> rw_tail_m env' m body }
      Case scrut b ty alts
        -> rw_case env scrut b ty alts (tail_ty ty) (\env' e -> rw_tail_m env' m e)
      Tick t e | not (tickishIsCode t) -> Tick (rw_tick env t) <$> rw_tail_m env m e
      _ | Just (_, vals) <- tupleApp expr
        , length vals == length m
        -> do { let keep = [ v | (v, True) <- zip vals m ]
                    drop_eval = [ v | (v, False) <- zip vals m, needsEval v ]
              ; keep' <- mapM (rw env) keep
              ; foldr (\v k -> k >>= keepEval env v) (return (mkCoreUnboxedTuple keep')) drop_eval }
        | Just j <- jumpTo expr, retyped env j
        -> rw env expr
        | Just w <- callWeb expr
        -> do { e' <- rw env expr
              ; adapt e' (fromMaybe all_live (mask w)) }
        | otherwise
        -> do { e' <- rw env expr; adapt e' all_live }
      where
        all_live = map (const True) m
        tail_ty ty = case tupleComps ty of
          Just cs -> mkTupleTy Unboxed [ c | (c, True) <- zip (map dropTy cs) m ]
          Nothing -> dropTy ty

        -- e returns the components live in 'from' (a superset of m)
        adapt e from
          | from == m = return e
          | otherwise
          = do { let e_ty = exprType e
                     comps = fromMaybe (pprPanic "Useless.adapt" (ppr e_ty)) (tupleComps e_ty)
                     idxs = [ k | (k, True) <- zip [0 :: Int ..] from ]
                 ; ys <- mapM (\c -> do { w <- mkWild c; return w }) comps
                 ; wild <- mkWild e_ty
                 ; let ys_kept = [ y | (k, y) <- zip idxs ys, m !! k ]
                 ; return (Case e wild (mkTupleTy Unboxed (map idType ys_kept))
                             [Alt (DataAlt (tupleDataCon Unboxed (length ys))) ys
                                  (mkCoreUnboxedTuple (map Var ys_kept))]) }

    -- A binding in a masked tail: join points bound here return the masked
    -- tuple too
    rw_tail_bind env m bind = case bind of
      NonRec j rhs
        | isJoinId j, not (j `elemVarSet` dead_lets)
        -> do { let j' = retype_join m j
                    env' = extendVarEnv env j j'
              ; rhs' <- rw_join_rhs (join_arity j) env (\env'' e -> rw_tail_m env'' m e) rhs
              ; return (env', [NonRec j' rhs']) }
      Rec prs
        | all (isJoinId . fst) prs
        -> do { let prs1 = [ pr | pr@(j, _) <- prs, not (j `elemVarSet` dead_lets) ]
                    js' = map (retype_join m . fst) prs1
                    env' = extendVarEnvList env (zip (map fst prs1) js')
              ; rhss' <- sequence [ rw_join_rhs (join_arity j) env' (\env'' e -> rw_tail_m env'' m e) rhs
                                  | (j, rhs) <- prs1 ]
              ; return (env', [ Rec (zip js' rhss') | not (null prs1) ]) }
      _ -> rw_bind env bind

    join_arity j = case idJoinPointHood j of
      JoinPoint n  -> n
      NotJoinPoint -> 0

    retyped env j = case lookupVarEnv env j of
      Just j' -> not (idType j' `eqType` idType (rw_bndr j))
      Nothing -> False

    -- j1's type has lost the arrows of deleted parameters, and its join
    -- arity with them (fixBinderInfo): peel j1's arity, not j's
    -- (network: a join point in a masked tail that also lost a parameter)
    retype_join m j = let j1 = rw_bndr j
                      in setIdType j1 (replaceResult (join_arity j1) (idType j1))
      where
        replaceResult :: Int -> Type -> Type
        replaceResult 0 ty = case tupleComps ty of
          Just cs -> mkTupleTy Unboxed [ c | (c, True) <- zip cs m ]
          Nothing -> pprPanic "Useless.replaceResult" (ppr ty)
        replaceResult n ty = case ty of
          ForAllTy b t -> ForAllTy b (replaceResult (n - 1) t)
          ft@FunTy { ft_res = r } -> let r' = replaceResult (n - 1) r
                                     in ft { ft_res = r', ft_af = chooseFunTyFlag (ft_arg ft) r' }
          _ | Just ty' <- coreView ty -> replaceResult n ty'
          _ -> pprPanic "Useless.replaceResult" (ppr ty)
