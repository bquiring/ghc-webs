#!/usr/bin/env bash
# PLDI'27 experiment F (reviewer A): stronger GHC baselines.
#   agg       -fspecialise-aggressively -fexpose-all-unfoldings
#             -fspec-constr-count=6 -fspec-constr-threshold=4000
#   inl180    -funfolding-use-threshold=180 (twice the default)
#   occ-agg   the paper configuration on top of agg
#   occ2      the paper configuration, with the final compiler (control)
# Timed against base and each other.
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
A="-fspecialise-aggressively -fexpose-all-unfoldings -fspec-constr-count=6 -fspec-constr-threshold=4000"
D="-dcore-lint -ddump-webs-stats"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh occ2 "$B $D"
webs-bench/run-nofib.sh agg "$A $D"
webs-bench/run-nofib.sh inl180 "-funfolding-use-threshold=180 $D"
webs-bench/run-nofib.sh occ-agg "$B $A $D"
python3 webs-bench/report.py base occ2 agg inl180 occ-agg > webs-bench/results/report-paper-f.md 2>&1
python3 webs-bench/time-nofib.py base occ2 agg inl180 occ-agg --label paper-f --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (occ|agg|inl)" webs-bench/results/timing-paper-f.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: paper F done" "instructions vs base: $summary"
