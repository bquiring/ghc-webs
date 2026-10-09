-- | Web-based strictness: strict arguments are evaluated at the call, and
-- result fields that every caller forces are evaluated in the definition.
--
-- See Note [Web strictness] and WEBS-STRICTNESS.md.
module GHC.WebCore.Transform.Strictness
  ( strictnessRound
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Type
import GHC.Types.Var ( isCoVar )
import GHC.Core.Utils ( exprType, exprIsHNF, exprIsTrivial )

import GHC.Types.Demand ( isStrUsedDmd, splitDmdSig, strictifyDmd )
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Id
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Transform.Common ( mkWild )
import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )

{- Note [Web strictness]
~~~~~~~~~~~~~~~~~~~~~~~~~
Two dual transformations (WEBS-STRICTNESS.md):

1. Strict arguments.  If every lambda of a (non-exposed) web is strict in
   its parameter, a call of the web evaluates the argument first:
       f @^w a   ==>   case a of a' { __DEFAULT -> f @^w a' }
   A lambda's demand on its parameter describes full applications, so each
   lambda has a saturation depth k (the number of value lambdas from its own
   on), and a call evaluates the argument only if it supplies at least the
   web's largest k arguments from this one on.  The case wraps the whole
   application spine.  At a call of a known function (or a jump), an
   argument that the function's demand signature already makes strict is
   left alone: CorePrep passes it by value.

2. Strict result fields.  If the result of a web is a product, and every
   call of the web is scrutinised by a case on that constructor whose
   alternative is strict in field i, then each lambda of the web evaluates
   field i in the constructor applications it returns (in tail position):
       K e1 e2   ==>   case e1 of v1 { __DEFAULT -> K v1 e2 }

Both only change the order of evaluation within an expression whose value is
demanded anyway, which imprecise exceptions allow.  Nothing changes type.  A
web is transformed once (it is then in 'done').

Both analyses are fixpoints over the webs (Note [Web strictness fixpoints]).

Note [Web strictness fixpoints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Demand analysis treats an argument of an unknown call as lazy.  So in

    \^w1 x. g @^w2 x          -- g a parameter

x looks lazy even if every lambda of w2 is strict.  We compute strictness
of the webs together, as a greatest fixpoint: assume every eligible web is
strict, then repeatedly drop the webs one of whose lambdas is not strict in
its parameter under the current assumption, until nothing changes.
'strictIn' says whether a parameter is evaluated whenever an expression is:
it is scrutinised or called; a case scrutinee is strict in it, or every
alternative is; or it is passed, at a call supplying enough arguments, to a
web assumed strict.  Demand analysis's own verdict (idDemandInfo) counts
too.  Starting from "strict" is what makes recursive webs strict (as in
demand analysis, which starts from bottom).

Result fields are the dual.  A call of a web has a context:

  * a case on a constructor K, which is strict in some fields of K;
  * a tail position of a lambda of a web w': the call's result is w''s
    result, so its fields are forced exactly when w''s are;
  * anything else (a lazy let, an argument, a cast, a case with DEFAULT
    alternatives): unknown.

A case alternative is strict in a field binder if it evaluates it, or if
the case is a tail of a lambda of a web w' and every tail of the
alternative returns the binder in a field of w''s result that is strict
(under the current assumption).  So in

    \^w' n. case f @^w n of (# a, b #) -> (a, b)

if w''s callers force the first field, so is w's first field forced.

The two fixpoints feed each other.  If every call of a web forces field j
of its result, a lambda that returns its parameter x in field j (in every
tail) is strict in x, although evaluating the lambda to WHNF does not
evaluate x: every call forces it.  So in testsuite strict006,
bad n = (error "..", n) is strict in n, since every caller forces the
second field, and so are the callers that pass n on.  We iterate: argument
strictness, then result fields, then argument strictness again with them,
until the strict-argument webs stop growing.

The strict fields of a web are the intersection over its calls' contexts.
Tail contexts make this a fixpoint too, again computed from the top: a web
starts with "every field strict" and is lowered by its contexts until
nothing changes.  Join points are lambdas whose calls (jumps) are in tail
positions, so a join point's result fields come from the lambda it is in.
-}

