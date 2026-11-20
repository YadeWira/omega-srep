{ OREP streaming / API edge cases (tests/orep_edge.sh builds and runs it,
  native and -dOREP_NO_NATIVE, and compares the digests of both):

  - input sizes around the chunk C, the window W and the ring R (0, 1, 15,
    16, 17, 63..65, C-1..C+1, 2C-1..2C+1, W-1..W+1, R-1..R+1, the
    encoder's threaded ring R+C-1..R+C+1, 2R+1) with small windows and
    64 KiB chunks, data with matches exactly W back (also across the ring
    wrap), W = 1 and W < C;
  - OREP_FLUSH at every byte of a small input, twice in a row, on an empty
    encoder, at block boundaries, right before OREP_FINISH, together with
    the input or after it; 1-byte input and output buffers, calls with no
    output room;
  - the decoder fed 1 byte at a time with a 1-byte output buffer, and
    OrepDecPeek / OrepDecSkip in odd sizes;
  - reset and reuse of encoder and decoder across parameters and streams
    (bigger window after a smaller one and the reverse), decoder reset after
    an error, in the middle of a stream and with a memory limit;
  - two streams back to back, streams cut at every byte, nonzero header
    flags, other versions and bad parameters;
  - every stream: exact round trip, the same bytes with 1, 2 and 4
    threads, max distance <= W (parsed), and a digest line ("D ...") the
    shell compares between the native and the reference build.

    orep_edge [quick] }

program orep_edge;

{$mode objfpc}{$H+}
{$Q-}{$R-}

uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, orep;

const
  K64 = 64 * 1024;

type
  TBuf = record
    B: TBytes;
    N: SizeUInt;
  end;

  TPlan = record
    InStep, OutStep: LongInt;  { > 0 fixed, 0 = everything, -1 = random }
    Flush: array of SizeUInt;  { ascending; equal entries = flush again }
    Double: Boolean;           { each flush point flushed twice }
    WithInput: Boolean;        { OREP_FLUSH given with the last input piece }
    ZeroOut: Boolean;          { a call with no output room before each }
    Seed: QWord;
  end;

  TInfo = record
    Ok: Boolean;
    Why: string;
    Window: QWord;
    Chunk: LongWord;
    Flags: QWord;
    FlagsOff, FlagsLen, CrcOff: SizeUInt;
    Blocks, Matches, DistW: QWord;
    MaxDist, Total: QWord;
  end;

var
  Fails: Integer = 0;
  Checks: QWord = 0;
  Quick: Boolean = False;
  Dummy: array[0..15] of Byte;
  Rng: QWord = 88172645463325252;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Checks);
  if not Ok then
  begin
    WriteLn('FAIL: ', What);
    Inc(Fails);
  end;
end;

function Rnd: QWord;
begin
  Rng := Rng xor (Rng shl 13);
  Rng := Rng xor (Rng shr 7);
  Rng := Rng xor (Rng shl 17);
  Result := Rng;
end;

function PtrOf(const B: TBytes): PByte;
begin
  if Length(B) = 0 then Result := @Dummy[0] else Result := @B[0];
end;

procedure Append(var Buf: TBuf; P: PByte; N: SizeUInt);
var
  C: SizeUInt;
begin
  if N = 0 then Exit;
  if Buf.N + N > SizeUInt(Length(Buf.B)) then
  begin
    C := Length(Buf.B) * 2 + 256;
    if C < Buf.N + N then C := Buf.N + N;
    SetLength(Buf.B, C);
  end;
  Move(P^, Buf.B[Buf.N], N);
  Inc(Buf.N, N);
end;

function Bytes(const Buf: TBuf): TBytes;
begin
  Result := Copy(Buf.B, 0, Buf.N);
end;

