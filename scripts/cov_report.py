#!/usr/bin/env python3
"""Merge Verilator --coverage-user files and report functional coverage.

Covergroup bins and SVA cover properties both land in coverage.dat. This
sums hit counts across runs, then reports per covergroup and per
coverpoint/cross, lists every bin still at zero, and lists every cover
property with its hit count.

usage: cov_report.py [--md OUT.md] file.dat [file.dat ...]
"""
import argparse
import collections
import re
import sys


def parse(path, acc):
    with open(path, encoding="latin1") as f:
        next(f, None)
        for line in f:
            if not line.startswith("C '"):
                continue
            q = line.rindex("'")
            key, cnt = line[3:q], int(line[q + 1:].strip() or 0)
            d = dict(p.split("\x02", 1) for p in key.split("\x01") if "\x02" in p)
            acc[(d.get("t"), d.get("h"), d.get("o", ""))] += cnt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()

    acc = collections.Counter()
    for p in a.files:
        parse(p, acc)

    groups = collections.OrderedDict()   # cg -> point -> [(bin, cnt)]
    covers = []
    for (t, h, o), c in sorted(acc.items(), key=lambda kv: str(kv[0])):
        if t == "covergroup":
            # newer Verilator: pkg::class::cg.point.bin ; 5.050: __vlAnonCG_cg.point.bin
            m = re.match(r"(?:.*::)?(?:__vlAnonCG_)?(\w+?)\.(\w+)\.(.+)$", h)
            if not m:
                continue
            cg, pt, b = m.groups()
            groups.setdefault(cg, collections.OrderedDict()).setdefault(pt, []).append((b, c))
        elif t == "user":
            name = re.sub(r"__BRA__\*__KET____DOT__", "[*].", h.split(".", 2)[-1])
            covers.append((name, c))

    out = []
    out.append(f"Merged {len(a.files)} coverage file(s)\n")
    out.append("| Covergroup | Bins hit | Coverage |")
    out.append("|---|---:|---:|")
    total_hit = total = 0
    holes = []
    for cg, pts in groups.items():
        h = sum(1 for bins in pts.values() for _, c in bins if c > 0)
        n = sum(len(bins) for bins in pts.values())
        total_hit += h
        total += n
        out.append(f"| {cg} | {h}/{n} | {100.0 * h / n:.1f}% |")
        for pt, bins in pts.items():
            for b, c in bins:
                if c == 0:
                    holes.append(f"{cg}.{pt}.{b}")
    out.append(f"| **all** | **{total_hit}/{total}** | **{100.0 * total_hit / max(total, 1):.1f}%** |")
    out.append("")
    out.append("| Cover property | Hits |")
    out.append("|---|---:|")
    for name, c in covers:
        out.append(f"| {name} | {c} |")
    out.append("")
    out.append("Unhit bins: " + (", ".join(holes) if holes else "none"))
    text = "\n".join(out)
    print(text)
    if a.md:
        with open(a.md, "w") as f:
            f.write(text + "\n")
    zero_covers = [n for n, c in covers if c == 0]
    return 0 if not holes and not zero_covers else 1


if __name__ == "__main__":
    sys.exit(main())
