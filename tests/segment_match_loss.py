#!/usr/bin/env python3
"""
Quantify the compression-ratio loss from splitting Omega SREP's -m3/-m4/-m5
match-finder into independent parallel segments.

Design rationale (see task brief / docs/research-notes.md F3.3):

  - Real SREP's -m3/-m4/-m5 path (Compression/SREP/hash_table.cpp,
    compress.cpp) samples the input on a fixed L-byte grid:
    `HashTable::total_chunks = filesize/L` and `curchunk = (block_start+i)/L`.
    That means the hash table is fundamentally chunk-indexed, not a
    byte-stride-1 rolling window; a `PolynomialRollingHash` is used only to
    *compute* each aligned chunk's hash cheaply, not to support arbitrary
    (non-grid) offsets. So this prototype hashes disjoint L-byte chunks on
    an absolute grid (grid position = multiple of L from file offset 0),
    exactly mirroring `curchunk = (block_start+i)/L`.
  - MIN_MATCH / L default to 512 bytes, per the code facts (non-CDC,
    neither -l nor -c given: min_match = 512; for -m3/-m4, L = min_match).
  - Hash table semantics: one slot per bucket, unconditionally overwritten
    on insert (hash_table.cpp add_hash0) -> modeled as a plain dict that
    is overwritten on every insert (last writer wins).
  - Matching is greedy / single-candidate, first hit wins, no lazy
    lookahead (compress.cpp goto match_found2) -> modeled as: on a hash
    hit, verify + extend immediately; if it clears MIN_MATCH, commit and
    jump `last_match_end` forward; never reconsidered.
  - matchWindow fact: -m3/-m4/-m5 have NO real distance cap (pc.max_offset
    is a diagnostic counter only, never a rejection filter) -> "whole
    buffer" mode uses one hash table across the entire slice with
    unbounded lookback, matching that fact.
  - "segment-independent" mode approximates what an N-way inner-loop split
    would look like: each segment gets a *fresh* hash table and can only
    see/mutate its own bytes -> no cross-segment matches at all.
  - "handoff/overlap" mitigation approximates carrying forward K MB of
    *raw bytes + the hash-table entries actually produced while scanning
    those bytes* from the tail of the previous segment, as read-only
    context for the next segment (never mutated by it) -> cheap, no
    cross-segment synchronization of the mutable table required.

This is a structural proxy, not a byte-for-byte reimplementation of
Compression/SREP/*.cpp. It preserves: chunk grid size (=MIN_MATCH),
whole-file vs segment-bounded lookback, greedy single-candidate matching,
and unconditional hash-slot overwrite.
"""

import os
import sys
import time

MIN_MATCH = 512   # srep.cpp:405 default min_match for non-CDC -m3/-m4/-m5
L = MIN_MATCH      # srep.cpp:408 -- for -m3/-m4 (non-exhaustive), L == min_match

MB = 1024 * 1024


def common_len_forward(buf, a, b, max_len):
    """Longest k <= max_len such that buf[a:a+k] == buf[b:b+k].
    Uses coarse doubling steps + a final binary search, so each comparison
    is a single C-level bytes `==` (memcmp), not a Python byte-by-byte loop.
    """
    if max_len <= 0:
        return 0
    pos = 0
    step = 1024
    while pos < max_len:
        s = step if step < max_len - pos else max_len - pos
        if buf[a + pos:a + pos + s] == buf[b + pos:b + pos + s]:
            pos += s
            if step < (1 << 22):
                step *= 2
        else:
            lo, hi = pos, pos + s
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if buf[a:a + mid] == buf[b:b + mid]:
                    lo = mid
                else:
                    hi = mid - 1
            return lo
    return pos


def common_len_backward(buf, a, b, max_len):
    """Longest k <= max_len such that buf[a-k:a] == buf[b-k:b]."""
    if max_len <= 0:
        return 0
    pos = 0
    step = 1024
    while pos < max_len:
        s = step if step < max_len - pos else max_len - pos
        if buf[a - pos - s:a - pos] == buf[b - pos - s:b - pos]:
            pos += s
            if step < (1 << 22):
                step *= 2
        else:
            lo, hi = pos, pos + s
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if buf[a - mid:a] == buf[b - mid:b]:
                    lo = mid
                else:
                    hi = mid - 1
            return lo
    return pos


