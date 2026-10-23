#!/usr/bin/env python3
"""Instruction geomeans against base, per nofib suite (imaginary, spectral,
real, shootout), from time-nofib.py's JSON.

    webs-bench/suite-report.py LABEL [CONFIG ...]

Reads webs-bench/results/timing-LABEL.json; CONFIGs default to every
configuration in it except base.  Per benchmark, the median over rounds of
the paired instruction ratio against base; per suite, the geometric mean,
the median, and how many benchmarks move by at least 0.5%.
"""
import json, math, os, statistics, sys

label = sys.argv[1]
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results', f'timing-{label}.json')
d = json.load(open(path))
configs = sys.argv[2:] or [c for c in d['configs'] if c != 'base']

def ratio(runs, cfg):
    b, c = runs.get('base'), runs.get(cfg)
    if not b or not c:
        return None
    rs = [y['instructions'] / x['instructions'] for x, y in zip(b, c)
          if x.get('instructions') and y.get('instructions')]
    return statistics.median(rs) if rs else None

suites = ['imaginary', 'spectral', 'real', 'shootout', 'all']
print(f'| config | ' + ' | '.join(suites) + ' |')
print('|---|' + '---|' * len(suites))
for cfg in configs:
    cells = []
    for suite in suites:
        rs = [ratio(runs, cfg) for name, runs in d['samples'].items()
              if (suite == 'all' or name.split('/')[0] == suite)
              # as time-nofib.py: only benchmarks every configuration ran
              # and whose base time is measurable
              and all(runs.get(c) for c in d['configs'])
              and statistics.median(x['mut'] + x['gc'] for x in runs['base']) > 0]
        rs = [r for r in rs if r]
        if not rs:
            cells.append('-')
            continue
        g = math.exp(sum(map(math.log, rs)) / len(rs)) - 1
        better = sum(r <= 0.995 for r in rs)
        worse = sum(r >= 1.005 for r in rs)
        cells.append(f'{100*g:+.2f}% (n={len(rs)}, {better}/{worse}, median {100*(statistics.median(rs)-1):+.1f}%)')
    print(f'| {cfg} | ' + ' | '.join(cells) + ' |')
