#!/usr/bin/env bash
# B side of the CBV A/B (the CBV marks for unboxed tuple arguments removed;
# also SpecConstr keeps reflexive coercions, Note [SpecConstr and reflexive
# coercions]): early-cur-b and late-cur-b against early-cur and late-cur;
# base2 (base with this compiler); early-df2 (whole-arity defunc).  Then the
# timing of everything, after the nofib runs (never at the same time).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-cur-b "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh late-cur-b "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh base2 ""
webs-bench/run-nofib.sh early-df2 "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc -ddump-webs-data -dcore-lint"
python3 webs-bench/time-nofib.py base base2 early-fix early-du9 early-du10 early-cur early-cur-b late-cur late-cur-b early-df2 --label cbvab --rounds 1
