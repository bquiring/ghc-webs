# Web Bugs

Every bug found in the web transformations, with its cause and fix:
correctness bugs (crashes, Lint errors, panics, miscompilations, a compiler
that loops) and performance bugs (a transformation or heuristic that makes a
benchmark worse). Newest first in each section. Background in the Notes
named, measurements in `WEBS-EXPERIMENTS.md` and `WEBS-DATA.md`.

Entry fields: **found by** (test, benchmark, configuration), **symptom**,
**cause**, **fix** (with its Note), **guard** (the test or benchmark that
would catch it again), **commit** (empty while uncommitted).

## Open

* **rewrite also fails under `early-cur`** (2026-10-09, nofib binaries
  built before the fix below): fixed; rewrite builds and runs right in the
  hf-on/hf-off/types nofib runs (2026-10-09).
* **k-nucleotide "segfault": not ours** (2026-10-09). `base` segfaults
  the same way: the timing runner (time-nofib.py, norm mode) gives it an
  empty stdin, because nofib's boot made only `k-nucleotide.faststdin`, and
  it indexes the input unsafely. With real input (fasta 600000) base and
  the defunctionalisation build agree with the expected output. So every
  k-nucleotide timing so far is invalid; time-nofib needs the norm input
  (to fix in webs-bench, between runs).
* **cryptarithm2 loses 3% to strict elimination** (`WEBS-EXPERIMENTS.md`
  §10): the unboxing cascade runs out of rounds (outer-first rule, three
  rounds). Not a bug as such; fixpoint rounds to try.

## Correctness

### Hidden fields: the definition is a use too (2026-10-09)
* **Found by:** the user's question (polymorphism), then a test
  (`hfield004`: `data P a = P Int (a -> Int)`, used only at `(Int, Int)`).
* **Symptom:** Web Lint after arity raising, argument type mismatch.
* **Cause:** the transformations decide from the program's types, and the
  constructor signatures are not in the program. Every use took a pair, so
  the field's web was raised, but the definition's field takes one
  polymorphic parameter and its signature could not follow.
* **Fix:** while the transformations run, each hidden-field signature is a
  top-level binding in the program (Note [Signatures in the program]): the
  analyses see the definition, the rewrites reach it.
* **Guard:** `hfield004`.
* **Commit:** `7779168632`

### Hidden fields: unsafeCoerce reads the old layout (2026-10-09)
* **Found by:** checking which uses of a data type the hidden-field rule
  misses (a hand-written test, now `hfield003`).
* **Symptom:** wrong output, `(1099511628032,1099511628032)` for `(15,60)`.
* **Cause:** Lint does not relate the two sides of an unsafe coercion. `H`'s
  field web was raised (the field became curried) and `H` was rebuilt, but
  `unsafeCoerce` turned an `H` into an `H'` whose field still takes a pair.
* **Fix:** a type in the type arguments of `unsafeCoerce`/
  `unsafeEqualityProof`, or in a `UnivCo`, keeps its fields exposed, as do
  the types reachable through its fields (Note [Hidden fields]), as data
  splitting does for its copies (Note [Non-parametric functions]).
* **Guard:** `hfield003`.
* **Commit:** `7779168632`

### Hidden fields: three problems found while adding them (2026-10-09)
* **Found by:** `recweb001`, `hfield001`, the `dsedge` tests in the
  `lateall` mode, while making the webs inside hidden fields internal.
* **Symptoms and fixes:**
  * Web Lint, binder and right-hand side disagree on `w` (`recweb001`):
    raising a web stored in a field of the type it takes needs an infinite
    type. The occurs check rejects it (Note [Recursive products]); the
    real fix is a newtype for that web (WEBS-BACKLOG.md).
  * Web Lint, argument type mismatch (non-recursive field): constructor
    signatures were fixed for the whole pipeline. Each round now returns
    its type rewrite, applied to the signatures, and the type is rebuilt
    after erasure.
  * A record type's field webs stayed exposed: GHC marks every record
    selector as exported, so its type was kept fixed. Selectors of types
    with hidden fields are no longer kept.
  * "Call without a web against a web-annotated arrow" (`lateall`): result
    raising rebuilds products with the raw constructor worker, and the
    worker refresh gave it the annotated signature. Raw occurrences now get
    the signature's shape without webs.
* **Guard:** `recweb001`-`005`, `hfield001`-`002`, the `dsedge` tests.
* **Commit:** `7779168632`

### Rebuilt recursive type: flattened components keep the old type (2026-10-09)
* **Found by:** new test `dsedge023` (`R = R (Int, R)`), every unboxing mode.
* **Symptom:** Web Lint, "Application error": `depth`'s recursive call
  passed `R_s9{w2Au}` (the split copy) where `R_s9{w2AV}` (the rebuilt type)
  was expected; both print as `R_s9`.
