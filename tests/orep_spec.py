#!/usr/bin/env python3
"""OREP stream format, version 4: an independent decoder written only from
spec/orep-format.md (not from the Pascal decoder), plus a structure-level
stream builder and mutator for fuzzing the real decoders.

    orep_spec.py decode <stream> [<out>]      oracle decode; prints
                                             'valid <size> <sha256>' or
                                             'invalid <class> <reason>'
    orep_spec.py roundtrip <stream>          parse + re-serialize, must be
                                             byte-identical
    orep_spec.py gen --seed S --n N --dir D [--seeds-dir P]
                                             write N cases (D/case-*.orep)
                                             and D/manifest.tsv with the
                                             oracle's verdict per case

Verdicts: 'valid' (the output is defined), or 'invalid' with a class:
'version' (magic, version or unknown flags: the spec says "unsupported
version") or 'data' (everything else).  Policy points the spec leaves open
are in AMBIGUITIES below; the oracle follows the stricter reading only where
the spec says so, and the fuzzer tags cases that hit an open point so a
disagreement there is reported as a spec question, not as a bug.
"""
import hashlib
import os
import random
import struct
import sys

AMBIGUITIES = """
- settled in the spec (2026-11-20): every varint has at most 5 bytes and a
  value below 2^32, except the end's total (10 bytes, below 2^64); longer
  than needed forms are valid within those limits; header checks run in the
  order varint limits, CRC, ranges (all 'data'), then flags ('version');
  min match takes any value; a streaming decoder leaves bytes after the end
  to its caller (this oracle is whole-buffer: trailing bytes are invalid).
"""

# ---------------------------------------------------------------- CRC-32C
_T = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ 0x82F63B78 if _c & 1 else _c >> 1
    _T.append(_c)
_CRC_CACHE = {}


def crc32c(b):
    b = bytes(b)
    if len(b) > 256:
        r = _CRC_CACHE.get(b)
        if r is not None:
            return r
    c = 0xFFFFFFFF
    t = _T
    for x in b:
        c = t[(c ^ x) & 0xFF] ^ (c >> 8)
    c ^= 0xFFFFFFFF
    if len(b) > 256:
        if len(_CRC_CACHE) > 4000:
            _CRC_CACHE.clear()
        _CRC_CACHE[b] = c
    return c


assert crc32c(b"123456789") == 0xE3069283


# ---------------------------------------------------------------- decoder
class Invalid(Exception):
    def __init__(self, cls, why):
        Exception.__init__(self, why)
        self.cls = cls
        self.why = why


def _varint(buf, off, maxbytes, maxval, what, cls="data", end=None):
    v = 0
    shift = 0
    if end is None:
        end = len(buf)
    for k in range(maxbytes):
        if off + k >= end:
            raise Invalid("data", "truncated in %s" % what)
        x = buf[off + k]
        v |= (x & 0x7F) << shift
        shift += 7
        if not x & 0x80:
            if v > maxval:
                raise Invalid(cls, "%s = %d too large" % (what, v))
            return v, off + k + 1
    raise Invalid(cls, "%s varint longer than %d bytes" % (what, maxbytes))


U32 = (1 << 32) - 1
U64 = (1 << 64) - 1


