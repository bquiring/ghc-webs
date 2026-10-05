#!/usr/bin/env python3
"""Summarise the higher-order worker/wrapper experiment over nofib.

    ww-bench/report.py CONFIG [CONFIG ...]

reads ww-bench/results/CONFIG/ (see run-nofib.sh) and prints
  1. the -ddump-ww-ho-stats counts (Note [Higher-order worker/wrapper
     statistics] in GHC.Core.Opt.WorkWrap), summed over all modules, at each
     point of the pipeline (early, pre-ww, final), and per benchmark;
  2. program allocation and code size against the first configuration;
  3. build and run failures.
"""
import os, re, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
FIELDS = ['funs', 'returns_fun', 'takes_fun', 'res_splits', 'res_deep', 'res_levels',
          'arg_splits', 'arg_nested']
PHASES = ['early', 'pre-ww', 'final']

def benchmarks(config):
    d = os.path.join(ROOT, config, 'dumps')
    for dirpath, _, files in os.walk(d):
        yield os.path.relpath(dirpath, d), [os.path.join(dirpath, f) for f in files]

def ho_rejects(config):
    """phase -> reason -> count, summed over all modules"""
    res = collections.defaultdict(collections.Counter)
    for bench, files in benchmarks(config):
        for f in files:
            if not f.endswith('.dump-ww-ho-stats'):
                continue
            for line in open(f, errors='replace'):
                m = re.match(r'ww-ho-reject (\S+) (\d+) (.*)', line.strip())
                if m:
                    res[m.group(1)][m.group(3)] += int(m.group(2))
    return res

def ho_splits(config, phase):
    """the functions split at a point: (benchmark, line)"""
    out = []
    for bench, files in benchmarks(config):
        for f in files:
            if not f.endswith('.dump-ww-ho-stats'):
                continue
            for line in open(f, errors='replace'):
                m = re.match(r'ww-ho-split (\S+) (.*)', line.strip())
                if m and m.group(1) == phase:
                    out.append((bench, m.group(2)))
    return sorted(out)

def ho_stats(config):
    """bench -> phase -> field -> count"""
    res = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    for bench, files in benchmarks(config):
        for f in files:
            if not f.endswith('.dump-ww-ho-stats'):
                continue
            for line in open(f, errors='replace'):
                m = re.match(r'ww-ho-stats (\S+) (.*)', line.strip())
                if m:
                    for kv in m.group(2).split():
                        k, v = kv.split('=')
                        res[bench][m.group(1)][k] += int(v)
    return res

def failures(config):
    """Lines of the nofib log that report a build or run failure"""
    log = os.path.join(ROOT, config, 'nofib.log')
    if not os.path.exists(log):
        return []
    bad = []
    bench = None
    for line in open(log, errors='replace'):
        m = re.match(r'==nofib== (\S+):', line)
        if m:
            bench = m.group(1)
        if re.search(r'not matched by reality|expected exit status|expected a failure'
                     r'|\*\*\* \[.*\] Error|panic! \(the .impossible. happened\)'
                     r'|Core Lint errors|Web Lint errors', line):
            bad.append('%s: %s' % (bench, line.strip()[:140]))
    return bad

def timings(config):
    """bench -> {'compile_alloc', 'compile_time', 'run_alloc', 'run_mut'} from
    the <<ghc: ...>> lines that follow the ==nofib== markers"""
    log = os.path.join(ROOT, config, 'nofib.log')
    res = collections.defaultdict(collections.Counter)
    if not os.path.exists(log):
        return res
    bench, what = None, None
    for line in open(log, errors='replace'):
        m = re.match(r'==nofib== (\S+): time to (compile|run) ', line)
        if m:
            bench, what = m.group(1), m.group(2)
            continue
        m = re.search(r'<<ghc: (\d+) bytes.*? ([\d.]+) MUT \(([\d.]+) elapsed\)', line)
        if m and bench:
            if what == 'compile':
                res[bench]['compile_alloc'] += int(m.group(1))
                res[bench]['compile_time'] += float(m.group(3))
            elif what == 'run':
                res[bench]['run_alloc'] = int(m.group(1))
                res[bench]['run_mut'] = float(m.group(2))
    return res

def sizes(config):
    """bench -> {'obj_text', 'obj_total', 'exe_text', 'exe_total'} from the
    output of size(1) that follows the "size of X follows..." markers.  The
    object files are the benchmark's own modules (including the shared
    NofibUtils.o, which is the same in every configuration)."""
    log = os.path.join(ROOT, config, 'nofib.log')
    res = collections.defaultdict(collections.Counter)
    if not os.path.exists(log):
        return res
    bench, target = None, None
    for line in open(log, errors='replace'):
        m = re.match(r'==nofib== (\S+): size of (\S+) follows', line)
        if m:
            bench, target = m.group(1), m.group(2)
            continue
        m = re.match(r'\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+(\S+)\s*$', line)
        if m and bench and target and m.group(5) == target:
            text, total = int(m.group(1)), int(m.group(4))
            if target.endswith('.o'):
                res[bench]['obj_text'] += text
                res[bench]['obj_total'] += total
            else:
                res[bench]['exe_text'] = text
                res[bench]['exe_total'] = total
            target = None
    return res

