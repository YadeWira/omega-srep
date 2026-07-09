#!/usr/bin/env python3
"""
P2.7 research: compare the current FNV-style "hash-of-prefix-since-last-cut"
CDC chunker (tests/dup_prototype.py's cdc_split) against a proper fixed-window
Gear-hash chunker (FastCDC-style) on real corpora.

Three angles:
  1. Throughput (bytes/sec in pure Python -- relative comparison only,
     the real win would show up in C++/SIMD, not here).
  2. Chunk-size distribution (stddev, % at min/max clamp -- FastCDC's
     "normalized chunking" claim).
  3. Edit locality: insert a few random bytes near the START of a buffer
     and measure how far downstream chunk boundaries stay disrupted.
     This is the concrete, mechanical difference: the current chunker's
     rolling value is h = h*PRIME + byte, reset to 0 only at a cut --
     it hashes the ENTIRE prefix since the last cut, so it has no fixed
     window and never "forgets" an edit until the next cut fires.
     Gear hash's h = (h << 1) + GEAR[byte] naturally forgets bytes older
     than ~64 shifts (they fall off the top of the 64-bit register), so
     it has an implicit ~64-byte window and recovers locally.
"""
import hashlib
import os
import random
import statistics
import struct
import sys
import time

sys.path.insert(0, "/home/forum/git/omega-srep/tests")
from dup_prototype import cdc_split as fnv_cdc_split  # noqa: E402

AVG, MIN_CHUNK, MAX_CHUNK = 4096, 1024, 16384

_rng = random.Random(0xC0FFEE)
GEAR = [_rng.getrandbits(64) for _ in range(256)]
MASK64 = 0xFFFFFFFFFFFFFFFF


def gear_cdc_split(data: bytes, lo: int = 0, hi: int | None = None, normalized: bool = False):
    """Gear-hash CDC. With normalized=False: single mask, same shape as the
    current FNV chunker (fair apples-to-apples hash-only comparison).
    With normalized=True: FastCDC's actual "normalized chunking" -- a
    stricter mask below AVG, a laxer mask above AVG, which is the real
    source of FastCDC's tighter size distribution (not the hash itself).
    """
    if hi is None:
        hi = len(data)
    if lo >= hi:
        return
    bits = AVG.bit_length() - 1
    assert (1 << bits) == AVG, "AVG must be power of 2"
    mask = AVG - 1
    mask_s = (1 << (bits + 2)) - 1   # stricter: harder to satisfy, used below AVG
    mask_l = (1 << (bits - 2)) - 1   # laxer: easier to satisfy, used above AVG
    start = lo
    h = 0
    for i in range(lo, hi):
        h = ((h << 1) + GEAR[data[i]]) & MASK64
        span = i - start
        if span < MIN_CHUNK:
            continue
        if span >= MAX_CHUNK - 1:
            yield data[start:i + 1]
            start = i + 1
            h = 0
            continue
        if normalized:
            m = mask_s if span < AVG else mask_l
        else:
            m = mask
        if (h & m) == 0:
            yield data[start:i + 1]
            start = i + 1
            h = 0
    if start < hi:
        yield data[start:hi]


def fnv_chunks(data: bytes):
    return list(fnv_cdc_split(data, avg=AVG, min_chunk=MIN_CHUNK, max_chunk=MAX_CHUNK))


def gear_chunks(data: bytes):
    return list(gear_cdc_split(data))


def gear_norm_chunks(data: bytes):
    return list(gear_cdc_split(data, normalized=True))


def chunk_stats(chunks, label):
    sizes = [len(c) for c in chunks]
    n = len(sizes)
    if n == 0:
        print(f"  {label}: no chunks")
        return
    avg = statistics.mean(sizes)
    sd = statistics.pstdev(sizes) if n > 1 else 0.0
    at_min = sum(1 for s in sizes if s <= MIN_CHUNK)
    at_max = sum(1 for s in sizes if s >= MAX_CHUNK - 1)
    print(f"  {label}: n={n:>7} avg={avg:>7.0f} stdev={sd:>7.0f} "
          f"min={min(sizes):>6} max={max(sizes):>6} "
          f"at_min%={100*at_min/n:>5.1f} at_max%={100*at_max/n:>5.1f}")


