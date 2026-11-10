# OSREP CLI contract (draft for phase 1)

This is the behaviour the new implementation must provide. Exact texts and
exit codes are pinned by the new golden transcripts; this file defines the
surface, not the wording.

## Invocation

```
  osrep [options] <input> [<output>]
  osrep -d [options] <archive> [<output>]
  osrep --verify <archive>
  osrep -i <archive>
```

Input `-` is stdin; output `-` is stdout. A missing output derives from the
input name (`x` -> `x.osr`, `x.osr` -> `x`).

## Format

v6 only (`OSR6`). There is no `--format=v4|v5`; OSREP does not write or read
the SREP v1-v5 containers. `--format=v6` may be accepted as a no-op for
scripts, but the default and only writer is v6.

## Methods (phase 1)

- `-m3`: LZ match finder, index-LZ.
- `-m4`: LZ match finder, in-memory/re-read path.
- `-m5`: exhaustive LZ match search.

`-m0` (in-memory), `-m1`/`-m2` (CDC) and `-dup` are phase 2; until then they
exit 2 with a clear "not implemented yet" message.

## Options kept from the old contract

`-lN`, `-cN`, `-bN`, `-aN[/M]`, `-ia-`/`-ia+`, `-hash=NAME`, `-tN`, `-vN`,
`-bar`, `--seed=N`, `-sN`, `-delete`, `-index=`, `-temp=`, `-mmap`/`-nommap`,
`-slp`/`-slp+`/`-slp-`, `-mBYTES`.

The new implementation may reject an option it does not implement yet, but it
must not silently ignore it.

## `-i` output

`-i <archive>` prints one `key=value` per line, no paths:

```
OSREP v6
blocks=N
original_size=N
stat_size=N
meta_size=N
hash_id=N
hash_size=N
```

This is the phase-1 contract; the new golden fixes it.

## Exit codes

- `0`: success.
- `2`: command line error.
- `3`: input/output error.
- `4`: bad data (damaged archive, failed `--verify`).

## Version

`--version` prints `OSREP <version> (<date>)`. The OSREP line starts at
`0.0.1`; phase 0 is `OSREP 0.0.1 (2026-11-10)`, phase 1 is `0.0.2` and the
first stable release is `1.0.0`. Every 0.0.x release is a pre-release.
