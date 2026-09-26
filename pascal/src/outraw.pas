unit OutRaw;
{ Escritura cruda a stdout y stderr.

  Nada de `WriteLn` sobre un `Text`: en Windows la capa de texto puede traducir
  LF a CRLF, y la salida de `--version`/`--help` tiene que ser byte a byte la
  misma en Linux y en Windows, porque `tests/pascal_cli_conformance.sh` la
  diffea contra el binario Rust. Escribiendo al handle directo no hay capa que
  traduzca nada. }

{$MODE OBJFPC}{$H+}
interface

procedure WriteOut(const S: AnsiString);
procedure WriteErr(const S: AnsiString);

implementation

uses SysUtils;   { FileWrite, THandle }

{ En Unix son los descriptores de siempre. En Windows la RTL expone los handles
  como VARIABLES, fijadas al arrancar, asi que no pueden ir en un `const`: hay
  que leerlas en tiempo de ejecucion. }
function OutHandle: THandle;
begin
  {$IFDEF UNIX}Result := 1;{$ELSE}Result := StdOutputHandle;{$ENDIF}
end;

function ErrHandle: THandle;
begin
  {$IFDEF UNIX}Result := 2;{$ELSE}Result := StdErrorHandle;{$ENDIF}
end;

procedure WriteRaw(Handle: THandle; const S: AnsiString);
var
  written, total: LongInt;
begin
  total := 0;
  while total < Length(S) do
  begin
    written := FileWrite(Handle, S[total + 1], Length(S) - total);
    if written <= 0 then Exit;   { pipe cerrado: no hay nada que hacer }
    Inc(total, written);
  end;
end;

procedure WriteOut(const S: AnsiString); begin WriteRaw(OutHandle, S); end;
procedure WriteErr(const S: AnsiString); begin WriteRaw(ErrHandle, S); end;

end.
