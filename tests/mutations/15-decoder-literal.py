# Decoder: the literal run that closes a block loses its last byte. The
# archive still decodes with exit 0, so only the round-trip catches it.
p = "pascal/src/futurelz.pas"
s = open(p, 'rb').read()
old = b"  if inPos < nlit then Move(Literals[inPos], OutBuf[outPos], nlit - inPos);"
new = b"  if inPos < nlit then Move(Literals[inPos], OutBuf[outPos], nlit - inPos - 1); {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
