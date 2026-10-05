{-
(c) The GRASP/AQUA Project, Glasgow University, 1993-1998

\section[WorkWrap]{Worker/wrapper-generating back-end of strictness analyser}
-}


module GHC.Core.Opt.WorkWrap
 ( WwOpts (..)
 , wwTopBinds
 , HoStats, higherOrderStats, pprHoStats
 )
where

import GHC.Prelude

import GHC.Core
import GHC.Core.Unfold.Make
import GHC.Core.Utils  ( exprType, exprIsHNF, mkLamTypes )
import GHC.Core.Type
import GHC.Core.Opt.WorkWrap.Utils
import GHC.Core.SimpleOpt

import GHC.Data.FastString

import GHC.Types.Var
import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Unique.Supply
import GHC.Types.Basic
import GHC.Types.Demand
import GHC.Types.Cpr
import GHC.Types.SourceText
import GHC.Types.Unique

import GHC.Utils.Misc
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Utils.Monad
import GHC.Core.DataCon
import Data.Maybe ( isJust, isNothing )
import GHC.Core.Make ( mkWildValBinder )
import GHC.Core.Opt.Arity ( exprIsDeadEnd, typeArity )
import GHC.Types.Var.Env
import GHC.Types.Name ( mkSystemVarName )
import GHC.Core.Multiplicity ( Scaled(..), scaledThing )

{-
We take Core bindings whose binders have:

\begin{enumerate}

\item Strictness attached (by the front-end of the strictness
analyser), and / or

\item Constructed Product Result information attached by the CPR
analysis pass.

\end{enumerate}

and we return some ``plain'' bindings which have been
worker/wrapper-ified, meaning:

\begin{enumerate}

\item Functions have been split into workers and wrappers where
appropriate.  If a function has both strictness and CPR properties
then only one worker/wrapper doing both transformations is produced;

\item Binders' @IdInfos@ have been updated to reflect the existence of
these workers/wrappers (this is where we get STRICTNESS and CPR pragma
info for exported values).
\end{enumerate}
-}

wwTopBinds :: WwOpts -> UniqSupply -> CoreProgram -> CoreProgram

wwTopBinds ww_opts us top_binds
  = initUs_ us $ concatMapM (wwBind ww_opts) top_binds

{-
************************************************************************
*                                                                      *
\subsection[wwBind-wwExpr]{@wwBind@ and @wwExpr@}
*                                                                      *
************************************************************************

@wwBind@ works on a binding, trying each \tr{(binder, expr)} pair in
turn.  Non-recursive case first, then recursive...
-}

wwBind  :: WwOpts
        -> CoreBind
        -> UniqSM [CoreBind]    -- returns a WwBinding intermediate form;
                                -- the caller will convert to Expr/Binding,
                                -- as appropriate.

wwBind ww_opts (NonRec binder rhs) = do
    new_rhs   <- wwExpr ww_opts rhs
    new_pairs <- tryWW ww_opts NonRecursive binder new_rhs
    return [NonRec b e | (b,e) <- new_pairs]
      -- Generated bindings must be non-recursive
      -- because the original binding was.

wwBind ww_opts (Rec pairs)
  = return . Rec <$> concatMapM do_one pairs
  where
    do_one (binder, rhs) = do new_rhs <- wwExpr ww_opts rhs
                              tryWW ww_opts Recursive binder new_rhs

{-
@wwExpr@ basically just walks the tree, looking for appropriate
annotations that can be used. Remember it is @wwBind@ that does the
matching by looking for strict arguments of the correct type.
@wwExpr@ is a version that just returns the ``Plain'' Tree.
-}

wwExpr :: WwOpts -> CoreExpr -> UniqSM CoreExpr

wwExpr _ e@(Type {}) = return e
wwExpr _ e@(Coercion {}) = return e
wwExpr _ e@(Lit  {}) = return e
wwExpr _ e@(Var  {}) = return e

wwExpr ww_opts (Lam binder expr)
  = Lam new_binder <$> wwExpr ww_opts expr
  where new_binder | isId binder = zapIdUsedOnceInfo binder
                   | otherwise   = binder
  -- See Note [Zapping Used Once info in WorkWrap]

wwExpr ww_opts (App f a)
  = App <$> wwExpr ww_opts f <*> wwExpr ww_opts a

wwExpr ww_opts (Tick note expr)
  = Tick note <$> wwExpr ww_opts expr

wwExpr ww_opts (Cast expr co) = do
    new_expr <- wwExpr ww_opts expr
    return (Cast new_expr co)

wwExpr ww_opts (Let bind expr)
  = mkLets <$> wwBind ww_opts bind <*> wwExpr ww_opts expr

wwExpr ww_opts (Case expr binder ty alts) = do
    new_expr <- wwExpr ww_opts expr
    new_alts <- mapM ww_alt alts
    let new_binder = zapIdUsedOnceInfo binder
      -- See Note [Zapping Used Once info in WorkWrap]
    return (Case new_expr new_binder ty new_alts)
  where
    ww_alt (Alt con binders rhs) = do
        new_rhs <- wwExpr ww_opts rhs
        let new_binders = [ if isId b then zapIdUsedOnceInfo b else b
                          | b <- binders ]
           -- See Note [Zapping Used Once info in WorkWrap]
        return (Alt con new_binders new_rhs)

