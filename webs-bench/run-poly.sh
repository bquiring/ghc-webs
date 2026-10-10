#!/usr/bin/env bash
# Function-level polymorphism in the final Core (Note [Polymorphism
# statistics] in GHC.WebCore.PolyStats, in -ddump-first-class-stats): GHC's
# own pipeline (poly-base) and the webs baseline (poly-bnd3, early-bnd3's
# options).  Builds and runs only; nothing is timed.  Summarised by
# poly-report.py.  A desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh poly-base ""
webs-bench/run-nofib.sh poly-bnd3 "$O"
python3 webs-bench/poly-report.py poly-base poly-bnd3 > webs-bench/results/report-poly.md 2>&1
notify-send -a webs -i dialog-information "Webs: polymorphism measurement done" "webs-bench/results/report-poly.md"
