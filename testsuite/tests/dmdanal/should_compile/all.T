# Only compile with optimisation
setTestOpts( only_ways(['optasm']))
setTestOpts( extra_hc_opts('-dno-debug-output') )

test('default', normal, compile, [''])
test('fact', normal, compile, [''])
test('fun', normal, compile, [''])
test('goo', normal, compile, [''])
test('ins', normal, compile, [''])
test('map', normal, compile, [''])
test('sim', normal, compile, [''])
test('str001', normal, compile, [''])
test('str002', normal, compile, [''])
test('syn', normal, compile, [''])
test('test', normal, compile, [''])
test('tst', normal, compile, [''])
test('unu', normal, compile, [''])
test('newtype', req_profiling, compile, ['-prof -fprof-auto'])
test('T1988', normal, compile, [''])
test('T8467', normal, compile, [''])
test('T8037', normal, compile, [''])
test('T8743', [], multimod_compile, ['T8743', '-v0'])

# T10482
#   The intent here is to check that $wfoo has type
#         $wfoo :: Int# -> Int# -> Int
#   with two unboxed args.  See #10482 for background
#
# Set -dppr-cols to ensure output doesn't wrap
test('T10482',  [ grep_errmsg(r'wfoo.*Int#') ], compile, ['-dppr-cols=200 -ddump-simpl'])
test('T10482a', [ grep_errmsg(r'wf.*Int#') ],   compile, ['-dppr-cols=200 -ddump-simpl'])

test('T9208', normal, compile_fail, ['-dstg-lint -O -ddebug-output'])
# T9208 fails (and should do so) if you have assertion checking on in the compiler
# It now also fails with stgLint, hence the above compile_fail.  See comments in the ticket

test('T10694', [ grep_errmsg(r'(Str|Cpr)=') ],   compile, ['-dppr-cols=200 -ddump-simpl -dsuppress-uniques'])
test('T11770', [ check_errmsg('OneShot') ], compile, ['-ddump-simpl'])

test('T13031', normal, makefile_test, [])

test('T13077', normal, compile, [''])
test('T13077a', normal, compile, [''])

# T13143: WW for NOINLINE function f
test('T13143', [ grep_errmsg(r'^T13143\.\$wf') ], compile, ['-ddump-simpl -dsuppress-uniques'])

# T15627
#   Absent bindings of unlifted types should be WW'ed away.
#   The idea is to check that both $wmutVar and $warray
#   don't mention MutVar# and Array# anymore.
test('T15627',  [ grep_errmsg(r'(wmutVar|warray).*Int#') ], compile, ['-dppr-cols=200 -ddump-simpl'])
# Absent bindings of unlifted newtypes are WW’ed away.
test('T17852',  [ grep_errmsg(r'\\$wf ::') ], compile, ['-ddump-worker-wrapper -dsuppress-idinfo'])

test('T16029', normal, makefile_test, [])
test('T10069',  [ grep_errmsg(r'(wc1).*Int#$') ], compile, ['-dppr-cols=200 -ddump-simpl'])
test('T13380b',  [ grep_errmsg('bigDeadAction') ], compile, ['-dppr-cols=200 -ddump-simpl'])

# We just want to find the worker of foo in there:
test('T18122',  [ grep_errmsg(r'wfoo =') ], compile, ['-ddump-simpl'])
# We just want to find the workers of foo and bar in there:
test('T17819',  [ grep_errmsg(r'(wfoo|wbar)') ], compile, ['-ddump-simpl'])

# We care about the call demand on $wg
test('T18903',  [ grep_errmsg(r'Dmd=\S+C\S+') ], compile, ['-ddump-simpl -dsuppress-uniques'])
# We care about the call demand on $wg1 and $wg2
test('T18894',  [ grep_errmsg(r'Dmd=\S+C\S+') ], compile, ['-ddump-dmdanal -dsuppress-uniques'])
# We care about the Arity 2 on eta, as a result of the annotated Dmd
test('T18894b',  [ grep_errmsg(r'Arity=2') ], compile, ['-ddump-dmdanal -dsuppress-uniques -fno-call-arity -dppr-cols=200'])
# We care about the workers of f,g,h,i:
test('T18982',  [ grep_errmsg(r'\$w. .*Int#$') ], compile, ['-dppr-cols=1000 -ddump-simpl -dsuppress-idinfo -dsuppress-uniques'])
# We care about the type of $wyeah. The unlifted Gram constructor should unbox
test('T20663', [ grep_errmsg(r'\$wyeah ::') ], compile, ['-dppr-cols=1000 -ddump-simpl -dsuppress-idinfo -dsuppress-uniques'])

test('T19180', normal, compile, [''])
test('T19766', [ grep_errmsg(r'absentError') ], compile, ['-ddump-worker-wrapper'])
test('T19849', normal, compile, [''])
test('T19882a', normal, compile, [''])
test('T19882b', normal, compile, [''])
# We want that the 'go' joinrec in the unfolding has been worker/wrappered.
# So we simply grep for 'jump $wgo' and hope we find more than 2 call sites:
test('T20510', [ grep_errmsg(r'jump \$wgo') ], compile, ['-dsuppress-uniques -ddump-exitify'])
test('T20817', [ grep_errmsg(r'Str') ], compile, ['-dsuppress-uniques -ddump-dmdanal'])
# T21150: Check that t{,1,2} haven't been inlined.
test('T21150', [ grep_errmsg(r'( t\d? :: Int)') ], compile, ['-dsuppress-uniques -ddump-exitify'])

# T21128: Check that y is not reboxed in $wtheresCrud
#         If so, there should be no `let` for y
test('T21128', [ grep_errmsg(r'let { y = I\#') ], multimod_compile, ['T21128', '-v0 -dsuppress-uniques -dsuppress-all -ddump-simpl'])

