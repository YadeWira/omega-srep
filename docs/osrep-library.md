# OSREP como librería para proyectos externos

**Estado: L0 implementado, 2026-11-10.** La dirección es **library-first**:
el núcleo es `libosrep` con ABI C, y el CLI es un cliente del mismo núcleo.
L0 está en el árbol: `include/osrep.h`, `src/lib/osrep_lib.pas`,
`src/lib/osrep7z.c` (el plugin de 7-Zip), `src/lib/build.sh`,
`src/lib/test_lib.c`, `tests/lib.sh` y `tests/lib_7z.sh`. Este documento
fija la API, el empaquetado y el orden de integración, usando **PJA, PMPA,
PRA, PPA y PAIA** como primeros consumidores. PJA (`libpja`) es el modelo,
por veterano y por compartir FPC + C + asm y licencia MIT. Los proyectos
`pack*` **no son la familia**: son sus predecesores ("Successor of" en las
tablas de la familia) y solo aparecen aquí como historia de la API.

## 0. Por qué

OSREP es un preprocesador/dedup, no un compresor final. Los proyectos que
pueden aprovecharlo ya existen y tienen interfaces parecidas:

La familia actual, según la tabla "Sibling | Formats | Successor of" de
PJA, PMPA, PRA, PPA y PAIA:

| proyecto | formatos | Successor of | licencia | artefacto hoy |
|---|---|---|---|---|
| **PJA** | JPEG, JPEG-LS, JPEG 2000 | packJPG | MIT | `libpja`: `pja.so`/`.dll`/`.dylib`, `pja.h`, `test_lib.c`, plugin 7-Zip y codecs zpaq-std |
| **PMPA** | MPEG audio (MP1, MP2, MP3) | packMP3, packMP2 | MIT | CLI; todavía sin librería propia; vendoriza PJA |
| **PRA** | raster (PNM, BMP, TIFF, PSD, HDR, ...) | packPNM | MIT | CLI; todavía sin librería propia |
| **PPA** | familia PNG (PNG, APNG, MNG, JNG) | packPNG | MIT | `libppa`: `ppa.so`/`.dll`/`.dylib`, `ppa.h`, plugin 7-Zip |
| **PAIA** | imágenes animadas (GIF, WebP, FLI/FLC, ANI, IFF ANIM) | (nuevo) | MIT | plugin de zpaq-std (`paia.so`); sin librería C general todavía |

Fuera de la familia, pero relevantes:

| proyecto | papel | licencia |
|---|---|---|
| **zpaq-std** | archivador; dedup por fragmentos (ver `docs/zpaq-dedup-study.md`) | MIT |
| **packJPG** | predecesor de PJA | LGPL-3.0 |
| **packMP3**, **packMP2** | predecesores de PMPA | LGPL-3.0 |
| **packPNG** | predecesor de PPA | MIT |
| **packPNM** | predecesor de PRA | LGPL-3.0 |

PJA es el mejor modelo para OSREP: mismo lenguaje (Free Pascal + C + asm),
misma licencia, y ya tiene `libpja` con `pja.h`, `test_lib.c`, filtro y
plugin. PPA confirma que el patrón se repite (`libppa`, `ppa.h`). PMPA, PRA y
PAIA son consumidores naturales, aunque sus librerías aún no existan. Los
`pack*` no se integran: son los predecesores que la familia reemplaza.

## 1. Principios

1. **El núcleo no depende del CLI.** El parser de opciones, los textos y el
   progreso quedan en el cliente; la librería recibe opciones tipadas.
2. **ABI C estable.** `extern "C"`, `cdecl` (`OSREP_CALL` en Win32), tipos de
   ancho fijo, ningún `AnsiString`/objeto Pascal cruzando la frontera.
3. **Sin estado global.** Cada llamada recibe su contexto/opciones; el error
   es thread-local. Se puede llamar desde varios hilos a la vez.
4. **Memoria del llamador o de la librería, explícita.** Las funciones que
   devuelven buffers usan `osrep_free`; L1 agrega
   `osrep_compress_bound`/`osrep_compress_into` para el buffer del llamador.
