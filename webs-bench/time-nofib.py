#!/usr/bin/env python3
"""Time the nofib executables of several configurations against each other.

    webs-bench/time-nofib.py [options] CONFIG...

The first CONFIG is the baseline.  Each configuration must have been built
by run-nofib.sh, which keeps its executables (results/CONFIG/bin/) and the
command nofib uses to run each one (results/CONFIG/runs.tsv).

Why not use the times in the nofib logs: run-nofib.sh builds and runs one
configuration after another, over hours, and this machine's speed drifts
(powersave governor, thermal limits, a hybrid CPU), so the same code timed
up to 3x apart in different configurations.  Here the configurations are
interleaved instead: in every round, each benchmark runs once per
configuration, in a fresh random order, so drift hits all of them alike.
Every run is pinned to one CPU (a performance core whose hyperthread
sibling is left idle), and the first run of each benchmark is a discarded
warm-up.  Each run goes through nofib's own runstdtest, so its output is
checked against the expected output, and a wrong answer is never timed.

Measured per run: mutator and GC elapsed time (from the RTS's -ghc-timing
line), wall time, and, if perf_event_paranoid allows it, user-space
instructions and cycles.  Results go to results/timing-LABEL.json (every
sample) and results/timing-LABEL.md (the report).  The report compares
medians of paired ratios, and calls a time change real only if it is at least
--min-change, with every round's paired ratio (config/baseline, measured
in the same round) on the same side of 1.
"""

import argparse
import json
import os
import random
import re
import shlex
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOFIB = os.path.join(ROOT, 'nofib')
RESULTS = os.path.join(ROOT, 'webs-bench', 'results')

GHC_TIMING = re.compile(r'<<ghc: (\d+) bytes.*?([\d.]+) MUT \(([\d.]+) elapsed\), '
                        r'([\d.]+) GC \(([\d.]+) elapsed\)')


def read_runs(config):
    """benchmark -> (directory, command), from results/CONFIG/runs.tsv"""
    path = os.path.join(RESULTS, config, 'runs.tsv')
    runs = {}
    with open(path) as f:
        for line in f:
            bench, d, cmd = line.rstrip('\n').split('\t')
            runs[d] = (bench, d, cmd)
    return runs


def perf_ok():
    try:
        with open('/proc/sys/kernel/perf_event_paranoid') as f:
            level = int(f.read())
    except OSError:
        return False
    if level > 2:
        return False
    r = subprocess.run(['taskset', '-c', '4', 'perf', 'stat', '-x,', '-e', perf_events(), 'true'],
                       capture_output=True, text=True)
    return r.returncode == 0 and re.search(r'^\d+,', r.stderr, re.M) is not None


def perf_events():
    """The user-space instruction and cycle events.  On a hybrid CPU (this
    one) perf counts the performance cores (cpu_core) and the efficiency
    cores (cpu_atom) separately; the runs are pinned to a performance core."""
    if os.path.isdir('/sys/bus/event_source/devices/cpu_core'):
        return 'cpu_core/instructions/u,cpu_core/cycles/u'
    return 'instructions:u,cycles:u'


def machine_state():
    def read(p):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            return '?'
    return {
        'governor': read('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'),
        'no_turbo': read('/sys/devices/system/cpu/intel_pstate/no_turbo'),
        'loadavg': read('/proc/loadavg'),
        'perf_event_paranoid': read('/proc/sys/kernel/perf_event_paranoid'),
    }


def run_once(config, d, cmd, cpu, use_perf, timeout):
    """Run one benchmark of one configuration; returns a sample dict, or
    {'error': ...}"""
    argv = shlex.split(cmd)
    # argv: runstdtest ./prog ...; run this configuration's copy of prog
    argv[0] = os.path.join(NOFIB, 'runstdtest', 'runstdtest')
    argv[1] = os.path.join(RESULTS, config, 'bin', d, os.path.basename(argv[1]))
    prefix = ['taskset', '-c', str(cpu)]
    perf_out = None
    if use_perf:
        fd, perf_out = tempfile.mkstemp(suffix='.perf')
        os.close(fd)
        prefix += ['perf', 'stat', '-x,', '-o', perf_out, '-e', perf_events()]
    t0 = time.perf_counter()
    try:
        r = subprocess.run(prefix + argv, cwd=os.path.join(NOFIB, d),
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'error': 'timeout'}
    wall = time.perf_counter() - t0
    out = r.stdout + r.stderr
    if r.returncode != 0:
        return {'error': 'exit %d: %s' % (r.returncode, out[-300:])}
    m = GHC_TIMING.search(out)
    if not m:
        return {'error': 'no timing line: ' + out[-300:]}
    s = {'alloc': int(m.group(1)), 'mut': float(m.group(3)), 'gc': float(m.group(5)),
         'wall': wall}
    if perf_out:
        with open(perf_out) as f:
            for line in f:
                parts = line.split(',')
                if len(parts) > 2 and parts[0].strip().isdigit():
                    # 'instructions:u', or on a hybrid CPU 'cpu_core/instructions/u'
                    m = re.search(r'instructions|cycles', parts[2])
                    if m:
                        s[m.group(0)] = int(parts[0])
        os.unlink(perf_out)
    return s


