#!/usr/bin/env python3
"""Choose webs chunks of a hadrian package from its modules' types
(WEBS-CHUNKS.md section 3.5, "From types").

    chunk-graph.py DEPENDENCIES BUILDDIR GHC OUTDIR [--max-bytes N]
                   [--max-modules N] [--max-module-bytes N] [--min-weight W]

DEPENDENCIES is hadrian's .dependencies file of the package, BUILDDIR its
build directory (with the interfaces of a build), GHC a compiler that reads
them (--show-iface).  Writes OUTDIR/chunkN.modules (one module per line)
and OUTDIR/chunks.txt (a summary).

The graph: a node per module, weighted by its source size; an edge joins a
module to each module of the package it uses names from (the interface's
usages), weighted by what exposing those names costs the webs:

  * a value: the arrows nested in its type (function arguments and
    results; the arrows of its own arity are free: a first-order
    Int -> Int weighs nothing), its class constraints (dictionaries), and
    one for each type of the package in its type whose fields hold a
    function (a monad like SimplM, a record of functions);
  * a type, constructor or field: one if the type's fields hold a function.

Chunking: greedily, heaviest edge first, merge the two groups and every
group on an import path between them (a chunk must be convex: hadrian
builds a module outside a chunk either before or after it; this also keeps
the graph of chunks acyclic), unless the result exceeds the size bounds.
{-# SOURCE #-} imports are no edges.  Modules larger than
--max-module-bytes stay out of chunks.
"""
import argparse, heapq, os, re, subprocess, sys
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument('deps'); ap.add_argument('build'); ap.add_argument('ghc'); ap.add_argument('out')
ap.add_argument('--max-bytes', type=int, default=300000)
ap.add_argument('--max-modules', type=int, default=40)
ap.add_argument('--max-module-bytes', type=int, default=100000)
ap.add_argument('--min-weight', type=float, default=1.0)
ap.add_argument('--package', default='ghc')
a = ap.parse_args()

build = a.build.rstrip('/') + '/'

def mod(path, ext):
    return path[len(build):-len(ext)].replace('/', '.')

# --- the import graph and the sources
imports, src = {}, {}
for line in open(a.deps):
    ws = line.split()
    if len(ws) < 2 or not ws[0].startswith(build) or not ws[0].endswith('.o'):
        continue
    m = mod(ws[0], '.o')
    src[m] = ws[1]
    imports[m] = {mod(d, '.hi') for d in ws[2:] if d.startswith(build) and d.endswith('.hi')}
mods = sorted(imports)
size = {m: os.path.getsize(src[m]) if os.path.exists(src[m]) else 0 for m in mods}

# --- interfaces
HEX = re.compile(r'^[0-9a-f]{32}$')
IMPORT = re.compile(r'^\s*import\s+-/\s+(\S+)\s+[0-9a-f]{32}')
ENTITY = re.compile(r'^\s{13}(\S+) [0-9a-f]{32},?\]?$')

def iface(m):
    hi = build + m.replace('.', '/') + '.hi'
    r = subprocess.run([a.ghc, '--show-iface', hi], capture_output=True, text=True)
    return r.stdout.splitlines()

