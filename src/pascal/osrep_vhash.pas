unit osrep_vhash;
{ VHASH-128 without nonce, as used by the v6 block digest (hash_id=4).

  This is a Pascal implementation of the public VMAC/VHASH reference by Ted
  Krovetz and Wei Dai (public domain).  The v6 profile is fixed:
  VMAC_KEY_LEN=256, VMAC_TAG_LEN=128, VMAC_NHBYTES=4096, the `vhash` entry
  point (no nonce), tag = the two QWords in little-endian, and the length
  tweak len8 = (len mod 4096) * 8.  See spec/format-v6.md §2.6. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, osrep_aes;

const
  VhashNhBytes = 4096;
  VhashNhWords = VhashNhBytes div 8; { 512 }

function Vhash128(const Key: TBytes; const Data: TBytes;
  Offset, Len: SizeUInt; out Tag: TBytes): Boolean;

implementation

const
  P64: QWord   = QWord($FFFFFFFFFFFFFEFF); { 2^64 - 257 }
  M62: QWord   = QWord($3FFFFFFFFFFFFFFF);
  M63: QWord   = QWord($7FFFFFFFFFFFFFFF);
  M64: QWord   = QWord($FFFFFFFFFFFFFFFF);
  MPoly: QWord = QWord($1FFFFFFF1FFFFFFF);

type
  TVhashContext = record
    Aes: TAes256Context;
    NHKey: array[0..VhashNhWords + 1] of QWord;
    PolyKey: array[0..3] of QWord;
    L3Key: array[0..3] of QWord;
    PolyTmp: array[0..3] of QWord;
  end;

function GetU64LE(const Data: TBytes; Off: SizeUInt): QWord; inline;
begin
  Result := QWord(Data[SizeInt(Off)]) or
            (QWord(Data[SizeInt(Off) + 1]) shl 8) or
            (QWord(Data[SizeInt(Off) + 2]) shl 16) or
            (QWord(Data[SizeInt(Off) + 3]) shl 24) or
            (QWord(Data[SizeInt(Off) + 4]) shl 32) or
            (QWord(Data[SizeInt(Off) + 5]) shl 40) or
            (QWord(Data[SizeInt(Off) + 6]) shl 48) or
            (QWord(Data[SizeInt(Off) + 7]) shl 56);
end;

function GetU64LEPad(const Data: TBytes; Off, EndOff: SizeUInt): QWord;
var
  I: Integer;
  B: Byte;
begin
  Result := 0;
  for I := 0 to 7 do
  begin
    if Off + SizeUInt(I) < EndOff then
      B := Data[SizeInt(Off) + I]
    else
      B := 0;
    Result := Result or (QWord(B) shl (8 * I));
  end;
end;

function GetU64BE(const Data: TBytes; Off: SizeInt): QWord; inline;
begin
  Result := (QWord(Data[Off]) shl 56) or
            (QWord(Data[Off + 1]) shl 48) or
            (QWord(Data[Off + 2]) shl 40) or
            (QWord(Data[Off + 3]) shl 32) or
            (QWord(Data[Off + 4]) shl 24) or
            (QWord(Data[Off + 5]) shl 16) or
            (QWord(Data[Off + 6]) shl 8) or
            QWord(Data[Off + 7]);
end;

procedure Add128(var H, L: QWord; IH, IL: QWord); inline;
begin
  L := L + IL;
  if L < IL then
    Inc(H);
  H := H + IH;
end;

procedure Mul64(A, B: QWord; out RH, RL: QWord);
var
  A0, A1, B0, B1, M1, M2: QWord;
begin
  A0 := A and QWord($FFFFFFFF);
  A1 := A shr 32;
  B0 := B and QWord($FFFFFFFF);
  B1 := B shr 32;
  M1 := A0 * B1;
  M2 := A1 * B0;
  RH := A1 * B1;
  RL := A0 * B0;
  Add128(RH, RL, M1 shr 32, M1 shl 32);
  Add128(RH, RL, M2 shr 32, M2 shl 32);
end;

procedure PolyStep(var AH, AL: QWord; KH, KL, MH, ML: QWord);
var
  T1H, T1L, T2H, T2L, T3H, T3L: QWord;
begin
  Mul64(AL, KH, T3H, T3L);
  Mul64(AH, KL, T2H, T2L);
  Mul64(AH, KH shl 1, T1H, T1L);
  Mul64(AL, KL, AH, AL);
  Add128(AH, AL, T1H, T1L);
  Add128(T2H, T2L, T3H, T3L);
  Add128(T2H, AH, 0, T2L); { add T2L to AH, carry into T2H }
  T2H := (T2H shl 1) + (AH shr 63);
  AH := AH and M63;
  Add128(AH, AL, MH, ML);
  Add128(AH, AL, 0, T2H);
end;

procedure NhFull2(const Data: TBytes; Off: SizeUInt;
  const Key: array of QWord; NW: Integer;
  out RH, RL, RH2, RL2: QWord);
var
  I: Integer;
  TH, TL: QWord;
  V0, V1: QWord;
begin
  RH := 0; RL := 0; RH2 := 0; RL2 := 0;
  I := 0;
  while I < NW do
  begin
    V0 := GetU64LE(Data, Off + SizeUInt(I) * 8);
    V1 := GetU64LE(Data, Off + SizeUInt(I + 1) * 8);
    Mul64(V0 + Key[I], V1 + Key[I + 1], TH, TL);
    Add128(RH, RL, TH, TL);
    Mul64(V0 + Key[I + 2], V1 + Key[I + 3], TH, TL);
    Add128(RH2, RL2, TH, TL);

    V0 := GetU64LE(Data, Off + SizeUInt(I + 2) * 8);
    V1 := GetU64LE(Data, Off + SizeUInt(I + 3) * 8);
    Mul64(V0 + Key[I + 2], V1 + Key[I + 3], TH, TL);
    Add128(RH, RL, TH, TL);
    Mul64(V0 + Key[I + 4], V1 + Key[I + 5], TH, TL);
    Add128(RH2, RL2, TH, TL);

    V0 := GetU64LE(Data, Off + SizeUInt(I + 4) * 8);
    V1 := GetU64LE(Data, Off + SizeUInt(I + 5) * 8);
    Mul64(V0 + Key[I + 4], V1 + Key[I + 5], TH, TL);
    Add128(RH, RL, TH, TL);
    Mul64(V0 + Key[I + 6], V1 + Key[I + 7], TH, TL);
    Add128(RH2, RL2, TH, TL);

    V0 := GetU64LE(Data, Off + SizeUInt(I + 6) * 8);
    V1 := GetU64LE(Data, Off + SizeUInt(I + 7) * 8);
    Mul64(V0 + Key[I + 6], V1 + Key[I + 7], TH, TL);
    Add128(RH, RL, TH, TL);
    Mul64(V0 + Key[I + 8], V1 + Key[I + 9], TH, TL);
    Add128(RH2, RL2, TH, TL);

    Inc(I, 8);
  end;
end;

procedure NhPartial2(const Data: TBytes; Off, Len: SizeUInt;
  const Key: array of QWord; NW: Integer;
  out RH, RL, RH2, RL2: QWord);
var
  I: Integer;
  TH, TL: QWord;
  V0, V1: QWord;
  EndOff: SizeUInt;
begin
  RH := 0; RL := 0; RH2 := 0; RL2 := 0;
  EndOff := Off + Len;
  I := 0;
  while I < NW do
  begin
    V0 := GetU64LEPad(Data, Off + SizeUInt(I) * 8, EndOff);
    V1 := GetU64LEPad(Data, Off + SizeUInt(I + 1) * 8, EndOff);
    Mul64(V0 + Key[I], V1 + Key[I + 1], TH, TL);
    Add128(RH, RL, TH, TL);
    Mul64(V0 + Key[I + 2], V1 + Key[I + 3], TH, TL);
    Add128(RH2, RL2, TH, TL);
    Inc(I, 2);
  end;
end;

function L3Hash(P1, P2, K1, K2, Len: QWord): QWord;
var
  RH, RL, T: QWord;
begin
  T := P1 shr 63;
  P1 := P1 and M63;
  Add128(P1, P2, Len, T);
  if (P1 > M63) or ((P1 = M63) and (P2 = M64)) then
    T := 1
  else
    T := 0;
  Add128(P1, P2, 0, T);
  P1 := P1 and M63;

  T := P1 + (P2 shr 32);
  T := T + (T shr 32);
  if LongWord(T and QWord($FFFFFFFF)) > LongWord($FFFFFFFE) then
    Inc(T);
  P1 := P1 + (T shr 32);
  P2 := P2 + (P1 shl 32);

  P1 := P1 + K1;
  if P1 < K1 then
    Inc(P1, 257);
  P2 := P2 + K2;
  if P2 < K2 then
    Inc(P2, 257);

  Mul64(P1, P2, RH, RL);
  T := RH shr 56;
  Add128(T, RL, 0, RH);
  RH := RH shl 8;
  Add128(T, RL, 0, RH);
  T := T + (T shl 8);
  RL := RL + T;
  if RL < T then
    Inc(RL, 257);
  if RL > P64 - 1 then
    Inc(RL, 257);
  Result := RL;
end;

procedure VhashSetKey(out Ctx: TVhashContext; const Key: TBytes);
var
  InBlock, OutBlock: TBytes;
  I: Integer;
begin
  if Length(Key) <> 32 then
    raise Exception.Create('VHASH key must be 32 bytes');
  SetLength(InBlock, 16);
  SetLength(OutBlock, 16);
  FillChar(InBlock[0], 16, 0);
  Aes256Init(Ctx.Aes, Key);

  InBlock[0] := $80;
  I := 0;
  while I < Length(Ctx.NHKey) do
  begin
    Aes256Encrypt(Ctx.Aes, InBlock, OutBlock);
    Ctx.NHKey[I] := GetU64BE(OutBlock, 0);
    Ctx.NHKey[I + 1] := GetU64BE(OutBlock, 8);
    Inc(InBlock[15]);
    Inc(I, 2);
  end;

  FillChar(InBlock[0], 16, 0);
  InBlock[0] := $C0;
  I := 0;
  while I < 4 do
  begin
    Aes256Encrypt(Ctx.Aes, InBlock, OutBlock);
    Ctx.PolyKey[I] := GetU64BE(OutBlock, 0) and MPoly;
    Ctx.PolyKey[I + 1] := GetU64BE(OutBlock, 8) and MPoly;
    Ctx.PolyTmp[I] := Ctx.PolyKey[I];
    Ctx.PolyTmp[I + 1] := Ctx.PolyKey[I + 1];
    Inc(InBlock[15]);
    Inc(I, 2);
  end;

  FillChar(InBlock[0], 16, 0);
  InBlock[0] := $E0;
  I := 0;
  while I < 4 do
  begin
    repeat
      Aes256Encrypt(Ctx.Aes, InBlock, OutBlock);
      Ctx.L3Key[I] := GetU64BE(OutBlock, 0);
      Ctx.L3Key[I + 1] := GetU64BE(OutBlock, 8);
      Inc(InBlock[15]);
    until (Ctx.L3Key[I] < P64) and (Ctx.L3Key[I + 1] < P64);
    Inc(I, 2);
  end;
end;

function Vhash128(const Key: TBytes; const Data: TBytes;
  Offset, Len: SizeUInt; out Tag: TBytes): Boolean;
var
  Ctx: TVhashContext;
  FullBlocks, Remaining: SizeUInt;
  Moff: SizeUInt;
  CH, CL, CH2, CL2, RH, RL, RH2, RL2: QWord;
  L3Len: QWord;
  TagH, TagL: QWord;
  I: Integer;
begin
  SetLength(Tag, 16);
  try
    VhashSetKey(Ctx, Key);
  except
    Result := False;
    Exit;
  end;

  Moff := Offset;
  FullBlocks := Len div VhashNhBytes;
  Remaining := Len mod VhashNhBytes;

  if FullBlocks > 0 then
  begin
    NhFull2(Data, Moff, Ctx.NHKey, VhashNhWords, CH, CL, CH2, CL2);
    CH2 := CH2 and M62;
    Add128(CH2, CL2, Ctx.PolyKey[2], Ctx.PolyKey[3]);
    CH := CH and M62;
    Add128(CH, CL, Ctx.PolyKey[0], Ctx.PolyKey[1]);
    Inc(Moff, VhashNhBytes);
    Dec(FullBlocks);

    while FullBlocks > 0 do
    begin
      NhFull2(Data, Moff, Ctx.NHKey, VhashNhWords, RH, RL, RH2, RL2);
      RH2 := RH2 and M62;
      PolyStep(CH2, CL2, Ctx.PolyKey[2], Ctx.PolyKey[3], RH2, RL2);
      RH := RH and M62;
      PolyStep(CH, CL, Ctx.PolyKey[0], Ctx.PolyKey[1], RH, RL);
      Inc(Moff, VhashNhBytes);
      Dec(FullBlocks);
    end;

    if Remaining > 0 then
    begin
      NhPartial2(Data, Moff, Remaining, Ctx.NHKey,
        2 * Integer((Remaining + 15) div 16), RH, RL, RH2, RL2);
      RH2 := RH2 and M62;
      PolyStep(CH2, CL2, Ctx.PolyKey[2], Ctx.PolyKey[3], RH2, RL2);
      RH := RH and M62;
      PolyStep(CH, CL, Ctx.PolyKey[0], Ctx.PolyKey[1], RH, RL);
    end;
  end
  else if Remaining > 0 then
  begin
    NhPartial2(Data, Moff, Remaining, Ctx.NHKey,
      2 * Integer((Remaining + 15) div 16), CH, CL, CH2, CL2);
    CH2 := CH2 and M62;
    Add128(CH2, CL2, Ctx.PolyKey[2], Ctx.PolyKey[3]);
    CH := CH and M62;
    Add128(CH, CL, Ctx.PolyKey[0], Ctx.PolyKey[1]);
  end
  else
  begin
    CH := Ctx.PolyKey[0];
    CL := Ctx.PolyKey[1];
    CH2 := Ctx.PolyKey[2];
    CL2 := Ctx.PolyKey[3];
  end;

  L3Len := QWord(Remaining) * 8;
  TagL := L3Hash(CH2, CL2, Ctx.L3Key[2], Ctx.L3Key[3], L3Len);
  TagH := L3Hash(CH, CL, Ctx.L3Key[0], Ctx.L3Key[1], L3Len);
  for I := 0 to 7 do
  begin
    Tag[I] := Byte(TagH shr (8 * I));
    Tag[8 + I] := Byte(TagL shr (8 * I));
  end;
  Result := True;
end;

end.
