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

# Web strictness (GHC.WebCore.Transform.Strictness).  strict002, 003, 004,
# 006, 007, 010 and 012 check laziness and sharing; 009 and 011 check the
# fixpoints across webs; 004 counts evaluations with
# Debug.Trace (the expected stderr).
st_opts = webs_opts + ' -fcore-webs-strictness'

def strict_test(name):
    test(name, [], compile_and_run, [st_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, st_opts + ' -ddump-webs-strictness -dsuppress-uniques'])

for n in range(1, 13):
    strict_test('strict%03d' % n)

# Result raising (GHC.WebCore.Transform.ResultRaise).  resultraise002
# checks laziness.
rr_opts = webs_opts + ' -fcore-webs-result-raise'

def resultraise_test(name):
    test(name, [], compile_and_run, [rr_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, rr_opts + ' -ddump-webs-result-raise -dsuppress-uniques'])

for n in range(1, 6):
    resultraise_test('resultraise%03d' % n)

# Constant propagation (GHC.WebCore.Transform.ConstProp), followed by
# dead-parameter elimination.  constprop003 checks that calls with a constant
# result are still evaluated (Debug.Trace, the expected stderr); constprop005
# that a local variable passed at every call is not propagated.
cp_opts = webs_opts + ' -fcore-webs-const-prop -fcore-webs-dead-params'

def constprop_test(name):
    test(name, [], compile_and_run, [cp_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, cp_opts + ' -ddump-webs-const-prop -dsuppress-uniques'])

for n in range(1, 6):
    constprop_test('constprop%03d' % n)

# Super-beta inlining (GHC.WebCore.Transform.Inline).  inline002 and 004
# check laziness and sharing; inline005 checks top-level binding order.
in_opts = webs_opts + ' -fcore-webs-inline'

def inline_test(name):
    test(name, [], compile_and_run, [in_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, in_opts + ' -ddump-webs-inline -dsuppress-uniques'])

for n in range(1, 7):
    inline_test('inline%03d' % n)

# Every transformation together
all_opts = (webs_opts + ' -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise'
            ' -fcore-webs-dead-params -fcore-webs-uncurry -fcore-webs-result-raise'
            ' -fcore-webs-strictness')
test('alltransforms002', [extra_files(['alltransforms001.hs'])], multimod_compile_and_run,
     ['alltransforms001', all_opts])
test('webs007', [extra_files(['Webs006A.hs', 'webs006.hs'])], multimod_compile_and_run,
     ['webs006', all_opts])

# The early run (after demand analysis, before worker/wrapper); webs008 checks
# that stale usage information does not let the simplifier eta-expand an
# uncurried function (-fpedantic-bottoms)
early_opts = '-O -fcore-webs-early -dcore-lint'
test('webs008', [], compile_and_run,
     [early_opts + ' -fcore-webs-uncurry -floopification -fpedantic-bottoms'])
test('alltransforms003', [extra_files(['alltransforms001.hs'])], multimod_compile_and_run,
     ['alltransforms001', all_opts.replace('-fcore-webs ', '-fcore-webs-early ')])

# WORKING-THE-WORKER-WRAPPER.md: what GHC's worker/wrapper does today with a
# returned function whose argument is dead.  Plain GHC (no webs); the
# expected output records approach 1, so it changes, deliberately, when
# approach 2 (splitting the function that returns it) is implemented.
#   wwreturn001: g inlined, f's body (a call of marker) duplicated per call
#   wwreturn002: g not inlined; g returns \x _ ->, calls pass the dead argument
#   wwreturn003: f large and used twice: f split into $wf and a wrapper, which
#                g returns; calls of the wrapper pass the dead argument
test('wwreturn001', [grep_errmsg(r'\$wmarker \(|^g |^\$wg ')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwreturn002', [grep_errmsg(r'\\ x _ ->|^\$wg |= g [nm] |h[12] [ab] [ab]')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwreturn003', [grep_errmsg(r'^ *\$wf$|^ *\$wf =|\\ x _ ->|\$wf ww1 of|h[12] [ab] [ab]|^\$wg$')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
