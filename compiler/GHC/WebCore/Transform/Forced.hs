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
import GHC.Core.DataCon ( dataConRepStrictness, isMarkedStrict, dataConRepArity )
import GHC.Core.TyCon ( isUnboxedTupleTyCon )
import GHC.Core.Type
import GHC.Core.Utils ( exprIsHNF, exprType )
import GHC.Core.Opt.Arity ( exprIsDeadEnd )

import GHC.Types.Demand ( isStrUsedDmd, splitDmdSig )
import GHC.Types.Id
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

------------------------------------------------------------------
--      Elements and formulas
------------------------------------------------------------------

data FElem = FArg !WebId | FRes !WebId !Int | FLet !Id

fkey :: FElem -> (Int, Word64, Int)
fkey (FArg w)   = (0, getKey (getUnique w), 0)
fkey (FRes w i) = (1, getKey (getUnique w), i)
fkey (FLet x)   = (2, getKey (getUnique x), 0)

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

constraints :: WebSet -> CoreProgram -> Sites
constraints exposed binds = foldr top M.empty binds
  where
    top bind acc = foldr (\(_, rhs) -> go emptyVarEnv NoTail rhs) acc (flattenBinds [bind])

    -- The join points in scope: their bodies, for jumps
    -- go: walk the program, adding sites
    go :: IdEnv CoreExpr -> Tail -> CoreExpr -> Sites -> Sites
    go joins tl expr acc = case expr of
      WebLam w x e
        -> let (body, inner) = innerBody expr
               tl' = case inner of
                       Just (w', ty) | Just n <- resultArity ty -> Tail w' n
                       _ -> NoTail
               site | w `elementOfUniqSet` exposed = FFalse
                    | otherwise                    = forces joins x tl' body
           in addSite (FArg w) site (go joins tl' e acc)
      Lam _ e      -> go joins NoTail e acc
      Let bind body
        -> let joins' = extendVarEnvList joins [ (j, joinBody j rhs) | (j, rhs) <- flattenBinds [bind], isJoinId j ]
               lets = [ x | (x, rhs) <- flattenBinds [bind], isId x, not (isJoinId x)
                          , not (exprIsHNF (stripWebForms rhs)), definitelyLiftedType (idType x) ]
               acc1 = foldr (\x -> addSite (FLet x) (forces joins' x tl body)) acc lets
               acc2 = foldr (\(b, rhs) a -> go joins' (if isJoinId b then tl else NoTail) rhs a) acc1
                            (flattenBinds [bind])
           in go joins' tl body acc2
      Case scrut _ _ alts
        -> let acc1 = case (callWebArity scrut, alts) of
                        (Just (w, n), [Alt (DataAlt _) ys rhs])
                          | length ys == n
                          -> foldr (\(i, y) -> addSite (FRes w i) (forces joins y tl rhs)) acc (zip [0..] ys)
                        (Just (w, n), _) -> foldr (\i -> addSite (FRes w i) FFalse) acc [0 .. n - 1]
                        _ -> acc
               acc2 = foldr (\(Alt _ _ rhs) a -> go joins tl rhs a) acc1 alts
           in go_spine joins scrut acc2
      Tick t e | tickishIsCode t -> go joins NoTail e acc
               | otherwise       -> go joins tl e acc
      Cast e _ -> go joins NoTail e acc
      _ | Just (w, n) <- callWebArity expr
        -> let site = case tl of
                        Tail w' n' | n' == n -> \i -> FEl (FRes w' i)
                        _                    -> \_ -> FFalse
           in go_spine joins expr (foldr (\i -> addSite (FRes w i) (site i)) acc [0 .. n - 1])
        | otherwise -> go_spine joins expr acc

    go_spine joins expr acc = case expr of
      WebApp _ f a -> go_spine joins f (go joins NoTail a acc)
      App f a      -> go_spine joins f (go joins NoTail a acc)
      Tick _ e     -> go_spine joins e acc
      Var _        -> acc
      Lit _        -> acc
      Type _       -> acc
      Coercion _   -> acc
      _            -> go joins NoTail expr acc

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
            | isJoinId v, Just body <- lookupVarEnv joins v, not (v `elemVarSet` seen)
                        -> go (extendVarSet seen v) joins tl body
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
        -> let joins' = extendVarEnvList joins [ (j, rhs) | (j, rhs) <- flattenBinds [bind], isJoinId j ]
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
pprForced :: WebSet -> CoreProgram -> SDoc
pprForced exposed binds
  = vcat [ text "Forced (strict) parameters of webs:" <+> int (count isArg strict)
           <+> text "of" <+> int (count isArg all_es)
           <> text "; not known to demand analysis:" <+> int (length new_args)
         , text "Forced result components:" <+> int (count isRes strict)
           <+> text "of" <+> int (count isRes all_es)
         , text "Forced lazy lets:" <+> int (count isLet strict)
           <+> text "of" <+> int (count isLet all_es)
           <> text "; not known to demand analysis:" <+> int (length new_lets) ]
  where
    sites  = constraints exposed binds
    -- Exposed webs: other modules' lambdas and calls are unknown
    defs   = M.mapWithKey (\e fs -> if is_exposed e then FFalse else fand fs) sites
    is_exposed e = case e of
      FArg w   -> w `elementOfUniqSet` exposed
      FRes w _ -> w `elementOfUniqSet` exposed
      FLet _   -> False
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
    lam_params = lambdaParams binds
    new_args = [ w | FArg w <- strict
                   , any (not . isStrUsedDmd . idDemandInfo) (maybe [] id (lookupUFM lam_params w)) ]
    new_lets = [ x | FLet x <- strict, not (isStrUsedDmd (idDemandInfo x)) ]

-- | The parameters of each web's lambdas
lambdaParams :: CoreProgram -> UniqFM WebId [Id]
lambdaParams binds = foldr (\(_, e) -> go e) emptyUFM (flattenBinds binds)
  where
    go e acc = case e of
      WebLam w x b   -> addToUFM_C (++) (go b acc) w [x]
      Lam _ b        -> go b acc
      App f a        -> go f (go a acc)
      WebApp _ f a   -> go f (go a acc)
      Let b x        -> foldr (\(_, r) -> go r) (go x acc) (flattenBinds [b])
      Case s _ _ as  -> go s (foldr (\(Alt _ _ r) -> go r) acc as)
      Cast x _       -> go x acc
      Tick _ x       -> go x acc
      _              -> acc
