#!/usr/bin/env bash
# Liberate case through join points (Note [Liberate case through join points]
# in GHC.Core.Opt.LiberateCase): base and early-ulsl's options, each with
# and without -fliberate-case-join-points, with the current compiler
# (early-ulsl8: the baseline after the 2026-10-15/16 fixes), timed together.
#
#   webs-bench/run-libcase.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
L="-fliberate-case-join-points"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh base-lcj "$L -dcore-lint"
webs-bench/run-nofib.sh early-ulsl8 "$O"
webs-bench/run-nofib.sh early-ulsl8-lcj "$O $L"
python3 webs-bench/report.py base base-lcj early-ulsl8 early-ulsl8-lcj > webs-bench/results/report-libcase.md 2>&1
python3 webs-bench/time-nofib.py base base-lcj early-ulsl8 early-ulsl8-lcj --label libcase --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (base-lcj|early-ulsl8|early-ulsl8-lcj) \|" webs-bench/results/timing-libcase.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: liberate case through join points, nofib done" "instructions vs base: $summary"
