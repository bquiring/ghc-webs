#!/usr/bin/env bash
# Run nofib in the configurations of the web experiments, one after the
# other (they share the nofib tree), then write the report.  The late run
# (-fcore-webs) is no longer measured; see WEBS-EXPERIMENTS.md.
set -u
cd "$(dirname "$0")/.."
# Every web transformation
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh base       ""
webs-bench/run-nofib.sh early      "-fcore-webs-early $T"
python3 webs-bench/report.py base early > webs-bench/results/report.md 2>&1
echo "report: webs-bench/results/report.md"
