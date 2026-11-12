# Experimento 2: chunking normalizado (estilo FastCDC) para `-osrep`

Rama `frag-normalized`, 2026-11-11. Pregunta: con `-fragment N` =
promedio 2^N KiB (lo decidido con zpaq-std), ¿qué fragmentador conviene a
`-osrep`? Se probaron el hash, el umbral normalizado y la política de
mínimo/máximo, siempre contra el fragmentador de orden 1 de zpaq al **mismo
promedio**.

## Resultado

**Se envía: gear de 64 bytes con G[0] = 0, mínimo A/2, máximo 8128 << N (el
de zpaq) y un solo umbral.** El chunking normalizado (niveles 1 a 3) **no se
envía**: con el mínimo en A/2 no gana de forma consistente.

```c
/* A = 1024 << N, N <= 21 (N = 3 si -fragment no se da) */
osrep_frag_params p;
osrep_frag_params_osrep(&p, N, block_size); /* = _gear(&p, N, bs, 1, 0) */
/* mode = OSREP_FRAG_MODE_GEAR, min = A/2, norm = avg = A,
   max = 8128 << N recortado al bloque como en zpaq,
   t_small = t_large = ((UINT64_MAX / A) >> 16) * 131040 */
```

Corte: `h = (h << 1) + G[c]` sobre los últimos 64 bytes; se corta tras el
byte si `size >= min` y `h < t`, o en `max`. El hash empieza 64 bytes antes de
`min` (cut-point skipping): da los mismos valores que empezar en el corte.
`G` son 256 salidas de splitmix64 con semilla `0x4F5352455047454E`, salvo
`G[0] = 0`: 64 ceros dan `h = 0` y un corte, lo que ancla los cortes en el
relleno de ceros de tar, ejecutables y documentos (como ya hacía el FNV).
Todo es aritmética entera de 64 bits; la constante 131040 se calibró offline
(modelo de datos aleatorios en `tools/zpaq-vectors/frag_sim.c`) y en datos
aleatorios da 8131 B de promedio para A = 8192.

## Variantes

| nombre | hash | mínimo | máximo | umbral |
|---|---|---|---|---|
| `zpaq` | orden 1 de zpaq | 64 << N (A/16) | 8128 << N | — |
| `fnv` = `fnv:c:0` (actual) | FNV de 48 B | A/2 | 8128 << (N+3) (≈ 64 A) | `UINT64_MAX/A` |
| `gz:h:L` = `1:L` | gear, G[0]=0 | A/2 | 8128 << N (≈ 8 A) | calibrado, nivel L |
| `gz:f:L` = `2:L` | gear, G[0]=0 | A/4 (FastCDC) | 8128 << N | calibrado, nivel L |
| `gz:e:L` | gear, G[0]=0 | A/8 | 8128 << N | calibrado, nivel L |
| `gz:z:L` = `4:L` | gear, G[0]=0 | A/16 (el de zpaq) | 8128 << N | calibrado, nivel L |
| `gear:*` | gear, G[0]≠0 | — | — | — |

Nivel L de normalización (FastCDC NC-L): umbral `T >> L` antes de A y
`T << L` desde A. `T` está calibrado para cada (mínimo, L) de modo que el
promedio en datos aleatorios sea A.

## 1. Poda rápida (sin zpaq): `frag_sim`, 7 corpus

`est` = bytes únicos + 24 B por fragmento único + 4 B por referencia (el
índice de zpaq). "iso" compara con la curva de zpaq interpolada en el
**promedio realizado** de cada variante (log-lineal entre sus N); "avg" es el
promedio realizado / nominal (media geométrica). Media de % sobre versions,
pja, src-omega, src-zpaqstd, bin-releases, photos y mixed.

| variante | 4 KiB vs zpaq | iso | 8 KiB vs zpaq | vs actual | iso | avg | 64 KiB vs zpaq | iso |
|---|---|---|---|---|---|---|---|---|
| zpaq | 0 | 0 | 0 | +1.03 | 0 | 0.95 | 0 | 0 |
| fnv:c:0 (actual) | −0.92 | −4.77 | −0.87 | 0 | −4.52 | 1.22 | +3.45 | −2.19 |
| fnv:h:0 | −5.28 | −5.28 | −4.89 | −4.13 | −4.86 | 0.90 | −2.76 | −4.64 |
| gear:h:0 (G[0]≠0) | −3.89 | −3.89 | −3.76 | −2.93 | −3.87 | 0.93 | −0.72 | −3.88 |
| **gz:h:0** | −6.05 | **−5.78** | −5.21 | −4.46 | **−4.89** | 0.89 | −1.59 | **−4.01** |
| gz:h:1 | −5.32 | −5.18 | −4.60 | −3.85 | −4.56 | 0.90 | −1.73 | −4.03 |
| gz:h:2 | −3.82 | −3.74 | −3.65 | −2.93 | −3.70 | 0.90 | −1.12 | −3.32 |
| gz:f:1 (FastCDC) | −5.66 | −5.24 | −5.38 | −4.62 | −4.69 | 0.85 | −1.40 | −2.46 |
| gz:f:2 | −4.58 | −4.26 | −4.43 | −3.70 | −3.97 | 0.86 | −1.59 | −2.98 |
| gz:f:3 | −3.17 | −2.88 | −3.52 | −2.80 | −3.14 | 0.86 | −0.99 | −2.31 |
| gz:e:1 | −8.86 | −7.97 | −5.66 | −4.92 | −4.60 | 0.81 | −1.56 | +0.37 |
| gz:z:0 | −9.13 | −7.09 | −10.05 | −9.64 | −7.69 | 0.70 | −3.93 | +0.75 |
| gz:z:1 | −9.33 | −7.68 | −10.63 | −10.20 | −8.86 | 0.72 | −2.68 | +1.10 |

