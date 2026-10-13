-- | Strictness as the dual of liveness: a greatest fixpoint over the same
-- web elements as useless elimination, saying which are always forced.
-- An analysis only, for now: -ddump-webs-forced reports what it proves.
--
-- See Note [Strictness as the dual of liveness].
module GHC.WebCore.Transform.Forced
  ( pprForced
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon ( DataCon, dataConRepStrictness, isMarkedStrict, dataConRepArity, dataConTyCon
                        , isVanillaDataCon, isUnboxedTupleDataCon )
import GHC.Core.TyCon ( TyCon, isUnboxedTupleTyCon, tyConDataCons )
import GHC.Core.Type
import GHC.Core.Utils ( exprType )
import GHC.Core.Opt.Arity ( exprIsDeadEnd )

import GHC.Types.Demand ( isStrUsedDmd, splitDmdSig )
import GHC.Types.Id
import GHC.Types.Id.Info ( RecSelParent(..) )
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey, getUnique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Transform.ArityRaise ( productCon )
import GHC.WebCore.Traverse ( stripWebForms )

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word ( Word64 )
import Data.List ( sortOn )
import GHC.Types.Name ( getOccString )

{- Note [Strictness as the dual of liveness]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Useless elimination (Note [Useless elimination] in
GHC.WebCore.Transform.Useless) asks, of each element, whether it is *ever*
used: a least fixpoint, an element dead until a live use witnesses it.  The
dual asks whether it is *always* used (forced): a greatest fixpoint, an
element strict until some consumer is found that may not force it.  (The
lattice of Sainati et al., "Typing Strictness": unused <= lazy, strict,
indeterminate; here computed on webs.)  The elements are the same:

  FArg w     the parameter of web w: every lambda of w forces it whenever
             its body is evaluated (under full application)
  FRes w i   component i of web w's result (an unboxed tuple, or a product
             returned boxed): every consumer of a call forces it
  FLet x     a local lazy let x = rhs: its body forces x whenever it is
             evaluated

Each element's formula is a conjunction over its sites, built from
'forces x e tl': is x certainly evaluated whenever e is evaluated (to WHNF),
e being in tail context tl?

  x                      true
  case s of alts         forces x s, or (forces x in every alternative; an
                         alternative that is a dead end counts as true)
  let _ = _ in b         forces x b
  call f a1 .. an        forces x f, or, for an argument on web w_k,
                         FArg w_k and forces x a_k; for a global f, the
                         strict arguments of its demand signature; for a
                         constructor, its strict fields
  (# e1 .. en #) or K es in the tail of a lambda of web w
                         for some i, FRes w i and forces x e_i (the
                         consumers force component i)
  jump j as              forces x in j's body (and in the arguments, as a
                         call), once per join point
  a lambda, a literal    false

Sequencing (scrutinee, then alternative; head, then arguments) is a
disjunction; alternatives are a conjunction.  The formulas are monotone, so
the greatest fixpoint exists: start with every element strict, and drop the
ones whose formula is false under the current assumption until nothing
changes.  Starting from "strict" is what makes recursive webs strict, as in
GHC's demand analysis (which starts from bottom).

The sites of FRes w i are the calls of w: a case with one alternative on
its result forces component i if the alternative forces the binder; a call
in the tail of a lambda of w' returning its result forces it if FRes w' i
holds; anything else (a lazy let, an argument, a DEFAULT alternative)
might not.  Exposed webs are lazy (other modules' lambdas and calls are
unknown).

Vacuous strictness: an element with no sites (a web with no calls) is
strict.  Evaluating early what nothing consumes would be wrong if it can
diverge; so the transformations built on this run after useless
elimination, which removes what nothing uses, and never evaluate an element
that is also dead.

What a transformation could do with the solution (not yet built):
  FArg w   evaluate the argument at the calls (call-by-value), as web
           strictness does (Note [Web strictness]);
  FRes w i evaluate component i before returning it; for an unboxed tuple
           component of product type, it can then be raised too (nested
           CPR, which result raising does not do);
  FLet x   evaluate x where it is bound (let to case): strictness at the
           producer, the data-web version of thunk splitting.
This draft only reports, for comparison with web strictness and with GHC's
demand analysis: -ddump-webs-forced.
-}

