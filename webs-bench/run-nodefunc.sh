#!/usr/bin/env bash
# Where defunctionalisation's gains come from: early-ulsl's options without
# -fcore-webs-defunc (early-ulsl8-nod), with the current compiler, timed
# against base and early-ulsl8 (run-libcase.sh).
#
#   webs-bench/run-nodefunc.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-nod "$O"
python3 webs-bench/report.py base early-ulsl8 early-ulsl8-nod > webs-bench/results/report-nodefunc.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8 early-ulsl8-nod --label nodefunc --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (early-ulsl8|early-ulsl8-nod) \|" webs-bench/results/timing-nodefunc.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: nofib without defunctionalisation done" "instructions vs base: $summary"
