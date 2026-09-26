# Port a Pascal (FPC) — plan

> **Estado**: plan, sin código todavía. La decisión se tomó el 2026-09-25.

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
      osrep.lpr          el programa
      build.sh           los tres targets, con el cross propio
      src/
        widths.pas       guardas de ancho en tiempo de compilacion
        outraw.pas       escritura cruda a stdout/stderr
        help.pas         --version y --help, byte a byte
    tests/
      pascal_cli_conformance.sh   diffea el Pascal contra el binario Rust

`pascal/bin/` es salida de build y está en `.gitignore`.

## Fases

Mismo esqueleto que `docs/rust-port.md`, que ya demostró funcionar, y con el
mismo criterio de corrección: **diff byte a byte contra el oráculo, no
round-trip**.

| Fase | Qué | Puerta |
|---|---|---|
| **0** | Toolchain: FPC para i386-win32 y x86-64 | **hecha** (2026-09-25): los tres targets verificados, i386 corriendo en Win7 real |
| **1** | Andamiaje: layout, CLI que responde `--version`/`--help` | **hecha** (2026-09-25): byte a byte en los tres targets, verificado en Win7 real |
| **2** | Digests: vmac, siphash, md5, sha1, sha512 | `tests/hash_test` como oráculo, vector por vector |
| **3** | Container: header, seed, bloques, footer v4 y v5 | leer v1–v5 y escribir v4/v5 byte-exacto |
| **4** | Decoders: I/O-LZ, luego Future/Index-LZ + memory manager + spill | `decode_conformance` completo |
| **5** | Encoder: los 17 modos | `encode_conformance`, byte-idéntico en todos |
| **6** | `-dup` y `--verify` | `dup_v5_conformance`, `format_v5_conformance` |
| **7** | CLI completa | las 219 de `rust_cli_conformance` con `OSREP_BIN` |
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
* **El scratchpad de `/tmp` es tmpfs en RAM.** Las pruebas grandes van a
  `/mnt/IA_LAB/agentes/osrep/`. Un round-trip de 5,75 GiB «falló» y casi se
  reporta como pérdida de datos: era ENOSPC.
