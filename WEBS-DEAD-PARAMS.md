# Design: Dead-Parameter Elimination over Webs

Status: design only, not implemented. It builds on the web pipeline on branch
`webs` (`GHC/WebCore/`).

## 1. The transformation

Take a web `w` that is not exposed. If every lambda in `w` ignores its
parameter, the parameter can be removed from the whole web:

| Before | After |
|---|---|
| arrow type `A -{w}-> B` | `B` |
| lambda `\^w x. e` (with `x` dead in `e`) | `e` |
| call `f @^w a` | `f` |

Every arrow, lambda and call in the web changes the same way, so the program
stays well-typed. The paper's argument applies directly: a web is exactly the
set of places that have to agree on a calling convention. Re-running Web Lint
after the rewrite checks well-typedness mechanically.

Example (all functions local):

```haskell
apply :: (Int -> Int) -> Int          -- arrow of f: web w
apply f = f 0 + f 1                   -- calls in w
k1 = \_ -> 5 ; k2 = \_ -> 7           -- lambdas in w, parameter dead
main = print (apply k1 + apply k2)
```

becomes

```haskell
apply :: Int -> Int
apply f = f + f
k1 = 5 ; k2 = 7
```

GHC's own absence analysis cannot do this. It removes absent arguments only
from functions whose calls are all known (worker/wrapper on a let-bound
function). Here `f` is an unknown function, and webs are what tell us every
producer and consumer of it.

## 2. Is laziness enough? Mostly. The exceptions

The idea is that dropping `A ->` from `A -> B` is safe because `B` is lazy: the
body, now a thunk of type `B`, is only evaluated when the old call's result
would have been. That holds for calls. It fails in four cases:

