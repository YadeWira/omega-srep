# OSREP como motor de deduplicación de zpaq-std — estudio

**Estado: estudio, 2026-11-10.** No hay integración todavía. Este documento
lee el motor de deduplicación de **zpaq-std** y de **zpaqfranz** (del que
zpaq-std es un fork) y decide cómo encajaría **OSREP** como su motor de
deduplicación.

## 0. Qué es cada cosa (y qué no es)

- **SREP / SuperREP** (Bulat Ziganshin, 2009–2014) es un **preprocesador
  LZ77**, no un compresor completo: produce un stream de matches y literales
  que después un codificador entrópico/archivador comprime. SREP se usaba
  delante de FreeArc.
- **Omega SREP** (1.0–3.0.0) es el proyecto anterior: un port a Free Pascal de
  SREP, con contenedor propio (`.osr`, v4/v6), pero con el mismo rol de
  preprocesador. No es un archivador ni un codificador entrópico.
- **OSREP** es la reescritura clean-room de ese rol: preprocesador LZ77 y
  motor de deduplicación, con formato v6 propio. Tampoco es un compresor
  final; la compresión de verdad la hace un backend.
- **zpaq-std** es un **archivador multi-versión** (fork de zpaqfranz, que a su
  vez deriva de zpaq 7.15 de Matt Mahoney). Hace deduplicación a nivel de
  **fragmentos** y comprime los bloques de datos con ZPAQ (y los codecs
  `-ma` que agrega el fork).

La consecuencia importante: integrar OSREP en zpaq-std **no** es reemplazar
el compresor de zpaq-std. Es reemplazar la etapa que decide los fragmentos y
sus hashes, dejando que zpaq-std siga archivando, indexando y comprimiendo.

## 1. El motor de zpaq-std (y zpaqfranz)

Las dos fuentes son casi el mismo árbol; los números de línea cambian por el
código agregado en zpaq-std (codecs, JPEG, GUI), pero el motor de dedup es el
mismo. Referencias: `zpaq-std.cpp` y `zpaqfranz.cpp` del checkout local.

### 1.1 Fragmentación por contenido (CDC)

El corte no es fijo: es un rolling hash con un predictor de orden 1.

```
h = 0; c1 = 0; o1[256] = {0}      // por fragmento
por cada byte c:
    pred = o1[c1]
    h = (h + c + 1) * (c == pred ? 314159265 : 271828182)
    o1[c1] = c; c1 = c
    corte si h < (1 << (22 - fragment)) y tamaño >= MIN_FRAGMENT
    o si tamaño >= MAX_FRAGMENT
```

Parámetros (`zpaq-std.cpp:252655`, `zpaqfranz.cpp:265573`):

- `MIN_FRAGMENT = 64 << fragment` (con el tope de `MAX_FRAGMENT`);
- `MAX_FRAGMENT = 8128 << fragment` (recortado a `blocksize - 12`);
- umbral `1 << (22 - fragment)`;
- `fragment` por defecto **6**: mínimo 4 KiB, máximo 520.192 bytes, umbral
  65.536, promedio ~64 KiB. `-fragment N` va de 0 a 22; con `N > 22` no hay
  corte por contenido, solo por máximo.

El lazo está inline en `Jidac::add()` (`zpaq-std.cpp:251871`,
`zpaqfranz.cpp:264789`). Hay dos implementaciones paralelas con la misma
semántica:

- zpaq-std: `fragment_buffer()` (`zpaq-std.cpp:250299`) + `FrontFrag
  {sha1, size, hits, off, o1}`; la usa `add2()` en `zpaq-std.cpp:255315`.
  El comentario "NOT YET WIRED" quedó viejo: `add2` ya la usa.
- zpaqfranz: `add2_scan()` (`zpaqfranz.cpp:266994`) con la misma hash, los
  mismos cortes y el SHA-1 por fragmento.

`redu()` (`zpaq-std.cpp:202008`) repite el mismo CDC para estimar redundancia,
y `filelist_store()`/`sc_salva()` tienen un fragmentador aparte para la lista
de archivos (`ZPAQFILELIST_FRAGMENT`/`SC_FRAGMENT`), que no es el dedup de
datos.

### 1.2 Hash y decisión de duplicado

Cada fragmento se hashea con **SHA-1** (20 bytes). El índice es `HTIndex`
(`zpaq-std.cpp:169674`, `zpaqfranz.cpp:173244`):