* **Cause:** when a pair field is flattened, the binders for its components
  were typed from the pair's constructor instantiated at the field's *old*
  type arguments. For a type recursive through the pair, those mention the
  old type. The new constructor's own fields were rewritten (`ty (self t)`
  in `rebuild`), but the binders made in matches (`field`) and in
  constructions (`build`) were not.
* **Fix:** `inst_args` in `GHC.WebCore.DataFlatten` rewrites the
  instantiated type arguments with `ty` in both places.
* **Guard:** `dsedge023` (8 modes).
* **Commit:** `6caf54fe93`

### Demand rewriting unfolds recursive types: compiler runs out of memory (2026-10-09)
* **Found by:** the webs testsuite after the fix below; `dsedge011`, all
  unboxing modes. Twenty threads of compiles ran out of RAM and swap and
  froze the machine (see "Running tests" below).
* **Symptom:** GHC allocates without bound compiling the module.
* **Cause:** the new demand rewriting (Note [Demands after flattening])
  expanded a polymorphic subdemand (`L`, `1L`) into one demand per field
  with `viewProd`, then recursed into each field's type with it. On a
  recursive single-constructor type that never ends. `dsedge011` has no
  such type in its source, but `nats` never builds `[]`, so the splitter
  drops it and the list's copy has one constructor.
* **Fix:** recurse only into an explicit `Prod`; a `Poly` demand fits any
  fields and is kept.
* **Guard:** `dsedge022` (lists built only with `(:)`), `dsedge023`
  (single-constructor streams, recursion through a pair), `dsedge025` (dead
  fields in recursive types). Without the fix these 3 fail with "ghc: out of
  memory" in 20 of their 24 unboxing modes (checked by reverting it).
* **Commit:** `6caf54fe93`

### Stale demands after dropping and flattening fields: "Entered absent arg" (2026-10-09)
* **Found by:** nofib `spectral/rewrite` under `early-du10` (dead fields):
  fails on every run (30 of 30), never under `base`.
* **Symptom:** `internal error: Oops! Entered absent arg Arg: ww`.
* **Cause:** demand analysis runs before the splitter, so a product demand
  `P(d1, .., dn)` describes the old constructor's fields. `Eqn`'s dead
  number field was dropped in one round and its pair of expressions
  flattened in the next, so `Eqn` had two fields again. The stale demand
  matched in length and gave the first expression the dropped field's
  absent demand, and worker/wrapper passed it as absent.
* **Fix:** every binder whose type mentions a type whose fields change gets
  its demand signature and demand rewritten with the fields (kept: same
  demand; dropped: removed; flattened: its components' demands), and its
  CPR signature zapped (Note [Demands after flattening]). Dictionary
  arguments count as value arguments.
* **Guard:** `dataunbox008`, `dsedge025`.
* **Commit:** `6caf54fe93`

### CBV marks: a coercion taken for an unboxed tuple (2026-10-09)
* **Found by:** compiling base with an unfrozen stage 1.
* **Symptom:** panic in `kindPrimRep` in CoreTidy on
  `GHC.Internal.Data.Type.Equality`.
* **Cause:** `isUnboxedTupleType` looks only at the representation, and
  `a ~# b` has `TupleRep []`.
* **Fix:** only an unboxed tuple type constructor counts (Note [CBV marks
  for unboxed tuple arguments]).
* **Commit:** `56d79f119d`

### Copies lose field strictness (2026-10-08)
* **Found by:** x2n1 +1.0% instructions; then a semantic check.
* **Cause:** rebuilt constructors dropped bangs: a split `Data.Complex` was
  lazier than `Complex`, a semantic change.
* **Fix:** every rebuild keeps each field's bangs and strictness mark (Note
  [Copies keep strictness]).
* **Guard:** `dsedge019`-`021`.
* **Commit:** `b5e702d67d`

### unsafeCoerce and UnivCo split related types apart: segfault (2026-10-08)
* **Found by:** `dsedge010`.
* **Cause:** a `UnivCo`, and `unsafeCoerce`'s type arguments, relate two
  types that Lint does not see as related, so their copies were split
  apart and unboxed differently.
* **Fix:** both keep the original types (Note [Non-parametric functions]).
* **Guard:** `dsedge010`.
* **Commit:** `83f93e5697`

### Newtype splitting: class members and eta-reduced axioms (2026-10-08)
* **Found by:** nofib with newtype splitting: 91 modules failed Web Lint (a
  `TransCo` mismatch, `ReadP` inside `ReadPrec`); `spectral/lambda`
  (`N:Id`).
