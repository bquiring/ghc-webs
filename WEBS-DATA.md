# Design: Data Webs

Status: phase 2 (splitting) implemented on branch `data-split`, **not** as
described in sections 1-7 below: data types carry no webs. Instead
(`GHC/WebCore/DataSplit.hs`, Note [Splitting data types];
`-fcore-webs-data-split`, dump `-ddump-webs-data`):

* Annotation gives every occurrence of an eligible data type (binder types,
  type arguments, case types, constructor workers) a fresh *copy* of the
  type: a real `TyCon` with its own `DataCon`s. Recursive occurrences in a
  copy's fields are the same copy (a list's tail is the list's copy).
* Data Lint (`GHC/WebCore/DataLint.hs`), a copy of Core Lint, checks the
  annotated program up to copies and records the pairs of copies that its
  type equalities force together. A copy that meets the original type
  (imported or exported code, coercions, pinned binders) is exposed.
* Union-find gives classes. A non-exposed class becomes one new local type
  with only the constructors the class builds (others' alternatives are
  dropped); a class that builds nothing, and every exposed class, keeps the
  original. Core Lint checks the result.

nofib (`early-ds`: every early transformation plus splitting, with
`-dcore-lint`, 2026-10-08): no Data Lint or Core Lint errors, all 115
benchmarks build and give the right output. Over 442 modules: 582,500
copies in 6,788 classes; 4,373 exposed, 1,834 split (30 of them dropping
constructors), 7,779 binders pinned. Split most often: `Int` 502, `(,)`
439, `[]` 416, `(,,)` 95, `Double` 85, `Float` 52. Instruction counts not
measured yet.

Phase 3, unboxing (2026-10-08, `-fcore-webs-data-unbox`): split types are
specialised to the most general instance of their uses (Note [Specialising
split types]), and product fields are unpacked in rounds where every
construction passes a value and every use is a projection, an argument a
callee unboxes, or an argument to another unboxable field (Note [Unboxable
fields], a greatest fixpoint). Copies also go into coercions (Note [Copies in
coercions]), and newtypes are copied with fresh axioms, unified by
congruence (Note [Splitting newtypes]). A local [(Int, Int)] becomes a list
of cells holding two Int#s.

nofib instructions against `early-fix` (112 benchmarks; before newtype
splitting):

| | geomean | >0.5% better | >0.5% worse | within 0.1% |
|---|---|---|---|---|
| split only | +0.03% | 1 | 4 | 95 |
| split + unbox | −0.30% | 11 | 2 | 84 |
| + eager (`-fcore-webs-data-unbox-eager`) | −0.53% | 19 | 2 | 77 |

Best, split + unbox: cryptarithm2 −15.1%, puzzle −4.3%, comp_lab_zift −3.5%,
fft −2.8%, fulsom −2.2%, pic −2.2%. With eager: linear −12.2%, cryptarithm2
−11.8%, solid −5.1%. Worse: cichelli +1.7% (from splitting alone), x2n1
+1.0%. Allocation (split + unbox, before coercions): cryptarithm2 −22.7%,
rewrite −6.6%, fulsom −5.4%, fft −4.0%. Splitting `Int` (now excluded) cost
multiplier +10.2%. Compiler allocation roughly doubles (deferred).

Newtype splitting (Note [Splitting newtypes], `f7058ed8df`): all 115
benchmarks build (after two fixes: congruence's originals counted as class
members; copied axioms eta-reduced like the original's). It changes no
benchmark's instructions by more than 0.1% (split + unbox against the same
without newtypes, 111 benchmarks). What it splits is mostly `ST` (11
classes) and `IO` (9), plus two local `S` newtypes (CS, dom-lt).

Strictly eliminated fields (Note [Strictly eliminated fields], sound):
against `early-fix`, geomean −0.53% (18 benchmarks >0.5% better, 2
worse), the same as the unsound eager flag (−0.53%, 19/2); 398 fields
unboxed (301 before). linear −12.2%, cryptarithm2 −11.8% (−15.1% before:
unboxing a thunk field there costs), puzzle −7.2%, solid −4.2%, fibheaps
−3.1%. Measured with nested dependencies always on; they are now behind
`-fcore-webs-unbox-nested`, with the size bound `-fcore-webs-max-unbox-size`
(Note [Bounding unboxing]).

