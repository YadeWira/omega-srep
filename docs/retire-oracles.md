# Retirar los oráculos C++ y Rust: plan

**Estado: plan, pendiente de aprobación (2026-11-10).** Los oráculos siguen en
el árbol y siguen siendo la medida; esto es cómo dejar de necesitarlos sin
quedarse sin instrumento. Se apoya en `docs/format-spec-v6.md` (el formato que
se congela en 3.0.0) y en `tests/golden/` (los casos ya grabados).

## 0. La condición, no la fecha

No se retiran "cuando salga la 3.0.0". Se retiran cuando **un clon sin `g++` ni
`cargo` pase todas las compuertas del núcleo** y una auditoría de mutaciones
demuestre que esas compuertas ven los errores que los oráculos veían. Hasta
entonces, sacarlos es cambiar una medida por una suposición.

## 1. Qué se pierde y qué lo reemplaza

Hoy hay dos oráculos que coinciden entre sí: una discrepancia contra uno solo
es ambigua, contra dos que coinciden el culpable es el port. Al retirarlos, la
pregunta "¿qué habría hecho el C++?" deja de tener respuesta en `main`.

Lo que los reemplaza, en capas:

1. **La spec** (`format-spec-v6.md` normativa + las de v1–v5 como referencia
   histórica): el contrato deja de ser "lo que hace 1.0.7" y pasa a ser el
   documento.
2. **`tests/golden/`**: archivos + exit code + ida y vuelta, grabados cuando
   los tres coincidían.
3. **Fixtures de comportamiento** (nuevas): stdout, stderr y exit code de la
   CLI para una matriz fija, para no perder los textos y los códigos que hoy
   se comparan contra el Rust.
4. **Vectores fijos** para lo que no es un archivo: hashes (md5/sha1/sha512/
   vmac/siphash/AES), `dedup_test`, y el orden del `std::sort` (ya hay
   `cxx_sort_tie_divergence.sh`).
5. **Auditoría de mutaciones**: la prueba de que las capas 1–4 alcanzan.

## 2. Inventario (lo que hay que desacoplar)

Medido el 2026-11-10 sobre 49 scripts de `tests/`:

- **30** referencian el C++ (`CXX_BIN`, `make_cxx`) — incluye `_paths.sh` y los
  benchmarks.
- **18** referencian el Rust (`RUST_TARGET`, `cargo_rs`, `OSREP_RUST_BIN`).
- La golden tiene **39 casos** (v4 y v5; faltan v6 y los contenedores v1–v3).
- El `--help` y el `--version` del Pascal están clavados byte a byte contra los
  del Rust; el `--help` todavía dice `v4|v5`.
- El checklist de release compila los oráculos y varias compuertas los usan.

## 3. Fases

### Fase A — Cerrar la medida (prerrequisito)

- A1 y A4 de `PENDIENTES.md` cerrados o documentados como desviación (A4 ya
  tiene su compuerta con datos reales; A1 está investigado).
- v6 implementado y congelado (hecho el 2026-11-10, incluido `-dup` y el CDC
  independiente de la CPU).

**Aceptación:** no queda ninguna diferencia conocida contra el C++ sin
explicar; las que quedan son defectos del C++ documentados.

### Fase B — Ampliar las fixtures

1. **Golden a v6 y a los contenedores viejos.** Hoy 39 casos v4/v5. Agregar:
   - v6 por defecto y `--format=v6` en las mismas opciones (m0..m5, `o`/`f`,
     `-dup`, hashes, `-b/-l/-c`, `-a`, `-ia-`);
   - lectura de v1/v2/v3 (`o`/`f`) y v4, con archivos grabados de la era del
     oráculo (no hace falta escribirlos, solo leerlos);
   - casos de corrupción: cabecera, footer, bloques, meta, truncamiento (la
     suite de v6 ya cubre v6; falta el equivalente v4/v5).
2. **Fixtures de CLI** (`tests/golden/cli/`): para una matriz de invocaciones,
   guardar stdout, stderr y exit code. Cubre `--help`, `--version`, errores de
   opciones, `-i`, `--verify`, `-d` de archivos dañados, stdout cerrado, etc.
   Sin esto, retirar el Rust pierde los textos de error que hoy se comparan.
3. **Vectores de hash y dedup**: tablas fijas por algoritmo, tamaño y semilla,
   y los vectores de `dedup_test`; el `std::sort` ya está en su regresión.
4. **Regenerador**: `tests/golden/make.sh` ya exige que C++ y Rust coincidan
   con el port; para los casos nuevos de v6 no hay oráculo, así que se graban
   con el port y se validan con la spec, marcados como tales.

**Aceptación:** `tests/golden/check.sh` cubre la matriz de formatos, modos y
errores de la CLI sin abrir un binario de `oracles/`.

### Fase C — Separar las compuertas

- `tests/_paths.sh`: detectar los oráculos y **no fallar** si faltan; las
  suites diferenciales imprimen "sin oráculo — salteando" y salen 0.
- Dividir la lista en dos:
  - **núcleo** (siempre, sin oráculos): cargo tests del Rust no; golden,
    `pascal_*` contra fixtures, `v6_conformance`, `harness_selftest`,
    `local_hardening` en su parte de C++… ojo, esa también es del oráculo.
  - **diferencial** (opcional, requiere los oráculos): `rust_conformance`,
    `rust_cli_conformance`, `encode/decode/container/v5/dup` contra el C++.
- El checklist de release corre **solo el núcleo**; el diferencial queda como
  compuerta de investigación, no de release.
