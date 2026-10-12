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

## 5. Runtime: strictness fixpoints, boundary split, regression audit

Configurations: `base` (no webs), `early-fix` (the early pass with all seven
transformations, after the strictness fixes of 2026-10-07), `early-bnd`
(`early-fix` plus `-fcore-webs-boundary`). Measured with
`webs-bench/time-nofib.py`: 3 interleaved rounds, pinned to one performance
core, user-space instructions and cycles from perf, paired ratios against
`base` (`results/timing-audit.md`). Instruction counts vary by at most
0.018% from run to run.

Every benchmark that changes by more than 0.3% in instructions:

| benchmark | instructions | cycles | time (every round agrees) |
|---|---|---|---|
| `CS` | −5.3% | −7.6% | −9.7% |
| `solid` | −5.1% | −8.9% | −7.7% |
| `dom-lt` | −4.7% | −3.6% | −3.5% |
| `ansi` | −3.9% | −9.1% | −6.0% |
| `mate` | −3.5% | −5.1% | −4.8% |

That is `early-fix`; `early-bnd` is the same, plus `cse` −1.7%, `prolog`
−1.0% and `constraints` −0.9% instructions. **No benchmark gets worse by more
than 0.3% in instructions in either configuration.** Geomeans: −0.21%
instructions and −0.33% time (`early-fix`); −0.24% and −0.31% (`early-bnd`).

`cse` is 1.7% fewer instructions but 3.7% more time under `early-bnd`: code
layout. Identical or near-identical Core moved cycles by up to 8%
(`knights`, `mkhprog`), through front-end fetch bandwidth; with
`-fproc-alignment=64` the `knights` gap disappears. A time change without an
instruction change is reported as layout only.

How the regressions were fixed (each in a Note):

* `infer` +11% allocation, `gamteb` +1.2%, `VS` +16% code: the boundary
  split's reflexive cast, missing wrapper demands, and small or INLINE
  functions (Note [Splitting webs at the boundary], Note [Small functions are
  not split]); early result raising leaves known-call webs to
  worker/wrapper (Note [Early result raising]).
* `ida` +2.7% instructions: strictness evaluated variable arguments at
  calls in strict code (Note [Only evaluate what would be a thunk]).
* `pic` +1.1%: evaluating a strict result field early kept the
  constructor's other fields alive (same Note; the demand now propagates
  through the analysis, Note [Web strictness fixpoints]).

## 6. Defunctionalisation (first version)

`early-df` is `early-fix` plus `-fcore-webs-defunc` (`WEBS-DEFUNC.md`), built
with `-dcore-lint`: no Core Lint or Web Lint errors on nofib. Verdicts over
all webs (`results/verdicts-defunc.md`):

| verdict | webs |
|---|---|
| exposed | 7,782 |
| no unknown calls | 3,668 |
| polymorphic | 1,134 |
| in a coercion | 34 |
| known calls | 14 |
| shared lambda binders | 4 |
| **defunctionalised** | **22** (17 benchmarks) |

Of the local webs with unknown calls (about 1,200), 94% are rejected for
being polymorphic. That is the next step (a GADT encoding).

Against `early-fix`, in instructions: `mate` −4.7% (−8.0% against `base`;
time −11.8% against `base`), `treejoin` +0.3% (cycles −1.2%); every other
benchmark within ±0.1%.

## 7. Polymorphic defunctionalisation, lifted bodies, heuristics (2026-10-08)

`early-df` (polymorphic, with the specialisation post-pass) and `early-dfl`
(lifted bodies, `-fcore-webs-defunc-lifted`), both on `early-fix` with
`-dcore-lint`: no Lint errors, all 115 benchmarks build and give the right
output (after the fixes in `551b9df701`). 85 webs defunctionalised (54 with
one constructor). Timing: `results/timing-defunc.md` (3 rounds; the machine
was loaded, so times are noisy). Instructions against `early-fix`:

| benchmark | early-df | early-dfl |
|---|---|---|
| solid | −13.9% | −13.4% |
| mate | −4.7% | −4.7% |
| CS | **+156%** | +156% |
| event | +6.4% | +6.4% |
| constraints | +1.4% | +1.0% |

Lifted bodies and an apply function come out the same, to within noise.