def median(xs):
    return statistics.median(xs) if xs else None


def report(data, out):
    configs = data['configs']
    base = configs[0]
    metric = data['metric']
    lines = []
    w = lines.append
    w('# Runtime: %s\n' % ' vs '.join(configs))
    st = data['machine']
    w('%d rounds, mode %s, CPU %s; governor %s, no_turbo %s, load at start %s.\n'
      % (data['rounds'], data['mode'], data['cpu'], st['governor'], st['no_turbo'],
         st['loadavg']))
    w('Each cell is the median, over rounds, of the paired ratio config/%s: the '
      'two ran in the same round, seconds apart, so the machine\'s drift '
      '(which moves all configurations alike) cancels.  A time change counts only '
      'if it is at least %.1f%% and every round\'s ratio is on the same side of 1; '
      '"~" marks one that does not.  Time is %s.\n' % (base, 100 * data['min_change'], metric))
    counters = [k for k in ('instructions', 'cycles') if k in data.get('counters', [])]
    if counters:
        w('Instructions and cycles are user-space counts on the pinned performance '
          'core.  Instructions are nearly deterministic: changes of a fraction of a '
          'percent are real.\n')
        w('**Layout.**  The same code, placed differently in the binary, can run up '
          'to ~8%% faster or slower (spectral/knights, real/mkhprog: identical or '
          'nearly identical Core, cycles +8%% and -4%%, from fetch bandwidth).  So a '
          'time change whose instruction count moves less than %.1f%% is listed '
          'as "layout only" (L), not as a change.\n' % (100 * data['layout_ins']))

    def val(s, k):
        return s['mut'] + s['gc'] if k == 'time' and metric == 'mut+gc' else s[metric if k == 'time' else k]

    def paired(per, c, k):
        rs = [val(sc, k) / val(sb, k) for sb, sc in zip(per[base], per[c]) if val(sb, k) > 0]
        return rs

    keys = ['time'] + counters
    geo = {(c, k): [] for c in configs[1:] for k in keys}
    wins = {c: [] for c in configs[1:]}
    losses = {c: [] for c in configs[1:]}
    layouts = {c: [] for c in configs[1:]}
    rows = []
    for d, per in sorted(data['samples'].items()):
        if any(not per.get(c) for c in configs):
            continue
        tb = median([val(s, 'time') for s in per[base]])
        if not tb or tb <= 0:
            continue
        cells = []
        for c in configs[1:]:
            for k in keys:
                rs = paired(per, c, k)
                if not rs:
                    cells.append('')
                    continue
                r = median(rs)
                geo[(c, k)].append(r)
                if k == 'time':
                    real = abs(r - 1) >= data['min_change'] and (all(x > 1 for x in rs) or all(x < 1 for x in rs))
                    # Code layout: the time moves, the instructions do not
                    # (see the header); listed apart, not as a change
                    ins = paired(per, c, 'instructions') if 'instructions' in counters else []
                    layout = real and ins and abs(median(ins) - 1) < data['layout_ins']
                    if layout:
                        layouts[c].append((d.split('/')[-1], r))
                    elif real:
                        (wins if r < 1 else losses)[c].append((d.split('/')[-1], r))
                    cells.append('%s%+.1f%%' % ('L' if layout else '' if real else '~', 100 * (r - 1)))
                else:
                    cells.append('%+.2f%%' % (100 * (r - 1)))
        rows.append('| %s | %.3f | %s |' % (d.split('/')[-1], tb, ' | '.join(cells)))

    w('## Summary\n')
    def names(xs, rev=False):
        return ', '.join('%s %+.1f%%' % (n, 100 * (r - 1))
                         for n, r in sorted(xs, key=lambda x: -x[1] if rev else x[1])) or '-'
    lay = bool(counters)
    w('| config | %s | faster | slower |%s' % (' | '.join('geomean %s' % k for k in keys),
                                              ' layout only |' if lay else ''))
    w('|---|' + '---|' * len(keys) + '---|---|' + ('---|' if lay else ''))
    for c in configs[1:]:
        gs = ['%+.2f%% (%d)' % (100 * (statistics.geometric_mean(geo[(c, k)]) - 1), len(geo[(c, k)]))
              if geo[(c, k)] else '-' for k in keys]
        w('| %s | %s | %s | %s |%s' % (c, ' | '.join(gs), names(wins[c]), names(losses[c], True),
                                      ' %s |' % names(layouts[c]) if lay else ''))
    w('')
    w('Faster at least 5%%, backed by instructions (at least %.1f%% fewer): %s' % (
        100 * data['layout_ins'],
        '; '.join('%s: %s' % (c, ', '.join(n for n, r in sorted(wins[c], key=lambda x: x[1]) if r <= 0.95) or '-')
                  for c in configs[1:]) if lay else '(no instruction counts)'))
    w('')
    w('## Per benchmark\n')
    w('| benchmark | %s time (s) | %s |' % (base, ' | '.join('%s %s' % (c, k) for c in configs[1:] for k in keys)))
    w('|---|---|' + '---|' * (len(keys) * (len(configs) - 1)))
    lines += rows
    errs = data.get('errors', {})
    if errs:
        w('\n## Errors\n')
        w('A benchmark that fails is dropped; the configuration named is the first '
          'one that failed in its round (others may fail too: nofib\'s expected '
          'output for some benchmarks does not match mode norm).\n')
        for k, e in sorted(errs.items()):
            w('- %s: %s' % (k, e.replace('\n', ' ')[:200]))
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('configs', nargs='+')
    ap.add_argument('--label', help='name of the output files (default: the configs joined by _)')
    ap.add_argument('--rounds', type=int, default=5)
    ap.add_argument('--cpu', type=int, default=4,
                    help='CPU to pin to (default 4: a performance core; leave its sibling 5 idle)')
    ap.add_argument('--bench', action='append', default=[],
                    help='only benchmarks whose directory contains this (repeatable)')
    ap.add_argument('--metric', default='mut+gc', choices=['mut+gc', 'mut', 'wall'])
    ap.add_argument('--min-change', type=float, default=0.02,
                    help='smallest relative change reported as real (default 0.02)')
    ap.add_argument('--layout-ins', type=float, default=0.005,
                    help='a time change with an instruction change under this is '
                         'layout only (default 0.005)')
    ap.add_argument('--timeout', type=int, default=300, help='per run, in seconds')
    ap.add_argument('--report-only', action='store_true',
                    help='rewrite the report from the saved samples')
    a = ap.parse_args()
    label = a.label or '_'.join(a.configs)
    jpath = os.path.join(RESULTS, 'timing-%s.json' % label)
    mpath = os.path.join(RESULTS, 'timing-%s.md' % label)
    if a.report_only:
        with open(jpath) as f:
            data = json.load(f)
        data['metric'], data['min_change'] = a.metric, a.min_change
        data['layout_ins'] = a.layout_ins
        report(data, mpath)
        print(mpath)
        return

    runs = {c: read_runs(c) for c in a.configs}
    dirs = sorted(set.intersection(*(set(r) for r in runs.values())))
    if a.bench:
        dirs = [d for d in dirs if any(b in d for b in a.bench)]
    use_perf = perf_ok()
    mode = next(iter(runs[a.configs[0]].values()))[2]
    st = machine_state()
    print('%d benchmarks x %d configs x %d rounds (+1 warm-up); CPU %d; perf counters: %s'
          % (len(dirs), len(a.configs), a.rounds, a.cpu, 'yes' if use_perf else 'no'))
    print('machine: %s' % st)
    if st['governor'] != 'performance':
        print('note: governor is %s; "sudo cpupower frequency-set -g performance" reduces noise'
              % st['governor'])
    if not use_perf:
        print('note: no perf counters; "sudo sysctl kernel.perf_event_paranoid=1" enables '
              'instruction counts')

    data = {'configs': a.configs, 'rounds': a.rounds, 'cpu': a.cpu, 'machine': st,
            'metric': a.metric, 'min_change': a.min_change, 'layout_ins': a.layout_ins,
            'mode': os.environ.get('TIMING_MODE', 'norm'),
            'counters': ['instructions', 'cycles'] if use_perf else [],
            'samples': {d: {c: [] for c in a.configs} for d in dirs}, 'errors': {}}
    broken = set()
    t_start = time.time()
    for rnd in range(a.rounds + 1):
        for i, d in enumerate(dirs):
            if d in broken:
                continue
            order = list(a.configs)
            random.shuffle(order)
            for c in order:
                _, _, cmd = runs[c][d]
                s = run_once(c, d, cmd, a.cpu, use_perf, a.timeout)
                if 'error' in s:
                    data['errors']['%s [%s]' % (d, c)] = s['error']
                    broken.add(d)
                    break
                if rnd > 0:
                    data['samples'][d][c].append(s)
        print('round %d/%d done (%.0f s)' % (rnd, a.rounds, time.time() - t_start), flush=True)
        with open(jpath, 'w') as f:
            json.dump(data, f)
    for d in broken:
        data['samples'].pop(d, None)
    with open(jpath, 'w') as f:
        json.dump(data, f)
    report(data, mpath)
    print('samples: %s\nreport:  %s' % (jpath, mpath))


if __name__ == '__main__':
    main()
