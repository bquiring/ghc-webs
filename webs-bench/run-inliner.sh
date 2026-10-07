#!/usr/bin/env bash
# Does tuning down the inliner leave more for the web transformations?
# Runs the early configuration at several -funfolding-use-threshold values
# (default 80), and base at the lowest, then tallies the verdict dumps.
# Note: super-beta inlining (-fcore-webs-inline) uses the same threshold.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-t80 "-fcore-webs-early $T"
webs-bench/run-nofib.sh early-t20 "-fcore-webs-early $T -funfolding-use-threshold=20"
webs-bench/run-nofib.sh early-t0  "-fcore-webs-early $T -funfolding-use-threshold=0"
webs-bench/run-nofib.sh base-t0   "-funfolding-use-threshold=0"
python3 webs-bench/verdicts.py early-t80 early-t20 early-t0 > webs-bench/results/verdicts.md 2>&1
python3 webs-bench/report.py base base-t0 early-t80 early-t20 early-t0 > webs-bench/results/report-inliner.md 2>&1
echo "reports: webs-bench/results/verdicts.md, webs-bench/results/report-inliner.md"
