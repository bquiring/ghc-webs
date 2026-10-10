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

Plan (end of 2026-10-09; branches `webs` = `data-split` at `7582b2195a` and
later, instrumentation on `exposure-stats`):

1. **Read the exports experiment** (`webs-bench/run-exports.sh`, results in
   `results/timing-exports.md`, `report-exports.md`): early-mdf's options
   with the boundary split (`early-bnd2`), with the main module's exports
   internal (`early-main`, Note [Main's exports]), and both (`early-bm`),
   against `base` and `early-mdf` (−2.20% instructions, −3.14% allocation).
   Exported binders alone exposed 68% of exposed lambda classes (4,464 in
   ordinary modules, 814 in Main). If the boundary split helps, make it part
   of the default configuration; check its regressions first (WEBS-EXPERIMENTS
   §5 fixed infer, gamteb, VS).
2. **Re-measure exposure with the winner** (merge `exposure-stats`' counters
   in temporarily, or run them on that branch rebased): how many lambda
   classes are still exposed, and by what, once exports are handled. That
   decides between:
   - imported recursive functions (`map` 62, `filter` 21, ...): keep the
     foldr form of functions with fusion rules, or copy them with exposed
     unfoldings;
   - one-constructor defunctionalisation for captured variables, where the
     lambda's definition is not in scope at the call (not recursive
     functions, or eta-expand them first);
   - nested fields for data splitting (the `Step` inside `Stream` case:
     copies keep other data types in fields original).
3. **Super-beta for captured locals** (1,888 webs): count the ones whose
   calls are all in the binding's scope, before building anything.
4. **Data unboxing on the recorded demands**: run data splitting again after
   the web passes (37 of 518 fields blocked by laziness).
5. **Housekeeping**: the timing runner's k-nucleotide input (norm mode has
   no stdin file); fix the "by kind" grouping in the exposure script (the
   binder labels were filed under imported functions).

Measured and set aside (2026-10-09): unboxing fixpoints (more rounds change
nothing; one fixpoint for fields, arguments and results: a few percent more
fields at most), strictness feeding raising (no change on nofib), known-call
conversion for top-level single-lambda webs (28 calls over nofib), recursive
webs as newtypes (the occurs check never fires on nofib).

## Core-to-Core: to implement

- **Named function types, one per web** (from an earlier implementation):
  analogous to named data types, each web gets a named function type
  constructor, a top-level name for the structural `mu w. A -> B`. Two uses:
  * **Breaking cycles.** A web stored in a field of the type it takes or
    returns (`T = (Int, T ->{w} Int)`) cannot be raised structurally (an
    infinite type); with a name, `newtype W = W (Int -> W -> Int)`, it
    can, the field holding a `W` and calls unwrapping it (a cast, free).
    A GHC newtype may be the way to do it in Core (the user's suggestion,
    2026-10-09).
  * **Caching analysis.** The named types can be specialised and
    monomorphised once, recording what downstream web passes now recompute
    each time (e.g. defunctionalisation's types `D_w a b`, specialised when
    a most general unifier exists).

- **Data webs, phases 2–4** (`WEBS-DATA.md`): splitting into local types;
  strict, unpacked and dead fields; congruence for nested fields.