Edge-case tests `dsedge001`-`018` (coercions and boxes, five modes each)
found two unsound cases, both fixed: a `UnivCo`, and `unsafeCoerce`'s type
arguments, related two types that Lint does not, so their copies were split
apart and unboxed differently (a segfault). Both keep original types now
(Note [Non-parametric functions]).

Strict binders as values (Note [Strict binders are values], demand
analysis): against `early-fix`, geomean −0.72% (20 >0.5% better, 2 worse),
from −0.51%; queens −20%, sched −1.0%, typecheck −1.0%, pic −0.9%;
fibheaps +2.0% against the version before. 421 fields unboxed.

Then: copies keep each field's strictness (Note [Copies keep strictness]:
a split `Complex` had become lazier than `Complex`, the cause of x2n1's
+1.0%); only splits that change something are kept (Note [Keeping only
useful splits]: cichelli's split-only +1.7% came from two copy types of
one list that GHC could no longer share, and a specialisation that no
longer applied); splitting and unboxing also in the late run, without the
demand-based rules (Note [Unboxing in the late run]). Edge-case tests now
21 programs in seven modes (five early, two late).

Dead fields (Note [Dead fields], 2026-10-09): a field is dropped when,
in every match on its constructor, its pattern variable is in the
alternative's dead slice: it occurs only inside arguments of dead fields,
right-hand sides of dead lets, or scrutinees of single-alternative cases
whose binders are dead (a greatest fixpoint, inside the fixpoint over the
fields); the slice is deleted with it. x2n1 (`./x2n1 8000000`, pinned,
user instructions): base 6,677.6M, early-du9 6,741.6M (+0.96%), with dead
fields 6,677.6M (+0.0002%): the sum's accumulator keeps only the real
part, one `Double#`; the imaginary parts inside `^` stay (another class).
Test `dataunbox007`.

Fixed on the way (stage 1 had been frozen, so the libraries had never been
compiled with it): the CBV marks for unboxed tuple arguments (Note [CBV
marks for unboxed tuple arguments]) took a coercion argument `a ~# b` for
an unboxed tuple (`isUnboxedTupleType` looks only at the representation,
`TupleRep []`) and asked for the representation of `a :: k`: a panic in
CoreTidy compiling `GHC.Internal.Data.Type.Equality`. Now only an unboxed
tuple type constructor counts.

### Next: one fixpoint for all unboxing (planned, 2026-10-08)

Field unboxing, argument unboxing (arity raising) and result unboxing
(result raising) depend on each other, so they are solved together, in the
early web pipeline (flattening moves there from the splitter):

* **Arg(w)**: web w's argument passed as components. Each lambda uses its
  parameter only by projection, as an argument to an Arg web, in an unboxed
  field, or as a Res tail; and the lambdas are strict in it, or every call
  passes a value (values include Res calls and unboxed fields' pattern
  variables, rebuilt as constructor applications).
* **Res(w)**: web w's result returned as components. Every tail constructs
  the product, tail-calls a Res web, or returns an unboxed field's pattern
  variable; every call's result is used only by projection, an Arg
  argument, an unboxed field, or a Res tail.
* **Fld(K, i)**: as now (Note [Unboxable fields]), with "a callee unboxes
  it" meaning Arg of its web, and Res tails as uses.
* **Strictly eliminated (K, i)** (Note [Strictly eliminated fields]), with
  Arg webs as strict arguments.

One greatest fixpoint over all four; then the three rewrites with the
decisions fixed, each followed by Lint. Flag `-fcore-webs-unbox`, replacing
the separate decisions (the old passes stay for comparison). Stages: shared
facts; the solver with today's local conditions only (must reproduce the
three passes); the cross-dependencies; nofib.

Open: whether recursive fields could be separate copies (polymorphic
recursion in copies; edge cases), copies for fields of other data types
(section 2, step 3; phase 4), strict and unpacked fields (types with
wrappers are not eligible yet), and phase 3.

Function webs split the arrows of a program into classes that the typing rules
force to agree (`Note [Webs]` in `GHC/Types/Web.hs`). Data webs do the same for
algebraic data types. Two lists that never meet, directly or through a
function, a constructor or a `case`, are in different webs, and so could have
different types. Take

