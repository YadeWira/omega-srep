# v5 read-only fixtures

v5 is written up to 2.4.0 and read forever. 3.0.0 stops writing it
(`--format=v5` is rejected), so the archives here are the pinned samples the
decoder is tested against: `tests/v5_readonly.sh` checks the sha256, runs
`--verify` and decodes each one back to its input.

They were recorded with the port while it still wrote v5, at the commit where
the port's v5 output was byte-identical to the Rust 2.1.2 oracle (the same
archives are pinned in `tests/golden/manifest.tsv` and were recorded from both
references). They cover `-m0`, `-m1`, `-m3`, `-m4`, `-m5`, `-dup`, an empty
file and a tiny one. The inputs come from `tests/golden/inputs.sh`.

`manifest.tsv` is `sha256 <TAB> id <TAB> input <TAB> args`; the archive is
`<id>.osr`. Do not regenerate these with a 3.0.0 binary: it cannot write v5.
