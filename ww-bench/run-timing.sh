#!/usr/bin/env bash
# The full experiment with run times, in two phases:
#
#   ww-bench/run-timing.sh build          nofib in norm mode (fast mode runs
#                                         take about 0.1 s, too short to time)
#                                         for base and funres, the usual report
#                                         (allocation, size, statistics), and
#                                         the binaries stashed in ww-bench/bins
#   ww-bench/run-timing.sh time [ROUNDS] [CPU]
#                                         timing.py's pinned, interleaved runs
#                                         of the stashed binaries (default 10
#                                         rounds on CPU 4, a performance core)
#   ww-bench/run-timing.sh [ROUNDS] [CPU] both
#
# Results: ww-bench/results/{base-norm,funres-norm}, report-norm.md,
# timing-base-norm-funres-norm.jsonl and timing-norm.md.
#
# The time phase needs a quiet machine: no builds or other benchmarks (the
# webs branch has its own), and preferably on mains power.  With
# kernel.perf_event_paranoid <= 2 it also counts instructions and cycles
# (perf-wrap.sh), which do not depend on the CPU frequency.  It can be
# interrupted and resumed: runs already in the .jsonl file are skipped.  Do
# not rebuild the compiler during the build phase.
set -u
cd "$(dirname "$0")/.."

build() {
  export NOFIB_MODE=norm
  ww-bench/run-nofib.sh base-norm   ""
  python3 ww-bench/timing.py stash base-norm
  ww-bench/run-nofib.sh funres-norm "-fworker-wrapper-function-results"
  python3 ww-bench/timing.py stash funres-norm
  python3 ww-bench/report.py base-norm funres-norm > ww-bench/results/report-norm.md 2>&1
  echo "report: ww-bench/results/report-norm.md"
}

timing() {
  python3 ww-bench/timing.py run base-norm funres-norm --rounds "${1:-10}" --cpu "${2:-4}"
  python3 ww-bench/timing.py report base-norm funres-norm > ww-bench/results/timing-norm.md
  python3 ww-bench/mdalign.py ww-bench/results/timing-norm.md
  echo "timing: ww-bench/results/timing-norm.md"
}

case "${1:-}" in
  build) build ;;
  time)  shift; timing "$@" ;;
  *)     build && timing "$@" ;;
esac
