# Recrear Omega SREP desde cero (clean room)

**Estado: plan, 2026-11-10.** No hay código nuevo todavía. Este documento
decide qué se conserva, qué se reescribe y cómo se prueba que el resultado es
nuestro y no una traducción de SREP.

## 0. Por qué

El núcleo actual (`pascal/src/`) es una traducción fiel de SREP 3.93a, cuyos
headers dicen **“All rights reserved”** y ofrecen una licencia comercial. Una
traducción es una obra derivada: no podemos ponerle MIT al conjunto sin permiso
de Bulat Ziganshin. La única forma de tener un proyecto MIT es **código nuevo**,
con una pared clean-room real. La spec v6, la CLI, los tests, la golden, la
auditoría de mutaciones y el C/asm nuevo sí son nuestros.

## 1. Qué se conserva (nuestro)

| activo | por qué |
|---|---|
| `docs/format-spec-v6.md` | diseño propio del contenedor v6; es la spec normativa |
| `docs/format-spec-v5.md`, `docs/format-spec.md` | descripción funcional de los formatos; se usan como spec (revisar que no copien código) |
| `tests/golden/` (v6, CLI, hashes) | casos y vectores nuestros |
| `tests/fixtures/v5/`, `tests/fixtures/` v4 | datos de compatibilidad; no son código |
| `tests/mutations/` | banco de mutaciones nuestro; se adapta al código nuevo |
| `tests/*.sh` (harness) | nuestros; se adaptan, no se copian al núcleo |
| `pascal/build.sh`, CI, `man/`, `completions/`, packaging | infraestructura nuestra |
| `docs/native-c-asm.md`, `docs/omega-vs-srep-3.0.0.md`, README, CHANGELOG | documentación nuestra |
| el nombre y la marca “Omega SREP” / `osrep` | decisión del dueño (ver §10) |
| `pascal/native/` (C/asm futuro) | código nuevo, nuestro |

## 2. Qué se reescribe (derivado)

No se copia al repo nuevo. Se usa solo como **referencia de comportamiento**
(Team A, §3).

| grupo | archivos |
|---|---|
| encoder / match finder | `encoder.pas`, `secondpass.pas`, `hashtable.pas`, `fixedcompress.pas`, `fixedtext.pas`, `lzcodec.pas`, `inmem.pas` |
| decoder / contenedor | `decompress.pas`, `container.pas`, `futurelz.pas`, `v5verify.pas` |
| dedup | `dedup.pas`, `dupwrap.pas` |
| CLI / I/O / formato humano | `cliargs.pas`, `help.pas`, `clireport.pas`, `streamio.pas`, `osrep.lpr`, `*tool.lpr` |
| hashes | `hashes.pas`, `hasheskeyed.pas`, `aes.pas`, `vmac.pas` — los originales son public domain/LibTomCrypt, pero la traducción está entrelazada con SREP; se reescriben desde el original público o se portan con su licencia |
| modelos de test | `segment_match_loss.py`, `dup_prototype.py` — modelos del C++, quedan fuera |
| historia | todo el historial git, comentarios y estructura del port viejo |

**El match finder es nuevo.** No hace falta reproducir el stream de matches de
SREP. v6 define el contenedor, no cómo elegir matches. Eso es lo que permite
que el encoder sea original y, a la vez, compatible.

## 3. La pared clean-room

Dos contextos separados, con registro de qué leyó cada uno:

- **A — spec (puede leer el repo viejo):** escribe `spec/` con el formato, la
  CLI, el comportamiento observable, las tablas y los fixtures. No escribe
  código de implementación.
- **B — implementación (no lee el repo viejo):** trabaja en un repo nuevo que
  solo contiene `spec/`, `tests/fixtures/` y documentación pública. No abre
  `omega-srep`, ni el C++/Rust archivados, ni los `.pas` viejos.

La spec no lleva snippets del código viejo: solo comportamiento, fórmulas,
layouts y vectores. Los fixtures son datos (archivos `.osr`), no código.

**Honestidad:** un clean-room legal de verdad necesita dos equipos
independientes. Acá podemos aproximarlo con una sesión/contexto nuevo para B y
un directorio separado; la misma persona/modelo no es una garantía legal. Si el
proyecto va a distribuirse comercialmente, conviene que B sea otra persona. Para
un fork no comercial, la pared documentada + código nuevo es la mejor defensa
práctica.

