# Design: Web-Based Constant Propagation

Status: implemented in `GHC/WebCore/Transform/ConstProp.hs`
(`-fcore-webs-const-prop`, dump `-ddump-webs-const-prop`).

GHC propagates a constant argument into a function only at known calls,
either by inlining or by SpecConstr/specialisation, which make copies. A web
lists every call that can reach a lambda, and every lambda that a call can
reach. So a constant that is passed at *every* call, or returned by *every*
lambda, can be used without copying, through unknown calls too.

## 1. Constant arguments

> If every call of a (non-exposed) web passes the same constant `c`, then
> substitute `c` for the parameter in every lambda of the web.

```
\^w x. e      ==>   \^w x. e[c/x]
```

`x` is then dead. Dead-parameter elimination (which runs next) deletes it from
every lambda, and the argument from every call. Partial applications are
calls too.

**What is a constant.** Each of these is in scope everywhere, and copying it
duplicates no work:

- a literal (not a string);
- a saturated constructor application to constants, with closed type
  arguments (`True`, `Nothing @Int`, `I# 3#`);
- a top-level or imported variable of closed type.

**Types.** The constant's type must equal the parameter's type in every lambda.
A polymorphic lambda `\(x :: a) -> ...` can receive `True` only at the
instance `a = Bool`, so the web is rejected ("parameter type").

**Top-level order.** A top-level constant copied into a binding that comes
before it would break Tidy, which needs dependency order. The pipeline
re-sorts the top-level bindings after the transformations (Note [Top-level
binding order] in `Transform/Common.hs`).

## 2. Constant results

> If every lambda of a web returns the same constant `c`, then a `case` on a
> call of the web can choose its alternative now.

```
case f @^w a of b { alts }   ==>   case f @^w a of b { __DEFAULT -> rhs }
```

Here `rhs` is the alternative that matches `c`, with its binders bound to the
fields of `c`.

**When a lambda returns `c`.** Every tail of its body (through `let`, `case`
alternatives, ticks, and join points in tail position) is `c`, a dead end, a
tail call of the same web, or a jump to such a join point.

**The call is kept.** It may diverge, or have effects (`trace`,
`unsafePerformIO`). Only the choice of alternative moves. This is useful in
the late pipeline (no simplifier runs afterwards to do case-of-known-
constructor) and in the early one, where the alternatives that become dead
are dropped.

Only webs with a scrutinised call are transformed.

## Laziness

- Substituting a constant for a variable bound to it changes nothing. The
  constant is a value, or a top-level variable whose evaluation is shared.
- The scrutinised call is evaluated exactly as before.

## Tests

All run with `-O -fcore-webs -fcore-webs-const-prop -fcore-webs-dead-params
-dcore-lint`. **(E)** marks an effects test.

| Test | Shape |
|---|---|
| `constprop001` | every call passes `True`; propagated, then the parameter is deleted |
| `constprop002` | every function returns `True` (or fails); the case picks `True` |
| `constprop003` **(E)** | the constant-returning function traces; each call must still trace once (fails if the call is dropped) |
| `constprop004` | rejections: different constants passed, and different constants returned |
