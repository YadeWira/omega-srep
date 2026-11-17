# OSREP 0.0.15 — `-m6` de largo alcance y formato v7 congelado (pre-release)

**2026-11-16.** Método nuevo `-m6`, que pasa a ser el default de la CLI:
un índice global encuentra repeticiones a cualquier distancia y escribe el
formato v7, que queda **congelado** en esta versión. Con un backend detrás
gana o empata en las 28 celdas (7 corpus × 4 backends) contra SREP 3.93a,
REP y Omega SREP 3.0.0, y sin backend gana en los 7 corpus. Seis binarios,
mismas plataformas que 0.0.14. Pre-release.

## Qué cambia desde 0.0.14

- **`-m6`, método de largo alcance (default).** Una pasada con un índice
  global (hash cada `-l/2` bytes, filtro de bits, verificación y extensión
  en los dos sentidos) sobre toda la entrada, no solo dentro de bloques de
  8 MiB. `-l` mínimo de match (default 512), `--align=N` (largos múltiplos
  de N, default 16, para no correr la posición que modelan xz y
  `zpaq -m5`). `-m0`..`-m5` siguen escribiendo v6; `-dup` sin `-m` sigue
  siendo `-m3`. La biblioteca mantiene `-m3` como default.
- **Formato v7** (`spec/format-v7.md`, magic `OSR7`): la tabla de matches
  entera al principio, en orden de destino y en tres columnas varint
  (gap, largo, distancia) con su CRC-32C; los bloques llevan solo digest y
  literales. **Congelado:** los archivos de `tests/fixtures/v7/` (sha256
  fijos) tienen que decodificarse igual en toda versión posterior.
- **Encoder sin la entrada en RAM:** el buscador lee por posición con un
  búfer de 32 MiB (64 MiB con `-l` < 128) y una segunda pasada saca los
  literales. stdin se guarda en memoria antes, porque la entrada tiene que
  poder releerse.
- **Decoder v7 por páginas:** guarda solo las páginas de 4 KiB de las que
  todavía copia algún match; la tabla se lee del archivo con tres cursores
  y los literales van directo a su lugar. Sirve para stdout.
- **NH de VHASH en C** (`src/c/osrep_vhash_nh.c`, mismos digests).
- **Robustez:** fuzzer de v7 con conocimiento de la estructura
  (`tests/fuzz_v7.sh`, CRC recalculados para llegar a las validaciones de
  fondo, build con chequeos de rango). Encontró y quedaron arreglados un
  `original_size` falso que hacía reservar páginas enormes y una cuenta de
  páginas que daba la vuelta cerca de 2^64; 20.000 casos limpios.

## Números

Contra el mejor de SREP 3.93a, REP 1 GB y Omega 3.0.0 en cada celda
(negativo = gana OSREP; empate = menos de 0,1 %). Configuración: `-m6`
(`-l512 --align=16`) con xz, zstd y `zpaq -m5`; `-m6 -l64 --align=1` con
`zpaq -m1`.

| corpus | xz | zstd | zpaq -m1 | zpaq -m5 |
|---|---:|---:|---:|---:|
| enwik8 | +0,00 % | −0,00 % | **−0,54 %** | +0,00 % |
| silesia.tar | **−0,15 %** | −0,01 % | **−0,78 %** | **−0,21 %** |
| real64.bin | −0,01 % | +0,01 % | **−0,37 %** | −0,00 % |
| versions.tar | −0,08 % | −0,07 % | **−1,51 %** | −0,08 % |
| pja.tar | −0,06 % | −0,02 % | **−1,29 %** | −0,04 % |
| zpaqstd-history.tar | **−0,27 %** | **−0,10 %** | **−2,99 %** | −0,03 % |
| game-assets.tar | −0,04 % | +0,00 % | **−0,35 %** | −0,03 % |

11 victorias, 17 empates, 0 derrotas (0.0.14: 6 / 8 / 14). Los empates son
el techo del dedup: en esos corpus todos los preprocesadores quedan a menos
de 0,1 % del backend solo.

Sin backend, `-m6 -l32 --align=1` contra SREP `-m5f -l32`:

| corpus | OSREP | contra SREP |
|---|---:|---:|
| pja.tar | 4.270.804 | −13,2 % |
| versions.tar | 17.981.253 | −12,5 % |
| zpaqstd-history.tar | 20.578.939 | −13,8 % |
| real64.bin | 44.457.205 | −6,0 % |
| enwik8 | 88.138.071 | −3,4 % |
| silesia.tar | 137.969.306 | −9,8 % |
| game-assets.tar | 398.613.663 | −3,4 % |

- **CPU de codificar** con `-l512`: 1,4–2,8× la de SREP `-m5f` (0.0.14 con
  `-m3`/`-m5`: 21–37×).
- **RSS del encoder:** 39–106 MB con `-l512`; con `-l32` hasta ~1 GB (manda
  el índice, una entrada cada 16 bytes).
- **Decoder:** RSS 12–62 MB con `-l512` y 25–70 MB con `-l32 --align=1`;
  0,07–1,3 s en los 7 corpus (el tar de juegos de 584 MB: 1,3 s).

Detalle y método en `docs/scoreboard.md` y `tools/scoreboard/`.

## Pruebas

- `tests/v7_longrange.sh`: el buscador nativo contra la referencia Pascal
  (mismo archivo), idas y vueltas, `--verify`, `-i`, búferes mínimos y
  stdin, el default `-m6`, matches entre bloques, corrupción de la tabla y
  de un bloque, y los **6 fixtures v7 congelados** con los builds nativo y
  de referencia, a archivo y a stdout.
- `tests/fuzz_v7.sh` (3.000 casos por defecto; 20.000 limpios a mano).
- `tests/lib.sh`: la biblioteca lee v7 (`--decode`, `--decode-limit`, un
  match falso con CRC válido se rechaza).
- `v6_read`, `v6_encode`, `decode_blockwise`, `native_match`, `native_cdc`,
  `memory_budget`, `windows_cross.sh`, `arm64_cross.sh`,
  `linux_x86_cross.sh` y el workflow de macOS (ahora con `v7_longrange`).
- Windows 10 real (x64 y x86, los binarios del release): los 6 fixtures v7,
  idas y vueltas con `-m6`, `-m6 -l32 --align=1` y `-m3` (texto, mixto,
  versiones, tiny, vacío) con `--verify`, y `-d` a stdout. Los tamaños de
  los `.osr` son los mismos que en Linux.

## Limitaciones

- `-m6` no combina con `-dup` (v7 no lleva meta de dedup).
- La entrada de `-m6` tiene que poder releerse; stdin se copia en memoria.
- Con `-l32` el índice del encoder pesa 0,8–1,6 GB por GB de entrada.
- El archivo v7 tiene que poder leerse por posición para decodificarlo (la
  salida sí puede ir a stdout).
- Windows 8 no está disponible; Windows 10 y 7 SP1 son los validados.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
