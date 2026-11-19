# OREP: dedup de largo alcance en streaming (reemplazo de REP)

**Estado: 0.0.5, pre-release (2026-11-18).** Formato `spec/orep-format.md`,
versión 3, en borrador (puede cambiar hasta que se congele).

OREP es un preprocesador de una pasada, en streaming, que va delante de un
compresor (lzma, zstd...). Saca las repeticiones largas dentro de una
ventana de hasta ~3,75 GB y deja el resto como literales. Se escribió para
**PArc**, que necesita reemplazar REP de FreeArc (GPL) por algo MIT. Es
clean-room: no se leyó `rep.cpp` ni `srep.cpp`, y el formato es propio. Vive
en este repo junto a OSREP, con releases aparte (`orep-vX.Y.Z`).

## Diseño

- **Ring en slots (0.0.4).** El ring es un arreglo de slots de un chunk
  (potencia de 2), cada uno reservado cuando se usa por primera vez: no hay
  realloc, y la memoria es la que se usa (ver `docs/orep-audit-2026-11-18.md`).
- **Ring de la ventana.** La entrada entra a un ring de
  `ceil(W/C)*C + C` bytes por slots de C bytes (default 4 MiB). Cada slot
  lleno, o un flush, o el final, se busca y sale como un bloque.
- **Anclas por contenido.** Un gear hash (`h = 2h + T[byte]`) marca anclas
  donde unos bits del hash, todos dentro de los últimos `gram` bytes, son
  cero: más o menos una cada `s` posiciones, más una forzada si pasan `4s`
  sin ninguna (para corridas y períodos cortos). `gram = min(32, L/2)` y `s`
  es la potencia de 2 más grande que entra en `(L - gram + 1) / densidad`.
- **Candidatos (0.0.3).** El bucket guarda hasta cuatro copias del mismo
  gram; la verificación compara hasta 256 bytes hacia adelante con cada una
  y se queda con la que más coincide (`-c1`: una entrada por gram, como en
  0.0.2).
- **Alineación por bloque (0.0.3).** Con `-a0` (default) cada bloque se
  alinea a 1 si ~4096 bytes repartidos en él son en un 90 % texto ASCII, y
  a 4 si no; el valor va en la cabecera del bloque.
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

## Números de 0.0.3 (2026-11-18)

Contra REP (`-mrep:96m`), con el lzma de `parc -m4` detrás, OREP `-w96m`:

| corpus | REP | OREP 0.0.3 (`-l64`, defaults) | OREP 0.0.3 `-l32` |
|---|---:|---:|---:|
| zpaqstd-history.tar | 6.330.866 | 6.196.536 (**−2,12 %**) | 6.130.784 (**−3,16 %**) |
| versions.tar | 5.440.237 | 5.367.412 (**−1,34 %**) | 5.317.780 (**−2,25 %**) |
| silesia.tar | 54.769.356 | 54.158.366 (**−1,12 %**) | 53.963.072 (**−1,47 %**) |
| enwik8 | 30.338.496 | 30.232.499 (**−0,35 %**) | 29.997.573 (**−1,12 %**) |
| game-assets.tar | 303.520.426 | 303.280.014 (**−0,08 %**) | 303.508.638 (−0,00 %) |
| tilin_512m.tar | 255.185.911 | 254.908.393 (**−0,11 %**) | 255.183.951 (−0,00 %) |

(0.0.2 con sus defaults: −1,31, −0,85, −0,80, −0,25, −0,05 y −0,03 %.)
Lo que aportó cada cambio, contra 0.0.2:

- **Cuatro candidatos** (`-l64 -a4 -c4`): silesia −0,27 %, history −0,41 %,
  versions −0,25 %, enwik8 −0,03 %, juegos −0,03 %. Más anclas en vez de
  más candidatos (`-s16`, cuatro veces más) daba menos (−0,30 / −0,30 /
  −0,17 / −0,02 %) y cuadruplicaba la tabla. Menos anclas (`-s2`) perdía
  hasta 0,76 %.
- **Alineación por bloque**: deja `-a1` en el texto y `-a4` en lo binario;
  con `-l32` gana en todo (en 0.0.2, `-l32 -a1` perdía 0,55 % en silesia).

Tiempo (4 hilos, mejor de 5 intercalado, máquina compartida, tilin_512m,
`-l512`): 0.0.2 0,55 s; 0.0.3 0,65 s (`-c1 -a4`: 0,59 s); REP 0,77–0,83 s.
`-l64` cuesta ~4 veces `-l512` y `-l32` ~8 veces, sobre todo por la tabla.

