# Formato `.osr` v5 — diseño

Contenedor **honesto y autodescriptivo**, y un stream de matches **rediseñado**
sobre el mismo algoritmo de match finding. v1–v4 se siguen **leyendo** para
siempre; v5 es lo que se **escribe** por defecto, con `--format=v4` permanente
como herramienta de interoperabilidad.

## 0. Decisiones tomadas

| tema | decisión |
|---|---|
| Payload | **se rediseña**: records de longitud variable (LEB128), longitudes crudas |
| Integridad | **CRC-32C** sin clave (header, footer y meta), el polinomio de CDC |
| Meta de `-dup` | **al final**, localizado por `meta_offset`/`meta_size` del footer |
| `--format=v4` | **permanente** |

## 1. Qué arregla (mapeado a lo que encontramos)

| problema en v1–v4 | cómo lo arregla v5 |
|---|---|
| `header[0]` es `BULAT_ZIGANSHIN_SIGNATURE`, un magic que ya no significa nada; `header[1]` es el magic real | **un solo magic**, `"OSR5"` |
| `header[2]` empaqueta `version(8) \| hash_num(8) \| seed_size(8) \| (hash_size-16)(8)`: el digest se guarda **sesgado -16** y los 8 bytes de SipHash se envuelven a 248 | `hash_id` + `hash_size` **explícitos y sin sesgo** |
| `header[3]` es `BASE_LEN` (0 en v3/v4), un valor escondido en un word de header | **desaparece**: las longitudes se guardan crudas |
| `ROUND_MATCHES` parte el formato en dos formas de record (3 vs 4 STATs) y multiplica por `L` | **una sola forma**: varints, sin multiplicar, sin redondear |
| el offset de match se parte en dos words (tope de 2³²) | un varint **sin tope artificial** |
| `maximum_save` **no se guarda**: encoder y decoder tienen que coincidir por el default compartido de `-vmblock` | `max_match` explícito |
| el número de bloques es implícito (`(footer_size-24)/4`) y el fin de stream se deduce | `block_count` explícito en header y footer, que deben coincidir |
| `statsize` es 0 en el header de bloque de v4 y el tamaño real vive en la tabla | el header de bloque lleva **su propio** `statsize`; la tabla queda para ubicar las listas sin recorrer los literales, y el decoder **cruza** ambos |
| el digest de un hash deshabilitado reserva 16 bytes con contenido no especificado | `hash_size = 0` ⇒ el campo **no existe** |
| el footer se valida con dos firmas invertidas | CRC-32C del header y del footer |
| el meta de `-dup` es un **trailer** que se detecta olfateando `"ODUP"` en los últimos 4 bytes, y **no tiene integridad** | el footer lo **localiza** y lleva su **CRC-32C**: sin olfateo, sin misidentificación |

## 2. Layout

```
+-----------------------------------------------------------+
| file header (28 bytes)                                    |
|   magic          u32   "OSR5" = 0x3552534F LE             |
|   version        u8    = 5                                |
|   flags          u8    bit0 = has_dup meta                |
|   hash_id        u8    índice en la tabla de hashes       |
|   hash_size      u8    bytes de digest por bloque (0 = no)|
|   max_match      u32   máximo largo guardado en memoria   |
|   block_count    u32   número de bloques                  |
|   original_size  u64   tamaño del input original          |
|   header_crc     u32   CRC-32C de los 24 bytes anteriores |
+-----------------------------------------------------------+
| hash seed (seed_size bytes; 0 si el hash no lleva clave)  |
+-----------------------------------------------------------+
| bloque 1 .. bloque N:                                     |
|   header  : literal_bytes u32, origsize u32, statsize u32  |
|   digest  : hash_size bytes (ausente si hash_size == 0)   |
|   records : statsize bytes, triples varint (§3)           |
|   literales: literal_bytes bytes                          |
| (cada bloque es autocontenido: sin tabla al final)        |
+-----------------------------------------------------------+
| meta de -dup (sólo si flags.bit0):                        |
|   magic "DUPR" u32, version u8, 3 bytes reservados        |
|   chunk_count u64, unique_count u64                       |
|   tabla de chunks (igual que hoy)                         |
|   meta_crc  u32   CRC-32C de todo el meta salvo este campo|
+-----------------------------------------------------------+
| footer (32 bytes)                                         |
|   magic        u32  "OSRF" = 0x4652534F LE                |
|   block_count  u32  (debe coincidir con el header)        |
|   stat_size    u64  bytes totales de listas de matches    |
|   meta_offset  u64  offset del meta, o 0                  |
|   meta_size    u32  bytes del meta, o 0                   |
|   footer_crc   u32  CRC-32C de los 28 bytes anteriores    |
+-----------------------------------------------------------+
```

