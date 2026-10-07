# Design: Defunctionalisation over Webs

Status: implemented in `GHC/WebCore/Transform/Defunc.hs`
(`-fcore-webs-defunc`, dump `-ddump-webs-defunc`). Version 1: monomorphic
webs whose calls are all unknown. Survey §13.

An unknown call (a call of a parameter, a field, the result of another call)
is an indirect jump through `stg_ap_*`, which GHC cannot inline or
specialise. A non-exposed web lists every lambda that can reach its calls.
So the web's function values can be replaced by the values of a data type,
one constructor per lambda, and its calls by a call of one apply function
that cases on the constructor. This is Reynolds' defunctionalisation,
applied web by web, as in the paper.

## The transformation

For a web `w` with lambdas `L1 .. Ln`, where `Li = \^w x. ei` has free local
variables `vi1 .. vik`:

```
data D_w = C_1 t11 .. t1k | ... | C_n tn1 .. tnk     -- new, local to the module

Li            ==>   C_i vi1 .. vik
f @^w a       ==>   $apply_w f a
A -{w}-> B    ==>   D_w                               -- in every type

$apply_w :: D_w -> A -> B
$apply_w = \fd x. case fd of { C_i yi1 .. yik -> ei[yij/vij, x/xi] ; ... }
```

Each lambda body moves, unchanged except for renaming, into an alternative
of `$apply_w`. The pass runs after the other web transformations, since it
changes types. It is the last step of the web pipeline.

Afterwards every call of `w` is a *known* call of `$apply_w`. In the early
run (`-fcore-webs-early`), GHC's simplifier and SpecConstr then:

- inline `$apply_w` where it is small;
- take the `case` apart where the constructor is visible
  (case-of-known-constructor);
- merge consecutive calls (case-of-case);
- specialise a higher-order function on the constructor it is given.

Test `defunc001`: in `twice f x = f (f x)`, called with two lambdas, `twice`
becomes one `case f of` whose two alternatives contain both calls, inlined.

## Conditions (version 1)

- **Not exposed.** The web's lambdas and calls are all in this module.
- **No join points.** A jump is not a call.
- **Only unknown calls.** Defunctionalisation would turn a known call of a
  let-bound function into a call of `$apply_w` and a `case`. In a recursive
  function, that `case` cannot be resolved statically: the function is a loop
  breaker, so its constructor is not visible. Test `defunc004` (`go`).
- **At most 8 lambdas.** `$apply_w` has one alternative per lambda.
- **Monomorphic.** Every arrow of `w` in the program has closed argument and
  result types, and no lambda has free type or coercion variables. A
  polymorphic web needs a GADT `D_w a b` with an equality per constructor
  (Pottier and Gauthier's typed defunctionalisation). Not done; the verdict
  dumps count how often it matters (`defunc004`, `twiceP`).
- **Not in a coercion.** Coercions are not rewritten.
- **Fields.** Every free variable has a fixed runtime representation, and is
  not an unboxed tuple or sum.

## Laziness and sharing

A lambda is a value, and so is a constructor application. Fields are lazy
(not marked strict), so a captured thunk is still evaluated at most once, and
only if the body forces it. Test `defunc002` checks both: a traced free
variable is evaluated once over three calls, and a captured `error` that the
body never forces is never forced. A variable of the arrow type that is
bound to a thunk is now a thunk of type `D_w`; `seq` on it behaves the same.

## IdInfo

A binder whose type mentions `w` gets its type rewritten.

- If it was bound to a lambda of `w`, it is now bound to a constructor: arity
  0, no demand signature.
- Call demands on it lose their call structure (it is data now), but keep
  their strictness and cardinality.
- CPR signatures go, and so do stale unfoldings (Note [Unfoldings and rules
  after a transformation]).

## The new types

Each web's `TyCon` and `DataCon`s are built the way GHC builds wired-in types
(`mkAlgTyCon`, `mkDataCon`, `mkDataConWorkId`), with External names in the
current module (`Defun1`, `Defun1_1`, ...), lazy fields, and no wrappers. A
field type may mention another web's new type, so the types are built in one
knot, as the typechecker does for recursive data types. The pipeline adds
them to `mg_tcs`, so the code generator makes their info tables, and an
unfolding that mentions them can reach the interface file.

## Next steps

- Measure on nofib: how often each condition rejects a web
  (`webs-bench/results/verdicts-defunc.md`), and the effect on instructions.
- Polymorphic webs (a GADT encoding).
- Webs with known calls: keep the function for known calls and use the
  constructor only where it escapes.
- With the boundary split (`-fcore-webs-boundary`), many more webs are
  local.
