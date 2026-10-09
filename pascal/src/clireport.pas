unit CliReport;
{ Todo lo que el programa escribe a stderr (report.rs).

  Dos publicos. -bar es para maquinas y su formato es contrato
  (`PROGRESS <hecho> <total>`, digitos pelados, cada ~0,5 s mas una linea
  final garantizada), asi que va exacto. Las lineas para humanos van con la
  misma forma que el Rust y los numeros propios: tiempos y velocidades no se
  pueden comparar entre dos corridas de todos modos. Lo que tests/
  stderr_conformance.sh mira es QUE hechos se reportan, no sus valores. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Widths;

type
  TBar = record
    Enabled: Boolean;
    Last: QWord;          { GetTickCount64 de la ultima linea }
    LastDone: QWord;
  end;

  TStats = record
    Enabled: Boolean;
    Started: QWord;
    Last: QWord;
    LastDone: QWord;
  end;

{ show3 (Common.h:777): separador de miles, para humanos }
function Show3(N: QWord): AnsiString;
{ showMem (Common.cpp:268): la unidad mas grande que divide }
function ShowMem(Mem: QWord; AddB: Boolean): AnsiString;
{ un float con N decimales y punto, sin importar la configuracion regional }
function Fixed(X: Double; Decimals: LongInt): AnsiString;

procedure BarInit(out B: TBar; Enabled: Boolean);
procedure BarTick(var B: TBar; Done, Total: QWord);
procedure StatsInit(out S: TStats; Enabled: Boolean);
procedure StatsTick(var S: TStats; Done, Total: QWord);
procedure StatsFinish(var S: TStats; Read, Written: QWord);

{ print_info (srep.cpp:182-190): el resumen de la descompresion }
procedure PrintInfo(const Prefix: AnsiString; MaxRam: QWord; HasMaximumSave: Boolean;
                    MaximumSave, StatSize: QWord; RoundMatches: Boolean; FileSize: QWord);

implementation

uses OutRaw;

const
  KB = QWord(1024);
  MB = QWord(1024) * 1024;
  GB = QWord(1024) * 1024 * 1024;

var
  Dot: TFormatSettings;

function Show3(N: QWord): AnsiString;
var digits: AnsiString; i, len: LongInt;
begin
  digits := IntToStr(N);
  len := Length(digits);
  Result := '';
  for i := 1 to len do
  begin
    if (i > 1) and ((len - (i - 1)) mod 3 = 0) then Result := Result + ',';
    Result := Result + digits[i];
  end;
end;

function ShowMem(Mem: QWord; AddB: Boolean): AnsiString;
var b: AnsiString;
begin
  if AddB then b := 'b' else b := '';
  if Mem = 0 then Result := '0' + b
  else if Mem mod GB = 0 then Result := IntToStr(Mem div GB) + 'g' + b
  else if Mem mod MB = 0 then Result := IntToStr(Mem div MB) + 'm' + b
  else if Mem mod KB = 0 then Result := IntToStr(Mem div KB) + 'k' + b
  else Result := IntToStr(Mem) + b;
end;

function Fixed(X: Double; Decimals: LongInt): AnsiString;
begin
  Result := FloatToStrF(X, ffFixed, 18, Decimals, Dot);
end;

procedure BarInit(out B: TBar; Enabled: Boolean);
begin
  B.Enabled := Enabled;
  B.Last := 0;
  B.LastDone := High(QWord);
end;

{ un tick del core. Terminado fuerza la linea, haya pasado el timer o no:
  el consumidor necesita ver hecho == total exactamente una vez al final }
procedure BarTick(var B: TBar; Done, Total: QWord);
var finished: Boolean; now_: QWord;
begin
  if not B.Enabled then Exit;
  finished := (Total > 0) and (Done >= Total);
  now_ := GetTickCount64;
  if (not finished) and ((B.Last <> 0) and (now_ - B.Last < 500) or (Done = B.LastDone)) then Exit;
  B.Last := now_;
  if B.Last = 0 then B.Last := 1;
  B.LastDone := Done;
  { el salto de linea del principio es el del C++: la linea humana termina
    con backspaces, nunca con \n }
  WriteErr(#10 + 'PROGRESS ' + IntToStr(Done) + ' ' + IntToStr(Total) + #10);
end;

procedure StatsInit(out S: TStats; Enabled: Boolean);
begin
  S.Enabled := Enabled;
  S.Started := GetTickCount64;
  S.Last := 0;
  S.LastDone := High(QWord);
end;

procedure StatsTick(var S: TStats; Done, Total: QWord);
var finished: Boolean; now_, percents: QWord; secs, mbps: Double;
begin
  if (not S.Enabled) or (Done = S.LastDone) then Exit;
  finished := (Total > 0) and (Done >= Total);
  now_ := GetTickCount64;
  if (not finished) and (S.Last <> 0) and (now_ - S.Last < 200) then Exit;
  S.Last := now_;
  if S.Last = 0 then S.Last := 1;
  S.LastDone := Done;
  secs := (now_ - S.Started) / 1000.0;
  if Total > 0 then percents := Done * 100 div Total else percents := 100;
  if secs > 0 then mbps := Done / secs / MB else mbps := 0;
  WriteErr(#13 + IntToStr(percents) + '%: ' + Show3(Done) + ' of ' + Show3(Total) +
           ': real ' + Fixed(mbps, 0) + ' mb/s (' + Fixed(secs, 3) + ' sec)');
end;

{ reemplaza la linea en vuelo por la final }
procedure StatsFinish(var S: TStats; Read, Written: QWord);
var ratio, secs: Double;
begin
  if not S.Enabled then Exit;
  if Read > 0 then ratio := Written * 100.0 / Read else ratio := 0;
  secs := (GetTickCount64 - S.Started) / 1000.0;
  WriteErr(#13 + Show3(Read) + ' -> ' + Show3(Written) + ': ' + Fixed(ratio, 2) + '%.  ' +
           Fixed(secs, 3) + ' sec' + #10);
end;

procedure PrintInfo(const Prefix: AnsiString; MaxRam: QWord; HasMaximumSave: Boolean;
                    MaximumSave, StatSize: QWord; RoundMatches: Boolean; FileSize: QWord);
var withMs: AnsiString; perMatch: QWord; pct: Double;
begin
  if HasMaximumSave then withMs := ' with -m' + ShowMem(MaximumSave, False) else withMs := '';
  if RoundMatches then perMatch := 3 * 4 else perMatch := 4 * 4;
  if FileSize > 0 then pct := StatSize * 100.0 / FileSize else pct := 0;
  WriteErr(Prefix + 'Decompression memory' + withMs + ' is ' + IntToStr((MaxRam + MB - 1) div MB) +
           ' mb.  ' + Show3(StatSize div perMatch) + ' matches = ' + Show3(StatSize) +
           ' bytes = ' + Fixed(pct, 2) + '% of file');
end;

initialization
  Dot := DefaultFormatSettings;
  Dot.DecimalSeparator := '.';
  Dot.ThousandSeparator := #0;
end.
