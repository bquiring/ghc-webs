# Design: Web-Based (Super-Beta) Inlining

Status: implemented in `GHC/WebCore/Transform/Inline.hs`
(`-fcore-webs-inline`, dump `-ddump-webs-inline`).

GHC's inliner works at *known* calls: the head of the call must be a variable
with an unfolding. A call of an unknown function (a parameter, a field, the
result of another call) is never inlined. A web lists all the lambdas that
can reach a call. If there is exactly one, then that lambda is the function
at every call of the web, known or not. This is Shivers' *super-beta*
inlining.

## The transformation

If the only lambda of a (non-exposed) web `w` is `L = \^w x. \^w2 y. body`,
then at a call of `w`:

```
f @^w a @^w2 b    ==>   case f of _ { __DEFAULT -> let x = a; y = b in body' }
```

Here `body'` is a copy of `body` with fresh binders. L's lambdas are matched
with the call's arguments as far as both go. Any further arguments are
applied to the result.

## Conditions

- **Environment.** L's free variables must have the same values at the call as
  where L was built. We require them to be top-level (or imported), and L to
  have no free type variables. A lambda that captures a local variable may be
  called where another activation's binding of that variable is in scope
  (the classic super-beta environment problem; test `inline003`).
- **Types.** At the call, the function's type must equal L's type. With no
  free type variables, L cannot be instantiated. A polymorphic function that
  passes L on calls it at a type variable, so that call is left alone
  (`inline004`).
- **Size.** L passes GHC's own inlining test: `calcUnfoldingGuidance` gives
  `UnfWhen` (always inline), or a size of at most `-funfolding-use-threshold`.
- **Pragmas.** L is not the right-hand side of a binder with a `NOINLINE` or
  `OPAQUE` pragma, nor of a loop breaker (`inline006`).
- **Unknown calls only.** A call whose function is a variable bound to a known
  function (arity > 0), or a jump, is left to GHC's inliner. The inliner can
  see those calls, and has already decided not to inline them.
- **Not bottoming.** GHC does not inline bottoming functions either.
- **No unrolling.** Calls inside L itself are not inlined. Each web is inlined
  in one round only.
- **Top-level order.** A copy of L can mention top-level binders in an
  earlier binding. The pipeline re-sorts the top-level bindings afterwards
  (`inline005`; Note [Top-level binding order]).

## Laziness

- **The function is still evaluated**, unless it is evidently a value. So a
  call of a bottom function still diverges. GHC itself would accept the more
  defined program (`-fno-pedantic-bottoms`), but we stay exact. It costs a
  pointer-tag test.
- **Arguments are let-bound,** so they stay lazy and are computed at most once
  (`inline002`, `inline004`).
- **Demands.** A lambda binder's demand describes saturated calls. So the
  let binders keep L's demands only when every lambda of L is applied.
  Otherwise their demands are zapped, so that CorePrep does not evaluate them
  early.

## Tests

All run with `-O -fcore-webs -fcore-webs-inline -dcore-lint`. **(L)** marks a
laziness or sharing test.

| Test | Shape |
|---|---|
| `inline001` | one function reaches the unknown calls; inlined |
| `inline002` **(L)** | the inlined function ignores a diverging argument |
| `inline003` | the only lambda captures a local variable; rejected |
| `inline004` **(L)** | argument used twice and traced (once per call); a polymorphic caller is not inlined |
| `inline005` | the inlined lambda mentions top-level bindings that come after the call |
| `inline006` | `NOINLINE` is respected |
