#!/usr/bin/env python3
"""Structure-aware fuzzer for the v7 decoder (format-v7.md).

usage: fuzz_v7.py OSREP SEED_DIR WORK_DIR CASES [RNG_SEED]

Every case takes one seed archive (*.osr in SEED_DIR), mutates it and runs
`osrep -d` and `osrep --verify` on it.  Most mutations rebuild the archive
with valid CRCs (header, match table, footer), so the decoder's semantic
checks are reached and not only the CRC ones.  A case fails when the
decoder crashes, hangs, reports an RTL error (range check, access
violation: the binary is built with -Cr -Ct -CR), exits with
a code outside the documented ones, or accepts an archive whose output
differs from what its digests allow.  Failing cases are kept in
WORK_DIR/bad-*.osr.  Deterministic for a given RNG_SEED.
"""
import os
import random
import struct
import subprocess
import sys

# --- CRC-32C (Castagnoli, reflected 0x82F63B78) ---------------------------
_T = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ 0x82F63B78 if _c & 1 else _c >> 1
    _T.append(_c)


def crc32c(b, crc=0):
    # format-v6.md 2.5: initial value 0, no final XOR
    for x in b:
        crc = _T[(crc ^ x) & 0xFF] ^ (crc >> 8)
    return crc


def venc(v):
    o = bytearray()
    while v >= 0x80:
        o.append((v & 0x7F) | 0x80)
        v >>= 7
    o.append(v)
    return bytes(o)


def vdec(b, p):
    v = s = 0
    while True:
        c = b[p]
        p += 1
        v |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return v, p


HDR, FTR, BLKH = 28, 36, 16


class Archive:
    """A parsed v7 archive that can be written back with fresh CRCs."""

    def __init__(self, data):
        self.hdr = bytearray(data[:HDR])
        ft = data[-FTR:]
        (self.fmagic, self.fblocks, stat, self.meta_off, self.meta_size,
         self.blocks_crc, _) = struct.unpack('<IIQQIII', ft)
        # the table starts after the seed; find the seed size by its CRC
        for seed in range(0, 257):
            st = HDR + seed
            if st + stat > len(data) - FTR or stat < 12:
                continue
            tab = data[st:st + stat]
            if crc32c(tab[:-4]) == struct.unpack_from('<I', tab, len(tab) - 4)[0]:
                break
        else:
            raise ValueError('not a v7 archive')
        self.seed = data[HDR:st]
        n = struct.unpack_from('<Q', tab, 0)[0]
        p = 8
        cols = []
        for _ in range(3):
            col = []
            for _ in range(n):
                v, p = vdec(tab, p)
                col.append(v)
            cols.append(col)
        self.gap, self.len, self.dist = cols
        self.hash_size = self.hdr[7]
        self.blocks = []  # [lit, orig, stat, crc, payload]
        p = st + stat
        end = len(data) - FTR
        while p + BLKH <= end:
            lit, orig, sts, bcrc = struct.unpack_from('<IIII', data, p)
            pl = data[p + BLKH:p + BLKH + self.hash_size + lit]
            self.blocks.append([lit, orig, sts, bcrc, bytearray(pl)])
            p += BLKH + self.hash_size + lit

    def table(self, count=None, raw_cols=None):
        n = len(self.gap) if count is None else count
        if raw_cols is None:
            body = b''.join(venc(v) for v in self.gap) + \
                b''.join(venc(v) for v in self.len) + \
                b''.join(venc(v) for v in self.dist)
        else:
            body = raw_cols
        t = struct.pack('<Q', n) + body
        return t + struct.pack('<I', crc32c(t))

    def build(self, table=None, fix_hdr=True, fix_blocks=True, fix_ftr=True):
        h = bytearray(self.hdr)
        if fix_hdr:
            struct.pack_into('<I', h, 24, crc32c(h[:24]))
        tab = self.table() if table is None else table
        out = bytearray(h) + self.seed + tab
        chain = 0
        for b in self.blocks:
            lit, orig, sts, bcrc, pl = b
            if fix_blocks:
                bcrc = crc32c(pl)
            out += struct.pack('<IIII', lit, orig, sts, bcrc) + pl
            chain = crc32c(struct.pack('<I', bcrc), chain)
        bc = chain if fix_ftr else self.blocks_crc
        f = struct.pack('<IIQQII', self.fmagic, self.fblocks, len(tab),
                        self.meta_off, self.meta_size, bc)
        out += f + struct.pack('<I', crc32c(f) if fix_ftr else 0)
        return bytes(out)


BIG = [0, 1, 2, 15, 16, 17, 255, 4095, 4096, 65535, 65536, 1 << 31,
       (1 << 32) - 1, 1 << 32, 1 << 40, (1 << 63) - 1, 1 << 63,
       (1 << 64) - 1]


def pick_val(r, old):
    k = r.randrange(5)
    if k == 0:
        return r.choice(BIG)
    if k == 1:
        return max(0, old + r.randint(-3, 3))
    if k == 2:
        return old * 2
    if k == 3:
        return old // 2
    return r.randrange(0, 1 << r.randrange(1, 64))


