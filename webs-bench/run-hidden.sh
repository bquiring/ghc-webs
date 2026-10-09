#!/usr/bin/env bash
# Hidden fields (Note [Hidden fields] in GHC.WebCore.Sigs): how many more
# internal webs, and what the transformations do with them.  early-cur's
# options plus the web statistics, with hidden fields (hf-on) and without
# (hf-off, -fcore-webs-no-hidden-fields).
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
O="-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -ddump-webs-stats -dcore-lint"
webs-bench/run-nofib.sh hf-on "$O"
webs-bench/run-nofib.sh hf-off "$O -fcore-webs-no-hidden-fields"