Lo que se lee:

- **Política de mínimo/máximo (d)** es lo que más pesa. Cambiar solo el máximo
  del actual (≈ 64 A) al de zpaq (≈ 8 A) pasa de −4.5 % a −4.9 % iso y acerca
  el promedio real al nominal (1.22 → 0.90). Un mínimo chico (A/16, A/8)
  parece ganar en "vs zpaq", pero porque corta mucho más fino que lo pedido
  (0.70× a 8 KiB); a 64 KiB iso pierde, y en archivos reales (abajo) pierde.
- **Normalización (b)**: con mínimo A/2 cada nivel empeora (h:0 → h:1 → h:2);
  con mínimo A/4 (FastCDC) el nivel 1 es el mejor de su fila, pero queda por
  debajo de h:0 en las cuatro N.
- **Hash (c)**: gear con G[0]=0 supera a gear puro (−4.89 vs −3.87 a 8 KiB) y
  empata o mejora al FNV con la misma política (fnv:h:0).

A 1 KiB la columna iso cubre solo 1–2 corpus (zpaq N=0 es el extremo de su
curva); en la columna "vs zpaq" gz:h:0 da −4.78 % y el actual −3.72 %.

## 2. Archivos reales (zpaq-std 2.7.2 + `-osrep`)

Una corrida por caso, `-t4`, en versions.tar, pja.tar, src-omega (40
versiones) y bin-releases (39 carpetas); los directorios se agregan versión
por versión. **Todos** se extrajeron con el zpaq-std **sin modificar** y
coinciden con la entrada (columna `extract` = ok en los TSV). Total de bytes
de los 4 corpus; % vs zpaq / vs actual al mismo N.

| N | zpaq | actual (fnv) | **1:0 (gz:h:0)** | 2:1 (gz:f:1) | 4:1 (gz:z:1) |
|---|---|---|---|---|---|
| -m1 1 KiB | 62 330 510 | −2.26 / 0 | **−2.22 / +0.04** | −1.58 / +0.69 | −1.51 / +0.77 |
| -m1 4 KiB | 64 241 582 | −0.69 / 0 | **−2.68 / −2.00** | −2.15 / −1.47 | −2.85 / −2.17 |
| -m1 8 KiB | 66 502 525 | −1.01 / 0 | **−2.51 / −1.51** | −3.01 / −2.01 | −4.25 / −3.27 |
| -m1 64 KiB | 80 050 804 | −0.29 / 0 | **−3.88 / −3.61** | −3.86 / −3.59 | −5.60 / −5.33 |
| -m5 8 KiB | 38 650 853 | −0.36 / 0 | **−1.51 / −1.16** | −1.58 / −1.22 | −0.74 / −0.38 |

-m5 a 8 KiB por corpus (% vs zpaq): pja +0.6 / +1.0 / +3.7, versions
+0.8 / +1.3 / +4.3, src-omega +0.8 / −0.3 / +5.2, bin-releases
−2.1 / −2.1 / −2.0 (1:0 / 2:1 / 4:1). Al mismo número **real** de
fragmentos (curva de zpaq por N interpolada), 1:0 en -m5 queda +0.02 % en pja
y +0.06 % en versions: un empate; la ganancia de −1.5 % del total viene de
bin-releases. En -m1 el ruido es alto (src-omega a 8 KiB: zpaq mismo no es
monótono en N), así que pesan más los totales y la simulación.

- 4:1 gana en -m1 porque corta más fino (21 591 fragmentos contra 14 110 de
  zpaq en versions a 8 KiB), pero pierde en -m5 (+2.8 % de media) y gasta más
  índice: descartado.
- 2:1 contra 1:0: mejor a 8 KiB en -m1 (−0.5 pt), igual en -m5 (−0.07 pt,
  ganan dos corpus cada uno) y a 64 KiB, peor a 1 y 4 KiB; en la simulación
  pierde en todas las N. Hace 4.5 % más fragmentos y hashea el 75 % de los
  bytes en vez del 50 %. No compensa un segundo umbral.

Datos crudos: `docs/experiments/frag-normalized-data/` (`real-m1.tsv`,
`real-m5.tsv`, `real-m1-zpaq-extra-N.tsv` con zpaq en N = 1, 4, 5, 7 para las
curvas iso, y `sim.tsv`).

