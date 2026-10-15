#!/usr/bin/env python3
"""A convex webs chunk of a hadrian package (Note [Chunks] in GHC.WebCore.Chunk).

    chunk-convex.py DEPENDENCIES BUILDDIR SEED-MODULE... > MODULES

DEPENDENCIES is hadrian's .dependencies file of the package (lines
"OBJ SRC DEP..."), BUILDDIR its build directory (the prefix of its objects).
The seed modules, plus every module on an import path between two of them,
so that no module outside the chunk imports one of the chunk and is
imported by one: hadrian builds the modules outside the chunk one by one,
before (imported by the chunk) or after it.  An {-# SOURCE #-} import is
no edge: hadrian builds the hs-boot interface first.  A seed ending in '.'
is a prefix: every module under it.
"""
import sys

deps_file, build, seeds = sys.argv[1], sys.argv[2].rstrip('/') + '/', sys.argv[3:]

def mod(path, ext):
    return path[len(build):-len(ext)].replace('/', '.')

imports = {}
for line in open(deps_file):
    ws = line.split()
    if not ws or not ws[0].startswith(build):
        continue
    if not ws[0].endswith('.o'):
        continue
    m = mod(ws[0], '.o')
    imports[m] = {mod(d, '.hi') for d in ws[1:] if d.startswith(build) and d.endswith('.hi')}

chunk = set()
for s in seeds:
    if s.endswith('.'):
        chunk |= {m for m in imports if m.startswith(s)}
    elif s in imports:
        chunk.add(s)
    else:
        sys.exit('chunk-convex.py: no module ' + s)

def closure(start, edges):
    seen, todo = set(), list(start)
    while todo:
        m = todo.pop()
        for n in edges.get(m, ()):
            if n not in seen:
                seen.add(n)
                todo.append(n)
    return seen

importers = {}
for m, ns in imports.items():
    for n in ns:
        importers.setdefault(n, set()).add(m)
# Below some chunk module and above some: on a path between two
chunk |= closure(chunk, imports) & closure(chunk, importers)
print('\n'.join(sorted(chunk)))
print(len(chunk), 'modules', file=sys.stderr)
