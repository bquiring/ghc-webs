#!/usr/bin/env python3
"""Summarise the web experiments over nofib.

    webs-bench/report.py CONFIG [CONFIG ...]

reads webs-bench/results/CONFIG/ (see run-nofib.sh) and prints:

  1. First-class function statistics before and after the Core pipeline
     (GHC.WebCore.FirstClass), totals and per benchmark.
  2. Simplifier/inliner statistics (the "Grand total simplifier statistics"
     of -ddump-simpl-stats): total ticks and the inlining-related tick
     kinds, per configuration, with the change against the first one.
  3. Which benchmarks failed to build or run.
"""
import os, re, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
FC_FIELDS = ['lams', 'returned', 'passed', 'stored_data', 'stored_dict',
             'calls', 'unknown_calls', 'partial_apps', 'ww_workers']
INLINE_KINDS = ['PreInlineUnconditionally', 'PostInlineUnconditionally',
                'UnfoldingDone', 'RuleFired', 'BetaReduction',
                'KnownBranch', 'CaseOfCase', 'EtaExpansion', 'EtaReduction',
                'LetFloatFromLet', 'FillInCaseDefault', 'CaseElim',
                'CaseIdentity', 'CaseMerge', 'AltMerge']

def benchmarks(config):
    d = os.path.join(ROOT, config, 'dumps')
    for dirpath, _, files in os.walk(d):
        yield os.path.relpath(dirpath, d), [os.path.join(dirpath, f) for f in files]

def first_class(config):
    """bench -> phase -> field -> count"""
    res = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    for bench, files in benchmarks(config):
        for f in files:
            if not f.endswith('.dump-first-class-stats'):
                continue
            for line in open(f, errors='replace'):
                m = re.match(r'first-class-stats (\S+) (.*)', line.strip())
                if m:
                    for kv in m.group(2).split():
                        k, v = kv.split('=')
                        res[bench][m.group(1)][k] += int(v)
    return res

def simpl_stats(config):
    """bench -> kind -> count, from the grand totals"""
    res = collections.defaultdict(collections.Counter)
    for bench, files in benchmarks(config):
        for f in files:
            if not f.endswith('.dump-simpl-stats'):
                continue
            text = open(f, errors='replace').read()
            for sec in text.split('====================')[1:]:
                pass
            # Only the grand total section
            i = text.find('Grand total simplifier statistics')
            if i < 0:
                continue
            sec = text[i:]
            m = re.search(r'Total ticks:\s+(\d+)', sec)
            if m:
                res[bench]['Total ticks'] += int(m.group(1))
            for line in sec.splitlines():
                m = re.match(r'^(\d+)\s+([A-Za-z]+)\s*$', line)
                if m:
                    res[bench][m.group(2)] += int(m.group(1))
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