**(a) Forcing the function itself (`seq`).** Before, a value in web `w` is a
lambda, which is always in WHNF. After, it is a thunk of type `B` that can
diverge or be expensive. So `k `seq` ()` with `k = \_ -> undefined` returns
`()` before and diverges after: the program becomes *less* defined, which is
not allowed. (GHC's eta-expansion may only make programs *more* defined.)
Condition: no value of web `w` may be forced without being applied. See S4 in
§3.

**(b) Unlifted results.** If `B` is unlifted (`Int#`, `(# .. #)`, `State#`),
then `e :: B` is evaluated eagerly where it is bound, not lazily. Top-level
unlifted bindings are not even allowed. Condition: `B` must be *definitely
lifted* at every arrow of `w` (`definitelyLiftedType`). Results whose
representation is polymorphic are rejected.

**(c) Unlifted arguments with effects.** A call evaluates an unlifted argument
before the call, e.g. `f @^w (case writeMutVar# r v s of s' -> s')`.
Dropping the argument would drop the write. Lifted arguments are thunks, and
dropping them is fine. Rule: at a call `f @^w a`:
  - if `a` is lifted or `exprOkForSpeculation a`, rewrite to `f`;
  - otherwise, rewrite to `case a of _ { __DEFAULT -> f }`, which keeps the
    evaluation and drops only the value.

**(d) Sharing changes.** Before, every call re-evaluated the body; after, the
body is a thunk shared by all uses. That is semantically fine, and usually
faster, but it can retain memory: a large `B` stays alive as long as the
function value does. Nothing to prevent; I'll report it as a known trade-off
and measure it on nofib.

## 3. Which webs are eligible

A web class `w` (after renaming) is **dead** if all of the following hold:

1. **Not exposed.** Its class contains no exposed web and no `placeholderWeb`.
   This covers imported functions, data constructors, coercion axioms,
   exported binders, and arrows without webs.
2. **Every lambda ignores its parameter.** For every `WebLam w x e`, `x` is an
   Id but not a coercion variable, and `x` is not free in `e`.
   There must be at least one such lambda, otherwise there is nothing to gain.
3. **Lifted results** (§2b). For every arrow `A -{w}-> B` in the program,
   `definitelyLiftedType B`.
4. **Never forced unapplied** (§2a), checked conservatively:
   - no `Case` scrutinises an expression whose type is an arrow of `w`, and
   - `w` does not occur inside any type argument (`App e (Type t)` with
     `w ∈ typeWebs t`). Polymorphic code could force such a value
     (`seq @a`, `rnf`, `evaluate`, `seq#`, `dataToTag#`).
   Type arguments that merely mention the argument or result types (`map @A @B`)
   are fine. Only an arrow of `w` itself inside the type argument disqualifies.
5. **Coercions are simple.** Arrows of `w` occur in coercions only under
   `Refl`, `GRefl`, `FunCo`, `TyConAppCo`, `AppCo`, `SymCo`, `TransCo` and
   `SubCo`, which can all be rewritten structurally (§4). An occurrence under
   `SelCo`, `LRCo`, `KindCo`, `InstCo`'s argument, `UnivCo` or a coercion
   variable's type disqualifies `w`.
6. **Not kept alive by unfoldings or RULES.** `w` does not occur in the type of
   a local Id that is free in `mg_rules` or in the unfolding of an exported
   binder. Tidy exposes such Ids in the interface with their original calling
   convention. Annotation should make these webs exposed, which reduces this
   condition to (1).

Webs are classes, so these checks run once per class, over the renamed
program, in one traversal that collects a `UniqFM WebId Verdict`. The verdict
records the *reason* a web was rejected, for the dump and the tests.

## 4. The rewrite

Let `D` be the set of dead webs. The rewrite goes over the renamed,
web-annotated program, before erasure.

**Types** (`dropType`): `FunTy { ft_web = w, ft_res = r }` with `w ∈ D`
becomes `dropType r`; everything else is structural. Apply it to binder types
(`setIdType`), `Case` result types, `Type` arguments, and the types inside
coercions.

**Coercions** (`dropCo`): `FunCo { fco_web = w, fco_res = co_r }` with
`w ∈ D` becomes `dropCo co_r`. This is sound because the coercion's kind changes
from `(A1 -> B1) ~ (A2 -> B2)` to `B1 ~ B2`, and `co_r` proves exactly that.
`Refl t` becomes `Refl (dropType t)`; the rest is structural, which (§3.5)
guarantees is enough.

**Expressions:**
- `WebLam w x e` with `w ∈ D` becomes `e'`.
- `WebApp w f a` with `w ∈ D` becomes `f'`, or `case a' of _ -> f'` when `a`
  is unlifted and not ok-for-speculation (§2c).
- Join points: `join j x = e in ... jump j a ...` turns into
  `join j = e in ... jump j ...`. The join arity drops by one for each dropped
  parameter among the first `joinArity` lambdas, and jumps stay saturated
  because their arguments are dropped too.

**IdInfo fixes.** These matter because CorePrep and code generation rely on
them:
- **Arity:** `idArity` drops by the number of dead webs among the binder's
  first `idArity` arrows. Join arity is handled the same way.
- **Demand signature:** remove the demands at the dropped positions (from
  `splitDmdSig`), or zap the signature with `zapIdDmdSig`. Zapping is simpler
  and only loses optimisation information.
- **CPR signature:** keep it if no outer argument was dropped; otherwise zap it.
- **Unfoldings and specialisation rules:** zap them (`zapIdUnfolding`,
  `setIdSpecialisation emptyRuleInfo`) on every *local* binder whose unfolding
  mentions a changed Id. The simplest version zaps them on all local binders.
  The pass runs after optimisation, so nothing needs them, and condition (6)
  keeps the unfoldings of exported binders unchanged.
- **CBV marks** (`WorkerLikeId [CbvMark]`): these are always empty until after
  Tidy for Ids of the current module (`GHC.Types.Id.Info`). Our pass runs
  before Tidy, so there is nothing to fix. Assert that they are empty.

**Iteration.** Dropping one web can make another parameter dead:
`\^w1 x. g @^w2 x` with `w2` dead becomes `\^w1 x. g`, so `x` is now dead.
Repeat analyse-then-rewrite until no new dead webs appear. Each round shrinks
the program, so this terminates.

**Check.** After each round, run Web Lint again. It must report no errors and
no unsolved pairs. That is the type-preservation guarantee checked
mechanically, so a failure is a bug in the pass and should panic with a dump.

## 5. Where it goes

```
annotate → Web Lint + solve → rename → re-lint
         → dead-param elimination  (repeat: analyse, rewrite, Web Lint)   ← new
         → erase
```

- New module `GHC/WebCore/Transform/DeadParams.hs`:
  - `findDeadWebs :: WebSet {-exposed-} -> CoreProgram -> (WebSet, UniqFM WebId Reason)`
  - `dropDeadWebs :: WebSet -> CoreProgram -> CoreProgram`
  - helpers `dropType` and `dropCo`, built on `GHC.WebCore.Traverse`.
- `GHC/WebCore/Pipeline.hs`: call it between renaming and erasure when
  `-fcore-webs-dead-params` is on.
- Flags: `-fcore-webs-dead-params` (new `GeneralFlag`) and
  `-ddump-webs-dead-params`, which lists each class as dropped or rejected
  with the reason (`exposed`, `used parameter (x)`, `forced`,
  `unlifted result`, `in type argument`, `complex coercion`), without uniques
  so tests can check it.
- The round-trip check (Note [Web round trip]) must be skipped when the
  program has changed. Replace it with an ordinary Core Lint of the erased
  program, which `endPass` already does under `-dcore-lint`.

## 6. Tests

New tests in `testsuite/tests/webs`, each run with
`-O -fcore-webs -fcore-webs-dead-params -dcore-lint`, checking both the program
output and `-ddump-webs-dead-params`:

| Test | Shape | Expected |
|---|---|---|
| `deadparam001` | the `apply k1 k2` example | dropped; output unchanged |
| `deadparam002` | one lambda in the web uses its parameter | rejected: used parameter |
| `deadparam003` | `seq` on a function in the web | rejected: forced |
| `deadparam004` | function stored in a list passed to `id @[Int -> Int]` | rejected: in type argument |
| `deadparam005` | result type `Int#` | rejected: unlifted result |
| `deadparam006` | unlifted, effectful argument (`State#`-threaded write) | dropped, but the effect is kept via `case`; output shows the write happened |
| `deadparam007` | function passed to an imported `map` | rejected: exposed |
| `deadparam008` | two rounds: `\x -> g x` where `g`'s web is dead | both webs dropped |
| `deadparam009` | dead parameter of a join point | join arity reduced; Core Lint passes |
| `deadparam010` | `k = \_ -> undefined`, only ever applied, never forced | dropped; program still terminates |

Beyond these, run the smoke suite (about 3,000 tests) and nofib with
`-fcore-webs -fcore-webs-dead-params -dcore-lint`. Watch for Core Lint
failures, changed output, and changes in allocation or residency (§2d).

## 7. Open questions

1. **Condition 4 is conservative.** It rejects every web that flows into a
   type argument, which includes all polymorphic containers (`[a]`,
   `Maybe a`). A "may be forced" analysis that tracks `seq` and case on
   type-variable-typed values inside local polymorphic functions would
   recover these. For imported polymorphic functions it would need to be
   pessimistic, since we can't see their bodies. Worth doing once we see how
   often it bites on nofib.
2. **Space behaviour** (§2d). Should we refuse to drop when the body is not
   cheap (`exprIsCheap`)? Then the shared thunk can't hold much more than the
   lambda did, at the cost of fewer transformations.
3. **Partial deadness.** A web where only *some* lambdas ignore their
   parameter could be handled by splitting the web, as the paper's later
   transformations do. That is out of scope for this pass.
