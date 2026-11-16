# Formato `.osr` v7 — OSREP (borrador interno)

**Estado: borrador, 2026-11-15.** Lo escribe `-m6` (el método de largo
alcance) y lo leen el decoder, `--verify` y `-i`. Los demás métodos siguen
escribiendo v6 (`format-v6.md`). Nada de esto se publicó: el formato puede
cambiar hasta que se congele.

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
5.401.136, contra 5.417.412 de REP 1 GB. Como el encoder de `-m6` ya conoce
todos los matches antes de escribir, la tabla entera puede ir al principio.

## Layout

```
header (28 bytes)             igual que v6, con magic "OSR7" y version 7
seed (seed_size bytes)        igual que v6
match table (stat_size bytes)
  match_count    u64
  gap[count]     u64 LE cada uno
  length[count]  u64 LE cada uno
  distance[count] u64 LE cada uno
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

Reglas: `length ≥ 1`, `distance ≥ 1`, `distance ≤ dst` (la fuente no queda
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

Conoce todos los matches antes del primer bloque, así que solo guarda los
bytes desde la menor fuente de los matches que todavía no terminaron (un
mínimo de sufijos sobre la tabla). Cuesta 32 bytes por match más esa
ventana.

## Rechazos

Además de los de v6: `table_crc` distinto; `match_count` que no coincide con
`stat_size` (`8 + 24·count + 4`); un match fuera de las reglas de arriba; un
bloque con `statsize ≠ 0` o con más literales que bytes; literales que
sobran o faltan; matches después del último bloque; `flags ≠ 0`.

## Lo que el encoder de `-m6` decide (no es formato)

- `-l` mínimo de match (default 512); ventana de hash y paso del índice =
  `-l/2`; `-c` cambia el paso.
- Largo de cada match múltiplo de 16 (`OsrepLrAlign`): los bytes que siguen a
  un match quitado conservan su posición módulo 16, que modelan los backends
  (los `pb` de LZMA, el código x86). En `mozilla` de silesia, un tar de
  ejecutables, pasa de +1,5 % a −0,1 % contra xz solo.