function Same(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function IsPrefix(const A, Full: TBytes): Boolean;
begin
  Result := (Length(A) <= Length(Full)) and
    ((Length(A) = 0) or CompareMem(@A[0], @Full[0], Length(A)));
end;

function Cat(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function Crc(const B: TBytes): LongWord;
begin
  Result := OrepCrc32c(0, PtrOf(B), Length(B));
end;

function Hex(V: LongWord): string;
begin
  Result := IntToHex(V, 8);
end;

{ ---- stream parser (spec/orep-format.md, version 4) -------------------- }

function GetVar(const S: TBytes; var P: SizeUInt; out V: QWord): Boolean;
var
  Sh: LongWord;
  B: Byte;
begin
  V := 0; Sh := 0;
  repeat
    if (P >= SizeUInt(Length(S))) or (Sh > 63) then Exit(False);
    B := S[P];
    Inc(P);
    V := V or (QWord(B and $7F) shl Sh);
    Inc(Sh, 7);
  until B < $80;
  Result := True;
end;

function Parse(const S: TBytes): TInfo;
var
  P, Q, I: SizeUInt;
  V, OutSize, N, ColSize, A, SumLen, Pos, Pad: QWord;
  Lit, Len, Dist: array of QWord;

  function Bad(const W: string): TInfo;
  begin
    Result.Ok := False;
    Result.Why := W + ' at ' + IntToStr(P);
  end;

begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Why := '';
  P := 0;
  if (Length(S) < 6) or (S[0] <> Ord('O')) or (S[1] <> Ord('R')) or
    (S[2] <> Ord('E')) or (S[3] <> Ord('P')) or (S[4] <> 4) then
    Exit(Bad('header'));
  Result.Chunk := LongWord(1) shl S[5];
  P := 6;
  if not GetVar(S, P, Result.Window) then Exit(Bad('window'));
  if not GetVar(S, P, V) then Exit(Bad('align'));
  if not GetVar(S, P, V) then Exit(Bad('minlen'));
  Result.FlagsOff := P;
  if not GetVar(S, P, Result.Flags) then Exit(Bad('flags'));
  Result.FlagsLen := P - Result.FlagsOff;
  Result.CrcOff := P;
  if P + 4 > SizeUInt(Length(S)) then Exit(Bad('header crc'));
  if (LongWord(S[P]) or (LongWord(S[P + 1]) shl 8) or
    (LongWord(S[P + 2]) shl 16) or (LongWord(S[P + 3]) shl 24)) <>
    OrepCrc32c(0, @S[0], P) then Exit(Bad('header crc value'));
  Inc(P, 4);
  while True do
  begin
    if not GetVar(S, P, OutSize) then Exit(Bad('out size'));
    if OutSize = 0 then
    begin
      if not GetVar(S, P, V) then Exit(Bad('total'));
      if V <> Result.Total then Exit(Bad('total value'));
      if P <> SizeUInt(Length(S)) then Exit(Bad('bytes after the end'));
      Break;
    end;
    if (not GetVar(S, P, N)) or (not GetVar(S, P, ColSize)) or
      (not GetVar(S, P, A)) then Exit(Bad('block header'));
    if (OutSize > Result.Chunk) or
      ((Result.Total mod Result.Chunk) + OutSize > Result.Chunk) then
      Exit(Bad('block crosses a slot'));
    if (A < 1) or (A > 4096) or (N > OutSize div 16) then
      Exit(Bad('block fields'));
    SetLength(Lit, N); SetLength(Len, N); SetLength(Dist, N);
    Q := P;
    for I := 1 to N do if not GetVar(S, P, Lit[I - 1]) then Exit(Bad('lit'));
    for I := 1 to N do if not GetVar(S, P, Len[I - 1]) then Exit(Bad('len'));
    for I := 1 to N do if not GetVar(S, P, Dist[I - 1]) then Exit(Bad('dist'));
    if P - Q <> ColSize then Exit(Bad('column size'));
    SumLen := 0;
    Pos := 0;
    for I := 1 to N do
    begin
      Inc(Len[I - 1], 16);
      Inc(Dist[I - 1]);
      Inc(Pos, Lit[I - 1]);
      if Dist[I - 1] > Result.Window then Exit(Bad('dist > window'));
      if Dist[I - 1] > Result.Total + Pos then Exit(Bad('dist before start'));
      if Len[I - 1] mod A <> 0 then Exit(Bad('len not aligned'));
      if Dist[I - 1] > Result.MaxDist then Result.MaxDist := Dist[I - 1];
      if Dist[I - 1] = Result.Window then Inc(Result.DistW);
      Inc(Pos, Len[I - 1]);
      Inc(SumLen, Len[I - 1]);
    end;
    if Pos > OutSize then Exit(Bad('matches past the block'));
    Pad := ((Result.Total mod A) + A - (P mod A)) mod A;
    for I := 1 to Pad do
    begin
      if (P >= SizeUInt(Length(S))) or (S[P] <> 0) then Exit(Bad('padding'));
      Inc(P);
    end;
    Inc(P, OutSize - SumLen + 4);
    if P > SizeUInt(Length(S)) then Exit(Bad('literals'));
    Inc(Result.Blocks);
    Inc(Result.Matches, N);
    Inc(Result.Total, OutSize);
  end;
  Result.Ok := True;
end;

{ ---- encoder driver ------------------------------------------------------ }

function StepOf(Mode: LongInt; Big: SizeUInt): SizeUInt;
begin
  if Mode > 0 then Result := Mode
  else if Mode = 0 then Result := Big
  else
    case Rnd mod 4 of
      0: Result := 1 + Rnd mod 17;
      1: Result := 1 + Rnd mod 4099;
    else
      Result := 1 + Rnd mod 70001;
    end;
end;

function PlanOf(InStep, OutStep: LongInt): TPlan;
begin
  Result.InStep := InStep;
  Result.OutStep := OutStep;
  Result.Flush := nil;
  Result.Double := False;
  Result.WithInput := False;
  Result.ZeroOut := False;
  Result.Seed := 12345;
end;

{ encode Src with E (initialized) following the plan; Code = last result }
function EncodeOn(var E: TOrepEnc; const Src: TBytes; const Pl: TPlan;
  out Code: Integer): TBytes;
var
  Acc: TBuf;
  OutB: TBytes;
  NextIn, NextOut, ZP: PByte;
  AvailIn, AvailOut, OutN, Given, N, ZN, InBefore, Len: SizeUInt;
  R, Mode: Integer;
  Fi, Done, Need: LongInt;
  Pending: Boolean;
  Stall: LongInt;
begin
  Acc.B := nil; Acc.N := 0;
  Rng := Pl.Seed or 1;
  SetLength(OutB, 70002);
  Len := Length(Src);
  Given := 0; NextIn := PtrOf(Src); AvailIn := 0;
  Fi := 0; Done := 0; Stall := 0;
  if Pl.Double then Need := 2 else Need := 1;
  { flush points past the end are dropped }
  while True do
  begin
    while (Fi < Length(Pl.Flush)) and (Pl.Flush[Fi] > Len) do Inc(Fi);
    Pending := (Fi < Length(Pl.Flush)) and (Pl.Flush[Fi] = Given);
    if (AvailIn = 0) and (Given < Len) and not Pending then
    begin
      N := StepOf(Pl.InStep, Len);
      if N > Len - Given then N := Len - Given;
      if (Fi < Length(Pl.Flush)) and (Pl.Flush[Fi] > Given) and
        (Given + N > Pl.Flush[Fi]) then N := Pl.Flush[Fi] - Given;
      NextIn := @Src[Given];
      AvailIn := N;
      Inc(Given, N);
      Pending := (Fi < Length(Pl.Flush)) and (Pl.Flush[Fi] = Given);
    end;
    Pending := Pending and ((AvailIn = 0) or Pl.WithInput);
    if Pending then Mode := OREP_FLUSH
    else if (AvailIn = 0) and (Given = Len) then Mode := OREP_FINISH
    else Mode := OREP_RUN;
    InBefore := AvailIn;
    if Pl.ZeroOut then
    begin
      ZP := @OutB[0]; ZN := 0;
      R := OrepEncRun(E, NextIn, AvailIn, ZP, ZN, Mode);
      if R < 0 then begin Code := R; Exit(Bytes(Acc)); end;
      Check((ZP = @OutB[0]) and (ZN = 0), 'a call with no output room wrote');
    end;
    OutN := StepOf(Pl.OutStep, Length(OutB));
    if OutN > SizeUInt(Length(OutB)) then OutN := Length(OutB);
    NextOut := @OutB[0];
    AvailOut := OutN;
    R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut, Mode);
    Append(Acc, @OutB[0], OutN - AvailOut);
    if R <> OREP_OK then Break;
    if Pending and (AvailIn = 0) and (AvailOut > 0) then
    begin
      Inc(Done);
      if Done >= Need then begin Inc(Fi); Done := 0; end;
    end;
    if (InBefore = AvailIn) and (AvailOut = OutN) and not Pending then
    begin
      Inc(Stall);
      if Stall > 100000 then
      begin
        Check(False, 'encoder makes no progress');
        R := OREP_E_PARAM;
        Break;
      end;
    end
    else Stall := 0;
  end;
  Code := R;
  if R = OREP_END then
    Check((AvailIn = 0) and (Given = Len), 'OREP_END before all input');
  Result := Bytes(Acc);
end;

function Enc(const Src: TBytes; const P: TOrepParams; const Pl: TPlan;
  out Code: Integer): TBytes;
var
  E: TOrepEnc;
begin
  Result := nil;
  Code := OrepEncInit(E, P);
  if Code <> OREP_OK then Exit;
  Result := EncodeOn(E, Src, Pl, Code);
  OrepEncEnd(E);
end;

function EncT(const Src: TBytes; P: TOrepParams; T: LongWord;
  const Pl: TPlan; const Name: string): TBytes;
var
  Code: Integer;
begin
  P.Threads := T;
  Result := Enc(Src, P, Pl, Code);
  Check(Code = OREP_END, Name + ': encode -t' + IntToStr(T) + ' ended with ' +
    OrepErrorText(Code));
end;

{ ---- decoder drivers ----------------------------------------------------- }

{ OrepDecRun with InStep / OutStep pieces; Code = OREP_END, an error, or
  OREP_OK when it wants more input after all of S; Left = bytes of S not
  consumed }
function DecodeOn(var D: TOrepDec; const S: TBytes; InStep, OutStep: LongInt;
  out Code: Integer; out Left: SizeUInt): TBytes;
var
  Acc: TBuf;
  OutB: TBytes;
  NextIn, NextOut: PByte;
  AvailIn, AvailOut, OutN, Given, N: SizeUInt;
  R: Integer;
begin
  Acc.B := nil; Acc.N := 0;
  SetLength(OutB, 70002);
  Given := 0; NextIn := PtrOf(S); AvailIn := 0;
  repeat
    if (AvailIn = 0) and (Given < SizeUInt(Length(S))) then
    begin
      N := StepOf(InStep, Length(S));
      if N > SizeUInt(Length(S)) - Given then N := SizeUInt(Length(S)) - Given;
      NextIn := @S[Given];
      AvailIn := N;
      Inc(Given, N);
    end;
    OutN := StepOf(OutStep, Length(OutB));
    if OutN > SizeUInt(Length(OutB)) then OutN := Length(OutB);
    NextOut := @OutB[0];
    AvailOut := OutN;
    R := OrepDecRun(D, NextIn, AvailIn, NextOut, AvailOut);
    Append(Acc, @OutB[0], OutN - AvailOut);
    if R <> OREP_OK then Break;
    { all input given and consumed, and output room left: it needs more }
    if (AvailIn = 0) and (Given = SizeUInt(Length(S))) and (AvailOut > 0) then
      Break;
  until False;
  Code := R;
  Left := SizeUInt(Length(S)) - Given + AvailIn;
  Result := Bytes(Acc);
end;

function Dec(const S: TBytes; InStep, OutStep: LongInt; out Code: Integer;
  out Left: SizeUInt): TBytes;
var
  D: TOrepDec;
begin
  OrepDecInit(D, 0);
  Result := DecodeOn(D, S, InStep, OutStep, Code, Left);
  OrepDecEnd(D);
end;

function DecBuf(const S: TBytes; MemLimit: QWord; out Code: Integer): TBytes;
var
  P: PByte;
  N: SizeUInt;
begin
  Result := nil;
  Code := OrepDecodeBuf(PtrOf(S), Length(S), MemLimit, P, N);
  if Code = OREP_OK then
  begin
    SetLength(Result, N);
    if N > 0 then Move(P^, Result[0], N);
    FreeMem(P);
  end
  else Check((P = nil) and (N = 0), 'DecodeBuf error with output');
end;

{ OrepDecPeek / OrepDecSkip: input in InStep pieces, skips of odd sizes,
  a peek with no skip (it must give the same data again), skip past the
  end (clamped) }
function PeekOn(var D: TOrepDec; const S: TBytes; InStep: LongInt;
  out Code: Integer; out Left: SizeUInt): TBytes;
const
  Skips: array[0..7] of SizeUInt = (1, 3, 0, 7, 13, 65537, 4093, 2);
var
  Acc: TBuf;
  NextIn, Data, Data2: PByte;
  AvailIn, Given, N, Cnt, Cnt2: SizeUInt;
  R: Integer;
  Step: LongInt;
begin
  Acc.B := nil; Acc.N := 0;
  Given := 0; NextIn := PtrOf(S); AvailIn := 0; Step := 0;
  repeat
    if (AvailIn = 0) and (Given < SizeUInt(Length(S))) then
    begin
      N := StepOf(InStep, Length(S));
      if N > SizeUInt(Length(S)) - Given then N := SizeUInt(Length(S)) - Given;
      NextIn := @S[Given];
      AvailIn := N;
      Inc(Given, N);
    end;
    R := OrepDecPeek(D, NextIn, AvailIn, Data, Cnt);
    if R <> OREP_OK then Break;
    if Cnt > 0 then
    begin
      N := Skips[Step mod 8];
      Inc(Step);
      if N = 0 then
      begin
        R := OrepDecPeek(D, NextIn, AvailIn, Data2, Cnt2);
        Check((R = OREP_OK) and (Data2 = Data) and (Cnt2 = Cnt),
          'peek without a skip moved');
        OrepDecSkip(D, 0);
        Continue;
      end;
      if N > Cnt then
      begin
        Append(Acc, Data, Cnt);
        OrepDecSkip(D, N);  { more than there is: all of it }
      end
      else
      begin
        Append(Acc, Data, N);
        OrepDecSkip(D, N);
      end;
      Continue;
    end;
    if (AvailIn = 0) and (Given = SizeUInt(Length(S))) then Break;
  until False;
  Code := R;
  Left := SizeUInt(Length(S)) - Given + AvailIn;
  Result := Bytes(Acc);
end;

function DecPeek(const S: TBytes; InStep: LongInt; out Code: Integer;
  out Left: SizeUInt): TBytes;
var
  D: TOrepDec;
begin
  OrepDecInit(D, 0);
  Result := PeekOn(D, S, InStep, Code, Left);
  OrepDecEnd(D);
end;

{ every decoder path gives Src back and consumes all of S }
procedure CheckDecode(const S, Src: TBytes; const Name: string; Slow: Boolean);
var
  Code: Integer;
  Left: SizeUInt;
  X: TBytes;
begin
  X := DecBuf(S, 0, Code);
  Check((Code = OREP_OK) and Same(X, Src), Name + ': DecodeBuf ' +
    OrepErrorText(Code));
  X := Dec(S, -1, -1, Code, Left);
  Check((Code = OREP_END) and (Left = 0) and Same(X, Src),
    Name + ': streaming decode (random pieces) ' + OrepErrorText(Code));
  if Slow then
  begin
    X := Dec(S, 1, 1, Code, Left);
    Check((Code = OREP_END) and (Left = 0) and Same(X, Src),
      Name + ': decode 1 byte in / 1 byte out ' + OrepErrorText(Code));
  end;
  X := DecPeek(S, -1, Code, Left);
  Check((Code = OREP_END) and (Left = 0) and Same(X, Src),
    Name + ': peek/skip ' + OrepErrorText(Code));
  if Slow then
  begin
    X := DecPeek(S, 1, Code, Left);
    Check((Code = OREP_END) and (Left = 0) and Same(X, Src),
      Name + ': peek/skip 1 byte in ' + OrepErrorText(Code));
  end;
end;

{ OREP_EDGE_DUMP=<dir>: a failing case's input is written there }
procedure Dump(const Name: string; const Src: TBytes);
var
  Dir: string;
  F: File;
begin
  Dir := GetEnvironmentVariable('OREP_EDGE_DUMP');
  if Dir = '' then Exit;
  AssignFile(F, Dir + '/' + Name + '.bin');
  Rewrite(F, 1);
  if Length(Src) > 0 then BlockWrite(F, Src[0], Length(Src));
  CloseFile(F);
  WriteLn('  input written to ', Dir, '/', Name, '.bin');
end;

procedure Digest(const Name: string; const S: TBytes);
begin
  WriteLn('D ', Name, ' ', Length(S), ' ', Hex(Crc(S)));
end;

{ ---- data ---------------------------------------------------------------- }

procedure FillRandom(var B: TBytes; Seed: QWord);
var
  I: SizeUInt;
  V: QWord;
begin
  Rng := Seed or 1;
  V := 0;
  if Length(B) = 0 then Exit;
  for I := 0 to SizeUInt(Length(B)) - 1 do
  begin
    if I and 7 = 0 then V := Rnd;
    B[I] := Byte(V);
    V := V shr 8;
  end;
end;

procedure CopyBack(var B: TBytes; P, D, L: SizeUInt);
var
  I: SizeUInt;
begin
  if (D < 1) or (D > P) or (P + L > SizeUInt(Length(B))) then Exit;
  for I := 0 to L - 1 do B[P + I] := B[P + I - D];
end;

{ random data with copies from fixed distances: W, W-1, W-15, W/2, C, C+1,
  C-1, 17, 1, 4, W+1 (beyond the window: must not be used) and 3W/4, of
  lengths 16..4096; then copies from exactly W back that cross the chunk,
  window and ring boundaries }
function WData(N: SizeUInt; W: QWord; C: LongWord; Seed: QWord): TBytes;
const
  Lens: array[0..6] of SizeUInt = (16, 17, 64, 300, 4096, 1000, 33);
var
  Ds: array[0..11] of QWord;
  P, L: SizeUInt;
  K: LongWord;
  R: QWord;
  Sp: array[0..9] of QWord;
begin
  SetLength(Result, N);
  if N = 0 then Exit;
  FillRandom(Result, Seed);
  Ds[0] := W; Ds[1] := W - 1; Ds[2] := W - 15; Ds[3] := W div 2;
  Ds[4] := C; Ds[5] := C + 1; Ds[6] := C - 1; Ds[7] := 17; Ds[8] := 1;
  Ds[9] := 4; Ds[10] := W + 1; Ds[11] := 3 * W div 4;
  P := 700;
  K := 0;
  while P < N do
  begin
    L := Lens[K mod 7];
    CopyBack(Result, P, Ds[K mod 12], L);
    Inc(P, L + 300 + (K * 1237) mod 2500);
    Inc(K);
  end;
  R := (W + C - 1) div C * C + C;
  Sp[0] := C; Sp[1] := 2 * C; Sp[2] := W; Sp[3] := W + C; Sp[4] := R;
  Sp[5] := R + C; Sp[6] := 2 * R; Sp[7] := 2 * W; Sp[8] := R - 1;
  Sp[9] := 3 * C;
  for K := 0 to 9 do
    if Sp[K] > 300 then CopyBack(Result, Sp[K] - 300, W, 600);
end;

{ runs of one byte with random bursts and a short period }
function ZData(N: SizeUInt; Seed: QWord): TBytes;
var
  I: SizeUInt;
begin
  SetLength(Result, N);
  Rng := Seed or 1;
  if N = 0 then Exit;
  for I := 0 to N - 1 do
  begin
    if (I mod 5003) < 9 then Result[I] := Byte(Rnd)
    else if (I div 20011) mod 2 = 1 then Result[I] := Byte(I mod 3 + 65)
    else Result[I] := 0;
  end;
end;

{ ---- one case: every encoder and decoder path ---------------------------- }

procedure CheckCase(const Name: string; const Src: TBytes;
  const P: TOrepParams; WantDistW: Boolean);
var
  S1, S: TBytes;
  Pl: TPlan;
  T: LongWord;
  Info: TInfo;
  Code: Integer;
  BP: PByte;
  BN: SizeUInt;
  PP: TOrepParams;
  Small: Boolean;
begin
  Small := Length(Src) <= 2 * K64 + 1;
  S1 := EncT(Src, P, 1, PlanOf(0, 0), Name);
  Digest(Name, S1);
  Info := Parse(S1);
  Check(Info.Ok, Name + ': stream does not parse: ' + Info.Why);
  if not Info.Ok then Dump(Name, Src);
  if Info.Ok then
  begin
    Check(Info.Window = P.Window, Name + ': header window');
    Check(Info.Total = QWord(Length(Src)), Name + ': total');
    Check(Info.MaxDist <= P.Window, Name + ': distance > window');
    if WantDistW then
      Check(Info.DistW > 0, Name + ': no match exactly W back (' +
        IntToStr(Info.Matches) + ' matches, max dist ' +
        IntToStr(Info.MaxDist) + ')');
  end;
  for T := 1 to 4 do
  begin
    if T = 3 then Continue;
    if T > 1 then
      Check(Same(EncT(Src, P, T, PlanOf(0, 0), Name), S1),
        Name + ': -t' + IntToStr(T) + ' differs');
    Pl := PlanOf(-1, -1);
    Pl.Seed := 777 + T;
    Check(Same(EncT(Src, P, T, Pl, Name), S1),
      Name + ': random pieces -t' + IntToStr(T) + ' differ');
  end;
  if Small and not Quick then
  begin
    Check(Same(EncT(Src, P, 1, PlanOf(1, 1), Name), S1),
      Name + ': 1 byte in / 1 byte out differs');
    Pl := PlanOf(1, 1);
    Pl.ZeroOut := True;
    Check(Same(EncT(Src, P, 4, Pl, Name), S1),
      Name + ': 1 byte in / out with empty-output calls -t4 differs');
    Check(Same(EncT(Src, P, 2, PlanOf(1, 0), Name), S1),
      Name + ': 1 byte in -t2 differs');
  end;
  CheckDecode(S1, Src, Name, not Quick);
  { whole buffer (SizeHint = the input size: maybe a smaller window) }
  PP := P;
  Code := OrepEncodeBuf(PtrOf(Src), Length(Src), PP, BP, BN);
  Check(Code = OREP_OK, Name + ': EncodeBuf ' + OrepErrorText(Code));
  if Code = OREP_OK then
  begin
    SetLength(S, BN);
    if BN > 0 then Move(BP^, S[0], BN);
    FreeMem(BP);
    Digest(Name + '/buf', S);
    Info := Parse(S);
    Check(Info.Ok and (Info.Window <= P.Window),
      Name + ': EncodeBuf stream: ' + Info.Why);
    CheckDecode(S, Src, Name + '/buf', False);
    PP.Threads := 4;
    Code := OrepEncodeBuf(PtrOf(Src), Length(Src), PP, BP, BN);
    Check((Code = OREP_OK) and (BN = SizeUInt(Length(S))) and
      ((BN = 0) or CompareMem(BP, @S[0], BN)), Name + ': EncodeBuf -t4 differs');
    if Code = OREP_OK then FreeMem(BP);
  end;
end;

function Params(W: QWord; C, MinLen: LongWord): TOrepParams;
begin
  OrepParamsDefault(Result);
  Result.Window := W;
  Result.Chunk := C;
  Result.MinLen := MinLen;
end;

procedure AddSize(var A: array of SizeUInt; var N: LongInt; V: Int64);
var
  I: LongInt;
begin
  if V < 0 then Exit;
  for I := 0 to N - 1 do if A[I] = SizeUInt(V) then Exit;
  A[N] := V;
  Inc(N);
end;

{ ---- 1. sizes around C, W and R -------------------------------------------- }

procedure SizeSweep(W: QWord; C: LongWord; MinLen: LongWord; Big: Boolean);
var
  Sz: array[0..63] of SizeUInt;
  N, I: LongInt;
  R: QWord;
  P: TOrepParams;
  Src: TBytes;
  Nm: string;
begin
  R := (W + C - 1) div C * C + C;
  N := 0;
  AddSize(Sz, N, 0); AddSize(Sz, N, 1); AddSize(Sz, N, 15); AddSize(Sz, N, 16);
  AddSize(Sz, N, 17); AddSize(Sz, N, 63); AddSize(Sz, N, 64); AddSize(Sz, N, 65);
  for I := -1 to 1 do
  begin
    AddSize(Sz, N, Int64(C) + I);
    AddSize(Sz, N, 2 * Int64(C) + I);
    AddSize(Sz, N, Int64(W) + I);
    AddSize(Sz, N, Int64(R) + I);
    if Big then AddSize(Sz, N, Int64(R) + C + I); { the threaded encoder's ring }
  end;
  if Big then AddSize(Sz, N, 2 * Int64(R) + 1);
  P := Params(W, C, MinLen);
  for I := 0 to N - 1 do
  begin
    Nm := 'w' + IntToStr(W) + '-b' + IntToStr(C) + '-l' + IntToStr(MinLen) +
      '-n' + IntToStr(Sz[I]);
    Src := WData(Sz[I], W, C, Sz[I] + W);
    CheckCase(Nm + '-w', Src, P, (W >= 1024) and (Sz[I] >= W + 4096));
    if Sz[I] <= 2 * C + 1 then
    begin
      Src := ZData(Sz[I], Sz[I] + 3);
      CheckCase(Nm + '-z', Src, P, False);
    end;
  end;
end;

{ ---- 2. flushes ------------------------------------------------------------- }

procedure FlushSweep(Al: LongWord);
const
  L = 300;
var
  Src, Base, S, S2, X, Agg: TBytes;
  P: TOrepParams;
  Pl: TPlan;
  K: SizeUInt;
  T: LongWord;
  Code: Integer;
  Left: SizeUInt;
  AggCrc: LongWord;
  Nm: string;
  Info: TInfo;
begin
  { a small input with repeats (period 37) and random bytes between }
  SetLength(Src, L);
  FillRandom(Src, 99);
  for K := 60 to 200 do Src[K] := Src[K - 37];
  for K := 240 to 299 do Src[K] := Src[K - 200];
  P := Params(64 * 1024, K64, 16);
  P.Align := Al;
  Base := EncT(Src, P, 1, PlanOf(0, 0), 'flush base');
  Digest('a' + IntToStr(Al) + '-flush-base', Base);
  AggCrc := 0;
  Agg := nil;
  for K := 0 to L do
  begin
    Nm := 'a' + IntToStr(Al) + '-flush@' + IntToStr(K);
    Pl := PlanOf(0, 0);
    SetLength(Pl.Flush, 1);
    Pl.Flush[0] := K;
    S := EncT(Src, P, 1, Pl, Nm);
    AggCrc := OrepCrc32c(AggCrc, PtrOf(S), Length(S));
    Info := Parse(S);
    Check(Info.Ok, Nm + ': does not parse: ' + Info.Why);
    if (K = 0) or (K = L) then
      Check(Same(S, Base), Nm + ': a flush with nothing new changed the stream')
    else
      Check(Info.Ok and (Info.Blocks = 2), Nm + ': expected 2 blocks');
    X := DecBuf(S, 0, Code);
    Check((Code = OREP_OK) and Same(X, Src), Nm + ': round trip');
    X := Dec(S, 1, 1, Code, Left);
    Check((Code = OREP_END) and Same(X, Src) and (Left = 0),
      Nm + ': 1-byte decode');
    for T := 2 to 4 do
    begin
      if T = 3 then Continue;
      Check(Same(EncT(Src, P, T, Pl, Nm), S), Nm + ': -t' + IntToStr(T) + ' differs');
    end;
    { flushed twice: the second is a no-op }
    Pl.Double := True;
    Check(Same(EncT(Src, P, 1, Pl, Nm), S), Nm + ': flush twice differs');
    Pl.Double := False;
    { OREP_FLUSH given together with the input; 1-byte output }
    Pl.WithInput := True;
    Pl.OutStep := 1;
    Check(Same(EncT(Src, P, 2, Pl, Nm), S), Nm + ': flush with input differs');
    { 1 byte in, 1 byte out, flush twice, empty-output calls }
    Pl.WithInput := False;
    Pl.InStep := 1;
    Pl.Double := True;
    Pl.ZeroOut := True;
    Check(Same(EncT(Src, P, 4, Pl, Nm), S), Nm + ': 1-byte flush twice differs');
  end;
  WriteLn('D a', Al, '-flush-sweep ', Hex(AggCrc));
  { a flush at every byte in one stream: blocks of one byte }
  Pl := PlanOf(1, 1);
  SetLength(Pl.Flush, L + 1);
  for K := 0 to L do Pl.Flush[K] := K;
  S := EncT(Src, P, 1, Pl, 'flush-every-byte');
  Digest('a' + IntToStr(Al) + '-flush-every-byte', S);
  Info := Parse(S);
  Check(Info.Ok and (Info.Blocks = L), 'flush every byte: ' + IntToStr(Info.Blocks) +
    ' blocks ' + Info.Why);
  Check(Same(EncT(Src, P, 4, Pl, 'flush-every-byte'), S), 'flush every byte -t4');
  Pl.Double := True;
  Check(Same(EncT(Src, P, 2, Pl, 'flush-every-byte'), S), 'flush every byte twice -t2');
  CheckDecode(S, Src, 'flush-every-byte', True);
  { the same flush point twice in the list }
  Pl := PlanOf(0, 0);
  SetLength(Pl.Flush, 3);
  Pl.Flush[0] := 100; Pl.Flush[1] := 100; Pl.Flush[2] := 100;
  S2 := EncT(Src, P, 1, Pl, 'flush x3');
  SetLength(Pl.Flush, 1);
  Check(Same(EncT(Src, P, 1, Pl, 'flush x1'), S2), 'flush three times differs');
  { the empty input: flush, flush, finish }
  Pl := PlanOf(0, 0);
  SetLength(Pl.Flush, 2);
  Pl.Flush[0] := 0; Pl.Flush[1] := 0;
  SetLength(X, 0);
  S := EncT(X, P, 1, Pl, 'empty flushed');
  Check(Same(S, EncT(X, P, 1, PlanOf(0, 0), 'empty')), 'flushes on an empty encoder changed the stream');
  Check(Same(S, EncT(X, P, 4, Pl, 'empty flushed')), 'empty flushed -t4');
  CheckDecode(S, X, 'empty flushed', True);
end;

{ flushes at and around block boundaries of a 3C+5 input }
procedure FlushBlocks;
var
  Src, Base, S: TBytes;
  P: TOrepParams;
  Pl: TPlan;
  Pts: array[0..6] of SizeUInt;
  I, T: LongInt;
  Info: TInfo;
  Nm: string;
begin
  P := Params(100 * 1024, K64, 16);
  Src := WData(3 * K64 + 5, P.Window, K64, 4242);
  Base := EncT(Src, P, 1, PlanOf(0, 0), 'blocks base');
  Digest('fb-base', Base);
  Pts[0] := K64 - 1; Pts[1] := K64; Pts[2] := K64 + 1; Pts[3] := 2 * K64;
  Pts[4] := 2 * K64 + 1; Pts[5] := 3 * K64; Pts[6] := 3 * K64 + 5;
  for I := 0 to 6 do
  begin
    Nm := 'fb@' + IntToStr(Pts[I]);
    Pl := PlanOf(-1, -1);
    SetLength(Pl.Flush, 1);
    Pl.Flush[0] := Pts[I];
    S := EncT(Src, P, 1, Pl, Nm);
    Digest(Nm, S);
    if Pts[I] mod K64 = 0 then
      Check(Same(S, Base), Nm + ': a flush at a block boundary changed the stream')
    else if Pts[I] = SizeUInt(Length(Src)) then
      Check(Same(S, Base), Nm + ': a flush right before the end changed the stream');
    for T := 2 to 4 do
      if T <> 3 then
        Check(Same(EncT(Src, P, T, Pl, Nm), S), Nm + ': -t' + IntToStr(T));
    Pl.Double := True;
    Pl.WithInput := True;
    Check(Same(EncT(Src, P, 4, Pl, Nm), S), Nm + ': twice with input -t4');
    CheckDecode(S, Src, Nm, False);
  end;
  { all of them together, with odd pieces }
  Pl := PlanOf(-1, -1);
  SetLength(Pl.Flush, 7);
  for I := 0 to 6 do Pl.Flush[I] := Pts[I];
  S := EncT(Src, P, 1, Pl, 'fb-all');
  Digest('fb-all', S);
  Info := Parse(S);
  Check(Info.Ok and (Info.Blocks = 7), 'fb-all: blocks ' + IntToStr(Info.Blocks));
  for T := 2 to 4 do
    if T <> 3 then Check(Same(EncT(Src, P, T, Pl, 'fb-all'), S), 'fb-all -t' + IntToStr(T));
  CheckDecode(S, Src, 'fb-all', True);
end;

{ ---- 3. reset and reuse ----------------------------------------------------- }

procedure EncoderReuse;
var
  E: TOrepEnc;
  P1, P2, P3: TOrepParams;
  X, Y, Z, S, F, OutB: TBytes;
  Code, R: Integer;
  T: LongWord;
  InP, OutP: PByte;
  InN, OutN: SizeUInt;
begin
  P1 := Params(64 * 1024, K64, 16);
  P2 := Params(300 * 1024, 128 * 1024, 32);
  P3 := Params(4096, K64, 16);
  X := WData(200000, P1.Window, K64, 1);
  Y := WData(700000, P2.Window, 128 * 1024, 2);
  Z := ZData(150000, 3);
  SetLength(OutB, 1 shl 20);
  for T := 1 to 4 do
  begin
    if T = 3 then Continue;
    P1.Threads := T; P2.Threads := T; P3.Threads := T;
    { End then Init again on the same record: bigger window after smaller,
      then smaller after bigger }
    Check(OrepEncInit(E, P1) = OREP_OK, 'reuse init 1');
    S := EncodeOn(E, X, PlanOf(-1, -1), Code);
    Check((Code = OREP_END) and Same(S, EncT(X, P1, 1, PlanOf(0, 0), 'x')), 'reuse 1');
    OrepEncEnd(E);
    Check(OrepEncInit(E, P2) = OREP_OK, 'reuse init 2');
    S := EncodeOn(E, Y, PlanOf(-1, -1), Code);
    Check((Code = OREP_END) and Same(S, EncT(Y, P2, 1, PlanOf(0, 0), 'y')),
      'reuse bigger window -t' + IntToStr(T));
    { reset in the middle of a stream (blocks in flight), another input }
    Check(OrepEncReset(E) = OREP_OK, 'reset after the end');
    InP := @Y[0]; InN := 3 * 128 * 1024 + 77;
    OutP := @OutB[0]; OutN := 100;
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_RUN);
    Check(R = OREP_OK, 'run before reset: ' + OrepErrorText(R));
    Check(OrepEncReset(E) = OREP_OK, 'reset mid-stream');
    S := EncodeOn(E, Z, PlanOf(-1, -1), Code);
    F := EncT(Z, P2, 1, PlanOf(0, 0), 'z');
    Check((Code = OREP_END) and Same(S, F), 'reset mid-stream -t' + IntToStr(T));
    { reset right after a flush }
    InP := @Y[0]; InN := 1000;
    OutP := @OutB[0]; OutN := Length(OutB);
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_RUN);
    Check(OrepEncReset(E) = OREP_OK, 'reset 2');
    InP := @Y[0]; InN := 1000;
    OutP := @OutB[0]; OutN := Length(OutB);
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_FLUSH);
    Check(R = OREP_OK, 'flush before reset');
    Check(OrepEncReset(E) = OREP_OK, 'reset after flush');
    S := EncodeOn(E, Z, PlanOf(0, 0), Code);
    Check((Code = OREP_END) and Same(S, F), 'reset after flush -t' + IntToStr(T));
    { after OREP_END: more calls end again, take no input, write nothing }
    InP := @Y[0]; InN := 10;
    OutP := @OutB[0]; OutN := 10;
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_FINISH);
    Check((R = OREP_END) and (InN = 10) and (OutN = 10), 'run after the end');
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_RUN);
    Check((R = OREP_END) and (InN = 10) and (OutN = 10), 'run (RUN) after the end');
    { reset twice, then an empty stream }
    Check(OrepEncReset(E) = OREP_OK, 'reset 3');
    Check(OrepEncReset(E) = OREP_OK, 'reset 4');
    SetLength(S, 0);
    S := EncodeOn(E, S, PlanOf(0, 1), Code);
    SetLength(F, 0);
    Check((Code = OREP_END) and Same(S, EncT(F, P2, 1, PlanOf(0, 0), 'e')),
      'empty stream after reset');
    OrepEncEnd(E);
    Check(OrepEncInit(E, P3) = OREP_OK, 'reuse init 3');
    S := EncodeOn(E, X, PlanOf(1000, 3), Code);
    Check((Code = OREP_END) and Same(S, EncT(X, P3, 1, PlanOf(0, 0), 'x3')),
      'reuse smaller window -t' + IntToStr(T));
    OrepEncEnd(E);
    { calls on an ended encoder }
    InP := @Y[0]; InN := 10;
    OutP := @OutB[0]; OutN := 10;
    Check(OrepEncRun(E, InP, InN, OutP, OutN, OREP_RUN) = OREP_E_PARAM,
      'run on an ended encoder');
    Check(OrepEncReset(E) = OREP_E_PARAM, 'reset on an ended encoder');
  end;
