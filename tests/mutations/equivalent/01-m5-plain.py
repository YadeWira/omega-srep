# R19: -m5 always takes the plain scan, ignoring the slice filter.
p = "pascal/src/encoder.pas"
s = open(p, 'rb').read()
old = b"  if (QWord(accelerator) > l) or (bitarrAccelerator = 0) then accelerator := 0;\n"
new = old + b"  if Kind = ekFixedExhaustive then accelerator := 0; {mutation}\n"
assert old in s, "target not found"
open(p, 'wb').write(s.replace(old, new, 1))