5. **Ninguna excepción escapa.** Cada export atrapa y devuelve un código de
   error; el detalle queda en `osrep_last_error()` (thread-local).
6. **El formato no cambia.** La librería escribe/lee el v6 de la spec; no
   introduce un contenedor nuevo.
7. **MIT.** La librería es MIT, igual que PJA, PMPA, PRA, PPA, PAIA y
   zpaq-std, así que con la familia no hay fricción de licencia. Los
   predecesores `pack*` son LGPL-3.0 (salvo packPNG, MIT); solo importan si
   alguna vez se usan como host, y ahí el linkeo dinámico es lo simple.

## 2. API de L0 (`osrep.h`)

El header normativo es `include/osrep.h`; esto es lo que exporta la librería
hoy. Modelo `libpja`: versión, memoria, opciones y `osrep_free`.

```c
#define OSREP_API_VERSION 1

enum {
    OSREP_OK = 0,
    OSREP_E_DATA = 1,        /* dañado, truncado o no es OSR6 */
    OSREP_E_MEMORY = 2,      /* sin memoria, o sobre max_output */
    OSREP_E_IO = 3,          /* falló una lectura/escritura */
    OSREP_E_ARG = 4,         /* puntero nulo u opción inválida */
    OSREP_E_VERSION = 5,     /* escrito por una versión más nueva */
    OSREP_E_NOT_TAKEN = 6,   /* reservado: OSREP toma cualquier byte */
    OSREP_E_UNSUPPORTED = 7  /* opción o método no implementado */
};

typedef struct osrep_options {
    uint32_t struct_size;   /* sizeof(osrep_options), o 0 */
    int32_t  method;        /* 0 = default, 3 = -m3 */
    int32_t  format;        /* 0 = default, 6 = v6 */
    int32_t  dedup;         /* 0; 1 aún no se escribe (E_UNSUPPORTED) */
    int32_t  threads;       /* aceptado; el encoder MVP es de un hilo */
    uint64_t seed;          /* 0 = default determinista; si no, esa semilla */
    uint64_t block_size;    /* 0 = 8 MiB */
    uint64_t max_output;    /* descompresión: 0 = sin tope extra */
    int32_t  min_match;     /* 0 = 4 */
    int32_t  chain_depth;   /* 0 = 16 */
    int32_t  stride;        /* 0 = 1 */
    int32_t  digest;        /* -1 = default, 0 = ninguno (-hash-) */
    uint32_t reserved[8];   /* debe ir en cero */
} osrep_options;

void OSREP_CALL osrep_options_default(osrep_options *o);
const char *OSREP_CALL osrep_version(void);       /* "OSREP 0.0.2" */
const char *OSREP_CALL osrep_last_error(void);    /* thread-local */

int OSREP_CALL osrep_compress(const void *in, size_t in_size,
                              void **out, size_t *out_size,
                              const osrep_options *o);
int OSREP_CALL osrep_decompress(const void *in, size_t in_size,
                                void **out, size_t *out_size,
                                const osrep_options *o);

int OSREP_CALL osrep_compress_file(const char *in_path, const char *out_path,
                                   const osrep_options *o);
int OSREP_CALL osrep_decompress_file(const char *in_path, const char *out_path,
                                     const osrep_options *o);
void OSREP_CALL osrep_free(void *p);
```

`osrep_options_default()` llena los mismos valores que `osrep -m3`: bloques
de 8 MiB, mínimo 4, cadena 16, stride 1, digest VHASH-128 y la semilla
determinista 0. **No** hay semilla aleatoria: `seed=0` es el default
determinista, y cualquier otro valor se expande con `SeedFromNumber`, igual
que `--seed=N` en el CLI. `max_output` se comprueba contra el `origsize` del
header antes de reservar la salida y, en un archivo `-dup`, también contra el
tamaño final mientras se reconstruye (el `origsize` de un `-dup` es el cuerpo
deduplicado, no la entrada restaurada). `struct_size` puede ser 0 o el tamaño
actual; un tamaño distinto devuelve `OSREP_E_ARG`.

