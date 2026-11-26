# Scoreboard: OSREP contra SREP, REP, Omega SREP y el dedup de zpaq-std

**Fecha: 2026-11-14/15.** Medición interna; no se publica nada. OSREP 0.0.14
en la rama `osrep` (`803de06`). La meta de Wira es que OSREP **gane** a
SREP 3.93a, REP (FreeArc), Omega SREP 3.0.0 y al deduplicador de zpaq-std.
Este documento dice dónde está hoy, con qué margen, y qué conviene atacar
primero.

**En pocas líneas:**

- Con un backend detrás (que es como se usa un preprocesador), el
  **default de OSREP (`-m3`) pierde en todo**: el archivo final crece entre
  +9 % y +652 % contra el mejor rival.
- Con los mejores ajustes que ya existen, de 28 celdas (7 corpus × 4
  backends) **gana 6, empata 8 y pierde 14**. Las 6 victorias son con
  `zpaq -m1` (−0,2 a −1,9 %) y casi todas necesitan meter el archivo
  entero en un bloque (`-m5 -l128 -b256mb -t1`), que es 10–35× más lento
  que la tubería rival.
- **Al deduplicador de zpaq-std sí le gana**: −33 a −41 % sin backend y −38 a
  −49 % con `zpaq -m1` en los corpus multi-versión. Pero SREP y REP le
  ganan más.
- Gasta **21–37× la CPU** de SREP para codificar, decodifica **13–28× más
  lento** y usa **10–40× más RAM**.