## Números de 0.0.1 (2026-11-17)

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
| -m1, -m2 (`rep:96m:256:c256`, rápidos) | tor / LZ propio | `-w96m -l256 -c1` (a la par de REP en tiempo) o `-l128 -c1` (gana en todo, 1,6× el tiempo) |
| -m3 .. -m5 (y `4x4:lzma:24mb`) | normal, dict 16–96 MB | 0.0.3: `-w96m -l64` (defaults), o `-l32` si sobra tiempo; grupo de texto `-l32` |
| -m6 .. -m9 | `max`, dict menor que la ventana | 0.0.4: `-w<ventana> -l512 -a4 -s8` |

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

**Presupuesto de hilos (0.0.5).** `P.OnWorkerBusy` / `P.OnWorkerIdle`
(con `P.HookCtx`) son callbacks opcionales: los llaman los hilos de OREP
(workers y coordinador) al empezar a trabajar y antes de bloquearse a
esperar, para que un programa con un presupuesto global de hilos (PArc,
`PARC_THREADS`) tome y devuelva una ficha por hilo. `Busy` puede bloquear
hasta que haya ficha: un worker se suma a un trabajo solo mientras quedan
ítems, así que la búsqueda nunca espera a uno que todavía no llegó. La
espera activa corta entre trabajos cuenta como ocupado. `tests/orep_api.lpr`
lo prueba con 5 hilos y 2 fichas: mismos bytes, nunca más de 2 ocupados.

**Presupuesto, segunda vuelta (0.0.6).** Lo que midió PArc con 0.0.5: con
hilos, OREP quedaba más lento que en línea, porque los workers giraban con
la ficha tomada entre trabajos y el hilo del que llama esperaba al
coordinador con la suya. Tres agregados, todos opcionales:

- `P.SpinUs` (CLI `-y`): cuánto gira un hilo ocioso antes de devolver la
  ficha y dormir, en microsegundos (por defecto 2000; 0 = enseguida).
- `P.OnCallerWaitBegin` / `End`: van alrededor de las esperas del hilo del
  que llama (dentro de `OrepEncRun`, `OrepEncReset`, `OrepEncEnd`), solo si
  de verdad va a bloquear, para que devuelva su ficha mientras tanto.
  **Si el que llama tiene ficha y el presupuesto se puede agotar, hacen
  falta** (o `OnWorkerTryBusy`): si no, el que llama espera a un
  coordinador que espera la ficha del que llama (deadlock; se reprodujo
  con 4 encoders y 4 fichas).
- `P.OnWorkerTryBusy` (no bloquea, `True` = tomó una ficha): ningún hilo de
  OREP espera una ficha. Al empezar cada bloque, el que llama pide una para
  el coordinador; si no hay, busca el bloque él mismo. Al empezar cada
  tramo de 8 segmentos, el que busca pide fichas para sus ayudantes,
  despierta solo a esos, reparte el tramo en tantos shards (la tabla
  termina igual con cualquier reparto) y las devuelve al terminar el
  tramo. Con el presupuesto lleno funciona como `Threads = 1`; con fichas
  libres las usa.

Medido con `tools/scoreboard/orep_budget_bench.lpr` (N encoders a la vez sobre tilin_512m,
`-w96m -l256`, compartiendo 4 fichas; cada hilo que llama tiene una;
segundos de pared, Xeon compartido, dos corridas):

| | 1 hilo (en línea) | 4 hilos, Busy + caller, `SpinUs 2000` (la espera de 0.0.5) | 4 hilos, `SpinUs 0` + caller | 4 hilos, `TryBusy` + caller, `SpinUs 200` |
|---|---:|---:|---:|---:|
| 4 encoders (presupuesto lleno) | 1,97–2,12 | 4,72–5,00 | 2,82–2,90 | **2,03–2,08** |
| 1 encoder (fichas libres) | 1,66–1,89 | 1,22 | 1,54–1,73 | **1,15–1,24** |

Recomendación para PArc: `Threads = 4`, `OnWorkerTryBusy`, los dos hooks
del que llama y `SpinUs = 200`. Los bytes son los mismos en todos los casos
(y los mismos que 0.0.5).

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

Tamaño final con TILIN.tar entero y el lzma de `parc -m4`: REP 96m
1.017.365.357; OREP `-l512` 1.014.676.387 (−0,26 %), `-l256` 1.014.652.985
(−0,27 %), `-l64` 1.012.323.242 (−0,50 %).

El decoder saca 0,7–1 GB/s.

## Pruebas

`tests/orep.sh`: idas y vueltas con varios parámetros (incluidas ventanas de
64 KiB que dan muchas vueltas al ring), nativo == referencia byte a byte,
stdin/stdout, límite de memoria y 300 streams truncados o dañados (ninguno
cuelga ni se decodifica mal). Los cinco binarios del release (Linux
x86_64/x86/arm64 con qemu, Windows x64/x86 con wine) dan el mismo stream.
