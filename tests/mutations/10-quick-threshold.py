# R18: the quick-path threshold. Blocks shorter than 2*L are stored as
# literals; with 3*L the blocks between 2*L and 3*L take that path too. The
# a33929 -b261b -l130 case sits exactly on the boundary (2*L = 260 <= 261).
p = "pascal/src/fixedcompress.pas"
s = open(p, 'rb').read()
old = b"  if 2 * L > BlockSize then Exit;"
new = b"  if 3 * L > BlockSize then Exit; {mutation}"
assert s.count(old) == 2, "target not found twice"
open(p, 'wb').write(s.replace(old, new))
