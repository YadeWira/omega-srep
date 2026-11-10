# -ia- is ignored: the slice filter always stays on (io_accelerator = 1).
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"Kind = ekDigest, cdc, l, minMatch, Opts.IoAccelerator, bitarrAccelerator,"
new = b"Kind = ekDigest, cdc, l, minMatch, 1, bitarrAccelerator, {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
