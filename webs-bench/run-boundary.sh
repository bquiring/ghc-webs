#!/usr/bin/env bash
# The strictness fixpoints and boundary splitting (-fcore-webs-boundary),
# against base and early-t80 (the early run before both; run-inliner.sh).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-fix "-fcore-webs-early $T"
webs-bench/run-nofib.sh early-bnd "-fcore-webs-early $T -fcore-webs-boundary"
python3 webs-bench/verdicts.py early-t80 early-fix early-bnd > webs-bench/results/verdicts-boundary.md 2>&1
python3 webs-bench/report.py base early-t80 early-fix early-bnd > webs-bench/results/report-boundary.md 2>&1
echo "reports: webs-bench/results/verdicts-boundary.md, webs-bench/results/report-boundary.md"
# Runtime: base's executables must be kept (run-nofib.sh base "")
python3 webs-bench/time-nofib.py base early-fix early-bnd --label boundary --rounds 3