```haskell
module M (main) where
main = do
  let xs = [1 .. n] :: [Int]        -- built and summed here only
  print (sum' xs)                   -- sum' is local
  putStrLn (show ys)                -- ys reaches the Show instance from base
```

`xs`'s list web touches only local code, so it can become a local type
`List_w`. Its element can then be strict and unpacked, giving `ConsW Int# List_w`:
no boxed `Int`s and no thunks. `ys`'s web reaches base's `Show [a]` code, which
expects the real `[]`, so it is exposed and stays `[]`.

Splitting by itself changes nothing. The payoff is what the data
transformations (phase 3) can then do to a local copy: strict fields,
unpacked fields, dead fields.

## 1. Where a data web lives

Arrow webs live in `FunTy`'s `ft_web` and `FunCo`'s `fco_web`. A data web
needs a place on `TyConApp tc tys`. The options:

| option | cost | verdict |
|---|---|---|
| a field on the `TyConApp` constructor | `TyConApp` is matched in thousands of places | no |
| an extra phantom type argument | changes kinds; breaks every `tyConArity` user | no |
| **a clone of `tc`**, with the same `Unique`, carrying the web | one field on `TyCon`; clones are cached | **yes** |

The plan: add `tyConWeb :: !WebId` to `TyCon` (`GHC/Core/TyCon.hs`), equal to
`placeholderWeb` outside the web pipeline. A *web clone* of `tc` is
`tc { tyConWeb = w }`. `Eq TyCon` compares `Unique`s, so `eqType`, Core Lint,
`tyConDataCons` and every `Unique`-keyed map see no difference, exactly as they
ignore `ft_web` today. The same trick is used already for global Ids and
coercion axioms (`Note [Exposed webs]`): an occurrence is replaced by a clone
with the same `Unique` and a different type.

Clones are made through one cached function,
`webTyCon :: TyCon -> WebId -> TyCon`, memoised on `(Unique, WebId)` so a web
has one clone. Erasure maps every clone back to the original `TyCon`, kept in
`WebSigs` (a new `ws_tycons`, like `ws_axioms`).

### Which type constructors get data webs

Only algebraic data types whose values a program builds with constructors
and takes apart with `case`:

* yes: `isAlgTyCon`, `data`, boxed tuples, `[]`, `Maybe`, local data types
* no: newtypes (they are coercions; Survey §14 is a separate change), classes
  (dictionaries), unboxed tuples and sums, primitive types, type and data
  families, and type constructors with existentials or GADT equalities
  (phase 4 at the earliest)

Any other `TyConApp` keeps `placeholderWeb` and takes no part.

## 2. Annotation (`GHC/WebCore/Annotate.hs`)

* **Types.** `annType`'s `TyConApp` case gives each eligible
  `TyConApp tc tys` a fresh web: `TyConApp (webTyCon tc w) tys'`. Type
  arguments are annotated as before, so `[[Int]]` gets two webs, one per
  level. As with arrows, kinds are left alone (`annType` is not called on
  them).
* **Coercions.** `TyConAppCo r tc cos` gets a web clone the same way, so
  `coercionKind` produces annotated types.
* **Constructors in expressions.** Today `annGlobalId` gives a data
  constructor worker *one* exposed signature, shared by every occurrence, so
  all lists in a module would be one web. Instead, each occurrence of a
  constructor gets its own instance of its signature (`instDataCon`, below)
  with a **fresh data web**. Its arrow webs stay shared and exposed: they
  describe calling the worker, which does not change.
* **Constructors in `case`.** Annotation records nothing new. Lint
  instantiates the signature from the scrutinee's type (section 3).
* **Literals and magic.** Ids that build or inspect data without a
  constructor or a `case` keep exposed signatures. Their data webs are then
  exposed by the ordinary rules: `unpackCString#` (strings), `tagToEnum#`,
  `dataToTag#`, `seq#`, `unsafeCoerce` (a `UnivCo`, section 4).

### Instantiating a constructor's signature

`instDataCon :: WebId -> DataCon -> Type` returns `dataConRepType dc` with:

1. the result `TyConApp` set to `webTyCon (dataConTyCon dc) w`;
2. every *recursive* field occurrence of the same type constructor at the
   same arguments set to `w` too. A list's tail is the same web as the list.
   Anything else would be polymorphic recursion in webs.