def find_matches_in_range(buf, seg_start, seg_end, table, carry_table, carry_floor):
    """Greedy chunk-grid match scan over buf[seg_start:seg_end).

    table        : mutable dict, hash -> absolute position. Only entries
                    from THIS segment's own scan live here (mutated).
    carry_table   : read-only dict, hash -> absolute position, carried
                    forward from a previous segment's tail (never
                    mutated). Empty dict for plain segment-independent
                    (no-mitigation) runs and for the whole-buffer baseline.
    carry_floor   : lowest absolute position for which carry_table entries
                    are backed by actual available bytes (i.e. the start
                    of the carried K-MB raw-byte window). Backward
                    extension of a carry-sourced candidate cannot cross
                    below this.

    Returns (bytes_covered_by_matches, last_match_end).
    """
    n = len(buf)
    last_match_end = seg_start
    covered = 0

    i = seg_start
    if i % L != 0:
        i = ((i // L) + 1) * L

    while i + L <= seg_end:
        if i < last_match_end:
            i += L
            continue

        chunk = buf[i:i + L]
        h = hash(chunk)

        p = table.get(h)
        src_floor = seg_start
        if p is None:
            p = carry_table.get(h)
            src_floor = carry_floor

        if p is not None and p != i and buf[p:p + L] == chunk:
            dest_floor = last_match_end if last_match_end > seg_start else seg_start
            max_bwd = i - dest_floor
            mb = p - src_floor
            if mb < max_bwd:
                max_bwd = mb
            bwd = common_len_backward(buf, i, p, max_bwd) if max_bwd > 0 else 0

            max_fwd = seg_end - i
            fwd = common_len_forward(buf, p, i, max_fwd)

            mlen = bwd + fwd
            if mlen >= MIN_MATCH:
                covered += mlen
                match_end = i + fwd
                last_match_end = match_end
                table[h] = i  # unconditional overwrite, same as add_hash0
                i = match_end
                if i % L != 0:
                    i = ((i // L) + 1) * L
                continue

        table[h] = i  # unconditional overwrite regardless of match outcome
        i += L

    return covered, last_match_end


def run_whole_buffer(buf):
    n = len(buf)
    table = {}
    covered, _ = find_matches_in_range(buf, 0, n, table, {}, 0)
    return covered


def run_segmented(buf, seg_size, carry_bytes):
    """seg_size: segment size in bytes. carry_bytes: 0 for plain
    segment-independent, else K*MB for the handoff/overlap mitigation."""
    n = len(buf)
    total_covered = 0
    carry_table = {}
    carry_floor = 0
    seg_start = 0
    while seg_start < n:
        seg_end = seg_start + seg_size
        if seg_end > n:
            seg_end = n
        table = {}
        this_carry_floor = seg_start - carry_bytes if carry_bytes > 0 else seg_start
        if this_carry_floor < 0:
            this_carry_floor = 0
        covered, _ = find_matches_in_range(
            buf, seg_start, seg_end, table, carry_table, this_carry_floor
        )
        total_covered += covered

        if carry_bytes > 0:
            carry_lo = seg_end - carry_bytes
            carry_table = {hh: pp for hh, pp in table.items() if pp >= carry_lo}
            carry_floor = carry_lo if carry_lo > 0 else 0
        else:
            carry_table = {}
            carry_floor = 0

        seg_start = seg_end
    return total_covered


def load_slice(path, max_bytes):
    size = os.path.getsize(path)
    n = size if size < max_bytes else max_bytes
    with open(path, "rb") as f:
        data = f.read(n)
    return data


def fmt_mb(n):
    return "%.2f MB" % (n / MB)


def analyze_corpus(name, path, max_read_mb):
    max_bytes = max_read_mb * MB
    t0 = time.time()
    buf = load_slice(path, max_bytes)
    n = len(buf)
    load_t = time.time() - t0
    print("=" * 78)
    print(f"Corpus: {name}  path={path}")
    print(f"  slice used: {fmt_mb(n)} ({n} bytes)  [requested up to {max_read_mb} MB, "
          f"file actual size {os.path.getsize(path)} bytes]  load_time={load_t:.2f}s")

    seg_sizes_mb = [4, 16, 64]
    overlap_k_mb = [1, 4]

    t0 = time.time()
    baseline = run_whole_buffer(buf)
    t_base = time.time() - t0
    print(f"  [whole-buffer]      covered={baseline:>12} bytes "
          f"({100.0*baseline/n:5.2f}% of slice)   time={t_base:.2f}s")

    results = []
    for seg_mb in seg_sizes_mb:
        seg_bytes = seg_mb * MB
        if seg_bytes > n:
            print(f"  [segment={seg_mb:>3} MB]  SKIPPED (segment size larger than corpus slice)")
            continue

        t0 = time.time()
        seg_covered = run_segmented(buf, seg_bytes, 0)
        t_seg = time.time() - t0
        loss_pct = 100.0 * (baseline - seg_covered) / baseline if baseline else 0.0
        print(f"  [segment={seg_mb:>3} MB, no overlap]      covered={seg_covered:>12} bytes "
              f"  loss vs whole-buffer = {loss_pct:6.2f}%   time={t_seg:.2f}s")
        row = {"corpus": name, "slice_mb": n / MB, "seg_mb": seg_mb,
               "baseline": baseline, "no_overlap": seg_covered,
               "loss_no_overlap_pct": loss_pct}

        for k_mb in overlap_k_mb:
            k_bytes = k_mb * MB
            t0 = time.time()
            ov_covered = run_segmented(buf, seg_bytes, k_bytes)
            t_ov = time.time() - t0
            ov_loss_pct = 100.0 * (baseline - ov_covered) / baseline if baseline else 0.0
            recovered_pct = (100.0 * (ov_covered - seg_covered) / (baseline - seg_covered)
                              if baseline > seg_covered else 0.0)
            print(f"  [segment={seg_mb:>3} MB, +{k_mb}MB overlap]  covered={ov_covered:>12} bytes "
                  f"  loss vs whole-buffer = {ov_loss_pct:6.2f}%   "
                  f"(recovers {recovered_pct:5.1f}% of the lost bytes)   time={t_ov:.2f}s")
            row[f"overlap_{k_mb}mb"] = ov_covered
            row[f"loss_overlap_{k_mb}mb_pct"] = ov_loss_pct
            row[f"recovered_overlap_{k_mb}mb_pct"] = recovered_pct

        results.append(row)
    return results


def main():
    corpora = [
        ("mixed.bin", "/home/forum/git/omega-srep/tests/corpus/mixed.bin", 6553600 // MB + 1),
        ("text.bin", "/home/forum/git/omega-srep/tests/corpus/text.bin", 4194304 // MB + 1),
        ("enwik8", os.path.expanduser("~/.osrep-bench-multi/enwik8"), 64),
        ("dup_bench_in_32x4.bin", os.path.expanduser("~/.osrep-bench/dup_bench_in_32x4.bin"), 64),
    ]

    all_rows = []
    t_start = time.time()
    for name, path, max_mb in corpora:
        if not os.path.exists(path):
            print(f"SKIP {name}: not found at {path}")
            continue
        rows = analyze_corpus(name, path, max_mb)
        all_rows.extend(rows)

    print("=" * 78)
    print(f"TOTAL WALL TIME: {time.time() - t_start:.2f}s")
    print()
    print("SUMMARY TABLE (loss %, negative-safe, vs whole-buffer baseline)")
    hdr = ("corpus", "slice_MB", "seg_MB", "loss_no_overlap%",
           "loss_+1MB%", "recovered_1MB%", "loss_+4MB%", "recovered_4MB%")
    print("\t".join(hdr))
    for r in all_rows:
        print("\t".join(str(x) for x in (
            r["corpus"], f"{r['slice_mb']:.1f}", r["seg_mb"],
            f"{r['loss_no_overlap_pct']:.2f}",
            f"{r['loss_overlap_1mb_pct']:.2f}", f"{r['recovered_overlap_1mb_pct']:.1f}",
            f"{r['loss_overlap_4mb_pct']:.2f}", f"{r['recovered_overlap_4mb_pct']:.1f}",
        )))


if __name__ == "__main__":
    main()
