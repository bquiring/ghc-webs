#!/usr/bin/env bash
# Moving constructors across webs (Note [Raising through tail calls], Note
# [Evaluated arguments]): early-ulsl's options with -fcore-webs-raise-through-calls
# -fcore-webs-evald-args, without defunctionalisation (early-ulsl8-nodm) and
# with it (early-ulsl8-m), timed against base, early-ulsl8 and early-ulsl8-nod.
#
#   webs-bench/run-movecons.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
M="-fcore-webs-raise-through-calls -fcore-webs-evald-args"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-nodm "$O $M"
webs-bench/run-nofib.sh early-ulsl8-m "$O -fcore-webs-defunc $M"
python3 webs-bench/report.py base early-ulsl8 early-ulsl8-nod early-ulsl8-nodm early-ulsl8-m > webs-bench/results/report-movecons.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8 early-ulsl8-nod early-ulsl8-nodm early-ulsl8-m --label movecons --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl8" webs-bench/results/timing-movecons.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: moving constructors, nofib done" "instructions vs base: $summary"