## 4. Política de compatibilidad

| formato | política |
|---|---|
| **v6 (nuestro)** | es el formato nativo. El encoder nuevo puede dar otros bytes (otro match finder); los `.osr` v6 de 3.0.0 se siguen leyendo. La spec no cambia. |
| **v4 (interop 1.0.x)** | se escribe el **contenedor**, no el stream exacto de SREP. Aceptación: el C++ 1.0.7 archivado decodifica los v4 nuevos. **No se exige byte-identidad**; eso obligaría a copiar el match finder. |
| **v5** | solo lectura; se decodifican los fixtures guardados. No se escribe. |
| **v1-v3** | solo lectura; decoders desde la spec, validados con fixtures. |
| **CLI** | contrato de 3.0.0 (v6 default, v5 rechazado, v4 interop, `--verify`, `--seed`, `-dup`); implementación propia y textos propios, fijados por la golden nueva. |

El objetivo es **compatibilidad de formato y de contrato**, no clonar el
algoritmo. Un `.osr` v4 nuevo tiene que abrirse con 1.0.7; no tiene que ser el
mismo archivo que escribía SREP.

## 5. Arquitectura y lenguajes

Repo nuevo (nombre a decidir, §10):

```
  src/pascal/     contenedor, CLI, orquestación, encoder/decoder de alto nivel
  src/c/          CRC-32C HW, memcmp/memcpy/CommonPrefix SIMD, AES/VMAC, SHA,
                  y al final el lazo del escaneo
  src/asm/        prefetch, CPUID/HWCAP, hojas de una instrucción
  spec/           format-v6.md, format-v5.md, format-v4.md, cli.md, behavior.md
  tests/          unitarios, golden, compatibilidad, mutaciones, fuzz, plataformas
  docs/           README, build, decisiones
```

Reglas del C/asm (las de `docs/native-c-asm.md`): funciones puras, sin libc,
ABI `cdecl`, tipos fijos, prefijo `osrep_`; **toda función nativa tiene
referencia Pascal** y build `-dOSREP_NO_NATIVE`; los bytes no cambian; nada de
`-march=native`; dispatch en runtime.

Pascal hace el formato y las decisiones; C hace lo vectorial/mediable; asm solo
lo que no se puede expresar bien en C (prefetch/CPUID).

## 6. Fases

### Fase 0 — Preparación (2–4 días)

- Crear el repo nuevo con historia limpia y `LICENSE` MIT.
- Congelar `spec/` (v6 primero; v4/v5 después) y el set de fixtures.
- CI vacío con la matriz (Linux x64/i386/ARM64, Windows x86/x64, macOS arm64).
- Registro de la pared clean-room (qué leyó A, qué ve B).

**Aceptación:** repo nuevo vacío de código, spec y fixtures revisados, CI verde
en trivial.

### Fase 1 — MVP v6 (3–4 semanas)

- Contenedor v6: header, bloques, footer, `blocks_crc`, `--verify`.
- Decoder v6 completo.
- Encoder v6 con un **match finder propio** (hash chain simple; sin copiar el
  de SREP). Ratio inicialmente peor; se mejora después.
- CLI mínima: `-m0..-m5`, `-d`, `--verify`, `-i`, `--seed`, `--format=v4|v6`.
- Fuzz de decoder y round-trip.

**Aceptación:** round-trip 100% en el corpus; los `.osr` v6 de 3.0.0 se leen;
el fuzz no encuentra crashes; la golden v6 nueva queda grabada.

### Fase 2 — Compatibilidad v1–v5 y escritura v4 (3–4 semanas)

- Decoders v1–v5 desde la spec, con los fixtures guardados.
- Escritor v4 (contenedor) con el match finder propio.
- Cross-decode: los v4 nuevos los lee el C++ 1.0.7 archivado; los v4 viejos los
  lee el proyecto nuevo.
- CLI completa y textos propios; golden de CLI nueva.

**Aceptación:** fixtures v1–v5 decodifican byte a byte; v4 nuevo cruza con
1.0.7; la CLI nueva reproduce el contrato (no los textos viejos).

### Fase 3 — C/asm (3–4 semanas)

