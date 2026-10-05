#!/usr/bin/env bash
# Run nofib in the four configurations of the web experiments, one after the
# other (they share the nofib tree), then write the report.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-arity-raise -fcore-webs-dead-params -fcore-webs-uncurry"
webs-bench/run-nofib.sh base       ""
webs-bench/run-nofib.sh late       "-fcore-webs $T"
webs-bench/run-nofib.sh early      "-fcore-webs-early $T"
webs-bench/run-nofib.sh early-late "-fcore-webs-early -fcore-webs $T"
python3 webs-bench/report.py base late early early-late > webs-bench/results/report.md 2>&1
echo "report: webs-bench/results/report.md"
