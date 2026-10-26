#!/usr/bin/env bash
# Timing for run-dskl.sh's builds (WEBS-DICT-SPEC.md §6). Run with the
# laptop awake throughout: a suspend in the middle spoils the times.
set -u
# ghcup's defaults are ghc 9.14.1 and cabal 3.18.1.0 since 2026-10-24; the
# pins are ghc 9.10.1 (bootstrap) and cabal 3.12.1.0 (3.18 passes -gbcdir).
export PATH=/home/benjamin/.local/pinned-toolchain/bin:$PATH
cd /home/benjamin/projects/ghc-webs
python3 webs-bench/time-nofib.py base occ4ev occ4kl --label dskl --rounds 3 --cpus 2,4,6,8
cd /home/benjamin/projects/webs-hackage-bench
python3 time.py base22 xu-agg xu-agg2 xu-wagg xu-wagg-kl xu-wagg-ic --rounds 3 --label dskl
python3 profile.py xu-agg2 xu-wagg-kl --only happy --runs 3 --label dskl-happy
notify-send -a webs -i dialog-information "Webs: dskl timing done" "webs-bench/results/timing-dskl.md, webs-hackage-bench/results/timing-dskl.md"
