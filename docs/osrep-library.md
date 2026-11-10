# OSREP como librería para proyectos externos

**Estado: diseño, 2026-11-10.** OSREP hoy es un CLI. La dirección que se
quiere es **library-first**: el núcleo es una librería con ABI C, y el CLI es
un cliente más. Este documento fija la API, el empaquetado y el orden de
integración, usando **PJA** y la familia **pack** como primeros consumidores.

## 0. Por qué

OSREP es un preprocesador/dedup, no un compresor final. Los proyectos que
pueden aprovecharlo ya existen y tienen interfaces parecidas:

| proyecto | licencia | API/artefacto | cómo lo usa un tercero |
|---|---|---|---|
| **PJA** | MIT | `pja.so`/`pja.dll`/`pja.dylib`, `pja.h`, `test_lib.c` | `pja_compress`/`pja_decompress`, filtros con callbacks, plugin 7-Zip y codecs zpaq-std |
| **packPNG** | MIT | `libpackpng`, `packpng.h` | `packpng_compress_mem`/`decompress_mem`, file, threads, `last_error` |
| **packJPG** | LGPL-3.0 | `packJPG.so`/`.dll`/`.a`, `packjpglib.h` | 6 símbolos: `pjglib_init_streams`, `convert_*`, `version_info`, `short_name` |
| **packMP3** | LGPL-3.0 | `libpackMP3.so`/`.dll`/`.a`, `packmp3dll.h` | 6 símbolos: `pmplib_*`, mismos tipos 0/1/2 (archivo/memoria/FILE*) |
| **packPNM/packRAW** | LGPL-3.0 | librería/CLI | misma familia |
| **zpaq-std** | MIT | CLI/archivador | dedup por fragmentos (ver `docs/zpaq-dedup-study.md`) |

PJA es el mejor modelo para OSREP: mismo lenguaje (Free Pascal + C + asm),
misma licencia, misma idea de una librería que también es un codec de
archivador. packPNG muestra la API moderna; packJPG/packMP3 muestran la API
de 6 símbolos que ya usan sus consumidores.

## 1. Principios

1. **El núcleo no depende del CLI.** El parser de opciones, los textos y el
   progreso quedan en el cliente; la librería recibe opciones tipadas.
2. **ABI C estable.** `extern "C"`, `cdecl` (`OSREP_CALL` en Win32), tipos de
   ancho fijo, ningún `AnsiString`/objeto Pascal cruzando la frontera.
3. **Sin estado global.** Cada llamada recibe su contexto/opciones; el error
   es thread-local. Se puede llamar desde varios hilos a la vez.
4. **Memoria del llamador o de la librería, explícita.** Las funciones que
   devuelven buffers usan `osrep_free`; las que escriben en un buffer del
   llamador piden `osrep_compress_bound`/`osrep_decompress_bound`.
5. **Ninguna excepción escapa.** Cada export atrapa y devuelve un código de
   error; el detalle queda en `osrep_last_error()` (thread-local).
6. **El formato no cambia.** La librería escribe/lee el v6 de la spec; no
   introduce un contenedor nuevo.
7. **MIT.** La librería es MIT; los hosts LGPL (packJPG/packMP3/packPNM)
   pueden linkearla (dinámico es lo simple; estático tiene las obligaciones
   de LGPL).

## 2. API propuesta (`osrep.h`)

Modelo PJA/packPNG: versión, memoria, archivo, callbacks y opciones.

