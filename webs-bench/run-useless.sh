#!/usr/bin/env bash
# Useless elimination (Note [Useless elimination], -fcore-webs-useless):
# early-bnd4 is the baseline (early-bnd3's options, current compiler),
# early-uls replaces dead parameters with useless elimination, early-ulsd
# runs both.  Built with -dcore-lint, timed against base; 4 build jobs,
# timing on 4 performance cores; a desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-bnd4 "$O -fcore-webs-dead-params"
webs-bench/run-nofib.sh early-uls "$O -fcore-webs-useless"
webs-bench/run-nofib.sh early-ulsd "$O -fcore-webs-dead-params -fcore-webs-useless"
python3 webs-bench/report.py base early-bnd4 early-uls early-ulsd > webs-bench/results/report-useless.md 2>&1
python3 webs-bench/time-nofib.py base early-bnd4 early-uls early-ulsd --label useless --rounds 3 --cpus 2,4,6,8
python3 webs-bench/verdicts.py early-bnd4 early-uls early-ulsd > webs-bench/results/verdicts-useless.md 2>&1
summary=$(grep -E "^\| (early-bnd4|early-uls|early-ulsd) \|" webs-bench/results/timing-useless.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: useless elimination experiment done" "instructions vs base: $summary"
