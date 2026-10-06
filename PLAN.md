# Higher-order worker/wrapper: status and plan

This is the working summary for the `ww-higher-order` branch (a git worktree
of `~/projects/ghc-webs`, branched from `master`, pushed to
`origin/ww-higher-order` on github.com/bquiring/ghc-webs). Read this first
when resuming. The design is in `WW-HIGHER-ORDER.md`; the original idea and
examples are in `WORKING-THE-WORKER-WRAPPER.md`.

## The goal

Extend GHC's own worker/wrapper (not the webs work, which lives on the `webs`
branch in `~/projects/ghc-webs`) to see through functions that are
**returned** or **passed as arguments**. The webs paper is the same authors'
whole-program approach; this branch is the local, native version.

Today GHC splits a function only up to its arity. A function that does work
and then returns a function (with the partial application shared, so it
cannot be eta-expanded), or that passes a local function to a function
parameter, leaves dead and boxed arguments at every unknown call. We split
**through** them:

```haskell
-- returned functions (§2.1)
g = \n -> let k = expensive n in \x y -> e        -- y dead, x strict
==>  $wg = \n -> let k = .. in \x# -> e'
     g   = \n -> let wf = $wg n in \x y -> case x of I# x# -> wf x#

-- function arguments (§2.2)
h = \g n -> let f = \x y -> .. in .. g f ..
==>  h = \g n -> $wh (\c -> g (\x _ -> c x)) n
```

Everything is behind **`-fworker-wrapper-function-results`** (off by default).

## Key decisions (with the reasons)

1. **Every split is a worker/wrapper pair with `wrap . unwrap = id`, where
   `wrap` and `unwrap` are closed.** `unwrap` is evaluated where a value is
   made, `wrap` where it is used: different contexts. So neither may have
   free references; only top-level or imported binders are allowed. A
   justification may use facts about the calls only if nothing moves between
   contexts, or what moves is a closed constant.
2. **Wrapper binds the worker's result with `let` by default, `case` under
   `-fpedantic-bottoms`.** With `let`, a shared partial application
   `h = g n` becomes a lambda, and its uses call the worker directly. The
   price is that `g n` is more defined when `$wg n` diverges, the same trade
   GHC makes when eta-expanding (Note [Dealing with bottom]). Tests
   `wwfunres001` and `wwdeep004` check the exact behaviour under
   `-fpedantic-bottoms`.
3. **Only strict demands unbox.** A returned lambda's binders can be lazy
   but marked unboxed; `wwfunres003` and `wwhoarg009` crashed before this
   rule (both mutation-checked).
4. **Returned and passed lambdas get their demands from an isolated demand
   analysis** (analyse `tmp = \xs -> body` as its own binding). This is
   combined with the in-context binder demands, keeping the more precise
   claim per argument, because the isolated analysis cannot see free local
   functions' signatures.
5. **No split when eta-expansion is safe:** each partial application called
   at most once with all arguments (`T18894b`). **No split for functions
   that inline whole** (`certainlyWillInline`; `T16038`), NOINLINE, or
   stable unfoldings or RULES.
6. **One pass over several levels.** Going down, collect each level's
   demands; coming up, build types; introduce the wrapper only at the
   definition (one `let` per level). Up to depth 4.
7. **Function arguments are "conversions"**: a closed unwrap/wrap pair for
   the values reaching an argument position. Either (A) an ordinary
   `mkWwBodies` split of the functions passed there, (B) for lambdas whose
   function parameter is only called, a nested conversion (going down), or
   (C) for values that are the same constructor at every call, its fields
   (an unboxed tuple), the dual of CPR for continuations.
   The user's framing: track wrappers per parameter, collate at the
   definition.
8. **Data structures of functions are out of scope.** They would rely on
   downstream fusion.

## Current state (2026-10-06)

