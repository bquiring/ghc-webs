#!/usr/bin/env python3
"""Ticky counters of nofib benchmarks with and without some GHC options:

    python3 webs-bench/ticky-compare.py OUTDIR "BASE OPTIONS" "OTHER OPTIONS" BENCH...

Builds each benchmark (its directory and arguments from results/base/runs.tsv)
twice with -O2 -ticky, runs it as nofib does (stdin, arguments), and prints
the call and allocation counters of the two ticky reports side by side:
known and unknown calls, slow calls (an unknown call that does not match the
function's arity), entries, and allocation of functions, thunks,
constructors and partial applications.
"""
import os, re, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOFIB = os.path.join(HERE, '..', 'nofib')
GHC = os.path.join(HERE, '..', '_build', 'stage1', 'bin', 'ghc')
COUNTERS = ['KNOWN_CALL_ctr', 'KNOWN_CALL_TOO_FEW_ARGS_ctr', 'KNOWN_CALL_EXTRA_ARGS_ctr',
            'UNKNOWN_CALL_ctr', 'SLOW_CALL_fast_pv_ctr', 'SLOW_CALL_FUN_CORRECT_ctr',
            'SLOW_CALL_FUN_TOO_FEW_ctr', 'SLOW_CALL_FUN_TOO_MANY_ctr', 'SLOW_CALL_PAP_CORRECT_ctr',
            'MULTI_CHUNK_SLOW_CALL_ctr', 'VERY_SLOW_CALL_ctr',
            'ENT_DYN_FUN_DIRECT_ctr', 'ENT_STATIC_FUN_DIRECT_ctr', 'ENT_DYN_THK_SINGLE_ctr',
            'ENT_DYN_THK_MANY_ctr', 'ENT_LNE_ctr', 'ENT_DYN_CON_ctr', 'ENT_STATIC_CON_ctr',
            'ALLOC_FUN_ctr', 'ALLOC_FUN_gds', 'ALLOC_THK_ctr', 'ALLOC_THK_gds',
            'ALLOC_CON_ctr', 'ALLOC_CON_gds', 'ALLOC_PAP_ctr', 'ALLOC_PAP_gds',
            'ALLOC_HEAP_tot', 'UPDF_PUSHED_ctr']


def runs():
    out = {}
    for line in open(os.path.join(HERE, 'results', 'base', 'runs.tsv')):
        name, d, cmd = line.rstrip('\n').split('\t')[:3]
        out[name] = (d, cmd)
    return out


def counters(path):
    c = {}
    for line in open(path, errors='replace'):
        m = re.match(r'\s*(\d+)\s+([A-Z_a-z]+_(?:ctr|gds|tot))\b', line)
        if m:
            c[m.group(2)] = c.get(m.group(2), 0) + int(m.group(1))
    return c


def build_and_run(outdir, opts, d, cmd, tag):
    src = os.path.join(NOFIB, d)
    main = next(f for f in ['Main.hs', 'Main.lhs'] if os.path.exists(os.path.join(src, f)))
    o = os.path.join(outdir, os.path.basename(d) + '-' + tag)
    os.makedirs(o, exist_ok=True)
    r = subprocess.run([GHC, '--make', '-O2', '-ticky', '-rtsopts', '-fforce-recomp', '-i' + src,
                        '-outputdir', o, '-o', os.path.join(o, 'prog'), main, '-v0'] + shlex.split(opts),
                       cwd=src, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('build failed: %s %s\n%s' % (d, tag, r.stderr[-2000:]))
    argv = shlex.split(cmd)[2:]
    stdin = None
    if '-i' in argv:
        k = argv.index('-i'); stdin = argv[k + 1]; del argv[k:k + 2]
    for flag in ['-o1', '-o2']:
        while flag in argv:
            k = argv.index(flag); del argv[k:k + 2]
    argv = [a for a in argv if a != '-ghc-timing']
    tick = os.path.join(o, 'ticky.txt')
    with open(os.path.join(src, stdin)) if stdin else open(os.devnull) as fin:
        subprocess.run([os.path.join(o, 'prog')] + argv + ['+RTS', '-r' + tick, '-RTS'],
                       cwd=src, stdin=fin, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return counters(tick)


def main():
    outdir, opts_a, opts_b = sys.argv[1:4]
    rs = runs()
    for b in sys.argv[4:]:
        d, cmd = rs[b]
        a = build_and_run(outdir, opts_a, d, cmd, 'a')
        c = build_and_run(outdir, opts_b, d, cmd, 'b')
        print('== %s' % b)
        for k in COUNTERS:
            x, y = a.get(k, 0), c.get(k, 0)
            if x or y:
                ch = '%+.1f%%' % (100.0 * (y - x) / x) if x else 'new'
                print('  %-30s %16d %16d  %s' % (k, x, y, ch))


if __name__ == '__main__':
    main()
