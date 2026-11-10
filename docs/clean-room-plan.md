# OSREP — recreación clean-room

**Estado: plan y Fase 0, 2026-11-10.** El producto pasa a llamarse **OSREP**.
Se mantiene el mismo repositorio (`YadeWira/omega-srep`), pero el código nuevo
vive en una **rama huérfana `osrep`** con historia propia; `main` y los tags
quedan como **legacy**.

Decisiones del dueño (2026-11-10):

1. **Mismo repo**, no uno nuevo.
2. **Nombre OSREP** en README, wiki y binarios.
3. **No hace falta compatibilidad con SREP**: se deja atrás v1–v5 y el
   contenedor v4. El formato propio es v6.
4. **MIT desde el día 1** para el código nuevo; el legacy no queda cubierto.
5. La **nota de la pared clean-room** queda en `CLEAN-ROOM.md`, para la sesión
   de implementación.

## 0. Por qué

El núcleo de `main` es una traducción de SREP 3.93a, cuyos headers dicen “All
rights reserved”. No se puede relicenciar como MIT. La salida es código nuevo,
con una pared clean-room y un alcance más chico: **solo el formato v6**, que sí
es nuestro.

## 1. Qué se conserva (nuestro)

| activo | por qué |
|---|---|
| `spec/format-v6.md` + el layout del payload | diseño propio del contenedor v6; es la spec normativa |
| `tests/fixtures/v6/` | archivos v6 de 3.0.0, como datos de lectura compatible |
| `tests/golden/`, `tests/mutations/` | casos, vectores y mutaciones nuestros; se adaptan |
| `tests/gen_corpus.sh`, `inputs.sh`, harnesses | nuestros; se reutilizan |
| `pascal/build.sh`, CI, packaging, man/completions | nuestros; se adaptan |
| `docs/native-c-asm.md`, este plan, README | documentación nuestra |
| C/asm nuevos | código nuevo, nuestro |
| el repo, los tags, los releases | se conservan como legacy |

## 2. Qué se reescribe

No se copia a `osrep`:

- encoder, match finder, decoder, contenedor, dedup, CLI, I/O y hashes
  entrelazados de `pascal/src/` (la lista completa está en la versión anterior
  de este plan, en `main`).
- los modelos `segment_match_loss.py` y `dup_prototype.py`.
- la historia de `main`: `osrep` arranca en un commit raíz propio.
- los decoders v1–v5 y el escritor v4: **no se implementan**.

**El match finder es nuevo.** No hay que reproducir el stream de SREP ni el de
3.0.0. v6 define el contenedor, no la elección de matches.

## 3. Pared clean-room

- **A — spec:** puede leer `main`, los tags y los binarios viejos. Escribe
  `spec/`, `tests/fixtures/` y `CLEAN-ROOM.md`. No escribe implementación.
- **B — implementación:** clona **solo** la rama `osrep`
  (`git clone --single-branch --branch osrep`), no abre `main`, ni los tags, ni
  los oráculos archivados, ni los `.pas` viejos. Trabaja solo con `spec/` y
  `tests/fixtures/`.
- `CLEAN-ROOM.md` deja la instrucción escrita para B y el registro de qué leyó
  A. Si falta un detalle en la spec, B pregunta a A; no lo deduce del código
  viejo.

**Honestidad:** con la misma persona/modelo es una pared documentada, no una
garantía legal. Para uso comercial, B debería ser otra persona.

## 4. Formato y compatibilidad

| formato | decisión |
|---|---|
| **v6 (OSREP)** | es el único formato. El encoder nuevo puede dar otros bytes; los `.osr` v6 de 3.0.0 se leen (fixtures). La spec no cambia. |
| **v1–v5, v4** | **no se leen ni se escriben**. No hay compatibilidad con SREP. Se documenta el corte. |
| **CLI** | contrato OSREP: v6 por defecto, `-m0..-m5`, `-d`, `--verify`, `-i`, `--seed`, `-dup`, `-bar`. Sin `--format=v4/v5`; a lo sumo `--format=v6` reservado. |
| **nombre** | `osrep` en binarios y `--version`; extensión `.osr`; magic `OSR6`. |

## 5. Arquitectura y lenguajes

```
  src/pascal/   contenedor, CLI, orquestación, encoder/decoder de alto nivel
  src/c/        CRC-32C HW, memcmp/memcpy/CommonPrefix SIMD, AES/VMAC, SHA,
                y al final el lazo del escaneo
  src/asm/      prefetch, CPUID/HWCAP, hojas de una instrucción
  spec/         format-v6.md, payload.md, cli.md
  tests/        unitarios, golden, fixtures v6, mutaciones, fuzz, plataformas
  docs/         README, build, decisiones
```

