#!/usr/bin/env python3
"""List the files zpaq would add for a corpus, for frag_sim.

    frag_sim_list.py PATH [single]

PATH is a file (one input), a folder of versions (subfolders, sorted by name,
as bench_versions.py adds them) or, with "single", one folder. A file of a
later version is left out when the previous version has it with the same
size and mtime: zpaq skips it, so it adds no fragment and no reference.
"""
import os
import sys


def walk(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            st = os.stat(p)
            out[os.path.relpath(p, root)] = (p, st.st_size, st.st_mtime_ns)
    return out


def main():
    path = sys.argv[1]
    single = len(sys.argv) > 2 and sys.argv[2] == "single"
    if os.path.isfile(path):
        print(path)
        return
    versions = [path] if single else [os.path.join(path, v)
                                      for v in sorted(os.listdir(path))]
    prev = {}
    for v in versions:
        cur = walk(v)
        for rel in sorted(cur):
            p, sz, mt = cur[rel]
            q = prev.get(rel)
            if q is not None and q[1] == sz and q[2] == mt:
                continue
            print(p)
        prev = cur


if __name__ == "__main__":
    main()
