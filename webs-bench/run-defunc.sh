#!/usr/bin/env bash
# Defunctionalisation (-fcore-webs-defunc) on top of early-fix, built with
# -dcore-lint (Lint does not change the code), timed against base and
# early-fix (whose executables run-nofib.sh kept).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-df "-fcore-webs-early $T -fcore-webs-defunc -dcore-lint"
python3 webs-bench/report.py base early-fix early-df > webs-bench/results/report-defunc.md 2>&1
python3 webs-bench/time-nofib.py base early-fix early-df --label defunc --rounds 3
python3 webs-bench/verdicts.py early-df > webs-bench/results/verdicts-defunc.md 2>&1
