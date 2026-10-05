# Design: Higher-Order Worker/Wrapper for GHC

Status: §2.1 (function results) and §2.2 (function arguments) implemented
behind `-fworker-wrapper-function-results` (Notes [Worker/wrapper for
function results] and [Worker/wrapper for function arguments] in
`GHC.Core.Opt.WorkWrap`). Branch `ww-higher-order`, from `master`. It is independent
of the webs: it is an extension of GHC's
own demand analysis and worker/wrapper (`GHC.Core.Opt.DmdAnal`,
`GHC.Core.Opt.WorkWrap`, `GHC.Core.Opt.WorkWrap.Utils`). It is based on the
examples in `WORKING-THE-WORKER-WRAPPER.md`.

## 1. The problem, in GHC today

Worker/wrapper splits a function according to its demand signature, and the
signature covers only the function's arity (Note [Demand signatures are
computed for a threshold arity]). A function that **returns** a function,
**takes** one, or **stores** one in a data structure has a second function
inside its type whose arguments worker/wrapper cannot see. That second
function may have dead or strict arguments, or arguments worth unboxing.

GHC's existing answer is eta-expansion. If

```haskell
g n = let f x y = e in f          -- y dead in e
```

can be eta-expanded to `g n x y = e`, the ordinary worker/wrapper drops `y`.
Eta-expansion is not possible when `g` does work before returning the
function and the partial application `g n` is shared:

```haskell
g n = let k = expensive n
          f x y = e[k, x]         -- y dead
      in f
run n a b = let h = g n in h a b + h b a      -- k computed once per h
```

Eta-expanding `g` would recompute `k` at every call of `h`. Then what GHC
does depends on whether `f` is still `let`-bound when worker/wrapper runs
(it runs late, after the main simplifier and demand analysis). The tests
in `testsuite/tests/dmdanal/should_compile` record each case:

| shape | GHC today | test |
|---|---|---|
| `g` cheap, inlinable | inlines `g`, copies `f`'s body to every call | `wwreturn001` |
| `f` used once (`let f = .. in f`) | the binding is inlined before worker/wrapper runs; `g` returns `\x _ -> e`; no split at all; calls pass `y` and boxed `x` | `wwreturn002` |
| `f` large, used more than once | `f` is split into `$wf` and a wrapper, and `g` returns the wrapper `\x _ -> case x of I# x# -> $wf x#`; every call of `h` is an unknown call of that wrapper, passing `y` and boxed `x` | `wwreturn003` |

The cost in all three: an unknown call of a closure that takes a dead
argument and boxed values, while a worker exists, or could, that takes
neither.

## 2. The idea: split the outer function through the inner one

In each case, split the *outer* function so that the inner function's
worker crosses the boundary instead of its wrapper. Every split is a
worker/wrapper pair. It is correct when `wrap . unwrap = id` and the two are
closed, in the sense of `WEBS-WW.md`: `unwrap` is evaluated where the
function is defined, `wrap` where it is used.

### 2.1 Returned functions (the main case)

```haskell
g n = let k = expensive n in \x y -> e[k, x]              -- y dead, x strict

==>
$wg n = let k = expensive n in \x# -> e[k, I# x#]        -- worker returns f's worker
g n   = case $wg n of f' -> \x y -> case x of I# x# -> f' x#   -- wrapper, INLINE
```

At a saturated call, the wrapper inlines, and
`g n a b = case $wg n of f' -> case a of I# a# -> f' a#`: no dead argument,
no boxing.

For a shared partial application,
`h = g n = case $wg n of f' -> \x y -> ...`. `k` is still computed once per
`h`, because `$wg n` is evaluated once, when `h` is forced. But the calls
`h a b` are still unknown calls of the wrapper lambda. To reach the worker
there, the binding must be split as well (§2.4).

**Soundness.**
- **Divergence.** The wrapper uses `case $wg n of f'`, not `let`. So
  `g n` diverges exactly when `$wg n` does, which is exactly when the
  original `g n` did: the bodies differ only in the lambda they return.
  With `let`, `g n` would always be a lambda, which is more defined.
