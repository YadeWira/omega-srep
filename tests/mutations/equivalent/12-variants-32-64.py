# R20: the 32 and 64 scan variants are not implemented and fall back to the
# plain scan (they stay in the same validation case as an unknown value).
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"    1, 2, 4, 8, 16, 32, 64: ;"
new = b"    1, 2, 4, 8, 16: ; {mutation: 32/64 fall to 0}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
