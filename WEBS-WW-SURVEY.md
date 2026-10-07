# Worker/Wrapper-Style Transformations in GHC, and Their Web Counterparts

GHC changes calling conventions in many places, almost always with the same
trick: split a function into a **worker** with the new convention and a
**wrapper** with the old one, then rely on the inliner to inline the wrapper at
call sites. That works only where the call site is *known*, i.e. the function
is called by name and the wrapper can be inlined. Webs give the other route:
change the convention of **every producer and consumer of a web at once**, with
no wrapper. That also reaches *unknown* calls (higher-order functions), and
needs neither wrappers nor the inliner.

This survey lists the transformations in this GHC tree (`9.15`) that follow
this pattern, where they live, and what a web-based version would be. For
each: **Status** says whether we have a web version. File paths are relative
to `compiler/`.

## 1. Strictness-based argument unboxing (the core W/W)

- **Where:** `GHC/Core/Opt/WorkWrap.hs`, `GHC/Core/Opt/WorkWrap/Utils.hs`
  (`mkWwBodies`, `mkWWstr`, `mkWWstr_one`, `unbox_one_arg`). Notes
  [Worker/wrapper for strict arguments], [Unboxing through unboxed tuples].
  Boxity analysis in `GHC/Core/Opt/DmdAnal.hs` decides what to unbox.
- **What:** a function strict in a product argument gets a worker that takes
  the fields; the wrapper unboxes at the call site.
- **Web version:** arity raising (`GHC/WebCore/Transform/ArityRaise.hs`). It
  works for unknown functions too (e.g. functions passed to a local
  higher-order function), with no wrapper.
- **Status:** done. Not yet done: nested unboxing (a pair of pairs; GHC
  unboxes recursively up to a depth), and unboxing sums (GHC only does this
  with `-funbox-small-strict-fields`-like flags for fields, not arguments).

## 2. Absent arguments

- **Where:** `mkAbsentFiller` in `WorkWrap/Utils.hs`; Notes [Absent fillers],
  [Protecting the last value argument], [Do not split void functions],
  [Worker/wrapper needs to add void arg last].
- **What:** the worker drops arguments the function never uses; the wrapper
  passes an "absent" filler. When all value arguments are dropped, GHC adds a
  `(# #)` argument so the worker stays a function.
- **Web version:** dead-parameter elimination
  (`GHC/WebCore/Transform/DeadParams.hs`). Its "unit" mode is the same
  `(# #)` trick, and it decides per web whether deleting is safe.
- **Status:** done.

## 3. CPR: constructed product results

