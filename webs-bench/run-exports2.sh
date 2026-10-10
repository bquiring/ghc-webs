#!/usr/bin/env bash
# The boundary split for every exported function, contracted where the local
# copy is unchanged, with eta-expanded higher-order parameters (Note
# [Contracting the boundary split], Note [Eta-expanding parameters at the
# boundary]): early-bnd3 without and early-bm3 with the main module's exports
# internal, against base and early-bm (the previous boundary split).  4 build
# jobs, timing on 4 performance cores; a desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -ddump-webs-data -dcore-lint"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-bnd3 "$O -fcore-webs-boundary"
webs-bench/run-nofib.sh early-bm3 "$O -fcore-webs-boundary -fcore-webs-internal-main-exports"
python3 webs-bench/report.py base early-bm early-bnd3 early-bm3 > webs-bench/results/report-exports2.md 2>&1
python3 webs-bench/time-nofib.py base early-bm early-bnd3 early-bm3 --label exports2 --rounds 3 --cpus 2,4,6,8
python3 webs-bench/verdicts.py early-bm early-bnd3 early-bm3 > webs-bench/results/verdicts-exports2.md 2>&1
summary=$(grep -E "^\| (early-bm|early-bnd3|early-bm3) \|" webs-bench/results/timing-exports2.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: exports2 experiment done" "instructions vs base: $summary"