3. every other eligible `TyConApp` in a field, e.g. the `Maybe` in
   `data T = T (Maybe Int)`, given a web shared by **all instances of `dc`**,
   recorded in `ws_dcs`. All `T`s then share one `Maybe` web for that field.
   This is conservative, but not exposed. Phase 4 refines it (section 5).

Type parameters need no care. In `Cons :: forall a. a -> [a] -> [a]`, the
element type comes from the type argument (`[Int]^w2` in `[[Int]^w2]^w1`),
which carries its own webs, and substitution (`piResultTys`) puts them in
place.

## 3. Web Lint (`GHC/WebCore/Lint.hs`, `GHC/WebCore/Compare.hs`)

* **Type equality.** `collectWebPairs`'s `TyConApp` case already checks
  `tc1 == tc2`. It now also emits `(tyConWeb tc1, tyConWeb tc2)` when they
  differ. That is the whole rule for data flow: every place Core Lint
  requires two types to be equal (a call's argument against the parameter, a
  `let`'s right-hand side against its binder, a `case` alternative against
  the result type, and so on) links the data webs of the two types,
  argument by argument.
* **`case` alternatives** (`lintCoreAlt`). The constructor's type now comes
  from `instDataCon (tyConWeb scrut_tc) con` instead of the single exposed
  signature. The pattern binders' types then carry the scrutinee's web on
  their recursive fields, and the shared per-constructor webs on the others.
  `tycon == dataConTyCon con` still holds, since equality is by `Unique`.
* **Constructor occurrences** need no change: annotation already gave each
  one its instantiated clone.
* **Placeholders.** A `TyConApp` of an eligible type constructor with
  `placeholderWeb`, built by a transformation or after instantiation, is
  treated like an arrow without a web (`Note [Arrows without webs]`): a pair
  with `placeholderWeb`, so its class is exposed.

No other part of Lint changes. Data webs follow the same equalities as arrow
webs.

## 4. Exposure (`GHC/WebCore/Sigs.hs`)

A data web is exposed if its type crosses into code compiled without it, by
the existing rules, which now also collect `tyConWeb`s (`typeWebs`):

* **Signatures of imported Ids** that mention the type constructor
  concretely: `map :: (a -> b) -> [a] -> [b]` exposes the lists passed to
  `map`. A type variable exposes nothing. `id @[Int] xs` does not expose
  `xs`, by parametricity: `id`'s code cannot look at the list.
* **Dictionaries.** `$fShowList @Int :: Show [Int]` is an imported Id that
  mentions `[]`, so `show`ing a list exposes it, as it must, since the
  instance's code walks the list.
* **Exported binders' types** and `ws_interface_ids`, as now.
* **Coercion axioms**, and **`UnivCo`s** (`unsafeCoerce`), expose every web
  they mention.
* **Rules and stable unfoldings**: no change. Their Ids are already in
  `ws_interface_ids`.

**Expected result.** Lists are passed to base functions everywhere, so most
list webs will be exposed. What remains is local data types and
lists that are built and consumed in one module. Phase 1 measures how much
that is before we build anything that depends on it.

## 5. Solving (`GHC/WebCore/Solve.hs`)

**Phase 1: unchanged.** Data webs are `WebId`s from the same supply, and the
pairs are the same kind of pairs. Union-find gives the classes, and an
exposed member exposes the class. Arrow and data webs never pair with each
other, because `collectWebPairs` pairs like with like.

**Phase 4: congruence.** Section 2's per-constructor field webs (step 3) are
coarse: every `T` shares one web for its `Maybe` field. To give each `T` web
its own field webs, a data web gets *children*, one fresh web per eligible
field type constructor. When the solver merges two webs, it also merges
their children pairwise. That needs union-find with a work list (a small
congruence closure), not plain union-find. We defer it until phase 1 shows
whether data inside local data types matters.

## 6. Renaming, erasure, traversals, statistics

* **`Traverse.hs`.** `WebMapper` gets `wm_tycon :: TyCon -> TyCon`.
  `mapWebsType` and `mapWebsCo` apply it to every `TyConApp` and
  `TyConAppCo`. `typeWebs` and `programWebs` collect `tyConWeb`s.
* **`Rename.hs`.** Maps `tyConWeb` through the substitution (via
  `webTyCon`, so clones stay shared).