- **The identity.** `wrap (unwrap f) = \x y -> case x of I# x# -> f (I# x#) ⊥`
  equals `f` when `f` ignores `y`, is strict in `x`, and is a lambda of
  arity at least 2 that does no work between its lambdas. That is what the
  analysis (§3) must establish for every value `g n` can return.
- **Sharing.** Work in `g`'s body before the returned lambda (`k`) stays in
  `$wg n` and is shared as before. Work between the returned lambda's own
  arguments would not be shared after the split, so the returned lambda
  must be a manifest lambda group of the required arity.

### 2.2 Function arguments

```haskell
h g = let f x y = ... in                 -- y dead
      ... f 1 2 ... + g f                -- f used locally (big) and passed to g

==> (after the ordinary split of f)
h g = let f' x = ... in ... f' 1 ... + g (\x y -> f' x)

==>
$wh g' = let f' x = ... in ... f' 1 ... + g' f'
h g    = $wh (\f' -> g (\x y -> f' x))       -- wrapper, INLINE
```

At a call `h (\q -> q 3 4)`, the wrapper inlines, and the argument becomes
`\f' -> (\q -> q 3 4) (\x y -> f' x)`, which simplifies to `\f' -> f' 3`.
The consumer now calls the worker directly. This is worker/wrapper on the
*argument's* argument (contravariant): `$wh` passes `f'` to `g'`, and the
wrapper adapts the caller's `g`.

**Soundness.** `$wh (\f' -> g (wrapF f')) = h g`, with `wrapF f' = \x y -> f' x`,
when every function `$wh` passes to `g'` is a worker of the shape the
wrapper expects. That is a property of `h`'s body (it passes only `f'`),
established by analysis. The adapter is closed; it mentions only its own
binders.

### 2.3 Data structures (out of scope)

```haskell
g n lst = let f x y = e in f : lst                     -- y dead
... foldr g [] xs ...

==>
$wg n lst = let f' x = e in f' : lst                   -- a list of workers
... map (\f' -> \x y -> f' x) (foldr $wg [] xs) ...
```

This is the same idea through a type constructor: worker/wrapper on the
element type of a list. A `map` of the wrapper restores the original list.

**Not pursued.** It only pays when the restoring `map` fuses with the
consumer (`foldr/build`), so that the consumer calls `f'` directly. Nothing
guarantees that fusion happens downstream. When it does not, the split costs
an extra traversal and a new list, so the transformation cannot be relied
on. A data structure of functions needs a type-directed transformation of
the element type across all producers and consumers, which is what the webs
do (`webs` branch), not a local worker/wrapper split.

### 2.4 Shared partial applications

For `h = g n` used as `h a b`, the wrapper inlines to
`h = case $wg n of f' -> \x y -> f' x#`. The calls of `h` reach the worker
only if the binding itself is split (thunk splitting for a function-valued
`let`):

```haskell
let h = case $wg n of f' -> \x y -> body[f']
in ... h a b ...

==>
let h' = $wg n                      -- the worker closure, shared
in ... (case h' of f' -> body[f']) a b ...      -- then beta: case h' of f' -> f' a#
```

This is valid when `h` is only ever *called* (its usage demand is a call
demand). Then evaluating `h'` at each call is the same as evaluating `h`
once, because `h'` is shared. Demand analysis knows the usage: `h` above has
usage `C(1,C(1,L))`. If `h` is `seq`ed or escapes, keep it.

## 3. The analysis

For §2.1 we need, for a binder `g` of arity `n`, a **result-function
signature**: every value its body returns after `n` arguments is a manifest
lambda group of arity at least `k`, with argument demands `ds` (absent,
strict, unboxable). This is to functions what CPR is to products, so call it
"constructed lambda result". Two ways to compute it:

1. **In the demand analyser.** When the body's tails, through `let`,
   `case` and join points, are manifest lambdas, analyse them under a call
   demand of depth `k` and record their argument demands. The demand
   analyser already analyses a lambda body under the incoming call demand.
   What is missing is to *record* it in `g`'s signature beyond `g`'s
   arity. That would be a new field of `DmdSig` (a nested signature for the
   result), analogous to nested CPR.
