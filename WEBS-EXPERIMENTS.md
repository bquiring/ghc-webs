# Web Experiments on nofib

Two questions:

1. **How much first-class function behaviour is left after Core optimisation?**
2. **Do web transformations run *before* the main simplifier reduce the
   inliner's work?** The hypothesis: web transformations do some of
   worker/wrapper's job without wrappers, so there are fewer wrappers to
   inline.

## Setup

- Compiler: this branch (`webs`), `quick` flavour, stage 2.
- nofib, legacy `make` system, `fast` mode, `NoFibRuns=1`, default
  directories (`imaginary`, `spectral`, `real`, `shootout`): 115 benchmarks
  with dumps. Reproduce with `webs-bench/run-all.sh`; it writes
  `webs-bench/results/report.md` (see `webs-bench/run-nofib.sh` and
  `webs-bench/report.py`).
- Four configurations; T = `-fcore-webs-arity-raise -fcore-webs-dead-params
  -fcore-webs-uncurry`:

| name | flags |
|---|---|
| `base` | none |
| `late` | `-fcore-webs` T (web pipeline after all Core optimisation) |
| `early` | `-fcore-webs-early` T (web pipeline before the main simplifier phases; does not uncurry, see below) |
| `early-late` | both |

- **Measures:**
  - `-ddump-first-class-stats` (`GHC/WebCore/FirstClass.hs`): static counts,
    before and after the Core pipeline;
  - `-ddump-simpl-stats` (grand totals of simplifier ticks);
  - allocation of the compiler and of the programs (`<<ghc: ...>>` lines in
    the nofib log).
- **Times are not reported.** On this machine, compile and mutator times
  varied by up to 3× between configurations for identical code. Allocation
  is deterministic. Timings would need `NoFibRuns=5` on a quiet machine.
- **Failures:** the same four benchmarks fail in every configuration,
  including `base`: `smallpt` and `ben-raytrace` don't build (missing
  packages), and `fasta` and `k-nucleotide` fail at runtime. No
  configuration introduces a failure. nofib checks every program's output.

## 1. First-class function behaviour (`base`)

Static counts over all modules (see Note [First-class function statistics]):

| | lambda groups | returned | passed | stored in data | stored in dictionaries | calls | unknown calls | partial apps | `$w` workers |
|---|---|---|---|---|---|---|---|---|---|
| before Core optimisation | 12,571 | 1,103 | 11,787 | 432 | 1,155 | 62,717 | 5,929 | 4,400 | 0 |
| after Core optimisation | 13,762 | 481 | 5,745 | 1,129 | 1,182 | 70,686 | 1,393 | 927 | 1,926 |
| change | +9% | **−56%** | **−51%** | **+161%** | +2% | +13% | **−77%** | **−79%** | |

What the optimiser does to first-class functions:

- It removes most of them from the call path. Unknown calls fall by 77% and
  partial applications by 79%. Functions returned (−56%) and passed as
  arguments (−51%) roughly halve: inlining, specialisation, and
  worker/wrapper resolve most higher-order code.
- Functions stored in data structures go *up*, by 2.6×. Inlining exposes
  constructor applications whose fields are functions (e.g. closures in
  lists or records that were built behind function calls before).
  Dictionary storage barely changes.
- What remains after optimisation (about 1,400 unknown calls, about 5,700
  function arguments, about 1,100 stored functions, summed over 115
  programs) is what web transformations can target, and what GHC's
  known-call machinery cannot.

Per-benchmark tables are in `report.md`.

## 2. Does an early web pass reduce the inliner's work?

Simplifier ticks, summed over all modules:

| | `base` | `late` | `early` | `early-late` |
|---|---|---|---|---|
| total ticks | 810,502 | +0.3% | **−0.5%** | −0.2% |
| `UnfoldingDone` (inlinings) | 80,032 | +0.1% | **−1.8%** | −1.7% |
| `PreInlineUnconditionally` | 256,187 | +0.3% | −0.6% | −0.3% |
| `PostInlineUnconditionally` | 19,444 | +0.0% | +2.2% | +2.2% |
| `BetaReduction` | 306,412 | +0.3% | −0.5% | −0.2% |
| `$w` workers in the final Core | 1,926 | −0.6% | **−1.4%** | −1.7% |
| compiler allocation (geomean) | | +15.9% | +7.8% | +22.8% |
| program allocation (geomean) | | +0.27% | +0.01% | +0.26% |