`osrep_compress_file`/`osrep_decompress_file` usan el mismo núcleo que las
funciones de memoria. L1 agrega `osrep_compress_bound`,
`osrep_compress_into` y los filtros por callbacks
(`osrep_filter_encode`/`decode`). El ABI no cambia: solo se suman símbolos.

### 2.1 Modo fragmentador/dedup (zpaq-std y hosts que lo quieran)

Además del archivo v6, la librería puede exponer la etapa que zpaq-std
necesita (ver `docs/zpaq-dedup-study.md`):

```c
typedef struct osrep_frag {
    uint64_t off;        /* offset en el buffer de entrada */
    uint32_t size;
    uint8_t  sha1[20];
    uint32_t hits;       /* predictor de orden 1, para el data-type analysis */
    uint8_t  o1[256];
} osrep_frag;

typedef struct osrep_frag_params {
    int32_t  mode;       /* 0 = exacto zpaq, 1 = CDC de OSREP */
    int32_t  fragment;   /* log2, como -fragment de zpaq (6 = ~64 KiB) */
    uint32_t min, max;   /* 0 = derivados de fragment */
} osrep_frag_params;

int OSREP_CALL osrep_fragment_buffer(const void *buf, size_t len,
                                     const osrep_frag_params *p,
                                     osrep_frag **out, size_t *out_n);
void OSREP_CALL osrep_sha1(const void *buf, size_t len, uint8_t out[20]);
```

Esto es lo que se enchufa en zpaq-std (`fragment_buffer`/`add2` y el lazo de
`add()`) y lo que puede usar cualquier host que quiera dedup por fragmentos
sin adoptar el contenedor `.osr`.

### 2.2 Compatibilidad con los predecesores pack (opcional)

Los `pack*` no son la familia ni el objetivo de la integración. Si alguna vez
se usan como host (o se quiere comparar con su API), se puede ofrecer un
`osrep_compat.h` con la forma de 6 símbolos:

```c
void        osrep_init_streams(void *in_src, int in_type, int in_size,
                               void *out_dest, int out_type);
bool        osrep_convert_stream2stream(char *msg);
bool        osrep_convert_file2file(char *in, char *out, char *msg);
bool        osrep_convert_stream2mem(unsigned char **out, unsigned int *size, char *msg);
const char *osrep_version_info(void);
const char *osrep_short_name(void);
```

Es una capa fina sobre la API de contexto; existe solo para esos hosts
históricos. La API recomendada sigue siendo la de §2, y la familia
(PJA/PMPA/PRA/PPA/PAIA) no la necesita.

## 3. Empaquetado y build

Modelo `libpja` (`pas/lib/build.sh`, `pjalib.pas`, `pja.h`, `test_lib.c`).

**L0, en el árbol:**

- `src/lib/osrep_lib.pas` es un `library` de FPC con `exports`,
  `IsMultiThread := True` y `threadvar` para `osrep_last_error`; cada export
  atrapa excepciones. `src/pascal/osrep_codec.pas` es la API Pascal limpia
  que usan la librería y, más adelante, el CLI.
- Artefactos: `libosrep.so` (Linux); `include/osrep.h`; `src/lib/test_lib.c`;
  `tests/lib.sh`. `src/lib/osrep7z.c` compila dentro del mismo `.so` y
  exporta las seis funciones de 7-Zip; `tests/lib_7z.sh` arma una copia
  privada de 7-Zip con el plugin en `Codecs/`. `src/lib/build.sh` detecta
  Windows/macOS igual que el de PJA, aunque L0 solo se probó en Linux
  x86_64.
- Build y prueba:

  ```sh
  src/lib/build.sh build/lib
  cc -O2 -Iinclude src/lib/test_lib.c -Lbuild/lib -losrep -o test_lib
  ./tests/lib.sh
  ./tests/lib_7z.sh
  ```

- Hilos: cada llamada es independiente; `osrep_last_error` es thread-local;
  `IsMultiThread` en la inicialización de la librería. El reader ya no tiene
  `FBlocks`/`FAllLiterals` globales: son campos de la instancia.
- Memoria: `osrep_free` para los buffers que devuelve la librería.

**L1, plan:**

