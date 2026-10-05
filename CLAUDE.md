# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a GHC source tree: a git **worktree** of `~/projects/ghc-webs` on
branch `ww-higher-order`, which extends GHC's worker/wrapper through
returned and passed functions. **Read `PLAN.md` first**: it has the current
status, the key decisions and what is left. `WW-HIGHER-ORDER.md` is the
design, and `WORKING-THE-WORKER-WRAPPER.md` the user's original examples.
The `webs` branch (in `~/projects/ghc-webs`, with its own build) is separate
work; do not mix the two.

## Build

```sh
./hadrian/build -j20 --flavour=quick --freeze1 stage2:exe:ghc-bin
```

- The compiler under test is `_build/stage1/bin/ghc`: the stage-2 compiler,
  despite the path. `--freeze1` keeps the stage-1 compiler, so only stage 2
  is rebuilt after a compiler change (a few minutes).
- A from-scratch build (`./boot && ./configure` then the command above
  without `--freeze1`) takes about an hour.
- Warnings in compiler code are not errors in the `quick` flavour, but keep
  new code warning-free.
- The tree uses `GHC.Prelude`:
  - partial functions such as `head`, `minimum` and `foldr1` on lists are
    rejected;
  - you cannot define `Semigroup` instances with `<>` (write plain functions
    instead);
  - many names need explicit imports (`eqType` from
    `GHC.Core.TyCo.Compare`, `Scaled(..)` from `GHC.Core.Multiplicity`, ...).

## Tests

```sh
./hadrian/build -j20 --flavour=quick --freeze1 test --test-root-dirs=testsuite/tests/dmdanal      # a directory
./hadrian/build -j20 --flavour=quick --freeze1 test --test-root-dirs=testsuite/tests/dmdanal --only=wwfunres001
./hadrian/build ... test --only=NAME --test-accept                                                 # record expected output
EXTRA_HC_OPTS="-fworker-wrapper-function-results -dcore-lint" ./hadrian/build ... test ...          # every test with the flag on
```

- Results are in the `SUMMARY` section of the output. Failures are listed as
  `/tmp/ghctest-.../NAME.run NAME [reason] (way)`.
- Tests are declared in `all.T` files (Python): `compile`,
  `compile_and_run`, `multimod_compile[_and_run]` (with
  `extra_files([...])`), `makefile_test`.
  - **Never name a loop variable `t` in an `all.T`.** It shadows the
    driver's global `t`, and the whole directory fails with
    `AttributeError: 'str' object has no attribute 'metrics'`.
- Expected output: `NAME.stdout` and `NAME.stderr`. Core dumps go to stderr.
  - Dump tests use `grep_errmsg(regex)`, which filters both the expected and
    the actual output before comparing. After `--test-accept`, filter the
    accepted `.stderr` down to the matching lines so it stays readable.
  - Take a runtime test's expected output from a plain GHC run (without the
    new flag), so the test checks that the transformation does not change
    meaning.
- **Quick manual check**, outside the testsuite:
  ```sh
  _build/stage1/bin/ghc -O -dcore-lint -fworker-wrapper-function-results \
    -ddump-simpl -dsuppress-all -dsuppress-uniques -ddump-to-file \
    -outputdir /tmp/x X.hs
  ```
  - Useful dumps: `-ddump-worker-wrapper` (output of the worker/wrapper
    pass), `-ddump-dmdanal` (its input, with demands), and
    `-ddump-ww-ho-stats` (statistics; see below).
  - **A small single-module example is usually inlined whole by GHC**, so
    nothing is split. Keep functions out of line with more than one caller,
    a separate module, or a large body. Don't use `NOINLINE`, since the
    split skips `NOINLINE` functions.
- `PLAN.md` has the "smoke" set of test directories, about 3,000 tests,
  used as a regression check with the flag on everywhere.

## nofib benchmarks

`ww-bench/run-all.sh` runs nofib (in the `nofib/` submodule) twice:
- `base`: plain GHC;
- `funres`: with `-fworker-wrapper-function-results`.

