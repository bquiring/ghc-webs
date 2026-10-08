#!/usr/bin/env python3
"""Tally the verdicts of the web transformations over nofib.

    webs-bench/verdicts.py CONFIG [CONFIG ...]

reads the -ddump-webs-<pass> dumps in webs-bench/results/CONFIG/dumps/ (see
run-nofib.sh).  Each dump line is "verdict: binders", one per web.  Prints,
per pass, how many webs the pass changed ("fired"), then every verdict's
count per configuration.
"""
import os, re, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
PASSES = ['one-shot', 'inline', 'const-prop', 'arity-raise', 'dead-params', 'uncurry', 'defunc',
          'result-raise', 'strictness']
# A verdict component that changed the program starts with one of these
FIRED = ['inline', 'strict argument', 'strict result fields',
         'constant argument', 'constant result', 'uncurried', 'raised',
         'deleted', 'unit', 'one-shot']

def components(verdict):
    """Split a verdict into its parts (const-prop and strictness give one
    for the arguments and one for the result), dropping specifics such as
    the constant or the depth from the parts that fired."""
    out = []
    for c in verdict.split('; '):
        for k in FIRED:
            if c.startswith(k) and not c.startswith('unit ('):
                c = k
                break
        out.append(c)
    return out

def fired(part):
    return part in FIRED or part.startswith('unit (')

def tally(config):
    """pass -> Counter of verdict parts, plus 'webs' and 'fired' counts"""
    t = {p: collections.Counter() for p in PASSES}
    d = os.path.join(ROOT, config, 'dumps')
    for dirpath, _, files in os.walk(d):
        for f in files:
            m = re.search(r'\.dump-webs-(.*)$', f)
            if not m or m.group(1) not in t:
                continue
            c = t[m.group(1)]
            # Sections other than the verdicts (defunctionalisation's
            # specialisation post-pass: "Main.Defun1: specialised ...")
            skip = False
            for line in open(os.path.join(dirpath, f), errors='replace'):
                line = line.rstrip('\n')
                if line.startswith('===='):
                    skip = 'specialising' in line
                    continue
                if skip or not line or line[0].isspace() or ': ' not in line:
                    continue
                verdict = line.rsplit(': ', 1)[0]
                parts = components(verdict)
                c['webs'] += 1
                if any(fired(p) for p in parts):
                    c['fired'] += 1
                for p in parts:
                    c[p] += 1
    return t

def main(configs):
    ts = {c: tally(c) for c in configs}
    print('# Web transformation verdicts (webs, summed over modules)\n')
    print('| pass | ' + ' | '.join('%s fired / webs' % c for c in configs) + ' |')
    print('|---' * (len(configs) + 1) + '|')
    for p in PASSES:
        print('| %s | ' % p + ' | '.join(
            '%d / %d' % (ts[c][p]['fired'], ts[c][p]['webs']) for c in configs) + ' |')
    for p in PASSES:
        keys = set()
        for c in configs:
            keys |= set(ts[c][p]) - {'webs', 'fired'}
        if not keys:
            continue
        print('\n## %s\n' % p)
        print('| verdict | ' + ' | '.join(configs) + ' |')
        print('|---' * (len(configs) + 1) + '|')
        for k in sorted(keys, key=lambda k: (not fired(k), -ts[configs[0]][p][k], k)):
            mark = '**%s**' % k if fired(k) else k
            print('| %s | ' % mark + ' | '.join(str(ts[c][p][k]) for c in configs) + ' |')

if __name__ == '__main__':
    main(sys.argv[1:])
