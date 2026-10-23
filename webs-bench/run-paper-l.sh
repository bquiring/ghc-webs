#!/usr/bin/env bash
# PLDI'28 shepherding, after the restoreOccurrences fix (roundtrip002,
# WEBS-BUGS.md): resumes run-paper-k.sh from K2.
#  L1: occ4 = the paper configuration with the fixed compiler; timed with
#      base and occ3 (the fix must change no benchmark: fixes-no-regressions)
#  L2: Hackage small group, constant specialisation alone (spec22), timed
#      with base22 and webs22
#  L3: release-compiler compile time with -ddump-timings (ct-rel-tim)
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless"
B="$T -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
S="-fcore-webs-early -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
export NOFIB_JOBS=4
webs-bench/run-nofib.sh occ4 "$B -dcore-lint -ddump-webs-stats"
echo "occ4 lint/panics: $(grep -c 'Lint errors\|panic!' webs-bench/results/occ4/nofib.log)"
(cd /home/benjamin/projects/webs-hackage-bench && ./build.sh spec22 "$S -dcore-webs-lint")
python3 webs-bench/time-nofib.py base occ3 occ4 --label paper-l --rounds 3 --cpus 2,4,6,8
(cd /home/benjamin/projects/webs-hackage-bench && python3 time.py base22 webs22 spec22 --rounds 5 --label paper24)
export NOFIB_JOBS=1 WEBS_NO_DUMPS=1 WEBS_NOFIB_HC=$PWD/webs-bench/ghc-rel-timeout.sh
webs-bench/run-nofib.sh ct-rel-tim "$B -ddump-timings"
rm -rf webs-bench/results/ct-rel-tim/bin
notify-send -a webs -i dialog-information "Webs: paper L done" "timing-paper-l.md, timing-paper24.md, ct-rel-tim"
