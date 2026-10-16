#!/usr/bin/env bash
# Constant specialisation (Note [Constant specialisation] in
# GHC.WebCore.Transform.ConstSpec): early-ulsl's options without
# defunctionalisation, with keys from web classes (early-ulsl8-sw) and from
# calls (early-ulsl8-sc), timed against base, early-ulsl8 (with defunc) and
# early-ulsl8-nod (without).
#
#   webs-bench/run-constspec.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again -ddump-webs-spec"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-sw "$O -fcore-webs-spec-webs"
webs-bench/run-nofib.sh early-ulsl8-sc "$O -fcore-webs-spec-calls"
python3 webs-bench/report.py base early-ulsl8 early-ulsl8-nod early-ulsl8-sw early-ulsl8-sc > webs-bench/results/report-constspec.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8 early-ulsl8-nod early-ulsl8-sw early-ulsl8-sc --label constspec --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl8" webs-bench/results/timing-constspec.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: constant specialisation, nofib done" "instructions vs base: $summary"
