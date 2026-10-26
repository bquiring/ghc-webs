#!/usr/bin/env bash
# The laptop's runs for WEBS-DICT-SPEC.md §6 (perf instruction counts):
#  1. Rebuild _build and _build-xu at this tree (raise-known-lazy, rule and
#     instance copies, the specialiser's bounds).
#  2. nofib occ4ev and occ4kl (WEBS-EXPERIMENTS.md §38), timed with base.
#  3. Hackage small group in store-xu, against xu-agg:
#       xu-agg2     the specialiser pair alone (agg2, §37)
#       xu-wagg     agg2 + occ4's flags + drop-rules + evald-args
#       xu-wagg-kl  xu-wagg + raise-known-lazy
#       xu-wagg-ic  xu-wagg-kl with rule and instance copies for drop-rules
#     and happy profiled (xu-agg2 vs xu-wagg-kl) to see $slookup.
# Builds only; the timing is in run-dskl-time.sh, run when the laptop is
# not suspended.
set -u
# ghcup's defaults are ghc 9.14.1 and cabal 3.18.1.0 since 2026-10-24; the
# pins are ghc 9.10.1 (bootstrap) and cabal 3.12.1.0 (3.18 passes -gbcdir).
export PATH=/home/benjamin/.local/pinned-toolchain/bin:$PATH
cd /home/benjamin/projects/ghc-webs
T="-fcore-webs-early -fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again -fcore-webs-boundary -fcore-webs-useless"
B="$T -fcore-webs-spec-calls -fcore-webs-spec-lambdas"
A2="-fspecialise-aggressively -fexpose-all-unfoldings"
fail() { notify-send -a webs -i dialog-error "Webs: dskl failed" "$1"; exit 1; }

start=$(date +%s)
(ulimit -v 8000000 && GHC=ghc-9.10.1 hadrian/build -j4 --flavour=devel2) > build.log 2>&1 || fail "ghc-webs/build.log"
echo "_build: $(( $(date +%s) - start )) s"
start=$(date +%s)
(ulimit -v 8000000 && GHC=ghc-9.10.1 hadrian/build -j4 --flavour=devel2 --build-root=_build-xu) > build-xu.log 2>&1 || fail "ghc-webs/build-xu.log"
echo "_build-xu: $(( $(date +%s) - start )) s"

export NOFIB_JOBS=4
[ -d webs-bench/results/occ4ev/bin ] || webs-bench/run-nofib.sh occ4ev "$B -fcore-webs-evald-args -dcore-lint"
[ -d webs-bench/results/occ4kl/bin ] || webs-bench/run-nofib.sh occ4kl "$B -fcore-webs-evald-args -fcore-webs-raise-known-lazy -dcore-lint"
for c in occ4ev occ4kl; do echo "$c lint/panics: $(grep -c 'Lint errors\|panic!' webs-bench/results/$c/nofib.log)"; done

cd /home/benjamin/projects/webs-hackage-bench
export BENCH_STORE=store-xu
W="$B -fcore-webs-drop-rules -fcore-webs-evald-args"
for c in xu-agg2 xu-wagg xu-wagg-kl xu-wagg-ic; do cp xu-base.extra $c.extra; done
./build.sh xu-agg2 "$A2"
./build.sh xu-wagg "$A2 $W -dcore-webs-lint"
./build.sh xu-wagg-kl "$A2 $W -fcore-webs-raise-known-lazy -dcore-webs-lint"
./build.sh xu-wagg-ic "$A2 $B -fcore-webs-rule-copies -fcore-webs-instance-copies -fcore-webs-evald-args -fcore-webs-raise-known-lazy -dcore-webs-lint"
notify-send -a webs -i dialog-information "Webs: dskl builds done" "next: webs-bench/run-dskl-time.sh"
