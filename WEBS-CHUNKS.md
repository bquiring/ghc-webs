# Webs: compiling chunks of a program together

Draft, 2026-10-14. Toward whole-program compilation: compile a chunk of a
program (a package, or a set of modules) as one Core program, so that webs
see every call inside the chunk. Not implemented; this is the design to
discuss before any code.

## 1. Why: what keeps the passes from firing

Firing counts building GHC's stage-1 compiler (the `ghc` package and the
libraries the boot compiler builds for it: 1,091 modules) with early-ulsl's
options, against nofib's 442 modules (`verdicts.py`, 2026-10-14):

| pass | nofib fired / webs | GHC fired / webs | GHC: exposed |
|---|---|---|---|
| useless | 441 / 23,669 | 6,700 / 188,503 | 78,698 |
| const-prop | 34 / 23,526 | 768 / 188,340 | 78,698 |
| inline | 27 / 23,534 | 711 / 188,377 | 78,698 |
| strictness | 58 / 23,295 | 523 / 182,770 | 78,698 |
| defunc | 105 / 20,860 | 514 / 145,449 | 79,429 |
| arity-raise | 62 / 23,666 | 92 / 188,479 | 78,698 |
| result-raise | 14 / 23,666 | 20 / 188,479 | 78,698 |

Data splitting: 71% of GHC's classes of copies are exposed (89,925 of
127,536 over both runs); 3,668 split.

### 1.1 The other rejections are mostly "nothing to gain"

Apart from exposure, the largest verdicts are not restrictions to lift:

* **Arity raising**, "only known calls (early: left to worker/wrapper)":
  106,538. Worker/wrapper raises these after the web pass, and unboxes
  further (Note [Early arity raising]); raising them in the web pass doubled
  allocation on spectral/dom-lt and mate. "Argument not a product" (2,266)
  is what the transformation needs. What is left is small: lazy (518),
  complex coercion (279), the product used boxed (48), curried (40).
* **Defunctionalisation**, "no unknown calls": 63,445. Nothing to
  defunctionalise. The restrictions proper are small: one lambda (1,246,
  measured harmful: real/eff/CS +156%), in a coercion (490), absorbed (140).
* **Strictness**, "strict argument (no change)": 55,312 (demand analysis
  already has them) and "lazy": 48,289 (lazy). Strict result fields stop at
  "unknown call context" (61,162: a call whose result is not scrutinised
  directly, e.g. passed on or bound lazily); extending the context through
  returns is a possible design change, not yet measured.

So exposure is the lever: 42% of webs (and 70% of data-splitting classes)
are exposed, and no pass looks at them.

### 1.2 What exposes them

Exposed lambda classes in GHC by origin, counting only those with a single
origin (`-ddump-webs-stats`):

