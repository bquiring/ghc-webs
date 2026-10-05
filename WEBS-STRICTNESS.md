# Design: Web-Based Strictness

Status: implemented in `GHC/WebCore/Transform/Strictness.hs`
(`-fcore-webs-strictness`, dump `-ddump-webs-strictness`).

GHC's strictness machinery (demand analysis followed by worker/wrapper and
CorePrep) only exploits strictness at **known** calls. A function's demand
signature is attached to its *name*, so a call through an unknown function
(e.g. `f x` where `f` is a parameter) is always treated lazily. A web
collects *all* the definitions (lambdas) and *all* the call sites of a set of
function values. So we can compute a strictness fact for the whole web, and
use it at every call site, known or not.

There are two dual transformations.

## 1. Strict arguments: evaluate at the call

> If every definition (lambda) of a web is strict in its argument, then
> evaluate the argument at every call.

```
f @^w a      ==>      case a of a' { __DEFAULT -> f @^w a' }
```

**Why it helps.** A lazy argument is allocated as a thunk at the call and
evaluated (entered) in the callee. Evaluating it at the call avoids the thunk
allocation whenever the argument is not already a value. And if the caller
has just evaluated it (e.g. it was scrutinised), the evaluation is free. GHC
does this for known calls (CorePrep's `cpeArg` uses the callee's demand
signature). This extends it to unknown calls. It is the "option C" that
Note [WW for calling convention] in `GHC/Core/Opt/WorkWrap/Utils.hs`
describes as needing all call sites to be known, which a web provides.

**Soundness.** Every function value that can reach the call is a lambda of
the web (non-exposed web). Each would evaluate `a` before producing any
result, so evaluating `a` first can only change *which* divergence or
exception happens, which GHC's imprecise-exception semantics allows. Two
details:

- **Partial applications.** A lambda's demand on its parameter describes
  full applications. For `\x y -> e`, `x` is strict when two arguments are
  supplied, but `f undefined` is a partial application that never forces
  `x`. So each lambda records its **saturation depth** `k`: the number of
  value lambdas starting at its own. For the web, `k` is the maximum over its
  lambdas. A call evaluates the argument only if the call supplies at least
  `k` arguments, starting with this one. (This replaces arity raising's
  coarser "reject curried lambdas" rule.)
- **Values of the web's type that are not lambdas.** These are `⊥` (e.g.
  `undefined @(A -> B)`) or come from exposed code. An exposed web is never
  transformed, and calling `⊥` diverges anyway (order of divergence again).

**Where strictness comes from.**
- Late run: the demand info of the lambda binders (`idDemandInfo`, from the
  final demand analysis).
- Early run (no demand analysis yet): syntactic. The body, after the
  remaining lambdas, scrutinises the parameter first (`isStrictIn`, as in
  arity raising).

**The rewrite** wraps the `case` around the whole application spine, so jumps
stay in tail position, as in arity raising. Arguments that are unlifted, or
already values (`exprIsHNF`), are left alone.

## 2. Strict results: evaluate in the definition

> If, at every call of a web, the caller evaluates part of the returned value,
> then evaluate that part in the definition.

A call's result is always in WHNF when it returns, because evaluating the call
evaluates the body. So "evaluate the result in the definition" applies one
level down, to the **fields** of a returned product. If every call site
immediately uses field *i* of the returned constructor, the definition can
compute field *i* eagerly instead of allocating a thunk for it:

```
definition:   \^w x. ... K e1 e2 ...        ==>   \^w x. ... case e1 of v1 -> K v1 e2 ...
call sites:   case f @^w a of K y1 y2 -> ... y1 used strictly ...
```

**Why it helps.** The definition no longer allocates a thunk for `e1`, and
the caller no longer evaluates (enters) `y1`. Combined with result raising
(CPR, `WEBS-WW-SURVEY.md` §3), the fields come back in registers and already
evaluated.

**Soundness.** The fields are evaluated only when the call's result is
evaluated, i.e. when the definition's body runs. By assumption every call
site then forces field *i* as well, so the only difference is the order of
evaluation (imprecise exceptions again). A call in a lazy position
(`let r = f a in ...`) is fine too: the body runs only when `r` is forced, and
then the strictness condition applies to `r`'s use.

**Call-site analysis.** For each web `w` whose result type is a product `T`,
we combine the call sites:
- `case <call of w> of b { K y1 .. yn -> rhs }` with `K` the constructor of
  `T`: field *i* is strict here if `y_i` is strict in `rhs` (its demand info in
  the late run, or `isStrictIn` in the early run);
- any other occurrence of a call of `w` (a lazy `let`, an argument, a tail
  call, `case` with a `DEFAULT` alternative): unknown, so no field is
  strict.

The web's strict fields are the intersection over all its call sites. The
web of a call is the web of the *outermost* application of the spine: the
arrow whose result is `T`.

**Definition side.** In each lambda of the web, walk the tail positions of
the body (through `let`, `case` alternatives, and ticks). At a saturated
application of `K` (the product's worker), wrap each strict, lifted, non-value
field argument in a `case`. Other tails (a variable, a call) are left alone,
which is always safe.

## 3. Eligibility (both parts)

A web is considered only if it is **not exposed** (as for every web
transformation). Nothing changes types, so there are no typing conditions,
and every transformed program is still checked by Web Lint.

- **Part 1:** every lambda of the web is strict in its parameter, at some
  saturation depth. Lambdas binding coercion variables are excluded.
- **Part 2:** the result type is a product (single-constructor, no
  existentials; `productCon` in arity raising), at every arrow of the web.
  There is at least one call site, and every call site is a `case` with that
  constructor's alternative.

## 4. Tests

Each runs with `-O -fcore-webs -fcore-webs-strictness -dcore-lint`, and
checks the output and a verdict dump (`-ddump-webs-strictness`). **(L)**
marks a laziness test.

| Test | Shape | Expected |
|---|---|---|
| `strict001` | local higher-order function applying strict functions to a lazily built argument | argument evaluated at the call |
| `strict002` **(L)** | one function in the web ignores its argument; the argument is `undefined` | not evaluated; prints the result |
| `strict003` **(L)** | curried strict function, partial application forced with `seq` | the partial application is *not* evaluated early (saturation depth); terminates |
| `strict004` **(L)** | argument traced with `Debug.Trace` | traced once (no duplication) |
| `strict005` | functions returning pairs whose first field every caller forces | field evaluated in the definition |
| `strict006` **(L)** | one call site ignores the field, which is `undefined` | field not evaluated; prints the result |
| `strict007` **(L)** | call in a lazy `let` that is never forced, whose field would throw | no exception |
| `strict008` | exposed web (function passed to `map`) | rejected |

## 5. Expected interaction with the inliner (the hypothesis)

In the early run, part 1 hands the simplifier calls whose arguments are
already evaluated, and part 2 hands it definitions whose fields are already
evaluated. Worker/wrapper's strictness-driven unboxing then finds less to do,
and the inliner has fewer wrappers to inline. Measured with the same
experiment as `WEBS-EXPERIMENTS.md`.
