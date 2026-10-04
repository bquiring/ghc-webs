# CLAUDE-PLAN: Where the Webs Pipeline Touches GHC

This document turns `PLAN.md` into a concrete list of changes to the GHC
source tree (version `9.15.20251215`, branch `master`). For each pass it lists
the files and functions to change, the new modules to add, and the design
decisions behind them.

Paper: *Webs and Flow-Directed Well-Typedness Preserving Program
Transformations*, Benjamin Quiring, David Van Horn, John Reppy, Olin Shivers.
PACMPL 9 (PLDI 2025), article 177, https://dl.acm.org/doi/10.1145/3729280. A *web*
is an equivalence class of program points: λ-abstractions, call sites, and arrow
types that the type system forces to agree. Type-directed flow analysis finds
them. A transformation that is applied uniformly to every member of a web (for
example, changing arity or calling convention) keeps the program well-typed.

All paths below are relative to `compiler/` unless they start with `/`.

## Settled decisions

- **Every arrow carries a web.** `FunTy` and `FunCo` get a required (not
  optional) `WebId` field. Code outside the web pipeline never reads it.
- **New `Expr` forms (`WebLam`, `WebApp`) panic downstream.** They never flow
  past erasure, so every other pass may `pprPanic` on them.
- **Module boundaries use exposed webs.** Webs that come from imported Ids,
  DataCons, coercion axioms, or the types of exported binders are *exposed*.
  They form a fixed signature that later transformations must not change.
- **Any web involved in a coercion axiom is exposed.**
- **Web Lint is a full copy of `GHC/Core/Lint.hs`**, placed in
  `GHC/WebCore/Lint.hs`. The original linter is not modified.

## Implementation status (as built)

The pipeline is implemented and runs with `-fcore-webs`. Dumps:
`-ddump-webs` (annotated program and exposed signatures), `-ddump-webs-solved`
(renamed program and web classes), `-ddump-webs-stats`. Tests are in
`testsuite/tests/webs/`. With `-fcore-webs -dcore-lint` added to every test,
about 3,000 existing testsuite tests also pass (callarity, dmdanal, simplCore,
typecheck, deriving, codeGen, indexed-types, gadt, linear, programs, numeric,
concurrent, polykinds, th).

Where the implementation differs from the plan below:

- **Global Ids and coercion axioms are replaced by clones, not looked up.**
  Annotation replaces each global Id occurrence with a clone (same Unique)
  whose type is the exposed signature. It also replaces the `CoAxiom` in each
  `AxiomCo` with a clone whose branches are annotated. GHC's own
  `coercionKind` and `exprType` then produce webbed types, so Web Lint needs
  no `webCoercionKind`. Erasure puts the originals back. Only data constructors
  in case alternatives are looked up in `WebSigs` (in `lintCoreAlt`).
- **Arrows without webs.** Some term-level arrows are built during type
  checking and cannot carry a web. The main case is `(->)` passed unapplied as
  a type argument (`Category (->)`, `Functor ((->) r)`). Web Lint pairs such
  an arrow's `placeholderWeb` with the web it meets, and the solver treats the
  placeholder as exposed. Any class that meets such an arrow is therefore
  exposed. See `Note [Arrows without webs]` in `GHC/WebCore/Lint.hs`. Real
  annotation mistakes are still errors: a plain `Lam` or `App` against an
  arrow, or a `WebApp` with a type argument.
- **Kinds and type-level applications** are compared ignoring webs
  (`ensureEqKinds`).
- **Type synonyms** are expanded only when the expansion contains an arrow,
  for example `(->)` itself (`type (->) = FUN 'Many`) or
  `type Endo a = a -> a`.
- **The `(placeholderWeb ⇒ error)` check of §3.3 and §5's `assertNoWebs`** are
  replaced by the round-trip check, which runs under `-dcore-lint` (Note
  [Web round trip] in `GHC/WebCore/Pipeline.hs`). After erasure, the program
  must equal the input up to α-equivalence and contain no webs.
- Haddock (`utils/haddock`) also needed the positional `FunTy` patterns
  updated.

---

## 0. Overview