{- Note [Forced fields]
~~~~~~~~~~~~~~~~~~~~~~~~
Field i of a constructor K of an internal type (hidden fields: Note [Hidden
fields] in GHC.WebCore.Sigs) is an element too, FField K i.  Evaluating it
where K is built is safe only if both sides agree:

  * consumers: every match on K forces field i in its alternative (a match
    where K falls in DEFAULT, or a record selector, forces nothing);
  * producers: every construction of K is in a context that certainly
    evaluates the value built.  A K built and then dropped would otherwise
    evaluate a field the program never touched.

The context of an expression (the 'ctx' formula) says whether its value is
certainly evaluated whenever it is computed: true for a case scrutinee and
for a strict field; FLet x for the right-hand side of let x; FArg w for
the argument of a saturated call of w; FEvald w for a lambda body of w
(FEvald w: every call of w is evaluated, a conjunction over the calls'
contexts); FField K' j for field j of another such construction; false
otherwise.  A result component (FRes) needs no producer side: a lambda's
result always goes back to its call.

'forces' also follows let-bound thunks: if rhs forces x, then once v
(let v = rhs) has been evaluated, so has x, whether v was forced now or
before.  A cycle (a thunk that refers to itself) forces nothing.
-}

------------------------------------------------------------------
--      Elements and formulas
------------------------------------------------------------------

data FElem = FArg !WebId | FRes !WebId !Int | FLet !Id
           | FField !DataCon !Int   -- ^ field i of an internal constructor
           | FEvald !WebId          -- ^ every call of the web is evaluated

fkey :: FElem -> (Int, Word64, Int)
fkey (FArg w)   = (0, getKey (getUnique w), 0)
fkey (FRes w i) = (1, getKey (getUnique w), i)
fkey (FLet x)   = (2, getKey (getUnique x), 0)
fkey (FField dc i) = (3, getKey (getUnique dc), i)
fkey (FEvald w) = (4, getKey (getUnique w), 0)

instance Eq FElem where a == b = fkey a == fkey b
instance Ord FElem where compare a b = compare (fkey a) (fkey b)

-- | Monotone formulas over the elements
data Formula = FTrue | FFalse | FEl !FElem | FAnd [Formula] | FOr [Formula]

fand, forr :: [Formula] -> Formula
fand fs | any isFalse fs = FFalse
        | otherwise      = case filter (not . isTrue) fs of
                             []  -> FTrue
                             [f] -> f
                             gs  -> FAnd gs
forr fs | any isTrue fs  = FTrue
        | otherwise      = case filter (not . isFalse) fs of
                             []  -> FFalse
                             [f] -> f
                             gs  -> FOr gs

isTrue, isFalse :: Formula -> Bool
isTrue FTrue = True
isTrue _     = False
isFalse FFalse = True
isFalse _      = False

mentions :: Formula -> [FElem]
mentions f = case f of
  FEl e   -> [e]
  FAnd fs -> concatMap mentions fs
  FOr fs  -> concatMap mentions fs
  _       -> []

-- | The greatest fixpoint: the elements that are not strict
solve :: M.Map FElem Formula -> S.Set FElem
solve defs = loop (M.keys defs) S.empty
  where
    deps = M.fromListWith (++) [ (d, [e]) | (e, f) <- M.toList defs, d <- mentions f ]
    eval lazy f = case f of
      FTrue   -> True
      FFalse  -> False
      FEl e   -> not (e `S.member` lazy) && M.member e defs
      FAnd fs -> all (eval lazy) fs
      FOr fs  -> any (eval lazy) fs
    loop [] lazy = lazy
    loop (e : rest) lazy
      | e `S.member` lazy = loop rest lazy
      | Just f <- M.lookup e defs, not (eval lazy f)
      = loop (M.findWithDefault [] e deps ++ rest) (S.insert e lazy)
      | otherwise = loop rest lazy

