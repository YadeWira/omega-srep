# zpaq-std OSREP mode — benchmarks

**Estado: `-osrep` integrado (2026-11-12, rama `frag-int`); portado a
zpaq-std 2.11.0 y medido contra su deduplicador el 2026-11-15 (ver
[zpaq-std 2.11.0](#zpaq-std-2110-2026-11-15)).** El fragmentador
de zpaq-std puede usar el de OSREP en lugar del de orden 1. El formato ZPAQ no
cambia: solo cambian los cortes y, por lo tanto, el tamaño del archivo. El
zpaq-std sin modificar extrae todos los archivos `-osrep`.

## Qué hace `-osrep` (desde 2026-11-12)

- **`-fragment N` significa lo mismo que en zpaq**: un promedio de
  A = 2^N KiB (N=0 1 KiB, N=3 8 KiB, N=6 64 KiB). **`-osrep` sin `-fragment`
  usa N=3 (8 KiB)**; el default de zpaq sigue siendo N=6. N válido: 0..21.
  Con `-stdin` zpaq fuerza N=6, también con `-osrep`.
- **CDC gear** (ventana de 64 bytes, `h = (h << 1) + G[c]`, `G[0] = 0`):
  mínimo A/2, máximo el de zpaq (`8128 << N`, recortado al bloque, igual que
  `MAX_FRAGMENT`), un umbral calibrado para que datos aleatorios promedien A.
  Viene del experimento [`frag-normalized`](experiments/frag-normalized.md).
- **Cortes de formato** (`OSREP_FRAG_F_FORMAT`, del experimento
  [`frag-formataware`](experiments/frag-formataware.md)): después de cada
  cabecera tar con checksum válido, después de `PK\3\4`, del resto de la
  cabecera local de zip y de la primera `PK\1\2`. Ignoran el mínimo y nunca
  hacen retroceder un corte.
- Toda la política está en `osrep_frag_params_osrep(&p, N, blocksize)`;
  zpaq-std solo llama a esa función, a `osrep_frag_state_reset()` y a
  `osrep_frag_state_push()` (ver [`zpaq-fragment-api.md`](zpaq-fragment-api.md)).
  El estado depende solo de los bytes desde el último corte, así que el lazo
  simple y los workers de `add2_scan` cortan igual con cualquier número de
  hilos.
- Parche de referencia: `tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.7.2.patch`
  (`git format-patch` sobre `b8ad717`, zpaq-std 2.7.2).

## zpaq-std 2.11.0 (2026-11-15)

Medición interna para el scoreboard ([`scoreboard.md`](scoreboard.md#dedup-osrep-contra-el-deduplicador-de-zpaq-std)):
no se publica nada. El parche `-osrep` se portó a zpaq-std 2.11.0 (`6b165e3`,
que integra zpaqfranz 65.20) y se midió contra el deduplicador de zpaq en los
corpus de antes y en tres corpus nuevos que apuntan a sus puntos débiles.

### El parche

`tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.11.0.patch` (`git
format-patch` sobre `6b165e3`; aplica limpio con `git apply`):

- Es el parche de 2.7.2 con dos cambios. El `Makefile` tuvo un conflicto:
  2.10.0 agregó fuentes a `LZ6SRC`, y `OSREPSRC` va después. Los trozos de
  `zpaq-std.cpp` entraron sin conflicto (desplazados): `-osrep`,
  `g_fragmentgiven` (N=3 solo si `-fragment` no leyó un número), la
  comprobación de N en `testparametriadd()` antes de cualquier hilo, el lazo
  simple de `add()`/`add2()` y `add2_scan_osrep()` para los workers de
  `-turbo`.
- **Nuevo**: con `-sa`/`-sae`/`-sat`, la consulta "¿parte de este archivo ya
  está en el archivo?" (`fragment_buffer()` en `add2()`) usaba los cortes de
  zpaq aunque el archivo se fuera a cortar con `-osrep`. Ahora usa
  `osrep_fragment_buffer()` con los mismos parámetros. No se probó con
  códecs reales: `-sa` necesita los códecs externos (PJA/PPA), que no están en
  este build.
- 65.18/65.20 no cambiaron los lazos de corte. Lo que sí cambió es el lote de
  `-turbo`: ya no es fijo de 64 MB, depende del tamaño de bloque y de los
  hilos (`-turbochunk` lo fija). Como el estado de `-osrep` empieza de cero en
  cada corte, el lote no cambia los cortes: `versions.tar -m1 -osrep` da el
  mismo archivo con `-noturbo`, `-t8 -turbochunk 1`, `-t3 -turbochunk 1` y
  `-t2 -turbochunk 7`.
- `compressors/osrep/` es copia byte a byte de `src/c/osrep_fragment.c`,
  `osrep_fragment.h`, `osrep_sha1.c` y `LICENSE` de `803de06`.

`osrep-switch-test.sh` (baseline 2.11.0 contra el parcheado, `versions.tar`
y `pja.tar`): **fails=0**. Sin `-osrep` el archivo es byte a byte el del
baseline (`-m0`/`-m1`/`-m5`, con y sin `-noturbo`); con `-osrep` es el mismo
con hilos por defecto, `-t1`, `-t8` y `-noturbo`; sin `-fragment` es N=3; el
baseline extrae los 12 archivos; `-fragment 22` sale con error (exit 2).
Los tamaños de los tars son los de 2.7.2 a menos de 10 bytes.

### Cómo se midió

- Binarios: baseline = zpaq-std 2.11.0 sin cambios; parcheado = el parche de
  arriba. Mismo compilador y `make -j4`.
- Tars (`versions.tar`, `pja.tar` y `zpaqstd-history.tar`, los 8 tags de
  zpaq-std del scoreboard) con `bench_fair.py`; carpetas con
  `bench_versions.py` (cada versión se copia sobre la misma carpeta y se
  agrega al mismo archivo). Todo con `-threads 4` en `a`, `l` y `x`.
- Configuraciones: zpaq `-fragment N` contra `-osrep -fragment N` con N=0, 3
  y 6, y los defaults (zpaq N=6, `-osrep` N=3).
- **Corpus nuevos** (`tools/zpaq-vectors/make_weakspots.py`, semilla fija,
  archivos reales; la versión k tiene fecha 2024-k-01):
  - `disk`: imagen de disco de 512 MiB: 4 MiB de metadatos (un registro de
    256 B por archivo) y 2.373 archivos reales (mixed, photos v1, fuentes de
    zpaq-std 2.7.2, binarios, silesia) en sectores de 4 KiB, el 20 % de los
    de más de 32 KiB partidos en 2–4 extents intercalados, con huecos de
    ceros. v2 cambia 350 cosas sueltas: 200 sectores enteros (datos nuevos),
    8–64 bytes dentro de otros 100 y 50 registros de metadatos.
  - `insert`: un árbol de 2.477 archivos (317 MB: mixed, photos v1, fuentes,
    binarios) y el mismo árbol con un byte agregado al principio de cada
    archivo.
  - `db4k`, `db8k`, `db16k`: un archivo de 128 MiB en páginas de 4, 8 y 16
    KiB (cabecera con número de página, LSN y CRC; registros de texto de
    enwik8) en 4 versiones: cada una cambia un registro en el 2 % de las
    páginas, intercambia de a pares el 0,5 % (cambia el número de página en la
    cabecera, los registros no) y agrega un 1 % de páginas.
- Una corrida por celda, con la máquina compartida: los tamaños son exactos;
  los tiempos, indicativos. **Las 154 extracciones dieron los bytes
  originales** (la última versión, en las carpetas). La primera corrida de
  `disk` falló esa comprobación: v1 y v2 tenían el mismo tamaño y la misma
  fecha, y zpaq no agregó v2. Desde entonces cada versión tiene su fecha y
  `disk -m1` se repitió.
- `-m5` en `disk`, `insert`, `db4k` y `db16k` no se corrió (2–4 h cada uno con
  `x` incluido); `db8k -m5` solo en N=3 y los defaults. Para esos corpus la
  deduplicación se ve sin compresor en `frag_stats` (más abajo).

### Tamaño del archivo

Cada celda: zpaq-std con `-fragment N` / con `-osrep -fragment N`, y la
diferencia de `-osrep`. En negrita, cuando `-osrep` gana por más de 0,1 %.

| corpus | `-m` | N=0 zpaq / osrep | N=3 | N=6 | default (zpaq 6 / osrep 3) | ok |
|---|---|---|---|---|---|---|
| versions.tar | `-m1` | 8.460.677 / **8.008.235** (−5,3 %) | 9.835.629 / **7.787.372** (−20,8 %) | 15.293.566 / **10.732.265** (−29,8 %) | 15.293.566 / **7.787.372** (−49,1 %) | sí |
| pja.tar | `-m1` | 1.942.760 / 1.957.732 (+0,8 %) | 1.767.849 / 1.777.493 (+0,5 %) | 2.817.680 / **1.756.721** (−37,7 %) | 2.817.680 / **1.777.493** (−36,9 %) | sí |
| zpaqstd-history.tar | `-m1` | 11.365.904 / **10.306.569** (−9,3 %) | 18.000.930 / **11.702.495** (−35,0 %) | 32.598.013 / **22.119.764** (−32,1 %) | 32.598.013 / **11.702.495** (−64,1 %) | sí |
| versions.tar | `-m5` | 4.489.907 / 4.556.285 (+1,5 %) | 3.749.055 / 3.879.126 (+3,5 %) | 4.548.932 / **3.789.882** (−16,7 %) | 4.548.932 / **3.879.126** (−14,7 %) | sí |
| pja.tar | `-m5` | 1.178.782 / 1.191.916 (+1,1 %) | 1.006.293 / 1.021.271 (+1,5 %) | 971.240 / 1.012.779 (+4,3 %) | 971.240 / 1.021.271 (+5,2 %) | sí |
| zpaqstd-history.tar | `-m5` | 5.461.215 / 5.516.459 (+1,0 %) | 5.863.907 / **4.603.534** (−21,5 %) | 8.457.000 / **6.393.248** (−24,4 %) | 8.457.000 / **4.603.534** (−45,6 %) | sí |
| src-zpaqstd | `-m1` | 11.191.182 / 11.226.058 (+0,3 %) | 10.346.266 / **9.819.016** (−5,1 %) | 13.000.404 / **12.708.901** (−2,2 %) | 13.000.404 / **9.819.016** (−24,5 %) | sí |
| src-omega | `-m1` | 3.303.645 / **3.169.248** (−4,1 %) | 3.915.262 / 4.482.542 (+14,5 %) | 5.190.126 / 5.337.872 (+2,8 %) | 5.190.126 / **4.482.542** (−13,6 %) | sí |
| bin-releases | `-m1` | 48.619.026 / **47.829.980** (−1,6 %) | 50.979.911 / **49.972.395** (−2,0 %) | 56.744.870 / **54.957.377** (−3,2 %) | 56.744.870 / **49.972.395** (−11,9 %) | sí |
| mixed | `-m1` | 89.607.208 / 89.728.474 (+0,1 %) | 86.539.771 / 86.582.306 (+0,0 %) | 86.342.652 / 86.539.943 (+0,2 %) | 86.342.652 / 86.582.306 (+0,3 %) | sí |
| disk | `-m1` | 255.158.963 / 255.759.306 (+0,2 %) | 246.148.799 / 249.118.252 (+1,2 %) | 263.568.325 / **258.594.356** (−1,9 %) | 263.568.325 / **249.118.252** (−5,5 %) | sí |
| insert | `-m1` | 194.589.102 / 194.937.094 (+0,2 %) | 191.260.784 / 191.391.339 (+0,1 %) | 206.340.416 / **205.181.163** (−0,6 %) | 206.340.416 / **191.391.339** (−7,2 %) | sí |
| db4k | `-m1` | 60.719.985 / **60.061.560** (−1,1 %) | 68.276.312 / **61.454.267** (−10,0 %) | 130.183.204 / **85.190.941** (−34,6 %) | 130.183.204 / **61.454.267** (−52,8 %) | sí |
| db8k | `-m1` | 59.298.170 / **58.952.206** (−0,6 %) | 62.064.051 / **58.966.115** (−5,0 %) | 103.592.168 / **72.910.694** (−29,6 %) | 103.592.168 / **58.966.115** (−43,1 %) | sí |
| db16k | `-m1` | 58.440.778 / 58.441.481 (+0,0 %) | 58.932.845 / **56.816.935** (−3,6 %) | 81.223.876 / **64.546.424** (−20,5 %) | 81.223.876 / **56.816.935** (−30,0 %) | sí |
| db8k | `-m5` | — | 27.097.423 / **25.366.372** (−6,4 %) | — | 43.377.207 / **25.366.372** (−41,5 %) | sí |
| photos | `-m1` | 100.499.687 / 100.742.329 (+0,2 %) | 98.214.736 / **98.043.349** (−0,2 %) | 97.870.612 / **97.667.353** (−0,2 %) | 97.870.612 / 98.043.349 (+0,2 %) | sí |
| photos | `-m3` | 93.662.680 / 93.812.905 (+0,2 %) | 91.146.734 / 91.173.632 (+0,0 %) | 90.820.501 / 90.824.126 (+0,0 %) | 90.820.501 / 91.173.632 (+0,4 %) | sí |
| src-zpaqstd | `-m5` | 7.589.258 / 7.692.838 (+1,4 %) | 6.101.510 / **5.858.076** (−4,0 %) | 7.438.882 / 7.473.612 (+0,5 %) | 7.438.882 / **5.858.076** (−21,3 %) | sí |
| src-omega | `-m5` | 2.354.354 / **2.315.970** (−1,6 %) | 2.860.713 / 2.884.328 (+0,8 %) | 3.482.867 / 3.871.416 (+11,2 %) | 3.482.867 / **2.884.328** (−17,2 %) | sí |
| bin-releases | `-m5` | 30.719.486 / **30.192.308** (−1,7 %) | 30.980.251 / **30.391.791** (−1,9 %) | 34.076.422 / **33.067.141** (−3,0 %) | 34.076.422 / **30.391.791** (−10,8 %) | sí |
| mixed | `-m5` | 74.840.998 / 74.952.551 (+0,1 %) | 71.819.132 / 71.884.278 (+0,1 %) | 71.571.832 / 71.612.432 (+0,1 %) | 71.571.832 / 71.884.278 (+0,4 %) | sí |

**El mejor N de cada uno** (lo que obtiene quien elige bien `-fragment`):

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

### Tiempo y memoria

`a`: suma de todas las versiones (s) y RSS pico (MB). "Última versión": el
`a` de la última versión sola, sobre el archivo con todas las anteriores
(lo que cuesta agregar una versión más a un archivo grande). `x`: extraer la
última versión con el zpaq-std sin parche (s y RSS pico; ahí pesa el índice).

| corpus | `-m` | N | zpaq a s / MB | osrep a s / MB | zpaq última versión s / MB | osrep última versión s / MB | zpaq x s / MB | osrep x s / MB |
|---|---|---|---|---|---|---|---|---|
| versions.tar | `-m1` | 0 | 0,96 / 336 | 1,09 / 327 | 0,96 / 336 | 1,09 / 327 | 0,47 / 68 | 0,53 / 77 |
| versions.tar | `-m1` | 3 | 0,84 / 390 | 0,97 / 307 | 0,84 / 390 | 0,97 / 307 | 0,32 / 98 | 0,32 / 77 |
| versions.tar | `-m1` | 6 | 1,13 / 466 | 0,88 / 407 | 1,13 / 466 | 0,88 / 407 | 0,33 / 140 | 0,33 / 101 |
| versions.tar | `-m1` | d | 1,09 / 463 | 0,93 / 308 | 1,09 / 463 | 0,93 / 308 | 0,32 / 140 | 0,35 / 77 |
| pja.tar | `-m1` | 0 | 0,44 / 213 | 0,49 / 185 | 0,44 / 213 | 0,49 / 185 | 0,16 / 31 | 0,15 / 27 |
| pja.tar | `-m1` | 3 | 0,43 / 200 | 0,41 / 199 | 0,43 / 200 | 0,41 / 199 | 0,17 / 36 | 0,15 / 30 |
| pja.tar | `-m1` | 6 | 0,49 / 239 | 0,47 / 200 | 0,49 / 239 | 0,47 / 200 | 0,17 / 43 | 0,19 / 37 |
| pja.tar | `-m1` | d | 0,56 / 239 | 0,42 / 200 | 0,56 / 239 | 0,42 / 200 | 0,17 / 42 | 0,17 / 30 |
| zpaqstd-history.tar | `-m1` | 0 | 1,20 / 428 | 1,22 / 341 | 1,20 / 428 | 1,22 / 341 | 0,76 / 114 | 0,81 / 90 |
| zpaqstd-history.tar | `-m1` | 3 | 1,25 / 494 | 1,25 / 416 | 1,25 / 494 | 1,25 / 416 | 0,50 / 141 | 0,46 / 118 |
| zpaqstd-history.tar | `-m1` | 6 | 1,70 / 533 | 1,34 / 513 | 1,70 / 533 | 1,34 / 513 | 0,64 / 140 | 0,50 / 137 |
| zpaqstd-history.tar | `-m1` | d | 1,63 / 534 | 1,20 / 390 | 1,63 / 534 | 1,20 / 390 | 0,69 / 139 | 0,48 / 110 |
| versions.tar | `-m5` | 0 | 105,80 / 1035 | 84,16 / 724 | 105,80 / 1035 | 84,16 / 724 | 94,31 / 868 | 80,89 / 546 |
| versions.tar | `-m5` | 3 | 136,90 / 1035 | 86,68 / 932 | 136,90 / 1035 | 86,68 / 932 | 137,17 / 897 | 97,20 / 793 |
| versions.tar | `-m5` | 6 | 167,48 / 1291 | 126,11 / 967 | 167,48 / 1291 | 126,11 / 967 | 168,45 / 1105 | 128,18 / 837 |
| versions.tar | `-m5` | d | 166,43 / 1291 | 82,35 / 938 | 166,43 / 1291 | 82,35 / 938 | 171,20 / 1108 | 85,64 / 798 |
| pja.tar | `-m5` | 0 | 22,25 / 453 | 18,26 / 364 | 22,25 / 453 | 18,26 / 364 | 23,20 / 309 | 18,39 / 211 |
| pja.tar | `-m5` | 3 | 35,49 / 445 | 23,29 / 439 | 35,49 / 445 | 23,29 / 439 | 35,35 / 316 | 22,78 / 308 |
| pja.tar | `-m5` | 6 | 54,77 / 651 | 34,79 / 423 | 54,77 / 651 | 34,79 / 423 | 57,40 / 521 | 32,88 / 292 |
| pja.tar | `-m5` | d | 54,66 / 651 | 24,99 / 438 | 54,66 / 651 | 24,99 / 438 | 54,83 / 522 | 24,52 / 308 |
| zpaqstd-history.tar | `-m5` | 0 | 148,28 / 1080 | 112,45 / 1071 | 148,28 / 1080 | 112,45 / 1071 | 136,66 / 905 | 110,86 / 887 |
| zpaqstd-history.tar | `-m5` | 3 | 170,99 / 1549 | 150,79 / 1060 | 170,99 / 1549 | 150,79 / 1060 | 175,08 / 1367 | 150,27 / 917 |
| zpaqstd-history.tar | `-m5` | 6 | 173,96 / 2380 | 173,49 / 1911 | 173,96 / 2380 | 173,49 / 1911 | 180,70 / 2160 | 170,75 / 1755 |
| zpaqstd-history.tar | `-m5` | d | 191,61 / 2384 | 167,64 / 1061 | 191,61 / 2384 | 167,64 / 1061 | 188,80 / 2152 | 164,40 / 917 |
| src-zpaqstd | `-m1` | 0 | 5,73 / 295 | 7,34 / 294 | 0,40 / 142 | 0,48 / 142 | 0,43 / 62 | 0,44 / 64 |
| src-zpaqstd | `-m1` | 3 | 5,41 / 263 | 6,85 / 263 | 0,34 / 131 | 0,43 / 132 | 0,35 / 51 | 0,37 / 49 |
| src-zpaqstd | `-m1` | 6 | 5,64 / 264 | 7,37 / 264 | 0,33 / 132 | 0,43 / 132 | 0,34 / 67 | 0,35 / 60 |
| src-zpaqstd | `-m1` | d | 5,64 / 264 | 6,81 / 264 | 0,33 / 132 | 0,42 / 131 | 0,34 / 67 | 0,34 / 56 |
| src-omega | `-m1` | 0 | 2,18 / 30 | 2,38 / 30 | 0,09 / 18 | 0,11 / 18 | 0,11 / 20 | 0,15 / 20 |
| src-omega | `-m1` | 3 | 2,21 / 30 | 2,48 / 30 | 0,10 / 17 | 0,10 / 17 | 0,10 / 20 | 0,12 / 20 |
| src-omega | `-m1` | 6 | 2,20 / 30 | 2,70 / 30 | 0,10 / 18 | 0,10 / 18 | 0,09 / 18 | 0,09 / 18 |
| src-omega | `-m1` | d | 2,20 / 30 | 2,47 / 30 | 0,10 / 18 | 0,11 / 18 | 0,09 / 18 | 0,11 / 20 |
| bin-releases | `-m1` | 0 | 8,03 / 207 | 9,37 / 208 | 0,30 / 61 | 0,46 / 61 | 0,28 / 56 | 0,25 / 48 |
| bin-releases | `-m1` | 3 | 7,27 / 200 | 8,49 / 200 | 0,28 / 54 | 0,37 / 55 | 0,15 / 35 | 0,15 / 37 |
| bin-releases | `-m1` | 6 | 7,62 / 201 | 8,83 / 201 | 0,33 / 56 | 0,32 / 57 | 0,14 / 26 | 0,12 / 27 |
| bin-releases | `-m1` | d | 7,62 / 201 | 7,96 / 200 | 0,33 / 56 | 0,33 / 57 | 0,14 / 26 | 0,15 / 37 |
| mixed | `-m1` | 0 | 2,31 / 489 | 2,80 / 482 | 2,31 / 489 | 2,80 / 482 | 1,09 / 162 | 1,09 / 159 |
| mixed | `-m1` | 3 | 1,98 / 441 | 2,64 / 435 | 1,98 / 441 | 2,64 / 435 | 1,02 / 139 | 0,92 / 137 |
| mixed | `-m1` | 6 | 2,14 / 439 | 2,35 / 440 | 2,14 / 439 | 2,35 / 440 | 0,89 / 136 | 0,89 / 136 |
| mixed | `-m1` | d | 2,14 / 439 | 2,41 / 438 | 2,14 / 439 | 2,41 / 438 | 0,89 / 136 | 1,00 / 137 |
| disk | `-m1` | 0 | 7,24 / 769 | 7,67 / 739 | 1,60 / 326 | 2,11 / 264 | 2,73 / 202 | 2,80 / 211 |
| disk | `-m1` | 3 | 6,66 / 597 | 7,51 / 612 | 1,40 / 175 | 2,07 / 227 | 2,41 / 144 | 2,39 / 149 |
| disk | `-m1` | 6 | 6,76 / 580 | 7,38 / 587 | 1,61 / 372 | 2,06 / 248 | 2,59 / 140 | 2,44 / 138 |
| disk | `-m1` | d | 6,76 / 580 | 8,09 / 612 | 1,61 / 372 | 2,71 / 226 | 2,59 / 140 | 2,42 / 148 |
| insert | `-m1` | 0 | 5,71 / 636 | 7,51 / 623 | 1,95 / 176 | 3,17 / 178 | 1,91 / 177 | 1,97 / 180 |
| insert | `-m1` | 3 | 4,95 / 602 | 6,60 / 606 | 1,78 / 217 | 2,89 / 217 | 1,89 / 143 | 1,80 / 142 |
| insert | `-m1` | 6 | 4,91 / 596 | 6,66 / 596 | 1,79 / 303 | 3,22 / 279 | 2,10 / 140 | 1,98 / 140 |
| insert | `-m1` | d | 4,91 / 596 | 6,61 / 606 | 1,79 / 303 | 2,94 / 214 | 2,10 / 140 | 1,89 / 142 |
| db4k | `-m1` | 0 | 4,04 / 603 | 4,73 / 612 | 0,71 / 218 | 0,91 / 208 | 0,90 / 170 | 0,83 / 168 |
| db4k | `-m1` | 3 | 4,95 / 558 | 4,69 / 570 | 0,98 / 214 | 0,98 / 210 | 0,92 / 141 | 0,83 / 142 |
| db4k | `-m1` | 6 | 5,37 / 548 | 5,53 / 548 | 1,17 / 476 | 1,14 / 294 | 1,49 / 153 | 1,09 / 141 |
| db4k | `-m1` | d | 5,37 / 548 | 4,89 / 569 | 1,17 / 476 | 0,99 / 210 | 1,49 / 153 | 0,84 / 143 |
| db8k | `-m1` | 0 | 4,05 / 603 | 4,53 / 613 | 0,69 / 201 | 0,81 / 207 | 0,84 / 152 | 0,84 / 170 |
| db8k | `-m1` | 3 | 4,27 / 558 | 4,24 / 560 | 0,79 / 206 | 0,75 / 172 | 0,78 / 142 | 0,75 / 142 |
| db8k | `-m1` | 6 | 5,09 / 547 | 5,46 / 550 | 1,10 / 383 | 1,14 / 228 | 1,30 / 141 | 0,93 / 140 |
| db8k | `-m1` | d | 5,09 / 547 | 4,45 / 559 | 1,10 / 383 | 0,77 / 172 | 1,30 / 141 | 0,76 / 142 |
| db16k | `-m1` | 0 | 3,91 / 603 | 4,53 / 605 | 0,63 / 199 | 0,79 / 197 | 0,80 / 153 | 0,78 / 169 |
| db16k | `-m1` | 3 | 3,76 / 558 | 4,11 / 560 | 0,61 / 172 | 0,71 / 168 | 0,73 / 142 | 0,73 / 141 |
| db16k | `-m1` | 6 | 5,09 / 549 | 4,88 / 546 | 1,11 / 291 | 1,05 / 207 | 0,99 / 141 | 0,84 / 141 |
| db16k | `-m1` | d | 5,09 / 549 | 4,16 / 559 | 1,11 / 291 | 0,76 / 168 | 0,99 / 141 | 0,75 / 142 |
| db8k | `-m5` | 3 | 283,00 / 1876 | 243,84 / 1878 | 29,21 / 424 | 17,00 / 330 | 186,04 / 2054 | 193,93 / 1846 |
| db8k | `-m5` | d | 580,72 / 1858 | 242,05 / 1881 | 126,48 / 962 | 17,53 / 330 | 263,51 / 3232 | 200,21 / 1853 |
| photos | `-m1` | 0 | 2,16 / 560 | 2,17 / 520 | 0,51 / 216 | 0,54 / 216 | 0,86 / 140 | 0,79 / 140 |
| photos | `-m1` | 3 | 1,36 / 502 | 1,81 / 489 | 0,31 / 143 | 0,33 / 143 | 0,79 / 131 | 0,74 / 122 |
| photos | `-m1` | 6 | 1,49 / 497 | 1,85 / 499 | 0,34 / 144 | 0,35 / 144 | 0,70 / 132 | 0,70 / 127 |
| photos | `-m1` | d | 1,49 / 497 | 1,79 / 440 | 0,34 / 144 | 0,34 / 143 | 0,70 / 132 | 0,74 / 130 |
| photos | `-m3` | 0 | 46,11 / 860 | 45,81 / 861 | 4,06 / 226 | 4,29 / 227 | 23,23 / 285 | 22,75 / 290 |
| photos | `-m3` | 3 | 39,49 / 855 | 44,57 / 849 | 4,12 / 217 | 4,17 / 217 | 23,58 / 278 | 22,96 / 278 |
| photos | `-m3` | 6 | 40,56 / 856 | 40,17 / 857 | 4,14 / 219 | 4,19 / 217 | 22,87 / 282 | 23,26 / 278 |
| photos | `-m3` | d | 40,56 / 856 | 42,76 / 853 | 4,14 / 219 | 4,00 / 219 | 22,87 / 282 | 22,51 / 282 |
| src-zpaqstd | `-m5` | 0 | 85,31 / 672 | 84,57 / 674 | 0,59 / 239 | 0,65 / 240 | 68,06 / 763 | 67,10 / 763 |
| src-zpaqstd | `-m5` | 3 | 96,32 / 664 | 102,93 / 664 | 0,78 / 229 | 0,79 / 229 | 69,75 / 773 | 70,22 / 769 |
| src-zpaqstd | `-m5` | 6 | 126,96 / 668 | 136,12 / 667 | 1,06 / 230 | 1,91 / 231 | 71,98 / 925 | 74,25 / 864 |
| src-zpaqstd | `-m5` | d | 126,96 / 668 | 93,47 / 664 | 1,06 / 230 | 0,81 / 230 | 71,98 / 925 | 70,90 / 767 |
| src-omega | `-m5` | 0 | 20,46 / 144 | 20,47 / 144 | 0,71 / 100 | 0,71 / 100 | 8,51 / 392 | 8,60 / 307 |
| src-omega | `-m5` | 3 | 28,08 / 144 | 30,33 / 143 | 1,53 / 99 | 1,52 / 99 | 7,93 / 309 | 9,82 / 306 |
| src-omega | `-m5` | 6 | 36,33 / 145 | 39,48 / 144 | 2,26 / 101 | 2,52 / 99 | 8,27 / 226 | 8,10 / 229 |
| src-omega | `-m5` | d | 36,33 / 145 | 28,81 / 144 | 2,26 / 101 | 1,41 / 99 | 8,27 / 226 | 8,02 / 307 |
| bin-releases | `-m5` | 0 | 288,91 / 422 | 284,99 / 423 | 15,61 / 195 | 15,64 / 196 | 29,83 / 587 | 27,24 / 601 |
| bin-releases | `-m5` | 3 | 333,60 / 416 | 329,51 / 416 | 16,60 / 193 | 16,58 / 193 | 16,10 / 604 | 16,52 / 426 |
| bin-releases | `-m5` | 6 | 389,26 / 417 | 377,27 / 417 | 17,37 / 195 | 17,00 / 195 | 18,19 / 352 | 17,32 / 352 |
| bin-releases | `-m5` | d | 389,26 / 417 | 323,89 / 416 | 17,37 / 195 | 17,40 / 193 | 18,19 / 352 | 15,81 / 435 |
| mixed | `-m5` | 0 | 215,19 / 2143 | 215,41 / 2137 | 215,19 / 2143 | 215,41 / 2137 | 222,87 / 2027 | 212,25 / 2032 |
| mixed | `-m5` | 3 | 225,39 / 2468 | 226,49 / 2449 | 225,39 / 2468 | 226,49 / 2449 | 223,44 / 2366 | 220,21 / 2354 |
| mixed | `-m5` | 6 | 215,66 / 2473 | 217,10 / 2478 | 215,66 / 2473 | 217,10 / 2478 | 223,88 / 2372 | 214,92 / 2375 |
| mixed | `-m5` | d | 215,66 / 2473 | 210,42 / 2458 | 215,66 / 2473 | 210,42 / 2458 | 223,88 / 2372 | 213,01 / 2373 |

### Sin compresor: cuánto deduplica cada fragmentador

`frag_stats` corta cada archivo como zpaq-std, deduplica por SHA-1 y da los
bytes únicos y el fragmento medio. **"Mismo N" no es el mismo promedio**: el
gear de `-osrep` corta en cuanto ve 64 ceros (`G[0] = 0`) y después de cada
cabecera tar, así que en datos con relleno de ceros o tars su fragmento medio
es menor que 2^N KiB, y a N=6 es la mitad o menos que el de zpaq:

| entrada | N=3 zpaq / `-osrep` | N=6 zpaq / `-osrep` |
|---|---:|---:|
| versions.tar | 9,0 / 6,5 KiB | 71,8 / 22,8 KiB |
| disk (v1+v2) | 8,9 / 6,7 KiB | 70,7 / 32,7 KiB |
| insert (v1+v2) | 8,0 / 7,4 KiB | 46,3 / 39,0 KiB |
| db4k (4 versiones) | 8,5 / 5,9 KiB | 71,2 / 34,3 KiB |
| db8k | 8,4 / 7,2 KiB | 72,4 / 37,2 KiB |
| db16k | 8,5 / 7,6 KiB | 69,8 / 41,3 KiB |

En `disk`, lo que cuesta v2 (350 cambios sueltos) en bytes únicos y en el
archivo `-m1`:

| N | únicos v2 − v1, zpaq | únicos, `-osrep` | archivo `-m1` v2 − v1, zpaq | archivo, `-osrep` |
|---|---:|---:|---:|---:|
| 0 | 1.669.321 | 1.338.856 (−19,8 %) | 2.798.233 | 2.761.850 (−1,3 %) |
| 3 | 6.569.274 | 13.987.098 (+112,9 %) | 3.844.783 | 6.522.266 (+69,6 %) |
| 6 | 44.569.598 | 34.033.764 (−23,6 %) | 21.776.533 | 16.374.947 (−24,8 %) |

**El mínimo.** `frag_stats gearS N 42` es el gear de `-osrep` con sus cortes
de formato pero con mínimo A >> S (`gear1` es `-osrep`, mínimo A/2; zpaq-std
usa `64 << N` = A/16). Bytes únicos + índice estimado (24 B por fragmento
único + 4 B por referencia), diferencia contra zpaq al mismo N; en negrita el
mejor mínimo:

| entrada | N | zpaq (únicos + índice) | `-osrep` (A/2) | A/4 | A/8 | A/16 |
|---|---|---:|---:|---:|---:|---:|
| disk | 0 | 497.629.022 | −0,7 % | −1,0 % | **−1,2 %** | −0,8 % |
| disk | 3 | 506.275.348 | +0,9 % | +0,1 % | −0,1 % | **−2,1 %** |
| disk | 6 | 554.056.973 | −2,9 % | **−4,4 %** | −2,8 % | −3,0 % |
| insert | 0 | 302.664.223 | −0,2 % | −0,5 % | **−0,7 %** | −0,6 % |
| insert | 3 | 315.961.615 | +0,0 % | −0,5 % | −0,9 % | **−1,2 %** |
| insert | 6 | 355.585.417 | +0,0 % | −0,8 % | −2,0 % | **−2,9 %** |
| db4k | 0 | 152.679.983 | −1,6 % | −1,5 % | −1,6 % | **−1,7 %** |
| db4k | 3 | 183.231.300 | −11,2 % | −12,7 % | **−12,9 %** | −12,8 % |
| db4k | 6 | 350.049.950 | −34,4 % | −44,5 % | −49,6 % | **−51,7 %** |
| db8k | 0 | 148.257.732 | **−0,9 %** | −0,7 % | −0,8 % | −0,8 % |
| db8k | 3 | 163.954.117 | −5,5 % | **−5,8 %** | −5,8 % | −5,6 % |
| db8k | 6 | 277.720.183 | −30,1 % | −36,7 % | −39,6 % | **−40,2 %** |
| versions.tar | 0 | 36.920.148 | −10,9 % | −12,0 % | −15,6 % | **−15,6 %** |
| versions.tar | 3 | 53.389.685 | −31,0 % | −33,4 % | **−34,1 %** | −30,5 % |
| versions.tar | 6 | 75.492.086 | −25,0 % | −34,6 % | −39,8 % | **−42,7 %** |
| zpaqstd-history.tar | 0 | 54.359.988 | −18,0 % | −19,4 % | −19,4 % | **−23,2 %** |
| zpaqstd-history.tar | 3 | 96.472.501 | −38,1 % | −40,9 % | **−41,6 %** | −37,6 % |
| zpaqstd-history.tar | 6 | 153.323.279 | −26,4 % | −36,6 % | −43,0 % | **−46,1 %** |
| src-zpaqstd | 0 | 32.245.598 | **−0,9 %** | −0,7 % | −0,3 % | −0,1 % |
| src-zpaqstd | 3 | 34.932.947 | **−4,7 %** | −2,9 % | −1,8 % | −1,5 % |
| src-zpaqstd | 6 | 46.348.235 | **−1,2 %** | +1,3 % | +5,9 % | +4,0 % |
| src-omega | 0 | 6.342.960 | **−6,5 %** | −4,8 % | −3,6 % | −2,4 % |
| src-omega | 3 | 9.124.008 | +0,9 % | **+0,5 %** | +1,2 % | +2,3 % |
| src-omega | 6 | 12.024.653 | +9,2 % | +8,0 % | +5,9 % | **+4,7 %** |

### Velocidad del corte

`frag_speed` (solo el corte, con `hits` y `o1`; sin SHA-1 ni E/S; mediana de
3, MB/s): zpaq 293–319, `-osrep` 166–172 en `versions.tar` y en la imagen
`disk` v1, con N=3 y N=6. `push` y `scan` dan lo mismo en `-osrep` porque los
cortes de formato obligan a empujar byte a byte. Con SHA-1 (`frag_stats`,
mediana de 3): `versions.tar` 1,25 s zpaq N=3 contra 1,59 s `-osrep` N=3
(+27 %); `disk` v1 5,15 s contra 6,52 s (+27 %). En `a -m1` completo eso es
+10 a +35 % de tiempo (tabla de arriba); con `-m5` `-osrep` suele tardar menos
porque comprime menos datos.

### Lectura

- **Default contra default** (quien solo agrega `-osrep`): gana donde hay
  redundancia entre versiones: −12 a −64 % con `-m1` en los seis corpus con
  versiones y −11 a −46 % con `-m5` en cinco de ellos; −5,5 % en `disk`,
  −7,2 % en `insert` y −30 a −53 % en las bases de datos (`db8k -m5`:
  −41,5 %). Pierde en PJA con `-m5` (+5,2 %) y por
  poco en datos sin redundancia (mixed, photos: +0,2 a +0,4 %).
- **Al mismo N**: de 64 celdas, `-osrep` gana 34, empata 7 (±0,1 %) y
  pierde 23. Las derrotas grandes son PJA con `-m5` (+1,1 a +4,3 %),
  `versions.tar -m5` en N=0/3 (+1,5/+3,5 %), `src-omega` en N=3/6 (`-m1`
  +14,5/+2,8 %, `-m5` +0,8/+11,2 %) y `disk` N=3 (+1,2 %); el resto son
  +0,1 a +0,8 % en N=0 o en datos sin redundancia.
- **Cada uno con su mejor N**: `-osrep` gana en 15 de 22 casos (−0,2 a
  −15,7 %); pierde en PJA `-m5` (+4,3 %), `disk` (+1,2 %),
  `versions.tar -m5` (+1,1 %), mixed `-m1`/`-m5` (+0,2/+0,1 %) e `insert`
  (+0,1 %), y empata en photos `-m3`. (`db8k -m5` compara solo N=3 y 6 de zpaq
  con N=3 de `-osrep`.)
- **2.11.0 no cambia nada respecto de 2.7.2**: en los tars los tamaños son los
  de la tabla de 2.7.2 a menos de 10 bytes. En las carpetas, los números
  cambian con la ruta de trabajo (ver la nota de `src-omega` en la tabla de
  2.7.2): `src-omega -m1` N=3 pasó de +6,5 % a +14,5 % solo por eso.
- **`disk`**, el punto débil que zpaq-std nombra, **no lo gana `-osrep` en
  N=3**: v2 (350 cambios sueltos) cuesta 6,5 MB en el archivo con `-osrep`
  contra 3,8 MB con zpaq N=3 (+70 %), y 14,0 contra 6,6 MB de bytes únicos.
  Con N=0 empatan y con N=6 gana `-osrep` (v2 cuesta un 25 % menos), pero
  porque su fragmento medio es la mitad del de zpaq. La causa es el **mínimo A/2**:
  después de un cambio, el gear tiene un candidato de corte cada ~A/2 bytes y
  no puede cortar antes de A/2, así que la cadena de cortes de v2 tarda
  varios fragmentos en volver a caer en los de v1. zpaq en N=3 tiene mínimo
  512 B (A/16) y se reengancha enseguida. Con los cortes de formato y mínimo
  A/16, `frag_stats` da −2,1 % contra zpaq (hoy +0,9 %).
- **Bases de datos**: gana mucho (N=6: −20 a −35 %) porque el gear corta en
  el relleno de ceros al final de cada página (`G[0] = 0`): los fragmentos
  quedan alineados a página y las páginas movidas se deduplican. Con páginas
  llenas, sin ceros, esa ventaja no existiría (no se midió).
- **`insert`** (un byte al principio de cada archivo): empate en N=3
  (+0,1 %). Los dos pierden el primer fragmento de cada archivo; `-osrep` solo
  gana por usar fragmentos más chicos en el default.
- **`-m5` con todo el tar en un bloque** (PJA, `versions.tar`): ahí `-osrep`
  deduplica bastante más (PJA N=6: 13,9 MB únicos contra 21,4 MB de zpaq) y aun
  así el archivo sale más grande, porque el modelo de `-m5` ya encontraba esa
  redundancia dentro del bloque. Lo que queda es el costo de tener 3× más
  fragmentos: índice (≈25 KB de los 41 KB que pierde PJA N=6) y contexto
  cortado para el compresor.
- **Memoria**: al mismo N, el RSS de `x` es igual o menor con `-osrep`
  salvo en algunas filas N=0 (hasta +13 %); default contra default sube en
  `bin-releases` y `src-omega` con `-m5` (+24 % y +36 %, más fragmentos), y
  es mucho menor donde zpaq usa
  fragmentos grandes con `-m5` (historial default: 917 MB contra 2.152 MB;
  `db8k` default: 1.853 MB contra 3.232 MB). Agregar una versión más al archivo de 16
  versiones de `src-zpaqstd` cuesta lo mismo (229–240 MB los dos). La
  excepción es `disk` N=3: 227 MB contra 175 MB (+30 %), por los 33 % más de
  fragmentos. El RSS varía un ~5 % entre corridas.
- **Tiempo**: con `-m1`, `a` tarda típicamente un 15–35 % más en carpetas
  (corte 1,8× más lento; en algunos tars y bases de datos tarda menos); con
  `-m5`, `-osrep` tarda lo mismo o menos (comprime menos datos): historial
  default 168 s contra 192 s, PJA 25 s contra 55 s.

Un mínimo más chico gana en `disk`, `insert`, las bases de datos y los tars,
y pierde en `src-zpaqstd`. Parte de la ganancia es que corta más fino (en
`disk` N=3 el fragmento medio baja de 6,9 a 3,2 KiB): hay que confirmarlo con
archivos reales y `-m5` antes de cambiar `osrep_frag_params_osrep()`.

Datos crudos: `tools/zpaq-vectors/bench-2110-tars.tsv` (`bench_fair.py`),
`bench-2110-dirs.tsv` (`bench_versions.py`), `bench-2110-fragstats.tsv`
(`frag_stats`: los corpus nuevos, la velocidad y el barrido del mínimo) y
`bench-2110-fragspeed.tsv` (`frag_speed`).

```sh
T=tools/zpaq-vectors
python3 $T/make_weakspots.py --out SYN --disk-src DIR ... --tree-src DIR ... \
  --new-data game-assets.tar --text enwik8 --db-pages 4,8,16
python3 $T/bench_fair.py --baseline BASE --patched NEW --input versions.tar \
  --input pja.tar --input zpaqstd-history.tar --method=-m1 --fragments 0,3,6,d \
  --workdir W --extra=-threads --extra=4 --xextra=-threads --xextra=4
python3 $T/bench_versions.py --baseline BASE --patched NEW --workdir W \
  --method=-m1 --configs zpaq:0,osrep:0,zpaq:3,osrep:3,zpaq:6,osrep:6,osrep:d \
  --corpus disk=SYN/disk --corpus mixed=DIR:single \
  --extra=-threads --extra=4 --xextra=-threads --xextra=4
```

## Tabla final: zpaq contra `-osrep` al mismo N (2026-11-12)

Cada celda: zpaq-std baseline con `-fragment N` / zpaq-std parcheado con
`-osrep -fragment N`, los dos con promedio nominal 2^N KiB, y la diferencia de
`-osrep`. La última columna compara los defaults: zpaq sin `-fragment` (N=6)
contra `-osrep` sin `-fragment` (N=3). En negrita, cuando `-osrep` gana.

- Binarios: baseline zpaq-std 2.7.2 (`b8ad717`) sin cambios; parcheado = el
  parche de arriba (`zs-int`, commit `71e2690`).
- Los tar con `tools/zpaq-vectors/bench_fair.py` (`-touch`/`-timestamp`
  fijos); las carpetas con `tools/zpaq-vectors/bench_versions.py`: cada
  versión se copia sobre la misma carpeta y se agrega al mismo archivo, como
  un backup que cambia (`src-omega` 40 versiones, `bin-releases` 39,
  `photos` 2, `mixed` 1).
- Todo con `-threads 4`, un zpaq-std a la vez, en un cgroup de 6 GB, con la
  máquina compartida y cargada. Una corrida por celda: los tamaños son
  exactos; los tiempos, indicativos.
- **El baseline extrae los 84 archivos idénticos a la entrada** (la última
  versión, en las carpetas).
- La columna default se midió sin `-fragment` en los tars y en las carpetas
  con `-m1`; en el resto es la fila N=6 de zpaq y la N=3 de `-osrep`, que
  dan el mismo archivo (lo comprueba `osrep-switch-test.sh`).
- Sumando los seis corpus: `-m1` −0,4 % / −1,2 % / −2,7 % en N=0/3/6 y
  −6,0 % default contra default; `-m5` (sin photos) −0,3 % / −0,4 % / −1,3 %
  y −3,9 %. La suma la dominan los corpus grandes sin redundancia.

```sh
T=tools/zpaq-vectors
python3 $T/bench_fair.py --baseline BASE --patched PATCHED \
  --input versions.tar --input pja.tar --method=-m1 --method=-m5 \
  --fragments 0,3,6,d --workdir W --extra=-threads --extra=4
python3 $T/bench_versions.py --baseline BASE --patched PATCHED --workdir W \
  --method=-m1 --configs zpaq:0,osrep:0,zpaq:3,osrep:3,zpaq:6,osrep:6,osrep:d \
  --corpus src-omega=DIR --corpus mixed=DIR:single --extra=-threads --extra=4
```

Tamaño del archivo en bytes, índice incluido:

| corpus | `-m` | N=0 (1 KiB) zpaq / osrep | N=3 (8 KiB) | N=6 (64 KiB) | default: zpaq N=6 / osrep N=3 |
|---|---|---|---|---|---|
| versions.tar | `-m1` | 8.460.664 / **8.008.231** (-5,3 %) | 9.835.635 / **7.787.367** (-20,8 %) | 15.293.575 / **10.732.272** (-29,8 %) | 15.293.575 / 7.787.367 (-49,1 %) |
| versions.tar | `-m5` | 4.489.893 / 4.556.282 (+1,5 %) | 3.749.060 / 3.879.120 (+3,5 %) | 4.548.941 / **3.789.889** (-16,7 %) | 4.548.941 / 3.879.120 (-14,7 %) |
| pja.tar | `-m1` | 1.942.765 / 1.957.736 (+0,8 %) | 1.767.855 / 1.777.501 (+0,5 %) | 2.817.689 / **1.756.729** (-37,7 %) | 2.817.689 / 1.777.501 (-36,9 %) |
| pja.tar | `-m5` | 1.178.787 / 1.191.920 (+1,1 %) | 1.006.299 / 1.021.279 (+1,5 %) | 971.248 / 1.012.787 (+4,3 %) | 971.248 / 1.021.279 (+5,2 %) |
| src-omega | `-m1` | 3.247.436 / **3.098.668** (-4,6 %) | 3.913.943 / 4.167.167 (+6,5 %) | 5.027.941 / 5.342.757 (+6,3 %) | 5.027.941 / 4.167.167 (-17,1 %) |
| src-omega | `-m5` | 2.358.300 / **2.286.392** (-3,0 %) | 2.847.682 / 2.887.390 (+1,4 %) | 3.402.723 / 3.654.920 (+7,4 %) | 3.402.723 / 2.887.390 (-15,1 %) |
| bin-releases | `-m1` | 48.620.223 / **47.831.045** (-1,6 %) | 50.980.820 / **49.898.680** (-2,1 %) | 56.745.707 / **54.958.138** (-3,2 %) | 56.745.707 / 49.898.680 (-12,1 %) |
| bin-releases | `-m5` | 30.720.686 / **30.252.164** (-1,5 %) | 31.031.847 / **30.392.607** (-2,1 %) | 34.077.230 / **33.067.937** (-3,0 %) | 34.077.230 / 30.392.607 (-10,8 %) |
| mixed | `-m1` | 89.612.611 / 89.744.682 (+0,1 %) | 86.540.905 / 86.581.380 (+0,0 %) | 86.343.654 / 86.545.850 (+0,2 %) | 86.343.654 / 86.581.380 (+0,3 %) |
| mixed | `-m5` | 74.846.481 / 74.968.295 (+0,2 %) | 71.820.193 / 71.890.586 (+0,1 %) | 71.572.910 / 71.618.657 (+0,1 %) | 71.572.910 / 71.890.586 (+0,4 %) |
| photos | `-m1` | 100.499.962 / 100.742.613 (+0,2 %) | 98.214.843 / **98.043.460** (-0,2 %) | 97.870.761 / **97.667.494** (-0,2 %) | 97.870.761 / 98.043.460 (+0,2 %) |
| photos | `-m3` | 93.662.955 / 93.813.189 (+0,2 %) | 91.146.840 / 91.173.743 (+0,0 %) | 90.820.649 / 90.824.267 (+0,0 %) | 90.820.649 / 91.173.743 (+0,4 %) |

Datos crudos: `tools/zpaq-vectors/bench-int-tars.tsv`,
`bench-int-dirs.tsv` y `bench-int-speed.tsv`.

Tiempo de `a` (s, suma de todas las versiones; una corrida) y RSS pico (MB);
N=d es sin `-fragment`:

| corpus | `-m` | N | zpaq s / MB | osrep s / MB |
|---|---|---|---|---|
| versions.tar | `-m1` | 0 | 1,14 / 343 | 1,27 / 347 |
| versions.tar | `-m1` | 3 | 0,97 / 394 | 1,11 / 324 |
| versions.tar | `-m1` | 6 | 1,37 / 478 | 1,05 / 424 |
| versions.tar | `-m1` | d | 1,26 / 478 | 1,18 / 315 |
| versions.tar | `-m5` | 0 | 111,09 / 1030 | 96,54 / 716 |
| versions.tar | `-m5` | 3 | 161,91 / 1031 | 95,83 / 932 |
| versions.tar | `-m5` | 6 | 199,60 / 1291 | 149,53 / 966 |
| versions.tar | `-m5` | d | 198,64 / 1290 | 93,86 / 934 |
| pja.tar | `-m1` | 0 | 0,61 / 229 | 0,56 / 198 |
| pja.tar | `-m1` | 3 | 0,63 / 218 | 0,56 / 216 |
| pja.tar | `-m1` | 6 | 0,68 / 255 | 0,72 / 217 |
| pja.tar | `-m1` | d | 0,65 / 255 | 0,57 / 215 |
| pja.tar | `-m5` | 0 | 26,52 / 454 | 21,87 / 362 |
| pja.tar | `-m5` | 3 | 41,89 / 446 | 28,38 / 438 |
| pja.tar | `-m5` | 6 | 61,98 / 651 | 38,46 / 421 |
| pja.tar | `-m5` | d | 66,51 / 651 | 25,81 / 439 |
| src-omega | `-m1` | 0 | 2,35 / 29 | 2,75 / 29 |
| src-omega | `-m1` | 3 | 2,28 / 29 | 2,62 / 28 |
| src-omega | `-m1` | 6 | 2,53 / 29 | 2,74 / 28 |
| src-omega | `-m5` | 0 | 22,23 / 144 | 23,85 / 144 |
| src-omega | `-m5` | 3 | 31,03 / 144 | 31,14 / 144 |
| src-omega | `-m5` | 6 | 38,74 / 144 | 42,57 / 143 |
| bin-releases | `-m1` | 0 | 9,37 / 223 | 10,45 / 224 |
| bin-releases | `-m1` | 3 | 9,27 / 216 | 10,23 / 216 |
| bin-releases | `-m1` | 6 | 9,33 / 218 | 10,44 / 217 |
| bin-releases | `-m5` | 0 | 324,83 / 422 | 314,06 / 424 |
| bin-releases | `-m5` | 3 | 376,66 / 416 | 344,32 / 416 |
| bin-releases | `-m5` | 6 | 429,67 / 417 | 414,88 / 417 |
| mixed | `-m1` | 0 | 2,58 / 479 | 3,17 / 469 |
| mixed | `-m1` | 3 | 2,33 / 425 | 2,82 / 435 |
| mixed | `-m1` | 6 | 2,39 / 426 | 2,67 / 425 |
| mixed | `-m5` | 0 | 238,79 / 2144 | 230,27 / 2145 |
| mixed | `-m5` | 3 | 242,12 / 2462 | 246,32 / 2453 |
| mixed | `-m5` | 6 | 234,46 / 2472 | 237,61 / 2480 |
| photos | `-m1` | 0 | 2,57 / 524 | 2,53 / 524 |
| photos | `-m1` | 3 | 1,84 / 500 | 2,27 / 443 |
| photos | `-m1` | 6 | 1,77 / 505 | 2,10 / 500 |
| photos | `-m3` | 0 | 51,05 / 866 | 59,60 / 864 |
| photos | `-m3` | 3 | 49,45 / 851 | 51,01 / 853 |
| photos | `-m3` | 6 | 50,16 / 855 | 49,96 / 855 |

**Lectura.**

- **Contra el default de zpaq** (lo que obtiene quien solo agrega `-osrep`):
  con redundancia entre versiones, `-osrep` sale más chico en los dos
  métodos: versions.tar −49 % (`-m1`) y −15 % (`-m5`), src-omega −17 % y
  −15 %, bin-releases −12 % y −11 %, PJA −37 % con `-m1`. Pierde en PJA con
  `-m5` (+5,2 %) y, por poco, en datos sin redundancia (mixed, photos:
  +0,2 a +0,4 %), donde los fragmentos de 64 KiB de zpaq cuestan menos índice.
- **Al mismo N** (mismo promedio nominal):
  - `-m1`: gana en los tars (versions.tar −5 % / −21 % / −30 % en N=0/3/6;
    PJA −38 % en N=6) y en bin-releases (−1,6 a −3,2 %); empata en mixed y
    photos (±0,2 %). PJA en N=0 y N=3 pierde 0,5–0,8 %.
  - `-m5`: gana en bin-releases (−1,5 a −3,0 %) y en versions.tar N=6
    (−16,7 %); pierde 1,1–3,5 % en los tars con N=0 y N=3 y 4,3 % en PJA N=6.
  - **src-omega** (árbol de fuentes, archivos chicos) pierde en N=3 y N=6
    (+6,5 % y +6,3 % con `-m1`; +1,4 % y +7,4 % con `-m5`) y gana en N=0
    (−4,6 % y −3,0 %). La causa es el mínimo A/2: con N=6 casi todos sus
    archivos son un solo fragmento. Además, en este corpus el tamaño se mueve
    con la ruta de la carpeta que se agrega: con cinco rutas distintas,
    `-osrep -m1 N=3` dio de 4,17 a 4,49 MB y zpaq de 3,908 a 3,919 MB
    (+6,6 % a +14,9 %); en bin-releases la ruta mueve 0,15 % y en mixed y
    photos nada. Por eso las comparaciones son dentro de una misma corrida.
- **Qué aporta cada pieza**, con los archivos del experimento 2 (gear sin
  reglas, mismo zpaq-std):
  - Cortes de formato en versions.tar N=3: `-m1` 8.656.074 → 7.787.367
    (−10,0 %), `-m5` 3.779.936 → 3.879.120 (+2,6 %). En PJA N=3: `-m1`
    1.772.982 → 1.777.501 (+0,3 %), `-m5` 1.012.390 → 1.021.279 (+0,9 %).
    Con `-m5` la regla tar cuesta: más fragmentos (más índice) y una
    deduplicación que el compresor ya hacía. En zips la ganancia no depende
    del método (el experimento 3 midió −68 % con `-m1`; los datos deflate no
    se recomprimen).
- **Tiempo y memoria**: con `-m5`, `-osrep` tarda menos en los tars (1,4–2,1×:
  versions.tar N=3 96 s contra 162 s; default 94 s contra 199 s) porque
  deduplica más antes de comprimir, e igual en las carpetas. Con `-m1` es un
  10–15 % más lento en carpetas (ver abajo). El RSS es igual o menor (default
  versions.tar `-m5`: 934 MB contra 1.290 MB).

## Análisis sin zpaq (`frag_stats`)

`tools/zpaq-vectors/frag_stats` corta cada archivo de la lista como lo haría
zpaq-std, deduplica por SHA-1 y estima lo que se guarda: bytes únicos + 24 B
por fragmento único + 4 B por referencia (el índice). Entre paréntesis, el
fragmento medio de zpaq y la diferencia contra zpaq. `omega-tar`, `omega-zip`
y `omega-zip0` son las 40 versiones de `src-omega` empaquetadas en tar, zip
deflate y zip stored (del experimento 3). Datos:
`tools/zpaq-vectors/frag-stats-int.tsv`.

| entrada | N | zpaq (fragmento medio) | gear sin reglas | `-osrep` (gear + 42) | 42 vs gear |
|---|---|---:|---:|---:|---:|
| versions.tar | 0 | 36.920.148 (1.088) | 32.884.955 (-10,9 %) | 32.884.876 (-10,9 %) | -0,0 % |
| versions.tar | 3 | 53.389.685 (9.249) | 45.993.065 (-13,9 %) | 36.820.980 (-31,0 %) | -19,9 % |
| versions.tar | 6 | 75.492.086 (73.520) | 72.734.319 (-3,7 %) | 56.614.772 (-25,0 %) | -22,2 % |
| pja.tar | 0 | 8.753.087 (1.072) | 7.641.422 (-12,7 %) | 7.640.414 (-12,7 %) | -0,0 % |
| pja.tar | 3 | 13.505.880 (8.744) | 11.420.034 (-15,4 %) | 8.954.092 (-33,7 %) | -21,6 % |
| pja.tar | 6 | 21.445.740 (66.774) | 18.863.510 (-12,0 %) | 13.917.352 (-35,1 %) | -26,2 % |
| omega-tar | 0 | 15.961.660 (1.014) | 10.336.776 (-35,2 %) | 10.336.550 (-35,2 %) | -0,0 % |
| omega-tar | 3 | 34.301.314 (7.782) | 29.928.693 (-12,7 %) | 18.471.370 (-46,1 %) | -38,3 % |
| omega-tar | 6 | 49.109.085 (62.716) | 49.343.817 (+0,5 %) | 42.800.702 (-12,8 %) | -13,3 % |
| omega-zip | 0 | 9.689.102 (1.033) | 9.026.447 (-6,8 %) | 5.582.557 (-42,4 %) | -38,2 % |
| omega-zip | 3 | 14.379.533 (8.003) | 14.647.663 (+1,9 %) | 5.631.145 (-60,8 %) | -61,6 % |
| omega-zip | 6 | 16.234.162 (50.513) | 16.197.107 (-0,2 %) | 5.689.016 (-65,0 %) | -64,9 % |
| omega-zip0 | 0 | 13.522.197 (1.079) | 11.229.032 (-17,0 %) | 6.880.900 (-49,1 %) | -38,7 % |
| omega-zip0 | 3 | 30.906.200 (7.690) | 29.277.549 (-5,3 %) | 10.110.274 (-67,3 %) | -65,5 % |
| omega-zip0 | 6 | 45.497.294 (63.376) | 45.652.262 (+0,3 %) | 14.048.507 (-69,1 %) | -69,2 % |
| src-omega | 0 | 6.355.324 (975) | 5.942.469 (-6,5 %) | 5.942.469 (-6,5 %) | +0,0 % |
| src-omega | 3 | 9.126.616 (4.495) | 9.209.473 (+0,9 %) | 9.209.473 (+0,9 %) | +0,0 % |
| src-omega | 6 | 12.025.937 (9.151) | 13.133.585 (+9,2 %) | 13.133.585 (+9,2 %) | +0,0 % |
| bin-releases | 0 | 111.029.633 (1.045) | 108.684.694 (-2,1 %) | 108.704.625 (-2,1 %) | +0,0 % |
| bin-releases | 3 | 125.816.529 (9.147) | 121.958.328 (-3,1 %) | 121.959.836 (-3,1 %) | +0,0 % |
| bin-releases | 6 | 147.683.798 (75.576) | 142.309.313 (-3,6 %) | 142.309.640 (-3,6 %) | +0,0 % |
| mixed | 0 | 163.338.443 (963) | 162.722.599 (-0,4 %) | 162.730.791 (-0,4 %) | +0,0 % |
| mixed | 3 | 168.564.842 (7.972) | 168.210.978 (-0,2 %) | 168.349.195 (-0,1 %) | +0,1 % |
| mixed | 6 | 171.855.217 (46.894) | 172.419.111 (+0,3 %) | 172.289.232 (+0,3 %) | -0,1 % |
| photos | 0 | 109.184.264 (1.048) | 109.382.985 (+0,2 %) | 109.388.273 (+0,2 %) | +0,0 % |
| photos | 3 | 107.001.981 (8.665) | 106.860.839 (-0,1 %) | 106.861.631 (-0,1 %) | +0,0 % |
| photos | 6 | 107.395.753 (66.316) | 107.194.186 (-0,2 %) | 107.194.346 (-0,2 %) | +0,0 % |

- Los cortes de formato no cambian nada donde no hay tar ni zip (±0,1 %).
- En N=0 la regla tar no aporta: con mínimo 512 B el gear ya corta en el
  relleno de ceros de cada miembro (`G[0] = 0`).
- `src-omega` pierde en N=6 (+9 %): casi todos sus archivos miden menos que
  el mínimo de 32 KiB, así que cada archivo cambiado es un fragmento entero;
  zpaq, con mínimo 4 KiB, todavía lo corta.

## Velocidad del corte

Corte + SHA-1 en un hilo, sin zpaq (`frag_stats`, mediana de 3, s):

| entrada | zpaq N=3 | gear N=3 sin reglas | `-osrep` N=3 | zpaq N=6 | `-osrep` N=6 |
|---|---:|---:|---:|---:|---:|
| versions.tar (130,5 MB) | 1,40 | 1,50 | 1,68 | 1,38 | 1,73 |
| mixed (178,6 MB) | 2,07 | 2,01 | 2,44 | 1,91 | 2,42 |

Los cortes de formato cuestan un 12–21 % del corte + SHA-1: zpaq-std empuja
byte a byte (`osrep_frag_state_push`) y las reglas guardan cada byte en un
anillo de 512. `osrep_frag_state_scan()` (≈1 GB/s sin reglas) no lo usa
zpaq-std todavía.

`a` completo con `-m1 -threads 4`, mediana de 3 (s) y RSS (MB):

| entrada | zpaq N=3 | `-osrep` N=3 | zpaq default (N=6) | `-osrep` default (N=3) |
|---|---:|---:|---:|---:|
| versions.tar | 0,89 / 408 | 0,97 / 319 | 1,01 / 485 | 0,91 / 326 |
| src-omega (40 versiones) | 2,25 / 30 | 2,60 / 30 | — | — |
| bin-releases (39 versiones) | 7,46 / 218 | 8,61 / 218 | — | — |

## Comprobaciones

- `tools/zpaq-vectors/osrep-switch-test.sh BASELINE zs-int versions.tar pja.tar`
  (2026-11-12): **fails=0**.
  - Sin `-osrep`, `-m0`/`-m1`/`-m5` con y sin `-noturbo`, `tests/corpus` y
    `versions.tar`: byte a byte idéntico al baseline.
  - `-osrep` sin `-fragment` y con `-fragment` 0, 3 y 6, en los tres corpus:
    el mismo archivo con los hilos por defecto, `-t1`, `-t8` y `-noturbo`.
  - `-osrep` sin `-fragment` da el mismo archivo que `-osrep -fragment 3`.
  - El baseline extrae los 12 archivos `-osrep` a los bytes originales.
- `fragment_dump FILE N 0 osrep` en N=0, 3 y 6 sobre `versions.tar` y
  `pja.tar`: la misma salida (cortes, `hits`, SHA-1, `o1`) en x64, x86
  (`gcc -m32`) y arm64 (`aarch64-linux-gnu-gcc -static`, qemu-user).
- `tests/fragment_state_check.c`: el empuje byte a byte, `osrep_frag_state_scan()`
  y `osrep_fragment_buffer()` cortan igual (zpaq, FNV, las 48 políticas gear y
  `-osrep` con cortes de formato); cortes fijados por checksum. Compila sin
  warnings con `-std=c99 -Wall -Wextra -pedantic -Werror` en gcc, clang,
  gcc `-m32`, aarch64 y mingw x86/x64, y pasa en todos (mingw bajo wine).
- `tests/fragment_format.sh`: los cortes de formato salen iguales por todos
  los caminos y tras un reinicio en cualquier corte; en un tar o un zip, un
  miembro sin cambios conserva sus fragmentos.

## Qué se entregó y qué no

| experimento | resultado | entregado |
|---|---|---|
| gear 1:0 (mínimo A/2, máximo de zpaq, un umbral) | el mejor de los medidos a igual promedio | **sí** |
| chunking normalizado (FastCDC 2:1, 4:1) | sin ganancia constante con mínimo A/2; 4:1 corta más fino de lo pedido | no (queda en `osrep_frag_params_gear()` para experimentos) |
| cortes tras cabecera tar y zip (`TAR_AFTER`, `ZIP_SIG`, `ZIP_AFTER`) | `frag_stats` en N=3/6: zips −38 a −69 %, tars −13 a −38 %, sin efecto en otros datos; en archivos reales los tars ganan con `-m1` y pierden 1–3 % con `-m5` | **sí**, fijos en `-osrep` |
| cortes antes de la cabecera (`TAR_BEFORE`, `ZIP_BEFORE`) | 0–4 % mejor o peor; hacen retroceder el corte | no: exigen cambiar cada lazo de zpaq-std |
| corte en salto de línea (`TEXT`) | neutro en texto, hasta +29 % en tars | no |
| promedio adaptativo por archivo (`-osrepauto`) | mejor caso −0,2 %; backups normales +0,1–2 %, hasta +65 % | no ([informe](experiments/frag-adaptive.md)) |

## Pendiente

1. ~~**`-m5` y la regla tar.**~~ Medido el 2026-11-25
   ([`experiments/frag-tar-rule.md`](experiments/frag-tar-rule.md)): la regla
   se queda en todos los métodos. Quitarla desde `-m3` cuesta 5–19 puntos en
   `-m3` y la victoria del historial en `-m5`; un umbral de tamaño para el
   corte tar solo reparte entre los dos extremos.
2. ~~**Árboles de archivos chicos**~~ (medido 2026-11-26, rechazado: [`experiments/frag-mincap.md`](experiments/frag-mincap.md)) (src-omega): el mínimo A/2 pierde contra el
   mínimo de zpaq (`64 << N`) en N≥3. El experimento 2 midió A/4 y A/8; un
   mínimo que no pase de cierto tamaño (por ejemplo `min(A/2, 4 KiB)`) es lo
   siguiente a probar.
3. **Velocidad**: zpaq-std empuja byte a byte con una llamada por byte. Un
   `osrep_frag_state_scan()` con los cortes de formato dentro del lazo, y
   zpaq-std llamándolo por bloques, recuperaría el 10–15 % de `-m1` en
   carpetas.
4. Benchmarks con zpaqfranz y un corpus de backup más grande.
5. **El mínimo A/2 contra cambios sueltos** (2.11.0): en una imagen de disco
   `-osrep` N=3 pierde contra zpaq N=3 (+1,2 %; lo que cuesta v2, +70 %).
   Con los cortes de formato y mínimo A/8–A/16, `frag_stats` gana en disco,
   árboles, bases de datos y tars, y pierde en `src-zpaqstd`. Es lo primero a
   medir con archivos reales (`-m1` y `-m5`), junto con el punto 2.

6. **Revisión de zpaq-std del parche 2.11.0 (2026-11-15):**
   - Rama `-sa` (~270627): si `osrep_fragment_buffer` falla (ENOMEM), `safr`
     queda vacío sin aviso. Que caiga a `fragment_buffer` o corte con error.
   - `-osrep -stdin`: revisar qué hace el camino `if (flagstdin) if (fragment
     != 6)` con N=3 forzado antes.
   - `g_fragmentgiven` por `argv[i]` es frágil: comparar `fragment` antes y
     después de `cli_getint`, o usar un centinela.
   - Velocidad: en `add2_scan` el tramo está en memoria; una función
     (base, desde, hasta) que devuelva el corte evita la llamada por byte
     (ver el punto 3).
   - Ayuda en cinco idiomas y `-helpcheck` en 0, cuando deje de ser prototipo.
   - Probar `-sa`: `codecs/` de `zpaq-std-v2.11.0-linux-x64-extra-codecs.zip`
     al lado del binario, y `suite_sa.sh` del testlab de zpaq-std (copiar
     `/mnt/IA_LAB/agentes/ZPAQ-STD/testlab`, solo lectura).
7. **Lo que falta en el marcador, según zpaq-std:**
   - La tabla que decide es N contra el mismo N (3 contra 3, 6 contra 6); default
     contra default mide sobre todo el tamaño del fragmento.
   - El costo de N=3 por defecto en conjuntos grandes (50 GB o más): `l`, `t` y
     `x` (tiempo y RAM), tamaño de los bloques de índice, y agregar una
     versión. Es el riesgo principal de ese default.
   - Archivo mezclado: v1 sin `-osrep` y v2 con él (y al revés, y con otro N).
     Medir cuánto cuesta y decidir si avisar o detectar (zpaq no guarda el
     fragmentador; la propuesta es `frag=osrep:N` en VFILE-info).
   - x86 de 32 bits y Windows 7: los mismos bytes de archivo que x64. Es
     condición para entrar.
   - PJA `-m5` (+4–5 %): ver si es el corte de tar partiendo flujos que `-sa`
     agrupa, o fragmentos chicos que le quitan contexto al CM.

---

## Mapeo anterior (histórico, hasta 2026-11-11)

Todo lo que sigue se midió con el `-osrep` anterior: CDC FNV de 48 bytes,
promedio `64 KiB << (N-9)` (N=6 8 KiB, N=3 1 KiB) y el mínimo y máximo de
zpaq. Se conserva como registro; las cifras actuales están arriba.

### Qué es el modo OSREP

- CDC de ventana fija de 48 bytes con hash FNV-1a rodante (el mismo de
  `-m1`/`-m2` de OSREP).
- Estado incremental (`osrep_frag_state_push`): hash, `hits` y `o1`; sirve
  para el lazo de `add2_scan` de zpaq-std.
- Parámetros: `min`/`max` salen del mapeo de `-fragment` de zpaq; el promedio
  se deriva de `-fragment N` como `64 KiB << (N - 9)`, con tope 1 KiB–1 MiB.
  - `N=6` (default de zpaq) → 8 KiB.
  - `N=3` → 1 KiB; `N=5` → 4 KiB; `N=9` → 64 KiB.
- Se activa con el switch `-osrep` de zpaq-std (ver abajo). Las tablas de
  esta página se midieron con el prototipo anterior, que tomaba el promedio de
  `OSREP_FRAG_AVG` con el mínimo y el máximo de `-fragment 6`.

### El switch `-osrep` (parche de entrega, 2026-11-11)

`tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.7.2.patch` reemplaza al
prototipo con variables de entorno. Sobre zpaq-std 2.7.2 (`b8ad717`):

- **`-osrep`** (EXPERIMENTAL, en `a`): corta con el fragmentador de OSREP.
  Sin el switch el código de zpaq-std no cambia: el bucle desenrollado,
  `add2_scan()` y su SHA-1 quedan como estaban.
- **`-fragment N`** conserva su sentido: `MIN_FRAGMENT`/`MAX_FRAGMENT` salen
  de N como siempre, y el promedio de OSREP es `64 KiB << (N-9)`, de 1 KiB a
  1 MiB (`osrep_frag_params_osrep()`). N=6, el default de zpaq, da 8 KiB;
  N=5, 4 KiB; N=3, 1 KiB. (El experimento
  `docs/experiments/frag-normalized.md` cambia esto: promedio 2^N KiB con el
  fragmentador gear, N=3 por defecto con `-osrep`; falta llevarlo al parche.)
- El SHA-1 de los fragmentos sigue siendo el de libzpaq. De OSREP solo entran
  `osrep_frag_state_reset()`/`osrep_frag_state_push()`, que llevan también
  `hits` y `o1` para el análisis de tipo de datos.
- Fuentes copiadas en `compressors/osrep/` (C99, MIT) y compiladas por el
  Makefile como los demás códecs en C. El tarball para vendorizar lo arma
  `tools/zpaq-vendor/make-vendor.sh`, con `VENDOR.md` (versión, commit y
  sha256 de cada archivo).
- Se quitó el modo de volcado de vectores (`OSREP_FRAG_VECTORS`) y las
  variables `OSREP_FRAG_MODE`/`OSREP_FRAG_AVG`. El parche de vectores sigue
  aparte, solo para regenerar los vectores.

Comprobado con `tools/zpaq-vectors/osrep-switch-test.sh BASELINE PARCHEADO
versions.tar pja.tar`:

| prueba | resultado |
|---|---|
| sin `-osrep`, `-m0`/`-m1`/`-m5`, con y sin `-noturbo`, `tests/corpus` y `versions.tar` | byte a byte idéntico al baseline |
| `-osrep` con `-fragment` 6, 3 y 5, en los tres corpus | el mismo archivo con los hilos por defecto, `-t1`, `-t8` y `-noturbo` (el bucle simple y `add2_scan` cortan igual) |
| los nueve archivos `-osrep` | el zpaq-std baseline los extrae idénticos a la entrada |
| `fragment_dump` (modo zpaq y osrep, N=3/5/6, los dos tar) | los mismos cortes, `hits`, SHA-1 y `o1` en x64, x86 (`-m32`) y arm64 |

Tamaños con `-m1` y el switch: `versions.tar` 9.028.353 (N=6), 8.450.469
(N=5), 7.723.228 (N=3); PJA 1.762.633, 1.784.370, 1.892.508. N=3 sale más
chico que en el prototipo (8,37 MB) porque ahora `-fragment 3` también baja el
mínimo y el máximo de zpaq, no solo el promedio.

### Comparación justa: a igual tamaño de fragmento (2026-11-11)

Las tablas más abajo comparan OSREP a 1–8 KiB contra zpaq a 64 KiB, así que
mezclan dos efectos. `-fragment N` no significa lo mismo en los dos: el
cortador de zpaq promedia 2^N KiB y el mapeo de `-osrep`, 2^(N-3) KiB. Con
`tools/zpaq-vectors/bench_fair.py --osrep-shift 3` se comparan los dos al
**mismo promedio** (zpaq `-fragment N` contra `-osrep -fragment N+3`), con el
switch `-osrep` y el baseline 2.7.2 del mismo commit; una corrida, y el
baseline extrae los 32 archivos idénticos a la entrada.

Tamaño del archivo (bytes) y diferencia de `-osrep`:

| corpus | `-m` | 64 KiB zpaq / osrep | 8 KiB | 4 KiB | 1 KiB |
|---|---|---|---|---|---|
| versions.tar | `-m1` | 15.293.575 / 15.570.270 (+1,8 %) | 9.835.635 / 9.028.353 (−8,2 %) | 8.754.145 / 8.450.469 (−3,5 %) | 8.460.664 / **7.723.228** (−8,7 %) |
| versions.tar | `-m5` | 4.548.941 / 4.599.056 (+1,1 %) | 3.749.060 / **3.744.504** (−0,1 %) | 3.868.320 / 3.829.169 (−1,0 %) | 4.489.893 / 4.275.325 (−4,8 %) |
| pja.tar | `-m1` | 2.817.689 / 2.873.103 (+2,0 %) | 1.767.855 / **1.762.633** (−0,3 %) | 1.795.605 / 1.784.370 (−0,6 %) | 1.942.765 / 1.892.508 (−2,6 %) |
| pja.tar | `-m5` | **971.248** / 972.735 (+0,2 %) | 1.006.299 / 1.003.143 (−0,3 %) | 1.034.092 / 1.024.389 (−0,9 %) | 1.178.787 / 1.127.372 (−4,4 %) |

Tiempo y RSS: iguales a 64 y 8 KiB (`versions.tar -m5`: 194/185 s y 163/155 s).
A 1 KiB `-osrep` es más rápido y usa menos memoria (`versions.tar -m5`: 93 s y
702 MB contra 109 s y 1.032 MB), en parte porque su mínimo es 512 bytes y el
de zpaq a `-fragment 0`, 64.

**Lectura.**

- Casi toda la ganancia de las tablas de abajo viene del fragmento más chico,
  no del CDC: zpaq con `-fragment 3` ya logra casi lo mismo que `-osrep` a 8 KiB.
- El CDC de OSREP suma 0,1–8,7 % a 8 KiB o menos y pierde 0,2–2 % a 64 KiB.
  Lo mejor que da es con `-m1` y fragmentos chicos (versions.tar, 1 KiB:
  −8,7 %, y es el mejor archivo `-m1` de toda la tabla).

**Por qué `-m5` pierde en PJA (punto 5).** Con `fragment_dump` sobre los dos tar:

| pja.tar | fragmentos | únicos | bytes únicos |
|---|---:|---:|---:|
| zpaq 64 KiB | 503 | 292 | 21.436.720 |
| osrep 8 KiB | 3.132 | 1.301 | 12.614.882 |
| osrep 1 KiB | 22.391 | 5.457 | 7.433.748 |

Fragmentar más chico saca 9–14 MB de datos repetidos, pero con `-m5` el
archivo crece: el compresor ya aprovechaba esa repetición, y cada fragmento
cuesta en el índice (≈24 bytes por fragmento único en los bloques `h`, SHA-1 y
tamaño, que no comprimen, más ≈4 por referencia en los `i`). A 8 KiB eso son
≈44 KB contra ≈9 KB a 64 KiB: +35 KB, y el archivo creció 32 KB. En
versions.tar la dedup sí gana (−804 KB a 8 KiB con +138 KB de índice).

**Qué promedio conviene.**

- `-m1`/`-m2` (compresores rápidos, sin contexto largo): fragmentos chicos,
  1–4 KiB.
- `-m5`: 8 KiB con muchas versiones parecidas; con pocas repeticiones entre
  versiones, 64 KiB (el default de zpaq).
- Un default único razonable: 8 KiB.

### Metodología

- zpaq-std baseline: mismo commit `b8ad717` (v2.7.2), sin cambios.
- Integrado: el prototipo con variables de entorno (ya reemplazado por
  `-osrep`), con `add2_scan` usando la API de OSREP.
- Archivos con `-touch 20240101000000 -timestamp 2024-01-01_00:00:00` para
  que la comparación no dependa del reloj.
- Tiempo de pared y RSS pico con `wait4`; una corrida.
- Corpora: `versions.tar` (125 MB, 4 snapshots de zpaq-std) y `pja.tar`
  (33 MB, 5 snapshots de PJA).

### Resultados (`-m1`)

| corpus | modo | archivo | vs exacto | tiempo | RSS |
|---|---|---:|---:|---:|---:|
| zpaq-std | exacto | 15.293.533 | — | 0,79 s | 542 MB |
| zpaq-std | OSREP 1 KiB | **8.368.993** | **−45,3 %** | 0,76 s | 353 MB |
| zpaq-std | OSREP 4 KiB | 8.683.254 | −43,2 % | 0,75 s | 394 MB |
| zpaq-std | OSREP 8 KiB | 9.028.305 | −41,0 % | 0,82 s | 393 MB |
| PJA | exacto | 2.817.645 | — | 0,50 s | 258 MB |
| PJA | OSREP 1 KiB | 1.784.620 | −36,7 % | 0,39 s | 217 MB |
| PJA | OSREP 4 KiB | 1.768.633 | −37,2 % | 0,43 s | 218 MB |
| PJA | OSREP 8 KiB | **1.762.589** | **−37,4 %** | 0,43 s | 219 MB |

### Resultados (`-m5`)

| corpus | modo | archivo | vs exacto | tiempo | RSS |
|---|---|---:|---:|---:|---:|
| zpaq-std | exacto | 4.548.898 | — | 170,3 s | 1.292 MB |
| zpaq-std | OSREP 1 KiB | 3.837.237 | −15,6 % | 108,0 s | 1.021 MB |
| zpaq-std | OSREP 4 KiB | 3.775.412 | −17,0 % | 119,4 s | 1.023 MB |
| zpaq-std | OSREP 8 KiB | **3.744.456** | **−17,7 %** | 124,4 s | 1.028 MB |
| PJA | exacto | **971.204** | — | 57,6 s | 654 MB |
| PJA | OSREP 1 KiB | 1.024.650 | +5,5 % | 26,9 s | 440 MB |
| PJA | OSREP 4 KiB | 1.010.229 | +4,0 % | 31,4 s | 442 MB |
| PJA | OSREP 8 KiB | 1.003.099 | +3,3 % | 33,8 s | 445 MB |

### Lectura

- **`-m1` (dedup barato)**: OSREP mode es una mejora grande y consistente:
  37–45 % menos archivo, igual o más rápido y 30–35 % menos RSS. El mejor
  promedio depende del corpus: 1 KiB en el grande, 8 KiB en PJA; 4 KiB es un
  buen compromiso.
- **`-m5` (compresión fuerte)**: en el corpus grande OSREP mode gana 17,7 %
  y tarda 27 % menos; en PJA pierde 3,3 % pero tarda **1,7× menos** y usa
  32 % menos RSS. Es un trade-off entre más fragmentos (mejor dedup) y menos
  contexto por bloque para el compresor.
- El default `N=6 → 8 KiB` es razonable para `-m5`; para `-m1` conviene
  `-fragment 3` (1 KiB) o `-fragment 5` (4 KiB).
- Todos los archivos OSREP-mode se extraen con el zpaq-std baseline y
  coinciden byte a byte con la entrada.

### Reproducir

```sh
python3 tools/zpaq-vectors/bench_osrep_mode.py \
  --baseline /ruta/zpaq-std-baseline \
  --integrated /ruta/zpaq-std-osrep \
  --input versions.tar --input pja.tar \
  --method=-m1 --method=-m5 --avgs 1024,4096,8192
```

La salida de la corrida está en `tools/zpaq-vectors/bench-osrep-mode.tsv`.

### Limitaciones

- Las tablas de arriba son del prototipo; los tamaños con `-osrep` están en
  la sección del switch.
- Dos corpus; falta zpaqfranz y un corpus de backup real más grande.
- El modo exacto sigue siendo el default y el que garantiza archivos
  idénticos al baseline.