def nested_arrows(t):
    """Arrows inside parentheses, brackets or braces, and constraints"""
    depth, n = 0, 0
    i = 0
    while i < len(t):
        c = t[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif t.startswith('->', i):
            if depth > 0:
                n += 1
            i += 1
        elif t.startswith('=>', i):
            n += 1
            i += 1
        i += 1
    return n

uses = {}          # module -> {defining module -> [names]}
values = {}        # (module, name) -> type text
tycons = {}        # (module, name) -> has a function field
owner = {}         # (module, constructor or field name) -> type name
for m in mods:
    lines = iface(m)
    u = defaultdict(list)
    cur = None
    in_usages = False
    for ln in lines:
        if ln.startswith('  usages:'):
            in_usages = True
        if in_usages:
            mi = IMPORT.match(ln.replace('usages: [', '         ', 1))
            if mi:
                pkg, _, mname = mi.group(1).rpartition(':')
                cur = mname if pkg.startswith(a.package + '-') else None
                continue
            me = ENTITY.match(ln)
            if me and cur is not None:
                u[cur].append(me.group(1))
                continue
            if not ln.startswith(' '):
                in_usages = False
    uses[m] = u
    # declarations: blocks after a fingerprint line
    blocks, blk = [], None
    for ln in lines:
        if HEX.match(ln):
            if blk:
                blocks.append(blk)
            blk = []
        elif blk is not None:
            if ln and not ln.startswith(' '):
                blocks.append(blk); blk = None
            else:
                blk.append(ln)
    if blk:
        blocks.append(blk)
    for b in blocks:
        text = '\n'.join(b)
        hd = [l for l in b if not l.strip().startswith('type ') or ' = ' in l]
        if not hd:
            continue
        first = hd[0].strip()
        dm = re.match(r'(?:data|newtype)\s+(?:\([^)]*\)\s*=>\s*)?(\S+)', first)
        if dm:
            name = dm.group(1)
            body = text[text.find(first) + len(first):]
            # constructors and fields
            for c in re.findall(r'(?:=|\|)\s+(\S+?)[\s{]', body):
                owner[(m, c)] = name
            for f in re.findall(r'(\w[\w\']*) ::', body):
                owner[(m, f)] = name
            tycons[(m, name)] = '->' in body
            continue
        vm = re.match(r'(\S+) ::(.*)', first)
        if vm:
            # the type: up to the IdInfo ([...]) or the unfolding
            # (continuation lines are indented further than the name)
            ty = [vm.group(2)]
            for l in b[1:]:
                s = l.strip()
                if len(l) - len(l.lstrip()) <= 2 or s.startswith('[') or s.startswith('{-'):
                    break
                ty.append(s)
            values[(m, vm.group(1))] = ' '.join(ty)

QUAL = re.compile(r'\b((?:[A-Z]\w*\.)+)([A-Z]\w*)')
UNQ = re.compile(r'(?<![\w.])([A-Z]\w*)')

def fun_types(m, ty):
    n = 0
    for q, t in QUAL.findall(ty):
        if tycons.get((q[:-1], t)):
            n += 1
    for t in UNQ.findall(ty):
        if tycons.get((m, t)):
            n += 1
    return n

def weight(d, name):
    if (d, name) in values:
        ty = values[(d, name)]
        return nested_arrows(ty) + fun_types(d, ty)
    t = owner.get((d, name), name)
    return 1 if tycons.get((d, t)) else 0

# A module that defines no values (a re-export module, like GHC.Plugins)
# has no code whose calls the chunk would change
has_code = {d for (d, n) in values if not n.startswith('$tr')}
w = defaultdict(float)     # undirected: frozenset -> weight
for m, u in uses.items():
    if m not in has_code:
        continue
    for d, names in u.items():
        if d == m or d not in imports:
            continue
        x = sum(weight(d, n) for n in names)
        if x > 0:
            w[frozenset((m, d))] += x
total = sum(w.values())
if os.environ.get('CHUNK_GRAPH_DEBUG'):
    for e, x in sorted(w.items(), key=lambda kv: -kv[1])[:25]:
        print('edge %.0f %s' % (x, ' '.join(sorted(e))), file=sys.stderr)
    ws_ = sorted(((weight(d, n), d, n) for m, u in uses.items() for d, ns in u.items() for n in ns if d in imports),
                 reverse=True)
    seen_ = set()
    for x, d, n in ws_:
        if (d, n) in seen_: continue
        seen_.add((d, n))
        if len(seen_) > 25: break
        print('name %d %s.%s :: %s' % (x, d, n, values.get((d, n), '(type)')[:150]), file=sys.stderr)

# --- greedy convex merging
group = {m: m for m in mods}          # module -> group id
members = {m: {m} for m in mods}
gsize = {m: size[m] for m in mods}
gimports = {m: set(imports[m]) for m in mods}   # group -> groups it imports
def g_of(x): return group[x]
def importers_of():
    r = defaultdict(set)
    for g, gs in gimports.items():
        for h in gs:
            r[h].add(g)
    return r

def closure(start, edges):
    seen, todo = set(start), list(start)
    while todo:
        x = todo.pop()
        for y in edges.get(x, ()):
            if y not in seen:
                seen.add(y); todo.append(y)
    return seen

big = {m for m in mods if size[m] > a.max_module_bytes}
heap = [(-x, sorted(e)) for e, x in w.items() if x >= a.min_weight]
heapq.heapify(heap)
merges = 0
while heap:
    negx, (p, q) = heapq.heappop(heap)
    gp, gq = g_of(p), g_of(q)
    if gp == gq or p in big or q in big:
        continue
    imps = {g: s for g, s in gimports.items()}
    impd = importers_of()
    down = closure([gp, gq], imps)
    up = closure([gp, gq], impd)
    between = (down & up) | {gp, gq}
    if any(m in big for g in between for m in members[g]):
        continue
    nb = sum(gsize[g] for g in between)
    nm = sum(len(members[g]) for g in between)
    if nb > a.max_bytes or nm > a.max_modules:
        continue
    new = min(between)
    ms = set().union(*(members[g] for g in between))
    gi = set().union(*(gimports[g] for g in between)) - between
    for g in between:
        del members[g], gsize[g], gimports[g]
    members[new] = ms; gsize[new] = nb; gimports[new] = gi
    for g in list(gimports):
        if gimports[g] & between:
            gimports[g] = (gimports[g] - between) | {new}
    for x in ms:
        group[x] = new
    merges += 1

chunks = sorted([sorted(ms) for ms in members.values() if len(ms) > 1], key=lambda c: -len(c))
cut = sum(x for e, x in w.items() if len({group[y] for y in e}) > 1)
os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, 'chunks.txt'), 'w') as f:
    f.write('modules %d, edges %d, weight %.0f; cut by chunks %.0f (%.1f%%); chunks %d covering %d modules\n'
            % (len(mods), len(w), total, cut, 100 * cut / max(total, 1), len(chunks), sum(map(len, chunks))))
    for i, c in enumerate(chunks):
        inner = sum(x for e, x in w.items() if all(group[y] == group[c[0]] for y in e))
        f.write('chunk%d: %d modules, %d bytes, internal weight %.0f: %s\n'
                % (i, len(c), sum(size[m] for m in c), inner, ' '.join(c)))
for i, c in enumerate(chunks):
    with open(os.path.join(a.out, 'chunk%d.modules' % i), 'w') as f:
        f.write('\n'.join(c) + '\n')
print(open(os.path.join(a.out, 'chunks.txt')).readline().rstrip(), file=sys.stderr)
