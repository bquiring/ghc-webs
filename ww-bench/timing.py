#!/usr/bin/env python3
"""Stable run-time measurements for nofib, outside nofib's own runner.

  timing.py stash CONFIG
      After ww-bench/run-nofib.sh CONFIG: copy each benchmark's binary to
      ww-bench/bins/CONFIG/ and record its run command (from nofib.log).
  timing.py run CONFIG_A CONFIG_B [--rounds N] [--cpu C]
      Run every benchmark of both configurations N times.  Each round visits
      the benchmarks in a random order, and the two configurations in a
      random order per benchmark, so drift (temperature, other load) hits
      both alike.  Each run is pinned to one CPU (taskset; choose a
      performance core) and goes through nofib's runstdtest, which checks the
      output.  Results are appended to ww-bench/results/timing-A-B.jsonl as
      they come, and runs already there are skipped: the measurement can be
      resumed after an interruption.
  timing.py report CONFIG_A CONFIG_B
      Per benchmark: median MUT and elapsed time of each configuration, the
      ratio B/A, and the spread of A's runs; geometric means of the ratios.

Times come from the GHC RTS (-ghc-timing): MUT is the time spent in the
program, outside garbage collection; elapsed is INIT + MUT + GC, wall clock.
When perf can count user-space events (kernel.perf_event_paranoid <= 2),
each program also runs under perf stat (perf-wrap.sh), for its retired
instructions and cycles: instructions hardly vary from run to run, and do
not depend on the CPU frequency.
"""
import json
import math
import os
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOFIB = os.path.join(ROOT, 'nofib')
RESULTS = os.path.join(ROOT, 'ww-bench', 'results')
BINS = os.path.join(ROOT, 'ww-bench', 'bins')

RUN_RE = re.compile(r'^==nofib== (\S+): time to run (\S+) follows')
DIR_RE = re.compile(r'^ in (/\S+)$')
TIMING_RE = re.compile(r'<<ghc:(.*?):ghc>>', re.S)
FIELD_RE = re.compile(r'([\d.]+) (INIT|MUT|GC) \(([\d.]+) elapsed\)')


def commands(config):
    """(benchmark directory relative to nofib, program, run command)"""
    out = []
    cur_dir = None
    lines = open(os.path.join(RESULTS, config, 'nofib.log'), errors='replace').read().splitlines()
    for i, line in enumerate(lines):
        m = DIR_RE.match(line)
        if m:
            cur_dir = m.group(1)
            continue
        m = RUN_RE.match(line)
        if m and cur_dir and i + 1 < len(lines) and 'runstdtest' in lines[i + 1]:
            prog = m.group(2)
            cmd = lines[i + 1].strip().rstrip(';')
            out.append((os.path.relpath(cur_dir, NOFIB), prog, cmd))
    return out


def stash(config):
    dest = os.path.join(BINS, config)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    kept = []
    for rel, prog, cmd in commands(config):
        src = os.path.join(NOFIB, rel, prog)
        if not os.path.exists(src):
            print(f'missing binary: {rel}/{prog}', file=sys.stderr)
            continue
        os.makedirs(os.path.join(dest, rel), exist_ok=True)
        shutil.copy2(src, os.path.join(dest, rel, prog))
        kept.append({'dir': rel, 'prog': prog, 'cmd': cmd})
    json.dump(kept, open(os.path.join(dest, 'commands.json'), 'w'), indent=1)
    print(f'{config}: stashed {len(kept)} benchmarks in {dest}')


def load_commands(config):
    return {(c['dir'], c['prog']): c for c in json.load(open(os.path.join(BINS, config, 'commands.json')))}


def parse_timing(text):
    """Sum over the program's runs (some benchmarks run it more than once)"""
    blocks = TIMING_RE.findall(text)
    if not blocks:
        return None
    mut = elapsed = 0.0
    for b in blocks:
        for _cpu, kind, wall in FIELD_RE.findall(b):
            if kind == 'MUT':
                mut += float(wall)
            elapsed += float(wall)
    return {'mut': mut, 'elapsed': elapsed}


