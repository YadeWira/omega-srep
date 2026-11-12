# Experimento 1: promedio de fragmento adaptativo por archivo (`-osrepauto`)

> **Integración (rama `frag-int`, 2026-11-12):** no se entregó. El código
> (`osrep_frag_sample_kind`, `osrep_frag_params_auto*`, `-osrepauto`) queda
> solo en la rama `frag-adaptive`; aquí están el informe, los resultados y el
> parche prototipo de zpaq-std como registro. La advertencia sobre el mínimo
> de N=3 (512 B con el FNV) la resolvió el fragmentador gear: mínimo A/2,
> 4 KiB en N=3.

Rama `frag-adaptive`, 2026-11-11. EXPERIMENTAL: no forma parte de ningún
release.

## Pregunta

Con `-osrep` y `-fragment N` (promedio 2^N KiB, N=3 por defecto), ¿conviene
que cada archivo elija su propio promedio a partir de sus primeros 64 KiB,
subiéndolo para datos ya comprimidos (JPEG, PNG, ZIP, MP4…) y dejándolo igual
para texto, código y ejecutables?

La idea: un fragmento cuesta ≈24 bytes en el índice (SHA-1 y tamaño en los
bloques `h`) más ≈4 por referencia (bloques `i`), y en datos comprimidos la
deduplicación fina casi nunca encuentra nada, así que fragmentos más grandes
deberían ahorrar índice sin perder dedup.

## Respuesta corta

**No lo envíes.** La ganancia tiene un techo bajo y las pérdidas no:

- El ahorro máximo es el índice de los datos comprimidos únicos: 24 B por
  fragmento de 8 KiB, ≈0,3 %. En `photos` (fotos nuevas o copias idénticas,
  el mejor caso posible) da −0,22 % con `-m1` y −0,23 % con `-m5`.
- En cuanto un archivo comprimido cambia en un punto (una edición de metadatos,
  un fixture que se regenera, un contenedor con miembros compartidos), cada
  cambio cuesta ≈medio fragmento, y el fragmento ahora es 8 veces mayor:
  `photoedit` +1,54 % (`-m5`: +1,65 %), `src-omega` +2,10 %, `mixed` +0,11 %.
- Un número mágico no dice que el contenido sea incompresible ni único: los
  176 `.osr` de `src-omega` son archivos OSREP (algunos `-m0`, sin comprimir)
  que cambian entre versiones, y fueron los que perdieron.

Con subidas menores (+1, +2) el balance sigue siendo negativo fuera de
`photos`. Tampoco hay ganancia de velocidad: el cortador recorre igual cada
byte (los tiempos de `auto` y `osrep` son iguales dentro del ruido).

## API (prototipo, en `src/c/osrep_fragment.{c,h}`)

```c
#define OSREP_FRAG_SAMPLE_MAX 65536u
#define OSREP_FRAG_KIND_DEFAULT 0u /* texto, código, ejecutables, media cruda */
#define OSREP_FRAG_KIND_PACKED  1u /* ya comprimido */
#define OSREP_FRAG_AUTO_RAISE   3u /* comprimido: -fragment N + 3 */

unsigned osrep_frag_sample_kind(const uint8_t *sample, size_t len,
                                osrep_frag_sample_info *info);
int osrep_frag_params_auto(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size, const uint8_t *sample,
                           size_t len);
int osrep_frag_params_auto_raise(osrep_frag_params *params, unsigned fragment,
                                 uint32_t block_size, const uint8_t *sample,
                                 size_t len, unsigned raise);
uint32_t osrep_frag_auto_max(unsigned fragment, uint32_t block_size,
                             unsigned raise);
```

- La muestra es exactamente los primeros `min(tamaño, 64 KiB)` bytes del
  archivo. `sample == NULL, len == 0` (stdin sin datos, imágenes) da N.
- **Comprimido** si empieza con un número mágico conocido (JPEG, PNG, GIF,
  WebP, 7z, RAR, gzip, xz, zstd, bzip2, LZ4, ISO-BMFF (MP4/MOV/HEIC/AVIF),
  Matroska, Ogg, FLAC, MP3 con ID3, ZPAQ, OSREP v6), o si la muestra tiene al
  menos 4 KiB, entropía de orden 0 de al menos 7,5 bits por byte y menos de
  1/16 de aciertos del predictor de orden 1 (el mismo `o1` del estado).
