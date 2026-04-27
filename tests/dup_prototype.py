#!/usr/bin/env python3
"""
Pure-Python reference implementation of Omega SREP's -dup pre-pass.

Standalone, no SREP integration. Encodes/decodes a .dupref file that
matches the format described in docs/dup-mode-design.md. Exists so:

  1. F5.2's C++ encoder can be validated byte-for-byte against this.
  2. The design can be exercised end-to-end before any C++ is written.

Format (little-endian, x86_64-only):

  HEADER (24 bytes):
    magic           : 4 bytes  = "DUPR"  (0x52505544 LE)
    version         : uint32   = 1
    chunk_count     : uint64   = total chunks (unique + refs)
    unique_count    : uint64   = distinct unique chunks
  CHUNK TABLE (variable):
    for each of chunk_count chunks, in order:
      tag           : uint8    (0 = unique, 1 = ref)
      tag==0 payload:
        length      : uint32   (bytes of unique chunk that follow in body)
      tag==1 payload:
        ref_index   : varint   (LEB128, must be < current chunk index)
  BODY (variable):
    concatenated bytes of each unique chunk in order of first appearance.

This format is the dedup-only payload; in real osrep it will live as
a footer alongside the SREP-compressed unique-chunk stream.

Self-test at __main__ encodes + decodes synthetic inputs (zeros, text,
random with fixed seed, mixed) and asserts decode(encode(x)) == x.
"""

from __future__ import annotations
import argparse
import hashlib
import io
import random
import struct
import sys
from typing import Iterator


# ---------------------------------------------------------------------------
# CDC (content-defined chunking)
# ---------------------------------------------------------------------------
# Rolling hash. Boundary at every position where hash & MASK == 0.
# MASK is set so average chunk size = AVG bytes. Min/max enforce
# bounds so the table doesn't degenerate on adversarial input.

PRIME = 0x100000001B3  # FNV-style multiplier for a cheap rolling hash


def _cdc_split_buffer(data: bytes, lo: int, hi: int, avg: int,
                      min_chunk: int, max_chunk: int) -> Iterator[bytes]:
    """CDC inside data[lo:hi]; rolling hash starts fresh at lo."""
    if lo >= hi:
        return
    mask = avg - 1
    use_mask = (avg & mask) == 0
    start = lo
    h = 0
    for i in range(lo, hi):
        h = (h * PRIME + data[i]) & 0xFFFFFFFFFFFFFFFF
        if i - start < min_chunk:
            continue
        if i - start >= max_chunk:
            yield data[start:i + 1]
            start = i + 1
            h = 0
            continue
        if use_mask:
            if (h & mask) == 0:
                yield data[start:i + 1]
                start = i + 1
                h = 0
        else:
            if h % avg == 0:
                yield data[start:i + 1]
                start = i + 1
                h = 0
    if start < hi:
        yield data[start:hi]


def cdc_split(data: bytes, avg: int = 4096, min_chunk: int = 1024,
              max_chunk: int = 16384, buf_size: int = 0) -> Iterator[bytes]:
    """Yield chunks of `data` using a rolling-hash CDC algorithm.

    avg, min_chunk, max_chunk are byte counts. When buf_size > 0 the
    rolling hash is reset at every buffer boundary so identical
    buffers produce identical chunk sequences (this is what makes
    long-range duplicates dedupe cleanly). buf_size = 0 means single
    buffer (legacy behaviour).
    """
    if not data:
        return
    n = len(data)
    if buf_size <= 0:
        yield from _cdc_split_buffer(data, 0, n, avg, min_chunk, max_chunk)
        return
    lo = 0
    while lo < n:
        hi = min(lo + buf_size, n)
        yield from _cdc_split_buffer(data, lo, hi, avg, min_chunk, max_chunk)
        lo = hi


# ---------------------------------------------------------------------------
# Hash for dedup
# ---------------------------------------------------------------------------
# Real C++ implementation will use VMAC (matching FA 0.11). Python
# stdlib has no VMAC, so the prototype uses the first 8 bytes of
# SHA-256 as a 64-bit hash with the same collision profile.

def chunk_hash(chunk: bytes) -> int:
    return int.from_bytes(hashlib.sha256(chunk).digest()[:8], 'little')


# ---------------------------------------------------------------------------
# Varint (unsigned LEB128) for ref indices
# ---------------------------------------------------------------------------

def varint_encode(value: int) -> bytes:
    if value < 0:
        raise ValueError("varint must be non-negative")
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def varint_decode(stream: io.BytesIO) -> int:
    result = 0
    shift = 0
    while True:
        b = stream.read(1)
        if not b:
            raise EOFError("varint truncated")
        v = b[0]
        result |= (v & 0x7F) << shift
        if not (v & 0x80):
            return result
        shift += 7
        if shift > 63:
            raise ValueError("varint too large")


# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

MAGIC = b"DUPR"
VERSION = 1
TAG_UNIQUE = 0
TAG_REF = 1


