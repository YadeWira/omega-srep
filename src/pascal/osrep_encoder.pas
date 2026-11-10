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
  SysUtils, Classes, osrep_crc, osrep_format, osrep_vhash;

type
  TEncoderOptions = record
    BlockSize: QWord;
    MinMatch: LongWord;
    ChainDepth: LongWord;
    Stride: LongWord;
    Method: LongInt;
    UseHash: Boolean;
    Threads: LongInt;
    Seed: TBytes;
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
  Result.Seed := SeedFromNumber(0);
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
    UseHash16, UseHash8: Boolean;
  begin
    UseHash16 := (Opt.Method >= 4) and (Opt.MinMatch >= 16);
    UseHash8 := (Opt.Method >= 4) and (Opt.MinMatch >= 8) and not UseHash16;
    if UseHash16 then
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
    if UseHash16 then
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
    if (Opt.Method >= 4) and (Opt.MinMatch >= 16) then
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
  if Opt.Method in [1, 2] then
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
  ThreadCount, BatchCount, J: SizeInt;
  MetaOffset: QWord;
  ErrMsg: string;
  Jobs: array of TEncodeJob;
  Workers: array of TEncodeThread;
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

  InSize := QWord(InStream.Size);
  if InSize = 0 then
    BlockCountQ := 0
  else
    BlockCountQ := (InSize + Opt.BlockSize - 1) div Opt.BlockSize;
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
  PutU32LE(Hdr, 8, LongWord(Opt.BlockSize));
  PutU32LE(Hdr, 12, LongWord(BlockCountQ));
  PutU64LE(Hdr, 16, InSize);
  PutU32LE(Hdr, 24, Crc32C(Hdr, 0, 24));
  OutStream.WriteBuffer(Hdr[0], Length(Hdr));
  if Opt.UseHash then
    OutStream.WriteBuffer(Opt.Seed[0], 32);

  BlocksCrc := 0;
  StatSize := 0;
  BlockStartQ := 0;
  BlockIndex := 0;
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
  { a single block has nothing to overlap, and tiny inputs are not worth a
    thread creation }
  if (BlockCountQ <= 1) or (InSize < Opt.BlockSize) then
    ThreadCount := 1;
  while BlockIndex < BlockCountQ do
  begin
    BatchCount := ThreadCount;
    if QWord(BatchCount) > BlockCountQ - BlockIndex then
      BatchCount := SizeInt(BlockCountQ - BlockIndex);
    SetLength(Jobs, BatchCount);
    SetLength(Workers, BatchCount);
    for J := 0 to BatchCount - 1 do
    begin
      BlockLenQ := Opt.BlockSize;
      if BlockStartQ + BlockLenQ > InSize then
        BlockLenQ := InSize - BlockStartQ;
      SetLength(Data, SizeInt(BlockLenQ));
      if BlockLenQ > 0 then
        InStream.ReadBuffer(Data[0], SizeInt(BlockLenQ));
      Jobs[J] := TEncodeJob.Create;
      Jobs[J].Data := Data;
      Data := nil;
      Jobs[J].Opt := Opt;
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
    MetaOffset := QWord(OutStream.Position);
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
