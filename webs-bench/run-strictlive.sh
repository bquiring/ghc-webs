#!/usr/bin/env bash
# Strict and live (Note [Strict and live]): early-ulsda's options with the current compiler
# of internal types]) instead of dead parameters (early-ulsl), timed against
# base and early-bnd4 (run-useless.sh); also collects the forced analysis
# with fields and let-bound thunks (-ddump-webs-forced, Note [Forced
# fields]).  Built with -dcore-lint; a desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl "$O -fcore-webs-useless -fcore-webs-data-again"
python3 webs-bench/report.py base early-ulsda early-ulsl > webs-bench/results/report-strictlive.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsda early-ulsl --label strictlive --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (early-ulsda|early-ulsl) \|" webs-bench/results/timing-strictlive.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: useless elimination with fields done" "instructions vs base: $summary"
