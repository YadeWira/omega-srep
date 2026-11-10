# Benchmarks — línea base vs SREP y Omega SREP

**Fecha: 2026-11-10.** Primera línea base del proyecto, antes de optimizar.
Nada de esto es una promesa: son los números de hoy y el punto de partida.

## Máquina y binarios

- CPU: Intel Xeon E5-2697A v4 @ 2.60 GHz, x86-64 (64 hilos visibles).
- OSREP 0.0.4, compilado con FPC 3.2.2 `-O2` (sin C/asm todavía), con
  codificación paralela de bloques (`-tN`, default automático hasta 8).
- SREP 3.92 beta (2013-07-23), binario `srep64` de
  `repo-extras/srep392.zip`. No hay binario de 3.93a en el árbol; 3.92 es
  la referencia publicada más cercana.
- Omega SREP 3.0.0, binario `osrep-linux-x86_64` de `release-3.0.0`.
- Entrada: `real64.bin`, 64 MiB de datos reales del bench de r240.
- Tiempos de pared, una corrida; el ruido de la máquina es de decenas de ms.

## Resultados

| herramienta | ajustes | salida (bytes) | ratio | tiempo |
|---|---|---:|---:|---:|
| OSREP | `-m3` (default: `-l4 -c1 -a16`, `-t` auto) | 39.551.315 | 58,94 % | 1,23 s |
| OSREP | `-m4` (default, `-t` auto) | 38.353.352 | 57,15 % | 1,53 s |
| OSREP | `-m5` (default, `-t` auto) | 38.083.480 | 56,75 % | 1,51 s |
| OSREP | `-m3 -t1` | 39.551.315 | 58,94 % | 4,8 s |
| OSREP | `-m3 -l64 -c64` (`-t` auto) | 51.278.520 | 76,41 % | 0,92 s |
| OSREP | `-m4 -l64 -c64` (`-t` auto) | 51.249.808 | 76,37 % | 1,02 s |
| OSREP | `-m5 -l64 -c64` (`-t` auto) | 51.155.786 | 76,23 % | 1,42 s |
| OSREP | `-m3 -l128 -c128` (`-t` auto) | 54.107.363 | 80,63 % | 0,94 s |
| SREP 3.92 | `-m3` (default: `-l512 -c512 -a4/4`) | 58.333.128 | 86,92 % | 0,24 s |
| SREP 3.92 | `-m3 -l64 -c64` | 51.925.720 | 77,38 % | 0,35 s |
| SREP 3.92 | `-m4 -l64 -c64` | 50.535.519 | 75,30 % | 0,32 s |
| SREP 3.92 | `-m5 -l64 -c64` | 50.535.519 | 75,30 % | 0,34 s |
| Omega 3.0.0 | `-m3` | 58.291.120 | 86,86 % | 0,49 s |
| Omega 3.0.0 | `-m3 -l64 -c64` | 51.181.908 | 76,27 % | 0,80 s |
| Omega 3.0.0 | `-m4 -l64 -c64` | 49.814.847 | 74,23 % | 0,64 s |
| Omega 3.0.0 | `-m5 -l64 -c64` | 49.814.847 | 74,23 % | 0,68 s |

En `text.bin` y `mixed.bin` pasa algo parecido: OSREP gana en su default
porque busca matches desde 4 bytes, pero a igualdad de `-l64 -c64` queda
entre Omega `-m3` y `-m4`, y muy por detrás en tiempo.

## Lectura

1. **Comparar defaults no es justo.** OSREP usa `-l4 -c1`; SREP y Omega usan
   `-l512 -c512` para archivos enormes. El ratio de OSREP en default es
   mucho mejor (39,6 MB contra 58,3 MB), pero su default hace mucho más
   trabajo.
2. **La codificación paralela cambió el Pareto.** El default `-m3` bajó de
   4,8 s (`-t1`) a 1,23 s (auto, 8 hilos) sin cambiar un byte del archivo.
   `-m4`/`-m5` bajan el stream a 38,1 MB (56,75 %) en ~1,5 s: el mejor ratio
   de la tabla, a cambio de ~2,4× el tiempo de Omega `-m4`.
