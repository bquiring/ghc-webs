#!/usr/bin/env bash
# Data splitting with copies in coercions: split only (early-ds3), with field
# unboxing (early-du3) and eager unboxing (early-due3); instruction counts
# against base and early-fix, with early-du2 (unboxing before copies in
# coercions) for comparison.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-ds3 "-fcore-webs-early $T -fcore-webs-data-split -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-du3 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-due3 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-unbox-eager -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-ds3 early-du2 early-du3 early-due3 --label datasplit3 --rounds 1
