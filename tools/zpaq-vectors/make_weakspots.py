#!/usr/bin/env python3
"""Synthetic but deterministic corpora for the weak spots of zpaq's dedup.

zpaq-std's deduplicator only sees whole fragments (64 KiB on average, at
least 4 KiB), so a change of a few bytes costs a whole fragment. These
corpora aim at that, built from real files (seed 1, the same bytes every
run):

  disk   DIR/disk/v1/disk.img, v2/disk.img: a 512 MiB disk-like image. A
         4 MiB metadata area (one 256-byte record per file) and the files
         laid out in 4 KiB sectors, some split into extents interleaved with
         other files, with small gaps of zeros. v2 changes 200 sectors whole
         (new data), edits 8-64 bytes inside 100 more and updates 50
         metadata records: 350 scattered changes.
  insert DIR/insert/v1, v2: a tree and the same tree with one byte ("X")
         inserted at the start of every file.
  db     DIR/db<P>k/v1..v4/data.db: a database-like file of P KiB pages
         (header with page number, LSN and CRC-32; records cut from text).
         Each version updates one record in 2 % of the pages, swaps 0.5 %
         of the pages in pairs (new page number and CRC, same records) and
         appends 1 % new pages.

    make_weakspots.py --out DIR --tree-src D1 --tree-src D2 ... \
        --disk-src D ... --new-data FILE --text FILE [--db-pages 4,8,16]

--tree-src: folders copied into the insert tree. --disk-src: folders whose
files fill the disk image (sorted, then shuffled with the seed).
--new-data: a file (not used elsewhere) the new sectors of v2 come from.
Every file of version k gets the mtime 2024-k-01 12:00 UTC.
--text: a text file the database records come from (e.g. enwik8).
"""
import argparse
import calendar
import os
import random
import shutil
import struct
import sys
import zlib

SECTOR = 4096
DISK = 512 << 20
META = 4 << 20


def files_under(dirs):
    out = []
    for d in dirs:
        for root, subdirs, names in os.walk(d):
            subdirs.sort()
            for n in sorted(names):
                p = os.path.join(root, n)
                if os.path.isfile(p) and not os.path.islink(p):
                    out.append(p)
    return out


