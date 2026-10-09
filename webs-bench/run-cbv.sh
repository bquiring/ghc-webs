#!/usr/bin/env bash
# Call-by-value marks for unboxed tuple arguments (Note [CBV marks for unboxed
# tuple arguments] in GHC.Core.Tidy): early-du9 (against early-du8), and the
# late run with the uncurrying gate (late-fix4, against late-fix3) and without
# it (late-fix4k: -fcore-webs-uncurry-known).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-du9 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh late-fix4 "-fcore-webs $T -dcore-lint"
webs-bench/run-nofib.sh late-fix4k "-fcore-webs $T -fcore-webs-uncurry-known -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-du8 early-du9 late-fix3 late-fix4 late-fix4k --label cbv --rounds 1
