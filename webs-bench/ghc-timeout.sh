#!/usr/bin/env bash
# Run the stage-2 compiler under a timeout, so that a compile that does not
# terminate fails like any other build error.  The timeout (in seconds) is
# WEBS_GHC_TIMEOUT, default 120 (twice the slowest baseline compile, 60s).  Used by run-nofib.sh as nofib's compiler.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec timeout --kill-after=30 "${WEBS_GHC_TIMEOUT:-120}" "$ROOT/_build/stage1/bin/ghc" "$@"
