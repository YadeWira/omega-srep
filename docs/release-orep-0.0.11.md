# OREP 0.0.11 — CLI fix for FreeArc stdio methods (pre-release)

**2026-11-25.** A fix in the command-line program only. The stream format
(version 4, frozen), the Pascal unit and the C core are the same as in
0.0.10, so streams and archives made with 0.0.10 are unchanged, and
programs that link the unit (PArc) need nothing.

## Fix

- **Stdio methods in FreeArc failed on Windows** (issue #2). With an
  external compressor that uses `<stdin> <stdout>`, for example

  ```
  packcmd   = orep - - <stdin> <stdout>
  unpackcmd = orep -d - - <stdin> <stdout>
  ```

  FreeArc 0.67 starts the program with an invalid stderr handle. The data
  was encoded or decoded correctly, but the CLI then wrote its summary line
  to stderr, the write raised a runtime error, orep exited with a non-zero
  code, and FreeArc reported "general (de)compression error". The same
  methods with `$$arcdatafile$$.tmp`/`$$arcpackedfile$$.tmp` worked. The
  CLI now ignores a failed write to stderr; errors reading or writing the
  data still stop it with a non-zero exit code. With 0.0.10, `-q` avoids the
  problem.

## Tests

- FreeArc 0.67.1 on a real Windows 10: pack and test through stdio and
  through temporary files, with the x64 and x86 binaries: All OK.
- `tests/orep.sh` (the whole suite) on Linux and in the macOS CI.
- The six binaries give the same stream as the Linux x86_64 one, with round
  trips, on the host (x86_64 and x86), under qemu (arm64), under wine, and
  in the macOS CI.

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.11.tar.gz`, `SHA256SUMS`.

## License

MIT.
