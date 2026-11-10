# R15: the tail padding of the accelerated scan. The last CYCLES positions of
# a chunk are marked and added again after the look-ahead batch; skipping
# them changes which candidates a later chunk sees.
p = "pascal/src/fixedcompress.pas"
s = open(p, 'rb').read()
old = b"""    hash1.Value := savedHash1;
    hash2.Value := savedHash1;
    HtMarkPossible(T, hash1.Value);
    j := 1;"""
new = b"""    hash1.Value := savedHash1;
    hash2.Value := savedHash1;
    HtMarkPossible(T, hash1.Value);
    j := Cycles; {mutation: the tail is not marked again}"""
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
