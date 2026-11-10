# v6 stops computing the per-block CRC and the blocks_crc chain.
p = "pascal/src/secondpass.pas"
s = open(p, 'rb').read()
old = b"      if V6 then\n      begin\n        { CRC-32C de digest"
new = b"      if False then {mutation}\n      begin\n        { CRC-32C de digest"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