* **`Erase.hs`.** Maps every clone back to its original (`ws_tycons`).
  `Note [Web round trip]`'s `-dcore-lint` check then covers data webs too:
  the erased program must contain no clones.
* **Statistics** (`-ddump-webs-stats` and `FirstClass`): count data webs,
  exposed data webs and classes, per type constructor (`[]`, tuples, `Maybe`,
  local types). Add a column to `report.py`.

## 7. The existing passes

They rewrite types, and they build new types with `mkTyConApp` and the
original type constructors. With data webs those new types carry
`placeholderWeb`, which Lint would treat as exposed (section 3). Two things
to do:

* `Common.hs` gets a helper that rebuilds a type keeping the webs of the type
  it replaces, for the passes that rewrite a product's type (arity raising,
  result raising, uncurrying).
* Result and arity raising look at `productCon`, which will see clones. It
  compares by `Unique`, so it is unaffected, but the unboxed tuples it builds
  must not get data webs (they are not eligible).

## 8. The data transformations (phases 2 and 3)

For a non-exposed data web `w` of type constructor `T`:

1. **Splitting (phase 2).** Create a local `T_w`: a fresh `Name` and
   `Unique`, and constructors `K_w`, with the same fields as `T`. Rewrite the
   types (clones with web `w` become `T_w`), the constructor occurrences and
   the `case` alternatives. On its own this should change nothing at runtime;
   we check that with instruction counts. It costs code if `T` has instances,
   which `T_w` does not need, because no instance of `T` reaches `w`: that
   would have exposed `w`.
2. **Strict fields (phase 3).** Field `i` of `T_w` becomes strict if every
   construction site passes a value, or every consumer forces it. These are
   the two directions of the existing web strictness pass, applied to
   constructors and `case`s. That is GHC's strict-field wrapper
   (Survey §7), decided per web.
3. **Unpacked fields (phase 3).** A strict field of a single-constructor type
   (`Int`) is unpacked (`Int#`). Combined with 2, a local `[Int]` becomes a
   list of `Int#`. This is where we expect the >5% speedups: list-heavy
   nofib benchmarks that build and consume lists locally.
4. **Dead fields (phase 3).** A field no `case` of the web reads is dropped.

Phase 2 uses GHC's own machinery to make the `TyCon` and `DataCon`s
(`mkAlgTyCon`, `mkDataCon` with a `DataConRep` for strict and unpacked
fields), so the code generator sees ordinary data types. The new types are
local to the module and not exported, so the interface never sees them.

## 9. Phases and how we measure them

| phase | what | done when |
|---|---|---|
| 1 | annotation, Lint, solving, renaming, erasure; statistics only | webs testsuite passes with data webs on; round trip clean on nofib with `-dcore-lint`; nofib count of non-exposed data webs, per type constructor |
| 2 | splitting into local types, no representation change | nofib instruction counts unchanged (±0.1%), no failures |
| 3 | strict, unpacked and dead fields | instruction counts and paired times on nofib; target >5% on some benchmarks, few regressions |
| 4 | congruence for nested fields; newtypes (Survey §14) | if phase 1's numbers say nested data matters |

All of it sits behind a flag, `-fcore-webs-data`. With the flag off, every
`TyConApp` keeps `placeholderWeb` and nothing changes.

## 10. Risks and open questions

* **Clone hygiene.** Some GHC code might keep a `TyCon` and later rebuild
  types from it (`tyConDataCons`, `dataConTyCon`). Those types have no
  webs, so the class becomes exposed. That is safe, but costs precision.
  Phase 1's statistics will show how often it happens.
* **`TyCon` size and cost.** One more field on every `TyCon`, and a cache of
  clones per module. We need to measure compile time (`report.py` already
  reports compiler allocation).
* **Type classes.** Every instance method that mentions `T` exposes what
  reaches it. Derived instances of local types (`deriving Show`) are local
  binders, so only the uses that actually reach `show` are exposed. Are
  dictionaries for local types built locally? Yes, but the class methods'
  selectors are imported Ids, and their types mention only the class's type
  variable, so this should be fine. Phase 1 checks it.
* **`[]` and `build`/`foldr` fusion.** The early run happens after the
  simplifier's fusion phases, so most local lists that remain are real ones.
  Rules that mention `[]` concretely (`map`/`foldr` rules) belong to
  imported Ids; their types expose what they rewrite.