- `libosrep.a` estática; `include/osrep_compat.h` (solo para los
  predecesores `pack*`, si alguna vez se usan como host).
- `osrep.pc` (pkg-config) y `osrep-config.cmake`.
- Targets Linux x86_64/i386/ARM64, Windows x86/x64, macOS ARM64 (los mismos
  del CLI). macOS en CI; Windows con el cruce FPC + mingw.
- Windows x86: `OSREP_CALL` = `__cdecl`, como PJA; el `.dll` no debe depender
  de un runtime C++ (PJA ya lo hace).
- ABI: `OSREP_API_VERSION`, versión semver; los símbolos nuevos se agregan,
  los existentes no cambian de firma. `osrep_options.struct_size` y
  `reserved` para crecer sin romper.
- `osrep_compress_into` para el buffer del llamador; hilos reales en el
  encoder.

## 4. Integración con los proyectos

### 4.0 7-Zip / 7-Zip-zstd (prueba de la librería)

`libosrep.so` es también un codec de 7-Zip, como `pja.so`: el método
`OSREP`, ID experimental `03 7F 03`. No es un compresor final; en el archivo
va delante del coder real:

```sh
7z a -m0=OSREP -m1=LZMA2 files.7z files/     # 7-Zip
7z a -m0=OSREP -m1=zstd  files.7z files/     # 7-Zip-zstd
7z x files.7z                                # necesita el plugin
```

El plugin toma el bloque sólido, llama a `osrep_compress` y entrega el
`.osr` al siguiente coder; al extraer, `osrep_decompress` hace el camino
inverso. L0 lee el bloque entero en memoria (el reader v6 necesita el
footer); L1 lo hará por streaming, sin cambiar el método ni el formato. `GetMethodProperty` publica `OSREP` y `CreateEncoder`/
`CreateDecoder` son el coder de un solo stream (`ICompressCoder`); acepta
`-mmt` con `ICompressSetCoderMt` aunque el encoder MVP siga siendo de un
hilo. Los errores se mapean a 7-Zip: datos dañados `S_FALSE` ("Data Error"),
versión nueva `E_NOTIMPL` ("Unsupported Method"), memoria `E_OUTOFMEMORY`.

`tests/lib_7z.sh` compila la librería, copia `7z`/`7z.so` a un directorio
privado, pone `libosrep.so` en `Codecs/` y comprueba, en **7-Zip 25.01** y
en **7-Zip-zstd 26.02** (este último con `SEVEN_ZSTD=<dir>` y también con
`-m1=zstd`): `7z i` lista
`37F03 OSREP`; `-m0=OSREP` solo; `-m0=OSREP -m1=LZMA2`; `7z t`; un archivo
con bloques sólidos de 1 MiB (`-ms=1m`) para probar varias llamadas al
plugin; todos los archivos vuelven byte a byte; un archivo dañado falla con
"Data Error". También mide el tamaño contra LZMA2 solo: en el corpus de
prueba, OSREP+LZMA2 quedó 830 bytes más chico, y OSREP+zstd fue más grande
que zstd solo (depende del corpus y del nivel; no es una promesa general).
Con bloques de 1 MiB el archivo crece (cada bloque lleva su header/footer y
su LZMA2), lo que confirma que el filtro se aplica por bloque. Es la primera
prueba de la librería en un archivador real. zpaq-std queda para después,
coordinado con su agente, porque ahí OSREP entra como fragmentador/dedup y
no como filtro de bloque.

### 4.1 PJA (primero)

PJA es el primer consumidor natural:

- mismo stack (FPC + C + asm), MIT, y ya tiene `libpja` con `pja.h` y
  `test_lib.c`; se puede copiar el patrón de build tal cual.
- Dos formas:
  1. **Enlace Pascal**: PJA importa las unidades de OSREP y usa la API
     Pascal (sin ABI C); es lo más simple para PJA y para un primer demo.
  2. **Librería C**: PJA linkea `libosrep` y usa `osrep.h`; sirve para
     probar la ABI que usarán los demás.
