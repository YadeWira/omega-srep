# Building Omega SREP on Windows (FOSS toolchains)

The supported and tested Windows toolchain is **MinGW-w64** (gcc).
This is the path the shipped `osrep-windows-x86_64.exe` releases use,
and it is what the maintainer builds locally before each tag.

You do not need Visual Studio. Everything below is open-source and
self-contained.

## Recommended: MinGW-w64 via scoop

[scoop](https://scoop.sh) gives you a clean, user-local install of
the full toolchain on Windows 10 / 11 (x86_64) with no admin rights
and no system PATH pollution.

```powershell
# One-time toolchain install
scoop install gcc make git

# Build
git clone https://github.com/YadeWira/omega-srep
cd omega-srep
make bin/osrep
```

The resulting `bin\osrep.exe` is statically linked (no DLL
dependencies, no runtime to ship alongside) -- same artifact shape
as the Linux build, just for Windows.

`gcc` from scoop currently resolves to MinGW-w64 gcc 15.2 with the
UCRT runtime, which is what the F6.4 / F6.6 / F6.10 release binaries
on GitHub were built with.

## Alternatives (also FOSS, untested but expected to work)

The codebase has no GCC-isms outside of headers gated behind
`__GNUC__` (verified during the F6.8 portability audit). Any C++17
compiler that reaches the same Win32 APIs should build it. Known
options on Windows:

- **MSYS2 / mingw64** -- full Unix-like environment with the same
  MinGW-w64 toolchain underneath. Useful if you also want bash,
  pacman-style package management, and a posix-shaped shell.
  Build is the same `make bin/osrep` once you are inside the
  `mingw64` shell.

- **llvm-mingw** -- LLVM (clang + lld) with the MinGW C runtime.
  Drop `clang++` in front of the `g++` flags in the Makefile and
  it should build cleanly. No Microsoft runtime, no Microsoft
  toolchain.

- **clang on MSVC headers (clang-cl)** -- works in principle via
  the `CMakeLists.txt` at repo root (it has `MSVC`-conditional
  branches that clang-cl honors). Untested by the maintainer.
  See "CMake build" below.

- **Native MSVC `cl.exe`** -- the source compiles MSVC-clean as of
  v1.0a-beta.4 (the Handle.h gate was widened to exclude
  `_MSC_VER` in `Synchronization.h`). You can drive it via the
  `CMakeLists.txt`. Not tested by the maintainer; there is no
  policy reason to add it to CI.

## CMake build (alternative to Make)

The `CMakeLists.txt` at repo root is provided for users who prefer
cmake over the Makefile (Ninja generator, IDE integration, etc.).
It works with GCC + Make on Linux, GCC + MinGW on Windows, and any
other C++17 compiler that CMake can drive.

```powershell
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

The Makefile remains the primary path (CI uses it; release
binaries are built from it). CMake is purely an alternative.

## Verifying the build

```powershell
.\bin\osrep.exe
```

Should print:

```
Omega SREP 1.0a-beta.4 (April 27, 2026): ...
```

Round-trip smoke test:

```powershell
$tmp = "$env:TEMP\osrep-smoke"
New-Item -ItemType Directory -Force $tmp | Out-Null
$bytes = [byte[]]::new(1MB)
[System.Random]::new(42).NextBytes($bytes)
[System.IO.File]::WriteAllBytes("$tmp\in.bin", $bytes)
& .\bin\osrep.exe -m4 "$tmp\in.bin" "$tmp\in.osr"
& .\bin\osrep.exe -d "$tmp\in.osr" "$tmp\out.bin"
$h1 = (Get-FileHash "$tmp\in.bin" -Algorithm SHA256).Hash
$h2 = (Get-FileHash "$tmp\out.bin" -Algorithm SHA256).Hash
if ($h1 -eq $h2) { "OK: round-trip matches" } else { "FAIL: hash mismatch" }
Remove-Item -Recurse -Force $tmp
```

## Notes on shell environment

`make` from scoop runs in plain PowerShell or cmd, but the Makefile
uses GNU coreutils-shaped recipes (`mkdir -p -v`, `rm -f -v`). If
you build in plain PowerShell after deleting `bin/`, you may need
to recreate the directory yourself before invoking make again, or
run `make` from a shell that has `mkdir` / `rm` from coreutils on
PATH (MSYS2's `mingw64` shell, Git for Windows' `bash`, busybox-w32,
or scoop's `coreutils` package).

The maintainer builds from a Git for Windows bash session, which
ships GNU coreutils.
