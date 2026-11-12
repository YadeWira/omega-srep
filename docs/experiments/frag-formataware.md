# Experimento 3: cortes que conocen el formato (tar, zip, texto)

> **Integración (rama `frag-int`, 2026-11-12):** se entregaron `TAR_AFTER`,
> `ZIP_SIG` y `ZIP_AFTER` (42, `OSREP_FRAG_F_FORMAT`), reimplementados sobre
> el fragmentador gear y fijos en `osrep_frag_params_osrep()`. Con el mínimo
> A/2 del gear la regla tar ya no es neutra en N=3: −20 % a −38 % en tars con
> `frag_stats`. `TAR_BEFORE`, `ZIP_BEFORE` (retroceden el corte) y `TEXT` no
> se entregaron, por lo que dice este informe. Este informe midió el modo FNV;
> las cifras actuales están en `docs/zpaq-osrep-mode.md`.

**Estado: prototipo, 2026-11-11. EXPERIMENTAL.** Rama `frag-formataware`.

La idea: además del CDC de OSREP (FNV de 48 bytes), forzar cortes en los
límites de estructura de los contenedores, para que un miembro sin cambios
de un tar o de un zip dé los mismos fragmentos aunque cambie su vecino.

## Resumen

| reglas | qué hacen | resultado | ¿entregar? |
|---|---|---|---|
| `ZIP_SIG` + `ZIP_AFTER` (40) | corte tras `PK\3\4`, tras el resto de la cabecera local y tras la primera `PK\1\2` | zips versionados: **−68 %** con `-m1` (deflate), −16 % (stored); sin zips: 0 a +0,27 % | **sí** |
| `TAR_AFTER` (2) | corte tras una cabecera ustar con checksum válido | N=3: archivo idéntico; N=6: −28 % a −37 % | sí, junto con la anterior (no cuesta nada en N=3) |
| `TAR_BEFORE` (1), `ZIP_BEFORE` (4) | corte *antes* de la cabecera (devuelve 263 o 4 bytes: `CUT_BACK`) | 0–4 % mejor o peor que lo anterior según el corpus | no: exige cambiar cada lazo de zpaq-std |
| `TEXT` (16) | tras disparar el hash, cortar en el siguiente `\n` | neutro en texto, hasta +29 % en tars | no |

**Recomendación: entregar con `flags = OSREP_FRAG_F_TAR_AFTER |
OSREP_FRAG_F_ZIP_SIG | OSREP_FRAG_F_ZIP_AFTER` (42) fijo bajo `-osrep`**, sin
switch nuevo. Son reglas que solo cortan *después* del byte que acaba de
entrar, así que zpaq-std no cambia ningún lazo: solo pone el campo `flags`.
El precio es un ~15 % más de tiempo en la etapa de corte + SHA-1 (sin efecto
visible en el tiempo total de `-m1` sobre archivos grandes; +20–30 % en
carpetas de archivos pequeños, donde el lazo de OSREP ya era el cuello de
botella; corridas sueltas).

## API

En `src/c/osrep_fragment.h` (`osrep_frag_params` gana el campo `flags`;
`osrep_frag_params_osrep()` lo deja en 0):

```c
#define OSREP_FRAG_F_TAR_BEFORE 1u   /* devuelve 263 bytes (CUT_BACK) */
#define OSREP_FRAG_F_TAR_AFTER  2u
#define OSREP_FRAG_F_ZIP_BEFORE 4u   /* devuelve 4 bytes (CUT_BACK) */
#define OSREP_FRAG_F_ZIP_AFTER  8u
#define OSREP_FRAG_F_TEXT      16u
#define OSREP_FRAG_F_ZIP_SIG   32u   /* gana sobre ZIP_BEFORE */
#define OSREP_FRAG_F_ZIP_NOBACK (OSREP_FRAG_F_ZIP_SIG | OSREP_FRAG_F_ZIP_AFTER)
#define OSREP_FRAG_F_BACK (OSREP_FRAG_F_TAR_BEFORE | OSREP_FRAG_F_ZIP_BEFORE)

#define OSREP_FRAG_CUT      1  /* cortar tras el byte recién entrado */
#define OSREP_FRAG_CUT_BACK 2  /* cortar state->back bytes antes */
```

