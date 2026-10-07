#!/usr/bin/env python3
"""Top-down breakdown (level 1) of the nofib executables of one configuration.

    webs-bench/topdown-nofib.py CONFIG

Runs each benchmark kept by run-nofib.sh (results/CONFIG/bin, runs.tsv) once,
pinned to a performance core, under perf's TopdownL1 metric group, and
reports where its pipeline slots go: retiring (useful work), front-end bound
(instruction fetch and decode), back-end bound (execution and memory), bad
speculation.  The question it answers: is GHC-compiled code limited by
instruction delivery, so that code layout matters?  Needs perf counters
(perf_event_paranoid <= 2).  Output: results/topdown-CONFIG.md.
"""

import os
import shlex
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOFIB = os.path.join(ROOT, 'nofib')
RESULTS = os.path.join(ROOT, 'webs-bench', 'results')
CPU = '4'
METRICS = ['tma_retiring', 'tma_frontend_bound', 'tma_backend_bound', 'tma_bad_speculation']


def run(config, d, cmd):
    argv = shlex.split(cmd)
    argv[0] = os.path.join(NOFIB, 'runstdtest', 'runstdtest')
    argv[1] = os.path.join(RESULTS, config, 'bin', d, os.path.basename(argv[1]))
    r = subprocess.run(['taskset', '-c', CPU, 'perf', 'stat', '-x,', '-M', 'TopdownL1',
                        '--cputype', 'core'] + argv,
                       cwd=os.path.join(NOFIB, d), capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return None
    res = {}
    for line in r.stderr.splitlines():
        parts = line.split(',')
        if len(parts) >= 7:
            for m in METRICS:
                if m in parts[6]:
                    res[m] = float(parts[5])
    return res if len(res) == len(METRICS) else None


def main():
    config = sys.argv[1]
    rows = []
    with open(os.path.join(RESULTS, config, 'runs.tsv')) as f:
        for line in f:
            bench, d, cmd = line.rstrip('\n').split('\t')
            r = run(config, d, cmd)
            if r:
                rows.append((bench, r))
    out = os.path.join(RESULTS, 'topdown-%s.md' % config)
    with open(out, 'w') as f:
        w = lambda s='': f.write(s + '\n')
        w('# Top-down breakdown (level 1): %s\n' % config)
        w('Share of pipeline slots, %d benchmarks, one run each on CPU %s.\n' % (len(rows), CPU))
        w('| | median | 25th pct | 75th pct |')
        w('|---|---|---|---|')
        for m in METRICS:
            xs = sorted(r[m] for _, r in rows)
            q = statistics.quantiles(xs, n=4)
            w('| %s | %.1f%% | %.1f%% | %.1f%% |' % (m[4:], statistics.median(xs), q[0], q[2]))
        fe = [b for b, r in rows if r['tma_frontend_bound'] >= 30]
        w('\nFront-end bound at least 30%%: %d of %d benchmarks.\n' % (len(fe), len(rows)))
        w('| benchmark | retiring | front-end | back-end | bad speculation |')
        w('|---|---|---|---|---|')
        for b, r in sorted(rows, key=lambda x: -x[1]['tma_frontend_bound']):
            w('| %s | %.1f | %.1f | %.1f | %.1f |' % ((b,) + tuple(r[m] for m in METRICS)))
    print(out)


if __name__ == '__main__':
    main()
