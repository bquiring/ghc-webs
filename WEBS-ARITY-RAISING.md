# Design: Arity Raising over Webs

Status: **implemented** in `GHC/WebCore/Transform/ArityRaise.hs`, behind
`-fcore-webs-arity-raise` (dump: `-ddump-webs-arity-raise`). Tests are
`testsuite/tests/webs/arityraise*`. Where the implementation differs from the
design below:

- "Product" includes `Int`, `Char`, `Double` and so on (single-constructor
  types such as `I# Int#`). A web of lambdas strict in an `Int` is raised to
  take `(# Int# #)`: worker/wrapper unboxing, but for unknown functions.
  Class dictionaries and newtypes are excluded.
- A case binder of `case p of b { K ys -> rhs }` is bound to `p` only if it
  is used, so that `p` is re-boxed only when needed.
- A function passed to a polymorphic function whose own arrow is in the web
  (`app :: (a -> b) -> a -> b`) is rejected (argument not a product). One
  passed only as a value (`opaque :: a -> Int`) is raised, with the type
  argument rewritten. See `arityraise008`. Raising the first case would need
  `app` to be specialised to the product type first.
- The laziness tests (002, 003, 004) were checked against a version of the
  pass that ignores strictness; all three then crash.

## 1. The transformation

Arity raising turns a function that takes a product into a function that
takes the product's components, fully applied:

```
(A, B) -{w}-> C          ==>     A ->* B -> C
```

As in `WEBS-UNCURRYING.md` §1, `A ->* B -> C` is encoded in Core as an arrow
with an unboxed-tuple argument, `(# A, B #) -{w}-> C`. The type enforces
saturation, Unarise turns it into a real two-argument calling convention, and
the rewrite commutes with type substitution.

"Product" means any single-constructor data type without existentials or
equality constraints: boxed tuples, records, and `data P = P !Int Int`
(`splitDataProductType_maybe`). The components are the constructor's
*representation* argument types (`dataConRepArgTys`), so strict, unpacked
fields arrive already evaluated (an unpacked `!Int` is an `Int#`).

GHC's own worker/wrapper already does this for *known* functions that are
strict in a product argument. Webs extend it to *unknown* functions: a
higher-order function's argument, and every function that flows into it.

### The rewrite (for a web `w` that qualifies, §3)

| Before | After |
|---|---|
| type `(A, B) -{w}-> C` | `(# A, B #) -{w}-> C` |
| lambda `\^w p. e` | `\^w (t :: (# A, B #)). case t of (# a, b #) -> e[ (a, b) / p ]` |
| call `f @^w x` | `case x of (a, b) -> f @^w (# a, b #)` |
| call `f @^w (MkP x y)` (a constructor application) | `f @^w (# x, y #)` |

**Lambda side.** If `p` occurs only as a case scrutinee,
`case p of (x, y) -> body`, substitute `x := a` and `y := b`: no allocation at
all. Any other occurrence of `p` needs the box back: `let p = (a, b) in e`.
That costs one allocation in the callee in exchange for the one the caller no
longer makes, so it is never worse. This pass runs after the simplifier, so it
must do this small case-of-known-constructor cleanup itself.

**Call side.** The argument now has to be *evaluated at the call*, to take it
apart. That is the main laziness issue (§2).

## 2. Laziness

**(a) The caller now forces the argument.**

```haskell
lazyF :: (Int, Int) -> Int
lazyF _ = 0
use f = f undefined          -- with f := lazyF: returns 0
```

Raising the arity turns the call into `case undefined of (a, b) -> f (# a, b #)`,
which diverges. That makes the program *less* defined, so it is not allowed.
**Rule:** every lambda of `w` must be **strict** in its product argument, i.e.
it always evaluates `p`. Then forcing `p` at the call only moves the
evaluation earlier: if `p` diverges, the call diverged anyway. That change of
order is allowed under imprecise exceptions. We read strictness from each
lambda binder's demand (`idDemandInfo`, `isStrUsedDmd`), which the final
demand analysis computes just before our pass runs. If an earlier web
transformation in the same pipeline run has changed the program, re-run
demand analysis first, or treat the demands as unknown and reject.

**(b) Strict, but only on some paths.** A lambda that forces `p` only on some
branches (`\p -> if c then fst p else 0`) is *not* strict: the demand is lazy,
so the rule rejects it. Likewise an irrefutable pattern (`\ ~(a, b) -> ..`)
compiles to selector thunks, which is a lazy demand, so it is rejected.

**(c) Taking components lazily instead.** One alternative is to keep calls
lazy by passing selector thunks: `f (# fst x, snd x #)`. It is *not* sound
for strict lambdas either. The lambda's `case p of (a, b)` used to force the
argument, but after rewriting it matches an unboxed tuple, which forces
nothing, so `f undefined` would terminate where it used to diverge. So we
don't do that: strictness of every lambda is required, and the call evaluates
the argument.

