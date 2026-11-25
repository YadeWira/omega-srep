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

- FreeArc 0.67.1 on a real Windows 10: pack (`a`) and test (`t`) through
  stdio and through temporary files, with the x64 and x86 binaries: All OK.
  (With that FreeArc build, extracting with `x` through a stdio
  `unpackcmd` wrote an empty file and sent the data to FreeArc's own
  stdout, also with a plain copy program in place of orep; use temporary
  files in `unpackcmd` if extraction misbehaves.)
- `tests/orep.sh` (the whole suite) on Linux and in the macOS CI.
- The five Linux and Windows binaries give the same stream as the Linux
  x86_64 one, with round trips, on the host (x86_64 and x86), under qemu
  (arm64) and under wine (`-t1`, `-t4 -y0`, `-l32 -b64k -w1m -t3`,
  `-l256 -c2 -r512 -t2`); the macOS binary passes the whole suite in CI,
  including the pinned format 4 streams.

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.11.tar.gz`, `SHA256SUMS`.

## License

MIT.