{-
************************************************************************
*                                                                      *
\subsection[tryWW]{@tryWW@: attempt a worker/wrapper pair}
*                                                                      *
************************************************************************

@tryWW@ just accumulates arguments, converts strictness info from the
front-end into the proper form, then calls @mkWwBodies@ to do
the business.

The only reason this is monadised is for the unique supply.

Note [Don't w/w INLINE things]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's very important to refrain from w/w-ing an INLINE function (ie one
with a stable unfolding) because the wrapper will then overwrite the
old stable unfolding with the wrapper code.

Furthermore, if the programmer has marked something as INLINE,
we may lose by w/w'ing it.

If the strictness analyser is run twice, this test also prevents
wrappers (which are INLINEd) from being re-done.  (You can end up with
several liked-named Ids bouncing around at the same time---absolute
mischief.)

Notice that we refrain from w/w'ing an INLINE function even if it is
in a recursive group.  It might not be the loop breaker.  (We could
test for loop-breaker-hood, but I'm not sure that ever matters.)

Note [Worker/wrapper for INLINABLE functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we have
  {-# INLINABLE f #-}
  f :: Ord a => [a] -> Int -> a
  f x y = ....f....

where f is strict in y, we might get a more efficient loop by w/w'ing
f.  But that would make a new unfolding which would overwrite the old
one! So the function would no longer be INLINABLE, and in particular
will not be specialised at call sites in other modules.

This comes up in practice (#6056).

Solution:

* Do the w/w for strictness analysis, even for INLINABLE functions

* Transfer the Stable unfolding to the *worker*.  How do we "transfer
  the unfolding"? Easy: by using the old one, wrapped in work_fn! See
  GHC.Core.Unfold.Make.mkWorkerUnfolding.

* We use the /original, user-specified/ function's InlineSpec pragma
  for both the wrapper and the worker (see `mkStrWrapperInlinePrag`).
  So if f is INLINEABLE, both worker and wrapper will get an InlineSpec
  of (Inlinable "blah").

  It's important that both get this, because the specialiser uses
  the existence of a /user-specified/ INLINE/INLINABLE pragma to
  drive specialisation of imported functions.  See  GHC.Core.Opt.Specialise
  Note [Specialising imported functions]

* Remember, the subsequent inlining behaviour of the wrapper is expressed by
  (a) the stable unfolding
  (b) the unfolding guidance of UnfWhen
  (c) the inl_act activation (see Note [Wrapper activation]

For our {-# INLINEABLE f #-} example above, we will get something a
bit like like this:

  {-# Has stable unfolding, active in phase 2;
      plus InlineSpec = INLINEABLE #-}
  f :: Ord a => [a] -> Int -> a
  f d x y = case y of I# y' -> fw d x y'

  {-# Has stable unfolding, plus InlineSpec = INLINEABLE #-}
  fw :: Ord a => [a] -> Int# -> a
  fw d x y' = let y = I# y' in ...f...


(Historical note: we used to always give the wrapper an INLINE pragma,
but CSE will not happen if there is a user-specified pragma, but
should happen for w/w’ed things (#14186).  But now we simply propagate
any user-defined pragma info, so we'll defeat CSE (rightly) only when
there is a user-supplied INLINE/INLINEABLE pragma.)

Note [No worker/wrapper for record selectors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We sometimes generate a lot of record selectors, and generally the
don't benefit from worker/wrapper.  Yes, mkWwBodies would find a w/w split,
but it is then suppressed by the certainlyWillInline test in splitFun.

The wasted effort in mkWwBodies makes a measurable difference in
compile time (see MR !2873), so although it's a terribly ad-hoc test,
we just check here for record selectors, and do a no-op in that case.

I did look for a generalisation, so that it's not just record
selectors that benefit.  But you'd need a cheap test for "this
function will definitely get a w/w split" and that's hard to predict
in advance...the logic in mkWwBodies is complex. So I've left the
super-simple test, with this Note to explain.

NB: record selectors are ordinary functions, inlined iff GHC wants to,
so won't be caught by the preceding isInlineUnfolding test in tryWW.

Note [Worker/wrapper for NOINLINE functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We used to disable worker/wrapper for NOINLINE things, but it turns out
this can cause unnecessary reboxing of values. Consider

  {-# NOINLINE f #-}
  f :: Int -> a
  f x = error (show x)

  g :: Bool -> Bool -> Int -> Int
  g True  True  p = f p
  g False True  p = p + 1
  g b     False p = g b True p

the strictness analysis will discover f and g are strict, but because f
has no wrapper, the worker for g will rebox p. So we get

  $wg x y p# =
    let p = I# p# in  -- Yikes! Reboxing!
    case x of
      False ->
        case y of
          False -> $wg False True p#
          True -> +# p# 1#
      True ->
        case y of
          False -> $wg True True p#
          True -> case f p of { }

  g x y p = case p of (I# p#) -> $wg x y p#

Now, in this case the reboxing will float into the True branch, and so
the allocation will only happen on the error path. But it won't float
inwards if there are multiple branches that call (f p), so the reboxing
will happen on every call of g. Disaster.

Solution: do worker/wrapper even on NOINLINE things; but move the
NOINLINE pragma to the worker.

(See #13143 for a real-world example.)

It is crucial that we do this for *all* NOINLINE functions. #10069
demonstrates what happens when we promise to w/w a (NOINLINE) leaf
function, but fail to deliver:

  data C = C Int# Int#

  {-# NOINLINE c1 #-}
  c1 :: C -> Int#
  c1 (C _ n) = n

  {-# NOINLINE fc #-}
  fc :: C -> Int#
  fc c = 2 *# c1 c

Failing to w/w `c1`, but still w/wing `fc` leads to the following code:

  c1 :: C -> Int#
  c1 (C _ n) = n

  $wfc :: Int# -> Int#
  $wfc n = let c = C 0# n in 2 #* c1 c

  fc :: C -> Int#
  fc (C _ n) = $wfc n

Yikes! The reboxed `C` in `$wfc` can't cancel out, so we are in a bad place.
This generalises to any function that derives its strictness signature from
its callees, so we have to make sure that when a function announces particular
strictness properties, we have to w/w them accordingly, even if it means
splitting a NOINLINE function.

Note [Worker activation]
~~~~~~~~~~~~~~~~~~~~~~~~
Follows on from Note [Worker/wrapper for INLINABLE functions]

It is *vital* that if the worker gets an INLINABLE pragma (from the
original function), then the worker has the same phase activation as
the wrapper (or later).  That is necessary to allow the wrapper to
inline into the worker's unfolding: see GHC.Core.Opt.Simplify.Utils
Note [Simplifying inside stable unfoldings].

If the original is NOINLINE, it's important that the worker inherits the
original activation. Consider

  {-# NOINLINE expensive #-}
  expensive x = x + 1

  f y = let z = expensive y in ...

If expensive's worker inherits the wrapper's activation,
we'll get this (because of the compromise in point (2) of
Note [Wrapper activation])

  {-# NOINLINE[Final] $wexpensive #-}
  $wexpensive x = x + 1
  {-# INLINE[Final] expensive #-}
  expensive x = $wexpensive x

  f y = let z = expensive y in ...

and $wexpensive will be immediately inlined into expensive, followed by
expensive into f. This effectively removes the original NOINLINE!

Otherwise, nothing is lost by giving the worker the same activation as the
wrapper, because the worker won't have any chance of inlining until the
wrapper does; there's no point in giving it an earlier activation.

Note [Don't w/w inline small non-loop-breaker things]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In general, we refrain from w/w-ing *small* functions, which are not
loop breakers, because they'll inline anyway.  But we must take care:
it may look small now, but get to be big later after other inlining
has happened.  So we take the precaution of adding a StableUnfolding
for any such functions.

I made this change when I observed a big function at the end of
compilation with a useful strictness signature but no w-w.  (It was
small during demand analysis, we refrained from w/w, and then got big
when something was inlined in its rhs.) When I measured it on nofib,
it didn't make much difference; just a few percent improved allocation
on one benchmark (bspt/Euclid.space).  But nothing got worse.

There is an infelicity though.  We may get something like
      f = g val
==>
      g x = case gw x of r -> I# r

      f {- InlineStable, Template = g val -}
      f = case gw x of r -> I# r

The code for f duplicates that for g, without any real benefit. It
won't really be executed, because calls to f will go via the inlining.

Note [Don't w/w join points for CPR]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
There's no point in exploiting CPR info on a join point. If the whole function
is getting CPR'd, then the case expression around the worker function will get
pushed into the join point by the simplifier, which will have the same effect
that w/w'ing for CPR would have - the result will be returned in an unboxed
tuple.

  f z = let join j x y = (x+1, y+1)
        in case z of A -> j 1 2
                     B -> j 2 3

  =>

  f z = case $wf z of (# a, b #) -> (a, b)
  $wf z = case (let join j x y = (x+1, y+1)
                in case z of A -> j 1 2
                             B -> j 2 3) of (a, b) -> (# a, b #)

  =>

  f z = case $wf z of (# a, b #) -> (a, b)
  $wf z = let join j x y = (# x+1, y+1 #)
          in case z of A -> j 1 2
                       B -> j 2 3

Note that we still want to give `j` the CPR property, so that `f` has it. So
CPR *analyse* join points as regular functions, but don't *transform* them.

We could retain the CPR /signature/ on the worker after W/W, but it would
become outright wrong if the Simplifier pushes a non-trivial continuation
into it. For example:
    case (let $j x = (x,x) in ...) of alts
    ==>
    let $j x = case (x,x) of alts in case ... of alts
Before pushing the case in, `$j` has the CPR property, but not afterwards.

So we simply zap the CPR signature for join pints as part of the W/W pass.
The signature served its purpose during CPR analysis in propagating the
CPR property of `$j`.

Doing W/W for returned products on a join point would be tricky anyway, as the
worker could not be a join point because it would not be tail-called. However,
doing the *argument* part of W/W still works for join points, since the wrapper
body will make a tail call:

  f z = let join j x y = x + y
        in ...

  =>

  f z = let join $wj x# y# = x# +# y#
                 j x y = case x of I# x# ->
                         case y of I# y# ->
                         $wj x# y#
        in ...

Note [Wrapper activation]
~~~~~~~~~~~~~~~~~~~~~~~~~
When should the wrapper inlining be active?

1. It must not be active earlier than the current Activation of the Id,
   because we must give rewrite rules mentioning the wrapper and
   specialisation a chance to fire.
   See Note [Worker/wrapper for INLINABLE functions]
   and Note [Worker activation]

2. It should be active at some point, despite (1) because of
   Note [Worker/wrapper for NOINLINE functions]

3. For ordinary functions with no pragmas we want to inline the
   wrapper as early as possible (#15056).  Suppose another module
   defines    f !x xs = ... foldr k z xs ...
   and suppose we have the usual foldr/build RULE.  Then if we have
   a call `f x [1..x]`, we'd expect to inline f and the RULE will fire.
   But if f is w/w'd (which it might be), we want the inlining to
   occur just as if it hadn't been.

   (This only matters if f's RHS is big enough to w/w, but small
   enough to inline given the call site, but that can happen.)

4. We do not want to inline the wrapper before specialisation.
         module Foo where
           f :: Num a => a -> Int -> a
           f n 0 = n              -- Strict in the Int, hence wrapper
           f n x = f (n+n) (x-1)

           g :: Int -> Int
           g x = f x x            -- Provokes a specialisation for f

         module Bar where
           import Foo

           h :: Int -> Int
           h x = f 3 x

   In module Bar we want to give specialisations a chance to fire
   before inlining f's wrapper.

   (Historical note: At one stage I tried making the wrapper inlining
   always-active, and that had a very bad effect on nofib/imaginary/x2n1;
   a wrapper was inlined before the specialisation fired.)

4a. If we have
      {-# SPECIALISE foo :: (Int,Int) -> Bool -> Int #-}
      {-# NOINLINE [n] foo #-}
    then specialisation will generate a SPEC rule active from Phase n.
    See Note [Auto-specialisation and RULES] in GHC.Core.Opt.Specialise
    This SPEC specialisation rule will compete with inlining, but we don't
    mind that, because if inlining succeeds, it should be better.

    Now, if we w/w foo, we must ensure that the wrapper (which is very
    keen to inline) has a phase /after/ 'n', else it'll always "win" over
    the SPEC rule -- disaster (#20709).

Conclusion: the activation for the wrapper should be the /later/ of
  (a) the current activation of the function, or FinalPhase if it is NOINLINE
  (b) one phase /after/ the activation of any rules
This is implemented by mkStrWrapperInlinePrag.

Reminder: Note [Don't w/w INLINE things], so we don't need to worry
          about INLINE things here.


What if `foo` has no specialisations, is worker/wrappered (with the
wrapper inlining very early), and exported; and then in an importing
module we have {-# SPECIALISE foo : ... #-}?

Well then, we'll specialise foo's wrapper, which will expose a
specialisation for foo's worker, which we will do too.  That seems
fine.  (To work reliably, `foo` would need an INLINABLE pragma,
in which case we don't unpack dictionaries for the worker; see
see Note [Do not unbox class dictionaries].)

Note [Drop absent bindings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (#19824):
   let t = ...big...
   in ...(f t x)...

were `f` ignores its first argument.  With luck f's wrapper will inline
thereby dropping `t`, but maybe not: the arguments to f all look boring.

So we pre-empt the problem by replacing t's RHS with an absent filler.
Simple and effective.
-}

tryWW   :: WwOpts
        -> RecFlag
        -> Id                           -- The fn binder
        -> CoreExpr                     -- The bound rhs; its innards
                                        --   are already ww'd
        -> UniqSM [(Id, CoreExpr)]      -- either *one* or *two* pairs;
                                        -- if one, then no worker (only
                                        -- the orig "wrapper" lives on);
                                        -- if two, then a worker and a
                                        -- wrapper.
tryWW ww_opts is_rec fn_id rhs
  -- See Note [Drop absent bindings]
  | isAbsDmd (demandInfo fn_info)
  , not (isJoinId fn_id)
  , Just filler <- mkAbsentFiller ww_opts fn_id NotMarkedStrict
  = return [(new_fn_id, filler)]

  -- See Note [Don't w/w INLINE things]
  | hasInlineUnfolding fn_info
  = return [(new_fn_id, rhs)]

  -- See Note [No worker/wrapper for record selectors]
  | isRecordSelector fn_id
  = return [ (new_fn_id, rhs ) ]

  -- Don't w/w OPAQUE things
  -- See Note [OPAQUE pragma]
  --
  -- Whilst this check might seem superfluous, since we strip boxity
  -- information in GHC.Core.Opt.DmdAnal.finaliseArgBoxities and
  -- CPR information in GHC.Core.Opt.CprAnal.cprAnalBind, it actually
  -- isn't. That is because we would still perform w/w when:
  --
  -- - An argument is used strictly, and -fworker-wrapper-cbv is
  --   enabled, or,
  -- - When demand analysis marks an argument as absent.
  --
  -- In a debug build we do assert that boxity and CPR information
  -- are actually stripped, since we want to prevent callers of OPAQUE
  -- things to do reboxing. See:
  -- - Note [The OPAQUE pragma and avoiding the reboxing of arguments]
  -- - Note [The OPAQUE pragma and avoiding the reboxing of results]
  | isOpaquePragma (inlinePragInfo fn_info)
  = assertPpr (onlyBoxedArguments (dmdSigInfo fn_info) &&
               isTopCprSig (cprSigInfo fn_info))
              (text "OPAQUE fun with boxity" $$
               ppr new_fn_id $$
               ppr (dmdSigInfo fn_info) $$
               ppr (cprSigInfo fn_info) $$
               ppr rhs) $
    return [ (new_fn_id, rhs) ]

  -- Do this even if there is a NOINLINE pragma
  -- See Note [Worker/wrapper for NOINLINE functions]
  | is_fun
  = splitHigherOrder maxFunArgSplits ww_opts new_fn_id rhs

  -- See Note [Thunk splitting]
  | isNonRec is_rec, is_thunk
  = splitThunk ww_opts is_rec new_fn_id rhs

  | otherwise
  = return [ (new_fn_id, rhs) ]

  where
    fn_info        = idInfo fn_id
    (wrap_dmds, _) = splitDmdSig (dmdSigInfo fn_info)
    new_fn_id      = zap_join_cpr $ zap_usage fn_id

    zap_usage = zapIdUsedOnceInfo . zapIdUsageEnvInfo
        -- See Note [Zapping DmdEnv after Demand Analyzer] and
        -- See Note [Zapping Used Once info in WorkWrap]

    zap_join_cpr id
      | isJoinId id = id `setIdCprSig` topCprSig
      | otherwise   = id
        -- See Note [Don't w/w join points for CPR]

    is_fun     = notNull wrap_dmds || isJoinId fn_id
    is_thunk   = not is_fun && not (exprIsHNF rhs) && not (isJoinId fn_id)
                            && not (isUnliftedType (idType fn_id))

{-
Note [Zapping DmdEnv after Demand Analyzer]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In the worker-wrapper pass we zap the DmdEnv.  Why?
 (a) it is never used again
 (b) it wastes space
 (c) it becomes incorrect as things are cloned, because
     we don't push the substitution into it

Why here?
 * Because we don’t want to do it in the Demand Analyzer, as we never know
   there when we are doing the last pass.
 * We want them to be still there at the end of DmdAnal, so that
   -ddump-str-anal contains them.
 * We don’t want a second pass just for that.
 * WorkWrap looks at all bindings anyway.

We also need to do it in TidyCore.tidyLetBndr to clean up after the
final, worker/wrapper-less run of the demand analyser (see
Note [Final Demand Analyser run] in GHC.Core.Opt.DmdAnal).

Note [Zapping Used Once info in WorkWrap]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During the work/wrap pass, using zapIdUsedOnceInfo, we zap the "used once" info
* on every binder (let binders, case binders, lambda binders)
* in both demands and in strictness signatures
* recursively

Why?
 * The simplifier may happen to transform code in a way that invalidates the
   data (see #11731 for an example).
 * It is not used in later passes, up to code generation.

At first it's hard to see how the simplifier might invalidate it (and
indeed for a while I thought it couldn't: #19482), but it's not quite
as simple as I thought.  Consider this:
  {-# STRICTNESS SIG <SP(M,A)> #-}
  f p = let v = case p of (a,b) -> a
        in p `seq` (v,v)

I think we'll give `f` the strictness signature `<SP(M,A)>`, where the
`M` says that we'll evaluate the first component of the pair at most
once.  Why?  Because the RHS of the thunk `v` is evaluated at most
once.

But now let's worker/wrapper f:
  {-# STRICTNESS SIG <M> #-}
  $wf p1 = let p2 = absentError "urk" in
           let p = (p1,p2) in
           let v = case p of (a,b) -> a
           in p `seq` (v,v)

where I've gotten the demand on `p1` by decomposing the P(M,A) argument demand.
This rapidly simplifies to
  {-# STRICTNESS SIG <M> #-}
  $wf p1 = let v = p1 in
           (v,v)

and thence to `(p1,p1)` by inlining the trivial let. Now the demand on `p1` should
not be at most once!!

Conclusion: used-once info is fragile to simplification, because of
the non-monotonic behaviour of let's, which turn used-many into
used-once.  So indeed we should zap this info in worker/wrapper.

Conclusion: kill it during worker/wrapper, using `zapUsedOnceInfo`.
Both the *demand signature* of the binder, and the *demand-info* of
the binder.  Moreover, do so recursively.

You might wonder: why do we generate used-once info if we then throw
it away.  The main reason is that we do a final run of the demand analyser,
immediately before CoreTidy, which is /not/ followed by worker/wrapper; it
is there only to generate used-once info for single-entry thunks.

Note [Don't eta expand in w/w]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A binding where the manifestArity of the RHS is less than idArity of
the binder means GHC.Core.Opt.Arity didn't eta expand that binding
When this happens, it does so for a reason (see Note [Arity invariants for bindings]
in GHC.Core.Opt.Arity) and we probably have a PAP, cast or trivial expression
as RHS.

Below is a historical account of what happened when w/w still did eta expansion.
Nowadays, it doesn't do that, but will simply w/w for the wrong arity, unleashing
a demand signature meant for e.g. 2 args to be unleashed for e.g. 1 arg
(manifest arity). That's at least as terrible as doing eta expansion, so don't
do it.
---
When worker/wrapper did eta expansion, it implictly eta expanded the binding to
idArity, overriding GHC.Core.Opt.Arity's decision. Other than playing fast and loose with
divergence, it's also broken for newtypes:

  f = (\xy.blah) |> co
    where
      co :: (Int -> Int -> Char) ~ T

Then idArity is 2 (despite the type T), and it can have a DmdSig based on a
threshold of 2. But we can't w/w it without a type error.

The situation is less grave for PAPs, but the implicit eta expansion caused a
compiler allocation regression in T15164, where huge recursive instance method
groups, mostly consisting of PAPs, got w/w'd. This caused great churn in the
simplifier, when simply waiting for the PAPs to inline arrived at the same
output program.

Note there is the worry here that such PAPs and trivial RHSs might not *always*
be inlined. That would lead to reboxing, because the analysis tacitly assumes
that we W/W'd for idArity and will propagate analysis information under that
assumption. So far, this doesn't seem to matter in practice.
See https://gitlab.haskell.org/ghc/ghc/merge_requests/312#note_192064.

Note [Inline pragma for certainlyWillInline]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this (#19824 comment on 15 May 21):
  f _ (x,y) = ...big...
  v = ...big...
  g x = f v x + 1

So `f` will generate a worker/wrapper split; and `g` (since it is small)
will trigger the certainlyWillInline case of splitFun.  The danger is that
we end up with
  g {- StableUnfolding = \x -> f v x + 1 -}
    = ...blah...

Since (a) that unfolding for g is AlwaysActive
      (b) the unfolding for f's wrapper is ActiveAfterInitial
the call of f will never inline in g's stable unfolding, thereby
keeping `v` alive.

I thought of changing g's unfolding to be ActiveAfterInitial, but that
too is bad: it delays g's inlining into other modules, which makes fewer
specialisations happen. Example in perf/should_run/DeriveNull.

So I decided to live with the problem.  In fact v's RHS will be replaced
by LitRubbish (see Note [Drop absent bindings]) so there is no great harm.
-}


---------------------
splitFun :: WwOpts -> Id -> CoreExpr -> UniqSM [(Id, CoreExpr)]
splitFun ww_opts fn_id rhs
  | Just (arg_vars, body) <- collectNValBinders_maybe ww_arity rhs
  = warnPprTrace (not (wrap_dmds `lengthIs` (arityInfo fn_info)))
                 "splitFun"
                 (ppr fn_id <+> (ppr wrap_dmds $$ ppr cpr)) $
    do { mb_stuff <- mkWwBodies ww_opts fn_id ww_arity arg_vars (exprType body) wrap_dmds cpr
       ; case mb_stuff of
            Nothing -> -- No useful wrapper; leave the binding alone
                       return [(fn_id, rhs)]

            Just stuff
              | let opt_wwd_rhs = mkLams arg_vars $
                                  simpleOptExpr (wo_simple_opts ww_opts) body
                  -- Run the simple optimiser on the WW'd body, to get rid of
                  -- junk. Keep all the original `arg_vars` binders though: this
                  -- might be a join point, and we don't want to lose the
                  -- one-shot annotations.  At least I think that's the reason
                  -- (honestly, I have forgottne), but doing it this way
                  -- certainly does no harm and is slightly more efficient.

              , Just stable_unf <- certainlyWillInline uf_opts fn_info opt_wwd_rhs
                -- We could make a w/w split, but in fact the RHS is small
                -- See Note [Don't w/w inline small non-loop-breaker things]

              , let id_w_unf = fn_id `setIdUnfolding` stable_unf
                -- See Note [Inline pragma for certainlyWillInline]
              ->  return [ (id_w_unf, rhs) ]

              | otherwise
              -> do { work_uniq <- getUniqueM
                    ; return (mkWWBindPair ww_opts fn_id fn_info arg_vars body
                                           work_uniq div stuff) } }

  | otherwise    -- See Note [Don't eta expand in w/w]
  = return [(fn_id, rhs)]

  where
    uf_opts  = so_uf_opts (wo_simple_opts ww_opts)
    fn_info  = idInfo fn_id
    ww_arity = workWrapArity fn_id rhs
      -- workWrapArity: see (4) in Note [Worker/wrapper arity and join points] in DmdAnal

    (wrap_dmds, div) = splitDmdSig (dmdSigInfo fn_info)

    cpr_ty = getCprSig (cprSigInfo fn_info)
    -- Arity of the CPR sig should match idArity when it's not a join point.
    -- See Note [Arity trimming for CPR signatures] in GHC.Core.Opt.CprAnal
    cpr = assertPpr (isJoinId fn_id || cpr_ty == topCprType || ct_arty cpr_ty == arityInfo fn_info)
                    (ppr fn_id <> colon <+> text "ct_arty:" <+> int (ct_arty cpr_ty)
                      <+> text "arityInfo:" <+> ppr (arityInfo fn_info)) $
          ct_cpr cpr_ty

{- Note [Worker/wrapper for function results]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(See WW-HIGHER-ORDER.md.)  A function that returns a function,

    g = \n -> let k = expensive n in \x y -> e      -- y dead, x strict

cannot be eta-expanded when the partial application  g n  is shared (that
would recompute k), so the ordinary split never sees the returned
function's arguments, and every call of  g n  passes the dead y and a
boxed x.  We split g *through* the returned function: its worker returns
the returned function's worker,

    $wg = \n -> let k = expensive n in \x# -> e[I# x#/x]
    g   = \n -> case $wg n of wf { __DEFAULT -> \x y -> case x of I# x# -> wf x# }

The wrapper is the returned function's wrapper (mkWwBodies), applied to the
result of the worker.  At a saturated call it inlines and the call reaches
wf directly.

The tails of g's body (through let, case alternatives and ticks) must each
be one of
  * a manifest lambda group of at least k value lambdas;
  * a variable bound by a let on the path to the tail, to a function of
    arity at least k, perhaps applied to type arguments (typically the
    wrapper of a local function that was split earlier:
    let f = \x y -> $wf x in f, or f @Int when f's dead argument got a
    polymorphic type);
  * a dead end.
k is the smallest arity of the non-bottoming tails.  The demand on each of
the k arguments is the least upper bound over the tails (the binders' demand
info, or the variable's demand signature), so that every tail is at least
as strict, and at least as absent, as the split assumes.

Soundness: wrap (unwrap g) = g, up to the definedness of g n (LetOrCase).
  * With a case, g n  diverges exactly when the original did (the bodies
    differ only in the lambdas they return).
  * For each tail t,  wrap (unwrap t) = t  is the ordinary worker/wrapper
    identity for t, which holds because t's demands are at least the
    combined ones.  A dead-end tail is kept as a dead end
    (case e of {}), not turned into a lambda.
  * Work before the returned lambda stays in  $wg n, and is shared as
    before.  The returned lambdas are manifest groups of k lambdas, so no
    work between their lambdas is lost.

(Boxity) Worker/wrapper decides to unbox from a demand's boxity alone; the
demand analyser's finaliseArgBoxities makes sure that only strict arguments
of a function are marked unboxed.  It does not finalise the binders of a
returned lambda, which can be lazy and still marked unboxed (L!P(L)).  So
a combined demand that is not strict loses its boxity.  (Without this,
\x y -> k + 2  and  \x y -> x * k  returned from different branches made
x look unboxable, and  h undefined 5  diverged: test wwfunres003.)

(EtaFirst) If every partial application  g n  is called at most once, with
all the returned function's arguments (in g's usage demand, the call level
just below g's arity has cardinality at most one, and there are k more call
levels), there is no sharing to lose, and the simplifier
eta-expands g instead (Note [Eta expansion based on demand]); that is
better than a split, since no closure is built at all.  So we do not split
then.  (dmdanal/should_compile/T18894b checks that eta-expansion.)

(Small) A function small enough to be inlined whole (certainlyWillInline)
is not split, as for the ordinary split (Note [Don't w/w inline small
non-loop-breaker things]).  Inlined, its returned lambda meets the call's
arguments directly; split, the call would go through the worker, which
builds the returned closure at every call.  (A derived Eq method that builds
a dictionary and returns the comparison was split, and every comparison in
the importing module then allocated a dictionary and a closure, where
before the method was inlined: simplCore/should_compile/T16038.)

(LetOrCase) The wrapper binds the worker's result with a let by default:

    g = \n -> let wf = $wg n in \x y -> case x of I# x# -> wf x#

so that  g n  is a lambda.  Inlined at a shared partial application,
    let h = g n in ... map (\a -> h a a) xs
the simplifier floats wf out of h's right-hand side, h becomes a lambda and
is inlined into its uses, which then call wf directly; wf is a thunk, so
$wg n is still computed once.  With a case instead, h is a thunk whose
value is the wrapper lambda, and every call through it is an unknown call
that passes the dead argument.
    The cost: g n is now a lambda even when $wg n diverges, so
seq (g n) ()  terminates where it diverged before.  That is the trade GHC
already makes by default when it eta-expands (Note [Dealing with bottom] in
GHC.Core.Opt.Arity), and refuses under -fpedantic-bottoms; we follow it:
with -fpedantic-bottoms the wrapper uses a case, and  g n  diverges exactly
when the original did (test dmdanal/should_run/wwfunres001).  Either way,
$wg n is evaluated at most once per  g n, and calls of  g n  behave as
before.

(Depth) The function returned may itself return a function, and so on:

    g = \n -> let k1 = .. in \a -> let k2 = .. in \b -> let k3 = .. in \x y -> e   -- y dead

Any level may have something to gain (here only level 3).  One traversal
handles all of them.  Going down (analyseLevels), as long as every live tail
at a level is a lambda group, we collect each level's combined demands and
ask mkWwBodies whether splitting that level's functions gains something.
Coming back up (mkFunResultPairs), each level's tails are its lambda groups
with their bodies rebuilt for the levels below, passed through the level's
worker function if it is split; so each level's new type is known from
below.  The wrapper has one let (or case) per level; a split level's
wrapper function converts the original arguments for the worker:

    g = \n -> let wf1 = $wg n in \a -> let wf2 = wf1 a in \b -> let wf3 = wf2 b
                               in \x y -> wf3 x

so each level's work (k1, k2, k3) is shared by its partial applications
exactly as before.  We go down at most maxFunResultDepth levels, and not
through a variable tail (which hides what it returns).

(BoringOk) The wrapper is inlined even in a boring context.  The typical use
is a shared partial application,  let h = g n in ... h a b ... h b a,  and
h = g n  is a boring context.  Inlined there,
    h = case $wg n of wf { __DEFAULT -> \x y -> case x of I# x# -> wf x# }
and when h is strict (it is always called) the simplifier turns the let
into a case and inlines the lambda at the calls, which then call wf
directly.  Inlining the wrapper costs little: it is a case and a small
lambda.
-}

-- | See Note [Worker/wrapper for function results]
splitFunResult :: WwOpts -> Id -> CoreExpr -> UniqSM (Maybe [(Id, CoreExpr)])
splitFunResult ww_opts fn_id rhs
  = do { mb <- funResultLevels ww_opts fn_id rhs
       ; case mb of
           Nothing -> return Nothing
           Just (arg_vars, body, levels) -> Just <$> mkFunResultPairs ww_opts fn_id arg_vars body levels }

-- | The levels of a function-result split, if there is one: the function's
-- arguments and body, and the levels down to the deepest split one
funResultLevels :: WwOpts -> Id -> CoreExpr -> UniqSM (Maybe ([Var], CoreExpr, [FrLevel]))
funResultLevels ww_opts fn_id rhs
  | not (wo_fun_results ww_opts)                     = return Nothing
  | isJoinId fn_id                                   = return Nothing
  | isStableUnfolding (realUnfoldingInfo fn_info)    = return Nothing
  | not (null (ruleInfoRules (ruleInfo fn_info)))    = return Nothing
    -- See (Small) in Note [Worker/wrapper for function results]
  | isJust (certainlyWillInline uf_opts fn_info rhs)  = return Nothing
  | Just (arg_vars, body) <- collectNValBinders_maybe ww_arity rhs
  = do { levels <- analyseLevels ww_opts fn_id ww_arity (demandInfo fn_info) body
         -- Levels below the deepest split level need no wrapping
       ; let levels' = reverse (dropWhile (isNothing . frl_split) (reverse levels))
       ; if null levels'
         then return Nothing        -- Nothing to gain at any level
         else return (Just (arg_vars, body, levels')) }
  | otherwise
  = return Nothing
  where
    fn_info    = idInfo fn_id
    ww_arity   = workWrapArity fn_id rhs
    uf_opts    = so_uf_opts (wo_simple_opts ww_opts)

-- | How many levels of returned functions we look at.
-- See (Depth) in Note [Worker/wrapper for function results]
maxFunResultDepth :: Int
maxFunResultDepth = 4

-- | One level of returned functions (level 1 is the function the body
-- returns, level 2 the function that one returns, and so on)
data FrLevel = FrLevel
  { frl_arity    :: Arity            -- ^ How many value arguments
  , frl_args     :: [(Mult, Type)]   -- ^ Their multiplicities and types
  , frl_rep_tail :: CoreExpr         -- ^ A live tail at this level
  , frl_split    :: Maybe (Id -> CoreExpr, CoreExpr -> CoreExpr)
      -- ^ The wrapper and worker functions of mkWwBodies, if splitting the
      -- functions at this level gains something
  }

-- | Go down the levels of returned functions, as long as every live tail
-- is a lambda group, and decide at each level whether to split.
-- See (Depth) in Note [Worker/wrapper for function results]
analyseLevels :: WwOpts -> Id -> Arity -> Demand -> CoreExpr -> UniqSM [FrLevel]
analyseLevels ww_opts fn_id ww_arity fn_dmd body = go 1 [(emptyVarEnv, body)] (exprType body)
  where
    go :: Int -> [(IdEnv Id, CoreExpr)] -> Type -> UniqSM [FrLevel]
    go depth exprs res_ty
      | depth > maxFunResultDepth = return []
      | Just tails <- concat <$> mapM (\(env, e) -> collectTails env e) exprs
      , t0 : ts <- [ t | t <- tails, isLiveTail t ]
      , let k = foldr (min . tailArity) (tailArity t0) ts
      , k >= 1
      , Just (args, inner_res_ty) <- splitValArgs k res_ty
      = do { let dmds = map finalise (foldr (zipWith lubDmd . tailDemands k) (tailDemands k t0) ts)
           ; xs <- mapM (\((m, ty), d) -> do { u <- getUniqueM
                                              ; return (mkSysLocal (fsLit "fr") u m ty
                                                         `setIdDemandInfo` d) })
                        (zip args dmds)
           ; mb_stuff <- if depth == 1 && etaExpandable ww_arity k fn_dmd
                         then return Nothing   -- See (EtaFirst)
                         else mkWwBodies ww_opts fn_id k xs inner_res_ty dmds topCpr
           ; let split = fmap (\(_, _, w, u) -> (w, u)) mb_stuff
                 this  = FrLevel k args (tailExpr t0) split
             -- Go down only through lambda groups (a variable tail hides
             -- what it returns)
           ; case mapM (peelTail k) (t0 : ts) of
               Just deeper -> (this :) <$> go (depth + 1) deeper inner_res_ty
               Nothing     -> return [this] }
      | otherwise = return []

    -- Only strict arguments may be unboxed: see (Boxity)
    finalise d | isStrictDmd d = d
               | otherwise     = trimBoxity d

    peelTail k (LamTail e _) = Just (emptyVarEnv, snd (splitValLams k e))
    peelTail _ _             = Nothing

-- | The first n value lambdas of an expression, and its body after them
splitValLams :: Int -> CoreExpr -> ([Var], CoreExpr)
splitValLams 0 e         = ([], e)
splitValLams n (Lam b e) = let (bs, e') = splitValLams (n - 1) e in (b : bs, e')
splitValLams _ e         = ([], e)

-- | Make the worker and the wrapper, in one pass over the levels.
-- See (Depth) in Note [Worker/wrapper for function results]
mkFunResultPairs :: WwOpts -> Id -> [Var] -> CoreExpr -> [FrLevel] -> UniqSM [(Id, CoreExpr)]
mkFunResultPairs ww_opts fn_id arg_vars body levels
  = do { -- The worker.  Going back up, each level's new tails are its lambda
         -- groups with their bodies rebuilt for the levels below, then (if
         -- this level is split) passed through the level's worker function.
         -- The new type of each level comes from its representative tail.
         let work_body = fst (rebuild levels body)
             work_rhs  = mkLams arg_vars work_body
       ; work_uniq <- getUniqueM
       ; let work_id = mkWorkerId work_uniq fn_id (exprType work_rhs)
                         `setIdArity`     arityInfo fn_info
                         `setIdDmdSig`    dmdSigInfo fn_info
                         `setIdCprSig`    topCprSig
                         `setInlinePragma` work_prag
         -- The wrapper: one let (or case) per level
       ; wrap_body <- mkWrap levels (mkVarApps (Var work_id) arg_vars)
       ; let wrap_rhs = simpl (mkLams arg_vars wrap_body)
             -- Inline the wrapper even in a boring context: see (BoringOk)
             wrap_unf = case mkWrapperUnfolding simpl_opts wrap_rhs (arityInfo fn_info) of
                          unf@(CoreUnfolding { uf_guidance = g@(UnfWhen {}) })
                            -> unf { uf_guidance = g { ug_boring_ok = boringCxtOk } }
                          unf -> unf
             wrap_id  = fn_id `setIdUnfolding`  wrap_unf
                              `setInlinePragma` mkStrWrapperInlinePrag (inlinePragInfo fn_info) []
                              `setIdOccInfo`    noOccInfo
         -- The worker may itself be split for its own arguments
       ; work_pairs <- splitFun ww_opts work_id work_rhs
       ; return (work_pairs ++ [(wrap_id, wrap_rhs)]) }
  where
    fn_info    = idInfo fn_id
    simpl_opts = wo_simple_opts ww_opts
    simpl      = simpleOptExpr simpl_opts
    work_prag  = (inlinePragInfo fn_info) { inl_rule = FunLike }
    pedantic   = wo_pedantic_bottoms ww_opts

    -- Rebuild an expression whose tails are the given level's values;
    -- returns it and the level's new type
    rebuild :: [FrLevel] -> CoreExpr -> (CoreExpr, Type)
    rebuild [] e = (e, exprType e)
    rebuild (lvl : lvls) e = (rebuildTails new_ty new_tail e, new_ty)
      where
        new_tail t = case splitValLams (frl_arity lvl) t of
          (bs, inner) | length bs == frl_arity lvl, not (null lvls)
                      -> split_fn (mkLams bs (fst (rebuild lvls inner)))
          _           -> split_fn t      -- The deepest level: a lambda or variable
        split_fn t = case frl_split lvl of
          Just (_, work_fn) -> simpl (work_fn t)
          Nothing           -> t
        new_ty = exprType (new_tail (frl_rep_tail lvl))

    -- The wrapper's body for the levels from here down, given the call that
    -- produces this level's new value
    mkWrap :: [FrLevel] -> CoreExpr -> UniqSM CoreExpr
    mkWrap [] call = return call
    mkWrap (lvl : lvls) call
      = do { wf <- mk_var "wf" ManyTy (exprType call)
           ; inner_fun <- case frl_split lvl of
               -- This level is split: its wrapper function takes the
               -- original arguments and calls wf with the worker's; what
               -- that call returns is the next level's new value
               Just (wrap_fn, _) | null lvls -> return (wrap_fn wf)
               _ -> do { xs <- mapM (\(m, ty) -> mk_var "fr" m ty) (frl_args lvl)
                       ; let next_call = case frl_split lvl of
                               Just (wrap_fn, _) -> mkVarApps (wrap_fn wf) xs   -- beta-reduced by simpl
                               Nothing           -> mkVarApps (Var wf) xs
                       ; rest <- mkWrap lvls next_call
                       ; return (mkLams xs rest) }
           ; return (bind wf call inner_fun) }

    mk_var str m ty = do { u <- getUniqueM; return (mkSysLocal (fsLit str) u m ty) }

    -- See (LetOrCase) in Note [Worker/wrapper for function results]
    bind wf call body
      | pedantic  = Case call wf (exprType body) [Alt DEFAULT [] body]
      | otherwise = Let (NonRec wf call) body

{- Note [Worker/wrapper for function arguments]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(See WW-HIGHER-ORDER.md, §2.2.)  A function that passes a local function to
one of its function parameters,

    h = \g n -> let f = \x y -> e in ... g f ...        -- y dead, x strict

gives g the wrapper of f (or f itself), and every call of f inside g passes
the dead y and a boxed x.  We split h so that g receives f's worker:

    $wh = \g' n -> let f = .. in ... g' f' ...          -- f' = f's worker
    h   = \g n -> $wh (\f' -> g (\x y -> case x of I# x# -> f' x#)) n

h's wrapper adapts the caller's g; inlined at a call with a known g, the
adapter meets g's body and g's calls of f become calls of f'.

The general form is a /conversion/ for the values that flow to one argument
position: a closed pair of  unwrap  (original value to new value, used where
the values are made) and  wrap  (new value back to original, used where they
are consumed), with  wrap (unwrap v) = v  for each value v.  A conversion is
one of
  (A) the values are functions (lambda groups, or let-bound functions); their
      combined argument demands give an ordinary worker/wrapper split
      (mkWwBodies): unwrap is its worker function, wrap its wrapper;
  (B) the values are lambda groups, one of whose parameters q is only ever
      called, always with values at some argument position r for which there
      is a conversion C (found first, recursively: this is the traversal
      going down).  unwrap rewrites a lambda so that q's calls pass
      (C.unwrap e) at position r; wrap l' = \as -> l' .. (adapter a_q) ..
      with  adapter = \cs -> a_q .. (C.wrap c_r) .. .
The function h itself is split by a conversion of kind (B) for its own
right-hand side: the worker is  unwrap rhs  and the wrapper  wrap $wh; the
conversions are collated into h's wrapper only there, at the definition.
Deeper nesting (g is given a function that is given f) is (B) inside (B).

Soundness: in the worker, q (now q') occurs only in calls, which pass
C.unwrap e at position r; the wrapper passes the adapter as q', so each call
computes  a_q .. C.wrap (C.unwrap e) ..  =  a_q .. e ..  by C's identity.  For
(A) that identity is the ordinary worker/wrapper one, which holds because each
value's demands are at least the combined ones (and only strict combined
demands unbox: (Boxity) in Note [Worker/wrapper for function results]).
wrap and unwrap mention only their own binders, so they can be used at the
definition and at the call alike.  The adapter is a lambda where the caller's
g might be bottom; but g' is only ever called, never forced on its own, so
that cannot be observed.

We do not split a function with a NOINLINE pragma (its wrapper could not be
inlined, so the adapter would only cost), nor look deeper than
maxFunResultDepth levels of (B).  One split handles one parameter; the worker
is tried again for the others, at most maxFunArgSplits times.
-}

-- | Statistics: how many higher-order splits a program offers.
-- See Note [Higher-order worker/wrapper statistics]
data HoStats = HoStats
  { hs_funs        :: !Int   -- ^ function bindings (arity >= 1, not join points)
  , hs_returns_fun :: !Int   -- ^ ... whose result (after their arity) is a function
  , hs_takes_fun   :: !Int   -- ^ ... with a parameter of function type
  , hs_res_splits  :: !Int   -- ^ function-result splits
  , hs_res_deep    :: !Int   -- ^ ... of which split below level 1
  , hs_res_levels  :: !Int   -- ^ ... levels split, in total
  , hs_arg_splits  :: !Int   -- ^ function-argument splits (parameters split)
  , hs_arg_nested  :: !Int   -- ^ ... of which nested (a conversion of depth > 2)
  , hs_splits      :: [SDoc] -- ^ one line per function split: its name, and how
  }

plusHo :: HoStats -> HoStats -> HoStats
plusHo (HoStats a1 b1 c1 d1 e1 f1 g1 h1 i1) (HoStats a2 b2 c2 d2 e2 f2 g2 h2 i2)
  = HoStats (a1+a2) (b1+b2) (c1+c2) (d1+d2) (e1+e2) (f1+f2) (g1+g2) (h1+h2) (i1 ++ i2)

noHo :: HoStats
noHo = HoStats 0 0 0 0 0 0 0 0 []

sumHo :: [HoStats] -> HoStats
sumHo = foldr plusHo noHo

pprHoStats :: String -> HoStats -> SDoc
pprHoStats phase st
  = text "ww-ho-stats" <+> text phase <+> hsep
      [ text "funs=" <> int (hs_funs st), text "returns_fun=" <> int (hs_returns_fun st)
      , text "takes_fun=" <> int (hs_takes_fun st), text "res_splits=" <> int (hs_res_splits st)
      , text "res_deep=" <> int (hs_res_deep st), text "res_levels=" <> int (hs_res_levels st)
      , text "arg_splits=" <> int (hs_arg_splits st), text "arg_nested=" <> int (hs_arg_nested st) ]
    $$ vcat [ text "ww-ho-split" <+> text phase <+> d | d <- hs_splits st ]

{- Note [Higher-order worker/wrapper statistics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-ddump-ww-ho-stats counts, for every function binding of a program (top
level and nested), whether the function-result and function-argument splits
would apply to it, using the same decision functions as the splits
themselves (funResultLevels, funArgConv), with the splits enabled whatever
the flags.  It changes nothing.  GHC.Core.Opt.Pipeline runs it at three
points: early (before the main simplifier), pre-ww (just before
worker/wrapper: what the splits would do with
-fworker-wrapper-function-results), and final.  Early and final run the
demand analyser on a copy first, since the splits need demand information.
-}

-- | Count the higher-order splits a program offers.
-- See Note [Higher-order worker/wrapper statistics]
higherOrderStats :: WwOpts -> UniqSupply -> CoreProgram -> HoStats
higherOrderStats ww_opts0 us binds = initUs_ us (sumHo <$> mapM go_bind binds)
  where
    ww_opts = ww_opts0 { wo_fun_results = True }

    go_bind bind = sumHo <$> mapM go_pair (flattenBinds [bind])

    go_pair (b, rhs) = do { here <- if isId b && not (isJoinId b) && idArity b >= 1
                                     then fun_stats b rhs else return noHo
                          ; inner <- go rhs
                          ; return (here `plusHo` inner) }

    go e = case e of
      App f a        -> plusHo <$> go f <*> go a
      Lam _ b        -> go b
      Let bind body  -> plusHo <$> go_bind bind <*> go body
      Case s _ _ alts -> plusHo <$> go s <*> (sumHo <$> mapM (\(Alt _ _ rhs) -> go rhs) alts)
      Cast b _       -> go b
      Tick _ b       -> go b
      _              -> return noHo

    fun_stats fn_id rhs
      = do { let ty         = idType fn_id
                 res_is_fun = case collectNValBinders_maybe (workWrapArity fn_id rhs) rhs of
                                Just (_, body) -> isFunTy (exprType body)
                                Nothing        -> False
                 takes_fun  = any (isFunTy . scaledThing) (fst (splitFunTys (dropForAlls ty)))
           ; mb_res <- funResultLevels ww_opts fn_id rhs
           ; arg_ns <- count_args maxFunArgSplits fn_id rhs
           ; let (res, deep, lvls, split_lvls) = case mb_res of
                   Just (_, _, levels) -> ( 1, if length levels > 1 then 1 else 0
                                          , length (filter (isJust . frl_split) levels)
                                          , [ i | (i, l) <- zip [1 :: Int ..] levels, isJust (frl_split l) ] )
                   Nothing             -> (0, 0, 0, [])
                 line = ppr (idName fn_id) <> colon
                        <+> (if res == 1 then text "result at levels" <+> hsep (punctuate comma (map int split_lvls)) else empty)
                        <+> (if null arg_ns then empty else text "arguments, depths" <+> hsep (punctuate comma (map int arg_ns)))
           ; return (HoStats 1 (fromEnum res_is_fun) (fromEnum takes_fun) res deep lvls
                             (length arg_ns) (length (filter (> 2) arg_ns))
                             [ line | res == 1 || not (null arg_ns) ]) }

    -- The depths of the successive argument splits of one function
    count_args :: Int -> Id -> CoreExpr -> UniqSM [Int]
    count_args 0 _ _ = return []
    count_args fuel fn_id rhs
      = do { mb <- funArgConv ww_opts fn_id rhs
           ; case mb of
               Nothing   -> return []
               Just conv -> do { (work_id, work_rhs, _) <- mkFunArgPairs ww_opts fn_id rhs conv
                               ; (cv_depth conv :) <$> count_args (fuel - 1) work_id work_rhs } }

-- | How many parameters of one function we split.
-- See Note [Worker/wrapper for function arguments]
maxFunArgSplits :: Int
maxFunArgSplits = 4

-- | Worker/wrapper through function arguments, function results, or plain
-- (in that order); the worker of a higher-order split goes round again.
splitHigherOrder :: Int -> WwOpts -> Id -> CoreExpr -> UniqSM [(Id, CoreExpr)]
splitHigherOrder fuel ww_opts fn_id rhs
  = do { mb_arg <- if fuel > 0 then splitFunArg ww_opts fn_id rhs else return Nothing
       ; case mb_arg of
           Just (work_id, work_rhs, wrapper) ->
             do { work_pairs <- splitHigherOrder (fuel - 1) ww_opts work_id work_rhs
                ; return (work_pairs ++ [wrapper]) }
           Nothing ->
             do { mb_res <- splitFunResult ww_opts fn_id rhs
                  -- See Note [Worker/wrapper for function results]
                ; case mb_res of
                    Just pairs -> return pairs
                    Nothing    -> splitFun ww_opts fn_id rhs } }

-- | A conversion for the values flowing to one place.
-- See Note [Worker/wrapper for function arguments]
data Conv = Conv
  { cv_unwrap :: CoreExpr -> UniqSM CoreExpr   -- ^ original value to new
  , cv_wrap   :: Id -> UniqSM CoreExpr         -- ^ new value (bound to the Id) to original
  , cv_new_ty :: Type                          -- ^ the type of the new values
  , cv_depth  :: Int }                         -- ^ nesting: 1 for (A), 1 + inner for (B)

-- | A value passed at an argument position
data ArgVal = ArgLam (IdEnv Id) CoreExpr [Var]
                -- ^ A lambda group, its value binders, and the let-bound
                -- variables in scope where it is (for the functions its
                -- body passes on)
            | ArgFun CoreExpr Id
                -- ^ A let-bound function (binder), perhaps applied to type
                -- arguments

argValExpr :: ArgVal -> CoreExpr
argValExpr (ArgLam _ e _) = e
argValExpr (ArgFun e _)   = e

classifyArg :: IdEnv Id -> CoreExpr -> Maybe ArgVal
classifyArg bound e = case classifyTail bound e of
  Just (LamTail e' bs)  -> Just (ArgLam bound e' bs)
  Just (VarTail e' b)   -> Just (ArgFun e' b)
  _                     -> Nothing

-- | Split a function so that one of its function parameters receives
-- workers.  Returns the worker (Id and right-hand side) and the wrapper.
splitFunArg :: WwOpts -> Id -> CoreExpr -> UniqSM (Maybe (Id, CoreExpr, (Id, CoreExpr)))
splitFunArg ww_opts fn_id rhs
  = do { mb <- funArgConv ww_opts fn_id rhs
       ; case mb of
           Nothing   -> return Nothing
           Just conv -> Just <$> mkFunArgPairs ww_opts fn_id rhs conv }

-- | The conversion for a function-argument split of this function, if any
funArgConv :: WwOpts -> Id -> CoreExpr -> UniqSM (Maybe Conv)
funArgConv ww_opts fn_id rhs
  | not (wo_fun_results ww_opts)                     = return Nothing
  | isJoinId fn_id                                   = return Nothing
  | isStableUnfolding (realUnfoldingInfo fn_info)    = return Nothing
  | not (null (ruleInfoRules (ruleInfo fn_info)))    = return Nothing
  | isNoInlinePragma (inlinePragInfo fn_info)        = return Nothing
  | isJust (certainlyWillInline uf_opts fn_info rhs)  = return Nothing
  | Just (arg_vars, _) <- collectNValBinders_maybe ww_arity rhs
  , not (null arg_vars)
    -- Value parameters only (not yet: type or coercion parameters)
  , all (\v -> isId v && not (isCoVar v)) arg_vars
  = lambdaConv ww_opts fn_id 1 [ArgLam emptyVarEnv rhs arg_vars]
  | otherwise = return Nothing
  where
    fn_info    = idInfo fn_id
    ww_arity   = workWrapArity fn_id rhs
    uf_opts    = so_uf_opts (wo_simple_opts ww_opts)

mkFunArgPairs :: WwOpts -> Id -> CoreExpr -> Conv -> UniqSM (Id, CoreExpr, (Id, CoreExpr))
mkFunArgPairs ww_opts fn_id rhs conv
             = do { work_rhs0 <- cv_unwrap conv rhs
                ; let work_rhs = simpleOptExpr simpl_opts work_rhs0
                ; work_uniq <- getUniqueM
                ; let work_id = mkWorkerId work_uniq fn_id (exprType work_rhs)
                                  `setIdArity`     arityInfo fn_info
                                  `setIdDmdSig`    dmdSigInfo fn_info
                                  `setIdCprSig`    cprSigInfo fn_info
                                  `setInlinePragma` (inlinePragInfo fn_info) { inl_rule = FunLike }
                ; wrap_rhs0 <- cv_wrap conv work_id
                ; let wrap_rhs = simpleOptExpr simpl_opts wrap_rhs0
                      wrap_unf = case mkWrapperUnfolding simpl_opts wrap_rhs (arityInfo fn_info) of
                                   unf@(CoreUnfolding { uf_guidance = g@(UnfWhen {}) })
                                     -> unf { uf_guidance = g { ug_boring_ok = boringCxtOk } }
                                   unf -> unf
                      wrap_id  = fn_id `setIdUnfolding`  wrap_unf
                                       `setInlinePragma` mkStrWrapperInlinePrag (inlinePragInfo fn_info) []
                                       `setIdOccInfo`    noOccInfo
                ; return (work_id, work_rhs, (wrap_id, wrap_rhs)) }
  where
    fn_info    = idInfo fn_id
    simpl_opts = wo_simple_opts ww_opts

-- | A conversion for a set of values at one position: (A) if splitting them
-- as functions gains something, else (B)
valuesConv :: WwOpts -> Id -> Int -> [ArgVal] -> UniqSM (Maybe Conv)
valuesConv ww_opts fn_id depth vals
  | depth > maxFunResultDepth = return Nothing
  | v0 : vs <- vals
  = do { mb_a <- functionsConv ww_opts fn_id v0 vs
       ; case mb_a of
           Just c  -> return (Just c)
           Nothing -> lambdaConv ww_opts fn_id depth vals }
  | otherwise = return Nothing

-- | (A): the values are functions; split them with mkWwBodies
functionsConv :: WwOpts -> Id -> ArgVal -> [ArgVal] -> UniqSM (Maybe Conv)
functionsConv ww_opts fn_id v0 vs
  | let k = foldr (min . valArity) (valArity v0) vs
  , k >= 1
  , Just (args, inner_res_ty) <- splitValArgs k (exprType (argValExpr v0))
  = do { let dmds = map finalise (foldr (zipWith lubDmd . valDemands k) (valDemands k v0) vs)
       ; xs <- mapM (\((m, ty), d) -> do { u <- getUniqueM
                                          ; return (mkSysLocal (fsLit "fa") u m ty
                                                     `setIdDemandInfo` d) })
                    (zip args dmds)
       ; mb_stuff <- mkWwBodies ww_opts fn_id k xs inner_res_ty dmds topCpr
       ; case mb_stuff of
           Nothing -> return Nothing
           Just (_, _, wrap_fn, work_fn) ->
             let unwrap e = return (simpleOptExpr simpl_opts (work_fn e))
             in return (Just (Conv { cv_unwrap = unwrap
                                   , cv_depth  = 1
                                   , cv_wrap   = \v -> return (wrap_fn v)
                                   , cv_new_ty = exprType (simpleOptExpr simpl_opts (work_fn (argValExpr v0))) })) }
  | otherwise = return Nothing
  where
    simpl_opts = wo_simple_opts ww_opts
    valArity (ArgLam _ _ bs) = length bs
    valArity (ArgFun _ b)  = idArity b
    valDemands k (ArgLam _ _ bs) = map idDemandInfo (take k bs)
    valDemands k (ArgFun _ b)  = take k (fst (splitDmdSig (idDmdSig b)) ++ repeat topDmd)
    finalise d | isStrictDmd d = d
               | otherwise     = trimBoxity d

-- | (B): the values are lambda groups, one of whose parameters is a function
-- that is only called, with values at some position that have a conversion
lambdaConv :: WwOpts -> Id -> Int -> [ArgVal] -> UniqSM (Maybe Conv)
lambdaConv ww_opts fn_id depth vals
  | Just lams <- mapM isLam vals
  , _ : _ <- lams
  , let m = minimum' [ length bs | (_, _, bs) <- lams ]
  , m >= 1
  = try_params [0 .. m - 1] lams m
  | otherwise = return Nothing
  where
    simpl_opts = wo_simple_opts ww_opts
    isLam (ArgLam env e bs) = Just (env, e, bs)
    isLam _                 = Nothing
    minimum' (x : xs) = foldr min x xs
    minimum' []       = 0

    try_params [] _ _ = return Nothing
    try_params (qi : qis) lams m
      = do { r <- try_param qi lams m
           ; case r of { Just c -> return (Just c); Nothing -> try_params qis lams m } }

    -- Parameter number qi of every lambda: only called, in every lambda,
    -- with at least ri value arguments, and the values at ri convertible
    try_param qi lams m
      | Just callss <- mapM (\(env, e, bs) -> paramCalls env (bs !! qi) (snd (splitValLams m e))) lams
      , let calls = concat callss
      , not (null calls)
      , let n_args = foldr (min . length . snd) maxBound calls
      = try_positions [0 .. n_args - 1] qi calls lams m
      | otherwise = return Nothing

    try_positions [] _ _ _ _ = return Nothing
    try_positions (ri : ris) qi calls lams m
      | Just vals' <- mapM (\(env, args) -> classifyArg env (args !! ri)) calls
      , isFunTy (exprType (argValExpr (headVal vals')))
      = do { mb_c <- valuesConv ww_opts fn_id (depth + 1) vals'
           ; case mb_c of
               Just c  -> mkLambdaConv qi ri m lams c
               Nothing -> try_positions ris qi calls lams m }
      | otherwise = try_positions ris qi calls lams m

    headVal (v : _) = v
    headVal []      = panic "lambdaConv"

    mkLambdaConv qi ri m lams inner
      | (_, e0, bs0) : _ <- lams
      , let q0 = bs0 !! qi
      , Just (q_args, q_res) <- splitValArgs (ri + 1) (idType q0)
      = do { let q_ty' = mkScaledFunTys [ Scaled mu (if i == ri then cv_new_ty inner else t)
                                        | (i, (mu, t)) <- zip [0 :: Int ..] q_args ] q_res
                 -- unwrap: the lambda's parameter qi becomes q', whose calls
                 -- pass  inner.unwrap e  at position ri
                 unwrap lam
                   = do { let (bs, body) = splitValLams m lam
                              q  = bs !! qi
                        ; u <- getUniqueM
                        ; let q' = mkLocalIdOrCoVar (mkSystemVarName u (fsLit "q")) (idMult q) q_ty'
                                     `setIdDemandInfo` idDemandInfo q
                        ; body' <- rewriteCalls q q' ri (cv_unwrap inner) body
                        ; return (mkLams [ if i == qi then q' else b | (i, b) <- zip [0 :: Int ..] bs ] body') }
                 -- wrap: \as -> l' .. (adapter a_q) ..
                 wrap l'
                   = do { as <- mapM (\b -> do { u <- getUniqueM
                                                ; return (mkSysLocal (fsLit "a") u (idMult b) (idType b)) })
                                     (take m bs0)
                        ; let a_q = as !! qi
                        ; cs <- mapM (\((mu, t), i) -> do { u <- getUniqueM
                                                         ; return (mkSysLocal (fsLit "c") u mu
                                                                     (if i == ri then cv_new_ty inner else t)) })
                                     (zip q_args [0 :: Int ..])
                        ; let c_r = cs !! ri
                        ; inner_wrapped <- cv_wrap inner c_r
                        ; let adapter = mkLams cs (mkApps (Var a_q)
                                          [ if i == ri then inner_wrapped else Var c | (i, c) <- zip [0 :: Int ..] cs ])
                              call = mkApps (Var l') [ if i == qi then adapter else Var a | (i, a) <- zip [0 :: Int ..] as ]
                        ; return (mkLams as call) }
           ; e0' <- unwrap e0
           ; return (Just (Conv { cv_unwrap = unwrap, cv_wrap = wrap
                                , cv_depth = 1 + cv_depth inner
                                , cv_new_ty = exprType (simpleOptExpr simpl_opts e0') })) }
      | otherwise = return Nothing

-- | The calls of a function parameter in a body: for each, the let-bound
-- variables in scope (for classifyArg) and its value arguments.  Nothing if
-- the parameter occurs other than as the head of a call.
paramCalls :: IdEnv Id -> Id -> CoreExpr -> Maybe [(IdEnv Id, [CoreExpr])]
paramCalls env0 q = go env0
  where
    go env e = case e of
      _ | (Var v, args) <- collectArgs e, v == q
        , not (null (filter isValArg args))
        -> do { rest <- concat <$> mapM (go env) args
              ; return ((env, filter isValArg args) : rest) }
      Var v | v == q    -> Nothing
            | otherwise -> Just []
      Lit {}           -> Just []
      Type {}          -> Just []
      Coercion {}      -> Just []
      App f a          -> (++) <$> go env f <*> go env a
      Lam _ b          -> go env b
      Let bind body    -> let env' = extendVarEnvList env [ (b, b) | b <- bindersOf bind ]
                          in (++) <$> (concat <$> mapM (go env') (rhssOfBind bind)) <*> go env' body
      Case s _ _ alts  -> (++) <$> go env s <*> (concat <$> mapM (\(Alt _ _ rhs) -> go env rhs) alts)
      Cast b _         -> go env b
      Tick _ b         -> go env b

-- | Rename a function parameter q to q' and convert its calls' argument at
-- value position ri
rewriteCalls :: Id -> Id -> Int -> (CoreExpr -> UniqSM CoreExpr) -> CoreExpr -> UniqSM CoreExpr
rewriteCalls q q' ri conv = go
  where
    go e = case e of
      _ | (Var v, args) <- collectArgs e, v == q, any isValArg args
        -> do { args' <- mapM go args
              ; args'' <- convertNth ri args'
              ; return (mkApps (Var q') args'') }
      Var {}        -> return e
      Lit {}        -> return e
      Type {}       -> return e
      Coercion {}   -> return e
      App f a       -> App <$> go f <*> go a
      Lam b body    -> Lam b <$> go body
      Let bind body -> Let <$> go_bind bind <*> go body
      Case s b ty alts -> Case <$> go s <*> pure b <*> pure ty
                               <*> mapM (\(Alt c bs rhs) -> Alt c bs <$> go rhs) alts
      Cast body co  -> (\b -> Cast b co) <$> go body
      Tick t body   -> Tick t <$> go body

    go_bind (NonRec b r) = NonRec b <$> go r
    go_bind (Rec prs)    = Rec <$> mapM (\(b, r) -> (,) b <$> go r) prs

    -- Convert the ri-th value argument
    convertNth n (a : as)
      | isValArg a, n == 0 = (: as) <$> conv a
      | isValArg a         = (a :) <$> convertNth (n - 1) as
      | otherwise          = (a :) <$> convertNth n as
    convertNth _ []        = return []

-- | Is every partial application of a function of the given arity called
-- at most once, and with at least k more arguments?  Then eta-expansion
-- loses no sharing.  See (EtaFirst) in Note [Worker/wrapper for function
-- results]
etaExpandable :: Arity -> Arity -> Demand -> Bool
etaExpandable arity k dmd = case dmd of
  _ :* sd -> go_arity arity sd
  where
    -- The calls with g's own arguments: any cardinality
    go_arity 0 sd = go_res True k sd
    go_arity n sd = go_arity (n - 1) (snd (peelCallDmd sd))
    -- The calls of the partial application: the first at most once, and k
    -- of them
    go_res _ 0 _ = True
    -- (peelCallDmd gives the top cardinality when there is no call)
    go_res first n sd = case peelCallDmd sd of
      (c, sd') | not first || isAtMostOnce c -> go_res False (n - 1) sd'
               | otherwise                   -> False

-- | A tail of a function body (Note [Worker/wrapper for function results])
data Tail = LamTail CoreExpr [Var]     -- ^ The lambda group, its value binders
          | VarTail CoreExpr Id        -- ^ A let-bound function, perhaps
                                       --   applied to type arguments
          | DeadTail CoreExpr
          | JumpTail                   -- ^ A jump to a join point bound on
                                       --   the path (its body's tails count)

tailExpr :: Tail -> CoreExpr
tailExpr (LamTail e _) = e
tailExpr (VarTail e _) = e
tailExpr (DeadTail e)  = e
tailExpr JumpTail      = panic "tailExpr: jump"

-- | A tail that returns a function: not a dead end, not a jump
isLiveTail :: Tail -> Bool
isLiveTail (LamTail {}) = True
isLiveTail (VarTail {}) = True
isLiveTail _            = False

tailArity :: Tail -> Arity
tailArity (LamTail _ bs) = length bs
tailArity (VarTail _ v)  = idArity v
tailArity (DeadTail _)   = 0
tailArity JumpTail       = 0

-- | The demands on the first k arguments of a tail
tailDemands :: Arity -> Tail -> [Demand]
tailDemands k (LamTail _ bs) = map idDemandInfo (take k bs)
tailDemands k (VarTail _ v)  = take k (fst (splitDmdSig (idDmdSig v)) ++ repeat topDmd)
tailDemands k (DeadTail _)   = replicate k botDmd
tailDemands k JumpTail       = replicate k botDmd

-- | Classify an expression in tail position.  'bound' maps the variables
-- let-bound on the path to it to their binders: an occurrence does not carry
-- the demand signature, its binder does.  Nothing: not a tail we can split.
classifyTail :: IdEnv Id -> CoreExpr -> Maybe Tail
classifyTail bound e = case e of
  _      | (Var j, _) <- collectArgs e, isJoinId j    -> Just JumpTail
  Lam {} | Just bs <- valueLams e                     -> Just (LamTail e bs)
  _      | (Var v, ty_args) <- collectArgs e
         , all isTypeArg ty_args
         , Just b <- lookupVarEnv bound v, idArity b >= 1 -> Just (VarTail e b)
  _      | exprIsDeadEnd e                            -> Just (DeadTail e)
         | otherwise                                  -> Nothing
  where
    -- A lambda group of value lambdas only (no type or coercion lambdas)
    valueLams (Lam b body) | isId b, not (isCoVar b) = (b :) <$> more body
    valueLams _ = Nothing
    more (Lam b body) | isId b, not (isCoVar b) = (b :) <$> more body
    more (Lam {})                               = Nothing
    more _                                      = Just []

-- | The tails of a body (through lets, join points, case alternatives and
-- ticks), or Nothing if some tail is not one we can split.  The bodies of
-- join points bound on the path are tails; jumps to them are JumpTails.
collectTails :: IdEnv Id -> CoreExpr -> Maybe [Tail]
collectTails bound e = case e of
  Let bind body
    | all isJoinId (bindersOf bind)
    -> do { jts <- concat <$> mapM (\(j, rhs) -> collectTails bound (joinRhsBody j rhs))
                                   (flattenBinds [bind])
          ; bts <- collectTails bound body
          ; return (jts ++ bts) }
    | otherwise
    -> collectTails (extendVarEnvList bound [ (b, b) | b <- bindersOf bind ]) body
  Case _ _ _ alts -> concat <$> mapM (\(Alt _ _ rhs) -> collectTails bound rhs) alts
  Tick _ body     -> collectTails bound body
  _               -> (: []) <$> classifyTail bound e

-- | The body of a join point's right-hand side, after its parameters
joinRhsBody :: Id -> CoreExpr -> CoreExpr
joinRhsBody j rhs = snd (joinRhsSplit j rhs)

joinRhsSplit :: Id -> CoreExpr -> ([Var], CoreExpr)
joinRhsSplit j rhs = case idJoinPointHood j of
  JoinPoint ar -> collectNBinders ar rhs
  NotJoinPoint -> ([], rhs)

-- | Rebuild a body, replacing each live tail by the given function and each
-- dead end by  case e of {}; case expressions get the new result type, and
-- join points bound on the path return it too (they are retyped, and the
-- jumps to them changed).  Follows collectTails exactly.
rebuildTails :: Type -> (CoreExpr -> CoreExpr) -> CoreExpr -> CoreExpr
rebuildTails new_ty new_tail = go emptyVarEnv emptyVarEnv
  where
    -- bound: let-bound variables (for classifyTail); joins: retyped joins
    go bound joins e = case e of
      Let bind body
        | all isJoinId (bindersOf bind)
        -> let prs    = flattenBinds [bind]
               js'    = [ retype j (mkLamTypes (fst (joinRhsSplit j rhs)) new_ty) | (j, rhs) <- prs ]
               joins' = extendVarEnvList joins (zip (map fst prs) js')
               rhs_env | isRec bind = joins'
                       | otherwise  = joins
               new_rhs (j, rhs) = let (ps, jb) = joinRhsSplit j rhs
                                  in mkLams ps (go bound rhs_env jb)
               bind' = case bind of
                         NonRec {} -> NonRec (headOr js') (new_rhs (headOr prs))
                         Rec {}    -> Rec (zip js' (map new_rhs prs))
           in Let bind' (go bound joins' body)
        | otherwise
        -> Let bind (go (extendVarEnvList bound [ (b, b) | b <- bindersOf bind ]) joins body)
      Case scrut b _ alts -> Case scrut b new_ty [ Alt c bs (go bound joins rhs) | Alt c bs rhs <- alts ]
      Tick t body         -> Tick t (go bound joins body)
      _ -> case classifyTail bound e of
             Just (DeadTail _) -> Case e (mkWildValBinder ManyTy (exprType e)) new_ty []
             Just JumpTail     -> retarget joins e
             Just _            -> new_tail e
             Nothing           -> pprPanic "rebuildTails" (ppr e)

    isRec (Rec {}) = True
    isRec _        = False

    -- A join point whose result type changes: its arity cannot exceed what
    -- the new type allows, and its demand and CPR signatures describe the
    -- old result
    retype j ty = setIdType j ty
                    `setIdArity`  min (idArity j) (typeArity ty)
                    `setIdDmdSig` nopSig
                    `setIdCprSig` topCprSig

    headOr (x : _) = x
    headOr []      = panic "rebuildTails"

    -- A jump to a retyped join point
    retarget joins e = case collectArgs e of
      (Var j, args) | Just j' <- lookupVarEnv joins j -> mkApps (Var j') args
      _ -> e

-- | The first k value arguments (multiplicity, type) of a function type,
-- and the rest
splitValArgs :: Arity -> Type -> Maybe ([(Mult, Type)], Type)
splitValArgs 0 ty = Just ([], ty)
splitValArgs n ty = case splitFunTy_maybe ty of
  Just (af, m, arg, res) | isVisibleFunArg af
    -> do { (args, r) <- splitValArgs (n - 1) res; return ((m, arg) : args, r) }
  _ -> Nothing

mkWWBindPair :: WwOpts -> Id -> IdInfo
             -> [Var] -> CoreExpr -> Unique -> Divergence
             -> ([Demand],JoinArity, Id -> CoreExpr, Expr CoreBndr -> CoreExpr)
             -> [(Id, CoreExpr)]
mkWWBindPair ww_opts fn_id fn_info fn_args fn_body work_uniq div
             (work_demands, join_arity, wrap_fn, work_fn)
  = -- pprTrace "mkWWBindPair" (ppr fn_id <+> ppr wrap_id <+> ppr work_id $$ ppr wrap_rhs) $
    [(work_id, work_rhs), (wrap_id, wrap_rhs)]
     -- Worker first, because wrapper mentions it
  where
    arity = arityInfo fn_info
            -- The arity is set by the simplifier using exprEtaExpandArity
            -- So it may be more than the number of top-level-visible lambdas

    simpl_opts = wo_simple_opts ww_opts

    work_rhs = work_fn (mkLams fn_args fn_body)
    work_act = case fn_inline_spec of  -- See Note [Worker activation]
                   NoInline _  -> inl_act fn_inl_prag
                   _           -> inl_act wrap_prag

    work_prag = InlinePragma { inl_src = SourceText $ fsLit "{-# INLINE"
                             , inl_inline = fn_inline_spec
                             , inl_sat    = Nothing
                             , inl_act    = work_act
                             , inl_rule   = FunLike }
      -- inl_inline: copy from fn_id; see Note [Worker/wrapper for INLINABLE functions]
      -- inl_act:    see Note [Worker activation]
      -- inl_rule:   it does not make sense for workers to be constructorlike.

    work_join_arity | isJoinId fn_id = JoinPoint join_arity
                    | otherwise      = NotJoinPoint
      -- worker is join point iff wrapper is join point
      -- (see Note [Don't w/w join points for CPR])

    work_id  = asWorkerLikeId $
               mkWorkerId work_uniq fn_id (exprType work_rhs)
                `setIdOccInfo` occInfo fn_info
                        -- Copy over occurrence info from parent
                        -- Notably whether it's a loop breaker
                        -- Doesn't matter much, since we will simplify next, but
                        -- seems right-er to do so

                `setInlinePragma` work_prag

                `setIdUnfolding` mkWorkerUnfolding simpl_opts work_fn fn_unfolding
                        -- See Note [Worker/wrapper for INLINABLE functions]

                `setIdDmdSig` mkClosedDmdSig work_demands div
                        -- Even though we may not be at top level,
                        -- it's ok to give it an empty DmdEnv

                `setIdCprSig` topCprSig

                `setIdDemandInfo` worker_demand

                `setIdArity` work_arity
                        -- Set the arity so that the Core Lint check that the
                        -- arity is consistent with the demand type goes
                        -- through

                `asJoinId_maybe` work_join_arity

    work_arity = length work_demands :: Int

    -- See Note [Demand on the worker]
    single_call = saturatedByOneShots arity (demandInfo fn_info)
    worker_demand | single_call = mkWorkerDemand work_arity
                  | otherwise   = topDmd

    wrap_rhs  = wrap_fn work_id
    wrap_prag = mkStrWrapperInlinePrag fn_inl_prag fn_rules
    wrap_unf  = mkWrapperUnfolding simpl_opts wrap_rhs arity

    wrap_id   = fn_id `setIdUnfolding`  wrap_unf
                      `setInlinePragma` wrap_prag
                      `setIdOccInfo`    noOccInfo
                        -- Zap any loop-breaker-ness, to avoid bleating from Lint
                        -- about a loop breaker with an INLINE rule

    fn_inl_prag     = inlinePragInfo fn_info
    fn_inline_spec  = inl_inline fn_inl_prag
    fn_unfolding    = realUnfoldingInfo fn_info
    fn_rules        = ruleInfoRules (ruleInfo fn_info)

mkStrWrapperInlinePrag :: InlinePragma -> [CoreRule] -> InlinePragma
mkStrWrapperInlinePrag (InlinePragma { inl_inline = fn_inl
                                     , inl_act    = fn_act
                                     , inl_rule   = rule_info }) rules
  = InlinePragma { inl_src    = SourceText $ fsLit "{-# INLINE"
                 , inl_sat    = Nothing

                 , inl_inline = fn_inl
                      -- See Note [Worker/wrapper for INLINABLE functions]

                 , inl_act    = activeAfter wrapper_phase
                      -- See Note [Wrapper activation]

                 , inl_rule   = rule_info }  -- RuleMatchInfo is (and must be) unaffected
  where
    -- See Note [Wrapper activation]
    wrapper_phase = foldr (laterPhase . get_rule_phase) earliest_inline_phase rules
    earliest_inline_phase = beginPhase fn_act `laterPhase` nextPhase InitialPhase
          -- laterPhase (nextPhase InitialPhase) is a temporary hack
          -- to inline no earlier than phase 2.  I got regressions in
          -- 'mate', due to changes in full laziness due to Note [Case
          -- MFEs], when I did earlier inlining.

    get_rule_phase :: CoreRule -> CompilerPhase
    -- The phase /after/ the rule is first active
    get_rule_phase rule = nextPhase (beginPhase (ruleActivation rule))

{-
Note [Demand on the worker]
~~~~~~~~~~~~~~~~~~~~~~~~~~~

If the original function is called once, according to its demand info, then
so is the worker. This is important so that the occurrence analyser can
attach OneShot annotations to the worker’s lambda binders.


Example:

  -- Original function
  f [Demand=<L,1*C(1,U)>] :: (a,a) -> a
  f = \p -> ...

  -- Wrapper
  f [Demand=<L,1*C(1,U)>] :: a -> a -> a
  f = \p -> case p of (a,b) -> $wf a b

  -- Worker
  $wf [Demand=<L,1*C(1,C(1,U))>] :: Int -> Int
  $wf = \a b -> ...

We need to check whether the original function is called once, with
sufficiently many arguments. This is done using saturatedByOneShots, which
takes the arity of the original function (resp. the wrapper) and the demand on
the original function.

The demand on the worker is then calculated using mkWorkerDemand, and always of
the form [Demand=<L,1*(C(1,...(C(1,U))))>]

Note [Thunk splitting]
~~~~~~~~~~~~~~~~~~~~~~
Suppose x is used strictly; never mind whether it has the CPR
property.  I'll use a '*' to mean "x* is demanded strictly".

      let
        x* = x-rhs
      in body

splitThunk transforms like this:
      let
        x* = let x = x-rhs in
             case x of { I# a -> I# a }
      in body

This is a little strange: we are re-using the same `x` in the RHS; and
the RHS takes `x` apart and reboxes it. But because the outer 'let' is
strict, and the inner let mentions `x` only once, the simplifier
transform it to
      case x-rhs of
        I# a -> let x* = I# a
                in body

That is good: in `body` we know the form of `x`, which
  * gives the CPR property, and
  * allows case-of-case to happen on x

Notes
* I tried transforming like this:
      let
        x* = let x = x-rhs in
             case x of { I# a -> x }
      in body
  where I return `x` itself, rather than reboxing it.  But this
  turned out to cause some regressions, which I never fully
  investigated.

* Suppose x-rhs is itself a case:
        x-rhs = case e of { T -> I# e1; F -> I# e2 }
  Then we'll get
      join j a = let x* = I# a in body
      in case e of { T -> j e1; F -> j e2 }
  which is good (no boxing).  But in the original, unsplit program
  we would transform
      let x* = case e of ... in body
  ==> join j2 x = body
      in case e of { T -> j2 (I# e1); F -> j (I# e2) }
  which is not good (boxing).

* In fact, splitThunk uses the function argument w/w splitting
  function, mkWWstr_one, so that if x's demand is deeper (say U(U(L,L),L))
  then the splitting will go deeper too.

* For recursive thunks, the Simplifier is unable to float `x-rhs` out of
  `x*`'s RHS, because `x*` occurs freely in `x-rhs`, and will just change it
  back to the original definition, so we just split non-recursive thunks.

Note [Thunk splitting for top-level binders]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Top-level bindings are never strict. Yet they can be absent, as T14270 shows:

  module T14270 (mkTrApp) where
  mkTrApp x y
    | Just ... <- ... typeRepKind x ...
    = undefined
    | otherwise
    = undefined
  typeRepKind = Tick scc undefined

(T19180 is a profiling-free test case for this)
Note that `typeRepKind` is not exported and its only use site in
`mkTrApp` guards a bottoming expression. Thus, demand analysis
figures out that `typeRepKind` is absent and splits the thunk to

  typeRepKind =
    let typeRepKind = Tick scc undefined in
    let typeRepKind = absentError in
    typeRepKind

But now we have a local binding with an External Name
(See Note [About the NameSorts]). That will trigger a CoreLint error, which we
get around by localising the Id for the auxiliary bindings in 'splitThunk'.
-}

-- | See Note [Thunk splitting].
--
-- splitThunk converts the *non-recursive* binding
--      x = e
-- into
--      x = let x' = e in
--          case x' of I# y -> let x' = I# y in x'
-- See comments above. Is it not beautifully short?
-- Moreover, it works just as well when there are
-- several binders, and if the binders are lifted
-- E.g.     x = e
--     -->  x = let x' = e in
--              case x' of (a,b) -> let x' = (a,b)  in x'
-- Here, x' is a localised version of x, in case x is a
-- top-level Id with an External Name, because Lint rejects local binders with
-- External Names; see Note [About the NameSorts] in GHC.Types.Name.
--
-- How can we do thunk-splitting on a top-level binder?  See
-- Note [Thunk splitting for top-level binders].
splitThunk :: WwOpts -> RecFlag -> Var -> Expr Var -> UniqSM [(Var, Expr Var)]
splitThunk ww_opts is_rec x rhs
  = assert (not (isJoinId x)) $
    do { let x' = localiseId x -- See comment above
       ; (useful,_args, wrap_fn, fn_arg)
           <- mkWWstr_one ww_opts x' NotMarkedStrict
       ; let res = [ (x, Let (NonRec x' rhs) (wrap_fn fn_arg)) ]
       ; if useful then assertPpr (isNonRec is_rec) (ppr x) -- The thunk must be non-recursive
                   return res
                   else return [(x, rhs)] }