def mutate(r, data):
    """Return (description, mutated bytes)."""
    a = Archive(data)
    n = len(a.gap)
    kind = r.randrange(12)
    if kind == 0:  # raw byte flips; CRCs stay as they were
        d = bytearray(data)
        for _ in range(r.randint(1, 8)):
            d[r.randrange(len(d))] ^= 1 << r.randrange(8)
        return 'flip', bytes(d)
    if kind == 1:  # truncate or extend
        d = bytearray(data)
        if r.randrange(2):
            return 'truncate', bytes(d[:r.randrange(len(d))])
        return 'extend', bytes(d + bytes(r.randrange(1, 64)))
    if kind in (2, 3, 4) and n:  # one table field, valid CRC
        col = r.choice([a.gap, a.len, a.dist])
        for _ in range(r.randint(1, 3)):
            i = r.randrange(n)
            col[i] = pick_val(r, col[i])
        return 'table-field', a.build()
    if kind == 5 and n:  # reorder, drop or duplicate matches
        rows = list(zip(a.gap, a.len, a.dist))
        op = r.randrange(3)
        if op == 0 and n > 1:
            i, j = r.randrange(n), r.randrange(n)
            rows[i], rows[j] = rows[j], rows[i]
        elif op == 1:
            del rows[r.randrange(n)]
        else:
            i = r.randrange(n)
            rows.insert(i, rows[i])
        a.gap = [x[0] for x in rows]
        a.len = [x[1] for x in rows]
        a.dist = [x[2] for x in rows]
        return 'table-rows', a.build()
    if kind == 6:  # count that disagrees with the columns, or odd varints
        body = bytearray(a.table()[8:-4])
        op = r.randrange(4)
        if op == 0:
            cnt = max(0, n + r.choice([-1, 1, 2, 1000, 1 << 32, 1 << 63]))
            return 'table-count', a.build(table=a.table(cnt, bytes(body)))
        if op == 1 and body:  # non-minimal varint at a random spot
            p = r.randrange(len(body) + 1)
            body[p:p] = b'\x80\x00'
        elif op == 2:  # an over-long varint (more than 64 bits)
            p = r.randrange(len(body) + 1)
            body[p:p] = b'\xff' * r.randint(9, 12) + b'\x01'
        elif body:  # trailing or missing bytes
            if r.randrange(2):
                body += bytes(r.randint(1, 4))
            else:
                del body[-r.randint(1, min(4, len(body))):]
        t = struct.pack('<Q', n) + bytes(body)
        return 'table-raw', a.build(table=t + struct.pack('<I', crc32c(t)))
    if kind == 7:  # header fields with a valid header CRC
        h = a.hdr
        f = r.choice(['max', 'count', 'orig', 'hash', 'ver', 'flags'])
        if f == 'max':
            struct.pack_into('<I', h, 8, pick_val(r, struct.unpack_from('<I', h, 8)[0]) & 0xFFFFFFFF)
        elif f == 'count':
            v = pick_val(r, struct.unpack_from('<I', h, 12)[0]) & 0xFFFFFFFF
            struct.pack_into('<I', h, 12, v)
            if r.randrange(2):
                a.fblocks = v
        elif f == 'orig':
            struct.pack_into('<Q', h, 16, pick_val(r, struct.unpack_from('<Q', h, 16)[0]) & ((1 << 64) - 1))
        elif f == 'hash':
            h[6] = r.randrange(8)
            h[7] = r.choice([0, 4, 8, 16, 32, r.randrange(256)])
        elif f == 'ver':
            h[4] = r.choice([5, 6, 8, 255])
        else:
            h[5] = r.choice([1, 2, 0x80])
        return 'header-' + f, a.build()
    if kind in (8, 9) and a.blocks:  # block header fields
        b = r.choice(a.blocks)
        i = r.randrange(3)
        b[i] = pick_val(r, b[i]) & 0xFFFFFFFF
        return 'block-field', a.build(fix_blocks=r.randrange(2) == 0)
    if kind == 10 and a.blocks:  # literal bytes changed (digest catches it)
        b = r.choice(a.blocks)
        if len(b[4]) > a.hash_size:
            p = r.randrange(a.hash_size, len(b[4]))
            b[4][p] ^= 1 << r.randrange(8)
        return 'block-literal', a.build()
    if kind == 11 and len(a.blocks) > 1:  # drop or duplicate a block
        i = r.randrange(len(a.blocks))
        if r.randrange(2):
            del a.blocks[i]
        else:
            a.blocks.insert(i, list(a.blocks[i]))
        return 'blocks', a.build()
    # fallback: footer meta fields
    a.meta_off = r.choice([0, 1, 28, 1 << 40])
    a.meta_size = r.choice([0, 1, 100])
    return 'footer-meta', a.build()