def geomean_ratio(xs):
    import math
    xs = [x for x in xs if x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float('nan')

def pct(new, old):
    return '' if old == 0 else '%+.1f%%' % (100.0 * (new - old) / old)

def main(configs):
    print('# First-class function statistics (static counts, summed over modules)\n')
    for c in configs:
        fc = first_class(c)
        tot = {p: collections.Counter() for p in ('before', 'after')}
        for b in fc:
            for p in tot:
                tot[p].update(fc[b][p])
        print('## %s  (%d benchmarks)\n' % (c, len(fc)))
        print('| | ' + ' | '.join(FC_FIELDS) + ' |')
        print('|---' * (len(FC_FIELDS) + 1) + '|')
        for p in ('before', 'after'):
            print('| %s | ' % p + ' | '.join(str(tot[p][f]) for f in FC_FIELDS) + ' |')
        print()
    c0 = configs[0]
    fc0 = first_class(c0)
    print('## Per benchmark, %s: before -> after (returned / passed / stored_data / unknown_calls)\n' % c0)
    print('| benchmark | returned | passed | stored_data | stored_dict | unknown_calls |')
    print('|---|---|---|---|---|---|')
    for b in sorted(fc0):
        r = fc0[b]
        print('| %s | %d -> %d | %d -> %d | %d -> %d | %d -> %d | %d -> %d |' % (
            b, r['before']['returned'], r['after']['returned'],
            r['before']['passed'], r['after']['passed'],
            r['before']['stored_data'], r['after']['stored_data'],
            r['before']['stored_dict'], r['after']['stored_dict'],
            r['before']['unknown_calls'], r['after']['unknown_calls']))
    print()

    print('# Simplifier and inliner statistics (grand totals, summed over modules)\n')
    stats = {c: simpl_stats(c) for c in configs}
    tots = {c: sum((stats[c][b] for b in stats[c]), collections.Counter()) for c in configs}
    ww = {c: sum((first_class(c)[b]['after']['ww_workers'] for b in first_class(c)), 0)
          for c in configs}
    kinds = ['Total ticks'] + INLINE_KINDS
    print('| kind | ' + ' | '.join(configs) + ' |')
    print('|---' * (len(configs) + 1) + '|')
    for k in kinds:
        row = [str(tots[c0][k])] + ['%d (%s)' % (tots[c][k], pct(tots[c][k], tots[c0][k]))
                                    for c in configs[1:]]
        print('| %s | ' % k + ' | '.join(row) + ' |')
    row = [str(ww[c0])] + ['%d (%s)' % (ww[c], pct(ww[c], ww[c0])) for c in configs[1:]]
    print('| $w workers (final Core) | ' + ' | '.join(row) + ' |')
    print()

    if len(configs) > 1:
        print('## UnfoldingDone per benchmark (largest changes vs %s)\n' % c0)
        print('| benchmark | ' + ' | '.join(configs) + ' |')
        print('|---' * (len(configs) + 1) + '|')
        benches = sorted(stats[c0], key=lambda b: -max(abs(stats[c][b]['UnfoldingDone'] - stats[c0][b]['UnfoldingDone']) for c in configs))
        for b in benches[:25]:
            print('| %s | ' % b + ' | '.join(str(stats[c][b]['UnfoldingDone']) for c in configs) + ' |')
        print()

    print('# Compile and run performance (from the nofib logs)\n')
    tim = {c: timings(c) for c in configs}
    print('| measure | ' + ' | '.join(configs[1:]) + ' |')
    print('|---' * len(configs) + '|')
    # Only allocation: it is deterministic.  Times (compile time, mutator
    # time) varied by up to 3x across the configurations of one run, for
    # identical code, because the machine's speed varied over the hours the
    # runs take; comparing them needs NoFibRuns > 1 on a quiet machine.
    for k, name in [('compile_alloc', 'compiler allocation'),
                    ('run_alloc', 'program allocation')]:
        cells = []
        for c in configs[1:]:
            ratios = [tim[c][b][k] / tim[c0][b][k] for b in tim[c0]
                      if b in tim[c] and tim[c0][b][k] > 0 and tim[c][b][k] > 0]
            g = geomean_ratio(ratios)
            cells.append('%+.2f%% (geomean over %d)' % (100 * (g - 1), len(ratios)))
        print('| %s vs %s | ' % (name, c0) + ' | '.join(cells) + ' |')
    print()
    print('Times are not reported: they are not reliable on this machine (see report.py).\n')
    print('## Program allocation per benchmark (bytes; change vs %s)\n' % c0)
    print('| benchmark | ' + ' | '.join(configs) + ' |')
    print('|---' * (len(configs) + 1) + '|')
    for b in sorted(tim[c0]):
        base = tim[c0][b]['run_alloc']
        cells = [str(base)] + ['%s' % pct(tim[c][b]['run_alloc'], base) for c in configs[1:]]
        print('| %s | ' % b + ' | '.join(cells) + ' |')
    print()

    print('# Build and run failures\n')
    for c in configs:
        f = failures(c)
        print('- %s: %d lines' % (c, len(f)))
        for line in f[:40]:
            print('    ' + line)

if __name__ == '__main__':
    main(sys.argv[1:])