3. **A igualdad de ajustes, Omega `-m4`/`-m5` gana:** 49,8 MB contra
   51,2 MB de OSREP `-m5`, y 0,64 s contra 1,42 s. SREP `-m4` es aún más
   rápido (0,32 s) con 50,5 MB. OSREP `-m5` sí gana en el default
   (38,1 MB contra 49,8 MB).
4. **El hueco que queda** es el match finder a igualdad de `-l/-c`: C/asm o
   un parseo más inteligente, no otro método nominal.
5. **El objetivo medible** es un Pareto: a igual ratio que Omega `-m4`,
   tiempos comparables, y a igual tiempo, mejor ratio. Hoy el default de
   OSREP es un punto fuerte en ratio, pero falta el método que compita en
   ratio con `-m4`/`-m5` a la misma velocidad.

## Reproducir

```sh
# OSREP
fpc -Mobjfpc -O2 -Sh -Fu./src/pascal -FU/tmp/u -FE/tmp/bin src/pascal/osrep.lpr

# con los binarios de referencia
python3 scripts/bench_vs_srep.py \
  --osrep /tmp/bin/osrep \
  --srep /ruta/a/srep64 \
  --omega /ruta/a/osrep-linux-x86_64 \
  --input /ruta/a/real64.bin
```

## Próximos pasos (en orden)

1. **Match finder más rápido**: llevar el lazo a C/asm o rediseñarlo para
   no recorrer cada byte cuando `-c > 1`; medir cada cambio. La
   paralelización ya está; el límite ahora es el trabajo por bloque.
2. **`-m4`/`-m5`**: parseo perezoso/óptimo y búsqueda más profunda, con la
   meta de bajar de 49,8 MB en `real64.bin` sin perder el orden de magnitud
   de tiempo.
3. **`-dup` de escritura** y dedup por contenido (la otra mitad de la meta).
4. Repetir esta tabla en cada release; los números viejos no se borran.

## Dedup (`-dup`)

Entrada sintética `twice64.bin`: `real64.bin` (64 MiB) concatenado consigo
mismo, 128 MiB. El cuerpo deduplicado de OSREP es 67.145.683 bytes (casi una
copia); el archivo final es el cuerpo comprimido con `-m3`.

| herramienta | ajustes | archivo | tiempo |
|---|---|---:|---:|
| OSREP | `-dup -m3` (auto) | 39.558.390 | 2,46 s |
| Omega 3.0.0 | `-dup -m3` | 58.397.529 | 1,03 s |
| OSREP | `-dup -m3`, `zeros.bin` 256 KiB | 182 | 0,01 s |
| Omega 3.0.0 | `-dup -m3`, `zeros.bin` 256 KiB | 1.449 | 0,01 s |

OSREP gana tamaño en los dos casos y pierde tiempo en el grande; el CDC y la
tabla de chunks son Pascal todavía. Falta el corpus multi-versión real para
comparar con zpaq-std/zpaqfranz, que es el siguiente paso de dedup.

## Dedup multi-versión (`versions.bin`)

Cuatro versiones de `real64.bin` (67 MiB cada una, 268 MiB en total), con
cambios pequeños y distintos por versión. `zpaq-std v2.7.0` archivó el
directorio; OSREP deduplicó la concatenación (`versions.bin`).

| flujo | archivo | tiempo |
|---|---:|---:|
| zpaq-std `-m1` | 42.516.733 | 0,89 s |
| zpaq-std `-m5` | 36.018.487 | 215 s |
| OSREP `-m1` (dedup stored) | 75.792.589 | 2,25 s |
| OSREP `-m2` (dedup stored) | 76.319.202 | 2,08 s |
| OSREP `-dup -m5` | 41.355.999 | 3,80 s |
| OSREP `-dup -m5`, después zpaq-std `-m1` | 41.177.567 | +0,60 s |

