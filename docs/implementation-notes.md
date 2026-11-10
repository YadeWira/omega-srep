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
3. Decodifica los 9 fixtures no-dup (incluye `text-b1mb-m3` de 4 bloques y
   `text-hashnone-m3` sin digest) y compara byte a byte con la entrada.
4. `--verify` sobre los 10 (incluye `text-dup-m3.osr` y su `meta_crc`).
5. Corrompe un byte de un bloque: `--verify` y `-d` deben dar exit 4.
6. Corrompe un byte del meta: exit 4.
7. Cambia un byte del digest y rehace `block_crc`/`blocks_crc`/`footer_crc`:
   `--verify` debe pasar y `-d` debe dar exit 4 por digest.
8. Fija la salida de `-i` para `text-m3.osr`.
9. Prueba salida a stdout, opción desconocida (2), archivo inexistente (3) y
   `-d` sin argumento (2).

Resultado actual: `v6_read: PASS`.

## 7. Huecos de `spec/` (para el Equipo A)

La spec `14cfd76` cerró el hueco de VMAC (VHASH-128 sin nonce), el orden de
`running_skip`, la identidad global y el caso `hash_size=0`. Quedan:

1. **`-dup` no reconstruye la entrada original.** El lector valida el CRC del
   meta y decodifica el cuerpo deduplicado (que es lo que cubre el digest),
   pero no aplica la tabla de chunks de §2.8 para restaurar la entrada. Falta
   implementar el post-paso y su test.

2. **Otros `hash_id`.** La tabla declara MD5 (0), SHA-1 (2), SHA-512 (3) y
   SipHash-2-4 (5), pero el lector solo verifica VHASH-128 (4) y el caso sin
   digest. Con esos ids `-d` hoy termina en error de digest no implementado;
   `--verify` sigue validando el `block_crc`. No hay fixtures para ellos.

3. **Multiplataforma.** El código es Pascal puro; no se probó i386, ARM64 ni
   Windows en esta fase. No hay código nativo todavía.

## 8. Lo que no se hizo

- El digest VHASH-128 sí se verifica en `-d`; `--verify` valida el
  `block_crc` que cubre el digest en disco.
- No se interpreta la tabla de chunks del meta `DUPR` ni se aplica el
  post-paso de `-dup`; `-d` de un `-dup` entrega el cuerpo deduplicado.
- No se soporta stdin (`-` como entrada); sí stdout como salida.
- No se implementan opciones de encoder (`-m*`, `-l`, `-c`, `-b`, `-hash=`,
  etc.); se rechazan como opciones desconocidas con exit 2.
