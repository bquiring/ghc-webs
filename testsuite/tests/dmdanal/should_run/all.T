# Run this always as we compile the test with -O0 and -O1 and check that the
# output is correct and the same in both cases.
test('T16197', normal, makefile_test, [])

# Run the rest only in optasm way (which implies -O), we're testing the
# strictness analyser here
setTestOpts( only_ways(['optasm']) )

test('strun001', normal, compile_and_run, [''])
test('strun002', exit_code(1), compile_and_run, [''])
test('strun003', normal, compile_and_run, [''])
test('strun004', normal, compile_and_run, [''])
test('T2756b', normal, compile_and_run, [''])
test('T7649', normal, compile_and_run, [''])
test('T9254', normal, compile_and_run, [''])
test('T10148', normal, compile_and_run, [''])
test('T10218', normal, compile_and_run, [''])
test('T11076', normal, multimod_compile_and_run, ['T11076.hs', 'T11076_prim.cmm'])
test('T11555a', normal, compile_and_run, [''])
test('T12368', exit_code(1), compile_and_run, [''])
test('T12368a', exit_code(1), compile_and_run, [''])
test('T13380', exit_code(1), compile_and_run, [''])
test('T13380d', exit_code(1), compile_and_run, [''])
test('T13380e', exit_code(1), compile_and_run, [''])
test('T14171', [expect_broken(14171), exit_code(1)], compile_and_run, [''])
test('T14290', normal, compile_and_run, [''])
test('T14285', normal, multimod_compile_and_run, ['T14285', ''])
test('T17676', normal, compile_and_run, [''])
test('T19053', normal, compile_and_run, [''])
test('T21717b', normal, compile_and_run, [''])
test('T22475', normal, compile_and_run, [''])
test('T22475b', normal, compile_and_run, [''])
# T22549: Do not strictify DFuns, otherwise we will <<loop>>
test('T22549', normal, compile_and_run, ['-fdicts-strict -fno-specialise'])
test('T23208', exit_code(1), multimod_compile_and_run, ['T23208_Lib', 'T23208'])
test('T25439', normal, compile_and_run, [''])

# Higher-order worker/wrapper, -fworker-wrapper-function-results
# (Note [Worker/wrapper for function results] in GHC.Core.Opt.WorkWrap).
# Each checks that the split does not change the program's meaning:
#   wwfunres001: g n diverges before returning its function; with
#                -fpedantic-bottoms, seq (g n) () must still diverge (the
#                wrapper uses a case, not a let)
#   wwfunres002: work before the returned function is shared per partial
#                application (Debug.Trace)
#   wwfunres003: an argument lazy in one returned function is not unboxed
#   wwfunres004: partial applications that escape and are forced
test('wwfunres001', normal, compile_and_run, ['-O -fworker-wrapper-function-results -fpedantic-bottoms'])
for name in ['wwfunres002', 'wwfunres003', 'wwfunres004']:
    test(name, normal, compile_and_run, ['-O -fworker-wrapper-function-results'])

# Deeper and mixed cases of -fworker-wrapper-function-results.  Each checks
# that the program means the same; the dump tests in should_compile
# (wwdeep_dump, wwmix002_dump) record which splits happen.
#   wwdeep001: three levels of returned functions, a dead argument at the
#              deepest; per-level work shared (traces, compared sorted)
#   wwdeep002: something to gain at two levels (levels 1 and 3), one pass
#   wwdeep003: five levels, deeper than the split looks
#   wwdeep004: -fpedantic-bottoms: a level-2 partial application diverges
#   wwhoarg001, wwhoarg002: a local function with a dead argument passed to
#              a function argument, at two depths (Note [Worker/wrapper for
#              function arguments])
#   wwhoarg003: two local functions at the same position (one lazy)
#   wwhoarg004: the function parameter escapes: no split
#   wwhoarg005: laziness: g undefined and not called; g ignoring f; the
#              dead argument undefined
#   wwhoarg006: function argument and function result together
#   wwhoarg007: two function parameters, at different argument positions
#   wwhoarg008: a recursive function passing g on (no split yet)
#   wwhoarg009: a lambda argument lazy in x (undefined): x must not be unboxed
#   wwmix001: the split together with the ordinary split of g's argument
#   wwmix002: returned functions from a lambda, a join point and an error
#   wwmix003: a recursive function returning a function, with CPR
#   wwmix004: an overloaded function returning a function
#   wwmix005: a partial application both called and stored; a join point
#              inside the returned function
def sorted_lines(s):
    return ''.join(sorted(s.splitlines(True)))

for name in ['wwdeep001', 'wwdeep002', 'wwdeep003']:
    test(name, [extra_files(['WWDeepA.hs']), normalise_errmsg_fun(sorted_lines)],
         multimod_compile_and_run, [name, '-O -fworker-wrapper-function-results'])
test('wwdeep004', normal, compile_and_run, ['-O -fworker-wrapper-function-results -fpedantic-bottoms'])
for name in ['wwhoarg001', 'wwhoarg002', 'wwhoarg003', 'wwhoarg004', 'wwhoarg005',
             'wwhoarg006', 'wwhoarg007', 'wwhoarg008', 'wwhoarg009', 'wwmix001', 'wwmix002', 'wwmix003', 'wwmix004', 'wwmix005']:
    test(name, normal, compile_and_run, ['-O -fworker-wrapper-function-results'])

# Two larger examples mixing cases that are split ([+]) and cases that are
# not ([-]), with a library module each (so that GHC keeps its functions out
# of line); -ddump-ww-ho-stats lists the functions split.
test('wwlarge001', [extra_files(['WWLarge1A.hs'])], multimod_compile_and_run,
     ['wwlarge001', '-O -fworker-wrapper-function-results'])
test('wwlarge002', [extra_files(['WWLarge2A.hs'])], multimod_compile_and_run,
     ['wwlarge002', '-O -fworker-wrapper-function-results'])

# Through newtypes (casts in tail position; see (Casts) in Note
# [Worker/wrapper for function results]):
#   wwcast001: a state-like newtype over a function: split, state unboxed
#   wwcast002: laziness and divergence through a newtype (-fpedantic-bottoms)
test('wwcast001', normal, compile_and_run, ['-O -fworker-wrapper-function-results'])
test('wwcast002', normal, compile_and_run, ['-O -fworker-wrapper-function-results -fpedantic-bottoms'])
