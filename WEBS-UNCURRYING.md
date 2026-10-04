# Design: Uncurrying over Webs

Status: design only. It builds on the web pipeline and on dead-parameter
elimination (`WEBS-DEAD-PARAMS.md`, `GHC/WebCore/Transform/DeadParams.hs`).

## 1. The transformation

Uncurrying turns a curried function, which is called one argument at a time,
into a two-argument function that must be fully applied:

```
A -{w1}-> (B -{w2}-> C)     ==>     A ->* B -> C
```

Here `w1` is the web of the outer arrow and `w2` the web of the inner one.

### Encoding `->*` in Core

Core has no n-ary arrow. We encode `A ->* B -> C` as an arrow whose argument
is an unboxed tuple:

```
(# A, B #) -{w1}-> C
```

- **Saturation is enforced by the type.** A call must supply `(# a, b #)`
  all at once; there is no way to partially apply it.
- **It costs nothing at runtime.** Unarise (`GHC.Stg.Unarise`) turns a
  parameter of type `(# A, B #)` into two parameters, and a call
  `f (# a, b #)` into `f a b`. So the result is a real two-argument calling
  convention, with no allocation.
- **It is an ordinary type.** The rewrite replaces arrow nodes of web `w1`
  and nothing else, so (as for dead parameters, `WEBS-DEAD-PARAMS.md` §3)
  it commutes with type substitution, and the program stays well-typed even
  when the web flows through polymorphic code.

The alternative of keeping curried arrows and relying on arity information or
CBV marks enforces nothing: a partial application would still be well-typed,
so we could not rely on calls being saturated. We do not use it.

Chains generalise directly: if `w1, ..., wn` are nested in the same way, we get
`(# A1, ..., An #) -{w1}-> R`.

### The rewrite (for a web `w1` that qualifies, §3)

| Before | After |
|---|---|
| type `A -{w1}-> (B -{w2}-> C)` | `(# A, B #) -{w1}-> C` |
| lambdas `\^w1 a. \^w2 b. e` | `\^w1 (t :: (# A, B #)). case t of (# a, b #) -> e` |
| saturated call `(f @^w1 x) @^w2 y` | `f @^w1 (# x, y #)` |
| partial call `f @^w1 x` (not applied to a `w2` argument) | `let v = x in \^w2 b. f @^w1 (# v, b #)` |

Only the arrows of `w1` change. Arrows of `w2` that are not directly under a
`w1` arrow keep their type. A partial application still produces a
`B -{w2}-> C` function, built by eta-expansion, so `w2` may even be exposed
(e.g. partial applications passed to an imported `map`).

## 2. Laziness and sharing

Uncurrying looks harmless, but there are three ways it can change a program.

**(a) Work between the lambdas.**

```haskell
f = \a -> let t = expensive a in \b -> t + b
let g = f 5 in g 1 + g 2        -- expensive 5 is computed ONCE
```

Uncurrying moves `expensive a` under both lambdas, so the partial application
`g` would recompute it at every call. That changes complexity, not meaning,
but it can make a program asymptotically slower. **Rule:** every lambda of
`w1` must be *directly* a `w2` lambda (`\^w1 a. \^w2 b. e`, with only type
lambdas and ticks between them). Cheap work in between (`exprIsCheap`) could
be allowed later.

**(b) Forcing a partial application.**

```haskell
f = \a -> case a of { True -> \b -> b; False -> \b -> 0 }
f undefined `seq` ()        -- diverges
```

After uncurrying, `f undefined` would be the eta-expanded lambda
`\b -> f (# undefined, b #)`, which is already in WHNF, so `seq` would
terminate. The program becomes *more* defined, which a transformation must not
do. The same direct-lambda rule from (a) rules this out: if `f a` is always a
lambda, it is always in WHNF, before and after.

**(c) Duplicating the argument of a partial application.** When eta-expanding
`f @^w1 x`, the argument `x` has to be let-bound first:
`let v = x in \b. f (# v, b #)`. Writing `\b. f (# x, b #)` instead would
re-evaluate `x` at every call of the result. If `x` is unlifted and might have
an effect or diverge, evaluate it first instead:
`case x of v { __DEFAULT -> \b. f (# v, b #) }`, as dead-parameter
elimination does.

**(d) Evaluation order of unlifted arguments.** `(f x#) y#` evaluates `x#`,
then `y#`; `f (# x#, y# #)` evaluates both before the call. That only
reorders unlifted evaluations within one call, which GHC's imprecise-exceptions
semantics already allows. Nothing to do.

The function values themselves are unaffected: before and after, values of
`w1` are lambdas, so `seq` on `f` behaves the same.

