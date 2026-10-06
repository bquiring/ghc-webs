# Higher-order worker/wrapper opportunities (base, 115 benchmarks, summed over modules)

| point  | funs  | returns_fun | takes_fun | res_splits | res_deep | res_levels | arg_splits | arg_nested |
|--------|------:|------------:|----------:|-----------:|---------:|-----------:|-----------:|-----------:|
| early  |  7567 |         477 |       626 |          9 |        0 |          9 |          9 |          0 |
| pre-ww |  8947 |         367 |       632 |          7 |        0 |          7 |         13 |          0 |
| final  | 10770 |         412 |       768 |         10 |        0 |         10 |          6 |          0 |

## Why functions are not split (functions returning (r:) or taking (a:) a function)

| reason                                                    | early | pre-ww | final |
|-----------------------------------------------------------|------:|-------:|------:|
| a: small (inlined whole)                                  |   143 |    174 |   163 |
| a: parameter not only called: passed to a recursive call  |   134 |    162 |   135 |
| a: not given known functions: only non-function arguments |   189 |    131 |   131 |
| r: tail: call                                             |    90 |     83 |    69 |
| r: nothing to gain                                        |   142 |     80 |    87 |
| r: tail: local variable                                   |    88 |     79 |    43 |
| r: small (inlined whole)                                  |    53 |     70 |    67 |
| a: parameter not only called: passed to a global function |    58 |     44 |    26 |
| a: parameter not only called: passed to a local function  |    26 |     31 |    82 |
| a: parameter not only called: returned                    |     8 |     29 |    31 |
| r: no live tail                                           |    24 |     24 |    17 |
| a: function only under a type                             |    19 |     16 |    13 |
| a: stable unfolding                                       |    13 |     13 |   155 |
| a: constructed data, no consumer at the calls             |     5 |     11 |    14 |
| r: stable unfolding                                       |     8 |      7 |    92 |
| r: tail: application                                      |    21 |      6 |     6 |
| r: has RULES                                              |    19 |      5 |    17 |
| r: tail: cast                                             |     6 |      3 |     2 |
| r: tail: global variable                                  |     2 |      2 |     2 |
| a: parameter not only called: stored in a constructor     |     2 |      2 |     7 |
| a: type parameters after value parameters                 |     3 |      2 |     2 |
| r: eta-expandable (each partial application called once)  |    15 |      1 |     0 |
| a: parameter not only called: scrutinised (seq)           |     2 |      1 |     0 |
| a: not given known functions: a partial application       |     2 |      1 |     1 |
| a: not given known functions: a global function           |     1 |      1 |     1 |
| a: parameter not only called: returned from a lambda      |     0 |      1 |     1 |
| a: arity above manifest lambdas                           |    11 |      0 |     0 |
| a: not given known functions: never called                |     2 |      0 |     0 |

## Functions split at pre-ww

- real/anna: $cshowsPrec_a2co: result at levels 1
- real/fem: Matrix.makemat: arguments, depths 2
- real/fem: VBmatrix.makevbmat: arguments, depths 2
- real/fem: Vector.makevec: arguments, depths 2
- real/fluid: S_Array.s_ixmap: arguments, depths 2
- real/hpg: Env.get_constructors: arguments, depths 2
- real/hpg: Env.get_type_names: arguments, depths 2
- real/hpg: Env.get_val_names: arguments, depths 2
- real/hpg: GenType.gen_types: arguments, depths 2
- real/hpg: GenVal.gen_vals: arguments, depths 2
- real/hpg: karg_s1pf: result at levels 1
- real/infer: StateX.thenSX: arguments, depths 2
- real/pic: Utils.applyOpToMesh: arguments, depths 2
- real/scs: LinearAlgebra.apply: result at levels 1
- real/scs: LinearAlgebra.m_mul: result at levels 1
- spectral/hartel/fft: Main.tabulate: arguments, depths 2
- spectral/hartel/wave4main: Main.tabulate: arguments, depths 2
- spectral/pretty: Pretty.ppDouble: result at levels 1
- spectral/pretty: Pretty.ppInt: result at levels 1
- spectral/pretty: Pretty.ppInteger: result at levels 1

## Per benchmark (benchmarks with any split, early / pre-ww / final)

| benchmark                 | res_splits | res_deep  | arg_splits | arg_nested |
|---------------------------|-----------:|----------:|-----------:|-----------:|
| real/anna                 |  1 / 1 / 1 | 0 / 0 / 0 |  0 / 0 / 0 |  0 / 0 / 0 |
| real/fem                  |  0 / 0 / 1 | 0 / 0 / 0 |  1 / 3 / 1 |  0 / 0 / 0 |
| real/fluid                |  0 / 0 / 0 | 0 / 0 / 0 |  0 / 1 / 0 |  0 / 0 / 0 |
| real/hpg                  |  0 / 1 / 3 | 0 / 0 / 0 |  7 / 5 / 1 |  0 / 0 / 0 |
| real/infer                |  1 / 0 / 0 | 0 / 0 / 0 |  1 / 1 / 0 |  0 / 0 / 0 |
| real/pic                  |  0 / 0 / 0 | 0 / 0 / 0 |  0 / 1 / 0 |  0 / 0 / 0 |
| real/scs                  |  2 / 2 / 2 | 0 / 0 / 0 |  0 / 0 / 0 |  0 / 0 / 0 |
| real/veritas              |  1 / 0 / 0 | 0 / 0 / 0 |  0 / 0 / 1 |  0 / 0 / 0 |
| spectral/circsim          |  1 / 0 / 0 | 0 / 0 / 0 |  0 / 0 / 0 |  0 / 0 / 0 |
| spectral/exact-reals      |  0 / 0 / 0 | 0 / 0 / 0 |  0 / 0 / 1 |  0 / 0 / 0 |
| spectral/hartel/fft       |  0 / 0 / 0 | 0 / 0 / 0 |  0 / 1 / 1 |  0 / 0 / 0 |
| spectral/hartel/wave4main |  0 / 0 / 0 | 0 / 0 / 0 |  0 / 1 / 1 |  0 / 0 / 0 |
| spectral/pretty           |  3 / 3 / 3 | 0 / 0 / 0 |  0 / 0 / 0 |  0 / 0 / 0 |

# Performance (from the nofib logs)

| measure                     | funres                    |
|-----------------------------|--------------------------:|
| compiler allocation vs base | +0.18% (geomean over 117) |
| program allocation vs base  | -0.07% (geomean over 113) |
| object code (text) vs base  | +0.10% (geomean over 115) |

## Program allocation changes over 0.5%

| benchmark | base      | funres |
|-----------|----------:|-------:|
| pic       | 310856552 |  -3.9% |
| wave4main | 305912088 |  -3.3% |

# Build and run failures

- base: 32 lines
    smallpt: make[2]: *** [../../mk/suffix.mk:23: smallpt.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: BVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: BoundingBox.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Colour.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Figure.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Image.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Interval.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Main.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Matrix.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Mesh.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Lehmer64.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Lehmer64Mut.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Wyhash64.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: RandomDist.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Ray.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: STL.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Sampler.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Naive.o] Error 1
- funres: 32 lines
    smallpt: make[2]: *** [../../mk/suffix.mk:23: smallpt.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: BVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: BoundingBox.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Colour.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Figure.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Image.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Interval.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Main.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Matrix.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Mesh.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Lehmer64.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Lehmer64Mut.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Random/Wyhash64.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: RandomDist.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Ray.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: STL.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Sampler.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Naive.o] Error 1
