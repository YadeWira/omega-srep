#!/usr/bin/env python3
"""Real zpaq-std archives for several -osrep fragmenter policies at the same
average fragment size (experiment frag-normalized).

    tools/zpaq-vectors/bench_policies.py --baseline BASE --patched PATCHED \
        --workdir DIR --method=-m1 --fragments 0,2,3,6 \
        --corpus versions=/path/versions.tar --corpus src-omega=/path/dir \
        --configs zpaq,fnv,1:0,2:1,4:1

A corpus is a file (added alone) or a directory of versions (subdirectories
in name order, staged and added one after the other, as bench_versions.py
does). Configurations, all at an average of 2^N KiB:

  zpaq   the baseline, zpaq's own fragmenter at -fragment N
  fnv    the patched binary, -osrep with OSREP_GEAR_POLICY=fnv at
         -fragment N+3 (the old mapping averaged 2^(N-3) KiB)
  S:L    the patched binary, -osrep -fragment N with OSREP_GEAR_POLICY=S:L
         (gear, min A >> S, normalized chunking level L)
  osrep  the patched binary, -osrep -fragment N, no policy variable

The patched binary is a zpaq-std copy that reads OSREP_GEAR_POLICY (only
the experiment's copy does). Every archive is extracted with the baseline
and compared with the input (the last version for directories). One run
per case; before each run it waits until MemAvailable is at least
--min-avail-gb. Prints TSV: corpus method config N archive add_s rss_mb
extract.
"""
import argparse
import filecmp
import os
import shutil
import subprocess
import sys
import time

FIX = ["-touch", "20240101000000", "-timestamp", "2024-01-01_00:00:00"]


def avail_gb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 1048576
    return 0.0


def wait_mem(need):
    while avail_gb() < need:
        print(f"# waiting: MemAvailable {avail_gb():.1f} GB", file=sys.stderr,
              flush=True)
        time.sleep(60)


def run(argv, env=None):
    pid = os.fork()
    if pid == 0:
        dn = os.open("/dev/null", os.O_WRONLY)
        os.dup2(dn, 1)
        os.dup2(dn, 2)
        if env is None:
            os.execv(argv[0], argv)
        os.execve(argv[0], argv, env)
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
    ap.add_argument("--fragments", default="3")
    ap.add_argument("--corpus", action="append", required=True)
    ap.add_argument("--configs", default="zpaq,fnv,1:0,2:1,4:1")
    ap.add_argument("--threads", default="4")
    ap.add_argument("--min-avail-gb", type=float, default=12.0)
    a = ap.parse_args()
    methods = a.method or ["-m1"]
    wd = os.path.abspath(a.workdir)
    os.makedirs(wd, exist_ok=True)
    stage = os.path.join(wd, "cur")
    arc = os.path.join(wd, "a.zpaq")
    xdir = os.path.join(wd, "x")
    print("corpus\tmethod\tconfig\tN\tarchive\tadd_s\trss_mb\textract",
          flush=True)
    for spec in a.corpus:
        name, path = spec.split("=", 1)
        path = os.path.abspath(path)
        versions = None
        if os.path.isdir(path):
            versions = [os.path.join(path, v) for v in sorted(os.listdir(path))]
        for m in methods:
            for n in [int(x) for x in a.fragments.split(",")]:
                for cfg in a.configs.split(","):
                    env = dict(os.environ)
                    env.pop("OSREP_GEAR_POLICY", None)
                    binary, nn, extra = a.patched, n, ["-osrep"]
                    if cfg == "zpaq":
                        binary, extra = a.baseline, []
                    elif cfg == "fnv":
                        env["OSREP_GEAR_POLICY"] = "fnv"
                        nn = n + 3
                    elif cfg != "osrep":
                        env["OSREP_GEAR_POLICY"] = cfg
                    common = [m, "-fragment", str(nn), "-t" + a.threads] + extra
                    wait_mem(a.min_avail_gb)
                    if os.path.exists(arc):
                        os.remove(arc)
                    add_s, rss, ok = 0.0, 0, True
                    if versions is None:
                        rc, add_s, rss = run([binary, "a", arc, path] + common
                                             + FIX, env)
                        ok = rc == 0
                    else:
                        for i, v in enumerate(versions):
                            subprocess.run(["rsync", "-a", "--delete", v + "/",
                                            stage + "/"], check=True)
                            ts = "2024-%02d-%02d_00:00:00" % (1 + i // 28,
                                                              1 + i % 28)
                            rc, s, r = run([binary, "a", arc, stage] + common
                                           + ["-timestamp", ts], env)
                            add_s += s
                            rss = max(rss, r)
                            ok = ok and rc == 0
                    size = os.path.getsize(arc) if os.path.exists(arc) else -1
                    shutil.rmtree(xdir, ignore_errors=True)
                    xrc, _, _ = run([a.baseline, "x", arc, "-to", xdir])
                    if versions is None:
                        out = xdir + path
                        ok = (ok and xrc == 0 and os.path.exists(out)
                              and filecmp.cmp(path, out, shallow=False))
                    else:
                        got = xdir + stage
                        ok = (ok and xrc == 0 and os.path.isdir(got)
                              and same_tree(versions[-1], got))
                    shutil.rmtree(xdir, ignore_errors=True)
                    if os.path.exists(arc):
                        os.remove(arc)
                    print(f"{name}\t{m}\t{cfg}\t{n}\t{size}\t{add_s:.2f}\t"
                          f"{rss}\t{'ok' if ok else 'FAIL'}", flush=True)
    shutil.rmtree(stage, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
