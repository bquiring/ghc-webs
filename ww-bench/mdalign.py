#!/usr/bin/env python3
"""Align the columns of the markdown tables in a text, so that they read well
as plain text: cells padded to the column width, numbers right-aligned.

    ww-bench/mdalign.py FILE...     (rewrites the files in place)
"""
import re, sys

NUM = re.compile(r'^[-+]?[\d,]+(\.\d+)?%?( \(.*\))?$|^[-+]?\d[\d,]*( / [-+]?\d[\d,]*)+$')

def is_row(line):
    s = line.strip()
    return s.startswith('|') and s.endswith('|') and len(s) > 1

def cells(line):
    return [c.strip() for c in line.strip()[1:-1].split('|')]

def is_rule(cs):
    return all(re.fullmatch(r':?-{1,}:?', c) for c in cs)

def align_table(rows):
    parsed = [cells(r) for r in rows]
    n = max(len(r) for r in parsed)
    parsed = [r + [''] * (n - len(r)) for r in parsed]
    body = [r for r in parsed if not is_rule(r)]
    width = [max(3, max(len(r[i]) for r in body)) for i in range(n)]
    # A column is numeric if all its non-header, non-empty cells are numbers
    numeric = [all(NUM.match(r[i]) for r in body[1:] if r[i]) and any(r[i] for r in body[1:])
               for i in range(n)]
    out = []
    for r in parsed:
        if is_rule(r):
            out.append('|' + '|'.join(('-' * (width[i] + 1) + ':') if numeric[i] else ('-' * (width[i] + 2))
                                      for i in range(n)) + '|')
        else:
            out.append('| ' + ' | '.join((r[i].rjust(width[i]) if numeric[i] and r is not parsed[0]
                                          else r[i].ljust(width[i])) for i in range(n)) + ' |')
    return out

def align_text(text):
    lines = text.split('\n')
    out, table = [], []
    for line in lines + ['']:
        if is_row(line):
            table.append(line)
            continue
        if table:
            out.extend(align_table(table))
            table = []
        out.append(line)
    return '\n'.join(out[:-1])

if __name__ == '__main__':
    for f in sys.argv[1:]:
        t = open(f).read()
        open(f, 'w').write(align_text(t))
