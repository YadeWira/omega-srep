# -a0 (accelerator off) is read as "not given" and falls back to the default
# derived from -l. That is the realistic parser slip: the port keeps the
# derived path and forgets that an explicit single -aN, 0 included, sets the
# scan variant too (srep.cpp:343-348, 632-633).
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"  if Opts.Accel = 9000 then\n  begin"
new = b"  if (Opts.Accel = 9000) or (Opts.Accel = 0) then {mutation}\n  begin"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
