#!/usr/bin/env python3
"""Exported values that no other module uses, for -fcore-webs-unused-exports
(Note [Unused exports] in GHC.WebCore.Pipeline).

    python3 webs-bench/unused-exports.py GHC DIR[,DIR..] [--out FILE] [--keep-module M ...]
        [--warnings LOG] [--chunk-modules FILE]

Reads every interface (*.hi) under DIR with GHC --show-iface: the usages of
each module name every entity it uses from the other modules of its package
(of other packages, only the module, so DIR must hold one package, and the
modules other packages import must be named with --keep-module).  Writes
FILE (default DIR/webs-unused.txt): "Module occurrence" for each exported
value (not a constructor, field, or class method) that no other module of
DIR uses.  A function named main is never listed.  A name that an import
list names but nothing uses is still used: removing it from the exports
would break the import, and so is every export of a module whose whole
import is redundant (--warnings LOG, a file of -Wunused-imports
warnings from the first build)."""
import argparse, collections, os, re, subprocess, sys


def iface(ghc, path):
    r = subprocess.run([ghc, '--show-iface', path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('%s --show-iface %s failed:\n%s' % (ghc, path, r.stderr[-400:]))
    return r.stdout


def parse(txt):
    m = re.search(r'^interface (\S+)', txt, re.M)
    mod = m.group(1)
    vals = []
    ex = re.search(r'^exports:\n(.*?)^\S', txt, re.M | re.S)
    for line in (ex.group(1).splitlines() if ex else []):
        name = line.strip().split('{')[0].split('|')[0].strip()
        # values: lower-case names and operators other than constructor operators
        if name and (name[0].islower() or name[0] == '_' or not (name[0].isalpha() or name[0] == ':')):
            # an imported entity re-exported is qualified (M.f): not ours
            if '.' in name.rstrip('.') and name[0].isalpha():
                continue
            vals.append(name)
    used = collections.defaultdict(set)
    # the usages end at the orphan hash (the last entry ends with ']')
    us = re.search(r'usages: \[(.*?)\n\s*orphan hash:', txt, re.S)
    cur = None
    for line in (us.group(1).splitlines() if us else []):
        mm = re.match(r'\s*import\s+\S+\s+(?:[^\s:]+:)?(\S+) [0-9a-f]{32}', line)
        if mm:
            cur = mm.group(1)
            continue
        mm = re.match(r'\s+(\S+) [0-9a-f]{32}[,\]]?$', line)
        if mm and cur and cur != mod:
            used[cur].add(mm.group(1))
    return mod, vals, used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ghc')
    ap.add_argument('dir')
    ap.add_argument('--out')
    ap.add_argument('--keep-module', action='append', default=[])
    ap.add_argument('--warnings')
    # a chunk (Note [Chunks] in GHC.WebCore.Chunk): only the uses by
    # modules outside it count, and only its modules are listed
    ap.add_argument('--chunk-modules')
    # names other packages use (from -ddump-minimal-imports: their
    # interfaces name only the modules), used in every module
    ap.add_argument('--used-names')
    a = ap.parse_args()
    chunk = set(open(a.chunk_modules).read().split()) if a.chunk_modules else None
    his = sorted(os.path.join(r, f) for d in a.dir.split(',') for r, _, fs in os.walk(d)
                 for f in fs if f.endswith('.hi'))
    exports = {}
    used = collections.defaultdict(set)
    for h in his:
        mod, vals, u = parse(iface(a.ghc, h))
        exports[mod] = vals
        if chunk is not None and mod in chunk:
            continue
        for m, ns in u.items():
            used[m] |= ns
    # "The import of ‘a, b’ from module ‘M’ is redundant" (possibly wrapped)
    if a.warnings and os.path.exists(a.warnings):
        txt = ' '.join(open(a.warnings, errors='replace').read().split())
        for names, mod in re.findall(r'The import of \u2018(.*?)\u2019 from module \u2018(\S+?)\u2019 is redundant', txt):
            for n in names.split(','):
                n = n.strip().split('(')[0].strip() if not n.strip().startswith('(') else n.strip()[1:].split(')')[0]
                used[mod].add(n)
        # a whole import redundant ("The import of ‘M’ is redundant"): the
        # warning does not name its import list, so all of M is used
        whole = set(re.findall(r'The import of \u2018([A-Z][\w.]*)\u2019 is redundant', txt))
    else:
        whole = set()
    extra = set(open(a.used_names).read().split()) if a.used_names else set()
    out = a.out or os.path.join(a.dir.split(',')[0], 'webs-unused.txt')
    lines = []
    for mod in sorted(exports):
        if mod in a.keep_module or mod in whole or (chunk is not None and mod not in chunk):
            continue
        lines += ['%s %s' % (mod, v) for v in exports[mod]
                  if v != 'main' and v not in used[mod] and v not in extra]
    with open(out, 'w') as f:
        f.write(''.join(l + '\n' for l in lines))
    print('%s: %d modules, %d exported values, %d unused' %
          (a.dir, len(exports), sum(len(v) for v in exports.values()), len(lines)))


if __name__ == '__main__':
    main()
