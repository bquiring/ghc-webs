#!/usr/bin/env bash
# PLDI'28: rerun of run-paper-j.sh's J2 (compile time with the release
# compiler) after installing unlit in _build-rel (the first run failed on
# every .lhs module).
set -u
cd "$(dirname "$0")/.."
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
export NOFIB_JOBS=1 WEBS_NO_DUMPS=1 WEBS_NOFIB_HC=$PWD/webs-bench/ghc-rel-timeout.sh
webs-bench/run-nofib.sh ct-rel-base ""
rm -rf webs-bench/results/ct-rel-base/bin
webs-bench/run-nofib.sh ct-rel-scl "$B"
rm -rf webs-bench/results/ct-rel-scl/bin
python3 webs-bench/ct-report.py ct-rel-base ct-rel-scl > webs-bench/results/compiletime-paper-j.md 2>&1
notify-send -a webs -i dialog-information "Webs: paper J2 done" "compiletime-paper-j.md"
