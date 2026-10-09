#!/usr/bin/env bash
# After merging webs into data-split: the current compiler with early-cur's
# options (now with constructed-argument raising and hidden fields:
# early-m), and with defunctionalisation too (early-mdf), timed against base
# and early-cur.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-m "$O"
webs-bench/run-nofib.sh early-mdf "$O -fcore-webs-defunc"
python3 webs-bench/report.py base early-cur early-m early-mdf > webs-bench/results/report-merged.md 2>&1
python3 webs-bench/time-nofib.py base early-cur early-m early-mdf --label merged --rounds 3
python3 webs-bench/verdicts.py early-cur early-m early-mdf > webs-bench/results/verdicts-merged.md 2>&1
