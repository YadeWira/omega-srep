# OREP: dedup de largo alcance en streaming (reemplazo de REP)

**Estado: 0.0.2, pre-release (2026-11-17).** Formato `spec/orep-format.md`,
versión 1, en borrador (puede cambiar hasta que se congele).

OREP es un preprocesador de una pasada, en streaming, que va delante de un
compresor (lzma, zstd...). Saca las repeticiones largas dentro de una
ventana de hasta ~3,75 GB y deja el resto como literales. Se escribió para
**PArc**, que necesita reemplazar REP de FreeArc (GPL) por algo MIT. Es
clean-room: no se leyó `rep.cpp` ni `srep.cpp`, y el formato es propio. Vive
en este repo junto a OSREP, con releases aparte (`orep-vX.Y.Z`).

## Diseño

- **Ring de la ventana.** La entrada entra a un ring de
  `ceil(W/C)*C + C` bytes por slots de C bytes (default 4 MiB). Cada slot
  lleno, o un flush, o el final, se busca y sale como un bloque.
- **Anclas por contenido.** Un gear hash (`h = 2h + T[byte]`) marca anclas
  donde unos bits del hash, todos dentro de los últimos `gram` bytes, son
  cero: más o menos una cada `s` posiciones, más una forzada si pasan `4s`
  sin ninguna (para corridas y períodos cortos). `gram = min(32, L/2)` y `s`
  es la potencia de 2 más grande que entra en `(L - gram + 1) / densidad`.
- **Tabla.** Buckets de 4 entradas (32 bytes, una línea de caché) con tag de
  32 bits y posición; como mucho una entrada por gram (la copia nueva
  reemplaza la vieja), la más nueva primero. Se hace prefetch del bucket 16
  anclas antes y de los bytes del candidato 6 anclas antes.
- **Match.** Un candidato se verifica y se extiende hacia adelante y hacia
  atrás. El largo se recorta a un múltiplo de `-a`. Un match que llega al
  final del bloque sigue en el bloque siguiente con la misma distancia.
- **Bloque.** Primero las tres columnas (literales antes, largo, distancia,
  en varints), después un relleno de ceros para que cada literal quede en su
  posición de entrada módulo `-a`, los literales y el CRC-32C del bloque.
- **Decodificador.** Solo necesita el ring. Cada bloque se valida antes de
  copiar nada (largos, distancias contra la ventana y contra el inicio del
  stream, tamaño de columnas, relleno) y se emite recién después de comprobar
  el CRC. Con datos dañados nunca lee ni escribe fuera del ring. `-M` o el
  `MemLimit` de la API rechazan un stream que pida más memoria.
- **Determinismo.** Los mismos parámetros dan los mismos bytes en todas las
  plataformas. El núcleo en C (`src/c/orep_core.c`) y la referencia en Pascal
  (`-dOREP_NO_NATIVE`) dan el mismo stream, y lo verifica `tests/orep.sh`.

## API (`src/orep/orep.pas`)

Estilo zlib, sin callbacks y sin estado global: un estado por hilo.

```pascal
var P: TOrepParams; E: TOrepEnc; D: TOrepDec;

OrepParamsDefault(P);        { W 512 MiB, -l64, -a4, bloque 4 MiB }
P.Window := 96 shl 20;
P.SizeHint := TamanoTotal;   { opcional: ventana más chica si entra }
OrepEncInit(E, P);
R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut,
                OREP_RUN | OREP_FLUSH | OREP_FINISH);
OrepEncEnd(E);

OrepDecInit(D, MemLimit);    { 0 = sin límite }
R := OrepDecRun(D, NextIn, AvailIn, NextOut, AvailOut);
OrepDecEnd(D);
```

`Run` devuelve `OREP_OK` (llamar de nuevo con más entrada o más lugar),
`OREP_END` (stream completo y todo escrito) o un error negativo.
`OrepEncodeBuf`/`OrepDecodeBuf` hacen un buffer entero. `OrepEncMemory(P)`
y `OrepDecMemory(W, C)` dan el máximo que va a reservar cada lado, para un
limitador de memoria.

