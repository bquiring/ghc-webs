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

# Note [Splitting webs at the boundary] (GHC.WebCore.Boundary,
# -fcore-webs-boundary).  boundary001 splits an exported function, 002
# eta-expands the argument of an imported one; their dumps show the dead
# parameter going.  003 checks sharing (the trace appears once).  004 does
# not split a small exported function; its dump shows the web exposed.
bnd_opts = (early_opts + ' -fcore-webs-boundary -fcore-webs-dead-params'
            ' -fcore-webs-strictness')
for n in range(1, 5):
    test('boundary%03d' % n, [], compile_and_run, [bnd_opts])
for n in [1, 2, 4]:
    test('boundary%03d_dump' % n, [extra_files(['boundary%03d.hs' % n])],
         multimod_compile, ['boundary%03d' % n, bnd_opts + ' -ddump-webs-dead-params -dsuppress-uniques'])

# Note [Defunctionalisation] (GHC.WebCore.Transform.Defunc,
# -fcore-webs-defunc).  001 is the basic case, 002 checks laziness and
# sharing (the trace appears once, the error never), 003 curried lambdas
# (two webs), 004 webs that are rejected (known calls; exposed), 005 a
# polymorphic and a monomorphic lambda in one web, 006 a polymorphic
# higher-order function used at two types, 007 a lambda whose free
# variables' types mention a type variable its body does not, 008 a type
# specialised to more parameters than it had.  Their dumps show the verdicts.
# The *_lifted tests run the same programs with lifted bodies
# (Note [Lifted bodies]).
df_opts = early_opts + ' -fcore-webs-defunc'
for n in range(1, 9):
    test('defunc%03d' % n, [], compile_and_run, [df_opts])
    test('defunc%03d_dump' % n, [extra_files(['defunc%03d.hs' % n])],
         multimod_compile, ['defunc%03d' % n, df_opts + ' -ddump-webs-defunc -dsuppress-uniques'])
    test('defunc%03d_lifted' % n,
         [extra_files(['defunc%03d.hs' % n]),
          use_specs(dict(stdout='defunc%03d.stdout' % n,
                         **({'stderr': 'defunc002.stderr'} if n == 2 else {})))],
         multimod_compile_and_run, ['defunc%03d' % n, df_opts + ' -fcore-webs-defunc-lifted'])

# Note [Splitting data types] (GHC.WebCore.DataSplit, -fcore-webs-data-split).
# 001 a local list and an exposed one, 002 constructors a class never builds
# are dropped, 003 a recursive type exposed through a derived instance in one
# place and split in another.  The *_dump tests show what was split; the
# runs check the result with Core Lint (and Data Lint checks the copies).
ds_opts = early_opts + ' -fcore-webs-data-split'
for n in range(1, 5):
    test('datasplit%03d' % n, [], compile_and_run, [ds_opts])
    test('datasplit%03d_dump' % n, [extra_files(['datasplit%03d.hs' % n])],
         multimod_compile, ['datasplit%03d' % n, ds_opts + ' -ddump-webs-data -dsuppress-uniques'])
    test('datasplit%03d_all' % n,
         [extra_files(['datasplit%03d.hs' % n]),
          use_specs({'stdout': 'datasplit%03d.stdout' % n})],
         multimod_compile_and_run, ['datasplit%03d' % n, all_opts.replace('-fcore-webs ', '-fcore-webs-early ') + ' -fcore-webs-data-split'])

# Note [Flattening fields] (GHC.WebCore.DataFlatten, -fcore-webs-data-unbox):
# the split tests again, with the product fields of the new types unboxed
# (datasplit002: Circle's and Tri's Double fields; datasplit003: Node's Int).
for n in range(1, 4):
    test('dataunbox%03d' % n,
         [extra_files(['datasplit%03d.hs' % n]),
          use_specs({'stdout': 'datasplit%03d.stdout' % n})],
         multimod_compile_and_run, ['datasplit%03d' % n, ds_opts + ' -fcore-webs-data-unbox'])
for n in [2, 3]:
    test('dataunbox%03d_dump' % n, [extra_files(['datasplit%03d.hs' % n])],
         multimod_compile, ['datasplit%03d' % n, ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])

# dataunbox004: a local [(Int, Int)] is specialised to its element type, the
# pairs are unpacked into the cons cells, and then their Ints into Int#s
# (Note [Specialising split types], Note [Flattening fields])
test('dataunbox004', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('dataunbox004_dump', [extra_files(['dataunbox004.hs'])],
     multimod_compile, ['dataunbox004', ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])
# dataunbox005: a pair passed whole to a function that unboxes it
# (Note [Unboxable fields])
test('dataunbox005', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('dataunbox005_dump', [extra_files(['dataunbox005.hs'])],
     multimod_compile, ['dataunbox005', ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])
# dataunbox006: thunk fields that are strictly eliminated are unboxed; ones
# that may be built without being eliminated are not (Note [Strictly
# eliminated fields])
test('dataunbox006', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('dataunbox006_dump', [extra_files(['dataunbox006.hs'])],
     multimod_compile, ['dataunbox006', ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])
