#!/usr/bin/env bash
# The late web run followed by the simplifier and the final demand analysis
# (Note [Simplifying after the late webs]): late-fix2 and late-du2, against
# late-fix, late-du (without them) and early-fix, early-du8.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh late-fix2 "-fcore-webs $T -dcore-lint"
webs-bench/run-nofib.sh late-du2 "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix late-fix late-fix2 early-du8 late-du late-du2 --label late2 --rounds 1