Lectura: OSREP `-m1`/`-m2` encuentran los duplicados y el cuerpo único queda
en ~76 MB; el LZ de `-dup -m5` baja el archivo a 41,36 MB. Contra zpaq `-m1`
(42,52 MB, 0,89 s), OSREP + zpaq `-m1` es un poco más chico (41,18 MB) pero
más lento. Contra zpaq `-m5` (36,02 MB), OSREP queda 14 % más grande, pero
tarda ~50× menos. No es una comparación de compresores equivalentes: OSREP
es el preprocesador; la comparación limpia con el deduplicador de zpaq
requiere el mismo backend y el mismo nivel, que es el siguiente paso.

## CDC nativo (C) vs referencia Pascal

`twice64.bin` (128 MiB), mismo binario, `-dOSREP_NO_NATIVE` para forzar la
referencia:

| modo | Pascal | C |
|---|---:|---:|
| `-m1` | 1,17 s | 0,83 s |
| `-m2` | 1,33 s | 1,07 s |
| `-dup` (incluye LZ) | 2,42 s | 2,37 s |

Los archivos son byte-idénticos; `tests/native_cdc.sh` es la compuerta. El
`-dup` apenas cambia porque el LZ domina el tiempo.

## Match finder nativo (C) vs referencia Pascal

`real64.bin`, mismos bytes de salida:

| modo | Pascal | C | salida |
|---|---:|---:|---:|
| `-m3` | 1,33 s | 1,03 s | 39.551.315 |
| `-m4` | 1,43 s | 1,13 s | 38.353.352 |
| `-m5` | 1,53 s | 1,14 s | 38.083.480 |

Para `-m4`/`-m5` con `-l >= 8` el match finder usa un hash de 8 bytes, y con
`-l >= 16` uno de 16 (nunca `-m3`, que conserva el fixture `-m3 -l64`):

| flujo | antes (hash4, Pascal) | ahora (hash16, C) |
|---|---:|---:|
| `-m4 -l64 -c64` | 51.249.808 / 1,02 s | 51.084.790 / 0,83 s |
| `-m5 -l64 -c64` | 51.155.786 / 1,42 s | 51.039.922 / 0,83 s |
| `-m5 -l64 -c64 -a32` | 51.082.852 / 1,75 s | 51.005.877 / 0,93 s |

`tests/native_match.sh` es la compuerta (byte a byte, también con
`-l64 -c64 -a32` y entrada vacía). El default `-m5` sigue ~1,8× más lento
que Omega `-m4` (0,64 s), pero con 15 puntos menos de ratio. A igual
`-l64 -c64`, Omega `-m4` todavía gana por ~1,2 MB (49,8 vs 51,0 MB) y ~0,2 s.

## CRC-32C nativo

`real64.osr` (38 MB, `-m5`): `--verify` con la tabla Pascal 0,116 s; con
SSE4.2 0,029 s (~4×). El encode `-m3` baja de ~1,43 s a ~1,04 s, aunque ahí
también influye el match finder nativo. Los bytes son los mismos.

### El parámetro `-c` y el ratio

`-m5 -l64 -a32` en `real64.bin`, variando `-c` (posición de inserción del
hash chain):

| `-c` | salida | tiempo |
|---|---:|---:|
| 1 | 49.584.278 | 2,55 s |
| 4 | 49.758.002 | 1,25 s |
| 16 | 50.113.181 | 1,05 s |
| 64 | 51.005.877 | 0,93 s |

Con `-c1`/`-c4` OSREP ya baja de los 49,81 MB de Omega `-m4`, pero a más
tiempo; con `-c64` Omega gana ratio y tiempo. La diferencia no es solo el
hash: `-c` controla cuántas posiciones entran a la cadena, y el `-c` de SREP
no tiene exactamente la misma semántica. El default de OSREP (`-m5`, `-c1`)
sigue siendo el mejor ratio de la tabla, a ~1,14 s.
