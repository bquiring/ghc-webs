# First-class function statistics (static counts, summed over modules)

## base  (115 benchmarks)

| | lams | returned | passed | stored_data | stored_dict | calls | unknown_calls | partial_apps | ww_workers |
|---|---|---|---|---|---|---|---|---|---|
| before | 12571 | 1103 | 11787 | 432 | 1155 | 62717 | 5929 | 4400 | 0 |
| after | 13762 | 481 | 5745 | 1129 | 1182 | 70686 | 1393 | 927 | 1926 |

## late  (115 benchmarks)

| | lams | returned | passed | stored_data | stored_dict | calls | unknown_calls | partial_apps | ww_workers |
|---|---|---|---|---|---|---|---|---|---|
| before | 12571 | 1103 | 11787 | 432 | 1155 | 62717 | 5929 | 4400 | 0 |
| after | 13729 | 518 | 5754 | 1130 | 1182 | 70236 | 1504 | 817 | 1915 |

## early  (115 benchmarks)

| | lams | returned | passed | stored_data | stored_dict | calls | unknown_calls | partial_apps | ww_workers |
|---|---|---|---|---|---|---|---|---|---|
| before | 12571 | 1103 | 11787 | 432 | 1155 | 62717 | 5929 | 4400 | 0 |
| after | 13577 | 479 | 5760 | 1129 | 1182 | 69995 | 1389 | 927 | 1899 |

## early-late  (115 benchmarks)

| | lams | returned | passed | stored_data | stored_dict | calls | unknown_calls | partial_apps | ww_workers |
|---|---|---|---|---|---|---|---|---|---|
| before | 12571 | 1103 | 11787 | 432 | 1155 | 62717 | 5929 | 4400 | 0 |
| after | 13728 | 518 | 5769 | 1130 | 1182 | 70244 | 1500 | 817 | 1894 |

## Per benchmark, base: before -> after (returned / passed / stored_data / unknown_calls)

