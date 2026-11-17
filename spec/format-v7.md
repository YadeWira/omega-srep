# Formato `.osr` v7 — OSREP

**Estado: congelado en OSREP 0.0.15 (2026-11-16).** Lo escribe `-m6` (el
método de largo alcance y el default de la CLI) y lo leen el decoder,
`--verify`, `-i` y la biblioteca. Los demás métodos siguen escribiendo v6
(`format-v6.md`). Todo lector posterior tiene que decodificar igual los
archivos de `tests/fixtures/v7/` (sha256 fijos en su `manifest.tsv`). Un
cambio incompatible lleva otro número de versión y otro magic; lo que el
encoder decide (sección final) puede cambiar sin tocar el formato.

## Por qué un v7

`-m6` busca repeticiones en todo el archivo con un índice global. En v6 los
registros de cada bloque van entre el digest y los literales, ordenados por
`source`. Con un backend detrás (xz, zstd, zpaq), los dos detalles cuestan:

- los registros intercalados cortan el contexto de los literales cada 8 MiB
  y el contexto de los registros entre sí;
- el orden por `source` comprime peor que el orden por `destination`.

Medido con `xz -9` sobre la salida de `-m6 -l512` (mismos matches): en el
historial de zpaq-std, v6 da 5.426.756 bytes. Con la tabla aparte en columnas
y por destino da 5.407.576 (−0,35 %) y con largos múltiplos de 16 da
5.401.136, contra 5.417.412 de REP 1 GB.

Las columnas son varints y no enteros de ancho fijo: con `-l64`, la tabla del
historial ocupa 513.687 bytes en varints contra 1.127.367 en anchos fijos, y
`zpaq -m1` (un LZ77 sin modelo de contexto) deja 7.903.216 contra 7.999.138;
con xz la tabla también sale más chica (314.044 contra 319.552). Como el encoder de `-m6` ya conoce
todos los matches antes de escribir, la tabla entera puede ir al principio.

## Layout

```
header (28 bytes)             igual que v6, con magic "OSR7" y version 7
seed (seed_size bytes)        igual que v6
match table (stat_size bytes)
  match_count    u64
  gap[count]      varint LEB128 cada uno
  length[count]   varint LEB128 cada uno
  distance[count] varint LEB128 cada uno
  table_crc      u32   CRC-32C de todo lo anterior de la tabla
bloque 1 .. bloque N
  literal_bytes  u32
  origsize       u32
  statsize       u32   = 0 siempre
  block_crc      u32   CRC-32C de digest || literales
  digest         hash_size bytes (sobre los origsize bytes reconstruidos)
  literales      literal_bytes bytes
footer (36 bytes)             igual que v6; stat_size = tamaño de la tabla
```

- Header: `flags` tiene que ser 0 (v7 no lleva meta de `-dup` todavía);
  `max_match` guarda el tamaño de bloque, como v6.
- Footer: `meta_offset` y `meta_size` en 0; `blocks_crc` es la cadena de los
  `block_crc` en orden, como v6.
- Los CRC son los de v6 (§2.5 de `format-v6.md`); los hashes de digest, la
  tabla de §2.6.

## Semántica de la tabla

Los matches están en orden de destino y no se pisan en destino:

```
prev_end = 0
para cada i en 0 .. match_count-1:
    dst_i    = prev_end + gap_i
    src_i    = dst_i - distance_i
    prev_end = dst_i + length_i
```

Las tres columnas van una después de la otra, `match_count` varints cada una,
y terminan justo antes de `table_crc`. Reglas: `length ≥ 1`, `distance ≥ 1`, `distance ≤ dst` (la fuente no queda
antes del inicio) y `dst + length ≤ original_size`. `distance < length` es
válido (copia solapada, byte a byte). Un match puede cruzar bordes de bloque
en destino y su fuente puede estar en cualquier bloque anterior o en el
mismo.

## Bloques

El bloque `k` cubre `[block_start, block_start + origsize)` de la salida
(`block_start` es la suma de los `origsize` anteriores). Sus literales son los
bytes de ese rango que ningún match cubre, en orden. El decoder recorre el
bloque: dentro de un match copia desde `src + (pos - dst)`; fuera, toma
literales. `literal_bytes` tiene que consumirse exacto.

## Lo que hace el decoder con la memoria

