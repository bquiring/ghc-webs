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
# evaluations with Debug.Trace (the expected stderr).  Their webs have only
# known calls, which are left to GHC (Note [Uncurrying known calls]), so they
# run with -fcore-webs-uncurry-known; uncurry011 checks the default.
uc_opts = webs_opts + ' -fcore-webs-uncurry -fcore-webs-uncurry-known'

def uncurry_test(name, extra_opts=''):
    test(name, [], compile_and_run, [uc_opts + extra_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, uc_opts + extra_opts + ' -ddump-webs-uncurry -dsuppress-uniques'])

for n in range(1, 11):
    # uncurry005: stop GHC's own eta-expansion through a case, which would
    # make the program more defined by itself
    uncurry_test('uncurry%03d' % n, ' -fpedantic-bottoms' if n == 5 else '')
test('uncurry011', [], compile_and_run, [webs_opts + ' -fcore-webs-uncurry'])
test('uncurry011_dump', [extra_files(['uncurry011.hs'])], multimod_compile,
     ['uncurry011', webs_opts + ' -fcore-webs-uncurry -ddump-webs-uncurry -dsuppress-uniques'])

# Arity raising (GHC.WebCore.Transform.ArityRaise).  arityraise002-006, 011
# and 012 check laziness; arityraise008 checks functions passed to polymorphic
# functions; arityraise013 constructed arguments (lazy lambdas, lazy
# components).
ar_opts = webs_opts + ' -fcore-webs-arity-raise'

def arityraise_test(name):
    test(name, [], compile_and_run, [ar_opts])
    test(name + '_dump', [extra_files([name + '.hs'])],
         multimod_compile, [name, ar_opts + ' -ddump-webs-arity-raise -dsuppress-uniques'])

for n in range(1, 14):
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
# parameter going.  003 checks sharing (the trace appears once).  004 splits
# a small exported function too.  005 keeps one split and contracts another
# (Note [Contracting the boundary split]).  006 eta-expands a higher-order
# parameter in the wrapper, and its web is defunctionalised; 007 checks that
# the expansion shares partial applications (the trace appears once; Note
# [Eta-expanding parameters at the boundary]).  008: a web with such a
# lambda and one that captures a dictionary is not defunctionalised (Note
# [Captured dictionaries] in GHC.WebCore.Transform.Defunc).
bnd_opts = (early_opts + ' -fcore-webs-boundary -fcore-webs-dead-params'
            ' -fcore-webs-strictness')
for n in range(1, 7):
    test('boundary%03d' % n, [], compile_and_run, [bnd_opts])
for n in [1, 2, 4]:
    test('boundary%03d_dump' % n, [extra_files(['boundary%03d.hs' % n])],
         multimod_compile, ['boundary%03d' % n, bnd_opts + ' -ddump-webs-dead-params -dsuppress-uniques'])
test('boundary005_dump', [extra_files(['boundary005.hs']), grep_errmsg(r'^(Split|Contracted|Kept):')],
     multimod_compile, ['boundary005', bnd_opts + ' -ddump-webs-stats'])
test('boundary006_dump', [extra_files(['boundary006.hs'])],
     multimod_compile, ['boundary006', bnd_opts + ' -fcore-webs-defunc -ddump-webs-defunc -dsuppress-uniques'])
test('boundary007', [extra_files(['Boundary007A.hs'])],
     multimod_compile_and_run, ['boundary007', bnd_opts])
test('boundary008', [], compile_and_run, [bnd_opts + ' -fcore-webs-defunc'])
test('boundary008_dump', [extra_files(['boundary008.hs']), grep_errmsg(r'captured dictionary')],
     multimod_compile, ['boundary008', bnd_opts + ' -fcore-webs-defunc -ddump-webs-defunc -dsuppress-uniques'])

