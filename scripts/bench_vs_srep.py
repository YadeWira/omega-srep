#!/usr/bin/env python3
"""Baseline benchmark: OSREP vs SREP on the same input.

    scripts/bench_vs_srep.py --osrep build/osrep --srep /path/to/srep64 \
        --input FILE [--input FILE...] [--runs N] [--outdir DIR]

Prints one TSV line per (input, tool, settings) with the output size and the
median wall time. It does not decode or verify; it measures the preprocessor
stream and the time to write it. SREP 3.92 needs -c to be a power of two >= 2;
the l64c64/l128c128 rows keep the comparison valid.
"""
import argparse
import os
import statistics
import subprocess
import sys
import tempfile
import time

CASES = [
    ("osrep", "default", ["-m3"]),
    ("osrep", "l64c64", ["-m3", "-l64", "-c64"]),
    ("osrep", "l128c128", ["-m3", "-l128", "-c128"]),
    ("srep", "default", ["-m3"]),
    ("srep", "l64c64", ["-m3", "-l64", "-c64"]),
    ("srep", "l128c128", ["-m3", "-l128", "-c128"]),
    ("srep", "m4-l64c64", ["-m4", "-l64", "-c64"]),
    ("srep", "m5-l64c64", ["-m5", "-l64", "-c64"]),
    ("omega", "default", ["-m3"]),
    ("omega", "l64c64", ["-m3", "-l64", "-c64"]),
    ("omega", "m4-l64c64", ["-m4", "-l64", "-c64"]),
    ("omega", "m5-l64c64", ["-m5", "-l64", "-c64"]),
]


def run_one(cmd, out_path):
    start = time.perf_counter()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    elapsed = time.perf_counter() - start
    size = os.path.getsize(out_path) if os.path.exists(out_path) else -1
    return p.returncode, size, elapsed, p.stderr.decode("utf-8", "replace").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--osrep", required=True)
    ap.add_argument("--srep", required=True)
    ap.add_argument("--omega", default=None, help="Omega SREP 3.0.0 binary (optional)")
    ap.add_argument("--input", action="append", required=True)
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    outdir = a.outdir or tempfile.mkdtemp(prefix="osrep-bench-")
    os.makedirs(outdir, exist_ok=True)
    bins = {"osrep": a.osrep, "srep": a.srep}
    if a.omega:
        bins["omega"] = a.omega
    print("input\ttool\tsettings\tinput_size\toutput_size\tratio\ttime_s\trc")
    for inp in a.input:
        in_size = os.path.getsize(inp)
        for tool, label, args in CASES:
            if tool not in bins:
                continue
            outs = []
            times = []
            rcs = []
            err = ""
            for i in range(a.runs):
                out = os.path.join(outdir, f"{os.path.basename(inp)}.{tool}.{label}.{i}.out")
                cmd = [bins[tool]] + args + [inp, out]
                rc, size, elapsed, msg = run_one(cmd, out)
                rcs.append(rc)
                times.append(elapsed)
                outs.append(size)
                if msg:
                    err = msg
            size = outs[0] if outs else -1
            ratio = (size / in_size * 100.0) if size >= 0 and in_size else -1
            print(f"{inp}\t{tool}\t{label}\t{in_size}\t{size}\t{ratio:.4f}\t"
                  f"{statistics.median(times):.3f}\t{rcs[0]}")
            if err and rcs[0] != 0:
                print(f"# {tool} {label}: {err.splitlines()[-1]}", file=sys.stderr)
            for i, out in enumerate(outs):
                try:
                    os.remove(os.path.join(outdir, f"{os.path.basename(inp)}.{tool}.{label}.{i}.out"))
                except OSError:
                    pass


if __name__ == "__main__":
    main()
