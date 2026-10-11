#!/usr/bin/env bash
# Useless elimination with data splitting again after the web passes
# of internal types]) instead of dead parameters (early-ulsda), timed against
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
webs-bench/run-nofib.sh early-ulsda "$O -fcore-webs-useless -fcore-webs-data-again"
python3 webs-bench/report.py base early-bnd4 early-uls3 early-ulsda > webs-bench/results/report-uselessda.md 2>&1
python3 webs-bench/time-nofib.py base early-bnd4 early-ulsda --label uselessda --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (early-bnd4|early-ulsda) \|" webs-bench/results/timing-uselessda.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: useless elimination with fields done" "instructions vs base: $summary"