def decode(buf, want_struct=False):
    """Returns (output bytes, structure or None). Raises Invalid."""
    buf = bytes(buf)
    if len(buf) < 6:
        raise Invalid("version" if buf[:len(buf)] != b"OREP"[:len(buf)]
                      else "data", "short header")
    if buf[:4] != b"OREP":
        raise Invalid("version", "magic")
    if buf[4] != 4:
        raise Invalid("version", "version %d" % buf[4])
    clog = buf[5]
    off = 6
    W, off = _varint(buf, off, 5, U32, "window")
    align, off = _varint(buf, off, 5, U32, "align")
    mm, off = _varint(buf, off, 5, U32, "minmatch")
    flags, off = _varint(buf, off, 5, U32, "flags")
    if off + 4 > len(buf):
        raise Invalid("data", "truncated header crc")
    hcrc = struct.unpack_from("<I", buf, off)[0]
    if hcrc != crc32c(buf[:off]):
        raise Invalid("data", "header crc")
    off += 4
    if not 16 <= clog <= 26:
        raise Invalid("data", "chunk log2 %d" % clog)
    if not 1 <= W <= 0xF0000000:
        raise Invalid("data", "window %d" % W)
    if align > 4096:
        raise Invalid("data", "align %d" % align)
    if flags != 0:
        raise Invalid("version", "flags %d" % flags)
    C = 1 << clog
    st = {"clog": clog, "W": W, "align": align, "mm": mm, "flags": 0,
          "blocks": []}
    out = bytearray()
    while True:
        pos = len(out)
        out_size, off = _varint(buf, off, 5, U32, "out_size")
        if out_size == 0:
            total, off = _varint(buf, off, 10, U64, "total")
            if total != pos:
                raise Invalid("data", "total %d != %d" % (total, pos))
            if off != len(buf):
                raise Invalid("data", "trailing bytes")
            break
        if out_size > C or (pos % C) + out_size > C:
            raise Invalid("data", "out_size %d at %d" % (out_size, pos))
        n, off = _varint(buf, off, 5, U32, "n")
        if n > out_size // 16:
            raise Invalid("data", "n %d" % n)
        col_size, off = _varint(buf, off, 5, U32, "col_size")
        if not 3 * n <= col_size <= 15 * n:
            raise Invalid("data", "col_size %d n %d" % (col_size, n))
        A, off = _varint(buf, off, 5, U32, "A")
        if not 1 <= A <= 4096:
            raise Invalid("data", "A %d" % A)
        cend = off + col_size
        if cend > len(buf):
            raise Invalid("data", "truncated columns")
        cols = []
        for k in range(3 * n):
            if off >= cend:
                raise Invalid("data", "columns shorter than 3n varints")
            v, off = _varint(buf, off, 5, U32, "column", end=cend)
            cols.append(v)
        if off != cend:
            raise Invalid("data", "columns do not fill col_size")
        lit = cols[0:n]
        ln = [v + 16 for v in cols[n:2 * n]]
        dist = [v + 1 for v in cols[2 * n:3 * n]]
        q = off
        npad = (pos - q) % A
        if off + npad > len(buf):
            raise Invalid("data", "truncated padding")
        if any(buf[off:off + npad]):
            raise Invalid("data", "padding not zero")
        off += npad
        cum = 0
        for i in range(n):
            mpos = pos + cum + lit[i]
            cum += lit[i] + ln[i]
            if cum > out_size:
                raise Invalid("data", "match %d past out_size" % i)
            if dist[i] > W or dist[i] > mpos:
                raise Invalid("data", "dist %d at %d (W %d)" % (dist[i], mpos, W))
        L = out_size - sum(ln)
        if off + L > len(buf):
            raise Invalid("data", "truncated literals")
        lits = buf[off:off + L]
        off += L
        lp = 0
        for i in range(n):
            out += lits[lp:lp + lit[i]]
            lp += lit[i]
            d = dist[i]
            m = ln[i]
            s = len(out) - d
            if d >= m:
                out += out[s:s + m]
            else:
                pat = bytes(out[s:s + d])
                rep = (pat * (m // d + 1))[:m]
                out += rep
        out += lits[lp:]
        if len(out) - pos != out_size:
            raise AssertionError("oracle bug")
        if off + 4 > len(buf):
            raise Invalid("data", "truncated block crc")
        bcrc = struct.unpack_from("<I", buf, off)[0]
        off += 4
        if bcrc != crc32c(out[pos:]):
            raise Invalid("data", "block crc")
        if want_struct:
            st["blocks"].append({"litv": lit, "lenv": cols[n:2 * n],
                                 "distv": cols[2 * n:3 * n], "A": A,
                                 "literals": bytes(lits)})
    return bytes(out), st


def ring_size(W, clog):
    C = 1 << clog
    return -(-W // C) * C + C


# ---------------------------------------------------------------- builder
def enc(v, nbytes=None):
    """LEB128 of v, padded to nbytes with continuation bytes if given."""
    if v < 0:
        v &= U64
    b = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        if v:
            b.append(x | 0x80)
        else:
            b.append(x)
            break
    if nbytes is not None and nbytes > len(b):
        b[-1] |= 0x80
        while len(b) < nbytes - 1:
            b.append(0x80)
        b.append(0)
    return bytes(b)


def new_block(litv, lenv, distv, A, literals):
    return {"litv": list(litv), "lenv": list(lenv), "distv": list(distv),
            "A": A, "literals": bytes(literals), "ov": {}}


def lenient_output(blk, hist):
    """What the block writes, decoding without any check (zeros where the
    source does not exist)."""
    o = bytearray()
    lits = blk["literals"]
    lp = 0
    base = len(hist)
    for i in range(min(len(blk["litv"]), len(blk["lenv"]), len(blk["distv"]))):
        k = blk["litv"][i]
        if k > 1 << 20:
            break
        o += lits[lp:lp + k]
        lp += k
        m = blk["lenv"][i] + 16
        d = blk["distv"][i] + 1
        if m > 1 << 20:
            break
        for _ in range(m):
            p = base + len(o) - d
            if p < 0:
                o.append(0)
            elif p < base:
                o.append(hist[p])
            else:
                o.append(o[p - base])
    o += lits[lp:]
    return o


def serialize(s):
    """s: {'hdr': {...}, 'blocks': [...], 'end': {...}}; overrides in the
    'ov' dicts. Returns bytes."""
    h = s["hdr"]
    hv = h.get("ov", {})
    b = bytearray(hv.get("magic", b"OREP"))
    b.append(hv.get("version", 4))
    b.append(h["clog"])
    for f in ("W", "align", "mm", "flags"):
        b += hv.get(f + "_raw") or enc(h[f], hv.get(f + "_nb"))
    crc = crc32c(b)
    b += struct.pack("<I", hv.get("crc", crc) & U32)
    hist = bytearray()
    for blk in s["blocks"]:
        ov = blk.get("ov", {})
        pos = len(hist)
        out = lenient_output(blk, hist)
        out_size = ov.get("out_size", sum(v + 16 for v in blk["lenv"]) +
                          len(blk["literals"]))
        cnb = ov.get("col_nb", {})
        cols = bytearray()
        k = 0
        for col in ("litv", "lenv", "distv"):
            for v in blk[col]:
                cols += enc(v, cnb.get(k))
                k += 1
        cols += ov.get("col_extra", b"")
        b += ov.get("out_size_raw") or enc(out_size, ov.get("out_size_nb"))
        b += enc(ov.get("n", len(blk["litv"])), ov.get("n_nb"))
        b += enc(ov.get("col_size", len(cols)), ov.get("col_size_nb"))
        b += enc(blk["A"], ov.get("A_nb"))
        b += cols
        q = len(b)
        A = blk["A"]
        pad = ov.get("pad")
        if pad is None:
            pad = bytes((pos - q) % A) if 0 < A <= 4096 else b""
        b += pad
        b += blk["literals"]
        b += struct.pack("<I", ov.get("crc", crc32c(out)) & U32)
        hist += out
    e = s.get("end", {})
    b += e.get("zero_raw", b"\x00")
    b += enc(e.get("total", len(hist)) & U64, e.get("total_nb"))
    b += e.get("trailing", b"")
    if "truncate" in s:
        b = b[:s["truncate"]]
    return bytes(b)


def from_struct(st):
    return {"hdr": {"clog": st["clog"], "W": st["W"], "align": st["align"],
                    "mm": st["mm"], "flags": 0, "ov": {}},
            "blocks": [new_block(x["litv"], x["lenv"], x["distv"], x["A"],
                                 x["literals"]) for x in st["blocks"]],
            "end": {}}


def deep(s):
    import copy
    return copy.deepcopy(s)


# ---------------------------------------------------------------- synthetic
def synth(rng):
    clog = rng.choice([16, 16, 16, 17, 18])
    C = 1 << clog
    total = rng.choice([0, 1, 100, C - 1, C, C + 1, 2 * C + 77,
                        rng.randrange(1, 3 * C)])
    total = min(total, 3 * C)
    W = rng.choice([1, 2, 16, 17, 1000, C - 1, C, C + 1, 2 * C - 1,
                    rng.randrange(1, 4 * C), 0xF0000000 if rng.random() < .1
                    else rng.randrange(1, 300000)])
    align = rng.choice([0, 1, 4, 4096, rng.randrange(0, 4097)])
    s = {"hdr": {"clog": clog, "W": W, "align": align,
                 "mm": rng.choice([16, 32, 64, 65536, rng.randrange(0, 1 << 21)]),
                 "flags": 0, "ov": {}}, "blocks": [], "end": {}}
    hist = bytearray()
    alpha = rng.choice([2, 4, 26, 256])
    tab = bytes(i % alpha for i in range(256))
    while len(hist) < total:
        pos = len(hist)
        room = min(C - pos % C, total - pos)
        osz = rng.choice([room, room, rng.randrange(1, room + 1)])
        A = rng.choice([1, 1, 4, 4, 2, 16, 4096, rng.randrange(1, 4097)])
        litv, lenv, distv = [], [], []
        literals = bytearray()
        got = 0
        out = bytearray()
        while osz - got >= 16 and rng.random() < 0.85:
            lit = rng.choice([0, 0, 1, rng.randrange(0, 200)])
            lit = min(lit, osz - got - 16)
            mpos = pos + got + lit
            maxd = min(W, mpos)
            if maxd < 1:
                break
            m = rng.choice([16, 17, rng.randrange(16, 64),
                            rng.randrange(16, osz - got - lit + 1)])
            m = min(m, osz - got - lit)
            d = rng.choice([1, maxd, maxd, rng.randrange(1, maxd + 1),
                            min(maxd, rng.randrange(1, 40))])
            lb = rng.randbytes(lit).translate(tab)
            literals += lb
            out += lb
            for _ in range(m):
                p = pos + len(out) - d
                out.append(hist[p] if p < pos else out[p - pos])
            litv.append(lit)
            lenv.append(m - 16)
            distv.append(d - 1)
            got += lit + m
            if len(litv) >= osz // 16:
                break
        tail = rng.randbytes(osz - got).translate(tab)
        literals += tail
        out += tail
        s["blocks"].append(new_block(litv, lenv, distv, A, literals))
        hist += out
    return s


# ---------------------------------------------------------------- mutator
def match_positions(s):
    """[(block index, match index, absolute match position)]"""
    res = []
    pos = 0
    for bi, blk in enumerate(s["blocks"]):
        cum = 0
        for i in range(len(blk["litv"])):
            mp = pos + cum + blk["litv"][i]
            res.append((bi, i, mp))
            cum += blk["litv"][i] + blk["lenv"][i] + 16
        pos += sum(v + 16 for v in blk["lenv"]) + len(blk["literals"])
    return res


def block_starts(s):
    r = []
    pos = 0
    for blk in s["blocks"]:
        r.append(pos)
        pos += sum(v + 16 for v in blk["lenv"]) + len(blk["literals"])
    return r


EDGE32 = [0, 1, 15, 16, 17, 0x7F, 0x80, 0x3FFF, 0x4000, 0xFFFF, 0x10000,
          0x7FFFFFFF, 0x80000000, 0xEFFFFFFF, 0xF0000000, 0xF0000001,
          0xFFFFFFF0, 0xFFFFFFFE, U32, 1 << 32, (1 << 35) - 1]


def mutate(s, rng):
    """Applies one structure-level mutation; returns its tag. CRCs are
    recomputed by serialize() unless the mutation overrides them."""
    h = s["hdr"]
    hv = h["ov"]
    C = 1 << h["clog"]
    W = h["W"]
    blocks = s["blocks"]
    mps = match_positions(s)
    starts = block_starts(s)
    ops = ["hdr"] * 4 + ["end"] * 2 + ["trunc", "trail"]
    if blocks:
        ops += ["blk"] * 8 + ["pad", "lits", "colenc", "struct"] * 2
    if mps:
        ops += ["match"] * 10
    op = rng.choice(ops)
    if op == "hdr":
        f = rng.choice(["version", "clog", "W", "align", "flags", "mm",
                        "nb", "crc", "magic", "W_hostile"])
        if f == "version":
            hv["version"] = rng.choice([0, 3, 5, 255])
        elif f == "clog":
            h["clog"] = rng.choice([0, 15, 16, 26, 27, 63, 255])
        elif f == "W":
            h["W"] = rng.choice([0, 1, 0xF0000000, 0xF0000001, U32, 1 << 32,
                                 W - 1, W + 1])
        elif f == "W_hostile":
            # shrink the window under the largest distance used
            dmax = max([1] + [b["distv"][i] + 1 for b in blocks
                              for i in range(len(b["distv"]))])
            h["W"] = rng.choice([dmax - 1, dmax, max(dmax - 1, 1)])
        elif f == "align":
            h["align"] = rng.choice([0, 4095, 4096, 4097, U32, 1 << 40])
        elif f == "flags":
            h["flags"] = rng.choice([1, 2, 1 << 31, U32, 1 << 32, 1 << 35])
        elif f == "mm":
            h["mm"] = rng.choice([0, 1 << 21, (1 << 21) - 1, U32, 1 << 40,
                                  U64])
        elif f == "nb":
            g = rng.choice(["W", "align", "mm", "flags"])
            hv[g + "_nb"] = rng.choice([2, 3, 4, 5, 6, 10, 11])
            return "hdr_nb_%s_%d" % (g, hv[g + "_nb"])
        elif f == "crc":
            hv["crc"] = rng.randrange(1 << 32)
        elif f == "magic":
            hv["magic"] = rng.choice([b"OREq", b"PREP", b"OREP"[:3] + b"\x00"])
        return "hdr_" + f
    if op == "end":
        e = s["end"]
        f = rng.choice(["total", "total_nb", "zero"])
        tot = starts[-1] + sum(v + 16 for v in blocks[-1]["lenv"]) + \
            len(blocks[-1]["literals"]) if blocks else 0
        if f == "total":
            e["total"] = rng.choice([tot - 1, tot + 1, 0, U32, U64, 1 << 64])
        elif f == "total_nb":
            e["total_nb"] = rng.choice([2, 5, 10, 11])
            return "end_total_nb_%d" % e["total_nb"]
        else:
            e["zero_raw"] = rng.choice([b"\x80\x00", b"\x80\x80\x80\x80\x00",
                                        b"\x80" * 10 + b"\x00"])
            return "end_zero_overlong"
        return "end_" + f
    if op == "trunc":
        s["truncate"] = -rng.randrange(1, 40)
        return "truncate"
    if op == "trail":
        s["end"]["trailing"] = rng.choice([b"\x00", b"\xff", b"OREP",
                                           b"\x00\x00"])
        return "trailing"
    bi = rng.randrange(len(blocks)) if blocks else 0
    blk = blocks[bi] if blocks else None
    ov = blk["ov"] if blk else None
    osz = sum(v + 16 for v in blk["lenv"]) + len(blk["literals"]) if blk else 0
    if op == "blk":
        f = rng.choice(["out_size", "n", "col_size", "A", "crc", "cross",
                        "out_size_nb", "big"])
        if f == "out_size":
            ov["out_size"] = rng.choice([osz - 1, osz + 1, C, C + 1, U32,
                                         1 << 40])
        elif f == "n":
            nn = len(blk["litv"])
            ov["n"] = rng.choice([nn - 1 if nn else 1, nn + 1, osz // 16 + 1,
                                  U32])
        elif f == "col_size":
            nn = len(blk["litv"])
            cs = sum(len(enc(v)) for c in ("litv", "lenv", "distv")
                     for v in blk[c])
            ov["col_size"] = rng.choice([cs - 1, cs + 1, 3 * nn - 1,
                                         15 * nn + 1, 0, U32])
            if ov["col_size"] < 0:
                ov["col_size"] = 0
        elif f == "A":
            blk["A"] = rng.choice([0, 1, 2, 3, 4095, 4096, 4097, U32])
            if blk["A"] == 0 or blk["A"] > 4096:
                ov["pad"] = b""
        elif f == "crc":
            ov["crc"] = rng.randrange(1 << 32)
        elif f == "out_size_nb":
            k = rng.choice(["out_size_nb", "n_nb", "col_size_nb", "A_nb"])
            ov[k] = rng.choice([2, 5, 6, 10, 11])
            return "blk_%s_%d" % (k, ov[k])
        elif f == "cross":
            # grow the block by literals so it crosses its slot
            pos = starts[bi]
            extra = C - (pos % C) - osz + rng.choice([0, 1, 16])
            if extra > 0 and extra < (1 << 20):
                blk["literals"] += rng.randbytes(extra)
        elif f == "big":
            # a block of exactly the room left in its slot (valid) or one more
            pos = starts[bi]
            extra = C - (pos % C) - osz
            if bi == len(blocks) - 1 and 0 < extra < (1 << 20):
                blk["literals"] += bytes(extra + rng.choice([0, 0, 1]))
        return "blk_" + f
    if op == "pad":
        pos = starts[bi]
        f = rng.choice(["nonzero", "short", "long"])
        # padding length needs the column bytes: compute it by serializing
        A = blk["A"]
        if A <= 1 or A > 4096:
            blk["A"] = A = rng.choice([4, 4096])
        # find padding length as serialize() would: re-derive quickly
        q = _col_end(s, bi)
        npad = (pos - q) % A
        if f == "nonzero" and npad:
            p = bytearray(npad)
            p[rng.randrange(npad)] = rng.randrange(1, 256)
            ov["pad"] = bytes(p)
        elif f == "short" and npad:
            ov["pad"] = bytes(npad - 1)
        else:
            ov["pad"] = bytes(npad + 1)
        return "pad_" + f
    if op == "lits":
        f = rng.choice(["short", "long"])
        if f == "short" and blk["literals"]:
            # out_size kept, literals one short (the decoder must read past)
            ov["out_size"] = osz
            blk["literals"] = blk["literals"][:-1]
        else:
            ov["out_size"] = osz
            blk["literals"] += b"\x00"
        return "lits_" + f
    if op == "colenc":
        k = sum(len(blk[c]) for c in ("litv", "lenv", "distv"))
        if k:
            nb = rng.choice([2, 5, 5, 6])
            which = rng.choice(["one", "all"])
            if which == "one":
                ov["col_nb"] = {rng.randrange(k): nb}
            else:
                ov["col_nb"] = {j: nb for j in range(k)}
            return "colenc_%s_%d" % (which, nb)
        ov["col_extra"] = b"\x00"
        return "col_extra"
    if op == "struct":
        f = rng.choice(["drop", "swap", "dup", "merge_slot"])
        if f == "drop":
            del blocks[bi]
        elif f == "swap" and len(blocks) > 1:
            j = rng.randrange(len(blocks))
            blocks[bi], blocks[j] = blocks[j], blocks[bi]
        elif f == "dup":
            import copy
            blocks.insert(bi, copy.deepcopy(blk))
        else:
            # split the block in two inside the same slot (valid when the
            # split point is between matches)
            if blk["litv"]:
                i = rng.randrange(len(blk["litv"]))
                lp = sum(blk["litv"][:i + 1])
                tail_lits = blk["literals"][lp:]
                b1 = new_block(blk["litv"][:i + 1], blk["lenv"][:i + 1],
                               blk["distv"][:i + 1], blk["A"],
                               blk["literals"][:lp])
                b2 = new_block(blk["litv"][i + 1:], blk["lenv"][i + 1:],
                               blk["distv"][i + 1:],
                               rng.choice([1, 4, 4096]), tail_lits)
                blocks[bi:bi + 1] = [b1, b2]
        return "struct_" + f
    # match field mutations
    bi, i, mp = rng.choice(mps)
    blk = blocks[bi]
    ov = blk["ov"]
    f = rng.choice(["dist", "dist", "dist", "len", "lit", "dist_ok"])
    if f == "dist":
        d = rng.choice([mp, mp + 1, W, W + 1, 0x100000000, mp + W,
                        rng.choice(EDGE32)])
        blk["distv"][i] = max(d - 1, 0) if d > 0 else 0
        if d == 0:
            blk["distv"][i] = 0
        return "dist_%s" % ("pos" if d == mp else "pos+1" if d == mp + 1
                            else "W" if d == W else "W+1" if d == W + 1
                            else "edge")
    if f == "dist_ok":
        d = min(mp, W)
        if d >= 1:
            blk["distv"][i] = d - 1
        return "dist_max_ok"
    if f == "len":
        rest = osz - sum(blk["litv"][:i + 1]) - \
            sum(v + 16 for v in blk["lenv"][:i + 1])
        v = rng.choice([0, U32, (1 << 32), blk["lenv"][i] + rest,
                        blk["lenv"][i] + rest + 1, rng.choice(EDGE32)])
        delta = v - blk["lenv"][i]
        blk["lenv"][i] = v
        if rng.random() < 0.5 and 0 <= delta <= rest:
            # keep out_size: take the bytes from the literals
            cut = len(blk["literals"]) - delta
            blk["literals"] = blk["literals"][:max(cut, 0)]
        return "len_edge"
    v = rng.choice([0, U32, 1 << 32, blk["litv"][i] + 1, rng.choice(EDGE32)])
    blk["litv"][i] = v
    return "lit_edge"


def _col_end(s, bi):
    """Stream offset right after block bi's columns."""
    t = deep(s)
    t["blocks"] = t["blocks"][:bi + 1]
    blk = t["blocks"][bi]
    blk["literals"] = b""
    blk["ov"].pop("pad", None)
    blk["A"] = 1
    blk["ov"].pop("crc", None)
    t["end"] = {}
    t.pop("truncate", None)
    raw = serialize(t)
    # strip: crc(4) + end(2+ bytes: 0x00 + total varint)
    tot = sum(sum(v + 16 for v in b["lenv"]) + len(b["literals"])
              for b in t["blocks"])
    return len(raw) - 4 - 1 - len(enc(tot))


# ---------------------------------------------------------------- generator
def oracle(raw):
    try:
        out, _ = decode(raw)
        return "valid", out
    except Invalid as e:
        return "invalid", e


AMBIG_TAGS = ()   # the spec settled every open point (2026-11-20)


def gen(seed, n, outdir, seeds_dir=None):
    rng = random.Random(seed)
    pool = []
    if seeds_dir and os.path.isdir(seeds_dir):
        for fn in sorted(os.listdir(seeds_dir)):
            if fn.endswith(".orep"):
                raw = open(os.path.join(seeds_dir, fn), "rb").read()
                try:
                    _, st = decode(raw, True)
                except Invalid:
                    continue
                pool.append((fn, from_struct(st)))
    os.makedirs(outdir, exist_ok=True)
    man = open(os.path.join(outdir, "manifest.tsv"), "w")
    for k in range(n):
        if pool and rng.random() < 0.5:
            name, base = rng.choice(pool)
            s = deep(base)
            src = "seed:" + name
        else:
            s = synth(rng)
            src = "synth"
        tags = []
        for _ in range(rng.choice([0, 1, 1, 1, 2, 3])):
            try:
                tags.append(mutate(s, rng))
            except (ValueError, IndexError):
                pass
        raw = serialize(s)
        v, x = oracle(raw)
        fn = "case-%d-%05d.orep" % (seed, k)
        open(os.path.join(outdir, fn), "wb").write(raw)
        tag = "+".join(tags) or "none"
        amb = "ambig" if any(t in tag for t in AMBIG_TAGS) else "-"
        R = ring_size(s["hdr"]["W"], s["hdr"]["clog"]) \
            if 0 < s["hdr"]["clog"] < 64 else 0
        if v == "valid":
            man.write("%s\tvalid\t%s\t%d\t%s\t%s\t%s\n" % (
                fn, hashlib.sha256(x).hexdigest(), R, src, tag, amb))
        else:
            man.write("%s\tinvalid:%s\t%s\t%d\t%s\t%s\t%s\n" % (
                fn, x.cls, x.why.replace("\t", " "), R, src, tag, amb))
    man.close()


def main():
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (3 << 30, 3 << 30))
    except (ImportError, ValueError):
        pass
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        sys.exit(2)
    if a[0] == "decode":
        raw = open(a[1], "rb").read()
        try:
            out, _ = decode(raw)
        except Invalid as e:
            print("invalid", e.cls, e.why)
            sys.exit(1)
        if len(a) > 2:
            open(a[2], "wb").write(out)
        print("valid", len(out), hashlib.sha256(out).hexdigest())
    elif a[0] == "roundtrip":
        raw = open(a[1], "rb").read()
        _, st = decode(raw, True)
        again = serialize(from_struct(st))
        if again != raw:
            print("roundtrip differs")
            sys.exit(1)
        print("roundtrip ok")
    elif a[0] == "gen":
        opts = dict(zip(a[1::2], a[2::2]))
        gen(int(opts["--seed"]), int(opts["--n"]), opts["--dir"],
            opts.get("--seeds-dir"))
    elif a[0] == "ambiguities":
        print(AMBIGUITIES)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
