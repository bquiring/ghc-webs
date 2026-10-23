# Webs: bounded dictionary specialisation

Proposal 3 of the Hackage profiles (WEBS-BACKLOG.md, "Proposals from the
Hackage profiles"): specialise on dictionaries where few dictionaries reach a
parameter, and keep the gain of GHC's aggressive settings at a bounded cost.

## 1. What we know (2026-10-23)

- **The gain is there.** `-fspecialise-aggressively -fexpose-all-unfoldings`
  (agg22): futhark −34.2%, purs −33.7%, skylighting −26.0%, alex −12.5%,
  cabal −5.7% instructions (WEBS-EXPERIMENTS.md §34).
- **So is the cost.** Text +10 to +39% (futhark +39%, cabal +19%), purs
  needs 8.8 GB to compile.
- **Webs add nothing on top today** (wagg22 −10.1% vs agg22 −10.4%).
- **GHC's Specialise runs first.** It runs before the early web pass
  (Core/Opt/Pipeline.hs: Specialise at :235, `CoreDoWebs True` after
  demand analysis), so by the time webs run, every call with a constant
  dictionary and a visible unfolding has been specialised already. This is
  why `-fcore-webs-split-classes` found nothing (WEBS-CHUNKS.md §3.2j).
- **Constant specialisation cannot take dictionaries today.**
  `ConstSpec.fun_param` excludes `isDictId` (ConstSpec.hs:253), `calledIn`
  wants a called parameter, `knownFun` rejects saturated DFun
  applications, and candidates are only the module's own top-level
  bindings (no imported unfoldings).
- **Where agg's gain comes from: imported unfoldings.**
  `canSpecImport` (Specialise.hs:899) takes an imported function only if it
  has an INLINE/INLINABLE pragma, or anything with an unfolding under
  `-fspecialise-aggressively`. With `-fexpose-all-unfoldings` on every
  package, that is every function. Specialise makes one copy per distinct
  call pattern, without a bound.

So the question for webs is not how to specialise on dictionaries (GHC does
that), but **which** specialisations to make. The design follows from
that.

## 2. Design: bound what Specialise makes, in two steps

**Step A: a bound without webs (the baseline for webs to beat).**
Keep `-fexpose-all-unfoldings` (on the program and its dependencies). Make
`-fspecialise-aggressively` selective in `canSpecImport` and for local
overloaded functions:
- at most N distinct call patterns per function per module
  (`-fspecialise-max-keys=N`, like `-fcore-webs-spec-max-keys`);
- only unfoldings up to a size (`-fspecialise-max-size=S`).

If A keeps most of agg's gain at much less code, the bound is the
contribution, and webs only need to justify it (step B). If A loses the
gain, the gain sits in many-key or large functions, and webs must say
which of those are worth it.

**Step B: webs choose.** Per overloaded function, a web summary decides:
- **how many dictionaries reach each dictionary parameter** in the
  whole module, through parameters, data fields and returns (data webs
  with `-fcore-webs-split-classes` give the classes; a new producer set per
  class gives the values: DFun applications and global dictionary Ids,
  with their types);
- **whether the dictionary is used at a hot call:** a selector applied
  inside a loop (webs' `calledIn`/`callSites` notion).

Specialise then admits a call pattern only if the parameter's class has at
most N producers and the selector use is called in a loop. This is the
flow-directed part: Specialise's own call patterns see only constant
dictionaries at call sites, while webs also see dictionaries stored in
records (mtl-style, `ASTMapper`) and passed through local functions.

## 3. First steps

1. **Measure where agg's code goes.** Per configuration, count the
   specialisations Specialise makes per function (RULES "SPEC" in
   `-ddump-spec` or the interfaces) and their size, on alex, skylighting,
   futhark and cabal. If a few functions with many keys make most of the
   growth, step A works.
2. **Step A** behind two flags, off by default; tests in
   testsuite/tests/webs (a module with a function called at 1 and at 6
   dictionaries, checking which copies exist).
3. Measure A on the small, large and compilers groups (allocation and
   time on the desktop; instructions with `time-nofib.py --cachegrind`
   style counting for Hackage, or on the laptop).
4. Step B, if A leaves gain on the table or the bound needs a reason.

## 4. Open questions

- Should the early web pass move before Specialise, so that webs see the
  dictionaries GHC removes? That costs the web pass's position after
  demand analysis, which strictness and result raising rely on.
- Proposal 8 (boot libraries with exposed unfoldings) is needed for
  happy's `lookup`: measured −31.4% with agg (§5). Step A applies to it
  unchanged.

## 5. What the laptop runs add (2026-10-23)

Instruction counts (perf), WEBS-EXPERIMENTS.md §36; scripts
`run-p8.sh` and `run-p8b.sh` (hb).

**None of the gains so far are webs'.** base, agg and the xu
configurations all run without the webs pass; with webs on top of agg
(wagg22), the result is unchanged. Every gain measured for proposals 3 and
8 is GHC's Specialise given more unfoldings. Webs' contribution has to be
what this document is about: which copies to make, at what cost, plus
anything webs can do to the copies afterwards (below).

**agg is four flags on top of -O2,** applied to every package cabal
builds:
- `-fspecialise-aggressively`;
- `-fexpose-all-unfoldings`;
- `-fspec-constr-count=6`;
- `-fspec-constr-threshold=4000`.

It is not yet measured which of them matters. The SpecConstr pair came
from a request for a stronger baseline, not from this work. A run with
only the first two settles it, and is worth doing before step A.

**Proposal 8 (boot libraries with exposed unfoldings).** A second compiler
tree, `_build-xu`, built with `-fexpose-all-unfoldings` for the stage-1
user libraries, in its own store `store-xu`. Instructions against base:

| | agg | xu-base (exposure, -O2) | xu-agg (exposure + agg) |
|---|---|---|---|
| happy | 0 | 0 | −31.4% |
| cabal | −4.9% | 0 | −6.8% (allocation −10.2%) |
| purs | −34.0% | 0 | −34.8% |
| futhark, skylighting, alex, koka, cpphs | as xu-agg | 0 | unchanged from agg |

- **Exposure without specialisation gives exactly 0.** Default -O2
  specialises only INLINABLE imports and does not inline recursive
  functions.
- **Only programs whose time is in boot code gain:** happy (`lookup`) and
  cabal (Cabal-syntax's and parsec's parsers). So step A/B must also
  cover imports from boot packages: the bound cannot assume that hot
  copies come from the program's own packages.
- **Compile memory grows:** purs with xu-agg needs 9.9 GB max RSS (it ran
  out at a 14 GB virtual limit; it builds with `BENCH_JOBS=1
  BENCH_ULIMIT=18000000`). agg needed 8.8 GB. Breadth costs memory as
  well as text.

**A candidate webs win on top of Specialise: the copies' static
arguments.**
- happy with xu-agg spends 13.5G instructions in `$slookup` (First.lhs),
  Specialise's `Int` copy of base's `lookup`.
- The hand-written oracle inlined a local `lookup` into mkFirst's loop,
  with the key free and unboxed once: 9.6G.
- The copy takes the key as an argument and unboxes it on every element.
  It is lazy in the key (the empty list), so worker/wrapper does not
  unbox it.
- The 3.9G difference is the whole gap between −31.4% and the oracle's
  −42.3%.
- The early web pass runs after Specialise, so webs see the copies. A
  web transformation that hoists a self-recursive function's unchanging
  arguments (arity raising's machinery, or the static argument
  transformation applied to Specialise's output) would get it.
- The same pattern (overloaded recursive search or fold, specialised,
  with a constant argument) is likely in other copies. Before building
  it, count how often it occurs.

**Where the gain sits, for step B.** perf attributes instructions to
symbols, so the laptop can measure which copies (`$s…` symbols) carry
agg's gain in each program. That gives an oracle bound for step B: how
much of the gain the top N hot copies give. Combined with §35's breadth
result (1214 copies, mostly cold), this is the number that says how
small a use-based bound can be. Not yet run.

**Infrastructure, if the desktop reproduces these runs:**
- `_build-xu/hadrian.settings`: `_build`'s two `-O1` lines, plus
  `stage1.P.ghc.hs.opts += -fexpose-all-unfoldings` for each P of:
  array base binary bytestring Cabal Cabal-syntax containers deepseq
  directory exceptions file-io filepath ghc-bignum ghc-boot-th
  ghc-internal ghc-prim haskeline integer-gmp mtl os-string parsec pretty
  process stm template-haskell text time transformers unix.
- Build: `hadrian/build -j4 --flavour=devel2 --build-root=_build-xu`
  (22 minutes on the laptop).
- The tree's boot packages have the same unit ids as `_build`'s, so its
  Hackage builds need their own store. `BENCH_STORE=store-xu ./build.sh
  NAME OPTS`, with `with-compiler: …/_build-xu/stage1/bin/ghc` in
  `NAME.extra`.
- build.sh records each configuration's store in `results/NAME/store`,
  and time.py and trace-apply read it, so one timing run can mix stores.
  Before this fix, a configuration from another store silently ran the
  wrong binary: run time.py from webs-hackage-bench `e60d77d` or later.

**Measurement split:**
- the desktop (WSL2): builds, tests, time, allocation and cachegrind;
- the laptop: perf instruction counts and the per-symbol profiles
  (profile.py, trace-apply.py).

Docker's data root is on the laptop's /home; check `docker system df`
when the disk fills.