```
core2core (GHC/Core/Opt/Pipeline.hs)
  ... existing optimisation passes ...
  CoreDoWebs  ─┐                                   (new CoreToDo, gated by -fcore-webs)
               │ 1. annotate   : CoreProgram         -> (WebProgram, WebSigs)
               │ 2. web-lint   : WebSigs, WebProgram -> Bag (WebId, WebId)    (constraints)
               │    solve      : Bag (WebId, WebId)  -> WebSubst               (union-find)
               │ 3. rename     : WebSubst -> WebProgram -> WebProgram
               │    re-lint    : must produce zero pairs
               │ 4. erase      : WebProgram          -> CoreProgram            (placeholder webs only)
               └─ endPass (regular Core Lint under -dcore-lint, dumps)
hscTidy / CorePrep / interface generation  (only see placeholder webs; never read them)
```

"WebProgram" is an ordinary `CoreProgram` in which every value λ is a `WebLam`,
every value call is a `WebApp`, and every term-level arrow has a real web.

New module tree (the `GHC/WebCore/` directory already exists and holds `notes`):

| Module | Purpose |
|---|---|
| `GHC/Types/Web.hs` | `WebId`, `placeholderWeb`, `WebSet`, `WebSubst`; low in the module graph so `TyCo/Rep.hs` and `Core.hs` can import it |
| `GHC/WebCore/Pipeline.hs` | `webPass :: ModGuts -> CoreM ModGuts`; runs steps 1–4, dumps, statistics |
| `GHC/WebCore/Sigs.hs` | `WebSigs`: the exposed signatures of global Ids, DataCons and CoAxioms, plus the exposed-web set |
| `GHC/WebCore/Annotate.hs` | Step 1 |
| `GHC/WebCore/Lint.hs` | Step 2: full copy of `GHC/Core/Lint.hs`, extended for webs |
| `GHC/WebCore/Compare.hs` | `eqTypeWebs`, a structural type equality that collects web pairs |
| `GHC/WebCore/Solve.hs` | Union-find over pairs to get a `WebSubst` |
| `GHC/WebCore/Traverse.hs` | Generic `mapWebs{Type,Co,Expr,Bind}`, used by Rename and Erase |
| `GHC/WebCore/Rename.hs` | Step 3 |
| `GHC/WebCore/Erase.hs` | Step 4 |

Register every new module in `ghc.cabal.in` (the `exposed-modules` list near
`GHC.Core.Opt.Pipeline`, around line 397).

---

## 1. Shared infrastructure

### 1.1 Web identifiers — `GHC/Types/Web.hs` (new)

```haskell
newtype WebId = WebId Unique  deriving (Eq, Data)
instance Uniquable WebId; instance Outputable WebId   -- prints as  w123

placeholderWeb :: WebId   -- fixed unique; what every arrow holds outside the web pipeline
type WebSet   = UniqSet WebId
type WebSubst = UniqFM WebId WebId
```

- The `FunTy`/`FunCo` field is required, so every arrow GHC builds (the type
  checker, desugarer, `mkFunTy`, interface loading) needs some value. That value
  is `placeholderWeb`. Annotation replaces it with real webs, and erasure puts it
  back. Inside the web pipeline, finding `placeholderWeb` on a term-level arrow
  means annotation missed something, and Web Lint reports it as an error (§3).
- Fresh webs come from `UniqSM` / `getUniqueSupplyM` in `CoreM`
  (`GHC/Core/Opt/Monad.hs:175`). Use a unique tag that is not already in use; the
  tags are documented in `GHC/Types/Unique.hs` and `GHC/Builtin/Uniques.hs`.
  `placeholderWeb` gets a fixed unique from `GHC/Builtin/Uniques.hs`.
- Only `GHC.Types.Unique`, `GHC.Types.Unique.FM/Set` and `GHC.Utils.Outputable`
  may be imported here, so the module does not create import cycles with `TyCo/Rep`.

### 1.2 Dump and enable flags — `GHC/Driver/Flags.hs`, `GHC/Driver/Session.hs`

- `GeneralFlag`: add `Opt_CoreWebs` (`-fcore-webs`), and add it to the flag
  table in `Session.hs` (`fFlagsDeps`).