| origin | classes |
|---|---|
| kept binder: in an unfolding or rule (closure of kept binders' stable unfoldings and rules; mostly, by the modules it is in, instance methods that dictionary unfoldings mention) | 26,360 |
| kept binder: exported (boundary wrapper) | 20,569 |
| kept binder: exported | 9,896 |
| constructor (data and class dictionary constructors) | 8,210 |
| imported from base / ghc-internal | 2,075 |
| kept binder: free in rules | 1,543 |
| imported (other modules) | 1,137 |
| axiom (newtype) | 665 |

Exports (30,465) and the unfolding closure (26,360) dominate. Imported
library functions are a small share.

## 2. Cheaper steps first

### 2.1 Split kept binders (exists: -fcore-webs-boundary-kept)

Kept binders that only rules and unfoldings mention are split like
exported functions (Note [Splitting kept binders]). On nofib (2026-10-13
audit) it made 1,767 more classes internal (useless 436 -> 594 fired,
inline 25 -> 44) with the same runtime (-4.17% instructions, as without).
Never adopted. On GHC it makes 25,586 more classes internal and adds 3,567
useless eliminations (§5).

### 2.2 Unused exports

GHC records, in each interface's usages, the names a module uses from each
module of its own package, but only the module for other packages. From
those (no compiler change; `unused-ghc.py`): of the `ghc` package's 15,258
exported values, 2,482 (16%) are used by no module, counting a module that
another package imports as fully used (155 modules). Most are constants
(GHC.Builtin.Names: 445, GHC.Builtin.Names.TH: 307, instruction
constructors' helpers of other architectures), without webs. So cutting
unused exports gains little; within a chunk, nearly all exports are used
only inside it, which is what §3 is for.

A two-pass version would be simple if wanted: build once, collect usages
(within a package; across packages with `-ddump-minimal-imports`), and
rebuild with the list of unused exports treated as internal by keptIds.
Sound because importers are recompiled against the new interfaces.

## 3. Chunks

A chunk is a set of modules compiled together: their Core is merged into
one program before the web passes, and only what outside modules (and
`main`) use stays exposed.

### 3.1 Design: merge at the end of the chunk

1. **Build the chunk normally**, every module with
   `-fwrite-if-simplified-core` (GHC since 9.4): each interface carries the
   module's tidied Core (`mi_simplified_core`), as for GHCi's bytecode. Webs
   off, or the per-module early run on.
2. **Merge.** A new driver mode, `ghc --webs-chunk M1 .. Mn` (or a front-end
   plugin), loads the chunk's interfaces, and turns their Core back into
   bindings with `typecheckWholeCoreBindings` (GHC.IfaceToCore: what
   `-fbyte-code-and-object-code` uses to rebuild code from an interface).
   Names stay External (they are unique: module plus occurrence), so the
   merged program needs no renaming.
3. **Roots** (what keeps its type): `main`; every name that a module outside
   the chunk uses (usages of the modules outside, `-ddump-minimal-imports`
   for other packages); instance dictionaries (anything can use them);
   foreign exports; the free variables of RULES of names outside the chunk.
   Everything else is internal: keptIds gets the roots instead of
   `isExportedId`.
4. **Web passes and the simplifier** on the merged program: the late run
   (this is optimised Core), then the simplifier, as `-fcore-webs-late`.
5. **Code generation**: one object for the chunk, from the merged program,
   replacing the chunk's objects at link time. Foreign stubs from each
   module's `wcb_foreign`. The interfaces stay as built in step 1: modules
   outside the chunk see the roots' original types.

### 3.2 Alternative: keep the session

A front-end plugin compiles the chunk in one session: typecheck, desugar
and simplify each module in dependency order, write each interface from its
own typechecked types (so outside modules see the original types), keep
the ModGuts, and generate code only once all are done, after merging. No
round trip through interfaces, and the early run could see the merged
program before worker/wrapper. More GHC driver work (the `--make` pipeline
generates code module by module).

### 3.3 What is hard

* **Memory and time.** The merged program is the chunk. GHC's
  GHC.Tc.Errors.Types alone needs ~6 GB under data splitting. The `ghc`
  package as one chunk is out of reach for now; a group of modules (a
  directory, a dependency cluster) is not.
* **Code generation of several modules' names** in one object: symbols are
  module-qualified already, but module initialisation, SPT entries
  (static pointers), and HPC/profiling ticks assume one module per object.
  Leave out programs that use them.
* **Template Haskell** in the chunk: splices run against the per-module
  build; the merged object must not be needed by them.
* **The early run** works before worker/wrapper and the main simplifier;
  merged Core from interfaces is after them. The late run's results
  (WEBS-EXPERIMENTS) are weaker than the early run's.

### 3.4 Plan

1. Prototype §3.1 on nofib's multi-module programs (whole program = chunk):
   compare the late run on the merged program against early-ulsl per
   module. Measure firing counts (§1) and instructions.
2. Then chunks of the large programs: one package (e.g. a dependency of
   ShellCheck or hledger), then module clusters of GHC.
3. Choose between §3.1 and §3.2 by what the prototype shows about the
   early versus late run.

## 4. Open questions

* Is the late run on merged Core enough, or does chunking need the early
  run (§3.2)?
* Instance methods (the unfolding closure) stay exposed even in a whole
  program: their types are the class's. Splitting class dictionaries like
  data types (WEBS-DATA.md) would be the next step.

## 5. GHC with -fcore-webs-boundary-kept

The same build with `-fcore-webs-boundary-kept` (2026-10-14; the split adds
webs, so the totals grow):

| | early-ulsl options | + boundary-kept |
|---|---|---|
| lambda classes | 188,377 | 225,350 |
| internal | 109,679 | 135,265 (+25,586) |
| useless: deleted / unit | 5,445 / 922 | 7,754 / 2,180 |
| inline | 711 | 907 |
| defunc | 514 | 546 |
| strictness (strict argument) | 452 | 472 |
| arity-raise | 92 | 102 |
| const-prop, result-raise | 768, 20 | 768, 20 |

The unfolding closure moves to the wrappers (36,328 classes "in an
unfolding or rule (boundary wrapper)": the wrappers keep the types), and the
local copies become internal. Useless elimination gains most (+3,567);
the others little. Runtime not measured on GHC.
