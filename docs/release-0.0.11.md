# OSREP 0.0.11 — ratio checkpoint (pre-release)

**2026-11-10.** Último checkpoint de núcleo: hash de 32 bytes para `-m4`/
`-m5` con `-l >= 32`. Seis plataformas, mismos binarios base que 0.0.10.

## Qué cambia desde 0.0.10

- **Hash de 32 bytes** para `-m4`/`-m5` con `-l >= 32` (8/16 bytes para
  `-l >= 8/16`; `-m3` conserva hash4 para no cambiar su fixture `-m3 -l64`).
  Menos colisiones de cadena en `-l64`.
- `-m5 -l64 -c8 -a32` queda en **49.811.892** contra **49.814.847** de
  Omega `-m4`: OSREP gana por ~3 KB, pero tarda ~1,14 s contra 0,64 s.
- A igual `-c64`, Omega sigue ganando ratio/tiempo (49,8 MB / 0,64 s contra
  51,0 MB / 0,93 s).
- Todo lo de 0.0.10: Linux x86, x86_64, ARM64; Windows x86/x64; macOS
  ARM64; `-m0..-m5`, `-dup`, stdin/stdout, `-t`, CDC/match/CRC nativos.

## Números

`real64.bin` (Linux x86_64, auto threads):

| flujo | salida | tiempo |
|---|---:|---:|
| `-m5` default | 38.083.480 | ~1,1 s |
| `-m5 -l64 -c8 -a32` | 49.811.892 | ~1,1 s |
| `-m5 -l64 -c64` | 51.001.239 | ~0,9 s |
| `-m3` default | 39.551.315 | ~1,0 s |

Dedup `-m1` 8 KiB + zpaq: 8,87 MB vs 15,29 MB (zpaq-std), 1,73 MB vs
2,82 MB (PJA).

## Pendientes cerrados o evaluados

- **AVX2 para `match_len`**: probado, sin ganancia; revertido.
- **CRC-32C**: SSE4.2 nativo; `--verify` 0,029 s.
- **AES-NI para VHASH**: evaluado como bajo ROI (el AES interviene en la
  derivación de claves, no por byte); no se implementó.
- **Linux i386**: incluido y probado.
- **Windows 8**: sin VM disponible; Windows 10 y 7 SP1 validados.
- **zpaq-std**: la coordinación del fragmentador queda a cargo de Wira, como
  pidió.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
`windows_cross.sh`, `arm64_cross.sh`, `linux_x86_cross.sh` y el workflow de
macOS.

## Limitaciones

- Tiempo a igual `-c` por detrás de Omega; el ratio ya empata/gana en `-c8`.
- La integración con zpaq-std no está hecha (coordinación externa).

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
