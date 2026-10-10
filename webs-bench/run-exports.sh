#!/usr/bin/env bash
# Exposure through exports (WEBS-BACKLOG.md, "What exposes webs and data
# types: measured"): early-mdf's options with the boundary split
# (early-bnd2), with the main module's exports internal (early-main, Note
# [Main's exports]), and with both (early-bm), timed against base and
# early-mdf.  4 build jobs, timing on 4 performance cores; a desktop
# notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -ddump-webs-data -dcore-lint"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-bnd2 "$O -fcore-webs-boundary"
webs-bench/run-nofib.sh early-main "$O -fcore-webs-internal-main-exports"
webs-bench/run-nofib.sh early-bm "$O -fcore-webs-boundary -fcore-webs-internal-main-exports"
python3 webs-bench/report.py base early-mdf early-bnd2 early-main early-bm > webs-bench/results/report-exports.md 2>&1
python3 webs-bench/time-nofib.py base early-mdf early-bnd2 early-main early-bm --label exports --rounds 3 --cpus 2,4,6,8
python3 webs-bench/verdicts.py early-mdf early-bnd2 early-main early-bm > webs-bench/results/verdicts-exports.md 2>&1
summary=$(grep -E "^\| (early-mdf|early-bnd2|early-main|early-bm) \|" webs-bench/results/timing-exports.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: exports experiment done" "instructions vs base: $summary"
