# API embebible de `-m6` (`osrep_m6.pas`)

**Desde 0.0.16 (2026-11-26).** Para programas que llevan OSREP adentro, como
PArc (reemplazo de su etapa `srep`, GPL). Es `-m6` (formato `.osr` v7,
congelado) de memoria a memoria, en una unidad Pascal con los fuentes en C
que se pueden copiar a otro repo, como `src/orep`. No reemplaza a
`libosrep` (la `.so` con ABI de C de `docs/osrep-library.md`, que escribe
v6): es otra puerta al mismo encoder y decoder.

## Uso

```pascal
uses osrep_m6;
var P: TOsrepM6Params; Cap, Len, Orig: QWord; R: LongInt;

OsrepM6ParamsDefault(P);          { -l512, --align=16, bloques de 8 MiB, sin digest }
Cap := OsrepM6Bound(SrcLen, P);   { el stream nunca pasa de esto }
R := OsrepM6Encode(Src, SrcLen, Dst, Cap, Len, P);

R := OsrepM6OrigSize(Stream, StreamLen, Orig);
R := OsrepM6Decode(Stream, StreamLen, Out, Orig);   { Out de Orig bytes exactos }
```

- Devuelve `OSREP_M6_OK` o un código (`OsrepM6ErrorText`, y el mensaje en
  `OsrepM6LastError`, por hilo). No lanza excepciones.
- Sin estado global: varias llamadas pueden correr a la vez en hilos
  distintos.
- Tamaños de 64 bits. Probado con 6,5 GiB y repeticiones que cruzan 2^31,
  2^32 y 3·2^31 (`tests/osrep_m6_big.sh`).
- El stream es un `.osr` v7 normal: `osrep -d` lo decodifica y
  `OsrepM6Decode` decodifica los del CLI. Con los mismos parámetros, los
  bytes son los de `osrep -m6 -l<MinLen> --align=<Align> -b<BlockSize>`
  (más `-hash-` sin digest).

### Parámetros (`TOsrepM6Params`)

| campo | default | rango | qué hace |
|---|---|---|---|
| `MinLen` | 512 | 32..65536 | match más corto. 512 delante de lzma/zstd/plz; 64 delante de un LZ sin modelo; 32 sin backend |
| `Align` | 16 | 1..4096 | los largos son múltiplos de `Align`: 16 no corre la posición módulo 16 que modela lzma; 1 sin backend |
| `BlockSize` | 8 MiB | 64 KiB..256 MiB | bloque de literales del stream; no cambia los matches |
| `Threads` | 1 | ≥ 0 | presupuesto de hilos: la búsqueda corre en el hilo que llama y no crea otros |
| `Digest` | no | | VHASH-128 por bloque. Sin él quedan los CRC-32C de la tabla y de cada bloque |

## Memoria

Aparte de la entrada y la salida:

- **Encoder: `OsrepM6EncMem(SrcLen, P)`**, una cota. El índice
  (`2^t` buckets de 24 bytes, con `2^t` ≥ entradas/2 y una entrada cada
  `MinLen/2` bytes: 4,7–9,4 % de la entrada con `-l512`), el filtro de bits
  (~0,8–1,6 %; hasta 0.0.17, la mitad), la lista de matches (24 bytes por
  match, contada en su peor caso, `SrcLen/MinLen`, y con el crecimiento por
  duplicación) y dos trozos de 256 KiB en curso (desde 0.0.18: las
  posiciones que vale la pena buscar, 16 bytes cada una; en el peor caso
  todas, ~25 MB). Medido con
  6,5 GiB y `-l512`: pico de 416 MB anónimos contra una cota de 1.353 MB;
  con 300 MB, 26 contra 73 MB.
- **Decoder: `OsrepM6DecMem`**, ~1 MiB: cuatro cursores de 64 KiB sobre el
  stream. Escribe en el búfer de salida y copia las fuentes de los matches de
  ahí mismo, así que no guarda páginas ni bloques. Con digest, más un bloque.
  Medido: 1 MB con 6,5 GiB.

## Archivos para copiar

`scripts/build_osrep_unit.sh` arma `osrep-unit-<ver>.tar.gz`:

- `src/pascal/`: `osrep_m6`, `osrep_encoder`, `osrep_decoder`,
  `osrep_format`, `osrep_crc`, `osrep_vhash`, `osrep_aes`;
- `src/c/`: `osrep_lr.c`, `osrep_match.c`, `osrep_vhash_nh.c`,
  `osrep_crc_native.c` (no llaman a la libc);
- `obj/<target>/`: esos cuatro objetos para linux-x86_64, linux-x86,
  linux-arm64, win64 y win32;
- `LICENSE` (MIT), `VERSION`, `README.md`.

Con `-dOSREP_NO_NATIVE` todo es Pascal y no hace falta ningún objeto: mismos
streams, más lento.

## Pruebas

- `tests/osrep_m6.sh` (también en el CI de macOS):
  - `tests/osrep_m6_test.lpr self` con el build nativo y el de referencia
    (150.108 checks): ida y vuelta de 5 juegos de parámetros × 4 tipos de
    entrada × 6 tamaños, la cota, búfer de salida corto, búfer de decodificar
    de otro tamaño, todos los truncados y bytes cambiados (en streams
    chicos; una muestra en los grandes), un byte de más, cabecera v6, y 4
    hilos a la vez;
  - el API y el CLI escriben los mismos bytes (7 corpus × 4 juegos de
    parámetros, nativo y referencia) y cada uno decodifica los del otro;
  - un stream v6 se rechaza.
- `tests/fuzz_v7.sh`: el decoder en su lugar del API corre junto a
  `osrep -d` en cada caso mutado; tienen que dar el mismo veredicto y, si
  aceptan, los mismos bytes (4.000 casos, build con chequeos de rango).
- `tests/osrep_m6_big.sh <dir> [6656m]` (aparte; minutos y ~3× el tamaño en
  disco): 6,5 GiB de `tests/orep_bigsrc.c` por archivos mapeados en memoria,
  ida y vuelta, el mismo stream que el CLI y el CLI lo decodifica.
- Mismo stream y mismos bytes al decodificar en linux-x86_64, linux-x86,
  linux-arm64 (qemu), win64 y win32 (wine), y con los objetos del paquete.
