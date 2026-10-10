#!/usr/bin/env bash
# Useless elimination again, after the fresh-binders fix (WEBS-BUGS.md):
# early-uls2 replaces dead parameters with useless elimination, early-ulsd2
# runs both; early-bnd4 (from run-useless.sh) is the baseline.  Also
# collects the strictness dual's counts (-ddump-webs-forced).  Built with -dcore-lint, timed against base; 4 build jobs,
# timing on 4 performance cores; a desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-uls2 "$O -fcore-webs-useless"
webs-bench/run-nofib.sh early-ulsd2 "$O -fcore-webs-dead-params -fcore-webs-useless"
python3 webs-bench/report.py base early-bnd4 early-uls2 early-ulsd2 > webs-bench/results/report-useless2.md 2>&1
python3 webs-bench/time-nofib.py base early-bnd4 early-uls2 early-ulsd2 --label useless2 --rounds 3 --cpus 2,4,6,8
python3 webs-bench/verdicts.py early-bnd4 early-uls2 early-ulsd2 > webs-bench/results/verdicts-useless2.md 2>&1
summary=$(grep -E "^\| (early-bnd4|early-uls2|early-ulsd2) \|" webs-bench/results/timing-useless2.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: useless elimination experiment done" "instructions vs base: $summary"
