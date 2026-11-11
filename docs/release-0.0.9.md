# OSREP 0.0.9 — multiplatform checkpoint (pre-release)

**2026-11-10.** Checkpoint de plataformas: Linux x86_64 y ARM64, Windows
x86/x64 y macOS ARM64 con el mismo CLI y los mismos tests. Pre-release.

## Plataformas

- **Linux x86_64**: binario nativo, tests completos.
- **Linux ARM64**: cross-build con `ppcrossa64` + gcc aarch64; round-trip
  bajo qemu, incluido stdin. El stub `__libc_csu_init/fini` cubre el
  `cprt0.o` viejo de FPC con glibc moderno.
- **Windows x86/x64**: cross-build FPC + mingw; probado bajo wine, en
  Windows 10 y en Windows 7 SP1 reales (x64/x86, `-m5`, verify, decode,
  stdin y `-dup`).
- **macOS ARM64**: GitHub Actions `macos-latest` + `brew install fpc`;
  `native_cdc`, `native_match`, `v6_read` y `v6_encode` pasan; el artefacto
  es un Mach-O arm64.

## Funcionalidad

- `-m0` stored, `-m1/-m2` dedup, `-m3/-m4/-m5` LZ, `-dup`, stdin/stdout
  (`-`), `-t`, `-b/-l/-c/-a`, `-hash-`, `--seed`, `-d`, `--verify`, `-i`.
- CDC, match finder y CRC-32C nativos, con `-dOSREP_NO_NATIVE` como
  referencia y tests diferenciales.
- Dedup `-m1` de 8 KiB + backend zpaq: 8,87 MB vs 15,29 MB en el corpus de
  zpaq-std, 1,73 MB vs 2,82 MB en PJA.

## Números

`real64.bin` (Linux x86_64, auto threads): `-m3` 39.551.315 (~1,0 s),
`-m5` 38.083.480 (~1,1 s), `-m5 -l64 -c64` 51.039.922 (~0,8 s).
`--verify` de `real64.osr`: 0,029 s con CRC nativo.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
`windows_cross.sh`, `arm64_cross.sh` y el workflow de macOS.

## Limitaciones

- Linux i386 no está en este release.
- Windows 8/11 no se probaron específicamente (sí 7 SP1 y 10).
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- AES/SIMD restante.
- Integración con zpaq-std (fragmentador) pendiente de coordinar.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
