# OSREP 0.0.14 — streaming y `-dup` sin body en RAM (pre-release)

**2026-11-10.** Checkpoint de memoria de decodificación: los archivos con
matches que cruzan bloques usan un decoder streaming con ventana, y el body
de `-dup` grande se restaura desde un archivo temporal. Seis binarios, mismas
plataformas que 0.0.13. Pre-release.

## Qué cambia desde 0.0.13

- **Decoder streaming Future-LZ** para archivos donde algún match cruza su
  bloque (legacy Omega, o cualquier producto que use esa libertad del
  formato): produce la salida en orden de posición con una cola de matches
  pendientes por destino y una ventana deslizante que conserva solo los bytes
  que esos matches todavía necesitan. Copia por tramos y verifica el digest
  de cada bloque.
  - Sintético de 64 MiB con matches encadenados: **5 MB / 0,09 s** contra
    74 MB / 0,41 s del decoder global anterior.
- **`-dup` sin body en RAM**: si el body supera 32 MiB se decodifica a un
  archivo temporal y los chunks se leen por offset. En `real64.bin`
  `-dup -m5`: **42 MB / 1,16 s** (0.0.13: 106 MB; 0.0.12: 3,2 GB / 11,9 s).
- Se eliminó el decoder global que quedó sin uso; `--verify` mantiene su
  propio recorrido de validación (`VerifyBlocks`).

## Números (`real64.bin`, 64 MiB, `-m5`)

| flujo | versión | salida | tiempo | RSS |
|---|---|---|---:|---:|---:|
| `-d` block-local | 0.0.13 | 67.108.864 | 1,10 s | 42 MB |
| `-d` block-local | **0.0.14** | 67.108.864 | **1,10 s** | **42 MB** |
| `-d` de `-dup -m5` | 0.0.13 | 67.108.864 | 1,10 s | 106 MB |
| `-d` de `-dup -m5` | **0.0.14** | 67.108.864 | **1,16 s** | **42 MB** |
| `-d` cross-block sintético | 0.0.12 (global) | 67.108.864 | 0,41 s | 74 MB |
| `-d` cross-block sintético | **0.0.14** | 67.108.864 | **0,09 s** | **5 MB** |

`--verify` sigue en 15 MB / 0,03 s.

## Pruebas

- `tests/gen_crossblock.py` (nuevo): genera un v6 con matches que cruzan
  bloques encadenados y su salida esperada.
- `tests/decode_blockwise.sh`: además del fixture legacy y DUPR, decodifica
  el sintético de 16 bloques a archivo y a stdout.
- `v6_read`, `v6_encode`, `native_cdc`, `native_match`, `memory_budget`,
  `lib.sh` (73/103), `windows_cross.sh`, `arm64_cross.sh`,
  `linux_x86_cross.sh` y el workflow de macOS.

## Limitaciones

- El body de `-dup` grande necesita espacio temporal del tamaño del body
  (se borra al terminar). Si no se puede crear el temporal, se usa el camino
  en memoria.
- La ventana del streaming crece con la distancia máxima de los matches
  pendientes; un archivo con distancias enormes puede acercarse al tamaño de
  la salida, pero no lo supera.
- Ratio a igual `-l64 -c64` sigue por detrás de Omega `-m4`.
- Windows 8 no está disponible; Windows 10 y 7 SP1 son los validados.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