- **Hidden fields** (done, 2026-10-09; Note [Hidden fields] in
  `GHC.WebCore.Sigs`, Note [Signatures follow the transformations] in
  `GHC.WebCore.HiddenFields`): the webs inside the fields of types whose
  constructors are not exported are internal; constructor signatures follow
  the transformations and the types are rebuilt in place. Webs that would
  raise through themselves (`T = (Int, T ->{w} Int)`) are rejected (Note
  [Recursive products]). Tests `hfield001`-`002`, `recweb001`-`005`. Next:
  * **Recursive webs as newtypes** (low priority: the occurs check fired 0
    times on nofib, 2026-10-09, and the user expects it to be rare): for
    exactly the webs Note [Recursive products] rejects, name the web's type
    with a recursive newtype (`newtype W = W (Int -> W -> Int)`), the field
    holding a `W`, and raise. **Only there**: every other web stays
    structural, since a newtype adds a cast at every use (the user,
    2026-10-09).
  * **Defunctionalisation** leaves hidden-field webs alone: its new types
    are replaced by SpecIndex afterwards, and a rebuilt field would have to
    follow.
  * **Strict function fields** (next): a constructor whose wrapper only
    evaluates `!`-marked fields (`data T = T !(Int -> Int)`) keeps its
    fields exposed today. Regenerate the wrapper with `mkDataConRep` in the
    rebuild (most wrapper calls are inlined before the early run).
  * **Low priority** (the user, 2026-10-09), what each would take:
    * Existentials (non-GADT): the rebuild carries existential type
      variables and contexts; signatures skip their binders and dictionary
      arguments. Would unblock stream fusion's `Stream` (`stream001`).
    * Newtypes (`recweb005`): a hidden newtype's axiom gets an internal
      signature that follows the transformations, and is rebuilt in place
      (local newtypes over functions: parsers, `State`; "Local newtypes").
    * Other wrappers (unpacked fields), GADTs, data family instances.
    * Not classes: instances are global, and cross-module unfoldings use
      dictionary fields.
    Constructors in rules or stable unfoldings stay exposed (that Core is
    not rewritten), as do types related by unsafe coercions (Note [Hidden
    fields]).
  * **Safety, later** (after the runtime gains, the user's call): the
    unsafe-coercion rule sees only types written in the coercion's type
    arguments. A polymorphic `unsafeCoerce @a @Int`, in a function called
    at a hidden-field type, gets past it; ignored explicitly for now.
  * **Measured on nofib** (early-cur options, `webs-bench/run-hidden.sh`,
    2026-10-09): 481 types with hidden fields, but only 22 webs inside them;
    internal lambda classes 7,460 -> 7,483 (+23, +0.3%), most in event,
    constraints, circsim, k-nucleotide, infer. Arity raising changes 13 ->
    14 webs, result raising 15 -> 16. All 115 build under Core Lint, same
    output as base. Local types rarely hold functions; the function-holding
    ones are newtypes (parsers, State) and existentials (streams), still
    exposed, so the low-priority items above are where more would come from.
  * **Specialising for webs** (Note [Specialising for webs] in
    `GHC.WebCore.DataSplit`): data splitting keeps a copy whose
    specialisation adds product arguments or results to its function fields
    (`data P a = P Int (a -> Int)` used only at pairs). Not yet measured on
    nofib; watch for split costs (Note [Keeping only useful splits]).
- **Local newtypes** (Survey §14): a newtype that is not exported gets
  ordinary webs on its axiom, so functions in a local `State` monad become
  transformable.
- **Constructed-argument raising** (Survey §8): done (`78d6fd8fc9`;
  wave4main −4.6%), with curried components since the merge.
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
- **Strictness feeding raising** (done, 2026-10-09: WEBS-EXPERIMENTS.md §12,
  no change on nofib; arity raising is limited by exposure and known calls,
  not laziness). The user's design: Web strictness (Note [Web strictness fixpoints])
  already proves argument strictness as a greatest fixpoint over the webs,
  and strict result fields backward from the case contexts of all calls
  (through tail calls), but it runs last and records nothing on the
  lambdas' parameters, which arity raising reads. So:
  1. strictness records what it proves (a strict demand on the parameters
     of a strict web), and the raised components get the demand they had
     inside the product (nested raising: their fresh webs are rejected as
     lazy today, `arityraise013`);
  2. the transformation sequence repeats while something changes (2-3
     passes): raising, strictness, raising. Measure against the 39 webs
     arity raising rejects as lazy on nofib.
- **Strictness feeding data unboxing** (after the function-web version is
  measured; the user's question, 2026-10-09). Data splitting and unboxing
  run once, before the web pipeline, so strictness that web strictness
  proves later never reaches them; but unboxing decides from demands too
  (Note [Strict binders are values]: 37 of 518 fields are blocked by
  laziness). Run data splitting and unboxing again after the web passes,
  on the recorded demands (it has never run twice in one pipeline).
- **Strictness at the producer** (the user, 2026-10-09; later): lift the
  evaluation of a data structure's components from where they are consumed
  to where they are produced. Needs an analysis proving that every path from
  the construction to the use is strict (the component is certainly forced
  once the structure is built), across webs and data webs, as a fixpoint.
  The strict result fields of web strictness are the special case of a
  direct return to a scrutinising caller.
- **Richer demands in web strictness** (after the above). GHC's demand type
  instead of one bit per argument: product demands (strict in a field of an
  argument), call demands, cardinality. A web's signature is the lub of its
  lambdas' demands (strict only if every lambda is), each lambda analysed
  with the current signatures of the webs it calls, iterated to a fixpoint
  (a depth bound on nested demands for termination); results backward from
  the case contexts of all calls. In effect, demand signatures for unknown
  calls, which GHC's demand analysis lacks. Only internal webs; strict only
  where evaluation is proven (the user: "we only want to make things strict
  when we can prove we are going to evaluate it").
- **One-shot lambdas from webs.** Done (`78d6fd8fc9`): no effect on nofib.
  Find out why, or drop it.
- **Partial absence.** Drop the unused fields of a product argument at
  unknown calls (dead parameters handles whole parameters only).
- **Exposure through recursive imported functions** (2026-10-09): `map`
  has no unfolding in base's interface (self-recursive, NOINLINE [0], kept
  for fusion rules; mapList turns unfused code back into a call), unlike
  `foldr` (INLINE, a local go), so a lambda passed to `map` is called in
  base's code. Options: keep the foldr form of functions with fusion rules
  when the function argument is ours; or expose recursive unfoldings
  (-fexpose-all-unfoldings for base) and copy such functions into the
  module, specialised to the argument.
- **What exposes webs and data types: measured** (branch `exposure-stats`,
  `-ddump-webs-stats`, nofib with early-mdf's options, 2026-10-09).
  Lambda classes: 15,245, 7,762 exposed. Exposed *only* by an exported
  binder: 5,278 (68%; 814 in Main modules, 4,464 in others), only by a
  binder kept for rules or stable unfoldings: 511, only by `map`: 62, by
  any other single import: about 250. 243 of nofib's 656 modules have no
  export list (61 of them Main). So:
  1. **Boundary split** (exists, `-fcore-webs-boundary`, off in every
     configuration timed since §5): exposed wrapper, internal worker; aimed
     at the 4,464. Measure early-mdf with it first.
  2. **Main's exports**: in the program's main module, everything but `main`
     is not really exported (nothing imports Main); treat it as internal
     (814).
  Data classes: 5,446, 3,995 exposed, 411 split; exposure through imported
  functions mostly, spread thin (noinline, readNumber, map 291, (++) 235,
  unpackCString#, runMainIO, ReadP.run, hPutStr: I/O, Read and String
  plumbing), constructors of other data types holding copies (fields stay
  original: Note [Splitting data types]; e.g. Step inside Stream), and
  Typeable metadata.
- **What exposes data types?** (the user, 2026-10-09) Measure how many
  data webs/classes are exposed only because they pass through small
  imported functions (`map`, `foldr`, `(++)`, `length`, ...) that could be
  inlined or copied into the module (as the boundary split does for
  functions). The data dump records no reason for exposure today: add one
  (which global Id or axiom exposed the class), then count per function on
  nofib. If a few functions account for most, copying them locally would
  unlock data splitting (and unboxing) broadly.
- **Known-call conversion** (agreed with the user, 2026-10-09). A
  single-lambda web whose lambda is a named function in scope at the call
  (top-level, or local without captured variables) needs no inlining:
  `k x  ==>  case k of _ -> f x`, a direct saturated call instead of an
  unknown one, with no code copied. For the webs super-beta rejects as loop
  breakers (2,581) or too big (177): inlining a recursive function at its
  own calls would not terminate, and big bodies are what GHC's threshold
  keeps from being copied. **Measured (2026-10-09, the user's version: one
  lambda, a top-level function): 4,772 such webs on nofib, but only 28 calls
  not already by name (27 in internal webs, 1 in an outflow-only web; 144
  more in webs that values from outside can reach). Not worth building.**
- **One-constructor defunctionalisation for captured variables** (agreed,
  2026-10-09). Wrapping the captured variables in a constructor and
  projecting them at the call is closure conversion, i.e.
  defunctionalisation with one constructor, which the heuristics exclude
  (at least two lambdas: CS was +156% when GHC lost the lambda it
  specialises loops on). Do it only where the lambda's definition is not
  in scope at the call (defined in one part of the program, called
  elsewhere, non-locally); not for recursive functions, or eta-expand them
  first (the user).
- **Join points** are not a super-beta blocker: their calls are jumps,
  known and saturated (2,621 webs; nothing to do).
- **Super-beta for lambdas that capture locals** (2026-10-09). Of the
  15,245 webs with lambdas on nofib, 94% have one; super-beta inlines 56.
  Its blockers among one-lambda webs: exposed 6,999, join point 2,621 (no
  need), loop breaker 2,581 (no), captures local variables 1,888, too big
  177. The last needs Shivers' environment analysis: inline at a call that
  sees the same binding of each captured variable (every call within the
  binding's scope, no other activation in between), e.g. a local function
  and its unknown calls in one function body. First count how many of the
  1,888 have all their calls in scope.
- **Streams** (tests `stream001`, `stream002`, 2026-10-09): stream fusion's
  `Step`/`Stream` with combinators not inlined. No transformation improves
  either (2,000,000 elements: 806M instructions, 488 MB allocated, base and
  webs alike, within 0.4%). Data splitting splits nothing (17 classes, 11
  exposed), so `Step`'s pairs and zipS's state triple stay boxed, even with
  the state in the type (`stream002`); the step functions stored in each
  `Stream` are exposed, so arity raising rejects them; defunctionalisation
  takes only mapS's two functions. First find out what exposes the
  classes (the data dump gives no reason for them: add one).
- **Unboxing fixpoints** (later, 2026-10-09; measured, little to gain):
  * More flattening rounds (`-fcore-webs-unbox-rounds`): no field of a split
    type ends waiting for a later round on nofib, and cryptarithm2 at 5 or
    10 rounds unboxes the same 6 fields with the same instructions (its lost
    3% is strict elimination's extra field, which costs). `early-hf10` in
    run-hftiming.sh checks all of nofib.
  * One fixpoint for field, argument and result unboxing (WEBS-DATA.md,
    planned 2026-10-08): of 518 fields of split types, 277 are unboxed and
    63 dropped; it would reach the 29 used boxed (returned, an argument, an
    unboxed tuple), and some of the 97 blocked by another structure's boxed
    field, most of which are exposed tuples. The 37 blocked by laziness need
    strictness, not a fixpoint. A ceiling of a few percent more fields, and
    more fields is not always faster.
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
