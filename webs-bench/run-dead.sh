#!/usr/bin/env bash
# Dead fields of split types (Note [Dead fields] in GHC.WebCore.DataFlatten):
# early-du10 (against early-du9) and late-du4 (against late-du3).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-uncurry -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-du10 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh late-du4 "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base early-fix early-du9 early-du10 late-du4 --label dead --rounds 1
