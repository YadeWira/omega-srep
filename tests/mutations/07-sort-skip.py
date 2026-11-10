# The second pass does not sort the match list (a different tie/order layout).
p = "pascal/src/secondpass.pas"
s = open(p, 'rb').read()
old = b"  SortBySrc(matches);"
new = b"  {mutation: SortBySrc(matches) removed}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
