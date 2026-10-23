#!/usr/bin/env python3
"""Allocation and peak memory of the benchmark programs from a
time-nofib.py JSON file: geomeans of median paired ratios config/base.

   python3 webs-bench/mem-report.py LABEL"""
import json, sys, math, statistics, os
RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
d = json.load(open(os.path.join(RES, 'timing-%s.json' % sys.argv[1])))
cfgs = d['configs']; base = cfgs[0]; S = d['samples']
def med(b, c, k):
    xs = [r[k] for r in S[b].get(c, []) if k in r]
    return statistics.median(xs) if xs else None
print('| config | metric | geomean | n | largest decrease | largest increase |')
print('|---|---|---|---|---|---|')
for c in cfgs[1:]:
    for k in ['alloc', 'maxres', 'inuse']:
        rs = {}
        for b in S:
            x, y = med(b, base, k), med(b, c, k)
            if x and y: rs[b] = y / x
        if not rs: continue
        g = math.exp(sum(math.log(v) for v in rs.values()) / len(rs))
        lo = min(rs, key=rs.get); hi = max(rs, key=rs.get)
        print('| %s | %s | %+.2f%% | %d | %s %+.1f%% | %s %+.1f%% |' % (c, k, (g - 1) * 100, len(rs),
              lo.split('/')[-1], (rs[lo] - 1) * 100, hi.split('/')[-1], (rs[hi] - 1) * 100))