The results support the hypothesis, but the effect is modest:

- With `early`, worker/wrapper creates 1.4% fewer workers, and the
  simplifier does 1.8% fewer inlinings (`UnfoldingDone`) and 0.5% fewer
  ticks in total.
- The reduction is concentrated in the large programs: `real/veritas` −502
  inlinings (of 6,244), `real/anna` −272 (of 6,439, and 8 fewer workers),
  `real/reptile` −112. The few increases are small (`spectral/mate` +13,
  `simple` +12).
- `PostInlineUnconditionally` rises by 2.2%. The early pass leaves some
  bindings simpler, so they are inlined unconditionally instead.
- The cost: the web pipeline itself (annotation, Web Lint once per round,
  erasure) costs +7.8% compiler allocation in `early` and +15.9% in `late`.
  The pipeline has not been optimised at all. The late run does more, since
  it handles the larger, optimised program and runs three transformations
  with several rounds each.
- Running only the late pass changes the inliner's work by +0.1%, as
  expected, since it runs after the simplifier.

The early pass currently does arity raising (with syntactic strictness only,
because demand analysis hasn't run yet) and dead-parameter elimination. Those
are the two web transformations that overlap with worker/wrapper's strict
unboxing and absent-argument removal. The survey (`WEBS-WW-SURVEY.md`) lists
further worker/wrapper patterns that could move into the early pass, CPR and
call-by-value in particular. Those would test the hypothesis more strongly.

## 3. All seven transformations (second run)

Same setup, but T is now every transformation: super-beta inlining,
constant propagation, arity raising, dead parameters, uncurrying (late
only), result raising (web CPR) and strictness.  The table compares it with
the first run (only arity raising, dead parameters and uncurrying):

| vs `base` | `early`, 3 passes | `early`, 7 passes | `late`, 3 passes | `late`, 7 passes |
|---|---|---|---|---|
| total ticks | −0.5% | **−0.7%** | +0.3% | +0.3% |
| `UnfoldingDone` (inlinings) | −1.8% | **−2.1%** | +0.1% | +0.1% |
| `PreInlineUnconditionally` | −0.6% | −0.9% | +0.3% | +0.3% |
| `$w` workers in the final Core | −1.4% | **−2.9%** | −0.6% | −0.6% |
| object code (text), geomean | +0.19% | +0.37% | +1.74% | +1.97% |
| object code (text), total | +0.0% | +0.2% | +1.5% | +1.8% |
| compiler allocation (geomean) | +7.8% | +11.8% | +15.9% | +21.0% |
| program allocation (geomean) | +0.01% | −0.01% | +0.27% | +0.26% |

Executables change by at most 0.02%: they are dominated by the RTS and the
libraries, so code size is measured on the benchmarks' own object files.

- **Worker/wrapper.** Moving CPR (result raising) and call-by-value
  (strictness) into the early pass doubles the drop in `$w` workers, from
  −1.4% to −2.9%.  The web passes now do part of worker/wrapper's job.
- **Inlining.** `UnfoldingDone` falls a little more, from −1.8% to −2.1%.
- **Code size does not fall.**  The benchmarks' object code grows slightly
  in `early` (+0.37% geomean; `wave4main` +33%, `nucleic2` +13%,
  `circsim` +6%; `reptile` −3.6%, `typecheck` −2.8%).  Fewer workers and
  inlinings do not give smaller code.  The likely reasons are that the
  simplifier still inlines the (now smaller) functions, and that unboxed-
  tuple calling conventions at unknown calls cost code at each call site.
  The hypothesis holds for the inliner's work but not for code size, at
  least for these transformations.
- **Runtime allocation** is unchanged in `early` (−0.01%).  In `late` the
  outliers are the same as before (`wave4main` +13.8%, `dom-lt` +12.2%,
  `compress2` −8.4%), so the new passes did not cause them.
- **Compile cost** grows by 4–5 points per configuration: each pass adds
  rounds, each round runs Web Lint.
- No configuration introduces a build or run failure (the same four
  pre-existing failures as `base`).

## 4. The early pass after demand analysis (third run)

The late run is no longer measured.  `-fcore-webs-early` now runs after the
main simplifier, call arity and demand analysis, and before CPR and
worker/wrapper (Note [Early webs]): the transformations see contracted code
with demand information, and worker/wrapper and the later simplifier runs
see their result.  `early` = every transformation except uncurrying.

The first measurement of this placement showed what goes wrong when web
transformations pre-empt worker/wrapper (program allocation +2.45%; CS
+300%, dom-lt +128%, mate +114%, binary-trees +49%), with `$w` workers −51%:

| cause | benchmarks | fix |
|---|---|---|
| uncurrying: worker/wrapper does not unbox the components of an unboxed-tuple argument | binary-trees | no uncurrying in the early run (Note [No early uncurrying]) |
| arity raising, same reason, for known functions | mate | early: raise only webs with an unknown call (Note [Early arity raising]) |
| arity raising rebuilt a product the lambda also used whole (46-field state record) | dom-lt | reject when the product is used boxed (both runs) |
| constant propagation + dead parameters turned a one-argument continuation into a value; SpecConstr and eta-expansion lost the lambda | CS | early: a last dead parameter becomes `(# #)` (Note [Early dead parameters]) |

Along the way: a miscompilation (T24295b, `-fpedantic-bottoms`) from stale
usage demands, fixed by reshaping usage demands and call arities like
demand signatures (Note [Usage information after a transformation]).

After the fixes:

| vs `base` | `early` |
|---|---|
| total ticks | −0.4% |
| `UnfoldingDone` (inlinings) | −0.6% |
| `CaseIdentity` | −22.9% |
| `$w` workers in the final Core | −1.9% |
| object code (text), geomean | +0.46% |
| compiler allocation (geomean) | +9.3% |
| program allocation (geomean) | **−0.47%** |

No benchmark allocates more than base; `solid` −38.6%, `dom-lt` −3.1%,
`fibheaps` −0.7%.  The large drop in workers of the first measurement was
mostly the harmful transformations; what remains is a modest, regression-free
reduction of the inliner's and worker/wrapper's work, with a small code-size
increase.

## Findings along the way

Running nofib found three performance bugs and one design constraint. Each
was fixed and is documented in a Note:

1. **Zapping unfoldings** of every local binder hid them from the interface
   file. `spectral/minimax` allocated **3,000× more**. Now only stale
   unfoldings are zapped, and vanilla ones are left for Tidy to rebuild
   (Note [Unfoldings and rules after a transformation]).
2. **Zapping demand signatures** of transformed functions made CorePrep pass
   strict arguments as thunks: **+25%** allocation in
   `imaginary/bernouilli`. Signatures are now reshaped (Note [Demand
   signatures after a transformation]).
3. **Strict components of unboxed tuples** are not evaluated by CorePrep, so
   uncurrying now evaluates them at the call (Note [Uncurrying]).
4. **No early uncurrying.** Before demand analysis, uncurrying loses
   call-by-value for strict arguments. The testsuite's T10830 overflows its
   stack. So the early run does not uncurry (Note [No early uncurrying]).

Program allocation of `late` over the three runs: +8.8% → +1.3% → **+0.27%**.
The remaining outliers are `wave4main` +13.8% and `dom-lt` +11.6%, against
`compress2` −8.1%. These are worth a look before measuring time.

## Next steps

- Repeat with `NoFibRuns=5` on a quiet machine to get runtimes.
- Look at the `late` outliers (`wave4main`, `dom-lt`).
- Profile the web pipeline itself (+8–16% compiler allocation): Web Lint
  runs once per round of each transformation.
- Find out why code size grows in `early` (`wave4main`, `nucleic2`).
- Count how often each new pass fires on nofib (verdict dumps).
- Web-based defunctionalization.
