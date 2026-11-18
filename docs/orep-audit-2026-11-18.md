# Auditoría: dónde pierde OREP 0.0.3 frente a REP (2026-11-18)

REP = FreeArc'Next 0.11 (`fa a -mrep:...`; al tamaño se le restan los 183
bytes del contenedor). OREP 0.0.3 (`72dba73`), CLI con 4 hilos. Máquina
compartida (Xeon E5 v4, dos sockets, load 20–27 durante las medidas); los
tiempos son el mínimo de 3 corridas intercaladas, con `sync` antes de cada
una (sin eso, las páginas sucias de una corrida frenaban a la siguiente y
los números no servían). Logs en `tools/scoreboard/orep.log`.

## Resumen

| # | dónde pierde | cuánto | causa | arreglo |
|---|---|---|---|---|
| 1 | **memoria con ventanas grandes** | 2× REP (1 GB: enc 2,64 GB vs 1,32; dec 2,17 GB vs 1,06) | el ring crece duplicándose con `ReAllocMem` (pico = viejo + nuevo) | ring en slots de C bytes, sin realloc |
| 2 | **velocidad del decoder con ventanas grandes** | 512 MB: 1,07 s vs 0,58; 1 GB: 2,48 s vs 1,81 | las mismas copias del realloc | el mismo |
| 3 | **velocidad de codificación con los defaults** (`-l64`) | 2,5–7× más tiempo de pared, 2–4× más CPU | la tabla (una consulta cada ~8 bytes, limitada por la memoria) | ninguno barato: es el precio de la compresión |
| 4 | velocidad con `-w512m -l512 -s16` (preset fuerte) | 2–3× más tiempo de pared | `-s16` = 4× anclas | usar `-s4` si el tamaño lo permite; medir |
| 5 | decoder con ventana chica | 0–35 % más lento (silesia 0,30 vs 0,22 s) | dos copias por literal (entrada→ring→salida) y emite recién después del CRC | revisar |
| 6 | memoria con ventana chica | enc 285 vs 244 MB (`-l64`), dec 136 vs 111 MB | tabla de `-l64`; ring + pico de realloc | el arreglo de #1 baja el decoder |
| 7 | compresión, casos sueltos | pja preset rápido +0,20 %; pja y versions con `lzma:max` +0,06 / +0,04 % | ver abajo | |
| 8 | costo fijo por stream | 37–49 bytes vs ~20 | cabecera de 28 bytes con campos fijos, fin con u64 | cabecera con varints |
| 9 | CLI frente a disco lento | trabas de varios segundos | lee y escribe sincrónico en el hilo que alimenta la búsqueda | escritura en otro hilo (solo CLI) |

Donde **gana**: tamaño en casi todo (ver 0.0.3), y con `-l256 -c1` o
`-l512` usa menos CPU que REP con un tiempo de pared parecido.

## 1–2. Memoria y decoder con ventanas grandes

TILIN.tar entero (1,86 GB):

| | salida | enc s | enc RSS | dec s | dec RSS |
|---|---:|---:|---:|---:|---:|
| REP `rep:1024m` | 1.058.162.109 | 5,18 | 1,32 GB | 1,81 | 1,06 GB |
| OREP `-w1024m -l512 -s16` | 1.057.461.441 | 7,77 | 2,64 GB | 2,48 | 2,17 GB |
| OREP `-w1024m -l64` | 992.268.865 | 11,51 | 3,17 GB | 2,45 | 2,10 GB |
| REP `rep:2040m` | 1.056.523.611 | 2,84 | 2,23 GB | 2,00 | 1,85 GB |
| OREP `-w2040m -l512 -s16` | 1.052.428.505 | 8,03 | 3,16 GB | 2,90 | 2,17 GB |

El decoder necesita un ring de W + C (1,03 GB con 1 GB de ventana) pero
llega a 2,17 GB: crece 512 MB → 1 GB → 1,03 GB copiando, y en cada paso
conviven los dos bloques. El encoder suma la tabla (W/4 con `-s16`) y lo
mismo con su ring. Con 512 MB de ventana y game-assets: enc 1,33 GB vs
0,73; dec 1,07 GB vs 0,54. Para PArc es lo más importante: su limitador de
memoria achica la ventana, y en 32 bits un ring contiguo de ese tamaño ni
siquiera se puede reservar.

## 3–5. Velocidad (pared / CPU usuario+sistema, segundos)

