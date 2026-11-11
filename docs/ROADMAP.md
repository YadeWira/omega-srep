# OSREP — rumbo del proyecto

**Decisión de Wira, 2026-11-10.** Primero se termina **el proyecto**: el
preprocesador, el formato, el CLI y el motor de deduplicación. Las librerías
(`libosrep`, el plugin de 7-Zip, la integración con PJA y con zpaq-std) quedan
**congeladas** hasta que Wira diga que se empieza con ellas.

## Meta

Ser mejor que:

- **SREP 3.93a** (Bulat Ziganshin), el preprocesador LZ77 de referencia.
- **Omega SREP 3.0.0**, el proyecto anterior y su formato v6.
- El **deduplicador de zpaq-std / zpaqfranz**: fragmentación por contenido,
  SHA-1, tabla `HT`/`HTIndex` y bloques `h`/`i`/`d`.

"Mejor" se mide, no se afirma: ratio, tiempo de compresión, tiempo de
descompresión, memoria y, en dedup, tamaño del archivo multi-versión y
velocidad. Los números van en `docs/benchmarks.md` (o el informe que lo
reemplace) y se repiten en cada release.

## Qué entra en "terminar el proyecto"

1. **Formato y lector v6**
   - Leer los v6 de Omega SREP 3.0.0, `--verify`, `-i`, `-dup` de lectura.
   - Fuzz, corrupción, CRC, digest y límites de memoria.
2. **CLI completo** (hecho en lo esencial)
   - `-m0..-m5`, `-b`, `-l`, `-c`, `-a`, `-hash=`, `--seed`, `-dup`,
     stdin/stdout (`-`), `-i`, `-t`.
   - Queda revisar opciones históricas que se aceptan y se ignoran.
3. **Encoder**
   - `-m3` actual y los métodos que hagan falta para igualar/superar a SREP:
     `-m4`, `-m5`, y una estrategia de bloques/diccionario propia.
   - `-dup` de escritura (el lector ya existe).
   - Determinismo, `-hash-`, tamaños de bloque y semilla.
4. **Deduplicación**
   - Dedup de stream de OSREP (`-dup`/`DUPR`) completo.
   - Diseño del fragmentador/dedup por contenido que después usará zpaq-std:
     CDC, hash, tabla e índice. La integración se hará al final, pero el
     motor se diseña y se mide ahora.
5. **Rendimiento**
   - Benchmarks contra SREP 3.93a y Omega SREP 3.0.0 con el mismo corpus y
     el mismo backend.
   - C/asm para CRC, hashes y copias; medir antes y después.
6. **Calidad**
   - Corpus fijo, pruebas de round-trip, determinismo, fuzz, valgrind,
     corrupción y límites.
   - Documentación y presentación honestas: qué está hecho y qué no.

## Fuera de alcance por ahora

- `libosrep` y su ABI C: existen y se mantienen compilando, pero no se
  amplían.
- El plugin de 7-Zip/7-Zip-zstd: existe como prueba, no se sigue puliendo.
- PJA, la familia PJA/PMPA/PRA/PPA/PAIA y `pack*`.
- La integración con zpaq-std/zpaqfranz: primero el motor, después se
  coordina con su agente.

## Orden de trabajo

1. **Línea base** (hecha): medir OSREP 0.0.2 `-m3` contra SREP 3.92 y Omega
   SREP 3.0.0 en el corpus y en `real64.bin`. Números en
   `docs/benchmarks.md`.
2. **Cerrar el encoder**: métodos y opciones que falten, con la meta de
   igualar o superar el ratio de SREP sin perder más tiempo del aceptable.
3. **Dedup por contenido**: `-m1`/`-m2` hechos. Con el mismo backend en un
   corpus real, `-m1` + zpaq da 12,23 MB contra 15,29 MB de zpaq solo;
   `-m2` empata y `-dup -m5` empeora. Falta decidir el fragmentador que
   usará zpaq y coordinarlo con su agente.
4. **Benchmarks de dedup** contra zpaq-std/zpaqfranz (mismo corpus
   multi-versión; tamaño y tiempos).
5. **C/asm y memoria**.
6. **Release 0.0.x** con los números y las limitaciones.
7. **Recién entonces**: librería, 7-Zip, PJA y zpaq-std, cuando Wira lo pida.

## Estado actual (para no confundirse)

- Lector v6 y encoder `-m3`: funcionando; tests `v6_read` y `v6_encode`.
- `libosrep` L0/L1 parcial y plugin de 7-Zip: congelados, no se amplían.
- `-dup` de escritura: implementado (CDC orden-1, meta `DUPR`); el lector
  ya lo restauraba.
- `-m1`/`-m2`: implementados (dedup de ventana fija y CDC orden-1, cuerpo
  stored); `-m3`/`-m4`/`-m5` son los métodos LZ.
- `-m4`/`-m5`: implementados (lazy y cadena más profunda); el ratio y el
  tiempo están en `docs/benchmarks.md`.
- Benchmarks contra SREP/Omega SREP: línea base hecha en `docs/benchmarks.md`.
- Checkpoints: `0.0.3` (`-m1..-m5`, `-t`, `-dup`) y `0.0.4` (CDC, match
  finder y CRC nativos; hash16 para `-m4/-m5`).
- Codificación paralela de bloques (`-tN`): hecha; el `.osr` no cambia.
- C/asm: CDC, match finder y CRC-32C nativos, verificados contra Pascal;
  hash de 32 bytes para `-m4/-m5` con `-l >= 32`. Windows x86/x64 cruza y
  pasa round-trip bajo wine, Windows 10 y Windows 7 SP1; Linux x86 se cruza
  y pasa nativo; Linux ARM64 se cruza y pasa qemu; macOS ARM64 en GitHub
  Actions. Con `-l64 -c8 -a32` el ratio empata/gana a Omega `-m4`, pero el
  tiempo sigue por detrás; a `-c64` Omega gana ambos.
- Dedup por contenido para zpaq: diseñado en `docs/zpaq-dedup-study.md`,
  no implementado.