CS (a Church-encoded state monad) had two causes. Curried continuations
(`\a s -> ..`) were defunctionalised on their first arrow only, so the first
application went through `$apply` and returned an allocated closure; and
one-lambda webs blocked GHC's specialisation of the loop on the lambda,
which otherwise reduces it to a counter. Heuristics (`78618024bc`, Note
[Curried lambdas]): at least two lambdas; a curried web only with the web it
returns. With them: CS +0.0%, event +0.0%, solid −13.8%, mate −4.7%;
constraints +1.4% left (multi-lambda webs, not yet explained).

Uncurrying every web in the early run when defunctionalisation is on (to
defunctionalise whole arities) is worse: event +8.9%, constraints +2.5%,
solid −15.8%, and mate fails Core Lint after SpecConstr (a nested
unboxed-tuple case binder). The backlog has the restricted version.

## 8. Constructed-argument raising and one-shot lambdas (2026-10-08)

`early-cr` is `early-fix` rebuilt with constructed-argument raising (part of
arity raising since `78d6fd8fc9`); `early-os` adds `-fcore-webs-one-shot`.
Both with `-dcore-lint`: no errors, right output everywhere
(`results/timing-newpasses.md`, `results/verdicts-newpasses.md`).

* Constructed arguments: 4 of 112 benchmarks change by more than 0.1% in
  instructions against `early-fix`: `wave4main` −4.6%, `dom-lt` −0.3%,
  `fft` −0.1%, `fluid` +0.2%.
* One-shot lambdas: 1,588 of 15,300 webs marked one-shot, but no benchmark
  changes by more than 0.1% against `early-cr`. GHC gets the information
  elsewhere (demand analysis), or does not use it where we give it.

## 9. Early against late; uncurrying known calls; CBV marks (2026-10-08/09)

All with `-dcore-lint`, all 115 benchmarks built and right. Instructions
against `base` (112 benchmarks; `WEBS-DATA.md` has the data-splitting runs):

| configuration | geomean | >0.5% better | >0.5% worse |
|---|---|---|---|
| `early-fix` (function webs, early) | −0.20% | 5 | 0 |
| `late-fix` (function webs, late) | +2.68% | 3 | 57 |
| `late-fix2` (+ simplifier after the late run) | +2.18% | 7 | 53 |
| `late-fix3` (+ uncurrying gate) | −0.24% | 8 | 2 |
| `early-du8` (early + data splitting + unboxing) | **−0.96%** | **23** | 1 |
| `late-du3` (late + data splitting + unboxing, gated) | −0.58% | 16 | 2 |

* **The simplifier after the late run** (Note [Simplifying after the late
  webs]) helps a little; the big regressions were elsewhere.
* **Uncurrying known calls** was all of them: binary-trees +34%, fft2 +30%,
  both back to `base` without uncurrying. In the late run it uncurried
  worker/wrapper's workers, whose calls are known. Gate: Note [Uncurrying
  known calls] (`-fcore-webs-uncurry-known` lifts it).
* **Why it cost so much**: a worker's strict arguments carry call-by-value
  marks (`StrictWorker([~, !])`: the caller passes the tree evaluated and
  tagged, so the callee matches on it without checks). GHC gives no marks to
  a function with a multi-register unboxed tuple argument, and the web
  transformations pass arguments as unboxed tuples: the uncurried worker was
  `StrictWorker([])`, and every match paid an evaluatedness check.
  Allocation was unchanged; mutator time 0.90 s → 1.32 s.
* **CBV marks for unboxed tuple arguments** (Note [CBV marks for unboxed
  tuple arguments] in `GHC.Core.Tidy`): one mark per unarised argument. With
  known-call workers uncurried, binary-trees 10.07 G → 7.54 G instructions
  (`base` 7.51 G), fft2 11.33 G → 8.85 G (8.71 G). Passes the webs tests,
  GHC's stranal, codeGen/should_run and unboxedsums tests, and
  `-dtag-inference-checks` on five benchmarks. In the default configurations
  it changes nothing (`early-du9` = `early-du8`, `late-fix4` = `late-fix3`):
  the gates keep the transformations away from workers.
* **Without the gate, with marks** (`late-fix4k`): +1.09% (43 worse), from
  +2.18%. wheel-sieve1 +16.6%, nucleic2 +15.1%, sched +12.1%, boyer +11.6%,
  queens +11.1% remain: a second cause. Wins too (puzzle −9.5%, bspt −4.7%,
  gen_regexps −3.2%, solid −2.9%): a finer rule could keep them.

