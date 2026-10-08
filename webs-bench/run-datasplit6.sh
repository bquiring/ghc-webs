#!/usr/bin/env bash
# Unboxing with the bounds of Note [Bounding unboxing]: the defaults (nested
# off, size 4: early-du6) and nested on (early-du6n), against early-du5 (no
# bounds); instruction counts against base and early-fix.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-du6 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-du6n "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-unbox-nested -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-du5 early-du6 early-du6n --label datasplit6 --rounds 1