* **Cause:** a class's members came from Data Lint's pairs only, missing
  the originals that congruence brings in; a copy's axiom was not
  eta-reduced like the original's (Note [Newtype eta]).
* **Fix:** members include congruence's originals; copied axioms are
  eta-reduced like the original.
* **Commit:** `26afb1ee2d`, `f7058ed8df`

### Rebuilt types: constructors still mention the old types (2026-10-08)
* **Found by:** six nofib benchmarks failed Web Lint.
* **Cause:** specialisation and flattening rebuilt a split type but not the
  split types whose fields mention it.
* **Fix:** rebuild every split type whose fields mention a rebuilt type.
  (The 2026-10-09 entry above is the same mistake in the match binders.)
* **Commit:** `f70212b4b7`

### Polymorphic defunctionalisation: Lint errors and panics on six benchmarks (2026-10-08)
* **Found by:** nofib CS, dom-lt, transform, veritas, circsim, solid with
  `-dcore-lint`.
* **Cause:** a lambda's existentials missed the type variables of its free
  variables' types; SpecIndex indexed coercions by the new type's
  parameters into the old (a `!!` panic), did not substitute eliminated
  existentials into field binders, and did not rebuild types whose fields
  mention a specialised type; an absent demand lost its form.
* **Fix:** all four.
* **Guard:** `defunc007`, `defunc008`; every defunc test also with lifted
  bodies.
* **Commit:** `551b9df701`

### Stale usage demands: miscompilation under -fpedantic-bottoms (2026-10-05)
* **Found by:** testsuite T24295b; `webs008`.
* **Cause:** usage demands and call arities of transformed binders were
  kept, so the simplifier eta-expanded an uncurried function.
* **Fix:** reshape usage demands and call arities like demand signatures
  (Note [Usage information after a transformation]).
* **Commit:** `d75e6520da`

### Testsuite with the transformations on (2026-10-04)
* **Found by:** running GHC's testsuite with the transformations on.
* **Fixes:** uncurrying: unboxed-tuple components must not be constraints;
  push the unpacking case below further lambdas (join points); do not
  uncurry a join point's last lambda. Arity raising: wrap the case that
  takes an argument apart around the whole application spine (jumps stay in
  tail position); reject curried lambdas, whose argument demands describe
  full applications only. Kept Ids: include binders with rules at any
  level, follow free variables of rules and stable unfoldings, consult
  every binder that shares a Unique. No early uncurrying: before demand
  analysis it loses call-by-value for strict arguments (T10830 overflows its
  stack; Note [No early uncurrying]).
* **Commit:** `2118fa15b4`

## Performance (heuristics and regressions)

### Unarise loses component types: uncurrying parked, arity raising curried (2026-10-09)
* **Found by:** late run without the uncurrying gate: nucleic2 +15.1%,
  wheel-sieve1 +16.6%, sched, boyer, queens +11-12%.