Reglas del C/asm (`docs/native-c-asm.md`): funciones puras, sin libc, ABI
`cdecl`, tipos fijos, prefijo `osrep_`; toda función nativa tiene referencia
Pascal y build `-dOSREP_NO_NATIVE`; los bytes no cambian; dispatch en runtime.

## 6. Fases

### Fase 0 — Preparación (hecha el 2026-11-10)

- Rama huérfana `osrep`, `LICENSE` MIT, `NOTICE`, `CLEAN-ROOM.md`.
- `spec/format-v6.md`, `spec/payload.md`, `spec/cli.md`.
- `tests/fixtures/v6/` con archivos de 3.0.0 y su manifiesto.
- README OSREP y CI base.

### Fase 1 — MVP v6 (3–4 semanas)

- Contenedor v6: header, bloques, footer, `blocks_crc`, `--verify`.
- Decoder v6 completo (incluye los fixtures de 3.0.0).
- Encoder v6 con match finder propio (hash chain simple).
- CLI mínima y round-trip.

**Aceptación:** round-trip 100% en el corpus; los v6 de 3.0.0 se leen; fuzz sin
crashes; golden v6 nueva.

### Fase 2 — C/asm (3–4 semanas)

1. CRC-32C por hardware (SSE4.2/ARMv8) + tabla.
2. `memcmp`/`memcpy`/`CommonPrefix` SIMD.
3. AES-NI para VMAC / SHA-NI para SHA-1.
4. Prefetch/CPUID en asm.
5. (Opcional) lazo del escaneo, con perfil y ganancia clara.

**Aceptación:** mismos CRC/digests; `.osr` idénticos con y sin nativo;
benchmark contra 3.0.0 y SREP 3.93a.

### Fase 3 — Producto y release 1.0 (2–3 semanas)

- CLI/UX, docs, packaging, man/completions.
- Golden completa y mutaciones adaptadas.
- Matriz de seis plataformas (macOS arm64 en CI).
- Release `v0.0.x` (pre-release) y, al cerrar la fase, `v1.0.0` con `LICENSE` MIT y `NOTICE`.

**Total estimado:** ~2–3 meses de trabajo efectivo.

## 7. Pruebas

- Unitarias: CRC, varints, headers, footer, hashes.
- Golden v6: nuevos archivos + lectura de los de 3.0.0.
- Diferencial: nativo vs Pascal de referencia.
- Mutaciones: adaptar las 15; las equivalentes se re-evalúan.
- Plataformas: seis; macOS arm64 en Actions.
- Fuzz: decoder v6 y `-dup`.

## 8. Licencia

- **MIT** para todo el código de la rama `osrep`, desde el primer commit.
- `NOTICE`: el MIT cubre el código nuevo de `osrep`; `main`, los tags y los
  releases legacy **no** están cubiertos. Compatibilidad de formato con el v6
  de 3.0.0 (datos, no código). LibTomCrypt/VMAC/LZMA2 si se reutilizan.
- No se copia código de `main` ni de los oráculos.

## 9. README, wiki y binarios

- `README.md` de `osrep`: título **OSREP**, estado de la recreación, link al
  legacy 3.0.0.
- Wiki: `Home.md` pasa a OSREP; las páginas viejas quedan marcadas como
  **legacy (Omega SREP 3.0.0)**.
- Binarios nuevos: `osrep-*`, `--version` imprime `OSREP x.y.z`. Los binarios
  3.0.0 legacy conservan su nombre y su texto.
- Versión nueva: `0.0.1` en la fase 0; `0.0.2` en el MVP y `0.0.x` durante el
  resto; `1.0.0` en el primer release estable. Todos los `0.0.x` son
  pre-releases.

## 10. Riesgos

| riesgo | mitigación |
|---|---|
| pared clean-room imperfecta (misma persona/modelo) | `CLEAN-ROOM.md`, clon `--single-branch`, registro; otra persona si se comercializa |
| el match finder nuevo comprime peor | medir desde el MVP; mejorar en Fase 2/3 |
| v6 de 3.0.0 tiene rarezas | fixtures + decoder contra la spec |
| esfuerzo | fases con aceptación; MVP primero |
| confusión legacy/nuevo | README, NOTICE y wiki separan OSREP de Omega SREP 3.0.0 |