2. **From the inner function's signature.** When the tail is a variable `f`
   bound locally to a lambda (the `wwreturn003` shape), use `f`'s own demand
   signature. The `wwreturn002` shape (the lambda inlined into the tail) needs
   option 1.

The depth `k` of the call demand to use comes from the usage: the binder's
usage demand (idDemandInfo) says how many arguments the result is applied
to (`h a b`: two).

For §2.2: an analysis that a function parameter is applied only to
particular known local functions (here `f`). This is a much narrower fact.
It can be read off the body syntactically: every occurrence of `g` is
`g f` with the same local `f`.

## 4. Where it goes in GHC

- **`GHC.Types.Demand`:** a result-function signature in `DmdSig` (or a
  separate signature on the binder, like `CprSig`).
- **`GHC.Core.Opt.DmdAnal`:** compute it (§3). Interface files must carry it
  so that wrappers work across modules: `GHC.Iface.Syntax`,
  `GHC.CoreToIface`, `GHC.IfaceToCore`.
- **`GHC.Core.Opt.WorkWrap.Utils`:** `mkWwBodies` builds wrapper and worker
  bodies from argument demands. Extend it to wrap the *result*: the worker's
  tails become the inner lambda's worker (reusing `mkWwBodies` for the inner
  lambda), and the wrapper's body becomes
  `case worker args of f' -> <inner wrapper of f'>`. The CPR machinery
  (`mkWWcpr_entry`) is the model for changing a result.
- **`GHC.Core.Opt.WorkWrap`:** `tryWW` decides when to split. It splits when
  the result-function signature has something to gain (an absent argument,
  or an unboxable strict one), and the inner function would not be exposed
  by eta-expansion anyway (the binder's arity is below the manifest arity
  of its use).
- **§2.4:** in the simplifier, or as a small pass after worker/wrapper:
  a `let` whose right-hand side is `case w args of f' -> \xs -> body`, and
  whose usage demand is a call demand, is split as above.
- A flag, `-fworker-wrapper-function-results`, off by default until it is
  measured.

## 5. Tests

- **Expected output:** `wwreturn002` and `wwreturn003`, which record GHC
  today, change to show `$wg` returning the worker and the calls passing
  `a#` with no dead argument. `wwreturn001` should not change (eta-expansion
  and inlining already handle it).
- **Laziness:**
  1. `g n` diverges before returning its lambda; `seq (g n) ()` must still
     diverge (checks the `case`, not `let`, in the wrapper).
  2. `k` traced with `Debug.Trace`: one trace per partial application `h`,
     not one per call (sharing).
  3. The returned function is lazy in `x` on some path: no unboxing.
  4. `h` is `seq`ed: the `let` split of §2.4 must not happen.
- **Cross-module:** `g` exported and used from another module; its wrapper
  must inline there, through the interface file.
- **nofib:** allocation, the number of unknown calls left after optimisation
  (`-ddump-first-class-stats` on the `webs` branch counts them), code size.

## 6. Status of the implementation (§2.1)

`splitFunResult` in `GHC.Core.Opt.WorkWrap`, tried before the ordinary split:

