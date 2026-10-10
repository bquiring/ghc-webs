#!/usr/bin/env bash
# poison-check.sh NAME (run from a directory with src/NAME.hs, as poison-gen.py writes): compile NAME.hs at -O0 and in the early and late webs
# configurations; compare stdout, stderr and exit code with -O0's
G=/home/benjamin/projects/ghc-webs/_build/stage1/bin/ghc
W="-fcore-webs-inline -fcore-webs-const-prop -fcore-webs-arity-raise -fcore-webs-dead-params -fcore-webs-useless -fcore-webs-result-raise -fcore-webs-strictness -fcore-webs-data-split -fcore-webs-data-unbox -fcore-webs-defunc"
E="-O -fcore-webs-early -dcore-lint $W -fcore-webs-boundary"
L="-O -fcore-webs -dcore-lint $W"
n=$1
ulimit -v 3000000
run() { # tag opts
  d=b-$1-$n; mkdir -p $d
  if ! timeout 300 $G $2 -fforce-recomp -outputdir $d src/$n.hs -o $d/$n > $d/compile.log 2>&1; then echo "$n $1 COMPILE FAILED"; tail -5 $d/compile.log; return; fi
  (cd $d && timeout 10 ./$n > out 2> err; echo $? > code)
}
run ref "-O0"; run early "$E"; run late "$L"
for c in early late; do
  [ -f b-$c-$n/code ] || continue
  if cmp -s b-ref-$n/out b-$c-$n/out && cmp -s b-ref-$n/err b-$c-$n/err && cmp -s b-ref-$n/code b-$c-$n/code
  then echo "$n $c ok (exit $(cat b-ref-$n/code))"
  else echo "$n $c DIFFERS: ref exit $(cat b-ref-$n/code) $(head -c 200 b-ref-$n/out b-ref-$n/err | tr '\n' ' ') | $c exit $(cat b-$c-$n/code) $(head -c 200 b-$c-$n/out b-$c-$n/err | tr '\n' ' ')"
  fi
done
