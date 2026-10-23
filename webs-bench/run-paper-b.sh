#!/usr/bin/env bash
# PLDI'27 experiments, part B (run after run-paper-a.sh).
#  B1: leave-one-out ablation from early-ulsl8-scl: which transformation
#      each win comes from (abl-no-*), in two batches (disk space).
#  B2: dialling back GHC's inlining: base and early-ulsl8-scl's options with
#      -funfolding-use-threshold 45, 20, 5 (default 90).
# Each batch is timed against base and early-ulsl8-scl, then its
# executables are deleted (results stay in timing-*.md/json, runs.tsv).
#
#   webs-bench/run-paper-b.sh
set -u
cd "$(dirname "$0")/.."
declare -A F=(
  [inline]="-fcore-webs-inline" [cprop]="-fcore-webs-const-prop"
  [arity]="-fcore-webs-arity-raise" [result]="-fcore-webs-result-raise"
  [strict]="-fcore-webs-strictness"
  [data]="-fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-data-again"
  [bnd]="-fcore-webs-boundary" [useless]="-fcore-webs-useless"
  [spec]="-fcore-webs-spec-calls -fcore-webs-spec-lambdas")
ALL="inline cprop arity result strict data bnd useless spec"
D="-dcore-lint -ddump-webs-stats"
export NOFIB_JOBS=4
opts_without() {   # the early-ulsl8-scl options without group $1
  local o="-fcore-webs-early"
  for g in $ALL; do [ "$g" = "$1" ] || o="$o ${F[$g]}"; done
  echo "$o"
}
batch() {   # label config...
  local label=$1; shift
  python3 webs-bench/time-nofib.py base early-ulsl8-scl "$@" --label "$label" --rounds 3 --cpus 2,4,6,8
  for c in "$@"; do rm -rf "webs-bench/results/$c/bin"; done
}
c1=(); for g in inline cprop arity result strict; do
  webs-bench/run-nofib.sh abl-no-$g "$(opts_without $g) $D"; c1+=(abl-no-$g); done
batch paper-b-abl1 "${c1[@]}"
c2=(); for g in data bnd useless spec; do
  webs-bench/run-nofib.sh abl-no-$g "$(opts_without $g) $D"; c2+=(abl-no-$g); done
batch paper-b-abl2 "${c2[@]}"
notify-send -a webs -i dialog-information "Webs: paper B1 (ablation) done" "timing-paper-b-abl1/2.md"
c3=(); for n in 45 20 5; do
  webs-bench/run-nofib.sh inl-base-u$n "-funfolding-use-threshold=$n $D"
  webs-bench/run-nofib.sh inl-webs-u$n "$(opts_without none) -funfolding-use-threshold=$n $D"
  c3+=(inl-base-u$n inl-webs-u$n); done
python3 webs-bench/report.py base early-ulsl8-scl "${c3[@]}" > webs-bench/results/report-paper-b-inl.md 2>&1
batch paper-b-inl "${c3[@]}"
notify-send -a webs -i dialog-information "Webs: paper B done" "timing-paper-b-inl.md"