Conoce todos los matches antes del primer bloque, así que de lo ya escrito
guarda solo las páginas (4 KiB; más grandes si la salida pasa de 16 GiB) de
las que todavía copia algún match: la página `k` hace falta hasta el mayor
fin (`dst + length`) de los matches cuya fuente la toca, y se guarda solo
mientras ese fin quede más allá del bloque actual. El bloque actual se
decodifica en su propio búfer. La tabla no se guarda: se lee del archivo con
tres cursores (uno por columna, 64 KiB cada uno), una pasada para el cálculo
de páginas y otra al decodificar, y los literales y el digest de cada bloque
se leen directo a su lugar (el CRC del bloque se calcula al pasar). Cuesta
~24 bytes por página de la salida (fin, puntero, lista de liberación), el
búfer de un bloque y las páginas vivas: 7 MB de páginas en el tar de juegos
de 584 MB, donde guardar desde la fuente pendiente más vieja pedía 427 MB.
RSS medido (2026-11-16, `tools/scoreboard/v7-decoder-ram-2026-11-16.log`):
12–62 MB con `-l512` y 25–70 MB con `-l32 --align=1`, contra 26–65 y
25–96 MB con la tabla en arreglos. No depende de que la salida se pueda
releer (sirve para stdout); sí de que el archivo se pueda leer por
posición.

## Rechazos

Además de los de v6: `table_crc` distinto; `match_count` mayor que lo que
cabe (`(stat_size − 12) / 3`); un varint mal formado o bytes de más entre la
última columna y el CRC; un match fuera de las reglas de arriba; un
bloque con `statsize ≠ 0` o con más literales que bytes; literales que
sobran o faltan; matches después del último bloque; `flags ≠ 0`.

El decoder suma los `origsize` de los headers de bloque y comprueba que
caben en el área de bloques **antes** de reservar nada que dependa de
`original_size` (páginas y sus arreglos): un header con CRC válido pero un
`original_size` falso no puede hacerle reservar páginas enormes. Un varint
no mínimo (`80 00`) se acepta: decodifica al mismo valor.

`tests/fuzz_v7.sh` (2026-11-16) muta archivos v7 sabiendo su estructura
(campos de la tabla, del header y de los bloques, con los CRC recalculados
para llegar a las validaciones de fondo) y corre `-d` y `--verify` en un
build con chequeos de rango (`-Cr -Ct -CR`). Encontró el reparto de páginas
de arriba y una cuenta de páginas que daba la vuelta con `original_size`
cerca de 2^64; 20.000 casos limpios después del arreglo.

## Por qué la tabla va entera y no por segmentos (medido 2026-11-16)

La tabla entera al principio obliga a conocer todos los matches antes de
escribir. Se midió si convenía partirla (`tools/scoreboard/v7-table-ram-2026-11-16.log`):

- **Cuánto pesa.** Con `-l512` hay a lo sumo ~100 matches por MB de entrada
  (juegos; el historial ~54): ≈ 2,4 MB por GB en el encoder (24 bytes por
  match) y ≈ 3 MB por GB en el decoder. Con `-l32 --align=1`, hasta ~6.000
  por MB (silesia): ≈ 145 MB por GB en el encoder y ≈ 175 MB por GB en el
  decoder.
- **No es lo que limita al encoder.** Su índice cuesta 13–26 bytes por
  ventana indexada (una cada `-l/2` bytes): 52–104 MB por GB con `-l512` y
  0,8–1,6 GB por GB con `-l32`, 20–40 veces la lista de matches.
- **En el decoder se resuelve sin cambiar el formato.** Las columnas se
  leen con tres cursores sobre la tabla tal como está en disco (hecho, ver
  arriba), y el cálculo de páginas es una pasada más.
- **Partirla cuesta.** Con un segmento de tabla delante de cada S bytes de
  salida, mismos matches: con S = 16 MiB, de −0,05 a +0,12 %; con 64 MiB,
  de −0,07 a +0,14 % (historial con zstd), del orden del margen contra
  los rivales. Y no le sirve al decoder por sí sola: para soltar páginas
  necesita saber qué matches futuros las leen, que es justo lo que da la
  tabla entera.

Conclusión: la tabla se queda entera. La memoria del decoder con `-l32` se
bajó en la implementación, no en el formato.

## Lo que el encoder de `-m6` decide (no es formato)

- `-l` mínimo de match (default 512); ventana de hash y paso del índice =
  `-l/2`; `-c` cambia el paso.
- El encoder no guarda la entrada entera: el buscador lee por posición
  (`pread`) a través de un búfer fijo (ventana alrededor del cursor con
  historia, caché de fuentes por bloques y dos cachés de comparación), y una
  segunda pasada lee los bloques para sacar los literales. La memoria es ese
  búfer más el índice (≈ 16–32 bytes por ventana indexada, `n / paso`) y la
  lista de matches. Por eso la entrada tiene que poder releerse; stdin se
  guarda en memoria antes.
- Largo de cada match múltiplo de `--align` (default 16): los bytes que
  siguen a un match quitado conservan su posición módulo 16, que modelan los
  backends (los `pb` de LZMA, el código x86). En `mozilla` de silesia, un tar
  de ejecutables, pasa de +1,5 % a −0,1 % contra xz solo. Con un LZ77 sin
  modelo de posición (`zpaq -m1`) la alineación cuesta 0,1–0,9 % y conviene
  `--align=1`.