# Note [Defunctionalisation] (GHC.WebCore.Transform.Defunc,
# -fcore-webs-defunc).  001 is the basic case, 002 checks laziness and
# sharing (the trace appears once, the error never), 003 curried lambdas
# (two webs), 004 webs that are rejected (known calls; exposed), 005 a
# polymorphic and a monomorphic lambda in one web, 006 a polymorphic
# higher-order function used at two types, 007 a lambda whose free
# variables' types mention a type variable its body does not, 008 a type
# specialised to more parameters than it had, 009 lambdas of two arguments
# defunctionalised at arity two.  Their dumps show the verdicts.
# The *_lifted tests run the same programs with lifted bodies
# (Note [Lifted bodies]).
df_opts = early_opts + ' -fcore-webs-defunc'
for n in range(1, 10):
    test('defunc%03d' % n, [], compile_and_run, [df_opts])
    test('defunc%03d_dump' % n, [extra_files(['defunc%03d.hs' % n])],
         multimod_compile, ['defunc%03d' % n, df_opts + ' -ddump-webs-defunc -dsuppress-uniques'])
    test('defunc%03d_lifted' % n,
         [extra_files(['defunc%03d.hs' % n]),
          use_specs(dict(stdout='defunc%03d.stdout' % n,
                         **({'stderr': 'defunc002.stderr'} if n == 2 else {})))],
         multimod_compile_and_run, ['defunc%03d' % n, df_opts + ' -fcore-webs-defunc-lifted'])
# defunc010: lambdas that take class dictionaries (hpke's Crypto.HPKE.AEAD):
# the apply function's and lifted functions' dictionary arrows are
# constraint arrows.
test('defunc010', [], compile_and_run, [df_opts])
test('defunc010_lifted', [extra_files(['defunc010.hs']), use_specs({'stdout': 'defunc010.stdout'})],
     multimod_compile_and_run, ['defunc010', df_opts + ' -fcore-webs-defunc-lifted'])

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
# datasplit005: GHC.Generics' FixityI is used as a kind and is not copied
# (Note [Types used as kinds])
test('datasplit005', [], compile_and_run, [ds_opts])
# datasplit006 (generated): 2000 constructors matched by case tables; finding
# copied constructors by tag was quadratic (GHC.Builtin.PrimOps, out of memory).
# GHC's own passes take ~4 minutes on it with -dcore-lint, near the default
# timeout under load: hence the multiplier
test('datasplit006', [compile_timeout_multiplier(3)], compile_and_run, [ds_opts])
# datasplit009: a program with IO still splits its local lists; an unboxed
# tuple's hidden representation arguments ('[] in TupleRep '[]) made lists
# "used as kinds" (Note [Types used as kinds])
test('datasplit009', [], compile_and_run, [ds_opts])
test('datasplit009_dump', [extra_files(['datasplit009.hs'])],
     multimod_compile, ['datasplit009', ds_opts + ' -ddump-webs-data -dsuppress-uniques'])
