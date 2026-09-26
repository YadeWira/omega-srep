unit Widths;
{ Guardas de ancho, en tiempo de compilacion.

  FPC deja pasar en silencio dos cosas que cambian el tamano de lo que se
  escribe al archivo, y ninguna de las dos es un error para el compilador:

  1. **El ancho depende de la arquitectura.** `SizeInt`, `PtrUInt` y
     `NativeUInt` miden 4 bytes en i386 y 8 en x86-64 (medido en Win7 real,
     2026-09-25). Este proyecto ya fue mordido por exactamente eso en C++:
     `PolynomialRollingHash<size_t>` tenia un modulo que dependia del ancho de
     `size_t`, asi que `-m1`/`-m2` producian fronteras de chunk distintas por
     arquitectura y corrompian en silencio cualquier archivo comprimido en un
     ancho y descomprimido en el otro (`docs/32bit-support.md`).

  2. **El ancho depende del MODO del compilador.** `Integer` mide 2 bytes en
     los modos `fpc` y `tp` -- y `fpc` es el modo por defecto, el que se usa si
     nadie pone directiva-- y 4 en `objfpc` y `delphi`. Medido, no citado.
     El aviso es de ytool, a quien esto le afecta de lleno: su `TStreamHeader`
     usa `Integer` y es seguro *solo* porque su build pasa `-Mdelphi`.

  La regla del proyecto es usar unicamente tipos cuyo NOMBRE fije el ancho
  (`QWord`, `Int64`, `DWord`, `Cardinal`, `LongInt`, `Word`, `Byte`) en todo lo
  que llegue al archivo. Esta unidad hace que romperla no compile.

  El mecanismo: un rango que se vuelve invalido cuando el ancho no es el
  esperado. `{$IF SizeOf(...)}` NO sirve -- el preprocesador de FPC no conoce
  tipos y falla con "Identifier not found". }

{$MODE OBJFPC}{$H+}
interface

{ El modo tiene que ser objfpc o delphi; en los otros dos `Integer` es de 16
  bits. Esto se chequea aparte del ancho porque da un mensaje que dice QUE
  hacer, en vez de un error de rango. }
{$IF not defined(FPC_OBJFPC) and not defined(FPC_DELPHI)}
  {$ERROR Compilar en modo objfpc o delphi: en modo fpc/tp, Integer mide 2 bytes}
{$ENDIF}

type
  { Anchos que el formato da por sentados. Si alguno cambia, el limite superior
    queda por debajo del inferior y el compilador para con
    "Upper bound of range is less than lower bound". }
  TAssertByte     = array[0 .. SizeOf(Byte)     - 1] of Byte;
  TAssertWord     = array[0 .. SizeOf(Word)     - 2] of Byte;
  TAssertDWord    = array[0 .. SizeOf(DWord)    - 4] of Byte;
  TAssertCardinal = array[0 .. SizeOf(Cardinal) - 4] of Byte;
  TAssertLongInt  = array[0 .. SizeOf(LongInt)  - 4] of Byte;
  TAssertQWord    = array[0 .. SizeOf(QWord)    - 8] of Byte;
  TAssertInt64    = array[0 .. SizeOf(Int64)    - 8] of Byte;
  { Y el que motiva todo esto: en un modo equivocado mide 2. }
  TAssertInteger  = array[0 .. SizeOf(Integer)  - 4] of Byte;

implementation

end.
