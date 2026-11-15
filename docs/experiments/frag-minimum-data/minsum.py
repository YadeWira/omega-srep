#!/usr/bin/env python3
"""Summarize min-shift sweep: for each (corpus, method) zpaq best N and
default, osrep s1/s3/s4 best N and default, % against zpaq."""
import csv, glob, os, re, sys
from collections import defaultdict
Z = os.path.dirname(os.path.abspath(__file__))
res = defaultdict(dict)  # (corpus, m) -> {(kind, N): size}
for f in sorted(glob.glob(os.path.join(Z, "min-*.tsv"))):
    s = re.search(r"-s(\d)\.tsv$", f).group(1)
    for r in csv.DictReader(open(f), delimiter="\t"):
        if "config" in r:
            corpus, m = r["corpus"], r["method"]
            kind, n = r["config"].split(":")
            ok = r["extract"] == "ok"
        else:
            corpus, m, kind, n = r["input"], r["method"], r["fragmenter"], r["N"]
            ok = r.get("extract") == "ok"
        if not r["archive"].lstrip("-").isdigit():
            continue
        key = ("zpaq" if kind == "zpaq" else "s" + s, n)
        res[(corpus, m)][key] = int(r["archive"]) if ok else None
def pct(a, b): return "%+.1f%%" % (100.0 * (a - b) / b)
print("corpus\tm\tzpaq best\tzpaq d(6)\t" + "\t".join(
    f"s{s} best\ts{s} vs best\ts{s} d vs d" for s in (1, 3, 4)))
for (c, m), d in sorted(res.items()):
    z = {n: v for (k, n), v in d.items() if k == "zpaq" and v}
    if not z: continue
    zb_n = min(z, key=z.get); zb = z[zb_n]
    zd = z.get("6") or z.get("d")
    row = [c, m, f"{zb} (N={zb_n})", str(zd)]
    for s in (1, 3, 4):
        o = {n: v for (k, n), v in d.items() if k == f"s{s}" and v}
        if not o: row += ["-", "-", "-"]; continue
        ob_n = min(o, key=o.get)
        row += [f"{o[ob_n]} (N={ob_n})", pct(o[ob_n], zb),
                pct(o["d"], zd) if "d" in o and zd else "-"]
    print("\t".join(row))