Para enlazar: `orep.pas` más `orep_core.o` del target (el paquete
`orep-unit-<ver>.tar.gz` del release los trae para Linux x86_64/x86/arm64 y
Windows x64/x86). El objeto no usa la libc.

## Memoria

| ventana | -l | encoder | decoder |
|---:|---:|---:|---:|
| 96 MiB | 64 | ~270 MB | ~135 MB |
| 96 MiB | 512 | ~150 MB | ~135 MB |
| 512 MiB | 512 | ~590 MB | ~530 MB |

El encoder es ring + tabla (`32 * 2^tbits`, con `2^tbits` ≈ `W / (4s)`); el
decoder, ring más las columnas de un bloque.

## Números (2026-11-17)

Contra REP de FreeArc'Next 0.11 (`-mrep:96m`, su default `-l512`), cada
salida comprimida con lzma igual al de `parc -m4`
(`lzma:96m:normal:16:mc8:lc4`, simulado con
`xz --format=raw --lzma1=dict=96MiB,lc=4,lp=0,pb=2,mode=normal,nice=16,mf=hc4,depth=8`).
OREP con `-w96m` y los defaults (`-l64 -a4`):

| corpus | sin preproc. | REP | OREP | contra REP |
|---|---:|---:|---:|---:|
| zpaqstd-history.tar | 6.475.595 | 6.330.866 | 6.247.803 | **−1,31 %** |
| versions.tar | 5.474.742 | 5.440.237 | 5.393.973 | **−0,85 %** |
| silesia.tar | 54.704.070 | 54.769.356 | 54.333.022 | **−0,80 %** |
| enwik8 | 30.339.891 | 30.338.496 | 30.261.237 | **−0,25 %** |
| pja.tar | 1.371.469 | 1.361.970 | 1.360.143 | **−0,13 %** |
| game-assets.tar | 303.578.873 | 303.520.426 | 303.365.351 | **−0,05 %** |

Con texto y versiones rinde más `-l32 -a1`: history −1,90 %, versions
−1,44 %, enwik8 −0,98 %, pja −0,56 %; en binarios (silesia, juegos) es peor
que `-a4`. Por eso PArc puede usar `-l32 -a1` en su grupo de texto y
`-l64 -a4` en el binario.

Con un lzma fuerte detrás (el de `parc -m7`: `lzma:64m:max`, bt4 con nice
273, simulado con `--lzma1=dict=64MiB,...,nice=273,mf=bt4`) los matches
cortos sobran, porque lzma ya los encuentra. Contra `-mrep:512m`:

| corpus | REP | OREP `-l512 -a4` | OREP `-l512 -a4 -s16` | OREP `-l64 -a4` |
|---|---:|---:|---:|---:|
| silesia.tar | 48.615.525 | **−0,47 %** | | +1,15 % |
| tilin_512m.tar | 249.113.518 | **−0,03 %** | | +0,21 % |
| versions.tar | 4.660.290 | +0,11 % | +0,05 % (empate) | +1,84 % |
| zpaqstd-history.tar | 5.381.975 | +0,13 % | −0,00 % (empate) | +2,18 % |

**Parámetros sugeridos para PArc**, según el lzma que va detrás:

| preset de PArc | lzma | OREP |
|---|---|---|
| -m1, -m2 (`rep:96m:256:c256`, rápidos) | tor / LZ propio | `-w96m -l256` |
| -m3 .. -m5 (y `4x4:lzma:24mb`) | normal, dict 16–96 MB | `-w96m -l64 -a4`; grupo de texto `-l32 -a1` |
| -m6 .. -m9 | `max`, dict menor que la ventana | `-w<ventana> -l512 -a4 -s16` |

Lo que se aprendió en el camino:

- **La alineación pesa.** Quitar un match de largo cualquiera corre la
  posición de todo lo que sigue, y lzma modela la posición (pb2). Con largos
  múltiplos de 4 silesia pasa de +0,29 % a −0,66 % contra REP; el relleno
  que alinea los literales después de las columnas lo lleva a −0,80 %.
  `-a16` es peor que `-a4` en todos.