```c
#ifndef OSREP_H
#define OSREP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define OSREP_CALL __cdecl
#else
#define OSREP_CALL
#endif

#define OSREP_API_VERSION 1

enum {
    OSREP_OK = 0,
    OSREP_E_DATA = 1,       /* archivo dañado o no es .osr v6 */
    OSREP_E_MEMORY = 2,     /* sin memoria, o sobre el límite */
    OSREP_E_IO = 3,         /* falló una lectura/escritura */
    OSREP_E_ARG = 4,        /* puntero nulo, opción inválida */
    OSREP_E_VERSION = 5,    /* escrito por una versión más nueva */
    OSREP_E_NOT_TAKEN = 6,  /* el input no es algo que OSREP tome */
    OSREP_E_UNSUPPORTED = 7 /* opción/modo no implementado todavía */
};

typedef struct osrep_options {
    uint32_t struct_size;   /* sizeof(osrep_options), para compatibilidad */
    int32_t  method;        /* 0..5; -1 = default (m3) */
    int32_t  format;        /* 6 = v6; 0 = default */
    int32_t  dedup;         /* 0/1; -1 = default */
    int32_t  threads;       /* 0 = auto, 1 = un hilo */
    uint64_t seed;          /* 0 = aleatorio; != 0 = determinista */
    uint64_t block_size;    /* 0 = default (8 MiB) */
    uint64_t max_output;    /* 0 = sin límite adicional al descomprimir */
    uint32_t reserved[8];   /* debe ir en cero */
} osrep_options;

void OSREP_CALL osrep_options_default(osrep_options *o);

const char *OSREP_CALL osrep_version(void);       /* "osrep 0.0.x" */
const char *OSREP_CALL osrep_last_error(void);    /* thread-local */

/* Memoria: *out lo libera el llamador con osrep_free. */
int OSREP_CALL osrep_compress(const void *in, size_t in_size,
                              void **out, size_t *out_size,
                              const osrep_options *o);
int OSREP_CALL osrep_decompress(const void *in, size_t in_size,
                                void **out, size_t *out_size,
                                const osrep_options *o);

/* Sin asignar: el llamador pone el buffer. Devuelve el tamaño necesario. */
size_t OSREP_CALL osrep_compress_bound(size_t in_size, const osrep_options *o);
int OSREP_CALL osrep_compress_into(const void *in, size_t in_size,
                                   void *out, size_t out_cap, size_t *out_size,
                                   const osrep_options *o);

/* Archivo: mismos códigos; el path es UTF-8 en todas las plataformas. */
int OSREP_CALL osrep_compress_file(const char *in_path, const char *out_path,
                                   const osrep_options *o);
int OSREP_CALL osrep_decompress_file(const char *in_path, const char *out_path,
                                     const osrep_options *o);

/* Filtro/stream: para archivers que pasan un bloque sólido. */
typedef ptrdiff_t (OSREP_CALL *osrep_read_fn)(void *ctx, void *buf, size_t size);
typedef int       (OSREP_CALL *osrep_write_fn)(void *ctx, const void *buf, size_t size);
int OSREP_CALL osrep_filter_encode(osrep_read_fn read, void *read_ctx,
                                   osrep_write_fn write, void *write_ctx,
                                   const osrep_options *o);
int OSREP_CALL osrep_filter_decode(osrep_read_fn read, void *read_ctx,
                                   osrep_write_fn write, void *write_ctx,
                                   const osrep_options *o);

void OSREP_CALL osrep_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
```

### 2.1 Modo fragmentador/dedup (para zpaq-std y packs)

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

### 2.2 Compatibilidad con la API de pack (opcional)

Para que packJPG/packMP3 no tengan que reescribir su capa de glue, se puede
ofrecer un `osrep_compat.h` con la forma de 6 símbolos:

```c
void        osrep_init_streams(void *in_src, int in_type, int in_size,
                               void *out_dest, int out_type);
bool        osrep_convert_stream2stream(char *msg);
bool        osrep_convert_file2file(char *in, char *out, char *msg);
bool        osrep_convert_stream2mem(unsigned char **out, unsigned int *size, char *msg);
const char *osrep_version_info(void);
const char *osrep_short_name(void);
```

Es una capa fina sobre la API de contexto; existe solo para los hosts que ya
tienen esa forma. La API recomendada sigue siendo la de §2.

## 3. Empaquetado y build

Modelo `libpja` (`pas/lib/build.sh`, `pjalib.pas`, `pja.h`, `test_lib.c`):

- `src/lib/osrep_lib.pas` es un `library` de FPC con `exports` y
  `IsMultiThread := True`; cada export atrapa excepciones.
- Los `.c`/`.asm` del núcleo se compilan por target con `-fPIC` y se enlazan.
- Artefactos:
  - `libosrep.so` (Linux), `libosrep.dylib` (macOS), `osrep.dll` (Windows);
  - `libosrep.a` estática;
  - `include/osrep.h`, `include/osrep_compat.h`;
  - `osrep.pc` (pkg-config) y `osrep-config.cmake`;
  - `test_lib.c` y ejemplos.
- Targets: Linux x86_64/i386/ARM64, Windows x86/x64, macOS ARM64 (los mismos
  del build actual). macOS en CI; Windows con el cruce FPC + mingw.
- Windows x86: `OSREP_CALL` = `__cdecl`, como PJA; el `.dll` no debe depender
  de un runtime C++ (PJA ya lo hace).
- ABI: `OSREP_API_VERSION`, versión semver; los símbolos nuevos se agregan,
  los existentes no cambian de firma. `osrep_options.struct_size` y
  `reserved` para crecer sin romper.
- Hilos: cada llamada es independiente; `osrep_last_error` es thread-local;
  `IsMultiThread` en la inicialización de la librería.
- Memoria: `osrep_free` para los buffers que devuelve; `osrep_compress_into`
  para el que pone el llamador.

## 4. Integración con los proyectos

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

### 4.2 packPNG (MIT)