------------------------------------------------------------------
--      Constraints
------------------------------------------------------------------

-- | The result components of webs: unboxed tuples, and products returned
-- boxed (their fields)
resultArity :: Type -> Maybe Int
resultArity ty = case splitTyConApp_maybe (coreFullView ty) of
  Just (tc, args) | isUnboxedTupleTyCon tc -> Just (length args `div` 2)
  _ | Just (_, _, dc) <- productCon ty -> Just (dataConRepArity dc)
  _ -> Nothing

data Tail = NoTail | Tail !WebId !Int

-- | The sites of each element: one formula per site, conjoined
type Sites = M.Map FElem [Formula]

addSite :: FElem -> Formula -> Sites -> Sites
addSite e f = M.insertWith (++) e [f]

constraints :: (DataCon -> Bool) -> WebSet -> CoreProgram -> Sites
constraints eligible exposed binds = foldr top M.empty binds
  where
    top bind acc = foldr (\(_, rhs) -> go emptyVarEnv NoTail FFalse rhs) acc (flattenBinds [bind])

    -- go env tl ctx e: env holds the bodies of the join points and the
    -- right-hand sides of the lazy lets in scope (for 'forces'); ctx says
    -- whether e's value is certainly evaluated whenever e is computed (the
    -- producer side of field strictness: Note [Forced fields])
    go :: IdEnv CoreExpr -> Tail -> Formula -> CoreExpr -> Sites -> Sites
    go env tl ctx expr acc = case expr of
      Var v
        | Just (RecSelData tc) <- recordSelectorTyCon_maybe v
        -> foldr (\dc a -> foldr (\i -> addSite (FField dc i) FFalse) a [0 .. dataConRepArity dc - 1])
                 acc (filter eligible (tyConDataCons tc))
        | otherwise -> acc
      Lit _        -> acc
      Type _       -> acc
      Coercion _   -> acc
      WebLam w x e
        -> let (body, inner) = innerBody expr
               tl' = case inner of
                       Just (w', ty) | Just n <- resultArity ty -> Tail w' n
                       _ -> NoTail
               site | w `elementOfUniqSet` exposed = FFalse
                    | otherwise                    = forces env x tl' body
           in addSite (FArg w) site (go env tl' (FEl (FEvald w)) e acc)
      Lam _ e      -> go env NoTail FFalse e acc
      Let bind body
        -> let prs   = flattenBinds [bind]
               env'  = extendVarEnvList env
                         ([ (j, joinBody j rhs) | (j, rhs) <- prs, isJoinId j ] ++
                          [ (x, rhs) | (x, rhs) <- prs, isLazyLet x ])
               acc1  = foldr (\(x, _) -> addSite (FLet x) (forces env' x tl body)) acc
                             [ pr | pr@(x, _) <- prs, isLazyLet x ]
               acc2  = foldr (\(b, rhs) a -> if isJoinId b then go env' tl ctx rhs a
                                             else go env' NoTail (if isLazyLet b then FEl (FLet b) else FFalse) rhs a)
                             acc1 prs
           in go env' tl ctx body acc2
      Case scrut b _ alts
        -> let acc1 = case (callWebArity scrut, alts) of
                        (Just (w, n), [Alt (DataAlt _) ys rhs])
                          | length ys == n
                          -> foldr (\(i, y) -> addSite (FRes w i) (forces env y tl rhs)) acc (zip [0..] ys)
                        (Just (w, n), _) -> foldr (\i -> addSite (FRes w i) FFalse) acc [0 .. n - 1]
                        _ -> acc
               -- consumers of the fields of internal constructors
               acc2 = case splitTyConApp_maybe (idType b) of
                        Just (tc, _) | any eligible (tyConDataCons tc)
                          -> foldr (consumer env tl alts) acc1 (filter eligible (tyConDataCons tc))
                        _ -> acc1
               acc3 = foldr (\(Alt _ _ rhs) a -> go env tl ctx rhs a) acc2 alts
           in go env NoTail FTrue scrut acc3
      Tick t e | tickishIsCode t -> go env NoTail ctx e acc
               | otherwise       -> go env tl ctx e acc
      Cast e _ -> go env NoTail ctx e acc
      _ | Just (w, n) <- callWebArity expr
        -> let site = case tl of
                        Tail w' n' | n' == n -> \i -> FEl (FRes w' i)
                        _                    -> \_ -> FFalse
           in go_spine env ctx expr (foldr (\i -> addSite (FRes w i) (site i)) acc [0 .. n - 1])
        | otherwise -> go_spine env ctx expr acc

    isLazyLet x = isId x && not (isJoinId x) && definitelyLiftedType (idType x)

    -- A match on an internal type: for each constructor, its alternative
    -- forces field i (or the constructor falls in DEFAULT, which forces
    -- nothing)
    consumer env tl alts dc acc
      = case [ (xs, rhs) | Alt (DataAlt dc') xs rhs <- alts, dc' == dc ] of
          ((xs, rhs) : _) -> foldr (\(i, x) -> addSite (FField dc i) (forces env x tl rhs)) acc (zip [0..] xs)
          [] | any (\(Alt c _ _) -> c == DEFAULT) alts
             -> foldr (\i -> addSite (FField dc i) FFalse) acc [0 .. dataConRepArity dc - 1]
             | otherwise -> acc

    -- An application spine: its value is evaluated as ctx says; each
    -- argument is evaluated if the callee forces it (a saturated call)
    go_spine :: IdEnv CoreExpr -> Formula -> CoreExpr -> Sites -> Sites
    go_spine env ctx expr acc0 = foldr arg acc2 numbered
      where
        (hd, args) = collectSpine expr
        saturated  = not (isFunTy (exprType expr))
        -- each value argument with its index among the value arguments
        numbered   = number 0 args
        number _ [] = []
        number j ((mw, a) : rest)
          | isTypeArg a = number j rest
          | otherwise   = (j, mw, a) : number (j + 1) rest
        n_vals     = length numbered
        -- the result of each web arrow on the spine: the outermost is
        -- evaluated as ctx says, the inner ones (partial applications) are
        -- applied at once
        webs = [ w | (Just w, _) <- args ]
        acc1 = foldr (\(k, w) -> addSite (FEvald w) (if k == length webs - 1 then ctx else FTrue)) acc0
                     (zip [0 :: Int ..] webs)
        -- constructions of internal constructors: the producer side
        acc2 = case hd of
          Var v | Just dc <- isDataConWorkId_maybe v, eligible dc, n_vals == dataConRepArity dc
            -> foldr (\i -> addSite (FField dc i) ctx) acc1 [0 .. n_vals - 1]
          _ -> go env NoTail FFalse hd acc1
        arg (j, mw, a) acc = go env NoTail (arg_ctx j mw) a acc
        arg_ctx j mw = case hd of
          Var v
            | Just dc <- isDataConWorkId_maybe v
            , j < dataConRepArity dc
            -> if isMarkedStrict (dataConRepStrictness dc !! j) then FTrue
               else if eligible dc then FEl (FField dc j) else FFalse
            | isGlobalId v, saturated
            , d : _ <- drop j (fst (splitDmdSig (idDmdSig v)))
            -> if isStrUsedDmd d then FTrue else FFalse
          _ | Just w <- mw, saturated, not (w `elementOfUniqSet` exposed) -> FEl (FArg w)
            | otherwise -> FFalse

    collectSpine e = go_c e []
      where go_c (App f a) as      = go_c f ((Nothing, a) : as)
            go_c (WebApp w f a) as = go_c f ((Just w, a) : as)
            go_c (Tick t f) as | not (tickishIsCode t) = go_c f as
            go_c f as              = (f, as)

    -- The body under a lambda's leading lambdas, and the innermost web
    -- lambda's web with the body's type (that web's result)
    innerBody :: CoreExpr -> (CoreExpr, Maybe (WebId, Type))
    innerBody e = peel Nothing e
      where
        peel _   (WebLam w _ b) = peel (Just w) b
        peel lst (Lam _ b)      = peel lst b
        peel lst b              = (b, fmap (\w -> (w, exprType b)) lst)

    joinBody j rhs = case idJoinPointHood j of
      JoinPoint n -> dropLams n rhs
      NotJoinPoint -> rhs
    dropLams :: Int -> CoreExpr -> CoreExpr
    dropLams 0 e = e
    dropLams n (Lam _ e) = dropLams (n - 1) e
    dropLams n (WebLam _ _ e) = dropLams (n - 1) e
    dropLams _ e = e

-- | Is x certainly evaluated whenever e is (in tail context tl)?
forces :: IdEnv CoreExpr -> Id -> Tail -> CoreExpr -> Formula
forces joins0 x = go emptyVarSet joins0
  where
    go :: VarSet -> IdEnv CoreExpr -> Tail -> CoreExpr -> Formula
    go seen joins tl expr = case expr of
      Var v | v == x    -> FTrue
            | Just body <- lookupVarEnv joins v, not (v `elemVarSet` seen)
                        -- a jump, or a lazy let: evaluating it evaluates its
                        -- right-hand side (Note [Forced fields])
                        -> go (extendVarSet seen v) joins (if isJoinId v then tl else NoTail) body
            | otherwise -> FFalse
      Lit _        -> FFalse
      Type _       -> FFalse
      Coercion _   -> FFalse
      Lam {}       -> FFalse
      WebLam {}    -> FFalse
      Tick t e | tickishIsCode t -> go seen joins NoTail e
               | otherwise       -> go seen joins tl e
      Cast e _     -> go seen joins NoTail e
      Let bind body
        -> let joins' = extendVarEnvList joins
                          [ (j, rhs) | (j, rhs) <- flattenBinds [bind]
                                     , isJoinId j || definitelyLiftedType (idType j) ]
           in go seen joins' tl body
      Case scrut _ _ alts
        -> forr [ go seen joins NoTail scrut
                , fand [ if exprIsDeadEnd (stripWebForms rhs) then FTrue else go seen joins tl rhs
                       | Alt _ _ rhs <- alts ] ]
      _ -> app seen joins tl expr

    -- A call, a jump, or a constructor application
    app seen joins tl expr
      = forr (go seen joins NoTail hd : head_forces ++ ret)
      where
        (hd, args) = collect expr []
        val_args = [ (w, a) | (w, a) <- args, not (isTypeArg a) ]
        head_forces = case hd of
          Var v
            | Just dc <- isDataConWorkId_maybe v
            -> [ go seen joins NoTail a | ((_, a), s) <- zip val_args (dataConRepStrictness dc)
                                        , isMarkedStrict s ]
            | isGlobalId v
            -> [ go seen joins NoTail a | ((_, a), d) <- zip val_args (fst (splitDmdSig (idDmdSig v)))
                                        , isStrUsedDmd d ]
            | isJoinId v, Just body <- lookupVarEnv joins v, not (v `elemVarSet` seen)
            -> go (extendVarSet seen v) joins tl body : web_args
          _ -> web_args
        web_args = [ fand [FEl (FArg w), go seen joins NoTail a] | (Just w, a) <- val_args ]
        -- a construction returned in the tail of a lambda of w: component i
        -- is forced if the consumers force it
        ret = case (tl, hd) of
          (Tail w n, Var v)
            | Just dc <- isDataConWorkId_maybe v
            , length val_args == n
            , dataConRepArity dc == n
            -> [ fand [FEl (FRes w i), go seen joins NoTail a] | (i, (_, a)) <- zip [0..] val_args ]
          _ -> []

    collect (App f a) as      = collect f ((Nothing, a) : as)
    collect (WebApp w f a) as = collect f ((Just w, a) : as)
    collect (Tick t f) as | not (tickishIsCode t) = collect f as
    collect f as              = (f, as)

-- | The web of a call (not a jump) and the number of components of its
-- result, if it returns a product or an unboxed tuple
callWebArity :: CoreExpr -> Maybe (WebId, Int)
callWebArity e = case e of
  WebApp w _ _ | not (isJump e) -> (,) w <$> resultArity (exprType e)
  Tick t e' | not (tickishIsCode t) -> callWebArity e'
  _ -> Nothing
  where
    isJump (App f _) = isJump f
    isJump (WebApp _ f _) = isJump f
    isJump (Tick _ f) = isJump f
    isJump (Var v) = isJoinId v
    isJump _ = False

------------------------------------------------------------------
--      Report
------------------------------------------------------------------

-- | Solve and report: per element kind, how many are strict, and how many
-- of those GHC's demand analysis did not already know (lambda parameters
-- and let binders whose demand is not strict)
pprForced :: (TyCon -> Bool) -> WebSet -> CoreProgram -> SDoc
pprForced hidden exposed binds
  = vcat [ text "Forced (strict) parameters of webs:" <+> int (count isArg strict)
           <+> text "of" <+> int (count isArg all_es)
           <> text "; not known to demand analysis:" <+> int (length new_args)
         , text "Forced result components:" <+> int (count isRes strict)
           <+> text "of" <+> int (count isRes all_es)
         , text "Forced lazy lets:" <+> int (count isLet strict)
           <+> text "of" <+> int (count isLet all_es)
           <> text "; not known to demand analysis:" <+> int (length new_lets)
         , text "Forced fields of internal constructors:" <+> int (count isField strict)
           <+> text "of" <+> int (count isField all_es)
           <> (if null strict_fields then empty
               else colon <+> hsep [ ppr dc <> char '#' <> int i | (dc, i) <- strict_fields ]) ]
  where
    eligible dc = hidden (dataConTyCon dc) && isVanillaDataCon dc && not (isUnboxedTupleDataCon dc)
    sites  = constraints eligible exposed binds
    -- Exposed webs: other modules' lambdas and calls are unknown
    defs   = M.mapWithKey (\e fs -> if is_exposed e then FFalse else fand fs) sites
    is_exposed e = case e of
      FArg w   -> w `elementOfUniqSet` exposed
      FRes w _ -> w `elementOfUniqSet` exposed
      FEvald w -> w `elementOfUniqSet` exposed
      _        -> False
    lazy   = solve defs
    all_es = M.keys defs
    strict = [ e | e <- all_es, not (e `S.member` lazy) ]
    count p = length . filter p
    isArg FArg {} = True
    isArg _       = False
    isRes FRes {} = True
    isRes _       = False
    isLet FLet {} = True
    isLet _       = False
    strict_fields = sortOn (\(dc, i) -> (getOccString dc, i)) [ (dc, i) | FField dc i <- strict ]
    isField FField {} = True
    isField _         = False
    lam_params = lambdaParams binds
    new_args = [ w | FArg w <- strict
                   , any (not . isStrUsedDmd . idDemandInfo) (maybe [] id (lookupUFM lam_params w)) ]
    new_lets = [ x | FLet x <- strict, not (isStrUsedDmd (idDemandInfo x)) ]

-- | The parameters of each web's lambdas
lambdaParams :: CoreProgram -> UniqFM WebId [Id]
lambdaParams binds = foldr (\(_, e) -> go e) emptyUFM (flattenBinds binds)
  where
    go e acc = case e of
      WebLam w x b   -> addToUFM_C (\old new -> new ++ old) (go b acc) w [x]   -- (in any order)
      Lam _ b        -> go b acc
      App f a        -> go f (go a acc)
      WebApp _ f a   -> go f (go a acc)
      Let b x        -> foldr (\(_, r) -> go r) (go x acc) (flattenBinds [b])
      Case s _ _ as  -> go s (foldr (\(Alt _ _ r) -> go r) acc as)
      Cast x _       -> go x acc
      Tick _ x       -> go x acc
      _              -> acc
