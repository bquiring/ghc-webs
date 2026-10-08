#!/usr/bin/env bash
# Data splitting (-fcore-webs-data-split) and field unboxing
# (-fcore-webs-data-unbox) on top of the early-fix transformations, built
# with -dcore-lint; instruction counts against base and early-fix (results
# linked from the main tree).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-ds2 "-fcore-webs-early $T -fcore-webs-data-split -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-du2 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-ds2 early-du2 --label datasplit --rounds 1
