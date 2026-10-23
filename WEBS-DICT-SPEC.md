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
  happy's `lookup` (−42% oracle). Step A applies to it unchanged.