* **Open: which run.** Splitting must happen before worker/wrapper and the
  simplifier's last phases, so they can optimise the new types. That is the
  early run. The late run would only get the representation change, with
  no cleanup.

## 11. Redesign: splitting by unification (proposed, 2026-10-14)

Status: proposed, not implemented. Modelled on the SML web inference in
`~/projects/3cps` (`infer-webs.sml`: `newTyc`, `renameDCon`, `unifyTyc`,
`mergeTycons`).

### Why

Splitting costs far more than the rest of the web pipeline, and its cost
grows faster than the module. Each splitting step runs twice: once to find
the useful classes, then again keeping only those (Note [Keeping only
useful splits]). With `-fcore-webs-data-again` that happens in both the
`_s` and the `_r` run.

Step 0 (2026-10-14, `3f0c024f91`: -dshow-passes times each step) on three
GHC modules, first `_s` pass. Allocation in GB; "rest" is flattening and the
dump. **Caveat:** these figures, and every compile-time figure in this
document before 2026-10-14, come from the devel2 stage 2 compiler, built
with -O0 and debug assertions. Its unique maps run through unspecialised
`Bits Word64` and `Integer` code, so map-heavy code is penalised out of
proportion. From 2026-10-14 the stage 2 compiler is built with -O1
(`_build/hadrian.settings`). Only the large structural differences carry
over.

| module | size | copies (constructors behind them) | annotation | Data Lint | solving | rewriting | specialising | rest | total |
|---|---|---|---|---|---|---|---|---|---|
| `GHC.Core.Opt.Arity` | 7.7k terms | 4,194 (14k) | 0.16 | 0.37 | **0.85** | 0.10 | 0.03 | 0.36 | 1.87 GB, 0.8 s |
| `GHC.CmmToLlvm.CodeGen` | 27k terms | 66,328 (284k) | 1.6 | 3.3 | **23.3** | 1.3 | 0.5 | 8.2 | 38 GB, 12 s |
| `GHC.Tc.Errors.Types` | 31k terms, 6.0M types | 362,154 (1.39M) | 37 | **211** | 83 | 0 | 0 | 0 | 331 GB, 100 s |

* The parts the redesign replaces are annotation, Data Lint and solving.
  They take 74% of the allocation on `Arity`, 74% on `CodeGen` and 100% on
  `GHC.Tc.Errors.Types`.
* Solving dominates the first two. It is probably the offline congruence
  loop (`components` over every pair, up to 20 rounds), the only part of
  solving that is not linear; the timer covers all of solving.
