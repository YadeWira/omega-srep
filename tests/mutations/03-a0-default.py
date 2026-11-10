# -a0 (accelerator off) is read as the default accelerator.
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"  else accel := Opts.Accel;"
new = b"  else if Opts.Accel = 0 then accel := 4 else accel := Opts.Accel; {mutation}"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