RTL_WORDS = ('Range check', 'Access violation', 'overflow', 'Invalid pointer',
             'Runtime error', 'Division by zero', 'Invalid floating',
             'Stack overflow', 'Heap overflow', 'Invalid typecast',
             'Out of memory', 'Bus error', 'Segmentation', 'EAccess', 'ERange',
             'EIntOverflow')
OK_CODES = {0, 4, 6}  # ok, data error, max_output


def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout)
        return p.returncode, p.stderr.decode('latin-1')
    except subprocess.TimeoutExpired:
        return 'timeout', ''


def main():
    osrep, seed_dir, work, cases = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    rng_seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    r = random.Random(rng_seed)
    seeds = sorted(f for f in os.listdir(seed_dir) if f.endswith('.osr'))
    blobs = {}
    for f in seeds:
        blobs[f] = open(os.path.join(seed_dir, f), 'rb').read()
        # the seed itself must decode
        orig = os.path.join(seed_dir, f[:-4])
        c, err = run([osrep, '-d', os.path.join(seed_dir, f), os.path.join(work, 'seed.out')])
        if c != 0:
            print(f'seed {f} does not decode: {c} {err.strip()}')
            return 1
        if os.path.exists(orig) and open(orig, 'rb').read() != open(os.path.join(work, 'seed.out'), 'rb').read():
            print(f'seed {f} decodes to the wrong bytes')
            return 1
    bad = 0
    stats = {}
    case = os.path.join(work, 'case.osr')
    out = os.path.join(work, 'case.out')
    # FUZZ_API: tests/osrep_m6_test, run on every case next to -d
    api = os.environ.get('FUZZ_API', '')
    out_api = os.path.join(work, 'case.api')
    for k in range(cases):
        f = r.choice(seeds)
        desc, data = mutate(r, blobs[f])
        open(case, 'wb').write(data)
        res = []
        for cmd in ([osrep, '-d', case, out], [osrep, '--verify', case]):
            c, err = run(cmd)
            res.append(c)
            why = None
            if c == 'timeout':
                why = 'timeout'
            elif c not in OK_CODES:
                why = f'exit {c}'
            elif any(w in err for w in RTL_WORDS):
                why = 'rtl error'
            if why:
                bad += 1
                keep = os.path.join(work, f'bad-{k:06d}-{desc}.osr')
                open(keep, 'wb').write(data)
                print(f'case {k} ({f}, {desc}): {cmd[1]} {why}: {err.strip()[:200]}')
        # the embeddable API (osrep_m6, in-place decoder) must give the same
        # verdict as `osrep -d` and, when both accept, the same bytes
        if api:
            ca, erra = run([api, 'dec', case, out_api])
            why = None
            if ca == 'timeout':
                why = 'timeout'
            elif ca not in (0, 1):
                why = f'exit {ca}'
            elif any(w in erra for w in RTL_WORDS):
                why = 'rtl error'
            elif (ca == 0) != (res[0] == 0):
                why = f'verdict differs: -d rc={res[0]}, api rc={ca}'
            elif ca == 0 and open(out, 'rb').read() != open(out_api, 'rb').read():
                why = 'accepted with other bytes than -d'
            if why:
                bad += 1
                keep = os.path.join(work, f'bad-{k:06d}-{desc}-api.osr')
                open(keep, 'wb').write(data)
                print(f'case {k} ({f}, {desc}): api {why}: {erra.strip()[:200]}')
            if os.path.exists(out_api):
                os.remove(out_api)
        # --verify does not decode (format-v6.md 2.3), so it may accept what
        # -d rejects by digest; it must never reject what -d accepts
        if res[0] == 0 and res[1] != 0 and 'timeout' not in res:
            bad += 1
            keep = os.path.join(work, f'bad-{k:06d}-{desc}-disagree.osr')
            open(keep, 'wb').write(data)
            print(f'case {k} ({f}, {desc}): -d rc={res[0]} but --verify rc={res[1]}')
        # an accepted archive with digests must give the seed's output
        if res[0] == 0 and Archive_hashed(blobs[f]) and Archive_hashed(data):
            orig = os.path.join(seed_dir, f[:-4])
            if os.path.exists(orig) and open(out, 'rb').read() != open(orig, 'rb').read():
                bad += 1
                keep = os.path.join(work, f'bad-{k:06d}-{desc}-wrong.osr')
                open(keep, 'wb').write(data)
                print(f'case {k} ({f}, {desc}): accepted with wrong output')
        s = stats.setdefault(desc, [0, 0])
        s[0] += 1
        s[1] += res[0] == 0
        if os.path.exists(out):
            os.remove(out)
    print('mutations (cases, accepted): ' +
          ', '.join(f'{d} {v[0]}/{v[1]}' for d, v in sorted(stats.items())))
    print(f'{cases} cases, {bad} failures')
    return 1 if bad else 0


def Archive_hashed(data):
    return data[7] != 0


if __name__ == '__main__':
    sys.exit(main())
