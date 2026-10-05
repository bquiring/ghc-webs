# Design: Result Raising (Web CPR)

Status: implemented in `GHC/WebCore/Transform/ResultRaise.hs`
(`-fcore-webs-result-raise`, dump `-ddump-webs-result-raise`).

This is the web version of GHC's CPR worker/wrapper (item 1 of
`WEBS-WW-SURVEY.md`). GHC's CPR analysis finds functions that always return a
freshly constructed product. Worker/wrapper then splits each one into a worker
that returns the components in an unboxed tuple, and a wrapper that boxes them
again; the wrapper is inlined at known calls. A web knows *every* lambda that
can reach a call and *every* call that a lambda can reach. So the calling
convention can change for all of them at once, at unknown calls too, without a
wrapper.

## The transformation

For a web `w` whose arrows all return a product `T` (single constructor `K`,
no existentials; `productCon` in arity raising):

```
type:        A -{w}-> T ts                 ==>   A -{w}-> (# c1, .., cn #)
lambda:      \^w x. ... K e1 .. en ...     ==>   \^w x. ... (# e1, .., en #) ...       (tails)
call:        f @^w a                        ==>   case f @^w a of (# y1, .., yn #) -> K y1 .. yn
scrutinised: case f @^w a of b { K ys -> rhs }
                                            ==>   case f @^w a of (# ys #) -> [let b = K ys in] rhs
```

The components `c1 .. cn` are the constructor's representation argument types
at `ts`.

**Tails.** The tails of a lambda's body are found by looking through `let`,
`case` alternatives, ticks, and join points bound in tail position. A join
point bound in tail position returns the tuple too, so its type changes.
A lambda qualifies when every tail is one of:

- a saturated application of `K`;
- a dead end (e.g. `error ...`), which is then taken apart with `case`; this
  costs nothing;
- a jump to a join point bound in tail position;
- a tail call of `w` itself, which already returns the tuple once rewritten.

Any other tail (a variable, or a call of another function) rejects the web,
as in GHC's CPR: taking it apart would cost more than the boxing saves. At
least one tail must construct.

## Laziness

Nothing changes:

- The components stay lazy: building and matching an unboxed tuple evaluates
  nothing.
- A call in a lazy position stays lazy, because the re-boxing `case` is inside
  the thunk (`let r = case f a of (# ys #) -> K ys`).
- The definition still evaluates exactly what it evaluated before.

## Eligibility

A web is rejected if:

- it is exposed;
- one of its lambdas is a join point's (calls are jumps, which cannot be
  scrutinised);
- some arrow's result is not a product, or the products differ between arrows;
- a component is representation-polymorphic;
- the web appears in a coercion whose result part cannot be split;
- a tail does not construct, or no tail constructs.

## Tests

`resultraise001`–`005`, all run with `-O -fcore-webs -fcore-webs-result-raise
-dcore-lint`. **(L)** marks a laziness test.

| Test | Shape |
|---|---|
| `resultraise001` | two functions returning pairs, called through an unknown call |
| `resultraise002` **(L)** | call in a lazy `let` whose components diverge; must not be evaluated |
| `resultraise003` | pair built in several branches, through a join point |
| `resultraise004` | rejections: a tail returns a stored pair; a polymorphic result |
| `resultraise005` | the case binder of the scrutinised call is used (re-boxing) |