def perf_ok():
    try:
        p = subprocess.run(['perf', 'stat', '-x,', '-e', 'instructions:u', '--', 'true'],
                           capture_output=True, text=True)
        return p.returncode == 0 and 'instructions' in p.stderr and '<not supported>' not in p.stderr
    except OSError:
        return False


def parse_perf(path):
    """Instructions and cycles, summed over the runs and over the CPU types
    of a hybrid CPU (cpu_core, cpu_atom); uncounted lines are skipped"""
    counts = {}
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return {}
    for line in lines:
        fields = line.split(',')
        if len(fields) < 3 or not fields[0].strip().isdigit():
            continue
        for ev in ('instructions', 'cycles'):
            if ev in fields[2]:
                counts[ev] = counts.get(ev, 0) + int(fields[0])
    return counts


def results_path(a, b):
    return os.path.join(RESULTS, f'timing-{a}-{b}.jsonl')


def run(a, b, rounds, cpu):
    ca, cb = load_commands(a), load_commands(b)
    benches = sorted(set(ca) & set(cb))
    path = results_path(a, b)
    done = set()
    if os.path.exists(path):
        for line in open(path):
            r = json.loads(line)
            done.add((r['round'], r['dir'], r['prog'], r['config']))
    total = rounds * len(benches) * 2
    use_perf = perf_ok()
    wrapper = os.path.join(ROOT, 'ww-bench', 'perf-wrap.sh')
    perf_out = os.path.join(tempfile.mkdtemp(prefix='timing-'), 'perf.csv')
    print(f'{len(benches)} benchmarks, {rounds} rounds, CPU {cpu}, perf {"on" if use_perf else "off"}; '
          f'{len(done)} of {total} runs already done', flush=True)
    with open(path, 'a') as out:
        for rnd in range(rounds):
            rng = random.Random(rnd)
            order = benches[:]
            rng.shuffle(order)
            for key in order:
                configs = [(a, ca[key]), (b, cb[key])]
                rng.shuffle(configs)
                for config, c in configs:
                    if (rnd, key[0], key[1], config) in done:
                        continue
                    binary = os.path.join(BINS, config, key[0], key[1])
                    # The command runs ./prog: run the stashed binary instead
                    # (through perf-wrap.sh when counting)
                    env = dict(os.environ)
                    if use_perf:
                        env.update(PERF_BIN=binary, PERF_OUT=perf_out)
                        if os.path.exists(perf_out):
                            os.remove(perf_out)
                    cmd = c['cmd'].replace(f'./{key[1]} ', f'{wrapper if use_perf else binary} ', 1)
                    p = subprocess.run(['taskset', '-c', str(cpu), 'bash', '-c', cmd],
                                       cwd=os.path.join(NOFIB, key[0]), env=env,
                                       capture_output=True, text=True, errors='replace')
                    t = parse_timing(p.stdout + p.stderr)
                    rec = {'round': rnd, 'dir': key[0], 'prog': key[1], 'config': config,
                           'ok': p.returncode == 0 and t is not None}
                    if t:
                        rec.update(t)
                    if use_perf:
                        rec.update(parse_perf(perf_out))
                    out.write(json.dumps(rec) + '\n')
                    out.flush()
            print(f'round {rnd + 1}/{rounds} done', flush=True)


def geomean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float('nan')


