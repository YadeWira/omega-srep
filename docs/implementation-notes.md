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
3. Decodifica los 8 fixtures no-dup (incluye `text-b1mb-m3`, 4 bloques) y
   compara byte a byte con la entrada.
4. `--verify` sobre los 9 (incluye `text-dup-m3.osr` y su `meta_crc`).
5. Corrompe un byte de un bloque: `--verify` y `-d` deben dar exit 4.
6. Corrompe un byte del meta: exit 4.
7. Fija la salida de `-i` para `text-m3.osr`.
8. Prueba salida a stdout, opción desconocida (2), archivo inexistente (3) y
   `-d` sin argumento (2).

Resultado actual: `v6_read: PASS`.

## 7. Huecos de `spec/` (para el Equipo A)

La spec del commit `6571fe5` cerró los huecos de CRC, footer, Future-LZ,
tabla de hashes y meta `DUPR`. Quedan estos:

1. **VMAC: falta el nonce/variante exacta.** `spec/format-v6.md` §2.6 fija
   `hash_id=4` = VMAC, digest 16, seed 32 y "la clave es el seed", pero no
   dice el nonce ni la variante. Con VMAC estándar (referencia pública
   fastcrypto) y `key=seed`:
   - VMAC-128, nonce cero, sobre `text.bin` → `ce6ea86669296bb64d7be2310d4c74cc`;
   - VMAC-256, nonce cero → `b1f50fa50803f99d81047942226696ce`;
   - el fixture espera `94303bebcecb2d284461e5972eebbaf0`.
   Probé también key/nonce = mitades del seed (16+16, 8+16), todos los
   offsets de 4 bytes, el índice/`block_start`/`origsize`/`literal_bytes`/
   `statsize` del bloque como nonce, y variantes de `VMAC_NHBYTES`/endian.
   Ninguna coincide. La implementación de VMAC está validada contra los
   vectores del draft `draft-krovetz-vmac-01` (key `abcdefghijklmnop`, nonce
   `bcdefghi`), así que el problema no es el algoritmo estándar: falta cómo
   deriva SREP la clave/nonce (o si usa una variante propia). **Sin ese dato
   no se puede verificar el digest sin rechazar los fixtures válidos.** Con
   `hash_id=4` el lector hoy no verifica el digest; `--verify` sí valida el
   `block_crc`, que cubre el digest tal como está en disco.

2. **`running_skip`: el pseudocódigo de §2.7 está invertido respecto de los
   fixtures.** La spec dice `source = block_start + running_skip` y después
   `running_skip += skip`; los fixtures requieren **sumar el `skip` antes**:
   `running_skip += skip; source = block_start + running_skip`. Con
   `text-m3` el primer record `(512, 4193280, 69)` da source 512/dest 581 (no
   0/69); con `text-b1mb` el primer bloque solo cuadra así. Corregir el
   pseudocódigo.

3. **`sum(length) + literal_bytes = origsize` no es por bloque.** En
   `text-b1mb`, el bloque 0 tiene `origsize=1048576`, `literal_bytes=1024` y
   `sum(length)=1083904`; la identidad vale para el archivo completo, porque
   un match puede empezar en el borde y seguir en el bloque siguiente. La
   spec lo dice como si fuera por bloque; aclarar que es global.

4. **`-dup` no reconstruye la entrada original.** El lector verifica el CRC
   del meta y decodifica el cuerpo deduplicado (que es lo que cubre el
   digest), pero no aplica la tabla de chunks para restaurar la entrada. La
   spec §2.8 ya describe la tabla; falta implementar el post-paso y su test.

5. **`-i`.** La spec ya fija el key=value de §5, así que este punto está
   cerrado; el test lo congela.

6. **`hash_size = 0`.** Se acepta `hash_id=0/hash_size=0` como "sin digest"
   (seed vacía), pero no hay fixture ni texto normativo que lo confirme.

7. **Multiplataforma.** El código es Pascal puro; no se probó i386, ARM64 ni
   Windows en esta fase. No hay código nativo todavía.

## 8. Lo que no se hizo

- No hay verificación del digest por bloque: falta el nonce/variante de VMAC
  (ver §7.1). `--verify` valida el `block_crc` que cubre el digest en disco.
- No se interpreta la tabla de chunks del meta `DUPR` ni se aplica el
  post-paso de `-dup`; `-d` de un `-dup` entrega el cuerpo deduplicado.
- No se soporta stdin (`-` como entrada); sí stdout como salida.
- No se implementan opciones de encoder (`-m*`, `-l`, `-c`, `-b`, `-hash=`,
  etc.); se rechazan como opciones desconocidas con exit 2.
