#!/usr/bin/env bash
# One-shot marks on raised lambdas (Note [Raised lambdas are one-shot] in
# GHC.WebCore.Transform.ArityRaise): early-ulsl8 (with defunc) and
# early-ulsl8-sc (constant specialisation, no defunc) rebuilt with the fix,
# as early-ulsl8-os and early-ulsl8-sco.
#
#   webs-bench/run-oneshot.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-os "$O -fcore-webs-defunc"
webs-bench/run-nofib.sh early-ulsl8-sco "$O -ddump-webs-spec -fcore-webs-spec-calls"
python3 webs-bench/report.py base early-ulsl8 early-ulsl8-os early-ulsl8-sc early-ulsl8-sco > webs-bench/results/report-oneshot.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8 early-ulsl8-os early-ulsl8-sc early-ulsl8-sco --label oneshot --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl8" webs-bench/results/timing-oneshot.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: one-shot raised lambdas, nofib done" "instructions vs base: $summary"