- `DumpFlag` (next to `Opt_D_dump_simpl`, `Flags.hs:477`): add
  `Opt_D_dump_webs_annot`, `Opt_D_dump_webs_solved`, `Opt_D_dump_webs_erased`
  and `Opt_D_dump_webs_stats`, with entries in `Session.hs` next to the
  `ddump-simpl` entry (`Session.hs:1512`).
- Optional: `-fcore-webs-check-roundtrip` turns on the erase∘annotate = id
  check (§6).

### 1.3 Pipeline hook — `GHC/Core/Opt/Pipeline/Types.hs`, `GHC/Core/Opt/Pipeline.hs`

- Add a `CoreDoWebs` constructor to `data CoreToDo` (`Pipeline/Types.hs:34`) and
  an `Outputable` case (`text "Webs"`).
- In `getCoreToDo` (`Pipeline.hs:120`), append
  `runWhen (gopt Opt_CoreWebs dflags) CoreDoWebs` at the very end of the list,
  after `add_late_ccs` (≈ line 350). This places it after every Core
  optimisation, including the final demand analysis, as `PLAN.md` requires.
- In `doCorePass` (`Pipeline.hs:459`), add
  `CoreDoWebs -> GHC.WebCore.Pipeline.webPass guts`.
- No change is needed in `GHC/Driver/Main.hs`: `hscSimplify'` → `core2core`
  (`Main.hs:1870`) already runs the list, and `runCorePasses` calls `endPass`
  afterwards, which runs the normal Core Lint under `-dcore-lint` and the dumps.
  GHCi's `hscCompileCoreExpr` path is out of scope for now.

---

## 2. Pass 1 — Initial Annotation

### 2.1 Webs on arrows — `GHC/Core/TyCo/Rep.hs`

```haskell
| FunTy { ft_af :: FunTyFlag, ft_mult :: Mult
        , ft_web :: !WebId                 -- NEW: always present
        , ft_arg :: Type, ft_res :: Type }
```

- `mkFunTy` (`:689`), `mkVisFunTy`, `mkScaledFunTy` and friends set
  `ft_web = placeholderWeb`. Add
  `mkWebFunTy :: WebId -> FunTyFlag -> Mult -> Type -> Type -> Type`.
- Substitution, `mapTyCo`, tidying and similar traversals rebuild arrows with
  record update (`ty { ft_mult = .., ft_arg = .., ft_res = .. }`; see
  `GHC/Core/TyCo/Subst.hs:799` and `GHC/Core/Type.hs:915`). Those keep webs with
  no change. The copied linter calls `substTy` constantly, so this matters.
- Positional `FunTy af w a r` patterns and constructions stop compiling.
  Mechanically add `_` to patterns, and use `mkFunTy` or `placeholderWeb` for
  constructions. The heaviest files are `GHC/Core/Type.hs` (~70 mentions),
  `TyCo/Rep.hs` (~50), `Core/Unify.hs`, `TyCo/FVs.hs`, `Core/Coercion.hs`,
  `TyCo/Compare.hs`, `Core/Map/Type.hs`, `Types/RepType.hs`, `TyCo/Tidy.hs:238`,
  `Types/Var.hs`, `Builtin/Types*.hs`, `CoreToIface.hs`, and the `Tc/`, `Iface/`
  and `HsToCore/` code.
- `GHC/Core/TyCo/Compare.hs` (`:398`, `:714`, `:814`): `eqType` and
  `nonDetCmpType` **ignore** `ft_web`, so all existing GHC code behaves exactly
  as it does today. Web-sensitive equality lives in `GHC/WebCore/Compare.hs` (§3.2).
- Pretty-printing: in `GHC/Core/TyCo/Ppr.hs`, show a web as `a -[w12]-> b` only
  when it is not `placeholderWeb`, so ordinary dumps do not change. This needs a
  printing path that does not go through `IfaceType`, or a debug-only field there.
- `GHC/CoreToIface.hs` drops the field. After erasure every web is
  `placeholderWeb`, and interfaces do not serialize webs.

### 2.2 Webs on coercions — `GHC/Core/TyCo/Rep.hs`, `GHC/Core/Coercion.hs`