## 3. Which webs qualify

A web `w1` can be uncurried when:

1. **`w1` is not exposed.** `w2` may be exposed (§1).
2. **Every arrow of `w1` has an arrow as its result, syntactically** (after
   expanding synonyms). If some occurrence is `A -{w1}-> r`, where the
   result is hidden behind a type variable (e.g. `apply :: (a -> r) -> a -> r`
   instantiated with `r := B -> C`), the rewrite would no longer commute with
   substitution, and the program would become ill-typed. Reject. All the
   inner arrows are then in one class `w2`, because Web Lint unified them.
3. **Every lambda of `w1` is directly a lambda of `w2`** (§2a, b).
4. **The components have a fixed representation.** `A` and `B` must satisfy
   `typeHasFixedRuntimeRep`; an unboxed tuple can't have
   representation-polymorphic components.
5. **Coercions are structural.** An arrow of `w1` may appear in a coercion only
   as `FunCo w1 co_a (FunCo w2 co_b co_c)` or under `Refl`. The first becomes
   `FunCo w1 (TyConAppCo (#,#) [.., co_a, co_b]) co_c`. Anything else
   (`SelCo`, `LRCo`, …) rejects the web, as for dead parameters.

There are no lifted-result or "forced" conditions: every value of `w1` stays a
lambda.

## 4. IdInfo

- **Arity:** a binder whose type has `w1` arrows among its first `idArity`
  arrows has its arity reduced by one for each, since two arguments become one
  unboxed-tuple argument. Join arity is handled the same way. Unarise later
  turns the tuple back into two arguments at the STG level.
- **Demand and CPR signatures:** zap them, or merge the two argument demands
  into a product demand on the tuple.
- **Unfoldings and rules:** as for dead parameters. Zap them on local binders
  outside `ws_interface_ids`; the types of the interface binders are exposed,
  so they never change.

## 5. Where it goes

`GHC/WebCore/Transform/Uncurry.hs`, with `-fcore-webs-uncurry` and a
`-ddump-webs-uncurry` dump in the same style as dead parameters (verdict and
reason per web, no uniques). It runs after dead-parameter elimination. Like
dead parameters, it repeats until nothing changes, with Web Lint after each
round, so that chains of three or more lambdas are uncurried one web at a time
into nested unboxed tuples, which Unarise flattens.

## 6. Tests

Each test checks the program's output and the verdict dump, with
`-O -fcore-webs -fcore-webs-uncurry -dcore-lint`. All functions are local and
`NOINLINE`, so GHC's own optimiser does not do the work first. Tests marked
**(L)** fail if laziness or sharing is handled incorrectly. They use
`Debug.Trace` (or an `IORef` counter via `unsafePerformIO`) to make the number
of evaluations visible in the output.

| Test | Shape | Expected |
|---|---|---|
| `uncurry001` | `apply2 f = f 1 2 + f 3 4` with local `\a b -> ..` functions | uncurried; output unchanged; Web Lint passes |
| `uncurry002` | a 3-argument chain | all uncurried, over two rounds |
| `uncurry003` **(L)** | partial application shared: `let g = f (trace "arg" 5) in g 1 + g 2` | uncurried; `arg` is printed **once** (the eta-expansion must let-bind the argument) |
| `uncurry004` **(L)** | work between the lambdas: `f a = let t = trace "work" (a*2) in \b -> t + b`; `let g = f 5 in g 1 + g 2` | **rejected** (not a direct lambda); `work` is printed **once** |
| `uncurry005` **(L)** | `f a = case a of {..} -> \b -> ..`; `f undefined `seq` ()` inside `try` | **rejected**; the exception is still thrown |
| `uncurry006` | partial applications passed to an imported `map` (`w2` exposed) | uncurried; the partial application is eta-expanded |
| `uncurry007` | result behind a type variable: `apply :: (a -> r) -> a -> r` with `r := Int -> Int` | rejected (result hidden by a type variable); Web Lint passes |
| `uncurry008` | function stored in a local list, used polymorphically | uncurried; Web Lint passes (commutes with substitution) |
| `uncurry009` **(L)** | unlifted partial-application argument that throws, partial application never called | the exception is still thrown (the argument is evaluated with a `case`, not dropped or duplicated) |
| `uncurry010` | join point with two parameters, jumped to saturated | uncurried; join arity reduced; Core Lint passes |

Beyond these, run the smoke suite and nofib with `-fcore-webs-uncurry`. On
nofib, also measure allocation: partial-application closures and PAPs should
go down, and unknown calls should become saturated known-arity calls.