end;

procedure BadParams;
var
  P: TOrepParams;
  E: TOrepEnc;
  BP: PByte;
  BN: SizeUInt;

  procedure Bad(const Q: TOrepParams; const What: string);
  begin
    Check(OrepEncInit(E, Q) = OREP_E_PARAM, 'accepted ' + What);
    Check(OrepEncodeBuf(@Dummy[0], 1, Q, BP, BN) = OREP_E_PARAM,
      'EncodeBuf accepted ' + What);
  end;

begin
  OrepParamsDefault(P); P.Window := 0; Bad(P, 'window 0');
  OrepParamsDefault(P); P.Window := OREP_MAX_WINDOW + 1; Bad(P, 'window too big');
  OrepParamsDefault(P); P.Chunk := 32 * 1024; Bad(P, 'chunk 32k');
  OrepParamsDefault(P); P.Chunk := 128 * 1024 * 1024; Bad(P, 'chunk 128m');
  OrepParamsDefault(P); P.Chunk := 96 * 1024; Bad(P, 'chunk 96k');
  OrepParamsDefault(P); P.MinLen := 15; Bad(P, 'minlen 15');
  OrepParamsDefault(P); P.MinLen := 16; P.Align := 32; Bad(P, 'align > minlen');
  OrepParamsDefault(P); P.Threads := 257; Bad(P, 'threads 257');
  OrepParamsDefault(P); P.Cands := 0; Bad(P, 'cands 0');
  OrepParamsDefault(P); P.Density := 0; Bad(P, 'density 0');
  { the limits themselves are accepted }
  OrepParamsDefault(P); P.Window := 1; P.Chunk := K64; P.MinLen := 16;
  Check(OrepEncInit(E, P) = OREP_OK, 'window 1 rejected');
  OrepEncEnd(E);
