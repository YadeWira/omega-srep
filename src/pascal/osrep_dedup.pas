unit osrep_dedup;
{ Content-defined chunking and the DUPR meta of -dup.

  The chunker is the order-1 CDC used by zpaq: a rolling hash with a
  one-byte predictor, MIN = 64 << 6, MAX = 8128 << 6 and a 1 << 16
  threshold (about 64 KiB average). Only exact duplicates are removed; the
  unique chunks are concatenated in first-appearance order and the meta
  records, in input order, a 0+length for a new chunk or a 1+index for a
  reference. The result is independent of the block size and the thread
  count.

  The body is what the normal v6 encoder compresses; this unit only builds
  the deduplicated body and the DUPR meta. Each call has its own builder,
  so two compressions can run at once. }

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, osrep_crc, osrep_format;

const
  OsrepDupFragment  = 6;
  OsrepDupMinChunk  = 64 shl OsrepDupFragment;
  OsrepDupMaxChunk  = 8128 shl OsrepDupFragment;
  OsrepDupThreshold = 1 shl (22 - OsrepDupFragment);
  OsrepDupFixedAverage = 8192;

type
  TDedupChunker = (dcOrder1, dcFixedWindow);

  TDedupResult = record
    Body: TBytes;
    Meta: TBytes;
    ChunkCount: QWord;
    UniqueCount: QWord;
    OriginalSize: QWord;
  end;

function BuildDedup(const Data: TBytes; Chunker: TDedupChunker;
  out Res: TDedupResult): Boolean;

implementation

{$ifndef OSREP_NO_NATIVE}
{$L osrep_cdc.o}
type
  {$packrecords c}
  TOsrepChunk = record
    Offset: QWord;
    Len: LongWord;
    Hash: QWord;
  end;
  {$packrecords default}

function OsrepCdcFind(Data: Pointer; Len: SizeUInt; Chunker: LongInt;
  OutChunks: Pointer; Cap: SizeUInt): SizeUInt; cdecl;
  external name 'osrep_cdc_find';
{$endif}

type
  TByteBuf = record
    Data: TBytes;
    Len: SizeInt;
    procedure Init;
    procedure Ensure(Cap: SizeInt);
    procedure AddByte(B: Byte);
    procedure AddBytes(const Src; Count: SizeInt);
  end;

  TUnique = record
    Hash: QWord;
    BodyOff: QWord;
    Len: LongWord;
    Index: LongWord;
    Used: Boolean;
  end;

  TDedupBuilder = class
  private
    FBody: TByteBuf;
    FEntries: TByteBuf;
    FTable: array of TUnique;
    FTableMask: SizeInt;
    FUniqueCount: LongWord;
    FChunkCount: QWord;
    procedure InitTable(Size: SizeInt);
    procedure GrowTable;
    function InternChunk(const Data: TBytes; Start: SizeInt; Len: LongWord;
      Hash: QWord; out IsNew: Boolean): LongWord;
    procedure EmitChunkHashed(const Data: TBytes; Start: SizeInt;
      Len: LongWord; Hash: QWord);
    procedure EmitChunk(const Data: TBytes; Start: SizeInt; Len: LongWord);
    procedure BuildPascal(const Data: TBytes; Chunker: TDedupChunker);
{$ifndef OSREP_NO_NATIVE}
    procedure BuildNative(const Data: TBytes; Chunker: TDedupChunker);
{$endif}
  public
    function Build(const Data: TBytes; Chunker: TDedupChunker;
      out Res: TDedupResult): Boolean;
  end;

procedure TByteBuf.Init;
begin
  Data := nil;
  Len := 0;
end;

procedure TByteBuf.Ensure(Cap: SizeInt);
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

procedure TByteBuf.AddByte(B: Byte);
begin
  Ensure(Len + 1);
  Data[Len] := B;
  Inc(Len);
end;

