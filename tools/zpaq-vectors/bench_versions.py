#!/usr/bin/env python3
"""Multi-version backup benchmark: zpaq-std's fragmenter against -osrep.

Each corpus is a directory of versions (sorted by name) or a single folder.
For every configuration the versions are copied, one after the other, into
the same staging folder and added to one archive, as a backup of a folder
that changes. Reports the archive size, the total add time and the peak RSS,
the time of `l` and of `x` of the last version, and whether `x` gives the last
version back.

    tools/zpaq-vectors/bench_versions.py --baseline BASE --patched PATCHED \
        --workdir DIR --method=-m1 --method=-m5 \
        --corpus src-zpaqstd=/path/versions_dir --corpus mixed=/path/folder:single

A configuration is `zpaq:N` (the baseline at -fragment N) or `osrep:N` (the
patched binary with -osrep -fragment N); --configs takes a comma list. N "d"
leaves -fragment out (zpaq's default N=6, -osrep's N=3). --extra passes more
switches to every add (e.g. --extra=-threads --extra=4).
"""
import argparse
import filecmp
import os
import shutil
import subprocess
import sys
import time


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


def same_tree(a, b):
    cmp = filecmp.dircmp(a, b)
    if cmp.left_only or cmp.right_only or cmp.funny_files:
        return False
    _, mismatch, errors = filecmp.cmpfiles(a, b, cmp.common_files,
                                           shallow=False)
    if mismatch or errors:
        return False
    return all(same_tree(os.path.join(a, d), os.path.join(b, d))
               for d in cmp.common_dirs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--patched", required=True)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--method", action="append", default=None)
    ap.add_argument("--corpus", action="append", required=True,
                    help="name=dir (versions in subdirs) or name=dir:single")
    ap.add_argument("--configs", default="zpaq:6,zpaq:3,osrep:6,osrep:3")
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()
    methods = a.method or ["-m1", "-m5"]
    wd = os.path.abspath(a.workdir)
    os.makedirs(wd, exist_ok=True)
    stage = os.path.join(wd, "cur")
    arc = os.path.join(wd, "a.zpaq")
    xdir = os.path.join(wd, "x")
    print("corpus\tversions\tmethod\tconfig\tarchive\tadd_s\trss_mb\tl_s\t"
          "x_s\tx_rss_mb\textract", flush=True)
    for spec in a.corpus:
        name, path = spec.split("=", 1)
        single = path.endswith(":single")
        if single:
            path = path[:-len(":single")]
            versions = [path]
        else:
            versions = [os.path.join(path, v) for v in sorted(os.listdir(path))]
        for m in methods:
            for cfg in a.configs.split(","):
                kind, n = cfg.split(":")
                binary = a.patched if kind == "osrep" else a.baseline
                extra = ["-osrep"] if kind == "osrep" else []
                if os.path.exists(arc):
                    os.remove(arc)
                add_s, rss, ok_all = 0.0, 0, True
                for i, v in enumerate(versions):
                    subprocess.run(["rsync", "-a", "--delete", v + "/",
                                    stage + "/"], check=True)
                    ts = "2024-%02d-%02d_00:00:00" % (1 + i // 28, 1 + i % 28)
                    frag = [] if n == "d" else ["-fragment", n]
                    rc, s, r = run([binary, "a", arc, stage, m] + frag
                                   + extra + a.extra + ["-timestamp", ts])
                    add_s += s
                    rss = max(rss, r)
                    ok_all = ok_all and rc == 0
                size = os.path.getsize(arc) if os.path.exists(arc) else -1
                _, l_s, _ = run([a.baseline, "l", arc])
                shutil.rmtree(xdir, ignore_errors=True)
                xrc, x_s, x_rss = run([a.baseline, "x", arc, "-to", xdir])
                got = xdir + stage
                ok = (ok_all and xrc == 0 and os.path.isdir(got)
                      and same_tree(versions[-1], got))
                print(f"{name}\t{len(versions)}\t{m}\t{cfg}\t{size}\t"
                      f"{add_s:.2f}\t{rss}\t{l_s:.2f}\t{x_s:.2f}\t{x_rss}\t"
                      f"{'ok' if ok else 'FAIL'}", flush=True)
    for p in (stage, xdir):
        shutil.rmtree(p, ignore_errors=True)
    if os.path.exists(arc):
        os.remove(arc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
