#!/usr/bin/env bash
# Field unboxing after the fixpoint (early-du2) and with eager unboxing
# (early-due), then instruction counts with split-only (early-ds2, from
# run-datasplit.sh) against base and early-fix.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-du2 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-due "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-unbox-eager -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-ds2 early-du2 early-due --label datasplit --rounds 1