- The tails of the body (through `let`, `case`, ticks) must be manifest
  lambda groups, `let`-bound functions (possibly applied to type arguments,
  e.g. `f @Int` when `f`'s dead argument got a polymorphic type), or dead
  ends. The demand on each of the returned function's `k` arguments is the
  least upper bound over the tails. For a variable tail it is taken from the
  `let` binder, since occurrences do not carry demand signatures.
- The worker returns the returned function's worker (`mkWwBodies`). The
  wrapper is `case $wg args of wf -> <returned function's wrapper of wf>`.
  Then the ordinary split runs on the worker.
- **Boxity:** only strict combined demands may unbox. A returned lambda's
  binders are not finalised by `finaliseArgBoxities`, and can be lazy but
  marked unboxed (bug found by `wwfunres003`).
- **No split when eta-expansion is safe:** if each partial application is
  called at most once with all `k` arguments, GHC eta-expands instead
  (`T18894b`).
- **Inline in boring contexts:** the wrapper's unfolding is `boring_ok`, so
  it inlines into `let h = g n`.
- **Shared partial applications (§2.4), via the wrapper:** by default the
  wrapper binds the worker's result with `let`, not `case`:
  `g = \n -> let wf = $wg n in \x y -> ... wf ...`. Inlined into
  `let h = g n`, the simplifier floats `wf` out of `h`, `h` becomes a lambda
  and is inlined at its uses. So even a lazy `h` captured by a lambda
  (`map (\a -> h a a) xs`) ends up calling `wf` directly (`wwfunres005`), and
  `$wg n` is still computed once. No separate pass is needed. The price is
  definedness: `g n` is a lambda even when `$wg n` diverges, the trade GHC
  already makes by default when eta-expanding (Note [Dealing with bottom]).
  With `-fpedantic-bottoms` the wrapper uses `case` and is exact
  (`wwfunres001`).
- **Several levels in one pass:** a function may return a function that
  returns a function, each level doing work first. Going down (as long as
  every returned value is a lambda group, up to depth 4), the analysis
  collects each level's combined demands and decides whether splitting
  that level gains anything. Coming back up, each level's new type is known
  from below. The wrapper is introduced once, at the definition, with one
  `let` per level, so each level's work stays shared:
  `g = \n -> let wf1 = $wg n in \a -> let wf2 = wf1 a in \b -> ... \x y -> wf3 x`.
  Levels at which nothing is gained keep their lambdas. Tests: `wwdeep001`
  (three levels), `wwdeep002` (levels 1 and 3 in one pass), `wwdeep003`
  (five levels, beyond the depth: unchanged), `wwdeep004` (divergence at
  level 2, `-fpedantic-bottoms`), `wwdeep_dump`.
- **Join points:** a returned function can be the body of a join point on
  the path (GHC turns a local function used in several branches into one).
  Its body's tails are tails, and it is retyped: new result type, arity
  capped by the new type, demand and CPR signatures reset (`wwmix002`,
  `wwmix002_dump`; without the arity fix, Core Lint failed).
- **Mixed cases** (`wwmix001`-`005`): with the ordinary split of the
  function's own arguments; returned functions from a lambda, a join point
  and an error; a partial application that is both called and stored; a
  join point inside the returned function. Two cases correctly do nothing:
  a recursive function whose recursive tail passes the dead argument on
  (`wwmix003`; finding that it is dead needs a fixed point, as demand
  analysis does), and an overloaded function that GHC inlines and
  specialises anyway (`wwmix004`).
- **Function arguments (§2.2):** a *conversion* for the values that flow
  to one argument position is a closed pair `unwrap` (original value to
  new) and `wrap` (back), with `wrap (unwrap v) = v`. It is either (A) an
  ordinary worker/wrapper split of the functions passed there (combined
  demands, `mkWwBodies`), or (B) for lambdas passed there, one of whose
  parameters `q` is only ever called, with values at some position that
  have a conversion found first, recursively, going down: `unwrap` rewrites
  `q`'s calls, `wrap l' = \as -> l' ... (adapter a_q) ...`. `h` itself is
  split by a conversion of kind (B) for its own right-hand side, so the
  wrappers are collated and introduced only at the definition:
  `h = \g n -> $wh (\c -> g (\x _ -> c x)) n`. Nesting (`g` given a
  function that is given `f`) is (B) inside (B). One parameter per split;
  the worker is tried again for the others (up to 4). Not for `NOINLINE`
  functions, or functions with type parameters (yet).

  Tests: `wwhoarg001` (the README example: the caller's function becomes
  `\c -> c 1 ...`, calling the worker without the dead argument),
  `wwhoarg002` (nested: `\c -> c 9#` two levels in), `wwhoarg003` (two
  local functions at one position), `wwhoarg004` (`g` escapes: no split),
  `wwhoarg005` (laziness: `g` undefined and not called, `g` ignoring `f`,
  the dead argument undefined), `wwhoarg006` (argument and result splits
  composed: `h = \a a1 -> let wf = $w$wh (\c -> a (\fa _ -> c fa)) a1 in
  \fr _ -> wf fr`), `wwhoarg007` (two parameters), `wwhoarg008` (recursive
  `h` passing `g` on: not split; the recursive call could pass `g'`),
  `wwhoarg009` (a lambda argument lazy in `x`: not unboxed; mutation-checked),
  and the dump tests `wwhoarg001/002/006_dump`.
- **Not yet:** the returned lambda's own arguments are not unboxed unless
  the inner function's signature says so (e.g. `wwreturn003`). Demand
  analysis looks at a returned lambda as if it might not be called, so its
  binders' demands are lazy. Recording the result's demands in the analysis
  (§3 option 1) would fix that.

Results:

- `wwreturn002_funres`, `wwreturn003_funres`: `$wg` returns the worker (no
  dead argument, unboxed `x`), and the calls are `case wf ww of ...`.
- `wwfunres001`–`004` (dmdanal/should_run): divergence, sharing, a lazy
  argument, escaping partial applications. `wwfunres001` was
  mutation-checked: with `let` instead of `case` in the wrapper, it fails.
- **Small functions are not split:** a function small enough to be inlined
  whole (`certainlyWillInline`) is left alone, as in the ordinary split. A
  derived `Eq` method that builds a dictionary and returns the comparison
  used to be split, and every comparison in the importing module then
  allocated a dictionary and a closure, where before the method was inlined
  (`T16038`'s output changed).
- With the flag on everywhere, the smoke suite (about 3,000 tests across
  dmdanal, cpranal, simplCore, typecheck, codeGen, programs, th, ...) has no
  Lint errors, wrong results, or changed expected output (other than
  `wwreturn002`/`003`, which record the flag-off output).

## 7. How often it applies: nofib

`-ddump-ww-ho-stats` (Note [Higher-order worker/wrapper statistics]) over
nofib (115 benchmarks, `fast` mode; `ww-bench/`, report in
`ww-bench/report-latest.md`), summed over all modules:

| point | function bindings | return a function | take a function | result splits | argument splits |
|---|---|---|---|---|---|
| early (before the main simplifier) | 7,567 | 443 | 626 | 8 | 0 |
| pre-ww (where worker/wrapper decides) | 8,947 | 335 | 632 | 7 | 0 |
| final, flag off | 10,770 | 369 | 768 | 9 | 0 |
| final, flag on | 10,778 | 376 | 769 | 2 | 0 |

- **Splits are rare.** About 2% of the functions that return a function are
  split. The 7 at pre-ww are in 4 programs: `spectral/pretty` (`ppInt`,
  `ppInteger`, `ppDouble`), `real/fem` (`LinearAlgebra.apply`, `m_mul`,
  `Matrix.mmatmat`), `real/hpg` (one local function) and `real/scs`.
- **All are at level 1.** None is deeper, and nofib has no
  function-argument split at all.
- **Before and after GHC's own optimisations barely differ** (8 vs 7).
- **Performance is unchanged:** program allocation +0.00% (geomean; no
  benchmark changes by more than 0.5%), object code +0.06%, compiler
  allocation +0.13%. Both configurations fail only on the same
  pre-existing benchmarks.

Possible reasons, not yet measured (logging a rejection reason per function
would show which matter):
- returned functions behind `newtype` constructors (parser and state
  monads), whose tails are casts;
- GHC already eta-expanding when the work before the returned lambda is
  cheap;
- the returned lambda's argument demands looking lazy, so only absent
  arguments count (§3 option 1 would fix this);
- for arguments, the parameter must be only called and only given local
  functions.

## 8. Order of work

1. Done: §2.1 with option 2 of §3, and §2.4 through the wrapper.
2. §3 option 1 (the demand analyser records the result's signature): covers
   `wwreturn002`.
3. Done: §2.2 (function arguments). Next: recursive functions that pass a
   function parameter on (`wwhoarg008`), type parameters.
(§2.3, data structures, is out of scope: see there.)

## Notes on `WORKING-THE-WORKER-WRAPPER.md`

- In the first example, the wrapper should be `f = fun x y -> f' x` (`f'`
  takes only `x`). The final result passes the live arguments:
  `((g' 1) 2) + ((g' 4) 5)`.
- The wrapper for `g` should be `case g' n of f' -> ...`, not
  `let f' = g' n`. With `let`, `g n` becomes a lambda even when `g'` diverges
  before returning (§2.1).