## 10. The second cause; curried arguments; whole-arity defunctionalisation (2026-10-09)

* **The second cause** was Unarise: an unboxed-tuple argument's components
  get binders typed by representation only (`Any`), so the code generator
  cannot tell that a `Float` is not a function, and `case us of F# y`
  becomes a slow call through `stg_ap_0_fast` (nucleic2, late: 15% of its
  instructions; wheel-sieve1 too). GHC's generic apply checks the arity at
  run time, so curried calls are already cheap, and uncurrying never showed
  a win: **uncurrying is parked** (the user's call), and **arity raising
  passes the components curried** (Note [Raised arguments are curried]),
  with the arity, demand signature and usage patched up. nucleic2 (late):
  +11.2% → −0.28%; wheel-sieve1: back to `base`. The CBV-marks change of §9
  is then mostly dead code; the A/B (`early-cur`/`late-cur` against
  `-b` without it) gave identical instructions (−2.00%, −0.87%), so it
  was removed.
* **Program allocation** against `base` (geomean): `early-du9` −0.99%,
  `early-du10` (+ dead fields) −1.84%, `early-cur` (+ curried) −1.84%,
  `late-cur` (late, curried, no uncurrying) −0.85%, nothing worse by 1%
  (cryptarithm2 −23.1%, compress2 −10.1%, mkhprog −9.5%, treejoin −6.6%).
* **Whole-arity defunctionalisation** (Note [Defunctionalising whole
  arities]): constraints' foldTree lambdas take two arguments; the outer web
  and the one it returns become one `D_w A X B` with a two-argument apply.
  That alone changed nothing: **SpecConstr made a wild-card of every
  coercion argument**, and the constructors' reflexive equalities made each
  call pattern quantify over coercion variables, which SpecConstr discards
  (Note [SpecConstr and casts]); base GHC specialises foldTree on the
  lambdas, three copies. Fixed in SpecConstr (Note [SpecConstr and
  reflexive coercions]). Defunctionalisation against `base`: constraints
  +1.4% → −0.02%, solid −18.8% (allocation −50.9%), mate −8.0%, CS −5.4%,
  event 0.0%.
* **cryptarithm2's lost 3%** (−15.1% before strictly eliminated fields,
  −11.8% after): with `-fcore-webs-no-strict-elim`, −15.2%. Not the round
  limit, as first thought: with `-fcore-webs-unbox-rounds=5` or `10` the
  same 6 fields are unboxed and the instructions are the same (6,927.8M
  against 6,664.9M without strict elimination, 5 fields; base 7,855.9M).
  Strict elimination unboxes one field more, and that one costs.

## 11. After merging webs into data-split (2026-10-09)

The merged compiler (constructed-argument raising, hidden fields,
specialising for webs, the flattening fixes), all with `-dcore-lint`, all
115 benchmarks built (`webs-bench/run-merged.sh`; `base` rebuilt with it).
`early-m` = early-cur's options; `early-mdf` = with defunctionalisation.
Against `base` (`results/timing-merged.md`, `report-merged.md`):

| | `early-cur` | `early-m` | `early-mdf` |
|---|---|---|---|
| instructions (geomean) | −2.00% | −2.02% | **−2.20%** |
| time (geomean) | −2.32% | −2.34% | **−2.60%** |
| program allocation (geomean) | −1.84% | −1.89% | **−3.14%** |
| >0.5% fewer / more instructions | | 31 / 1 | 31 / 1 |

Best instructions (`early-mdf`): integer −59.7%, solid −21.8% (allocation
−85.9%), queens −20.0%, linear −12.2%, cryptarithm2 −11.8%, mate −7.9%,
puzzle −7.2%, CS −5.3%, treejoin −5.2%, dom-lt −5.1%, wave4main −4.7%
(new: constructed arguments), cse −4.0%. Worst: simple +0.5%. 13
benchmarks at least 5% faster, backed by instructions. rewrite now builds
and runs right (−6.6% allocation; early-cur crashed). fasta, awards and
k-nucleotide fail for base too (harness).

## 12. Strictness feeding raising (2026-10-09)

