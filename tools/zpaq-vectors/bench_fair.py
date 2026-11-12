#!/usr/bin/env python3
"""Fair comparison of the two fragmenters at the same -fragment N.

zpaq-std's own fragmenter (the baseline binary, or the patched one without
-osrep) against -osrep, both at -fragment N, so the gain of OSREP's CDC is
measured apart from the gain of a smaller fragment.

    tools/zpaq-vectors/bench_fair.py --baseline BASE --patched PATCHED \
        --input versions.tar --input pja.tar --method=-m1 --method=-m5 \
        --fragments 6,5,3 --workdir DIR

Both fragmenters average 2^N KiB at -fragment N (the mapping -osrep has
since 2026-11-12), so the default --osrep-shift 0 compares them at the same
average size. --osrep-shift K runs -osrep at -fragment N+K instead (K=3 was
needed with the old -osrep mapping, 2^(N-3) KiB). A fragment "d" runs both
without -fragment: zpaq's default N=6 against -osrep's N=3. --extra passes
more switches to every add (e.g. --extra=-threads --extra=4).

Prints one TSV line per case: archive size, wall time, peak RSS, and whether
the baseline extracts the archive to the original bytes. One run each.
"""
import argparse
import filecmp
import os
import shutil
import sys
import time

FIX = ["-touch", "20240101000000", "-timestamp", "2024-01-01_00:00:00"]


def run(argv):
    pid = os.fork()
    if pid == 0:
        dn = os.open("/dev/null", os.O_WRONLY)
        os.dup2(dn, 1)
        os.dup2(dn, 2)
        os.execv(argv[0], argv)
        os._exit(127)
    start = time.perf_counter()
    _, status, usage = os.wait4(pid, 0)
    return (os.waitstatus_to_exitcode(status), time.perf_counter() - start,
            usage.ru_maxrss // 1024)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--patched", required=True)
    ap.add_argument("--input", action="append", required=True)
    ap.add_argument("--method", action="append", default=None)
    ap.add_argument("--fragments", default="6,5,3")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--osrep-shift", type=int, default=0)
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()
    methods = a.method or ["-m1", "-m5"]
    os.makedirs(a.workdir, exist_ok=True)
    arc = os.path.join(a.workdir, "a.zpaq")
    xdir = os.path.join(a.workdir, "x")
    print("input\tmethod\tfragmenter\tN\tarchive\twall_s\trss_mb\textract")
    for inp in a.input:
        inp = os.path.abspath(inp)
        for m in methods:
            for n in a.fragments.split(","):
                for kind in ("zpaq", "osrep"):
                    binary = a.baseline if kind == "zpaq" else a.patched
                    extra = ["-osrep"] if kind == "osrep" else []
                    if n == "d":
                        nn, frag = "d", []
                    else:
                        nn = int(n) + a.osrep_shift if kind == "osrep" else int(n)
                        frag = ["-fragment", str(nn)]
                    if os.path.exists(arc):
                        os.remove(arc)
                    rc, wall, rss = run([binary, "a", arc, inp, m] + frag +
                                        extra + a.extra + FIX)
                    if rc != 0:
                        print(f"{os.path.basename(inp)}\t{m}\t{kind}\t{nn}\t"
                              f"FAILED rc={rc}", flush=True)
                        continue
                    size = os.path.getsize(arc)
                    shutil.rmtree(xdir, ignore_errors=True)
                    xrc, _, _ = run([a.baseline, "x", arc, "-to", xdir])
                    out = xdir + inp
                    ok = (xrc == 0 and os.path.exists(out)
                          and filecmp.cmp(inp, out, shallow=False))
                    print(f"{os.path.basename(inp)}\t{m}\t{kind}\t{nn}\t{size}\t"
                          f"{wall:.2f}\t{rss}\t{'ok' if ok else 'FAIL'}",
                          flush=True)
    shutil.rmtree(xdir, ignore_errors=True)
    if os.path.exists(arc):
        os.remove(arc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
