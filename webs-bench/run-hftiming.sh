#!/usr/bin/env bash
# The current compiler (hidden fields, specialising for webs, the flattening
# demand fixes) with early-cur's options, at 3 flattening rounds (early-hf)
# and 10 (early-hf10, does a fixpoint help?), timed against base and
# early-cur.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh early-hf "$O"
webs-bench/run-nofib.sh early-hf10 "$O -fcore-webs-unbox-rounds=10"
python3 webs-bench/report.py base early-cur early-hf early-hf10 > webs-bench/results/report-hftiming.md 2>&1
python3 webs-bench/time-nofib.py base early-cur early-hf early-hf10 --label hftiming --rounds 3
python3 webs-bench/verdicts.py early-cur early-hf early-hf10 > webs-bench/results/verdicts-hftiming.md 2>&1