| benchmark | returned | passed | stored_data | stored_dict | unknown_calls |
|---|---|---|---|---|---|
| imaginary/bernouilli | 1 -> 0 | 17 -> 9 | 0 -> 1 | 0 -> 0 | 5 -> 1 |
| imaginary/digits-of-e1 | 0 -> 0 | 3 -> 5 | 0 -> 1 | 0 -> 0 | 0 -> 1 |
| imaginary/digits-of-e2 | 1 -> 0 | 20 -> 9 | 0 -> 1 | 0 -> 0 | 0 -> 2 |
| imaginary/exp3_8 | 1 -> 0 | 5 -> 6 | 0 -> 1 | 19 -> 19 | 0 -> 1 |
| imaginary/gen_regexps | 0 -> 0 | 20 -> 5 | 0 -> 0 | 0 -> 0 | 6 -> 1 |
| imaginary/integrate | 0 -> 0 | 16 -> 16 | 0 -> 3 | 0 -> 0 | 19 -> 10 |
| imaginary/kahan | 1 -> 0 | 5 -> 6 | 0 -> 1 | 0 -> 0 | 0 -> 1 |
| imaginary/paraffins | 0 -> 0 | 40 -> 6 | 0 -> 1 | 0 -> 0 | 14 -> 1 |
| imaginary/primes | 0 -> 0 | 8 -> 10 | 0 -> 2 | 0 -> 0 | 0 -> 2 |
| imaginary/queens | 0 -> 0 | 7 -> 5 | 0 -> 1 | 0 -> 0 | 2 -> 1 |
| imaginary/rfib | 0 -> 0 | 3 -> 6 | 0 -> 1 | 0 -> 0 | 0 -> 1 |
| imaginary/tak | 0 -> 0 | 1 -> 5 | 0 -> 3 | 0 -> 0 | 0 -> 1 |
| imaginary/wheel-sieve1 | 1 -> 0 | 18 -> 9 | 0 -> 2 | 0 -> 0 | 6 -> 2 |
| imaginary/wheel-sieve2 | 0 -> 0 | 17 -> 20 | 0 -> 2 | 0 -> 0 | 2 -> 2 |
| imaginary/x2n1 | 0 -> 0 | 3 -> 5 | 0 -> 1 | 0 -> 0 | 1 -> 1 |
| real/anna | 88 -> 61 | 1502 -> 934 | 70 -> 65 | 128 -> 130 | 447 -> 115 |
| real/bspt | 16 -> 1 | 182 -> 75 | 0 -> 3 | 67 -> 67 | 486 -> 14 |
| real/cacheprof | 31 -> 9 | 588 -> 153 | 0 -> 24 | 135 -> 135 | 443 -> 23 |
| real/compress | 12 -> 0 | 28 -> 6 | 0 -> 2 | 8 -> 11 | 11 -> 0 |
| real/compress2 | 1 -> 0 | 12 -> 5 | 0 -> 0 | 3 -> 3 | 3 -> 1 |
| real/eff/CS | 5 -> 2 | 53 -> 57 | 0 -> 0 | 10 -> 10 | 15 -> 34 |
| real/eff/CSD | 1 -> 0 | 7 -> 2 | 0 -> 0 | 0 -> 0 | 3 -> 9 |
| real/eff/FS | 3 -> 2 | 22 -> 11 | 4 -> 5 | 10 -> 10 | 4 -> 7 |
| real/eff/S | 1 -> 0 | 3 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 |
| real/eff/VS | 6 -> 1 | 51 -> 55 | 0 -> 0 | 10 -> 10 | 21 -> 47 |
| real/eff/VSD | 1 -> 0 | 4 -> 1 | 0 -> 0 | 0 -> 0 | 1 -> 2 |
| real/eff/VSM | 9 -> 2 | 33 -> 29 | 0 -> 0 | 10 -> 10 | 11 -> 25 |
| real/fem | 7 -> 1 | 98 -> 50 | 0 -> 1 | 0 -> 0 | 31 -> 7 |
| real/fluid | 27 -> 9 | 432 -> 142 | 2 -> 53 | 10 -> 10 | 293 -> 33 |
| real/fulsom | 65 -> 4 | 53 -> 47 | 3 -> 4 | 58 -> 58 | 36 -> 1 |
| real/gamteb | 2 -> 0 | 28 -> 22 | 0 -> 1 | 0 -> 0 | 29 -> 1 |
| real/gg | 24 -> 0 | 153 -> 153 | 0 -> 1 | 81 -> 81 | 54 -> 18 |
| real/grep | 18 -> 6 | 252 -> 92 | 0 -> 30 | 0 -> 0 | 44 -> 33 |
| real/hidden | 28 -> 9 | 144 -> 69 | 4 -> 7 | 97 -> 112 | 70 -> 13 |
| real/hpg | 122 -> 104 | 453 -> 211 | 66 -> 136 | 25 -> 25 | 132 -> 109 |
| real/infer | 81 -> 31 | 346 -> 131 | 19 -> 74 | 22 -> 22 | 57 -> 63 |
| real/lift | 12 -> 29 | 174 -> 134 | 3 -> 1 | 0 -> 0 | 85 -> 26 |
| real/linear | 2 -> 0 | 246 -> 73 | 4 -> 6 | 0 -> 0 | 234 -> 5 |
| real/maillist | 0 -> 0 | 11 -> 19 | 0 -> 0 | 0 -> 0 | 0 -> 2 |
| real/mkhprog | 14 -> 1 | 89 -> 57 | 0 -> 1 | 0 -> 0 | 21 -> 10 |
| real/parser | 21 -> 0 | 403 -> 81 | 15 -> 78 | 43 -> 43 | 107 -> 27 |
| real/pic | 0 -> 0 | 99 -> 21 | 0 -> 2 | 0 -> 0 | 110 -> 11 |
| real/prolog | 18 -> 13 | 247 -> 101 | 4 -> 17 | 11 -> 11 | 40 -> 27 |
| real/reptile | 12 -> 0 | 200 -> 35 | 0 -> 2 | 0 -> 0 | 228 -> 12 |
| real/rsa | 2 -> 1 | 28 -> 9 | 0 -> 2 | 0 -> 0 | 4 -> 2 |
| real/scs | 38 -> 2 | 364 -> 180 | 0 -> 19 | 3 -> 3 | 100 -> 25 |
| real/symalg | 4 -> 0 | 69 -> 39 | 2 -> 7 | 56 -> 56 | 29 -> 3 |
| real/veritas | 160 -> 82 | 728 -> 378 | 99 -> 125 | 33 -> 33 | 374 -> 140 |
| shootout/binary-trees | 1 -> 6 | 6 -> 11 | 0 -> 20 | 0 -> 0 | 0 -> 2 |
| shootout/fannkuch-redux | 2 -> 0 | 44 -> 10 | 0 -> 1 | 5 -> 5 | 4 -> 1 |
| shootout/fasta | 0 -> 0 | 13 -> 12 | 0 -> 0 | 0 -> 0 | 19 -> 0 |
| shootout/k-nucleotide | 1 -> 2 | 103 -> 38 | 0 -> 4 | 0 -> 0 | 29 -> 2 |
| shootout/n-body | 0 -> 2 | 47 -> 6 | 0 -> 4 | 0 -> 0 | 0 -> 1 |
| shootout/pidigits | 0 -> 0 | 7 -> 3 | 0 -> 1 | 0 -> 0 | 0 -> 0 |
| shootout/reverse-complement | 1 -> 0 | 33 -> 3 | 0 -> 0 | 0 -> 0 | 3 -> 3 |
| shootout/spectral-norm | 0 -> 1 | 30 -> 7 | 0 -> 2 | 0 -> 0 | 0 -> 0 |
| spectral/ansi | 10 -> 4 | 24 -> 8 | 0 -> 1 | 0 -> 0 | 12 -> 4 |
| spectral/atom | 7 -> 5 | 14 -> 8 | 0 -> 1 | 10 -> 10 | 7 -> 2 |
| spectral/awards | 2 -> 0 | 26 -> 46 | 4 -> 1 | 0 -> 0 | 40 -> 9 |
| spectral/banner | 0 -> 0 | 66 -> 3 | 0 -> 0 | 0 -> 0 | 270 -> 0 |
| spectral/boyer | 0 -> 0 | 48 -> 12 | 0 -> 2 | 4 -> 4 | 91 -> 2 |
| spectral/boyer2 | 2 -> 0 | 22 -> 7 | 0 -> 15 | 8 -> 8 | 2 -> 1 |
| spectral/calendar | 5 -> 0 | 30 -> 12 | 0 -> 1 | 0 -> 0 | 29 -> 2 |
| spectral/cichelli | 7 -> 4 | 51 -> 13 | 0 -> 1 | 3 -> 3 | 33 -> 2 |
| spectral/circsim | 19 -> 0 | 91 -> 24 | 0 -> 7 | 20 -> 20 | 41 -> 1 |
| spectral/clausify | 2 -> 0 | 30 -> 9 | 0 -> 2 | 0 -> 0 | 4 -> 2 |
| spectral/constraints | 11 -> 1 | 88 -> 42 | 1 -> 8 | 16 -> 16 | 22 -> 11 |
| spectral/cryptarithm1 | 0 -> 0 | 14 -> 5 | 0 -> 1 | 0 -> 0 | 5 -> 0 |
| spectral/cryptarithm2 | 1 -> 0 | 23 -> 10 | 0 -> 1 | 3 -> 3 | 11 -> 1 |
| spectral/cse | 23 -> 8 | 66 -> 25 | 3 -> 1 | 3 -> 3 | 34 -> 25 |
| spectral/dom-lt | 11 -> 24 | 272 -> 96 | 0 -> 2 | 10 -> 10 | 14 -> 58 |
| spectral/eliza | 1 -> 0 | 89 -> 26 | 0 -> 1 | 0 -> 0 | 133 -> 1 |
| spectral/exact-reals | 3 -> 2 | 73 -> 478 | 12 -> 83 | 59 -> 59 | 36 -> 77 |
| spectral/expert | 7 -> 0 | 77 -> 25 | 0 -> 1 | 0 -> 0 | 40 -> 3 |
| spectral/fft2 | 3 -> 3 | 69 -> 26 | 0 -> 1 | 0 -> 0 | 6 -> 1 |
| spectral/fibheaps | 7 -> 0 | 26 -> 18 | 2 -> 2 | 0 -> 0 | 2 -> 4 |
| spectral/fish | 2 -> 0 | 64 -> 53 | 0 -> 9 | 0 -> 0 | 89 -> 7 |
| spectral/gcd | 1 -> 0 | 6 -> 5 | 0 -> 1 | 0 -> 0 | 1 -> 1 |
| spectral/hartel/comp_lab_zift | 0 -> 0 | 80 -> 19 | 0 -> 2 | 0 -> 0 | 20 -> 3 |
| spectral/hartel/event | 1 -> 0 | 28 -> 22 | 10 -> 12 | 0 -> 0 | 10 -> 6 |
| spectral/hartel/fft | 0 -> 0 | 22 -> 26 | 0 -> 2 | 0 -> 0 | 9 -> 4 |
| spectral/hartel/genfft | 0 -> 0 | 22 -> 17 | 0 -> 1 | 0 -> 0 | 6 -> 3 |
| spectral/hartel/ida | 0 -> 0 | 32 -> 23 | 0 -> 2 | 0 -> 0 | 12 -> 5 |
| spectral/hartel/listcompr | 0 -> 0 | 20 -> 13 | 0 -> 1 | 0 -> 0 | 10 -> 2 |
| spectral/hartel/listcopy | 0 -> 0 | 20 -> 13 | 0 -> 1 | 0 -> 0 | 10 -> 2 |
| spectral/hartel/nucleic2 | 0 -> 0 | 62 -> 12 | 0 -> 23 | 0 -> 0 | 114 -> 4 |
| spectral/hartel/parstof | 10 -> 1 | 605 -> 56 | 44 -> 112 | 0 -> 0 | 34 -> 31 |
| spectral/hartel/sched | 0 -> 0 | 4 -> 10 | 0 -> 2 | 0 -> 0 | 1 -> 2 |
| spectral/hartel/solid | 1 -> 0 | 56 -> 66 | 4 -> 1 | 0 -> 0 | 13 -> 15 |
| spectral/hartel/transform | 5 -> 2 | 266 -> 126 | 42 -> 26 | 0 -> 0 | 67 -> 20 |
| spectral/hartel/typecheck | 0 -> 0 | 67 -> 61 | 9 -> 17 | 0 -> 0 | 15 -> 13 |
| spectral/hartel/wang | 0 -> 0 | 31 -> 9 | 0 -> 1 | 0 -> 0 | 9 -> 2 |
| spectral/hartel/wave4main | 0 -> 0 | 31 -> 35 | 0 -> 1 | 0 -> 0 | 8 -> 3 |
| spectral/integer | 1 -> 0 | 37 -> 33 | 0 -> 3 | 0 -> 0 | 4 -> 14 |
| spectral/knights | 8 -> 4 | 63 -> 42 | 0 -> 0 | 24 -> 24 | 27 -> 9 |
| spectral/lambda | 7 -> 1 | 48 -> 34 | 0 -> 24 | 24 -> 24 | 2 -> 29 |
| spectral/last-piece | 0 -> 0 | 84 -> 9 | 0 -> 0 | 0 -> 0 | 234 -> 8 |
| spectral/lcss | 2 -> 0 | 7 -> 6 | 0 -> 1 | 0 -> 0 | 1 -> 1 |
| spectral/life | 3 -> 0 | 30 -> 8 | 0 -> 1 | 0 -> 0 | 45 -> 1 |
| spectral/mandel | 4 -> 0 | 42 -> 22 | 0 -> 3 | 3 -> 3 | 1 -> 7 |
| spectral/mandel2 | 0 -> 0 | 4 -> 5 | 0 -> 1 | 0 -> 0 | 0 -> 2 |
| spectral/mate | 8 -> 1 | 84 -> 29 | 0 -> 4 | 50 -> 50 | 50 -> 10 |
| spectral/minimax | 6 -> 0 | 98 -> 42 | 0 -> 1 | 10 -> 10 | 155 -> 10 |
| spectral/multiplier | 6 -> 1 | 80 -> 73 | 0 -> 1 | 0 -> 0 | 31 -> 24 |
| spectral/para | 6 -> 0 | 162 -> 157 | 0 -> 1 | 0 -> 0 | 51 -> 14 |
| spectral/power | 29 -> 27 | 5 -> 6 | 0 -> 1 | 36 -> 43 | 1 -> 1 |
| spectral/pretty | 7 -> 12 | 18 -> 39 | 2 -> 8 | 0 -> 0 | 22 -> 15 |
| spectral/primetest | 3 -> 0 | 13 -> 4 | 0 -> 1 | 0 -> 0 | 2 -> 2 |
| spectral/puzzle | 7 -> 0 | 51 -> 6 | 0 -> 1 | 21 -> 21 | 5 -> 1 |
| spectral/rewrite | 15 -> 0 | 203 -> 65 | 4 -> 3 | 4 -> 4 | 68 -> 14 |
| spectral/scc | 1 -> 0 | 11 -> 10 | 0 -> 0 | 0 -> 0 | 19 -> 2 |
| spectral/simple | 0 -> 0 | 469 -> 95 | 0 -> 1 | 0 -> 0 | 253 -> 14 |
| spectral/sorting | 4 -> 0 | 42 -> 9 | 0 -> 8 | 0 -> 0 | 19 -> 4 |
| spectral/sphere | 0 -> 0 | 42 -> 3 | 0 -> 1 | 0 -> 0 | 45 -> 0 |
| spectral/treejoin | 4 -> 0 | 11 -> 5 | 0 -> 0 | 3 -> 3 | 1 -> 0 |