- Todo es aritmética entera: la entropía se calcula en Q16 con un `log2` por
  cuadrados sucesivos, sin coma flotante. El clasificador da la misma salida
  byte a byte en x86-64, x86 (`-m32`) y aarch64 sobre 6.823 archivos de los
  corpus (340 comprimidos).
- `osrep_frag_auto_max()` da el mayor `max` posible para dimensionar el buffer
  de fragmento del llamador antes de ver ningún archivo.
- Compila sin warnings con gcc, clang, gcc `-m32`, mingw x86/x64 y aarch64
  (`-std=c99 -Wall -Wextra -pedantic`). `tests/fragment_state_check.c` cubre
  el mapeo nuevo de N y la clasificación.

## Lado zpaq-std (prototipo en `frag-adaptive-zpaq-std.patch`)

Contra zpaq-std `osrep-fragmenter` (d53ca1f). Además de `-osrepauto`, el
parche trae lo **decidido** con zpaq-std: `-fragment N` promedia 2^N KiB
también con `-osrep`, y `-osrep` sin `-fragment` usa N=3 (8 KiB); el default
de zpaq-std sigue en N=6.

La decisión es por archivo, antes del primer corte, y se toma en los dos
caminos con los mismos bytes:

1. En `add()`, junto a `MAX_FRAGMENT`: si `-osrepauto`, el buffer de fragmento
   (`fragbuf`) y `TURBOROOM` se dimensionan con
   `osrep_frag_auto_max(N, blocksize, raise)`.
2. También en `add()`, después de `if (flagstdin) g_ioBUFSIZE= 4096;`: con
   `-osrepauto`, `g_ioBUFSIZE` es al menos 64 KiB. Así la primera lectura del
   bucle simple trae la muestra entera aunque haya `-buffer` chico o stdin
   (sin esto, stdin decidiría con 4 KiB y el mismo contenido cortaría distinto
   según cómo llegue).
3. Bucle simple: en la primera lectura del archivo (`fj == 0`, `sz == 0`,
   `bufptr == 0`, no imagen) se llama
   `osrep_frag_params_auto_raise(&fp_archivo, N, blocksize, buf, min(buflen, 64 KiB), raise)`
   y se reinicia el estado con esos parámetros. Si el archivo sigue en el
   bloque siguiente (`fj > 0`), los parámetros se conservan.
4. `-turbo` (`add2_scan`): el primer lote del archivo contiene su comienzo; ahí
   se llama lo mismo con `base, min(fine, 64 KiB)`, y todos los trabajadores
   (`scan[k]`, `uno`, `coda`) reciben `&fp_archivo` y `maxf = fp_archivo.max`.
   Como el estado se reinicia en cada corte y en cada inicio adivinado
   (`from`/`after`/`dopo`), basta con que los parámetros sean fijos por
   archivo para que el resincronizado dé los mismos cortes.
5. Las imágenes (`-image`, VHD, NTFS) conservan N, en los dos caminos.

Verificado: con `-threads 1` (bucle simple) y `-threads 4` (`-turbo`) los
archivos `.zpaq` salen idénticos byte a byte (`photos`, `-osrep` y
`-osrepauto`), y el **baseline sin modificar** extrae todos los archivos de
todas las corridas idénticos a la entrada. El formato no cambia: un fragmento
de N+3 es un fragmento de zpaq `-fragment 6`.

## Resultados

Binario: zpaq-std d53ca1f + el parche; baseline: 2.7.2 sin modificar.
`tools/zpaq-vectors/bench_adaptive.py`, `-threads 4`, versiones agregadas una
tras otra al mismo archivo. Tamaños en bytes, índice incluido (es el `.zpaq`
entero). `zpaq` = fragmentador de zpaq a `-fragment 3`; `osrep` =
`-osrep -fragment 3`; `+R` = `-osrepauto` con subida R (los dos a 8 KiB de
promedio para los archivos no comprimidos). Una corrida por tamaño; los
tiempos de `-m1` de las tres primeras filas son medianas de 3.

