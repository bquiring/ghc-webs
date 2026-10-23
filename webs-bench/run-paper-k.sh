#!/usr/bin/env bash
# PLDI'28 shepherding experiments (reviews/round1 in docs/pldi28), in order,
# one at a time so that timing runs alone:
#  K1: nod (webs without constant specialisation) with the current compiler
#  K2: Hackage small group with constant specialisation alone (spec22,
#      ~/projects/webs-hackage-bench)
#  K3: nofib timing of base, occ3, nod, spec, sat, occ-sat (one run, Table 8)
#  K4: Hackage timing of base22, webs22, spec22
#  K5: release-compiler compile time of the paper configuration with
#      -ddump-timings (per-sub-pass breakdown)
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless"
B="$T -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
S="-fcore-webs-early -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh nod "$T -dcore-lint -ddump-webs-stats"
echo "nod lint/panics: $(grep -c 'Lint errors\|panic!' webs-bench/results/nod/nofib.log)"
(cd /home/benjamin/projects/webs-hackage-bench && ./build.sh spec22 "$S -dcore-webs-lint")
python3 webs-bench/time-nofib.py base occ3 nod spec sat occ-sat --label paper-k --rounds 3 --cpus 2,4,6,8
notify-send -a webs -i dialog-information "Webs: paper K3 (nofib timing) done" "timing-paper-k.md"
(cd /home/benjamin/projects/webs-hackage-bench && python3 time.py base22 webs22 spec22 --rounds 5 --label paper24)
export NOFIB_JOBS=1 WEBS_NO_DUMPS=1 WEBS_NOFIB_HC=$PWD/webs-bench/ghc-rel-timeout.sh
webs-bench/run-nofib.sh ct-rel-tim "$B -ddump-timings"
rm -rf webs-bench/results/ct-rel-tim/bin
notify-send -a webs -i dialog-information "Webs: paper K done" "timing-paper-k.md, timing-paper24.md, ct-rel-tim"
