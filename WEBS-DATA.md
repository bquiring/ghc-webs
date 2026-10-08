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
