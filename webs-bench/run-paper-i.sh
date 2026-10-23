#!/usr/bin/env bash
# PLDI'28 resubmission, experiment I (builds only; timing in run-paper-i-time.sh
# once the release compiler build is done):
#   sat      base + GHC's static argument transformation
#   occ-sat  the paper configuration (occ3) + the static argument transformation
#   spec     constant specialisation alone: the early run with no web
#            transformation but spec-calls and spec-lambdas (which run on
#            ordinary Core after erasure, without webs)
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
S="-fcore-webs-early -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
SAT="-fstatic-argument-transformation"
D="-dcore-lint -ddump-webs-stats"
export NOFIB_JOBS=4
# GHC's SAT fails Core Lint in this snapshot (upstream: saTransform clones
# type variables without substituting them in later binders' types), so the
# SAT configurations are built without -dcore-lint; outputs are still checked.
webs-bench/run-nofib.sh sat "$SAT"
webs-bench/run-nofib.sh occ-sat "$B $SAT -ddump-webs-stats"
webs-bench/run-nofib.sh spec "$S $D"
for c in sat occ-sat spec; do echo "$c lint/panics: $(grep -c 'Lint errors\|panic!' webs-bench/results/$c/nofib.log)"; done
python3 webs-bench/report.py base occ3 sat occ-sat spec > webs-bench/results/report-paper-i.md 2>&1
notify-send -a webs -i dialog-information "Webs: paper I builds done" "report-paper-i.md"
