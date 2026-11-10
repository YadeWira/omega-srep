# CRC-32C starts from all ones instead of zero (archives change).
p = "pascal/src/container.pas"
s = open(p, 'rb').read()
old = b"  c := Crc;"
new = b"  c := Crc xor DWord($FFFFFFFF); {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
