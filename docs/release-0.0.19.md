# OSREP 0.0.19 — `osrep_run`, the command line as a library function (pre-release)

**2026-11-27.** `libosrep` exports `osrep_run()`, in the form of libsrep's
`srep_run()`, for programs that run OSREP in their own process instead of
starting the `osrep` program (ytool, for its `-ddo`). Also a fix: `-dup`,
`-m1` and `-m2` wrote a broken archive to a pipe. The formats and the
archives are unchanged from 0.0.18.

## `osrep_run`

```c
int osrep_run(int argc, char **argv, intptr_t in_handle,
              intptr_t out_handle, intptr_t err_handle);
const char *osrep_version(void);
```

- `argv[0]` is the program name, the rest are the CLI's arguments in UTF-8.
  The bytes are the `osrep` program's with the same arguments.
- "-" as the input or the output is `in_handle` / `out_handle`; messages go
  to `err_handle` (POSIX file descriptors, Windows HANDLEs). `-1` is the
  process's own standard handle and is left open; the others are closed
  before the call returns, each once.
- It returns the CLI's exit code (0, 2 command line, 3 I/O or memory,
  4 damaged data) and never ends the process. When it fails, it deletes the
  output file it created.
- No global state: each call frees what it allocated and stops the threads
  it started (`-m6 -tN`), and calls may run at the same time on different
  threads. A host that writes to pipes ignores SIGPIPE.

The CLI is now this function: the command line moved from `osrep.lpr` to
`src/pascal/osrep_cli.pas`, with no `Halt` and no global variables, and
`osrep.lpr` only calls it. A Free Pascal program can link the unit in
directly (`OsrepRunArgs`, with its own strings) instead of loading the
library; `scripts/build_osrep_unit.sh` now packages it with the units and C
objects it needs.

## Fixes

- **`-dup`, `-m1` and `-m2` to a pipe** wrote 0 as the offset of the dedup
  metadata (the encoder asked the output stream for its position, which a
  pipe does not have), so `osrep -m1 - - | ...` gave an archive that `-d`
  rejected ("meta does not end at the footer"), with exit code 0. The
  encoder now counts the bytes it wrote. Output to a file was not affected;
  archives written to a pipe by 0.0.18 or earlier with these methods cannot
  be read. `-m0`, `-m3` to `-m6` without `-dup` were not affected.
- **A failed `-d` or encode deletes the output file** it created instead of
  leaving a partial one (output to `-` cannot be undone).
- **libosrep builds for Windows** (`osrep.dll`, x64 and x86, with the
  mingw cross compilers): the 7-Zip glue called three functions by C names
  that a PE link does not resolve through the exports. On Windows the
  library now takes UTF-8 paths, as on the other platforms.
- The temporary file counter is atomic (calls at the same time).

## Tests

- `tests/lib_run.sh` (new): the library's `osrep_run` writes the CLI's
  archive for 9 method sets; a loop (`src/lib/test_run_loop.c`, the shape
  of ytool's `lib_loop.c`) calls it 20 times in one process, files, pipes,
  `-1` handles, damaged archives (4, no output left), a bad option (2, the
  message on the err pipe), a missing input, `--version`, two calls at
  once: 1,030 checks, descriptors and threads back to where they were,
  resident set flat (4.0-4.2 MB). The same loop under AddressSanitizer
  with the Pascal heap on malloc (`cmem`): no leak, no bad access (a leak
  planted on purpose is reported).
- Linux x86 (`libosrep.so`, i386): the same loop, 10 rounds, 520 checks;
  the archives equal the x86-64 CLI's.
- Windows 10, `osrep.dll` x64 and x86 (`src/lib/test_run_win.c`, HANDLEs and
  anonymous pipes): 15 rounds, 345 checks each, handle count stable, no
  thread left.
- `tests/v6_encode.sh`: `-dup -m3`, `-m1` and `-m2` to a pipe give the
  archive of a file and round-trip through pipes.
- The old and the new CLI compared on 30 command lines (help, version,
  errors, every mode, stdin/stdout, damaged archives): the same stdout,
  stderr, exit codes and files.
- The full suite (19 scripts) and the cross builds.

## Files

`osrep-linux-x86_64`, `osrep-linux-x86`, `osrep-linux-aarch64`,
`osrep-windows-x86_64.exe`, `osrep-windows-x86.exe`, `osrep-macos-arm64`,
`libosrep-linux-x86_64.so`, `libosrep-linux-x86.so`,
`osrep-windows-x86_64.dll`, `osrep-windows-x86.dll`, `osrep.h`,
`osrep-unit-0.0.19.tar.gz`, `SHA256SUMS`.

## License

MIT.
