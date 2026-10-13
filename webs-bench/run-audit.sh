#!/usr/bin/env bash
# After the reporting audit (WEBS-BUGS.md, e241d489e8): early-ulsl's options
# with the current compiler (early-ulsl2), whose dumps mark only the webs a
# pass changed, and the same with kept binders split (early-ulslk,
# -fcore-webs-boundary-kept).  Built with -dcore-lint, timed against base and
# early-ulsl; a desktop notification at the end.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -fcore-webs-boundary -ddump-webs-data -dcore-lint -ddump-webs-useless -ddump-webs-forced -ddump-webs-stats -fcore-webs-useless -fcore-webs-data-again"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl2 "$O"
webs-bench/run-nofib.sh early-ulslk "$O -fcore-webs-boundary-kept"
python3 webs-bench/report.py base early-ulsl early-ulsl2 early-ulslk > webs-bench/results/report-audit.md 2>&1
python3 webs-bench/verdicts.py early-ulsl2 early-ulslk > webs-bench/results/verdicts-audit.md 2>&1
python3 webs-bench/expo-report.py webs-bench/results/early-ulsl2/dumps > webs-bench/results/expo-audit-ulsl2.md 2>&1
python3 webs-bench/expo-report.py webs-bench/results/early-ulslk/dumps > webs-bench/results/expo-audit-ulslk.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl early-ulsl2 early-ulslk --label audit --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| (early-ulsl2|early-ulslk) \|" webs-bench/results/timing-audit.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: nofib after the reporting audit done" "instructions vs base: $summary"