end;

procedure DecoderReuse;
var
  D: TOrepDec;
  Pa, Pb, Pc: TOrepParams;
  Xa, Xb, Xc, Sa, Sb, Sc, X, G: TBytes;
  Code: Integer;
  Left: SizeUInt;
  InP, OutP: PByte;
  InN, OutN: SizeUInt;
  OutB: TBytes;
begin
  Pa := Params(64 * 1024, K64, 16);
  Pb := Params(300 * 1024, 128 * 1024, 32);
  Pc := Params(100 * 1024, K64, 16);
  Xa := WData(250000, Pa.Window, K64, 11);
  Xb := WData(800000, Pb.Window, 128 * 1024, 12);
  Xc := WData(300000, Pc.Window, K64, 13);
  Sa := EncT(Xa, Pa, 1, PlanOf(0, 0), 'a');
  Sb := EncT(Xb, Pb, 1, PlanOf(0, 0), 'b');
  Sc := EncT(Xc, Pc, 1, PlanOf(0, 0), 'c');
  OrepDecInit(D, 0);
  X := DecodeOn(D, Sa, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xa), 'dec reuse a');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 1');
  X := DecodeOn(D, Sb, 1, 1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xb), 'dec reuse b (bigger window and chunk)');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 2');
  X := PeekOn(D, Sa, 7, Code, Left);
  Check((Code = OREP_END) and Same(X, Xa), 'dec reuse a after b (smaller)');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 3');
  X := DecodeOn(D, Sc, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xc), 'dec reuse c (same chunk, bigger ring)');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 4');
  { reset in the middle of a stream }
  X := DecodeOn(D, Copy(Sb, 0, Length(Sb) div 2), -1, -1, Code, Left);
  Check((Code = OREP_OK) and IsPrefix(X, Xb), 'half a stream wants more');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset mid-stream');
  X := DecodeOn(D, Sa, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xa), 'dec after a reset mid-stream');
  { an incompatible stream, then the error sticks, then reset recovers }
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 5');
  G := Copy(Sa, 0, 64);
  G[0] := Ord('X');
  X := DecodeOn(D, G, -1, -1, Code, Left);
  Check(Code = OREP_E_VERSION, 'bad magic after reset: ' + OrepErrorText(Code));
  InP := @Sa[0]; InN := Length(Sa);
  SetLength(OutB, 16); OutP := @OutB[0]; OutN := 16;
  Check(OrepDecRun(D, InP, InN, OutP, OutN) < 0, 'the error does not stick');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset after error');
  X := DecodeOn(D, Sc, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xc), 'dec after an error and reset');
  { a corrupted block in the middle, then reset }
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 6');
  G := Copy(Sb, 0, Length(Sb));
  G[Length(G) div 2] := G[Length(G) div 2] xor $40;
  X := DecodeOn(D, G, -1, -1, Code, Left);
  Check(Code < 0, 'corrupt block accepted');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 7');
  X := DecodeOn(D, Sb, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xb), 'dec b after a corrupt b');
  OrepDecEnd(D);
  { a memory limit that fits a but not b; it is kept across resets }
  OrepDecInit(D, OrepDecMemory(64 * 1024, K64));
  X := DecodeOn(D, Sa, -1, -1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xa), 'memlimit: a');
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 8');
  X := DecodeOn(D, Sb, -1, -1, Code, Left);
  Check(Code = OREP_E_MEM, 'memlimit: b accepted ' + OrepErrorText(Code));
  Check(OrepDecReset(D) = OREP_OK, 'dec reset 9');
  X := DecodeOn(D, Sa, 1, 1, Code, Left);
  Check((Code = OREP_END) and Same(X, Xa), 'memlimit: a again');
  OrepDecEnd(D);
  { calls on an ended decoder }
  InP := @Sa[0]; InN := Length(Sa); OutP := @OutB[0]; OutN := 16;
  Check(OrepDecRun(D, InP, InN, OutP, OutN) = OREP_E_PARAM, 'run on an ended decoder');
  Check(OrepDecReset(D) = OREP_E_PARAM, 'reset on an ended decoder');
  Digest('dec-a', Sa); Digest('dec-b', Sb); Digest('dec-c', Sc);
