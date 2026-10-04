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
