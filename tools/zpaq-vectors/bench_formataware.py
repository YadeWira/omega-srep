#!/usr/bin/env python3
"""Experiment 3: format-aware cuts in zpaq-std -osrep (EXPERIMENTAL).

zpaq's own fragmenter (the baseline binary) against -osrep with and without
format-aware cuts, all at the same -fragment N (2^N KiB on average for both).
The patched binary reads the OSREP_FRAG_FLAGS environment variable (a
prototype hook; see docs/experiments/frag-formataware.md).

    tools/zpaq-vectors/bench_formataware.py --baseline BASE --patched PATCHED \
        --input versions.tar --input DIR --method=-m1 --fragments 3,6 \
        --flags 0,3,12,15 --repeat 1 --workdir WORK [--threads-check]

Prints one TSV line per case: archive size, median wall time, peak RSS, and
whether the baseline extracts the archive to the original bytes. With
--threads-check every -osrep archive is built again with -t1 and must be
byte-identical.
"""
import argparse
import filecmp
import os
import shutil
import statistics
import subprocess
import sys
import time

FIX = ["-touch", "20240101000000", "-timestamp", "2024-01-01_00:00:00"]


def run(argv, env=None):
    pid = os.fork()
    if pid == 0:
        dn = os.open("/dev/null", os.O_WRONLY)
        os.dup2(dn, 1)
        os.dup2(dn, 2)
        os.execve(argv[0], argv, env if env is not None else os.environ)
        os._exit(127)
    start = time.perf_counter()
    _, status, usage = os.wait4(pid, 0)
    return (os.waitstatus_to_exitcode(status), time.perf_counter() - start,
            usage.ru_maxrss // 1024)


def same_tree(src, out):
    if os.path.isfile(src):
        return os.path.isfile(out) and filecmp.cmp(src, out, shallow=False)
    r = subprocess.run(["diff", "-rq", src, out], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--patched", required=True)
    ap.add_argument("--input", action="append", required=True)
    ap.add_argument("--method", action="append", default=None)
    ap.add_argument("--fragments", default="3,6")
    ap.add_argument("--flags", default="0,3,12,15")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--no-zpaq", action="store_true")
    ap.add_argument("--threads-check", action="store_true")
    ap.add_argument("--workdir", required=True)
    a = ap.parse_args()
    methods = a.method or ["-m1"]
    os.makedirs(a.workdir, exist_ok=True)
    arc = os.path.join(a.workdir, "a.zpaq")
    arc1 = os.path.join(a.workdir, "t1.zpaq")
    xdir = os.path.join(a.workdir, "x")
    print("input\tmethod\tfragmenter\tN\tflags\tarchive\twall_s\trss_mb\t"
          "extract\tt1", flush=True)
    for inp in a.input:
        inp = os.path.abspath(inp)
        for m in methods:
            for n in [int(x) for x in a.fragments.split(",")]:
                cases = [] if a.no_zpaq else [("zpaq", None)]
                cases += [("osrep", int(f, 0)) for f in a.flags.split(",")]
                for kind, flags in cases:
                    binary = a.baseline if kind == "zpaq" else a.patched
                    extra = ["-osrep"] if kind == "osrep" else []
                    env = dict(os.environ)
                    env.pop("OSREP_FRAG_FLAGS", None)
                    if flags:
                        env["OSREP_FRAG_FLAGS"] = str(flags)
                    argv = [binary, "a", arc, inp, m, "-fragment", str(n)] + \
                        extra + FIX
                    walls, rsss, sizes, bad = [], [], set(), False
                    for _ in range(a.repeat):
                        if os.path.exists(arc):
                            os.remove(arc)
                        rc, wall, rss = run(argv, env)
                        if rc != 0:
                            bad = True
                            break
                        walls.append(wall)
                        rsss.append(rss)
                        sizes.add(os.path.getsize(arc))
                    label = f"{os.path.basename(inp)}\t{m}\t{kind}\t{n}\t" \
                        f"{'-' if flags is None else flags}"
                    if bad or len(sizes) != 1:
                        print(f"{label}\tFAILED rc={rc} sizes={sizes}",
                              flush=True)
                        continue
                    shutil.rmtree(xdir, ignore_errors=True)
                    xrc, _, _ = run([a.baseline, "x", arc, "-to", xdir])
                    ok = xrc == 0 and same_tree(inp, xdir + inp)
                    shutil.rmtree(xdir, ignore_errors=True)
                    t1 = "-"
                    if a.threads_check and kind == "osrep":
                        if os.path.exists(arc1):
                            os.remove(arc1)
                        rc1, _, _ = run(argv[:2] + [arc1] + argv[3:] + ["-t1"],
                                        env)
                        t1 = "same" if rc1 == 0 and filecmp.cmp(
                            arc, arc1, shallow=False) else "DIFF"
                        os.remove(arc1)
                    print(f"{label}\t{sizes.pop()}\t"
                          f"{statistics.median(walls):.2f}\t{max(rsss)}\t"
                          f"{'ok' if ok else 'FAIL'}\t{t1}", flush=True)
                    os.remove(arc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
