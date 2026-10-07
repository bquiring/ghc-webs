#!/usr/bin/env bash
# Rebuild early-fix and early-bnd with the current compiler and time them
# against base (whose executables run-nofib.sh kept).
set -u
cd "$(dirname "$0")/.."
LABEL=${1:-validate}
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-fix "-fcore-webs-early $T"
webs-bench/run-nofib.sh early-bnd "-fcore-webs-early $T -fcore-webs-boundary"
python3 webs-bench/verdicts.py early-t80 early-fix early-bnd > webs-bench/results/verdicts-$LABEL.md 2>&1
python3 webs-bench/report.py base early-t80 early-fix early-bnd > webs-bench/results/report-$LABEL.md 2>&1
python3 webs-bench/time-nofib.py base early-fix early-bnd --label $LABEL --rounds 3
