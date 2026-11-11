# OSREP vs SREP, Omega SREP y zpaq-std

**Fecha: 2026-11-10.** OSREP 0.0.11, SREP 3.92, Omega SREP 3.0.0 y
zpaq-std 2.7.0. Los números son de esta máquina (Xeon E5-2697A, 64 hilos,
62 GB) y sirven para decidir, no como promesa.

## Metodología

- SREP/Omega/OSREP son **preprocesadores**: se compara el `.osr`/`.srep` que
  escriben, no un archivo comprimido final.
- OSREP default es `-m3`; para el VS se usa también `-m5`, que es el método
  de ratio.
- SREP y Omega usan sus defaults (`-l512 -c512`) y, aparte, `-l64 -c64` para
  comparar con OSREP.
- Tiempo de pared; memoria = RSS pico del proceso (`wait4`).
- El backend de dedup es el mismo `zpaq-std -m1` para las pipelines.

## Ratio y tiempo — `real64.bin` (64 MiB)

| herramienta | ajustes | salida | ratio | tiempo | RSS |
|---|---|---:|---:|---:|---:|
| OSREP | `-m3` default | 39.551.315 | 58,94 % | 1,04 s | 665 MB |
| OSREP | `-m5` default | **38.083.480** | **56,75 %** | 1,14 s | 656 MB |
| OSREP | `-m5 -l64 -c8 -a32` | 49.811.892 | 74,23 % | 1,14 s | 308 MB |
| OSREP | `-m5 -l64 -c64` | 51.001.239 | 76,00 % | 0,92 s | 656 MB |
| SREP 3.92 | `-m3` default | 58.333.128 | 86,92 % | 0,28 s | 38 MB |
| SREP 3.92 | `-m4` default | 57.476.487 | 85,65 % | 0,29 s | 36 MB |
| SREP 3.92 | `-m5` default | 56.695.400 | 84,48 % | 0,31 s | 38 MB |
| SREP 3.92 | `-m4 -l64 -c64` | 50.535.519 | 75,30 % | 0,32 s | 51 MB |
| Omega 3.0.0 | `-m3` default | 58.291.120 | 86,86 % | 0,53 s | 22 MB |
| Omega 3.0.0 | `-m4` default | 57.435.228 | 85,59 % | 0,44 s | 19 MB |
| Omega 3.0.0 | `-m5` default | 56.642.607 | 84,40 % | 0,53 s | 23 MB |
| Omega 3.0.0 | `-m4 -l64 -c64` | 49.814.847 | 74,23 % | 0,60 s | 33 MB |

Lectura:

- **Ratio default**: OSREP gana por 15 puntos (38,1 MB vs 56,6–58,3 MB).
- **A igual `-l64 -c8`**: OSREP 49.811.892 vs Omega 49.814.847; gana por
  ~3 KB, pero tarda ~1,9×.
- **A igual `-l64 -c64`**: Omega gana ratio y tiempo (49,8 MB/0,60 s vs
  51,0 MB/0,92 s). El `-c` de SREP/Omega no tiene exactamente la misma
  semántica que el de OSREP.
- En `text.bin`, SREP `-m4/-m5` da 189 bytes y OSREP 203; en `mixed.bin`
  todos rondan 2.097.3xx bytes. El default de OSREP no siempre gana en
  archivos pequeños.

## Memoria — el hueco grande

`real64.bin` (64 MiB), misma máquina:

| operación | RSS pico |
|---|---:|
| OSREP `-m5` auto (8 hilos) | **655 MB** |
| OSREP `-m5 -t4` | 329 MB |
| OSREP `-m5 -t1` | 84 MB |
| OSREP `-m5 -b1mb` auto (8 hilos) | 86 MB |
| OSREP `-m5 -mem128` (0.0.12) | **84 MB** |
| OSREP `-m5 -mem192` (0.0.12) | 164 MB |
| SREP `-m5` | 38 MB |
| Omega `-m5` | 22 MB |
| OSREP `-d` 0.0.12 (global) | 210 MB |
| OSREP `-d` 0.0.13 (por bloques) | **42 MB** |
| OSREP `-d` de `-dup -m5` 0.0.13 | 106 MB |
| SREP `-d` | 20 MB |
| Omega `-d` | 28 MB |

El costo de OSREP viene de tres cosas:

1. cada hilo mantiene `Prev` (4 bytes por byte del bloque) y el bloque de
   datos; con 8 MiB × 8 hilos son cientos de MB;
2. los buffers de entrada/salida se copian varias veces;
3. el decoder 0.0.12 reconstruía **toda** la salida en memoria
   (`DecodeAll` + `Covered`); 0.0.13 decodifica por bloques.

`-b1mb` con 8 hilos baja a 86 MB y mantiene ~38,6 MB de salida, a 1,28 s:
es un buen punto de partida para un modo con presupuesto de memoria.

## Dedup contra zpaq

Mismo backend `zpaq-std -m1`:

