# Formato `.osr` v6 — OSREP (normativo)

**Estado: normativo para OSREP (2026-11-10).** Es el **único** contenedor de
OSREP: se escribe y se lee v6. El encoder nuevo puede elegir otros matches,
pero este layout no cambia. El layout de los records está en `payload.md`;
las menciones a v5/v4 en este documento son la procedencia del payload, no
objetivos de compatibilidad.

## 0. Decisiones acordadas

| tema | propuesta |
|---|---|
| Base del payload | el de v5 (header, bloques autocontenidos, records varint, meta `DUPR`, footer) |
| Integridad nueva | **CRC-32C por bloque** sobre los bytes tal como quedan en disco + **`blocks_crc`** en el footer (CRC de los CRC de bloque, en orden) |
| `--verify` | pasa a ser completo: con el CRC por bloque no hace falta descomprimir para detectar daño en un bloque guardado |
| Lectura | v6 de OSREP y los v6 de Omega SREP 3.0.0; **no** v1–v5 |
| Escritura | v6, único formato |
| `-dup` | mismo diseño CDC y mismo meta, adentro y con CRC |
| Compatibilidad | **no** hay compatibilidad con SREP; el formato es propio |
| Determinismo de CPU | **el hash de frontera de CDC deja de depender de SSE4.2**: v6 fija una sola ruta (propuesta: la polinomial) y el mismo input da el mismo archivo en x86, x86-64, ARM64 y Windows |
| Congelamiento | a partir de OSREP 1.0 el layout no cambia; la spec y la golden son la definición |

## 1. Plataformas soportadas

Esta es la matriz que OSREP 1.0 tiene que construir, publicar y verificar:

| sistema | arquitectura | estado hoy | cómo se verifica |
|---|---|---|---|
| Linux | x86_64 | se distribuye | nativo |
| Linux | i386 | construido y validado, se publica en 3.0.0 | nativo (binario estático) |
| Linux | aarch64 | construido y validado (con la ruta polinomial de CDC) | `qemu-user` + VM ARM64 |
| Windows | x86_64 (Win7 SP1 o superior) | se distribuye | Win7 real |
| Windows | i386 (Win7 SP1 o superior) | se distribuye | Win7 real |
| macOS (11 o superior) | arm64 | construido y validado en CI (2026-11-10) | `macos-15` de GitHub Actions, FPC 3.2.2 nativo, `core` + artefacto |

Fuera de la matriz: BSD, Windows anteriores a 7, macOS x86 y cualquier target
sin compilador de FPC 3.2.2. La 3.0.0 no promete nada que no esté en esta
tabla.

**Toolchain (hecho el 2026-10-20):** el cross propio
(`/mnt/IA_LAB/agentes/osrep/fpc-cross/`) ahora tiene `ppcross386` con las RTL
y paquetes de i386-linux y `ppcrossa64` con los de aarch64-linux, construidos
desde la fuente oficial de FPC 3.2.2 (`PROCEDENCIA.md` tiene los comandos).
`pascal/build.sh` construye los cinco targets. Lo que falta es publicar los
assets en la 3.0.0; el código ya está.

## 2. Qué cambia en el archivo

### 2.1. Header

Igual al de v5 salvo `version = 6` y un bit de flags nuevo:

```
magic          u32   "OSR6"
version        u8    = 6
flags          u8    bit0 = meta de -dup; el resto, rechazado
hash_id        u8
hash_size      u8    (derivado de hash_id; 0 = sin digest)
max_match      u32
block_count    u32
original_size  u64
header_crc     u32   CRC-32C de los 24 bytes anteriores
```

### 2.2. Bloque

El bloque de v5 más un CRC sobre su payload. El header del bloque queda:

```
literal_bytes   u32
origsize        u32
statsize        u32
block_crc       u32   CRC-32C de todo lo que sigue en el bloque:
                             digest (hash_size) || records (statsize) || literales
```

El orden de los campos dentro del payload no cambia (digest, records,
literales). El CRC cubre **exactamente los bytes que quedan en el archivo**, no
los datos reconstruidos: es lo que permite verificarlo sin descomprimir, y lo
que hoy falta cuando `literal_bytes == origsize` (bloque guardado sin
comprimir).

### 2.3. Footer

```
magic          u32   "OSRF"
block_count    u32
stat_size      u64
meta_offset    u64
meta_size      u32
blocks_crc     u32   CRC-32C de la concatenación de los block_crc, en orden
footer_crc     u32   CRC-32C de los 32 bytes anteriores
```

**El digest del archivo entero no va.** Los hashes del proyecto son
*one-shot* (`MD5(Data)`, `VmacCompute(V, M)`, etc.): no hay forma de calcular
el digest de los datos originales mientras se leen de un stream sin escribir
un hash incremental nuevo. Y no hace falta para la integridad: el digest por
bloque ya cubre la reconstrucción de ese bloque (el decoder lo verifica), y
`blocks_crc` ata la secuencia al footer. Un digest global solo agregaría un
número para comparar contra `sha256sum`, no detección. Si en el futuro se
quiere ese número, se agrega en un v7 con su hash incremental.