- `hash(sha1) = primeros 32 bits & (t.size() - 1)`;
- tabla abierta con sondas lineales (`t[h ^ i]`);
- `find()` devuelve el índice del fragmento o 0;
- `update()` indexa los `HT` nuevos y crece la tabla.

La tabla global es `vector<HT> ht` (`zpaq-std.cpp:126105`,
`zpaqfranz.cpp:131753`):

```
struct HT {
    uint32_t crc32, crc32size;   // opcional, para -verify/-collision
    unsigned char sha1[20];
    int usize;                   // tamaño sin comprimir
    int64_t csize;               // >= 0: offset en un bloque; < 0: -fragmento
    double estimatedratio;
};
```

Flujo en `add()` (`zpaq-std.cpp:253156` y siguientes):

1. Fragmento nuevo: SHA-1, `htinv.find`.
2. Si `htptr != 0`, es duplicado: **no se vuelve a escribir**; el índice del
   archivo guarda ese ID de fragmento.
3. Si `htptr == 0`, se agrega a `ht`, se escribe en el bloque de datos `sb`,
   y el índice del archivo guarda el ID nuevo.
4. El bloque de datos se arma con los fragmentos nuevos + una lista de
   tamaños + un 0 terminador; después se comprime con el método de zpaq-std.
5. La tabla de fragmentos va en los bloques `h`; el índice de archivos
   (archivo → lista de fragmentos) en los bloques `i`; los datos en los
   bloques `d`.

El resultado es dedup **global al archivo y a todas las versiones**: un
fragmento idéntico en dos archivos o en dos snapshots se guarda una vez, y
cada archivo/versión solo referencia su ID. La extracción lee `i`/`h`, busca
los fragmentos y descomprime los bloques `d` necesarios: acceso aleatorio por
fragmento, sin reconstruir todo el archivo.

### 1.3 Coste

- La CDC es barata por byte (una multiplicación y una comparación).
- **SHA-1 es el coste dominante** de la deduplicación.
- `HTIndex` es una búsqueda en tabla abierta por fragmento (~64 KiB de media).
- `-turbo`/`add2()` paraleliza fragmentación + SHA-1 por archivo; el `add()`
  principal hace el dedup y el armado de bloques en orden.
- `-nodedup` y `-store` están documentados (`zpaq-std.cpp:159775` y
  `:159811`), pero en el código revisado `flagnodedup` se parsea y se setea y
  **no encontré una lectura en el camino de `add()`**. Antes de integrar hay
  que verificar si esos switches realmente apagan el dedup; si no, es un bug
  heredado de zpaqfranz que conviene arreglar.

## 2. zpaqfranz vs zpaq-std

- **Mismo motor**: el `HT`, `HTIndex`, el CDC de orden 1, SHA-1,
  `-fragment`/`-nodedup`/`-store` y la tabla de fragmentos son iguales.
- zpaq-std es un fork de zpaqfranz con codecs `-ma`, recompresión JPEG,
  GUI/scripts y otras adiciones; el dedup no se rediseñó.
- La diferencia de implementación está en el camino paralelo: zpaq-std usa
  `fragment_buffer()`/`FrontFrag`; zpaqfranz usa `add2_scan()`. La semántica
  (hash, cortes, SHA-1, `hits`, `o1`) es la misma.
- Por eso el mismo motor de OSREP sirve para los dos; el punto de integración
  es la función de fragmentación, no el formato del archivo.

## 3. El motor de dedup de OSREP

OSREP viene de Omega SREP, cuyo `-dup` está descrito en
`docs/dup-mode-design.md` (rama `main`):

- **Buffer split** fijo (el `-b`, por defecto 8 MiB).
- **CDC** con `--chunk-avg` (4 KiB por defecto), `--chunk-min` (1 KiB) y
  `--chunk-hash=fnv|gear`.
- **Hash interno FNV-1a** por chunk (no se guarda en el archivo), tabla de
  primera aparición; los duplicados se convierten en referencias.
- **Stream único + meta `DUPR`**: se concatenan los chunks únicos, se
  comprime ese stream con el pipeline LZ de SREP, y el meta (tags 0/1) se
  guarda adentro; el decoder reconstruye el original expandiendo las
  referencias.
- En OSREP v6 el lector de `-dup` ya restaura la entrada
  (`src/pascal/osrep_decoder.pas`); el **escritor** de `-dup` es fase 2.

Diferencias clave con zpaq:

