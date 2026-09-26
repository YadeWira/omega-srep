program osrep;
{ Omega SREP -- port a Pascal (FPC). Ver docs/pascal-port.md.

  Fase 1: el andamiaje. Solo responde `--version` y `--help`, y lo hace byte a
  byte igual que el binario Rust publicado. Todo lo demas sale con el codigo de
  error de linea de comandos, que es lo honesto mientras no este implementado:
  un binario que acepta una opcion y no hace nada es peor que uno que la
  rechaza. }

{$MODE OBJFPC}{$H+}

uses
  Widths,   { guardas de ancho en tiempo de compilacion; no exporta nada }
  OutRaw,
  Help,
  SysUtils;

const
  { `srep.cpp:45-50`. Los mismos que el C++ y el port a Rust. }
  ERROR_OK       = 0;
  ERROR_CMDLINE  = 2;

function Run: LongInt;
var
  i: LongInt;
  a: AnsiString;
begin
  { `dup_wrapper.cpp:412-472`: el wrapper contesta --help y --version antes de
    que corra el parser de opciones, asi que cualquier otra cosa en la linea de
    comandos es irrelevante si una de las dos aparece. Reproducido tal cual:
    el port a Rust depende de esto y sus tests lo asertan. }
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--help') or (a = '-h') or (a = '-?') then
    begin
      WriteOut(HelpText);
      Exit(ERROR_OK);
    end;
    if (a = '--version') or (a = '-V') then
    begin
      WriteOut(VersionLine + #10);
      Exit(ERROR_OK);
    end;
  end;

  WriteErr(#10 + '  ERROR! el port a Pascal esta en la fase 1: solo --version y --help' + #10);
  Result := ERROR_CMDLINE;
end;

begin
  ExitCode := Run;
end.