`--verify` sin descomprimir valida header, footer, meta y **cada CRC de
bloque**, incluidos los bloques guardados sin comprimir (el agujero de A6).

### 2.4. Determinismo entre CPUs (nuevo en v6)

Hoy `-m1`/`-m2` eligen el hash de frontera del CDC según la CPU: con SSE4.2
usan el CRC32C por hardware y sin SSE4.2 caen en un hash polinomial
(`cdc.pas:68`, `is_x86_feature_detected!("sse4.2")` en el Rust, y lo mismo el
C++). **Las dos rutas escriben archivos distintos para el mismo input y las
mismas opciones.** En la práctica: un x86 sin SSE4.2 y un ARM64 dan otro
archivo que un x86 con SSE4.2, con los mismos bytes de entrada. **Implementado
el 2026-11-10:** al escribir v6, el encoder llama a `CdcForcePoly` y toma
siempre la polinomial; v4/v5 conservan la elección por CPU para no cambiar sus
archivos.

Eso es incompatible con "mismo input, mismo archivo" entre las plataformas de
§1, y no se puede parchear sin cambiar el formato. v6 lo fija: **una sola
ruta de frontera, sin detección de CPU** (propuesta: la polinomial, que ya está
probada contra el Rust con `OSREP_CDC_POLY=1`). `OSREP_CDC_POLY` deja de ser
una perilla de prueba y pasa a ser el comportamiento único; el CRC por
hardware queda como una optimización interna **solo** si da exactamente los
mismos bytes (no es el caso hoy, así que no se usa).

### 2.5. CRC-32C: parámetros

Todos los CRC de v6 son **CRC-32C (Castagnoli)** con:

- polinomio reflejado `0x82F63B78`,
- valor inicial `0`,
- sin XOR final,
- bytes procesados del bit menos significativo al más significativo.

`Crc32cUpdate(crc, buf, len)` encadena sin reiniciar. `header_crc` cubre los
24 bytes anteriores del header; `block_crc` cubre `digest || records ||
literales` tal como están en disco; `footer_crc` cubre los 32 bytes anteriores
del footer; `blocks_crc` es la cadena de los `block_crc` en orden, empezando en
0. No es el CRC-32C "de catálogo" (init/xorout `0xFFFFFFFF`): con esos
parámetros ningún CRC de los archivos v6 coincide.

### 2.6. Digest por bloque

El payload de un bloque es `digest (hash_size) || records (statsize) ||
literales`. El digest cubre los `origsize` bytes **reconstruidos** del bloque
(para `-dup`, el cuerpo ya deduplicado; el post-paso de `-dup` restaura la
entrada después). El decoder lo recalcula al reconstruir el bloque y rechaza
la diferencia con exit 4. `--verify` no descomprime, así que **no** recalcula
el digest: valida el `block_crc`, que cubre los bytes del digest tal como están
en disco.

| `hash_id` | algoritmo | digest | seed |
|---:|---|---:|---:|
| 0 | MD5 | 16 | 0 |
| 1 | desactivado | 0 | 0 |
| 2 | SHA-1 | 20 | 0 |
| 3 | SHA-512 | 64 | 0 |
| 4 | VMAC | 16 | 32 |
| 5 | SipHash-2-4 | 8 | 16 |

El seed va después del header del archivo, `seed_size` bytes (derivado de la
tabla). Para VMAC la clave es el seed; para SipHash, los 16 bytes del seed.
`hash_size = 0` significa "sin digest": no hay bytes de digest ni seed, y el
`hash_id` se ignora. Cualquier otro `hash_size` tiene que coincidir con la
tabla; si no, el archivo se rechaza.

### 2.7. Semántica de los records: Future-LZ

La lista de un bloque es una secuencia de triples LEB128 **sin signo**:

```
skip       varint   avance del puntero de source desde el record anterior
length     varint   largo del match
distance   varint   destination - source
```

Semántica (Future-LZ), con `block_start` la posición del bloque en la salida:

```
running_skip = 0
para cada record, en el orden del archivo (ordenado por source):
    source      = block_start + running_skip
    destination = source + distance
    running_skip = running_skip + skip
```

Los records están guardados en orden de `source`. El decoder los ordena por
`destination` y recorre el bloque de 0 a `origsize`:

1. entre el final del match anterior y el `destination` del siguiente, copia
   bytes del stream de literales, en orden;
2. copia `length` bytes desde `source` a `destination`, con solapamiento
   permitido (`distance < length` es válido);
3. después del último match, copia los literales restantes hasta `origsize`.

`source` puede apuntar a un bloque anterior ya reconstruido. El stream de
literales tiene `literal_bytes` bytes y se consume en orden de destino. Se
cumple `sum(length) + literal_bytes = origsize`; `sum(skip)` **no** es la
cuenta de literales y puede superar `literal_bytes`. `statsize` es el número de
bytes de records; no hay centinela.

