#!/usr/bin/env bash
# Curried arity raising (Note [Raised arguments are curried]), no uncurrying,
# with the CBV marks for unboxed tuple arguments still in (A side of the
# CBV A/B): early-cur (best early flags) and late-cur.
set -u
cd "$(dirname "$0")/.."
T="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params
   -fcore-webs-result-raise -fcore-webs-strictness"
T=$(echo $T)
webs-bench/run-nofib.sh early-cur "-fcore-webs-early $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
webs-bench/run-nofib.sh late-cur "-fcore-webs $T -fcore-webs-data-split -fcore-webs-data-unbox -ddump-webs-data -dcore-lint"