### `-m1`

| corpus | zpaq 8 KiB | osrep 8 KiB | +1 (16 KiB) | +2 (32 KiB) | +3 (64 KiB) | +19 (máx.) |
|---|---:|---:|---:|---:|---:|---:|
| photos (2 versiones) | 98.214.848 | 98.058.100 | 97.935.540 (−0,12 %) | 97.873.631 (−0,19 %) | **97.844.164 (−0,22 %)** | 98.017.281 (−0,04 %) |
| photoedit (2) | **90.392.613** | 90.455.795 | 90.601.940 (+0,16 %) | 90.847.469 (+0,43 %) | 91.845.659 (+1,54 %) | 149.641.430 (+65 %) |
| mixed (1 carpeta) | **86.540.909** | 86.944.526 | 87.023.661 (+0,09 %) | 87.049.641 (+0,12 %) | 87.037.714 (+0,11 %) | 87.032.664 (+0,10 %) |
| src-omega (40) | **3.918.761** | 4.048.368 | | | 4.133.515 (+2,10 %) | |
| bin-releases (39) | 50.980.795 | 50.414.909 | | | **50.413.917 (−0,002 %)** | |
| pja.tar | **1.767.947** | 1.792.894 | | | 1.792.894 (idéntico) | |
| versions.tar | 9.835.727 | **7.702.436** | | | 7.702.436 (idéntico) | |

Porcentajes contra `osrep`. `src-zpaqstd` no tiene ningún archivo
comprimido: `auto` da los mismos cortes que `osrep` (comprobado con
`frag_stats`, sin zpaq), igual que los dos tar.

### `-m5`

| corpus | zpaq 8 KiB | osrep 8 KiB | +3 (64 KiB) |
|---|---:|---:|---:|
| photos | 87.873.000 | 87.916.304 | **87.717.780 (−0,23 %)** |
| photoedit | **81.087.040** | 81.347.999 | 82.687.087 (+1,65 %) |
| pja.tar | **1.006.391** | 1.045.874 | 1.045.874 (idéntico) |

`mixed -m5` no se corrió: el servidor estaba cargado y `-m1` ya muestra que
pierde (los datos comprimidos casi no cambian de tamaño con `-m5`).

### Tiempo y memoria

| corpus `-m1` (mediana de 3) | zpaq | osrep | +3 |
|---|---:|---:|---:|
| photos | 1,61 s · 519 MB | 2,31 s · 460 MB | 2,43 s · 456 MB |
| photoedit | 1,67 s · 516 MB | 3,04 s · 456 MB | 3,19 s · 459 MB |
| mixed | 2,12 s · 445 MB | 3,81 s · 390 MB | 3,79 s · 368 MB |

`-m5` (una corrida, `photos`): zpaq 317 s, osrep 314 s, +3 329 s, todos con
≈1,79 GB de RSS. El costo de clasificar (un histograma de 64 KiB por archivo)
no se ve; tampoco hay ahorro, porque el cortador de OSREP recorre cada byte
igual con cualquier promedio.

### Por qué pierde: `frag_stats` sin zpaq

`tools/zpaq-vectors/frag_stats.c` corta con la API y cuenta fragmentos únicos
y bytes únicos, con la estimación de índice de 24 B por único y 4 por
referencia:

| corpus | config | bytes únicos | índice est. |
|---|---|---:|---:|
| photos | osrep 3 | 106.215.507 | 449.664 |
| photos | +3 | 106.609.288 (+394 K) | 235.200 (−214 K) |
| photoedit | osrep 3 | 98.066.269 | 422.000 |
| photoedit | +3 | 100.095.854 (+2.030 K) | 225.600 (−196 K) |
| mixed | osrep 3 | 165.074.397 | 945.096 |
| mixed | +3 | 165.503.792 (+429 K) | 831.744 (−113 K) |

- `photoedit` son las 61 fotos de `photos/v1` y una v2 con 37 bytes insertados
  en el offset 600 de cada una (una edición de metadatos). Con 8 KiB cada
  edición cuesta ≈un fragmento; con 64 KiB, ≈ocho. Con el máximo (+19) se
  pierde casi todo: +65 %.
