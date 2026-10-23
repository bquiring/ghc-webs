#!/usr/bin/env bash
# PLDI'28 resubmission, experiment J (after run-paper-i.sh's builds):
#  J1: instruction timing of base, occ3 (paper configuration), sat, occ-sat
#      and spec (constant specialisation alone).
#  J2: compile time with the release compiler (_build-rel, perf flavour, no
#      assertions): base and the paper configuration, serial, no Lint, no
#      dumps (ct-rel-base, ct-rel-scl; ct-report.py).
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
python3 webs-bench/time-nofib.py base occ3 sat occ-sat spec --label paper-j --rounds 3 --cpus 2,4,6,8
notify-send -a webs -i dialog-information "Webs: paper J1 (timing) done" "timing-paper-j.md"
export NOFIB_JOBS=1 WEBS_NO_DUMPS=1 WEBS_NOFIB_HC=$PWD/webs-bench/ghc-rel-timeout.sh
webs-bench/run-nofib.sh ct-rel-base ""
rm -rf webs-bench/results/ct-rel-base/bin
webs-bench/run-nofib.sh ct-rel-scl "$B"
rm -rf webs-bench/results/ct-rel-scl/bin
python3 webs-bench/ct-report.py ct-rel-base ct-rel-scl > webs-bench/results/compiletime-paper-j.md 2>&1
notify-send -a webs -i dialog-information "Webs: paper J done" "compiletime-paper-j.md"