# Simplifier and inliner statistics (grand totals, summed over modules)

| kind | base | late | early | early-late |
|---|---|---|---|---|
| Total ticks | 810502 | 812609 (+0.3%) | 806561 (-0.5%) | 808640 (-0.2%) |
| PreInlineUnconditionally | 256187 | 257017 (+0.3%) | 254536 (-0.6%) | 255359 (-0.3%) |
| PostInlineUnconditionally | 19444 | 19453 (+0.0%) | 19868 (+2.2%) | 19876 (+2.2%) |
| UnfoldingDone | 80032 | 80127 (+0.1%) | 78611 (-1.8%) | 78703 (-1.7%) |
| RuleFired | 65812 | 66053 (+0.4%) | 65891 (+0.1%) | 66132 (+0.5%) |
| BetaReduction | 306412 | 307248 (+0.3%) | 304821 (-0.5%) | 305650 (-0.2%) |
| KnownBranch | 53752 | 53802 (+0.1%) | 54001 (+0.5%) | 54042 (+0.5%) |
| CaseOfCase | 5247 | 5244 (-0.1%) | 5234 (-0.2%) | 5231 (-0.3%) |
| EtaExpansion | 1690 | 1690 (+0.0%) | 1690 (+0.0%) | 1690 (+0.0%) |
| EtaReduction | 252 | 245 (-2.8%) | 251 (-0.4%) | 244 (-3.2%) |
| LetFloatFromLet | 0 | 0 () | 0 () | 0 () |
| FillInCaseDefault | 3347 | 3347 (+0.0%) | 3344 (-0.1%) | 3344 (-0.1%) |
| CaseElim | 1415 | 1462 (+3.3%) | 1411 (-0.3%) | 1458 (+3.0%) |
| CaseIdentity | 455 | 455 (+0.0%) | 454 (-0.2%) | 454 (-0.2%) |
| CaseMerge | 697 | 698 (+0.1%) | 697 (+0.0%) | 698 (+0.1%) |
| AltMerge | 55 | 55 (+0.0%) | 55 (+0.0%) | 55 (+0.0%) |
| $w workers (final Core) | 1926 | 1915 (-0.6%) | 1899 (-1.4%) | 1894 (-1.7%) |