## 3. Velocidad y memoria

Fragmentador solo (`tools/zpaq-vectors/frag_speed.c`, versions.tar en RAM,
corte + hits/o1 de orden 1, sin SHA-1; mediana de 3; `push` = byte a byte como
el bucle de zpaq-std, `scan` = `osrep_frag_state_scan()`):

| modo | 8 KiB push | scan | 64 KiB push | scan |
|---|---|---|---|---|
| zpaq | 282 MB/s | 282 | 293 | 303 |
| actual (FNV 48) | 90 | 93 | 91 | 95 |
| **gear 1:0** | **295** | **985** | **304** | **1010** |
| gear 2:1 | 274 | 929 | 278 | 933 |
| gear 4:1 | 264 | 888 | 255 | 853 |

El o1 de orden 1 que pide el análisis de tipo de zpaq domina `push`; en
`scan` el gear con mínimo A/2 va 3.3× más rápido que zpaq y 10× más que el
FNV actual. zpaq-std hoy usa `push` en `add2_scan_osrep()`; cambiarlo a
`scan` es una mejora posible, aparte.

`a` completo, versions.tar `-m1 -fragment 3 -t4` (FNV: `-fragment 6`, mismo
promedio), mediana de 3 con la máquina compartida y cargada: zpaq 1.37 s
(1.21/1.41/1.37), actual 1.46 s, **1:0 1.20 s**, 2:1 1.00 s; RSS 405 / 391 /
389 / 390 MB. Suma de los tiempos de una corrida en los 4 corpus a 8 KiB:
-m1 11.4 / 14.0 / 11.9 / 11.9 s, -m5 576 / 571 / 540 / 537 s (zpaq / actual /
1:0 / 2:1). RSS pico de -m5 a 8 KiB: versions 1033 / 1025 / 1022 / 1021 MB.

## 4. Determinismo y portabilidad

- Los cortes dependen solo de los bytes desde el último corte: el estado se
  reinicia en cada corte (`osrep_frag_state_reset()`) y el hash solo mira 64
  bytes. Eso es lo que necesita la resincronización de `add2_scan()` (los
  trozos de cada hilo empiezan en cortes supuestos y se validan al
  encontrarse con la cadena verdadera).
- versions.tar `-m1 -fragment 3 -osrep` con `-t1`, `-t4` y `-t16`: archivos
  idénticos byte a byte, para 1:0 y para 2:1.
- `tests/fragment_state_check.c`: `push`, `scan` (en bloques de tamaño
  pseudoaleatorio) y `osrep_fragment_buffer()` cortan igual en los tres modos
  y en las 48 políticas gear (N = 0, 2, 3; mínimo A/2..A/16; niveles 0..3),
  con corridas de ceros y de un byte repetido; los cortes gear quedan fijados
  por un checksum (`tests/fragment_gear_pins.inc`). Pasa sin warnings
  (`-std=c99 -Wall -Wextra -pedantic -Werror`) con gcc, clang, gcc -m32,
  aarch64-linux-gnu-gcc (qemu-user) y mingw x86/x64 (wine): mismos pins en
  todas.
- `tests/zpaq_fragments_exact.sh` y `tests/osrep_cdc_mode.sh` siguen pasando
  (el modo zpaq y el FNV no cambian; el FNV queda en
  `osrep_frag_params_fnv()` con su mapeo viejo).

## Qué falta en zpaq-std (no es parte de esta rama)

- `osrep_fill_params()`: `osrep_frag_params_osrep(&fp, fragment, 0)` y luego
  `fp.max = MAX_FRAGMENT` (ya recortado al bloque), sin la variable
  `OSREP_GEAR_POLICY`, que solo existe en la copia del experimento
  (`zs-normalized`).
- `-osrep` sin `-fragment` explícito: N = 3. El default de zpaq-std sigue en
  N = 6. Actualizar el texto de ayuda (hoy dice `64 KiB<<(N-9)`).

## Reproducir

```sh
cc -O2 -std=c99 tools/zpaq-vectors/frag_sim.c -lm -o frag_sim
cc -O2 -std=c99 -Isrc/c src/c/osrep_fragment.c src/c/osrep_sha1.c \
   tools/zpaq-vectors/frag_speed.c -o frag_speed
python3 tools/zpaq-vectors/frag_sim_list.py CORPUS > corpus.lst
./frag_sim corpus.lst 0,1,2,3,4,5,6,7 zpaq fnv:c:0 gz:h:0 gz:f:1 gz:z:1
tools/zpaq-vectors/bench_policies.py --baseline BASE --patched PATCHED \
   --workdir W --method=-m1 --fragments 0,2,3,6 --configs zpaq,fnv,1:0,2:1 \
   --corpus versions=versions.tar --corpus src-omega=DIR
./frag_speed versions.tar 3 3 zpaq osrep gear:2:1
```

`PATCHED` es un zpaq-std con `-osrep` que lee `OSREP_GEAR_POLICY` (`S:L` o
`fnv`); ver el comentario de `bench_policies.py`.