**(d) Strict fields.** With `data P = P !Int !Int`, taking `x` apart gives
already-evaluated (or unboxed) fields, and re-boxing with `MkP`'s worker
keeps the invariant. No new evaluation happens.

**(e) Sharing.** If the caller's argument `x` is a variable used elsewhere, the
caller does `case x of (a, b) -> ..`, which evaluates the shared thunk
in place, exactly as the callee would have. Nothing is duplicated. A
constructor application `MkP e1 e2` passes `e1` and `e2` as they are
(thunks if lifted), so nothing is evaluated early.

The function values stay lambdas, so `seq` on them is unaffected.

## 3. Which webs qualify

A web `w` can be raised when:

1. **`w` is not exposed.**
2. **Every arrow of `w` has a product argument, syntactically**, with the same
   type constructor at every occurrence after expanding synonyms. If the
   argument is a type variable at some occurrence (e.g.
   `apply :: (a -> r) -> a -> r` instantiated with `a := (Int, Int)`), the
   rewrite would not commute with substitution. Reject.
3. **The product type is a single-constructor data type** with no
   existentials or constraints, and the components have a fixed
   representation.
4. **Every lambda of `w` is strict in its parameter** (§2a, b).
5. **Coercions are structural**: `FunCo w co_arg co_res` where `co_arg` is
   `Refl` or a `TyConAppCo` of the product type constructor. Rewrite it to
   the corresponding `TyConAppCo` of `(#,#)`. Newtype axioms over the product
   type reject the web.

## 4. IdInfo

- **Arity:** unchanged at the Core level. One argument becomes one
  unboxed-tuple argument, which Unarise turns into two at the STG level.
- **Demand signature:** the argument demand stays strict. Zap the signature,
  or replace the product demand with the components' demands.
- **Unfoldings and rules:** as for dead parameters.

## 5. Where it goes

`GHC/WebCore/Transform/ArityRaise.hs`, with `-fcore-webs-arity-raise` and a
`-ddump-webs-arity-raise` dump (verdict and reason per web, no uniques). It
runs before dead-parameter elimination, so a component that turns out to be
unused can then be removed by it. Web Lint runs after it.

## 6. Tests

Each test checks the program's output and the verdict dump, with
`-O -fcore-webs -fcore-webs-arity-raise -dcore-lint`. Functions are local and
`NOINLINE`, and are passed to a local higher-order function, so that GHC's own
worker/wrapper cannot do the work first. Tests marked **(L)** fail if laziness
is handled incorrectly.

| Test | Shape | Expected |
|---|---|---|
| `arityraise001` | `useP f = f (1,2) + f (3,4)` with lambdas `\p -> case p of (a,b) -> a+b` | raised; output unchanged; allocation lower (a `stats` test on bytes allocated) |
| `arityraise002` **(L)** | the web contains `lazyF _ = 0`, and `useP` calls `f undefined` | **rejected** (lazy lambda); prints 0. If the caller forced the argument, it would throw |
| `arityraise003` **(L)** | the web contains `\p -> if c then fst p else 0`, with `c = False` and argument `undefined` | **rejected** (lazy on some path); prints 0 |
| `arityraise004` **(L)** | irrefutable pattern `\ ~(a, b) -> 1` with argument `undefined` | **rejected**; prints 1 |
| `arityraise005` **(L)** | strict lambdas; the argument is `trace "arg" (3, 4)`, a variable used twice by the caller | raised; `arg` printed **once** (the shared thunk is not duplicated) |
| `arityraise006` **(L)** | strict lambdas; argument `(trace "x" 1, 2)` whose first component is never used | raised; `x` is **never** printed (components stay lazy thunks) |
| `arityraise007` | the product parameter used both in a `case` and as a whole (`\p -> case p of (a,_) -> a + g p`) | raised; the callee re-boxes; output unchanged |
| `arityraise008` | argument behind a type variable (`apply :: (a -> r) -> a -> r`) | rejected; Web Lint passes |
| `arityraise009` | record with strict and unpacked fields (`data P = P !Int Int`) | raised; components are `Int#` and `Int`; Core Lint passes |
| `arityraise010` | function flows into an imported higher-order function | rejected (exposed) |
| `arityraise011` **(L)** | strict lambdas, argument `undefined`, call inside `try` | raised; the exception is still thrown (diverging argument diverges at the call instead of inside the callee) |

Beyond these, run the smoke suite and nofib with `-fcore-webs-arity-raise`.
Measure allocation and residency: boxed tuples passed to unknown functions
should disappear.
