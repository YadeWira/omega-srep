unit osrep_encoder;
{ Minimal v6 encoder (-m3): a new hash-chain match finder, no legacy code.

  The format does not require a particular match stream.  This encoder uses a
  greedy LZ parse inside each block, keeps source and destination inside the
  block, then emits the matches in source order (as required by §2.7) and the
  uncovered bytes in destination order. }

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$ifdef unix}BaseUnix,{$endif} SysUtils, Classes, osrep_crc, osrep_format,
  osrep_vhash;

type
  TEncoderOptions = record
    BlockSize: QWord;
    MinMatch: LongWord;
    ChainDepth: LongWord;
    Stride: LongWord;
    Method: LongInt;
    UseHash: Boolean;
    Threads: LongInt;
    { 0 = no limit; otherwise a soft cap in bytes. The encoder lowers the
      block size (and, if needed, the thread count) to stay under it. }
    MemLimit: QWord;
    Seed: TBytes;
    { -m6: the length of every match is a multiple of Align (--align=N) }
    Align: LongWord;
  end;

function DefaultEncoderOptions: TEncoderOptions;
function SeedFromNumber(N: QWord): TBytes;
procedure EncodeToStream(InStream, OutStream: TStream;
  const Opt: TEncoderOptions; const Meta: TBytes = nil);

implementation

{$ifndef OSREP_NO_NATIVE}
{$L osrep_match.o}
function OsrepMatchFind(Data: Pointer; N: SizeUInt; MinMatch, ChainDepth,
  Stride: LongWord; Method: LongInt; Head: PLongInt; HashMask: LongWord;
  Prev: PLongInt; OutMatches: Pointer; Cap: SizeUInt): SizeUInt; cdecl;
  external name 'osrep_match_find';
{$endif}

type
  TLrMatch = record
    Src, Dst, Len: QWord;
  end;
  TLrMatchArray = array of TLrMatch;
  PLrMatch = ^TLrMatch;

const
  { -m6: the default minimum match and the length alignment (osrep_lr.c) }
  OsrepLrDefaultMinMatch = 512;
  OsrepLrAlign = 16;

{$ifndef OSREP_NO_NATIVE}
{$L osrep_lr.o}
type
  TLrReadFn = function(Ctx: Pointer; Pos: QWord; Buf: PByte;
    Len: SizeUInt): LongInt; cdecl;
  TLrEmitFn = function(Ctx: Pointer; Src, Dst, Len: QWord): LongInt; cdecl;
  {$push}{$packrecords c}
  { osrep_lr_params (src/c/osrep_lr.c) }
  TLrParams = record
    N: QWord;
    BufCap: QWord;
    Mem: PByte;
    Read: TLrReadFn;
    Emit: TLrEmitFn;
    Ctx: Pointer;
    Table: PLongWord;
    Filter: PByte;
    Buf: PByte;
    MinLen, Win, Step, Align, TBits, FBits: LongWord;
  end;
  {$pop}
  PLrParams = ^TLrParams;

function OsrepLrIndex(D: PByte; Len: QWord; Win, Step: LongWord;
  OutM: PQWord): QWord; cdecl; external name 'osrep_lr_index';
procedure OsrepLrFilterAdd(Filter: PByte; FBits: LongWord; M: PQWord;
  Count: QWord); cdecl; external name 'osrep_lr_filter_add';
function OsrepLrScan(D: PByte; Lo, Hi, Ns: QWord; Win, Step: LongWord;
  Filter: PByte; FBits: LongWord; OutRec: PQWord; Cap: QWord;
  out Next: QWord): QWord; cdecl; external name 'osrep_lr_scan';
function OsrepLrStateSize: QWord; cdecl; external name 'osrep_lr_state_size';
function OsrepLrBegin(State: Pointer; Params: PLrParams): LongInt; cdecl;
  external name 'osrep_lr_begin';
function OsrepLrFeed(State: Pointer; Rec: PQWord; Count: QWord): LongInt;
  cdecl; external name 'osrep_lr_feed';
{$else}
{ Pascal reference of osrep_lr_find (src/c/osrep_lr.c): same table, same
  filter, same matches. }
{$push}{$Q-}{$R-}
const
  LrB = QWord($9E3779B97F4A7C15);
  LrWays = 4;

function LrHash(D: PByte; Win: LongWord): QWord;
var
  I: LongWord;
begin
  Result := 0;
  for I := 0 to Win - 1 do
    Result := Result * LrB + QWord(D[I]) + 1;
end;

function LrMix(H: QWord): QWord;
begin
  H := H xor (H shr 31);
  H := H * QWord($D6E8FEB86659FD93);
  H := H xor (H shr 32);
  Result := H;
end;

procedure LrInsert(Table: PLongWord; TBits: LongWord; Filter: PByte;
  FBits: LongWord; H: QWord; Idx1: LongWord);
var
  M, F: QWord;
  B: PLongWord;
  I: LongWord;
begin
  M := LrMix(H);
  B := Table + (M shr (64 - TBits)) * LrWays * 2;
  F := M and ((QWord(1) shl FBits) - 1);
  Filter[F shr 3] := Filter[F shr 3] or Byte(1 shl (F and 7));
  for I := LrWays - 1 downto 1 do
  begin
    B[2 * I] := B[2 * (I - 1)];
    B[2 * I + 1] := B[2 * (I - 1) + 1];
  end;
  B[0] := LongWord(M);
  B[1] := Idx1;
end;

function OsrepLrFind(Data: Pointer; N: QWord; MinLen, Win, Step,
  Align: LongWord; Table: PLongWord; TBits: LongWord; Filter: PByte;
  FBits: LongWord; OutMatches: Pointer; Cap: SizeUInt): SizeUInt;
var
  D: PByte;
  Outp: PLrMatch;
  Bw1, H, Q, LastEnd, NextIns, M, F, P, Fl, Bl, BestLen, BestSrc, BestBack,
    Dst, E: QWord;
  B: PLongWord;
  Tag, W, I: LongWord;
  Found: Boolean;
begin
  Result := 0;
  D := PByte(Data);
  Outp := PLrMatch(OutMatches);
  if (Win = 0) or (Step = 0) or (Align = 0) or (N < QWord(Win)) or
     (MinLen < Win) then
    Exit;
  Bw1 := 1;
  for I := 1 to Win - 1 do
    Bw1 := Bw1 * LrB;
  H := LrHash(D, Win);
  Q := 0;
  LastEnd := 0;
  NextIns := 0;
  while Q + Win <= N do
  begin
    M := LrMix(H);
    F := M and ((QWord(1) shl FBits) - 1);
    Found := False;
    if (Filter[F shr 3] and (1 shl (F and 7))) <> 0 then
    begin
      B := Table + (M shr (64 - TBits)) * LrWays * 2;
      Tag := LongWord(M);
      BestLen := 0;
      BestSrc := 0;
      BestBack := 0;
      for W := 0 to LrWays - 1 do
      begin
        if B[2 * W + 1] = 0 then
          Break;
        if B[2 * W] <> Tag then
          Continue;
        P := QWord(B[2 * W + 1] - 1) * Step;
        if (P >= Q) or (CompareByte(D[P], D[Q], Win) <> 0) then
          Continue;
        Fl := Win;
        while (Q + Fl < N) and (D[P + Fl] = D[Q + Fl]) do
          Inc(Fl);
        Bl := 0;
        while (Bl < P) and (Q - Bl > LastEnd) and
              (D[P - Bl - 1] = D[Q - Bl - 1]) do
          Inc(Bl);
        if Fl + Bl > BestLen then
        begin
          BestLen := Fl + Bl;
          BestSrc := P - Bl;
          BestBack := Bl;
        end;
      end;
      BestLen := BestLen - BestLen mod Align;
      if BestLen >= MinLen then
      begin
        Dst := Q - BestBack;
        E := Dst + BestLen;
        if Result >= Cap then
          Exit(High(SizeUInt));
        Outp[Result].Src := BestSrc;
        Outp[Result].Dst := Dst;
        Outp[Result].Len := BestLen;
        Inc(Result);
        LastEnd := E;
        while NextIns * Step < E do
        begin
          if NextIns * Step + Win <= N then
            LrInsert(Table, TBits, Filter, FBits,
              LrHash(D + NextIns * Step, Win), LongWord(NextIns + 1));
          Inc(NextIns);
        end;
        Q := E;
        if Q + Win > N then
          Break;
        H := LrHash(D + Q, Win);
        Found := True;
      end;
    end;
    if Found then
      Continue;
    if Q = NextIns * Step then
    begin
      LrInsert(Table, TBits, Filter, FBits, H, LongWord(NextIns + 1));
      Inc(NextIns);
    end;
    if Q + Win >= N then
      Break;
    H := (H - (QWord(D[Q]) + 1) * Bw1) * LrB + QWord(D[Q + Win]) + 1;
    Inc(Q);
  end;
