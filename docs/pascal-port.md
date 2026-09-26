# Port a Pascal (FPC) — plan

> **Estado**: en curso. La decisión se tomó el 2026-09-25; las fases 0 a 4b
> están hechas (decoders I/O-LZ y Future/Index-LZ). Ver la tabla de fases.

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
        futurelz.pas       decoder Future/Index-LZ (v3/v4): memory manager,
                           heap de matches, spill a disco
        spillfile.pas      el temporal del spill, creado como el Rust (lo
                           unico que depende de la plataforma)
    tests/
      pascal_cli_conformance.sh        --version/--help contra el binario Rust
      pascal_hash_conformance.sh       los cinco digests y AES
      pascal_container_conformance.sh  leer y reescribir el armazon
      pascal_decode_conformance.sh     I/O-LZ, errores de decodetool, y que v5
                                       diga "no portado"
      pascal_futurelz_conformance.sh   v3/v4, con la linea de estadisticas entera

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
| **4c** | Decoder v5 | pendiente |
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
  la 4b, el Rust publicado hizo **panic** (exit 101) donde el Pascal falla
  limpio: en una sola de las campañas, 933 archivos corruptos dieron `capacity
  overflow` al reservar lo que declara el footer (`future_lz.rs:839`, `:373`);
  aparte, el slice de un digest más corto que el descriptor, y la división por
  cero de un v1 con `base_len = 0` (`decompress.rs:155`; el C++ muere con
  SIGFPE). El criterio del harness es «los dos fallan», así que eso no es una
  divergencia. Pero son bugs del binario que se publica hoy, y hay que
  arreglarlos en Rust también (el mismo criterio que el port a Rust aplicó al
  C++).
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