| corpus | REP 96m | OREP default | REP c256 | OREP `-l256 -c1` | OREP `-l512` | REP 512m | OREP `-w512m -l512 -s16` |
|---|---|---|---|---|---|---|---|
| silesia | 0,39/2,48 | 1,44/5,56 | 0,35/2,28 | 0,48/1,94 | 0,51/1,80 | 0,40/2,47 | 0,86/3,21 |
| history | 0,45/2,91 | 1,77/6,82 | 0,43/2,49 | 0,63/2,40 | 0,55/2,10 | 0,48/2,82 | 1,39/5,04 |
| juegos | 0,81/4,93 | 5,54/21,04 | 0,75/6,65 | 0,91/3,87 | 0,87/3,64 | 0,96/8,96 | 2,19/7,43 |
| tilin | 0,79/7,32 | 2,07/8,66 | 0,74/7,07 | 0,92/3,99 | 0,84/3,60 | 0,80/7,35 | 2,01/6,55 |

Decoder (pared): REP 0,22–0,61 s, OREP 0,26–0,78 s con ventana de 96 MB
casi a la par (silesia 0,30 vs 0,22 es el peor), y con 512 MB el problema
de #2.

REP usa ~6 hilos (su CPU es 6–9 veces su tiempo de pared); OREP tenía 4.

## 7. Compresión

Con el lzma rápido de `parc -m3` (`lzma:96m:fast:32:mc6:lc4`), REP `c256`
contra OREP `-l256 -c1`: silesia −0,69 %, history −0,20 %, enwik8 −0,03 %,
versions +0,01 %, **pja +0,20 %**. OREP con sus defaults gana en los cinco
(pja −0,71 %), pero es el preset rápido.

Con `lzma:max` (`parc -m7`), REP 512m contra OREP `-w512m -l512 -s16`:
silesia −0,49 %, history −0,09 %, **versions +0,04 %, pja +0,06 %**. Con un
lzma tan fuerte la alineación automática rinde un poco peor que `-a4` fijo
(history 5.378.662 vs 5.377.285), y en silesia ni REP ni OREP le ganan a no
preprocesar (48.371.088).

Con lzma normal (`-m4`) OREP gana en los siete corpus (0.0.3). Juegos y
tilin con `-l32` empatan.

## 8. Costo fijo

Datos al azar de 0 B a 1 MB: OREP agrega 37–49 bytes por stream (cabecera
28, cabecera de bloque + CRC ~10, fin 9); el formato de REP ~20. Solo pesa
con muchos bloques sólidos diminutos.

## Orden sugerido de arreglos

1. Ring en slots (encoder y decoder): baja la memoria a ~REP + tabla y
   saca las copias del decoder (#1, #2, parte de #6).
2. Cabecera compacta (#8) y revisar las copias del decoder (#5), mientras
   el formato siga abierto.
3. Para los presets rápidos de PArc, `-l256 -c1` / `-l512` ya están a la
   par de REP en tiempo; los defaults son para cuando manda lzma.

## Después de los arreglos (OREP 0.0.4, 2026-11-18)

| # | estado |
|---|---|
| 1 | **arreglado**: ring en slots de un chunk, reservados al usarse, sin realloc. TILIN.tar con 1 GB de ventana: decoder 2,17 → **1,06 GB** (REP 1,06), encoder `-l512 -s16` 2,64 → 1,60 GB (REP 1,32; la diferencia es la tabla) |
| 2 | **arreglado**: decoder 1 GB 2,6 → **1,5 s** (REP 1,8); 512 MB juegos 1,10 → **0,58 s** (REP 0,58), 533 MB (REP 537); silesia 96 MB 0,21 s y 107 MB (REP 0,22 s, 111 MB) |
| 3 | sin cambio (el precio de la compresión de `-l64`) |
| 4 | **mitigado**: con 4 candidatos alcanza `-s8` en el preset fuerte: `-w512m -l512 -s8 -a4` 0,97 s vs 1,38 con `-s16` (REP 0,79 s), y en `lzma:max` versions +0,04 %, pja +0,01 %, history −0,03 %, silesia −0,49 % contra REP |
| 5 | **arreglado** con #2 |
| 6 | decoder arreglado con #1; encoder sin cambio (tabla) |
| 7 | preset rápido: `-l128 -c1` gana en los cinco corpus contra REP `c256` (pja −0,12 %, enwik8 −0,12 %, versions −0,54 %, silesia −0,81 %, history −1,12 %) en 1,09 s vs 0,68 (tilin); `-l256 -c1` empata en tiempo (0,67 s) y pierde solo en pja (+0,20 %) |
| 8 | **arreglado**: cabecera compacta (formato 3), 19–32 bytes por stream (REP ~20) |
| 9 | probado: lectura y escritura en hilos aparte en la CLI no mejoró (el disco compartido es el límite, con o sin hilos de 0,8 a 7 s); se descartó. La biblioteca no hace E/S. |
