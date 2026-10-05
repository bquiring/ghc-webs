# Design: Web Transformations as Worker/Wrapper

Status: design. The passes in `GHC/WebCore/Transform/` will be re-expressed
in this form, one at a time.

## The idea

GHC's worker/wrapper splits a function `f` into a worker and a wrapper so
that `f = wrap work`, where `work = unwrap f`. Its correctness rests on one
identity, `wrap . unwrap = id`. Every web transformation is the same thing,
done for a whole web at once:

- **Definitions:** every lambda `λ` of the web (at type `T`) becomes
  `unwrap_T λ`, at the new type `T'`.
- **Calls:** every call `f a1 .. an` of the web becomes
  `(wrap_T f) a1 .. an`.
- **Types:** every arrow of the web goes from `T` to `T'`.

Then beta-reduce. `wrap` and `unwrap` are known lambdas, so the extra
applications disappear.

**Why it is correct.** In a non-exposed web, every function value that
reaches a call is some `unwrap λ` (or bottom; see below). So the call
computes `wrap (unwrap λ) a1 .. an`. If `wrap . unwrap = id` on every lambda
of the web, the call computes `λ a1 .. an`, exactly as before. The
condition is checked **per lambda**, and it is the *only* condition. All of
the passes' laziness rules (curried lambdas, partial applications, forced
values, sharing) are instances of it.

**Two rules for wrap and unwrap.**

1. **`wrap` forces its argument first:** `wrap g = case g of g' -> ...`.
   Values of the web's type that are not lambdas are bottom (`undefined`,
   `error`, a loop). Exposed values are excluded by not transforming exposed
   webs. A wrapper that did not force `g` would turn bottom into a lambda,
   and `seq (f a) ()` on a partial application would then terminate. With
   the `case`, `wrap ⊥ = ⊥`. When `g` is already a value (a variable bound
   to a lambda, a function with arity > 0), the `case` costs a tag test,
   and simplifies away when the function is known.
2. **`wrap` and `unwrap` are closed.** They are built from the arrow's type
   alone, so they can be placed at any definition or call. When a pass needs
   to mention something, such as a constant or an inlined lambda, it may
   only mention top-level or imported binders. Those are in scope
   everywhere, provided the top-level bindings are re-sorted into dependency
   order (Note [Top-level binding order]).

**Beta reduction keeps laziness.** `(\x. e) a` becomes `let x = a in e`
(or substitution when `a` is trivial), never `case a of x -> e`. So
arguments stay lazy and shared. Evaluation appears only where `wrap` or
`unwrap` contain an explicit `case`.

## Contexts: definitions and calls

`unwrap` is evaluated where the lambda is defined, and `wrap` where the
function is called. The two contexts are different: `wrap (unwrap λ)` never
appears in a single context. So:

- **`wrap` and `unwrap` must not have free references.** Any variable they
  mention would be looked up in two different environments. Top-level and
  imported binders are allowed: they denote the same binding everywhere
  (given dependency order, Note [Top-level binding order]).
