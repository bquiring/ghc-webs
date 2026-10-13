#!/usr/bin/env python3
"""Tally the verdicts of the web transformations over nofib.

    webs-bench/verdicts.py CONFIG [CONFIG ...]

reads the -ddump-webs-<pass> dumps in webs-bench/results/CONFIG/dumps/ (see
run-nofib.sh), or, for a CONFIG that is a directory, the dumps anywhere
under it (a cabal build directory built with -ddump-to-file).  Each dump line is "verdict: binders", one per web.  Prints,
per pass, how many webs the pass changed ("fired"), then every verdict's
count per configuration.
"""
import os, re, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
PASSES = ['one-shot', 'inline', 'const-prop', 'arity-raise', 'dead-params', 'uncurry', 'defunc',
          'result-raise', 'strictness', 'useless']
# A verdict component that changed the program starts with one of these
FIRED = ['inline', 'strict argument', 'strict result fields',
         'constant argument', 'constant result', 'uncurried', 'raised',
         'deleted', 'unit', 'one-shot', 'dead fields', 'defunctionalised']

def components(verdict):
    """Split a verdict into its parts (const-prop and strictness give one
    for the arguments and one for the result), dropping specifics such as
    the constant or the depth from the parts that fired."""
    out = []
    for c in verdict.split('; '):
        if 'no change' in c:
            # e.g. "constant argument X (no change: parameter unused)",
            # "strict argument (depth 1, no change)": the kind and the reason
            kind = next((k for k in FIRED if c.startswith(k)), c)
            m = re.search(r'no change(: [^)]*)?', c)
            out.append('%s (%s)' % (kind, m.group(0)))
            continue
        for k in FIRED:
            if c.startswith(k) and not c.startswith('unit ('):
                c = k
                break
        out.append(c)
    return out

def fired(part):
    # "no change": the verdict held but the rewrite had nothing to do
    # (strictness, constant propagation, inlining say so)
    if 'no change' in part:
        return False
    return part in FIRED or part.startswith('unit (')

def tally(config):
    """pass -> Counter of verdict parts, plus 'webs' and 'fired' counts"""
    t = {p: collections.Counter() for p in PASSES}
    d = config if os.path.isdir(config) else os.path.join(ROOT, config, 'dumps')
    for dirpath, _, files in os.walk(d):
        for f in files:
            m = re.search(r'\.dump-webs-(.*)$', f)
            if not m or m.group(1) not in t:
                continue
            c = t[m.group(1)]
            # Sections other than the verdicts (defunctionalisation's
            # specialisation post-pass: "Main.Defun1: specialised ...")
            skip = False
            blocks = 0
            for line in open(os.path.join(dirpath, f), errors='replace'):
                line = line.rstrip('\n')
                if line.startswith('===='):
                    skip = 'specialising' in line
                    if not skip:
                        blocks += 1
                        if blocks == 2:
                            # an early and a late run, or several passes
                            # (-fcore-webs-passes): webs are counted per block
                            c['repeated blocks'] += 1
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
    rep = [(c, p, ts[c][p]['repeated blocks']) for c in configs for p in PASSES if ts[c][p]['repeated blocks']]
    if rep:
        print('\nNote: dumps with more than one block (each web counted once per block): '
              + ', '.join('%s %s: %d files' % r for r in rep))
    for p in PASSES:
        keys = set()
        for c in configs:
            keys |= set(ts[c][p]) - {'webs', 'fired', 'repeated blocks'}
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
