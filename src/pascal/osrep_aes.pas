unit osrep_aes;
{ Minimal AES-256 block encryption for the VHASH-128 block digest.

  Only encryption is needed by VHASH.  The S-box and round constants are the
  standard FIPS-197 values; this code is written for OSREP (no legacy code
  was used). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TAes256Context = record
    W: array[0..59] of LongWord; { 15 round keys x 4 words }
  end;

procedure Aes256Init(out Ctx: TAes256Context; const Key: TBytes);
procedure Aes256Encrypt(const Ctx: TAes256Context;
  const InBlock: TBytes; var OutBlock: TBytes);

implementation

const
  SBox: array[0..255] of Byte = (
    $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
    $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
    $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
    $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
    $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
    $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
    $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
    $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
    $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
    $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
    $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
    $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
    $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
    $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
    $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
    $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);

  Rcon: array[1..10] of LongWord = (
    $01000000, $02000000, $04000000, $08000000, $10000000,
    $20000000, $40000000, $80000000, $1B000000, $36000000);

function GetU32BE(const B: TBytes; Off: SizeInt): LongWord;
begin
  Result := (LongWord(B[Off]) shl 24) or
            (LongWord(B[Off + 1]) shl 16) or
            (LongWord(B[Off + 2]) shl 8) or
            LongWord(B[Off + 3]);
end;

procedure PutU32BE(var B: TBytes; Off: SizeInt; V: LongWord);
begin
  B[Off] := Byte(V shr 24);
  B[Off + 1] := Byte(V shr 16);
  B[Off + 2] := Byte(V shr 8);
  B[Off + 3] := Byte(V);
end;

function SubWord(W: LongWord): LongWord;
begin
  Result := (LongWord(SBox[Byte(W shr 24)]) shl 24) or
            (LongWord(SBox[Byte(W shr 16)]) shl 16) or
            (LongWord(SBox[Byte(W shr 8)]) shl 8) or
            LongWord(SBox[Byte(W)]);
end;

function RotWord(W: LongWord): LongWord;
begin
  Result := (W shl 8) or (W shr 24);
end;

procedure Aes256Init(out Ctx: TAes256Context; const Key: TBytes);
var
  I: Integer;
  Temp: LongWord;
begin
  if Length(Key) <> 32 then
    raise Exception.Create('AES-256 key must be 32 bytes');
  for I := 0 to 7 do
    Ctx.W[I] := GetU32BE(Key, I * 4);
  for I := 8 to 59 do
  begin
    Temp := Ctx.W[I - 1];
    if (I mod 8) = 0 then
      Temp := SubWord(RotWord(Temp)) xor Rcon[I div 8]
    else if (I mod 8) = 4 then
      Temp := SubWord(Temp);
    Ctx.W[I] := Ctx.W[I - 8] xor Temp;
  end;
end;

function XTime(B: Byte): Byte; inline;
begin
  if (B and $80) <> 0 then
    Result := Byte((B shl 1) xor $1B)
  else
    Result := Byte(B shl 1);
end;

procedure AddRoundKey(var S: array of LongWord; const Ctx: TAes256Context;
  Round: Integer);
var
  C: Integer;
begin
  for C := 0 to 3 do
    S[C] := S[C] xor Ctx.W[Round * 4 + C];
end;

procedure SubBytes(var S: array of LongWord);
var
  C: Integer;
begin
  for C := 0 to 3 do
    S[C] := SubWord(S[C]);
end;

procedure ShiftRows(var S: array of LongWord);
var
  T: array[0..3] of LongWord;
  C: Integer;
  B0, B1, B2, B3: Byte;
begin
  for C := 0 to 3 do
  begin
    B0 := Byte(S[C] shr 24);
    B1 := Byte(S[(C + 1) mod 4] shr 16);
    B2 := Byte(S[(C + 2) mod 4] shr 8);
    B3 := Byte(S[(C + 3) mod 4]);
    T[C] := (LongWord(B0) shl 24) or (LongWord(B1) shl 16) or
            (LongWord(B2) shl 8) or LongWord(B3);
  end;
  for C := 0 to 3 do
    S[C] := T[C];
end;

procedure MixColumns(var S: array of LongWord);
var
  C: Integer;
  A0, A1, A2, A3: Byte;
  R0, R1, R2, R3: Byte;
begin
  for C := 0 to 3 do
  begin
    A0 := Byte(S[C] shr 24);
    A1 := Byte(S[C] shr 16);
    A2 := Byte(S[C] shr 8);
    A3 := Byte(S[C]);
    R0 := XTime(A0) xor (XTime(A1) xor A1) xor A2 xor A3;
    R1 := A0 xor XTime(A1) xor (XTime(A2) xor A2) xor A3;
    R2 := A0 xor A1 xor XTime(A2) xor (XTime(A3) xor A3);
    R3 := (XTime(A0) xor A0) xor A1 xor A2 xor XTime(A3);
    S[C] := (LongWord(R0) shl 24) or (LongWord(R1) shl 16) or
            (LongWord(R2) shl 8) or LongWord(R3);
  end;
end;

procedure Aes256Encrypt(const Ctx: TAes256Context;
  const InBlock: TBytes; var OutBlock: TBytes);
var
  S: array[0..3] of LongWord;
  Round, C: Integer;
begin
  if (Length(InBlock) <> 16) or (Length(OutBlock) <> 16) then
    raise Exception.Create('AES block must be 16 bytes');
  for C := 0 to 3 do
    S[C] := GetU32BE(InBlock, C * 4);
  AddRoundKey(S, Ctx, 0);
  for Round := 1 to 13 do
  begin
    SubBytes(S);
    ShiftRows(S);
    MixColumns(S);
    AddRoundKey(S, Ctx, Round);
  end;
  SubBytes(S);
  ShiftRows(S);
  AddRoundKey(S, Ctx, 14);
  for C := 0 to 3 do
    PutU32BE(OutBlock, C * 4, S[C]);
end;

end.
