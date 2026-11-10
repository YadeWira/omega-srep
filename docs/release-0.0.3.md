# OSREP 0.0.3 — checkpoint (pre-release)

**2026-11-10.** Primera release con la matriz de métodos completa y el
deduplicador de escritura. Es un **checkpoint antes de C/asm**: el núcleo
sigue en Free Pascal y la librería/el plugin de 7-Zip están congelados.

## Qué hay

- **v6**: lector y escritor, CRC-32C, digest VHASH-128, footer encadenado,
  `--verify`, `-i`, lectura y escritura de `-dup`.
- **Métodos**:
  - `-m1`: dedup de ventana fija (hash rodante de 48 bytes), cuerpo stored.
  - `-m2`: dedup CDC orden-1 (parámetros de zpaq), cuerpo stored.
  - `-m3`: LZ77 greedy con hash chain.
  - `-m4`: LZ con parseo perezoso.
  - `-m5`: LZ perezoso con cadena más profunda.
- **`-dup`**: CDC orden-1, chunks únicos concatenados y meta `DUPR` con CRC;
  `-i` imprime `original_size` y `restored_size`.
- **`-tN`**: codificación paralela de bloques (automática hasta 8 hilos); el
  `.osr` es byte-idéntico para cualquier `N`.
- **CLI**: `-m1..-m5`, `-b`, `-l`, `-c`, `-a`, `-hash-`, `--seed`, `-dup`,
  `-t`, `-d`, `--verify`, `-i`.
- **Pruebas**: fixtures v6, golden v6-new, round-trip, determinismo,
  corrupción, `-dup`, `-m1..-m5`, hilos, y la matriz de la librería.
- **Librería/7-Zip**: existen y compilan, pero no se amplían en esta etapa.

## Números de referencia

En `real64.bin` (64 MiB, Xeon E5-2697A, FPC 3.2.2 `-O2`):

| flujo | salida | tiempo |
|---|---:|---:|
| `-m3` default | 39.551.315 | 1,23 s |
| `-m4` default | 38.353.352 | 1,53 s |
| `-m5` default | 38.083.480 | 1,51 s |
| `-m3 -l64 -c64` | 51.278.520 | 0,92 s |
| `-m5 -l64 -c64` | 51.155.786 | 1,42 s |

Dedup multi-versión (4 versiones de `real64.bin`):

| flujo | archivo | tiempo |
|---|---:|---:|
| zpaq-std `-m1` | 42.516.733 | 0,89 s |
| zpaq-std `-m5` | 36.018.487 | 215 s |
| OSREP `-dup -m5` | 41.355.999 | 3,80 s |
| OSREP `-dup -m5` + zpaq `-m1` | 41.177.567 | +0,60 s |

Todo está en `docs/benchmarks.md`, con el comando para reproducirlo.

## Limitaciones conocidas

- El match finder y el CDC están en Pascal; C/asm es el siguiente paso.
- A igualdad `-l64 -c64`, Omega SREP `-m4` todavía gana ratio/tiempo.
- `-m0` no está implementado.
- stdin como entrada no está implementado.
- La comparación con zpaq con el mismo backend/fragmentador queda pendiente.
- Solo se probó Linux x86_64; Windows/macOS/ARM son builds previstos, no
  verificados en esta release.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
