#!/usr/bin/env bash
# nofib's compiler for chunk compilation (Note [Chunks] in GHC.WebCore.Chunk):
# every invocation goes to ghc-timeout.sh, except the link step
# (-o PROG with object files, no -c), which instead compiles the program's
# sources as one Core program: ghc --make -fcore-webs-chunk with the link
# line's options (nofib links with the compile options, HC_OPTS) and, for
# each X.o whose X.hs or X.lhs exists, that source; other objects are linked
# as given.  Limited to WEBS_CHUNK_TIMEOUT seconds (default 600).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
link=0; compile=0
for a in "$@"; do
  case "$a" in
    -c|-M|-E|-S|--info|--version|--numeric-version|--print-libdir) compile=1;;
    -o) link=1;;
  esac
done
# The per-module compiles only feed make: their dumps go elsewhere, so the
# dump directory holds the chunk's alone
if [ $compile = 1 ] || [ $link = 0 ]; then
  pass=(); prev=
  for a in "$@"; do
    if [ "$prev" = -dumpdir ]; then pass+=(webs-chunk-ignore/); else pass+=("$a"); fi
    prev=$a
  done
  exec "$ROOT/webs-bench/ghc-timeout.sh" "${pass[@]}"
fi
args=(); srcs=()
for a in "$@"; do
  case "$a" in
    *.o) b=${a%.o}
         if [ -f "$b.hs" ]; then srcs+=("$b.hs")
         elif [ -f "$b.lhs" ]; then srcs+=("$b.lhs")
         else args+=("$a"); fi;;
    *) args+=("$a");;
  esac
done
exec timeout --kill-after=30 "${WEBS_CHUNK_TIMEOUT:-600}" "$ROOT/_build/stage1/bin/ghc" \
  --make -fcore-webs-chunk -outputdir webs-chunk-out "${args[@]}" "${srcs[@]}"
