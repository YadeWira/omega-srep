# Implementación OSREP 0.0.2 — notas de las Fases 1a/1b (lector y encoder v6)

**Equipo B (clean-room), 2026-11-10.** Este documento registra qué se
implementó, de dónde sale cada comportamiento y los huecos de `spec/` que
aparecieron. Nada de esto se dedujo del código legacy: sale de `spec/`,
`tests/fixtures/` y documentación pública de SREP/VMAC.

## 1. Alcance

- `src/pascal/osrep.lpr`: CLI (encoder, lector, `-d`, `--verify`, `-i`).
- `src/pascal/osrep_crc.pas`: CRC-32C con tabla software.
- `src/pascal/osrep_format.pas`: header, footer, bloque, helpers LE.
- `src/pascal/osrep_aes.pas`: AES-256 para VHASH.
- `src/pascal/osrep_vhash.pas`: VHASH-128 sin nonce (digest de bloque).
- `src/pascal/osrep_decoder.pas`: lector v6, Future-LZ multi-bloque, meta
  `DUPR` y post-paso de `-dup`.
- `src/pascal/osrep_encoder.pas`: encoder `-m3` con hash chain propio.
- `tests/v6_read.sh`: aceptación del lector.
- `tests/v6_encode.sh`: aceptación del encoder y de `-dup`.

No hay v1–v5 ni código de SREP.

Compilar y probar:

```sh
fpc -Mobjfpc -O2 -Sh -Fu./src/pascal -FU./tests/tmp/units \
    -FE./tests/tmp/build ./src/pascal/osrep.lpr
./tests/v6_read.sh
./tests/v6_encode.sh
```

## 2. La diferencia importante: los fixtures v6 son Future-LZ

`spec/payload.md` §3 describe el record como LZ normal:

```
lit_len | match_len | distance
dest avanza lit_len desde el final del match anterior
```

Eso **no** describe los `.osr` v6 de Omega SREP 3.0.0. Los fixtures usan el
modo Future-LZ (el default de SREP: `-m3f`), donde:

```
record = (skip, length, distance)
source = suma acumulada de skip          (empieza en 0 en cada bloque)
destination = source + distance
```

Los records están ordenados por **source**. El decoder:

1. Lee todos los records del bloque y calcula `(source, destination, length)`.
2. Los ordena por `destination`.
3. Recorre el destino de 0 a `origsize`; entre dos matches copia los bytes
   literales del stream de literales (en orden).
4. Copia cada match desde `source` (con solapamiento permitido: `distance <
   length` es válido).
5. Al final copia los literales que faltan hasta `origsize`.

Comprobación concreta con `text-m3.osr` (bloque de 4194304 bytes, 1024
literales, un record `(512, 4193280, 69)`):

- `source = 512`, `destination = 512 + 69 = 581`.
- Se copian 581 literales, el match de 4193280 bytes desde 512 y quedan 443
  literales al final: `581 + 4193280 + 443 = 4194304`.
- Ese es exactamente el contenido de `text.bin`.

El `skip` observado en los fixtures siempre es múltiplo de 512 (el `-c512`
del match finder de SREP); no se exige esa alineación al leer, pero se
documenta porque explica los valores. `max_match` no se usa para decodificar.

La documentación pública de SREP (la página archivada de freearc.org) describe
Future-LZ como "matches are stored at the match source rather than destination
position" y "matches are sorted by their source address". Eso coincide con lo
que muestran los fixtures. No se leyó código legacy para llegar a esto.

Esta semántica también explica la identidad que cumplen todos los fixtures:

```
origsize(archivo) = suma(literal_bytes) + suma(match_len)
```

No es por bloque: en `text-b1mb-m3.osr` el bloque 0 tiene `origsize=1048576`,
`literal_bytes=1024` y `sum(match_len)=1083904`, porque un match puede cruzar
el borde. `sum(lit_len)`/`sum(skip)` puede ser mayor que `literal_bytes` (en
`zruns-m3` es 238592 contra 104228): no cuenta literales, cuenta el avance del
puntero de source.

## 3. CRC-32C: parámetros que fijan los fixtures

`spec/format-v6.md` dice solo "CRC-32C". Los fixtures usan:

- polinomio reflejado `0x82F63B78` (Castagnoli),
- valor inicial `0`,
- sin XOR final.