Uso en zpaq-std para lo recomendado (una línea donde arma `osrep_fp`):

```c
osrep_fp.flags = OSREP_FRAG_F_TAR_AFTER | OSREP_FRAG_F_ZIP_NOBACK;
```

Con esos bits `osrep_frag_state_push()` solo devuelve 0 o 1, igual que hoy.
Con `TAR_BEFORE` o `ZIP_BEFORE` puede devolver `OSREP_FRAG_CUT_BACK`: el
fragmento termina `state->back` bytes antes y esos bytes empiezan el
siguiente (se vuelven a empujar tras el reset; con esos bits el mínimo sube a
512, así que empujarlos nunca corta). `osrep_fragment_buffer()` lo resuelve
solo. En zpaq-std hace falta tocar `add2_scan_osrep()` (retroceder `pos`) y
el lazo en línea de `add2()` (guardar los bytes y empujarlos al empezar el
fragmento siguiente); el prototipo está en
`tools/zpaq-vectors/formataware-prototype.patch` (el `add()` de las builds
`ANCIENT` no está tocado). La variable de entorno `OSREP_FRAG_FLAGS` del
parche es solo para medir.

### Las reglas

- **Tar.** `TAR_AFTER`: cuando acaba de entrar el byte 512 de un bloque con
  `ustar` en el offset 257 y checksum válido (suma sin signo, el campo leído
  como espacios), cortar. Como el último byte de una cabecera ustar, GNU o pax
  es relleno, la comprobación solo se hace cuando entra un 0. `TAR_BEFORE`:
  al ver `ustar\0` o `ustar ` en el offset 257 de un bloque cuyos campos
  octales son plausibles, cortar al principio de ese bloque (263 bytes atrás).
- **Zip.** `ZIP_SIG`: cortar justo después de `PK\3\4`. El fragmento anterior
  acaba con esos cuatro bytes sea cual sea el miembro siguiente, así que la
  cola de un miembro no cambia. Lo mismo tras `PK\1\2` si el fragmento no
  empezó con el resto de una entrada del directorio central (validada en el
  byte 42), es decir, solo en la primera entrada: el directorio entero queda
  junto. `ZIP_AFTER` con `ZIP_SIG`: si el fragmento empieza con el resto
  plausible de una cabecera local (versión ≤ 63, método conocido, nombre de 1
  a 4096 bytes), cortar tras nombre y extra. Sin `ZIP_SIG`, `ZIP_BEFORE` corta
  antes de `PK\3\4` y de la primera `PK\1\2`, y `ZIP_AFTER` exige la firma al
  principio del fragmento.
- Todo se decide con los bytes del fragmento actual (un anillo de 512 bytes,
  los últimos 8 bytes y dos contadores) y se reinicia en cada corte. Un falso
  positivo solo añade un corte, igual de determinista.

## Determinismo y seguridad

- **Hilos.** `add2_scan` arranca trabajadores en posiciones adivinadas con el
  estado limpio y acepta su cadena cuando un corte suyo coincide con uno de la
  cadena verdadera. Como el estado solo depende de los bytes desde el último
  corte, una cadena que empieza en un corte verdadero sigue igual. Para
  `CUT_BACK` el retroceso queda dentro del fragmento abierto, así que tampoco
  cruza el `carry` entre lotes. Comprobado: **los 112 archivos `-osrep` de la
  tabla `-m1` (84 con reglas) son byte a byte iguales con los hilos por
  defecto y con `-t1`** (que usa el lazo en línea, no `add2_scan`).
- `tests/fragment_format_check.c` compara `osrep_fragment_buffer()` con un
  lazo tipo `add2()` en línea (bytes devueltos guardados y reinyectados), con
  uno tipo `add2_scan` (retrocede la posición) y con reinicios en cortes
  (16 por archivo), para N = 0, 3, 6 y los bits 1, 2, 3, 4, 12, 16, 31, 32,
  40 y 42.