end;
{$pop}
{$endif}

type
  TMatchRec = record
    Source: LongWord;
    Dest: LongWord;
    Len: LongWord;
  end;
  TMatchArray = array of TMatchRec;

  TByteBuffer = record
    Data: TBytes;
    Len: SizeInt;
    procedure Init;
    procedure Ensure(Cap: SizeInt);
    procedure AddByte(B: Byte);
    procedure AddBytes(const Src; Count: SizeInt);
    function Finish: TBytes;
  end;

procedure TByteBuffer.Init;
begin
  Data := nil;
  Len := 0;
end;

procedure TByteBuffer.Ensure(Cap: SizeInt);
var
  NewCap: SizeInt;
begin
  if Cap <= Length(Data) then
    Exit;
  NewCap := Length(Data);
  if NewCap < 4096 then
    NewCap := 4096;
  while NewCap < Cap do
  begin
    if NewCap > High(SizeInt) div 2 then
    begin
      NewCap := Cap;
      Break;
    end;
    NewCap := NewCap * 2;
  end;
  SetLength(Data, NewCap);
end;

procedure TByteBuffer.AddByte(B: Byte);
begin
  Ensure(Len + 1);
  Data[Len] := B;
  Inc(Len);
end;

procedure TByteBuffer.AddBytes(const Src; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  Ensure(Len + Count);
  Move(Src, Data[Len], Count);
  Inc(Len, Count);
end;

function TByteBuffer.Finish: TBytes;
begin
  SetLength(Data, Len);
  Result := Data;
  Data := nil;
  Len := 0;
end;

{ wraps modulo 2^64 on purpose: no overflow check even under -Co }
{$push}{$Q-}{$R-}
function SplitMix64(var X: QWord): QWord;
var
  Z: QWord;
begin
  X := X + QWord($9E3779B97F4A7C15);
  Z := X;
  Z := (Z xor (Z shr 30)) * QWord($BF58476D1CE4E5B9);
  Z := (Z xor (Z shr 27)) * QWord($94D049BB133111EB);
  Result := Z xor (Z shr 31);
end;
{$pop}

function SeedFromNumber(N: QWord): TBytes;
var
  X, V: QWord;
  I, J: Integer;
begin
  Result := nil;
  SetLength(Result, 32);
  X := N xor QWord($D1B54A32D192ED03);
  for I := 0 to 3 do
  begin
    V := SplitMix64(X);
    for J := 0 to 7 do
      Result[I * 8 + J] := Byte(V shr (8 * J));
  end;
end;

function DefaultEncoderOptions: TEncoderOptions;
begin
  Result.BlockSize := 8 * 1024 * 1024;
  Result.MinMatch := 4;
  Result.ChainDepth := 16;
  Result.Stride := 1;
  Result.Method := 3;
  Result.UseHash := True;
  Result.Threads := 0; { auto: up to 8 }
  Result.MemLimit := 0;
  Result.Seed := SeedFromNumber(0);
  Result.Align := OsrepLrAlign;
end;

const
  { The encoder's fixed footprint (binary, RTL, streams) and a safety margin
    over the measured peak RSS. }
  OsrepEncoderBaseBytes = QWord(8) * 1024 * 1024;
  OsrepMinBlockSize = QWord(64) * 1024;

function EncoderHeadBytes(BlockSize: QWord): QWord;
var
  Bits: Integer;
  Needed: QWord;
begin
  Bits := 12;
  Needed := BlockSize div 4 + 1;
  while (QWord(1) shl Bits) < Needed do
    Inc(Bits);
  if Bits > 22 then
    Bits := 22;
  Result := (QWord(1) shl Bits) * 4;
end;

function EncoderThreadBytes(BlockSize: QWord): QWord;
begin
  { data (1x) + Prev (4x) + matches (3x) + records/literals buffers (1x),
    plus the hash head table }
  Result := BlockSize * 9 + EncoderHeadBytes(BlockSize);
end;

function EstimateEncoderBytes(BlockSize: QWord; Threads: SizeInt): QWord;
begin
  Result := OsrepEncoderBaseBytes +
    QWord(Threads) * EncoderThreadBytes(BlockSize);
end;

function HighestPowerOfTwo(N: QWord): QWord;
begin
  Result := 1;
  while (Result <= N div 2) do
    Result := Result * 2;
end;

function Hash4(const Data: TBytes; P: SizeInt): LongWord; inline;
var
  H: LongWord;
begin
  H := LongWord(Data[P]) * LongWord($9E3779B1);
  H := H xor (LongWord(Data[P + 1]) * LongWord($85EBCA77));
  H := H xor (LongWord(Data[P + 2]) * LongWord($C2B2AE3D));
  H := H xor (LongWord(Data[P + 3]) * LongWord($27D4EB2F));
  H := H xor (H shr 15);
  Result := H;
end;

procedure AddVarint(var Buf: TByteBuffer; Value: QWord);
var
  B: Byte;
begin
  repeat
    B := Byte(Value and $7F);
    Value := Value shr 7;
    if Value <> 0 then
      B := B or $80;
    Buf.AddByte(B);
  until Value = 0;
end;

procedure SortMatches(var A: TMatchArray);
var
  Tmp: TMatchArray;
  Width, L, M, R, I, J, K: SizeInt;

  function Less(const X, Y: TMatchRec): Boolean; inline;
  begin
    if X.Source <> Y.Source then
      Exit(X.Source < Y.Source);
    if X.Dest <> Y.Dest then
      Exit(X.Dest < Y.Dest);
    Result := X.Len < Y.Len;
  end;

begin
  if Length(A) < 2 then
    Exit;
  SetLength(Tmp, Length(A));
  Width := 1;
  while Width < Length(A) do
  begin
    L := 0;
    while L < Length(A) do
    begin
      M := L + Width;
      if M > Length(A) then
        M := Length(A);
      R := L + 2 * Width;
      if R > Length(A) then
        R := Length(A);
      I := L;
      J := M;
      K := L;
      while (I < M) and (J < R) do
      begin
        if Less(A[I], A[J]) then
        begin
          Tmp[K] := A[I];
          Inc(I);
        end
        else
        begin
          Tmp[K] := A[J];
          Inc(J);
        end;
        Inc(K);
      end;
      while I < M do
      begin
        Tmp[K] := A[I];
        Inc(I);
        Inc(K);
      end;
      while J < R do
      begin
        Tmp[K] := A[J];
        Inc(J);
        Inc(K);
      end;
      Inc(L, 2 * Width);
    end;
    for I := 0 to High(A) do
      A[I] := Tmp[I];
    Width := Width * 2;
  end;
end;

procedure BuildLiterals(const Data: TBytes; const Matches: TMatchArray;
  out Literals: TBytes);
var
  Buf: TByteBuffer;
  I, Pos: SizeInt;
  M: TMatchRec;
begin
  Buf.Init;
  Pos := 0;
  for I := 0 to High(Matches) do
  begin
    M := Matches[I];
    if M.Dest < LongWord(Pos) then
      raise EOsrepError.Create(3, 'encoder: overlapping match destinations');
    if M.Dest > LongWord(Pos) then
      Buf.AddBytes(Data[Pos], SizeInt(M.Dest) - Pos);
    Pos := SizeInt(M.Dest) + SizeInt(M.Len);
  end;
  if Pos < Length(Data) then
    Buf.AddBytes(Data[Pos], Length(Data) - Pos);
  Literals := Buf.Finish;
end;

function OsrepCpuCount: LongInt;
{$ifdef linux}
var
  F: TextFile;
  S: string;
begin
  Result := 0;
  try
    AssignFile(F, '/proc/cpuinfo');
    Reset(F);
    try
      while not Eof(F) do
      begin
        ReadLn(F, S);
        if Copy(S, 1, 9) = 'processor' then
          Inc(Result);
      end;
    finally
      CloseFile(F);
    end;
  except
    Result := 0;
  end;
  if Result < 1 then
    Result := 1;
end;
{$else}
begin
  Result := TThread.ProcessorCount;
  if Result < 1 then
    Result := 1;
end;
{$endif}

function MatchLength(const Data: TBytes; A, B, MaxLen: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 0;
  while I + SizeOf(QWord) <= MaxLen do
  begin
    if PInt64(@Data[A + I])^ <> PInt64(@Data[B + I])^ then
      Break;
    Inc(I, SizeOf(QWord));
  end;
  while (I < MaxLen) and (Data[A + I] = Data[B + I]) do
    Inc(I);
  Result := I;
end;

function Hash8(const Data: TBytes; P: SizeInt): LongWord; inline;
var
  H: LongWord;
begin
  H := Hash4(Data, P) xor (Hash4(Data, P + 4) * LongWord($9E3779B1));
  H := H xor (H shr 15);
  Result := H;
end;

function Hash16(const Data: TBytes; P: SizeInt): LongWord; inline;
var
  H: LongWord;
begin
  H := Hash8(Data, P) xor (Hash8(Data, P + 8) * LongWord($9E3779B1));
  H := H xor (H shr 15);
  Result := H;
end;

function Hash32(const Data: TBytes; P: SizeInt): LongWord; inline;
var
  H: LongWord;
begin
  H := Hash16(Data, P) xor (Hash16(Data, P + 16) * LongWord($9E3779B1));
  H := H xor (H shr 15);
  Result := H;
end;

procedure EncodeBlock(const Data: TBytes; const Opt: TEncoderOptions;
  out Records, Literals, Digest: TBytes);
var
  N, Pos, BestLen, BestSrc, NextLen, NextSrc, HashBits, HeadSize: SizeInt;
  Head: array of LongInt;
  Prev: array of LongInt;
  HashMask: LongWord;
  Matches: TMatchArray;
  Sorted: TMatchArray;
  I, K: SizeInt;
  Count: SizeUInt;
  Needed: QWord;
  Buf: TByteBuffer;
  PrevSource: LongWord;
  M: TMatchRec;
  Tag: TBytes;

  procedure InsertPos(P: SizeInt); inline;
  var
    HH: LongWord;
    UseHash32, UseHash16, UseHash8: Boolean;
  begin
    UseHash32 := (Opt.Method >= 4) and (Opt.MinMatch >= 32);
    UseHash16 := (Opt.Method >= 4) and (Opt.MinMatch >= 16) and not UseHash32;
    UseHash8 := (Opt.Method >= 4) and (Opt.MinMatch >= 8) and
      not UseHash16 and not UseHash32;
    if UseHash32 then
    begin
      if P + 32 > N then
        Exit;
    end
    else if UseHash16 then
    begin
      if P + 16 > N then
        Exit;
    end
    else if UseHash8 then
    begin
      if P + 8 > N then
        Exit;
    end
    else if P + 4 > N then
      Exit;
    if (Opt.Stride > 1) and ((P mod SizeInt(Opt.Stride)) <> 0) then
      Exit;
    if UseHash32 then
      HH := Hash32(Data, P) and HashMask
    else if UseHash16 then
      HH := Hash16(Data, P) and HashMask
    else if UseHash8 then
      HH := Hash8(Data, P) and HashMask
    else
      HH := Hash4(Data, P) and HashMask;
    Prev[P] := Head[HH];
    Head[HH] := P;
  end;

  procedure FindBest(P: SizeInt; out BLen, BSrc: SizeInt);
  var
    MaxLenC, D, L: SizeInt;
    HH: LongWord;
    C: LongInt;
  begin
    BLen := 0;
    BSrc := -1;
    MaxLenC := N - P;
    if (Opt.Method >= 4) and (Opt.MinMatch >= 32) then
    begin
      if MaxLenC < 32 then
        Exit;
      HH := Hash32(Data, P) and HashMask;
    end
    else if (Opt.Method >= 4) and (Opt.MinMatch >= 16) then
    begin
      if MaxLenC < 16 then
        Exit;
      HH := Hash16(Data, P) and HashMask;
    end
    else if (Opt.Method >= 4) and (Opt.MinMatch >= 8) then
    begin
      if MaxLenC < 8 then
        Exit;
      HH := Hash8(Data, P) and HashMask;
    end
    else
    begin
      if MaxLenC < 4 then
        Exit;
      HH := Hash4(Data, P) and HashMask;
    end;
    C := Head[HH];
    D := SizeInt(Opt.ChainDepth);
    if Opt.Method >= 5 then
    begin
      D := D * 2;
      if D > 256 then
        D := 256;
    end;
    while (C >= 0) and (D > 0) do
    begin
      L := MatchLength(Data, SizeInt(C), P, MaxLenC);
      if L > BLen then
      begin
        BLen := L;
        BSrc := C;
        if L = MaxLenC then
          Break;
      end;
      C := Prev[C];
      Dec(D);
    end;
  end;

begin
  N := Length(Data);
  Matches := nil;
  if Opt.Method in [0, 1, 2] then
  begin
    { dedup-only modes: the body is stored, not LZ-parsed }
    Records := nil;
    Literals := Data;
    Digest := nil;
    if Opt.UseHash then
    begin
      if not Vhash128(Opt.Seed, Data, 0, Length(Data), Tag) then
        raise EOsrepError.Create(3, 'encoder: VHASH failed');
      Digest := Tag;
    end;
    Exit;
  end;
  if N > 0 then
  begin
    HashBits := 12;
    Needed := QWord(N div 4) + 1;
    while (QWord(1) shl HashBits) < Needed do
      Inc(HashBits);
    if HashBits > 22 then
      HashBits := 22;
    HeadSize := 1 shl HashBits;
    HashMask := LongWord(HeadSize - 1);
    SetLength(Head, HeadSize);
    FillChar(Head[0], HeadSize * SizeOf(LongInt), $FF);
    SetLength(Prev, N);
    FillChar(Prev[0], N * SizeOf(LongInt), $FF);

{$ifdef OSREP_NO_NATIVE}
    Pos := 0;
    while Pos < N do
    begin
      FindBest(Pos, BestLen, BestSrc);
      if (BestLen >= SizeInt(Opt.MinMatch)) and (BestSrc >= 0) then
      begin
        if (Opt.Method >= 4) and (Pos + 1 < N) and
           (BestLen < N - Pos) then
        begin
          { lazy matching: if starting one byte later is clearly better,
            emit this byte as a literal and let the next iteration take it }
          InsertPos(Pos);
          FindBest(Pos + 1, NextLen, NextSrc);
          if NextLen > BestLen + 1 then
          begin
            Inc(Pos);
            Continue;
          end;
          for K := Pos + 1 to Pos + BestLen - 1 do
            InsertPos(K);
        end
        else
          for K := Pos to Pos + BestLen - 1 do
            InsertPos(K);
        SetLength(Matches, Length(Matches) + 1);
        Matches[High(Matches)].Source := LongWord(BestSrc);
        Matches[High(Matches)].Dest := LongWord(Pos);
        Matches[High(Matches)].Len := LongWord(BestLen);
        Inc(Pos, BestLen);
      end
      else
      begin
        InsertPos(Pos);
        Inc(Pos);
      end;
    end;
{$else}
    if N > 0 then
    begin
      SetLength(Matches, N div 4 + 2);
      Count := OsrepMatchFind(@Data[0], SizeUInt(N), Opt.MinMatch,
        Opt.ChainDepth, Opt.Stride, Opt.Method, @Head[0], HashMask,
        @Prev[0], @Matches[0], SizeUInt(Length(Matches)));
      if Count = High(SizeUInt) then
        raise EOsrepError.Create(2, 'match finder capacity is too small');
      SetLength(Matches, SizeInt(Count));
    end;
{$endif}
  end;

  BuildLiterals(Data, Matches, Literals);

  Sorted := Copy(Matches);
  SortMatches(Sorted);
  Buf.Init;
  PrevSource := 0;
  for I := 0 to High(Sorted) do
  begin
    M := Sorted[I];
    if M.Source < PrevSource then
      raise EOsrepError.Create(3, 'encoder: matches are not source-ordered');
    AddVarint(Buf, QWord(M.Source - PrevSource));
    AddVarint(Buf, QWord(M.Len));
    AddVarint(Buf, QWord(M.Dest - M.Source));
    PrevSource := M.Source;
  end;
  Records := Buf.Finish;

  Digest := nil;
  if Opt.UseHash then
  begin
    if not Vhash128(Opt.Seed, Data, 0, Length(Data), Tag) then
      raise EOsrepError.Create(3, 'encoder: VHASH failed');
    Digest := Tag;
  end;
end;

type
  TEncodeJob = class
    Data: TBytes;
    Opt: TEncoderOptions;
    Payload: TBytes;
    BlockCrc: LongWord;
    OrigSize: LongWord;
    RecordsSize: LongWord;
    LiteralSize: LongWord;
    ErrorMsg: string;
    procedure EncodeOne;
  end;

  TEncodeThread = class(TThread)
  public
    Job: TEncodeJob;
    procedure Execute; override;
  end;

procedure TEncodeJob.EncodeOne;
var
  Records, Literals, Digest: TBytes;
begin
  try
    EncodeBlock(Data, Opt, Records, Literals, Digest);
    SetLength(Payload, Length(Digest) + Length(Records) + Length(Literals));
    if Length(Digest) > 0 then
      Move(Digest[0], Payload[0], Length(Digest));
    if Length(Records) > 0 then
      Move(Records[0], Payload[Length(Digest)], Length(Records));
    if Length(Literals) > 0 then
      Move(Literals[0], Payload[Length(Digest) + Length(Records)],
        Length(Literals));
    BlockCrc := Crc32C(Payload);
    OrigSize := LongWord(Length(Data));
    RecordsSize := LongWord(Length(Records));
    LiteralSize := LongWord(Length(Literals));
  except
    on E: Exception do
      ErrorMsg := E.Message;
  end;
end;

procedure TEncodeThread.Execute;
begin
  Job.EncodeOne;
end;

type
  { what the finder gives back, and where it reads from }
  TLrCollect = record
    Stream: TStream;
    Matches: TLrMatchArray;
    Count: SizeInt;
  end;
  PLrCollect = ^TLrCollect;

{$ifndef OSREP_NO_NATIVE}
function LrReadCb(Ctx: Pointer; Pos: QWord; Buf: PByte;
  Len: SizeUInt): LongInt; cdecl;
{$if defined(unix) and defined(CPU64)}
var
  Got: TSsize;
{$endif}
begin
{$if defined(unix) and defined(CPU64)}
  { a file: pread, one call and no shared position }
  if PLrCollect(Ctx)^.Stream is THandleStream then
  begin
    while Len > 0 do
    begin
      { PChar: an untyped `var buf` overload exists and would take the
        address of the local pointer }
      Got := fpPRead(THandleStream(PLrCollect(Ctx)^.Stream).Handle,
        PChar(Buf), Len, TOff(Pos));
      if Got <= 0 then
        Exit(1);
      Inc(Buf, Got);
      Inc(Pos, QWord(Got));
      Dec(Len, SizeUInt(Got));
    end;
    Exit(0);
  end;
{$endif}
  try
    PLrCollect(Ctx)^.Stream.Position := Int64(Pos);
    if Len > 0 then
      PLrCollect(Ctx)^.Stream.ReadBuffer(Buf^, Len);
    Result := 0;
  except
    Result := 1;
  end;
end;

function LrEmitCb(Ctx: Pointer; Src, Dst, Len: QWord): LongInt; cdecl;
var
  C: PLrCollect;
begin
  C := PLrCollect(Ctx);
  try
    if C^.Count >= Length(C^.Matches) then
      SetLength(C^.Matches, 2 * Length(C^.Matches) + 1024);
    C^.Matches[C^.Count].Src := Src;
    C^.Matches[C^.Count].Dst := Dst;
    C^.Matches[C^.Count].Len := Len;
    Inc(C^.Count);
    Result := 0;
  except
    Result := 1;
  end;
end;
{$endif}

{$ifndef OSREP_NO_NATIVE}
const
  { -m6 pieces: the hashes of a piece are worked out on one thread }
  LrPieceSize = 256 shl 10;

type
  { one piece of the input for steps 1 and 2 of osrep_lr.c }
  TLrJob = class
    Phase: Integer;     { 1: the indexed windows; 2: the positions }
    Data: PByte;        { the bytes from position Lo on: Own, or the input }
    Own: TBytes;
    Lo, Hi, Len: QWord; { positions [Lo, Hi), Len bytes at Data }
    Win, Step, FBits: LongWord;
    Filter: PByte;
    M: array of QWord;
    MCount: QWord;
    Recs: array of QWord;  { pairs (position, hash), osrep_lr_scan }
    RecCount: QWord;
    ErrorMsg: string;
    procedure Run;
  end;


procedure TLrJob.Run;
var
  Q, Ns, Got, Next, Need: QWord;
begin
  try
    if Phase = 1 then
    begin
      Need := Len div Step + 1;
      if QWord(Length(M)) < Need then
        SetLength(M, SizeInt(Need));
      MCount := OsrepLrIndex(Data, Len, Win, Step, @M[0]);
    end
    else
    begin
      RecCount := 0;
      Q := Lo;
      while Q < Hi do
      begin
        Ns := ((Q + Step - 1) div Step) * Step;
        if QWord(Length(Recs)) < 2 * RecCount + 2 then
          SetLength(Recs, 2 * Length(Recs) + 2048);
        Got := OsrepLrScan(Data + (Q - Lo), Q, Hi, Ns, Win, Step, Filter,
          FBits, @Recs[2 * RecCount], QWord(Length(Recs)) div 2 - RecCount,
          Next);
        Inc(RecCount, Got);
        Q := Next;
        if Q < Hi then
          SetLength(Recs, 2 * Length(Recs));
      end;
    end;
  except
    on E: Exception do
      ErrorMsg := E.Message;
  end;
end;

type
  { a worker that runs one piece at a time, until it is told to quit.
    Plain RTL threads and events: TThread.WaitFor on the main thread waits
    in steps of CheckSynchronize, which cost more than a piece takes. }
  TLrWorker = class
    Thread: TThreadID;
    Go, Done: PRTLEvent;
    Job: TLrJob;
    Quit: Boolean;
  end;

function LrWorkerFunc(P: Pointer): PtrInt;
var
  W: TLrWorker;
begin
  W := TLrWorker(P);
  repeat
    RTLEventWaitFor(W.Go);
    if W.Quit then
      Break;
    W.Job.Run;
    RTLEventSetEvent(W.Done);
  until False;
  Result := 0;
end;
{$endif}

{ Every long-range match of InStream (osrep_lr.c), in destination order.
  The native finder works out the hashes of every position by pieces, on
  Threads threads (the matches do not depend on how many), then goes
  through the positions that may hold a match in order; it reads the input
  by position through a 32-64 MiB buffer (or uses it in place when it is
  already in memory, or reads it whole when it is no larger than that
  buffer).  The Pascal reference reads it whole and goes through every
  position. }
function LrFindMatches(InStream: TStream; InSize: QWord; MinLen, Win, Step,
  Align: LongWord; Threads: LongInt): TLrMatchArray;
var
  Entries: QWord;
  TBits, FBits: LongWord;
  Table: array of LongWord;
  Filter: TBytes;
  Coll: TLrCollect;
{$ifndef OSREP_NO_NATIVE}
  Params: TLrParams;
  Buf, State: TBytes;
  BufCap, Piece, NPos, NPieces: QWord;
  R: LongInt;
  Jobs: array[0..1] of array of TLrJob;
  Pool: array of TLrWorker;
  Started: array[0..1] of SizeInt;
  Phase: Integer;

  { the pieces K.. into set S, then runs them (on threads if more than one) }
  procedure StartSet(S: Integer; K: QWord);
  var
    J: SizeInt;
    Job: TLrJob;
  begin
    Started[S] := 0;
    while (Started[S] < Length(Jobs[S])) and (K < NPieces) do
    begin
      Job := Jobs[S][Started[S]];
      Job.Phase := Phase;
      Job.Lo := K * Piece;
      Job.Hi := Job.Lo + Piece;
      if Job.Hi > NPos then
        Job.Hi := NPos;
      Job.Len := Job.Hi - Job.Lo + Win - 1;
      if Job.Len > InSize - Job.Lo then
        Job.Len := InSize - Job.Lo;
      if Params.Mem <> nil then
        Job.Data := Params.Mem + Job.Lo
      else
      begin
        if QWord(Length(Job.Own)) < Job.Len then
          SetLength(Job.Own, SizeInt(Piece + Win));
        InStream.Position := Int64(Job.Lo);
        InStream.ReadBuffer(Job.Own[0], SizeInt(Job.Len));
        Job.Data := @Job.Own[0];
      end;
      Job.ErrorMsg := '';
      Inc(Started[S]);
      Inc(K);
    end;
    if Length(Pool) = 0 then
    begin
      for J := 0 to Started[S] - 1 do
        Jobs[S][J].Run;
      Exit;
    end;
    for J := 0 to Started[S] - 1 do
    begin
      Pool[J].Job := Jobs[S][J];
      RTLEventSetEvent(Pool[J].Go);
    end;
  end;

  { waits for the threads of set S }
  procedure WaitSet(S: Integer);
  var
    J: SizeInt;
    Err: string;
  begin
    Err := '';
    if Length(Pool) > 0 then
      for J := 0 to Started[S] - 1 do
        RTLEventWaitFor(Pool[J].Done);
    for J := 0 to Started[S] - 1 do
      if (Err = '') and (Jobs[S][J].ErrorMsg <> '') then
        Err := Jobs[S][J].ErrorMsg;
    if Err <> '' then
      raise EOsrepError.Create(2, '-m6: ' + Err);
  end;

  { hands the pieces of set S on, in order }
  procedure TakeSet(S: Integer);
  var
    J: SizeInt;
  begin
    for J := 0 to Started[S] - 1 do
      if Phase = 1 then
        OsrepLrFilterAdd(@Filter[0], FBits, @Jobs[S][J].M[0],
          Jobs[S][J].MCount)
      else
      begin
        R := OsrepLrFeed(@State[0], @Jobs[S][J].Recs[0], Jobs[S][J].RecCount);
        if R < 0 then
          raise EOsrepError.Create(2, '-m6: long-range finder failed (' +
            IntToStr(R) + ')');
      end;
    Started[S] := 0;
  end;

  procedure RunPhase;
  var
    K: QWord;
    S: Integer;
  begin
    K := 0;
    S := 0;
    StartSet(0, 0);
    Inc(K, QWord(Started[0]));
    while Started[S] > 0 do
    begin
      WaitSet(S);
      { the next set runs while this one is handed on }
      if K < NPieces then
      begin
        StartSet(1 - S, K);
        Inc(K, QWord(Started[1 - S]));
      end;
      TakeSet(S);
      S := 1 - S;
    end;
  end;

var
  T, S: Integer;
  J: SizeInt;
{$else}
  All: TBytes;
  Need: QWord;
  Count: SizeUInt;
{$endif}
begin
  Result := nil;
  if InSize < QWord(MinLen) then
    Exit;
  Entries := InSize div Step + 1;
  if Entries > QWord(High(LongWord)) then
    raise EOsrepError.Create(2, '-m6: input too large for this step');
  TBits := 4;
  while (QWord(1) shl TBits) * 4 < Entries * 2 do
    Inc(TBits);
  { native: a blocked Bloom filter, 16 bits or more a window; the reference
    sets one bit, 8 or more a window }
  FBits := 6;
{$ifndef OSREP_NO_NATIVE}
  while (QWord(1) shl FBits) < Entries * 16 do
    Inc(FBits);
{$else}
  while (QWord(1) shl FBits) < Entries * 8 do
    Inc(FBits);
{$endif}
  { native buckets: 6 u32 (16-bit tags, osrep_lr.c); the reference keeps
    two u32 per entry }
{$ifndef OSREP_NO_NATIVE}
  SetLength(Table, SizeInt((QWord(1) shl TBits) * 6));
{$else}
  SetLength(Table, SizeInt((QWord(1) shl TBits) * 8));
{$endif}
  FillChar(Table[0], Length(Table) * SizeOf(LongWord), 0);
  SetLength(Filter, SizeInt((QWord(1) shl FBits) div 8));
  FillChar(Filter[0], Length(Filter), 0);
  Coll.Stream := InStream;
  Coll.Matches := nil;
  Coll.Count := 0;
{$ifndef OSREP_NO_NATIVE}
  FillChar(Params, SizeOf(Params), 0);
  Params.N := InSize;
  Params.Read := @LrReadCb;
  Params.Emit := @LrEmitCb;
  Params.Ctx := @Coll;
  Params.Table := @Table[0];
  Params.MinLen := MinLen;
  Params.Win := Win;
  Params.Step := Step;
  Params.Align := Align;
  Params.TBits := TBits;
  if InStream is TCustomMemoryStream then
    Params.Mem := PByte(TCustomMemoryStream(InStream).Memory)
  else
  begin
    { 32 MiB; with small windows there are many more candidates, spread
      over the file, and 64 MiB saves reads (silesia -l64: 11.8 s against
      9.1 s, the index already takes 128 MiB there) }
    BufCap := 32 shl 20;
    if Win < 64 then
      BufCap := 64 shl 20;
    { tests force a tiny buffer to run every refill path on small inputs }
    if GetEnvironmentVariable('OSREP_LR_BUF') <> '' then
      BufCap := StrToQWordDef(GetEnvironmentVariable('OSREP_LR_BUF'), BufCap)
    else if InSize <= BufCap then
      BufCap := 0;
    if BufCap = 0 then
    begin
      { an input no larger than the buffer is cheaper to hold whole }
      SetLength(Buf, SizeInt(InSize));
      InStream.Position := 0;
      InStream.ReadBuffer(Buf[0], SizeInt(InSize));
      Params.Mem := @Buf[0];
    end
    else
    begin
      if BufCap < 8 * (QWord(Win) + 1) then
        BufCap := 8 * (QWord(Win) + 1);
      SetLength(Buf, SizeInt(BufCap));
      Params.Buf := @Buf[0];
      Params.BufCap := BufCap;
    end;
  end;
  SetLength(State, SizeInt(OsrepLrStateSize));
  R := OsrepLrBegin(@State[0], @Params);
  if R < 0 then
    raise EOsrepError.Create(2, '-m6: long-range finder failed (' +
      IntToStr(R) + ')');

  { the pieces: a multiple of Step, so each indexed window is in one;
    tests force small pieces to run the piece and buffer paths }
  Piece := LrPieceSize;
  if GetEnvironmentVariable('OSREP_LR_PIECE') <> '' then
    Piece := StrToQWordDef(GetEnvironmentVariable('OSREP_LR_PIECE'), Piece);
  Piece := (Piece div Step) * Step;
  if Piece = 0 then
    Piece := Step;
  NPos := InSize - Win + 1;
  NPieces := (NPos + Piece - 1) div Piece;
  T := Threads;
  if QWord(T) > NPieces then
    T := LongInt(NPieces);
  if T < 1 then
    T := 1;
  for S := 0 to 1 do
  begin
    SetLength(Jobs[S], T);
    for J := 0 to T - 1 do
    begin
      Jobs[S][J] := TLrJob.Create;
      Jobs[S][J].Win := Win;
      Jobs[S][J].Step := Step;
      Jobs[S][J].FBits := FBits;
      Jobs[S][J].Filter := @Filter[0];
    end;
    Started[S] := 0;
  end;
  Pool := nil;
  try
    if T > 1 then
    begin
      SetLength(Pool, T);
      for J := 0 to T - 1 do
        Pool[J] := nil;
      for J := 0 to T - 1 do
      begin
        Pool[J] := TLrWorker.Create;
        Pool[J].Go := RTLEventCreate;
        Pool[J].Done := RTLEventCreate;
        Pool[J].Thread := BeginThread(@LrWorkerFunc, Pointer(Pool[J]));
        if Pool[J].Thread = TThreadID(0) then
          raise EOsrepError.Create(2, '-m6: cannot start a thread');
      end;
    end;
    Phase := 1;
    RunPhase;
    Phase := 2;
    RunPhase;
  finally
    { a worker may still run a piece after an error: Quit is only seen
      once that piece is done }
    for J := 0 to High(Pool) do
      if Pool[J] <> nil then
      begin
        if Pool[J].Thread <> TThreadID(0) then
        begin
          Pool[J].Quit := True;
          RTLEventSetEvent(Pool[J].Go);
          WaitForThreadTerminate(Pool[J].Thread, 0);
          CloseThread(Pool[J].Thread);
        end;
        RTLEventDestroy(Pool[J].Go);
        RTLEventDestroy(Pool[J].Done);
        Pool[J].Free;
      end;
    for S := 0 to 1 do
      for J := 0 to High(Jobs[S]) do
        Jobs[S][J].Free;
  end;
{$else}
  SetLength(All, SizeInt(InSize));
  InStream.Position := 0;
  InStream.ReadBuffer(All[0], SizeInt(InSize));
  Need := InSize div MinLen + 16;
  SetLength(Coll.Matches, SizeInt(Need));
  Count := OsrepLrFind(@All[0], InSize, MinLen, Win, Step, Align,
    @Table[0], TBits, @Filter[0], FBits, @Coll.Matches[0], SizeUInt(Need));
  if Count = High(SizeUInt) then
    raise EOsrepError.Create(2, 'long-range finder capacity is too small');
  Coll.Count := SizeInt(Count);
{$endif}
  SetLength(Coll.Matches, Coll.Count);
  Result := Coll.Matches;
end;

{ Long-range method (-m6): one global pass over the whole input finds every
  repeat of at least MinMatch bytes (osrep_lr.c).  Writes format v7
  (spec/format-v7.md): the whole match table first, in destination order
  and in three varint columns, then blocks that hold only literals.  The
  input is read twice (the finder, then the blocks), so it has to be
  seekable; it is never all in memory. }
procedure EncodeLongRange(InStream, OutStream: TStream;
  const Opt: TEncoderOptions; BSize: QWord; HashId, HashSize: Byte);
var
  InSize, BlockCountQ, BS, BE, PrevEnd, TableSize: QWord;
  Block: TBytes;
  Matches: TLrMatchArray;
  MinLen, Win, Step: LongWord;
  Hdr, Ftr, BlockHdr, Digest, Tab: TBytes;
  BlocksCrc, Crc: LongWord;
  CrcBytes: array[0..3] of Byte;
  K: QWord;
  DI, I, Col: SizeInt;
  Pos, E: QWord;
  TabBuf: TByteBuffer;
  LrThreads: LongInt;
  LitBuf: TBytes;
  LitLen: SizeInt;
begin
  InSize := QWord(InStream.Size);

  MinLen := Opt.MinMatch;
  if MinLen < 32 then
    MinLen := OsrepLrDefaultMinMatch;
  Win := MinLen div 2;
  Step := Win;
  if Opt.Stride > 1 then
    Step := Opt.Stride;

  { threads for the finder's hashes: -t, or as many as the CPUs, up to 8 }
  LrThreads := Opt.Threads;
  if LrThreads <= 0 then
  begin
    LrThreads := OsrepCpuCount;
    if LrThreads > 8 then
      LrThreads := 8;
  end;
  if LrThreads < 1 then
    LrThreads := 1;
  if LrThreads > 64 then
    LrThreads := 64;
  Matches := LrFindMatches(InStream, InSize, MinLen, Win, Step, Opt.Align,
    LrThreads);

  if InSize = 0 then
    BlockCountQ := 0
  else
    BlockCountQ := (InSize + BSize - 1) div BSize;
  if BlockCountQ > QWord(High(LongWord)) then
    raise EOsrepError.Create(2, 'too many blocks');

  SetLength(Hdr, OsrepHeaderSize);
  PutU32LE(Hdr, 0, OsrepMagicHeaderV7);
  Hdr[4] := OsrepVersionV7;
  Hdr[5] := 0;
  Hdr[6] := HashId;
  Hdr[7] := HashSize;
  PutU32LE(Hdr, 8, LongWord(BSize));
  PutU32LE(Hdr, 12, LongWord(BlockCountQ));
  PutU64LE(Hdr, 16, InSize);
  PutU32LE(Hdr, 24, Crc32C(Hdr, 0, 24));
  OutStream.WriteBuffer(Hdr[0], Length(Hdr));
  if Opt.UseHash then
    OutStream.WriteBuffer(Opt.Seed[0], 32);

  { the match table: count, then the gap, length and distance columns, each
    a run of LEB128 varints }
  TabBuf.Init;
  for I := 0 to 7 do
    TabBuf.AddByte(Byte(QWord(Length(Matches)) shr (8 * I)));
  for Col := 0 to 2 do
  begin
    PrevEnd := 0;
    for I := 0 to High(Matches) do
    begin
      case Col of
        0: AddVarint(TabBuf, Matches[I].Dst - PrevEnd);
        1: AddVarint(TabBuf, Matches[I].Len);
      else
        AddVarint(TabBuf, Matches[I].Dst - Matches[I].Src);
      end;
      PrevEnd := Matches[I].Dst + Matches[I].Len;
    end;
  end;
  for I := 0 to 3 do
    TabBuf.AddByte(0);
  Tab := TabBuf.Finish;
  TableSize := QWord(Length(Tab));
  PutU32LE(Tab, SizeInt(TableSize) - 4, Crc32C(Tab, 0, SizeInt(TableSize) - 4));
  OutStream.WriteBuffer(Tab[0], Length(Tab));
  Tab := nil;

  InStream.Position := 0;
  if BlockCountQ > 0 then
  begin
    if BSize > InSize then
      SetLength(Block, SizeInt(InSize))
    else
      SetLength(Block, SizeInt(BSize));
    SetLength(LitBuf, Length(Block));
  end;
  BlocksCrc := 0;
  DI := 0;
  K := 0;
  while K < BlockCountQ do
  begin
    BS := K * BSize;
    Inc(K);
    BE := BS + BSize;
    if BE > InSize then
      BE := InSize;
    InStream.ReadBuffer(Block[0], SizeInt(BE - BS));
    { literals: the bytes of this block no match destination covers, into
      one buffer for every block (a block's literals fit in a block) }
    LitLen := 0;
    Pos := BS;
    if (DI > 0) and (Matches[DI - 1].Dst + Matches[DI - 1].Len > Pos) then
      Pos := Matches[DI - 1].Dst + Matches[DI - 1].Len;
    if Pos > BE then
      Pos := BE;
    while (DI < Length(Matches)) and (Matches[DI].Dst < BE) do
    begin
      if Matches[DI].Dst > Pos then
      begin
        Move(Block[SizeInt(Pos - BS)], LitBuf[LitLen],
          SizeInt(Matches[DI].Dst - Pos));
        Inc(LitLen, SizeInt(Matches[DI].Dst - Pos));
      end;
      E := Matches[DI].Dst + Matches[DI].Len;
      if E > Pos then
        Pos := E;
      Inc(DI);
    end;
    if Pos > BE then
      Pos := BE;
    if Pos < BE then
    begin
      Move(Block[SizeInt(Pos - BS)], LitBuf[LitLen], SizeInt(BE - Pos));
      Inc(LitLen, SizeInt(BE - Pos));
    end;

    Digest := nil;
    if Opt.UseHash then
      if not Vhash128(Opt.Seed, Block, 0, SizeInt(BE - BS), Digest) then
        raise EOsrepError.Create(3, 'encoder: VHASH failed');
    { the payload is the digest, then the literals; its CRC goes in the
      block header before it }
    Crc := 0;
    if Length(Digest) > 0 then
      Crc := Crc32CUpdate(Crc, Digest[0], PtrUInt(Length(Digest)));
    if LitLen > 0 then
      Crc := Crc32CUpdate(Crc, LitBuf[0], PtrUInt(LitLen));
    SetLength(BlockHdr, OsrepBlockHeaderSize);
    PutU32LE(BlockHdr, 0, LongWord(LitLen));
    PutU32LE(BlockHdr, 4, LongWord(BE - BS));
    PutU32LE(BlockHdr, 8, 0);
    PutU32LE(BlockHdr, 12, Crc);
    OutStream.WriteBuffer(BlockHdr[0], Length(BlockHdr));
    if Length(Digest) > 0 then
      OutStream.WriteBuffer(Digest[0], Length(Digest));
    if LitLen > 0 then
      OutStream.WriteBuffer(LitBuf[0], LitLen);
    PutU32LE(CrcBytes, 0, Crc);
    BlocksCrc := Crc32CUpdate(BlocksCrc, CrcBytes[0], 4);
  end;

  SetLength(Ftr, OsrepFooterSize);
  PutU32LE(Ftr, 0, OsrepMagicFooter);
  PutU32LE(Ftr, 4, LongWord(BlockCountQ));
  PutU64LE(Ftr, 8, TableSize);
  PutU64LE(Ftr, 16, 0);
  PutU32LE(Ftr, 24, 0);
  PutU32LE(Ftr, 28, BlocksCrc);
  PutU32LE(Ftr, 32, Crc32C(Ftr, 0, 32));
  OutStream.WriteBuffer(Ftr[0], Length(Ftr));
end;

procedure EncodeToStream(InStream, OutStream: TStream;
  const Opt: TEncoderOptions; const Meta: TBytes);
var
  InSize, BlockStartQ, BlockLenQ: QWord;
  BlockCountQ: QWord;
  Hdr, Ftr: TBytes;
  BlocksCrc: LongWord;
  CrcBytes: array[0..3] of Byte;
  Data: TBytes;
  BlockHdr: TBytes;
  BlockIndex: QWord;
  HashId, HashSize: Byte;
  StatSize: QWord;
  ThreadCount, BudgetThreads, BatchCount, J: SizeInt;
  MetaOffset: QWord;
  { the bytes written so far: the meta offset, without OutStream.Position
    (0 on a pipe, and not the archive's start on a stream given at an
    offset) }
  Written: QWord;
  ErrMsg: string;
  Jobs: array of TEncodeJob;
  Workers: array of TEncodeThread;
  BSize: QWord;
  JobOpt: TEncoderOptions;
begin
  if Opt.BlockSize = 0 then
    raise EOsrepError.Create(2, 'block size must be positive');
  if Opt.BlockSize > QWord(High(LongWord)) then
    raise EOsrepError.Create(2, 'block size does not fit in v6');
  if Opt.BlockSize > QWord(High(LongInt)) then
    raise EOsrepError.Create(2, 'block size is too large for this encoder');
  if Opt.UseHash and (Length(Opt.Seed) <> 32) then
    raise EOsrepError.Create(2, 'VHASH seed must be 32 bytes');
  if Opt.UseHash then
  begin
    HashId := 4;
    HashSize := 16;
  end
  else
  begin
    HashId := 1;
    HashSize := 0;
  end;

  if Opt.Method = 6 then
  begin
    if Length(Meta) > 0 then
      raise EOsrepError.Create(2, '-m6 does not combine with -dup');
    EncodeLongRange(InStream, OutStream, Opt, Opt.BlockSize, HashId, HashSize);
    Exit;
  end;

  ThreadCount := Opt.Threads;
  if ThreadCount <= 0 then
  begin
    ThreadCount := OsrepCpuCount;
    if ThreadCount > 8 then
      ThreadCount := 8;
  end;
  if ThreadCount < 1 then
    ThreadCount := 1;
  if ThreadCount > 64 then
    ThreadCount := 64;

  { With an explicit -mem, pick the block size from the budget so the choice
    does not depend on the machine: when -t is auto, size for the maximum
    automatic count (8), then cap the actual threads. }
  BSize := Opt.BlockSize;
  { The budget models the LZ tables (Prev, matches, head); the stored/dedup
    methods allocate none of them, and dedup buffers the whole input anyway. }
  if (Opt.MemLimit > 0) and (Opt.Method >= 3) then
  begin
    { Size the block for the maximum automatic thread count (8) so the
      archive does not depend on -t or on the machine; -t then only caps the
      workers that actually run. }
    BSize := HighestPowerOfTwo(Opt.BlockSize);
    while (BSize > OsrepMinBlockSize) and
          (EstimateEncoderBytes(BSize, 8) > Opt.MemLimit) do
      BSize := BSize div 2;
    if EstimateEncoderBytes(BSize, 1) > Opt.MemLimit then
      raise EOsrepError.Create(2, 'memory budget is too small');
    BudgetThreads := SizeInt((Opt.MemLimit - OsrepEncoderBaseBytes) div
      EncoderThreadBytes(BSize));
    if BudgetThreads < 1 then
      BudgetThreads := 1;
    if ThreadCount > BudgetThreads then
      ThreadCount := BudgetThreads;
  end;

  InSize := QWord(InStream.Size);
  if InSize = 0 then
    BlockCountQ := 0
  else
    BlockCountQ := (InSize + BSize - 1) div BSize;
  if BlockCountQ > QWord(High(LongWord)) then
    raise EOsrepError.Create(2, 'too many blocks');

  SetLength(Hdr, OsrepHeaderSize);
  PutU32LE(Hdr, 0, OsrepMagicHeader);
  Hdr[4] := OsrepVersion;
  if Length(Meta) > 0 then
    Hdr[5] := 1
  else
    Hdr[5] := 0;
  Hdr[6] := HashId;
  Hdr[7] := HashSize;
  PutU32LE(Hdr, 8, LongWord(BSize));
  PutU32LE(Hdr, 12, LongWord(BlockCountQ));
  PutU64LE(Hdr, 16, InSize);
  PutU32LE(Hdr, 24, Crc32C(Hdr, 0, 24));
  OutStream.WriteBuffer(Hdr[0], Length(Hdr));
  Written := QWord(Length(Hdr));
  if Opt.UseHash then
  begin
    OutStream.WriteBuffer(Opt.Seed[0], 32);
    Inc(Written, 32);
  end;

  BlocksCrc := 0;
  StatSize := 0;
  BlockStartQ := 0;
  BlockIndex := 0;
  { a single block has nothing to overlap, and tiny inputs are not worth a
    thread creation }
  if (BlockCountQ <= 1) or (InSize < BSize) then
    ThreadCount := 1;
  JobOpt := Opt;
  JobOpt.BlockSize := BSize;
  while BlockIndex < BlockCountQ do
  begin
    BatchCount := ThreadCount;
    if QWord(BatchCount) > BlockCountQ - BlockIndex then
      BatchCount := SizeInt(BlockCountQ - BlockIndex);
    SetLength(Jobs, BatchCount);
    SetLength(Workers, BatchCount);
    for J := 0 to BatchCount - 1 do
    begin
      BlockLenQ := BSize;
      if BlockStartQ + BlockLenQ > InSize then
        BlockLenQ := InSize - BlockStartQ;
      SetLength(Data, SizeInt(BlockLenQ));
      if BlockLenQ > 0 then
        InStream.ReadBuffer(Data[0], SizeInt(BlockLenQ));
      Jobs[J] := TEncodeJob.Create;
      Jobs[J].Data := Data;
      Data := nil;
      Jobs[J].Opt := JobOpt;
      Workers[J] := nil;
      if ThreadCount > 1 then
      begin
        Workers[J] := TEncodeThread.Create(True);
        Workers[J].Job := Jobs[J];
        Workers[J].Start;
      end
      else
        Jobs[J].EncodeOne;
      Inc(BlockStartQ, BlockLenQ);
      Inc(BlockIndex);
    end;

    ErrMsg := '';
    for J := 0 to BatchCount - 1 do
    begin
      if Workers[J] <> nil then
      begin
        Workers[J].WaitFor;
        Workers[J].Free;
      end;
      if (ErrMsg = '') and (Jobs[J].ErrorMsg <> '') then
        ErrMsg := Jobs[J].ErrorMsg;
    end;
    if ErrMsg <> '' then
    begin
      for J := 0 to BatchCount - 1 do
        Jobs[J].Free;
      raise EOsrepError.Create(2, ErrMsg);
    end;

    for J := 0 to BatchCount - 1 do
    begin
      SetLength(BlockHdr, OsrepBlockHeaderSize);
      PutU32LE(BlockHdr, 0, Jobs[J].LiteralSize);
      PutU32LE(BlockHdr, 4, Jobs[J].OrigSize);
      PutU32LE(BlockHdr, 8, Jobs[J].RecordsSize);
      PutU32LE(BlockHdr, 12, Jobs[J].BlockCrc);
      OutStream.WriteBuffer(BlockHdr[0], Length(BlockHdr));
      if Length(Jobs[J].Payload) > 0 then
        OutStream.WriteBuffer(Jobs[J].Payload[0], Length(Jobs[J].Payload));
      Inc(Written, QWord(Length(BlockHdr)) + QWord(Length(Jobs[J].Payload)));

      PutU32LE(CrcBytes, 0, Jobs[J].BlockCrc);
      BlocksCrc := Crc32CUpdate(BlocksCrc, CrcBytes[0], 4);
      Inc(StatSize, QWord(Jobs[J].RecordsSize));
      Jobs[J].Free;
    end;
    SetLength(Jobs, 0);
    SetLength(Workers, 0);
  end;

  if Length(Meta) > 0 then
  begin
    if QWord(Length(Meta)) > High(LongWord) then
      raise EOsrepError.Create(2, 'dup meta is too large');
    MetaOffset := Written;
    OutStream.WriteBuffer(Meta[0], Length(Meta));
  end
  else
    MetaOffset := 0;

  SetLength(Ftr, OsrepFooterSize);
  PutU32LE(Ftr, 0, OsrepMagicFooter);
  PutU32LE(Ftr, 4, LongWord(BlockCountQ));
  PutU64LE(Ftr, 8, StatSize);
  PutU64LE(Ftr, 16, MetaOffset);
  PutU32LE(Ftr, 24, LongWord(Length(Meta)));
  PutU32LE(Ftr, 28, BlocksCrc);
  PutU32LE(Ftr, 32, Crc32C(Ftr, 0, 32));
  OutStream.WriteBuffer(Ftr[0], Length(Ftr));
end;

end.
