# OSREP 0.0.4 — native checkpoint (pre-release)

**2026-11-10.** Checkpoint después de llevar el CDC, el match finder y el
CRC-32C a C, y de mejorar el ratio de `-m4`/`-m5` con `-l` grande. Sigue
siendo una pre-release; el núcleo de formato y la CLI son los mismos.

## Qué hay de nuevo desde 0.0.3

- **CDC nativo** (`src/c/osrep_cdc.c`): límites y FNV-1a de `-m1`, `-m2` y
  `-dup`. `tests/native_cdc.sh` exige bytes idénticos al Pascal.
- **Match finder nativo** (`src/c/osrep_match.c`): hash chain, lazy y
  profundidad de `-m3`/`-m4`/`-m5`. `tests/native_match.sh` compara contra
  `-dOSREP_NO_NATIVE`.
- **CRC-32C nativo** (`src/c/osrep_crc.c`): SSE4.2 con fallback bitwise;
  mismos parámetros v6 (init 0, sin xorout).
- **Hash de 16 bytes** para `-m4`/`-m5` con `-l >= 16` (8 bytes para
  `-l >= 8`); `-m3` conserva su hash de 4 bytes y sus fixtures.
- `-dOSREP_NO_NATIVE` deja un build 100 % Pascal como referencia
  diferencial.

## Números

`real64.bin` (64 MiB), `-t` automático:

| flujo | salida | tiempo |
|---|---:|---:|
| `-m3` default | 39.551.315 | ~1,03 s |
| `-m4` default | 38.353.352 | ~1,13 s |
| `-m5` default | 38.083.480 | ~1,14 s |
| `-m4 -l64 -c64` | 51.084.790 | ~0,83 s |
| `-m5 -l64 -c64` | 51.039.922 | ~0,83 s |
| `-m5 -l64 -c64 -a32` | 51.005.877 | ~0,93 s |

`real64.osr` (`-m5`): `--verify` baja de 0,116 s a 0,029 s con CRC nativo.
En `twice64.bin`: `-m1` 0,83 s, `-m2` 1,07 s, `-dup` 2,37 s.

Omega SREP `-m4 -l64 -c64` sigue mejor en ratio/tiempo (49,81 MB / 0,64 s);
el default `-m5` de OSREP tiene 15 puntos menos de ratio a cambio de ~1,8×
el tiempo. Es el objetivo pendiente del match finder, no una promesa.

## Pruebas

- `v6_read`, `v6_encode`, fixtures v6 y v6-new.
- `tests/native_cdc.sh`, `tests/native_match.sh` (Pascal vs C byte a byte).
- `tests/lib.sh` (73 checks propios, 103 con corpus) y los tests de 7-Zip.
- Compuertas de `-dup`, `-m1..-m5`, `-t1/-t4`, `-hash-`, corrupción y vacío.

## Limitaciones

- El ratio a igual `-l64 -c64` todavía no alcanza a Omega `-m4`.
- `-m0` no está implementado.
- stdin como entrada no está implementado.
- Solo Linux x86_64 verificado; Windows/macOS/ARM son builds previstos.
- La comparación de dedup con zpaq usando el mismo backend/fragmentador
  sigue pendiente; la integración con zpaq-std queda para cuando se coordine.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
