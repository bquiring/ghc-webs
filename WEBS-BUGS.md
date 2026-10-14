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

* **hpg +3.0% instructions with the boundary split for every exported
  function** (2026-10-10, `early-bnd3` against `early-bm`, WEBS-EXPERIMENTS.md
  §14; also veritas +0.8%). hpg is continuation-passing; its exported
  combinators (`choose`, `choosew`, `extend_type_env`, ...) are split and
  kept, and their continuation parameters eta-expanded in the wrappers.
  Without defunctionalisation +6.1%, so the cost is in the split itself.
  Next: an ablation flag for the parameter eta-expansion, then ticky.

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

### Type synonyms kept their types' fields exposed: constraints +15% (2026-10-13)
* **Found by:** comparing the fixed baseline (`early-ulsl2`, after the list
  fix below) per benchmark against `early-ulsl`: the only loss of ≥0.5%
  instructions, spectral/constraints +14.9%.
* **Symptom:** five more webs exposed (`eta` lambdas of CSP's fields), so
  inlining, useless elimination and arity raising skipped them, and data
  splitting's second pass no longer split CSP.
* **Cause:** 0fd07f955a (uniplate's Zipper) marks as Referenced, with
  their fields exposed, the types reachable from a local type that cannot
  be rebuilt, a family instance, or a type synonym's right-hand side.
  constraints' synonyms (`type Labeler = CSP -> ...`) mention CSP.  The
  synonym clause is not needed: the rewrite expands every use of a synonym
  that mentions a rebuilt type (mapTyCons), and tyConsOfType (fieldTyCons)
  sees through synonyms, so data and class fields that use one are already
  covered.  Found by bisecting with compiler/GHC/WebCore checked out per
  commit.
* **Fix:** drop the synonym clause (classifyTyCon in GHC.WebCore.Pipeline).
* **Guard:** `hfield006` (a hidden-field type behind two synonyms, every
  data-split mode; `_stats` checks it stays internal); hfield005 still
  covers Zipper.
* **Commit:** `ec8e62c538`

### Data splitting never split lists in a program with IO (2026-10-13)
* **Found by:** nofib after the reporting audit: `early-ulsl2` (early-ulsl's
  options, current compiler) −2.93% instructions against base where
  `early-ulsl` (built 2026-10-11 01:47) had −4.49%; integer (−74%) and
  queens (−20%) lost everything, cryptarithm2, typecheck and constraints
  most.
* **Symptom:** in queens, every class exposed and nothing split (before:
  the list split, specialised to Int and unboxed).
* **Cause:** Note [Types used as kinds] (6ce8c6716c, ten minutes after
  early-ulsl was built, for pretty-show) excluded a type that occurs in some
  type next to one of its own promoted constructors.  An unboxed tuple's
  hidden representation arguments count: getArgs's (# State# RealWorld,
  [String] #) has the representation TupleRep '[], so [] was "used as a
  kind" in every program with IO, and lists were never copied.
* **Fix:** a type is used as a kind if it is in a type variable's kind or in
  a dependent (named) argument of a type constructor (SingI's kind argument
  in pretty-show's case, a promoted constructor's kind argument); the
  -ddump-webs-data dump lists the copyable types left out, with a witness
  type under -dppr-debug.
* **Guard:** `datasplit009` (a list split in a program with IO);
  `datasplit005` still checks pretty-show's case.  Every nofib and Hackage
  result with data splitting since 2026-10-11 has lists unsplit:
  WEBS-EXPERIMENTS.md figures from early-ulsl builds after that date, and
  the Hackage groups' configurations with data splitting, need a rerun
  (`nods` has none).
* **Commit:** `29cd822b48`

### Flattening: an absent call demand on a function component (2026-10-14)
* **Found by:** the compilers group with data splitting (`ulsl2`, after the
  newtype fix below): "ASSERT failed!" in GHC.Types.Demand (mkCall,
  cardinality A), building futhark's Language.Futhark.TypeChecker.Terms.
  The debug stage 2 compiler checks assertions; a release compiler would
  have built a call demand with an absent cardinality.
* **Cause:** when a field is flattened, its components' demands are
  rewritten (fix_sd). A function component that is only evaluated has the
  demand 1A (seq: absent below). viewCall reads that sub-demand as a call
  with cardinality A, and fix_sd rebuilt it with mkCall, which takes no
  absent cardinality.
* **Fix:** an absent call is left as it is, as reshapeUsage in
  GHC.WebCore.Transform.Common already does.
* **Guard:** `dataunbox012` (a nested pair whose function component is only
  seq'd; the assertion fires without the fix).
* **Commit:**

### Useful splits: a newtype class reverted while its newtype child stayed split (2026-10-14)
* **Found by:** the compilers group with data splitting (`ulsl2`): Web Lint
  after annotation failed in futhark's Language.Futhark.TypeChecker.Unify,
  with a TransCo mismatch between `ExceptT_s136` and ExceptT, under
  `Sym N:UnifyM`. (Data Lint's pairs give the same classes and the same
  error, so the inference is not involved.)
* **Cause:** in the useful-splits pass, a newtype class is kept if one of
  its children's classes is useful. The useful set has data classes only,
  but a child is often a newtype itself: ExceptT inside the local UnifyM,
  kept for the Either inside it. UnifyM's class went back to the original,
  whose axiom names the original ExceptT, while its ExceptT copy stayed
  split.
* **Fix:** the kept classes are closed transitively: every newtype class
  with a kept child's class is kept (Note [Keeping only useful splits] in
  GHC.WebCore.DataSplit).
* **Guard:** `datasplit011` and `datasplit011_again`: a local newtype U
  over a newtype E over an Either that is only built with Right. Lint
  error before the fix.
* **Commit:** `ccc9e17218`

### Specialising a split type: a coercion through a variable under an arrow (2026-10-14)
* **Found by:** the Hackage root group rebuilt after the list and unfolding
  fixes (`ulsl2`, -O1 compiler): GHC panicked in vector-algorithms 0.9.1.0,
  Data.Vector.Algorithms.Tim, with "specialiseSplit: pattern variable not in
  pattern". (The earlier ulsl builds had never split lists in programs with
  IO, so they never got this far.)
* **Cause:** specialisation rebuilds a coercion T cos through a specialised
  T' by selecting each pattern variable's coercion out of cos along its
  path in the pattern (var_co). The path is followed through type
  constructor applications only. A pattern such as (b -> c, Int) has its
  variables only under an arrow, so it has no path, and the panic followed.
* **Fix:** a split type that heads a TyConAppCo in the program is
  specialised only if every pattern variable lies on such a path (Note
  [Specialising split types] in GHC.WebCore.DataSpec). Without such a
  coercion it is still specialised, which is what makes its Int field
  concrete for unboxing. No nofib module had the case (all of them built),
  so nofib is unchanged.
* **Guard:** `dataspec001` (a split pair at (Int -> Age, Int), coerced to
  (Int -> Int, Int)), which panicked before the fix.
* **Commit:** `3297d377ac`

### Worker/wrapper split small functions whose unfoldings webs had zapped; importers grew 37x (2026-10-14)
* **Found by:** step 0 of the data-splitting redesign (WEBS-DATA.md
  section 11). GHC.CmmToLlvm.CodeGen took 66 s against the nods build's
  interfaces, but over 18 minutes against the ulsl build's. The source
  desugars to 11.4k terms either way, but against ulsl's interfaces the
  simplifier grows it from 29k to 810k terms in one iteration (34,349
  inlinings of appOL against 165). Webs off in the importing module gives
  the same. Taking GHC.CmmToLlvm.Base's interface alone from ulsl gives the
  same; its LlvmM actions (getConfig1, $fMonadLlvmM1, ...) have wrappers
  (Inline: [2], boring_ok=False) instead of always-inline stable unfoldings:
  50 wrappers with data splitting, 21 without (and in base).
* **Cause:** the early run zaps vanilla unfoldings and leaves the
  simplifier to rebuild them. Data splitting zaps every binder it does not
  pin; the transformations zap those whose types they change (Note
  [Unfoldings and rules after a transformation]). But CPR analysis and
  worker/wrapper run before the simplifier, and worker/wrapper's
  certainlyWillInline needs an unfolding. A small function that would
  have kept a stable "always inline" unfolding was split instead. Its
  wrapper is active only from phase 2 and is not inlined in boring
  contexts, which changed how the LlvmM code inlined into CodeGen.
* **Fix:** at the end of the early run, every let-bound function (arity >
  0, or a join point) that had a vanilla unfolding before it and has none
  now gets one, built from its final right-hand side (mkUnfolding, as the
  simplifier would): Note [Restoring vanilla unfoldings] in
  GHC.WebCore.Pipeline. Base then has 20 wrappers, and CodeGen against it
  has 26,928 terms, as against the nods build's.
* **On the way:** restoring arity-0 binders too broke CPR analysis's
  assertion that a binder and its occurrences agree on whether it is a
  data structure (13 tests: dsedge022/026/029, poison037, useless018).
  CPR analysis reads a data structure's unfolding at its occurrences, and
  those still carry the old Id. Synchronising the occurrences does not help,
  because substitution drops vanilla unfoldings. Worker/wrapper's
  certainlyWillInline needs arity > 0 anyway.
* **Guard:** `datasplit010` (a state monad whose small methods got
  wrappers, plus a split list); `datasplit010_wrappers` greps -ddump-simpl
  for wrappers of the methods and expects none (six before the fix).
* **nofib** (`early-ulsl4` against `early-ulsl`, instructions): 108 of 109
  benchmarks within 0.5% (104 within 0.1%), geomean -4.17% against -4.19%.
  integrate is +2.9% (-76.40% against base instead of -77.07%):
  `integrate1D` keeps its unfolding now and becomes no wrapper, and -O2's
  specialisation then makes a large specialised copy of its worker (1,218
  terms to 2,151). That is what GHC does with it without webs.
  Reproduced with -fcore-webs-no-restore-unfoldings (1,247.6M against
  1,284.6M instructions). Kept: the fix is right, and the cost is GHC's
  heuristic on one function. Compiler allocation: +112% against base,
  from +145%.
* **Also:** every data-splitting measurement so far carries this effect:
  nofib's early-ulsl and early-ulsl3, the Hackage, large and SML groups
  (WEBS-EXPERIMENTS.md §16-§19), and the step 0 timings of CodeGen
  (measured against nods' interfaces, so not affected) and the earlier
  CodeGen out-of-memory runs (affected: that was this bug). The
  transformations' zaps, without data splitting, can do the same on a
  smaller scale.
* **Commit:** `bff0d10243`

### Data splitting: the "useful splits" pass kept the first pass alive (2026-10-14)
* **Found by:** the self-host build (early-ulsl, after the list fix
  `29cd822b48`): `ghc: out of memory` in GHC.CmmToLlvm.CodeGen (992k terms),
  which had compiled when lists were not split. Compiled alone with -M16g:
  the first splitting pass finished (614 s, 1.5 TB allocated), then the
  second ("useful splits") ran out of the 16 GB heap.
* **Cause:** `runDataSplit` passed `dsr_useful res0` to the second pass as
  a thunk. Until the second pass forced it, the thunk kept the whole first
  result alive: its annotated program, Data Lint's result and the dump.
* **Fix:** `dsr_changed` and the list of useful classes are forced before
  the second pass starts, so only they survive it. The same module then
  finishes both passes (523 s and 547 s; Note [Keeping only useful
  splits]). -dshow-passes now also times each step of splitting
  (annotation, Data Lint, solving, rewriting, specialising), and the
  -ddump-webs-data stats line counts the constructors behind the copies.
* **Guard:** none automatic (memory on a 1M-term module).
* **Also:** CodeGen had 992k terms only because of the unfolding bug above
  (the importers' 37x growth); without it CodeGen has 27k terms, and its
  two splitting passes take 12 s and 10 s. The leak is real, but it took
  that program to show it.
* **Commit:** `3f0c024f91`

### Data splitting: quadratic list code; GHC.Tc.Errors.Types takes an hour (2026-10-13)
* **Found by:** the self-host build (OPEN entry below), profiled alone: 63
  minutes, 2.0 GB maximum residency, 77% of the time in GC; ~3,100 s in the
  untimed data-splitting passes.
* **Cause:** list operations that grow with the number of copies and
  classes: each class's members appended to (`old ++ [x]` under a lazy
  foldl), the pairs from casts looked up in a list per Data Lint pair,
  `split_us !! n` per class, class numbers and reachable types in lists;
  in DataFlatten a list lookup of every constructor's size per candidate
  field and a closure that rescanned every type each round; in DataSpec a
  search with a list per type; origin lists appended per web in renaming.
* **Fix:** sets, maps and prepends; strict folds; one closure each over who
  mentions whom; -dshow-passes times both data-splitting passes.  The
  algorithms that are still superlinear are in WEBS-BACKLOG.md
  ("Superlinear algorithms left in the web passes").
* **Guard:** none automatic (compile time); `datasplit006` covers the
  2000-constructor case.
* **Commit:** `29cd822b48`

### Reporting audit: verdicts that fired without a change; script labels (2026-10-13)
* **Found by:** an audit of the dumps and the benchmark scripts, after the
  exposure-statistics bug below.
* **Symptoms and causes:**
  - Strictness printed "strict argument" or "strict result fields" for every
    web the analysis proved strict, and marked it changed, even when the
    rewrite edited nothing (the arguments already values, or passed by
    value by demand analysis).  On the compilers group this was 25% of webs
    "fired".
  - Constant propagation counted a constant argument for a parameter that
    is never used (on the compilers group, 458 of its 592: the `(##)`
    arguments of join points and thunks), and a constant result with no
    case on a call.
  - Inlining marked every candidate web changed when any call in the round
    was inlined.
  - FirstClass counted `(f |> co) x` and `(tick f) x` as unknown calls.
  - verdicts.py inferred firing from the verdict's first words; it now
    honours "no change", and verdicts.py and expo-report.py warn when a
    module's dump has more than one block (two builds into one directory).
  - time-nofib.py: "faster, backed by ≥0.5% fewer instructions" accepted
    any instruction change; the header's mode came from the environment,
    not from how the configuration was built (now recorded by run-nofib.sh;
    old configurations report "unknown").
  - poly-report.py classified `(a -> b) -> c` as parenthesised, not a
    function; report.py's baseline code-size total covered a different set
    of benchmarks; time.py's docstring named the wrong statistic.
  - The boundary-split statistic "Kept:" (splits not contracted) read as
    kept binders; now "Not contracted:".
* **Fix:** each pass records the webs it edited (Strictness: a StateT over
  the rewrite; Inline: the set of webs with an inlined call; ConstProp: only
  parameters that occur), and its dump marks only those changed, printing
  "(no change: reason)" otherwise.  Fire rates reported before this
  (WEBS-EXPERIMENTS.md tallies) overstate strictness, const-prop and inline.
  Timings are unaffected.
* **Guard:** the dump tests' expected output (strictness, const-prop and
  inline dumps).
* **Commit:** `e241d489e8`

### Statistics: every exposed class "joined with an arrow without a web"; defunctionalisation never counted as firing (2026-10-13)
* **Found by:** porting the exposure statistics (branch `exposure-stats`)
  and tallying the compilers group's dumps.
* **Symptom:** in `-ddump-webs-stats`, every exposed lambda class with more
  than one web had the origin "an arrow without a web" (100% of exposed
  classes on a small program that has no placeholder web), so few classes
  showed a single origin.  Separately, `webs-bench/verdicts.py` reported 0
  webs defunctionalised on nofib early-ulsl (there are 102).
* **Cause:** the origin was recorded for `ws_exposed_reps`, the
  representatives of every class with an exposed web, not just those with
  the placeholder web.  verdicts.py's list of verdicts that fire lacked
  "defunctionalised" (and "dead fields").
* **Fix:** record the origin only for the classes that contain
  placeholderWeb (GHC.WebCore.Pipeline, sigs2); add the verdicts.  The
  §13 figure "exported binders alone exposed 68%" (WEBS-EXPERIMENTS.md) came
  from the branch's counts; if it was a single-origin count, it was
  understated.
* **Guard:** none automatic (dump statistics); `boundary_kept001` checks
  the single-origin line.
* **Commit:** `a6f48e7819`

### Defunctionalisation and arity raising: an analysis list per arrow occurrence (2026-10-13)
* **Found by:** the compilers group, nods configuration:
  haskell-src-exts-1.24.0, Language.Haskell.Exts.InternalParser (happy's
  generated parser, 77k terms; Futhark needs it).
* **Symptom:** `ghc: out of memory` (4 GB, and still at 16 GB); a 13 GB peak
  with 40 GB allowed (base: 0.6 GB).  Defunctionalisation alone: 4.6 GB, and
  it defunctionalised nothing (20 s, 18 GB allocated); with the boundary
  split 8.9 GB.  The heap profile: 5.5 GB of list cells live.
* **Cause:** both analyses note every arrow of every type in the program,
  and kept a list element per occurrence until the verdicts: defunc the
  occurrence's type, its parent web and per call the head's web; arity
  raising the product type of the parameter.  Combined lazily, too (a chain
  of thunks per web).  Happy's action functions share internal webs whose
  arrows occur hundreds of millions of times.
* **Fix:** the verdicts read only counts, sets of webs, the distinct
  occurrence types (a TypeMap) and whether the product types agree (at most
  two kept), so Info keeps those, with strict fields and a strict note
  (Note [The size of the analysis] in GHC.WebCore.Transform.Defunc;
  GHC.WebCore.Transform.ArityRaise).  The module now peaks at 0.92 GB with
  every nods flag (281 MB live); defunctionalisation takes 0.6 s.
* **Guard:** the haskell-src-exts build (compilers group); the testsuite's
  defunc and arity-raising dumps are unchanged.  No small reproduction (a
  memory blowup on a 77k-term module).
* **Commit:** `4f6c501909`

### Useless elimination: changes that change nothing, until the round limit (2026-10-13)
* **Found by:** the compilers group, nods configuration (early-ulsl without
  data splitting, with -dcore-lint): Cabal-syntax-3.18.1.0,
  Language.Haskell.Extension (35k terms, 1.2 million type nodes from the
  Generic instance of its 140-constructor KnownExtension; base has the same
  size).  haskell-src-exts' Language.Haskell.Exts.Syntax failed the same
  way (not confirmed to be this bug).
* **Symptom:** `ghc: out of memory` (4 GB) with -dcore-lint; without it
  2:40 and a 2.3 GB peak (base: 0:45, 0.5 GB).  -dshow-passes (which now
  times each round) showed useless elimination running all ten rounds, each
  followed by a Web Lint check of the program (5 s, 18.7 GB allocated each).
* **Cause:** uselessRound reported a change whenever a pattern variable of a
  scrutinised construction was dead (dead_fields), whether or not the
  rewrite could do anything with it: (1) a field of a lifted constructor
  that cannot be filled (strict, or needs evaluation) or already was, in
  an earlier round; (2) a component of the projection the rewrite builds
  around a call whose result it cannot mask (adapt; here the primop
  unsafeFreezeArray#, its state token dead): the next round took the
  projection's dead component as a change and built the projection again.
  So the pass ran to its limit of ten rounds, rebuilding the same program.
* **Fix:** dead_fields keeps only pattern variables whose field some tail
  of the scrutinee builds fillable and not yet an absent filler
  (fillableTails), and skips projections (isProjection), in
  GHC.WebCore.Transform.Useless (scrutVars).  The module settles in two
  rounds: 1:29, 1.2 GB peak, and compiles with -dcore-lint.
* **Guard:** `useless_rounds001` (accumArray, as the module; two rounds) and
  `useless_rounds002` (a strict dead field and one that needs evaluation;
  one round); both ran ten rounds without the fix.
* **Commit:** `d241b19232`

### Data splitting was too slow and big for GHC's largest modules (2026-10-11, resolved 2026-10-14)
* **Update 2026-10-14 (later): resolved.** GHC builds with data splitting
  (self-host `ulsl`, early-ulsl's options with -dcore-webs-lint, the -O1
  stage 2 compiler, inference by default): phase 1 1,761 s, phase 2 710 s,
  no errors. The resulting GHC compiles anna, fluid and cacheprof to the
  same object files as base's GHC, and allocates 0.03-0.18% less. What
  fixed it: the unfolding bug (CodeGen's 37x growth), the space leak, the
  redesign steps 1a and 2 (WEBS-DATA.md section 11), and no longer
  measuring with an -O0 compiler.
* **Update 2026-10-14:** GHC.Tc.Errors.Types now compiles: after the list
  fixes (`29cd822b48`) it needs 2.4 GB of live heap and 6.1 GB in all, in
  1,003 s. The self-host runs with ulimit -v 10 GB at -j2. With lists split
  again (`29cd822b48`), GHC.CmmToLlvm.CodeGen ran out of memory: it had
  grown to 992k terms through the unfolding bug above. With that fixed it
  has 27k terms, and its two splitting passes take 12 s and 10 s.
  GHC.Tc.Errors.Types (6M type nodes) still spends 100 s per splitting
  pass and splits nothing. The self-host without data splitting (nods)
  builds GHC: phase 1 4,767 s against base's 2,796 s. Next: the redesign
  in WEBS-DATA.md section 11 (name-only copies, inference by unification,
  one pass with the webs), measured step by step first.

* **Found by:** building GHC with the webs compiler (early-ulsl,
  ~/projects/ghc-selfhost).
* **Symptom:** `ghc: out of memory` (4 GB) in the early webs run with
  -fcore-webs-data-split; -fcore-webs-early alone and every other pass fit
  (after the annotation fix below).  The module has 32k terms but 6.5 million
  type nodes counted as trees: the Generic representations of its large sums
  (:+: trees, built and matched by the derived from/to) repeated in every
  alternative's coercions.
* **Cause (partly known):** annotation copies :+: at every occurrence, and
  copies are expensive (a type constructor with constructors, and the types
  around it unshared): traces showed annotation itself reaching ~90,000
  copies before running out.  A cap of 40,000 copies (originals kept after
  it, which is sound) still ran out later in data splitting, so something
  after annotation (Data Lint over the unshared types?) is also too big.
* **Tried and dropped:** forcing Data Lint's recorded pairs (kept: harmless);
  making mapTyCons keep unchanged subtrees shared: did not help, and broke
  recweb/hfield/poison013 tests with an Int/Int# mismatch in a worker
  ($wwalkR), unexplained since the change should not alter any result.
* **Also:** ShellCheck.Parser (300k terms, parsec) runs out of 8 GB in data
  splitting (confirmed: it compiles with data splitting off, 1.3 GB, once the
  defunctionalisation fix below is in); pandoc's Text.Pandoc.Readers.LaTeX
  (parsec) runs out of 8 GB under early-ulsl, probably the same (not
  confirmed).
* **Workaround:** none in the compiler yet.  The self-host ulsl build stops
  at GHC.Tc.Errors.Types; the Hackage large group builds ShellCheck with
  data splitting off (large/ulsl.extra, not for benchmarking) and sets pandoc
  aside.  Deferred (the user: other benchmarks first; capping copies is a
  heuristic decision for the user).
* **Commit:** `56cae268d6` (partial)

### Data splitting: atomicModifyIORef's pair is read by the RTS (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl): GHC segfaulted
  compiling pandoc-types' Text.Pandoc.Definition, running aeson's
  deriveToJSON splices (aeson compiled with webs).  Bisected to aeson's
  Data.Aeson.Internal.TH, then reproduced without Template Haskell (letrecE
  run in IO).
* **Symptom:** segfault with -fcore-webs-data-split -fcore-webs-data-unbox;
  `absent error` abort with -fcore-webs-data-split -fcore-webs-useless.
  Data Lint and Core Lint pass: a miscompilation.
* **Cause:** letrecE records bindings with atomicModifyIORef ref (\m ->
  (Map.insert .., ())).  The pair is atomicModifyMutVar2#'s result type c,
  polymorphic in its signature, so splitting took it as parametric and split
  it.  But the RTS takes the IORef's new contents out of it with a selector
  thunk on its first field, a read no case shows: dead-field elimination
  dropped that field (useless elimination filled it with an absent error),
  and the IORef got () as its Map.
* **Fix:** atomicModifyMutVar2# is a non-parametric function: its type
  arguments keep their types (Note [Non-parametric functions] in
  GHC.WebCore.DataSplit).
* **Guard:** `datasplit007` (a memo table updated with atomicModifyIORef),
  `datasplit008` (aeson's letrecE), each with unboxing and with useless
  elimination; all four fail without the fix.
* **Also:** the ulsl store builds made before the fix (aeson and whatever
  else uses atomicModifyIORef this way) are miscompiled; cabal does not
  rebuild them by itself (same flags, same hash).
* **Commit:** `4623d859d3`

### Defunctionalisation: the analysis ran ShellCheck.Parser out of memory (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), ShellCheck-0.11.0,
  ShellCheck.Parser (300k terms after simplification, parsec throughout).
* **Symptom:** `ghc: out of memory` (8 GB) in the early webs pass, after
  strictness; with data splitting off too (data splitting also runs out on
  this module: the open entry above).  With defunctionalisation and data
  splitting off the module compiles at a 1.3 GB peak.
* **Cause:** the analysis recorded every occurrence of every web's arrow in
  every type, lazily appended per web, including the exposed webs of
  library signatures, which occur millions of times in a module like this
  and are rejected anyway.
* **Fix:** nothing is recorded for an exposed web, except its lambdas when
  -ddump-webs-defunc is on (its verdict is dumped).  The module's
  defunctionalisation now takes 2 s (13 webs), peak 1.33 GB with data
  splitting off.
* **Guard:** the ShellCheck build; the testsuite's defunc dumps are
  unchanged.  No small reproduction (a memory blowup on a 300k-term
  module).
* **Commit:** `b4bb78939d`

### Useless elimination: runRW# in a masked tail took its jumps out of tail position (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), http2-5.4.8,
  Network.HTTP2.H2.Receiver (needed by pandoc).
* **Symptom:** Web Lint after useless elimination: "Invalid occurrence of a
  join variable", and "Type of case alternatives not the same as the
  annotation on case" ((# State# RealWorld #) vs (# State# RealWorld, () #)).
* **Cause:** with -XStrict, Short.toShort's runRW# is evaluated before
  throwIO, and the simplifier moved the rest of the IO action, which jumps
  to a join point, into runRW#'s argument (Note [Simplification of runRW#]).
  The action's () result was dead, so the join point returned the masked
  tuple; the masked-tail rewrite treated the runRW# call as any other call
  and adapted it (case runRW# .. of (# a, _ #) -> (# a #)), which took it
  out of tail position and left its argument returning the old type.
* **Fix:** a runRW# call in a masked tail stays a tail: its argument's body
  is rewritten as the tail, and runRW# is instantiated at the masked type
  (Note [runRW# in a masked tail] in GHC.WebCore.Transform.Useless).
* **Guard:** `useless022` (a byte array built under runRW# in a strict
  field before throwIO; fails without the fix).
* **Commit:** `34aab1b77c`

### Defunctionalisation: lambdas that take class dictionaries (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), hpke-0.2.1,
  Crypto.HPKE.AEAD (needed by pandoc and hledger).
* **Symptom:** `ASSERT failed` in mkWebFunTy (arg `a4 :: Constraint`),
  called from mkVisFunTyMany in GHC.WebCore.Transform.Defunc.
* **Cause:** mkSealA takes a function polymorphic in its ByteArray types,
  and is called with three such functions; their web was defunctionalised
  (arity 8: four dictionaries, four arguments).  The apply function's type
  (and a lifted function's) was built with visible arrows, but a dictionary
  parameter needs a constraint arrow.
* **Fix:** build those arrows with mkFunctionType, which picks the arrow
  from the argument's kind.
* **Guard:** `defunc010`, `defunc010_lifted` (fail without the fix).
* **Commit:** `b0e5aafc16`

### Unboxing: a field mentioned only by a stable unfolding lost its binding (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), JuicyPixels-3.3.9,
  Codec.Picture.Gif.
* **Symptom:** Data Lint in the second data split (-fcore-webs-data-again):
  "The value variable n1 is out of scope ... In the unfolding of step1".
* **Cause:** vector's step1 (INLINE) has a stable unfolding that still
  mentions a stream size field n1, which its simplified right-hand side no
  longer does.  When the first run unboxed the field, DataFlatten's free
  variable walk (freeIds) did not look at let binders' unfoldings and rules,
  saw no use of n1, and did not rebind it.  Dead-field liveness had the
  same gap: such a field could be dropped, and inlining the unfolding later
  would reach the absent-error filler.
* **Fix:** both count the variables of a let binder's unfolding and rules.
* **Guard:** `dataunbox011` (a RULE active from phase 1 removes the use from
  the right-hand side but not from the unfolding; fails without the fix).
* **Commit:** `0dd375d78d`

### Constant propagation: a local binder with a top-level binder's unique (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), JuicyPixels-3.3.9,
  Codec.Picture.Bitmap.
* **Symptom:** Web Lint after constant propagation: "Mismatch in type
  between binder and occurrence: eta_B0 :: Word16 / eta_B0 ::
  IndexedBmpFormat", in a derived Show function.
* **Cause:** GHC's eta expansion names binders eta_B0, eta_B1, ...; one
  became a top-level `eta_B0 :: Word16`, and local lambdas elsewhere were
  also eta_B0.  isConstant accepted any variable whose unique was in the
  top-level set, so a local eta_B0 passed to showsPrec counted as the
  top-level constant, and the parameter was replaced by it.  The rewrite
  also substituted under binders that shadow the parameter or the
  constant's variable.
* **Fix:** the analysis tracks local binders in scope (a variable is a
  top-level constant only if none shadows it); the rewrite does not
  substitute under a binder that shadows the parameter or the constant's
  variable (Note [Constants and shadowing] in
  GHC.WebCore.Transform.ConstProp).
* **Guard:** the JuicyPixels build; no small reproduction (the collision
  comes from GHC's earlier passes on vector code).  Testsuite dumps
  unchanged.
* **Commit:** `0dd375d78d`

### Dead fields: a coercion bound by a match on Refl counted as unused (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), JuicyPixels-3.3.9,
  Codec.Picture.Metadata.
* **Symptom:** Web Lint after annotation: "The coercion variable co is out
  of scope", in `lookup`'s `Just Refl -> Just v`.
* **Cause:** keyEq's `Maybe (a :~: b)` was specialised to `Maybe_s a b`, and
  dead-field elimination dropped Just's field: the only use of its pattern
  variable was a case on Refl whose binder, a coercion variable, occurred
  only in a cast (`v |> co`).  The liveness walk (DataFlatten `live`) saw
  occurrences in expressions only, not in coercions or types.
* **Fix:** coercion variables free in a cast's coercion, a coercion or type
  argument, or a case's result type are live.
* **Guard:** `dataunbox010` (a copy of the module; fails without the fix).
* **Commit:** `0fd07f955a`

### Rebuilt hidden-field types: types that mention them keep the old ones (2026-10-11)
* **Found by:** the large Hackage group (early-ulsl), uniplate-1.6.13,
  Data.Generics.Uniplate.Zipper (needed by pandoc).
* **Symptom:** Core Lint after the Simplifier, in worker/wrapper's `$wup`:
  "Result binder in case doesn't match scrutinee" (`[Str to -> (# [Diff1 to],
  to #)]` vs `[Str to -> Zip1 to]`).  Needs only -fcore-webs-early and
  -fcore-webs-result-raise.
* **Cause:** result raising raised the function web in local ZipN's field,
  and ZipN was rebuilt in place (new TyCon, same unique).  Zipper (exported
  abstractly) mentions ZipN in a field and was not rebuilt, so it pointed at
  the old ZipN object; worker/wrapper unboxed a Zipper argument through it
  and read the old field types.  The third case of "old and rebuilt types".
* **Fix:** rebuildHiddenTypes also rebuilds, transitively, every local data
  type that can be rebuilt in place (rebuildableTyCon) and mentions a
  rebuilt type, and points stable and DFun unfoldings at the rebuilt types.
  Types reached from a local type that cannot be rebuilt (newtype, class,
  wrapper, existential, family instance), a type synonym or a family
  instance keep their fields exposed (new class `Referenced`).  Note
  [Signatures follow the transformations] in GHC.WebCore.HiddenFields.
* **Guard:** `hfield005` (every dsedge mode, plus result raising alone;
  fails without the fix).
* **Performance:** `Referenced` can only expose fields that were hidden
  before; not yet measured on nofib.
* **Commit:** `0fd07f955a`

### Annotation rebuilds arrow-free types: out of memory (2026-10-11)
* **Found by:** building GHC with the webs compiler, GHC.Tc.Errors.Types.
* **Symptom:** out of memory (4 GB) in the early webs run with only
  -fcore-webs-early; a heap profile showed THUNK_2_0 growing steadily.
* **Cause:** annType rebuilt every type node in the lazy AnnM monad, a thunk
  per node and no sharing, even in types with nothing to annotate.
* **Fix:** types with no arrow (written or behind a synonym) and no coercion
  are returned as they are (Note [Types without arrows] in
  GHC.WebCore.Annotate): the module's early run peaks at ~500 MB.  Output is
  unchanged (no webs are created for such types).
* **Guard:** the GHC build; the webs testsuite (unchanged results).
* **Commit:** `56cae268d6`

### Data specialisation: nested specialised types in coercions (2026-10-11)
* **Found by:** building GHC with the webs compiler (early-ulsl,
  ~/projects/ghc-selfhost), in GHC.Cmm.CommonBlockElim.
* **Symptom:** `ASSERT failed` in mkSelCo called from
  GHC.WebCore.DataSpec (coercion `Tuple2_s19 (Sub (D:R:KeyListMap ...) ; ...)`);
  after fixing that, Web Lint: "Role incompatibility: expected nominal, got
  representational" in a coercion `List_s6 (...)_R`.
* **Cause:** a local list of pairs, both specialised (List_s6 t1 =
  [Tuple2_s7 t1 Int]), cast through a type family (Key (ListMap ..) =
  [Label]).  (1) A TyConAppCo of the list selected each pattern variable's
  coercion out of already rewritten argument coercions, by paths through the
  pattern's original type constructors, while the rewritten pair is the
  specialised one with other arguments.  (2) Specialised types had
  all-nominal parameters, which a representational coercion between them
  cannot match.
* **Fix:** select out of the original argument coercions, then rewrite;
  a specialised type's parameter has the strictest role along its positions
  in the pattern, and its coercion is selected at that position
  (patVarRole, patPathRole in GHC.WebCore.DataSpec).
* **Guard:** `dataunbox009`; the GHC build.
* **Commit:** `89f414d94a`

### Data splitting: finding copied constructors by tag is quadratic (2026-10-11)
* **Found by:** building GHC with the webs compiler (early-ulsl,
  ~/projects/ghc-selfhost): GHC.Builtin.PrimOps ran out of memory (4 GB);
  bisected to -fcore-webs-data-split (the other passes peak at 200-350 MB).
* **Symptom:** `ghc: out of memory` in the early webs run; a heap profile
  (+RTS -hT) shows DataCons and thunks growing by GBs in seconds.
* **Cause:** PrimOp has ~1500 constructors (the vector ones have fields, so
  it is not an enumeration and is copied), and PrimOps's info tables match
  all of them.  conWithTag searched a copy's constructors by tag, building
  each lazily built constructor before the one wanted: quadratic over a
  case's alternatives.
* **Fix:** look at position tag-1 first (walks the spine only); 4+ GB to
  489 MB peak on PrimOps.
* **Guard:** `datasplit006` (generated: 2000 constructors, 6 tables); the
  GHC build.
* **Commit:** `095ea69492`

### Data Lint: a SelCo between a copy and an original behind a synonym (2026-10-11)
* **Found by:** building GHC with the webs compiler (early-ulsl,
  ~/projects/ghc-selfhost), in GHC.Hs.Type.
* **Symptom:** Data Lint after annotating copies: "Bad SelCo:
  SelCo:Tc(1,R) (Sym (D:R:XRecGhcPassa ...) ; ... ; GenLocated ...)" in
  hsWcScopedTvs; fatal, so the module did not compile.
* **Cause:** annotation copies every eligible type (GenLocated) in types it
  can see, but not behind a type synonym in an imported family instance's
  axiom (XRec (GhcPass p) a = XRecGhc a = GenLocated (Anno a) a).  The
  SelCo's kind then had the original on one side and the copy on the other,
  and Data Lint's SelCo check compared type constructors exactly, where the
  rest of Data Lint compares up to copies and records the pair (which then
  makes the copy exposed).
* **Fix:** the SelCo check compares up to copies and records the pair
  (lintCoercion SelCo in GHC.WebCore.DataLint).
* **Guard:** the GHC build (GHC.Hs.Type).  No small reproduction found: the
  simplifier removes the cast pairs that would carry such a SelCo in small
  programs (attempts with XRec/NoGhcTc-like families).
* **Commit:** `b228cf6240`

### Data splitting: a type used as a kind is copied (2026-10-11)
* **Found by:** building pretty-show 1.10 (skylighting's dependencies,
  Hackage benchmarks) with early-ulsl and `-dcore-lint`.
* **Symptom:** Data Lint after annotating copies: "Bad axiom application
  (check_ki1 N:SingI <FixityI>_N <'PrefixI>_N ...)" in a Constructor
  dictionary of Text.Show.PrettyVal's exported Either instance.
* **Cause:** GHC.Generics' FixityI is eligible (InfixI has fields), and was
  copied where it instantiates SingI's kind variable, while the promoted
  'PrefixI kept the original's kind.
* **Fix:** types used as kinds are not copied: those in the kinds of type
  variables, and those occurring in a type next to one of their own
  promoted constructors (usedAsKinds, Note [Types used as kinds] in
  GHC.WebCore.DataSplit).  A first version excluded every type with a
  promoted constructor anywhere, which stopped lists from being split (the
  'False of the Generics metadata and type-level lists are everywhere);
  the datasplit dumps caught it.  The final version only drops RuntimeRep
  (an exposed class, never split) from the testsuite's copies.
* **Guard:** `datasplit005`; the pretty-show build.
* **Commit:** 6ce8c6716c

### Useless elimination: a join point's result after a deleted parameter (2026-10-11)
* **Found by:** building network 3.1.2.7 (skylighting's dependencies,
  Hackage benchmarks) with early-ulsl.
* **Symptom:** panic `Useless.replaceResult (# State# RealWorld, () #)`.
* **Cause:** a join point bound in a tail whose result loses components is
  retyped after its binder is rewritten; the rewrite deletes dead
  parameters' arrows (and lowers the join arity), but the retyping peeled
  the old binder's arity off the new type.
* **Fix:** peel the rewritten binder's join arity (retype_join in
  GHC.WebCore.Transform.Useless).
* **Guard:** `useless021`; the network build.
* **Commit:** 6ce8c6716c

### Useless elimination: a web in a coercion variable's type (2026-10-11)
* **Found by:** building hashable 1.5.0.0 (skylighting's dependencies, the
  Hackage benchmarks in ~/projects/webs-hackage-bench) with early-ulsl and
  `-dcore-lint`.
* **Symptom:** Web Lint after useless elimination: "Mismatch in type
  between binder and occurrence" for a coercion variable bound by matching
  `UnsafeRefl` (unsafeIOToST's unsafeCoerce) in Data.Hashable.XXH3.
* **Cause:** the IO action's result `(# State# s, () #)` had a dead
  component; the variable's binder type was rewritten, its occurrences in
  coercions were not.  Webs in coercions were roots for result components,
  but only those in casts and coercion arguments.
* **Fix:** webs in the types of coercion-variable binders are roots too
  (coercionWebs in GHC.WebCore.Transform.Useless).
* **Guard:** `useless020`; the hashable build.
* **Commit:** 6ce8c6716c

### Result raising: a rebuilt case binder mentions dead field binders (2026-10-10)
* **Found by:** building happy 2.1.3 (the new Hackage benchmarks,
  webs-bench/hackage/) with early-ulsl and `-dcore-lint`.
* **Symptom:** Web Lint after result raising: "Occurrence of a dead Id"
  in happyReduce (happy's generated parser).
* **Cause:** `case f x of b { K y1 _ -> .. b .. }` becomes
  `case f x of (# y1, y2 #) -> let b = K y1 y2 in ..`; the wildcard's binder
  keeps its dead occurrence info, and the rebuilt K now mentions it.
* **Fix:** zap the field binders' occurrence info when the case binder is
  rebuilt (GHC.WebCore.Transform.ResultRaise).
* **Guard:** `resraise_alias`, `resraise_alias_late`; the happy build.
* **Commit:** `aee1086c04`

### Data splitting again: binding order and stale occurrences (2026-10-10)
* **Found by:** nofib, `run-uselessda.sh` (`early-ulsda`,
  `-fcore-webs-data-again`): spectral/rewrite did not build.
* **Symptom:** `ASSERT failed! lvl_wdt6` in CPR analysis (CprAnal.hs:357).
* **Cause:** the second data split runs after the pipeline sorted the
  top-level bindings, and it rewrites binders (zapping unfoldings) but not
  every occurrence. The simplifier fixes both after the first split; after
  the second, CPR analysis runs first, and it decides at the binding (from
  the binder's unfolding: a data structure gets no signature) and again at
  an occurrence (from the occurrence's), which disagreed.
* **Fix:** after the second split, sort the top-level bindings again and
  make every occurrence the binder's own Id (syncOccurrences in
  GHC.WebCore.Pipeline, Note [Data splitting again]).
* **Guard:** `useless019` (rewrite).
* **Commit:** `7579b380fd`

### A dead field filled, then evaluated early: "Entered absent arg" (2026-10-10)
* **Found by:** nofib, `run-useless3.sh` (`early-uls3`, useless elimination
  with fields): spectral/hartel/parstof aborted.
* **Symptom:** `internal error: Oops!  Entered absent arg useless field`.
* **Cause:** field 0 of `F_Par_succ` is only ever passed round
  f_parrep_right's recursion into field 0 of the result (through the
  unknown a_join) and never read at the end: dead, so useless elimination
  filled it with absentError.  Web strictness's strict result fields are a
  greatest fixpoint, and the field was vacuously strict (each consumer
  returns it in the same strict field), so the tails evaluated it at the
  producer: the filler.
* **Fix:** web strictness never evaluates a dead end early (Note [Do not
  evaluate dead ends early] in GHC.WebCore.Transform.Strictness).  Open:
  dead non-bottom computations of vacuously strict fields are still
  evaluated early; strictness should require liveness (the dual of useless
  elimination; WEBS-BACKLOG.md).
* **Guard:** `useless018` (parstof, preprocessed); `poison046` (a smaller
  attempt that does not reproduce it).
* **Commit:** `5a33b37065`

### Forced analysis: exprIsDeadEnd on web forms (2026-10-10)
* **Found by:** nofib, `run-useless2.sh` (with `-ddump-webs-forced`): all
  but 3 benchmarks panicked.
* **Symptom:** `exprBotStrictness: web-annotated form (WebLam/WebApp)
  outside the web pipeline`.
* **Cause:** the analysis-only draft (GHC.WebCore.Transform.Forced) called
  exprIsDeadEnd and exprIsHNF on annotated Core; no test ran the dump.
* **Fix:** strip the web forms first (stripWebForms), as the other passes
  do.
* **Guard:** `poison001_forced`, `006`, `013`, `036`, `040` run the dump.
* **Commit:** `585ca0a753`

### Useless elimination: two binding sites with one unique (2026-10-10)
* **Found by:** nofib, `run-useless.sh` (`early-uls`, `early-ulsd`): 34
  benchmarks did not build (gen_regexps, wheel-sieve1/2, circsim,
  constraints, integer, mate, typecheck, ...).
* **Symptom:** Web Lint after useless elimination: "The value variable
  go1 is out of scope".
* **Cause:** the liveness elements are keyed by unique, and GHC's Core binds
  the same unique twice in disjoint scopes (gen_regexps' expand: a go1 from
  a list comprehension in two case branches). The two sites shared one
  element, a guard from one and uses from the other, and a live let was
  deleted.
* **Fix:** each round copies the program with fresh local binders first
  (cloneExpr from super-beta inlining) and analyses the copy (Note [Fresh
  binders for useless elimination]). The timing of that run compared only
  the 75 benchmarks that built; it is discarded.
* **Guard:** `useless017` (gen_regexps' expand); the 40 `poison` tests.
* **Commit:** `e585e36ae3`

### Defunctionalisation: a captured dictionary as a field (2026-10-10)
* **Found by:** nofib, `run-exports2.sh` (`early-bnd3`, `early-bm3`: the
  boundary split for every exported function, with eta-expanded
  higher-order parameters): `spectral/scc` (Digraph) and `real/fem`
  (Matrix) did not build.
* **Symptom:** `ASSERT failed!` in `mkWebFunTy` (`af [->]`, `chooseAAF
  [=>]`, `arg Eq t`), building a defunctionalised constructor's type.
* **Cause:** a lambda's free variables become ordinary fields, and one was a
  class dictionary; an arrow from a constraint must be `=>`. Latent: the
  web became internal only when the exported `dfs :: Eq v => (v -> [v]) ->
  ..`'s wrapper eta-expanded its parameter, joining it with the local
  `new_range es`, which captures the dictionary.
* **Fix:** such a web is not defunctionalised, verdict "captured
  dictionary" (Note [Captured dictionaries] in
  GHC.WebCore.Transform.Defunc). The dictionaries could go in the
  constructor's context instead (backlog).
* **Guard:** `boundary008`, `boundary008_dump`; nofib scc and fem.
* **Commit:** `aee37c2fe7`

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
  for unboxed tuple arguments]; the whole change was later removed as dead
  code, arguments being curried).
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
  coercions) must map it through the rebuild (`ty`), and so must every type
  that mentions a rebuilt one (uniplate's Zipper). Three times so far.
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
