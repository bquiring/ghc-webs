#!/usr/bin/env bash
# PLDI'27 experiment E: the paper configuration (early-ulsl8-scl's options)
# with the compiler that restores occurrences after the round trip
# (Note [Occurrences after the round trip] in GHC.WebCore.Erase), and with
# the two opt-in bounds.  Timed against base and early-ulsl8-scl.
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
D="-dcore-lint -ddump-webs-stats"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh occ "$B $D"
webs-bench/run-nofib.sh occ-k8a6 "$B $D -fcore-webs-spec-max-keys=8 -fcore-webs-raise-max-args=6"
python3 webs-bench/report.py base early-ulsl8-scl occ occ-k8a6 > webs-bench/results/report-paper-e.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8-scl occ occ-k8a6 --label paper-e --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (occ|early)" webs-bench/results/timing-paper-e.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: paper E done" "instructions vs base: $summary"