- **The identity may be justified by facts about the lambda** ("`λ` ignores
  its argument", "`λ` is strict in it"). Those are facts about the
  definition's context, where `unwrap` runs.
- **It may also be justified by facts about the calls**, if what moves from
  the call context into the definition means the same thing in both.
  "Every call passes the constant `c`" justifies `unwrap λ = \x -> λ c`
  when `c` is closed: at the definition, `c` is the same value the calls
  pass. "Every call passes the variable `x`" does not justify
  `\_ -> λ x`, which is known-argument elimination: at the definition, `x`
  is out of scope, or is a different binding (another activation). Facts
  that move nothing (every caller forces field 1 of the result) are fine.

## The passes

Below, `T = A -> B -> R` etc. are the arrows of the web, `K` is a product
constructor, and `ys` are fresh binders.

| pass | `unwrap λ` (new definition) | `wrap g` (used at calls) | condition for `wrap (unwrap λ) = λ` |
|---|---|---|---|
| dead parameter, delete | `λ ⊥`, at type `B` | `case g of g' -> \_ -> g'` | `λ` ignores its argument, and `\_ -> (λ ⊥)` is `λ` up to `seq` on the lambda: so the web's values must never be forced (`wi_forced`), and `B` lifted |
| dead parameter, unit | `\(_ :: (# #)) -> λ ⊥` | `case g of g' -> \_ -> g' (# #)` | `λ` ignores its argument |
| uncurry | `\(# a, b #) -> λ a b` | `case g of g' -> \a b -> g' (# a, b #)` | `λ = \a -> \b -> e` *syntactically* (a direct lambda). Otherwise work between the two lambdas is no longer shared between partial applications (a cost, not a semantic change; still rejected) |
| arity raise | `\(# xs #) -> λ (K xs)` | `case g of g' -> \p -> case p of K xs -> g' (# xs #)` | `λ` is strict in `p` *when applied to one argument*: `wrap (unwrap λ) p = case p of ...` forces `p` even for a partial application. Hence "strict, and not curried" |
| result raise (CPR) | `\a -> case λ a of K ys -> (# ys #)` | `case g of g' -> \a -> case g' a of (# ys #) -> K ys` | always holds: `case (λ a) of K ys -> K ys = λ a` for a product type (`λ a` is `⊥` or `K ..`) |
| strict argument | `λ` (unchanged) | `case g of g' -> \x -> case x of x' -> g' x'` | `λ` is strict in `x` when given as many arguments as the call supplies (saturation depth) |
| constant argument | `\x -> λ c` (then `x` is dead) | `g` | every call passes `c`, and `c` is closed: a literal, a constructor applied to closed constants, or a top-level or imported variable. **Not** a local variable: that would be known-argument elimination. (A lambda with no free variables is also a constant; not implemented, since full laziness floats such lambdas to the top level, where they are top-level variables) |
| strict result field | `\a -> case λ a of K y1 y2 -> case y1 of y1' -> K y1' y2` | `g` | every call takes the result apart and forces field 1 (nothing moves between contexts) |
| constant result | `λ` | `case g of g' -> \a -> case g' a of _ -> c` | `λ a` is `c` or `⊥`; `c` is closed |
| super-beta inlining | `λ` | `case g of _ -> L` (`L` the only lambda) | the web has one lambda; `L` is closed (mentions only top-level binders) |

What the table shows:

- **Each existing laziness rule is an instance of the one condition.**
  "Arity raising rejects curried lambdas" is the failure of
  `wrap (unwrap λ) = λ` for a lambda that is strict only when saturated.
  Uncurrying's eta-expansion that "forces the function first and let-binds
  the argument" is beta-reduction of `wrap`. Dead-parameter deletion's
  "never forced" rule is the `seq` distinction between `\_ -> v` and `v`.
- **Beta reduction does the rest.** At a saturated call of a known lambda,
  `(case g of g' -> \a b -> g' (# a, b #)) x y` reduces to
  `case g of g' -> g' (# x, y #)`, and to `g (# x, y #)` when `g` is a
  value. At a partial application it reduces to
  `case g of g' -> let a = x in \b -> g' (# a, b #)`, which is correct for
  any `g`. There is no separate partial-application case to get wrong.
- **Constant results** become the `case` in `wrap`. Picking the alternative
  of a scrutinising `case` is then ordinary case-of-case and
  case-of-known-constructor, which the beta-reducer (or, in the early run,
  the simplifier) does.

## Implementation plan

1. **A generic engine** (`GHC/WebCore/Transform/WW.hs`). It is given, for
   each web to transform:
   - the new arrow type (the type mapping, as now);
   - `unwrapAt :: Type -> CoreExpr -> UniqSM CoreExpr` and
     `wrapAt :: Type -> CoreExpr -> UniqSM CoreExpr`, built from the
     occurrence's type. A web is polymorphic across its occurrences, so
     both are instantiated per occurrence.

   The engine rewrites every lambda group of the web to `unwrap λ`, and every
   call spine to `wrap f` applied to the arguments. Then a small beta-reducer
   runs: beta with `let`, case-of-known-constructor, and dropping `case` on
   a variable known to be a value. It also does what the passes share:
   rewriting types and coercions, fixing binder info, unfoldings and usage,
   and running Web Lint after each round.
2. **Each pass keeps its analysis.** The analysis decides which webs satisfy
   the condition. Each pass's rewrite is replaced by its `wrap` and `unwrap`.
   One pass at a time, starting with uncurrying (the most laziness-sensitive),
   with the existing tests as the check. The laziness tests in particular
   must keep passing, and the mutation checks must still fail them.
3. **Delete the per-pass rewrite code**: `rw_spine`, `eval_if`,
   `rw_partial`, `replaceCases` and so on. They become `wrap`, `unwrap` and
   the beta-reducer.