end;

{ OrepDecReset after a header that was parsed and then rejected (here by the
  memory limit) must not keep memory made for another chunk: a stream with
  64k chunks and a 2 MiB ring, then one with 1 MiB chunks over the limit,
  then one with 1 MiB chunks and the same 2 MiB ring (0.0.9 kept the 64k
  slots and wrote past them) }
procedure ResetAfterRejected;
var
  Src1, Src3, S1, S2, S3, X: TBytes;
  Code: Integer;
  Left: SizeUInt;
  D: TOrepDec;
  T: Integer;
begin
  SetLength(Src1, 100); FillRandom(Src1, 71);
  S1 := EncT(Src1, Params($1F0000, K64, 16), 1, PlanOf(0, 0), 'rr1');
  S2 := EncT(Src1, Params(64 * 1024 * 1024, 1024 * 1024, 16), 1, PlanOf(0, 0), 'rr2');
  Src3 := WData(204800, 4096, K64, 72);
  S3 := EncT(Src3, Params(1024 * 1024, 1024 * 1024, 16), 1, PlanOf(0, 0), 'rr3');
  for T := 0 to 1 do
  begin
    OrepDecInit(D, 4 * 1024 * 1024);
    X := DecodeOn(D, S1, -1, -1, Code, Left);
    Check((Code = OREP_END) and Same(X, Src1), 'reset-rejected: 1');
    Check(OrepDecReset(D) = OREP_OK, 'reset-rejected: reset 1');
    X := DecodeOn(D, S2, -1, -1, Code, Left);
    Check(Code = OREP_E_MEM, 'reset-rejected: 2 not over the limit ' + OrepErrorText(Code));
    Check(OrepDecReset(D) = OREP_OK, 'reset-rejected: reset 2');
    if T = 1 then
    begin
      Check(OrepDecReset(D) = OREP_OK, 'reset-rejected: reset 2b');
    end;
    X := DecodeOn(D, S3, -1, -1, Code, Left);
    Check((Code = OREP_END) and Same(X, Src3), 'reset-rejected: 3 ' + OrepErrorText(Code));
    OrepDecEnd(D);
  end;
