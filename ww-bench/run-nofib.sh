#!/usr/bin/env bash
# Run nofib with one compiler configuration and collect the higher-order
# worker/wrapper statistics (-ddump-ww-ho-stats).
#
#   ww-bench/run-nofib.sh NAME "EXTRA GHC OPTIONS"
#
# Uses the stage-2 compiler of this tree (_build/stage1/bin/ghc).  Results go
# to ww-bench/results/NAME/:
#   nofib.log      the nofib log (runtimes, allocations, compile times;
#                  compare logs with nofib/nofib-analyse)
#   dumps/         per-module dumps, mirroring the nofib tree:
#                    *.dump-first-class-stats   (GHC.WebCore.FirstClass)
#                    *.dump-simpl-stats         (simplifier/inliner ticks)
# Set NOFIB_MODE (default fast) and NOFIB_DIRS (default: nofib's own default
# set of benchmark directories) to change what runs, and NOFIB_OPT (default
# -O2, nofib's own default) for the optimisation level.
#
# Timeouts: each compiler invocation is limited to WEBS_GHC_TIMEOUT seconds
# (default 300; see ghc-timeout.sh), and the whole build-and-run of one
# configuration to WEBS_CONFIG_TIMEOUT seconds (default 3600), which also
# catches benchmarks that do not terminate.  A timeout is recorded in
# exit-code (124) and the dumps collected so far are kept.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GHC=$ROOT/ww-bench/ghc-timeout.sh
CONFIG_TIMEOUT=${WEBS_CONFIG_TIMEOUT:-3600}
NAME=$1
OPTS=${2:-}
MODE=${NOFIB_MODE:-fast}
OPT=${NOFIB_OPT:--O2}
OUT=$ROOT/ww-bench/results/$NAME
DUMPDIR=ww-dumps-$NAME

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT/nofib"

DIRS_ARG=()
if [ -n "${NOFIB_DIRS:-}" ]; then DIRS_ARG=("NoFibSubDirs=$NOFIB_DIRS"); fi

echo "[$NAME] cleaning"
make clean "${DIRS_ARG[@]}" > "$OUT/clean.log" 2>&1
find . -type d -name "ww-dumps-*" -prune -exec rm -rf {} +

echo "[$NAME] boot"
make boot WithNofibHc="$GHC" mode="$MODE" "${DIRS_ARG[@]}" > "$OUT/boot.log" 2>&1

echo "[$NAME] build and run (options: $OPTS)"
timeout --kill-after=60 "$CONFIG_TIMEOUT" \
make -k WithNofibHc="$GHC" mode="$MODE" NoFibRuns=1 "${DIRS_ARG[@]}" \
     NoFibHcOpts="$OPT -Wno-tabs" \
     EXTRA_HC_OPTS="$OPTS -ddump-to-file -dumpdir $DUMPDIR/ -ddump-ww-ho-stats" \
     > "$OUT/nofib.log" 2>&1
status=$?
echo "[$NAME] make exit code: $status" | tee "$OUT/exit-code"
if [ $status -eq 124 ]; then echo "[$NAME] TIMED OUT after ${CONFIG_TIMEOUT}s"; fi

echo "[$NAME] collecting dumps"
find . -type d -name "$DUMPDIR" | while read -r d; do
  bench=$(dirname "$d" | sed 's|^\./||')
  mkdir -p "$OUT/dumps/$bench"
  cp "$d"/*.dump-ww-ho-stats "$OUT/dumps/$bench/" 2>/dev/null
done
echo "[$NAME] done: $OUT"