* Data Lint dominates on large types: `GHC.Tc.Errors.Types` has 362k
  copies, and all 221 classes end up exposed. It splits nothing, so its
  100 s per pass (and the `_r` pass's 96 s) buy nothing.
* The "useful splits" rerun costs about as much again where something
  splits (`CodeGen`: 10 s, 33 GB).

(`CodeGen` once had 992k terms and ran out of memory. That came from a
separate bug: imported wrappers made by worker/wrapper after webs zapped
unfoldings; WEBS-BUGS.md, 2026-10-14. The earlier figures of 523 s and
1.5 TB are from that program.)

Plain types (the user's suggestion, 2026-10-14; tried in `ed3d581b0f`, then
removed). Not copying types that are monomorphic, not recursive, reach no
arrow through their fields and have no field that could be unboxed saves
about 1% of copies: `CodeGen` 66,328 to 65,907, with the same unboxing, and
`GHC.Tc.Errors.Types` 362,154 to 358,039. The copies there are GHC's
syntax-tree types used in the error messages (`GenLocated` 31k, `EpAnn` 30k,
`[]` 27k, `AnnListItem` 23k, `NonEmpty` 18k, `RdrName` 18k, `HsType`,
`HsExpr`, ...). These are polymorphic, recursive or reach arrows, and every
class is exposed (-dppr-debug -ddump-webs-data prints the copies per type).
So the cost is in how each copy is handled, not in which types are copied.

What the current design pays, per pass:

* **Full copies.** Every occurrence of an eligible type is a real `TyCon`
  with its own `DataCon`s, workers and field types (`mkCopy`). They are built
  lazily, but anything that looks at a copy's constructors builds them. A
  type with many constructors (`CmmToLlvm`'s and `Cmm`'s instruction and
  operation types) costs that many `DataCon`s per occurrence.
* **Data Lint.** A 4,079-line fork of Core Lint type-checks the annotated
  program. For every comparison it erases copies from both types
  (`eraseCopies`) and walks them again for pairs (`copyPairs`). It also
  checks kinds and substitutes types as Core Lint does, which unshares them
  (Note [Keeping types shared]).
* **Offline solving.** The pairs go into a list, then into connected
  components. Newtype congruence recomputes the components for up to 20
  rounds (WEBS-BACKLOG, "Superlinear algorithms", 5).
* **Two complete passes.** The "useful splits" pass repeats annotation, Data
  Lint and solving on the same input, and gets the same classes.

### The design

The classes, fates and names stay exactly as they are now. Only how they are
computed changes. So the first version must give the same output as today:
same `-ddump-webs-data`, the same instruction counts in nofib.

1. **Name-only copies.** A copy is a `TyCon` with a fresh `Name` and
   `Unique`, the original's binders, kind and roles, and no constructors
   (an abstract right-hand side), like `newTyc`'s `DataTyc []` in the SML.
   It costs one `TyCon` and one `Name`, whatever the type's size.
   * **Constructor occurrences.** A constructor occurrence becomes a fresh
     occurrence `Id` whose type is the worker's type with the copy in place
     of `T` (in the result and the recursive fields, as now). A side table
     maps it to its `DataCon` and copy.
   * **Case alternatives.** They keep the original `DataCon`; their copy is
     the case binder's.
   * **Newtype copies.** They get no axiom. Coercions that use an original
     newtype axiom instantiate it with fresh copies. Only a split newtype
     class gets a real axiom, at the end (`mkNewtypeCopy`, as now).
2. **Inference instead of Data Lint.** One traversal of the annotated program
   computes each expression's type and unifies two types wherever Core Lint
   requires them to be equal. Those are Data Lint's `ensureEqTys` sites:
   * a binder's type against its right-hand side's, including join points
     and unfoldings;
   * a function's argument type against the argument's;
   * a case binder's type against the scrutinee's;
   * a constructor pattern's instantiated fields against its binders;
   * each alternative's type against the case's;
   * a cast's coercion kind against its expression;
   * inside coercions, where they compose (`TransCo`, instantiated axioms,
     `ForAllCo` kinds).

   Unifying walks the two types once: same original, different copies →
   union. There is no erasure, no kind checking, no Lint environment and no
   substitution beyond instantiating `forall`s at type applications. A
   missed site would make two classes that meet differ. Core Lint on the
   output (tests and nofib run with `-dcore-lint`) reports that as a type
   error. While the new inference is developed, the old Data Lint stays
   behind a debug flag that checks both give the same partition. Once
   nofib and the self-host agree, it is deleted.
3. **Online union-find** (in `ST`, as `unifyTyc` and `merge` in the SML).
   Each class has a descriptor: the original if it meets one (exposed); the
   constructor tags built and matched; for newtype copies, their children.
   Merging two classes merges their descriptors. Merging two newtype classes
   unifies their children pairwise; merging one with its original unifies
   its children with the original's types. That is the congruence the
   20-round loop computes now, done once when the merge happens.
4. **One annotation and inference for both splitting passes.** The "useful
   splits" pass reuses the first pass's annotated program and classes. It
   only recomputes the fates, keeping the useful classes. Then it rewrites,
   specialises and flattens again. Annotation and solving are deterministic,
   so this is the second pass the current code computes.
5. **Rewriting** maps each copy to its class's type, and each occurrence
   `Id` to that type's constructor, as `rwMapper` does now. Classes are
   numbered by first copy in traversal order, as now, so `T_s<n>` keeps its
   number.

### One pass for data and function webs (user, 2026-10-14)

Data splitting and the web inference become one pass, as in the SML, where
one type checker unifies the fresh names of both datatypes and function
types. Function webs sit on arrows (`ft_web`). Web Lint records a pair of
webs at the same type comparisons where Data Lint records a pair of copies.
So one walk does both: `unify` unions the two arrows' webs at a `FunTy`, the
two copies at a `TyConApp`, and recurses. The early run becomes:

1. **Annotation:** arrows get webs (`annotateProgram`, as now) and eligible
   type occurrences get name-only copies, in the same traversal.
2. **Inference:** the unification above, at Core Lint's comparison sites,
   gives web pairs and data classes. Exposure works as now: webs reach
   `placeholderWeb`; data classes meet an original.
3. **Solving:** `solveWebs` for the webs (as now); fates for the data
   classes.
4. **Data:** rewrite to the split types, then specialise and flatten.
   Usefulness: recompute the fates and rewrite once more, without
   inferring again.
5. **Web transformations**, using the solution from step 3. The data rewrite
   rebuilds types with record updates and substitution, which keep
   `ft_web`. Wherever it builds a new arrow, the arrow gets the web of
   the one it replaces (section 7's helper). The rounds' Web Lint check
   (`checkSolved`, under `-dcore-lint`) catches a web that was lost.

**Webs in the fields of split types.** Today the webs see the program
after splitting, and `hiddenFields` hides the fields of the split types: an
arrow in a split type's field gets an internal web. In one pass, whether a
data class is exposed is known only while solving. So each constructor
occurrence gets fresh webs on the arrows in its fields. A class's descriptor
holds them, by constructor and field. Merging two classes unifies them, and
a class that meets its original unifies them with `placeholderWeb`. This
gives the same webs as today for split classes, and exposed ones for the
rest. It is the arrow half of `renameDCon`.

Web Lint and Data Lint both stay as checkers while this is built. The new
inference must give the same web solution as Web Lint and the same data
partition as Data Lint. After that, the inference is the only source of
constraints. Web Lint remains as the `-dcore-lint` check of each round.

What happens to the `_r` run (splitting again after the web
transformations) is decided by measurement. If it still adds splits, it
reruns the joint pass on the transformed program. If not, it goes.

### Later: nested fields (changes results; behind a flag)

The SML gives each constructor occurrence fresh copies of every datatype in
its fields too (`renameDCon`). Unifying two classes unifies their
constructors' fields by name (`unifyDCons`). Today a field of type `[Int]`
in `data T = T [Int]` keeps the original `[]`. So whatever flows through it
is exposed (section 4, phase 4 in section 9). With nested fields, the
descriptor holds each constructor's field copies, and a merge unifies them.

A final type's fields can then name other classes (a list's cells whose tail
is another class), so the new `TyCon`s are built knot-tied. This splits
more, so it goes behind its own flag and must pass the no-regression check
against `early-ulsl` before it is on by default.

### Steps

0. **Measure.** Add timings (`withTiming`, under `-dshow-passes`) for
   annotation, Data Lint, solving, rewriting, specialisation and each
   flattening round, and print the copy count with the constructors behind
   it. Measure `Arity`, `GHC.Tc.Errors.Types` and `CodeGen`. If
   specialisation or flattening dominates (each flattening round runs the
   simple optimiser over the whole program), fix that first; it is separate
   from this design.
1. Name-only copies, inference, online union-find. Check them against the
   old Data Lint (same partition) on the webs testsuite and nofib.
2. One annotation and inference for both passes.
   Then merge it with the web inference: one annotation, one inference,
   one solve for data and function webs (above). The web solution must
   be the same as Web Lint's.
3. **Verify; no lost splitting.** Each module must split at least what it
   splits now. A script compares old and new compilers per module: classes
   split, constructors dropped, fields unboxed, and internal webs. It runs
   on the webs testsuite, nofib and the Hackage and SML programs, and every
   module that splits less is explained or fixed. The webs testsuite's
   dumps are unchanged (apart from timing lines). nofib per benchmark is
   identical to `early-ulsl3`.
   Compiler allocation is measured on the three modules above. Then the GHC
   self-host builds with data splitting, which ran out of memory in
   `CodeGen` before. Delete Data Lint.
4. Nested fields, behind a flag; measured on nofib against `early-ulsl`,
   then on the Hackage and SML programs.

### Risks

* **Missed equation sites.** These are unsound when built without Lint.
  The partition check against Data Lint guards them during development.
  Afterwards, every test and benchmark build runs Core Lint on the result.
* **Coercions.** These are the hardest part to get right: axioms, `UnivCo`
  and the non-parametric functions (Note [Non-parametric functions]). They
  keep their current rule: whatever they touch meets the original.
* **Order.** Rewriting from the solved classes must give the same class
  numbers as now, or every dump and test output changes. Numbering by first
  copy in traversal order keeps them, if annotation visits occurrences in
  the same order.
