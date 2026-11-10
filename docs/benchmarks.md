# Benchmarks — línea base vs SREP y Omega SREP

**Fecha: 2026-11-10.** Primera línea base del proyecto, antes de optimizar.
Nada de esto es una promesa: son los números de hoy y el punto de partida.

## Máquina y binarios

- CPU: Intel Xeon E5-2697A v4 @ 2.60 GHz, x86-64 (64 hilos visibles).
- OSREP 0.0.2, compilado con FPC 3.2.2 `-O2` (sin C/asm todavía).
- SREP 3.92 beta (2013-07-23), binario `srep64` de
  `repo-extras/srep392.zip`. No hay binario de 3.93a en el árbol; 3.92 es
  la referencia publicada más cercana.
- Omega SREP 3.0.0, binario `osrep-linux-x86_64` de `release-3.0.0`.
- Entrada: `real64.bin`, 64 MiB de datos reales del bench de r240.
- Tiempos de pared, una corrida; el ruido de la máquina es de decenas de ms.

## Resultados

| herramienta | ajustes | salida (bytes) | ratio | tiempo |
|---|---|---:|---:|---:|
| OSREP | `-m3` (default: `-l4 -c1 -a16`) | 39.551.315 | 58,94 % | 4,4 s |
| OSREP | `-m3 -l64 -c64` | 51.278.520 | 76,41 % | 3,2 s |
| OSREP | `-m3 -l128 -c128` | 54.107.363 | 80,63 % | 3,2 s |
| SREP 3.92 | `-m3` (default: `-l512 -c512 -a4/4`) | 58.333.128 | 86,92 % | 0,25 s |
| SREP 3.92 | `-m3 -l64 -c64` | 51.925.720 | 77,38 % | 0,30 s |
| SREP 3.92 | `-m4 -l64 -c64` | 50.535.519 | 75,30 % | 0,35 s |
| SREP 3.92 | `-m5 -l64 -c64` | 50.535.519 | 75,30 % | 0,30 s |
| Omega 3.0.0 | `-m3` | 58.291.120 | 86,86 % | 0,46 s |
| Omega 3.0.0 | `-m3 -l64 -c64` | 51.181.908 | 76,27 % | 0,79 s |
| Omega 3.0.0 | `-m4 -l64 -c64` | 49.814.847 | 74,23 % | 0,61 s |
| Omega 3.0.0 | `-m5 -l64 -c64` | 49.814.847 | 74,23 % | 0,64 s |

En `text.bin` y `mixed.bin` pasa algo parecido: OSREP gana en su default
porque busca matches desde 4 bytes, pero a igualdad de `-l64 -c64` queda
entre Omega `-m3` y `-m4`, y muy por detrás en tiempo.

## Lectura

1. **Comparar defaults no es justo.** OSREP usa `-l4 -c1`; SREP y Omega usan
   `-l512 -c512` para archivos enormes. El ratio de OSREP en default es
   mejor, pero a costa de ~15-20× más tiempo.
2. **A igualdad de ajustes, Omega `-m4`/`-m5` gana:** 49,8 MB contra
   51,3 MB de OSREP `-m3`, y 0,6 s contra 3,2 s.
3. **Falta velocidad.** Aun con `-a1` (una sola sonda), OSREP `-m3 -l64 -c64`
   tarda ~2,1 s y da 52,3 MB. El costo no es solo la profundidad de la
   cadena: el lazo recorre cada byte y el hash/comparación en Pascal es
   lento.
4. **Faltan métodos.** `-m4`/`-m5` de SREP/Omega son los que hay que
   alcanzar. OSREP solo tiene `-m3`; `-m4`/`-m5` salen con exit 2.
5. **El objetivo medible** es un Pareto: a igual ratio que Omega `-m4`,
   tiempos comparables, y a igual tiempo, mejor ratio. Hoy no se cumple.

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

1. **Match finder rápido**: llevar el lazo de búsqueda a C/asm o rediseñarlo
   para no recorrer cada byte cuando `-c > 1`; medir cada cambio.
2. **`-m4`/`-m5`**: parseo perezoso/óptimo y búsqueda más profunda, con la
   meta de bajar de 49,8 MB en `real64.bin` sin perder el orden de magnitud
   de tiempo.
3. **`-dup` de escritura** y dedup por contenido (la otra mitad de la meta).
4. Repetir esta tabla en cada release; los números viejos no se borran.