No es el CRC-32C "de catálogo" (init/xorout `0xFFFFFFFF`). Con los parámetros
de catálogo ningún CRC de los fixtures coincide; con init/xorout 0 coinciden
los tres (header, footer, block) y `blocks_crc`. Está implementado así.

## 3.1. Digest de bloque: VHASH-128 sin nonce

`hash_id=4` no es el MAC VMAC completo: es **VHASH-128 sin nonce** de la
implementación pública de Krovetz/Wei Dai, con `VMAC_KEY_LEN=256` (clave = los
32 bytes del seed), `VMAC_TAG_LEN=128`, `VMAC_NHBYTES=4096` y la función
`vhash`. El tag son los dos QWord de `vhash` en little-endian; el tweak de
largo es `len8 = (len mod 4096) * 8`. El digest cubre los `origsize` bytes
reconstruidos del bloque. `-d` lo recalcula y rechaza con exit 4; `--verify`
no descomprime y solo valida el `block_crc`, que cubre el digest tal como está
en disco.

La implementación Pascal está en `src/pascal/osrep_vhash.pas` (usa
`osrep_aes.pas`, AES-256). El vector de control `text.bin` con el seed de los
fixtures da `94303bebcecb2d284461e5972eebbaf0`, y el test negativo de
`tests/v6_read.sh` cambia un byte del digest y rehace `block_crc`,
`blocks_crc` y `footer_crc`: `--verify` pasa y `-d` falla con exit 4.

`hash_id=1` con `hash_size=0` significa "sin digest": no hay digest ni seed y
el id se ignora; el fixture `text-hashnone-m3.osr` lo cubre.

## 4. Reglas de lectura implementadas

- Header: `OSR6`, versión 6, `flags` solo bit0, `hash_id`/`hash_size` conocidos,
  `header_crc` sobre los 24 bytes anteriores.
- Seed: la tabla de `spec/format-v6.md` §2.6 fija los tamaños; `hash_id=4`
  (VHASH-128) ⇒ 32 bytes de seed; `hash_id=1/hash_size=0` ⇒ sin seed.
- Digest: `hash_id=4` se verifica con VHASH-128 sobre los `origsize` bytes
  reconstruidos; `hash_size=0` no tiene digest.
- Footer de **36** bytes (no 32): `OSRF`, `block_count`, `stat_size`,
  `meta_offset`, `meta_size`, `blocks_crc`, `footer_crc` sobre los 32
  anteriores.
- `block_count` del header = footer; `original_size` = suma de `origsize` de
  bloques; `stat_size` = suma de `statsize`.
- Bloques: header de 16 bytes, `block_crc` sobre `digest || records ||
  literales` tal como están en disco. `--verify` no descomprime.
- `literal_bytes == origsize` y `statsize != 0` ⇒ corrupto.
- `statsize == 0` ⇒ `literal_bytes == origsize` (bloque guardado).
- Multi-bloque: `block_start` es la suma de los `origsize` anteriores. El
  `running_skip` se reinicia en cada bloque, pero **el `skip` se suma antes de
  calcular `source`** (`source = block_start + Σ skip`), que es lo que hacen
  los fixtures. Los matches se juntan en una cola global, se ordenan por
  `destination` y los literales de cada bloque llenan solo los huecos de su
  rango. Un match puede empezar en un bloque y seguir en el siguiente; el
  fixture `text-b1mb-m3.osr` (4 bloques) lo verifica.
- Meta `DUPR` solo con `flags.bit0`: `meta_offset + meta_size` termina en el
  footer, magic `DUPR`, versión 1 y `meta_crc` sobre todo el meta menos sus
  últimos 4 bytes. El contenido de la tabla de chunks no se interpreta.
- Cualquier byte entre el último bloque y el footer/meta, o cualquier tamaño
  que no cuadre, es corrupto (exit 4).

## 4.1. Encoder `-m3` (Fase 1b)

El encoder es propio: un **hash chain** de 4 bytes, greedy, dentro de cada
bloque. No reproduce el stream de SREP ni el de 3.0.0; solo produce un v6
válido que el lector reconstruye. Parámetros:

- `-bN` tamaño de bloque (default 8 MiB). Los matches se restringen al bloque
  actual (`source >= block_start`, `destination + length <= block_start +
  origsize`).