- **Where:** `GHC/Core/Opt/CprAnal.hs` (analysis); `mkWWcpr`, `mkWWcpr_one`,
  `move_transit_vars` in `WorkWrap/Utils.hs`. Notes [Always do CPR w/w],
  [CPR for thunks], [Don't w/w join points for CPR], [Linear types and CPR].
- **What:** a function that always returns a freshly built constructor
  returns its fields as an unboxed tuple instead; the wrapper re-boxes.
- **Web version — result raising.** For a web whose lambdas all return a
  constructor application of the same product type (CPR property per lambda),
  rewrite `A -{w}-> T ts` to `A -{w}-> (# fields #)`. Lambdas return
  `(# fields #)`; every call `f @^w a` becomes
  `case f @^w a of (# xs #) -> K xs` (re-box), and the re-box cancels when the
  caller scrutinises the result.
- **Laziness:** the call is already evaluated where its result is demanded,
  and the re-box is in the same place, so nothing is forced earlier. A lazy
  call (`let r = f x in ..`) stays a thunk whose body is the case.
- **Status:** done: result raising (`WEBS-RESULT-RAISING.md`,
  `Transform/ResultRaise.hs`). In the early run, webs whose calls are all
  known are left to GHC's worker/wrapper (Note [Early result raising]).

## 4. Calling-convention unlifting (call-by-value arguments)

- **Where:** Note [WW for calling convention] in `WorkWrap/Utils.hs`,
  `-fworker-wrapper-cbv`; Note [CBV Function Ids] and `WorkerLikeId [CbvMark]`
  in `GHC/Types/Id/Info.hs`; enforcement in `GHC/Stg/EnforceEpt.hs`
  (Note [EPT enforcement]).
- **What:** if a function always evaluates a (non-product) argument, the
  caller evaluates it instead, and the worker may assume it is evaluated and
  tagged. GHC does this only for workers it creates, because a wrapper or
  eta-expansion is needed at unknown call sites. The Note discusses an option
  C, "change the calling convention of the binding itself", which it rejects
  because it would need eta-expansion at every call site.
- **Web version — strict-argument passing.** That is exactly what webs make
  possible without eta-expansion: for a non-exposed web whose lambdas are all
  strict in their argument (and not curried, as in arity raising §2), evaluate
  the argument at every call (`case a of a' -> f @^w a'`) and mark the
  lambdas' binders as evaluated (CBV marks, after Tidy).
- **Status:** done: web strictness (`WEBS-STRICTNESS.md`,
  `Transform/Strictness.hs`), with fixpoints across webs.

## 5. Thunk splitting

- **Where:** Notes [Thunk splitting], [Thunk splitting for top-level binders]
  in `WorkWrap.hs`.
- **What:** W/W on strict, CPR'd let-bound thunks.
- **Web version:** none; it is about thunks, not functions. Out of scope.

## 6. Join points

- **Where:** Notes [Don't w/w join points for CPR], [Join points and
  beta-redexes]; arity rules in Note [Do not eta-expand join points]
  (`GHC/Core/Opt/Arity.hs`).
- **Web version:** every web pass handles join points directly (jumps are
  always saturated, so join webs avoid several laziness conditions).
- **Status:** handled in the three existing passes.

## 7. Data constructor wrappers (strict and unpacked fields)

- **Where:** `GHC/Types/Id/Make.hs` (`mkDataConRep`); Notes [Unpack one-wide
  fields], [Recursive unboxing], [Data con wrappers and unlifted types].
- **What:** a constructor's wrapper evaluates strict fields and unpacks
  `UNPACK`ed ones; the worker takes the representation.
- **Web version — field webs for local data types.** Today every data
  constructor is a boundary (its signature is exposed). For a data type that
  is not exported, its constructors' arrows could be ordinary webs. Then
  dead-field elimination and field-level arity raising (unpacking a field
  that is always a product and always forced) become web transformations.
- **Status:** not done; needs annotation to treat local data constructors as
  local. Medium value.

## 8. SpecConstr: call-pattern specialisation

- **Where:** `GHC/Core/Opt/SpecConstr.hs`; Notes [Good arguments],
  [Specialising for constant parameters], [Specialising for lambda parameters].
- **What:** clones a recursive function for argument shapes seen at call
  sites (`f (x:xs)`), with RULES redirecting calls.
- **Web version — constructed-argument raising.** If *every* call in a web
  passes an explicit constructor application of the same product type, the
  web can be raised even when some lambda is *lazy* in it. Each lambda
  re-boxes its argument (`let p = K xs`), which is always in WHNF, just like
  the original argument. So the strictness condition of arity raising is not
  needed. This covers lazy functions that SpecConstr reaches only by
  specialising.
- **Status:** not done. Medium value; a small extension of `ArityRaise.hs`
  (a second eligibility rule).

## 9. Type-class specialisation and dictionary passing

- **Where:** `GHC/Core/Opt/Specialise.hs`; Notes [Specialising on
  dictionaries] (SpecConstr), [Dict funs and default methods] (`Id/Make.hs`).
- **What:** clones overloaded functions for known dictionaries.
- **Web version — constant-argument webs.** If every call in a web passes
  the same global dictionary (or the same constant), drop the parameter and
  substitute the constant in each lambda. Dictionary arrows (`=>`) carry webs
  already.
- **Caveat:** needs specialisation when the constant's type mentions the
  web's type variables (the `arityraise008` situation).
- **Status:** not done. Medium value.

## 10. Static argument transformation

- **Where:** `GHC/Core/Opt/StaticArgs.hs` (`-fstatic-argument-transformation`).
- **What:** for a recursive function that passes some arguments unchanged
  to itself, introduce a local loop closed over them.
- **Web version:** the same constant-argument idea as §9, restricted to
  recursive calls. Low priority: the GHC pass is off by default.

## 11. Eta-expansion and arity

- **Where:** `GHC/Core/Opt/Arity.hs` (`etaExpand`, arity analysis; Notes
  [Dealing with bottom], [The state-transformer hack], [Exciting arity]);
  saturation in `GHC/CoreToStg/Prep.hs` (`cpeEtaExpand`).
- **What:** raises a binding's arity when no work is lost, so calls become
  saturated.
- **Web version:** uncurrying (`GHC/WebCore/Transform/Uncurry.hs`) changes
  the *type* of the whole web, so unknown calls become saturated calls with a
  known arity, which GHC's arity analysis cannot do for higher-order code.
- **Status:** done (for direct lambdas). Not done: uncurrying when the work
  between the lambdas is cheap (`exprIsCheap`), which Arity.hs would allow.

## 12. Unarisation

- **Where:** `GHC/Stg/Unarise.hs` (Note [Unarisation]).
- **What:** flattens unboxed tuples and sums into multiple arguments and
  results.
- **Web relevance:** this is the *target* of our multi-argument encoding
  (`(# A, B #) -> C`). No web version needed.

## 13. Late lambda lifting and closure conversion

- **Where:** `GHC/Stg/Lift.hs`, `GHC/Stg/Lift/` (`-fstg-lift-lams`).
- **What:** turns local functions into top-level functions with their free
  variables as extra arguments, to avoid closure allocation.
- **Web version — defunctionalisation.** The paper's headline example: for a
  non-exposed web with a small, known set of lambdas, replace the function
  values by a data type with one constructor per lambda (holding its free
  variables), and every call by a case that dispatches to the lambda's body.
  This removes unknown calls entirely.
- **Status:** not done. **High value** and well-supported by the paper, but
  the largest of these to implement.

## 14. Newtypes and casts

- **Where:** Notes [Newtype datacons], [Compulsory newtype unfolding]
  (`Id/Make.hs`).
- **Web relevance:** today every coercion axiom is exposed, including those of
  *local* newtypes. For a newtype that is not exported, its axiom could carry
  ordinary webs, so functions wrapped in local newtypes (e.g. a local `State`
  monad) become transformable.
- **Status:** not done. Medium value; it widens all the existing passes.

## Interaction with the inliner

GHC's W/W depends on the inliner: the wrapper only helps if it is inlined at
every call site. Hence a family of rules about pragmas and activation phases:
Notes [Don't w/w INLINE things], [Worker/wrapper for INLINABLE functions],
[Worker/wrapper for NOINLINE functions], [Wrapper activation], [Worker
activation], [Don't w/w inline small non-loop-breaker things] (all in
`WorkWrap.hs`). Wrappers also delay RULES (#20364). A web transformation has
no wrapper, so a web version of a W/W pattern that runs *before* the main
simplifier could remove the need for some W/W splits, and with them the
inlining of wrappers. The early-pipeline flag (`-fcore-webs-early`) and the
inliner measurements test this hypothesis.

## Suggested order

| Priority | Transformation | Builds on |
|---|---|---|
| 1 | Result raising (CPR, §3) | ArityRaise's encoding |
| 2 | Strict-argument passing (call-by-value, §4) | ArityRaise's strictness rule |
| 3 | Constructed-argument raising (§8) | ArityRaise |
| 4 | Local newtypes and local data constructors (§7, §14) | annotation |
| 5 | Defunctionalisation (§13) | new pass |
| 6 | Constant-argument webs (§9, §10) | needs specialisation |
