# Webs: Backlog

Things to implement and ideas to test, in one place. Results go to
`WEBS-EXPERIMENTS.md`, and designs to their own `WEBS-*.md`. When an item is
done, move it to "Done" with a pointer to the commit or document.

**Focus for now:** Core-to-Core passes. Code generation and layout come later.

**Success criterion:** a >5% speedup on some nofib benchmarks, backed by
instruction counts, with heuristics that rarely make a benchmark worse.
Regressions caused by GHC's inliner reacting to rewritten code are accepted
once explained. Regressions caused by our own rewrites are fixed or gated by
a heuristic.

## Now

Plan (2026-10-08):

1. ~~Fix the Core Lint errors in polymorphic defunctionalisation~~ (done,
   see "Done"). All six benchmarks missing from `early-df` (`CS`, `dom-lt`,
   `transform`, `veritas`, `circsim`, `solid`) now compile with
   `-dcore-lint`, with and without lifted bodies.
2. **Test lifted bodies** (`-fcore-webs-defunc-lifted`, Note [Lifted bodies]
   in `GHC.WebCore.Transform.Defunc`). It compiles but has not run yet: run
   the webs tests with it (add `-fcore-webs-defunc-lifted` variants of the
   `defunc` tests), then nofib against the apply-function version.
3. **Then measure.** Partial results so far, with the four benchmarks
   missing (`results/timing-defunc.md`): 71 webs defunctionalised (49 with
   one constructor), against 22 for the monomorphic version; `mate`
   −13.1% time against `base`, `event` +6.5% time (check its
   instructions).

4. ~~Constructed-argument raising and one-shot lambdas~~: done and
   measured (`WEBS-EXPERIMENTS.md` §8): wave4main −4.6%; one-shot has no
   effect. Find out why one-shot has no effect, or drop it.
5. **Data splitting** is on branch `data-split` (worktree
   `~/projects/ghc-data-split`, Note [Splitting data types]): copies of data
   types, no webs. nofib with `-dcore-lint` (`early-ds`) to check for type
   errors; then instruction counts (should be unchanged, ±0.1%).

6. **Defunctionalisation heuristics** (`78618024bc`, `WEBS-EXPERIMENTS.md`
   §7): at least two lambdas; a curried web only with the web it returns
   (Note [Curried lambdas]). Instructions against early-fix: CS +156% ->
   +0.0%, event +6.4% -> +0.0%, solid -13.9% -> -13.8%, mate -4.7% kept.
   constraints +1.4% is left: multi-lambda webs, not yet explained.