procedure TByteBuf.AddBytes(const Src; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  Ensure(Len + Count);
  Move(Src, Data[Len], Count);
  Inc(Len, Count);
end;

procedure AddU32LE(var B: TByteBuf; V: LongWord);
begin
  B.AddByte(Byte(V));
  B.AddByte(Byte(V shr 8));
  B.AddByte(Byte(V shr 16));
  B.AddByte(Byte(V shr 24));
end;

procedure AddVarint(var B: TByteBuf; V: QWord);
begin
  while V >= $80 do
  begin
    B.AddByte(Byte(V) or $80);
    V := V shr 7;
  end;
  B.AddByte(Byte(V));
end;

function HashChunk(const Data: TBytes; Start: SizeInt; Len: SizeInt): QWord;
var
  I: SizeInt;
  H: QWord;
begin
  H := QWord($CBF29CE484222325);
  for I := Start to Start + Len - 1 do
  begin
    H := H xor Data[I];
    H := H * QWord($100000001B3);
  end;
  Result := H;
end;

procedure TDedupBuilder.InitTable(Size: SizeInt);
begin
  SetLength(FTable, Size);
  FTableMask := Size - 1;
  FUniqueCount := 0;
end;

procedure TDedupBuilder.GrowTable;
var
  Old: array of TUnique;
  I, Slot: SizeInt;
  E: TUnique;
  NewSize: SizeInt;
begin
  Old := FTable;
  NewSize := Length(FTable) * 2;
  SetLength(FTable, NewSize);
  FTableMask := NewSize - 1;
  for I := 0 to High(FTable) do
    FTable[I].Used := False;
  for I := 0 to High(Old) do
    if Old[I].Used then
    begin
      E := Old[I];
      Slot := SizeInt(E.Hash and QWord(FTableMask));
      while FTable[Slot].Used do
        Slot := (Slot + 1) and FTableMask;
      FTable[Slot] := E;
    end;
end;

function TDedupBuilder.InternChunk(const Data: TBytes; Start: SizeInt;
  Len: LongWord; Hash: QWord; out IsNew: Boolean): LongWord;
var
  Slot: SizeInt;
  E: TUnique;
begin
  if (QWord(FUniqueCount) + 1) * 2 > QWord(Length(FTable)) then
    GrowTable;
  Slot := SizeInt(Hash and QWord(FTableMask));
  while FTable[Slot].Used do
  begin
    if (FTable[Slot].Hash = Hash) and (FTable[Slot].Len = Len) and
       CompareMem(@Data[Start], @FBody.Data[SizeInt(FTable[Slot].BodyOff)],
         Len) then
    begin
      IsNew := False;
      Exit(FTable[Slot].Index);
    end;
    Slot := (Slot + 1) and FTableMask;
  end;
  IsNew := True;
  E.Hash := Hash;
  E.BodyOff := QWord(FBody.Len);
  E.Len := Len;
  E.Index := FUniqueCount;
  E.Used := True;
  FBody.AddBytes(Data[Start], Len);
  FTable[Slot] := E;
  Result := FUniqueCount;
  Inc(FUniqueCount);
end;

procedure TDedupBuilder.EmitChunkHashed(const Data: TBytes; Start: SizeInt;
  Len: LongWord; Hash: QWord);
var
  Index: LongWord;
  IsNew: Boolean;
begin
  Index := InternChunk(Data, Start, Len, Hash, IsNew);
  if IsNew then
  begin
    FEntries.AddByte(0);
    AddU32LE(FEntries, Len);
  end
  else
  begin
    FEntries.AddByte(1);
    AddVarint(FEntries, Index);
  end;
  Inc(FChunkCount);
end;

procedure TDedupBuilder.EmitChunk(const Data: TBytes; Start: SizeInt;
  Len: LongWord);
begin
  EmitChunkHashed(Data, Start, Len, HashChunk(Data, Start, Len));
end;

procedure TDedupBuilder.BuildPascal(const Data: TBytes;
  Chunker: TDedupChunker);
var
  I, Start, Len: SizeInt;
  C, Pred, C1: Byte;
  O1: array[0..255] of Byte;
  H: LongWord;
  H64, Pow: QWord;
begin
  FillChar(O1, SizeOf(O1), 0);
  C1 := 0;
  H := 0;
  H64 := 0;
  Pow := 1;
  for I := 1 to 48 do
    Pow := Pow * QWord($100000001B3);
  Start := 0;
  Len := 0;
  for I := 0 to Length(Data) - 1 do
  begin
    C := Data[I];
    if Chunker = dcOrder1 then
    begin
      Pred := O1[C1];
      if C = Pred then
        H := (H + LongWord(C) + 1) * LongWord(314159265)
      else
        H := (H + LongWord(C) + 1) * LongWord(271828182);
      O1[C1] := C;
      C1 := C;
      Inc(Len);
      if (Len >= OsrepDupMinChunk) and
         ((H < LongWord(OsrepDupThreshold)) or (Len >= OsrepDupMaxChunk)) then
      begin
        EmitChunk(Data, Start, LongWord(Len));
        Inc(Start, Len);
        Len := 0;
        H := 0;
        C1 := 0;
        FillChar(O1, SizeOf(O1), 0);
      end;
    end
    else
    begin
      H64 := H64 * QWord($100000001B3) + QWord(C);
      if I - Start >= 48 then
        H64 := H64 - QWord(Data[I - 48]) * Pow;
      Inc(Len);
      if (Len >= OsrepDupMinChunk) and
         ((H64 < QWord(High(QWord)) div QWord(OsrepDupFixedAverage)) or
          (Len >= OsrepDupMaxChunk)) then
      begin
        EmitChunk(Data, Start, LongWord(Len));
        Inc(Start, Len);
        Len := 0;
        H64 := 0;
      end;
    end;
  end;
  if Len > 0 then
    EmitChunk(Data, Start, LongWord(Len));
end;

{$ifndef OSREP_NO_NATIVE}
procedure TDedupBuilder.BuildNative(const Data: TBytes;
  Chunker: TDedupChunker);
var
  Chunks: array of TOsrepChunk;
  Cap, N: SizeUInt;
  I: SizeInt;
  P: Pointer;
begin
  Cap := SizeUInt(Length(Data) div OsrepDupMinChunk) + 2;
  SetLength(Chunks, Cap);
  if Length(Data) > 0 then
    P := @Data[0]
  else
    P := nil;
  N := OsrepCdcFind(P, SizeUInt(Length(Data)), Ord(Chunker), @Chunks[0], Cap);
  if N = High(SizeUInt) then
    raise Exception.Create('CDC chunk capacity is too small');
  for I := 0 to SizeInt(N) - 1 do
    EmitChunkHashed(Data, SizeInt(Chunks[I].Offset), Chunks[I].Len,
      Chunks[I].Hash);
end;
{$endif}

function TDedupBuilder.Build(const Data: TBytes; Chunker: TDedupChunker;
  out Res: TDedupResult): Boolean;
begin
  Res.Body := nil;
  Res.Meta := nil;
  Res.ChunkCount := 0;
  Res.UniqueCount := 0;
  Res.OriginalSize := Length(Data);
  FBody.Init;
  FEntries.Init;
  FChunkCount := 0;
  InitTable(1024);
{$ifdef OSREP_NO_NATIVE}
  BuildPascal(Data, Chunker);
{$else}
  BuildNative(Data, Chunker);
{$endif}

  SetLength(Res.Body, FBody.Len);
  if FBody.Len > 0 then
    Move(FBody.Data[0], Res.Body[0], FBody.Len);
  SetLength(Res.Meta, 24 + FEntries.Len + 4);
  PutU32LE(Res.Meta, 0, OsrepMagicMeta);
  PutU32LE(Res.Meta, 4, 1);
  PutU64LE(Res.Meta, 8, FChunkCount);
  PutU64LE(Res.Meta, 16, FUniqueCount);
  if FEntries.Len > 0 then
    Move(FEntries.Data[0], Res.Meta[24], FEntries.Len);
  PutU32LE(Res.Meta, 24 + FEntries.Len,
    Crc32C(Res.Meta, 0, 24 + FEntries.Len));
  Res.ChunkCount := FChunkCount;
  Res.UniqueCount := FUniqueCount;
  Result := True;
end;

function BuildDedup(const Data: TBytes; Chunker: TDedupChunker;
  out Res: TDedupResult): Boolean;
var
  Builder: TDedupBuilder;
begin
  Builder := TDedupBuilder.Create;
  try
    Result := Builder.Build(Data, Chunker, Res);
  finally
    Builder.Free;
  end;
end;

end.