- Caso de uso: el stream de PJA (coeficientes JPEG) o el `.pja` completo pasa
  por OSREP como segunda etapa; medir tamaño/tiempo y round-trip. Después, un
  codec/filtro de OSREP para 7-Zip/zpaq-std, como el plugin de PJA.
- No se toca el formato `.pja` en el primer paso: es un experimento de
  tamaño/velocidad; un backend nuevo sería una versión de stream nueva.

### 4.2 PPA (MIT)

PPA ya tiene `libppa` con `ppa.h`, `ppa.so`/`.dll`/`.dylib`, filtro y plugin
de 7-Zip: es la prueba de que el patrón de `libpja` se repite en la familia.
OSREP puede probarse como segunda etapa del `.ppa` o de sus streams (medir
tamaño/tiempo y round-trip); un backend nuevo sería una versión de stream
nueva, no un cambio silencioso del `.ppa` actual.

### 4.3 PAIA (MIT)

PAIA ya es plugin de zpaq-std (`pas/plugin/paia_zpaqstd.pas`, `paia.so`) pero
todavía no tiene una librería C general. Es el primer miembro de la familia
que vive dentro de un archivador: el bloque que zpaq-std entrega al plugin se
puede medir con OSREP como preprocesado/dedup, sin adoptar el contenedor
`.osr`. Su stream cambia hasta 1.0.0; primero medir, después decidir.

### 4.4 PMPA y PRA (MIT)

Hoy son CLI sin librería propia. Son consumidores de la familia, pero no del
primer lote: cuando tengan `libpmpa`/`libpra` con el patrón de PJA/PPA, OSREP
podrá ser segunda etapa de sus streams. Mientras tanto, el consumo es por
CLI o por enlace Pascal interno, no por ABI C.

### 4.5 zpaq-std (MIT)

No usa el contenedor `.osr`: usa el modo fragmentador/dedup de §2.1. El
estudio `docs/zpaq-dedup-study.md` fija el plan: primero el fragmentador
exacto de zpaq (mismos fragmentos/SHA-1), después el CDC de OSREP como modo.

### 4.6 Los predecesores pack (no son la familia)

`packJPG`, `packMP3`/`packMP2`, `packPNG` y `packPNM` aparecen en la columna
"Successor of" de la familia, no en la familia. Sus formatos están congelados
y no se integran con OSREP en este plan: solo se conservan como referencia de
API (la forma de 6 símbolos de §2.2) y como historia. `packPNG` es MIT, los
demás LGPL-3.0; nada de esto afecta a `libosrep`, que es MIT y se linkea con
miembros MIT de la familia.

## 5. Plan por fases

### L0 — Librería mínima (hecho, 2026-11-10)

- Núcleo accesible por una API Pascal limpia: `src/pascal/osrep_codec.pas`.
- `include/osrep.h`; `osrep_version`, `osrep_compress`, `osrep_decompress`,
  `osrep_free`, `osrep_last_error`, `osrep_options_default`.
- `src/lib/osrep_lib.pas` (`library`), `src/lib/build.sh` (Linux `.so`;
  Windows/macOS por las mismas variables que PJA), `src/lib/test_lib.c`.
- El reader acepta un `TStream`, no solo un archivo: `DecodeToBytes` y
  `CreateFromStream`; `TArchiveReader` ya no usa estado global, así que dos
  hilos pueden descomprimir a la vez.

**Aceptación (cumplida):** un programa C comprime y descomprime el corpus,
byte a byte; el `.osr` es idéntico al del CLI con las mismas opciones
(inclusive `--seed=7`); `test_lib.c` pasa 64 checks y `tests/lib.sh` pasa
94 con el corpus; 4 hilos concurrentes pasan; los fixtures v6 y `-dup` se
leen desde la librería; `tests/lib_7z.sh` prueba `-m0=OSREP` y
`-m0=OSREP -m1=LZMA2` en 7-Zip 25.01 y 7-Zip-zstd 26.02 (también
`-m1=zstd`) con todos los archivos de vuelta. Compilar:

```sh
src/lib/build.sh build/lib
cc -O2 -Iinclude src/lib/test_lib.c -Lbuild/lib -losrep -o test_lib
./tests/lib.sh
./tests/lib_7z.sh
```