def geomean_ratio(xs):
    import math
    xs = [x for x in xs if x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float('nan')

def pct(new, old):
    return '' if old == 0 else '%+.1f%%' % (100.0 * (new - old) / old)

def main(configs):
    c0 = configs[0]
    st = ho_stats(c0)
    tot = {p: collections.Counter() for p in PHASES}
    for b in st:
        for p in PHASES:
            tot[p].update(st[b][p])
    print('# Higher-order worker/wrapper opportunities (%s, %d benchmarks, summed over modules)\n' % (c0, len(st)))
    print('| point | ' + ' | '.join(FIELDS) + ' |')
    print('|---' * (len(FIELDS) + 1) + '|')
    for p in PHASES:
        print('| %s | ' % p + ' | '.join(str(tot[p][f]) for f in FIELDS) + ' |')
    print()
    rej = ho_rejects(c0)
    print('## Why functions are not split (functions returning (r:) or taking (a:) a function)\n')
    print('| reason | ' + ' | '.join(PHASES) + ' |')
    print('|---' * (len(PHASES) + 1) + '|')
    reasons = sorted(set(r for p in PHASES for r in rej[p]), key=lambda r: -rej['pre-ww'][r])
    for r in reasons:
        print('| %s | ' % r + ' | '.join(str(rej[p][r]) for p in PHASES) + ' |')
    print()
    print('## Functions split at pre-ww\n')
    for bench, line in ho_splits(c0, 'pre-ww'):
        print('- %s: %s' % (bench, line))
    print()
    print('## Per benchmark (benchmarks with any split, early / pre-ww / final)\n')
    print('| benchmark | res_splits | res_deep | arg_splits | arg_nested |')
    print('|---|---|---|---|---|')
    for b in sorted(st):
        if any(st[b][p]['res_splits'] or st[b][p]['arg_splits'] for p in PHASES):
            print('| %s | %s | %s | %s | %s |' % (b,
                ' / '.join(str(st[b][p]['res_splits']) for p in PHASES),
                ' / '.join(str(st[b][p]['res_deep']) for p in PHASES),
                ' / '.join(str(st[b][p]['arg_splits']) for p in PHASES),
                ' / '.join(str(st[b][p]['arg_nested']) for p in PHASES)))
    print()
    if len(configs) > 1:
        print('# Performance (from the nofib logs)\n')
        tim = {c: timings(c) for c in configs}
        sz = {c: sizes(c) for c in configs}
        print('| measure | ' + ' | '.join(configs[1:]) + ' |')
        print('|---' * len(configs) + '|')
        for k, name, tab in [('compile_alloc', 'compiler allocation', tim), ('run_alloc', 'program allocation', tim),
                             ('obj_text', 'object code (text)', sz)]:
            cells = []
            for c in configs[1:]:
                ratios = [tab[c][b][k] / tab[c0][b][k] for b in tab[c0]
                          if b in tab[c] and tab[c0][b][k] > 0 and tab[c][b][k] > 0]
                g = geomean_ratio(ratios)
                cells.append('%+.2f%% (geomean over %d)' % (100 * (g - 1), len(ratios)))
            print('| %s vs %s | ' % (name, c0) + ' | '.join(cells) + ' |')
        print()
        print('## Program allocation changes over 0.5%\n')
        print('| benchmark | ' + ' | '.join(configs) + ' |')
        print('|---' * (len(configs) + 1) + '|')
        for b in sorted(tim[c0]):
            base = tim[c0][b]['run_alloc']
            if base and any(abs(tim[c][b]['run_alloc'] - base) / base > 0.005 for c in configs[1:]):
                print('| %s | %d | ' % (b, base) + ' | '.join(pct(tim[c][b]['run_alloc'], base) for c in configs[1:]) + ' |')
        print()
    print('# Build and run failures\n')
    for c in configs:
        f = failures(c)
        print('- %s: %d lines' % (c, len(f)))
        for line in f[:20]:
            print('    ' + line)

if __name__ == '__main__':
    # Print with the table columns aligned, to read as plain text (mdalign.py)
    import io, contextlib
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from mdalign import align_text
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        main(sys.argv[1:])
    sys.stdout.write(align_text(buf.getvalue()))
