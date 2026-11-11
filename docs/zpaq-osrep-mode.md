# zpaq-std OSREP mode — benchmarks

**Estado: modo OSREP implementado y medido (2026-11-10).** El fragmentador de
zpaq-std puede usar el CDC de OSREP en lugar del de orden 1. El formato ZPAQ
no cambia: solo cambian los cortes y, por lo tanto, el tamaño del archivo.

## Qué es el modo OSREP

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

## El switch `-osrep` (parche de entrega, 2026-11-11)

`tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.7.2.patch` reemplaza al
prototipo con variables de entorno. Sobre zpaq-std 2.7.2 (`b8ad717`):

- **`-osrep`** (EXPERIMENTAL, en `a`): corta con el fragmentador de OSREP.
  Sin el switch el código de zpaq-std no cambia: el bucle desenrollado,
  `add2_scan()` y su SHA-1 quedan como estaban.
- **`-fragment N`** conserva su sentido: `MIN_FRAGMENT`/`MAX_FRAGMENT` salen
  de N como siempre, y el promedio de OSREP es `64 KiB << (N-9)`, de 1 KiB a
  1 MiB (`osrep_frag_params_osrep()`). N=6, el default de zpaq, da 8 KiB;
  N=5, 4 KiB; N=3, 1 KiB.
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

## Comparación justa: a igual tamaño de fragmento (2026-11-11)

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

## Metodología

- zpaq-std baseline: mismo commit `b8ad717` (v2.7.2), sin cambios.
- Integrado: el prototipo con variables de entorno (ya reemplazado por
  `-osrep`), con `add2_scan` usando la API de OSREP.
- Archivos con `-touch 20240101000000 -timestamp 2024-01-01_00:00:00` para
  que la comparación no dependa del reloj.
- Tiempo de pared y RSS pico con `wait4`; una corrida.
- Corpora: `versions.tar` (125 MB, 4 snapshots de zpaq-std) y `pja.tar`
  (33 MB, 5 snapshots de PJA).

## Resultados (`-m1`)

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

## Resultados (`-m5`)

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

## Lectura

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

## Reproducir

```sh
python3 tools/zpaq-vectors/bench_osrep_mode.py \
  --baseline /ruta/zpaq-std-baseline \
  --integrated /ruta/zpaq-std-osrep \
  --input versions.tar --input pja.tar \
  --method=-m1 --method=-m5 --avgs 1024,4096,8192
```

La salida de la corrida está en `tools/zpaq-vectors/bench-osrep-mode.tsv`.

## Limitaciones

- Las tablas de arriba son del prototipo; los tamaños con `-osrep` están en
  la sección del switch.
- Dos corpus; falta zpaqfranz y un corpus de backup real más grande.
- El modo exacto sigue siendo el default y el que garantiza archivos
  idénticos al baseline.