- `-lN` largo mínimo de match (default 4; se eleva a 4 porque el hash es de 4
  bytes).
- `-cN` paso de inserción en el hash chain (default 1).
- `-aN[/M]` profundidad máxima de la cadena (default 16; `M` se acepta y se
  ignora).
- `--seed=N`: semilla determinista. El seed de 32 bytes sale de `SplitMix64`
  con `N xor 0xD1B54A32D192ED03`; no se usa aleatoriedad del sistema.
- `-hash-` escribe `hash_id=1/hash_size=0`, sin seed ni digest.
- `-m4`/`-m5` se aceptan como alias del mismo finder; `-m0..-m2` y `-dup` de
  escritura todavía se rechazan con exit 2.

El parse es greedy de izquierda a derecha: en cada `destination` busca el
match más largo en el hash chain, y si no llega a `-l` emite un literal. Los
matches quedan no solapados en destination y en orden de destination; después
se ordenan por `source` para escribir `(skip, length, distance)`, con
`skip = source - source_anterior` y el anterior inicializado en `block_start`.
Los literales se generan recorriendo los huecos de destination y la cola. El
digest VHASH-128 se calcula sobre los `origsize` bytes del bloque.

## 4.2. `-dup` de lectura

`-d` de un archivo con `flags.bit0` decodifica el cuerpo deduplicado (y
verifica su digest), después lee la tabla `DUPR` de §2.8 y la aplica:

- tag `0`: `u32` con el largo del chunk; los bytes salen del cuerpo en orden y
  el chunk se agrega a la lista de únicos;
- tag `1`: varint con el índice al chunk único ya visto; se repite ese chunk.

El resultado es la entrada original (para `text-dup-m3.osr`, los 4 MiB de
`text.bin`). `--verify` no aplica el post-paso: solo valida header/footer/meta
y los CRC.

## 5. CLI y `-i`

- `--version` → `OSREP 0.0.2 (2026-11-10)`.
- `osrep -m3 [opciones] <input> [<output>]`: comprime; salida por defecto
  `<input>.osr`. Opciones: `-b`, `-l`, `-c`, `-a`, `--seed`, `-hash-`.
- `-d <archive> [<output>]`: salida derivada (`x.osr` → `x`; si no termina en
  `.osr`, `x` → `x.out`). `-` como salida escribe a stdout. Con `-dup`, la
  salida es la entrada original restaurada.
- `--verify <archive>`: valida header, footer, cada `block_crc`, `blocks_crc`,
  `meta_crc`, contadores y tamaños. No descomprime.
- `-i <archive>`: salida estable key=value, sin path:

```
OSREP v6
blocks=1
original_size=4194304
stat_size=7
meta_size=0
hash_id=4
hash_size=16
```

- Exit codes: 0 OK, 2 cmdline, 3 I/O, 4 datos dañados.

## 6. Pruebas

`tests/v6_read.sh`:

1. Compila con FPC 3.2.2.
2. Genera las entradas con `tests/golden/inputs.sh`.
3. Decodifica los 9 fixtures no-dup (incluye `text-b1mb-m3` de 4 bloques y
   `text-hashnone-m3` sin digest) y compara byte a byte con la entrada.
4. `-d` de `text-dup-m3.osr` restaura los 4 MiB de `text.bin`.
5. `--verify` sobre los 10 (incluye `text-dup-m3.osr` y su `meta_crc`).
6. Corrompe un byte de un bloque: `--verify` y `-d` deben dar exit 4.
7. Corrompe un byte del meta: exit 4.
8. Cambia un byte del digest y rehace `block_crc`/`blocks_crc`/`footer_crc`:
   `--verify` debe pasar y `-d` debe dar exit 4 por digest.
9. Fija la salida de `-i` para `text-m3.osr`.
10. Prueba salida a stdout, opción desconocida (2), archivo inexistente (3) y
    `-d` sin argumento (2).

`tests/v6_encode.sh`:

1. Comprime y descomprime `text`, `mixed`, `zeros`, `random` y `tiny` con
   `-m3`; `--verify` y round-trip.
2. Prueba `-b1mb -l64 -c16 -a32`.
3. Determinismo: `--seed=7` dos veces da el mismo archivo.
4. `-hash-`: sin digest, `hash_id=1`, `hash_size=0`, round-trip.
5. Decodifica los fixtures nuevos de `tests/fixtures/v6-new/` contra el
   manifiesto.
