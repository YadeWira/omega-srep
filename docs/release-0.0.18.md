# OSREP 0.0.18 — faster `-m6` encoding, `-t` for `-m6` (pre-release)

**2026-11-26.** `-m6` encodes 2-4.5 times faster, and `-t` now sets its
threads. The format and the output bytes are unchanged from 0.0.17: the
same input and options give the same `.osr`, byte for byte, with any `-t`.

Measured on ytool's case (1.04 GB: an ISO, an installer and game data after
precomp, from its `-ddo` benchmark), `-m6 -hash-` to a pipe, this server
(Xeon, shared):

| | 0.0.17 | 0.0.18 `-t1` | 0.0.18 `-t8` |
|---|---:|---:|---:|
| `-m6` (`-l512`) | 19.9 s | 12.0 s | 4.2-4.8 s |
| `-m6 -l64 --align=1` | 28.3-31.5 s | 16.7-19.1 s | 9.1-10.4 s |

game-assets.tar (584 MB): 10.4 s → 4.6 s (`-t8`); silesia.tar (212 MB):
3.4 s → 1.5 s.

## Changes

- **The long-range finder works in three steps** (`src/c/osrep_lr.c`):
  1. the hash of every indexed window, by pieces of 256 KiB, all of them
     into the bit filter first;
  2. the rolling hash of every position, by pieces, keeping the positions
     whose hash passes the filter (1-10 % of them);
  3. those positions, in order on one thread, against the table: inserts,
     lookups, verification and extension, as before.

  Steps 1 and 2 run on `-t` threads (default: as many as the CPUs, up to
  8). The filter only skips lookups that cannot find anything (equal
  windows have equal hashes), so a filter that is complete from the start
  gives the same matches as one that grows with the table; the archive does
  not depend on the number of threads or on the size of the pieces
  (`tests/v7_longrange.sh` checks both against the Pascal reference).
- **The bit filter** is a blocked Bloom filter with three bits in the same
  64-bit word and 16 or more bits per indexed window: 0.2-0.5 % of the
  positions without a repeat get through (6 % before), and each test reads
  one word, fetched ahead.
- **Comparisons** go a word at a time; the hash of a whole window runs in
  four interleaved lanes (the same value).
- **The block pass** no longer allocates and copies a payload per block: the
  literals go into one buffer and the CRC is computed over the digest and
  the literals in turn (1.5-1.8 s → 0.6-0.9 s per GB).
- **Memory:** the filter takes twice as much (16 bits per window, ~1.6 % of
  the input with `-l64`), plus two pieces per thread in flight. ytool's
  case, `-l512`: 90 MB → 106 MB with `-t1`, 154 MB with `-t8`.
  `OsrepM6EncMem` (the embeddable API) counts the new parts; the API still
  runs on the caller's thread and starts none.

## Tests

- `tests/v7_longrange.sh`: pieces of one step, 97, 4096 and 100000 bytes
  (with a 4 KiB read buffer) and 1-64 threads give the archive of the
  Pascal reference, on zeros, text, versions, mixed and random data, with
  `-l32`, `-l64` and `-l128 --align=1`.
- The rest of the suite, unchanged: `v6_read`, `v6_encode`, `v7_longrange`
  with the frozen v7 fixtures, `osrep_m6`, `osrep_m6_big` (6.5 GiB:
  anonymous peak 457 MB against a bound of 1,409 MB), `fuzz_v7` with the API differential, `stdin_temp`, `lib`, the cross
  builds, and the macOS CI.
- Windows 10 (x64 and x86 binaries): `-t1`, `-t4`, `-t16` and stdin
  through a temporary file with `-t8` give the same archives as Linux;
  round trips, no temporary file left.
- An encoder differential fuzz (400 random inputs with runs and repeats,
  random `-l`, `--align`, `-t`, piece and buffer sizes) against the Pascal
  reference: all identical.
- Before release: 0.0.17 and 0.0.18 compared byte for byte on ytool's case,
  game-assets.tar, silesia.tar, enwik8 and pja.tar, with and without
  digests, `-t1`, `-t8` and `-t32`.

## Files

`osrep-linux-x86_64`, `osrep-linux-x86`, `osrep-linux-aarch64`,
`osrep-windows-x86_64.exe`, `osrep-windows-x86.exe`, `osrep-macos-arm64`,
`osrep-unit-0.0.18.tar.gz`, `SHA256SUMS`.

## License

MIT.
