#!/usr/bin/env bash
# Chunks (Note [Chunks] in GHC.WebCore.Chunk): every nofib program compiled
# as one Core program (webs-bench/ghc-chunk.sh as nofib's compiler), without
# webs (chunk-base, against base) and with early-ulsl's options (chunk-ulsl,
# against early-ulsl); timed together.  A desktop notification at the end.
#
#   webs-bench/run-chunk.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
export WEBS_NOFIB_HC=$PWD/webs-bench/ghc-chunk.sh
webs-bench/run-nofib.sh chunk-base "-dcore-lint"
webs-bench/run-nofib.sh chunk-ulsl "$O"
python3 webs-bench/report.py base chunk-base early-ulsl chunk-ulsl > webs-bench/results/report-chunk.md 2>&1
python3 webs-bench/verdicts.py early-ulsl chunk-ulsl > webs-bench/results/verdicts-chunk.md 2>&1
python3 webs-bench/time-nofib.py base chunk-base early-ulsl chunk-ulsl --label chunk --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (chunk-base|chunk-ulsl) \|" webs-bench/results/timing-chunk.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: chunks done" "instructions vs base: $summary"
