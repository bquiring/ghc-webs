#!/usr/bin/env python3
"""Why lambda classes are exposed, summed over modules.

    python3 webs-bench/expo-report.py DIR [--top N]

reads every *.dump-webs-stats under DIR (nofib's results/CONFIG/dumps, or a
cabal build directory built with -ddump-to-file -ddump-webs-stats) and sums
the "Exposed lambda classes by: ORIGIN: n" lines (pprHiddenStats in
GHC.WebCore.Pipeline).  An origin is the imported Id, constructor or axiom
whose signature exposes the class, a kept binder, or an arrow without a
web; a class with several origins counts under each, and under "only by"
when it has one.  Prints the totals by kind of origin, then the top origins
and the modules of the imported ones."""
import argparse, collections, os, re

KINDS = ['imported', 'constructor arrows', 'constructor', 'axiom', 'kept binder',
         'an arrow without a web', '(unknown)']


def kind(origin):
    for k in KINDS:
        if origin.startswith(k):
            if k == 'constructor' and ' C:' in origin.replace('.C:', ' C:'):
                return 'constructor (class dictionary)'
            if k == 'axiom' and '.N:' in origin:
                return 'axiom (newtype)'
            return k
    return 'other'


def module_of(origin):
    """The module of an imported Id: 'imported A.B.f' -> 'A.B'"""
    name = origin.split(' ', 1)[1]
    m = re.match(r'((?:[A-Z][\w\']*\.)+)', name)
    return m.group(1)[:-1] if m else '?'


def read(d):
    t = collections.Counter()
    by, only = collections.Counter(), collections.Counter()
    for dirpath, _, files in os.walk(d):
        for f in files:
            if not f.endswith('.dump-webs-stats'):
                continue
            t['modules'] += 1
            for line in open(os.path.join(dirpath, f), errors='replace'):
                m = re.match(r'(Lambda classes|Internal lambda classes|Webs|Exposed webs): (\d+)$', line)
                if m:
                    t[m.group(1)] += int(m.group(2))
                m = re.match(r'Exposed lambda classes (by|only by): (.*): (\d+)$', line)
                if m:
                    (by if m.group(1) == 'by' else only)[m.group(2)] += int(m.group(3))
    return t, by, only


def table(title, rows, total):
    print('\n## %s\n' % title)
    print('| | classes | share of exposed |')
    print('|---|---|---|')
    for k, n in rows:
        print('| %s | %d | %.1f%% |' % (k, n, 100.0 * n / max(total, 1)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--top', type=int, default=25)
    a = ap.parse_args()
    t, by, only = read(a.dir)
    lams, internal = t['Lambda classes'], t['Internal lambda classes']
    exposed = lams - internal
    print('# Exposure: %s\n' % a.dir)
    print('%d modules; %d lambda classes, %d exposed (%.1f%%), %d internal.'
          % (t['modules'], lams, exposed, 100.0 * exposed / max(lams, 1), internal))
    for title, c in [('Exposed lambda classes by kind of origin (a class counts under each of its origins)', by),
                     ('... with only one origin', only)]:
        k = collections.Counter()
        for o, n in c.items():
            k[kind(o)] += n
        table(title, k.most_common(), exposed)
    table('Top origins', by.most_common(a.top), exposed)
    mods = collections.Counter()
    for o, n in by.items():
        if o.startswith('imported '):
            mods[module_of(o)] += n
    table('Modules of the imported origins', mods.most_common(a.top), exposed)


if __name__ == '__main__':
    main()