| | OSREP `-dup` | zpaq-std |
|---|---|---|
| unidad | chunk CDC del stream completo | fragmento CDC por archivo/versión |
| hash | FNV-1a interno, no guardado | SHA-1 guardado en la tabla |
| índice | meta `DUPR` del stream | tabla `h` + índice `i` por archivo/versión |
| acceso | reconstruir el stream | acceso aleatorio por fragmento |
| compresión | el stream único pasa por el LZ de SREP | zpaq comprime bloques de datos |
| multi-versión | no es su modelo | sí, snapshots |

Por eso el `-dup` de OSREP **no** es un reemplazo directo del dedup de
zpaq-std: el modelo de zpaq es por fragmento y por archivo/versión, y el de
OSREP es un stream único con un meta. Lo que sí se puede reutilizar es la
**etapa de fragmentación + hash**, que es justo lo que zpaq-std llama
"deduplicator".

## 4. Opciones de integración

### A. OSREP como fragmentador/hash, zpaq-std como archivador (recomendada)

OSREP aporta el CDC y el hash (y, si se quiere, la tabla de dedup), pero
zpaq-std conserva su formato, su tabla de fragmentos `h`, su índice `i`, sus
bloques `d` y su compresión. El archivo sigue siendo un ZPAQ válido; los
archivos viejos se leen igual; solo cambian los cortes/hashes de los nuevos.

Dos modos:

1. **Exacto**: implementar en OSREP exactamente el CDC de orden 1 + SHA-1 de
   zpaq-std. Con los mismos parámetros, los fragmentos y sus SHA-1 son
   idénticos; se puede cambiar la implementación sin cambiar un archivo. Es
   el modo para validar la integración y para conservar la compatibilidad de
   comportamiento.
2. **OSREP**: usar el CDC de OSREP (gear/FNV) y su hash, manteniendo el
   formato de tabla de zpaq (SHA-1 + tamaño). Los archivos nuevos siguen
   siendo ZPAQ válidos y los viejos se leen; cambia la distribución de
   fragmentos, el ratio de dedup y la velocidad. Se documenta y se mide.

Puntos de integración:

- `fragment_buffer()`/`FrontFrag` en `add2()` (`zpaq-std.cpp:250299`,
  `:255315`); es una función pura, ideal para reemplazar por una API de
  OSREP.
- El lazo inline de `add()` (`zpaq-std.cpp:252655`); el mismo CDC.
- `redu()` (`:202008`) para que las estadísticas de redundancia usen el mismo
  fragmentador.
- `filelist_store()`/`sc_salva()` tienen su propio fragmentador de lista de
  archivos; no es el dedup de datos, pero conviene que compartan el mismo
  criterio si se quiere consistencia.
- `-fragment N` se mapea al promedio de OSREP (`--chunk-avg`); `-nodedup`
  debe apagar el lookup (y antes hay que verificar el flag, §1.3).

### B. OSREP `-dup` como pre-paso del stream completo

Deduplicar todo el input con OSREP, comprimir el stream único con zpaq y
guardar el meta `DUPR` aparte. Es más simple de enchufar, pero **rompe el
acceso aleatorio y el modelo multi-versión** de zpaq-std: para extraer un
archivo habría que descomprimir y reconstruir el stream. No es aceptable para
zpaq-std tal como está; podría ser un modo "OSREP container" separado.

### C. OSREP como preprocesador completo antes de zpaq

Comprimir con OSREP a un `.osr` y comprimir ese `.osr` con zpaq. Es un
"zpaq sobre OSREP", no un motor de dedup: el dedup de zpaq seguiría existiendo
(y sería redundante). No es lo que se busca.

### D. Reemplazar el `HTIndex` por el índice de OSREP

Cambiar la tabla de fragmentos por la de OSREP obligaría a cambiar el formato
ZPAQ y a romper la compatibilidad. No hay ganancia: el `HTIndex` no es el
cuello de botella. No recomendado.

## 5. Arquitectura propuesta para A

API mínima (C ABI, con referencia Pascal y tests diferenciales, como el resto
de `docs/native-c-asm.md`):

```c
/* Un fragmento, con lo que zpaq-std necesita para su tabla y su análisis. */
typedef struct {
    uint64_t off;        /* offset en el buffer de entrada */
    uint32_t size;
    uint8_t  sha1[20];
    uint32_t hits;       /* predictor de orden 1, para el data-type analysis */
    uint8_t  o1[256];    /* tabla de orden 1 al final del fragmento */
} osrep_frag;

/* Fragmenta un buffer completo (modo exacto o modo OSREP). */
int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *params,
                          osrep_frag **out, size_t *out_n);

/* SHA-1 y CDC sueltos, para los caminos que ya tienen el buffer. */
void osrep_sha1(const uint8_t *buf, size_t len, uint8_t out[20]);
```

