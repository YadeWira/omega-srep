program osrep;
{ OSREP command line: the code is osrep_cli (the same as the library's
  osrep_run).

  Exit codes: 0 success, 2 command line, 3 I/O, 4 damaged data. }

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, osrep_cli;

var
  Args: array of string;
  I: Integer;

begin
  {$ifdef windows}
  { the CLI takes UTF-8 paths on every platform, as the library contract }
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  {$endif}
  SetLength(Args, ParamCount);
  for I := 1 to ParamCount do
    Args[I - 1] := ParamStr(I);
  { -1: the process's own standard handles, left open }
  Halt(OsrepRunArgs(Args, -1, -1, -1, False));
end.
