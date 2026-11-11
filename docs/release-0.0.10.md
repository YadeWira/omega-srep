# OSREP 0.0.10 — Linux x86 (pre-release)

**2026-11-10.** Checkpoint que agrega Linux x86 (i386) a las plataformas.
Seis binarios: Linux x64/x86/ARM64, Windows x64/x86 y macOS ARM64.
Pre-release.

## Qué cambia desde 0.0.9

- **Linux x86**: `scripts/build_linux_x86.sh` compila con `ppcross386` +
  `gcc -m32`, 32-bit libc y el stub `__libc_csu_init/fini`.
  `tests/linux_x86_cross.sh` prueba `--version`, `-m5`, `--verify`, `-d`,
  stdin y `-dup` de forma nativa en el host x86_64.
- **Fix de link**: el objeto C `osrep_crc.o` chocaba con el `.o` de la
  unidad Pascal `osrep_crc.pas` en 32 bits. Se renombró a
  `osrep_crc_native.c` y se actualizaron todos los builds.
- Todo lo de 0.0.9 sigue: v6, `-m0..-m5`, `-dup`, stdin/stdout, `-t`, CDC/
  match/CRC nativos, Windows 10/7 SP1 y macOS ARM64.

## Plataformas

| plataforma | estado |
|---|---|
| Linux x86_64 | nativo, tests completos |
| Linux x86 | cross + test nativo |
| Linux ARM64 | cross + qemu |
| Windows x86/x64 | wine, Windows 10 y 7 SP1 |
| macOS ARM64 | GitHub Actions |

## Números

Sin cambios de formato ni de rendimiento:

- `-m5` default en `real64.bin`: 38.083.480 en ~1,1 s.
- Dedup `-m1` 8 KiB + zpaq: 8,87 MB vs 15,29 MB (zpaq-std); 1,73 MB vs
  2,82 MB (PJA).
- `--verify` con CRC nativo: 0,029 s.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
`windows_cross.sh`, `arm64_cross.sh`, `linux_x86_cross.sh` y el workflow de
macOS.

## Limitaciones

- Windows 8 no está disponible en las VMs; Win10 y Win7 SP1 son los
  validados.
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- AES/SIMD restante.
- Integración con zpaq-std (fragmentador) pendiente de coordinar.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
