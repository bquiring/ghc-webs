#!/usr/bin/env bash
# Data splitting with newtype copies (Note [Splitting newtypes]): split only (early-ds4), with field
# unboxing (early-du4) and eager unboxing (early-due4); instruction counts
# against base and early-fix, with early-du3 (before newtype splitting) for comparison.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-ds4 "-fcore-webs-early $T -fcore-webs-data-split -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-du4 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-due4 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-unbox-eager -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-ds4 early-du3 early-du4 early-due4 --label datasplit4 --rounds 1
