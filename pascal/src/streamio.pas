unit StreamIO;
{ Lecturas y escrituras de streams con cuentas de 64 bits.

  TStream.Read/Write/ReadBuffer/WriteBuffer toman la cuenta como LongInt. Un
  `LongInt(n)` con n >= 2 GiB no es un error para FPC: se trunca, y si el bit
  31 queda prendido la cuenta sale negativa, Read devuelve 0 y el que llama lo
  toma por EOF. Asi `-b2g`/`-b3g`/`-b4g` escribian un archivo SIN bloques con
  exit 0 (el Rust los comprime bien). Todo lo que pueda pasar de 2 GiB va por
  aca, en tramos de IO_SLICE. }

{$MODE OBJFPC}{$H+}
interface

uses Classes;

const
  IO_SLICE = QWord(1) shl 30;

{ Lee hasta Count bytes, repitiendo hasta llenar o hasta EOF. Devuelve lo
  leido (menos que Count solo en EOF). }
function ReadUpTo(S: TStream; var Buf; Count: QWord): QWord;
{ Una sola lectura, como un read(2): puede devolver menos que Count. }
function ReadOnce(S: TStream; var Buf; Count: QWord): QWord;
{ ReadUpTo que exige los Count bytes (EReadError si faltan). }
procedure ReadExact(S: TStream; var Buf; Count: QWord);
procedure WriteAll(S: TStream; const Buf; Count: QWord);

implementation

function Slice(N: QWord): LongInt; inline;
begin
  if N > IO_SLICE then Result := LongInt(IO_SLICE) else Result := LongInt(N);
end;

function ReadUpTo(S: TStream; var Buf; Count: QWord): QWord;
var got: LongInt;
begin
  Result := 0;
  while Result < Count do
  begin
    got := S.Read(PByte(@Buf)[Result], Slice(Count - Result));
    if got <= 0 then Break;
    Inc(Result, QWord(got));
  end;
end;

function ReadOnce(S: TStream; var Buf; Count: QWord): QWord;
var got: LongInt;
begin
  if Count = 0 then Exit(0);
  got := S.Read(Buf, Slice(Count));
  if got < 0 then got := 0;
  Result := QWord(got);
end;

procedure ReadExact(S: TStream; var Buf; Count: QWord);
begin
  if ReadUpTo(S, Buf, Count) <> Count then
    raise EReadError.Create('Stream read error');
end;

procedure WriteAll(S: TStream; const Buf; Count: QWord);
var done: QWord; n: LongInt;
begin
  done := 0;
  while done < Count do
  begin
    n := Slice(Count - done);
    S.WriteBuffer(PByte(@Buf)[done], n);
    Inc(done, QWord(n));
  end;
end;

end.
