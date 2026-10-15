#!/usr/bin/env bash
# ghc-timeout.sh, with a copy of the compiler's messages appended to
# webs-warnings.log in the current directory: run-unused.sh's first pass
# reads the -Wunused-imports warnings there (names imported by an import
# list but never used, which unused-exports.py must count as used).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/webs-bench/ghc-timeout.sh" "$@" 2> >(tee -a webs-warnings.log >&2)