{- Note [Recording proven strictness]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The fixpoint proves strictness that demand analysis could not see (an
argument passed on to an unknown call of a strict web).  Besides evaluating
the argument at the calls, the rewrite records it: the parameter of each
lambda of a strict web gets a strict demand, so that a later pass of the
other transformations sees it (arity raising decides from the parameter's
demand: isStrictIn in GHC.WebCore.Transform.ArityRaise; the pipeline
repeats the transformations, -fcore-webs-passes).  Only at saturation depth
1: a curried lambda's demand describes full applications, which a partial
application need not be (arity raising rejects curried lambdas anyway).
-}

{- Note [Only evaluate what would be a thunk]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Evaluating a strict argument at the call (or a strict field before the
constructor is built) pays when the argument would otherwise be a thunk:
CorePrep allocates a thunk for a non-trivial argument, and the case avoids
it.  A variable is a pointer either way, and the callee, being strict,
evaluates it anyway; a case at the call is a second tag test, in the
caller.  In nofib spectral/hartel/ida such cases in the inner search loop
(case sc of wild { F_SEARCH .. -> $sf_foldl (##) wild .. }) cost 2.7% more
instructions.

One kind of variable is the exception: one let-bound to a non-value (a
thunk), as in  let x = e in f x.  Evaluated at the call, the simplifier
that runs after the early web pass can turn the let into a case
(case e of x' -> f x'), and the thunk is never built.  So we evaluate an
argument only if it is not trivial, or is such a let-bound variable
('thunkLets').  Uniques of nested binders may be shadowed; that only makes
the choice less precise, never wrong: evaluating a strict argument is
always correct.

The same goes for strict result fields: a variable field is not evaluated
before the constructor is built.  Doing so would cost space as well as a
tag test: the constructor's other fields stay alive while the field is
evaluated.  In nofib real/pic, timeStep's base case returned (dt, phi,
heap) with dt evaluated first; forcing dt's long lazy chain there, instead
of in the consumer after phi and heap were dead, made the GC copy 3.4%
more (1.1% more instructions).  The demand still reaches the producer: a
field returned in a strict field of the enclosing web's result is strict
(Note [Web strictness fixpoints]).

Inside a thunk the opposite holds: a call in a thunk's body (a lazy
argument, a constructor field, a non-value let) evaluates even a variable
argument first.  In nofib spectral/ansi the tails of lazy lists are thunks
(c : prog cs); evaluating cs there, before the call, is worth 3.9% fewer
instructions, and the runtime spends far less time walking chains of
update frames (threadPaused).  So the rewrite tracks whether it is inside
a thunk ('lz'): a lambda body is not; a non-value argument or right-hand
side is; a join point is where it is bound.
-}

-- | The local (non-top-level) let-bound Ids whose right-hand side is not a
-- value, i.e. thunks.  See Note [Only evaluate what would be a thunk]
thunkLets :: CoreProgram -> VarSet
thunkLets binds = foldr top emptyVarSet binds
  where
    top (NonRec _ e) acc = go e acc
    top (Rec prs)    acc = foldr (go . snd) acc prs

    go :: CoreExpr -> VarSet -> VarSet
    go expr acc = case expr of
      Let bind body  -> foldr pair (go body acc) (flattenBinds [bind])
      Lam _ e        -> go e acc
      WebLam _ _ e   -> go e acc
      App f a        -> go f (go a acc)
      WebApp _ f a   -> go f (go a acc)
      Case e _ _ as  -> go e (foldr (\(Alt _ _ rhs) -> go rhs) acc as)
      Cast e _       -> go e acc
      Tick _ e       -> go e acc
      _              -> acc

    pair (b, rhs) acc
      | not (isJoinId b)
      , not (exprIsHNF (stripWebForms rhs)) = go rhs (extendVarSet acc b)
      | otherwise                           = go rhs acc

-- | Would this (erased) argument be allocated as a thunk if passed lazily?
-- See Note [Only evaluate what would be a thunk]
wouldBeThunk :: VarSet -> CoreExpr -> Bool
wouldBeThunk thunks a = case strip a of
  Var v -> v `elemVarSet` thunks
  e     -> not (exprIsTrivial e)
  where
    strip (Tick _ e) = strip e
    strip (Cast e _) = strip e
    strip (App f (Type _)) = strip f
    strip e          = e

-- | Webs with strict arguments (assumed, during the fixpoint), with depth
type StrictWebs = UniqFM WebId Int

-- | Is x evaluated whenever the expression is evaluated (to WHNF)?
-- Demand analysis says so, or 'strictIn' does.
isStrictIn :: StrictWebs -> Id -> CoreExpr -> Bool
isStrictIn sw x e = isStrUsedDmd (idDemandInfo x) || strictIn sw x e

-- | Is x evaluated whenever the body of a lambda is, after any further
-- lambdas (that is, at the lambda's saturation depth)?
isStrictInBody :: StrictWebs -> Id -> CoreExpr -> Bool
isStrictInBody sw x body = isStrictIn sw x (peel body)
  where
    peel (Lam _ e)      = peel e
    peel (WebLam _ _ e) = peel e
    peel e              = e

-- | Syntactic strictness, using the strict webs at calls.
-- See Note [Web strictness fixpoints]
strictIn :: StrictWebs -> Id -> CoreExpr -> Bool
strictIn sw x = go emptyVarEnv
  where
    -- joins: join points whose body is strict in x
    go :: VarEnv Bool -> CoreExpr -> Bool
    go joins expr = case expr of
      Var v -> v == x || lookupVarEnv joins v == Just True
      Case scrut _ _ alts -> go joins scrut || all (\(Alt _ _ rhs) -> go joins rhs) alts
      Let (NonRec j rhs) body
        | isJoinId j -> go (extendVarEnv joins j (go joins (peel_join rhs))) body
      Let (Rec prs) body
        | all (isJoinId . fst) prs
        -> go (extendVarEnvList joins [ (j, False) | (j, _) <- prs ]) body
      Let _ body -> go joins body
      Tick _ e   -> go joins e
      Cast e _   -> go joins e
      App {}     -> spine joins expr 0
      WebApp {}  -> spine joins expr 0
      _          -> False

    -- n = the number of value arguments applied after this node
    spine joins expr n = case expr of
      WebApp w f a -> (strict_at w (n + 1) && go joins a) || spine joins f (n + 1)
      App f a      -> spine joins f (if isValArg a then n + 1 else n)
      Tick _ f     -> spine joins f n
      Cast f _     -> spine joins f n
      f            -> go joins f      -- Evaluating a call evaluates its head

    strict_at w supplied = case lookupUFM sw w of
      Just k -> supplied >= k
      Nothing -> False

    peel_join (Lam _ e)      = peel_join e
    peel_join (WebLam _ _ e) = peel_join e
    peel_join e              = e

-- | The number of value lambdas at the top of an expression
valueLams :: CoreExpr -> Int
valueLams (Lam b e) | isId b = 1 + valueLams e
                    | otherwise = valueLams e
valueLams (WebLam _ _ e) = 1 + valueLams e
valueLams (Tick _ e)     = valueLams e
valueLams _              = 0

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

-- | The context of a call's result.  See Note [Web strictness fixpoints]
data Ctxt
  = CScrut DataCon [Var] CoreExpr Ctxt
      -- ^ case <call> of K ys -> rhs, and the context of the case itself
  | CTail WebId                     -- ^ a tail of a lambda of this web
  | CUnknown

data Info = Info
  { i_lams      :: [(Id, CoreExpr)]  -- The lambdas' parameters and bodies
  , i_depth     :: Int               -- Largest saturation depth
  , i_covar     :: Bool
  , i_calls     :: [Ctxt]
      -- One per call of the web whose result is the web's result
  }

noInfo :: Info
noInfo = Info [] 0 False []

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams  = i_lams a ++ i_lams b
                    , i_depth = max (i_depth a) (i_depth b)
                    , i_covar = i_covar a || i_covar b
                    , i_calls = i_calls a ++ i_calls b }

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec _ e) acc = go CUnknown e acc
    go_bind (Rec prs)    acc = foldr (go CUnknown . snd) acc prs

    -- ctxt: the context of the expression's value, if it is a call's result
    go :: Ctxt -> CoreExpr -> Infos -> Infos
    go ctxt expr acc = case expr of
      WebLam w x e
        -> go (CTail w) e $ note w (noInfo { i_lams  = [(x, e)]
                                           , i_depth = 1 + valueLams e
                                           , i_covar = isCoVar x }) acc
      Lam _ e -> go CUnknown e acc
      App {}    -> go_spine ctxt expr acc
      WebApp {} -> go_spine ctxt expr acc
      Let (NonRec b rhs) body
        | isJoinId b -> go ctxt rhs (go ctxt body acc)
        | otherwise  -> go CUnknown rhs (go ctxt body acc)
      Let (Rec prs) body
        -> foldr (\(b, rhs) -> go (if isJoinId b then ctxt else CUnknown) rhs)
                 (go ctxt body acc) prs
      Case scrut _ _ alts
        | [Alt (DataAlt dc) ys rhs] <- alts
        , isSpine scrut
        -> go_spine (CScrut dc ys rhs ctxt) scrut $ go ctxt rhs acc
        | otherwise
        -> go CUnknown scrut $ foldr (\(Alt _ _ rhs) -> go ctxt rhs) acc alts
      Cast e _ -> go CUnknown e acc
      Tick _ e -> go ctxt e acc
      _        -> acc

    isSpine (WebApp {}) = True
    isSpine (Tick _ e)  = isSpine e
    isSpine _           = False

    -- An application spine; the context of its result is 'ctxt'
    go_spine ctxt expr acc = case peelTicks expr of
      WebApp w f a -> note w (noInfo { i_calls = [ctxt] }) (go_fun f (go CUnknown a acc))
      e            -> go_fun e acc

    -- The function part of a spine: further applications are not the
    -- spine's result
    go_fun e acc = case e of
      WebApp _ f a -> go_fun f (go CUnknown a acc)
      App f a      -> go_fun f (go CUnknown a acc)
      Tick _ e'    -> go_fun e' acc
      _            -> go CUnknown e acc

    peelTicks (Tick _ e) = peelTicks e
    peelTicks e          = e