La lectura "Index-LZ" histórica (`lit_len` = literales antes del match, `dest`
avanza desde el match anterior) **no** es la de v6; ver la nota de
`payload.md` §3.

### 2.8. Meta `DUPR` de `-dup`

Cuando `flags.bit0` está puesto, el meta está en `meta_offset`/`meta_size`
(termina justo antes del footer) y tiene:

```
magic        u32   "DUPR"
version      u32   1
chunk_count  u64   chunks totales de la entrada
unique_count u64   chunks únicos
```

Después, `chunk_count` registros en orden de entrada:

- tag `0` (único): `u32` con el largo del chunk;
- tag `1` (referencia): varint LEB128 con el índice al chunk único
  (`< unique_count`).

El cuerpo de los chunks únicos es el cuerpo ya decodificado del archivo
(concatenación en orden de primera aparición). `meta_crc` cubre todo el meta
menos sus últimos 4 bytes. El CRC del meta se valida en `--verify`; la tabla de
chunks se usa para reconstruir la entrada original en `-d`.

### 2.9. Lo que no cambia


- El stream de matches: triples varint `skip | length | distance` en la
  semántica Future-LZ de §2.7, sin `BASE_LEN`, sin `ROUND_MATCHES`, sin
  multiplicar por `L`.
- El meta `DUPR` de `-dup`, con su CRC.
- El CRC-32C con los parámetros de §2.5.
- El header de 28 bytes y el footer de 36 bytes: v6 agrega campos, no reordena.

## 3. Reglas de rechazo

Las de v5, más:

- `block_crc` que no coincide → archivo corrupto, con el número de bloque.
- `flags` con bits distintos de bit0 → corrupto.
- Un bloque que dice `literal_bytes == origsize` y `statsize != 0` → corrupto
  (no se adivina si es guardado o comprimido).
- `block_crc` cubre el payload completo: un `statsize` o un `literal_bytes`
  manipulados también se detectan.

## 4. CLI: lo que la 3.0.0 puede limpiar

Al congelar el formato, el objetivo deja de ser "byte-idéntico al C++" fuera
del archivo. Queda así:

- Números: `-a`/`--seed=` dejan de leer octal y aceptan decimal/hex de forma
  consistente; se actualiza el texto de error de `--seed=`.
- `-a9`, `-a10`, `-a12`: hoy el C++ se cae y el port redondea. En v6 se define
  (redondear a potencia de dos, documentado) o se rechaza con error claro.
- `-m4`/`-m5` con `-l < -c`: se define "sin filtro" (lo que hacen hoy los
  ports) y se documenta; deja de ser una desviación.
- `-t`, `-mmap`, `-slp` y demás opciones aceptadas e ignoradas: rechazarlas con
  un mensaje, o documentarlas explícitamente como no-ops.
- `NUL NUL` en Windows y los textos de error: unificar con Linux.
- Los sufijos `o`/`f`: solo lectura; se documenta que no se escriben más.

## 5. Compatibilidad y migración

- **3.0.0 lee** v1, v2, v3, v4, v5 y v6. Lo viejo se queda como está: los
  decoders ya están portados y verificados.
- **3.0.0 escribe** v6 por defecto y v4 con `--format=v4`. No escribe v1–v3 ni
  v5.
- **Ninguna 2.x lee v6** (el magic es distinto), y eso es el bump de major.
  No hay migración automática: se re-comprime con 3.0.0 si se quiere el
  checksum.
- `--format=v5` en 3.0.0: **rechazado** con un mensaje que dice que v5 solo se
  lee (decisión del 2026-11-10). Se escribe v6 por defecto y v4 con
  `--format=v4`.

## 6. Verificación antes de congelar

1. **Oráculos**: v6 no tiene oráculo (ni el C++ ni el Rust lo escriben). El
   stream de matches se valida con los oráculos en v4/v5 **antes** de cambiar
   el contenedor; el contenedor v6 se valida con el decoder y con
   `tests/golden/`.
2. **Golden**: ampliar el manifiesto hasta cubrir cada campo de v6 (CRC malo,
   digest ausente, bloque guardado, meta, block_count, flags).
3. **Fuzz del decoder**: entradas mutadas sobre v6 (y v1–v5), con valgrind, que
   es lo que hoy no tenemos (el fuzz actual es del C++).
4. **Matriz de plataformas**: los cinco targets de §1, con los bytes
   comparados entre sí y el round-trip en cada uno.
5. **Win7 real**: la misma matriz de 72 casos por `.exe` que se usó en 2.4.0,
   más v6.

## 7. Congelamiento

Cuando la 3.0.0 salga:

- `docs/format-spec-v6.md` pasa a **normativa** (sin "borrador").
- `tests/golden/` y la spec son la definición; los oráculos se archivan en
  `oracle-cxx-1.0.7` y `oracle-rust-2.1.2` y salen de `main`.
- El layout no cambia más: cualquier cambio de bytes va a un v7 con su propio
  major.