- **(C), continuations called with constructed data**, is implemented
  ((Constructed) in Note [Worker/wrapper for function arguments];
  `conConv`, used from `lambdaConv`'s `try_positions`). If every call of a
  function parameter `k` passes the same constructor `D e1 .. em` at some
  position (no strict fields, no existentials, not an unboxed tuple, at
  least one field), the worker passes `(# e1, .., em #)` (or `e1` alone)
  and the wrapper's adapter rebuilds `D`.
  - **Fourth nofib run (C, no consumer check; `ww-bench/results-run4`):**
    argument splits at pre-ww went from 1 to 25 (13 in `hpg`, 3 each in
    `fem` and `boyer`). Program allocation -0.07% (geomean), `pic` -3.9%,
    `wave4main` -3.3%; code +0.03%, compiler allocation +0.17%.
  - **But (C) lost in `hpg`** (+0.1% allocation, measured by hand). Reading
    its Core: every continuation passed only stores the value
    (`\e -> ec (Apply_exp e1 e)`) or is unknown (`eta`), so the adapter
    rebuilds `D` and each call pays one more closure.
  - **Fixed by (Consumed)**, in two steps:
    - `bb84aba77b` required a consumer among the calls in the module. The
      fifth run (`ww-bench/results-run5`) showed it too strict: argument
      splits at pre-ww fell from 25 to 4, and `pic` lost its -3.9%
      (allocation -0.03% geomean, only `wave4main` -3.3% left). `pic`'s
      `applyOpToMesh` (in `Utils`) builds a list at every call of its
      operator, and the operators taking it apart are in `Potential`.
    - `26fa0e8d19`: the module's occurrences of the function decide. One
      passing a consumer (a lambda or function variable with a strict,
      unboxing demand on that argument) allows the split. If all of them
      pass something else, are partial applications or use the function
      as a value, it is rejected. No occurrence at all (external callers
      only, or inlined everywhere) allows it. Collected per module by
      `callLambdas` (`CallArg`, `wo_call_lams`); a worker split again
      inherits them (`inheritCallLams`). Not tried below the top level.
      New rejection reason: "constructed data, no consumer at the calls".
    - By hand: `pic` -3.1% again, `hpg` at base (+0.0009%), `veritas`
      unchanged. `wwcont_dump`: `storeK` not split, `findK` split.
      `dmdanal` 157 passes; smoke suite only the 2 expected differences.
  - **Sixth nofib run, with the revised (Consumed)** (`ww-bench/report-latest.md`):
    allocation -0.07% again, `pic` -3.9% and `wave4main` -3.3%; see Results.
- **Reading the optimised Core** (`hpg`, `infer`, `lift`, `anna`,
  `veritas`, `power`, `scs`, `exact-reals`, at -O2 with the flag; method:
  copy a benchmark to a scratch directory, `-ddump-simpl`, and compare
  allocation with `+RTS -s` with and without the flag):
  - The big remaining rejection pools mostly have **nothing to gain** for
    worker/wrapper: `lift`'s "tail: local variable" and "returned" cases
    are a difference-list pretty printer (`Iseq = Oseq -> Oseq`, returned
    lambdas only pass their argument on); `anna`'s static-argument cases
    are `map`/`zipWith`/`any`-like loops calling the parameter with list
    elements.
  - Parser combinators (`infer`'s `thenP`, `scs`'s `sequence2`; lists of
    successes) lose to intermediate tuple lists and to `thenP` never
    meeting its known continuation: that needs fusion or specialisation on
    function arguments, not worker/wrapper.
  - **(Cpr), CPR for the deepest returned lambda** (state-monad actions in
    `veritas`, `x_set_tactic t = let g = .. in \xin -> (.., ..)`): tried and
    **measured a loss**: veritas splits 54 functions and allocates 0.13%
    more, because callers bind the pair with lazy patterns (it is rebuilt
    at once) and each partial application gets one more closure. Kept as
    commit `e5fa74a35d` on the local branch `ww-ho-cpr-experiment` (with
    tests `wwcpr001`, `wwcpr_dump`), not on this branch. It would need a
    consumer check like (Consumed).
- **Analysis of the argument rejections** (base, nofib rebuilt without
  running; details in `WW-HIGHER-ORDER.md` §7, finer reasons committed in
  `fedcaa9b2e`):
  - "parameter not only called" (270 at pre-ww): 162 pass the parameter to
    a recursive call (a static argument), 44 to a global function (recursive
    combinators that do not inline: `sequence2`, `thenP`, `pgZeroOrMore`,
    `unpackFoldrCString#`, ...), 31 to a local function, 29 return it.
  - The recursive case is **not** handled by GHC already: the static
    argument transformation is off at every -O level, and even with
    `-fstatic-argument-transformation` it requires more than one static
    value argument. Written in SAT form by hand (`go` local, `g` free),
    `wwhoarg008` is split by our code with the same output.
  - "not given known functions" (156): 154 call the parameter only with
    data (first-order use, as in `map f`), which the split does not target.
  - Continuations called with data: 54 of the 154 take 2 or more arguments;
    31 have some argument constructed at every call (16 with 2 or more
    arguments). That is the pool (C) targets.
- **Invariant applications (the user's idea: the wrapper computes `g f`
  and the worker takes the result)**: statistic `ww-ho-papp` in
  `-ddump-ww-ho-stats` (`paramApps`). It lists applications whose head is an
  unknown function (a parameter, or a lambda- or case-bound variable from
  outside the body) and whose arguments are parameters, variables from
  outside, globals or literals; also invariant prefixes (`g f` in
  `g f y`). Flags: static (recursive, passed unchanged), prefix, underlam,
  only (the head is used nowhere else), call/pap, freeonly (no parameter).
  - nofib, pre-ww (`ww-bench/results/papp`): 211 in all; 173 calls, 137
    "only", 45 prefixes, 9 static, 7 under a lambda, 16 free-only.
  - Nearly all are a parser or state action applied to its input
    (`thenP`'s `xP a`, `sequence2`'s `p1 x0`, veritas's `f xin`), computed
    once per call either way, or a continuation applied to a constant (a
    tail call). Moving them to the wrapper saves no work; at best the
    worker loses an argument.
  - The 9 static ones save nothing either: partial applications of
    comparison or combining functions (`qpart`'s `le x` in knights,
    `segments`' `cellop In` in bspt, `f_tree_member`), a self-call through
    a shared stream (atom), or base cases of loops SpecConstr has already
    specialised (eff's Church-encoded state monad, whose comment asks for
    SAT).
  - Free-only prefixes (`iop ds` in integer, `leq y` in anna): full
    laziness does not float partial applications; again no work, since the
    functions have arity 2.
  - Where it would pay (small examples): a static *full* call, as in
    `k g c (y:ys) = g c * y + k g c ys`, recomputed at every iteration
    today. nofib has none.
- **Benchmark optimisation level:** every nofib run so far was at `-O2`
  (nofib's default `NoFibHcOpts`). `run-nofib.sh` / `run-all.sh` now take
  `NOFIB_OPT` (results then go to `base-O1`, `funres-O1`, `report-O1.md`);
  `-O0` was dropped (no demand analysis or worker/wrapper runs there) and
  an `-O1` run was started and then cancelled by the user.

## What is implemented (all in `compiler/GHC/Core/Opt/WorkWrap.hs`)

Notes to read: **[Worker/wrapper for function results]** (with sub-points
(Depth), (Casts), (Demands), (Calls), (LetOrCase), (EtaFirst), (Small),
(Boxity), (BoringOk)), **[Worker/wrapper for function arguments]** (with
(TypeParams), (Constructed) and (Consumed)), and **[Higher-order worker/wrapper
statistics]**.

- `tryWW` calls `splitHigherOrder`, which tries argument splits
  (`splitFunArg`, chained up to 4 parameters), then result splits
  (`splitFunResult`), then the ordinary `splitFun`.
- **Result splits:**
  - `funResultLevelsWhy` / `analyseLevels` give levels or a rejection reason;
    `mkFunResultPairs` builds the split.
  - Tails can be lambdas, `let`-bound functions (possibly applied to types),
    dead ends, or jumps to join points on the path (retyped).
  - Casts to a newtype over a function type are looked through.
  - Calls of other result-split functions are expanded via their wrapper:
    `expandCall` uses `wo_fr_wrappers`, threaded through `wwTopBinds`.
- **Argument splits:** `funArgConv` / `lambdaConv` / `functionsConv` /
  `conConv` / `paramCalls` / `rewriteCalls` / `mkFunArgPairs`. They handle
  leading type parameters and class dictionaries.
- **Statistics:** `-ddump-ww-ho-stats` (pass `CoreDoHoStats` in
  `GHC/Core/Opt/Pipeline.hs`) runs at three points: early (before the main
  simplifier), pre-ww (where worker/wrapper decides) and final. It counts
  splits, lists the functions split, and gives rejection reasons.
- **Flags and options:**
  - flags: `Opt_WorkerWrapperFunResults` and `Opt_D_dump_ww_ho_stats`, in
    `GHC/Driver/Flags.hs` and `Session.hs`;
  - `WwOpts` fields (in `GHC/Core/Opt/WorkWrap/Utils.hs`; set in
    `GHC/Driver/Config/Core/Opt/WorkWrap.hs`): `wo_fun_results`,
    `wo_pedantic_bottoms`, `wo_dicts_strict`, `wo_dmd_unbox_width`,
    `wo_max_worker_args`, `wo_fr_wrappers`, `wo_call_lams`.

## Tests (`testsuite/tests/dmdanal/`)

- `should_compile` (dump tests, comparing grepped `-ddump-simpl` lines):
  - `wwreturn001-003`: GHC without the flag. These deliberately differ when
    the flag is forced on everywhere.
  - `wwreturn002_funres`, `wwreturn003_funres`, `wwfunres005`,
    `wwdeep_dump`, `wwmix002_dump`, `wwhoarg001/002/006_dump`,
    `wwhostats001` (the statistics terminate on a never-called parameter),
    and `wwcont_dump` (which functions (C) splits, with (Consumed)).
- `should_run`: `wwfunres001-004`, `wwdeep001-004`, `wwhoarg001-009`,
  `wwmix001-005`, `wwlarge001-002` (larger examples with `[+]`/`[-]` marks),
  `wwcast001-002`, `wwpoly001`, `wwcompose001-002`, `wwcont001-002`. Each
  output was taken
  from plain GHC, so the tests check that meaning is unchanged.
- Last results: `dmdanal` 157 passes. A smoke suite of 3,066 tests
  with the flag on everywhere has only the 2 expected `wwreturn002/003`
  differences and no Core Lint errors (with (C)).

## How to build, test and measure

```sh
cd ~/projects/ghc-ww-higher-order
./hadrian/build -j20 --flavour=quick --freeze1 stage2:exe:ghc-bin    # compiler: _build/stage1/bin/ghc
./hadrian/build -j20 --flavour=quick --freeze1 test --test-root-dirs=testsuite/tests/dmdanal
# smoke suite, flag on everywhere:
EXTRA_HC_OPTS="-fworker-wrapper-function-results -dcore-lint" ./hadrian/build -j20 --flavour=quick --freeze1 test \
  --test-root-dirs=testsuite/tests/{callarity,dmdanal,cpranal,simplCore/should_run,simplCore/should_compile,typecheck/should_run,deriving/should_run,codeGen/should_run,indexed-types/should_run,gadt,linear/should_run,programs,numeric/should_run,concurrent/should_run,polykinds,typecheck/should_compile,th} --test-speed=fast
# nofib (about 2 hours; do not rebuild the compiler while it runs):
ww-bench/run-all.sh          # -> ww-bench/results/report.md (base vs funres), at -O2
NOFIB_OPT=-O1 ww-bench/run-all.sh   # -> ww-bench/results/report-O1.md
```

Accepting new dump goldens: run with `--test-accept --only=NAME`, then
filter the `.stderr` to the lines matching the test's `grep_errmsg` pattern.
That keeps the goldens readable; the driver compares filtered output only.

## Results so far (nofib at -O2, 115 benchmarks; `ww-bench/report-latest.md`)

Sixth run, with (C) and the revised (Consumed) (the third run, before (C),
is in `WW-HIGHER-ORDER.md` §7 and `ww-bench/results-run3`):

|                                | early | pre-ww | final |
|--------------------------------|------:|-------:|------:|
| functions returning a function |   477 |    367 |   412 |
| functions taking a function    |   626 |    632 |   768 |
| result splits                  |     9 |      7 |    10 |
| argument splits                |     9 |     13 |     6 |

- **Performance:**

| measure                      | run 3 (no C) | run 4 (C) | run 5 (strict check) | run 6 (revised check) |
|------------------------------|-------------:|----------:|---------------------:|----------------------:|
| program allocation (geomean) |       +0.00% |    -0.07% |               -0.03% |                -0.07% |
| object code (text)           |       +0.07% |    +0.03% |               +0.11% |                +0.10% |
| compiler allocation          |       +0.17% |    +0.17% |               +0.17% |                +0.18% |

  Over 0.5%: `pic` -3.9% (`Utils.applyOpToMesh`) and `wave4main` -3.3%
  (`Main.tabulate`). hpg's losing (C) splits (+0.1% in run 4, by hand) are
  gone. The code size difference between runs 4 and 6 (+0.03% vs +0.10%)
  is not explained yet.
- **The splits that happen (pre-ww):** results in `pretty`, `scs`, `hpg`,
  `anna`; arguments ((C)) in `fem` (3), `hpg` (5), `fluid`, `pic`, `fft`,
  `wave4main`, and `StateX.thenSX` in `infer`.
- **Rejection reasons at pre-ww (run 6):**

| reason                                                          | functions |
|-----------------------------------------------------------------|----------:|
| argument: the parameter is not only called                      |       270 |
| argument: small (inlined whole)                                 |       174 |
| argument: not given known functions (131 only call with data)   |       134 |
| result: a tail is a call                                        |        83 |
| result: nothing to gain                                         |        80 |
| result: a tail is a local variable                              |        79 |
| result: small                                                   |        70 |
| argument: constructed data, no consumer at the calls (Consumed) |        11 |

  Reading the Core (above) suggests most of the large pools have nothing
  for worker/wrapper to gain.
- **`real/symalg`** hit a loop in the statistics (fixed in `b1d3210493`,
  test `wwhostats001`) and was rerun alone; the original logs are kept as
  `ww-bench/results/*/nofib.log.orig`. Previous runs are in
  `ww-bench/results-run1` and `results-run2`.

## What is left to do

1. **Push** the commits after `5d4c77536d` when the user asks.
2. **(Cpr) with a consumer check**, if worth it: only where a call through
   the returned level has its result taken apart (often through a
   let-bound partial application, which makes the check harder).
3. **Remaining big rejection pools:**
   - **Static arguments (162):** recursive functions passing the function
     parameter on unchanged (`wwhoarg008`). Either a SAT-style step in our
     split (the worker's recursive call passes the converted `g'`), or SAT
     for a single static function argument before worker/wrapper. The hand
     SAT form already splits.
   - "result tail is a local variable" / parameter returned (29):
     continuation parameters. Needs the argument and result conversions
     combined.
   - Passed to global recursive combinators (44): would need the callee
     changed; out of reach locally.
   - "small": by design.
4. **Optionally an `-O1` nofib run** (`NOFIB_OPT=-O1`); cancelled once.
5. Type parameters *after* value parameters (argument split).
6. Calls of *other* functions in result tails, beyond result-split wrappers.
7. **An interaction to keep in mind:** the eta-expansion rule (EtaFirst)
   assumes GHC will eta-expand, which it does not under `-fpedantic-bottoms`
   with a bottoming branch (found in `wwcast002`).
8. **Before proposing upstream:** measure runtime (`NoFibRuns=5` on a quiet
   machine); the timings on this machine are unreliable. Also measure
   compile time, and run the full testsuite (not just the smoke subset)
   with the flag on.
9. **Housekeeping:** `build-setup.log` and the `ww-bench/results*`
   directories are untracked or ignored (`results-run3`: third run;
   `results-run4`: (C) without the consumer check).

## Related work on the `webs` branch (`~/projects/ghc-webs`)

That branch implements the webs paper (Quiring, Van Horn, Reppy, Shivers,
PLDI 2025) in GHC. It has web-based dead parameters, uncurrying, arity
raising, strictness, result raising, constant propagation and super-beta
inlining. There are nofib experiments in `WEBS-EXPERIMENTS.md`, and
`WEBS-WW.md` frames web passes as worker/wrapper. Its `PLAN.md` and
`CLAUDE-PLAN.md` are the webs plans; this file is only for `ww-higher-order`.
