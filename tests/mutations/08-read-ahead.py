# HtPrepareAhead does nothing: the next block's first digest is never written.
p = "pascal/src/hashtable.pas"
s = open(p, 'rb').read()
old = b"  if T.PrecomputeDigests and (BlockLen >= T.L) then"
new = b"  if False and T.PrecomputeDigests and (BlockLen >= T.L) then {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