7. **Defunctionalise whole arities** (the user's idea): GHC has no
   saturated-call arrow, but web uncurrying makes one, (# a, b #) -> c. Run
   uncurrying, for the curried webs defunctionalisation will take, inside
   defunctionalisation (one constructor per lambda chain, a multi-argument
   $apply), instead of the curried gate. A coarse version -- all
   uncurrying in the early run when defunc is on -- is wrong: event +8.9%,
   constraints +2.5%, solid -15.8%, and mate fails Core Lint after
   SpecConstr (an unlifted case binder of nested unboxed-tuple type; an
   early-uncurrying bug, see Note [No early uncurrying]).
8. **Data splitting, phase 3** (the user's priorities): unbox inside data
   structures -- a split list class whose elements are a non-exposed pair
   class used strictly (every construction passes a value, or every
   consumer forces it) gets the pair unpacked into the cons cell
   ([(a,b)] => a list of (# a, b #)); more aggressive unboxing of Int and
   (,). Needs the copy specialised to its element type (anti-unify the
   class's type arguments, as GHC.WebCore.Transform.SpecIndex does).

## Next

- **Data webs, phase 1** (`WEBS-DATA.md`): data webs in annotation, Lint,
  solving, renaming and erasure, with statistics only. Measure how many
  data webs are local on nofib, per type constructor.

## Core-to-Core: to implement

- **Named function types, one per web** (from an earlier implementation):
  analogous to named data types, each web gets a named function type
  constructor. Monomorphism or specialisation is then recorded once per web
  in its type, instead of being recomputed by every pass (e.g.
  defunctionalisation's types `D_w a b`, and specialising them when a most
  general unifier exists).

- **Data webs, phases 2–4** (`WEBS-DATA.md`): splitting into local types;
  strict, unpacked and dead fields; congruence for nested fields.
- **Local newtypes** (Survey §14): a newtype that is not exported gets
  ordinary webs on its axiom, so functions in a local `State` monad become
  transformable.
- **Constructed-argument raising** (Survey §8): if every call of a web
  passes an explicit constructor application, unbox it even if a lambda is
  lazy in it (each lambda rebuilds it, a value). What SpecConstr does by
  copying. A second eligibility rule in `ArityRaise.hs`.
- **Nested unboxing** (Survey §1): arity raising unboxes one level; GHC
  unboxes a pair of pairs recursively.
- **Uncurrying in the early run** (Survey §11): off there today (Note [No
  early uncurrying]: worker/wrapper does not unbox tuple components, and
  T10830 overflows its stack). Also: uncurry across cheap work between the
  lambdas, as GHC's arity analysis allows.
- **Constants of non-closed type** (Survey §9, §10): constant propagation
  handles closed constants, including global dictionaries; a constant whose
  type mentions the web's type variables needs specialisation. The static
  argument transformation is the recursive-call case. Low priority.
- **Boundary split: imported functions.** Eta-expand an imported function
  used as a value in local higher-order code, not only the arguments passed
  to one. (The current split is measured now: `WEBS-EXPERIMENTS.md` §5.)
- **Richer demands in web strictness.** Nested demands (strict in a field of
  a product argument), call demands (an argument always called with n
  arguments), cardinality.
- **One-shot lambdas from webs.** If every partial application of a web's
  lambdas is called at most once, the lambdas are one-shot. GHC uses this to
  float work into lambdas and to eta-expand.
- **Partial absence.** Drop the unused fields of a product argument at
  unknown calls (dead parameters handles whole parameters only).
- **Call demands and cardinality** are under "Richer demands" above.
- **Compile time** (deferred until the transformations give good results,
  the user's call, 2026-10-08). The early pipeline costs +10–11% compiler
  allocation on nofib; Web Lint runs once per round of each transformation.
  Data splitting doubles compiler allocation (+100% against base): every
  occurrence gets a real TyCon with DataCons (~580,000 copies over nofib).
  Fix: cheap placeholders per occurrence during annotation and Data Lint,
  real types only for the final split classes.

## Ideas to test

- **Constructed arguments with known calls.** The early run leaves
  known-call webs to worker/wrapper (Note [Early arity raising]), but
  worker/wrapper does not unbox a lazy constructed argument. Try raising
  constructed webs with only known calls too, against SpecConstr.
- **Data splitting: keep the original for one class.** A local,
  unexported type with no exposed class could keep its original type for
  one class instead of making a copy (fewer info tables).
- **Data splitting: Int and other boxed primitives.** `Int` is eligible
  (one constructor, an unboxed field, no wrapper), so local `Int`s get
  copies. Harmless, but it creates types; decide whether to exclude them
  until phase 3 can use them (unboxing).

- **Boundary split, size bound.** The bound is 2× `-funfolding-use-threshold`
  (Note [Small functions are not split]). Try 1× and 3× and compare
  instruction counts.
- **Boundary split, profitability.** Which passes fire on split webs
  (verdict dumps), and does each kind of firing pay off in instructions?
- **Inlining vs fetch bandwidth.** Less inlining means smaller code (fetch
  latency), but more calls and taken branches (fetch bandwidth). Measure
  with `-funfolding-use-threshold` and the top-down breakdown.
- **`nucleic2` code size** (+46%). Result raising makes the `distance`
  closure cheap enough for GHC to inline it at ~30 sites. Accepted as an
  inliner effect; check whether it costs time.

## Later: code generation and layout

- **Flow-directed code layout.** Webs give a call graph that includes
  unknown calls. Uses: order procedures so that hot callers and callees are
  adjacent, align hot entry points, and let a call fall through into its
  continuation. Motivation, measured 2026-10-07:
  - nofib (`base`) loses a median **30%** of pipeline slots in the front
    end; 54 of 112 benchmarks lose at least 30% (`tak` 60%). The back end
    loses a median 9% (`webs-bench/topdown-nofib.py`,
    `results/topdown-base.md`).
  - Identical Core differed by 8% in cycles depending on placement
    (`knights`, `early-fix` vs `early-bnd`), through fetch bandwidth
    (24% → 31% of slots; cache misses went down). With
    `-fproc-alignment=64` the gap disappears (4.48G vs 4.49G cycles):
    alignment alone moves `knights` by -5% to +2%.
- **Tag information at unknown calls.** Tell the code generator that an
  argument passed at an unknown call is already evaluated. Today GHC marks
  that only at known calls.

## Measurement notes

- **Building every configuration with `-fproc-alignment=64`** would take
  placement luck out of cycle and time comparisons (it removed `knights`'s
  8% gap), at some cost in code size. Worth trying in `run-nofib.sh` as an
  option.
- Instruction counts are nearly deterministic (max 0.018% run to run).
  Paired time cancels machine drift but not code layout; see the layout rule
  in `time-nofib.py`.
- The machine runs the `powersave` governor. `sudo cpupower frequency-set -g
  performance` would reduce time noise.
- In `norm` mode, nofib's harness fails `fasta`, `k-nucleotide` and `awards`
  under every configuration (expected output, input file). They are
  dropped from timing.

## Done

- Defunctionalisation fixes (tests `defunc007`, `defunc008`, and `_lifted`
  variants of every defunc test): a lambda's existentials include the type
  variables of its free variables' types; the specialisation post-pass names
  its new coercions freshly (it indexed the old ones by the new parameters:
  the `!!` panic in `circsim` and `solid`), substitutes eliminated
  existentials in field binders, and rebuilds every type whose fields
  mention a specialised type; absent demands are kept as they are.
- Strictness fixpoints across webs: `05886a3904`.
- Boundary split, with its heuristics and fixes: `52d79ed9f2`.
- Early result raising leaves known-call webs to worker/wrapper: `0c771d56b2`.
- Runtime measurement (`time-nofib.py`): `8aa66dad95`.
- Strictness evaluates an argument at the call only if it would otherwise be
  a thunk, or inside a thunk (`ida` +2.7% → 0.0%, `ansi` keeps −3.9%):
  `5e800f524b`.
- Strict result fields propagate through the analysis instead of extra
  cases; argument and result-field strictness are one fixpoint (`pic`
  +1.1% → 0.0%): `7d6e45b09c`.
- Regression audit of the early pass: no benchmark worse than +0.3%
  instructions; `CS` −5.3%, `solid` −5.1%, `dom-lt` −4.7%, `ansi` −3.9%,
  `mate` −3.5% (`WEBS-EXPERIMENTS.md` §5).
- Defunctionalisation, first version (monomorphic webs, unknown calls only):
  22 webs on nofib; `mate` −4.7% instructions more, −11.8% time against
  `base` (`WEBS-EXPERIMENTS.md` §6): `8737fb55c4`.
- Polymorphic webs: `D_w a b` with equalities in the constructors' contexts
  (`d2d8f7f9cb`); specialisation of the new types to the most general
  unifier of their uses, as a post-pass (`57e6903316`). Core Lint errors on
  four nofib benchmarks remain (see Now).