Web strictness records the strictness it proves on the parameters (Note
[Recording proven strictness]); raised components get their demands within
the product (Note [Component demands]), are never partially applied, and are
substituted rather than aliased, so nested raising works (`alltransforms001`:
`sumP` passes `Int#`); `-fcore-webs-passes=N` repeats the transformations
(Note [Repeating the transformations]). `run-strict.sh`: early-mdf's options
with one pass (`early-ns`) and two (`early-ns2`), all 115 built with
`-dcore-lint`.

No benchmark changes by more than 0.2% in instructions or allocation
against `early-mdf` (geomean −2.19% for all three; allocation −3.14%).
Arity raising raises 27 webs over nofib, 28 with one pass and 30 with two:
its limits are exposure (7,763 webs) and known calls left to worker/wrapper
(7,304), not laziness. Kept (correct, and nested raising is needed later),
with one pass by default.

The measurement itself got faster: builds with 4 jobs (`NOFIB_JOBS`) and
timing on 4 performance cores (`time-nofib.py --cpus 2,4,6,8`; instruction
ratios match the serial runner to 0.01 points over 111 benchmarks): 3 rounds
of 4 configurations in 7 minutes instead of about 40.

## 13. Exports: the boundary split and the main module (2026-10-09)

Exported binders alone exposed 68% of exposed lambda classes (branch
`exposure-stats`). `run-exports.sh`: early-mdf's options with the boundary
split (`early-bnd2`), with the main module's exports other than main
internal (`early-main`, Note [Main's exports]), and both (`early-bm`); all
115 built with `-dcore-lint`. Against `base`:

| | instructions | time | allocation |
|---|---|---|---|
| `early-mdf` | −2.19% | −2.47% | −3.14% |
| `early-bnd2` | −2.33% | −2.38% | −3.19% |
| `early-main` | −3.56% | −3.34% | −4.66% |
| `early-bm` | **−3.60%** | **−3.61%** | **−4.62%** |

Against `early-mdf`: integrate −76.2% and sphere −11.2% (Main's exports),
constraints −12.2%, cse −1.8%, prolog −1.0% (boundary split); multiplier
+1.15% (Main's exports), the only regression above 0.5% in instructions.
15 benchmarks at least 5% faster, backed by instructions (12 before).
treejoin +23% time in early-bnd2 and early-main but not early-bm, with no
instruction change: probably noise from parallel timing (it is GC-heavy);
recheck serially.

`early-bm` against `base`, medians of paired ratios, norm mode (112
benchmarks; geomean instructions −3.50%, time −3.61%, allocation −3.82%):

| benchmark | instructions | time | allocation |
|---|---|---|---|
| **geomean (112 benchmarks)** | **−3.50%** | **−3.61%** | **−3.82%** |
| imaginary/integrate | −76.4% | −72.0% | −80.8% |
| spectral/integer | −59.7% | −72.7% | −50.5% |
| spectral/hartel/solid | −21.8% | −17.8% | −54.6% |
| imaginary/queens | −20.0% | −17.7% | 0.0% |
| spectral/constraints | −12.2% | −11.9% | −4.2% |
| real/linear | −12.2% | −8.8% | −18.0% |
| spectral/cryptarithm2 | −11.8% | −16.2% | −14.5% |
| spectral/mate | −7.9% | −14.0% | −7.4% |
| spectral/puzzle | −7.2% | −5.6% | +0.7% |
| spectral/cse | −5.7% | −5.1% | −10.5% |
| real/eff/CS | −5.3% | −5.9% | 0.0% |
| spectral/treejoin | −5.3% | +3.0% | −0.9% |
| spectral/dom-lt | −5.1% | −3.9% | −3.7% |
| spectral/hartel/wave4main | −4.7% | −5.3% | −13.8% |
| spectral/ansi | −3.9% | −9.0% | −3.9% |

The main-module change is opt-in since: `-fcore-webs-internal-main-exports`.

## 14. The boundary split for every exported function (2026-10-10)

The design from §13: every exported function is split, small ones too; a
split whose local copy no transformation changed is undone after erasure
(Note [Contracting the boundary split]); the wrapper eta-expands
function-typed parameters, sharing partial applications (Note
[Eta-expanding parameters at the boundary]). `run-exports2.sh`: early-mdf's
options with the new split (`early-bnd3`), and with Main's exports internal
too (`early-bm3`), against `base` and `early-bm` (the old split with Main's
exports internal). Built with `-dcore-lint`; `scc` and `fem` did not build
(a latent defunctionalisation bug, fixed since: WEBS-BUGS.md, "a captured
dictionary as a field"), so they are missing from the new configurations.

Against `base` (medians of paired ratios, norm mode, 108 benchmarks timed):

| | instructions | time | allocation |
|---|---|---|---|
| `early-bm` | −3.63% | −4.09% | −3.89% |
| `early-bnd3` | **−3.63%** | −4.00% | −3.82% |
| `early-bm3` | −3.63% | −3.80% | −3.82% |

* **The new split covers Main's exports.** `early-bm3` and `early-bnd3`
  have the same instruction count and allocation on every benchmark: with
  every exported function split, making Main's exports internal changes
  nothing. `-fcore-webs-internal-main-exports`, which assumes the module is
  a program's main module, is no longer needed: the split gives Main's
  exported functions internal local copies, which was the flag's effect on
  nofib. What only the flag does (hidden fields for Main's types, exported
  non-function bindings) made no difference. The flag stays in the
  compiler (Note [Main's exports]), but experiments from here on leave it
  off; the baseline is `early-bnd3`.
* Against `early-bm`, instructions: integrate −2.8%, simple −0.9%; hpg
  +3.0%, veritas +0.8%; everything else within 0.1%.
* hpg is continuation-passing (`Cont = Env -> Answer`): 17 exported
  functions split, 1 contracted in `Env`. Pinned instruction counts:
  `early-bm` 5.28 G, new split 5.44 G (+3.0%), new split without
  defunctionalisation 5.60 G (+6.1%): defunctionalisation recovers half,
  the rest comes from the split (open, WEBS-BUGS.md).

## 15. Function-level polymorphism in the final Core (2026-10-10)

How much polymorphism is left at the end of the Core pipeline (before
CorePrep), and how each polymorphic binding's type parameters are
instantiated: Note [Polymorphism statistics] (`-ddump-first-class-stats`),
`run-poly.sh`, `poly-report.py`, `results/report-poly.md`. nofib, 442
modules; `poly-base` (GHC alone) and `poly-bnd3` (the webs baseline).

`poly-base`: 2,036 polymorphic bindings (2,020 top-level, 16 local; 910
exported; 583 overloaded), 3,195 type parameters:

| class | parameters | share |
|---|---|---|
| exported | 1,594 | 49.9% |
| open (one type, with type variables) | 833 | 26.1% |
| variable | 288 | 9.0% |
| constant (one closed type) | 220 | 6.9% |
| escaping | 178 | 5.6% |
| unused | 46 | 1.4% |
| other kind | 20 | 0.6% |
| **shape** (anti-unifier with a constructor on top) | **16** | **0.5%** |

`poly-bnd3` is close: 3,322 parameters, shape 15, constant 210, open 870,
variable 390.

* **Shape is rare**: 16 parameters, almost all in hartel's generated code
  (`f :: [a] -> ..` at lists, `(h0, [T])` in transform, solid's
  `(HS2, h0)`), plus constraints' `mapTree` at pairs. Generalising type
  abstractions by anti-unification has little to act on in nofib.
* **Constant**: 220 parameters always at one closed type (lists 41, fluid's
  `Frac` 24, Char 17, tuples 15, Int 14); 144 have two or more
  instantiations. Type constant propagation (monomorphisation) would reach
  these; unboxing gains need the type to be a product or a primitive box.
* **Open** (26%): one type that mentions type variables, 732 of 833 at a
  single site: top-level functions (floated out, or worker/wrapper's
  workers) called from one polymorphic caller at its own type variables.
  Nothing to specialise.
* Type applications are mostly to data constructors (65%) and imported
  functions (28%); 7% are to bindings defined in the module.
* Half the type parameters belong to exported bindings, which other modules
  instantiate; the boundary split leaves type abstractions alone.
* `ZonkAny` already appears in Core here: the typechecker zonks
  unconstrained type variables to it (parstof's `lexmatch_do`, scs), not
  the optimiser.

## 16. Useless elimination and its strictness dual (2026-10-10)

Useless elimination (`-fcore-webs-useless`, Note [Useless elimination]):
the user's constraint-fixpoint design on webs, a least fixpoint over local
variables, web parameters, unboxed-tuple result components and the fields
of internal types, with live dependency paths; dead lets go, dead
parameters are deleted or turned into `(# #)`, dead components are dropped,
dead fields become absent fillers. Against `early-bnd4` (the baseline with
dead parameters), useless elimination in its place (`early-uls3`), 112
benchmarks, `timing-useless3b.md`:

| against `base` | instructions | time | allocation |
|---|---|---|---|
| `early-bnd4` | −3.51% | −3.99% | −3.76% |
| `early-uls3` | **−4.05%** | **−4.70%** | **−4.17%** |

**Why paraffins gains 45%.** It only counts: `length` of lists of
radicals and paraffins, never a look inside `data Radical = H | C Radical
Radical Radical`. So all three fields of `C` are dead (each `C ri rj rk`'s
fields only go into other `C`s and paraffins, which are never matched).
Useless elimination replaces them with absent fillers, every construction
becomes `C absent absent absent`, a constant, and GHC floats it to one
static closure (`lvl8 = C lvl7 lvl7 lvl7`): the program no longer allocates
a `C` cell per radical. 17: 52.1 GB to 35.1 GB allocated, 6.4 s to 3.7 s
MUT. In general: when every field of a constructor is dead, all its
constructions collapse into one shared value. With
`-fcore-webs-data-again` the fields are then dropped from the type (`C_r14`
becomes nullary), which saves nothing more here.

`early-uls3` against `early-bnd4`: −0.57% instructions, −0.74% time;
paraffins −45.3% instructions (−29.9% allocation), ida −2.5%, parstof −1.7%
(−11.4% allocation); pic +1.0%, multiplier +0.6%. Time changes without
instruction changes (bspt, integer, fem +7–8%) are layout. Without fields
(`early-uls2`), useless elimination was −0.01% against `early-bnd4`: it
finds about 33 more dead parameters than dead parameters (cycles like the
dissertation's f/g) and 16 webs with dead result components, which change
little; the gain is the 14 dead fields, almost all of it paraffins'.

The dual (`-ddump-webs-forced`, analysis only, Note [Strictness as the dual
of liveness], Note [Forced fields]) on nofib: web parameters 6,965 strict of
23,280, 46 not known to demand analysis; lets 1,975 of 5,830 (with
let-bound thunks followed), 19 new; fields of internal types 56 of 1,107;
result components 0 (the 43 before let-following and fields were vacuous).
Little for a transformation to gain beyond what GHC already does.

Bugs found on the way (WEBS-BUGS.md): one unique bound twice in disjoint
scopes (fresh binders per round); the dump calling exprIsDeadEnd on web
forms; and a dead field filled by useless elimination, then evaluated early
by web strictness (vacuously strict: a greatest fixpoint), in parstof
(Note [Do not evaluate dead ends early]). Tests: useless001-018,
poison001-046 (each also in the late run), poison*_forced.

A timing run during heavy background load (a game, 5x slower wall times)
hit the 10 s timing timeout in 12 benchmarks; it was rerun with 60 s.

**Data splitting again and strict ∧ live** (`run-uselessda.sh`,
`run-strictlive.sh`). Splitting and unboxing again after the web passes
(`-fcore-webs-data-again`, Note [Data splitting again]) on top of
`early-uls3`: −0.02% instructions (constraints −2.1%; parstof −3%
allocation); once useless elimination has filled a dead field, dropping its
slot saves little, and few more fields unbox. Dead constructors are mostly
gone already: data splitting keeps only the constructors built in each
class, and a constructor built only for dead code is usually its own class
(poison047). Strict ∧ live (Note [Strict and live]: web strictness
evaluates early only what liveness finds live) changes no benchmark's
instructions (`early-ulsl` against `early-ulsda`): with useless elimination
before it, one strictness verdict on nofib changes; it closes the
soundness gap (vacuously strict dead values, parstof) rather than speeding
anything up. Against `base`, `early-ulsl`: −4.10% instructions, −4.44%
time, −4.18% allocation; all 115 benchmarks build (data splitting again
broke rewrite until its binders and occurrences were re-synchronised,
WEBS-BUGS.md).

## 17. Hackage programs: base vs early-ulsl (2026-10-11)

Real programs outside nofib, in the local repo ~/projects/webs-hackage-bench
(not part of this tree): happy 2.1.3 on GHC's Parser.y, alex 3.5.2.0 on
Lexer.x, cpphs 1.20.10 on all of compiler/GHC/*/*.hs concatenated, and
skylighting 0.13 highlighting Simplify/Iteration.hs as HTML.  Every package
and its non-boot dependencies (70 packages) built with -O2 plus the
configuration's flags; boot packages (base, containers, text, bytestring,
mtl, parsec, ...) are the tree's own and get no webs, as in nofib.
early-ulsl is the nofib baseline's flags (-fcore-webs-early, inline,
const-prop, arity/result raising, strictness, data split/unbox, defunc,
boundary, useless, data-again) with -dcore-lint.  5 interleaved rounds on
one pinned CPU, medians; all outputs identical to base.

| benchmark | base time (s) | base instr. (G) | instructions | time | allocation |
|---|---|---|---|---|---|
| happy | 2.30 | 35.78 | -0.05% | +0.16% | -0.02% |
| alex | 0.15 | 1.52 | -0.49% | +0.13% | -0.56% |
| cpphs | 0.61 | 6.59 | +0.53% | +0.30% | +0.03% |
| skylighting | 0.97 | 8.38 | +0.11% | +1.42% | -1.28% |
| geomean | | | +0.02% | +0.50% | -0.46% |

Neutral: nothing like nofib's -4%.  Time differences are within noise of
one-second runs; instructions and allocation are the reliable columns.
Likely reasons, not yet examined: much of these programs' time is in boot
libraries (text, containers, bytestring, parsec), which are not rebuilt
with webs; and the webs are per module, so the boundary split exposes the
large cross-module interfaces of library code while gaining little inside
it.  Building them found four compiler bugs (WEBS-BUGS.md, 2026-10-10/11:
result raising's case binder, useless elimination's coercion variables and
join arities, data splitting's kind-level types), all fixed.

## 18. Large Hackage programs: base vs early-ulsl (2026-10-11)

The second group in ~/projects/webs-hackage-bench (`large/`): ShellCheck
0.11.0 checking GHC's libraries/unix/configure (7.9k lines; GHC's own
19k-line configure needs more than 12 GB even without webs), hledger 1.52.4
on a generated 100,000-transaction journal (balance --tree --monthly
--value=then,$), and dhall 1.42.3 type-checking its Prelude without the
import cache.  Same setup as §17 (-O2, every non-boot package with the
configuration's flags, early-ulsl with -dcore-lint), 3 interleaved rounds on
one pinned CPU, medians; all outputs identical to base.

| benchmark | base time (s) | base instr. (G) | instructions | time | allocation |
|---|---|---|---|---|---|
| shellcheck | 8.05 | 69.90 | -0.35% | -0.67% | +0.15% |
| hledger | 4.82 | 41.45 | +0.95% | +3.67% | +1.73% |
| dhall | 0.51 | 2.35 | -0.01% | -1.55% | -0.07% |
| geomean | | | +0.20% | +0.46% | +0.60% |

Caveats: a first look, not final numbers.

* ShellCheck's early-ulsl build has data splitting, unboxing and data-again
  off (data splitting runs ShellCheck.Parser out of memory: WEBS-BUGS.md,
  open entry), so it measures the other transformations only.
* The store mixes packages built by successive versions of the webs
  compiler during the bug fixes of 2026-10-11 (only aeson and its dependents
  were rebuilt after the atomicModifyMutVar2# miscompilation).  A clean
  rebuild of every package is planned before final numbers.
* pandoc (out of memory in Text.Pandoc.Readers.LaTeX under early-ulsl) and
  Agda (does not build with this GHC snapshot at all) are set aside.

hledger is the one regression (+1.0% instructions, +1.7% allocation; its
time column is noisier).  Not yet examined.  Building the group found nine
webs bugs (WEBS-BUGS.md, 2026-10-11): eight fixed (uniplate, JuicyPixels
x3, hpke, http2, defunctionalisation's memory use on ShellCheck.Parser,
aeson's letrecE miscompilation) and one open (data splitting's memory use
on very large modules).

## 19. SML benchmarks translated to Haskell: base vs early-ulsl (2026-10-12)

The 3CPS test suite's SML programs (~/projects/3cps/3cps-main/test/programs/:
llvm-sml, mostly John Reppy's and others' classic benchmarks, and
higher-order, programs written to exercise higher-order behaviour),
translated to Haskell in ~/projects/webs-hackage-bench/sml (README there):
ordinary lazy Haskell (no strictness annotations, so the strictness
analyses have to find what SML evaluates eagerly), the same algorithms and
data structures, each repeated to ~1 s with an opaque zero added to its
inputs so nothing is floated out of the loop, each printing what its SML
original prints (checked against MLton executables).  boyer, life and
nucleic are left out (nofib has them).  early-ulsl with -dcore-lint, -O2;
3 interleaved rounds on one pinned CPU, medians.  Instructions and
allocation are the reliable columns (tak: +10% time with identical
instructions).  All 39 built without a webs bug.

| benchmark | base instr. (G) | instructions | allocation |
|---|---|---|---|
| ack | 16.45 | -0.04% | 0 |
| tak | 15.01 | 0 | 0 |
| cpstak | 12.94 | **+82.00%** | +6.87% |
| y-fact | 20.24 | **-17.75%** | -100.00% |
| nqueens | 9.46 | **-22.48%** | -14.73% |
| mandelbrot | 14.52 | +1.47% | 0 |
| quicksort | 11.26 | 0 | 0 |
| filter | 18.19 | 0 | 0 |
| derivative | 14.21 | -0.32% | -3.30% |
| streams | 18.53 | -5.81% | 0 |
| tardis | 13.64 | -4.50% | -2.69% |
| interpreter | 17.19 | -8.95% | -14.25% |
| parser-comb | 13.00 | +5.48% | -10.39% |
| twenty-four | 18.07 | **+12.58%** | +15.31% |
| json-decode | 16.01 | +6.60% | +143.65% |
| cps-convert | 14.63 | +0.48% | -0.65% |
| knuth-bendix | 9.86 | 0 | +0.82% |
| raytracer | 15.56 | **-25.21%** | -30.52% |
| ratio-regions | 11.55 | **-17.82%** | -31.97% |
| k-cfa | 14.29 | +1.88% | +0.10% |
| mc-ray | 14.52 | -8.30% | -0.48% |
| *higher-order/* | | | |
| defunctionalization | 14.05 | **-19.95%** | -44.26% |
| returned-closures | 11.51 | +1.97% | 0 |
| function-composition | 19.58 | **-31.30%** | -28.57% |
| mutual-recursion-ho | 12.71 | **-31.10%** | -27.16% |
| tree-fold-ho | 8.30 | **+32.14%** | +43.85% |
| curry-uncurry | 14.20 | -0.16% | -3.12% |
| closure-capture | 8.69 | **-32.29%** | -50.00% |
| higher-order-list | 11.73 | +1.53% | -0.80% |
| church-encoding | 22.00 | 0 | 0 |
| cps-explicit | 7.48 | -7.97% | -8.77% |
| callback-state | 21.15 | 0 | 0 |
| environment-sharing | 11.15 | **-29.45%** | -46.98% |
| polymorphic-ho | 7.01 | **-40.56%** | -50.00% |
| continuation-combinators | 17.39 | **-21.26%** | -33.33% |
| applicative-functor | 16.80 | **-11.70%** | -9.20% |
| tree-traversal-ho | 13.24 | -1.73% | -5.08% |
| register-allocator | 11.26 | **-15.63%** | -20.37% |
| dpll-sat | 8.06 | -1.26% | 0 |
| geomean, llvm-sml (21) | | -1.67% | |
| geomean, higher-order (18) | | -13.28% | |
| geomean, all 39 | | -7.21% | |

The higher-order programs are what webs was designed for, and it shows:
13 of 18 improve, 9 by 15-40% (polymorphic-ho -41%, closure-capture -32%,
function-composition -31%, mutual-recursion-ho -31%, environment-sharing
-29%), with allocation often halved.  The llvm-sml set is mixed: raytracer
-25%, nqueens -22%, ratio-regions and y-fact -18%.  Regressions, not
examined yet (the user: regressions later): cpstak +82% (CPS Takeuchi),
tree-fold-ho +32% (a generic fold with several function pairs),
twenty-four +12.6% (CPS backtracking), json-decode +6.6% (allocation x2.4),
parser-comb +5.5%.  The allocation geomean is not meaningful (y-fact drops
to almost nothing).

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

See `WEBS-BACKLOG.md`, which collects what to implement and what to test.
