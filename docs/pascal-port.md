# Port a Pascal (FPC) — plan

> **Estado**: en curso. La decisión se tomó el 2026-09-25; las fases 0 a 6
> están hechas: el port decodifica los cinco contenedores, comprime con los
> seis compresores en los cuatro contenedores que se escriben, hace `-dup` y
> `--verify`, todo byte a byte igual que el Rust y el C++. Falta la CLI y el
> release.

## Por qué, y qué cambió respecto del port a Rust

El port a Rust está terminado y publicado (v2.1.0). No falló: pasa 219 pruebas
de conformidad de CLI, 519 de `rust_conformance`, y sus tres binarios se
verifican en una máquina Windows 7 SP1 real en cada release, con bytes
idénticos entre Linux x64, Win7 x64 y Win7 x86.

Lo que cambió no es nuestro código, es **el compromiso de Rust upstream con
los dos requisitos que este proyecto sí tiene**: Windows 7 y 32 bits.

* **`i686-pc-windows-gnu` pasó de Tier 1 a Tier 2 en Rust 1.88.0** ([RFC
  3771](https://rust-lang.github.io/rfcs/3771-demote-i686-pc-windows-gnu.html),
  [anuncio](https://blog.rust-lang.org/2025/05/26/demoting-i686-pc-windows-gnu/)).
  Es la **primera degradación de un Tier 1** desde que existe la Target Tier
  Policy. El RFC cita: **cero mantenedores** (la política pide un mínimo de
  tres), uso bajo (76K descargas de rustc, 56K de std, comparable a FreeBSD),
  fallas de CI y tests deshabilitados con `ignore-windows-gnu`. Dice que x86 de
  32 bits está *«especialmente afectado»*, que los expertos de Windows-GNU
  *«se enfocan casi exclusivamente en los targets de 64 bits»*, y que MSYS2
  *«está dejando de empaquetar cosas de 32 bits»*.
* **El mismo RFC anticipa el siguiente escalón** —Tier 2 sin host tools— y
  aclara que **no hará falta otro RFC**, alcanza con un MCP.
* **Windows 7 dejó de ser piso Tier 1 en Rust 1.78**, que es exactamente por
  qué `rust-toolchain.toml` está clavado en **1.77.2**.

Esa última es la peor parte y no se ve en la tabla de tiers: **el pin es
permanente**. Nunca podemos tomar un arreglo del compilador, porque subir de
1.77.2 rompe Win7. Un bug de codegen en i686 en esa versión es nuestro para
siempre. Ya estamos fuera del soporte upstream; la degradación sólo confirma
la dirección.

La salida oficial de Rust para Win7 son los targets `*-win7-windows-msvc`,
pero son **Tier 3**: no se compilan ni se testean, no hay artefactos en rustup
(hay que construirse la std con `build-std`) y son **MSVC**, así que el
cross-compile desde Linux con MinGW —que es como construimos hoy— no aplica.

**FPC va en la dirección contraria.** Para Free Pascal, i386/Win32 es el
camino más viejo y más ejercitado, no un target periférico que se esté
soltando; 3.2.2 declara piso en «NT/2000/XP o posterior». Y hay precedente en
casa: **ytool** (FPC, mismo autor) compila y corre nativo en i386-win32 con
sus once codecs, **verificado bajo WOW64 en Windows 7 SP1 con round-trip
bit-exacto** contra la build de 64 bits.

## Lo que NO hay que rehacer

Esto no es empezar de cero. El port a Rust dejó cosas que son independientes
del lenguaje y se usan tal cual:

| Activo | Estado |
|---|---|
| **Suite de conformidad de CLI** (219 pruebas + 10 scripts) | Es shell y apunta al binario por `OSREP_BIN`. Corre contra un binario Pascal **sin tocar una línea**. |
| **`docs/format-spec.md` y `docs/format-spec-v5.md`** | El diseño de v5 se hizo durante la fase 5a del port a Rust. Ya está escrito, con su layout y sus decisiones. |
| **Los arreglos al oráculo C++** | 1.0.6 y 1.0.7 fueron bugs del C++ encontrados *por* el port; más `-index=` e `-c1..-c7` en 2.0.1. Siguen arreglados. |
| **`docs/rust-port.md`** | Cada decisión no obvia, con su medición. Un mapa de dónde están las trampas, escrito por alguien que ya recorrió el camino. |
| **Los invariantes de `--verify`** | Incluido el error que costó dos intentos: los records de Future-LZ **no** son «run de literales y después match». Ver más abajo. |

## Dos oráculos, no uno

El port a Rust se validó contra **un** oráculo, el C++. El port a Pascal tiene
**dos**: el C++ *y* el Rust, que ya son byte-idénticos entre sí en todos los
modos.

Eso es estrictamente más fuerte, y hay que explotarlo: una discrepancia contra
uno solo es ambigua (¿quién tiene razón?), pero contra dos que coinciden entre
sí, el que está mal es el nuevo. **Por lo tanto el Rust se queda en el árbol,
igual que el C++, y por el mismo motivo.**

## Fase 0 — toolchain: **CUMPLIDA** (2026-09-25)

El `fpc 3.2.2` del sistema trae **sólo el compilador x86-64** (`ppcx64`), con
targets Linux/FreeBSD/Win64. No sirve para i386-win32.

**No hay que instalar nada, y sobre todo no hay que instalar el paquete
i386 de Debian.** `apt-get install fp-compiler-3.2.2:i386` quiere **eliminar
30 paquetes**, entre ellos `build-essential`, `gcc-14`, `g++`, `binutils` y
`clang` — o sea el toolchain con el que se compila el oráculo C++, en una
máquina compartida con otros agentes. Simulado antes de ejecutarlo; no
ejecutar.

Lo que sí funciona: **ya existe un cross de FPC en el área compartida**, hecho
por PArc/PA-Lab:

```
/mnt/IA_LAB/compartido/parc/fpc-cross/lib/fpc/3.2.2/
    ppcross386     -> Win32 for i386, Linux for i386, Go32v2, OS/2, FreeBSD
    ppcrossx64     -> Win64 for x64
    units/i386-win32/  units/x86_64-win64/
```

Verificado de punta a punta el 2026-09-25, los tres targets que shipeamos:

| target | compilador | resultado |
|---|---|---|
| `i386-win32` | `ppcross386 -Twin32 -Pi386` | PE32 i386, **corre en Windows 7 SP1 real** |
| `x86_64-win64` | `ppcrossx64 -Twin64 -Px86_64` | PE32+ x86-64, **corre en Windows 7 SP1 real** |
| `x86_64-linux` | `fpc` del sistema | corre local |

Es decir que el cross-compile desde Linux funciona para los tres, igual que
con Rust y MinGW, y el flujo de release no cambia de forma.

**El toolchain es nuestro**, en `/mnt/IA_LAB/agentes/osrep/fpc-cross`, con su
`PROCEDENCIA.md`. Vivía en `compartido/` y funcionaba, pero no era nuestro: si
PArc o PA-Lab lo actualizan o lo mueven, nuestra build cambia sin que toquemos
nada — el problema de una dependencia sin pin. La copia cuesta 680 MB y lo
convierte en nuestro. (La sugerencia es de ytool.)

Detalle que cuesta diez minutos si no está escrito: **el cross no trae
`fpc.cfg`**, así que las unidades van explícitas con `-Fu`, y el directorio de
`-FU` tiene que existir de antes porque el compilador no lo crea.

Respondió ytool sobre cómo compilan ellos: **nativo en Windows dentro de la
VM** —win64 con el FPC de Lazarus, i386-win32 con un FPC standalone bajo
WOW64— y desde Linux sólo cross-compilan el C. Y aclararon algo que importa:
**no evaluaron este cross y lo descartaron, es que no existía** cuando
decidieron (su primer `winbuild-x86` es del 2026-07-10, el cross es del
2026-09-24). O sea que no hay un criterio técnico en contra que estemos
ignorando.

## Layout

    pascal/
      osrep.lpr            el programa (hoy: --version y --help)
      hashtool.lpr         herramientas de prueba: cada una expone una capa
      containertool.lpr    para diffearla contra el oraculo antes de que
      decodetool.lpr       exista la CLI completa
      encodetool.lpr
      verifytool.lpr
      build.sh             todo lo anterior, en los tres targets
      src/
        widths.pas         guardas de ancho en tiempo de compilacion
        outraw.pas         escritura cruda a stdout/stderr
        help.pas           --version y --help, byte a byte
        hashes.pas         md5, sha1, sha512
        hasheskeyed.pas    siphash
        aes.pas, vmac.pas  vmac y el AES que usa
        digest.pas         que digest verifica un archivo (Digest::for_archive)
        container.pas      header, bloques, footer v4 y v5, CRC-32C
        decompress.pas     decoder I/O-LZ (v1/v2), LzCopy, GrowOut
        futurelz.pas       decoder Future/Index-LZ (v3/v4) y v5: memory
                           manager, heap de matches, spill a disco
        rolling.pas        hashes rodantes de los match finders
        lzcodec.pas        el codec de records LZ (ENCODE/DECODE_LZ_MATCH)
        hashtable.pas      el match finder de -m3/-m4/-m5
        fixedcompress.pas  el compresor de un bloque de -m3/-m4/-m5
        inmem.pas          el REP en memoria de -m0 (y de -d)
        cdc.pas            chunking por contenido de -m1/-m2
        cpufeat.pas        si la CPU tiene SSE4.2 (elige la ruta de CDC)
        secondpass.pas     la segunda pasada: v3, v4 y v5
        dedup.pas          el pre-paso -dup: CDC, dedup y la meta .dupref
        dupwrap.pas        -dup pegado al encoder y al decoder
        v5verify.pas       --verify de v5 e inspeccion de v1-v4
        encoder.pas        el driver de compresion
        spillfile.pas      el temporal del spill, creado como el Rust (lo
                           unico que depende de la plataforma)
    tests/
      pascal_cli_conformance.sh        --version/--help contra el binario Rust
      pascal_hash_conformance.sh       los cinco digests y AES
      pascal_container_conformance.sh  leer y reescribir el armazon
      pascal_decode_conformance.sh     I/O-LZ, errores de decodetool, y que v5
                                       diga "no portado"
      pascal_futurelz_conformance.sh   v3/v4, con la linea de estadisticas entera
      pascal_encode_conformance.sh     el encoder, byte a byte contra el Rust
      pascal_dup_conformance.sh        -dup byte a byte y --verify contra osrep --verify
      pascal_v5_conformance.sh         v5, y el mismo error que el Rust en ~1.700
                                       archivos danados

`pascal/bin/` es salida de build y está en `.gitignore`. `build.sh` construye
el programa y las tres herramientas para Linux x86-64, Win64 y Win32 (las
herramientas salen como `decodetool`, `decodetool64.exe`, `decodetool32.exe`,
etc.), y si el compilador falla muestra por qué. `OSREP_PASCAL_OUT=<dir>`
construye en otro lado, para no pisar binarios que algo está ejecutando. El
build es **reproducible**: dos corridas dan los mismos bytes, así que un `cmp`
alcanza para saber si un binario en uso es el del árbol actual.

Los harnesses toman el binario de `OSREP_PASCAL_DECODETOOL` (y equivalentes).
Para los targets Windows se apuntan a un wrapper que lo corre bajo wine
—`exec env WINEDEBUG=-all wine .../decodetool32.exe "$@"`—, que tiene que
**dejar pasar stderr**: el harness de Future-LZ compara el mensaje de error.

## Fases

Mismo esqueleto que `docs/rust-port.md`, que ya demostró funcionar, y con el
mismo criterio de corrección: **diff byte a byte contra el oráculo, no
round-trip**.

| Fase | Qué | Puerta |
|---|---|---|
| **0** | Toolchain: FPC para i386-win32 y x86-64 | **hecha** (2026-09-25): los tres targets verificados, i386 corriendo en Win7 real |
| **1** | Andamiaje: layout, CLI que responde `--version`/`--help` | **hecha** (2026-09-25): byte a byte en los tres targets, verificado en Win7 real |
| **2** | Digests: vmac, siphash, md5, sha1, sha512, más AES | **hecha** (2026-09-25): 300 comprobaciones contra el oráculo, y los cinco idénticos también en i386-win32 y x86_64-win64 sobre Win7 real |
| **3** | Container: header, seed, bloques, footer v4 y v5 | **hecha** (2026-09-25): 84 comprobaciones, 80 archivos leídos igual que el oráculo y **reescritos byte a byte**; idéntico en i386 y x64 |
| **4a** | Decoder I/O-LZ (v1/v2, sufijo `o`) | **hecha** (2026-09-25): 231 comprobaciones, 225 combinaciones byte a byte, verificado en i386 y x64 |
| **4b** | Decoder Future/Index-LZ (v3/v4) + memory manager + spill | **hecha** (2026-09-26): 80 comprobaciones (79 bajo wine) con la línea de estadísticas entera —incluidos los bytes del spill— y los bytes reconstruidos; decode sube a 248. Revisión adversarial de cinco enfoques, ~80.000 comparaciones diferenciales: cero divergencias en el decoder, 17 hallazgos en los bordes que se reducen a 4 causas, todas arregladas con su regresión (verificado que cada una falla con el bug reintroducido). Win7 real: 73/73 en i386 y en x64 |
| **4c** | Decoder v5 | **hecha** (2026-10-09): 1.764 comprobaciones en Linux, i386 y x64 —60 archivos (12 métodos y hashes, `-dup` incluido) y el spill bajo cuatro presupuestos con la línea de estadísticas entera, ~1.700 archivos dañados que fallan **con el mismo mensaje** que el Rust, y 59 mutaciones que el Rust acepta y el Pascal reconstruye igual. Verificado que el harness atrapa tres bugs inyectados (después de agregar los casos que hicieron falta para dos de ellos). Win7 real: 70/70 en i386 y en x64 |
| **5** | Encoder: los 17 modos | **hecha** (2026-10-09). En cuatro partes, cada una con su gate contra el encoder Rust en `tests/pascal_encode_conformance.sh` (lo no portado se cuenta aparte, no como fallo): |
| 5a | match finder (`-m3`/`-m4`/`-m5`) y driver, contenedor I/O-LZ | **hecha** (2026-10-09): 83 archivos byte-idénticos en Linux, i386 y x64 — `-m3o`/`-m4o`/`-m5o` con `-b1mb`, `-l1024`, `-l256`, los seis hashes, 20 MiB cruzando bloques y entradas degeneradas |
| 5b | REP en memoria (`-m0`, `-d`) y CDC (`-m1`/`-m2`) | **hecha** (2026-10-09): 171 archivos byte-idénticos en Linux, i386 y x64 — `-m0o` dando vueltas al anillo, `-d` sobre `-m3o`/`-m4o`/`-m5o`, y CDC por **las dos rutas** del hash de frontera (CRC32C con SSE4.2, polinomial con `OSREP_CDC_POLY=1`), sobre una entrada en la que las dos rutas dan archivos distintos |
| 5c | segunda pasada: Index-LZ (v4) y Future-LZ (v3) | **hecha** junto con la 5d: la segunda pasada de Rust arma los tres contenedores |
| 5d | writer v5 | **hecha** (2026-10-09): 376 archivos byte-idénticos en Linux, i386 y x64 — toda la matriz de `encode_conformance.sh` más v5 con `-hash-`, siphash, sha512, `-b1mb` y `-d`, contra el Rust (308) y contra el C++ directo en v1–v4 (68). Win7 real: 108/108 en i386 y en x64. Velocidad, sin gate (como en Rust): x64 nativo 2,7–2,9× más lento que Rust en `-m3`/`-m4`, igual en `-m5`, más rápido en `-m0`/`-m1`; i386 1,5–1,7× más lento que x64 |
| **6** | `-dup` y `--verify` | **hecha** (2026-10-09): `tests/pascal_dup_conformance.sh`, 797 comprobaciones en Linux, i386 y x64 — archivos `-dup` byte-idénticos al Rust (v5, con la meta adentro) y al C++ (v4, con el trailer ODUP) que vuelven a la entrada por el decoder del Pascal, y `--verify` con **la misma salida y el mismo código** que `osrep --verify` en archivos sanos, v1–v4, lo que no es un `.osr` y ~710 mutaciones. Verificado que atrapa tres bugs inyectados. Win7 real: 18/18 y 8/8 en i386 y en x64, sin temporales. **Sin cubrir todavía**: el corte Gear y `--dup-paranoid`, que son opciones de la CLI (`--chunk-*`) y no tienen oráculo hasta la fase 7 |
| **7** | CLI completa | **hecha** (2026-10-09): `pascal/osrep.lpr` + `src/cliargs.pas` (args.rs), `src/clireport.pas` (report.rs) y `src/randbytes.pas`. La puerta del Rust entera, **`rust_cli_conformance.sh` con `OSREP_PORT_BIN` apuntando al Pascal: 225/225** — la capa byte a byte contra el C++ 1.0.7, pipes, `-index=`, `--verify`, `stderr_conformance` y las diez suites CLI. Además `tests/pascal_cli_conformance.sh`, 96 comprobaciones en Linux y bajo wine i386/x64: ~35 líneas de comandos con archivo e índice idénticos al Rust (incluye lo que la fase 6 no podía: Gear, `--dup-paranoid`, `--chunk-*`), pipes con y sin `-s`, ~37 errores con **el mismo código y el mismo stderr**, warnings, `OSREP_SEED_HEX`, nombres derivados, `-delete`, `-bar`. Verificado que atrapa siete bugs inyectados (después de agregar los casos para cinco que se escapaban). Win7 real: 170/170 en i386 y x64, sin temporales en `%TEMP%`. Encontró dos bugs que no eran del Pascal: el v5 por pipe del Rust (92b4a77) y el pánico de `-s` menor que la entrada (d267376). **Divergencia conocida**: los errores de los decoders llevan el mensaje (Display) y no el Debug del Rust; mismo código, otro texto |
| **8** | Release: tres targets, verificación en Win7 real, tag | como 2.1.0 |

## Trampas conocidas, para no redescubrirlas

* **`{$IFDEF}` con un símbolo mal escrito evalúa falso en silencio.** FPC no
  avisa. A ytool le costó **toda la vida de su port**: un `CPU64BITS` (que no
  existe; el correcto es `CPU64`) hizo que *toda* build de 64 bits tomara la
  rama de 32, capando la memoria a 1,5 GB y desactivando opciones, en Linux y
  Windows por igual. Es exactamente la forma que venimos cazando —un éxito
  silencioso— y en Pascal el compilador no ayuda. **Cualquier `{$IFDEF}` nuevo
  necesita una prueba que demuestre que la rama que uno cree activa está
  activa.**
* **Las DLL de 32 bits pueden depender de runtimes de mingw que no están en un
  Windows de fábrica.** A ytool le pasó con `-mflac`: `LoadLibrary` fallaba y
  el encoder nunca corría. Se arregló con `-static-libgcc`.
* **i686 no habilita SSE2 por defecto** (x86-64 sí). Hay que pasarlo explícito.
* **Los records de Future-LZ no son «literales y después match».** `lit_len` es
  el hueco hasta el *origen* del próximo match, el match se copia *hacia
  adelante* a `src + distance`, y el cursor avanza al origen, no más allá del
  match. Escribir la aritmética clásica de LZ ahí rechaza archivos sanos: pasó
  al implementar `--verify` en Rust. Ver `decompress_block`
  (`future_lz.rs:544-551`).
* **Nunca usar `SizeInt`, `PtrUInt` ni `NativeUInt` en aritmética que llegue al
  archivo.** Miden **4 bytes en i386 y 8 en x86-64** (medido el 2026-09-25 en
  Win7 real con los dos binarios). Esta es *exactamente* la forma del bug que
  ya mordió a este proyecto en C++: `PolynomialRollingHash<size_t>` tenía un
  módulo que dependía del ancho de `size_t`, así que `-m1`/`-m2` producían
  fronteras de chunk distintas en 32 y 64 bits y corrompían en silencio
  cualquier archivo comprimido en un ancho y descomprimido en el otro (ver
  `docs/32bit-support.md`). En Pascal se reproduce igual de fácil. **Usar
  siempre tipos de ancho explícito** —`QWord`, `Int64`, `DWord`, `Cardinal`—
  en todo lo que toque el formato.
* **La aritmética de 64 bits en Pascal puro SÍ es portable**, y eso está
  medido, no supuesto: `div`, `mod` y los shifts sobre `QWord` dan resultados
  idénticos en i386-win32 y x86_64-win64. El problema de los helpers que falta
  (`__udivdi3` y compañía) es de **objetos C enlazados desde Pascal**, no de
  Pascal. Si el port se mantiene puro, no aparece.
* **Tres trampas más, si alguna vez enlazamos C** (reportadas por ytool, que
  las sufrió): FPC le antepone un guion bajo a todo `external cdecl` en
  i386-win32 aunque pongas cláusula `name`, y si los bindings ya lo traen
  estilo Delphi queda doble y el símbolo no resuelve (~120 declaraciones en su
  caso); un `external` **sin** `cdecl` no da error, compila con otra
  convención y revienta en runtime; y enlazar objetos C en i386 pide helpers
  que la RTL de FPC no trae ahí (`memset`, `memcpy`, aritmética de 64 bits).
  En x86-64 ninguna de las tres aparece.
* **En i386, FPC no acepta un `QWord` como variable de control de un `for`.**
  «Ordinal expression expected», y **sólo en la build de 32 bits**: el mismo
  código compila limpio para x86-64. Es la mejor clase de diferencia entre
  arquitecturas, porque falla ruidoso, pero si uno sólo compila para 64 bits
  no se entera. Se arregla con un índice `LongInt` aparte para lo que nunca
  pasa de unos pocos bytes, o con `FillChar` donde el `for` sólo llenaba ceros.
* **Los nombres de las constantes importan más que los comentarios.** En
  `vmac.c` la máscara de las claves poly es `mpoly = 0x1fffffff1fffffff`, y a
  tres líneas vive `m62 = 0x3fffffffffffffff`. Usar la segunda da un vmac que
  deriva bien todas las claves, pasa AES contra el C vendorizado, transcribe
  `l3hash` exacto — y devuelve el digest equivocado para *toda* entrada. La
  encontró leer el nombre de la constante, después de descartar por medición
  AES, las claves NH, las poly, las L3 y `l3hash` uno por uno.
* **El CRC-32C de este proyecto NO es el canónico.** Arranca en **0** y **no
  hace el XOR final** (`rolling.rs:286`, `crc32c_of`); la tabla sí es la
  estándar. Usar la variante de libro —init `0xFFFFFFFF`, xor final
  `0xFFFFFFFF`— compila, corre, y rechaza como corrupto *todo* archivo v5
  sano. Sobre un header de prueba da `2b5ff9a1` donde el archivo guarda
  `afa4154f`.
* **`not` sobre una constante en FPC se evalúa con más ancho que un `DWord`.**
  Las firmas invertidas del footer v4 (`~SREP_SIGNATURE`) nunca coinciden con
  lo leído del archivo aunque los 32 bits bajos sean iguales. Se declaran
  explícitas: `$AFADACB0` y `$D9CAE7E8`.
* **`SysUtils` define su propio `TBytes`.** Importarlo en la sección de
  implementación tapa el `TBytes` del interface y las firmas dejan de
  coincidir; el compilador lo reporta como *«Forward declaration not solved»*,
  que no menciona el tipo tapado.
* **Un identificador no puede llamarse igual que una unidad importada.**
  Pascal no distingue mayúsculas, así que una constante `HASHES` choca con la
  unidad `Hashes`. Por lo mismo, una variable local `n` choca con un
  parámetro `N` («Duplicate identifier»), y un `on E: Exception do` **tapa** a
  una variable local `e` —ahí no hay error de duplicado, hay uno de tipos
  incompatibles que no menciona la sombra—. Pasó dos veces el mismo día.
* **`SetLength` llena de ceros todo lo que reserva, así que reservar lo que
  declara el archivo ocupa RAM real.** Rust hace `vec![0u8; n]` con el tamaño
  del bloque y no le cuesta nada: pide páginas en cero que el sistema no
  entrega hasta que se escriben. El mismo patrón en Pascal hacía que un
  archivo roto de **109 bytes** que declaraba un bloque de 3 GiB ocupara
  **3 GiB** antes de fallar (Rust: 11 MiB). Los tests de salida no lo ven —los
  dos fallan con el mismo error—; lo vio el kernel el 2026-09-26, cuando un
  fuzzer con decenas de esos en paralelo dejó la máquina sin memoria. En i386
  además cambiaba el error: el largo no entra en un `SizeInt`, `SetLength` lo
  recibe negativo y falla con *«Range check error»* en vez de *«truncated
  structure»*. La regla: **nada se reserva por lo que diga el archivo**. Las
  lecturas crecen a medida que llegan los datos (`ReadExactOrEof`), y el
  buffer de salida a medida que se escribe (`GrowOut`). Esto último funciona
  porque en los dos decoders las escrituras en la salida son estrictamente
  secuenciales y el relleno final llega exacto al largo declarado: un bloque
  sano termina del tamaño justo y el digest no cambia. El harness de
  Future-LZ lo prueba con el espacio de direcciones limitado a 256 MiB, y se
  verificó que falla con el bug reintroducido, en nativo y en i386.
* **Lo mismo vale para lo que declara una opción.** El slot del spill se
  reservaba entero con `SetLength(buf, VmBlock)` en cada derrame, aunque no
  hubiera nada que desalojar: con `--vmblock` de 256 MiB el Pascal ocupaba
  258 MiB y el Rust 10. En i386 era corrupción de memoria: un `--vmblock` de
  2³² o más llega truncado a `SetLength` (el `QWord` pasa a `SizeInt` de 32
  bits), el buffer queda de 0 o 1 byte, y el empaquetado escribe fuera de él.
  Terminaba en *access violation* y una cascada de excepciones hasta *stack
  overflow*, con la salida a medias. Ahora el slot se arma a medida y se
  completa con ceros al escribirlo (el archivo queda byte a byte como el del
  Rust), y la restauración lee registro por registro: i386 decodifica bien con
  `--vmblock` de 2³¹, 2³² y 2³²+1, igual que Rust.
* **El anillo del encoder tambien es un `vec![0u8; n]` de Rust.** Con el `-d`
  por defecto de `-m0` mide 528 MiB; Rust no los ocupa hasta escribirlos, y
  `SetLength` los ocuparía al arrancar aunque la entrada fuera de 5 bytes. El
  anillo se llena bloque a bloque y nunca se lee una zona sin escribir, así
  que crece a medida, en ceros, que es exactamente lo que ve Rust ahí.
* **Crecer duplicando tampoco alcanza: el `realloc` tiene el viejo y el nuevo
  a la vez, y `SetLength` llena de ceros la mitad nueva.** Con `-m0` sobre
  256 MiB el anillo pasaba de 256 a 512 MiB, copia mediante, y el pico era
  1061 MB contra 407 del Rust. Lo mismo las tablas del match finder: con
  stdin sin `-s` se dimensionan para 25 GiB, `SetLength` las escribía
  enteras (1,5 GB de pico para 4 MiB de entrada) y el Rust no. Desde la
  fase 8 los arreglos grandes salen de `zeropages.pas`: un mapeo anónimo
  (`fpmmap` / `VirtualAlloc`, los dos garantizan ceros sin tocar páginas) con
  la cabecera de arreglo dinámico de la RTL delante, así que el acceso, el
  `Length` y los parámetros no cambian. La cabecera lleva `refcount = -1`,
  que en `dynarr.inc` es «arreglo constante»: la RTL nunca lo libera ni lo
  cuenta, y un `SetLength` sobre él copia en vez de hacer `realloc`. Por eso
  **lo libera `ZFree` a mano** (`HtFree`, `DcFree`, el `finally` de
  `Encode`); olvidarlo no rompe nada, pero deja el mapeo hasta que termina el
  proceso. Si el mapeo falla, cae a `SetLength` con el mismo argumento, y el
  error por falta de memoria es el de siempre. Resultado: `-m0` 398 MB,
  stdin `-m3` 10 MB (el Rust toca 975).
* **Una prueba de CDC necesita una entrada que distinga las dos rutas.** El
  hash de frontera se elige por la CPU (SSE4.2: CRC32C; si no, polinomial) y
  las dos rutas dan archivos distintos, pero solo si hay fronteras que mover:
  la entrada periódica del harness (`dup4m`) no tiene ninguna, y con ella la
  ruta polinomial "pasaba" sin probarse. El harness usa 16 copias de 1 MiB
  aleatorio y **verifica primero que las dos rutas difieran**. FPC no trae
  detección de SSE4.2: `cpufeat.pas` hace el CPUID a mano, en asm para
  x86-64 y para i386, y que i386 bajo wine dé los archivos de la ruta CRC es
  lo que prueba que esa rama corre.
* **El asm de x86-64 tiene que servir a las DOS ABI, y la pila no es
  tuya.** `NhPair` (vmac.pas, el NH de los dos carriles con `MUL` de 64x64)
  es un bloque `asm` dentro de un procedimiento Pascal, no una funcion
  `assembler`: asi los parametros los acomoda FPC y no hace falta un IFDEF
  por ABI. Pero rsi/rdi son preservados en Win64 y no en SysV, y rbx/r12/r13
  en las dos: se guardan y restauran **en un record local**, no con `push`,
  porque en SysV una hoja puede tener sus locales en la red zone debajo de
  rsp y un `push` los pisaria. Los locales se leen una sola vez al entrar,
  por puntero. i386 usa el Pascal, con cada producto parcial escrito
  `QWord(DWord) * QWord(DWord)`: asi ppcross386 emite un `MUL` de 32x32 -> 64
  (verificado en el `.s`); con operandos `QWord` llama a `fpc_mul_qword`, y
  eso hacia al hash 3 veces mas lento. `hashtool vmac-impl` dice que rama
  quedo compilada y `pascal_hash_conformance.sh` lo comprueba.
* **Los llamadores por chunk no deben copiar el bloque para hashearlo.**
  `VmacCompute(TBytes)` obligaba a `SetLength`+`Move` del chunk entero en cada
  digest (llenando de ceros antes de copiar). `VmacTagOf(P, Len)` hashea en el
  lugar y devuelve el tag en un array fijo de pila: sin dynarray, sin el marco
  try/finally implicito que FPC arma para los locales manejados.
* **En bash, `VAR=x funcion` no llega seguro a los procesos que la función
  lanza.** Para correr un caso con `OSREP_CDC_POLY=1` el harness usa `export`
  y `unset` explícitos.
* **Los conteos de `TStream.Read`/`Write`/`ReadBuffer`/`WriteBuffer` son
  `LongInt`.** `LongInt(n)` con n ≥ 2 GiB da negativo, y con los range checks
  apagados no avisa nada. Rust acepta bloques de hasta 4 GiB, así que eso se
  rompía **también en x64**. Todo largo que llega a un stream va por tramos de
  1 GiB (`SinkRead`, `SinkWrite`).
* **`THandleStream.Seek` no lanza excepciones.** Con un offset que no entra en
  un `Int64` (o que el sistema de archivos rechaza) devuelve -1 y **deja la
  posición donde estaba**: la lectura que sigue lee de otro lado, sin error.
  Rust falla ahí con EINVAL. Todo seek que llega a un archivo se hace con
  `SeekExact`, que verifica la posición que devuelve.
* **El directorio temporal de FPC no es el de Rust.** En Unix, `GetTempDir`
  mira `TEMP`, después `TMP` y recién después `TMPDIR`. `std::env::temp_dir()`
  mira **solo** `TMPDIR` (o `/tmp`). Con `TEMP` apuntando a otro lado, el spill
  del Pascal iba a otro disco o fallaba donde el Rust andaba. En Windows los dos
  usan `GetTempPath`. Y el temporal se crea **en exclusiva** (`O_EXCL` /
  `CREATE_NEW`) con nombre `<pid>-<nanos>-<contador>`, como el Rust. Con
  `fmCreate` y un nombre predecible, un symlink plantado se seguía y el
  contenido descomprimido quedaba fuera del temporal. Todo eso vive en
  `spillfile.pas`, con la cadena de `$IF` terminada en `$FATAL`.
* **El oráculo también tiene bugs, y el port no los copia.** En la revisión de
  la 4b, el Rust publicado (2.1.0) hizo **panic** (exit 101) donde el Pascal
  falla limpio: 933 archivos corruptos en una sola de las campañas. Las
  causas son cuatro: la suma del footer v4 que se envolvía y terminaba en
  `capacity overflow`, el slice de un digest más corto que el descriptor, la
  división por cero de un v1 con `base_len = 0` (el C++ muere con SIGFPE), y
  el recorrido de un slot vacío con `-vmblock=0`. El criterio del harness es «los dos fallan», así que
  no eran divergencias, pero sí bugs del binario que se publica. **Arreglados
  en Rust el 2026-10-09**, fallando en el mismo punto donde reventaban (ver
  CHANGELOG), con un caso por causa en `tests/decode_conformance.sh`; y el
  Pascal se alineó a esos puntos (la suma chequeada del footer, y sin chequeo
  previo de `VmBlock < 4`), así que ahora los dos dan el mismo error. Y el
  binario Rust de **32 bits** tenía la versión Rust de la trampa de `SetLength`:
  `vec![0u8; n]` con un largo declarado de 2 GiB o más es *capacity overflow*,
  así que un archivo de 109 bytes que declaraba 3 GiB lo tumbaba. Se arregló
  igual que en Pascal (reservar sin tocar páginas o crecer a medida); ahora da
  el mismo error que x64.
* **Un barrido de mutaciones no ve ni el orden de los chequeos ni lo que el
  encoder nunca escribe.** El harness de v5 pasaba 1.760 casos con dos bugs
  inyectados adentro: dos chequeos del contenedor en el orden equivocado, y el
  límite del décimo byte de un varint sacado. Ninguna mutación de un solo
  campo rompe *dos* chequeos a la vez, que es lo único que hace visible el
  orden; y ningún archivo real trae un varint de 10 bytes. Hicieron falta
  casos armados a mano para cada uno. La regla que queda: **un harness nuevo
  se prueba contra bugs inyectados** antes de creerle un verde.
* **Un harness que fuerza el decoder no es lo mismo que uno que despacha.**
  `decode_conformance v5` decodifica como v5 lo que le den; `decodetool`, como
  la CLI, elige por la magia. Un v5 con la magia rota o truncado a menos de 4
  bytes ya no es un v5 para el segundo, y la diferencia de mensaje es del
  despacho (fase 7), no del decoder. Y un v5 `-dup` decodifica al stream
  *deduplicado*: el original lo arma el post-paso de la CLI (fase 6), así que
  ahí se comparan los dos decoders entre sí y no contra la entrada.
* **El orden de los chequeos es observable.** Un archivo truncado cuya lista
  de STATs además no es múltiplo de 4 da *truncated* en Rust porque lee antes
  de validar; validar primero da *bad data*. Lo mismo con cualquier par de
  chequeos: portar la condición no alcanza, hay que portar el orden.
* **En Future-LZ, la clase de matches se saca del heap ANTES de restaurar un
  slot del spill.** Al revés, la restauración reinserta matches con ese mismo
  destino y el `take` siguiente se los lleva: cada decode que derrama pierde
  datos. Y `TAVLTree.FindKey` llama al comparador como `Compare(clave, dato)`,
  en ese orden, con comparaciones sin signo escritas a mano (el comparador por
  defecto compara punteros).
* **Un caso de spill puede mover cero bytes y estar bien.** Con 512 KiB y
  vmblock 64 KiB el Rust da `vmw=0`: el recorte `maximum_save = vm_block - 24`
  deja a los matches de 64 KiB fuera del memory manager, así que no hay nada
  que derramar. Parece un spill roto y no lo es; el harness exige el número
  exacto por eso, y aparte exige `vmw>0` en el caso que sí tiene que derramar.
* **Con un solo bloque, medio decoder no se ejecuta.** Los matches que
  apuntan antes del bloque actual se traen del archivo de salida ya escrito,
  no del buffer en memoria — y esa rama no corre nunca si el archivo de prueba
  entra en un bloque. `-b512kb` sobre 12 MiB da 24 bloques y ahí esa rama es
  la mayoría del trabajo. La matriz del harness los incluye por eso.
* **El scratchpad de `/tmp` es tmpfs en RAM.** Las pruebas grandes van a
  `/mnt/IA_LAB/agentes/osrep/`. Un round-trip de 5,75 GiB «falló» y casi se
  reporta como pérdida de datos: era ENOSPC.
* **Una corrida pesada en paralelo va dentro de una jaula de memoria.** Cada
  pane de tmux es un scope de systemd con `OOMPolicy=stop`: si el kernel mata
  por OOM un solo subproceso, systemd mata el pane entero, sesión incluida.
  Así se cortó dos veces la revisión de la fase 4b, y la segunda se llevó
  también la sesión de otra IA en la misma máquina. Las campañas van en
  `systemd-run --user --scope --slice=osrep-review.slice -p MemoryMax=4G
  -p MemorySwapMax=0 -p OOMPolicy=continue -- <cmd>`, con el slice limitado a
  24 GiB en total: si algo se pasa, muere un proceso adentro, nunca afuera.
  Si una sesión se corta sin motivo, mirar `journalctl --user | grep -i oom`
  antes de relanzar lo mismo.
* **En `cmd.exe`, `echo rc=%ERRORLEVEL%>> archivo` no escribe el código.** Se
  expande a `echo rc=4>> archivo`, y cmd lee `4>>` como redirección del handle
  4: la línea sale por consola y el archivo queda sin el número. La
  redirección va adelante: `>>archivo echo rc=%ERRORLEVEL%`. (Win7 tampoco trae
  `tar`: los resultados se traen con `scp -r`.)
* **Bajo wine, lo que va a un stdout apuntado a `/dev/null` sale por
  stderr.** Un harness que descarta stdout y lee stderr ve la línea `ok ...`
  mezclada con los errores; filtrar por el prefijo (`ERROR!`).
* **El `.exe` de 32 bits tiene que ser *large address aware*.** El i686 del
  Rust lo es (lo pone el linker de mingw); FPC no, y sin el flag Windows le da
  2 GB de direcciones. Comprimir desde stdin sin `-s` dimensiona el match
  finder para 25 GiB (~1,5 GB tocados) y salía "Out of memory" solo en i386.
  `{$SETPEFLAGS $20}` en `osrep.lpr`; `pascal_cli_conformance.sh` lo revisa con
  `objdump`. Lo atrapó la suite bajo wine i386, no la nativa.
* **La unit `Windows` trae su propio `DeleteFile` (con `PChar`).** Si va
  después de `SysUtils` en el `uses`, lo tapa. Va antes.
* **Escribir el archivo a stdout necesita un stream que sepa su posición.**
  La segunda pasada pregunta `Output.Position` para el offset de la meta del
  v5, y un `THandleStream` sobre un pipe no puede contestar. `TCountWriter`
  (en `osrep.lpr`) cuenta lo escrito y contesta `Seek(0, soCurrent)` con eso;
  cualquier otro seek es un error. Además bufferea: el encoder escribe de a
  pedazos chicos.
* **Comprimir desde stdin sin `-s` usa ~1,5× la memoria del Rust** (1,5 GB
  contra 1,0 GB de pico, medido con `VmHWM`): `SetLength` pone a cero las
  tablas dimensionadas para 25 GiB y eso las toca enteras, mientras que el
  Rust las pide con calloc. No cambia la salida; queda anotado para la fase 8.
* **`zsh` no parte `$args` en palabras.** Un bucle de humo con
  `for args in "-m5f --format=v4"` le pasó al binario un solo argumento y los
  dos binarios "fallaron igual". Los scripts de prueba van con `bash`.
* **Un local administrado en una función caliente cuesta un marco de
  excepciones en CADA llamada, se use o no.** Un `TBytes`, `AnsiString`,
  interfaz o record que los contenga hace que FPC envuelva la función entera
  en un try/finally implícito: `fpc_pushexceptaddr` + `fpc_setjmp` al entrar,
  `fpc_popaddrstack` + `fpc_finalize` + `fpc_dynarray_clear` al salir. En
  `HtFindMatch` (una llamada por posición candidata) el `dig: TBytes` del
  chequeo de digest de `-m3` —que casi nunca se ejecuta— era ~29% de las
  instrucciones de `-m3` (callgrind sobre 16 MiB). Sacarlo a una función
  aparte (`DigestMatchesAt`) bajó `-m3` sobre 256 MiB de 12,1 s a 5,3 s con el
  archivo idéntico. Regla: lo que corre por posición o por chunk no declara
  locales administrados; el caso raro que los necesita va en su propia
  función. Para encontrarlos: `callgrind_annotate --tree=caller` y buscar
  quién llama a `fpc_pushexceptaddr`.