## UnfoldingDone per benchmark (largest changes vs base)

| benchmark | base | late | early | early-late |
|---|---|---|---|---|
| real/veritas | 6244 | 6244 | 5742 | 5742 |
| real/anna | 6439 | 6464 | 6167 | 6192 |
| real/reptile | 2236 | 2236 | 2124 | 2124 |
| spectral/hartel/transform | 1199 | 1199 | 1130 | 1130 |
| real/fem | 1309 | 1361 | 1303 | 1355 |
| spectral/boyer2 | 380 | 380 | 330 | 330 |
| spectral/rewrite | 710 | 710 | 672 | 672 |
| spectral/minimax | 472 | 472 | 437 | 437 |
| real/scs | 1899 | 1899 | 1866 | 1866 |
| spectral/multiplier | 829 | 829 | 798 | 798 |
| real/gg | 1819 | 1819 | 1795 | 1795 |
| real/symalg | 1268 | 1268 | 1245 | 1245 |
| real/bspt | 3100 | 3101 | 3078 | 3079 |
| spectral/clausify | 197 | 197 | 175 | 175 |
| real/fluid | 3158 | 3161 | 3139 | 3139 |
| spectral/expert | 483 | 483 | 466 | 466 |
| spectral/circsim | 706 | 706 | 690 | 690 |
| real/hpg | 1219 | 1219 | 1205 | 1205 |
| spectral/integer | 151 | 151 | 137 | 137 |
| real/linear | 2446 | 2453 | 2433 | 2440 |
| spectral/cryptarithm1 | 97 | 97 | 84 | 84 |
| spectral/mate | 870 | 870 | 883 | 883 |
| spectral/simple | 2236 | 2236 | 2248 | 2248 |
| real/pic | 767 | 767 | 758 | 758 |
| spectral/para | 1127 | 1127 | 1135 | 1135 |

