# OSREP CLI contract (draft for phase 1)

OSREP is a **preprocessor**: the `.osr` file holds an LZ77 match/literal
stream, not an entropy-coded archive. The final compression is a separate
stage (a backend such as zpaq-std). The CLI calls the operation "compress"
because it writes the `.osr` stream, but it does not add an entropy coder.

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

Encoding and decoding need to read their input more than once (`-m6` reads
it twice, the v7 decoder reads the match table by position), so stdin is
first copied into a seekable store: memory up to 32 MiB, and beyond that a
temporary file. `--temp=DIR` puts that file in `DIR` (default: the
system's temporary directory; a `DIR` that does not exist is a command-line
error). The file is deleted when the run ends, also after an error, and by
the system if the process dies (unlinked right after it is created on Unix,
`FILE_FLAG_DELETE_ON_CLOSE` on Windows). `-dup` keeps its whole input in
memory either way.

## Format

v6 only (`OSR6`). There is no `--format=v4|v5`; OSREP does not write or read
the SREP v1-v5 containers. `--format=v6` may be accepted as a no-op for
scripts, but the default and only writer is v6.

## Methods

- `-m0`: a stored v6 stream (no LZ, no dedup); with `-dup` it becomes
  dedup + store.
- `-m1`: fixed-window content-defined deduplication (48-byte rolling hash,
  8 KiB average); the unique chunks are stored, not LZ-parsed.
- `-m2`: order-1 content-defined deduplication (the zpaq CDC parameters:
  4 KiB minimum, ~64 KiB average, 520 KiB maximum); the unique chunks are
  stored.
- `-m3`: greedy hash-chain match finder.
- `-m4`: the same finder with one-byte lazy matching.
- `-m5`: lazy matching and a deeper chain (twice the `-a` depth, capped at
  256). The v6 match stream is free, so the LZ methods write the same
  format; only the parse changes.
- `-m6`: long-range method for a backend (xz, zstd, zpaq). One pass over the
  whole input finds every repeat of at least `-l` bytes (default 512; values
  under 32 mean 512) anywhere earlier in the file, with a global index; the
  length of each match is a multiple of 16. Writes format v7
  (`format-v7.md`). Reads the input by position (stdin goes to a temporary
  file first); `-t` sets the threads that hash it (below), `-a` and `-mem`
  do not apply, and it does not combine with `-dup`.

`-m1` and `-m2` write a `DUPR` meta (exact duplicate chunks removed) and store
the unique body; `-m3`..`-m5` write the LZ stream. `-dup` is a pre-pass that
deduplicates before any `-m*`; with `-m3`..`-m5` it combines CDC and LZ. `-d`
restores the original automatically, and `-i` prints `original_size` (the
deduplicated body) and `restored_size` (the input).

## Threads

`-tN` sets the encoder's worker threads: `0` = automatic (up to 8), `1` =
one thread, up to 64. Blocks are encoded independently and written in order,
so the `.osr` is byte-identical for every `N`; only the time changes. With
`-m6` the threads hash the input by pieces (256 KiB) and the matches are
then picked in order on one thread, so the `.osr` is byte-identical for
every `N` there too; past 8 threads the time hardly changes.

## Memory budget

`-memN` caps the encoder's memory. A bare number is megabytes (`-mem128`);
`kb`/`mb`/`gb` suffixes are accepted (`-mem192mb`). The encoder lowers the
block size (and, if needed, the worker count) to stay under the cap, so a
budgeted archive is valid but has more, smaller blocks.

The block size is chosen for the automatic maximum of 8 workers and does not
depend on `-t`, so `-mem` keeps the byte-identical-for-every-`N` guarantee.

The budget models the LZ tables (`-m3`..`-m5`). `-m0`..`-m2` store the body
and allocate none of them, and `-dup`/stdin still buffer the whole input,
which `-mem` does not bound. A budget too small for one 64 KiB block is a
command line error (2).

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
max_match=N
original_size=N
restored_size=N
stat_size=N
meta_size=N
hash_id=N
hash_size=N
```

`restored_size` is printed only when the `-dup` flag is set: in that case
`original_size` is the deduplicated body and `restored_size` is the final
output. This is the phase-1 contract; the new golden fixes it.

## Exit codes

- `0`: success.
- `2`: command line error.
- `3`: input/output error.
- `4`: bad data (damaged archive, failed `--verify`).

When `-d` or an encode fails, the output file it created is deleted (since
0.0.19; before, a partial file was left). Output to `-` is not undone.

## Version

`--version` prints `OSREP <version> (<date>)`. The OSREP line starts at
`0.0.1`; phase 0 is `OSREP 0.0.1 (2026-11-10)`, the v6 MVP was `0.0.2`,
`0.0.3` was the m1-m5/dup/threads checkpoint, `0.0.4` added the native CDC,
match finder and CRC-32C, `0.0.5` tuned `-m1` to 8 KiB chunks, `0.0.6` added stdin and stored `-m0`, `0.0.7` shipped Windows x86/x64, `0.0.8` fixed Windows stdin/stdout, `0.0.9` added Linux ARM64 and macOS ARM64, `0.0.10` added Linux x86, `0.0.11` added the 32-byte hash for large `-l`,
`0.0.12` added the `-mem` budget, `0.0.13` the block-wise decoder, `0.0.14` the streaming decoder and the
temporary-file `-dup` restore, `0.0.15` `-m6` and v7, `0.0.16` the embeddable `-m6`
API, `0.0.17` `--temp` and stdin over 32 MiB in a temporary file, `0.0.18` a faster `-m6` encoder with `-t` threads, `0.0.19` `osrep_run` (the command line as a library function) and `-dup`/`-m1`/`-m2` to a pipe, and the first stable release is `1.0.0`. Every 0.0.x release is a pre-release.
