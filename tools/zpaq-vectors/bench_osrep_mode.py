#!/usr/bin/env python3
"""Benchmark zpaq-std with OSREP mode against the unmodified baseline.

    tools/zpaq-vectors/bench_osrep_mode.py \
        --baseline /path/zpaq-std-baseline \
        --integrated /path/zpaq-std-osrep \
        --input versions.tar --method -m1 --method -m5 \
        --avgs 1024,4096,8192

Archives are frozen with -touch/-timestamp, so the only variable is the
fragmenter. Prints one TSV line per case.
"""
import argparse
import os
import sys
import time


def run(binary, args, env):
    pid = os.fork()
    if pid == 0:
        dn = os.open("/dev/null", os.O_WRONLY)
        os.dup2(dn, 1)
        os.dup2(dn, 2)
        os.execvpe(binary, [binary] + args, env)
        os._exit(127)
    start = time.perf_counter()
    _, status, usage = os.wait4(pid, 0)
    return (os.waitstatus_to_exitcode(status), time.perf_counter() - start,
            usage.ru_maxrss // 1024)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--integrated", required=True)
    ap.add_argument("--input", action="append", required=True)
    ap.add_argument("--method", action="append", default=None)
    ap.add_argument("--avgs", default="1024,4096,8192")
    ap.add_argument("--outdir", default="/tmp")
    args = ap.parse_args()
    methods = args.method or ["-m1"]
    avgs = [int(a) for a in args.avgs.split(",")]
    base_env = dict(os.environ)
    base_env.pop("OSREP_FRAG_MODE", None)
    base_env.pop("OSREP_FRAG_AVG", None)
    os.makedirs(args.outdir, exist_ok=True)

    print("input\tmethod\tmode\tsize\ttime_s\trss_mb\trc")
    for inp in args.input:
        tag = os.path.basename(inp).replace(".", "_")
        for method in methods:
            cases = [("exact", args.baseline, base_env),
                     ("integrated-exact", args.integrated, base_env)]
            for avg in avgs:
                env = dict(base_env)
                env["OSREP_FRAG_MODE"] = "osrep"
                env["OSREP_FRAG_AVG"] = str(avg)
                cases.append((f"osrep-{avg}", args.integrated, env))
            for name, binary, env in cases:
                out = os.path.join(args.outdir,
                                   f"bench-{tag}-{method}-{name}.zpaq")
                try:
                    os.remove(out)
                except FileNotFoundError:
                    pass
                rc, dt, rss = run(binary, [
                    "a", out, inp, method,
                    "-touch", "20240101000000",
                    "-timestamp", "2024-01-01_00:00:00",
                ], env)
                size = os.path.getsize(out) if os.path.exists(out) else -1
                print(f"{inp}\t{method}\t{name}\t{size}\t{dt:.3f}\t{rss}\t{rc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