end;

{ ---- 4. concatenation, truncation, headers ---------------------------------- }

procedure Concat;
var
  P1, P2: TOrepParams;
  X1, X2, S1, S2, SS, X, E0, S0: TBytes;
  Code: Integer;
  Left: SizeUInt;
  D: TOrepDec;
  Mode: Integer;
begin
  P1 := Params(64 * 1024, K64, 16);
  P2 := Params(300 * 1024, 128 * 1024, 32);
  X1 := WData(140000, P1.Window, K64, 21);
  X2 := WData(500000, P2.Window, 128 * 1024, 22);
  S1 := EncT(X1, P1, 1, PlanOf(0, 0), 's1');
  S2 := EncT(X2, P2, 1, PlanOf(0, 0), 's2');
  SetLength(E0, 0);
  S0 := EncT(E0, P1, 1, PlanOf(0, 0), 's0');
  SS := Cat(S1, S2);
  for Mode := 0 to 3 do
  begin
    OrepDecInit(D, 0);
    case Mode of
      0: X := DecodeOn(D, SS, 0, 0, Code, Left);
      1: X := DecodeOn(D, SS, 1, 1, Code, Left);
      2: X := DecodeOn(D, SS, -1, -1, Code, Left);
    else
      X := PeekOn(D, SS, 1, Code, Left);
    end;
    Check((Code = OREP_END) and Same(X, X1) and (Left = SizeUInt(Length(S2))),
      'concat mode ' + IntToStr(Mode) + ': first stream ' + OrepErrorText(Code) +
      ' left ' + IntToStr(Left));
    { called again with the rest: still the end, nothing consumed }
    X := DecodeOn(D, S2, 0, 0, Code, Left);
    Check((Code = OREP_END) and (Length(X) = 0) and (Left = SizeUInt(Length(S2))),
      'concat: a call after the end consumed or wrote');
    Check(OrepDecReset(D) = OREP_OK, 'concat reset');
    X := DecodeOn(D, Copy(SS, Length(S1), Length(S2)), -1, -1, Code, Left);
    Check((Code = OREP_END) and Same(X, X2) and (Left = 0), 'concat: second stream');
    OrepDecEnd(D);
  end;
  X := DecBuf(SS, 0, Code);
  Check(Code = OREP_E_DATA, 'DecodeBuf accepted two streams: ' + OrepErrorText(Code));
  X := DecBuf(Cat(S1, Copy(S2, 0, 1)), 0, Code);
  Check(Code = OREP_E_DATA, 'DecodeBuf accepted a trailing byte');
  X := DecBuf(Cat(S0, S0), 0, Code);
  Check(Code = OREP_E_DATA, 'DecodeBuf accepted two empty streams');
  { an empty stream first }
  X := Dec(Cat(S0, S1), 1, 1, Code, Left);
  Check((Code = OREP_END) and (Length(X) = 0) and (Left = SizeUInt(Length(S1))),
    'concat after an empty stream');
