# Benchmarks — línea base vs SREP y Omega SREP

**Fecha: 2026-11-10.** Primera línea base del proyecto, antes de optimizar.
Nada de esto es una promesa: son los números de hoy y el punto de partida.

## Máquina y binarios

- CPU: Intel Xeon E5-2697A v4 @ 2.60 GHz, x86-64 (64 hilos visibles).
- OSREP 0.0.2, compilado con FPC 3.2.2 `-O2` (sin C/asm todavía), con
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
| OSREP | `-m3 -t1` | 39.551.315 | 58,94 % | 4,8 s |
| OSREP | `-m3 -l64 -c64` (`-t` auto) | 51.278.520 | 76,41 % | 0,92 s |
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
2. **La codificación paralela cambió el Pareto.** El default bajó de 4,8 s
   (`-t1`) a 1,23 s (auto, 8 hilos) sin cambiar un byte del archivo. Sigue
   siendo ~2× más lento que Omega `-m4`, pero el ratio es 15 puntos mejor.
3. **A igualdad de ajustes, Omega `-m4`/`-m5` gana:** 49,8 MB contra
   51,3 MB de OSREP `-m3`, y 0,64 s contra 0,92 s. SREP `-m4` es aún más
   rápido (0,32 s) con 50,5 MB.
4. **Faltan métodos.** `-m4`/`-m5` de SREP/Omega son los que hay que
   alcanzar. OSREP solo tiene `-m3`; `-m4`/`-m5` salen con exit 2.
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
