#!/usr/bin/env bash
# Run nofib with one compiler configuration and collect the web experiment
# dumps.
#
#   webs-bench/run-nofib.sh NAME "EXTRA GHC OPTIONS"
#
# Uses the stage-2 compiler of this tree (_build/stage1/bin/ghc).  Results go
# to webs-bench/results/NAME/:
#   nofib.log      the nofib log (runtimes, allocations, compile times;
#                  compare logs with nofib/nofib-analyse)
#   dumps/         per-module dumps, mirroring the nofib tree:
#                    *.dump-first-class-stats   (GHC.WebCore.FirstClass)
#                    *.dump-simpl-stats         (simplifier/inliner ticks)
#                    *.dump-webs-*              (verdicts of each web transformation)
#   bin/           each benchmark's executable, mirroring the nofib tree
#   runs.tsv       how to run each one in TIMING_MODE (default norm), for
#                  time-nofib.py: benchmark, directory, runstdtest command
# Set NOFIB_MODE (default fast) and NOFIB_DIRS (default: nofib's own default
# set of benchmark directories) to change what runs, and NOFIB_JOBS (default
# 1) to build and run benchmarks in parallel.
#
# Timeouts: each compiler invocation is limited to WEBS_GHC_TIMEOUT seconds
# (default 300; see ghc-timeout.sh), and the whole build-and-run of one
# configuration to WEBS_CONFIG_TIMEOUT seconds (default 3600), which also
# catches benchmarks that do not terminate.  A timeout is recorded in
# exit-code (124) and the dumps collected so far are kept.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GHC=$ROOT/webs-bench/ghc-timeout.sh
CONFIG_TIMEOUT=${WEBS_CONFIG_TIMEOUT:-3600}
NAME=$1
OPTS=${2:-}
MODE=${NOFIB_MODE:-fast}
OUT=$ROOT/webs-bench/results/$NAME
DUMPDIR=webs-dumps-$NAME
VERDICTS="-ddump-webs-one-shot -ddump-webs-inline -ddump-webs-const-prop -ddump-webs-arity-raise -ddump-webs-dead-params -ddump-webs-defunc
          -ddump-webs-uncurry -ddump-webs-result-raise -ddump-webs-strictness"
VERDICTS=$(echo $VERDICTS)

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT/nofib"

DIRS_ARG=()
if [ -n "${NOFIB_DIRS:-}" ]; then DIRS_ARG=("NoFibSubDirs=$NOFIB_DIRS"); fi

echo "[$NAME] cleaning"
make clean "${DIRS_ARG[@]}" > "$OUT/clean.log" 2>&1
find . -type d -name "webs-dumps-*" -prune -exec rm -rf {} +

echo "[$NAME] boot"
make boot WithNofibHc="$GHC" mode="$MODE" "${DIRS_ARG[@]}" > "$OUT/boot.log" 2>&1

echo "[$NAME] build and run (options: $OPTS)"
timeout --kill-after=60 "$CONFIG_TIMEOUT" \
make -k -j"${NOFIB_JOBS:-1}" WithNofibHc="$GHC" mode="$MODE" NoFibRuns=1 "${DIRS_ARG[@]}" \
     EXTRA_HC_OPTS="$OPTS -ddump-to-file -dumpdir $DUMPDIR/ -ddump-first-class-stats -ddump-simpl-stats $VERDICTS" \
     > "$OUT/nofib.log" 2>&1
status=$?
echo "[$NAME] make exit code: $status" | tee "$OUT/exit-code"
if [ $status -eq 124 ]; then echo "[$NAME] TIMED OUT after ${CONFIG_TIMEOUT}s"; fi

echo "[$NAME] collecting dumps"
find . -type d -name "$DUMPDIR" | while read -r d; do
  bench=$(dirname "$d" | sed 's|^\./||')
  mkdir -p "$OUT/dumps/$bench"
  cp "$d"/*.dump-first-class-stats "$d"/*.dump-simpl-stats "$d"/*.dump-webs-* "$OUT/dumps/$bench/" 2>/dev/null
done

# Keep the executables, which the next configuration's clean deletes, so
# time-nofib.py can time the configurations against each other later.  The
# run command comes from nofib itself (make -n), in TIMING_MODE.
TIMING_MODE=${TIMING_MODE:-norm}
echo "[$NAME] keeping executables (run commands for mode $TIMING_MODE)"
: > "$OUT/runs.tsv"
find . -type d -name "$DUMPDIR" | sort | while read -r d; do
  dir=$(dirname "$d" | sed 's|^\./||')
  cmd=$(cd "$dir" && make -n -s runtests mode="$TIMING_MODE" NoFibRuns=1 WithNofibHc="$GHC" 2>/dev/null \
        | grep -m1 'runstdtest ' | sed 's/;[[:space:]]*$//')
  exe=$(echo "$cmd" | awk '{print $2}')
  if [ -n "$cmd" ] && [ -x "$dir/$exe" ]; then
    mkdir -p "$OUT/bin/$dir"
    cp "$dir/$exe" "$OUT/bin/$dir/"
    printf '%s\t%s\t%s\n' "$(basename "$dir")" "$dir" "$cmd" >> "$OUT/runs.tsv"
  fi
done
echo "[$NAME] kept $(wc -l < "$OUT/runs.tsv") executables"
echo "[$NAME] done: $OUT"