- Arquitecturas: listas de cortes idénticas (md5) en x64, x86 (`-m32`) y
  arm64 (qemu) para tar, zip deflate, zip stored y `pja.tar`. Solo aritmética
  entera. C99 puro sin advertencias con gcc, gcc `-m32`, clang, mingw
  x86/x64 y aarch64 (`-Wall -Wextra -pedantic -Werror`).
- Formato: **el zpaq-std sin modificar extrae todos los archivos** (todas las
  filas de las tablas, `extract = ok`).
- `bash tests/fragment_format.sh` lo comprueba, y también que en un tar
  (ustar y GNU) y en un zip de cuatro miembros cambiar el segundo solo añade
  ese miembro y su cabecera: 91.648 bytes nuevos con `TAR` frente a 97.039
  con el CDC solo; en zip, 91.282 con `ZIP_SIG|ZIP_AFTER` frente a 98.010.

## Corpus

- `versions.tar` (125 MB, 4 instantáneas de zpaq-std, rutas `snap/vN/...`)
  y `pja.tar` (33 MB, 5 instantáneas de PJA).
- `omega-tar`: 40 tars, uno por versión de `corpus6/src-omega`, mismas rutas
  `omega-srep/...` en todos (como un tarball de release; `tar --format=gnu`).
- `omega-zip`: los mismos 40 árboles con `zip -r -X` (deflate); `omega-zip0`
  con `zip -0` (stored). Cada versión tiene el mtime de su commit, así que las
  cabeceras de los miembros sin cambios difieren en cada versión.
- Carpetas, el caso normal de zpaq-std: `src-omega` (40 versiones de
  fuentes), `mixed` (documentos, ejecutables, 10 docx, sin versiones).

## Resultados

### Tamaño del archivo, `-m1`, misma `-fragment N` (2^N KiB de media)

Bytes; `zpaq` es el binario baseline; las columnas siguientes, `-osrep` con
esos bits.

| entrada | N | zpaq | OSREP | TAR_AFTER (2) | TAR (3) | ZIP (12) | **42** | 42 vs OSREP | 42 vs zpaq |
|---|---|---|---|---|---|---|---|---|---|
| versions.tar | 3 | 9.835.635 | 7.702.358 | 7.702.358 | 7.703.922 | 7.702.358 | **7.702.358** | 0 % | −21,7 % |
| versions.tar | 6 | 15.293.575 | 13.082.651 | 8.252.147 | 8.073.383 | 13.082.651 | **8.252.147** | −36,9 % | −46,0 % |
| pja.tar | 3 | 1.767.855 | 1.792.804 | 1.792.804 | 1.793.764 | 1.792.804 | **1.792.835** | 0 % | +1,4 % |
| pja.tar | 6 | 2.817.689 | 2.421.693 | 1.755.470 | 1.756.597 | 2.421.693 | **1.755.470** | −27,5 % | −37,7 % |
| omega-tar | 3 | 2.225.773 | 1.622.113 | 1.622.113 | 1.593.306 | 1.622.113 | **1.622.314** | 0 % | −27,1 % |
| omega-tar | 6 | 2.786.183 | 2.588.916 | 1.658.337 | 1.627.028 | 2.588.916 | **1.658.342** | −35,9 % | −40,5 % |
| omega-zip | 3 | 14.389.091 | 15.162.731 | 15.162.731 | 15.162.731 | 4.675.589 | **4.863.189** | −67,9 % | −66,2 % |
| omega-zip | 6 | 14.132.590 | 14.162.841 | 14.162.841 | 14.162.841 | 4.660.446 | **4.851.485** | −65,7 % | −65,7 % |
| omega-zip0 | 3 | 1.918.604 | 1.901.013 | 1.901.013 | 1.901.013 | 1.617.875 | **1.598.121** | −15,9 % | −16,7 % |
| omega-zip0 | 6 | 2.665.519 | 2.618.565 | 2.618.565 | 2.618.565 | 1.595.096 | **1.572.920** | −39,9 % | −41,0 % |
| src-omega | 3 | 1.623.790 | 1.623.167 | 1.623.167 | 1.623.167 | 1.623.167 | **1.623.167** | 0 % | 0 % |
| src-omega | 6 | 1.581.836 | 1.583.931 | 1.583.931 | 1.583.931 | 1.583.931 | **1.583.931** | 0 % | +0,1 % |
| mixed | 3 | 86.540.701 | 86.943.499 | 86.943.499 | 86.943.499 | 86.965.211 | **87.174.238** | +0,27 % | +0,73 % |
| mixed | 6 | 86.343.335 | 86.420.052 | 86.420.052 | 86.420.052 | 86.448.459 | **86.450.577** | +0,04 % | +0,12 % |

