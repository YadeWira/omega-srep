# LEB128 with 6-bit groups instead of 7: the match lists change.
p = "pascal/src/secondpass.pas"
s = open(p, 'rb').read()
old = b"  while V >= $80 do\n  begin\n    Push(Byte((V and $7F) or $80));\n    V := V shr 7;\n  end;"
new = b"  while V >= $40 do\n  begin\n    Push(Byte((V and $3F) or $80));\n    V := V shr 6;\n  end;"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
