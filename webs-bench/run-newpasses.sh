#!/usr/bin/env bash
# Constructed-argument raising (part of -fcore-webs-arity-raise since
# 78d6fd8fc9) and one-shot lambdas (-fcore-webs-one-shot), on top of the
# early-fix transformations: early-cr is early-fix rebuilt with the current
# compiler, early-os adds one-shot lambdas.  Built with -dcore-lint, timed
# against base and early-fix.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-cr "-fcore-webs-early $T -dcore-lint"
webs-bench/run-nofib.sh early-os "-fcore-webs-early $T -fcore-webs-one-shot -dcore-lint"
python3 webs-bench/report.py base early-fix early-cr early-os > webs-bench/results/report-newpasses.md 2>&1
python3 webs-bench/time-nofib.py base early-fix early-cr early-os --label newpasses --rounds 3
python3 webs-bench/verdicts.py early-fix early-cr early-os > webs-bench/results/verdicts-newpasses.md 2>&1