(`15` = TAR+ZIP con `CUT_BACK` da lo mismo que 3 en los tars y que 12 en los
zips y en `mixed`; está en `bench-formataware-m1.tsv`.)

### A igual tamaño medio de fragmento

Las reglas añaden cortes, así que bajan la media. Comparación a media
parecida con `frag_stats` (bytes únicos + índice estimado de 24 B por
fragmento único y 4 B por referencia; tabla completa en
`frag-stats-formataware.tsv`):

| entrada | reglas (media) | total | CDC solo (media) | total | zpaq (media) | total |
|---|---|---|---|---|---|---|
| versions.tar | TAR N=6 (11,7 K) | 39,97 MB | N=4 (12,0 K) | 51,34 MB | N=3 (9,2 K) | 53,39 MB |
| versions.tar | TAR N=3 (5,6 K) | 35,59 MB | N=3 (6,0 K) | 35,66 MB | N=2 (4,4 K) | 45,74 MB |
| pja.tar | TAR N=6 (11,5 K) | 9,06 MB | N=4 (11,7 K) | 13,20 MB | N=3 (8,7 K) | 13,51 MB |
| omega-tar | TAR N=3 (2,9 K) | 16,59 MB | N=3 (3,2 K) | 17,10 MB | N=1 (2,1 K) | 21,34 MB |
| omega-zip | 40 N=3 (1,3 K) | 5,63 MB | N=0 (1,1 K) | 10,15 MB | N=0 (1,0 K) | 9,69 MB |
| omega-zip0 | 40 N=3 (2,8 K) | 9,97 MB | N=1 (2,1 K) | 19,80 MB | N=1 (2,1 K) | 18,43 MB |

- **Zip:** −42 % a −50 % a igual media. Ningún tamaño de fragmento del CDC
  solo se acerca: la cabecera local de cada miembro cambia en cada versión
  (mtime) y se queda pegada al principio de los datos.
- **Tar con N=3:** neutro. El FNV de 48 bytes da 0 tras 48 ceros seguidos, y
  con un mínimo de 512 corta en el relleno de ceros tras los datos de cada
  miembro y en la cola de ceros de cada cabecera. El CDC solo ya se alinea con
  el tar. Por eso `TAR_AFTER` deja el archivo idéntico en N=3.
- **Tar con N≥4:** con mínimo 1–4 KiB esos ceros ya no cortan y las reglas
  ganan un 22–31 % a igual media. Valen para quien use `-osrep -fragment 6`:
  `versions.tar` queda un 7 % mayor que con N=3 (8,25 MB frente a 7,70 MB)
  pero con un tercio de los fragmentos (7.786 frente a 21.613), en vez de un
  70 % mayor sin las reglas.

### `-m5` en `pja.tar`

| fragmentador | N | archivo | tiempo | RSS |
|---|---|---|---|---|
| zpaq | 3 | 1.006.299 | 41,4 s | 445 MB |
| zpaq | 6 | 971.248 | 64,5 s | 652 MB |
| OSREP | 3 | 1.045.784 | 21,5 s | 323 MB |
| OSREP | 6 | 987.353 | 57,2 s | 648 MB |
| OSREP + TAR | 3 | 1.048.021 | 24,9 s | 322 MB |
| OSREP + TAR | 6 | 1.019.522 | 22,8 s | 413 MB |