def bench_throughput(data: bytes, label: str):
    print(f"\n=== {label} ({len(data):,} bytes, {len(set(data))} distinct bytes) ===")
    t0 = time.perf_counter()
    fc = fnv_chunks(data)
    t1 = time.perf_counter()
    gc = gear_chunks(data)
    t2 = time.perf_counter()
    gnc = gear_norm_chunks(data)
    t3 = time.perf_counter()
    for name, dt in (("fnv_prefix_hash", t1 - t0), ("gear_hash", t2 - t1),
                     ("gear_hash_normalized", t3 - t2)):
        print(f"  {name:<20}: {dt:6.2f}s  ({len(data)/dt/1e6:6.2f} MB/s)")
    chunk_stats(fc, "fnv_prefix_hash     ")
    chunk_stats(gc, "gear_hash           ")
    chunk_stats(gnc, "gear_hash_normalized")
    return fc, gc, gnc


def edit_locality_test(data: bytes, label: str, insert_at: int, insert_len: int = 5):
    print(f"\n=== edit locality: {label}, insert {insert_len}B @ offset {insert_at} ===")
    edited = data[:insert_at] + os.urandom(insert_len) + data[insert_at:]

    def boundary_offsets(chunks):
        offs = []
        pos = 0
        for c in chunks:
            pos += len(c)
            offs.append(pos)
        return offs

    for name, splitter in (("fnv_prefix_hash", fnv_chunks), ("gear_hash", gear_chunks)):
        orig_bounds = set(boundary_offsets(splitter(data)))
        edit_bounds = boundary_offsets(splitter(edited))
        # shift edited boundaries back by insert_len to compare in original coordinates
        # (only meaningful for boundaries after the insert point)
        recovered_at = None
        for b in edit_bounds:
            if b - insert_len <= insert_at:
                continue
            if (b - insert_len) in orig_bounds:
                recovered_at = b - insert_len - insert_at
                break
        print(f"  {name:<16}: recovers at +{recovered_at} bytes downstream of the edit"
              if recovered_at is not None else
              f"  {name:<16}: did NOT resync within this buffer")


def dedup_ratio(chunks):
    seen = set()
    unique_bytes = 0
    total_bytes = 0
    for c in chunks:
        h = hashlib.sha256(c).digest()[:8]
        total_bytes += len(c)
        if h not in seen:
            seen.add(h)
            unique_bytes += len(c)
    return unique_bytes, total_bytes


def dedup_comparison(data: bytes, label: str):
    print(f"\n=== dedup ratio: {label} ===")
    for name, splitter in (("fnv_prefix_hash", fnv_chunks),
                           ("gear_hash", gear_chunks),
                           ("gear_hash_normalized", gear_norm_chunks)):
        chunks = splitter(data)
        uniq, total = dedup_ratio(chunks)
        pct = 100 * uniq / total if total else 0
        print(f"  {name:<20}: unique_bytes/total = {uniq:>10}/{total:>10} = {pct:5.1f}% "
              f"(lower is better dedup)")


