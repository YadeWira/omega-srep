"""v7_segment_sim.py in.osr out.osr SEG_BYTES: rewrite a v7 archive with the
match table split per segment of output (size study only, not readable)."""
import os, sys, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tests'))
from fuzz_v7 import Archive, venc, crc32c
d = open(sys.argv[1], 'rb').read(); S = int(sys.argv[3])
a = Archive(d)
dst = []; pe = 0
for g, l in zip(a.gap, a.len):
    x = pe + g; dst.append(x); pe = x + l
out = bytearray(a.hdr) + a.seed
mi = 0; pos = 0; bi = 0; nb = len(a.blocks); prev_end = 0; nseg = 0
while bi < nb:
    seg_start = pos
    blks = []
    while bi < nb and (not blks or pos - seg_start < S):
        blks.append(a.blocks[bi]); pos += a.blocks[bi][1]; bi += 1
    g = []; L = []; D = []
    while mi < len(dst) and dst[mi] < pos:
        base = max(prev_end, seg_start)
        g.append(dst[mi] - base); L.append(a.len[mi]); D.append(a.dist[mi])
        prev_end = dst[mi] + a.len[mi]; mi += 1
    t = struct.pack('<Q', len(g)) + b''.join(map(venc, g)) + b''.join(map(venc, L)) + b''.join(map(venc, D))
    out += t + struct.pack('<I', crc32c(t)); nseg += 1
    for b in blks:
        out += struct.pack('<IIII', b[0], b[1], b[2], b[3]) + b[4]
out += d[-36:]
open(sys.argv[2], 'wb').write(bytes(out))
print('segments', nseg, file=sys.stderr)
