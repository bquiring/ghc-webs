#!/usr/bin/env bash
# The late web run with uncurrying limited to webs with an unknown call (Note
# [Uncurrying known calls]), and the simplifier after it: late-fix3 and
# late-du3, against late-fix2, late-du2 and the early configurations.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh late-fix3 "-fcore-webs $T -dcore-lint"
webs-bench/run-nofib.sh late-du3 "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix late-fix2 late-fix3 early-du8 late-du2 late-du3 --label late3 --rounds 1
