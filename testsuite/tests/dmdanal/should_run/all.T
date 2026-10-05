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
