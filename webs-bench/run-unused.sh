#!/usr/bin/env bash
# Unused exports (Note [Unused exports] in GHC.WebCore.Pipeline): early-ulsl's
# options plus -fcore-webs-unused-exports, as NAME (default early-unused).
#
# Pass 1 builds nofib at -O0 without running it, for the interfaces and
# the -Wunused-imports warnings (ghc-warnlog.sh); for each benchmark
# directory, webs-bench/unused-exports.py writes
# webs-unused.txt (the exports no other module of the program uses), which
# nofib's clean leaves alone.  Pass 2 is run-verify.sh's configuration with
# the list, timed against base and early-ulsl.
#
#   webs-bench/run-unused.sh [NAME]
set -u
cd "$(dirname "$0")/.."
N=${1:-early-unused}
ROOT=$(pwd)
GHC=$ROOT/_build/stage1/bin/ghc

echo "[$N] pass 1: interfaces at -O0"
mkdir -p webs-bench/results
(cd nofib && make clean > /dev/null 2>&1
 find . \( -name webs-unused.txt -o -name webs-warnings.log \) -delete
 make boot WithNofibHc="$ROOT/webs-bench/ghc-timeout.sh" mode=fast > /dev/null 2>&1
 make -k -j4 WithNofibHc="$ROOT/webs-bench/ghc-warnlog.sh" mode=fast NoFibRuns=1 RUNTEST=true \
      EXTRA_HC_OPTS="-O0 -Wunused-imports" > "$ROOT/webs-bench/results/unused-pass1-$N.log" 2>&1)
: > webs-bench/results/unused-lists-$N.txt
find nofib -name '*.hi' -printf '%h\n' | sort -u | while read -r d; do
  python3 webs-bench/unused-exports.py "$GHC" "$d" --warnings "$d/webs-warnings.log" >> webs-bench/results/unused-lists-$N.txt
done
echo "[$N] lists: $(awk '{n+=$(NF-1)} END {print n}' webs-bench/results/unused-lists-$N.txt) unused exports"

T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh $N "$O -fcore-webs-unused-exports=webs-unused.txt"
python3 webs-bench/report.py base early-ulsl $N > webs-bench/results/report-$N.md 2>&1
python3 webs-bench/verdicts.py $N > webs-bench/results/verdicts-$N.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl $N --label $N --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| $N \|" webs-bench/results/timing-$N.md | cut -d'|' -f2,4 | tr -s ' ')
notify-send -a webs -i dialog-information "Webs: unused exports done" "instructions vs base: $summary"