def report(a, b, min_time=0.2):
    runs = {}
    failed = set()
    for line in open(results_path(a, b)):
        r = json.loads(line)
        key = (r['dir'], r['prog'])
        if not r['ok']:
            failed.add((key, r['config']))
            continue
        runs.setdefault(key, {}).setdefault(r['config'], []).append(r)
    rows = []
    for key in sorted(runs):
        ra, rb = runs[key].get(a, []), runs[key].get(b, [])
        if not ra or not rb:
            continue
        row = {'bench': key[0].split('/', 1)[-1] if key[0].count('/') else key[0], 'n': min(len(ra), len(rb))}
        for m in ('mut', 'elapsed', 'instructions', 'cycles'):
            xa = [r[m] for r in ra if m in r]
            xb = [r[m] for r in rb if m in r]
            if not xa or not xb:
                continue
            ma, mb = statistics.median(xa), statistics.median(xb)
            row[m + '_a'], row[m + '_b'] = ma, mb
            row[m + '_ratio'] = mb / ma if ma > 0 else float('nan')
            # Spread of A's runs: (max - min) / median
            row[m + '_spread'] = (max(xa) - min(xa)) / ma if ma > 0 else float('nan')
        rows.append(row)

    timed = [r for r in rows if r['mut_a'] >= min_time]
    print(f'# Run time: {b} against {a}\n')
    print(f'{len(rows)} benchmarks, {max((r["n"] for r in rows), default=0)} runs each, '
          f'pinned to one performance core, configurations interleaved. '
          f'Medians; spread is (max - min) / median of the {a} runs. '
          f'Geometric means over the {len(timed)} benchmarks whose {a} MUT time is at least {min_time} s.\n')
    print('| measure | ratio (geomean) |')
    print('|---|---:|')
    have_perf = any('instructions_ratio' in r for r in rows)
    measures = [('mut', 'MUT time'), ('elapsed', 'elapsed time')]
    if have_perf:
        measures += [('instructions', 'instructions'), ('cycles', 'cycles')]
    for m, name in measures:
        ratios = [r[m + '_ratio'] for r in timed if m + '_ratio' in r]
        print(f'| {name} | {100 * (geomean(ratios) - 1):+.2f}% |' if ratios else f'| {name} | n/a |')
    for m, name in measures:
        spreads = sorted(r[m + '_spread'] for r in timed if m + '_spread' in r)
        if spreads:
            print(f'| {name}: spread of {a} runs (median over benchmarks) | {100 * statistics.median(spreads):.2f}% |')
    print()
    print('## Changes larger than the spread\n')
    print(f'MUT time changes over 1% and over the spread of the {a} runs'
          + ('; instruction count changes over 0.5%' if have_perf else '') + '.\n')
    print(f'| benchmark | {a} MUT (s) | {b} MUT | MUT spread | {b} instructions |')
    print('|---|---:|---:|---:|---:|')
    for r in sorted(timed, key=lambda r: r['mut_ratio']):
        big_time = abs(r['mut_ratio'] - 1) > max(r['mut_spread'], 0.01)
        big_insns = abs(r.get('instructions_ratio', 1) - 1) > 0.005
        if big_time or big_insns:
            ins = f'{100 * (r["instructions_ratio"] - 1):+.2f}%' if 'instructions_ratio' in r else ''
            print(f'| {r["bench"]} | {r["mut_a"]:.3f} | {100 * (r["mut_ratio"] - 1):+.2f}% '
                  f'| {100 * r["mut_spread"]:.2f}% | {ins} |')
    print()
    print('## All benchmarks\n')
    def pct(r, k):
        return f'{100 * (r[k] - 1):+.2f}%' if k in r else ''
    print(f'| benchmark | runs | {a} MUT (s) | {b} MUT | MUT spread | {a} elapsed (s) | {b} elapsed '
          f'| {b} instructions | {b} cycles |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for r in rows:
        print(f'| {r["bench"]} | {r["n"]} | {r["mut_a"]:.3f} | {pct(r, "mut_ratio")} '
              f'| {100 * r["mut_spread"]:.2f}% | {r["elapsed_a"]:.3f} | {pct(r, "elapsed_ratio")} '
              f'| {pct(r, "instructions_ratio")} | {pct(r, "cycles_ratio")} |')
    if failed:
        print('\n## Failed runs (wrong output or no timing)\n')
        for (key, config) in sorted(failed):
            print(f'- {key[0]}/{key[1]} ({config})')


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == 'stash':
        stash(args[1])
    elif len(args) >= 3 and args[0] == 'run':
        rounds = int(args[args.index('--rounds') + 1]) if '--rounds' in args else 10
        cpu = int(args[args.index('--cpu') + 1]) if '--cpu' in args else 4
        run(args[1], args[2], rounds, cpu)
    elif len(args) == 3 and args[0] == 'report':
        report(args[1], args[2])
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
