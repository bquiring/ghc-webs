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
   `mkWwBodies` split of the functions passed there, or (B) for lambdas whose
   function parameter is only called, a nested conversion (going down).
   The user's framing: track wrappers per parameter, collate at the
   definition.
8. **Data structures of functions are out of scope.** They would rely on
   downstream fusion.

## What is implemented (all in `compiler/GHC/Core/Opt/WorkWrap.hs`)

Notes to read: **[Worker/wrapper for function results]** (with sub-points
(Depth), (Casts), (Demands), (Calls), (LetOrCase), (EtaFirst), (Small),
(Boxity), (BoringOk)), **[Worker/wrapper for function arguments]** (with
(TypeParams)), and **[Higher-order worker/wrapper statistics]**.

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
  `paramCalls` / `rewriteCalls` / `mkFunArgPairs`. They handle leading type
  parameters and class dictionaries.
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
    `wo_max_worker_args`, `wo_fr_wrappers`.

## Tests (`testsuite/tests/dmdanal/`)

- `should_compile` (dump tests, comparing grepped `-ddump-simpl` lines):
  - `wwreturn001-003`: GHC without the flag. These deliberately differ when
    the flag is forced on everywhere.
  - `wwreturn002_funres`, `wwreturn003_funres`, `wwfunres005`,
    `wwdeep_dump`, `wwmix002_dump`, `wwhoarg001/002/006_dump`, and
  `wwhostats001` (the statistics terminate on a never-called parameter).
- `should_run`: `wwfunres001-004`, `wwdeep001-004`, `wwhoarg001-009`,
  `wwmix001-005`, `wwlarge001-002` (larger examples with `[+]`/`[-]` marks),
  `wwcast001-002`, `wwpoly001`, `wwcompose001-002`. Each output was taken
  from plain GHC, so the tests check that meaning is unchanged.
- Last results: `dmdanal` 154 passes. A smoke suite of about 3,060 tests
  with the flag on everywhere has only the 2 expected `wwreturn002/003`
  differences and no Core Lint errors.

## How to build, test and measure

```sh
cd ~/projects/ghc-ww-higher-order
./hadrian/build -j20 --flavour=quick --freeze1 stage2:exe:ghc-bin    # compiler: _build/stage1/bin/ghc
./hadrian/build -j20 --flavour=quick --freeze1 test --test-root-dirs=testsuite/tests/dmdanal
# smoke suite, flag on everywhere:
EXTRA_HC_OPTS="-fworker-wrapper-function-results -dcore-lint" ./hadrian/build -j20 --flavour=quick --freeze1 test \
  --test-root-dirs=testsuite/tests/{callarity,dmdanal,cpranal,simplCore/should_run,simplCore/should_compile,typecheck/should_run,deriving/should_run,codeGen/should_run,indexed-types/should_run,gadt,linear/should_run,programs,numeric/should_run,concurrent/should_run,polykinds,typecheck/should_compile,th} --test-speed=fast
# nofib (about 2 hours; do not rebuild the compiler while it runs):
ww-bench/run-all.sh          # -> ww-bench/results/report.md (base vs funres)
```

Accepting new dump goldens: run with `--test-accept --only=NAME`, then
filter the `.stderr` to the lines matching the test's `grep_errmsg` pattern.
That keeps the goldens readable; the driver compares filtered output only.

## Results so far (nofib, 115 benchmarks; `ww-bench/report-latest.md`)

Third run, with type parameters and calls of split functions (details in
`WW-HIGHER-ORDER.md` §7):

|                                | early | pre-ww | final |
|--------------------------------|------:|-------:|------:|
| functions returning a function |   477 |    367 |   412 |
| functions taking a function    |   626 |    632 |   768 |
| result splits                  |     9 |      7 |    10 |
| argument splits                |     1 |      1 |     0 |

- **Performance is unchanged:**

| measure                      | funres vs base |
|------------------------------|---------------:|
| program allocation (geomean) |         +0.00% |
| object code (text)           |         +0.07% |
| compiler allocation          |         +0.17% |

- **The splits that happen:** results in `pretty`, `scs`, `hpg`, `anna`
  (and `fem` at final); the one argument split is `StateX.thenSX` in
  `real/infer`.
- **Rejection reasons at pre-ww:**

| reason                                     | functions |
|--------------------------------------------|----------:|
| argument: the parameter is not only called |       270 |
| argument: small (inlined whole)            |       174 |
| argument: not given known functions        |       156 |
| result: a tail is a call                   |        83 |
| result: nothing to gain                    |        80 |
| result: a tail is a local variable         |        79 |
| result: small                              |        70 |

  Handling type parameters moved 252 functions on to these later checks;
  calls of split functions found nothing new.
- **`real/symalg`** hit a loop in the statistics (fixed in `b1d3210493`,
  test `wwhostats001`) and was rerun alone; the original logs are kept as
  `ww-bench/results/*/nofib.log.orig`. Previous runs are in
  `ww-bench/results-run1` and `results-run2`.

## What is left to do

1. **Push** the commits after `5d4c77536d` when the user asks.
2. **Remaining big rejection pools:**
   - "parameter not only called": includes recursive functions passing the
     parameter on (`wwhoarg008`). The recursive call could pass the
     converted `g'`.
   - "result tail is a local variable": continuation parameters. Needs the
     argument and result conversions combined.
   - "small": by design.
3. Type parameters *after* value parameters (argument split).
4. Calls of *other* functions in result tails, beyond result-split wrappers.
5. **An interaction to keep in mind:** the eta-expansion rule (EtaFirst)
   assumes GHC will eta-expand, which it does not under `-fpedantic-bottoms`
   with a bottoming branch (found in `wwcast002`).
6. **Before proposing upstream:** measure runtime (`NoFibRuns=5` on a quiet
   machine); the timings on this machine are unreliable. Also measure
   compile time, and run the full testsuite (not just the smoke subset)
   with the flag on.
7. **Housekeeping:** `build-setup.log` and the `ww-bench/results*`
   directories are untracked or ignored.

## Related work on the `webs` branch (`~/projects/ghc-webs`)

That branch implements the webs paper (Quiring, Van Horn, Reppy, Shivers,
PLDI 2025) in GHC. It has web-based dead parameters, uncurrying, arity
raising, strictness, result raising, constant propagation and super-beta
inlining. There are nofib experiments in `WEBS-EXPERIMENTS.md`, and
`WEBS-WW.md` frames web passes as worker/wrapper. Its `PLAN.md` and
`CLAUDE-PLAN.md` are the webs plans; this file is only for `ww-higher-order`.