1. **CRC-32C por hardware** (SSE4.2/ARMv8) + tabla + dispatch.
2. `memcmp`/`memcpy`/`CommonPrefix` SIMD.
3. AES-NI para VMAC / SHA-NI para SHA-1.
4. Prefetch/CPUID en asm.
5. (Opcional) lazo del escaneo, solo con perfil y ganancia clara.

**Aceptación:** mismos CRC/digests; los `.osr` son idénticos con y sin nativo;
benchmark contra 3.0.0 y SREP 3.93a.

### Fase 4 — Producto y release 1.0 (2–3 semanas)

- CLI/UX, docs, packaging, man/completions.
- Golden completa, auditoría de mutaciones adaptada.
- Matriz de seis plataformas (incluido macOS arm64 en CI).
- Release 1.0.0 con `LICENSE` MIT y `NOTICE`.

**Aceptación:** `core`/`full` desde un clon limpio; paridad v6/v4/v5; matriz
completa; release firmado por el dueño.

### Fase 5 — Rendimiento (opcional)

- Perfilar, mejorar el match finder (ratio/velocidad) y el escaneo.
- Solo si el benchmark muestra una ganancia que justifique el riesgo de paridad.

**Total estimado:** ~3 meses de trabajo efectivo de una persona/agente, sin
contar la curva de compatibilidad v1–v5 si aparece un caso raro.

## 7. Pruebas

- **Unitarias:** CRC, varints, headers, footer, hashes.
- **Golden:** v6 nuevo (definición), lectura de v6 de 3.0.0, fixtures v4/v5.
- **Diferencial:** nativo vs Pascal de referencia; cross-decode con los oráculos
  archivados para v4/v5 (solo datos).
- **Mutaciones:** adaptar las 15 de `tests/mutations/`; las equivalentes se
  re-evalúan.
- **Plataformas:** la matriz de seis; macOS arm64 en GitHub Actions.
- **Fuzz:** decoder v6 y v1–v5, entradas mutadas, valgrind/ASAN donde se pueda.

## 8. Licencia

- **MIT** para el repo nuevo: todo el código es nuevo; la spec y los tests son
  nuestros.
- `NOTICE`: compatibilidad de formato con SREP (sin código de SREP), autores de
  LibTomCrypt/VMAC/LZMA2 si se reutilizan, y el repo viejo como legacy.
- **No** se copia código del repo viejo ni de los oráculos. Si se reutiliza una
  función C/asm nuestra, se puede; si se reutiliza una traducción de LibTomCrypt
  o VMAC (public domain), se mantiene su atribución.
- El repo viejo (`omega-srep` 3.0.0) queda como **legacy**, sin licencia, con su
  release; no se toca ni se borra.

## 9. Riesgos

| riesgo | mitigación |
|---|---|
| La pared clean-room no es legalmente perfecta (misma persona/modelo) | contexto B separado, registro de accesos, y si se comercializa, otra persona para B |
| v1–v5 tienen rarezas difíciles | spec funcional + fixtures + cross-decode con los oráculos archivados |
| El match finder nuevo comprime peor | medirlo desde el MVP; mejorar en Fase 5; la compatibilidad no exige el mismo stream |
| El esfuerzo se subestima | fases con aceptación; el MVP v6 primero |
| Nombre/marca | decidir antes de crear el repo (§10) |
| La licencia del repo viejo sigue siendo un problema | no se mezcla con el nuevo; el nuevo nace MIT |

## 10. Decisiones antes de empezar

1. **Nombre y repo:** ¿`omega-srep-ng`, `osrep-ng`, u otro? ¿Se conserva la
   marca “Omega SREP” o se renombra para no arrastrar la confusión con SREP?
2. **Compatibilidad:** ¿formato (recomendado) o byte-identidad con SREP? La
   byte-identidad obliga a emular el match finder por observación y encarece
   todo.
3. **Pared clean-room:** ¿A prepara la spec en este repo y B arranca en una
   sesión/contexto nuevo con solo el repo nuevo? ¿O lo hace otra persona?
4. **MIT desde el primer commit** (recomendado) o al final.
5. **Qué se hace con el repo viejo:** dejarlo como legacy 3.0.0 y redirigir el
   README al nuevo, o archivar el repo.