def main():
    corpus_dir = "/home/forum/git/omega-srep/tests/corpus"
    bench_dir = os.path.expanduser("~/.osrep-bench")
    multi_dir = os.path.expanduser("~/.osrep-bench-multi")

    samples = []
    text_bin = os.path.join(corpus_dir, "text.bin")
    if os.path.exists(text_bin):
        samples.append(("tests/corpus/text.bin", open(text_bin, "rb").read()))

    mixed_bin = os.path.join(corpus_dir, "mixed.bin")
    if os.path.exists(mixed_bin):
        samples.append(("tests/corpus/mixed.bin", open(mixed_bin, "rb").read()))

    enwik8 = os.path.join(multi_dir, "enwik8")
    if os.path.exists(enwik8):
        with open(enwik8, "rb") as f:
            samples.append(("enwik8 (first 8MB)", f.read(8 * 1024 * 1024)))

    dup32x4 = os.path.join(bench_dir, "dup_bench_in_32x4.bin")
    if os.path.exists(dup32x4):
        with open(dup32x4, "rb") as f:
            samples.append(("dup_bench_in_32x4 (first 16MB, 2x repeat)", f.read(16 * 1024 * 1024)))

    for label, data in samples:
        bench_throughput(data, label)

    # Dedup ratio matters most on the corpus built specifically to have
    # long-range duplicate content (the -dup use case). Needs >=2 full
    # 32 MiB blocks to actually contain a repeat -- the 16 MB throughput
    # slice above is entirely within block 0, so re-read 64 MiB fresh.
    if os.path.exists(dup32x4):
        with open(dup32x4, "rb") as f:
            dup_data = f.read(64 * 1024 * 1024)
        dedup_comparison(dup_data, "dup_bench_in_32x4 (first 64MB, 2 full blocks)")
    for label, data in samples:
        if "mixed" in label:
            dedup_comparison(data, label)

    # Edit-locality demonstration on a higher-entropy sample (avoid the
    # low-byte-diversity text.bin, which degenerates any simple rolling hash).
    for label, data in samples:
        if "enwik8" in label:
            edit_locality_test(data, label, insert_at=len(data) // 4)
            edit_locality_test(data, label, insert_at=len(data) // 4, insert_len=1)
            break


if __name__ == "__main__":
    main()


def alignment_robustness_test():
    """The real question: does the current FNV hash need buffer-boundary
    resets (--chunk-buf) to find duplicates, and does Gear-hash still
    find them even when the duplicate content is NOT aligned to any
    buffer boundary (the realistic case -- a duplicated file embedded
    at an arbitrary offset inside a tar archive, say)?
    """
    print("\n=== alignment robustness: duplicate payload at a non-buffer-aligned offset ===")
    rng = random.Random(99)
    with open("/home/forum/git/omega-srep/tests/corpus/mixed.bin", "rb") as f:
        payload = f.read(2 * 1024 * 1024)  # 2 MiB payload to duplicate

    BUF = 1 * 1024 * 1024  # production-style buffer size, but small for speed

    def build(pad1_len, pad2_len):
        pad1 = bytes(rng.randint(0, 255) for _ in range(pad1_len))
        pad2 = bytes(rng.randint(0, 255) for _ in range(pad2_len))
        return pad1 + payload + pad2 + payload

    scenarios = {
        "aligned (pads are multiples of BUF)": build(BUF * 2, BUF * 3),
        "misaligned (+12345B off-grid)": build(BUF * 2 + 12345, BUF * 3 + 777),
    }

    def fnv_buffered_chunks(data, buf_size):
        return list(fnv_cdc_split(data, avg=AVG, min_chunk=MIN_CHUNK,
                                   max_chunk=MAX_CHUNK, buf_size=buf_size))

    def gear_nobuf_chunks(data):
        return list(gear_cdc_split(data, normalized=True))

    for scenario, data in scenarios.items():
        print(f"\n  -- {scenario} --")
        uniq, total = dedup_ratio(fnv_buffered_chunks(data, BUF))
        print(f"    fnv_prefix_hash (buf_size={BUF}, needs alignment): "
              f"{uniq}/{total} = {100*uniq/total:.1f}% unique")
        uniq, total = dedup_ratio(gear_nobuf_chunks(data))
        print(f"    gear_hash_normalized (buf_size=0, no reset needed): "
              f"{uniq}/{total} = {100*uniq/total:.1f}% unique")


alignment_robustness_test()