| corpus | zpaq solo | OSREP `-m1` + zpaq | OSREP `-m2` | OSREP `-dup -m5` |
|---|---:|---:|---:|---:|
| zpaq-std, 4 snapshots, 125 MB | 15,29 MB / 0,74 s | **8,87 MB / ~1,51 s** | 15,30 MB | 21,94 MB |
| PJA, 5 snapshots, 33,6 MB | 2,82 MB / 0,50 s | **1,73 MB / 0,66 s** | — | — |

El `-m1` fijo es el que gana; `-m2` (CDC orden-1) empata con zpaq; `-dup
-m5` antes de zpaq empeora. La integración a nivel fragmento (la tabla de
zpaq) no está implementada: la coordinación es externa.

## Matriz de funciones

| | SREP 3.92 | Omega 3.0.0 | OSREP 0.0.12 |
|---|---|---|---|
| Rol | preprocesador LZ77 | preprocesador + v6 | preprocesador + dedup |
| Formatos | v4/v5 propios | v4/v5/v6, lee v1–v6 | **solo v6** |
| Métodos | m1/m2 dedup, m3–m5 LZ | m0–m5, `-dup` | m0–m5, `-dup` |
| Dedup | m1/m2 | `-dup` (ODUP/v6) | `-m1`/`-m2`/`-dup` (DUPR) |
| Integridad | checksums por bloque | CRC + v6 | **CRC-32C + VHASH-128 + `--verify`** |
| Hilos | limitado | limitado | `-tN`, bloques en paralelo |
| Presupuesto de memoria | no | no | `-memN` |
| stdin/stdout | sí | sí | sí |
| Diccionario > RAM | **sí** | sí | no (bloques de 8 MiB) |
| Plataformas | Linux/Win antiguos | Linux/Win7/32-bit/macOS | Linux x64/x86/ARM64, Win x64/x86, macOS ARM64 |
| Librería | no | no | `libosrep` C ABI (congelada) |
| 7-Zip | no | no | plugin `OSREP` (congelado) |
| Licencia | SREP propietario | legacy | MIT |
| Tests | — | — | v6, golden, fuzz, diferencial C/Pascal |

## Fortalezas

- **Mejor ratio default** de la comparación (38,08 MB en `real64.bin`).
- **Mejor dedup** con zpaq en los dos corpus reales (38–42 % menos archivo).
- **Integridad y determinismo**: CRC, digest, `--verify`, `.osr` idéntico con
  cualquier `-t`.
- **Plataformas y librería**: seis binarios y ABI C; SREP/Omega no tienen
  librería.
- **Métodos y CLI completos** para el alcance actual: `-m0..-m5`, `-dup`,
  stdin, `-t`, `-i`, `--verify`.

## Debilidades (ordenadas por impacto)

1. **Memoria**: 655 MB de encode y 210 MB de decode contra 20–38 MB de
   SREP/Omega. Es el hueco más grande y el que más limita usarlo junto a
   zpaq en máquinas chicas.
2. **Velocidad**: 1,0–1,3 s contra 0,27–0,6 s en encode; 1,45 s contra
   0,08–0,26 s en decode.
3. **Ratio a igual `-c64`**: Omega gana; a `-c8 -a32` OSREP empata/gana por
   3 KB pero sigue más lento.
4. **Diccionario > RAM**: SREP/Omega están diseñados para eso; OSREP no.
5. **CLI histórico**: faltan `-bar`, `-delete`, `-index=`, `-mem`, `-v`,
   `-mem`, modos v4/v5 (estos últimos fuera de alcance por diseño).
6. **Integración zpaq**: el fragmentador no está; la coordinación es
   externa.

## Qué haría después

1. ~~**Presupuesto de memoria**~~ (hecho en 0.0.12): `-mem128` deja 84 MB y
   38,62 MB de salida en 1,40 s (+1,4 % de ratio); `-mem192`, 164 MB y
   +0,7 %. El bloque depende solo de `-mem`, no de `-t`.
2. ~~**Decoder por bloques**~~ (hecho en 0.0.13): 210 MB → 42 MB y 1,45 s →
   1,10 s; el `-dup` pasó de 3,2 GB/11,9 s a 106 MB/1,10 s. Queda el fallback
   global para archivos legacy con matches que cruzan bloques.
3. **Velocidad del match finder**: C/asm y menos copias; el ratio a `-c8`
   ya empata, falta el tiempo.
4. **Paridad de CLI** que no toque formato: `-bar`, `-delete`, `-v`.
5. **zpaq-std**: coordinar el fragmentador (lo lleva Wira).

## Reproducir

```sh
scripts/bench_vs_srep.py --osrep build/osrep --srep /ruta/srep64 \
  --omega /ruta/osrep-linux-x86_64 --input real64.bin
```

La memoria se midió con `wait4`/`ru_maxrss`; el script de la tabla está en
la sesión de benchmark, no se guarda como binario.
