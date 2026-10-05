#!/usr/bin/env bash
# nofib with and without -fworker-wrapper-function-results, then the report.
set -u
cd "$(dirname "$0")/.."
ww-bench/run-nofib.sh base   ""
ww-bench/run-nofib.sh funres "-fworker-wrapper-function-results"
python3 ww-bench/report.py base funres > ww-bench/results/report.md 2>&1
echo "report: ww-bench/results/report.md"
