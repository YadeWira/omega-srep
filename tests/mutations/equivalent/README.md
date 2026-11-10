# Equivalent mutations

A mutation here is applied and built the same way as the others, but it is
not a coverage hole when the suite passes: the references produce the same
bytes for the mutated code path, so there is nothing to catch.

`tests/mutations/run.sh` skips this directory. The runner's recipe is: export
HEAD with `git archive`, copy the `.py` to the scratch tree's
`tests/mutations/`, run it, build `pascal/osrep.lpr`, then run
`tests/gates.sh core`.

## 01-m5-plain

`-m5` always takes the plain scan (`accelerator := 0`), ignoring the derived
variant. The C++ 1.0.7 and the Rust also write the same bytes with `-a0` as
with the default accelerator on `-m5`, so there is no archive to distinguish.
Measured on the golden corpus plus `a33929.bin`, `a200k.bin` and a 2 MiB
slice of the real tarball, `-l` 16..1024, v4 and v6: all identical.

## 12-variants-32-64

`-a32` and `-a64` are not implemented and fall back to the plain scan. The
32/64 variants exist in the C++ and in the port, but on every input measured
they write the same archive as variant 16 and as variant 0: the golden
corpus, `a200k.bin` and 32 MiB of the real tarball, `-m3`/`-m4`/`-m5`,
`-l` 16..1000, with the same bitarr size in both binaries. R20 stays
unobservable for now; if a future sample distinguishes it, the case belongs
in `tests/real_world_scan_regression.sh`.
