# Building Omega SREP with native MSVC (cl.exe)

This is the supported path for users on Visual Studio 2022 / Visual
Studio Build Tools who want a native-MSVC `osrep.exe` (no MinGW
runtime DLLs, links against MSVCRT directly, integrates with
Microsoft toolchains like clang-cl, MSBuild, and the VS debugger).

For Linux + MinGW-w64 builds, keep using the `Makefile` -- it is the
primary build path and is what CI uses. CMake is only the alternative
for the `cl.exe` toolchain that the Makefile cannot drive.

## Prerequisites

- Windows 10 or 11 (64-bit).
- One of:
  - Visual Studio 2022 (Community / Professional / Enterprise) with
    the "Desktop development with C++" workload, OR
  - Visual Studio Build Tools 2022 (free) with the same workload.
- CMake 3.20 or newer (bundled with VS 2022; otherwise install from
  <https://cmake.org/download/>).

## One-shot build

From a "x64 Native Tools Command Prompt for VS 2022" (this puts
`cl.exe` on `PATH`):

```cmd
cd path\to\omega-srep
cmake -B build
cmake --build build --config Release
```

The resulting binary is at `build\Release\osrep.exe`.

Equivalent in PowerShell:

```powershell
cd path\to\omega-srep
& cmake -B build
& cmake --build build --config Release
```

## Picking a generator

CMake auto-detects the latest installed VS. To pick a specific one:

```cmd
cmake -B build -G "Visual Studio 17 2022" -A x64
```

For Ninja (faster, single-config; recommended once VS is installed):

```cmd
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

## What the CMakeLists does on MSVC

`CMakeLists.txt` at the repo root sets the same defines and include
paths as the Makefile and adds MSVC-specific compile flags:

- `/utf-8` -- source files use UTF-8 (some legacy comments).
- `/EHsc` -- standard C++ exception model.
- `/Zc:__cplusplus` -- report the real `__cplusplus` macro (MSVC's
  default lies about it for back-compat).
- `/W3` plus `/wd4244 /wd4267 /wd4018 /wd4146 /wd4996` -- silence the
  conversion + signed/unsigned + CRT-deprecation warnings that the
  upstream SREP source emits by the hundred. They are not real bugs
  on x86_64 (the codebase mixes `int`/`size_t` deliberately for
  ratio columns and progress display).
- `/D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_DEPRECATE` -- same.
- `/DWIN32_LEAN_AND_MEAN /DNOMINMAX` -- standard hygiene against
  `<windows.h>` polluting the global namespace.
- Release: `/O2 /Oi /GL` + `/LTCG` -- whole-program optimisation.

Linker libraries: `ole32 uuid shell32 advapi32` (for the COM /
shell-integration calls that `Compression/Common.cpp` makes).

## Source-level compatibility

The codebase is MSVC-clean as of v1.0a-beta.3+:

- The `Handle.h` LZMA-SDK shim (referenced from
  `Compression/LZMA2/MultiThreading/Synchronization.h`) is gated out
  for both MinGW and MSVC, since the inline operators that would use
  it pull `HANDLE` directly from `<windows.h>` and never reach into
  the shim's class hierarchy.
- The GCC asm CRC32 path in `hashes.cpp` is gated behind
  `GCC_VERSION >= 403`, an undefined macro on MSVC, so the
  table-based CRC fallback is the production path on every supported
  toolchain (this is also true on GCC -- the macro is never defined
  by the build).
- `<x86intrin.h>` and `<cpuid.h>` are not used (also gated behind the
  same `GCC_VERSION` check).
- `Compression/Common.h` already has `__GNUC__`-conditional aliases
  for `_logb` <- `logb` and `stricmp` <- `strcasecmp`.

If you hit a portability issue not covered above, please file an
issue with the exact `cl.exe` error and your VS version.

## Verifying the build

```cmd
build\Release\osrep.exe
```

Should print the banner:

```
Omega SREP 1.0a-beta.3 (April 27, 2026): ...
```

A round-trip smoke test (PowerShell):

```powershell
$tmp = "$env:TEMP\osrep-msvc-smoke"
New-Item -ItemType Directory -Force $tmp | Out-Null
$bytes = [byte[]]::new(1MB)
[System.Random]::new(42).NextBytes($bytes)
[System.IO.File]::WriteAllBytes("$tmp\in.bin", $bytes)
& build\Release\osrep.exe -m4 "$tmp\in.bin" "$tmp\in.osr"
& build\Release\osrep.exe -d "$tmp\in.osr" "$tmp\out.bin"
$h1 = (Get-FileHash "$tmp\in.bin" -Algorithm SHA256).Hash
$h2 = (Get-FileHash "$tmp\out.bin" -Algorithm SHA256).Hash
if ($h1 -eq $h2) { "OK: round-trip matches" } else { "FAIL: hash mismatch" }
Remove-Item -Recurse -Force $tmp
```

## Limitations

- `cl.exe` builds are not run in CI (CI uses `ubuntu-latest` and
  `make`, which exercises the Makefile path with GCC). Native-MSVC
  build verification is by hand for now -- if you build on MSVC and
  the smoke test passes, please share the `cl.exe` version on the
  release issue tracker; we will collect a small matrix of known-good
  versions over time.
- `cmake install` is intentionally not wired up. The Makefile
  (`make install`) drives the man-page + bash/zsh-completion install
  layout on POSIX; on Windows there is no equivalent layout, so just
  copy `build\Release\osrep.exe` wherever you want it on `PATH`.
- The Makefile and CMakeLists deliberately do not co-build. Pick one.
  CI uses Make; Windows users on MSVC use CMake; everyone else is
  free either way.
