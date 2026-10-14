#!/usr/bin/env bash
# The baseline after the list and synonym fixes (ec8e62c538): early-ulsl's
# options with the current compiler (early-ulsl3), timed against base and
# early-ulsl and checked per benchmark against early-ulsl: no benchmark
# should lose instructions.  Built with -dcore-lint; a desktop notification
# at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl3 "$O"
python3 webs-bench/report.py base early-ulsl early-ulsl3 > webs-bench/results/report-verify.md 2>&1
python3 webs-bench/verdicts.py early-ulsl3 > webs-bench/results/verdicts-verify.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl early-ulsl3 --label verify --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl3 \|" webs-bench/results/timing-verify.md | cut -d'|' -f2,4 | tr -s ' ')
notify-send -a webs -i dialog-information "Webs: nofib baseline check done" "instructions vs base: $summary"
