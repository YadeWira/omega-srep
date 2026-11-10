# Shifted blocks: HtChunkPos measures a chunk from K*L instead of from the
# block's own start, so a block that does not start on a chunk boundary
# compares the wrong chunks (the defect the -b1000001b round-trip caught).
p = "pascal/src/hashtable.pas"
s = open(p, 'rb').read()
old = b"  Result := T.Grid[lo - 1].Start + (K - T.Grid[lo - 1].Chunk) * T.L;"
new = b"  Result := K * T.L; {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