### L1 — API completa (2–3 semanas)

- `compress_file`/`decompress_file`, `filter_encode`/`filter_decode`,
  `compress_into`/`compress_bound`; hilos reales en el encoder.
- Estática y compartida; Windows x86/x64 y macOS ARM64; pkg-config/CMake.
- ABI: `nm` de símbolos, versión, `struct_size`, test de compatibilidad.
- Hilos: dos llamadas concurrentes; `last_error` por hilo.

**Aceptación:** la misma matriz de plataformas del CLI (Linux x86/x64/ARM64,
Windows x86/x64, macOS ARM64) compila y pasa `test_lib.c`; el CLI usa la
misma API (no hay dos caminos).

### L2 — Dedup/fragmentos (2–3 semanas)

- `osrep_fragment_buffer`/`osrep_sha1` en modo exacto zpaq y modo OSREP.
- Tests contra los vectores de zpaq-std (ver el estudio).
- zpaq-std puede linkear la librería; el CLI de zpaq-std no cambia.

### L3 — Primeros consumidores (2–3 semanas)

- PJA: demo de segunda etapa y, si funciona, filtro/codec.
- PPA: demo de segunda etapa con `libppa`; documentar.
- PAIA: medir el bloque del plugin de zpaq-std con OSREP.
- PMPA/PRA: enlace Pascal o CLI hasta que tengan librería propia.
- Ejemplos, docs, CI de la librería.

### L4 — ABI 1.0

- Congelar la API; release 1.0 de `libosrep`; el CLI y los hosts ya la usan.

## 6. Pruebas

- `test_lib.c` estilo PJA: memoria, errores, límites, hilos y `osrep_free`;
  ya cubre round-trip, determinismo, daño/truncado, `max_output`, 4 hilos y
  la identidad con el CLI. L1 suma archivo, callbacks y la ABI completa.
- Diferencial: el `.osr` de la librería == el del CLI, byte a byte, en el
  corpus y en los fixtures.
- ABI: `nm -D`/`dumpbin` de los símbolos; cargar con `dlopen`; versión.
- Fuzz del decoder a través de la API; entradas dañadas; `max_output`.
- Matriz de plataformas y CI (Linux, Windows/wine, macOS Actions).
- Familia: demo de round-trip y medición, sin cambiar los formatos.

## 7. Riesgos

| riesgo | mitigación |
|---|---|
| ABI/RTL de FPC en una librería | copiar el patrón de `libpja`; `IsMultiThread`; exports; test_lib.c |
| Excepciones que cruzan la frontera | cada export atrapa y devuelve código; `last_error` |
| Hilos | estado por llamada; thread-local; probar concurrencia |
| Windows x86 / macOS | mismo build cruzado que PJA; CI macOS |
| Formatos de la familia congelados (PJA desde 0.9.0; PPA/PAIA antes de 1.0) | no cambiarlos; segunda etapa opcional o versión nueva de stream |
| Licencias | toda la familia y zpaq-std son MIT; los `pack*` predecesores son LGPL y no se integran |
| ABI inestable | `struct_size`, `reserved`, semver, ABI 1.0 al final |
| Rendimiento | la librería no agrega copias; `compress_into`; medir |

## 8. Recomendación

**L0 ya está hecho.** El siguiente paso es L1 (archivo, callbacks, ABI
completa y las otras plataformas), y después usarlo desde PJA. El CLI pasa a
ser un cliente de la librería. Empezar por L0 (memoria + v6 + `test_lib.c`) y
usar **PJA** como primer consumidor, porque comparte lenguaje, licencia y
patrón de build. Después **PPA**, que ya tiene `libppa`; luego **PAIA** y, en
cuanto tengan librería, **PMPA** y **PRA**. zpaq-std entra por el modo
fragmentador. Los `pack*` quedan fuera: son los predecesores, no la familia.

La API de PJA (`pja.h`) es la plantilla y la de PPA (`ppa.h`) confirma el
patrón. No se toca ningún formato de la familia en esta etapa: primero se
mide y se prueba el valor de OSREP como segunda etapa.