- Las suites que hoy comparan contra el Rust (textos, CLI) se reemplazan por
  las fixtures de CLI.

**Aceptación:** en un clon sin `oracles/`, `g++` ni `cargo`, el núcleo pasa
entero y ninguna suite se saltea en silencio (las diferenciales dicen por qué).

### Fase D — Auditoría de mutaciones (la prueba)

Antes de borrar nada, inyectar a mano una lista de errores conocidos y
comprobar que el núcleo los ve:

- las mutaciones del escaneo que ya sobrevivían (R11, R15, R18, R19, R20, P04);
- los defectos que los oráculos encontraron en su momento (BASE_LEN, bloques
  corridos, read-ahead, orden de `std::sort`, `-ia-`, `-a`);
- 5–10 mutaciones nuevas al azar en el encoder/decoder (p. ej. cambiar un
  límite, un redondeo, un chequeo de digest).

Cada mutación que **no** falle en el núcleo se convierte en un caso nuevo de la
golden (o en una compuerta). La auditoría se repite hasta que todas mueran.

**Aceptación:** 100 % de las mutaciones de la lista fallan en el núcleo, y la
lista queda versionada como `tests/mutations/` (el parche de cada una).

### Fase E — Archivar y sacar

- Crear tags anotados **`oracle-cxx-1.0.7`** y **`oracle-rust-2.1.2`** en el
  último commit que los contiene (además de los tags de release que ya los
  tienen).
- Adjuntar a un release de "oráculos" (o dejar solo los tags) un tarball con
  los dos árboles y las instrucciones de build, para no depender de que GitHub
  guarde el historial para siempre.
- Borrar `oracles/` de `main` en un commit propio; actualizar:
  - `README.md` (implementación: FPC + C + asm; los oráculos, archivados);
  - `oracles/README.md` → se va con el árbol; su contenido pasa a
    `docs/retired-oracles.md` con los tags y el porqué;
  - `docs/pascal-port.md` "Dos oráculos, no uno" → nota histórica;
  - `.gitignore` y `tests/_paths.sh` (ya sin CXX/RUST).
- **CLI**: al no haber Rust contra el que comparar, el `--help` deja de estar
  clavado; se actualiza para listar v6 (y limpiar lo que la 3.0.0 decida:
  octal, textos, `-a9`, etc. — ver `format-spec-v6.md` §4).
- `--version`/fecha: la 3.0.0 las fija como propias, no como "igual al Rust".

**Aceptación:** `git grep -i "oracle\|oráculo"` en `main` solo encuentra
documentación histórica; ningún script de `tests/` referencia `oracles/`.

### Fase F — Verificación final

- Clon limpio, sin `oracles/`, sin `g++`, sin `cargo`: `bash pascal/build.sh`
  (FPC + C + asm) y el núcleo completo.
- La misma matriz en Win7 real, wine32/64, linux-x86/ARM64 y macOS ARM64.
- Comparar los binarios de la 3.0.0 con los de 2.4.0: los `.osr` de v4/v5
  decodifican igual; los de v6 son nuevos.
- Release 3.0.0 (estable) con la spec normativa y la golden como contrato.

## 4. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Las fixtures no cubren algo que el oráculo sí | Auditoría de mutaciones (Fase D); si una mutación sobrevive, se agrega el caso |
| Perder la respuesta a "¿qué haría el C++?" | Tags archivados + tarball; se consultan sin estar en `main` |
| El C++ tiene UB y no es un contrato | Ya está documentado: donde 1.0.7 no define, manda la spec (v6) |
| El Rust era el único oráculo de v5 | v5 se puede seguir escribiendo; sus fixtures se graban antes de retirarlo |
| Cambios de texto de la CLI sin oráculo | Fixtures de CLI (Fase B.2) |
| Los benchmarks/fuzz de C++ (`local_hardening`) | Se archivan con el oráculo; el fuzz del **decoder del Pascal** pasa a ser la compuerta de robustez |
| El retiro se mezcla con C/asm | Son independientes: el retiro no necesita C/asm, y C/asm no necesita los oráculos (la referencia de cada función nativa es Pascal) |

## 5. Esfuerzo estimado

| Fase | Trabajo | Estimación |
|---|---|---|
| A | A1/A4 + v6 congelado | ya hecho en su mayoría |
| B | Golden v6 + v1–v3 + CLI + vectores | 3–5 días |
| C | Desacoplar suites y checklist | 2–3 días |
| D | Auditoría de mutaciones | 2–4 días |
| E | Tags, tarball, borrado, docs | 1 día |
| F | Verificación en las seis plataformas | 2–3 días |

Total: **~2 semanas** de trabajo efectivo, sin contar la implementación de v6
(que ya está) ni C/asm.

## 6. Decisiones (tomadas el 2026-11-10)

1. **`--format=v5` no se escribe en 3.0.0**: v5 queda **solo lectura**, como
   v1–v3. Se escribe v6 por defecto y v4 con `--format=v4`. Sus fixtures de
   lectura se graban ahora, mientras el port y el Rust todavía pueden
   escribirlos.
2. **Archivo doble**: tags `oracle-cxx-1.0.7` / `oracle-rust-2.1.2` **y**
   tarball adjunto a un release de oráculos.
3. **Auditoría de mutaciones completa** antes de retirar.
4. **El fuzz del C++ se reemplaza por el fuzz del decoder del Pascal**, y el
   del C++ se archiva con el oráculo.
