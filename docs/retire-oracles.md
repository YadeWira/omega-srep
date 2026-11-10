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

**Implementado el 2026-11-10:** `tests/gates.sh core` corre solo el núcleo
(golden, v6 y su self-test); `full` agrega las diferenciales. Probado en un
worktree con `oracles/` borrado y un build limpio: **core pasa entero**
(golden 69, v6 42, frame 78). `harness_selftest` quedó del lado diferencial
porque compila el harness Rust.

**Aceptación:** en un clon sin `oracles/`, `g++` ni `cargo`, el núcleo pasa
entero y ninguna suite se saltea en silencio (las diferenciales dicen por qué).

### Fase D — Auditoría de mutaciones (la prueba)

**Implementado el 2026-11-10.** `tests/mutations/` tiene 15 mutaciones; cada
una es un `.py` que parchea una copia de HEAD, `run.sh` la compila con FPC y
corre `tests/gates.sh core`. CAUGHT si el núcleo falla; SURVIVED si pasa.
Resultado: **13 cazadas, 0 supervivientes, 2 equivalentes** documentadas.

| # | defecto | lo caza |
|---|---------|---------|
| 02 | `-ia-` ignorado (R19) | golden v4, 4 casos |
| 03 | `-a0` leído como "no dado" | `text.bin -m3 -l17 -a0` |
| 04 | v6 sin CRC de bloque | golden/CLI v6 |
| 05 | semilla de CRC-32C distinta | golden/CLI v6 |
| 06 | varint de 6 bits | golden/CLI v6 |
| 07 | segundo pase sin `SortBySrc` | golden v4 |
| 08 | sin read-ahead del digest | `a33929 -m3 -l130 -b261b` v6 |
| 09 | cap 16→8 (R11) | `text.bin -m3 -l100 -a16` |
| 10 | umbral de la quick path 2L→3L (R18) | el mismo caso de `a33929` |
| 11 | cola del escaneo sin marcar (R15) | golden `-m3`/`-m4` |
| 13 | `BASE_LEN` de cabecera +1 | la ida y vuelta de cualquier v4 |
| 14 | bloques corridos (`HtChunkPos`) | `text.bin -m3 -b1000001b` v6 |
| 15 | decodificador: último run de literales | ida y vuelta v4/v5/v6 |

Las dos equivalentes viven en `tests/mutations/equivalent/` con la medición:
**01** (`-m5` con escaneo plano: el C++ y el Rust también dan lo mismo con
`-a0`) y **12** (variantes 32/64: ningún input medido las distingue de 16 ni
de 0, así que R20 sigue sin caso). **P04** no se pudo reconstruir: la lista de
la revisión 2.3.0 se borró y no quedó el parche; la 15 cubre la clase
"decodificador".

De acá salieron cuatro casos nuevos: `-l17 -a0` y `-l100 -a16` (v4),
`a33929 -l130 -b261b` y `-b1000001b` (v6). Un `-l` que no es potencia de dos
avisa y sale con 1 con el archivo ya escrito; `make.sh`/`make-v6.sh` aceptan
ese exit code (y solo ese, contra el texto del aviso) y el manifiesto lo
guarda.

**Aceptación:** 100 % de las mutaciones de la lista fallan en el núcleo (o
quedan documentadas como equivalentes con la medición), y la lista queda
versionada como `tests/mutations/` (el parche de cada una).

### Fase E — Archivar y sacar

**Implementado el 2026-11-10.**

- Tags anotados **`oracle-cxx-1.0.7`** y **`oracle-rust-2.1.2`** en `b57e4e8`,
  el último commit con `oracles/`, pusheados.
- Release **`oracle-cxx-1.0.7`** con el tarball
  `omega-srep-oracles-cxx-1.0.7-rust-2.1.2.tar.gz` (388 KB, 135 archivos,
  los dos árboles trackeados + `RETIRED.md`). Comprobado: el C++ compila con
  su Makefile y el Rust con el pin 1.77.2 desde el tarball extraído.
- `oracles/` fuera de `main` en un commit propio. `tests/_paths.sh` deriva
  `CXX_DIR`/`CXX_BIN`/`RUST_DIR`/`RUST_TARGET` de **`OSREP_ORACLES`**;
  `tests/gates.sh full` se niega con las instrucciones del release si falta, y
  `core` no lo necesita. Las suites diferenciales siguen enteras para cuando
  se extraiga el archivo.
- `README.md` reescrito (los oráculos, archivados; cómo correr el `full`);
  `oracles/README.md` → `docs/retired-oracles.md`; nota histórica en
  `docs/pascal-port.md`; `.gitignore` sin las rutas de los oráculos.
- El fuzz de robustez pasa a ser el del decoder Pascal: `tests/fuzz.sh` usa
  el port por defecto y `tests/fuzz_regression.sh` (en `core`) reproduce los
  artefactos de crash contra el decoder. Los harnesses C++-only
  (`local_hardening.sh`, `pgo_train*.sh`) se fueron con los tags.
- **CLI**: queda como está hasta la 3.0.0. Pasar el default a v6 y rechazar
  `--format=v5` obliga a retirar o adaptar las suites diferenciales que
  escriben v5 (`rust_cli_conformance` con el port, `pascal_v5/dup/container`,
  `format_v5`), y ese corte es el de la 3.0.0. Queda listado en la Fase F.

**Aceptación:** `git grep -i "oracle\|oráculo"` en `main` solo encuentra
documentación histórica; ningún script de `tests/` resuelve rutas dentro de
`oracles/` (los comentarios de procedencia quedan como historia).

### Fase F — Verificación final

- **CLI 3.0.0**: default `v6`, `--format=v5` rechazado con el mensaje de
  `format-spec-v6.md` §4, `--help` listando `v4|v6`. Antes hay que retirar o
  adaptar las suites diferenciales que escriben v5 (`rust_cli_conformance` con
  `OSREP_PORT_BIN`, `pascal_v5/dup/container`, `format_v5`) y re-grabar los
  fixtures de CLI; los archivos v5 viejos se siguen leyendo.
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
