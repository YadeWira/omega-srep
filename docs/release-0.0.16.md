# OSREP 0.0.16 — embeddable `-m6` API (pre-release)

**2026-11-26.** A Pascal unit, `src/pascal/osrep_m6.pas`, that runs OSREP's
long-range method (`-m6`) memory to memory, for programs that link OSREP
in. It is packaged with its C sources and objects as
`osrep-unit-0.0.16.tar.gz`, to be copied into another repository; PArc uses
it to replace its GPL `srep` stage. The stream format is v7, frozen in
0.0.15, unchanged: the CLI and the unit read each other's streams, and the
CLI writes the same bytes as 0.0.15.

## New

- **`osrep_m6.pas`** (details in `docs/osrep-m6-api.md`):
  - `OsrepM6Encode(Src, SrcLen, Dst, DstCap, out DstLen, Params)` writes a
    standard `.osr` v7 stream into the caller's buffer; `OsrepM6Bound` gives
    a buffer size that is always enough.
  - `OsrepM6OrigSize` and `OsrepM6Decode(Src, SrcLen, Dst, OrigLen)`, which
    decodes in place into a buffer of exactly the original size.
  - `OsrepM6EncMem` / `OsrepM6DecMem`: the memory each call allocates
    besides the input and output (the encoder's is a bound).
  - Return codes, no exceptions; no global state, so calls can run on
    several threads at once; the search runs on the calling thread and
    starts no other (the `Threads` field is the caller's budget).
  - 64-bit sizes: tested with 6.5 GiB and repeats that cross 2^31, 2^32 and
    3·2^31.
  - Parameters: `MinLen` (default 512), `Align` (16), `BlockSize` (8 MiB),
    and `Digest` (off by default; the table and every block keep their
    CRC-32C). With the same parameters the bytes are those of
    `osrep -m6 -l<MinLen> --align=<Align> -b<BlockSize>` (with `-hash-`
    when the digest is off).
- **In-place v7 decoding** (`TArchiveReader.DecodeToMemory`): with the
  whole output in memory, match sources are copied from the output itself,
  so the decoder keeps no pages and no block buffer. Its memory is about
  1 MiB whatever the size (6.5 GiB: 1 MB of anonymous memory).
- **`scripts/build_osrep_unit.sh`** builds the package: 7 Pascal units, 4 C
  files that call nothing from libc, their objects for linux-x86_64,
  linux-x86, linux-arm64, win64 and win32, LICENSE, VERSION and a README.
  With `-dOSREP_NO_NATIVE` the units are all Pascal and need no object.
- The cross-build scripts (`build_windows.sh`, `build_linux_x86.sh`,
  `build_arm64.sh`) take `PROG=<program.lpr>` to build something other
  than the CLI.

## Tests

- `tests/osrep_m6.sh` (also in the macOS CI):
  - `tests/osrep_m6_test.lpr self` with the native and the reference build,
    150,108 checks: round trips for 5 parameter sets × 4 kinds of input × 6
    sizes, the bound, a short output buffer, a decode buffer of the wrong
    size, every truncation and byte flip (a sample on large streams), a
    trailing byte, a v6 header, and 4 threads at once;
  - the unit and the CLI write the same bytes (7 inputs × 4 parameter sets,
    native and reference), and each decodes the other's streams.
- `tests/fuzz_v7.sh` now runs the unit's in-place decoder next to
  `osrep -d` on every mutated stream: the same verdict, and the same bytes
  when both accept (4,000 cases, build with range checks).
- `tests/osrep_m6_big.sh` (run separately): 6.5 GiB from
  `tests/orep_bigsrc.c` through memory-mapped files. Round trip, the same
  stream as the CLI, and the CLI decodes it. Encoder: 416 MB of anonymous
  memory at peak, against a bound of 1,353 MB.
- The same streams and decoded bytes on linux-x86_64, linux-x86,
  linux-arm64 (qemu), win64 and win32 (wine), also when built from the
  package alone.
- The rest of the suite, unchanged (`v7_longrange`, the 6 frozen v7
  fixtures, `v6_read`, `v6_encode`, `lib`, the cross builds…).

## Files

`osrep-linux-x86_64`, `osrep-linux-x86`, `osrep-linux-aarch64`,
`osrep-windows-x86_64.exe`, `osrep-windows-x86.exe`, `osrep-macos-arm64`,
`osrep-unit-0.0.16.tar.gz`, `SHA256SUMS`.

## License

MIT.