end;

procedure Truncation;
var
  P: TOrepParams;
  Src, S, X, Pre: TBytes;
  Pl: TPlan;
  L: SizeUInt;
  Code, R: Integer;
  Left: SizeUInt;
  D: TOrepDec;
  InP, OutP: PByte;
  InN, OutN: SizeUInt;
  OutB: TBytes;
  Acc: TBuf;
  Bad, Wrong: LongInt;
begin
  { a small stream with several blocks (flushes) and matches }
  P := Params(64 * 1024, K64, 16);
  SetLength(Src, 3000);
  FillRandom(Src, 31);
  for L := 1000 to 1999 do Src[L] := Src[L - 1000];
  for L := 2500 to 2999 do Src[L] := 0;
  Pl := PlanOf(0, 0);
  SetLength(Pl.Flush, 3);
  Pl.Flush[0] := 700; Pl.Flush[1] := 1500; Pl.Flush[2] := 2600;
  S := EncT(Src, P, 1, Pl, 'trunc');
  Digest('trunc', S);
  Bad := 0; Wrong := 0;
  for L := 0 to Length(S) - 1 do
  begin
    Pre := Copy(S, 0, L);
    X := DecBuf(Pre, 0, Code);
    if Code = OREP_OK then Inc(Bad);
    X := Dec(Pre, -1, -1, Code, Left);
    if (Code <> OREP_OK) or (Left <> 0) or not IsPrefix(X, Src) then
    begin
      Inc(Wrong);
      if Wrong < 5 then
        WriteLn('  cut at ', L, ': ', OrepErrorText(Code), ' left ', Left);
    end;
  end;
  Check(Bad = 0, IntToStr(Bad) + ' cut streams accepted by DecodeBuf');
  Check(Wrong = 0, IntToStr(Wrong) + ' cut streams not "need more" in streaming');
  { one byte at a time: OK until the very last byte, output always a prefix }
  OrepDecInit(D, 0);
  SetLength(OutB, 1);
  Acc.B := nil; Acc.N := 0;
  Wrong := 0;
  for L := 0 to Length(S) - 1 do
  begin
    InP := @S[L]; InN := 1;
    repeat
      OutP := @OutB[0]; OutN := 1;
      R := OrepDecRun(D, InP, InN, OutP, OutN);
      Append(Acc, @OutB[0], 1 - OutN);
    until (R <> OREP_OK) or (OutN = 1);
    if L < SizeUInt(Length(S)) - 1 then
    begin
      if (R <> OREP_OK) or (InN <> 0) then Inc(Wrong);
    end
    else Check((R = OREP_END) and (InN = 0), 'last byte: not the end');
  end;
  Check(Wrong = 0, 'byte-by-byte decode ended early');
  Check(Same(Bytes(Acc), Src), 'byte-by-byte decode output');
  OrepDecEnd(D);
  { a big stream cut around its blocks }
  P := Params(100 * 1024, K64, 16);
  Src := WData(300000, P.Window, K64, 32);
  S := EncT(Src, P, 1, PlanOf(0, 0), 'trunc big');
  Bad := 0; Wrong := 0;
  L := 0;
  while L < SizeUInt(Length(S)) do
  begin
    X := DecBuf(Copy(S, 0, L), 0, Code);
    if Code = OREP_OK then Inc(Bad);
    X := Dec(Copy(S, 0, L), -1, -1, Code, Left);
    if (Code <> OREP_OK) or (Left <> 0) or not IsPrefix(X, Src) then Inc(Wrong);
    if (L < 300) or (L + 300 > SizeUInt(Length(S))) then Inc(L) else Inc(L, 997);
  end;
  Check(Bad = 0, 'big: ' + IntToStr(Bad) + ' cut streams accepted by DecodeBuf');
  Check(Wrong = 0, 'big: ' + IntToStr(Wrong) + ' cut streams not "need more"');
end;

function PutVarB(V: QWord): TBytes;
begin
  Result := nil;
  repeat
    SetLength(Result, Length(Result) + 1);
    if V >= $80 then Result[High(Result)] := (V and $7F) or $80
    else Result[High(Result)] := V;
    V := V shr 7;
  until V = 0;
end;

{ the stream with its header's flags field replaced by Fl (raw bytes) and
  the header CRC fixed (or not) }
function WithFlags(const S: TBytes; const Info: TInfo; const Fl: TBytes;
  FixCrc: Boolean): TBytes;
var
  H, Tail: TBytes;
  C: LongWord;
begin
  H := Cat(Copy(S, 0, Info.FlagsOff), Fl);
  if FixCrc then C := Crc(H)
  else C := Crc(H) xor 1;
  SetLength(H, Length(H) + 4);
  H[High(H) - 3] := Byte(C); H[High(H) - 2] := Byte(C shr 8);
  H[High(H) - 1] := Byte(C shr 16); H[High(H)] := Byte(C shr 24);
  Tail := Copy(S, Info.CrcOff + 4, Length(S));
  Result := Cat(H, Tail);
