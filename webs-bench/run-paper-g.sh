#!/usr/bin/env bash
# After F: the SML suite again with the final compiler (base23, webs23,
# tuned23), in ~/projects/webs-hackage-bench.
set -u
cd ~/projects/webs-hackage-bench
B="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless -fcore-webs-spec-calls -fcore-webs-spec-lambdas -dcore-webs-lint"
export BENCH_GROUP=sml
./build.sh base23 ""
./build.sh webs23 "$B"
./build.sh tuned23 "$B -fcore-webs-spec-max-keys=8 -fcore-webs-raise-max-args=6"
python3 time.py base23 webs23 tuned23 --rounds 3 --label paper23
notify-send -a webs -i dialog-information "Webs: SML suite (final compiler) done" "sml/results/timing-paper23.md"
