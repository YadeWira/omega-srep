# Implementación OSREP 0.0.2 — notas de la Fase 1a (lector v6)

**Equipo B (clean-room), 2026-11-10.** Este documento registra qué se
implementó, de dónde sale cada comportamiento y los huecos de `spec/` que
aparecieron. Nada de esto se dedujo del código legacy: sale de `spec/`,
`tests/fixtures/v6/` y documentación pública de SREP.

## 1. Alcance

- `src/pascal/osrep.lpr`: CLI.
- `src/pascal/osrep_crc.pas`: CRC-32C con tabla software.
- `src/pascal/osrep_format.pas`: header, footer, bloque, helpers LE.
- `src/pascal/osrep_decoder.pas`: lector v6, `-d`, `--verify`, meta `DUPR`.
- `tests/v6_read.sh`: build + aceptación.

No hay encoder, ni v1–v5, ni SREP.

Compilar y probar:

```sh
fpc -Mobjfpc -O2 -Sh -Fu./src/pascal -FU./tests/tmp/units \
    -FE./tests/tmp/build ./src/pascal/osrep.lpr
./tests/v6_read.sh
```

## 2. La diferencia importante: los fixtures v6 son Future-LZ

`spec/payload.md` §3 describe el record como LZ normal:

```
lit_len | match_len | distance
dest avanza lit_len desde el final del match anterior
```