end;

procedure ExpectCode(const S: TBytes; Want: Integer; const Name: string;
  AltOk: Integer);
var
  Code: Integer;
  Left: SizeUInt;
  X: TBytes;
begin
  X := DecBuf(S, 0, Code);
  Check((Code = Want) or (Code = AltOk), Name + ': DecodeBuf gave ' + OrepErrorText(Code));
  X := Dec(S, 1, 1, Code, Left);
  Check((Code = Want) or (Code = AltOk), Name + ': 1-byte decode gave ' + OrepErrorText(Code));
  X := DecPeek(S, -1, Code, Left);
  Check((Code = Want) or (Code = AltOk), Name + ': peek gave ' + OrepErrorText(Code));
  if Length(X) = 0 then ;
end;

procedure Headers;
var
  P: TOrepParams;
  Src, S, B, V3, Fl: TBytes;
  Info: TInfo;
  Vals: array[0..5] of QWord = (1, 2, $80, $4000, $80000000, $FFFFFFFF);
  I: LongInt;
  Code: Integer;
  C: LongWord;
begin
  P := Params(100 * 1024, K64, 16);
  Src := WData(150000, P.Window, K64, 41);
  S := EncT(Src, P, 1, PlanOf(0, 0), 'hdr');
  Info := Parse(S);
  Check(Info.Ok and (Info.Flags = 0) and (Info.FlagsLen = 1), 'flags field');
  for I := 0 to 5 do
  begin
    B := WithFlags(S, Info, PutVarB(Vals[I]), True);
    ExpectCode(B, OREP_E_VERSION, 'flags ' + IntToHex(Vals[I], 1), OREP_E_VERSION);
    B := WithFlags(S, Info, PutVarB(Vals[I]), False);
    ExpectCode(B, OREP_E_DATA, 'flags ' + IntToHex(Vals[I], 1) + ' bad crc', OREP_E_DATA);
  end;
  { flags of 2^32 and more (5 bytes): not a valid header either way }
  B := WithFlags(S, Info, PutVarB(QWord(1) shl 32), True);
  ExpectCode(B, OREP_E_VERSION, 'flags 2^32', OREP_E_DATA);
  { 6 varint bytes }
  SetLength(Fl, 6);
  Fl[0] := $81; Fl[1] := $80; Fl[2] := $80; Fl[3] := $80; Fl[4] := $80; Fl[5] := 0;
  B := WithFlags(S, Info, Fl, True);
  ExpectCode(B, OREP_E_DATA, 'flags in 6 bytes', OREP_E_VERSION);
  { flags 0 written in 2 bytes: a valid varint of 0 (with alignment 1, so
    that the header one byte longer does not move the padding) }
  P.Align := 1;
  S := EncT(Src, P, 1, PlanOf(0, 0), 'hdr a1');
  Info := Parse(S);
  SetLength(Fl, 2);
  Fl[0] := $80; Fl[1] := 0;
  B := DecBuf(WithFlags(S, Info, Fl, True), 0, Code);
  Check((Code = OREP_OK) and Same(B, Src), 'flags 0 in two bytes: ' +
    OrepErrorText(Code));
  P.Align := 0;
  S := EncT(Src, P, 1, PlanOf(0, 0), 'hdr');
  Info := Parse(S);
  { version 3: the same header without the flags field }
  V3 := Copy(S, 0, Info.FlagsOff);
  V3[4] := 3;
  C := Crc(V3);
  SetLength(V3, Length(V3) + 4);
  V3[High(V3) - 3] := Byte(C); V3[High(V3) - 2] := Byte(C shr 8);
  V3[High(V3) - 1] := Byte(C shr 16); V3[High(V3)] := Byte(C shr 24);
  V3 := Cat(V3, Copy(S, Info.CrcOff + 4, Length(S)));
  ExpectCode(V3, OREP_E_VERSION, 'version 3', OREP_E_VERSION);
  for I := 0 to 2 do
  begin
    B := Copy(S, 0, Length(S));
    case I of
      0: B[4] := 5;
      1: B[4] := 0;
      2: B[0] := Ord('o');
    end;
    ExpectCode(B, OREP_E_VERSION, 'version/magic ' + IntToStr(I), OREP_E_VERSION);
  end;
  { only the first 5 bytes of a version 3 stream: already rejected }
  ExpectCode(Copy(V3, 0, 5), OREP_E_VERSION, 'version 3, 5 bytes', OREP_E_VERSION);
end;

{ windows below the longest period a forced anchor tries (16): a period
  must not be used as a distance beyond the window.  The first case is
  6475dd96 x 5 with W = 3 (found by the size sweep). }
procedure TinyWindows;
const
  Ws: array[0..8] of LongWord = (1, 2, 3, 4, 7, 8, 15, 16, 17);
var
  I, U, Rep, K: LongInt;
  Src, Unt: TBytes;
  Info: TInfo;
  Bad: LongInt;
  P: TOrepParams;
  S, X: TBytes;
  Code: Integer;
begin
  SetLength(Src, 20);
  for K := 0 to 19 do Src[K] := ($96DD7564 shr (8 * (K mod 4))) and $FF;
  CheckCase('w3-period4x5', Src, Params(3, K64, 16), False);
  Bad := 0;
  for I := 0 to 8 do
    for U := 1 to 17 do
      for Rep := 2 to 6 do
      begin
        SetLength(Unt, U);
        FillRandom(Unt, U * 100 + Rep);
        SetLength(Src, U * Rep + 7);
        FillRandom(Src, 5);
        for K := 0 to U * Rep - 1 do Src[K + 3] := Unt[K mod U];
        P := Params(Ws[I], K64, 16);
        S := EncT(Src, P, 1, PlanOf(0, 0), 'tiny');
        Info := Parse(S);
        X := DecBuf(S, 0, Code);
        if (not Info.Ok) or (Code <> OREP_OK) or not Same(X, Src) then
        begin
          Inc(Bad);
          if Bad <= 5 then
            WriteLn('  W=', Ws[I], ' period ', U, ' x', Rep, ': ', Info.Why,
              ' / ', OrepErrorText(Code));
        end;
      end;
  Check(Bad = 0, IntToStr(Bad) + ' of 765 periodic inputs with W <= 17 give a bad stream');
end;

{ ---- main ------------------------------------------------------------------ }

var
  T0: QWord;
  Src: TBytes;

procedure Lap(const What: string);
begin
  WriteLn('# ', What, ' ', GetTickCount64 - T0, ' ms');
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = 'quick') then Quick := True;
  FillChar(Dummy, SizeOf(Dummy), 0);
  T0 := GetTickCount64;
  BadParams;
  TinyWindows;        Lap('tiny windows');
  Headers;            Lap('headers');
  Concat;             Lap('concat');
  Truncation;         Lap('truncation');
  DecoderReuse;       Lap('decoder reuse');
  ResetAfterRejected; Lap('reset after a rejected header');
  EncoderReuse;       Lap('encoder reuse');
  FlushSweep(1);      Lap('flush sweep, align 1');
  FlushSweep(0);      Lap('flush sweep, align auto');
  FlushBlocks;        Lap('flush at blocks');
  SizeSweep(64 * 1024, K64, 16, True);    Lap('sizes w64k');
  SizeSweep(100 * 1024, K64, 16, True);   Lap('sizes w100k');
  SizeSweep(300 * 1024, K64, 32, True);   Lap('sizes w300k');
  SizeSweep(4096, K64, 16, False);        Lap('sizes w4k');
  SizeSweep(128 * 1024, K64, 16, False);  Lap('sizes w128k');
  SizeSweep(200 * 1024, 128 * 1024, 16, False);  Lap('sizes w200k b128k');
  { W = 1: only runs }
  Src := ZData(3 * K64 + 1, 5);
  CheckCase('w1-z', Src, Params(1, K64, 16), False);
  Src := WData(2 * K64 + 1, 1, K64, 6);
  CheckCase('w1-w', Src, Params(1, K64, 16), False);
  Lap('w1');
  WriteLn('checks ', Checks, ', failures ', Fails);
  if Fails = 0 then WriteLn('orep_edge: ok') else Halt(1);
end.