`osrep_frag_params` lleva `fragment` (log2 de zpaq), `min`, `max`, `mode`
(exacto/OSREP) y el umbral. La función es pura y thread-safe; el que llama
decide el orden y el dedup.

La integración conserva:

- la tabla `HT`/`HTIndex` (SHA-1 + tamaño + `csize`);
- los bloques `h`/`i`/`d` y el formato ZPAQ;
- la compresión de zpaq-std y sus codecs;
- la extracción por fragmento.

OSREP solo reemplaza la producción de `(sha1, size, hits, o1)`; el resto del
archivador no se toca.

## 6. Plan por fases

### Fase 0 — Referencia de comportamiento (1 semana)

- Extraer el fragmentador de zpaq-std (`fragment_buffer` y el lazo de
  `add()`) a una función de prueba, o instrumentarlo, y generar vectores:
  buffer → lista de `(sha1, size, hits, o1)`.
- Correr zpaq-std actual sobre un corpus multi-versión y guardar los vectores
  (fragmentos, tamaños, SHA-1, tabla de dedup).
- Definir la API `osrep_fragment_*` y los parámetros.

### Fase 1 — Modo exacto (2–3 semanas)

- Implementar el CDC de orden 1 + SHA-1 en C (o Pascal primero, C después)
  con la misma semántica; comparar contra los vectores de Fase 0.
- Enchufar en `fragment_buffer`/`add2` y en el lazo de `add()`.
- Tests: los fragmentos y SHA-1 son idénticos; el archivo ZPAQ resultante es
  byte a byte el mismo que el de zpaq-std actual (con el mismo `--seed`/orden
  de archivos, si aplica).
- Caída: si el modo exacto no da idéntico, no se integra todavía.

### Fase 2 — Modo OSREP (2–3 semanas)

- Agregar el CDC de OSREP (gear/FNV) como modo; mapear `-fragment` al
  promedio; documentar que cambia el stream pero no el formato.
- Benchmarks: ratio de dedup, tamaño del archivo, tiempo de compresión,
  tiempo de extracción, RSS; corpus multi-versión (árbol de fuentes, snapshots
  de un backup real).
- Validación: los archivos nuevos se leen con zpaq-std y zpaqfranz; los
  viejos se siguen leyendo; `-verify`/extracción OK.

### Fase 3 — Producto (1–2 semanas)

- CLI/GUI: exponer `-fragment`/modo; documentar; tests de regresión.
- `-nodedup`/`-store`: verificar y arreglar si están muertos.
- Empaquetar OSREP como librería (C ABI) y como parte de zpaq-std.

## 7. Riesgos y preguntas abiertas

- **Compatibilidad**: el formato ZPAQ no se toca; la tabla sigue siendo
  SHA-1 + tamaño. Si se cambia el hash, se rompe la lectura de archivos
  viejos. Mantener SHA-1.
- **`-fragment`**: el parámetro de zpaq es log2 (6 = ~64 KiB); OSREP usa
  bytes (`--chunk-avg`). El mapeo tiene que quedar documentado.
- **`-nodedup`/`-store`**: en el código revisado el flag se parsea pero no se
  lee en `add()`; verificar antes de confiar en él.
- **Paralelismo**: la API debe ser pura/thread-safe; el `add2()` de zpaq-std
  fragmenta en paralelo por archivo.
- **Rendimiento**: SHA-1 domina; OSREP puede aportar SHA-1 por hardware
  (C/asm) y CDC vectorial; medir antes de prometer.
- **Licencia**: zpaq-std es MIT (con terceros), zpaqfranz MIT, OSREP MIT;
  compatible. Mantener los avisos de terceros.
- **Qué significa "motor de dedup"**: en este estudio es el fragmentador +
  hash; el índice y el archivado siguen siendo de zpaq-std. Si se quisiera
  reemplazar también el índice, sería otro formato y otro proyecto.

## 8. Recomendación

**A, en dos pasos**: primero el modo exacto (mismos fragmentos y SHA-1 que
zpaq-std), después el modo OSREP (CDC propio) como opción. El modo exacto
prueba que la integración no cambia el archivo; el modo OSREP es donde OSREP
aporta su CDC y su C/asm. El `-dup`/`DUPR` de OSREP no se usa para esto: su
modelo de stream único no encaja con el acceso por fragmento y las versiones
de zpaq-std.
