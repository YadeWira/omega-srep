# BASE_LEN: the number written in the header and the number used for the
# records must be the same. This writes base+1, so every v4 archive decodes
# with another base (the class of defect the round-trip sweep caught).
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"  ah.BaseLen := DWord(futurelzBaseLen);"
new = b"  ah.BaseLen := DWord(futurelzBaseLen) + 1; {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
