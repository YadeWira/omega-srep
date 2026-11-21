import random, sys, os
d = sys.argv[1]
random.seed(4)
r = random.randbytes(65536)
def w(n, b): open(os.path.join(d, n), 'wb').write(b)
w('empty.bin', b'')
w('tiny.bin', r[:1000])
w('zeros.bin', bytes(200000))
# three edited versions of 64 KiB of random data
out = bytearray()
for v in range(3):
    b = bytearray(r)
    for k in range(12):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
w('versions.bin', bytes(out))
# text: 40 KiB of lines, twice, with edits (text blocks get alignment 1)
words = [b'alpha', b'beta', b'gamma', b'delta', b'orep', b'stream', b'format', b'frozen']
t = bytearray()
i = 0
while len(t) < 40960:
    t += b' '.join(words[(i * 7 + k) % 8] for k in range(1 + i % 9)) + b'\n'
    i += 1
t2 = bytearray(t)
for k in range(20):
    p = (k * 2003) % (len(t2) - 4)
    t2[p:p + 3] = b'XYZ'
w('text.bin', bytes(t + t2 + t))
# runs and short periods between random data
p = bytearray()
for k in range(40):
    p += r[k * 997:k * 997 + 300 + k * 7]
    q = 1 + k % 16
    pat = r[k * 31:k * 31 + q]
    p += (pat * (1 + (300 + k * 11) // q))[:300 + k * 11]
    p += bytes([k]) * (200 + k * 5)
w('periods.bin', bytes(p))
