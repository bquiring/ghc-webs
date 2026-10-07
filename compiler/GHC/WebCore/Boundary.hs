{-# LANGUAGE PatternSynonyms #-}

-- | Splitting webs at the module boundary by eta-expansion, before
-- annotation.
--
-- See Note [Splitting webs at the boundary].
module GHC.WebCore.Boundary
  ( splitBoundary
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.FVs ( rulesFreeVars )
import GHC.Core.Opt.Arity ( etaExpand )
import GHC.Core.Utils ( exprIsTrivial )
import GHC.Core.Unfold ( UnfoldingOpts, unfoldingUseThreshold )
import GHC.Core.Coercion ( isReflexiveCo )

import GHC.Data.FastString

import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Demand ( splitDmdSig )
import GHC.Types.Basic ( Arity, isDefaultInlinePragma, noOccInfo )
import GHC.Core.Type ( pattern ManyTy )
import GHC.Types.Name
import GHC.Types.Unique ( Unique )
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set

import GHC.Data.Maybe ( orElse )
import GHC.Utils.Monad ( mapAccumLM )

{- Note [Splitting webs at the boundary]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A web that reaches the module boundary is exposed, and no transformation
touches it (Note [Exposed webs] in GHC.WebCore.Sigs).  On nofib about half
of all webs are exposed.  Often only one use of a function reaches the
boundary, and the others are local: an exported function is also called in
its own module; a local function is passed to an imported one (map f xs),
and also called locally.

Eta-expansion splits such a web.  In

    map (\x -> f x) xs

the exposed web is that of the new lambda.  f's own web meets it only at
the call (f x), which does not link the two: f's lambdas and calls are all
local again.  So, before annotation (with -fcore-webs-boundary, in the early
run only):

 1. Exported functions.  An exported top-level binding  f = \xs -> e  is
    split into a local function and an exported wrapper:

        $ef = \xs -> e[$ef/f]          -- local, not exported
        f   = \xs -> $ef xs            -- exported

    and every occurrence of f in the module becomes $ef.  This is
    worker/wrapper with the identity as the wrapper.  f is left alone if it
    has a stable unfolding, rules, or an inline pragma, or if a rule
    mentions it.  It is also left alone if it is small: see
    Note [Small functions are not split].

 2. Arguments of global Ids.  A local function variable v (arity n > 0)
    passed to an imported function or a data constructor is eta-expanded
    to its arity:  g v  ==>  g (\ys -> v ys).  So is a partial application
    of v to trivial arguments (map (go acc) xs).  Magic Ids (compulsory
    unfoldings) are left alone, and so is v if it has a stable unfolding or
    an inline pragma: the simplifier would inline v into the new lambda,
    leaving a second copy of its body.  (Instance methods marked INLINE,
    passed to the dictionary constructor, grew real/eff/VS by 16%.)

Both are semantically the identity: v has arity n, so it, and its partial
application to fewer than n arguments, are values, and eta-expansion
neither duplicates work nor turns bottom into a lambda.

If no transformation changes f's or v's web, the simplifier, which runs
after the early web pass, undoes the split: it eta-reduces  \ys -> v ys,
and shortOutIndirections turns  f = $ef  back into one binding.  If a
transformation did change the web, the wrapper is where the old calling
convention meets the new one (e.g.  \x y -> $ef x  after dead-parameter
deletion): GHC's worker/wrapper, with the wrapper built by the web pass.
In the late run nothing simplifies afterwards, so the split is not done.
-}

{- Note [Small functions are not split]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
GHC's worker/wrapper does not split a function that is small enough to
certainly inline after the split; it gives it a stable unfolding instead,
which inlines everywhere, even partially applied (Note [Don't w/w inline
small non-loop-breaker things] in GHC.Core.Opt.WorkWrap).  Its whole body
then reaches every caller, in other modules too, and its web is optimised
there, by inlining.  Splitting such a function at the boundary only stops
that:

  * real/infer: StateX.thenSX and friends are tiny.  Split, the exported
    wrapper got no stable unfolding, and InferMonad's partial applications
    (thenSX thenX) no longer inlined: +4.5% allocation.

  * real/gamteb: RoulSplit.split returns a pair of records.  Split, its
    result raised, it became a worker returning an unboxed pair and a
    wrapper; the callers in other modules, which used to inline its body
    and take the records apart, called the worker instead: +1.0%
    allocation.

We cannot ask worker/wrapper's own question (certainlyWillInline) here:
it is about the body after worker/wrapper, which unboxes arguments and
drops absent ones, and is often much smaller.  split's unfolding has size
152 before worker/wrapper and inlines unconditionally after it.  So the test
is a heuristic: a function is not split if its unfolding is within twice
the inlining threshold (-funfolding-use-threshold), with the argument
discount certainlyWillInline uses.  A function with an INLINE-like
unfolding (UnfWhen) is never split.
-}

-- | Is f small enough that GHC's worker/wrapper would probably make it
-- inline everywhere?  See Note [Small functions are not split]
nearlyInlines :: UnfoldingOpts -> Id -> Bool
nearlyInlines opts f = case realIdUnfolding f of
  CoreUnfolding { uf_guidance = UnfWhen {} } -> True
  CoreUnfolding { uf_guidance = UnfIfGoodArgs { ug_size = size, ug_args = args } }
    -> size - 10 * (length args + 1) <= 2 * unfoldingUseThreshold opts
  _ -> False

-- | Split exposed webs at the boundary of the module.
-- See Note [Splitting webs at the boundary]
splitBoundary :: UnfoldingOpts -> UniqSupply -> [CoreRule] -> CoreProgram -> CoreProgram
splitBoundary uf_opts us rules binds
  = map etaArgsBind (concat binds')
  where
    rule_fvs = rulesFreeVars rules
    (env, binds') = initUs_ us (mapAccumLM split_bind emptyVarEnv binds)

    -- First pass: choose the exported functions to split, and build their
    -- local copies.  The substitution maps each to its local copy.
    split_bind :: IdEnv Id -> CoreBind -> UniqSM (IdEnv Id, [CoreBind])
    split_bind acc (NonRec f rhs)
      | Just n <- splittable f rhs
      = do { u <- getUniqueM
           ; let f_w = mkLocalCopy u f
           ; return ( extendVarEnv acc f f_w
                    , [ NonRec f_w rhs, NonRec (zapSplit f) (mkWrapper f n f_w) ] ) }
    split_bind acc (Rec prs)
      = do { split <- sequence [ do { u <- getUniqueM; return (f, mkLocalCopy u f, n) }
                               | (f, rhs) <- prs, Just n <- [splittable f rhs] ]
           ; let sub = mkVarEnv [ (f, f_w) | (f, f_w, _) <- split ]
           ; return ( acc `plusVarEnv` sub
                    , Rec [ (lookupVarEnv sub f `orElse` f, rhs) | (f, rhs) <- prs ]
                      : [ NonRec (zapSplit f) (mkWrapper f n f_w) | (f, f_w, n) <- split ] ) }
    split_bind acc bind = return (acc, [bind])

    splittable f rhs
      | isExportedId f
      , not (isJoinId f)
      , not (isStableUnfolding (realIdUnfolding f))
      , isEmptyRuleInfo (idSpecialisation f)
      , isDefaultInlinePragma (idInlinePragma f)
      , not (f `elemVarSet` rule_fvs)
      , not (nearlyInlines uf_opts f)
      , let n = length (filter isId (fst (collectBinders rhs)))
      , n > 0
      = Just n
      | otherwise
      = Nothing

    -- Second pass: redirect the occurrences of split functions to their
    -- local copies (not in the wrappers, which have no occurrences of
    -- them), and eta-expand the arguments of global Ids
    etaArgsBind (NonRec b rhs) = NonRec b (go rhs)
    etaArgsBind (Rec prs)      = Rec [ (b, go rhs) | (b, rhs) <- prs ]

    go :: CoreExpr -> CoreExpr
    go expr = case expr of
      Var v -> Var (lookupVarEnv env v `orElse` v)
      App {}
        | (Var g, args) <- collectArgs expr
        , isGlobalId g
        , not (hasCompulsoryUnfolding g)
        -> mkApps (Var g) [ if isValArg a then eta_arg (go a) else a | a <- args ]
        | (f, args) <- collectArgs expr
        -> mkApps (go f) (map go args)
      Lam b e          -> Lam b (go e)
      Let bind body    -> Let (etaArgsBind bind) (go body)
      Case e b ty alts -> Case (go e) b ty [ Alt c bs (go rhs) | Alt c bs rhs <- alts ]
      Cast e co        -> Cast (go e) co
      Tick t e         -> Tick t (go e)
      _                -> expr

    -- A local function, or its partial application to trivial arguments,
    -- eta-expanded to its arity
    eta_arg a
      | (Var v, args) <- collectArgs a
      , isLocalId v
      , not (isJoinId v)
      , not (isStableUnfolding (realIdUnfolding v))
      , isDefaultInlinePragma (idInlinePragma v)
      , all exprIsTrivial args
      , let missing = idArity v - length (filter isValArg args)
      , missing > 0
      = etaExpandNoCast missing a
      | otherwise
      = a

-- | The local copy of an exported function: same type and analysis
-- results, not exported, no unfolding or rules
mkLocalCopy :: Unique -> Id -> Id
mkLocalCopy u f = mkLocalIdWithInfo name ManyTy (idType f) info
  where
    name = mkDerivedInternalName (\occ -> mkVarOccFS (fsLit "$e" `appendFS` occNameFS occ))
                                 u (idName f)
    info = idInfo f `setUnfoldingInfo` noUnfolding
                    `setRuleInfo` emptyRuleInfo
                    `setOccInfo` noOccInfo

-- | The exported wrapper keeps its Id, but not its unfolding, which
-- describes the old right-hand side
zapSplit :: Id -> Id
zapSplit f = f `setIdUnfolding` noUnfolding

-- | The exported wrapper  f = \xs -> $ef xs.  Its binders get the demands
-- of f's parameters (from f's demand signature): the binders etaExpand
-- makes have none, and GHC's worker/wrapper unboxes an argument only if
-- its binder's demand says it is strict.  Without them, f's worker took its
-- arguments boxed, and so did every caller in other modules (nofib
-- real/gamteb, PhotoElec.photoElec: +0.4% allocation).
mkWrapper :: Id -> Arity -> Id -> CoreExpr
mkWrapper f n f_w = go dmds (etaExpandNoCast n (Var f_w))
  where
    dmds = fst (splitDmdSig (idDmdSig f))
    go (d:ds) (Lam b e) | isId b = Lam (b `setIdDemandInfo` d) (go ds e)
    go ds     (Lam b e)          = Lam b (go ds e)
    go _      e                  = e

-- | etaExpand, without the reflexive cast it can leave around the lambdas
-- (forall types).  A cast there hides the lambdas from GHC's worker/wrapper
-- (splitFun), so the wrapper of a split function would not get the stable
-- unfolding that a small function gets (certainlyWillInline), and would not
-- inline when partially applied in other modules.
etaExpandNoCast :: Arity -> CoreExpr -> CoreExpr
etaExpandNoCast n e = strip (etaExpand n e)
  where
    strip (Cast e' co) | isReflexiveCo co = strip e'
    strip (Lam b body)                    = Lam b (strip body)
    strip e'                              = e'

hasCompulsoryUnfolding :: Id -> Bool
hasCompulsoryUnfolding v = isCompulsoryUnfolding (realIdUnfolding v)
