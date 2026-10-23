#!/usr/bin/env bash
# PLDI'27 experiment H: F again with the final compiler (the restore of
# occurrences fixed): occ3 (paper configuration) and occ-agg3 (with the
# aggressive GHC flags), timed with base, agg and inl180 (kept from F).
# Then the SML suite (run-paper-g.sh).
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
A="-fspecialise-aggressively -fexpose-all-unfoldings -fspec-constr-count=6 -fspec-constr-threshold=4000"
D="-dcore-lint -ddump-webs-stats"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh occ3 "$B $D"
webs-bench/run-nofib.sh occ-agg3 "$B $A $D"
for c in occ3 occ-agg3; do echo "$c lint/panics: $(grep -c 'Lint errors\|panic!' webs-bench/results/$c/nofib.log)"; done
python3 webs-bench/report.py base occ3 agg inl180 occ-agg3 > webs-bench/results/report-paper-h.md 2>&1
python3 webs-bench/time-nofib.py base occ3 agg inl180 occ-agg3 --label paper-h --rounds 3 --cpus 2,4,6,8
notify-send -a webs -i dialog-information "Webs: paper H (nofib) done" "timing-paper-h.md"
webs-bench/run-paper-g.sh