Es el más fácil de los packs: API moderna (`packpng_compress_mem`,
`packpng_decompress_mem`, `packpng_free`, `packpng_last_error`) y licencia
MIT. OSREP puede linkearse y usarse como segunda etapa del `.ppg` o de los
payloads; un backend nuevo de `.ppg` sería una extensión de formato, no un
cambio silencioso.

### 4.3 packJPG / packMP3 / packPNM (LGPL-3.0)

- La API de 6 símbolos ya está pensada para consumidores externos; OSREP
  puede ofrecer `osrep_compat.h` con la misma forma.
- Linkeo **dinámico** con `libosrep.so`/`.dll` es lo simple; el linkeo
  estático queda sujeto a las obligaciones de LGPL (poder re-linkear).
- Los formatos `.pjg`, `.mp3`/`.mp2`, `.pnm` están congelados: OSREP entra
  como una etapa opcional de una versión nueva o como preprocesador de los
  datos embebidos (packMP3 ya usa packJPG/packPNG para las carátulas), no
  cambiando el formato actual.
- packMP3 ya tiene `INTEGRATION-PMPLIB.md`; es el modelo de cómo documentar
  la integración de OSREP para los packs.

### 4.4 zpaq-std (MIT)

No usa el contenedor `.osr`: usa el modo fragmentador/dedup de §2.1. El
estudio `docs/zpaq-dedup-study.md` fija el plan: primero el fragmentador
exacto de zpaq (mismos fragmentos/SHA-1), después el CDC de OSREP como modo.

## 5. Plan por fases

### L0 — Librería mínima (1–2 semanas)

- Extraer el núcleo del CLI a unidades con una API Pascal limpia.
- `include/osrep.h`; `osrep_version`, `osrep_compress`, `osrep_decompress`,
  `osrep_free`, `osrep_last_error`, `osrep_options_default`.
- `src/lib/osrep_lib.pas` (`library`), build Linux x86_64, `test_lib.c`.
- Probar desde un programa C y desde PJA (unidad Pascal o `libosrep.so`).

**Aceptación:** un programa C comprime y descomprime el corpus, byte a byte;
el `.osr` es idéntico al del CLI; `test_lib.c` pasa; no hay fugas.

### L1 — API completa (2–3 semanas)

- `compress_file`/`decompress_file`, `filter_encode`/`filter_decode`,
  `compress_into`/`compress_bound`, opciones/threads/seed.
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
- packPNG: demo de segunda etapa; documentar.
- packJPG/packMP3: `osrep_compat.h` y demo de linkeo dinámico; sin tocar
  los formatos actuales.
- Ejemplos, docs, CI de la librería.

### L4 — ABI 1.0

- Congelar la API; release 1.0 de `libosrep`; el CLI y los hosts ya la usan.

## 6. Pruebas

- `test_lib.c` estilo PJA: memoria, archivo, callbacks, errores, límites,
  hilos, `osrep_free`.
- Diferencial: el `.osr` de la librería == el del CLI, byte a byte, en el
  corpus y en los fixtures.
- ABI: `nm -D`/`dumpbin` de los símbolos; cargar con `dlopen`; versión.
- Fuzz del decoder a través de la API; entradas dañadas; `max_output`.
- Matriz de plataformas y CI (Linux, Windows/wine, macOS Actions).
- Packs: demo de round-trip y medición, sin cambiar los formatos.

## 7. Riesgos

| riesgo | mitigación |
|---|---|
| ABI/RTL de FPC en una librería | copiar el patrón de `libpja`; `IsMultiThread`; exports; test_lib.c |
| Excepciones que cruzan la frontera | cada export atrapa y devuelve código; `last_error` |
| Hilos | estado por llamada; thread-local; probar concurrencia |
| Windows x86 / macOS | mismo build cruzado que PJA; CI macOS |
| Formatos de los packs congelados | no cambiarlos; etapa opcional/versión nueva |
| LGPL de packJPG/packMP3 | linkeo dinámico; documentar obligaciones |
| ABI inestable | `struct_size`, `reserved`, semver, ABI 1.0 al final |
| Rendimiento | la librería no agrega copias; `compress_into`; medir |

## 8. Recomendación

**Hacer `libosrep` ahora, antes de más funciones del CLI.** El CLI pasa a ser
un cliente de la librería. Empezar por L0 (memoria + v6 + `test_lib.c`) y
usar **PJA** como primer consumidor, porque comparte lenguaje, licencia y
patrón de build. Después packPNG (MIT), luego packJPG/packMP3 con la capa de
compatibilidad y linkeo dinámico, y zpaq-std con el modo fragmentador.

La API de PJA (`pja.h`) es la plantilla; la de packPNG muestra el estilo
moderno; la de packJPG/packMP3 muestra la compatibilidad que hay que ofrecer.
No se toca ningún formato de los packs en esta etapa: primero se mide y se
prueba el valor de OSREP como segunda etapa.
