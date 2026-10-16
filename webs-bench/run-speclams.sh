#!/usr/bin/env bash
# Partial applications and lambdas as keys of constant specialisation
# (Note [Specialising on lambdas] in GHC.WebCore.Transform.ConstSpec):
# early-ulsl8-sco with -fcore-webs-spec-lambdas, as early-ulsl8-scl.
#
#   webs-bench/run-speclams.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-scl "$O -ddump-webs-spec -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
python3 webs-bench/report.py base early-ulsl8-os early-ulsl8-sco early-ulsl8-scl > webs-bench/results/report-speclams.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8-os early-ulsl8-sco early-ulsl8-scl --label speclams --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl8" webs-bench/results/timing-speclams.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: spec-lambdas, nofib done" "instructions vs base: $summary"
