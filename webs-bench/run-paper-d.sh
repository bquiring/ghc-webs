#!/usr/bin/env bash
# PLDI'27 experiments, part D: two opt-in heuristics on top of
# early-ulsl8-scl, with the compiler rebuilt 2026-10-22 (defaults unchanged):
#   scl2     early-ulsl8-scl's options (control: the rebuild changes nothing)
#   scl-k8   -fcore-webs-spec-max-keys=8   (mate's eight directions)
#   scl-a6   -fcore-webs-raise-max-args=6  (hpg's 9-argument unknown call,
#            Note [Arguments of unknown calls])
#   scl-k8a6 both
#
#   webs-bench/run-paper-d.sh
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
D="-dcore-lint -ddump-webs-stats -ddump-webs-spec"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh scl2 "$B $D"
webs-bench/run-nofib.sh scl-k8 "$B $D -fcore-webs-spec-max-keys=8"
webs-bench/run-nofib.sh scl-a6 "$B $D -fcore-webs-raise-max-args=6"
webs-bench/run-nofib.sh scl-k8a6 "$B $D -fcore-webs-spec-max-keys=8 -fcore-webs-raise-max-args=6"
python3 webs-bench/report.py base early-ulsl8-scl scl2 scl-k8 scl-a6 scl-k8a6 > webs-bench/results/report-paper-d.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8-scl scl2 scl-k8 scl-a6 scl-k8a6 --label paper-d --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (scl|early)" webs-bench/results/timing-paper-d.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: paper D done" "instructions vs base: $summary"