def encode(data: bytes, *, avg: int = 4096, min_chunk: int = 1024,
           max_chunk: int = 16384, buf_size: int = 0) -> bytes:
    """Run the -dup pre-pass over `data` and return the .dupref bytes."""
    chunks = list(cdc_split(data, avg=avg, min_chunk=min_chunk,
                            max_chunk=max_chunk, buf_size=buf_size))
    if not chunks:
        return struct.pack("<4sIQQ", MAGIC, VERSION, 0, 0)

    # Map first-occurrence-by-content to the index of the unique chunk
    # in the *unique* list (not the chunk-stream index).
    seen: dict[int, int] = {}                     # content_hash -> unique_index
    unique_bytes: list[bytes] = []
    records: list[tuple[int, int]] = []           # (tag, payload)

    for chunk in chunks:
        h = chunk_hash(chunk)
        if h in seen:
            unique_idx = seen[h]
            if unique_bytes[unique_idx] == chunk:
                records.append((TAG_REF, unique_idx))
                continue
            # Hash collision (different bytes, same hash): treat as unique.
        seen[h] = len(unique_bytes)
        records.append((TAG_UNIQUE, len(chunk)))
        unique_bytes.append(chunk)

    out = io.BytesIO()
    out.write(struct.pack("<4sIQQ", MAGIC, VERSION,
                          len(chunks), len(unique_bytes)))
    for tag, payload in records:
        out.write(struct.pack("<B", tag))
        if tag == TAG_UNIQUE:
            out.write(struct.pack("<I", payload))
        elif tag == TAG_REF:
            out.write(varint_encode(payload))
        else:
            raise ValueError(f"unknown tag {tag}")
    out.write(b"".join(unique_bytes))
    return out.getvalue()


# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

def decode(blob: bytes) -> bytes:
    stream = io.BytesIO(blob)
    header = stream.read(24)
    if len(header) < 24:
        raise ValueError("truncated header")
    magic, version, chunk_count, unique_count = struct.unpack(
        "<4sIQQ", header)
    if magic != MAGIC:
        raise ValueError(f"bad magic: {magic!r}")
    if version != VERSION:
        raise ValueError(f"unsupported version: {version}")

    records: list[tuple[int, int]] = []
    for i in range(chunk_count):
        tag_byte = stream.read(1)
        if not tag_byte:
            raise ValueError("truncated chunk table")
        tag = tag_byte[0]
        if tag == TAG_UNIQUE:
            (length,) = struct.unpack("<I", stream.read(4))
            records.append((TAG_UNIQUE, length))
        elif tag == TAG_REF:
            ref = varint_decode(stream)
            if ref >= unique_count:
                raise ValueError(
                    f"chunk {i} ref={ref} exceeds unique_count={unique_count}")
            records.append((TAG_REF, ref))
        else:
            raise ValueError(f"bad tag {tag} at chunk {i}")

    unique_bytes: list[bytes] = []
    for tag, payload in records:
        if tag == TAG_UNIQUE:
            data = stream.read(payload)
            if len(data) != payload:
                raise ValueError("truncated body")
            unique_bytes.append(data)

    if len(unique_bytes) != unique_count:
        raise ValueError(
            f"unique_count={unique_count} but body had {len(unique_bytes)} chunks")

    out = bytearray()
    next_unique = 0
    for tag, payload in records:
        if tag == TAG_UNIQUE:
            out.extend(unique_bytes[next_unique])
            next_unique += 1
        else:
            out.extend(unique_bytes[payload])
    return bytes(out)


# ---------------------------------------------------------------------------
# Self-test + CLI
# ---------------------------------------------------------------------------

def _check_roundtrip(name: str, data: bytes, **kwargs) -> tuple[int, int]:
    encoded = encode(data, **kwargs)
    decoded = decode(encoded)
    assert decoded == data, f"{name}: round-trip mismatch"
    pct = int((len(encoded) / len(data)) * 100) if data else 0
    return len(encoded), pct


def selftest() -> None:
    cases: list[tuple[str, bytes]] = [
        ("empty", b""),
        ("zeros-64k", b"\x00" * 65536),
        ("text-1m", (b"Omega SREP dup test payload " * 40000)[:1_000_000]),
        ("dup-pattern", (b"AAAA" * 1024 + b"BBBB" * 1024) * 100),
    ]
    rng = random.Random(42)
    cases.append(("random-256k",
                  bytes(rng.randint(0, 255) for _ in range(262144))))
    half = bytes(random.Random(7).randint(0, 255) for _ in range(131072))
    cases.append(("doubled-random-256k", half + half))

    print(f"{'case':<22} {'in_size':>8} {'enc_size':>9} {'enc_pct':>8}")
    for name, data in cases:
        enc_size, pct = _check_roundtrip(name, data)
        print(f"{name:<22} {len(data):>8} {enc_size:>9} {pct:>7}%")
    print("all round-trips OK")


def _cli() -> int:
    p = argparse.ArgumentParser(description="Omega SREP -dup prototype.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    enc = sub.add_parser("encode")
    enc.add_argument("input")
    enc.add_argument("output")
    enc.add_argument("--avg", type=int, default=4096)
    enc.add_argument("--min", dest="min_chunk", type=int, default=1024)
    enc.add_argument("--max", dest="max_chunk", type=int, default=16384)
    enc.add_argument("--buf", dest="buf_size", type=int, default=0,
                     help="bytes per CDC buffer; 0 = single buffer (legacy)")
    dec = sub.add_parser("decode")
    dec.add_argument("input")
    dec.add_argument("output")
    args = p.parse_args()

    if args.cmd == "selftest":
        selftest()
        return 0
    if args.cmd == "encode":
        with open(args.input, "rb") as f:
            data = f.read()
        encoded = encode(data, avg=args.avg, min_chunk=args.min_chunk,
                         max_chunk=args.max_chunk, buf_size=args.buf_size)
        with open(args.output, "wb") as f:
            f.write(encoded)
        ratio = len(encoded) / max(len(data), 1)
        print(f"input={len(data)} output={len(encoded)} ratio={ratio:.4f}")
        return 0
    if args.cmd == "decode":
        with open(args.input, "rb") as f:
            blob = f.read()
        decoded = decode(blob)
        with open(args.output, "wb") as f:
            f.write(decoded)
        print(f"input={len(blob)} output={len(decoded)}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_cli())