# datasplit011: a newtype class kept only through a newtype child, which
# stays split (Note [Keeping only useful splits]; futhark's Unify)
test('datasplit011', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('datasplit011_again', [extra_files(['datasplit011.hs']), use_specs({'stdout': 'datasplit011.stdout'})],
     multimod_compile_and_run, ['datasplit011', ds_opts + ' -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-useless'])
# datasplit012: a copy whose tags dataToTag# observes keeps every
# constructor (Note [Observed tags]; cabal-install's solver)
test('datasplit012', [extra_files(['Datasplit012V.hs'])], multimod_compile_and_run, ['datasplit012', ds_opts])
# datasplit010: splitting keeps the vanilla unfoldings that worker/wrapper
# reads, so small functions get no wrapper (Note [Restoring vanilla
# unfoldings] in GHC.WebCore.Pipeline)
test('datasplit010', [], compile_and_run, [ds_opts])
test('datasplit010_wrappers', [extra_files(['datasplit010.hs']),
                               grep_errmsg(r'^Main\.\$f\S* \[InlPrag=\[2\]')],
     multimod_compile, ['datasplit010', ds_opts + ' -ddump-simpl -dsuppress-uniques'])
# datasplit007, datasplit008: atomicModifyIORef's pair is read by the RTS
# (atomicModifyMutVar2#, a selector thunk on its first field), so it is not
# split (Note [Non-parametric functions] in GHC.WebCore.DataSplit); 008 is
# aeson's letrecE, run in IO.  With unboxing (dead fields) and with useless
# elimination (absent fillers).
for (suffix, extra) in [('_unbox', ' -fcore-webs-data-unbox'), ('_useless', ' -fcore-webs-useless')]:
    test('datasplit007' + suffix, [extra_files(['datasplit007.hs']),
                                   use_specs({'stdout': 'datasplit007.stdout'})],
         multimod_compile_and_run, ['datasplit007', ds_opts + extra])
    test('datasplit008' + suffix, [extra_files(['datasplit008.hs', 'Datasplit008A.hs']),
                                   use_specs({'stdout': 'datasplit008.stdout'})],
         multimod_compile_and_run, ['datasplit008', ds_opts + extra + ' -package template-haskell'])

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
# dataunbox007: dead fields (Note [Dead fields]): an accumulator field that
# only feeds itself is dropped, with its arithmetic, even when it holds an
# error; a field passed to a function is kept
test('dataunbox007', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('dataunbox007_dump', [extra_files(['dataunbox007.hs'])],
     multimod_compile, ['dataunbox007', ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])
# dataunbox008: demands are rewritten with the fields (Note [Demands after
# flattening]): a dropped field next to an unpacked pair, read by a function
# worker/wrapper unboxes (nofib spectral/rewrite entered an absent argument)
test('dataunbox008', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
test('dataunbox008_dump', [extra_files(['dataunbox008.hs'])],
     multimod_compile, ['dataunbox008', ds_opts + ' -fcore-webs-data-unbox -ddump-webs-data -dsuppress-uniques'])
# dataunbox009: a local list of pairs, both specialised, cast through a type
# family: a coercion selects into the pair by the list pattern's paths
# (GHC.Cmm.CommonBlockElim, building GHC with webs)
test('dataunbox009', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
# dataunbox012: a flattened pair's function component that is only seq'd
# (demand 1A): its demand is left alone (fix_sd in GHC.WebCore.DataFlatten;
# futhark's Language.Futhark.TypeChecker.Terms tripped mkCall's assertion)
test('dataunbox012', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
# dataspec001: a split pair specialised at (b -> c, Int), cast with coerce:
# its variables occur only under an arrow, so it is not specialised
# (Note [Specialising split types]; vector-algorithms panicked)
test('dataspec001', [], compile_and_run, [ds_opts + ' -fcore-webs-data-unbox'])
# dataunbox010: JuicyPixels' Codec.Picture.Metadata.  A match on Refl binds a
# coercion variable that a cast uses: the field it came from is live (Note
# [Dead fields] in GHC.WebCore.DataFlatten).
test('dataunbox010', [extra_files(['dataunbox010.hs', 'Dataunbox010A.hs'])],
     multimod_compile_and_run,
     ['dataunbox010', ds_opts + ' -fcore-webs-data-unbox -fcore-webs-data-again'])
# dataunbox011: a field mentioned only by a let binder's stable unfolding
# stays bound and live (JuicyPixels' Codec.Picture.Gif).
test('dataunbox011', [], compile_and_run,
     [ds_opts + ' -fcore-webs-data-unbox -fcore-webs-data-again'])

# Edge cases for data splitting and unboxing.  001-010 are type-level, with
# coercions: local, parameterised, eta-reducible, recursive and mutually
# recursive newtypes; coerce; newtype deriving; type and data families;
# phantom roles; GADTs and existentials; unsafeCoerce.  011-018 are run-time,
# with boxes: errors and infinite structures inside fields, sharing (a trace
# that must appear once), seq/foldl'/length, values escaping to base, nested
# pairs/Maybe/Either, re-boxing, knots, exceptions.  019-021 are strict
# fields: polymorphic ones (no wrapper, so split; a copy must stay strict),
# Data.Complex, and unpacked ones mixed with lazy ones.  022-029 are
# recursive types (Note [Demands after flattening]: a stale or unfolded
# demand on one): lists only built with (:), so their copies have one
# constructor; single-constructor streams, self-referencing records and
# recursion through a pair; mutual recursion with class methods; dead fields
# (as nofib spectral/rewrite); function fields; polymorphic recursion;
# infinite trees; strict recursive fields.  Expected output from the stock
# compiler at -O0.  Every program runs in eight modes, all with Core Lint
# (and Data Lint): in the early run, split only; with unboxing; with nested
# unboxing; with the size bound at 1; with every early transformation; with
# those and defunctionalisation; and in the late run, split and unbox; with
# every late transformation.
dsedge_all = (early_opts + ' -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise'
              ' -fcore-webs-dead-params -fcore-webs-result-raise -fcore-webs-strictness'
              ' -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-unbox-nested')
dsedge_modes = [ ('_split',  ds_opts)
               , ('_unbox',  ds_opts + ' -fcore-webs-data-unbox')
               , ('_nested', ds_opts + ' -fcore-webs-data-unbox -fcore-webs-unbox-nested')
               , ('_size1',  ds_opts + ' -fcore-webs-data-unbox -fcore-webs-unbox-nested'
                                     ' -fcore-webs-max-unbox-size=1')
               , ('_all',    dsedge_all)
               , ('_df',     dsedge_all + ' -fcore-webs-defunc -fcore-webs-defunc-lifted')
                 # The late run (after all Core optimisations; Note [Unboxing in
                 # the late run]): split and unbox, and every late transformation
               , ('_late',   webs_opts + ' -fcore-webs-data-split -fcore-webs-data-unbox')
               , ('_lateall', all_opts + ' -fcore-webs-data-split -fcore-webs-data-unbox'
                                       ' -fcore-webs-unbox-nested') ]
for n in range(1, 30):
    name = 'dsedge%03d' % n
    specs = {'stdout': name + '.stdout'}
    if n in [12, 19]:
        specs['stderr'] = name + '.stderr'
    for (suffix, opts) in dsedge_modes:
        test(name + suffix, [extra_files([name + '.hs']), use_specs(specs)],
             multimod_compile_and_run, [name, opts])

# Streams (stream fusion's Step/Stream, combinators not inlined): stream001
# with an existential state, stream002 with the state in the type.  Both in
# every dsedge mode.  So far no transformation improves either
# (WEBS-BACKLOG.md).
for name in ['stream001', 'stream002']:
    for (suffix, opts) in dsedge_modes:
        test(name + suffix, [extra_files([name + '.hs']), use_specs({'stdout': name + '.stdout'})],
             multimod_compile_and_run, [name, opts])

# Recursive types whose function field's web takes or returns the type:
# T = (Int, T ->{w} Int), R = (Int, Int ->{w} R), S = (Int, S ->{w} S),
# T = (Int, (T, Int) ->{w} Int), and a newtype over a pair.  The fields are
# hidden (Note [Hidden fields] in GHC.WebCore.Sigs), so w is internal;
# raising w through itself would need an infinite type, so 001-003 are
# rejected (Note [Recursive products] in GHC.WebCore.Transform.ArityRaise),
# 004 is raised (T is nominal), and 005's newtype keeps w exposed.  Every
# dsedge mode.
for name in ['recweb%03d' % n for n in range(1, 6)]:
    for (suffix, opts) in dsedge_modes:
        test(name + suffix, [extra_files([name + '.hs']), use_specs({'stdout': name + '.stdout'})],
             multimod_compile_and_run, [name, opts])

# Hidden fields (Note [Hidden fields] in GHC.WebCore.Sigs): webs inside the
# fields of types whose constructors are not exported are internal; a type
# whose fields change is rebuilt in place (Note [Signatures follow the
# transformations] in GHC.WebCore.HiddenFields).  hfield001: local types, a
# record and a Show instance; hfield002: an abstract type, used from another
# module through unfoldings; hfield003: unsafeCoerce to an exposed type with
# the same layout keeps the fields exposed; hfield004: a polymorphic field
# used only at a pair is not raised on the original type, but data
# splitting specialises its copy (Note [Specialising for webs] in
# GHC.WebCore.DataSplit) and the copy's field is raised.  Every dsedge mode.
for name in ['hfield001', 'hfield003', 'hfield004']:
    for (suffix, opts) in dsedge_modes:
        test(name + suffix, [extra_files([name + '.hs']), use_specs({'stdout': name + '.stdout'})],
             multimod_compile_and_run, [name, opts])
for (suffix, opts) in dsedge_modes:
    test('hfield002' + suffix, [extra_files(['hfield002.hs', 'HField002A.hs']),
                               use_specs({'stdout': 'hfield002.stdout'})],
         multimod_compile_and_run, ['hfield002', opts])
# hfield005: an abstract type that mentions a local type whose field web is
# raised is rebuilt too (uniplate's Data.Generics.Uniplate.Zipper).
for (suffix, opts) in dsedge_modes:
    test('hfield005' + suffix, [extra_files(['hfield005.hs', 'HField005A.hs']),
                               use_specs({'stdout': 'hfield005.stdout'})],
         multimod_compile_and_run, ['hfield005', opts])
test('hfield005_rr', [extra_files(['hfield005.hs', 'HField005A.hs']),
                      use_specs({'stdout': 'hfield005.stdout'})],
     multimod_compile_and_run, ['hfield005', early_opts + ' -fcore-webs-result-raise'])
# hfield006: a type synonym that mentions a hidden-field type does not keep
# its fields exposed (nofib constraints); the stats show the type internal.
for (suffix, opts) in dsedge_modes:
    test('hfield006' + suffix, [extra_files(['hfield006.hs']), use_specs({'stdout': 'hfield006.stdout'})],
         multimod_compile_and_run, ['hfield006', opts])
test('hfield006_stats', [extra_files(['hfield006.hs']),
                         grep_errmsg(r'^Internal, hidden fields: [0-9]+')],
     multimod_compile, ['hfield006', early_opts + ' -fcore-webs-result-raise -ddump-webs-stats'])
# Note [One-shot lambdas from webs] (GHC.WebCore.Transform.OneShot,
# -fcore-webs-one-shot).  The dump shows which webs' lambdas are one-shot.
os_opts = early_opts + ' -fcore-webs-one-shot'
test('oneshot001', [], compile_and_run, [os_opts])
test('oneshot001_dump', [extra_files(['oneshot001.hs'])],
     multimod_compile, ['oneshot001', os_opts + ' -ddump-webs-one-shot -dsuppress-uniques'])

# Note [Main's exports] (GHC.WebCore.Pipeline, -fcore-webs-internal-main-exports):
# a Main module without an export list; with the flag its exported function's
# web is internal and raised, without it exposed (the two dumps)
me_opts = early_opts + ' -fcore-webs-arity-raise'
test('mainexp001', [], compile_and_run, [me_opts + ' -fcore-webs-internal-main-exports'])
test('mainexp001_dump', [extra_files(['mainexp001.hs'])],
     multimod_compile, ['mainexp001', me_opts + ' -fcore-webs-internal-main-exports -ddump-webs-arity-raise -dsuppress-uniques'])
test('mainexp001_keep_dump', [extra_files(['mainexp001.hs'])],
     multimod_compile, ['mainexp001', me_opts + ' -ddump-webs-arity-raise -dsuppress-uniques'])

# Note [Useless elimination] (GHC.WebCore.Transform.Useless,
# -fcore-webs-useless).  001 drops a dead result component (through a
# scrutinised re-boxing, Note [Scrutinised constructions]), 002 finds two
# parameters that only feed each other dead, 003 checks that nothing dead is
# evaluated.  The dumps show the verdicts.
useless_opts = (early_opts + ' -fcore-webs-arity-raise -fcore-webs-result-raise'
                ' -fcore-webs-useless -fcore-webs-strictness')
for n in range(1, 4):
    test('useless%03d' % n, [], compile_and_run, [useless_opts])

# Bad strictness: each program must behave as it does unoptimised (the
# expected output is -O0's).  004, 006: a dead unlifted argument or result
# component that raises an error is still evaluated (exit 1).  005, 012,
# 013: dead lazy arguments and lets that are errors, loops or traces are
# not.  007: a strict field the pattern ignores keeps its value (exit 1);
# 016: a lazy one becomes an absent filler and is never evaluated
# (Note [Scrutinised constructions]).  008: a field read through the case
# binder stays.  009: a dead last parameter keeps the lambda, so work is not
# shared.  010: a forced function value stays a function.  011: dead join
# point arguments.  014: a dead component returned through a join point.
# 015: a tail call adapted to fewer components.
for n in [4, 6, 7]:
    test('useless%03d' % n, [exit_code(1)], compile_and_run, [useless_opts])
for n in [5, 8, 9, 10, 11, 12, 13, 14, 15, 16]:
    test('useless%03d' % n, [], compile_and_run, [useless_opts])
# 017: two binding sites with one unique (Note [Fresh binders for useless
# elimination]); in the configuration nofib found it with
# 018: parstof, a dead field filled, then evaluated early by web strictness
# (Note [Do not evaluate dead ends early] in GHC.WebCore.Transform.Strictness)
test('useless018', [extra_run_opts('1')], compile_and_run,
     [useless_opts + ' -O2 -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-data-split'
      ' -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary'])
# 019: rewrite, split again (Note [Data splitting again])
test('useless019', [extra_run_opts('20000')], compile_and_run,
     [useless_opts + ' -O2 -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-data-split'
      ' -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -fcore-webs-data-again'])
# 020: a web in the type of a coercion variable (unsafeIOToST; hashable)
test('useless020', [], compile_and_run,
     [useless_opts + ' -O2 -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-data-split'
      ' -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -fcore-webs-data-again'])
# 021: a join point in a masked tail with a dead parameter (network)
test('useless021', [], compile_and_run,
     [useless_opts + ' -O2 -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-data-split'
      ' -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -fcore-webs-data-again'])
# 022: runRW# in a masked tail, jumping to a join point (http2)
test('useless022', [], compile_and_run, [useless_opts])
test('useless017', [], compile_and_run,
     [useless_opts + ' -O2 -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-data-split'
      ' -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary'])
for n in [1, 2]:
    test('useless%03d_dump' % n, [extra_files(['useless%03d.hs' % n])],
         multimod_compile, ['useless%03d' % n, useless_opts + ' -ddump-webs-useless -dsuppress-uniques'])

# Deadness and strictness (poison001-040): programs with thunks that no
# evaluation should reach (UNREACHABLE errors, a loop in 035) and, in
# 026-030, values that must still be evaluated (exit 1).  Each must behave
# as it does unoptimised: the expected output is -O0's.  Recursion (001-005),
# mutual recursion (006-009), higher-order and unknown calls (010-015), data
# structures (016-025), must-evaluate (026-030), thunks and sharing
# (031-035), results (036-040), fields of local types (041-045: dead through
# a web, evaluated at the producer only if every construction is consumed),
# 046 (parstof's shape), 047 (a constructor built only for dead code).  The
# early run also splits data types again (Note [Data splitting again]).  Every web transformation is on, in the
# early run (poisonNNN) and in the late run (poisonNNN_late).
poison_ws = (' -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise'
             ' -fcore-webs-dead-params -fcore-webs-useless -fcore-webs-result-raise'
             ' -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox'
             ' -fcore-webs-defunc')
poison_early = early_opts + poison_ws + ' -fcore-webs-boundary -fcore-webs-data-again'
poison_late = webs_opts + poison_ws
for n in range(1, 48):
    name = 'poison%03d' % n
    ec = [exit_code(1)] if 26 <= n <= 30 else []
    test(name, ec, compile_and_run, [poison_early])
    test(name + '_late', ec + [extra_files([name + '.hs'])],
         multimod_compile_and_run, [name, poison_late])

# Note [Strictness as the dual of liveness] (GHC.WebCore.Transform.Forced):
# the analysis-only dump runs on annotated Core (it once called
# exprIsDeadEnd on web forms and panicked); here on a few poison programs.
for n in [1, 6, 13, 16, 19, 36, 40, 41, 43]:
    name = 'poison%03d' % n
    test(name + '_forced', [extra_files([name + '.hs']), grep_errmsg(r'^Forced')],
         multimod_compile, [name, poison_early + ' -ddump-webs-forced'])

# Note [Result raising]: a case binder rebuilt from field binders one of
# which is a wildcard (found building happy's generated parser)
test('resraise_alias', [], compile_and_run, [early_opts + ' -fcore-webs-result-raise'])
test('resraise_alias_late', [extra_files(['resraise_alias.hs'])],
     multimod_compile_and_run, ['resraise_alias', rr_opts])

# Useless elimination settles before its round limit: a dead component it
# cannot drop (a projection around a primop call) or a dead field it cannot
# fill does not count as a change (Cabal-syntax's Language.Haskell.Extension
# ran ten rounds, each with Web Lint, and ran out of memory)
for name in ['useless_rounds001', 'useless_rounds002']:
    test(name, [grep_errmsg(r'^!!! Webs: (useless elimination, round [0-9]+):', [1])],
         compile_and_run, [early_opts + ' -fcore-webs-useless -dshow-passes'])

# -dcore-webs-lint lints the web pipeline's output only; Web Lint's
# re-checks after the transformations need -dcore-lint
test('lint_flag001', [grep_errmsg(r'^(\*\*\* Core Linted result of [^:]*|!!! Webs: Web Lint after [^:]*):', [1])],
     compile_and_run, ['-O -fcore-webs-early -fcore-webs-useless -dcore-webs-lint -dshow-passes'])

# -fcore-webs-boundary-kept splits binders kept only for rules and
# unfoldings; the specialisation $sinsert keeps only its wrapper exposed
test('boundary_kept001', [grep_errmsg(r'^Exposed lambda classes only by: (kept binder[^:]*: [^:]*):', [1])],
     compile_and_run, [early_opts + ' -fcore-webs-boundary -fcore-webs-boundary-kept -ddump-webs-stats'])
# unused001: an export listed by -fcore-webs-unused-exports is no longer
# exported and is deleted (Note [Unused exports] in GHC.WebCore.Pipeline)
test('unused001', [extra_files(['unused001.hs', 'Unused001L.hs', 'unused001.txt'])],
     makefile_test, ['unused001'])
# chunk001: --make -fcore-webs-chunk compiles the program as one Core
# program (Note [Chunks] in GHC.WebCore.Chunk)
test('chunk001', [extra_files(['chunk001.hs', 'Chunk001L.hs'])],
     makefile_test, ['chunk001'])
# chunk002: a chunk of two modules inside a program, Main outside it
# (Note [Chunks] in GHC.WebCore.Chunk)
test('chunk002', [extra_files(['chunk002.hs', 'Chunk002A.hs', 'Chunk002B.hs', 'chunk002.modules', 'chunk002.unused'])],
     makefile_test, ['chunk002'])
# chunk003: a library built as a chunk, then used as Cabal would use it
# (Note [Chunks] in GHC.WebCore.Chunk)
test('chunk003', [extra_files(['chunk003.hs', 'chunk003lib/'])],
     makefile_test, ['chunk003'])

# chunk004: a library chunk's SPECIALISE rule fires in an importer (Note
# [Interfaces of a chunk] in GHC.WebCore.Chunk)
test('chunk004', [extra_files(['chunk004.hs', 'chunk004lib/'])],
     makefile_test, ['chunk004'])

# chunk005: a chunk with a module that has an hs-boot file (Note [Chunks]
# in GHC.WebCore.Chunk)
test('chunk005', [extra_files(['chunk005.hs', 'chunk005lib/'])],
     makefile_test, ['chunk005'])
# chunk006: newtypes of one chunk module split in another (Note [Copies of
# one newtype from two TyCons] in GHC.WebCore.DataSplit; dhall)
test('chunk006', [extra_files(['chunk006.hs', 'Chunk006A.hs', 'Chunk006B.hs'])],
     makefile_test, ['chunk006'])
# chunk007: a chunk rebuilt into its output directory (Note [Chunks] in
# GHC.WebCore.Chunk; hledger)
test('chunk007', [extra_files(['chunk007.hs', 'Chunk007A.hs', 'Chunk007B.hs'])],
     makefile_test, ['chunk007'])