def make_disk(out, srcs, new_data):
    rng = random.Random(1)
    files = files_under(srcs)
    rng.shuffle(files)
    img = bytearray(DISK)
    nsec = DISK // SECTOR
    cur = META // SECTOR
    limit = nsec - nsec // 50          # leave 2 % free at the end
    pending = []                       # (sectors needed, data) extents to place later
    records = []                       # (record offset, [sectors])
    used = []

    def put(data, start):
        n = (len(data) + SECTOR - 1) // SECTOR
        img[start * SECTOR:start * SECTOR + len(data)] = data
        used.extend(range(start, start + n))
        return list(range(start, start + n))

    for f in files:
        with open(f, "rb") as h:
            data = h.read()
        if not data:
            continue
        nsect = (len(data) + SECTOR - 1) // SECTOR
        if cur + nsect + sum((len(d) + SECTOR - 1) // SECTOR for d in pending) >= limit:
            continue
        secs = []
        if len(data) > 32768 and rng.random() < 0.2:
            parts = rng.randint(2, 4)
            cuts = sorted(rng.sample(range(1, nsect), min(parts - 1, nsect - 1)))
            bounds = [0] + [c * SECTOR for c in cuts] + [len(data)]
            first = data[bounds[0]:bounds[1]]
            secs += put(first, cur)
            cur += (len(first) + SECTOR - 1) // SECTOR
            for i in range(1, len(bounds) - 1):
                pending.append(data[bounds[i]:bounds[i + 1]])
        else:
            secs += put(data, cur)
            cur += nsect
        # extents waiting for room go after the next file or two
        while pending and rng.random() < 0.6:
            d = pending.pop(0)
            secs += put(d, cur)
            cur += (len(d) + SECTOR - 1) // SECTOR
        if rng.random() < 0.05:
            cur += rng.randint(1, 64)  # a gap of zeros
        rec = len(records) * 256
        if rec + 256 > META:
            break
        name = os.path.basename(f).encode("utf-8", "replace")[:120]
        r = struct.pack("<IQQ", zlib.crc32(name), len(data), 1700000000 + len(records))
        r += name.ljust(120, b"\0")
        ext = b"".join(struct.pack("<I", s) for s in secs[:30])
        r = (r + ext).ljust(256, b"\0")[:256]
        img[rec:rec + 256] = r
        records.append(rec)
    for d in pending:
        put(d, cur)
        cur += (len(d) + SECTOR - 1) // SECTOR
    v1 = os.path.join(out, "disk", "v1")
    v2 = os.path.join(out, "disk", "v2")
    os.makedirs(v1, exist_ok=True)
    os.makedirs(v2, exist_ok=True)
    with open(os.path.join(v1, "disk.img"), "wb") as h:
        h.write(img)
    nd = os.path.getsize(new_data)
    chosen = rng.sample(used, 300)
    with open(new_data, "rb") as nf:
        for s in chosen[:200]:
            nf.seek(rng.randrange(0, nd - SECTOR))
            img[s * SECTOR:(s + 1) * SECTOR] = nf.read(SECTOR)
    for s in chosen[200:]:
        ln = rng.randint(8, 64)
        o = s * SECTOR + rng.randrange(0, SECTOR - ln)
        img[o:o + ln] = bytes(rng.getrandbits(8) for _ in range(ln))
    for rec in rng.sample(records, min(50, len(records))):
        img[rec + 12:rec + 20] = struct.pack("<Q", 1800000000 + rec)
    with open(os.path.join(v2, "disk.img"), "wb") as h:
        h.write(img)
    print(f"disk: {len(records)} files, {cur * SECTOR >> 20} MiB used, "
          f"{len(chosen)} sectors + 50 records changed", file=sys.stderr)


def make_insert(out, srcs):
    v1 = os.path.join(out, "insert", "v1")
    v2 = os.path.join(out, "insert", "v2")
    n = 0
    for d in srcs:
        base = os.path.basename(os.path.normpath(d))
        for f in files_under([d]):
            rel = os.path.join(base, os.path.relpath(f, d))
            with open(f, "rb") as h:
                data = h.read()
            for root, pre in ((v1, b""), (v2, b"X")):
                p = os.path.join(root, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "wb") as h:
                    h.write(pre + data)
            n += 1
    print(f"insert: {n} files", file=sys.stderr)


def make_db(out, text, kib, versions=4, size=128 << 20):
    rng = random.Random(1000 + kib)
    psz = kib << 10
    with open(text, "rb") as h:
        txt = h.read()
    lines = [l for l in txt.split(b"\n") if 40 <= len(l) <= 400]
    rowid = [0]

    def record():
        rowid[0] += 1
        body = lines[rng.randrange(len(lines))]
        return struct.pack("<QI", rowid[0], len(body)) + body

    def page(no, lsn, recs):
        body = b"".join(recs)
        body = body.ljust(psz - 32, b"\0")
        hdr = struct.pack("<2sHIQHHI", b"PG", 1, no, lsn, len(recs),
                          psz - 32 - len(b"".join(recs)), zlib.crc32(body))
        return hdr.ljust(32, b"\0") + body

    def fill():
        recs, used = [], 0
        while True:
            r = record()
            if used + len(r) > psz - 32:
                return recs
            recs.append(r)
            used += len(r)

    pages = []   # [recs]
    lsns = []
    for no in range(size // psz):
        pages.append(fill())
        lsns.append(1)
    lsn = 1
    d = os.path.join(out, f"db{kib}k")
    for v in range(1, versions + 1):
        if v > 1:
            lsn += 1
            n = len(pages)
            for p in rng.sample(range(n), n * 2 // 100):
                recs = pages[p]
                i = rng.randrange(len(recs))
                old = recs[i]
                body = lines[rng.randrange(len(lines))]
                ln = len(old) - 12
                body = (body * (ln // len(body) + 1))[:ln]
                recs[i] = old[:12] + body
                lsns[p] = lsn
            for _ in range(n * 5 // 1000 // 2):
                a, b = rng.randrange(n), rng.randrange(n)
                pages[a], pages[b] = pages[b], pages[a]
                lsns[a], lsns[b] = lsns[b], lsns[a]
            for _ in range(n // 100):
                pages.append(fill())
                lsns.append(lsn)
        vd = os.path.join(d, f"v{v}")
        os.makedirs(vd, exist_ok=True)
        with open(os.path.join(vd, "data.db"), "wb") as h:
            for no, recs in enumerate(pages):
                h.write(page(no, lsns[no], recs))
    print(f"db{kib}k: {len(pages)} pages of {psz} B in v{versions}",
          file=sys.stderr)


def stamp(out):
    """Version k gets mtime 2024-k-01 12:00 UTC: zpaq skips a file of the
    same size and date, and the two disk images have the same size."""
    for c in os.listdir(out):
        cd = os.path.join(out, c)
        if not os.path.isdir(cd):
            continue
        for v in os.listdir(cd):
            if not (v.startswith("v") and v[1:].isdigit()):
                continue
            t = calendar.timegm((2024, int(v[1:]), 1, 12, 0, 0))
            for root, _, names in os.walk(os.path.join(cd, v)):
                for n in names:
                    os.utime(os.path.join(root, n), (t, t))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--tree-src", action="append", default=[])
    ap.add_argument("--disk-src", action="append", default=[])
    ap.add_argument("--new-data")
    ap.add_argument("--text")
    ap.add_argument("--db-pages", default="8")
    ap.add_argument("--only", default="disk,insert,db")
    a = ap.parse_args()
    only = a.only.split(",")
    os.makedirs(a.out, exist_ok=True)
    if "disk" in only:
        shutil.rmtree(os.path.join(a.out, "disk"), ignore_errors=True)
        make_disk(a.out, a.disk_src, a.new_data)
    if "insert" in only:
        shutil.rmtree(os.path.join(a.out, "insert"), ignore_errors=True)
        make_insert(a.out, a.tree_src)
    if "db" in only:
        for k in a.db_pages.split(","):
            shutil.rmtree(os.path.join(a.out, f"db{k}k"), ignore_errors=True)
            make_db(a.out, a.text, int(k))
    stamp(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