- **`FunCo`**: add `fco_web :: !WebId`. One web is shared by both sides, because
  a zero-cost cast cannot change a calling convention. `coercion_lr_kind`
  (`Coercion.hs:~2489`) builds `FunTy{ft_web = fco_web}`. `mkFunCo`, `mkFunCo2`
  and `mkNakedFunCo` (`Coercion.hs:831-843`) default to `placeholderWeb`; add a
  web-taking variant. `liftCoSubst`, `mkReflCo` on FunTy (it should copy
  `ft_web` into `fco_web`), `decomposeFunCo` and `GHC/Core/Coercion/Opt.hs` must
  keep the field.
- No other coercion constructor gains a field. Annotation recurses into the
  `Type`/`Var` payloads of `Refl`, `GRefl`, `TyConAppCo`, `AppCo`, `ForAllCo`,
  `CoVarCo` (the covar's type) and `UnivCo` (`uco_lty`/`uco_rty`).
- **`AxiomCo`** is left unchanged in the term. Its webbed kind comes from the
  exposed axiom signature in `WebSigs` (§2.5), which the copied linter reads
  (§3.3). The term is not changed, so erasure is exact.

### 2.3 New forms for web-annotated functions and calls — `GHC/Core.hs`

`data Expr b` (`Core.hs:253`) gets two new constructors. `Lam` and `App` are
unchanged:

```haskell
  | WebLam WebId b (Expr b)            -- \^w x. e    : t1 -[w]-> t2
  | WebApp WebId (Expr b) (Arg b)      -- e1 @^w e2   (value arguments only)
```

- Type abstractions and type applications (`Lam tyvar`, `App e (Type t)`) stay
  plain `Lam`/`App`; only *value* λs and calls get webs.
- Cases for the new forms are needed only where the web pipeline and its dumps
  need them:
  - `GHC/Core/Utils.hs`: `exprType` (`:129`, using `mkWebFunTy` for `WebLam`;
    for `WebApp`, the same logic as `App`), and `mkLamType` (`:164`) or a web
    variant.
  - `GHC/Core/Ppr.hs`: printing (`\^w12 x ->`, `f @^w12 a`).
  - `GHC/Core/Stats.hs` (`coreBindsStats`, used by dumps), `GHC/Core/Seq.hs`,
    `GHC/Core/FVs.hs`, and `GHC/Core/Map/Expr.hs` (used by the round-trip check).
- Every other exhaustive match on `Expr` (simplifier, CorePrep, CoreToStg,
  `CoreToIface`, the original Lint, and so on) gets
  `pprPanic "web form escaped erasure"`. The `-Wincomplete-patterns` warnings
  give the full list.
- Update `Note [GHC Formalism]` in `GHC/Core/Lint.hs`, which asks for this
  whenever `Expr` changes.

### 2.4 The annotation transform — `GHC/WebCore/Annotate.hs` (new)

```haskell
annotateProgram :: Module -> CoreProgram -> UniqSM (CoreProgram, WebSigs)
```

It traverses `mg_binds` and keeps an environment `IdEnv Id` (old binder → binder
with annotated type), much like `GHC.Core.Subst`:

- **Types** (`annType`): every term-level `FunTy` gets a fresh web. Rules:
  - Expand type synonyms that hide arrows with `coreFullView`; a `TyConApp` of a
    synonym has nowhere to put a web.
  - Annotate all value-level `FunTyFlag`s (dictionary arrows `=>` are real
    functions in Core).
  - Annotate inside type arguments: in `Maybe (Int -> Int)` and
    `id @(Int -> Int)`, the inner arrows classify terms.
  - Arrows inside kinds (tyvar kinds, `CastTy` kind coercions, `ft_mult`) keep
    `placeholderWeb`. Web Lint compares kinds ignoring webs (§3.2).
- **Binders**: `setIdType b (annType (idType b))` for every λ, let, letrec,
  case-binder, alt-binder and join-point binder. `setIdType` keeps `IdInfo`, so
  unfoldings and rules are left alone. Occurrences are replaced by looking up the
  env.
- **Value λ**: `Lam x e` with `isId x` becomes `WebLam w x' e'` with a fresh `w`.
  Web Lint ties `w` to the arrow of the λ's type.
- **Value call**: `App f a` with `not (isTypeArg a)` becomes `WebApp w f' a'`
  with a fresh `w`.
- **`Case` result type, `Type t` arguments, `Coercion co` arguments, `Cast`
  coercions**: annotated with fresh webs (`annCo` recurses structurally and gives
  every `FunCo` a fresh `fco_web`).
- **Global entities** (`isGlobalId`: imported Ids, DataCon workers, class
  selectors, primops) and **axioms** are not rewritten in the term. Their webbed
  types come from `WebSigs` (§2.5).
- **Exported binders** (`isExportedId`): every web in their annotated type is
  added to the exposed set.
- **Not annotated:** `mg_rules`, unfoldings, `Tick` payloads (`Breakpoint` Id
  lists only use the env).

### 2.5 Exposed webs: `WebSigs` — `GHC/WebCore/Sigs.hs` (new)

Every entity whose type is fixed outside this module gets one exposed signature,
created lazily the first time annotation or Lint needs it. It is an annotated
copy of the entity's type with fresh webs. Every use of the same entity shares
those webs, so flow through constructors, imported functions and newtypes is
linked.

```haskell
data WebSigs = WebSigs
  { ws_ids     :: IdEnv Type                -- global Id      -> exposed idType
  , ws_dcs     :: NameEnv Type              -- DataCon        -> exposed dataConRepType
  , ws_axioms  :: NameEnv [(Type, Type)]    -- CoAxiom branch -> exposed (lhs, rhs)
  , ws_exposed :: WebSet }                  -- all exposed webs
```

- `ws_exposed` contains every web in `ws_ids`, `ws_dcs` and `ws_axioms` (so
  every web involved in a coercion axiom is exposed), plus the webs in exported
  binder types (§2.4).
- Signatures are created inside annotation, which must therefore visit every
  `AxiomCo` and every `DataAlt`. Web Lint only reads signatures; a missing entry
  is a Web Lint error.
- Exposure is not needed to erase webs. It is the input that later
  transformations use: a web class that contains any exposed web keeps its
  calling convention.

---

## 3. Pass 2 — Modified Linting and Type Checking

### 3.1 The linter copy — `GHC/WebCore/Lint.hs` (new)

- Copy `GHC/Core/Lint.hs` (4017 lines). Keep the copy close to the original so
  upstream changes can be merged in by diff, and put a note at the top giving the
  upstream commit it was copied from (`cd3e8cceab`).
- Delete what web linting does not need: `lintPassResult`, interactive entry
  points, rule and unfolding linting (`lintCoreRule`, `lintIdUnfolding`;
  annotation does not touch rules or unfoldings), static-pointer and some
  `endPass` plumbing.
- `LintEnv` (`:2964`): add `le_web_sigs :: WebSigs`.
- `LintM` (`:3016`) threads `WarnsAndErrs`. In the copy, replace it with
  `data WebLintState = WLS { wls_warns, wls_errs :: Bag SDoc, wls_pairs :: Bag (WebId, WebId) }`
  and adapt `initL` (`:3337`). Add `recordWebPair :: WebId -> WebId -> LintM ()`,
  which drops pairs `(w, w)` as `PLAN.md` specifies.
- Entry point:
  `lintWebProgram :: LintConfig -> WebSigs -> CoreProgram -> (Bag SDoc {-errs-}, Bag (WebId,WebId))`,
  modelled on `lintCoreBindings'` (`:462`).

### 3.2 Web-collecting equality — `GHC/WebCore/Compare.hs` (new)

```haskell
eqTypeWebs :: Bool {-check mult-} -> Type -> Type -> Maybe (Bag (WebId, WebId))
```

A copy of the equality logic in `TyCo/Compare.hs` (`:393-420`, `:653-750`):
`RnEnv2` for foralls, `coreView`, casts. The `FunTy` case recurses and emits
`(ft_web t1, ft_web t2)` when they differ. Multiplicity handling mirrors
`eq_type` (`Lint.hs:3599`, `lf_check_linearity`). Kinds are compared with the
ordinary `eqType`, which ignores webs.

### 3.3 Changes inside the copy (line numbers refer to the original)

| Site | Change |
|---|---|
| `ensureEqTys` (`:3590`), `eq_type` (`:3599`) | Use `eqTypeWebs` and record pairs |
| other direct `eqType` uses (12 sites, e.g. `lintJoinBndrType` `:1114`, `addrPrimTy` check `:606`, `lintTyKind` `:1574`) | Value-type comparisons go through `ensureEqTys`; kind comparisons stay `eqType` |
| `lintCoreExpr` (`:866`) | New `WebLam` case (like `Lam`, `:1007`) and `WebApp` case (like `App`, `:958`). A plain `Lam` over a value binder or a plain value `App` is an **error** ("unannotated function/call") |
| `lintLambda` (`:1083`) | `WebLam w x` returns `mkWebFunTy w …` |
| `lintCoreFun` (`:1066`) | Handle `WebLam` heads in beta redexes |
| App spine (`collectArgsTicks` at `:983`, `lintCoreArgs` `:1458`, `lintApp` `:2132`, `lintValApp` `:1556`) | Collect a `WebApp` spine, pairing each value arg with its call web. In `lintApp`'s `go … (FunTy …)` case (`:2177`), record `(call web, ft_web)` |
| `lintIdOcc` / `lintVarOcc` (`:1025`) | Global Ids take their type from `ws_ids`. `runRW#` (`:958`) and `checkRepPolyBuiltin` keep working because the term still has `Var` heads |
| `lintCoreAlt` DataAlt (`:1727`) | `con_payload_ty` instantiates the `ws_dcs` signature instead of `dataConRepType con` |
| `lintAltBinders` (`:1492`), `lintCoreExpr (Cast …)` (`:886`) | Already go through `ensureEqTys`, so they record pairs |
| Every `coercionKind` / `coercionLKind` / `coercionRKind` / `substCoKindM` call | Replace with `webCoercionKind sigs`. It is the same as `coercionKind` (`Coercion.hs:2485`), except that `AxiomCo` takes its sides from `ws_axioms` |
| `lintType (FunTy …)` (`:1994`), `lintArrow` (`:2084`), `lintCoercion (FunCo …)` (`:2471`) | Error if a term-level arrow still holds `placeholderWeb`. This is the "web function type checked against a non-web function type" error from `PLAN.md` |
| `lintCoercion` cases that compare kinds internally (`TransCo` `:2557`, `InstCo`, `AppCo`, …) | Route value-type comparisons through the collector |

### 3.4 Solving — `GHC/WebCore/Solve.hs` (new)

```haskell
solveWebs :: WebSet {-exposed-} -> Bag (WebId, WebId) -> (WebSubst, WebSet {-exposed classes' reps-})
```

- Union-find over the pairs. `GHC/Data/UnionFind.hs` exists (ST-based, used by
  `CmmToAsm/CFG.hs`); a pure `UniqFM` with path compression is also fine.
- The representative is an exposed member when the class has one, and otherwise
  the smallest `Unique`, so results are deterministic across runs (see
  `Note [Unique Determinism]`). A class containing an exposed web is exposed.
- Statistics for `-ddump-webs-stats`: number of webs, number of classes,
  exposed classes, and class-size histogram.

---

## 4. Pass 3 — Renaming

`GHC/WebCore/Traverse.hs` (new) holds one generic traversal that the rename and
erase passes share:

```haskell
mapWebsType :: (WebId -> WebId) -> Type -> Type          -- ft_web
mapWebsCo   :: (WebId -> WebId) -> Coercion -> Coercion  -- fco_web, payload types
mapWebsExpr :: (WebId -> WebId) -> IdEnv Id -> CoreExpr -> CoreExpr
```

- `mapWebsExpr` rewrites `WebLam`/`WebApp` webs, binder types (keeping an
  `IdEnv` so occurrences match binders, as in annotation), `Case` types,
  `Type`/`Coercion` arguments and casts.
- `GHC/WebCore/Rename.hs`: `renameProgram :: WebSubst -> CoreProgram -> CoreProgram`
  = `mapWebs (lookup in subst)`. `WebSigs` is renamed the same way.
- **Check**: in `GHC/WebCore/Pipeline.hs`, rerun `lintWebProgram` on the renamed
  program. Panic, with a dump, if any errors occur or if the pair bag is
  non-empty.

---

## 5. Pass 4 — Erasure

`GHC/WebCore/Erase.hs` (new): `eraseProgram :: CoreProgram -> CoreProgram`

- `WebLam _ x e` → `Lam x e`; `WebApp _ f a` → `App f a`.
- Every `ft_web` and `fco_web` → `placeholderWeb` (with
  `mapWebs (const placeholderWeb)`).
- Binders: `setIdType b (eraseType (idType b))`. `IdInfo` was never changed.
- Global Ids, DataCons and axioms were never rewritten in the term; drop `WebSigs`.
- The result is ordinary Core. `endPass CoreDoWebs` (run by `runCorePasses`)
  lints and dumps it as for any other pass. The normal Lint cannot tell real webs
  from placeholders (it ignores the field), so the pipeline checks this itself
  with an `assertNoWebs` traversal in debug builds.

---

## 6. `GHC/WebCore/Pipeline.hs` (new)

```haskell
webPass :: ModGuts -> CoreM ModGuts
webPass guts = do
  us <- getUniqueSupplyM
  let (binds1, sigs) = initUs_ us (annotateProgram (mg_module guts) (mg_binds guts))
  dump Opt_D_dump_webs_annot binds1
  let (errs, pairs) = lintWebProgram cfg sigs binds1      -- errors => panic + dump
      (subst, exposed) = solveWebs (ws_exposed sigs) pairs
      sigs2  = renameSigs subst sigs
      binds2 = renameProgram subst binds1
  dump Opt_D_dump_webs_solved binds2
  let (errs2, pairs2) = lintWebProgram cfg sigs2 binds2
  massert (isEmptyBag errs2 && isEmptyBag pairs2)
  let binds3 = eraseProgram binds2
  when roundtrip_check $ massert (binds3 `alphaEqBinds` mg_binds guts)
  return guts { mg_binds = binds3 }
```

- Round-trip oracle: annotation adds webs and changes nothing else, so
  `erase (rename (annotate p))` must be α-equivalent to `p`, including binder
  types. Use `GHC/Core/Map/Expr.hs` (`eqDeBruijnExpr`) per binding. This is the
  main correctness test until real transformations exist.
- Build `LintConfig` with the same helper that `endPass` uses
  (`GHC/Driver/Config/Core/Lint.hs`).

---

## 7. Testing and benchmarks (the first lines of `PLAN.md`)

- **Build**: `./boot && ./configure && hadrian/build -j --flavour=devel2`
  (`quick` for faster iteration; not `validate`, whose `-Werror` would fail on
  the panic stubs while they are in progress). The resulting compiler is
  `_build/stage1/bin/ghc`.
- **Unit-style tests**: add `testsuite/tests/webs/` with an `all.T`, using
  `extra_hc_opts('-fcore-webs -dcore-lint -ddump-webs-solved -dsuppress-uniques')`
  and `.stderr` golden files. Cover: higher-order functions, a local function
  passed to two different callers (webs merge), polymorphic `id`/`map`, a
  `newtype` over a function (axiom ⇒ exposed), data fields with functions
  (DataCon ⇒ exposed), type-class dictionaries, exported vs. local binders, join
  points, `runRW#`, unboxed tuples, letrec. Run with
  `hadrian/build test --test-root-dirs=testsuite/tests/webs`.
- **Whole-suite smoke test**: run the existing suite with `-fcore-webs` and
  `-dcore-lint` added (for example through `EXTRA_HC_OPTS`), checking that no
  outputs change. This holds while the pipeline is an identity.
- **Benchmarks**: `/nofib` is already checked out (`imaginary`, `spectral`,
  `real`, `gc`). Build the testing script on the nofib `Makefile`/`nofib-run`
  with `EXTRA_HC_OPTS=-fcore-webs`. Measure (a) the extra compile time and
  allocation of the web pass, using `-ddump-webs-stats` and `+RTS -s` on GHC, and
  (b) that runtime is unchanged. Record web counts, class sizes and the exposed
  fraction per module as a baseline for later transformations.

---

## 8. Remaining open points

1. **Unfoldings and RULES** stay unannotated. They become a problem only when a
   real transformation changes a function's type (only for non-exposed webs),
   because stable unfoldings and rules for that function would then be out of
   date.
2. **Keeping the Lint copy in sync**: there is no mechanism yet; merge upstream
   changes to `GHC/Core/Lint.hs` by hand when rebasing.
