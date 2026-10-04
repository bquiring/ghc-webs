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

# Uncurrying (GHC.WebCore.Transform.Uncurry).  uncurry003, 004, 005 and 009
# fail if laziness or sharing is not handled correctly; 003, 004 count
# evaluations with Debug.Trace (the expected stderr).
uc_opts = webs_opts + ' -fcore-webs-uncurry'

def uncurry_test(name, extra_opts=''):
    test(name, [], compile_and_run, [uc_opts + extra_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, uc_opts + extra_opts + ' -ddump-webs-uncurry -dsuppress-uniques'])

for n in range(1, 11):
    # uncurry005: stop GHC's own eta-expansion through a case, which would
    # make the program more defined by itself
    uncurry_test('uncurry%03d' % n, ' -fpedantic-bottoms' if n == 5 else '')

# Arity raising (GHC.WebCore.Transform.ArityRaise).  arityraise002-006, 011
# and 012 check laziness; arityraise008 checks functions passed to polymorphic
# functions.
ar_opts = webs_opts + ' -fcore-webs-arity-raise'

def arityraise_test(name):
    test(name, [], compile_and_run, [ar_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, ar_opts + ' -ddump-webs-arity-raise -dsuppress-uniques'])

for n in range(1, 13):
    arityraise_test('arityraise%03d' % n)

# All the transformations together
test('alltransforms001', [], compile_and_run,
     [webs_opts + ' -fcore-webs-arity-raise -fcore-webs-dead-params -fcore-webs-uncurry'])
test('alltransforms001_dump', [extra_files(['alltransforms001.hs'])], multimod_compile,
     ['alltransforms001', webs_opts + ' -fcore-webs-arity-raise -fcore-webs-dead-params'
      ' -fcore-webs-uncurry -ddump-webs-summary -dsuppress-uniques'])

# Interface boundary: Ids reachable from exposed vanilla unfoldings
test('webs006', [extra_files(['Webs006A.hs'])], multimod_compile_and_run,
     ['webs006', webs_opts + ' -fcore-webs-arity-raise -fcore-webs-dead-params -fcore-webs-uncurry'])