# Compile and run performance (from the nofib logs)

| measure | late | early | early-late |
|---|---|---|---|
| compiler allocation vs base | +15.93% (geomean over 117) | +7.76% (geomean over 117) | +22.75% (geomean over 117) |
| program allocation vs base | +0.27% (geomean over 113) | +0.01% (geomean over 113) | +0.26% (geomean over 113) |

Times are not reported: they are not reliable on this machine (see report.py).

## Program allocation per benchmark (bytes; change vs base)

| benchmark | base | late | early | early-late |
|---|---|---|---|---|
| CS | 160050240 | +0.0% | +0.0% | +0.0% |
| CSD | 1600050368 | +0.0% | +0.0% | +0.0% |
| FS | 1760050256 | +0.0% | +0.0% | +0.0% |
| S | 240050192 | +0.0% | +0.0% | +0.0% |
| VS | 483117120 | +0.0% | +0.0% | +0.0% |
| VSD | 50336 | +0.0% | +0.0% | +0.0% |
| VSM | 400050304 | +0.0% | +0.0% | +0.0% |
| anna | 195002328 | +0.0% | +0.0% | +0.0% |
| ansi | 1265690552 | +0.0% | +0.0% | +0.0% |
| atom | 537524528 | +0.0% | +0.0% | +0.0% |
| awards | 486399944 | +0.0% | +0.0% | +0.0% |
| banner | 613288616 | +0.0% | +0.0% | +0.0% |
| ben-raytrace | 0 |  |  |  |
| bernouilli | 140977880 | +0.0% | +0.0% | +0.0% |
| binary-trees | 262397232 | +0.2% | +0.0% | +0.2% |
| boyer | 622572592 | +0.0% | +0.0% | +0.0% |
| boyer2 | 123533344 | +0.0% | +0.2% | +0.2% |
| bspt | 377714288 | +0.0% | +0.0% | +0.0% |
| cacheprof | 322226000 | +0.0% | +0.0% | +0.0% |
| calendar | 710378936 | +0.0% | +0.0% | +0.0% |
| cichelli | 194209544 | +3.4% | +0.0% | +3.4% |
| circsim | 493903800 | +0.0% | +0.0% | +0.0% |
| clausify | 299615688 | +0.0% | +0.0% | +0.0% |
| comp_lab_zift | 452726128 | +4.4% | +0.0% | +4.4% |
| compress | 533552896 | +0.0% | +0.0% | +0.0% |
| compress2 | 599413952 | -8.1% | +0.0% | -8.1% |
| constraints | 1254410000 | +0.0% | +0.0% | +0.0% |
| cryptarithm1 | 1993762888 | +0.0% | +0.0% | +0.0% |
| cryptarithm2 | 370194224 | +0.0% | +0.0% | +0.0% |
| cse | 388280528 | +0.5% | +0.0% | +0.5% |
| digits-of-e1 | 101892648 | +0.0% | +0.0% | +0.0% |
| digits-of-e2 | 226018856 | +0.0% | +0.0% | +0.0% |
| dom-lt | 541748184 | +11.6% | +0.0% | +11.6% |
| eliza | 409884800 | +0.0% | +0.0% | +0.0% |
| event | 321891624 | +0.0% | +0.0% | +0.0% |
| exact-reals | 89758928 | +0.0% | +0.0% | +0.0% |
| exp3_8 | 597315784 | +0.0% | +0.0% | +0.0% |
| expert | 212140304 | +0.0% | +0.0% | +0.0% |
| fannkuch-redux | 65256 | +0.0% | +0.0% | +0.0% |
| fasta | 0 |  |  |  |
| fem | 962382032 | +0.1% | +0.0% | +0.1% |
| fft | 309653712 | +0.0% | -0.0% | -0.0% |
| fft2 | 211347480 | -1.6% | +0.0% | -1.6% |
| fibheaps | 652742424 | +4.7% | +0.0% | +4.7% |
| fish | 626063816 | +0.1% | +0.0% | +0.1% |
| fluid | 215121992 | +0.1% | +0.0% | +0.2% |
| fulsom | 506338968 | +0.0% | +0.0% | +0.0% |
| gamteb | 473334440 | -2.1% | +0.0% | -2.1% |
| gcd | 205458336 | +0.0% | +0.0% | +0.0% |
| gen_regexps | 447854800 | +0.0% | +0.0% | +0.0% |
| genfft | 517071368 | +0.0% | +0.0% | +0.0% |
| gg | 461011304 | +0.0% | +0.0% | +0.0% |
| grep | 447848976 | -0.0% | +0.0% | -0.0% |
| hidden | 349555848 | +0.0% | +0.0% | +0.0% |
| hpg | 342996448 | +0.0% | +0.0% | +0.0% |
| ida | 348109296 | +0.0% | +0.0% | +0.0% |
| infer | 221641496 | +0.1% | +0.0% | +0.1% |
| integer | 308020648 | +0.0% | +0.0% | +0.0% |
| integrate | 342470848 | +0.0% | +0.0% | +0.0% |
| k-nucleotide | 0 |  |  |  |
| kahan | 49080 | +0.0% | +0.0% | +0.0% |
| knights | 130041032 | -0.4% | +0.0% | -0.4% |
| lambda | 291501944 | +0.0% | +0.0% | +0.0% |
| last-piece | 743567088 | +0.0% | +0.0% | +0.0% |
| lcss | 669846936 | +0.0% | +0.0% | +0.0% |
| life | 274775096 | +0.0% | +0.0% | +0.0% |
| lift | 259816256 | +0.9% | +0.0% | +0.9% |
| linear | 470144752 | +0.0% | +0.0% | +0.0% |
| listcompr | 615676680 | +0.0% | +0.0% | +0.0% |
| listcopy | 675805448 | +0.0% | +0.0% | +0.0% |
| maillist | 809998896 | +0.0% | +0.0% | +0.0% |
| mandel | 175337024 | +0.0% | +0.0% | +0.0% |
| mandel2 | 2298992 | +0.0% | +0.0% | +0.0% |
| mate | 60655328 | +0.1% | +0.1% | +0.2% |
| minimax | 291353088 | +0.0% | +0.0% | +0.0% |
| mkhprog | 1100077760 | +0.0% | +0.0% | +0.0% |
| multiplier | 379885160 | +0.0% | +0.0% | +0.0% |
| n-body | 163144 | +0.0% | +0.0% | +0.0% |
| nucleic2 | 338159128 | +0.8% | +0.0% | +0.8% |
| para | 501836112 | +0.0% | +0.0% | +0.0% |
| paraffins | 407532528 | +0.0% | +0.0% | +0.0% |
| parser | 240605560 | +0.0% | +0.0% | +0.0% |
| parstof | 154654392 | +0.0% | +0.0% | +0.0% |
| pic | 310856552 | +0.0% | +0.0% | +0.0% |
| pidigits | 921309816 | +0.0% | +0.0% | +0.0% |
| power | 159684144 | +0.0% | +0.0% | +0.0% |
| pretty | 136560 | +0.0% | +0.0% | +0.0% |
| primes | 489067504 | +0.0% | +0.0% | +0.0% |
| primetest | 70431120 | +0.0% | +0.0% | +0.0% |
| prolog | 258439704 | +0.1% | +0.0% | +0.1% |
| puzzle | 191279296 | +2.1% | +0.0% | +2.1% |
| queens | 115735672 | +0.0% | +0.0% | +0.0% |
| reptile | 44609600 | +0.0% | +0.0% | +0.0% |
| reverse-complement | 59880 | +0.0% | +0.0% | +0.0% |
| rewrite | 139306112 | +0.0% | -0.0% | -0.0% |
| rfib | 106224 | +0.0% | +0.0% | +0.0% |
| rsa | 173873872 | +0.0% | +0.0% | +0.0% |
| scc | 57968 | +0.3% | +0.0% | +0.3% |
| sched | 337602760 | +0.0% | +0.0% | +0.0% |
| scs | 408726016 | -0.0% | +0.0% | +0.0% |
| simple | 82104688 | +0.0% | +0.0% | +0.0% |
| smallpt | 0 |  |  |  |
| solid | 640379584 | +0.0% | +0.0% | +0.0% |
| sorting | 241203832 | +0.0% | +0.0% | +0.0% |
| spectral-norm | 186936 | +0.0% | +0.0% | +0.0% |
| sphere | 205488456 | +0.4% | +0.0% | +0.4% |
| symalg | 69364520 | +0.0% | +0.0% | +0.0% |
| tak | 96872 | +0.0% | +0.0% | +0.0% |
| transform | 394676944 | +0.0% | +0.0% | +0.0% |
| treejoin | 465764632 | +0.7% | +0.0% | +0.7% |
| typecheck | 262950712 | +0.0% | +0.1% | +0.1% |
| veritas | 419856696 | +0.0% | +0.0% | +0.0% |
| wang | 486367736 | +0.0% | +0.0% | +0.0% |
| wave4main | 305912088 | +13.8% | +0.3% | +12.3% |
| wheel-sieve1 | 27573136 | +0.0% | +0.0% | +0.0% |
| wheel-sieve2 | 362093904 | +0.0% | +0.0% | +0.0% |
| x2n1 | 57312 | +0.0% | +0.0% | +0.0% |

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
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/STRand.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Unboxed.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene1.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene2.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Type.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: UnboxedBVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Vector.o] Error 1
    fasta: expected stdout not matched by reality
    fasta: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
    k-nucleotide: **** expected exit status 0 not seen ; got 139
    k-nucleotide: expected stderr not matched by reality
    k-nucleotide: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
- late: 32 lines
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
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/STRand.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Unboxed.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene1.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene2.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Type.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: UnboxedBVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Vector.o] Error 1
    fasta: expected stdout not matched by reality
    fasta: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
    k-nucleotide: **** expected exit status 0 not seen ; got 139
    k-nucleotide: expected stderr not matched by reality
    k-nucleotide: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
- early: 32 lines
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
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/STRand.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Unboxed.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene1.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene2.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Type.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: UnboxedBVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Vector.o] Error 1
    fasta: expected stdout not matched by reality
    fasta: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
    k-nucleotide: **** expected exit status 0 not seen ; got 139
    k-nucleotide: expected stderr not matched by reality
    k-nucleotide: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
- early-late: 32 lines
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
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/STRand.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: SamplerMonad/Unboxed.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene1.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Scene2.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Scene/Type.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: UnboxedBVH.o] Error 1
    ben-raytrace: make[2]: *** [../../mk/suffix.mk:23: Vector.o] Error 1
    fasta: expected stdout not matched by reality
    fasta: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
    k-nucleotide: **** expected exit status 0 not seen ; got 139
    k-nucleotide: expected stderr not matched by reality
    k-nucleotide: make[2]: *** [../../mk/target.mk:101: runtests] Error 1