* **Cause:** an unboxed-tuple argument's components get binders typed by
  representation only (`Any`), so the code generator cannot tell a `Float`
  is not a function: `case us of F# y` became a slow call through
  `stg_ap_0_fast` (15% of nucleic2's instructions).
* **Fix:** uncurrying parked; arity raising passes components curried
  (Note [Raised arguments are curried]). nucleic2 +11.2% → −0.28%.
* **Commit:** `da5f4f2847`

### SpecConstr wild-cards coercion arguments: defunctionalisation gains nothing (2026-10-09)
* **Found by:** constraints, whole-arity defunctionalisation unchanged.
* **Cause:** the constructors' reflexive equalities made each call pattern
  quantify over coercion variables, which SpecConstr discards (Note
  [SpecConstr and casts]); base GHC specialises `foldTree` three times.
* **Fix:** Note [SpecConstr and reflexive coercions]. constraints +1.4% →
  −0.02%, solid −18.8%.
* **Commit:** `5c9eac86b8`

### Uncurrying known calls: late run's big regressions (2026-10-08)
* **Found by:** `late-fix`: +2.68% geomean, 57 worse; binary-trees +34%,
  fft2 +30%.
* **Cause:** the late run uncurried worker/wrapper's workers, whose calls
  are known (GHC already makes those direct). The uncurried workers also
  lost their call-by-value marks: every match paid an evaluatedness check.
* **Fix:** leave webs with only known calls to GHC (Note [Uncurrying known
  calls]); CBV marks for unboxed tuple arguments. −0.24% geomean, 2 worse.
* **Commit:** `05743c0583`, `5c71c297f3`

### Defunctionalisation heuristics (2026-10-08)
* **Found by:** nofib instructions against `early-fix`: CS +156%, event
  +6.4%.
* **Cause:** defunctionalising webs with one lambda, and curried webs on
  their own.
* **Fix:** at least two lambdas; curried webs only with the web they return
  (Note [Curried lambdas]). CS → +0.0%, event → +0.0%, solid and mate wins
  kept.
* **Commit:** `008ca506e1` (`78618024bc` on `webs`)

### Splitting: useless copies, boxes of primitives (2026-10-08)
* **Found by:** cichelli +1.7% (split only); multiplier +10.2% (it split
  only `Int`s).
* **Cause:** two copies of one list that GHC could no longer share, and a
  specialisation that no longer applied; splitting `Int`, `Char`, `Double`
  boxes buys nothing.
* **Fix:** keep only splits that change something (Note [Keeping only
  useful splits]); do not split boxes of primitives.
* **Commit:** `b5e702d67d`, `d59c6691dd`

### Regression audit: boundary split, strictness (2026-10-07)
* **infer** +11% allocation, **gamteb** +1.2%, **VS** +16% code: the
  boundary split's reflexive cast, missing wrapper demands, and small or
  INLINE functions (Note [Splitting webs at the boundary], Note [Small
  functions are not split]); early result raising leaves known-call webs to
  worker/wrapper (Note [Early result raising]).
* **ida** +2.7% instructions: strictness evaluated variable arguments at
  calls in strict code (Note [Only evaluate what would be a thunk]).
* **pic** +1.1%: evaluating a strict result field early kept the
  constructor's other fields alive (same Note; Note [Web strictness
  fixpoints]).
* **Commit:** `3d69482c8d` (results), `05886a3904`

### Early run pre-empts worker/wrapper (2026-10-05)
* **Found by:** first measurement after demand analysis: allocation CS
  +300%, dom-lt +128%, mate +114%, binary-trees +49%; `$w` workers −51%.
* **Causes and fixes:**
  * uncurrying: worker/wrapper does not unbox an unboxed-tuple argument's
    components (binary-trees) → no early uncurrying;
  * arity raising, same reason, known functions (mate) → early run raises
    only webs with an unknown call (Note [Early arity raising]);
  * arity raising rebuilt a product the lambda also used whole (dom-lt,
    46-field record) → reject when the product is used boxed;
  * constant propagation + dead parameters turned a one-argument
    continuation into a value, losing the lambda SpecConstr and
    eta-expansion need (CS) → a last dead parameter becomes `(# #)` (Note
    [Early dead parameters]).
* **Commit:** `d75e6520da`

### Zapped unfoldings and demand signatures (2026-10-04)
* **minimax** allocated 3,000× more: unfoldings of every local binder were
  zapped and hidden from the interface. Only stale ones are zapped now
  (Note [Unfoldings and rules after a transformation]).
* **bernouilli** +25% allocation: zapped demand signatures made CorePrep
  pass strict arguments as thunks. Signatures are reshaped (Note [Demand
  signatures after a transformation]).
* **Commit:** `dbccaec555`

## Patterns

What keeps coming back, to check first when something breaks:

* **Metadata after a transformation.** Demand signatures, usage demands,
  call arities, unfoldings, CPR, types. Zapping costs performance
  (bernouilli, minimax); keeping it stale costs correctness (T24295b,
  rewrite). Reshape it with the change.
* **Old and rebuilt types.** Every place that builds a type from a
  constructor or a field (new fields, match binders, construction binders,
  coercions) must map it through the rebuild (`ty`). Twice so far.
* **Recursive types.** Never unfold a type, or a demand along a type,
  without a stopping rule. Splitting can give a recursive type one
  constructor (dropping a constructor never built). A web stored in a field
  of the type it takes or returns, `T = (Int, T ->{w} Int)`, cannot be
  raised through itself (an infinite type; safe today only because field
  webs are exposed: `recweb001`-`005`, WEBS-BACKLOG.md).
* **Pre-empting GHC.** A transformation that takes work from
  worker/wrapper, SpecConstr or the code generator has to leave them what
  they rely on: `$w` workers, lambdas, CBV marks, component types.
* **Copies must mean the same.** Strictness, sharing, representation.

## Running tests

Since the machine froze (2026-10-09: the webs testsuite on 20 threads, 7
ways each, with a compiler looping in memory): builds and tests run with
`-j4` inside `systemd-run --user --scope -p MemoryMax=20G -p
MemorySwapMax=0`, with `ulimit -v 4000000` per process. A single compile
under investigation gets `ulimit -v 3000000` and `timeout 60`.