test('T21265', normal, compile, [''])
test('EtaExpansion', normal, compile, [''])
test('T22039', normal, compile, [''])
# T22388: Should see $winteresting but not $wboring
test('T22388', [ grep_errmsg(r'^\S+\$w\S+') ], compile, ['-dsuppress-uniques -ddump-simpl'])
# T22997: Just a panic that should not happen
test('T22997', normal, compile, [''])
test('T23398', normal, compile, ['-dsuppress-uniques -ddump-simpl -dno-typeable-binds'])
test('T24623', normal, compile, [''])
test('T25196', [ req_th, collect_compiler_stats('bytes allocated', 10) ],
               multimod_compile, ['T25196', '-v0'])

# Worker/wrapper for functions that return functions (WW-HIGHER-ORDER.md,
# WORKING-THE-WORKER-WRAPPER.md).  The expected output records what GHC does
# today, so it changes, deliberately, when higher-order worker/wrapper is
# implemented:
#   wwreturn001: g cheap: inlined, f's body (a call of marker) copied per call
#   wwreturn002: f used once: inlined into g before w/w runs; g returns
#                \x _ -> ..., and calls pass the dead argument, boxed
#   wwreturn003: f large and used twice: f split into $wf and a wrapper, which
#                g returns; calls of the wrapper pass the dead argument, boxed
test('wwreturn001', [grep_errmsg(r'\$wmarker \(|^g |^\$wg ')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwreturn002', [grep_errmsg(r'\\ x _ ->|^\$wg |= g [nm] |h[12] [ab] [ab]')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwreturn003', [grep_errmsg(r'^ *\$wf$|^ *\$wf =|\\ x _ ->|\$wf ww1 of|h[12] [ab] [ab]|^\$wg$')], compile,
     ['-O -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
# The same two programs with -fworker-wrapper-function-results: g is split
# through its returned function ($wg returns the worker, without the dead
# argument), its wrapper is inlined at the shared partial applications
# (let wf = $wg n), and the calls reach the worker (wf a).
test('wwreturn002_funres', [extra_files(['wwreturn002.hs']), grep_errmsg(r'^\$w\$?wg$|^g =|wf[0-9]* = |wf[0-9]* [ab] ')],
     multimod_compile, ['wwreturn002', '-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwreturn003_funres', [extra_files(['wwreturn003.hs']), grep_errmsg(r'^\$w\$?wg$|^g =|wf[0-9]* = |wf[0-9]* [ab] ')],
     multimod_compile, ['wwreturn003', '-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds'])
test('wwfunres005', [grep_errmsg(r'^run|wf a|h a')], compile,
     ['-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds -dppr-cols=400'])
# The wrappers made for deep returned functions (-fworker-wrapper-function-results):
# g3 split at level 3, g4 at levels 1 and 3, g6 (five levels) not at all
test('wwdeep_dump', [grep_errmsg(r'^g[0-9]+ = \\ |^g[0-9]+$|^\$wg[0-9]+$')], compile,
     ['-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds -dppr-cols=400'])
# A split whose returned function is a join point (its result type changes)
test('wwmix002_dump', [grep_errmsg(r'^g = |^\$w\$?wg$')], compile,
     ['-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds -dppr-cols=400'])
# Worker/wrapper through function arguments: the callers' functions now call
# the local function's worker, without its dead argument (\ c -> c ...)
for name in ['wwhoarg001_dump', 'wwhoarg002_dump', 'wwhoarg006_dump']:
    test(name, [grep_errmsg(r'= \\ c -> |^\$w\$wh$|= \$w\$wh ')], compile,
         ['-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds -dppr-cols=400'])
# The statistics pass must terminate on a function parameter that is never
# called (it once counted through [0 .. maxBound])
test('wwhostats001', [grep_errmsg(r'ww-ho-reject')], compile,
     ['-O -ddump-ww-ho-stats'])
# Which functions (Constructed) splits: step (twice) and findK (no
# occurrence left in the module), not pick (different constructors),
# strictK (strict fields) or storeK (its calls here pass no continuation
# that takes the pair apart: (Consumed))
test('wwcont_dump', [grep_errmsg(r'ww-ho-split pre-ww')], compile,
     ['-O -fworker-wrapper-function-results -ddump-ww-ho-stats'])
# (Static): which recursive functions passing their function parameter on
# are split, and the worker's recursive calls pass the converted parameter
test('wwstatic_dump', [grep_errmsg(r'ww-ho-split pre-ww|\$w\$w\w+ q ')], compile,
     ['-O -fworker-wrapper-function-results -ddump-ww-ho-stats -ddump-simpl -dsuppress-all -dsuppress-uniques -dppr-cols=400'])

# (Cpr): the wrappers of step and setMsg rebuild the pair their worker's
# returned lambda returns unboxed (setMsg is split for that alone); pick's
# (a sum type) does not.  (CprConsumed): lazyTick's only call binds the pair
# lazily, and stored is only kept in a table, so neither returns it unboxed
# (lazyTick is still split for its argument).  A copy of
# should_run/wwcpr001.hs
test('wwcpr_dump', [grep_errmsg(r'^(step|setMsg|pick|lazyTick|stored) = ')], compile,
     ['-O -fworker-wrapper-function-results -ddump-simpl -dsuppress-all -dsuppress-uniques -dno-typeable-binds -dppr-cols=400'])

# (TypeParams): functions with a type parameter after value parameters (rank-2
# types, a newtype over one, polymorphic recursion) are split.  A copy of
# should_run/wwpoly002.hs
test('wwpoly_dump', [grep_errmsg(r'ww-ho-split pre-ww')], compile,
     ['-O -fworker-wrapper-function-results -ddump-ww-ho-stats -dsuppress-uniques'])
