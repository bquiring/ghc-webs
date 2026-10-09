#!/usr/bin/env bash
# Strictness feeding raising (Note [Recording proven strictness], Note
# [Component demands], Note [Repeating the transformations]): early-mdf's
# options with the new compiler, one pass (early-ns) and two (early-ns2),
# timed against base and early-mdf.  Builds with 4 jobs, timing on 4
# performance cores (instruction counts match the serial runner).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -ddump-webs-data -dcore-lint"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ns "$O"
webs-bench/run-nofib.sh early-ns2 "$O -fcore-webs-passes=2"
python3 webs-bench/report.py base early-mdf early-ns early-ns2 > webs-bench/results/report-strict.md 2>&1
python3 webs-bench/time-nofib.py base early-mdf early-ns early-ns2 --label strict --rounds 3 --cpus 2,4,6,8
python3 webs-bench/verdicts.py early-mdf early-ns early-ns2 > webs-bench/results/verdicts-strict.md 2>&1