Eso **no** describe los `.osr` v6 de Omega SREP 3.0.0. Los ocho fixtures usan
el modo Future-LZ (el default de SREP: `-m3f`), donde:

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
origsize(bloque) = literal_bytes + suma(match_len)
```

y que `sum(lit_len)` pueda ser mayor que `literal_bytes` (en `zruns-m3` es
238592 contra 104228): `lit_len`/`skip` no cuenta literales, cuenta el avance
del puntero de source.

## 3. CRC-32C: parámetros que fijan los fixtures

`spec/format-v6.md` dice solo "CRC-32C". Los fixtures usan:

- polinomio reflejado `0x82F63B78` (Castagnoli),
- valor inicial `0`,
- sin XOR final.

No es el CRC-32C "de catálogo" (init/xorout `0xFFFFFFFF`). Con los parámetros
de catálogo ningún CRC de los fixtures coincide; con init/xorout 0 coinciden
los tres (header, footer, block) y `blocks_crc`. Queda implementado así y
anotado como hueco en §7.

## 4. Reglas de lectura implementadas

- Header: `OSR6`, versión 6, `flags` solo bit0, `hash_id`/`hash_size` conocidos,
  `header_crc` sobre los 24 bytes anteriores.
- Seed: `hash_id=4`, `hash_size=16` ⇒ 32 bytes de seed (observado en los
  fixtures).
- Footer de **36** bytes (no 32): `OSRF`, `block_count`, `stat_size`,
  `meta_offset`, `meta_size`, `blocks_crc`, `footer_crc` sobre los 32
  anteriores.
- `block_count` del header = footer; `original_size` = suma de `origsize` de
  bloques; `stat_size` = suma de `statsize`.
- Bloques: header de 16 bytes, `block_crc` sobre `digest || records ||
  literales` tal como están en disco. `--verify` no descomprime.
- `literal_bytes == origsize` y `statsize != 0` ⇒ corrupto.
- `statsize == 0` ⇒ `literal_bytes == origsize` (bloque guardado).
- Meta `DUPR` solo con `flags.bit0`: `meta_offset + meta_size` termina en el
  footer, magic `DUPR`, versión 1 y `meta_crc` sobre todo el meta menos sus
  últimos 4 bytes. El contenido de la tabla de chunks no se interpreta.
- Cualquier byte entre el último bloque y el footer/meta, o cualquier tamaño
  que no cuadre, es corrupto (exit 4).

## 5. CLI y `-i`

- `--version` → `OSREP 0.0.2 (2026-11-10)`.
- `-d <archive> [<output>]`: salida derivada (`x.osr` → `x`; si no termina en
  `.osr`, `x` → `x.out`). `-` como salida escribe a stdout.
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
3. Decodifica los 7 fixtures no-dup y compara byte a byte con la entrada.
4. `--verify` sobre los 8 (incluye `text-dup-m3.osr` y su `meta_crc`).
5. Corrompe un byte de un bloque: `--verify` y `-d` deben dar exit 4.
6. Corrompe un byte del meta: exit 4.
7. Fija la salida de `-i` para `text-m3.osr`.
8. Prueba salida a stdout, opción desconocida (2), archivo inexistente (3) y
   `-d` sin argumento (2).

Resultado actual: `v6_read: PASS`.

## 7. Huecos de `spec/` (para el Equipo A)

1. **Records Future-LZ vs LZ normal.** `spec/payload.md` §3 describe LZ
   normal; los fixtures v6 de 3.0.0 son Future-LZ (source acumulado, records
   ordenados por source, decoder ordena por destination y rellena huecos con
   literales). Hay que corregir §3 o declarar explícitamente que v6 usa
   Future-LZ. Sin esto, un lector escrito desde la spec no lee los fixtures.
2. **Tabla de hashes.** No está documentado qué es `hash_id`, qué tamaños y
   seeds corresponden, ni qué algoritmo es `hash_id=4` (16 bytes de digest,
   32 de seed). Los fixtures solo permiten fijar ese caso. Tampoco está claro
   si el digest cubre el bloque reconstruido (todo apunta a que sí: `text-m3`,
   `text-m4` y `text-m5` tienen el mismo digest y reconstruyen el mismo
   `text.bin`).
3. **Digest no verificado.** El lector no puede verificar el digest de bloque
   porque falta el algoritmo/derivación de clave. `--verify` sí valida todo lo
   que pide la spec (header, footer, meta y `block_crc`). Falta que la spec
   fije el hash para completar la verificación de reconstrucción.
4. **Parámetros del CRC-32C.** La spec no dice init/xorout. Los fixtures usan
   init 0 y xorout 0. Hay que escribirlo.
5. **Tamaño del footer.** `spec/format-v6.md` §2.3 dice "footer (32 bytes)"
   pero lista 7 campos que suman 36 y `footer_crc` cubre "los 32 bytes
   anteriores". Los fixtures usan 36. Corregir el texto.
6. **Layout del meta `DUPR`.** `spec/payload.md` remite a
   `docs/format-spec.md` §3.1, que no está en esta rama. Solo se implementó
   lo necesario para `--verify` (magic, versión y CRC); la tabla de chunks no
   se valida ni se usa.
7. **`-i`.** La spec no fija formato. Se eligió el key=value de §5 y el test
   lo congela; si la golden nueva quiere otro, hay que cambiarlo en los dos
   lados.
8. **Bloques múltiples.** Los fixtures tienen un solo bloque. El lector
   soporta `block_count > 1` con sources locales al bloque, pero no hay
   fixture que lo pruebe. Falta un caso multi-bloque en `tests/fixtures/v6/`.
9. **`hash_size = 0`.** Se acepta `hash_id=0/hash_size=0` como "sin digest"
   (seed vacía), pero no hay fixture ni texto normativo que lo confirme.
10. **Multiplataforma.** El código es Pascal puro; no se probó i386, ARM64 ni
    Windows en esta fase. No hay código nativo todavía.

## 8. Lo que no se hizo

- No hay verificación del digest por bloque (ver §7.3).
- No se interpreta la tabla de chunks del meta `DUPR`.
- No se soporta stdin (`-` como entrada); sí stdout como salida.
- No se implementan opciones de encoder (`-m*`, `-l`, `-c`, `-b`, `-hash=`,
  etc.); se rechazan como opciones desconocidas con exit 2.
