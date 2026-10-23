#!/usr/bin/env python3
"""Compile time and compiler memory from nofib logs (runs made with
WEBS_NO_DUMPS=1 and NOFIB_JOBS=1, see run-paper-a.sh).

   python3 webs-bench/ct-report.py BASECONFIG CONFIG

Per benchmark: compiler allocation and MUT+GC seconds summed over its
modules, peak max residency over its modules; geomean ratios CONFIG/BASE;
totals; the largest ratios."""
import re, sys, math, os
RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
HDR = re.compile(r'^==nofib== (\S+): time to compile (\S+) follows')
GHC = re.compile(r'<<ghc: (\d+) bytes, .*?\d+/(\d+) avg/max bytes residency.*?(\d+)M in use.*?([\d.]+) MUT \(([\d.]+) elapsed\), ([\d.]+) GC \(([\d.]+) elapsed\)')

def load(cfg):
    d = {}
    cur = None
    for line in open(os.path.join(RES, cfg, 'nofib.log'), errors='replace'):
        m = HDR.match(line)
        if m:
            cur = (m.group(1), m.group(2)); continue
        m = GHC.search(line)
        if m and cur:
            b, mod = cur
            e = d.setdefault(b, {'alloc': 0, 'time': 0.0, 'maxres': 0, 'inuse': 0, 'mods': 0})
            e['alloc'] += int(m.group(1)); e['time'] += float(m.group(4)) + float(m.group(6))
            e['maxres'] = max(e['maxres'], int(m.group(2))); e['inuse'] = max(e['inuse'], int(m.group(3)))
            e['mods'] += 1
            cur = None
    return d

def gm(xs): return math.exp(sum(math.log(x) for x in xs) / len(xs))
b, c = load(sys.argv[1]), load(sys.argv[2])
common = sorted(k for k in b if k in c and b[k]['mods'] == c[k]['mods'])
print('# Compile time: %s vs %s (%d benchmarks, %d modules)\n' % (sys.argv[1], sys.argv[2], len(common), sum(b[k]['mods'] for k in common)))
print('| measure | %s total | %s total | ratio of totals | geomean of ratios | max ratio |' % (sys.argv[1], sys.argv[2]))
print('|---|---|---|---|---|---|')
for key, unit, scale in [('alloc', 'GB', 1e9), ('time', 's', 1), ('maxres', 'MB (peak)', 1e6), ('inuse', 'MB in use (peak)', 1)]:
    rs = [c[k][key] / b[k][key] for k in common if b[k][key] > 0]
    tb = sum(b[k][key] for k in common) / scale; tc = sum(c[k][key] for k in common) / scale
    mx = max(common, key=lambda k: c[k][key] / b[k][key] if b[k][key] else 0)
    print('| %s (%s) | %.2f | %.2f | %+.1f%% | %+.1f%% | %s %+.0f%% |' % (key, unit, tb, tc, (tc / tb - 1) * 100, (gm(rs) - 1) * 100, mx, (c[mx][key] / b[mx][key] - 1) * 100))
print('\n## Largest compile-time ratios\n')
print('| benchmark | modules | base time (s) | time | alloc | max residency |')
print('|---|---|---|---|---|---|')
for k in sorted(common, key=lambda k: -c[k]['time'] / max(b[k]['time'], 1e-3))[:15]:
    print('| %s | %d | %.2f | %+.0f%% | %+.0f%% | %+.0f%% |' % (k, b[k]['mods'], b[k]['time'], (c[k]['time'] / b[k]['time'] - 1) * 100,
          (c[k]['alloc'] / b[k]['alloc'] - 1) * 100, (c[k]['maxres'] / b[k]['maxres'] - 1) * 100))
