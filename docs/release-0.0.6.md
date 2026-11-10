# OSREP 0.0.6 — CLI checkpoint (pre-release)

**2026-11-10.** Checkpoint del CLI: stdin/stdout completo y `-m0` stored.
Sigue siendo una pre-release.

## Qué cambia desde 0.0.5

- **stdin**: `-` como entrada lee todo el stream en memoria. Funciona en
  encode, decode, `--verify`, `-i`, `-dup`, `-m1` y `-m2`.
- **stdout**: si la entrada es `-` y no se indica salida, escribe a stdout.
  `-` como salida ya funcionaba.
- **`-m0`**: stream v6 **stored** (sin LZ ni dedup). Con `-dup` se convierte
  en dedup + store.
- Tests: stdin/stdout idéntico al archivo, verify/info desde stdin,
  `-m1`/`-dup` desde stdin y `-m0`/`-m0 -dup` round-trip.

## Qué sigue de 0.0.5

- `-m1` con chunks de 8 KiB: 8,87 MB contra 15,29 MB de zpaq en el tar de
  zpaq-std, y 1,73 MB contra 2,82 MB en PJA (mismo backend zpaq `-m1`).
- CDC, match finder y CRC-32C nativos, `-dOSREP_NO_NATIVE`, hash8/hash16.
- `-m1..-m5`, `-dup`, `-t` y la librería congelada.

## Números

`real64.bin` (64 MiB, auto threads):

| flujo | salida | tiempo |
|---|---:|---:|
| `-m0` | ~64 MiB + headers | rápido |
| `-m3` default | 39.551.315 | ~1,03 s |
| `-m5` default | 38.083.480 | ~1,14 s |
| `-m5 -l64 -c64` | 51.039.922 | ~0,83 s |

Dedup real, mismo backend zpaq `-m1`:

| corpus | zpaq solo | OSREP `-m1` + zpaq |
|---|---:|---:|
| zpaq-std, 125 MB tar | 15,29 MB | **8,87 MB** |
| PJA, 33,6 MB tar | 2,82 MB | **1,73 MB** |

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103) y
7-Zip/7-Zip-zstd.

## Limitaciones

- AES/SIMD y la matriz Windows/macOS/ARM siguen pendientes.
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- La integración con zpaq-std (fragmentador) queda para coordinar con su
  agente.
- Las opciones históricas que no se implementan se rechazan; no se ignoran.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
