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

- **Regression audit of the early pass.** On user-space instructions against
  `base` (`results/timing-boundary4.md`): `ida` +2.7%, `pic` +1.1%,
  `transform` +0.5%. Method: bisect by module, as for `gamteb`, then trace
  to a pass and a verdict.
- **Data webs, phase 1** (`WEBS-DATA.md`): data webs in annotation, Lint,
  solving, renaming and erasure, with statistics only. Measure how many
  data webs are local on nofib, per type constructor.

## Core-to-Core: to implement

- **Data webs, phases 2–4** (`WEBS-DATA.md`): splitting into local types;
  strict, unpacked and dead fields; congruence for nested fields.
- **Local newtypes** (Survey §14): a newtype that is not exported gets
  ordinary webs on its axiom, so functions in a local `State` monad become
  transformable.
- **Defunctionalisation** (Survey §13): a local web with few lambdas becomes
  a data type, with a `case` at each call.
- **Boundary split: imported functions.** Eta-expand an imported function
  used as a value in local higher-order code, not only the arguments passed
  to one. Deferred on purpose: measure the current split first.
- **Richer demands in web strictness.** Nested demands (strict in a field of
  a product argument), call demands (an argument always called with n
  arguments), cardinality.
- **One-shot lambdas from webs.** If every partial application of a web's
  lambdas is called at most once, the lambdas are one-shot. GHC uses this to
  float work into lambdas and to eta-expand.
- **Partial absence.** Drop the unused fields of a product argument at
  unknown calls (dead parameters handles whole parameters only).
- **Compile time.** The early pipeline costs +10–11% compiler allocation on
  nofib. Web Lint runs once per round of each transformation.

## Ideas to test

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
  continuation. Motivation: `knights` is 42% front-end bound, and identical
  Core differed by 8% in cycles depending on placement, through fetch
  bandwidth (top-down: fetch bandwidth 24% → 31%, cache misses down).
- **Tag information at unknown calls.** Tell the code generator that an
  argument passed at an unknown call is already evaluated. Today GHC marks
  that only at known calls.

## Measurement notes

- Instruction counts are nearly deterministic (max 0.018% run to run).
  Paired time cancels machine drift but not code layout; see the layout rule
  in `time-nofib.py`.
- The machine runs the `powersave` governor. `sudo cpupower frequency-set -g
  performance` would reduce time noise.
- In `norm` mode, nofib's harness fails `fasta`, `k-nucleotide` and `awards`
  under every configuration (expected output, input file). They are
  dropped from timing.

## Running experiments

- **Top-down level 1 across nofib.** Is front-end-bound common? (For
  layout, later.)
- **`-fproc-alignment=64` on `knights`.** Does the 8% gap between
  `early-fix` and `early-bnd` disappear? (For layout, later.)

## Done

- Strictness fixpoints across webs: `05886a3904`.
- Boundary split, with its heuristics and fixes: `52d79ed9f2`.
- Early result raising leaves known-call webs to worker/wrapper: `0c771d56b2`.
- Runtime measurement (`time-nofib.py`): `8aa66dad95`.