El meta **es** el blob `.dupref` (`docs/format-spec.md` §3.1), verbatim, con el
CRC pegado al final: `meta_size = dupref.len() + 4`. Su `version u8` + 3
reservados son el campo `version u32 = 1` del `.dupref`, visto byte a byte, así
que el meta empieza con `DUPR` exactamente como el trailer de v4 — no lleva un
header propio encima. Lo único que cambia respecto de v4 es *dónde* está y que
ahora tiene integridad.

## 3. El record de match en v5

La lista de un bloque es una secuencia de **triples varint** LEB128:

```
lit_len     varint   bytes literales antes del match
match_len   varint   largo del match (crudo: ya no se resta BASE_LEN)
distance    varint   LZ.dest - LZ.src (crudo: un solo campo, sin /L1)
```

y termina cuando se consumen los `statsize` bytes del bloque (no hace falta un
contador ni un centinela: el tamaño ya está en el header de bloque y en la
tabla). Los literales finales del bloque quedan después del último match, como
siempre.

Qué se gana: un solo códec en lugar de dos formas; sin `L` que multiplicar ni
`BASE_LEN` que compartir por fuera del archivo (era un default implícito que
tenía que coincidir entre encoder y decoder); y sin el tope de 2³² en el offset.
Lo que se paga: records más lentos de leer que 4 lecturas alineadas, y un
`statsize` que ya no es múltiplo de nada.

Semántica de decodificación (sin cambios respecto de lo que el decoder ya
calcula): cada match `copies` de `[src, src+match_len)` a
`[dest, dest+match_len)`, donde `src = dest - distance`, y `dest` avanza
`lit_len` desde el final del match anterior, más el bloque base.

## 4. Compatibilidad y transición

* **Lectura**: v1–v4 sigue funcionando exactamente como hoy (decoders ya
  portados y verificados). El lector v5 se suma.
* **Escritura**: v5 por defecto; `--format=v4` escribe el v4 actual, de forma
  permanente, para interoperar con el parque de binarios 1.0.x.
* El número 5 estaba "reservado" para un header inline de `-dup` que **nunca se
  implementó** (se usó el trailer ODUP), así que se reclama sin conflicto.

## 5. Reglas de rechazo (errores limpios, nunca adivinar)

* magic ≠ `"OSR5"` → no es v5 (el lector prueba v1–v4 antes de rendirse).
* `version != 5` → versión no soportada, con el número leído.
* `header_crc`/`footer_crc`/`meta_crc` no coinciden → archivo corrupto.
* `flags` con bits desconocidos → rechazar (no ignorar).
* `block_count` del header ≠ el del footer, o ≠ la tabla → corrupto.
* `hash_id` desconocido, o `hash_size` que no corresponde a ese `hash_id` →
  rechazar (hoy `-hash=` vacío **desactiva los checksums en silencio**).
* `meta_offset`/`meta_size` fuera del archivo, o `"DUPR"` ausente cuando
  `flags.bit0` está puesto → corrupto.
* Un varint que se pasa de los 64 bits, o que se sale de `statsize` → corrupto.

## 6. Verificación

El C++ sólo produce v1–v4, así que v5 no tiene oráculo byte a byte. Se verifica
en tres capas, cada una apoyada en algo ya probado:

1. **Decisiones de match**: son las mismas que en v4 y eso **ya está verificado
   byte a byte** contra el C++ (`tests/encode_conformance.sh`). El encoder de v5
   reusa exactamente ese match finder y ese segundo pase; lo único que cambia es
   cómo se escriben los records.
2. **Equivalencia de streams**: para el mismo input y las mismas opciones, se
   codifica con el C++ (v4) y con el port (v5), se decodifican **las dos listas
   de matches** (con los lectores respectivos) y se comparan triple a triple
   (`lit_len`, `match_len`, `distance`) y bloque a bloque. Si coinciden, v5
   lleva exactamente los mismos matches que el oráculo, sólo en otro envoltorio.
3. **Round-trip y corrupción**: `encode → decode == input` en toda la matriz
   (modos × sufijos × opciones), y cada regla de rechazo de §5 con un caso
   negativo que debe fallar limpio (nunca pánico, nunca salida silenciosa).

Gate: `tests/format_v5_conformance.sh` (capas 2 y 3) sumado a la suite.

## 7. Lo que v5 deliberadamente NO hace

* No cambia el match finding ni el segundo pase: no toca lo que está verificado
  byte a byte contra el C++.
* No introduce compresión en el contenedor ni cifrado.
* No reordena bloques ni agrega un índice de posiciones: la tabla de tamaños ya
  permite saltar las listas sin recorrer los literales.
* No cambia el reparto de trabajo del `-dup`: sólo dónde y cómo se guarda su
  meta, y con qué integridad.
