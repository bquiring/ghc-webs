#!/usr/bin/env bash
# Early against late web runs: the function-web transformations late
# (late-fix, against early-fix), and data splitting with unboxing early
# (early-du8) and late (late-du; Note [Unboxing in the late run]); all with
# -dcore-lint; instruction counts against base and early-fix.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh late-fix "-fcore-webs $T -dcore-lint"
webs-bench/run-nofib.sh early-du8 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh late-du "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix late-fix early-du8 late-du --label earlylate --rounds 1