Con `-m5` el modelo encuentra la redundancia dentro del bloque y el índice de
los fragmentos pequeños pesa: las reglas no arreglan la pérdida de `-m5` en
PJA (+5 % frente a zpaq N=6), pero en N=6 la consiguen con 2,8 veces menos
tiempo y 37 % menos RSS.

### Velocidad

Corte + SHA-1, un hilo, `frag_stats`, mediana de 3 (N=3):

| entrada | zpaq | OSREP | 42 | 15 (con `CUT_BACK`) |
|---|---|---|---|---|
| versions.tar (130,5 MB) | 1,41 s | 2,85 s | 3,30 s (+16 %) | 3,51 s (+23 %) |
| omega-zip (18 MB) | 0,23 s | 0,46 s | 0,45 s | 0,51 s |
| mixed (175 MB) | 1,94 s | 3,76 s | 4,42 s (+18 %) | 4,76 s (+27 %) |

zpaq-std `a -m1` entero, mediana de 3 (hilos por defecto):
`versions.tar` N=6 0,80 s (zpaq), 0,84 s (OSREP), 0,83 s (OSREP + 15);
`omega-zip` N=3 0,20 / 0,45 / 0,70 s; `omega-tar` N=3 0,61 / 1,35 / 1,63 s.
RSS máximo: `versions.tar` N=6 548 / 478 / 351 MB. En una
carpeta de archivos de menos de 4 MB (sin `-turbo`) el lazo en línea de
`-osrep` va byte a byte y es la parte lenta, con o sin reglas.

## Lo que no sirve

- **`TEXT`.** En texto es neutro (dos `zpaq-std.cpp` consecutivos: 53.699
  bytes nuevos sin la regla, 53.721 con ella). Dentro de un tar empeora hasta
  un 29 % (`omega-tar`, N=3): el hash dispara en los ceros del relleno, la regla espera un `\n`
  hasta 256 bytes y corta en medio de la cabecera siguiente, que ya no se
  reconoce.
- **`CUT_BACK`** (`TAR_BEFORE`, `ZIP_BEFORE`). Mejor en algunos casos
  (`omega-zip` −3,9 %, `omega-tar` N=3 −1,8 %, `mixed` −0,24 %) y peor en
  otros (`omega-zip0` +1,2 %). No compensa: hay que tocar `add2_scan`, el lazo
  en línea y el `add()` antiguo, y `TAR_BEFORE` decide sin checksum.
- **Carpetas.** En el caso normal de zpaq-std (añadir carpetas) cada archivo
  ya es un corte. Las reglas solo actúan dentro de tars, zips, docx, jar, etc.
  En `src-omega` los cortes son idénticos y en `mixed` (sin versiones) cuesta
  entre +0,04 % y +0,27 %: la estimación de redundancia por fragmento de zpaq
  (`hits`, `o1`) cambia un poco las decisiones de bloque.

## Reproducir

```sh
bash tests/fragment_format.sh
cc -O2 -std=c99 -Isrc/c src/c/osrep_sha1.c src/c/osrep_fragment.c \
   tools/zpaq-vectors/frag_stats.c -o frag_stats
find DIR -type f | sort | ./frag_stats osrep 3 42
# zpaq-std 2.7.2 + tools/zpaq-vectors/formataware-prototype.patch, con los
# osrep_fragment.[ch] de esta rama en compressors/osrep/:
tools/zpaq-vectors/bench_formataware.py --baseline BASE --patched PATCHED \
    --input versions.tar --input DIR --method=-m1 --fragments 3,6 \
    --flags 0,2,40,42 --threads-check --workdir WORK
```

Datos crudos: `tools/zpaq-vectors/bench-formataware-{m1,m5,time}.tsv` y
`frag-stats-formataware.tsv`.