- **Las columnas cuestan poco** (silesia `-l512`: 41 KB comprimidas de
  54,8 MB). La pérdida de un dedup delante de lzma está en que se corren las
  distancias entre los datos que quedan y lzma pierde sus rep-matches.
- **Distancia mínima (`-D`).** Dejarle a lzma los matches que alcanza solo
  no ayudó en estos corpus; queda como opción.
- **tilin_512m** (el corpus de PArc) casi no tiene repeticiones lejanas:
  todo empata (±0,1 %) con lzma de 96 MB y con lzma de 64 MB en `max`.

## Hilos (0.0.2)

`P.Threads` (CLI `-t<n>`): con 2 o más, un hilo coordinador corre la
búsqueda ayudado por `Threads - 1` workers, y el hilo del que llama copia la
entrada del bloque siguiente y escribe la salida del anterior mientras
tanto. **El stream es el mismo con cualquier número de hilos** (lo verifica
`tests/orep.sh` con 1, 2, 3, 4 y 8, y con el build de referencia). Si un
hilo no se puede crear, sigue con los que tiene; sin thread manager
(programa Unix sin `cthreads`) usa solo el hilo del que llama.

La búsqueda de un bloque va por tramos de 8 segmentos de 64 KiB, en cuatro
fases:

1. **Anclas**, por segmento, en paralelo. Son locales al segmento (el gear
   hash y la cuenta de anclas forzadas empiezan en cada segmento). La pasada
   no tiene saltos: primero las anclas naturales, después se intercalan las
   forzadas.
2. **Tabla**, en paralelo por shards de buckets: cada bucket es de un solo
   hilo y se recorre en orden, así que la tabla termina igual con cualquier
   reparto. Las anclas se agrupan por dueño con un ordenamiento por conteo
   estable, y cada hilo escribe sus candidatos en el orden de su lista.
3. **Verificación**, por segmento, en paralelo: largos adelante y atrás de
   cada candidato, acotados a lo que hace falta para decidir.
4. **Elección**, secuencial y barata: decide con los largos acotados y
   extiende del todo solo los matches aceptados.

El ring del encoder tiene un slot más que el del decoder, para que el hilo
del que llama pueda llenar el siguiente mientras la búsqueda lee el más
viejo. Los workers esperan girando, después con yield y recién después
duermen (despertar un hilo cuesta ~0,5 ms en esta máquina).

Tiempos de pared (Xeon E5 v4 con carga de otros agentes, mejor de 3,
tilin_512m, `-w96m`):

| | 1 hilo | 4 hilos | 8 hilos | REP (FreeArc'Next, ~5 hilos) |
|---|---:|---:|---:|---:|
| `-l512` | 1,5 s | **0,57 s** | 0,53 s | 0,77–0,81 s (`rep:96m`) |
| `-l256` | 1,7 s | **0,70 s** | 0,62 s | 0,73 s (`rep:96m:256:c256`) |
| `-l64` | 3,2 s | 1,46 s | 1,4 s | — |

TILIN.tar entero (1,86 GB), `-l512 -t4`: 2,33 s y 1.343.009.625 bytes de
salida, contra 2,54 s y 1.415.525.869 de REP 96m (y 155 MB de RSS contra
245 MB). Con `-l64` la búsqueda es más cara (la tabla tiene una entrada cada
~8 bytes y escala mal entre los dos sockets de esta máquina); en los presets
donde rinde (lzma normal) lzma tarda cien veces más que OREP.

El decoder saca 0,7–1 GB/s.

## Pruebas

`tests/orep.sh`: idas y vueltas con varios parámetros (incluidas ventanas de
64 KiB que dan muchas vueltas al ring), nativo == referencia byte a byte,
stdin/stdout, límite de memoria y 300 streams truncados o dañados (ninguno
cuelga ni se decodifica mal). Los cinco binarios del release (Linux
x86_64/x86/arm64 con qemu, Windows x64/x86 con wine) dan el mismo stream.
