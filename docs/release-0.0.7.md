# OSREP 0.0.7 — Windows checkpoint (pre-release)

**2026-11-10.** Checkpoint de plataformas: Linux x86_64 y Windows x86/x64
con el mismo CLI, los mismos bytes y los tests nativos. Pre-release.

## Qué hay

- **Linux x86_64** y **Windows x86/x64** en el mismo release. Los `.exe` se
  cruzan con FPC + mingw y se prueban bajo wine (`tests/windows_cross.sh`):
  `--version`, `-m5`, `--verify` y round-trip.
- CLI completo: `-m0` stored, `-m1/-m2` dedup, `-m3/-m4/-m5` LZ, `-dup`,
  stdin/stdout (`-`), `-t`, `-b/-l/-c/-a`, `-hash-`, `--seed`, `-d`,
  `--verify`, `-i`.
- CDC, match finder y CRC-32C nativos, con builds `-dOSREP_NO_NATIVE` como
  referencia y tests diferenciales.
- `-m1` con chunks de 8 KiB: en el corpus multi-versión de zpaq-std deja
  8,87 MB contra 15,29 MB de zpaq solo (mismo backend `-m1`); en PJA,
  1,73 MB contra 2,82 MB.

## Números de referencia

`real64.bin` (64 MiB, Linux x86_64, auto threads):

| flujo | salida | tiempo |
|---|---:|---:|
| `-m3` default | 39.551.315 | ~1,03 s |
| `-m5` default | 38.083.480 | ~1,14 s |
| `-m5 -l64 -c64` | 51.039.922 | ~0,83 s |
| `-m5 -l64 -c4` | 49.758.002 | ~1,25 s |

`--verify` de `real64.osr`: 0,029 s con CRC nativo.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
7-Zip/7-Zip-zstd y `windows_cross.sh`.

## Limitaciones

- Windows se probó bajo wine, **no** en un Windows real todavía.
- Linux i386/ARM64 y macOS ARM64 siguen pendientes. El cross ARM64 llega al
  link pero el sysroot/crt no resuelve `__libc_csu_init/fini`.
- AVX2 para `match_len` se probó y se descartó (sin ganancia).
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- La integración con zpaq-std (fragmentador) queda para coordinar con su
  agente.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
