unit LzCodec;
{ El codec de records LZ: ENCODE_LZ_MATCH / DECODE_LZ_MATCH (lz.rs, que porta
  srep.cpp:116-139). Un match son 3 palabras de 32 bits con ROUND_MATCHES y 4
  sin (el offset de 64 bits partido en dos). BaseLen es el BASE_LEN del C++:
  el largo minimo garantizado, que el record guarda RESTADO. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths;

type
  { Una lista de STATs que crece: el Vec<u32> del Rust. }
  TStatList = record
    W: array of DWord;
    N: QWord;
  end;

  TLzMatch = record
    LitLen: DWord;
    Src, Dest: QWord;
    Len: DWord;
  end;

function StatsPerMatch(RoundMatches: Boolean): QWord;

procedure StatClear(var S: TStatList);
procedure StatPush(var S: TStatList; V: DWord);

{ Agrega un record. False si MatchLen < BaseLen, despues de haber agregado
  las primeras palabras (como el Rust, que empuja y despues falla). }
function EncodeLzMatch(var S: TStatList; RoundMatches: Boolean; BaseLen, LitLen: DWord;
                       Offset: QWord; MatchLen: DWord): Boolean;

{ Decodifica el record que empieza en S.W[At] (de una lista de N palabras).
  False si no entra entero. }
function DecodeLzMatch(const S: TStatList; At: QWord; RoundMatches, FutureLz: Boolean;
                       BaseLen: DWord; BasicPos: QWord; out M: TLzMatch;
                       out Used: QWord): Boolean;

implementation

function StatsPerMatch(RoundMatches: Boolean): QWord;
begin
  if RoundMatches then Result := 3 else Result := 4;
end;

procedure StatClear(var S: TStatList);
begin
  S.N := 0;
end;

procedure StatPush(var S: TStatList; V: DWord);
begin
  if S.N >= QWord(Length(S.W)) then
  begin
    if Length(S.W) < 64 then SetLength(S.W, 64) else SetLength(S.W, Length(S.W) * 2);
  end;
  S.W[S.N] := V;
  Inc(S.N);
end;

function EncodeLzMatch(var S: TStatList; RoundMatches: Boolean; BaseLen, LitLen: DWord;
                       Offset: QWord; MatchLen: DWord): Boolean;
var l1, off: QWord;
begin
  if RoundMatches then l1 := QWord(BaseLen) else l1 := 1;
  StatPush(S, LitLen);
  off := Offset div l1;
  StatPush(S, DWord(off));                       { 32 bits bajos }
  if not RoundMatches then StatPush(S, DWord(off shr 32));
  if MatchLen < BaseLen then Exit(False);
  StatPush(S, DWord(QWord(MatchLen - BaseLen) div l1));
  Result := True;
end;

function DecodeLzMatch(const S: TStatList; At: QWord; RoundMatches, FutureLz: Boolean;
                       BaseLen: DWord; BasicPos: QWord; out M: TLzMatch;
                       out Used: QWord): Boolean;
var l1: DWord; l164, offset, p: QWord; t: DWord;
begin
  if RoundMatches then l1 := BaseLen else l1 := 1;
  l164 := QWord(l1);
  if (At > S.N) or (S.N - At < StatsPerMatch(RoundMatches)) then Exit(False);
  M.LitLen := S.W[At];
  offset := QWord(S.W[At + 1]);
  p := At + 2;
  if not RoundMatches then
  begin
    offset := offset + (QWord(S.W[At + 2]) shl 32);
    p := At + 3;
  end;
  offset := offset * QWord(l1);                   { wrap en 64 bits }
  { el C++ calcula (*stat++)*L1 + L en unsigned: wrap a 32 bits. A un DWord
    antes de sumar, porque en x86-64 FPC evalua DWord*DWord en 64. }
  t := DWord(QWord(S.W[p]) * QWord(l1));
  t := DWord(QWord(t) + QWord(BaseLen));
  M.Len := t;
  Inc(p);
  if not FutureLz then
  begin
    M.Dest := BasicPos + QWord(M.LitLen);
    M.Src := (M.Dest div l164) * l164 - offset;
  end
  else
  begin
    M.Src := BasicPos + QWord(M.LitLen);
    M.Dest := M.Src + offset;
  end;
  Used := p - At;
  Result := True;
end;

end.