- En `mixed` (una sola versión) los datos comprimidos se repiten entre archivos
  distintos (GIF dentro de documentos, partes compartidas de `.docx`), y el
  fragmento grande deja de verlos.
- Aun en `photos` hay repeticiones internas: los bytes únicos suben 394 K.
- La estimación de índice se queda corta: según los `.zpaq` reales, cada
  fragmento ahorrado vale unas 3 veces los 24+4 B estimados (`photos` ganó
  214 KB donde la estimación decía que perdía 180 K; `photoedit` perdió 1,39 MB
  y no 1,83 MB; `mixed`, 93 KB y no 316 K). Aun así `photoedit`, `mixed` y
  `src-omega` pierden en el archivo real.

## Hallazgo lateral: el mínimo y el máximo del nuevo N

Con el mapeo decidido (`-osrep -fragment 3` = 8 KiB de promedio) el mínimo y
el máximo vienen del `-fragment 3` de zpaq (512 B y 63,5 KiB), no del
`-fragment 6` de antes (4 KiB y 508 KiB) con el mismo promedio de 8 KiB. Eso
cambia los números de la tabla de `docs/zpaq-osrep-mode.md` («8 KiB»):

| corpus | antes (`-fragment 6`, mín. 4 KiB) | ahora (`-fragment 3`, mín. 512 B) | zpaq 8 KiB |
|---|---:|---:|---:|
| versions.tar `-m1` | 9.028.353 | **7.702.436** (−14,7 %) | 9.835.727 |
| pja.tar `-m1` | **1.762.633** | 1.792.894 (+1,7 %) | 1.767.947 |
| pja.tar `-m5` | **1.003.143** | 1.045.874 (+4,3 %) | 1.006.391 |

Fragmentos mínimos más chicos ayudan a la dedup de `versions.tar` pero suman
índice, y con `-m5` en PJA `-osrep` pasa a perder 3,9 % contra zpaq al mismo
promedio. Conviene revisar el mínimo de `-osrep` (por ejemplo, `avg / 2` o
`avg / 4`) antes de fijar N=3 como default; es otro experimento.

## Recomendación

- **No enviar** `-osrepauto` ni la subida por tipo de datos. El mejor caso da
  0,2 % y los casos comunes de respaldo (fotos editadas, fixtures que cambian,
  contenedores) pierden de 0,1 % a 2 %, y hasta 65 % con fragmento de archivo
  entero.
- Si alguna vez se retoma, el único ajuste que no perdió feo fue +1
  (16 KiB): −0,12 % en `photos`, +0,16 % en `photoedit`, +0,09 % en `mixed`.
  No compensa el código ni la regla de la muestra de 64 KiB en zpaq-std.
- Lo que sí vale del prototipo: la regla de que cualquier decisión por archivo
  se toma con exactamente `min(tamaño, 64 KiB)` bytes, igual en el bucle simple
  y en `-turbo` (con `g_ioBUFSIZE` forzado a 64 KiB para stdin y `-buffer`), y
  el clasificador entero y portable, si otro experimento lo necesita.

## Reproducir

```sh
Z=/mnt/IA_LAB/agentes/osrep/zpaqclean
tools/zpaq-vectors/bench_adaptive.py --baseline $Z/baseline/zpaq-std \
  --patched $Z/zs-adaptive/zpaq-std --workdir $Z/adapt/runs/w --threads 4 \
  --method=-m1 --repeat 3 --configs zpaq:3,osrep:3,auto:3:1,auto:3:3 \
  --corpus photos=$Z/corpus6/photos --corpus mixed=$Z/corpus6/mixed:single
cc -O2 -std=c99 -Isrc/c src/c/osrep_sha1.c src/c/osrep_fragment.c \
  tools/zpaq-vectors/frag_stats.c -o frag_stats
find DIR -type f | sort | ./frag_stats auto 3 3
```

`OSREP_AUTO_RAISE=R` en el entorno cambia la subida del prototipo de zpaq-std
(solo para estos experimentos).
