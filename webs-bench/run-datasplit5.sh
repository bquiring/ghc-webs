#!/usr/bin/env bash
# Unboxing strictly eliminated fields (Note [Strictly eliminated fields]):
# split + unbox (early-du5), against the earlier unboxing (early-du4) and
# eager unboxing (early-due4); instruction counts against base and early-fix.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-du5 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-du4 early-du5 early-due4 --label datasplit5 --rounds 1