6. `-d` de `text-dup-m3.osr` = `text.bin`.
7. Corrupción del encoder: mueve un byte de literales a records, rehace
   `stat_size`/`footer_crc`; `--verify` pasa y `-d` da exit 4.
8. Vuelve a correr `tests/v6_read.sh` para comprobar que el lector no se
   rompió.

Resultado actual: `v6_read: PASS` y `v6_encode: PASS`.

Resultado actual: `v6_read: PASS`.

## 7. Huecos de `spec/` / límites (para el Equipo A)

La spec `14cfd76`/`931effa` cerró el digest VHASH-128, el orden de
`running_skip`, la identidad global y las obligaciones del encoder. Quedan:

1. **`-dup` de escritura.** El lector ya restaura `-dup`; el encoder todavía
   rechaza `-dup` con exit 2. La spec §2.10.8 describe el cuerpo deduplicado y
   la meta, pero no hace falta para el MVP actual.
2. **Otros `hash_id`.** La tabla declara MD5 (0), SHA-1 (2), SHA-512 (3) y
   SipHash-2-4 (5), pero el lector solo verifica VHASH-128 (4) y el caso sin
   digest. Con esos ids `-d` da un error claro de “digest hash id N is not
   implemented”; `--verify` sigue pasando. No hay fixtures para ellos.
3. **Opciones de encoder no equivalentes a SREP.** `-m4`/`-m5` son alias del
   mismo finder; `-aN/M` ignora `M`; `-c` es el paso de inserción del hash
   chain y `-l` el mínimo de match. La spec no fija estos detalles porque el
   match finder es libre, pero conviene documentarlos en la CLI.
4. **`-i` de `-dup`.** `original_size` es el tamaño del cuerpo deduplicado
   (101907 en `text-dup-m3.osr`), no el de la entrada restaurada (4 MiB). Si
   se quiere mostrar el tamaño final, hay que agregarlo al contrato de `-i`.
5. **Multiplataforma.** El código es Pascal puro; no se probó i386, ARM64 ni
   Windows en esta fase. No hay código nativo todavía.

## 8. Lo que no se hizo

- `-dup` de escritura (solo lectura/restauración).
- MD5/SHA-1/SHA-512/SipHash como digest (solo VHASH-128 y sin digest).
- stdin como entrada (`-`); stdout como salida sí funciona.
- `-m0..-m2` y el encoder `-dup`; se rechazan con exit 2.
- v1–v5 y compatibilidad con SREP.
- Código nativo (C/asm) y la matriz de plataformas.

## 9. L0 de `libosrep` (2026-11-10)

La librería no reimplementa el formato: envuelve el mismo `EncodeToStream` y
`TArchiveReader` que usa el CLI.

- `src/pascal/osrep_codec.pas`: API Pascal limpia (`TOsrepOptions`,
  `OsrepCompressBytes`, `OsrepDecompressBytes`, `EOsrepApiError`).
- `src/pascal/osrep_decoder.pas`: `CreateFromStream` (un `TStream`, no solo
  un archivo) y `DecodeToBytes`; `FBlocks`/`FAllLiterals` pasaron de variables
  de unidad a campos de `TArchiveReader`, para que dos hilos no compartan
  estado.
- `src/pascal/osrep_crc.pas`: la tabla CRC-32C se inicializa al cargar la
  unidad, no en la primera llamada, para que no haya una carrera entre hilos.
- `include/osrep.h`: `osrep_options`, `osrep_compress`, `osrep_decompress`,
  `osrep_free`, `osrep_last_error`, `osrep_version`.
- `src/lib/osrep_lib.pas`: `library` FPC con `exports`, `IsMultiThread` y
  `threadvar` para el error; ninguna excepción cruza la ABI.
- `src/lib/build.sh` y `src/lib/test_lib.c`; `tests/lib.sh` compila la
  librería, corre 54 checks propios, el corpus, 4 hilos, y compara el `.osr`
  con el del CLI (default y `--seed=7`), además de leer los fixtures v6 y
  `text-dup-m3.osr` desde la librería.

`seed = 0` en `osrep_options` significa el default determinista del CLI
(`SeedFromNumber(0)`), no una semilla aleatoria. `max_output` se comprueba
contra el `origsize` del header antes de reservar la salida.
