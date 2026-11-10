# OSREP 0.0.5 — dedup checkpoint (pre-release)

**2026-11-10.** Checkpoint del deduplicador: `-m1` pasa a chunks de 8 KiB y
se mide contra zpaq-std con el mismo backend en dos corpus multi-versión
reales. Sigue siendo una pre-release.

## Qué cambia desde 0.0.4

- **`-m1` default a 8 KiB** de chunk promedio (ventana fija de 48 bytes).
  Con 64 KiB el pipeline contra zpaq dejaba 12,23 MB en el tar de zpaq-std;
  con 8 KiB deja **8,87 MB**. Con 4 KiB baja a 8,53 MB, pero agrega meta.
- **Benchmark de dedup con el mismo backend**:
  - zpaq-std, 4 snapshots (125 MB): zpaq `-m1` 15,29 MB; OSREP `-m1` +
    zpaq `-m1` **8,87 MB** (~1,5 s total).
  - PJA, 5 snapshots (33,6 MB): zpaq `-m1` 2,82 MB; OSREP `-m1` + zpaq
    `-m1` **1,73 MB** (0,66 s total).
  - `-m2` (CDC orden-1) empata con zpaq; `-dup -m5` antes de zpaq empeora
    el resultado.
- Todo lo de 0.0.4 sigue: CDC, match finder y CRC-32C nativos, builds
  `-dOSREP_NO_NATIVE`, hash8/hash16 para `-m4`/`-m5` con `-l` grande,
  `-m3/-m4/-m5`, `-dup`, `-t` y la librería.

## Números de referencia

`real64.bin` (64 MiB, auto threads):

| flujo | salida | tiempo |
|---|---:|---:|
| `-m3` default | 39.551.315 | ~1,03 s |
| `-m5` default | 38.083.480 | ~1,14 s |
| `-m5 -l64 -c64` | 51.039.922 | ~0,83 s |
| `-m5 -l64 -c4` | 49.758.002 | ~1,25 s |

`--verify` de `real64.osr`: 0,029 s con CRC nativo (0,116 s con la tabla
Pascal). El default `-m5` sigue con 15 puntos menos de ratio que Omega
`-m4` a ~1,8× el tiempo; a igual `-c64`, Omega gana ratio/tiempo.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
7-Zip/7-Zip-zstd. Mismos bytes en los builds nativo y `-dOSREP_NO_NATIVE`.

## Limitaciones

- `-m0` y stdin como entrada siguen sin implementarse.
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- AES/SIMD y Windows/macOS/ARM pendientes.
- La integración con zpaq-std (fragmentador) queda para coordinar con su
  agente; esta release solo mide el pipeline con el backend zpaq.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
