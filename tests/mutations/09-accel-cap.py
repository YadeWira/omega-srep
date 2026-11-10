# R11: the default scan variant is capped at 8 instead of 16.
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"    if accel > 16 then accelerator := 16 else accelerator := accel;"
new = b"    if accel > 8 then accelerator := 8 else accelerator := accel; {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
