# OSREP 0.0.17 — stdin in a temporary file, `--temp` (pre-release)

**2026-11-26.** For programs that pipe large streams through the CLI
(ytool's `-ddo`): stdin is no longer held whole in memory. Formats and
output bytes are unchanged from 0.0.16.

## Changes

- **Stdin over 32 MiB goes to a temporary file.** Encoding (`-m6` reads
  its input twice) and decoding (the v7 decoder reads the match table by
  position) need a seekable input, so stdin used to be copied into memory:
  a multi-GB `.osr` piped to `osrep -d - -` took that much RAM, and on
  32-bit Windows failed past about 1.5 GB. Now stdin stays in memory up to
  32 MiB and beyond that is copied to a temporary file. With 96 MiB through
  pipes the peak RSS is ~59 MB for encode, decode and `--verify`.
- **`--temp=DIR`** chooses the directory of that file (default: the
  system's temporary directory; a missing `DIR` is a command-line error,
  exit 2). The file is deleted when the run ends, also after an error, and
  by the system if the process is killed: it is unlinked right after it is
  created on Unix and opened with `FILE_FLAG_DELETE_ON_CLOSE` on Windows.
  `-dup` still keeps its whole input in memory.
- **No overflow traps under `-Co`.** SplitMix64 (the default VHASH seed),
  VHASH and AES wrap on purpose; they now carry `{$Q-}{$R-}`, so a program
  that embeds OSREP and builds with `-Co` (overflow checks) works.
  `tests/osrep_m6.sh` also runs the embeddable API's checks with
  `-Co -Cr -Ct -CR`.

## Tests

- `tests/stdin_temp.sh` (new): with 96 MiB through pipes, the same archive
  as from a file, round trip, `--verify`, peak RSS under 80 MB, no
  temporary file left (also after a damaged archive, exit 4), and a missing
  `--temp` directory is exit 2.
- Windows 10 (x64 and x86 binaries): the same archive through `cmd`
  redirection as on Linux, round trip and `--verify` through stdin, no
  temporary file left; a process killed in the middle leaves none either.
- The rest of the suite, unchanged (`v6_read`, `v6_encode`,
  `v7_longrange` with the frozen v7 fixtures, `osrep_m6`, `lib`, the cross
  builds…), and the macOS CI.

## Files

`osrep-linux-x86_64`, `osrep-linux-x86`, `osrep-linux-aarch64`,
`osrep-windows-x86_64.exe`, `osrep-windows-x86.exe`, `osrep-macos-arm64`,
`osrep-unit-0.0.17.tar.gz`, `SHA256SUMS`.

## License

MIT.
