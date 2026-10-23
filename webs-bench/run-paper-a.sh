#!/usr/bin/env bash
# PLDI'27 experiments, part A.
#  A1: early-ulsl8-scl (spec-calls + spec-lambdas, no defunc) with the
#      constructor-moving flags of WEBS-EXPERIMENTS.md §22 (early-ulsl8-sclm),
#      and the same with defunctionalisation (early-ulsl8-sclmd); timed
#      against base and early-ulsl8-scl.
#  A2: compile time and compiler memory: base and early-ulsl8-scl's options
#      built serially, without -dcore-lint and without dumps (ct-base, ct-scl).
#
#   webs-bench/run-paper-a.sh
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
B="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-boundary -fcore-webs-useless -fcore-webs-data-again -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
D="-dcore-lint -ddump-webs-data -ddump-webs-useless -ddump-webs-stats -ddump-webs-spec"
M="-fcore-webs-raise-through-calls -fcore-webs-evald-args"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh early-ulsl8-sclm "$B $D $M"
webs-bench/run-nofib.sh early-ulsl8-sclmd "$B $D $M -fcore-webs-defunc"
python3 webs-bench/report.py base early-ulsl8-scl early-ulsl8-sclm early-ulsl8-sclmd > webs-bench/results/report-paper-a.md 2>&1
python3 webs-bench/time-nofib.py base early-ulsl8-scl early-ulsl8-sclm early-ulsl8-sclmd --label paper-a --rounds 3 --cpus 2,4,6,8
summary=$(grep -E "^\| early-ulsl8" webs-bench/results/timing-paper-a.md | cut -d'|' -f2,4 | tr -s ' ' | tr '\n' ';')
notify-send -a webs -i dialog-information "Webs: paper A1 done" "instructions vs base: $summary"
# A2: serial builds, no lint, no dumps
export NOFIB_JOBS=1 WEBS_NO_DUMPS=1
webs-bench/run-nofib.sh ct-base ""
webs-bench/run-nofib.sh ct-scl "$B"
rm -rf webs-bench/results/ct-base/bin webs-bench/results/ct-scl/bin
notify-send -a webs -i dialog-information "Webs: paper A done" "compile-time builds finished"
