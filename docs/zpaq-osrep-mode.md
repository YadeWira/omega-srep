# zpaq-std OSREP mode — benchmarks

**Estado: `-osrep` integrado (2026-11-12, rama `frag-int`).** El fragmentador
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

1. **`-m5` y la regla tar.** Cuesta 0,9–2,6 % con `-m5` y gana hasta 10 %
   con `-m1`. Una opción simple: que zpaq-std quite `OSREP_FRAG_F_TAR_AFTER`
   de `p.flags` desde `-m3`. Falta medir el gear sin reglas en `-m3`/`-m5`
   con N=0 y N=6 antes de decidir.
2. **Árboles de archivos chicos** (src-omega): el mínimo A/2 pierde contra el
   mínimo de zpaq (`64 << N`) en N≥3. El experimento 2 midió A/4 y A/8; un
   mínimo que no pase de cierto tamaño (por ejemplo `min(A/2, 4 KiB)`) es lo
   siguiente a probar.
3. **Velocidad**: zpaq-std empuja byte a byte con una llamada por byte. Un
   `osrep_frag_state_scan()` con los cortes de formato dentro del lazo, y
   zpaq-std llamándolo por bloques, recuperaría el 10–15 % de `-m1` en
   carpetas.
4. Benchmarks con zpaqfranz y un corpus de backup más grande.

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
