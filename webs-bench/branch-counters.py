#!/usr/bin/env python3
"""Branch and call counters of nofib benchmarks in several configurations
(results/CONFIG/bin, as run-nofib.sh builds them):

    python3 webs-bench/branch-counters.py CONFIG... --bench NAME... [--rounds 3] [--cpu 2]

Each benchmark runs through nofib's runstdtest, as time-nofib.py runs it,
pinned to a performance core, under perf stat with user-space counts of:
instructions, cycles, branches (all, conditional, indirect), mispredicted
branches (all, conditional, indirect), L1 instruction-cache misses; and the
RTS's allocation (-ghc-timing).  GHC's unknown calls, returns to
continuations and calls through info pointers are indirect jumps.  Prints,
per benchmark, the medians over rounds, and each configuration's change
against the first.
"""
import argparse, os, re, shlex, statistics as st, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NOFIB = os.path.join(HERE, '..', 'nofib')
RESULTS = os.path.join(HERE, 'results')
GHC_TIMING = re.compile(r'<<ghc: (\d+) bytes')
EVENTS = [('instr', 'cpu_core/instructions/u'), ('cycles', 'cpu_core/cycles/u'),
          ('br', 'cpu_core/br_inst_retired.all_branches/u'),
          ('br_cond', 'cpu_core/br_inst_retired.cond/u'),
          ('br_ind', 'cpu_core/br_inst_retired.indirect/u'),
          ('mis', 'cpu_core/br_misp_retired.all_branches/u'),
          ('mis_cond', 'cpu_core/br_misp_retired.cond/u'),
          ('mis_ind', 'cpu_core/br_misp_retired.indirect/u'),
          ('icache', 'cpu_core/L1-icache-load-misses/u')]
# two groups, so that no event is multiplexed
GROUPS = [EVENTS[:5], EVENTS[:2] + EVENTS[5:]]


def runs(config):
    out = {}
    for line in open(os.path.join(RESULTS, config, 'runs.tsv')):
        name, d, cmd = line.rstrip('\n').split('\t')[:3]
        out[name] = (d, cmd)
    return out


def run(config, d, cmd, cpu, group):
    argv = shlex.split(cmd)
    argv[0] = os.path.join(NOFIB, 'runstdtest', 'runstdtest')
    argv[1] = os.path.join(RESULTS, config, 'bin', d, os.path.basename(argv[1]))
    fd, po = tempfile.mkstemp(suffix='.perf'); os.close(fd)
    r = subprocess.run(['taskset', '-c', str(cpu), 'perf', 'stat', '-x,', '-o', po,
                        '-e', ','.join(e for _, e in group)] + argv,
                       cwd=os.path.join(NOFIB, d), capture_output=True, text=True)
    s = {}
    m = GHC_TIMING.search(r.stdout + r.stderr)
    if m:
        s['alloc'] = int(m.group(1))
    names = {e: k for k, e in group}
    for line in open(po):
        p = line.split(',')
        if len(p) > 2 and p[0].strip().isdigit() and p[2] in names:
            s[names[p[2]]] = int(p[0])
    os.unlink(po)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('configs', nargs='+')
    ap.add_argument('--bench', nargs='+', required=True)
    ap.add_argument('--rounds', type=int, default=3)
    ap.add_argument('--cpu', default='2')
    a = ap.parse_args()
    keys = [k for k, _ in EVENTS] + ['alloc']
    rs = {c: runs(c) for c in a.configs}
    for b in a.bench:
        res = {}
        for c in a.configs:
            if b not in rs[c]:
                continue
            d, cmd = rs[c][b]
            samples = {k: [] for k in keys}
            for _ in range(a.rounds):
                for g in GROUPS:
                    s = run(c, d, cmd, a.cpu, g)
                    for k, v in s.items():
                        if k in ('instr', 'cycles') and g is not GROUPS[0]:
                            continue
                        samples[k].append(v)
            res[c] = {k: st.median(v) for k, v in samples.items() if v}
        base = res.get(a.configs[0], {})
        print('== %s' % b)
        print('  %-18s' % 'config' + ''.join('%14s' % k for k in keys))
        for c in a.configs:
            if c not in res:
                continue
            row = res[c]
            print('  %-18s' % c + ''.join('%14d' % row.get(k, 0) for k in keys))
            if c != a.configs[0]:
                print('  %-18s' % '  change' + ''.join(
                    '%13.1f%%' % (100.0 * (row.get(k, 0) - base.get(k, 0)) / base[k]) if base.get(k) else '%14s' % '-'
                    for k in keys))


if __name__ == '__main__':
    main()
