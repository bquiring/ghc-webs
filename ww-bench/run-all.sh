#!/usr/bin/env bash
# nofib with and without -fworker-wrapper-function-results, then the report.
# NOFIB_OPT sets the optimisation level (default -O2, nofib's default); for
# any other level the configurations are named base-O0, funres-O0, ...
set -u
cd "$(dirname "$0")/.."
OPT=${NOFIB_OPT:--O2}
SUF=$([ "$OPT" = "-O2" ] && echo "" || echo "${OPT}")
export NOFIB_OPT=$OPT
ww-bench/run-nofib.sh "base$SUF"   ""
ww-bench/run-nofib.sh "funres$SUF" "-fworker-wrapper-function-results"
python3 ww-bench/report.py "base$SUF" "funres$SUF" > "ww-bench/results/report$SUF.md" 2>&1
echo "report: ww-bench/results/report$SUF.md"
