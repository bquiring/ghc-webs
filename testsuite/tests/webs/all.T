# Tests for the web pipeline (-fcore-webs); see GHC.WebCore.Pipeline.
#
# -dcore-lint makes the pipeline check that erasure gives back the original
# program (Note [Web round trip]), and Core Lint checks the result.

webs_opts = '-O -fcore-webs -dcore-lint'

test('webs001', [], compile_and_run, [webs_opts])
test('webs002', [], compile_and_run, [webs_opts])
test('webs003', [], compile_and_run, [webs_opts])


# Boundary cases.  The *_summary tests check -ddump-webs-summary, which labels
# every arrow of the top-level binders E (exposed) or with a local class
# number.  Their output depends on the optimiser's choices (worker/wrapper
# names, inlining), so it may need to be re-accepted when those change.
summary_opts = webs_opts + ' -ddump-webs-summary -dsuppress-uniques'

# Functions and data structures of functions crossing a module boundary
test('webs004', [extra_files(['Webs004A.hs'])],
     multimod_compile_and_run, ['webs004', webs_opts])
test('webs004_summary', [extra_files(['Webs004A.hs', 'webs004.hs'])],
     multimod_compile, ['webs004', summary_opts])

# Coercion axioms: local and imported newtypes, closed and open type families
test('webs005', [], compile_and_run, [webs_opts])
test('webs005_summary', [extra_files(['webs005.hs'])],
     multimod_compile, ['webs005', summary_opts])

# Dead-parameter elimination (GHC.WebCore.Transform.DeadParams).  Each test
# runs the program, and checks the verdicts (-ddump-webs-dead-params).
# deadparam003, 006, 010 and 012 fail if laziness is not handled correctly.
dp_opts = webs_opts + ' -fcore-webs-dead-params'

def deadparam(name):
    test(name, [], compile_and_run, [dp_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, dp_opts + ' -ddump-webs-dead-params -dsuppress-uniques'])

for n in range(1, 13):
    deadparam('deadparam%03d' % n)