- **Como fragmentador dentro de zpaq-std 2.11.0** (`-osrep`), default
  contra default gana en todo lo que tiene versiones (−11 a −64 %), también en
  imagen de disco, árboles con un byte insertado y bases de datos; con el
  mejor `-fragment` de cada uno gana 15 de 22 casos y pierde 6 (PJA `-m5`
  +4,3 %, disco +1,2 %). Ver [Dedup](#dedup-osrep-contra-el-deduplicador-de-zpaq-std).
- La brecha que más pesa es la **redundancia lejana**: el LZ de OSREP busca
  solo dentro de bloques de 8 MiB. El experimento de un bloque la cierra
  casi entera (el historial con `zpaq -m5` pasa de +35 % a +0,8 %), así que
  la causa está confirmada; falta hacerlo barato.

## Actualización 2026-11-15: `-m6` (largo alcance, formato v7)

`-m6` es un método nuevo pensado para ir delante de un backend. Hace una sola
pasada con un índice global (estilo SREP: hash cada `-l/2` bytes, filtro de
bits, verificación y extensión en los dos sentidos) y encuentra repeticiones
en todo el archivo, no solo dentro del bloque. Escribe el formato v7
(`spec/format-v7.md`): la tabla de matches entera al principio, por destino
y en columnas varint, y bloques que solo tienen literales. Los largos son
múltiplos de 16 (`--align`), para no correr la posición que modelan xz y
zpaq `-m5`. Commits `0dc4354`, `3a5edf4`, `d377eab`, `6c89785`; TSV en
`tools/scoreboard/scoreboard-2026-11-15-m6.tsv`, tabla con
`tools/scoreboard/compare_m6.py`.

**Contra SREP 3.93a, REP 1 GB y Omega 3.0.0, en las 28 celdas con backend:
gana 11, empata 17 (< 0,1 %) y no pierde ninguna.** Antes: 6 / 8 / 14.

| corpus | xz | zstd | zpaq -m1 | zpaq -m5 |
|---|---:|---:|---:|---:|
| enwik8 | +0,00 % | −0,00 % | **−0,54 %** | +0,00 % |
| silesia.tar | **−0,15 %** | −0,01 % | **−0,78 %** | **−0,21 %** |
| real64.bin | −0,01 % | +0,01 % | **−0,37 %** | −0,00 % |
| versions.tar | −0,08 % | −0,07 % | **−1,51 %** | −0,08 % |
| pja.tar | −0,06 % | −0,02 % | **−1,29 %** | −0,04 % |
| zpaqstd-history.tar | **−0,27 %** | **−0,10 %** | **−2,99 %** | −0,03 % |
| game-assets.tar | −0,04 % | +0,00 % | **−0,35 %** | −0,03 % |

Contra el mejor rival de cada celda; negativo = gana OSREP. Configuración:
`-m6` (`-l512`, `--align=16`) con xz, zstd y `zpaq -m5` (con xz en enwik8 y
silesia, `-l128` queda igual); `-m6 -l64 --align=1` con `zpaq -m1`. Los
cuatro `+` son de +0,003 % a +0,01 %: menos que lo que varían SREP y Omega
entre corridas por su semilla aleatoria.

- Contra el backend solo pierde en una celda: silesia con `zpaq -m5`
  (+0,22 %; SREP y REP pierden +0,44 %). Con xz, `-m6` le gana también al
  backend solo en silesia (48.707.612 contra 48.754.028).
- **CPU de codificar: 1,4–2,8× la de SREP `-m5f`** (antes 21–37×), menos que
  REP en los multi-versión.
- **Memoria del encoder (2026-11-16):** ya no lee la entrada entera; el
  buscador lee por posición con un búfer de 32 MiB (64 MiB con `-l` < 128) y
  los bloques salen de una segunda pasada. Mismos bytes que antes en los 14
  casos (7 corpus × `-l512` y `-l64 --align=1`). RSS con `-l512`: 39–106 MB
  (antes 51–669 MB; SREP 20–68 MB), con 5–15 % más de tiempo. Con `-l64`:
  62–521 MB (antes 82–1.344 MB), donde manda el índice: sus entradas pasaron
  de 8 a 6 bytes (tags de 16 bits; mismos matches, porque dos ventanas
  iguales tienen el mismo hash). Detalle en
  `tools/scoreboard/m6-stream-2026-11-16.log` y `m6-index-2026-11-16.log`.
  Descartado: dimensionar el índice exacto en vez de a potencia de dos
  (ahorra hasta 70 % más, 403 → 110 MB en los juegos con `-l64`), porque
  cambia el reparto en buckets y mueve el final −0,01 a +0,08 %; en
  versions/xz se come casi todo el margen (−0,08 %) contra los rivales
  (`tools/scoreboard/m6-index-exact-2026-11-16.log`).
- **Decoder (2026-11-16):** guarda solo las páginas de 4 KiB de las que
  todavía copia algún match (spec/format-v7.md) y el NH de VHASH pasó a C
  (`src/c/osrep_vhash_nh.c`, mismos digests). Con `-l512`: RSS 26–65 MB
  (antes 45–847 MB; SREP 19–57 MB, REP 45–571 MB) y 0,09–1,29 s (antes
  0,22–14,3 s; los juegos: 14,3 → 1,3 s). Medido con la máquina cargada
  (load ~27); SREP en el scoreboard, con menos carga: 0,05–0,56 s. Detalle
  en `tools/scoreboard/m6-decode-2026-11-16.log`.

- **Sin backend (2026-11-16): `-m6 -l32 --align=1` gana en los 7 corpus**
  al mejor rival (SREP `-m5f -l32`): pja −13,2 %, versions −12,5 %,
  historial −13,8 %, real64 −6,0 %, enwik8 −3,4 %, silesia −9,8 %, juegos
  −3,4 %. Antes, con `-l64`, perdía en las 7 (+0,9 a +12 %). Cuesta más:
  codificar 0,45–18 s (SREP 0,39–10,6 s; enwik8 11,4 contra 2,8 s) y RSS
  91–972 MB (SREP 55–639 MB); decodificar 0,07–1,24 s con 26–96 MB.
  Ida y vuelta OK en los 7. Detalle en `tools/scoreboard/m6-ties-2026-11-16.log`.
- **Los 17 empates con backend son el techo del dedup.** En enwik8, real64,
  los juegos y silesia, todos los preprocesadores quedan a menos de 0,1 % del
  backend solo: no hay redundancia lejana que sacar. En los multi-versión
  `-m6` ya va delante por 0,03–0,08 %. Probado, sin ganancia estable:
  `-l` 256–1024 y `--align` 8/32 (se mueve ±0,1 %, y en cada celda gana una
  combinación distinta: pja/xz −0,19 % con `-l256 --align=32`, pja/zstd
  −0,12 % con `--align=32` y versions/zstd −0,12 % con `--align=8`, pero eso
  es ajustar al ruido); tabla con largos/16 y distancias de repetición
  (−1,6 KB solo, ±0,05 % dentro de la tubería). Lo único que movería las
  celdas sin redundancia es transformar el contenido, que ningún rival hace:
  `xz --x86` sobre la entrada da −0,44 % en silesia, pero +0,05 % en los
  juegos y +0,34 % en real64, así que tendría que aplicarse solo a las zonas
  con código x86.

Qué se probó y no sirvió (medido con xz): no quitar matches cercanos
(distancia menor que la ventana del backend) salvo los largos; no quitar
matches cuyo contenido ya se repite en los 64 KiB anteriores. Los dos
arreglan silesia y empeoran los multi-versión. La alineación de 16 sí
arregla silesia: la pérdida estaba en `mozilla` (ejecutables), por correr la
posición módulo 4 que modela LZMA.

Lo que sigue de la sección de abajo es la medición del 2026-11-14 (sin
`-m6`); las brechas 1–3 quedan resueltas por `-m6` en tamaño y CPU, y la 4
(memoria) y la 5 (decodificación) por el encoder en streaming y el decoder
por páginas (2026-11-16).

## Qué se midió

- **Preprocesador solo**: tamaño, tiempo, CPU y RSS pico de codificar;
  tiempo y RSS de decodificar; ida y vuelta byte a byte (`cmp`).
- **Tubería**: preprocesador + backend (`xz -9 -T1`, `zstd -19 --long=27
  -T1`, `zpaq-std -m1`, `zpaq-std -m5`) y el backend solo. Tamaño final,
  tiempo total de codificar (pre + backend), RSS pico de cada etapa y tiempo
  total de decodificar (backend + pre), con ida y vuelta en las dos etapas.
- **Todas las idas y vueltas dieron `ok`** (417 filas del TSV).

### Configuraciones

| nombre | comando |
|---|---|
| `osrep-m1` | `osrep -m1` (solo dedup: CDC de ventana fija, mín. 4 KiB, ~12 KiB de promedio; el cuerpo queda sin LZ) |
| `osrep-m2` | `osrep -m2` (solo dedup: CDC orden 1 de zpaq, ~64 KiB) |
| `osrep-m3` | `osrep -m3` (default: `-l4 -c1 -a16`, bloques de 8 MiB, hasta 8 hilos) |
| `osrep-m5` | `osrep -m5` |
| `osrep-dup-m5` | `osrep -dup -m5` (dedup orden 1 + LZ) |
| `osrep-dup-m5-l32` | `osrep -dup -m5 -l32` |
| `osrep-dup-m5-l128` | `osrep -dup -m5 -l128` |
| `osrep-m5-l128-b256` | `osrep -m5 -l128 -b256mb -t1` (experimento: archivo entero en un bloque) |
| `osrep-m5-l512-b256` | `osrep -m5 -l512 -b256mb -t1` (ídem, con el `-l` de SREP) |
| `srep-m3f` | `srep -m3f` (SREP 3.93a; default `-l512 -c512 -a4/4`) |
| `srep-m5f` | `srep -m5f` |
| `srep-m5f-l32` | `srep -m5f -l32` |
| `omega-m3` / `omega-m5` | `osrep-linux-x86_64 -m3` / `-m5` (Omega SREP 3.0.0) |
| `rep-64mb` | `fa a X.fa -mrep IN` (FreeArc'Next 0.11, solo el filtro REP, diccionario default 64 MB) |
| `rep-1gb` | `fa a X.fa -mrep:1gb IN` |
| `zpaq-m0` | `zpaq-std a X.zpaq IN -m0 -threads 1` (el deduplicador de zpaq-std solo, fragmentos guardados) |

- **REP aislado**: `fa` acepta un método que es solo `rep:<dict>`; el
  archivo `.fa` es el stream de REP más ~175 bytes de cabecera y
  directorio (medido con `-mstoring`: 33.587.374 bytes para 33.587.200).
  Ese `.fa` es lo que recibe el backend. FA usa hilos de E/S aparte (la
  columna de CPU lo muestra). SREP 3.93a también trae REP (`-m0`), pero se
  midió el de FreeArc, que es el que pide la meta.
- **zpaq-std como preprocesador** (`zpaq-m0`): el archivo `-m0` es lo que
  vería un backend; sirve para comparar el deduplicador de zpaq-std con el
  de OSREP en igualdad de condiciones.
- **Backends**: `xz` 5.8.3, `zstd` 1.5.7, zpaq-std 2.7.2
  (`zpaqclean/baseline`). `zpaq-std -m5` corre con `-threads 1` en archivos
  de hasta 128 MiB y con `-threads 4` en los tres grandes (silesia,
  historial, juegos): los bytes no cambian con los hilos; la columna de
  CPU del TSV da el costo comparable.
- `zpaq -m5` es caro (~0,3–0,5 MB/s por hilo), así que se corrió solo sobre
  el backend solo, `osrep-m1` (la mejor OSREP en tuberías con los backends
  rápidos), `srep-m5f` y `rep-1gb`, y el experimento de un bloque en
  `versions.tar` y el historial. Omega `-m5` quedó a ±0,1 % de SREP
  `-m5f` con los tres backends rápidos y no se repitió con `zpaq -m5`. Los
  experimentos de un bloque se midieron con xz y `zpaq -m1` (no con zstd)
  y en 5 corpus (no en silesia ni en los juegos, que pasan de 256 MiB).

### Corpus

`tools/scoreboard/make_corpus.sh` arma todo en
`/mnt/IA_LAB/agentes/osrep/score/corpus` (copias; los originales no se
tocan):

| archivo | bytes | qué es |
|---|---:|---|
| `enwik8` | 100.000.000 | texto (Wikipedia XML) |
| `silesia.tar` | 211.957.760 | corpus Silesia en un tar |
| `real64.bin` | 67.108.864 | datos reales del bench de r240 |
| `versions.tar` | 130.498.560 | 4 snapshots de zpaq-std (multi-versión) |
| `pja.tar` | 33.587.200 | 5 snapshots de PJA (multi-versión) |
| `zpaqstd-history.tar` | 241.684.480 | `git archive` de 8 tags de zpaq-std (v1.5.1 … v2.11.0) |
| `game-assets.tar` | 584.499.200 | 13 archivos de juego distintos (pak/grp/bif/wad/mpq/pck) del corpus de muestras |

Las carpetas de `zpaqclean/corpus6` no entraron: SREP/OSREP toman un
archivo, y el historial y `versions.tar` ya cubren el caso multi-versión.

### Cómo se mide

- `tools/scoreboard/scoreboard.py`: cada comando se lanza con `Popen` y se
  espera con `os.wait4()`; de ahí salen el RSS pico (`ru_maxrss`) y la CPU
  (`ru_utime + ru_stime`) del proceso. Tiempo de pared con
  `perf_counter()`.
- Etapa de preprocesador: **mediana de 3** en archivos de hasta 128 MiB
  (pja, real64, enwik8, versions) en las filas de los backends rápidos; 1
  corrida en los grandes, en las filas de `zpaq -m5` y en los experimentos
  de un bloque. Backends: **1 corrida**. Los tamaños son exactos; los
  tiempos de los backends son indicativos: la máquina es compartida y el
  mismo `xz -9` sobre ~100 MB dio entre 82 y 133 s según la carga.
- Todo en serie, un proceso pesado a la vez, dentro de
  `systemd-run --user --scope -p MemoryMax=6G -p MemorySwapMax=0`, con
  `nice`, esperando ≥ 12 GB disponibles antes de cada paso.
- SREP y Omega usan una semilla aleatoria para el hash: su salida varía
  unos cientos de bytes entre corridas (por ejemplo `srep-m3f` + xz en pja:
  1.174.360 y 1.174.584). Por eso menos de 0,1 % se cuenta como empate.
- Máquina: Xeon E5-2697A v4 (64 hilos), 62 GB, Debian 13, kernel 6.12.
  OSREP compilado con FPC 3.2.2 `-O2` y gcc 14.2 `-O3` (receta del
  handoff), en `/mnt/IA_LAB/agentes/osrep/score/build`.

### Reproducir

```sh
S=/mnt/IA_LAB/agentes/osrep/score
tools/scoreboard/make_corpus.sh $S/corpus
# OSREP desde HEAD en $S/build/bin/osrep (receta de docs/ROADMAP.md)
CAGE="systemd-run --user --scope --quiet --slice=osrep-review.slice \
  -p MemoryMax=6G -p MemorySwapMax=0 -p OOMPolicy=continue -- nice"
SB="python3 tools/scoreboard/scoreboard.py --corpus $S/corpus --work $S/work \
  --tsv $S/out/scoreboard.tsv"
export TMPDIR=$S/tmp
$CAGE $SB --backends none xz zstd zpaq-m1                  # 1) backends rápidos
$CAGE $SB --pre none osrep-m1 srep-m5f rep-1gb osrep-m5-l128-b256 \
  --backends zpaq-m5 --reps 1                              # 2) zpaq -m5
python3 tools/scoreboard/report.py $S/out/scoreboard.tsv   # tablas de abajo
```

`scoreboard.py --list` muestra cada configuración y sus backends. El TSV se
escribe fila por fila; si se corta, el mismo comando sigue donde quedó. El
TSV de esta medición está en `tools/scoreboard/scoreboard-2026-11-14.tsv`.
En total fueron ~7 h de máquina, casi todas de `xz -9`, `zstd -19` y
`zpaq -m5`.

## Dónde gana y dónde pierde OSREP

Lo que cuenta es el archivo final con backend: el `.osr` solo no se compara
(ver la nota de las tablas por corpus).

### Con su configuración default (`-m3`) pierde siempre

El default empeora al backend en todos los corpus. Contra el mejor rival (o
el backend solo), el archivo final crece:

| corpus | xz | zstd | zpaq -m1 |
|---|---:|---:|---:|
| enwik8 | +82,0 % | +75,2 % | +56,3 % |
| silesia.tar | +56,5 % | +49,9 % | +32,7 % |
| real64.bin | +14,1 % | +13,4 % | +12,3 % |
| versions.tar | +173,0 % | +177,7 % | +385,7 % |
| pja.tar | +150,3 % | +148,3 % | +469,7 % |
| zpaqstd-history.tar | +363,6 % | +391,1 % | +652,2 % |
| game-assets.tar | +11,0 % | +10,9 % | +8,8 % |

`-m5` queda apenas mejor (por ejemplo +69,2 % en enwik8 con xz y +7,5 % en
los juegos con `zpaq -m1`). Es la brecha 2.

### Con los mejores ajustes que ya existen

La mejor OSREP de hoy (cualquier flag del CLI, incluido el experimento
`-m5 -l128 -b256mb -t1`) contra el mejor no-OSREP de cada celda, el backend
solo incluido:

| corpus | backend | mejor OSREP | MB | cod s | mejor rival | MB | cod s | OSREP vs rival |
|---|---|---|---:|---:|---|---:|---:|---:|
| enwik8 | xz | `osrep-m5-l128-b256` | 24,856 | 172 | `omega-m5` | 24,863 | 91,1 | -0,0 % (empate) |
| enwik8 | zstd | `osrep-dup-m5-l128` | 26,395 | 85,9 | `rep-1gb` | 26,389 | 64,3 | +0,0 % (empate) |
| enwik8 | zpaq-m1 | `osrep-m5-l128-b256` | 35,600 | 113 | `omega-m5` | 35,681 | 5,19 | -0,2 % (**gana**) |
| enwik8 | zpaq-m5 | `osrep-m1` | 19,642 | 302 | `rep-1gb` | 19,622 | 294 | +0,1 % (pierde) |
| silesia.tar | xz | `osrep-m1` | 48,785 | 87,6 | `none` | 48,754 | 88,6 | +0,1 % (empate) |
| silesia.tar | zstd | `osrep-m1` | 52,645 | 95,0 | `omega-m5` | 52,587 | 91,4 | +0,1 % (pierde) |
| silesia.tar | zpaq-m1 | `osrep-dup-m5-l32` | 69,045 | 16,8 | `omega-m5` | 69,412 | 9,07 | -0,5 % (**gana**) |
| silesia.tar | zpaq-m5 | `osrep-m1` | 40,073 | 205 | `none` | 40,052 | 241 | +0,1 % (empate) |
| real64.bin | xz | `osrep-m5-l512-b256` | 30,374 | 63,5 | `rep-1gb` | 30,378 | 21,5 | -0,0 % (empate) |
| real64.bin | zstd | `osrep-m1` | 31,126 | 16,7 | `srep-m5f` | 31,102 | 20,3 | +0,1 % (empate) |
| real64.bin | zpaq-m1 | `osrep-m5-l128-b256` | 34,448 | 36,6 | `omega-m5` | 34,571 | 3,14 | -0,4 % (**gana**) |
| real64.bin | zpaq-m5 | `osrep-m1` | 29,188 | 200 | `rep-1gb` | 29,156 | 216 | +0,1 % (pierde) |
| versions.tar | xz | `osrep-m5-l512-b256` | 4,703 | 28,2 | `rep-1gb` | 4,686 | 11,0 | +0,4 % (pierde) |
| versions.tar | zstd | `osrep-m1` | 4,918 | 11,5 | `rep-1gb` | 4,885 | 11,2 | +0,7 % (pierde) |
| versions.tar | zpaq-m1 | `osrep-m5-l128-b256` | 6,851 | 17,6 | `rep-1gb` | 6,914 | 1,33 | -0,9 % (**gana**) |
| versions.tar | zpaq-m5 | `osrep-m5-l128-b256` | 3,618 | 76,1 | `rep-1gb` | 3,590 | 75,9 | +0,8 % (pierde) |
| pja.tar | xz | `osrep-m5-l512-b256` | 1,176 | 4,42 | `rep-1gb` | 1,173 | 2,52 | +0,2 % (pierde) |
| pja.tar | zstd | `osrep-m1` | 1,229 | 2,76 | `omega-m5` | 1,221 | 3,20 | +0,6 % (pierde) |
| pja.tar | zpaq-m1 | `osrep-m5-l128-b256` | 1,702 | 2,14 | `rep-1gb` | 1,717 | 0,35 | -0,9 % (**gana**) |
| pja.tar | zpaq-m5 | `osrep-m1` | 0,973 | 33,6 | `rep-1gb` | 0,965 | 17,0 | +0,8 % (pierde) |
| zpaqstd-history.tar | xz | `osrep-m5-l128-b256` | 5,437 | 59,0 | `rep-1gb` | 5,417 | 11,5 | +0,4 % (pierde) |
| zpaqstd-history.tar | zstd | `osrep-m1` | 5,716 | 17,8 | `rep-1gb` | 5,622 | 12,2 | +1,7 % (pierde) |
| zpaqstd-history.tar | zpaq-m1 | `osrep-m5-l128-b256` | 7,995 | 48,8 | `rep-1gb` | 8,148 | 1,55 | -1,9 % (**gana**) |
| zpaqstd-history.tar | zpaq-m5 | `osrep-m5-l128-b256` | 4,207 | 110 | `srep-m5f` | 4,172 | 92,7 | +0,8 % (pierde) |
| game-assets.tar | xz | `osrep-m1` | 301,331 | 219 | `srep-m3f` | 301,187 | 217 | +0,0 % (empate) |
| game-assets.tar | zstd | `osrep-m1` | 308,743 | 169 | `omega-m5` | 308,504 | 175 | +0,1 % (empate) |
| game-assets.tar | zpaq-m1 | `osrep-dup-m5-l32` | 342,069 | 32,5 | `omega-m5` | 340,086 | 18,1 | +0,6 % (pierde) |
| game-assets.tar | zpaq-m5 | `osrep-m1` | 288,969 | 570 | `rep-1gb` | 288,603 | 486 | +0,1 % (pierde) |

Cuenta de las 28 celdas: **OSREP gana 6, empata 8 y pierde 14.**

- **Gana** con `zpaq -m1` en seis corpus (no en los juegos), por 0,2–1,9 %,
  pero en cinco solo con `-b256mb -t1` (en silesia, con `-dup -l32`): esa
  tubería tarda 2–113 s contra 0,35–9 s del rival (2–31× más) y usa hasta
  1,9 GB.
- **Empata** (< 0,1 %) con xz y zstd en enwik8, real64 y los juegos, y
  con xz y `zpaq -m5` en silesia: en datos sin redundancia lejana nadie le
  agrega nada al backend. La mejor OSREP ahí es `-m1` (casi no toca los
  datos) o `-l128`.
- **Pierde** en los corpus multi-versión con xz (+0,2–0,4 %), zstd
  (+0,6–1,7 %; el experimento de un bloque no se midió con zstd) y
  `zpaq -m5` (+0,8 %); por 0,1 % con `zpaq -m5` en enwik8, real64 y los
  juegos y con zstd en silesia; por 0,6 % con `zpaq -m1` en los juegos.
  Sin el bloque gigante (`-m1`), en el historial pierde **+104 %** con
  `zpaq -m1` y **+35 %** con `zpaq -m5`.

### Contra cada rival

- **SREP 3.93a / Omega 3.0.0**: SREP `-m5f` y Omega `-m5` quedan a ±0,1 %
  entre sí en todas las tuberías; Omega tarda 1,6–2,4× lo de SREP. Los dos
  dejan el historial en 34 MB sin backend, donde `osrep -m1` deja 91 MB y
  el experimento de un bloque 28,8 MB. SREP es el mejor rival con
  `zpaq -m5` en el historial (4,172 MB).
- **REP (`rep:1gb`)**: el rival más fuerte en los corpus multi-versión con
  xz, zstd y `zpaq -m1`. El diccionario importa: con 64 MB el historial
  queda en 42,4 MB en vez de 33,4.
- **Deduplicador de zpaq-std**: **OSREP le gana con claridad.**

  | corpus | `osrep -m1` vs `zpaq -m0` (sin backend) | `osrep -m1` + `zpaq -m1` vs `zpaq -m1` | `osrep -m1` + `zpaq -m5` vs `zpaq -m5` |
  |---|---:|---:|---:|
  | pja.tar | −41,1 % | −38,5 % | +0,1 % |
  | versions.tar | −33,2 % | −42,0 % | −20,3 % |
  | zpaqstd-history.tar | −40,6 % | −49,0 % | −33,5 % |

  Con un solo bloque la ventaja crece: −55,2 % y −75,5 % con `zpaq -m1`,
  −20,5 % y −50,3 % con `zpaq -m5` (versions, historial). Con xz, `osrep
  -m1` deja 0,5–5 % menos que `zpaq -m0` + xz. Pero SREP y REP también le
  ganan a zpaq, y por más que `osrep -m1`.

### Tiempo y memoria del preprocesador solo

| | OSREP `-m5` | OSREP `-m1` | SREP `-m5f` | Omega `-m5` | REP `rep:1gb` |
|---|---:|---:|---:|---:|---:|
| CPU de codificar, enwik8 | 26,5 s | 1,17 s | 0,71 s | 0,83 s | 1,57 s |
| CPU de codificar, historial | 26,6 s | 1,67 s | 0,83 s | 1,28 s | 4,62 s |
| decodificar, enwik8 | 3,85 s | 0,69 s | 0,16 s | 0,40 s | 0,19 s |
| RSS de codificar (rango en los 7 corpus) | 321–680 MB | 83–2.114 MB | 20–67 MB | 20–68 MB | 81–757 MB |
| RSS de decodificar (rango) | 28–80 MB | 19–31 MB | 19–57 MB | 25–127 MB | 45–571 MB |

OSREP `-m5` gasta 21–37× la CPU de SREP `-m5f` y decodifica 13–28× más
lento. `-dup` llega a 2,7 GB en los juegos. El experimento de un bloque
gasta 37–110 s de CPU en el historial y enwik8 (45–160× SREP) y hasta
1,9 GB.

## Brechas a cerrar, en orden

Ordenadas por cuánto mueven la meta (ganar en la tubería final), no por lo
fáciles que sean. Cada una con la causa que se ve en el código y cómo
confirmarla.

### 1. Redundancia lejana: el LZ no sale del bloque de 8 MiB

**Cuánto:** en los corpus multi-versión, con los ajustes normales (`-m1`)
OSREP pierde con `zpaq -m1` por **+28 %** (`versions.tar`, 8,87 MB contra
6,91 MB de REP) y **+104 %** (historial, 16,61 contra 8,15 MB); con
`zpaq -m5` por **+35 %** en el historial (5,63 contra 4,17 MB); con xz por
+0,8 % / +1,2 %. Sin backend, `osrep -m1` deja 91,0 MB del historial donde
SREP `-m5f` deja 34,1 y REP 33,4.

**Causa (código):**

- El LZ es **local al bloque**: `EncodeBlock` (`osrep_encoder.pas`) recibe
  solo los bytes de un bloque de 8 MiB y `osrep_match_find`
  (`osrep_match.c`) busca con el `head/prev` de ese bloque; `Source` y
  `Dest` son posiciones dentro del bloque. El formato v6 y el decoder sí
  aceptan matches entre bloques (`osrep_decoder.pas`: "A match may point
  into an earlier block"), pero el encoder nunca los emite.
- Lo lejano solo lo ve el dedup, que es **por chunks exactos**: `-m1` corta
  con ventana fija (mínimo 4 KiB, ~12 KiB de promedio, `osrep_cdc.c`) y
  `-dup`/`-m2` con el orden 1 de zpaq (~64 KiB, `OsrepDupFragment = 6`). Un
  byte cambiado invalida el chunk entero. SREP y REP encuentran cualquier
  repetición de ≥ 512 bytes en todo el archivo.
- El historial de fuentes es el peor caso: miles de archivos chicos, y cada
  versión cambia unas líneas en muchos de ellos; un chunk de 12 KiB casi
  nunca se repite entero.

**Confirmado con un experimento:** con el archivo entero en un bloque
(`-m5 -l128 -b256mb -t1`), el historial queda en 28,8 MB sin backend
(menos que SREP y REP), en 7,99 MB con `zpaq -m1` (**−1,9 %**, gana a REP),
en 4,21 MB con `zpaq -m5` (+0,8 %, antes +35 %) y en 5,437 MB con xz
(+0,4 %). En `versions.tar`: 6,85 MB con `zpaq -m1` (−0,9 %), 3,62 MB con
`zpaq -m5` (+0,8 %). El costo es el problema: 17–48 s de CPU y 1–1,9 GB
en esos dos corpus, y no sirve para archivos > 2 GB (`-b` llega a
`High(LongInt)`).

**Hipótesis de arreglo:** un índice **global** (todo el archivo, no el
bloque) de digests de chunks de `L` bytes (128–512) en posiciones
alineadas, con búsqueda rodante en cada byte y un filtro de bits, que
emita registros entre bloques (el formato ya los admite) y deje el LZ fino
dentro del bloque. Es el diseño de SREP `-m3`, con memoria ~8 % del
archivo y ~0,5 % de CPU de lo actual. El experimento dice cuánto se gana;
este diseño, a qué costo.

### 2. El default de OSREP empeora al backend

**Cuánto:** ver la tabla del default: +9 % a +652 %. En cambio `-m1` o
`-l128` quedan a ±0,1 % del backend solo donde no hay redundancia lejana.
Aun con un bloque, `-l128` queda +0,2–0,8 % detrás de SREP/REP con xz y
`zpaq -m5`.

**Causa (código):**

- `DefaultEncoderOptions`: `MinMatch := 4`. El parser greedy/perezoso de
  `osrep_match_find` cambia cualquier repetición de 4+ bytes por un
  registro: hace el trabajo del backend, y peor.
- El payload de cada bloque es `digest ‖ registros ‖ literales`
  (`TEncodeJob.EncodeOne`): los registros son varints (`skip, len, dist`)
  que el backend no modela bien, y los literales quedan con huecos, así que
  el backend pierde el contexto que cruzaba cada match.
- SREP y REP usan `-l512` por default: solo quitan lo que el backend no
  alcanza.

**Hipótesis de arreglo:** un modo "tubería" como default (o el default
mismo) con mínimo alto (≥ 128–512) y una regla por distancia: no emitir un
match que el backend encontraría solo (distancia menor que su ventana)
salvo que sea muy largo. Para el residuo de 0,2–0,8 %: probar registros de
ancho fijo en un stream aparte al final (como el índice de SREP) en vez de
varints delante de cada bloque. Medir siempre con xz/zstd/zpaq, no el
`.osr` solo.

### 3. Velocidad de codificación: 21–37× la CPU de SREP

**Cuánto:** `osrep -m5` usa 26,5 s de CPU en enwik8 (5,3 s de pared con 8
hilos) contra 0,71 s de SREP `-m5f`; en real64, 8,2 s contra 0,39 s. Los 8
hilos esconden parte en la pared, pero no en una máquina chica ni con el
servidor cargado. Con un bloque grande (brecha 1) empeora: 37–110 s.

**Causa (código):** `osrep_match_find` llama a `find_best` e `insert_pos`
**en cada byte**: hash, lectura de `head` (hasta 2^22 entradas, 16 MB) y
escritura de `prev` (4 bytes por byte, 32 MB por bloque); son fallos de
caché casi seguros. Medido en un bloque de 8 MiB de real64 con `-t1`:
`-m5` 0,75 s; con `-a1` (cadena de 1) 0,74 s, así que no es la
profundidad de la cadena; con `-c64` (insertar 1 de cada 64) 0,41 s. Con
`-l ≥ 32`, `hash32` encadena 8 llamadas a `hash4` por posición, dos veces
(buscar e insertar). SREP solo indexa posiciones alineadas a `L` y en el
resto consulta un arreglo de bits chico (`-a4`) que cabe en caché.

**Hipótesis de arreglo:** el índice de la brecha 1 baja el trabajo por
byte a un hash rodante y un bit; el LZ fino de mínimo 4 sobra si el
backend lo hace (brecha 2).

### 4. Memoria: 10–40× la de SREP, y nada de diccionario > RAM

**Cuánto:** `-m3`/`-m5` usan 321–680 MB de RSS; `-dup` de 279 MB a
2.714 MB (juegos: 4,6× los 584 MB de entrada); `-m1`, 2.114 MB en los
juegos. SREP: 20–67 MB; Omega: 20–68 MB.

**Causa (código):**

- Por hilo: datos (1×) + `Prev` (4×) + matches (3×) + buffers (1×) del
  bloque, más `head` (`EncoderThreadBytes`); con 8 hilos de 8 MiB,
  ~600 MB.
- `-dup`/`-m1`/`-m2` leen **toda** la entrada a memoria (`ReadAllInput` en
  `osrep.lpr`), arman el cuerpo en un `TByteBuf` que crece por
  duplicación, lo copian a `Res.Body` y otra vez a un `TMemoryStream`:
  `-m1` usa 2,2–4,2× la entrada y `-dup` suma encima el LZ. Un archivo
  más grande que la RAM no se puede deduplicar.

**Hipótesis de arreglo:** dedup en streaming (tabla de chunks en memoria,
cuerpo escrito al vuelo) y, con la brecha 1, un índice de ~8 % del archivo
como SREP. `-mem` ya acota el LZ, pero no el dedup.

### 5. Decodificación: 13–28× más lenta que SREP

**Cuánto:** `osrep -d` de un `-m5` tarda 3,85 s en enwik8 (SREP 0,16 s) y
1,20 s en real64 (SREP 0,08 s); de un `-m1`, 0,69 s en enwik8.

**Causa (código):** `DecodeOneBlock` (`osrep_decoder.pas`) marca cada byte
cubierto en un bitmap (`MarkCovered` por byte de cada match), recorre el
bloque byte a byte con `IsCovered` para colocar los literales, ordena los
matches con un merge sort y después verifica el VHASH. Con matches de 4
bytes hay millones de registros por bloque.

**Hipótesis de arreglo:** recorrer los matches ordenados por destino y
copiar los tramos de literales con `Move` entre uno y otro, sin bitmap; con
la brecha 2 (menos registros) baja sola.

### Qué haría primero

1. Brecha 2 es barata y quita el peor número (el default): cambiar el
   default de tubería a `-l` alto y medir de nuevo con este harness.
2. Brecha 1 con el diseño de índice global: es la única que convierte los
   empates y derrotas multi-versión en victorias, y si se hace como SREP
   resuelve de paso la 3 y buena parte de la 4.
3. 5 y el dedup en streaming de la 4 después.

## Dedup: `-osrep` contra el deduplicador de zpaq-std

**Fecha: 2026-11-15.** El fragmentador de OSREP dentro de zpaq-std 2.11.0
(`-osrep`, parche `tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.11.0.patch`)
contra el fragmentador de orden 1 del mismo zpaq-std. Mismo formato, mismo
compresor: solo cambian los cortes. Detalle, tablas completas, tiempos y
memoria en [`zpaq-osrep-mode.md`](zpaq-osrep-mode.md#zpaq-std-2110-2026-11-15).

**En pocas líneas:**

- **Default contra default, `-osrep` gana en todo lo que tiene versiones**:
  −12 a −64 % con `-m1`, −11 a −46 % con `-m5` (salvo PJA, +5,2 %), y en los
  puntos débiles que zpaq-std nombra: imagen de disco −5,5 %, un byte
  insertado al principio de cada archivo −7,2 %, bases de datos −30 a −53 %.
  Sin redundancia pierde por poco (+0,2 a +0,4 %).
- **Con el mejor `-fragment` de cada uno** gana 15 de 22 casos (−0,2 a
  −15,7 %), empata 1 y pierde 6: PJA `-m5` +4,3 %, imagen de disco +1,2 %,
  `versions.tar -m5` +1,1 %, mixed +0,1/+0,2 % e `insert` +0,1 %. Todavía no
  se le puede decir "gana siempre".
- ~~La palanca más grande es el **mínimo A/2** del gear~~ (medido el mismo día
  con archivos reales: **no sirve**, ver
  [`experiments/frag-minimum.md`](experiments/frag-minimum.md)): con mínimo A/8–A/16 y
  los mismos cortes de formato, `frag_stats` convierte la imagen de disco y el
  byte insertado en victorias y agranda las de tars y bases de datos; empeora
  los fuentes de zpaq-std. Falta medirlo con archivos reales.
- **Memoria del índice**: el RSS de `x` y el de agregar una versión más es
  igual o mucho menor donde hay muchos datos únicos (con `-m5`, −57 % en el historial y
  −43 % en db8k), y mayor en árboles de muchas versiones chicas default
  contra default (`x` +24 a +36 %) y en la imagen de disco en N=3 (+30 % al
  agregar v2). Corta 1,8× más lento y `a -m1` tarda un 15–35 % más.
- El parche se portó a zpaq-std 2.11.0 sin cambios de fondo y pasa
  `osrep-switch-test.sh` (fails=0).

### Default contra default

Lo que obtiene quien solo agrega `-osrep` (N=3, 8 KiB) contra zpaq sin
`-fragment` (N=6, 64 KiB). Tamaño del archivo; negativo = gana `-osrep`:

| corpus | `-m1` zpaq / `-osrep` | | `-m5` zpaq / `-osrep` | |
|---|---:|---:|---:|---:|
| versions.tar | 15.293.566 / 7.787.372 | **−49,1 %** | 4.548.932 / 3.879.126 | **−14,7 %** |
| pja.tar | 2.817.680 / 1.777.493 | **−36,9 %** | 971.240 / 1.021.271 | +5,2 % |
| zpaqstd-history.tar | 32.598.013 / 11.702.495 | **−64,1 %** | 8.457.000 / 4.603.534 | **−45,6 %** |
| src-zpaqstd | 13.000.404 / 9.819.016 | **−24,5 %** | 7.438.882 / 5.858.076 | **−21,3 %** |
| src-omega | 5.190.126 / 4.482.542 | **−13,6 %** | 3.482.867 / 2.884.328 | **−17,2 %** |
| bin-releases | 56.744.870 / 49.972.395 | **−11,9 %** | 34.076.422 / 30.391.791 | **−10,8 %** |
| mixed | 86.342.652 / 86.582.306 | +0,3 % | 71.571.832 / 71.884.278 | +0,4 % |
| photos | 97.870.612 / 98.043.349 | +0,2 % | 90.820.501 / 91.173.632 | +0,4 % (`-m3`) |
| disk | 263.568.325 / 249.118.252 | **−5,5 %** | — | — |
| insert | 206.340.416 / 191.391.339 | **−7,2 %** | — | — |
| db4k | 130.183.204 / 61.454.267 | **−52,8 %** | — | — |
| db8k | 103.592.168 / 58.966.115 | **−43,1 %** | 43.377.207 / 25.366.372 | **−41,5 %** |
| db16k | 81.223.876 / 56.816.935 | **−30,0 %** | — | — |

`disk`, `insert`, `db4k` y `db16k` no se corrieron con `-m5`.

### Cada uno con su mejor `-fragment`

La comparación más dura: el N que le conviene a zpaq contra el N que le
conviene a `-osrep`, corpus por corpus.

| corpus | `-m` | zpaq, su mejor N | `-osrep`, su mejor N | diferencia |
|---|---|---:|---:|---:|
| versions.tar | `-m1` | 8.460.677 (N=0) | **7.787.372** (N=3) | −8,0 % |
| pja.tar | `-m1` | 1.767.849 (N=3) | **1.756.721** (N=6) | −0,6 % |
| zpaqstd-history.tar | `-m1` | 11.365.904 (N=0) | **10.306.569** (N=0) | −9,3 % |
| versions.tar | `-m5` | 3.749.055 (N=3) | 3.789.882 (N=6) | +1,1 % |
| pja.tar | `-m5` | 971.240 (N=6) | 1.012.779 (N=6) | +4,3 % |
| zpaqstd-history.tar | `-m5` | 5.461.215 (N=0) | **4.603.534** (N=3) | −15,7 % |
| src-zpaqstd | `-m1` | 10.346.266 (N=3) | **9.819.016** (N=3) | −5,1 % |
| src-omega | `-m1` | 3.303.645 (N=0) | **3.169.248** (N=0) | −4,1 % |
| bin-releases | `-m1` | 48.619.026 (N=0) | **47.829.980** (N=0) | −1,6 % |
| mixed | `-m1` | 86.342.652 (N=6) | 86.539.943 (N=6) | +0,2 % |
| disk | `-m1` | 246.148.799 (N=3) | 249.118.252 (N=3) | +1,2 % |
| insert | `-m1` | 191.260.784 (N=3) | 191.391.339 (N=3) | +0,1 % |
| db4k | `-m1` | 60.719.985 (N=0) | **60.061.560** (N=0) | −1,1 % |
| db8k | `-m1` | 59.298.170 (N=0) | **58.952.206** (N=0) | −0,6 % |
| db16k | `-m1` | 58.440.778 (N=0) | **56.816.935** (N=3) | −2,8 % |
| db8k | `-m5` | 27.097.423 (N=3) | **25.366.372** (N=3) | −6,4 % |
| photos | `-m1` | 97.870.612 (N=6) | **97.667.353** (N=6) | −0,2 % |
| photos | `-m3` | 90.820.501 (N=6) | 90.824.126 (N=6) | +0,0 % |
| src-zpaqstd | `-m5` | 6.101.510 (N=3) | **5.858.076** (N=3) | −4,0 % |
| src-omega | `-m5` | 2.354.354 (N=0) | **2.315.970** (N=0) | −1,6 % |
| bin-releases | `-m5` | 30.719.486 (N=0) | **30.192.308** (N=0) | −1,7 % |
| mixed | `-m5` | 71.571.832 (N=6) | 71.612.432 (N=6) | +0,1 % |

### Memoria del índice

RSS pico (MB) de `x` (extraer la última versión, con el zpaq-std sin parche)
y de agregar la última versión sobre el archivo con todas las anteriores,
`-threads 4`, defaults:

| corpus | `-m` | `x` zpaq / `-osrep` | última versión zpaq / `-osrep` |
|---|---|---:|---:|
| zpaqstd-history.tar | `-m5` | 2.152 / 917 | (un solo `a`: 2.384 / 1.061) |
| src-zpaqstd (16 versiones) | `-m5` | 925 / 767 | 230 / 230 |
| bin-releases (39 versiones) | `-m5` | 352 / 435 | 195 / 193 |
| src-omega (40 versiones) | `-m5` | 226 / 307 | 101 / 99 |
| db8k (4 versiones) | `-m5` | 3.232 / 1.853 | 962 / 330 |
| disk (2 versiones) | `-m1` | 140 / 148 | 372 / 226 |
| disk, N=3 los dos | `-m1` | 144 / 149 | 175 / 227 |

Con `-m5` el RSS lo domina el compresor; donde zpaq guarda fragmentos
grandes y muchos datos únicos (historial, db8k) `-osrep` pide mucho menos.
Pide más (+24 a +36 % en `x`) en los árboles de muchas versiones chicas
(`bin-releases`, `src-omega`) default contra default, por tener 8× más
fragmentos nominales (N=3 contra N=6), y en `disk` N=3 al agregar v2 (+30 %,
33 % más fragmentos). Al mismo N, el RSS de `x` es igual o menor salvo en
algunas filas N=0 (hasta +13 %). El RSS de `x` varía un ~5 % entre corridas
(el mismo archivo, `osrep:3` y `osrep:d`, dio 426 y 435 MB).

### Dónde pierde todavía, en orden

Ordenadas por cuánto le falta a `-osrep` para ganarle a zpaq **con el mejor
`-fragment` de cada uno**, que es la comparación que importa (el default ya
gana casi siempre).

#### 1. PJA y tars con `-m5`: deduplica más y el archivo sale más grande

- PJA `-m5`: +4,3 % con el mejor N de cada uno (+5,2 % default contra
  default); `versions.tar -m5`: +1,1 %, y +1,5/+3,5 % en N=0/3.
- **Por qué**: con `-m5` todo el tar entra en un bloque y el modelo de contexto
  ya encuentra la redundancia entre versiones. La deduplicación extra de
  `-osrep` (PJA N=6: 13,9 MB únicos contra 21,4 MB) no le ahorra nada al
  compresor y cuesta: 3× más fragmentos, que son ≈25 KB de índice de los 41 KB
  que pierde PJA N=6, y fragmentos cortados donde el modelo tenía contexto.
  Los cortes de formato y los cortes en 64 ceros hacen que "N=6" de `-osrep`
  promedie 23 KiB en vez de 64–72 KiB.
- ~~**Qué probar**: quitar `OSREP_FRAG_F_TAR_AFTER` desde `-m3` y calibrar N
  contra el fragmento medio real.~~ **Medido el 2026-11-25: ninguna de las dos
  sirve** ([`experiments/frag-tar-rule.md`](experiments/frag-tar-rule.md)).
  Sin la regla, `-m3` pierde 5–19 puntos y el historial `-m5` pasa de −15,7 %
  a +1,0 %; con la regla, pja `-m5` pierde +4,2–4,7 % con cualquier N de 0 a
  9. La pérdida es del caso "todas las versiones en un tar, en un solo `a`"
  (33 MB caben en un bloque de `-m5`): pja agregado como 5 carpetas pierde
  +0,3 % (`-m1`) y +0,5 % (`-m5`), que es el problema de los árboles chicos
  (punto 3).

#### 2. Imagen de disco con cambios sueltos: el mínimo A/2 tarda en reengancharse

- `disk -m1` N=3: +1,2 % el archivo; lo que cuesta v2 (350 cambios) es
  6,5 MB contra 3,8 MB (+70 %). Es el caso que zpaq-std nombra como su punto
  débil y `-osrep` no lo mejora en N=3.
- **Por qué**: el gear tiene un candidato de corte cada ~A/2 bytes y no corta
  antes de A/2 (4 KiB en N=3), así que después de un cambio la cadena de
  cortes de v2 tarda varios fragmentos en volver a los de v1. zpaq en N=3
  tiene mínimo 512 B y se reengancha enseguida.
- **Qué probar**: el mínimo. Con los cortes de formato y mínimo A/16,
  `frag_stats` da `disk` N=3 −2,1 % contra zpaq (hoy +0,9 %), `insert` −1,2 %
  (hoy 0,0 %), los tars en N=6 −43/−46 % (hoy −25/−26 %) y las bases de datos
  en N=6 −40/−52 % (hoy −30/−34 %); `src-zpaqstd` empeora (N=3 −1,5 % contra
  −4,7 %; N=6 +4,0 % contra −1,2 %). Parte de la ganancia es que el
  fragmento medio baja (disk N=3: 3,2 KiB contra 6,9 KiB), así que hay que
  medirlo en archivos reales y con `-m5` antes de cambiarlo. **Medido: con el
  mejor N de cada uno A/2 sigue siendo mejor en 9 de 12 casos `-m1`; rechazado
  ([`experiments/frag-minimum.md`](experiments/frag-minimum.md)).** Era la palanca más
  grande que dejó esta medición.

#### 3. Árboles de fuentes chicos a N fijo (`src-omega`)

- N=3: `-m1` +14,5 %, `-m5` +0,8 %; N=6: `-m1` +2,8 %, `-m5` +11,2 %. Con su
  mejor N (N=0) `-osrep` gana (−4,1 % / −1,6 %), y el default gana −14/−17 %.
- **Por qué**: en N=6 el mínimo de 32 KiB es más que casi todos los
  archivos, así que cada archivo cambiado es un fragmento entero (+9,2 % de
  bytes únicos según `frag_stats`). En N=3 la deduplicación casi empata
  (+0,9 %); el resto del +14,5 % de `-m1` es el orden de los bloques, que en
  este corpus cambia con la ruta de trabajo (±7–15 %, medido con 2.7.2).
- **Qué probar**: lo mismo que el punto 2 (con A/16 N=6 pasa a +4,7 %); no
  alcanza: el hash de orden 1 de zpaq corta los archivos de texto chicos más
  fino que el gear.

#### 4. Velocidad del corte: 1,8× más lento

- Corte solo: 166–172 MB/s contra 293–319 MB/s de zpaq. Con SHA-1, +27 %.
  `a -m1` tarda típicamente un 15–35 % más en carpetas (con `-m5` tarda igual o
  menos).
- **Por qué**: zpaq-std empuja byte a byte (`osrep_frag_state_push`, una
  llamada por byte) y los cortes de formato guardan cada byte en un anillo de
  512; `osrep_frag_state_scan()` no tiene camino rápido con reglas.
- **Qué probar**: las reglas de formato dentro de `osrep_frag_state_scan()` y
  que zpaq-std lo llame por bloques.

#### 5. Datos sin redundancia: +0,1 a +0,4 %

- mixed y photos: +0,1/+0,2 % con el mejor N; +0,2 a +0,4 % default contra
  default (N=3 tiene 8× más fragmentos que N=6, y cada uno es índice).
- **Qué probar**: nada barato; el promedio adaptativo ya se probó y no sirvió
  (`docs/experiments/frag-adaptive.md`).

#### 6. Un byte al principio de cada archivo: empate

- `insert` N=3 +0,1 %, N=6 −0,6 %. Los dos pierden el primer fragmento de cada
  archivo. Con mínimo A/16 sería −1,2 % (punto 2).

#### 7. Memoria del índice con muchos fragmentos

- Default contra default, `x` pide +24 % en `bin-releases` y +36 % en
  `src-omega` con `-m5`; agregar v2 a `disk` en N=3 pide +30 %. Es la otra
  cara de cortar más fino (N=3 contra N=6, o 33 % más fragmentos en `disk`).
  Donde hay muchos datos únicos pasa lo contrario: −57 % en el historial y
  −43 % en db8k con `-m5`. Si se baja el mínimo (punto 2), este número sube: hay que
  medirlo junto.

## Tablas por corpus

En las tablas de preprocesador solo, el tamaño de OSREP `-m3/-m5` **no se
compara** con el de SREP/REP: OSREP ya hace LZ con matches de 4 bytes (el
trabajo del backend), mientras que SREP/REP solo quitan repeticiones de
≥ 512 bytes. Lo que decide es el tamaño final con backend. Celdas vacías:
esa combinación no se corrió (ver Configuraciones).

### enwik8 (100,00 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 100,04 | 100,0 | 0,91 | 1,17 | 418 | 0,69 | 19 | ok |
| `osrep-m2` | 100,01 | 100,0 | 1,22 | 1,42 | 417 | 0,69 | 19 | ok |
| `osrep-m3` | 55,75 | 55,8 | 3,21 | 15,3 | 682 | 4,57 | 49 | ok |
| `osrep-m5` | **50,80** | 50,8 | 5,26 | 26,5 | 680 | 3,85 | 45 | ok |
| `osrep-dup-m5` | 50,80 | 50,8 | 6,42 | 28,9 | 958 | 4,46 | 45 | ok |
| `osrep-dup-m5-l32` | 90,80 | 90,8 | 6,82 | 30,1 | 928 | 0,90 | 26 | ok |
| `osrep-dup-m5-l128` | 98,78 | 98,8 | 8,63 | 38,7 | 928 | 0,85 | 26 | ok |
| `osrep-m5-l128-b256` | 98,23 | 98,2 | 109 | 109 | 781 | 0,69 | 203 | ok |
| `osrep-m5-l512-b256` | 99,85 | 99,9 | 112 | 112 | 780 | 0,77 | 204 | ok |
| `srep-m3f` | 99,92 | 99,9 | 0,43 | 0,52 | 23 | 0,12 | 19 | ok |
| `srep-m5f` | 99,85 | 99,9 | 0,53 | 0,71 | 24 | 0,16 | 20 | ok |
| `srep-m5f-l32` | 91,29 | 91,3 | 2,82 | 3,09 | 110 | 0,24 | 26 | ok |
| `omega-m3` | 99,92 | 99,9 | 0,81 | 0,79 | 23 | 0,39 | 25 | ok |
| `omega-m5` | 99,85 | 99,8 | 0,84 | 0,83 | 24 | 0,40 | 25 | ok |
| `rep-64mb` | 99,87 | 99,9 | 0,20 | 1,30 | 207 | 0,18 | 77 | ok |
| `rep-1gb` | 99,86 | 99,9 | 0,24 | 1,56 | 239 | 0,19 | 109 | ok |
| `zpaq-m0` | 100,06 | 100,1 | 0,86 | 0,85 | 44 | 1,07 | 26 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 24,865 | 26,395 | 35,693 | 19,626 |
| `osrep-m1` | 24,881 | 26,411 | 35,727 | 19,642 |
| `osrep-m2` |  |  | 35,701 |  |
| `osrep-m3` | 45,254 | 46,232 | 55,780 |  |
| `osrep-m5` | 42,060 | 43,016 | 51,010 |  |
| `osrep-dup-m5` | 42,064 | 43,017 | 51,016 |  |
| `osrep-dup-m5-l32` | 25,168 | 26,655 | 35,721 |  |
| `osrep-dup-m5-l128` | 24,869 | 26,395 | 35,691 |  |
| `osrep-m5-l128-b256` | **24,856** |  | **35,600** |  |
| `osrep-m5-l512-b256` | 24,862 |  | 35,679 |  |
| `srep-m3f` | 24,865 | 26,394 | 35,690 |  |
| `srep-m5f` | 24,864 | 26,389 | 35,684 | 19,622 |
| `omega-m5` | 24,863 | 26,391 | 35,681 |  |
| `rep-1gb` | 24,863 | **26,389** | 35,682 | **19,622** |
| `zpaq-m0` | 24,915 | 26,440 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 133 / 1,40 · 674 | 125 / 0,30 · 274 | 4,94 / 1,77 · 103 | 301 / 307 · 942 |
| `osrep-m1` | 75,1 / 1,67 · 675 | 51,4 / 0,93 · 418 | 5,21 / 2,23 · 418 | 302 / 307 · 942 |
| `osrep-m2` |  |  | 5,27 / 2,19 · 417 |  |
| `osrep-m3` | 46,1 / 6,36 · 682 | 24,4 / 4,93 · 682 | 6,03 / 6,10 · 682 |  |
| `osrep-m5` | 32,3 / 5,51 · 680 | 33,6 / 4,06 · 680 | 6,96 / 5,20 · 680 |  |
| `osrep-dup-m5` | 32,1 / 6,28 · 958 | 24,4 / 4,63 · 958 | 8,18 / 5,76 · 958 |  |
| `osrep-dup-m5-l32` | 108 / 2,06 · 928 | 79,8 / 1,13 · 928 | 11,4 / 2,85 · 928 |  |
| `osrep-dup-m5-l128` | 122 / 2,27 · 928 | 85,9 / 1,15 · 928 | 13,1 / 2,54 · 928 |  |
| `osrep-m5-l128-b256` | 172 / 1,70 · 781 |  | 113 / 2,16 · 781 |  |
| `osrep-m5-l512-b256` | 182 / 1,80 · 780 |  | 116 / 2,51 · 780 |  |
| `srep-m3f` | 122 / 1,32 · 674 | 65,9 / 0,35 · 273 | 4,77 / 1,86 · 98 |  |
| `srep-m5f` | 82,4 / 1,36 · 674 | 68,6 / 0,38 · 273 | 4,88 / 1,97 · 98 | 311 / 310 · 943 |
| `omega-m5` | 91,1 / 1,56 · 675 | 68,5 / 0,67 · 273 | 5,19 / 2,11 · 98 |  |
| `rep-1gb` | 89,4 / 1,43 · 674 | 64,3 / 0,44 · 272 | 4,42 / 1,83 · 239 | 294 / 312 · 943 |
| `zpaq-m0` | 77,9 / 2,14 · 675 | 63,3 / 1,32 · 272 |  |  |

### silesia.tar (211,96 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 211,24 | 99,7 | 1,96 | 2,57 | 735 | 1,45 | 19 | ok |
| `osrep-m2` | 211,97 | 100,0 | 2,32 | 2,87 | 737 | 1,43 | 19 | ok |
| `osrep-m3` | 98,82 | 46,6 | 3,92 | 17,0 | 670 | 6,38 | 88 | ok |
| `osrep-m5` | **90,41** | 42,7 | 6,49 | 29,0 | 641 | 5,76 | 80 | ok |
| `osrep-dup-m5` | 90,43 | 42,7 | 8,48 | 30,7 | 1249 | 5,69 | 79 | ok |
| `osrep-dup-m5-l32` | 138,06 | 65,1 | 10,2 | 41,6 | 1249 | 2,03 | 26 | ok |
| `osrep-dup-m5-l128` | 184,61 | 87,1 | 12,3 | 57,7 | 1249 | 1,69 | 26 | ok |
| `srep-m3f` | 204,94 | 96,7 | 0,74 | 0,96 | 30 | 0,23 | 18 | ok |
| `srep-m5f` | 200,63 | 94,7 | 0,76 | 1,06 | 31 | 0,20 | 20 | ok |
| `srep-m5f-l32` | 152,97 | 72,2 | 4,74 | 5,46 | 224 | 0,61 | 32 | ok |
| `omega-m3` | 204,88 | 96,7 | 1,56 | 1,56 | 30 | 0,78 | 40 | ok |
| `omega-m5` | 200,53 | 94,6 | 1,75 | 1,75 | 31 | 0,78 | 41 | ok |
| `rep-64mb` | 201,20 | 94,9 | 0,35 | 3,27 | 206 | 0,34 | 77 | ok |
| `rep-1gb` | 201,18 | 94,9 | 0,35 | 3,64 | 370 | 0,31 | 215 | ok |
| `zpaq-m0` | 212,06 | 100,0 | 1,68 | 1,68 | 45 | 2,06 | 26 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | **48,754** | 52,589 | 69,437 | **40,052** |
| `osrep-m1` | 48,785 | 52,645 | 69,470 | 40,073 |
| `osrep-m2` |  |  | 69,457 |  |
| `osrep-m3` | 76,320 | 78,844 | 92,109 |  |
| `osrep-m5` | 72,072 | 74,620 | 86,675 |  |
| `osrep-dup-m5` | 72,079 | 74,626 | 86,686 |  |
| `osrep-dup-m5-l32` | 51,361 | 54,619 | **69,045** |  |
| `osrep-dup-m5-l128` | 49,262 | 52,728 | 69,139 |  |
| `srep-m3f` | 48,779 | 52,612 | 69,615 |  |
| `srep-m5f` | 48,971 | 52,604 | 69,444 | 40,227 |
| `omega-m5` | 49,001 | **52,587** | 69,412 |  |
| `rep-1gb` | 48,967 | 52,595 | 69,845 | 40,224 |
| `zpaq-m0` | 48,968 | 52,693 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 88,6 / 2,03 · 675 | 93,8 / 0,45 · 396 | 7,51 / 3,00 · 100 | 241 / 208 · 2867 |
| `osrep-m1` | 87,6 / 3,48 · 735 | 95,0 / 1,91 · 735 | 9,33 / 4,67 · 735 | 205 / 204 · 2871 |
| `osrep-m2` |  |  | 9,68 / 4,35 · 737 |  |
| `osrep-m3` | 63,5 / 9,17 · 675 | 40,7 / 6,68 · 670 | 8,63 / 8,78 · 670 |  |
| `osrep-m5` | 56,7 / 8,70 · 667 | 37,8 / 6,04 · 641 | 10,3 / 8,00 · 641 |  |
| `osrep-dup-m5` | 62,4 / 8,65 · 1249 | 49,4 / 5,95 · 1249 | 12,4 / 8,05 · 1249 |  |
| `osrep-dup-m5-l32` | 85,2 / 4,29 · 1249 | 77,5 / 2,35 · 1249 | 16,8 / 4,83 · 1249 |  |
| `osrep-dup-m5-l128` | 108 / 3,96 · 1249 | 109 / 2,11 · 1249 | 19,5 / 4,58 · 1249 |  |
| `srep-m3f` | 89,2 / 2,33 · 675 | 88,9 / 0,74 · 372 | 7,93 / 3,09 · 99 |  |
| `srep-m5f` | 79,3 / 2,25 · 675 | 87,9 / 0,62 · 387 | 8,32 / 3,26 · 102 | 199 / 192 · 2782 |
| `omega-m5` | 84,2 / 2,92 · 675 | 91,4 / 1,20 · 379 | 9,07 / 3,76 · 102 |  |
| `rep-1gb` | 80,7 / 2,40 · 675 | 90,3 / 0,76 · 386 | 7,67 / 3,24 · 370 | 192 / 197 · 2806 |
| `zpaq-m0` | 82,5 / 4,09 · 675 | 89,9 / 2,48 · 378 |  |  |

### real64.bin (67,11 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 66,14 | 98,6 | 0,60 | 0,80 | 319 | 0,46 | 19 | ok |
| `osrep-m2` | 67,06 | 99,9 | 0,67 | 0,89 | 323 | 0,47 | 19 | ok |
| `osrep-m3` | 39,55 | 58,9 | 1,44 | 6,08 | 641 | 1,24 | 47 | ok |
| `osrep-m5` | 38,08 | 56,7 | 1,64 | 8,25 | 640 | 1,20 | 43 | ok |
| `osrep-dup-m5` | **38,07** | 56,7 | 2,30 | 9,66 | 825 | 1,31 | 43 | ok |
| `osrep-dup-m5-l32` | 45,15 | 67,3 | 4,13 | 15,4 | 825 | 0,59 | 25 | ok |
| `osrep-dup-m5-l128` | 52,66 | 78,5 | 3,16 | 16,3 | 825 | 0,56 | 25 | ok |
| `osrep-m5-l128-b256` | 51,89 | 77,3 | 34,7 | 34,6 | 530 | 0,47 | 124 | ok |
| `osrep-m5-l512-b256` | 57,05 | 85,0 | 46,7 | 46,5 | 530 | 0,46 | 129 | ok |
| `srep-m3f` | 58,33 | 86,9 | 0,24 | 0,29 | 21 | 0,10 | 21 | ok |
| `srep-m5f` | 56,70 | 84,5 | 0,31 | 0,39 | 22 | 0,08 | 19 | ok |
| `srep-m5f-l32` | 47,29 | 70,5 | 0,96 | 1,10 | 89 | 0,15 | 23 | ok |
| `omega-m3` | 58,29 | 86,9 | 0,50 | 0,50 | 21 | 0,26 | 28 | ok |
| `omega-m5` | 56,64 | 84,4 | 0,58 | 0,58 | 22 | 0,30 | 27 | ok |
| `rep-64mb` | 56,80 | 84,6 | 0,17 | 1,07 | 196 | 0,14 | 77 | ok |
| `rep-1gb` | 56,80 | 84,6 | 0,17 | 0,89 | 196 | 0,14 | 77 | ok |
| `zpaq-m0` | 67,09 | 100,0 | 0,67 | 0,67 | 44 | 0,77 | 28 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 30,398 | 31,112 | 35,124 | 29,178 |
| `osrep-m1` | 30,410 | 31,126 | 35,028 | 29,188 |
| `osrep-m2` |  |  | 35,131 |  |
| `osrep-m3` | 34,655 | 35,275 | 38,833 |  |
| `osrep-m5` | 33,952 | 34,566 | 37,927 |  |
| `osrep-dup-m5` | 33,954 | 34,566 | 37,910 |  |
| `osrep-dup-m5-l32` | 30,693 | 31,378 | 35,081 |  |
| `osrep-dup-m5-l128` | 30,397 | 31,128 | 35,039 |  |
| `osrep-m5-l128-b256` | 30,388 |  | **34,448** |  |
| `osrep-m5-l512-b256` | **30,374** |  | 34,570 |  |
| `srep-m3f` | 30,391 | 31,107 | 34,611 |  |
| `srep-m5f` | 30,382 | **31,102** | 34,583 | 29,160 |
| `omega-m5` | 30,382 | 31,102 | 34,571 |  |
| `rep-1gb` | 30,378 | 31,102 | 34,577 | **29,156** |
| `zpaq-m0` | 30,436 | 31,144 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 21,9 / 0,90 · 645 | 16,3 / 0,13 · 213 | 2,56 / 1,16 · 104 | 205 / 206 · 885 |
| `osrep-m1` | 19,7 / 1,27 · 639 | 16,7 / 0,59 · 319 | 2,93 / 1,50 · 319 | 200 / 203 · 885 |
| `osrep-m2` |  |  | 3,10 / 1,51 · 323 |  |
| `osrep-m3` | 16,5 / 2,17 · 641 | 13,4 / 1,34 · 641 | 3,01 / 2,31 · 641 |  |
| `osrep-m5` | 19,3 / 1,99 · 640 | 16,3 / 1,27 · 640 | 2,93 / 2,26 · 640 |  |
| `osrep-dup-m5` | 21,1 / 2,09 · 825 | 16,9 / 1,41 · 825 | 3,46 / 2,33 · 825 |  |
| `osrep-dup-m5-l32` | 21,0 / 1,45 · 825 | 17,0 / 0,69 · 825 | 6,18 / 1,64 · 825 |  |
| `osrep-dup-m5-l128` | 24,3 / 1,41 · 825 | 19,3 / 0,67 · 825 | 5,45 / 1,72 · 825 |  |
| `osrep-m5-l128-b256` | 50,8 / 1,26 · 530 |  | 36,6 / 1,45 · 530 |  |
| `osrep-m5-l512-b256` | 63,5 / 1,29 · 560 |  | 49,1 / 1,62 · 530 |  |
| `srep-m3f` | 19,7 / 0,95 · 572 | 18,1 / 0,20 · 205 | 2,65 / 1,22 · 104 |  |
| `srep-m5f` | 25,1 / 0,98 · 556 | 20,3 / 0,19 · 204 | 2,56 / 1,15 · 104 | 189 / 206 · 867 |
| `omega-m5` | 22,7 / 1,16 · 556 | 18,5 / 0,43 · 205 | 3,14 / 1,47 · 104 |  |
| `rep-1gb` | 21,5 / 1,09 · 558 | 26,2 / 0,40 · 205 | 2,72 / 1,34 · 196 | 216 / 312 · 865 |
| `zpaq-m0` | 25,1 / 1,69 · 645 | 37,0 / 0,92 · 213 |  |  |

### versions.tar (130,50 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 50,43 | 38,6 | 0,79 | 0,92 | 320 | 0,46 | 19 | ok |
| `osrep-m2` | 75,47 | 57,8 | 1,26 | 1,40 | 399 | 0,56 | 19 | ok |
| `osrep-m3` | 44,05 | 33,8 | 1,84 | 9,80 | 641 | 3,69 | 55 | ok |
| `osrep-m5` | 39,84 | 30,5 | 2,64 | 15,8 | 640 | 3,15 | 41 | ok |
| `osrep-dup-m5` | 22,15 | 17,0 | 3,42 | 10,1 | 911 | 2,00 | 38 | ok |
| `osrep-dup-m5-l32` | 43,14 | 33,1 | 4,14 | 15,3 | 911 | 0,75 | 22 | ok |
| `osrep-dup-m5-l128` | 60,80 | 46,6 | 4,75 | 17,8 | 911 | 0,64 | 24 | ok |
| `osrep-m5-l128-b256` | 24,98 | 19,1 | 16,7 | 16,7 | 1014 | 0,93 | 166 | ok |
| `osrep-m5-l512-b256` | 28,65 | 22,0 | 18,7 | 18,7 | 1013 | 0,88 | 169 | ok |
| `srep-m3f` | 29,90 | 22,9 | 0,28 | 0,40 | 26 | 0,22 | 52 | ok |
| `srep-m5f` | 28,34 | 21,7 | 0,35 | 0,51 | 27 | 0,20 | 52 | ok |
| `srep-m5f-l32` | **20,55** | 15,7 | 1,42 | 1,79 | 159 | 0,23 | 53 | ok |
| `omega-m3` | 29,86 | 22,9 | 0,68 | 0,68 | 25 | 0,33 | 95 | ok |
| `omega-m5` | 28,30 | 21,7 | 0,78 | 0,78 | 27 | 0,33 | 127 | ok |
| `rep-64mb` | 28,12 | 21,5 | 0,23 | 1,69 | 168 | 0,22 | 77 | ok |
| `rep-1gb` | 28,11 | 21,5 | 0,28 | 2,16 | 237 | 0,26 | 137 | ok |
| `zpaq-m0` | 75,50 | 57,9 | 0,90 | 0,90 | 44 | 0,83 | 28 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 4,720 | 4,929 | 15,293 | 4,549 |
| `osrep-m1` | 4,723 | 4,918 | 8,874 | 3,624 |
| `osrep-m2` |  |  | 15,301 |  |
| `osrep-m3` | 12,794 | 13,563 | 33,578 |  |
| `osrep-m5` | 12,170 | 12,884 | 28,843 |  |
| `osrep-dup-m5` | 11,975 | 12,459 | 21,941 |  |
| `osrep-dup-m5-l32` | 5,259 | 5,490 | 12,570 |  |
| `osrep-dup-m5-l128` | 4,749 | 4,951 | 13,593 |  |
| `osrep-m5-l128-b256` | 4,705 |  | **6,851** | 3,618 |
| `osrep-m5-l512-b256` | 4,703 |  | 6,921 |  |
| `srep-m3f` | 4,704 | 4,898 | 6,963 |  |
| `srep-m5f` | 4,701 | 4,890 | 6,928 | 3,595 |
| `omega-m5` | 4,701 | 4,886 | 6,920 |  |
| `rep-1gb` | **4,686** | **4,885** | 6,914 | **3,590** |
| `zpaq-m0` | 4,748 | 4,957 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 39,7 / 0,41 · 675 | 16,6 / 0,20 · 283 | 2,75 / 1,01 · 96 | 202 / 194 · 927 |
| `osrep-m1` | 14,1 / 0,69 · 504 | 11,5 / 0,54 · 320 | 2,33 / 1,02 · 320 | 137 / 137 · 896 |
| `osrep-m2` |  |  | 3,46 / 1,39 · 399 |  |
| `osrep-m3` | 17,1 / 4,25 · 641 | 19,1 / 3,78 · 641 | 3,95 / 4,68 · 641 |  |
| `osrep-m5` | 16,0 / 3,76 · 640 | 18,0 / 3,23 · 640 | 4,58 / 4,08 · 640 |  |
| `osrep-dup-m5` | 11,5 / 2,56 · 911 | 11,9 / 2,07 · 911 | 4,17 / 2,62 · 911 |  |
| `osrep-dup-m5-l32` | 17,6 / 1,03 · 911 | 12,2 / 0,82 · 911 | 5,65 / 1,33 · 911 |  |
| `osrep-dup-m5-l128` | 26,0 / 0,93 · 911 | 16,8 / 0,73 · 911 | 6,92 / 1,43 · 911 |  |
| `osrep-m5-l128-b256` | 25,9 / 1,16 · 1014 |  | 17,6 / 1,35 · 1014 | 76,1 / 65,3 · 1013 |
| `osrep-m5-l512-b256` | 28,2 / 1,09 · 1013 |  | 19,6 / 1,23 · 1013 |  |
| `srep-m3f` | 11,9 / 0,45 · 325 | 11,9 / 0,27 · 139 | 1,27 / 0,62 · 97 |  |
| `srep-m5f` | 10,8 / 0,45 · 314 | 11,4 / 0,26 · 137 | 1,35 / 0,60 · 97 | 76,4 / 79,4 · 539 |
| `omega-m5` | 11,2 / 0,58 · 314 | 12,1 / 0,40 · 137 | 1,81 / 0,73 · 96 |  |
| `rep-1gb` | 11,0 / 0,52 · 312 | 11,2 / 0,32 · 237 | 1,33 / 0,63 · 237 | 75,9 / 75,1 · 540 |
| `zpaq-m0` | 21,9 / 1,12 · 652 | 17,6 / 0,94 · 228 |  |  |

### pja.tar (33,59 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 12,63 | 37,6 | 0,31 | 0,27 | 83 | 0,10 | 31 | ok |
| `osrep-m2` | 21,44 | 63,8 | 0,41 | 0,39 | 116 | 0,15 | 39 | ok |
| `osrep-m3` | 9,84 | 29,3 | 0,57 | 1,75 | 322 | 0,81 | 30 | ok |
| `osrep-m5` | 8,81 | 26,2 | 0,87 | 3,17 | 321 | 0,73 | 28 | ok |
| `osrep-dup-m5` | 4,96 | 14,8 | 1,23 | 2,11 | 279 | 0,46 | 48 | ok |
| `osrep-dup-m5-l32` | 9,17 | 27,3 | 1,61 | 3,03 | 279 | 0,20 | 38 | ok |
| `osrep-dup-m5-l128` | 12,58 | 37,5 | 1,69 | 3,20 | 278 | 0,17 | 37 | ok |
| `osrep-m5-l128-b256` | 6,05 | 18,0 | 1,91 | 1,91 | 274 | 0,23 | 43 | ok |
| `osrep-m5-l512-b256` | 6,72 | 20,0 | 2,17 | 2,17 | 274 | 0,25 | 44 | ok |
| `srep-m3f` | 6,96 | 20,7 | 0,07 | 0,10 | 19 | 0,05 | 23 | ok |
| `srep-m5f` | 6,70 | 19,9 | 0,10 | 0,13 | 20 | 0,05 | 23 | ok |
| `srep-m5f-l32` | **4,92** | 14,7 | 0,39 | 0,45 | 55 | 0,06 | 21 | ok |
| `omega-m3` | 6,96 | 20,7 | 0,20 | 0,20 | 19 | 0,09 | 25 | ok |
| `omega-m5` | 6,69 | 19,9 | 0,22 | 0,22 | 20 | 0,09 | 26 | ok |
| `rep-64mb` | 6,62 | 19,7 | 0,09 | 0,43 | 81 | 0,07 | 45 | ok |
| `rep-1gb` | 6,62 | 19,7 | 0,08 | 0,39 | 81 | 0,07 | 45 | ok |
| `zpaq-m0` | 21,45 | 63,9 | 0,27 | 0,27 | 43 | 0,28 | 26 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 1,180 | 1,229 | 2,818 | 0,971 |
| `osrep-m1` | 1,181 | 1,229 | 1,733 | 0,973 |
| `osrep-m2` |  |  | 2,817 |  |
| `osrep-m3` | 2,935 | 3,033 | 9,780 |  |
| `osrep-m5` | 2,777 | 2,876 | 8,734 |  |
| `osrep-dup-m5` | 2,808 | 2,909 | 4,915 |  |
| `osrep-dup-m5-l32` | 1,361 | 1,410 | 1,875 |  |
| `osrep-dup-m5-l128` | 1,189 | 1,238 | 1,730 |  |
| `osrep-m5-l128-b256` | 1,177 |  | **1,702** |  |
| `osrep-m5-l512-b256` | 1,176 |  | 1,717 |  |
| `srep-m3f` | 1,174 | 1,222 | 1,722 |  |
| `srep-m5f` | 1,173 | 1,221 | 1,718 | 0,965 |
| `omega-m5` | 1,174 | **1,221** | 1,718 |  |
| `rep-1gb` | **1,173** | 1,222 | 1,717 | **0,965** |
| `zpaq-m0` | 1,192 | 1,240 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 8,81 / 0,10 · 358 | 2,90 / 0,05 · 154 | 0,64 / 0,22 · 92 | 54,5 / 67,5 · 525 |
| `osrep-m1` | 3,23 / 0,19 · 179 | 2,76 / 0,13 · 110 | 0,67 / 0,28 · 92 | 33,6 / 35,1 · 317 |
| `osrep-m2` |  |  | 0,97 / 0,41 · 116 |  |
| `osrep-m3` | 2,84 / 0,93 · 322 | 3,35 / 0,83 · 322 | 0,92 / 1,06 · 322 |  |
| `osrep-m5` | 2,54 / 0,85 · 321 | 3,00 / 0,75 · 321 | 1,18 / 1,00 · 321 |  |
| `osrep-dup-m5` | 2,56 / 0,60 · 279 | 2,35 / 0,47 · 279 | 1,42 / 0,60 · 279 |  |
| `osrep-dup-m5-l32` | 4,39 / 0,29 · 279 | 3,52 / 0,23 · 279 | 1,91 / 0,35 · 279 |  |
| `osrep-dup-m5-l128` | 5,67 / 0,27 · 278 | 4,48 / 0,20 · 278 | 2,07 / 0,34 · 278 |  |
| `osrep-m5-l128-b256` | 4,11 / 0,31 · 274 |  | 2,14 / 0,35 · 274 |  |
| `osrep-m5-l512-b256` | 4,42 / 0,31 · 274 |  | 2,43 / 0,34 · 274 |  |
| `srep-m3f` | 2,59 / 0,12 · 132 | 2,91 / 0,06 · 99 | 0,38 / 0,15 · 53 |  |
| `srep-m5f` | 2,62 / 0,13 · 128 | 2,73 / 0,07 · 99 | 0,36 / 0,15 · 54 | 17,6 / 17,9 · 209 |
| `omega-m5` | 2,59 / 0,16 · 129 | 3,20 / 0,10 · 99 | 0,49 / 0,21 · 52 |  |
| `rep-1gb` | 2,52 / 0,14 · 125 | 2,80 / 0,08 · 100 | 0,35 / 0,18 · 81 | 17,0 / 17,0 · 209 |
| `zpaq-m0` | 5,75 / 0,38 · 254 | 3,50 / 0,31 · 126 |  |  |

### zpaqstd-history.tar (241,68 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 91,05 | 37,7 | 1,47 | 1,67 | 535 | 0,76 | 19 | ok |
| `osrep-m2` | 153,28 | 63,4 | 2,30 | 2,70 | 652 | 1,09 | 19 | ok |
| `osrep-m3` | 79,34 | 32,8 | 3,00 | 14,2 | 649 | 5,87 | 54 | ok |
| `osrep-m5` | 71,78 | 29,7 | 4,79 | 26,6 | 642 | 5,36 | 53 | ok |
| `osrep-dup-m5` | 45,45 | 18,8 | 5,02 | 19,4 | 1163 | 3,68 | 53 | ok |
| `osrep-dup-m5-l32` | 88,66 | 36,7 | 6,49 | 27,0 | 1165 | 1,42 | 22 | ok |
| `osrep-dup-m5-l128` | 123,03 | 50,9 | 7,30 | 32,6 | 1164 | 1,18 | 24 | ok |
| `osrep-m5-l128-b256` | 28,81 | 11,9 | 47,8 | 47,5 | 1862 | 1,54 | 291 | ok |
| `osrep-m5-l512-b256` | 34,27 | 14,2 | 37,1 | 37,1 | 1862 | 1,55 | 294 | ok |
| `srep-m3f` | 37,94 | 15,7 | 0,38 | 0,58 | 34 | 0,30 | 58 | ok |
| `srep-m5f` | 34,10 | 14,1 | 0,54 | 0,83 | 36 | 0,30 | 57 | ok |
| `srep-m5f-l32` | **23,88** | 9,9 | 2,76 | 3,28 | 281 | 0,39 | 60 | ok |
| `omega-m3` | 37,85 | 15,7 | 1,09 | 1,09 | 33 | 0,47 | 120 | ok |
| `omega-m5` | 33,99 | 14,1 | 1,28 | 1,28 | 36 | 0,43 | 119 | ok |
| `rep-64mb` | 42,43 | 17,6 | 0,37 | 3,79 | 182 | 0,40 | 77 | ok |
| `rep-1gb` | 33,36 | 13,8 | 0,43 | 4,62 | 364 | 0,45 | 243 | ok |
| `zpaq-m0` | 153,34 | 63,4 | 1,54 | 1,53 | 44 | 1,56 | 26 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 5,469 | 5,912 | 32,598 | 8,457 |
| `osrep-m1` | 5,481 | 5,716 | 16,612 | 5,627 |
| `osrep-m2` |  |  | 32,603 |  |
| `osrep-m3` | 25,117 | 27,611 | 61,291 |  |
| `osrep-m5` | 24,306 | 26,572 | 57,948 |  |
| `osrep-dup-m5` | 22,063 | 23,409 | 45,062 |  |
| `osrep-dup-m5-l32` | 6,526 | 6,879 | 24,652 |  |
| `osrep-dup-m5-l128` | 5,590 | 5,802 | 28,613 |  |
| `osrep-m5-l128-b256` | 5,437 |  | **7,995** | 4,207 |
| `osrep-m5-l512-b256` | 5,437 |  | 8,194 |  |
| `srep-m3f` | 5,445 | 5,670 | 8,496 |  |
| `srep-m5f` | 5,437 | 5,636 | 8,225 | **4,172** |
| `omega-m5` | 5,435 | 5,639 | 8,199 |  |
| `rep-1gb` | **5,417** | **5,622** | 8,148 | 4,175 |
| `zpaq-m0` | 5,768 | 5,808 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 56,0 / 0,47 · 675 | 26,3 / 0,21 · 387 | 5,00 / 1,84 · 96 | 193 / 196 · 2377 |
| `osrep-m1` | 24,1 / 1,06 · 669 | 17,8 / 0,89 · 535 | 4,04 / 1,73 · 535 | 204 / 191 · 1521 |
| `osrep-m2` |  |  | 6,88 / 2,82 · 652 |  |
| `osrep-m3` | 31,8 / 6,96 · 657 | 33,9 / 6,02 · 649 | 6,68 / 7,62 · 649 |  |
| `osrep-m5` | 29,2 / 6,41 · 649 | 32,0 / 5,51 · 642 | 7,77 / 6,97 · 642 |  |
| `osrep-dup-m5` | 21,3 / 4,63 · 1163 | 22,5 / 3,79 · 1163 | 6,44 / 4,76 · 1163 |  |
| `osrep-dup-m5-l32` | 32,7 / 1,78 · 1165 | 20,5 / 1,52 · 1165 | 9,49 / 2,60 · 1165 |  |
| `osrep-dup-m5-l128` | 41,4 / 1,57 · 1164 | 25,9 / 1,32 · 1164 | 11,4 / 2,77 · 1164 |  |
| `osrep-m5-l128-b256` | 59,0 / 1,77 · 1862 |  | 48,8 / 1,92 · 1862 | 110 / 91,5 · 1862 |
| `osrep-m5-l512-b256` | 49,2 / 1,83 · 1862 |  | 38,2 / 2,00 · 1862 |  |
| `srep-m3f` | 13,0 / 0,57 · 396 | 13,8 / 0,37 · 163 | 1,61 / 0,79 · 96 |  |
| `srep-m5f` | 12,1 / 0,60 · 364 | 13,1 / 0,37 · 159 | 1,66 / 0,76 · 96 | 92,7 / 96,3 · 1001 |
| `omega-m5` | 12,5 / 0,70 · 362 | 13,7 / 0,50 · 159 | 2,41 / 0,88 · 95 |  |
| `rep-1gb` | 11,5 / 0,70 · 364 | 12,2 / 0,52 · 364 | 1,55 / 0,92 · 364 | 92,7 / 90,3 · 677 |
| `zpaq-m0` | 37,3 / 1,94 · 675 | 25,8 / 1,72 · 303 |  |  |

### game-assets.tar (584,50 MB)

Preprocesador solo (MB = 10^6 bytes; tiempos en s; RSS en MB):

| config | salida MB | % | cod s | cod CPU s | cod RSS | dec s | dec RSS | ida y vuelta |
|---|---:|---:|---:|---:|---:|---:|---:|:-:|
| `osrep-m1` | 550,52 | 94,2 | 5,69 | 7,23 | 2114 | 5,38 | 19 | ok |
| `osrep-m2` | 570,72 | 97,6 | 5,67 | 7,42 | 2192 | 3,73 | 19 | ok |
| `osrep-m3` | 376,32 | 64,4 | 11,1 | 56,4 | 660 | 9,88 | 51 | ok |
| `osrep-m5` | 369,61 | 63,2 | 13,2 | 70,6 | 650 | 9,45 | 50 | ok |
| `osrep-dup-m5` | **367,96** | 63,0 | 17,5 | 75,4 | 2714 | 10,5 | 51 | ok |
| `osrep-dup-m5-l32` | 405,00 | 69,3 | 21,8 | 112 | 2705 | 6,26 | 27 | ok |
| `osrep-dup-m5-l128` | 445,85 | 76,3 | 26,1 | 130 | 2704 | 8,88 | 26 | ok |
| `srep-m3f` | 479,23 | 82,0 | 1,45 | 2,07 | 60 | 0,54 | 26 | ok |
| `srep-m5f` | 463,57 | 79,3 | 2,20 | 3,05 | 67 | 0,56 | 26 | ok |
| `srep-m5f-l32` | 412,71 | 70,6 | 10,6 | 12,9 | 639 | 0,87 | 31 | ok |
| `omega-m3` | 478,67 | 81,9 | 3,88 | 3,88 | 60 | 1,80 | 43 | ok |
| `omega-m5` | 463,01 | 79,2 | 4,86 | 4,86 | 68 | 1,79 | 44 | ok |
| `rep-64mb` | 472,78 | 80,9 | 0,82 | 9,19 | 207 | 0,91 | 77 | ok |
| `rep-1gb` | 465,98 | 79,7 | 0,92 | 10,5 | 757 | 0,96 | 571 | ok |
| `zpaq-m0` | 570,96 | 97,7 | 4,45 | 4,36 | 45 | 5,36 | 27 | ok |

Tamaño final con backend (MB con tres decimales; en negrita, el mejor de la columna):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 301,238 | 308,623 | 351,169 | 289,670 |
| `osrep-m1` | 301,331 | 308,743 | 350,301 | 288,969 |
| `osrep-m2` |  |  | 351,203 |  |
| `osrep-m3` | 334,444 | 342,016 | 370,083 |  |
| `osrep-m5` | 331,066 | 338,161 | 365,658 |  |
| `osrep-dup-m5` | 330,534 | 337,373 | 364,071 |  |
| `osrep-dup-m5-l32` | 302,982 | 310,069 | 342,069 |  |
| `osrep-dup-m5-l128` | 301,557 | 308,771 | 343,910 |  |
| `srep-m3f` | **301,187** | 308,636 | 343,165 |  |
| `srep-m5f` | 301,255 | 308,509 | 340,169 | 288,640 |
| `omega-m5` | 301,251 | **308,504** | **340,086** |  |
| `rep-1gb` | 301,248 | 308,565 | 340,337 | **288,603** |
| `zpaq-m0` | 301,569 | 308,902 |  |  |

Tiempo total de la tubería, codificar / decodificar (s), y RSS pico de la etapa más pesada (MB):

| preprocesador | xz | zstd | zpaq-m1 | zpaq-m5 |
|---|---:|---:|---:|---:|
| `none` | 191 / 9,41 · 675 | 171 / 0,95 · 573 | 14,7 / 8,55 · 108 | 520 / 605 · 3968 |
| `osrep-m1` | 219 / 14,1 · 2114 | 169 / 6,31 · 2114 | 20,0 / 13,9 · 2114 | 570 / 536 · 3951 |
| `osrep-m2` |  |  | 20,4 / 12,3 · 2192 |  |
| `osrep-m3` | 239 / 16,2 · 675 | 145 / 10,5 · 660 | 21,4 / 17,7 · 660 |  |
| `osrep-m5` | 195 / 16,1 · 675 | 126 / 10,1 · 650 | 21,1 / 15,8 · 650 |  |
| `osrep-dup-m5` | 212 / 16,8 · 2714 | 162 / 11,1 · 2714 | 25,6 / 16,9 · 2714 |  |
| `osrep-dup-m5-l32` | 236 / 13,4 · 2705 | 167 / 7,08 · 2705 | 32,5 / 12,8 · 2705 |  |
| `osrep-dup-m5-l128` | 242 / 17,5 · 2704 | 183 / 9,81 · 2704 | 37,7 / 17,1 · 2704 |  |
| `srep-m3f` | 217 / 9,20 · 675 | 168 / 1,50 · 586 | 14,2 / 8,01 · 108 |  |
| `srep-m5f` | 220 / 8,83 · 675 | 169 / 1,50 · 597 | 15,5 / 8,11 · 108 | 548 / 539 · 3796 |
| `omega-m5` | 219 / 9,90 · 675 | 175 / 2,68 · 597 | 18,1 / 9,48 · 108 |  |
| `rep-1gb` | 220 / 9,05 · 757 | 169 / 1,89 · 757 | 13,2 / 8,27 · 757 | 486 / 542 · 3816 |
| `zpaq-m0` | 220 / 14,1 · 675 | 170 / 6,32 · 581 |  |  |
