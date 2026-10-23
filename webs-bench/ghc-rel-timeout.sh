#!/usr/bin/env bash
# As ghc-timeout.sh, but the release compiler (perf flavour, no assertions)
# built in _build-rel for the compile-time measurement (run-paper-j.sh).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec timeout --kill-after=30 "${WEBS_GHC_TIMEOUT:-120}" "$ROOT/_build-rel/stage1/bin/ghc" "$@"