------------------------------------------------------------------
--      The fixpoints
------------------------------------------------------------------

-- | The webs with strict arguments: the greatest fixpoint.
-- See Note [Web strictness fixpoints]
strictArgWebs :: WebSet -> UniqFM WebId Fields -> Infos -> StrictWebs
strictArgWebs exposed rfs infos = loop initial
  where
    initial = mapUFM i_depth (filterUFM_Directly candidate infos)
    candidate u i = not (mkWebId u `elementOfUniqSet` exposed)
                 && not (null (i_lams i)) && not (i_covar i)

    loop sw | sizeUFM sw' == sizeUFM sw = sw
            | otherwise                 = loop sw'
      where sw' = filterUFM_Directly (\u _ -> all_strict sw u) sw

    all_strict sw u = case lookupUFM_Directly infos u of
      Just i  -> all (\(x, body) -> isStrictInBody sw x body
                                   || returnsForced sw (lookupUFM_Directly rfs u) x body)
                     (i_lams i)
      Nothing -> False

-- | Does every tail of the lambda's body return x (or something strict in
-- x) in a field of the result that every call of the web forces?
-- See Note [Web strictness fixpoints]
returnsForced :: StrictWebs -> Maybe Fields -> Id -> CoreExpr -> Bool
returnsForced sw (Just (FFields dc fs)) x body = allTails ok (peel body)
  where
    ok e | Just (dc', vals) <- conAppVals e, dc' == dc
         = or [ f && strictIn sw x v | (f, v) <- zip fs vals ]
         | otherwise
         = isStrictIn sw x e
    peel (Lam _ e)      = peel e
    peel (WebLam _ _ e) = peel e
    peel e              = e
returnsForced _ _ _ _ = False

-- | The strict result fields of a web, during the fixpoint
data Fields = FTop                   -- ^ No context seen yet: every field
            | FFields DataCon [Bool]
            | FNone String
  deriving Eq

meetFields :: Fields -> Fields -> Fields
meetFields FTop f = f
meetFields f FTop = f
meetFields n@(FNone _) _ = n
meetFields _ n@(FNone _) = n
meetFields (FFields dc1 s1) (FFields dc2 s2)
  | dc1 == dc2 = FFields dc1 (zipWith (&&) s1 s2)
  | otherwise  = FNone "unknown call context"

-- | The strict result fields of every web: the greatest fixpoint.
-- See Note [Web strictness fixpoints]
strictResultFields :: WebSet -> StrictWebs -> Infos -> UniqFM WebId Fields
strictResultFields exposed sw infos = loop initial
  where
    initial = mapUFM_Directly start infos
    start u i
      | mkWebId u `elementOfUniqSet` exposed = FNone "exposed"
      | null (i_lams i)                      = FNone "no lambdas"
      | null (i_calls i)                     = FNone "no calls"
      | otherwise                            = FTop

    loop st | st' == st = st
            | otherwise = loop st'
      where st' = mapUFM_Directly (step st) st

    step _  _ f@(FNone _) = f
    step st u _ = case lookupUFM_Directly infos u of
      Just i  -> foldr (meetFields . ctxt st) FTop (i_calls i)
      Nothing -> FNone "no calls"

    ctxt st (CScrut dc ys rhs outer)
      = FFields dc [ isId y && (isStrictIn sw y rhs || returned st outer y rhs) | y <- ys ]
    ctxt st (CTail w)          = case lookupUFM st w of
                                   Just (FNone _) -> FNone "unknown call context"
                                   Just f         -> f
                                   Nothing        -> FNone "unknown call context"
    ctxt _  CUnknown           = FNone "unknown call context"

    -- The case is a tail of a lambda of web w, and every tail of rhs
    -- returns y in a field of w's result that w's callers force (or is
    -- strict in y itself).  See Note [Web strictness fixpoints]
    returned st (CTail w) y rhs = case lookupUFM st w of
      Just FTop            -> allTails (tail_ok Nothing) rhs
      Just (FFields dc fs) -> allTails (tail_ok (Just (dc, fs))) rhs
      _                    -> False
      where
        tail_ok mb e
          | Just (dc', vals) <- conAppVals e
          , ok_con mb dc'
          = or [ strict_field mb j && strictIn sw y v | (j, v) <- zip [0..] vals ]
          | otherwise
          = isStrictIn sw y e
        ok_con Nothing          _   = True
        ok_con (Just (dc, _)) dc'   = dc == dc'
        strict_field Nothing        _ = True
        strict_field (Just (_, fs)) j = j < length fs && fs !! j
    returned _ _ _ _ = False

-- | Does p hold of every tail of the expression (through lets, case
-- alternatives, ticks and join points bound in tail position)?
allTails :: (CoreExpr -> Bool) -> CoreExpr -> Bool
allTails p = go
  where
    go expr = case expr of
      Let (NonRec j rhs) body
        | isJoinId j -> go (under_lams rhs) && go body
      Let (Rec prs) body
        | all (isJoinId . fst) prs -> all (go . under_lams . snd) prs && go body
      Let _ body       -> go body
      Case _ _ _ alts  -> all (\(Alt _ _ rhs) -> go rhs) alts
      Tick _ e         -> go e
      _                -> p expr
    under_lams (Lam _ e)      = under_lams e
    under_lams (WebLam _ _ e) = under_lams e
    under_lams e              = e

-- | A saturated application of a data constructor's worker, and its value
-- arguments
conAppVals :: CoreExpr -> Maybe (DataCon, [CoreExpr])
conAppVals e = case collect e [] of
  (Var v, args)
    | Just dc <- isDataConWorkId_maybe v
    , let vals = [ a | a <- args, isValArg a ]
    , length vals == dataConRepArity dc
    -> Just (dc, vals)
  _ -> Nothing
  where
    collect (App f a)      as = collect f (a : as)
    collect (WebApp _ f a) as = collect f (a : as)
    collect (Tick _ f)     as = collect f as
    collect f              as = (f, as)

------------------------------------------------------------------
--      Verdicts
------------------------------------------------------------------

data ArgVerdict = StrictArg Int | NotStrictArg String
data ResVerdict = StrictFields DataCon [Int] | NoStrictFields String

-- | The verdicts for one web
verdict :: WebSet -> StrictWebs -> UniqFM WebId Fields -> WebId -> Info
        -> (ArgVerdict, ResVerdict)
verdict exposed sw rfs w i
  | w `elementOfUniqSet` exposed = (NotStrictArg "exposed", NoStrictFields "exposed")
  | otherwise = (arg_v, res_v)
  where
    arg_v | null (i_lams i)            = NotStrictArg "no lambdas"
          | i_covar i                  = NotStrictArg "coercion parameter"
          | Just k <- lookupUFM sw w   = StrictArg k
          | otherwise                  = NotStrictArg "lazy"

    res_v = case lookupUFM rfs w of
      Just (FFields dc strict)
        | fields@(_:_) <- [ n | (n, True) <- zip [0..] strict ]
        -> StrictFields dc fields
        | otherwise -> NoStrictFields "no strict field"
      Just (FNone why) -> NoStrictFields why
      Just FTop        -> NoStrictFields "only tail calls"
      Nothing          -> NoStrictFields "no calls"

pprVerdict :: (ArgVerdict, ResVerdict) -> SDoc
pprVerdict (a, r) = ppr_a a <> semi <+> ppr_r r
  where
    ppr_a (StrictArg k)      = text "strict argument (depth" <+> int k <> text ")"
    ppr_a (NotStrictArg why) = text "lazy argument" <+> parens (text why)
    ppr_r (StrictFields dc fs) = text "strict result fields" <+> ppr dc <+> ppr fs
    ppr_r (NoStrictFields why) = text "no strict result fields" <+> parens (text why)

changes :: (ArgVerdict, ResVerdict) -> Bool
changes (StrictArg {}, _)    = True
changes (_, StrictFields {}) = True
changes _                    = False

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse and rewrite.  Webs in 'done' were handled in an earlier round.
strictnessRound :: UniqSupply -> WebSet -> WebSet -> CoreProgram
                -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
strictnessRound us exposed done binds
  | isNullUFM arg_webs && isNullUFM res_webs = (Nothing, dump)
  | otherwise = ( Just (initUs_ us (rewriteProgram arg_webs res_webs binds), handled)
                , dump )
  where
    infos = analyse binds
    -- The two fixpoints feed each other (Note [Web strictness fixpoints]):
    -- iterate until the strict-argument webs stop growing
    (sw, rfs) = joint (strictArgWebs exposed emptyUFM infos)
    joint sw0 | sizeUFM sw1 == sizeUFM sw0 = (sw0, rfs0)
              | otherwise                  = joint sw1
      where rfs0 = strictResultFields exposed sw0 infos
            sw1  = strictArgWebs exposed rfs0 infos
    verdicts = [ (w, verdict exposed sw rfs w i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (w `elementOfUniqSet` done) ]
    arg_webs = listToUFM [ (w, k) | (w, (StrictArg k, _), _) <- verdicts ]
    res_webs = listToUFM [ (w, (dc, fs)) | (w, (_, StrictFields dc fs), _) <- verdicts ]
    handled  = mkUniqSet [ w | (w, v, _) <- verdicts, changes v ]
    dump     = [ (w, pprVerdict v, changes v, map fst (i_lams i))
               | (w, v, i) <- verdicts, not (null (i_lams i)) || changes v ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

rewriteProgram :: UniqFM WebId Int                     -- ^ Strict-argument webs, with depth
               -> UniqFM WebId (DataCon, [Int])        -- ^ Strict-result-field webs
               -> CoreProgram -> UniqSM CoreProgram
rewriteProgram arg_webs res_webs binds = mapM (rw_bind False) binds
  where
    -- Note [Recording proven strictness]: a lambda of a strict web, at
    -- saturation depth 1, is strict in its parameter
    proven w x
      | Just 1 <- lookupUFM arg_webs w
      , isId x, not (isStrUsedDmd (idDemandInfo x))
      = x `setIdDemandInfo` strictifyDmd (idDemandInfo x)
      | otherwise = x

    -- See Note [Only evaluate what would be a thunk]
    thunks = thunkLets binds

    -- lz: are we inside a thunk (the code runs when a thunk is forced)?
    -- See Note [Only evaluate what would be a thunk]
    rw_bind lz (NonRec b e) = NonRec b <$> rw (rhs_lz lz b e) e
    rw_bind lz (Rec prs)    = Rec <$> mapM (\(b, e) -> (,) b <$> rw (rhs_lz lz b e) e) prs

    -- A join point runs where it is bound; any other non-value right-hand
    -- side is a thunk; a value's lambdas reset lz anyway
    rhs_lz lz b e | isJoinId b = lz
                  | otherwise  = not (exprIsHNF (stripWebForms e))

    rw :: Bool -> CoreExpr -> UniqSM CoreExpr
    rw lz expr = case expr of
      WebLam w x e
        | Just (dc, fs) <- lookupUFM res_webs w
        -> WebLam w (proven w x) <$> (rw False e >>= tails dc fs)
        | otherwise
        -> WebLam w (proven w x) <$> rw False e
      Lam b e
        | isTyVar b -> Lam b <$> rw lz e
        | otherwise -> Lam b <$> rw False e
      App {}        -> rw_app lz expr
      WebApp {}     -> rw_app lz expr
      Let bind body -> Let <$> rw_bind lz bind <*> rw lz body
      Case e b ty alts
        -> Case <$> rw lz e <*> pure b <*> pure ty
                <*> mapM (\(Alt c bs rhs) -> Alt c bs <$> rw lz rhs) alts
      Cast e co     -> (\e' -> Cast e' co) <$> rw lz e
      Tick t e      -> Tick t <$> rw lz e
      _             -> return expr

    -- An application spine: evaluate the strict arguments first.  At a call
    -- of a known function (or a jump), an argument that its demand
    -- signature makes strict is left alone: CorePrep already passes it by
    -- value.  See Note [Web strictness]
    rw_app lz expr = do { (wrap, e') <- go expr 0; return (wrap e') }
      where
        sig_strict = case collect_head expr of
          Var v | isJoinId v || idArity v > 0
                -> map isStrUsedDmd (fst (splitDmdSig (idDmdSig v)))
          _     -> []
        n_args = count_args expr

        -- An argument is a thunk's body, unless it is trivial
        rw_arg a = rw (not (exprIsTrivial (stripWebForms a))) a

        -- n = the number of value arguments applied after this node
        go (WebApp w f a) n
          = do { a' <- rw_arg a
               ; (wrap_a, a'') <- case lookupUFM arg_webs w of
                   Just k | n + 1 >= k
                          , not (by_sig (n_args - 1 - n)) -> eval lz a'
                   _                                      -> return (id, a')
               ; (wrap_f, f') <- go f (n + 1)
               ; return (wrap_f . wrap_a, WebApp w f' a'') }
        go (App f a) n
          = do { a' <- if isValArg a then rw_arg a else rw lz a
               ; (wrap_f, f') <- go f (if isValArg a then n + 1 else n)
               ; return (wrap_f, App f' a') }
        go (Tick t e) n
          = do { (wrap, e') <- go e n; return (wrap, Tick t e') }
        go e _
          = do { e' <- rw lz e; return (id, e') }

        by_sig i = i >= 0 && i < length sig_strict && sig_strict !! i

    count_args (App f a)      = count_args f + (if isValArg a then 1 else 0)
    count_args (WebApp _ f _) = count_args f + 1
    count_args (Tick _ f)     = count_args f
    count_args _              = 0 :: Int

    collect_head (App f _)      = collect_head f
    collect_head (WebApp _ f _) = collect_head f
    collect_head (Tick _ f)     = collect_head f
    collect_head f              = f

    -- Evaluate an argument (if lifted, not already a value, and, unless the
    -- Bool says always, it would otherwise be a thunk: Note [Only evaluate
    -- what would be a thunk])
    eval :: Bool -> CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    eval lz a
      | definitelyLiftedType ty
      , not (exprIsHNF a0)
      , lz || wouldBeThunk thunks a0
      = do { v <- mkWild ty
             -- The evaluated unfolding stops a second evaluation of v
             -- (exprIsHNF), e.g. by the tails of an enclosing lambda
           ; let v' = v `setIdUnfolding` evaldUnfolding
           ; return (\body -> Case a v' (exprType body) [Alt DEFAULT [] body], Var v') }
      | otherwise
      = return (id, a)
      where ty = exprType a
            a0 = stripWebForms a

    -- The tail positions of a lambda's body: evaluate the strict fields of
    -- the constructor applications returned there
    tails :: DataCon -> [Int] -> CoreExpr -> UniqSM CoreExpr
    tails dc fs = go
      where
        go expr = case expr of
          Let bind@(NonRec j rhs) body
            | isJoinId j -> do { rhs' <- under_lams rhs; Let (NonRec j rhs') <$> go body }
            | otherwise  -> Let bind <$> go body
          Let (Rec prs) body
            | all (isJoinId . fst) prs
            -> do { prs' <- mapM (\(j, rhs) -> (,) j <$> under_lams rhs) prs
                  ; Let (Rec prs') <$> go body }
            | otherwise -> Let (Rec prs) <$> go body
          Case e b ty alts -> Case e b ty <$> mapM (\(Alt c bs rhs) -> Alt c bs <$> go rhs) alts
          Tick t e  -> Tick t <$> go e
          _ | Just (vals, mk) <- conApp expr
            -> do { (wraps, vals') <- unzip <$> sequence
                                        [ if n `elem` fs then eval False v else return (id, v)
                                        | (n, v) <- zip [0..] vals ]
                  ; return (foldr (.) id wraps (mk vals')) }
            | otherwise -> return expr

        -- A join point's body (after its lambdas) is a tail too
        under_lams (Lam b e)      = Lam b <$> under_lams e
        under_lams (WebLam w b e) = WebLam w b <$> under_lams e
        under_lams e              = go e

        -- A saturated application of dc's worker: its value arguments, and
        -- a way to rebuild it with new ones (keeping each argument's web)
        conApp e = case collect e [] of
          (Var v, args)
            | Just dc' <- isDataConWorkId_maybe v, dc' == dc
            , let vals = [ a | (Just _, a) <- args ]
            , length vals == dataConRepArity dc
            -> Just (vals, \vals' -> rebuild (Var v) args vals')
          _ -> Nothing

        collect (App f a)      as = collect f ((Nothing, a) : as)
        collect (WebApp w f a) as = collect f ((Just w, a) : as)
        collect e              as = (e, as)

        rebuild f ((Nothing, a) : as) vs     = rebuild (App f a) as vs
        rebuild f ((Just w, _) : as) (v:vs)  = rebuild (WebApp w f v) as vs
        rebuild f _ _                        = f
