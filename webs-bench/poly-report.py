#!/usr/bin/env python3
"""Summarise function-level polymorphism over nofib (Note [Polymorphism
statistics] in GHC.WebCore.PolyStats).

    python3 webs-bench/poly-report.py CONFIG...

Reads webs-bench/results/CONFIG/dumps/**/*.dump-first-class-stats: the
"poly-stats after" line of each module, and its "poly-param" lines."""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent / "results"
CLASSES = ["exported", "escaping", "unused", "constant", "open", "shape", "variable", "other_kind"]


def read(config):
    totals = collections.Counter()
    params = []  # (benchmark, module, kind, binder, index, type, n)
    per_bench = collections.defaultdict(collections.Counter)
    modules = 0
    for f in sorted((ROOT / config / "dumps").rglob("*.dump-first-class-stats")):
        bench = str(f.parent.relative_to(ROOT / config / "dumps"))
        module = f.name.split(".dump-")[0]
        lines = []
        for line in f.read_text(errors="replace").splitlines():
            # pretty-printed types continue on indented lines
            if lines and line.startswith(" ") and lines[-1].startswith("poly-param"):
                lines[-1] += " " + line.strip()
            else:
                lines.append(line)
        for line in lines:
            if line.startswith("poly-stats after"):
                modules += 1
                for k, v in re.findall(r"(\w+)=(\d+)", line):
                    totals[k] += int(v)
                    per_bench[bench][k] += int(v)
            elif line.startswith("poly-param"):
                m = re.match(r"poly-param (\w+) (.*?) #(\d+): (.*), over (\d+) instantiations", line)
                if m:
                    kind, binder, i, ty, n = m.groups()
                    params.append((bench, module, kind, binder, int(i), ty, int(n)))
    return modules, totals, params, per_bench


def clean(s):
    """Drop uniques and module qualifiers, for readability"""
    s = re.sub(r"_[A-Za-z0-9]{2,6}\b", "", s)
    s = re.sub(r"\b(?:[A-Z][A-Za-z0-9]*\.)+(?=[A-Za-z(\[])", "", s)
    return s


def head_of(ty):
    ty = ty.strip()
    if ty.startswith("("):
        return "tuple" if "," in ty else "parenthesised"
    if ty.startswith("["):
        return "list"
    if "->" in ty:
        return "function"
    return ty.split()[0]


def main(configs):
    for config in configs:
        modules, t, params, per_bench = read(config)
        print(f"# {config}\n")
        print(f"{modules} modules. Polymorphic bindings: {t['poly_binds']} "
              f"({t['poly_top']} top-level, {t['poly_local']} local; {t['poly_exported']} exported; "
              f"{t['overloaded']} with dictionary parameters). Type lambdas not at the top of a "
              f"binding: {t['inner_tylams']}.\n")
        n = t["ty_params"] or 1
        print("| type parameters | count | share |")
        print("|---|---|---|")
        print(f"| all | {t['ty_params']} | 100% |")
        for c in CLASSES:
            print(f"| {c} | {t[c]} | {100 * t[c] / n:.1f}% |")
        apps = sum(t[k] for k in ["tyapp_local", "tyapp_imported", "tyapp_datacon", "tyapp_other"]) or 1
        print("\n| type applications, by head | count | share |")
        print("|---|---|---|")
        for k in ["tyapp_local", "tyapp_imported", "tyapp_datacon", "tyapp_other"]:
            print(f"| {k[len('tyapp_'):]} | {t[k]} | {100 * t[k] / apps:.1f}% |")

        for kind in ["shape", "constant", "open"]:
            ps = [p for p in params if p[2] == kind]
            print(f"\n## {kind}: {len(ps)} parameters\n")
            heads = collections.Counter(head_of(clean(p[5])) for p in ps)
            print("By the head of the type: " + ", ".join(f"{h} {c}" for h, c in heads.most_common(12)) + "\n")
            benches = collections.Counter(p[0] for p in ps)
            print("By benchmark: " + ", ".join(f"{b} {c}" for b, c in benches.most_common(15)) + "\n")
            if kind == "shape":
                print("Examples (binder, parameter, anti-unifier, instantiations):\n")
                for p in sorted(ps, key=lambda p: -p[6])[:40]:
                    print(f"- {p[0]} {p[1]}: `{clean(p[3])}` #{p[4]}: `{clean(p[5])}`, {p[6]}")
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
