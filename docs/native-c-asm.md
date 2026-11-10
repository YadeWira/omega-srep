# C y asm embebido: plan

**Estado: plan, sin código todavía (2026-11-10).** Decisión de Wira: lo que se
distribuye pasa a ser **Free Pascal + C + asm embebido**, no solo Pascal. Este
documento fija el contrato, el enlace y el orden; no cambia nada del formato.

## 0. Objetivo y no-objetivo

**Sí:** acelerar funciones hoja y medibles —CRC, comparación de bytes, copia,
hashes, el lazo del escaneo— sin mover a C la lógica de formato, el contenedor
ni la CLI. La estructura sigue en Pascal; C/asm entran donde el perfil diga.

**No:** reescribir el encoder en C, cambiar los bytes de ningún archivo,
depender de la libc en los binarios estáticos, ni reemplazar el Pascal como
implementación de referencia.

## 1. Contrato (reglas de oro)

1. **Toda función nativa tiene una referencia en Pascal**, y un test
   diferencial que compare las dos sobre entradas del corpus y aleatorias. El
   build de referencia es `-dOSREP_NO_NATIVE` (todo Pascal).
2. **Funciones puras**: sin estado global mutable, sin `malloc`/`printf`, sin
   libc; los buffers los pone el llamador. Se compilan con
   `-ffreestanding -fno-builtin -fno-stack-protector -fno-pic`.
3. **ABI C (`cdecl`)** y tipos de ancho fijo (`uint32_t`, `size_t`…), nombres
   con prefijo `osrep_`. Nada de estructuras Pascal cruzando la frontera.
4. **Los bytes no cambian**: una función nativa tiene que dar exactamente el
   mismo resultado que la de Pascal. Los tests lo verifican, no se asume.
5. **Sin `-march=native`**: los objetos se compilan para el piso de cada
   target y la ruta rápida se elige en runtime (CPUID/HWCAP), con la de Pascal
   o la de tabla como fallback.
6. **El asm embebido** (bloques `asm` de FPC) se reserva para hojas chicas:
   prefetch, CPUID, instrucciones sueltas. El código vectorial va en C con
   intrinsics, que es más legible y portable entre gcc/clang/mingw.

## 2. Enlace: verificado en los cinco targets

Prueba de concepto hecha el 2026-11-10: una función C (`int add(int,int)`)
compilada por separado y enlazada en un programa FPC, **en los cinco targets**,
ejecutada en cada uno (nativo, wine32/64, qemu-aarch64): devuelve 5 en todos.

Mecanismo:

1. `build.sh` compila los `.c` con el compilador de cada target:
   - linux-x86_64: `gcc`
   - linux-x86: `gcc -m32`
   - linux-aarch64: `aarch64-linux-gnu-gcc`
   - win32: `i686-w64-mingw32-gcc`
   - win64: `x86_64-w64-mingw32-gcc`
   - macOS-arm64: `clang` nativo (en un Mac)
2. Genera, por target, `$OUT/units-<target>/native_objs.inc` con una línea
   `{$L /ruta/al/objeto.o}` por objeto.
3. La unidad Pascal `native.pas` hace `{$I native_objs.inc}` en la
   implementación y declara las funciones `cdecl; external;`.
4. La compilación agrega `-Fi$OUT/units-<target>` para que FPC encuentre el
   include. Cada target tiene su propio directorio de unidades, así que no hay
   colisión entre builds.

Los objetos van a `pascal/bin/obj/<target>/`. En macOS el include apunta a los
`.o` que produce clang; el binario se construye **en el Mac** (no hay cross
práctico desde Linux por el SDK).

## 3. Componentes, en orden de prioridad

| # | Componente | Qué se acelera | Ganancia esperada | Riesgo | Fase |
|---|---|---|---|---|---|
| 1 | **CRC-32C** | CRC de header/footer/bloque y `--verify` (hoy tabla byte a byte) | alta en `--verify` y en encodes grandes; 10–20× el CRC | bajo: mismo valor, algoritmo fijo | 1 |
| 2 | **memcmp / CommonPrefix / memcpy** | extensión de matches, literales, copia de descompresión | media-alta en compresión y decode | bajo: comparación/copia puras | 2 |
| 3 | **AES del VMAC / SHA1** | hashes por bloque (AES-NI en x86, crypto NEON en ARM) | media; el hash por defecto es VMAC | medio: el digest tiene que ser idéntico | 3 |
| 4 | **Lazo del escaneo** (`FixedCompressAccel`, `Hash1Batch`/`CheckBatch`) | el corazón de `-m3..-m5` | la más alta | **alta**: es donde vive la paridad byte a byte | 4 |
| 5 | **Prefetch / win32** | el escaneo en win32, que hoy no tiene los prefetch de Linux/win64 | baja-media | bajo | 1 |
| 6 | **Copia de bloques del decoder** | `SinkWrite` y similares | media en decode | bajo | 2 |