It takes about 2 hours, and writes `ww-bench/results/report.md` (counts,
rejection reasons, allocation, code size; via `ww-bench/report.py`).
- **Never rebuild the compiler while nofib runs**: it uses
  `_build/stage1/bin/ghc` directly. Stop every process of a run before
  rebuilding: `pkill` alone missed child `make` processes once.
- Run times are unreliable on this machine; compare allocation and size only.
- Disk space on `/home` is tight. Check `df` before large builds.

## Architecture (the parts this branch touches)

- **The Core optimisation pipeline** is `getCoreToDo` in
  `compiler/GHC/Core/Opt/Pipeline.hs`, and `doCorePass` runs each
  `CoreToDo` (constructors in `GHC/Core/Opt/Pipeline/Types.hs`, dump flag
  per pass in `GHC/Driver/Config/Core/Lint.hs`).
  - Order: gentle simplifier, specialise, float out, the main simplifier
    phases, float in, call arity, then **demand analysis → CPR analysis →
    worker/wrapper** (`dmd_cpr_ww`), then more simplification, SpecConstr,
    and the final demand analysis.
  - The statistics pass `CoreDoHoStats` runs at `early` (before the main
    simplifier), `pre-ww` (right after demand analysis) and `final`.
- **Demand analysis** (`GHC/Core/Opt/DmdAnal.hs`, types in
  `GHC/Types/Demand.hs`) annotates binders. Two traps:
  - A function's `DmdSig` covers only its arity (Note [Demand signatures are
    computed for a threshold arity]).
  - Demand information lives on **binders, not occurrences**: an occurrence
    `Var f` does not carry `f`'s signature or a new unfolding. Look up the
    binder; this branch threads `IdEnv`s and `wo_fr_wrappers` for that.
- **Worker/wrapper:**
  - `GHC/Core/Opt/WorkWrap.hs` decides what to split (`wwTopBinds` →
    `wwBind` → `tryWW`).
  - `GHC/Core/Opt/WorkWrap/Utils.hs` builds splits: `mkWwBodies`, given
    arguments carrying demand info, returns a wrapper builder
    (`Id -> CoreExpr`) and a worker builder (`CoreExpr -> CoreExpr`), reused
    here for the inner functions.
  - Options come in `WwOpts`, filled from `DynFlags` in
    `GHC/Driver/Config/Core/Opt/WorkWrap.hs`.
- **This branch's code** is almost entirely in `WorkWrap.hs`:
  `splitHigherOrder` (from `tryWW`) tries argument splits, then result
  splits, then the ordinary `splitFun`.
  - The design and every subtle rule are in its Notes: [Worker/wrapper for
    function results], [Worker/wrapper for function arguments] and
    [Higher-order worker/wrapper statistics]. Each sub-point is labelled
    (Depth), (Casts), (Demands), (Calls), (LetOrCase), (EtaFirst), (Small),
    (Boxity), (BoringOk), (TypeParams), and has a test, often found by a bug.
  - Flags: `-fworker-wrapper-function-results` (`Opt_WorkerWrapperFunResults`)
    and `-ddump-ww-ho-stats`, in `GHC/Driver/Flags.hs` and `Session.hs`.
- **GHC conventions:** long comments are `Note [Title]` blocks, referenced
  as "See Note [Title]". Add a Note for any non-obvious rule, and keep the
  label in the code next to it.

## Working conventions with the user

- Commit at milestones, with messages that explain the why. End commit
  messages with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Push only when asked. The remote is `origin`
  (github.com/bquiring/ghc-webs).
- **Every split must preserve laziness exactly**, except where
  `-fpedantic-bottoms` governs. New rules get a runtime test that fails if
  laziness or sharing is mishandled: `undefined` arguments, `Debug.Trace`
  counts, `seq` on partial applications. Mutation-check the test when it
  matters, by breaking the rule, rebuilding and confirming the test fails.