Notas:

- **CRC-32C no toca los archivos.** En v6 el hash de frontera del CDC es el
  polinomial para todas las plataformas (§2.4 de `format-spec-v6.md`); el CRC
  por hardware solo acelera los CRC del contenedor y de `--verify`. Los bytes
  de los `.osr` no cambian.
- **El escaneo va último** a propósito: es el que más gana y el que más puede
  romper la paridad. Antes de tocarlo, un perfil que muestre dónde se va el
  tiempo (D19 ya dejó el método).
- **`memcmp`/`memcpy`** son los que mejor relación ganancia/riesgo tienen: una
  diferencia ahí se ve como un match distinto, no como un byte suelto.

## 4. Dónde va cada lenguaje

- **Pascal:** contenedor, encoder/decoder de alto nivel, CLI, todo lo que
  decide bytes, y la referencia de cada función nativa.
- **C con intrinsics:** SIMD (SSE2/SSE4.2/AVX2/NEON), CRC por hardware,
  AES/SHA por hardware, comparación y copia vectorial.
- **Asm de FPC:** prefetch (`prefetchnta`), CPUID/HWCAP si conviene, y hojas
  de una instrucción. Por arquitectura con `$IFDEF CPUX86_64/CPUI386/CPUAARCH64`
  y `{$asmmode}` dentro del branch.

## 5. Build, fallback y reproducibilidad

- `build.sh` sigue construyendo los seis targets (cinco hoy + macOS cuando
  exista el Mac) y suma la compilación de C y el include por target.
- **Fallback:** `-dOSREP_NO_NATIVE` genera un include vacío y usa solo Pascal.
  Sirve para (a) la referencia de los tests diferenciales y (b) targets sin
  ruta nativa.
- **Dispatch:** `HasSse42` ya existe; se suma `HasArmCrc32` (HWCAP) y, si hace
  falta, `HasAvx2`. Si la CPU no tiene la instrucción, se usa la tabla/Pascal.
  `OSREP_NO_SSE42`/`OSREP_NO_HWCRC` fuerzan el fallback para probarlo.
- **Reproducibilidad:** flags fijos y versiones de compilador anotadas; nada de
  `-march=native`.
- Windows 7: la ruta de fallback tiene que andar en CPUs sin SSE4.2; se prueba
  forzando `OSREP_NO_SSE42` en la VM.

## 6. Pruebas

1. **`tests/native_conformance.sh`**: para cada función nativa, entradas del
   corpus + aleatorias con semilla fija, comparando contra la referencia
   Pascal; y el build con `-dOSREP_NO_NATIVE` contra el nativo.
2. **Paridad de archivos**: la matriz de la golden y el corpus de 220 con
   `--seed=7`, comprimido con el build nativo y con el de referencia: mismos
   bytes, byte a byte.
3. **Compuertas existentes** con el build nativo (no se duplican: se corre la
   lista de siempre).
4. **Win7 real** con el build nativo, y forzando el fallback.
5. **ARM64** con qemu y la VM; el HWCAP de qemu puede no exponer CRC, así que
   ahí se prueba el fallback y la ruta de hardware por separado.

## 7. Fases y criterio de aceptación

0. **Scaffolding (hecho el 2026-11-10):** POC de enlace en los cinco targets.
   Siguiente: `native.pas`, compilación de C en `build.sh`, include por target,
   y una función trivial con su test (sin cambiar bytes).
1. **CRC-32C por hardware** (SSE4.2/ARMv8) + fallback + test + benchmark.
   Aceptación: mismos CRC en toda la matriz; `--verify` más rápido.
2. **memcmp/CommonPrefix/memcpy SIMD.** Aceptación: los 220 archivos dan los
   mismos `.osr` con y sin la ruta nativa.
3. **AES-NI para VMAC / SHA-NI para SHA1.** Aceptación: digests idénticos.
4. **Lazo del escaneo en asm/C.** Aceptación: misma paridad + medición; si no
   hay ganancia clara, se descarta.
5. **macOS ARM64** (build nativo) y validación.

## 8. Decisiones abiertas

1. **¿C con intrinsics o asm puro para SIMD?** Recomiendo C con intrinsics, y
   asm solo para prefetch/CPUID.
2. **¿Se acepta la referencia Pascal obligatoria por función?** Recomiendo sí:
   es lo que hace que "no cambian los bytes" sea verificable.
3. **¿CI con runner macOS** para construir y probar ahí, o build manual en un
   Mac de Wira?
4. **Licencia:** el repo no tiene `LICENSE`; si el C/asm es propio, hay que
   decidir la del proyecto antes de distribuir binarios con partes nuevas.
