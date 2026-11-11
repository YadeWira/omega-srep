unit osrep_decoder;
{ v6 archive reader: container validation and block reconstruction.

  The record stream uses the Future-LZ semantics of spec/format-v6.md §2.7:

    record = (skip, length, distance)
    running_skip starts at 0 for each block
    running_skip += skip
    source = block_start + running_skip
    destination = source + distance

  Records are stored in source order.  The decoder sorts all matches of the
  archive by destination, fills the holes with each block's literal stream,
  and only then copies the matches.  A match may point into an earlier block
  and may extend into a later block, so the match queue and the output are
  global (not per block). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, osrep_crc, osrep_format, osrep_vhash;

type
  TBlockMatch = record
    Src: LongWord;
    Dst: LongWord;
    Len: LongWord;
    Seq: LongWord;
  end;
  TBlockMatchArray = array of TBlockMatch;

  TArchiveReader = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FSize: Int64;
    FMaxOutput: QWord;
    FHeader: TArchiveHeader;
    FFooter: TArchiveFooter;
    FSeed: TBytes;
    FDataEnd: Int64;
    FBlocksCrc: LongWord;
    FSumOrig: QWord;
    FSumStat: QWord;
    procedure LoadHeaderFooter;
    procedure ValidateMeta;
    procedure ReadMeta(out Meta: TBytes);
    function DupOutputSize: QWord;
    procedure RestoreDup(const Body: TBytes; out Output: TBytes);
    procedure RestoreDupToStream(const Body: TBytes; OutStream: TStream);
    procedure RestoreDupFileToStream(BodyFile: TStream; BodySize: QWord;
      OutStream: TStream);
    procedure RestoreDupCore(const Body: TBytes; BodyFile: TStream;
      BodySize: QWord; OutStream: TStream; out Output: TBytes);
    function ParseBlockRecordsInto(const BH: TBlockHeader;
      const Payload: TBytes; BlockStart: QWord; Collect: Boolean;
      out Matches: TBlockMatchArray): Boolean;
    function ScanBlockLocality: Boolean;
    procedure DecodeBlocks(OutStream: TStream; out Data: TBytes);
    procedure DecodeStreaming(OutStream: TStream; out Data: TBytes);
    procedure ParseStreamRecords(const BH: TBlockHeader; const Payload: TBytes;
      BlockStart: QWord; Pending: TList);
    procedure VerifyBlocks;
  public
    constructor Create(const AFileName: string);
    constructor CreateFromStream(AStream: TStream; AOwnsStream: Boolean = False);
    destructor Destroy; override;
    procedure ReadInfo(out Info: TArchiveInfo);
    procedure Verify;
    procedure DecodeToStream(OutStream: TStream);
    procedure DecodeToBytes(out Data: TBytes);
    property Header: TArchiveHeader read FHeader;
    property Footer: TArchiveFooter read FFooter;
    { 0 = no extra cap; otherwise the final output may not exceed it. }
    property MaxOutput: QWord read FMaxOutput write FMaxOutput;
  end;

implementation

const
  { Above this body size the CLI restores -dup from a temporary file instead
    of keeping the whole body in RAM. }
  OsrepDupBodyMemoryLimit = QWord(32) * 1024 * 1024;

type
  PMatch = ^TMatch;
  TMatch = record
    Src: QWord;
    Dst: QWord;
    Len: QWord;
  end;

function VerifyBlockDigest(HashId: Byte; const Seed, Data: TBytes;
  Start: QWord; Len: LongWord; const Expected: TBytes): Boolean;
var
  Tag: TBytes;
  I: Integer;
begin
  Result := False;
  if Length(Expected) = 0 then
    Exit(True);
  if HashId = OsrepHashIdDisabled then
    Exit(True);
  if (HashId <> OsrepHashIdVhash) or (Length(Seed) <> OsrepSeedSizeVhash) or
     (Length(Expected) <> OsrepHashSizeVhash) then
    Exit(False);
  if not Vhash128(Seed, Data, SizeUInt(Start), SizeUInt(Len), Tag) then
    Exit(False);
  if Length(Tag) <> Length(Expected) then
    Exit(False);
  for I := 0 to High(Tag) do
    if Tag[I] <> Expected[I] then
      Exit(False);
  Result := True;
end;

function CompareMatches(Item1, Item2: Pointer): Integer;
var
  A, B: PMatch;
begin
  A := PMatch(Item1);
  B := PMatch(Item2);
  if A^.Dst < B^.Dst then
    Result := -1
  else if A^.Dst > B^.Dst then
    Result := 1
  else
    Result := 0;
end;

function ReadVarint(const Buf: TBytes; var Pos: SizeInt; Limit: SizeInt;
  out Value: QWord): Boolean;
var
  B: Byte;
  Shift: Integer;
  Part: QWord;
begin
  Value := 0;
  Shift := 0;
  while Pos < Limit do
  begin
    B := Buf[Pos];
    Inc(Pos);
    if Shift >= 64 then
      Exit(False);
    Part := QWord(B and $7F);
    if (Shift = 63) and (Part > 1) then
      Exit(False);
    Value := Value or (Part shl Shift);
    if (B and $80) = 0 then
      Exit(True);
    Inc(Shift, 7);
  end;
  Result := False;
end;

procedure MarkCovered(var Bits: TBytes; Index: QWord); inline;
begin
  Bits[SizeInt(Index shr 3)] :=
    Bits[SizeInt(Index shr 3)] or Byte(1 shl (Index and 7));
end;

function IsCovered(const Bits: TBytes; Index: QWord): Boolean; inline;
begin
  Result := (Bits[SizeInt(Index shr 3)] and Byte(1 shl (Index and 7))) <> 0;
end;

constructor TArchiveReader.Create(const AFileName: string);
var
  S: TFileStream;
begin
  inherited Create;
  try
    S := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
      raise EOsrepError.Create(3, 'cannot open input: ' + AFileName + ': ' + E.Message);
  end;
  FStream := S;
  FOwnsStream := True;
  FSize := FStream.Size;
end;

constructor TArchiveReader.CreateFromStream(AStream: TStream;
  AOwnsStream: Boolean);
begin
  inherited Create;
  if AStream = nil then
    raise EOsrepError.Create(4, 'nil archive stream');
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FSize := FStream.Size;
end;

destructor TArchiveReader.Destroy;
begin
  if FOwnsStream then
    FreeAndNil(FStream)
  else
    FStream := nil;
  inherited Destroy;
end;

procedure TArchiveReader.LoadHeaderFooter;
var
  Buf: TBytes;
  SeedSize: SizeInt;
  FooterPos: Int64;
  DataStart: Int64;
begin
  if FSize < OsrepHeaderSize + OsrepFooterSize then
    DataError('file is too short to be a v6 archive');

  SetLength(Buf, OsrepHeaderSize);
  FStream.Position := 0;
  ReadExact(FStream, Buf[0], OsrepHeaderSize, 'header');

  if GetU32LE(Buf, 0) <> OsrepMagicHeader then
    DataError('bad magic: not an OSR6 archive');
  FHeader.Version := Buf[4];
  if FHeader.Version <> OsrepVersion then
    DataError(Format('unsupported version %d (expected %d)',
      [FHeader.Version, OsrepVersion]));
  FHeader.Flags := Buf[5];
  if (FHeader.Flags and not 1) <> 0 then
    DataError(Format('unsupported flags byte $%02x', [FHeader.Flags]));
  FHeader.HashId := Buf[6];
  FHeader.HashSize := Buf[7];
  FHeader.MaxMatch := GetU32LE(Buf, 8);
  FHeader.BlockCount := GetU32LE(Buf, 12);
  FHeader.OriginalSize := GetU64LE(Buf, 16);
  FHeader.HeaderCrc := GetU32LE(Buf, 24);
  if Crc32C(Buf, 0, 24) <> FHeader.HeaderCrc then
    DataError('header CRC mismatch');

  if not SeedSizeFor(FHeader.HashId, FHeader.HashSize, SeedSize) then
    DataError(Format('unsupported hash id/size %d/%d',
      [FHeader.HashId, FHeader.HashSize]));
  DataStart := OsrepHeaderSize + SeedSize;
  if FSize < DataStart + OsrepFooterSize then
    DataError('file is too short for header seed and footer');
  SetLength(FSeed, SeedSize);
  if SeedSize > 0 then
  begin
    FStream.Position := OsrepHeaderSize;
    ReadExact(FStream, FSeed[0], SeedSize, 'hash seed');
  end;

  FooterPos := FSize - OsrepFooterSize;
  SetLength(Buf, OsrepFooterSize);
  FStream.Position := FooterPos;
  ReadExact(FStream, Buf[0], OsrepFooterSize, 'footer');
  if GetU32LE(Buf, 0) <> OsrepMagicFooter then
    DataError('bad footer magic');
  FFooter.BlockCount := GetU32LE(Buf, 4);
  FFooter.StatSize := GetU64LE(Buf, 8);
  FFooter.MetaOffset := GetU64LE(Buf, 16);
  FFooter.MetaSize := GetU32LE(Buf, 24);
  FFooter.BlocksCrc := GetU32LE(Buf, 28);
  FFooter.FooterCrc := GetU32LE(Buf, 32);
  if Crc32C(Buf, 0, 32) <> FFooter.FooterCrc then
    DataError('footer CRC mismatch');

  if FHeader.BlockCount <> FFooter.BlockCount then
    DataError(Format('block count mismatch: header %d, footer %d',
      [FHeader.BlockCount, FFooter.BlockCount]));

  if (FHeader.Flags and 1) <> 0 then
  begin
    if (FFooter.MetaOffset = 0) or (FFooter.MetaSize = 0) then
      DataError('dup flag set but footer has no meta');
    if FFooter.MetaOffset < QWord(DataStart) then
      DataError('meta offset points inside the header');
    if FFooter.MetaOffset + QWord(FFooter.MetaSize) <> QWord(FooterPos) then
      DataError('meta does not end at the footer');
    FDataEnd := Int64(FFooter.MetaOffset);
  end
  else
  begin
    if (FFooter.MetaOffset <> 0) or (FFooter.MetaSize <> 0) then
      DataError('footer meta fields set without the dup flag');
    FDataEnd := FooterPos;
  end;

  if FDataEnd < DataStart then
    DataError('block area ends before it starts');
  if QWord(FHeader.BlockCount) * QWord(OsrepBlockHeaderSize) >
     QWord(FDataEnd - DataStart) then
    DataError('block count does not fit in the block area');
end;

procedure TArchiveReader.ReadMeta(out Meta: TBytes);
begin
  Meta := nil;
  if (FHeader.Flags and 1) = 0 then
    Exit;
  if FFooter.MetaSize < OsrepMetaMinSize then
    DataError('dup meta is too short');
  if QWord(FFooter.MetaSize) > QWord(High(SizeInt)) then
    DataError('dup meta is too large');
  SetLength(Meta, SizeInt(FFooter.MetaSize));
  FStream.Position := Int64(FFooter.MetaOffset);
  ReadExact(FStream, Meta[0], Length(Meta), 'dup meta');
end;

procedure TArchiveReader.ValidateMeta;
var
  Meta: TBytes;
  Stored, Calculated: LongWord;
begin
  if (FHeader.Flags and 1) = 0 then
    Exit;
  ReadMeta(Meta);
  if GetU32LE(Meta, 0) <> OsrepMagicMeta then
    DataError('dup meta magic is not DUPR');
  if GetU32LE(Meta, 4) <> 1 then
    DataError('unsupported dup meta version');
  Stored := GetU32LE(Meta, Length(Meta) - 4);
  Calculated := Crc32C(Meta, 0, Length(Meta) - 4);
  if Stored <> Calculated then
    DataError('dup meta CRC mismatch');
end;

procedure AppendChunk(var Dest: TBytes; const Src: TBytes;
  SrcOffset, Len: SizeInt);
begin
  if Len <= 0 then
    Exit;
  SetLength(Dest, Length(Dest) + Len);
  Move(Src[SrcOffset], Dest[Length(Dest) - Len], Len);
end;

function TArchiveReader.DupOutputSize: QWord;
var
  Meta: TBytes;
  Pos, MetaEnd: SizeInt;
  ChunkCount, UniqueCount, I: QWord;
  Tag: Byte;
  Len: LongWord;
  Idx: QWord;
  UniqueLens: array of LongWord;
  Total: QWord;
begin
  ReadMeta(Meta);
  if Length(Meta) < 24 + 4 then
    DataError('dup meta is too short');
  if GetU32LE(Meta, 0) <> OsrepMagicMeta then
    DataError('dup meta magic is not DUPR');
  if GetU32LE(Meta, 4) <> 1 then
    DataError('unsupported dup meta version');
  ChunkCount := GetU64LE(Meta, 8);
  UniqueCount := GetU64LE(Meta, 16);
  Pos := 24;
  MetaEnd := Length(Meta) - 4;
  SetLength(UniqueLens, 0);
  Total := 0;
  I := 0;
  while I < ChunkCount do
  begin
    if Pos >= MetaEnd then
      DataError('dup meta is truncated');
    Tag := Meta[Pos];
    Inc(Pos);
    if Tag = 0 then
    begin
      if Pos + 4 > MetaEnd then
        DataError('dup meta has a truncated unique chunk');
      Len := GetU32LE(Meta, Pos);
      Inc(Pos, 4);
      if QWord(Length(UniqueLens)) >= UniqueCount then
        DataError('dup meta has too many unique chunks');
      SetLength(UniqueLens, Length(UniqueLens) + 1);
      UniqueLens[High(UniqueLens)] := Len;
      if Total > High(QWord) - QWord(Len) then
        DataError('dup output size overflows 64 bits');
      Inc(Total, Len);
    end
    else if Tag = 1 then
    begin
      if not ReadVarint(Meta, Pos, MetaEnd, Idx) then
        DataError('dup meta has a bad chunk reference');
      if Idx >= QWord(Length(UniqueLens)) then
        DataError('dup chunk reference points to an undefined chunk');
      if Total > High(QWord) - QWord(UniqueLens[SizeInt(Idx)]) then
        DataError('dup output size overflows 64 bits');
      Inc(Total, UniqueLens[SizeInt(Idx)]);
    end
    else
      DataError(Format('unknown dup chunk tag %d', [Tag]));
    Inc(I);
  end;
  if Pos <> MetaEnd then
    DataError('dup meta has trailing bytes');
  if QWord(Length(UniqueLens)) <> UniqueCount then
    DataError('dup unique chunk count mismatch');
  Result := Total;
end;

procedure TArchiveReader.RestoreDupCore(const Body: TBytes; BodyFile: TStream;
  BodySize: QWord; OutStream: TStream; out Output: TBytes);
var
  Meta: TBytes;
  Pos, MetaEnd, UCount: SizeInt;
  ChunkCount, UniqueCount, I, BodyPos, OutPos: QWord;
  Tag: Byte;
  Len: LongWord;
  Idx: QWord;
  UniqueOff: array of QWord;
  UniqueLen: array of LongWord;
  Total: QWord;
  ChunkBuf: TBytes;

  procedure EmitSlice(Off: QWord; Len: LongWord);
  begin
    if Len = 0 then
      Exit;
    if BodyFile <> nil then
    begin
      if QWord(Length(ChunkBuf)) < QWord(Len) then
        SetLength(ChunkBuf, SizeInt(Len));
      BodyFile.Position := Int64(Off);
      BodyFile.ReadBuffer(ChunkBuf[0], Len);
      if OutStream <> nil then
        OutStream.WriteBuffer(ChunkBuf[0], Len)
      else
        Move(ChunkBuf[0], Output[SizeInt(OutPos)], Len);
    end
    else if OutStream <> nil then
      OutStream.WriteBuffer(Body[SizeInt(Off)], Len)
    else
      Move(Body[SizeInt(Off)], Output[SizeInt(OutPos)], Len);
    Inc(OutPos, QWord(Len));
  end;

begin
  Output := nil;
  ReadMeta(Meta);
  if Length(Meta) < 24 + 4 then
    DataError('dup meta is too short');
  if GetU32LE(Meta, 0) <> OsrepMagicMeta then
    DataError('dup meta magic is not DUPR');
  if GetU32LE(Meta, 4) <> 1 then
    DataError('unsupported dup meta version');
  ChunkCount := GetU64LE(Meta, 8);
  UniqueCount := GetU64LE(Meta, 16);
  if UniqueCount > QWord(High(SizeInt)) then
    DataError('dup meta has too many unique chunks');
  Total := DupOutputSize;
  if (FMaxOutput > 0) and (Total > FMaxOutput) then
    raise EOsrepError.Create(6, 'dup output exceeds max_output');
  if OutStream = nil then
  begin
    if Total > QWord(High(SizeInt)) then
      DataError('dup output does not fit in memory');
    SetLength(Output, SizeInt(Total));
  end;

  SetLength(UniqueOff, SizeInt(UniqueCount));
  SetLength(UniqueLen, SizeInt(UniqueCount));
  Pos := 24;
  MetaEnd := Length(Meta) - 4;
  BodyPos := 0;
  OutPos := 0;
  UCount := 0;

  I := 0;
  while I < ChunkCount do
  begin
    if Pos >= MetaEnd then
      DataError('dup meta is truncated');
    Tag := Meta[Pos];
    Inc(Pos);
    if Tag = 0 then
    begin
      if Pos + 4 > MetaEnd then
        DataError('dup meta has a truncated unique chunk');
      Len := GetU32LE(Meta, Pos);
      Inc(Pos, 4);
      if BodyPos + QWord(Len) > BodySize then
        DataError('dup body is shorter than its unique chunks');
      if OutPos + QWord(Len) > Total then
        DataError('dup output is longer than its meta');
      if UCount >= SizeInt(UniqueCount) then
        DataError('dup meta has too many unique chunks');
      { unique chunks are a slice of the body; keep the offset, not a copy }
      UniqueOff[UCount] := BodyPos;
      UniqueLen[UCount] := Len;
      EmitSlice(BodyPos, Len);
      Inc(BodyPos, QWord(Len));
      Inc(UCount);
    end
    else if Tag = 1 then
    begin
      if not ReadVarint(Meta, Pos, MetaEnd, Idx) then
        DataError('dup meta has a bad chunk reference');
      if Idx >= QWord(UCount) then
        DataError('dup chunk reference points to an undefined chunk');
      Len := UniqueLen[SizeInt(Idx)];
      if OutPos + QWord(Len) > Total then
        DataError('dup output is longer than its meta');
      EmitSlice(UniqueOff[SizeInt(Idx)], Len);
    end
    else
      DataError(Format('unknown dup chunk tag %d', [Tag]));
    Inc(I);
  end;

  if Pos <> MetaEnd then
    DataError('dup meta has trailing bytes');
  if BodyPos <> BodySize then
    DataError('dup body has trailing bytes');
  if QWord(UCount) <> UniqueCount then
    DataError('dup unique chunk count mismatch');
  if OutPos <> Total then
    DataError('dup output is shorter than its meta');
end;

procedure TArchiveReader.RestoreDup(const Body: TBytes; out Output: TBytes);
begin
  RestoreDupCore(Body, nil, QWord(Length(Body)), nil, Output);
end;

procedure TArchiveReader.RestoreDupToStream(const Body: TBytes;
  OutStream: TStream);
var
  Dummy: TBytes;
begin
  RestoreDupCore(Body, nil, QWord(Length(Body)), OutStream, Dummy);
end;

procedure TArchiveReader.RestoreDupFileToStream(BodyFile: TStream;
  BodySize: QWord; OutStream: TStream);
var
  Dummy: TBytes;
begin
  RestoreDupCore(nil, BodyFile, BodySize, OutStream, Dummy);
end;

procedure SortBlockMatches(var A: TBlockMatchArray);
var
  Tmp: TBlockMatchArray;

  procedure Merge(Lo, Mid, Hi: SizeInt);
  var
    I, J, K: SizeInt;
  begin
    I := Lo;
    J := Mid + 1;
    K := Lo;
    while (I <= Mid) and (J <= Hi) do
    begin
      { stable by destination: equal destinations keep the record order. }
      if (A[I].Dst < A[J].Dst) or
         ((A[I].Dst = A[J].Dst) and (A[I].Seq <= A[J].Seq)) then
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
    while I <= Mid do
    begin
      Tmp[K] := A[I];
      Inc(I);
      Inc(K);
    end;
    while J <= Hi do
    begin
      Tmp[K] := A[J];
      Inc(J);
      Inc(K);
    end;
    for K := Lo to Hi do
      A[K] := Tmp[K];
  end;

  procedure MergeSort(Lo, Hi: SizeInt);
  var
    Mid: SizeInt;
  begin
    if Lo >= Hi then
      Exit;
    Mid := Lo + (Hi - Lo) div 2;
    MergeSort(Lo, Mid);
    MergeSort(Mid + 1, Hi);
    Merge(Lo, Mid, Hi);
  end;

begin
  if Length(A) < 2 then
    Exit;
  SetLength(Tmp, Length(A));
  MergeSort(0, High(A));
end;

{ Parses one block's record stream.  Returns False when any match leaves its
  own block (the cross-block Future-LZ case); the caller then uses the global
  decoder.  With Collect=True the relative matches are stored for the
  block-wise decoder. }
function TArchiveReader.ParseBlockRecordsInto(const BH: TBlockHeader;
  const Payload: TBytes; BlockStart: QWord; Collect: Boolean;
  out Matches: TBlockMatchArray): Boolean;
var
  HashSize, RecStart, RecEnd, LitStart, LitEnd: SizeInt;
  P: SizeInt;
  RunningSkip, Src, Dst, Skip, Len, Dist, BlockEnd: QWord;
  Count, RecIndex: SizeInt;
begin
  Matches := nil;
  HashSize := FHeader.HashSize;
  if QWord(HashSize) + QWord(BH.StatSize) + QWord(BH.LiteralBytes) <>
     QWord(Length(Payload)) then
    DataError('block payload size mismatch');
  RecStart := HashSize;
  RecEnd := RecStart + SizeInt(BH.StatSize);
  LitStart := RecEnd;
  LitEnd := LitStart + SizeInt(BH.LiteralBytes);
  if LitEnd <> Length(Payload) then
    DataError('block literal range does not match the payload');

  BlockEnd := BlockStart + QWord(BH.OrigSize);
  if BlockEnd > FHeader.OriginalSize then
    DataError('block extends past the original data');

  Result := True;
  Count := 0;
  RecIndex := 0;
  RunningSkip := 0;
  P := RecStart;
  while P < RecEnd do
  begin
    if not ReadVarint(Payload, P, RecEnd, Skip) then
      DataError('bad skip varint in block records');
    if not ReadVarint(Payload, P, RecEnd, Len) then
      DataError('bad match length varint in block records');
    if not ReadVarint(Payload, P, RecEnd, Dist) then
      DataError('bad distance varint in block records');

    if (Len = 0) or (Dist = 0) then
      DataError('zero match length or distance');
    if Skip > High(QWord) - RunningSkip then
      DataError('match source overflows 64 bits');
    Inc(RunningSkip, Skip);
    if RunningSkip > High(QWord) - BlockStart then
      DataError('match source overflows the output position');
    Src := BlockStart + RunningSkip;
    if Src >= FHeader.OriginalSize then
      DataError('match source is outside the original data');
    if Dist > High(QWord) - Src then
      DataError('match destination overflows 64 bits');
    Dst := Src + Dist;
    if (Len > High(QWord) - Dst) or
       (Dst + Len > FHeader.OriginalSize) then
      DataError('match destination is outside the original data');
    if Result then
    begin
      if (Src < BlockStart) or (Dst < BlockStart) or
         (Len > BlockEnd - Src) or (Len > BlockEnd - Dst) then
        Result := False;
    end;
    if Result and Collect then
    begin
      if Count = Length(Matches) then
      begin
        if Count = 0 then
          SetLength(Matches, 1024)
        else
          SetLength(Matches, Count * 2);
      end;
      Matches[Count].Src := LongWord(Src - BlockStart);
      Matches[Count].Dst := LongWord(Dst - BlockStart);
      Matches[Count].Len := LongWord(Len);
      Matches[Count].Seq := LongWord(RecIndex);
      Inc(Count);
    end;
    Inc(RecIndex);
  end;
  if P <> RecEnd then
    DataError('records do not end at statsize');
  if Collect then
    SetLength(Matches, Count);
end;

{ First pass: can this archive be decoded one block at a time?  True when
  every match's source and destination stay inside its own block, which is
  what this encoder writes.  Cross-block archives (legacy Omega SREP) take
  the global path instead. }
function TArchiveReader.ScanBlockLocality: Boolean;
var
  I: LongWord;
  Pos: Int64;
  Buf, Payload: TBytes;
  BH: TBlockHeader;
  PayloadLen: QWord;
  BlockStart: QWord;
  Matches: TBlockMatchArray;
begin
  Result := True;
  Pos := OsrepHeaderSize + Length(FSeed);
  BlockStart := 0;
  for I := 1 to FHeader.BlockCount do
  begin
    if Pos + OsrepBlockHeaderSize > FDataEnd then
      DataError(Format('block %d: header past end of block area', [I]));
    FStream.Position := Pos;
    SetLength(Buf, OsrepBlockHeaderSize);
    ReadExact(FStream, Buf[0], OsrepBlockHeaderSize,
      Format('block %d header', [I]));
    Inc(Pos, OsrepBlockHeaderSize);

    BH.LiteralBytes := GetU32LE(Buf, 0);
    BH.OrigSize := GetU32LE(Buf, 4);
    BH.StatSize := GetU32LE(Buf, 8);
    BH.BlockCrc := GetU32LE(Buf, 12);

    if (BH.LiteralBytes = BH.OrigSize) and (BH.StatSize <> 0) then
      DataError(Format('block %d: stored block has records', [I]));
    if (BH.StatSize = 0) and (BH.LiteralBytes <> BH.OrigSize) then
      DataError(Format('block %d: no records but literals do not cover it', [I]));

    PayloadLen := QWord(FHeader.HashSize) + QWord(BH.StatSize) +
      QWord(BH.LiteralBytes);
    if PayloadLen > QWord(FDataEnd - Pos) then
      DataError(Format('block %d: payload past end of block area', [I]));
    if PayloadLen > QWord(High(SizeInt)) then
      DataError(Format('block %d: payload is too large', [I]));
    SetLength(Payload, SizeInt(PayloadLen));
    if PayloadLen > 0 then
      ReadExact(FStream, Payload[0], SizeInt(PayloadLen),
        Format('block %d payload', [I]));
    Inc(Pos, Int64(PayloadLen));

    if not ParseBlockRecordsInto(BH, Payload, BlockStart, False, Matches) then
    begin
      Result := False;
      Exit;
    end;
    Inc(BlockStart, QWord(BH.OrigSize));
  end;
end;

procedure TArchiveReader.DecodeBlocks(OutStream: TStream; out Data: TBytes);
var
  I: LongWord;
  Pos: Int64;
  Buf, Payload, OutBytes, Digest: TBytes;
  BH: TBlockHeader;
  PayloadLen: QWord;
  Crc: LongWord;
  CrcBytes: array[0..3] of Byte;
  BlockStart, SumOrig, SumStat: QWord;
  BlocksCrc: LongWord;
  Matches: TBlockMatchArray;

  procedure DecodeOneBlock;
  var
    N, K, J, LitPos: SizeInt;
    LitStart: SizeInt;
    Covered: TBytes;
    M: TBlockMatch;
  begin
    N := SizeInt(BH.OrigSize);
    SetLength(OutBytes, N);
    SetLength(Covered, (N + 7) div 8);
    if N > 0 then
      FillChar(Covered[0], Length(Covered), 0);

    for J := 0 to High(Matches) do
    begin
      M := Matches[J];
      if M.Len > 0 then
        for K := 0 to SizeInt(M.Len) - 1 do
          MarkCovered(Covered, QWord(M.Dst) + QWord(K));
    end;

    LitStart := SizeInt(FHeader.HashSize) + SizeInt(BH.StatSize);
    LitPos := 0;
    for K := 0 to N - 1 do
      if not IsCovered(Covered, QWord(K)) then
      begin
        if LitPos >= SizeInt(BH.LiteralBytes) then
          DataError(Format('block %d: not enough literal bytes for a block hole', [I]));
        OutBytes[K] := Payload[LitStart + LitPos];
        Inc(LitPos);
      end;
    if LitPos <> SizeInt(BH.LiteralBytes) then
      DataError(Format('block %d: literal bytes left over at the end of a block', [I]));

    { Copy in destination order so overlapping matches see final bytes. }
    SortBlockMatches(Matches);
    for J := 0 to High(Matches) do
    begin
      M := Matches[J];
      if (QWord(M.Src) + QWord(M.Len) > QWord(N)) or
         (QWord(M.Dst) + QWord(M.Len) > QWord(N)) then
        DataError(Format('block %d: match leaves its block', [I]));
      if M.Src >= M.Dst then
        DataError(Format('block %d: match distance is not positive', [I]));
      if QWord(M.Dst) - QWord(M.Src) >= QWord(M.Len) then
        Move(OutBytes[SizeInt(M.Src)], OutBytes[SizeInt(M.Dst)], SizeInt(M.Len))
      else
        for K := 0 to SizeInt(M.Len) - 1 do
          OutBytes[SizeInt(M.Dst) + K] := OutBytes[SizeInt(M.Src) + K];
    end;

    SetLength(Digest, FHeader.HashSize);
    if FHeader.HashSize > 0 then
      Move(Payload[0], Digest[0], FHeader.HashSize);
    if not VerifyBlockDigest(FHeader.HashId, FSeed, OutBytes, 0, BH.OrigSize,
      Digest) then
      DataError(Format('block %d: digest mismatch', [I]));

    if N > 0 then
    begin
      if OutStream <> nil then
        OutStream.WriteBuffer(OutBytes[0], N)
      else
        Move(OutBytes[0], Data[SizeInt(BlockStart)], N);
    end;
  end;

begin
  Data := nil;
  if OutStream = nil then
  begin
    if FHeader.OriginalSize > QWord(High(SizeInt)) then
      DataError('original size does not fit in memory');
    SetLength(Data, SizeInt(FHeader.OriginalSize));
  end;
  FBlocksCrc := 0;
  FSumOrig := 0;
  FSumStat := 0;
  BlocksCrc := 0;
  Pos := OsrepHeaderSize + Length(FSeed);
  BlockStart := 0;
  for I := 1 to FHeader.BlockCount do
  begin
    if Pos + OsrepBlockHeaderSize > FDataEnd then
      DataError(Format('block %d: header past end of block area', [I]));
    FStream.Position := Pos;
    SetLength(Buf, OsrepBlockHeaderSize);
    ReadExact(FStream, Buf[0], OsrepBlockHeaderSize,
      Format('block %d header', [I]));
    Inc(Pos, OsrepBlockHeaderSize);

    BH.LiteralBytes := GetU32LE(Buf, 0);
    BH.OrigSize := GetU32LE(Buf, 4);
    BH.StatSize := GetU32LE(Buf, 8);
    BH.BlockCrc := GetU32LE(Buf, 12);

    if (BH.LiteralBytes = BH.OrigSize) and (BH.StatSize <> 0) then
      DataError(Format('block %d: stored block has records', [I]));
    if (BH.StatSize = 0) and (BH.LiteralBytes <> BH.OrigSize) then
      DataError(Format('block %d: no records but literals do not cover it', [I]));

    PayloadLen := QWord(FHeader.HashSize) + QWord(BH.StatSize) +
      QWord(BH.LiteralBytes);
    if PayloadLen > QWord(FDataEnd - Pos) then
      DataError(Format('block %d: payload past end of block area', [I]));
    if PayloadLen > QWord(High(SizeInt)) then
      DataError(Format('block %d: payload is too large', [I]));
    SetLength(Payload, SizeInt(PayloadLen));
    if PayloadLen > 0 then
      ReadExact(FStream, Payload[0], SizeInt(PayloadLen),
        Format('block %d payload', [I]));
    Inc(Pos, Int64(PayloadLen));

    Crc := Crc32C(Payload);
    if Crc <> BH.BlockCrc then
      DataError(Format('block %d: CRC mismatch', [I]));

    PutU32LE(CrcBytes, 0, BH.BlockCrc);
    BlocksCrc := Crc32CUpdate(BlocksCrc, CrcBytes[0], 4);

    if (FMaxOutput > 0) and
       (BlockStart + QWord(BH.OrigSize) > FMaxOutput) then
      raise EOsrepError.Create(6, 'original size exceeds max_output');

    if not ParseBlockRecordsInto(BH, Payload, BlockStart, True, Matches) then
      DataError(Format('block %d: cross-block match after the locality scan',
        [I]));
    DecodeOneBlock;

    Inc(BlockStart, QWord(BH.OrigSize));
    Inc(FSumOrig, QWord(BH.OrigSize));
    Inc(FSumStat, QWord(BH.StatSize));
  end;

  if Pos <> FDataEnd then
    DataError('there is data between the last block and the footer/meta');
  ValidateMeta;
  if FSumOrig <> FHeader.OriginalSize then
    DataError(Format('original size mismatch: header %d, blocks %d',
      [FHeader.OriginalSize, FSumOrig]));
  if FSumStat <> FFooter.StatSize then
    DataError(Format('stat size mismatch: footer %d, blocks %d',
      [FFooter.StatSize, FSumStat]));
  if BlocksCrc <> FFooter.BlocksCrc then
    DataError('blocks CRC mismatch');
  FBlocksCrc := BlocksCrc;
end;

{ General Future-LZ decoder: produce the output in position order keeping a
  sliding window of bytes that pending matches still need.  Used when matches
  cross block boundaries; block-local archives take the cheaper path. }
procedure TArchiveReader.DecodeStreaming(OutStream: TStream; out Data: TBytes);
var
  I: LongWord;
  Pos: Int64;
  Buf, Payload, Digest: TBytes;
  BH: TBlockHeader;
  PayloadLen: QWord;
  Crc: LongWord;
  CrcBytes: array[0..3] of Byte;
  BlockStart, SumOrig, SumStat: QWord;
  BlocksCrc: LongWord;
  Pending: TList;
  Active: array of PMatch;
  Win: TBytes;
  WinBase, WinLen, P, RunEnd, SrcAbs: QWord;
  J, K, A, L, Run, LitPos, LitStart, SrcOff, DstOff: SizeInt;
  M: PMatch;

  procedure FreePending;
  var
    Q: SizeInt;
  begin
    if Pending = nil then
      Exit;
    for Q := 0 to Pending.Count - 1 do
      Dispose(PMatch(Pending[Q]));
    Pending.Free;
    Pending := nil;
  end;

  procedure CompactWindow;
  var
    MinSrc, NeedPos, Cand: QWord;
    Shift: QWord;
    Q: SizeInt;
  begin
    MinSrc := BlockStart;
    for Q := 0 to Pending.Count - 1 do
    begin
      M := PMatch(Pending[Q]);
      if M^.Dst + M^.Len <= BlockStart then
        Continue;
      NeedPos := BlockStart;
      if M^.Dst > NeedPos then
        NeedPos := M^.Dst;
      Cand := M^.Src + (NeedPos - M^.Dst);
      if Cand < MinSrc then
        MinSrc := Cand;
    end;
    if MinSrc < WinBase then
      MinSrc := WinBase;
    if MinSrc > WinBase then
    begin
      Shift := MinSrc - WinBase;
      if Shift >= WinLen then
      begin
        WinBase := MinSrc;
        WinLen := 0;
      end
      else
      begin
        Move(Win[SizeInt(Shift)], Win[0], SizeInt(WinLen - Shift));
        Dec(WinLen, Shift);
        Inc(WinBase, Shift);
      end;
    end;
  end;

begin
  Data := nil;
  if OutStream = nil then
  begin
    if FHeader.OriginalSize > QWord(High(SizeInt)) then
      DataError('original size does not fit in memory');
    SetLength(Data, SizeInt(FHeader.OriginalSize));
  end;

  FBlocksCrc := 0;
  FSumOrig := 0;
  FSumStat := 0;
  BlocksCrc := 0;
  Pending := TList.Create;
  Win := nil;
  WinBase := 0;
  WinLen := 0;
  Pos := OsrepHeaderSize + Length(FSeed);
  BlockStart := 0;
  try
    for I := 1 to FHeader.BlockCount do
    begin
      if Pos + OsrepBlockHeaderSize > FDataEnd then
        DataError(Format('block %d: header past end of block area', [I]));
      FStream.Position := Pos;
      SetLength(Buf, OsrepBlockHeaderSize);
      ReadExact(FStream, Buf[0], OsrepBlockHeaderSize,
        Format('block %d header', [I]));
      Inc(Pos, OsrepBlockHeaderSize);

      BH.LiteralBytes := GetU32LE(Buf, 0);
      BH.OrigSize := GetU32LE(Buf, 4);
      BH.StatSize := GetU32LE(Buf, 8);
      BH.BlockCrc := GetU32LE(Buf, 12);

      if (BH.LiteralBytes = BH.OrigSize) and (BH.StatSize <> 0) then
        DataError(Format('block %d: stored block has records', [I]));
      if (BH.StatSize = 0) and (BH.LiteralBytes <> BH.OrigSize) then
        DataError(Format('block %d: no records but literals do not cover it',
          [I]));

      PayloadLen := QWord(FHeader.HashSize) + QWord(BH.StatSize) +
        QWord(BH.LiteralBytes);
      if PayloadLen > QWord(FDataEnd - Pos) then
        DataError(Format('block %d: payload past end of block area', [I]));
      if PayloadLen > QWord(High(SizeInt)) then
        DataError(Format('block %d: payload is too large', [I]));
      SetLength(Payload, SizeInt(PayloadLen));
      if PayloadLen > 0 then
        ReadExact(FStream, Payload[0], SizeInt(PayloadLen),
          Format('block %d payload', [I]));
      Inc(Pos, Int64(PayloadLen));

      Crc := Crc32C(Payload);
      if Crc <> BH.BlockCrc then
        DataError(Format('block %d: CRC mismatch', [I]));
      PutU32LE(CrcBytes, 0, BH.BlockCrc);
      BlocksCrc := Crc32CUpdate(BlocksCrc, CrcBytes[0], 4);

      if (FMaxOutput > 0) and
         (BlockStart + QWord(BH.OrigSize) > FMaxOutput) then
        raise EOsrepError.Create(6, 'original size exceeds max_output');

      ParseStreamRecords(BH, Payload, BlockStart, Pending);

      { Grow the window by exactly this block and produce its bytes. }
      SetLength(Win, SizeInt(WinLen + QWord(BH.OrigSize)));

      Pending.Sort(@CompareMatches);
      SetLength(Active, 0);
      J := 0;
      while (J < Pending.Count) and (PMatch(Pending[J])^.Dst < BlockStart) do
      begin
        M := PMatch(Pending[J]);
        if M^.Dst + M^.Len > BlockStart then
        begin
          SetLength(Active, Length(Active) + 1);
          Active[High(Active)] := M;
        end;
        Inc(J);
      end;

      LitPos := 0;
      LitStart := SizeInt(FHeader.HashSize) + SizeInt(BH.StatSize);
      K := 0;
      while K < SizeInt(BH.OrigSize) do
      begin
        P := BlockStart + QWord(K);
        while (J < Pending.Count) and (PMatch(Pending[J])^.Dst <= P) do
        begin
          SetLength(Active, Length(Active) + 1);
          Active[High(Active)] := PMatch(Pending[J]);
          Inc(J);
        end;
        { pick the last active match that covers this position }
        M := nil;
        for A := 0 to High(Active) do
          if (Active[A]^.Dst <= P) and (P < Active[A]^.Dst + Active[A]^.Len) then
            M := Active[A];

        if M = nil then
        begin
          { a literal run lasts until the next match destination }
          RunEnd := BlockStart + QWord(BH.OrigSize);
          if (J < Pending.Count) and
             (PMatch(Pending[J])^.Dst < RunEnd) then
            RunEnd := PMatch(Pending[J])^.Dst;
          Run := SizeInt(RunEnd - P);
          if LitPos + Run > SizeInt(BH.LiteralBytes) then
            DataError(Format('block %d: not enough literal bytes for a block hole',
              [I]));
          Move(Payload[LitStart + LitPos], Win[SizeInt(WinLen) + K], Run);
          Inc(LitPos, Run);
          Inc(K, Run);
        end
        else
        begin
          { copy up to the match end, the block end, or the next match start }
          RunEnd := M^.Dst + M^.Len;
          if RunEnd > BlockStart + QWord(BH.OrigSize) then
            RunEnd := BlockStart + QWord(BH.OrigSize);
          if (J < Pending.Count) and
             (PMatch(Pending[J])^.Dst < RunEnd) then
            RunEnd := PMatch(Pending[J])^.Dst;
          Run := SizeInt(RunEnd - P);
          if Run < 1 then
            Run := 1;
          SrcAbs := M^.Src + (P - M^.Dst);
          if SrcAbs < WinBase then
            DataError('match source is outside the decode window');
          SrcOff := SizeInt(SrcAbs - WinBase);
          DstOff := SizeInt(WinLen) + K;
          if DstOff - SrcOff >= Run then
            Move(Win[SrcOff], Win[DstOff], Run)
          else
            for L := 0 to Run - 1 do
              Win[DstOff + L] := Win[SrcOff + L];
          Inc(K, Run);
        end;
      end;
      if LitPos <> SizeInt(BH.LiteralBytes) then
        DataError(Format('block %d: literal bytes left over at the end of a block',
          [I]));

      SetLength(Digest, FHeader.HashSize);
      if FHeader.HashSize > 0 then
        Move(Payload[0], Digest[0], FHeader.HashSize);
      if not VerifyBlockDigest(FHeader.HashId, FSeed, Win,
        WinLen, BH.OrigSize, Digest) then
        DataError(Format('block %d: digest mismatch', [I]));

      if BH.OrigSize > 0 then
      begin
        if OutStream <> nil then
          OutStream.WriteBuffer(Win[SizeInt(WinLen)], BH.OrigSize)
        else
          Move(Win[SizeInt(WinLen)], Data[SizeInt(BlockStart)], BH.OrigSize);
      end;
      Inc(WinLen, QWord(BH.OrigSize));

      { Free matches that are fully applied and keep only the sources that
        pending matches still need. }
      J := 0;
      while J < Pending.Count do
      begin
        M := PMatch(Pending[J]);
        if M^.Dst + M^.Len <= BlockStart + QWord(BH.OrigSize) then
        begin
          Dispose(M);
          Pending.Delete(J);
        end
        else
          Inc(J);
      end;
      Inc(BlockStart, QWord(BH.OrigSize));
      CompactWindow;
      if QWord(Length(Win)) > WinLen then
        SetLength(Win, SizeInt(WinLen));

      Inc(FSumOrig, QWord(BH.OrigSize));
      Inc(FSumStat, QWord(BH.StatSize));
    end;

    if Pos <> FDataEnd then
      DataError('there is data between the last block and the footer/meta');
    ValidateMeta;
    if FSumOrig <> FHeader.OriginalSize then
      DataError(Format('original size mismatch: header %d, blocks %d',
        [FHeader.OriginalSize, FSumOrig]));
    if FSumStat <> FFooter.StatSize then
      DataError(Format('stat size mismatch: footer %d, blocks %d',
        [FFooter.StatSize, FSumStat]));
    if BlocksCrc <> FFooter.BlocksCrc then
      DataError('blocks CRC mismatch');
    FBlocksCrc := BlocksCrc;
  finally
    FreePending;
    SetLength(Win, 0);
  end;
end;

{ Records for the streaming decoder: absolute matches only, with the same validation as the
  block-wise parser. }
procedure TArchiveReader.ParseStreamRecords(const BH: TBlockHeader;
  const Payload: TBytes; BlockStart: QWord; Pending: TList);
var
  HashSize, RecStart, RecEnd, LitStart, LitEnd: SizeInt;
  P: SizeInt;
  RunningSkip, Src, Dst, Skip, Len, Dist: QWord;
  M: PMatch;
begin
  HashSize := FHeader.HashSize;
  if QWord(HashSize) + QWord(BH.StatSize) + QWord(BH.LiteralBytes) <>
     QWord(Length(Payload)) then
    DataError('block payload size mismatch');
  RecStart := HashSize;
  RecEnd := RecStart + SizeInt(BH.StatSize);
  LitStart := RecEnd;
  LitEnd := LitStart + SizeInt(BH.LiteralBytes);
  if LitEnd <> Length(Payload) then
    DataError('block literal range does not match the payload');

  RunningSkip := 0;
  P := RecStart;
  while P < RecEnd do
  begin
    if not ReadVarint(Payload, P, RecEnd, Skip) then
      DataError('bad skip varint in block records');
    if not ReadVarint(Payload, P, RecEnd, Len) then
      DataError('bad match length varint in block records');
    if not ReadVarint(Payload, P, RecEnd, Dist) then
      DataError('bad distance varint in block records');
    if (Len = 0) or (Dist = 0) then
      DataError('zero match length or distance');
    if Skip > High(QWord) - RunningSkip then
      DataError('match source overflows 64 bits');
    Inc(RunningSkip, Skip);
    if RunningSkip > High(QWord) - BlockStart then
      DataError('match source overflows the output position');
    Src := BlockStart + RunningSkip;
    if Src >= FHeader.OriginalSize then
      DataError('match source is outside the original data');
    if Dist > High(QWord) - Src then
      DataError('match destination overflows 64 bits');
    Dst := Src + Dist;
    if (Len > High(QWord) - Dst) or
       (Dst + Len > FHeader.OriginalSize) then
      DataError('match destination is outside the original data');
    New(M);
    M^.Src := Src;
    M^.Dst := Dst;
    M^.Len := Len;
    Pending.Add(M);
  end;
  if P <> RecEnd then
    DataError('records do not end at statsize');
end;

procedure TArchiveReader.VerifyBlocks;
var
  I: LongWord;
  Buf, Payload: TBytes;
  BH: TBlockHeader;
  PayloadLen: QWord;
  Crc: LongWord;
  CrcBytes: array[0..3] of Byte;
  Pos: Int64;
  BlocksCrc, SumOrig, SumStat: QWord;
begin
  BlocksCrc := 0;
  SumOrig := 0;
  SumStat := 0;
  Pos := OsrepHeaderSize + Length(FSeed);
  for I := 1 to FHeader.BlockCount do
  begin
    if Pos + OsrepBlockHeaderSize > FDataEnd then
      DataError(Format('block %d: header past end of block area', [I]));
    FStream.Position := Pos;
    SetLength(Buf, OsrepBlockHeaderSize);
    ReadExact(FStream, Buf[0], OsrepBlockHeaderSize,
      Format('block %d header', [I]));
    Inc(Pos, OsrepBlockHeaderSize);

    BH.LiteralBytes := GetU32LE(Buf, 0);
    BH.OrigSize := GetU32LE(Buf, 4);
    BH.StatSize := GetU32LE(Buf, 8);
    BH.BlockCrc := GetU32LE(Buf, 12);

    if (BH.LiteralBytes = BH.OrigSize) and (BH.StatSize <> 0) then
      DataError(Format('block %d: stored block has records', [I]));
    if (BH.StatSize = 0) and (BH.LiteralBytes <> BH.OrigSize) then
      DataError(Format('block %d: no records but literals do not cover it', [I]));

    PayloadLen := QWord(FHeader.HashSize) + QWord(BH.StatSize) +
      QWord(BH.LiteralBytes);
    if PayloadLen > QWord(FDataEnd - Pos) then
      DataError(Format('block %d: payload past end of block area', [I]));
    if PayloadLen > QWord(High(SizeInt)) then
      DataError(Format('block %d: payload is too large', [I]));
    SetLength(Payload, SizeInt(PayloadLen));
    if PayloadLen > 0 then
      ReadExact(FStream, Payload[0], SizeInt(PayloadLen),
        Format('block %d payload', [I]));
    Inc(Pos, Int64(PayloadLen));

    Crc := Crc32C(Payload);
    if Crc <> BH.BlockCrc then
      DataError(Format('block %d: CRC mismatch', [I]));
    PutU32LE(CrcBytes, 0, BH.BlockCrc);
    BlocksCrc := Crc32CUpdate(BlocksCrc, CrcBytes[0], 4);

    Inc(SumOrig, QWord(BH.OrigSize));
    Inc(SumStat, QWord(BH.StatSize));
  end;

  if Pos <> FDataEnd then
    DataError('there is data between the last block and the footer/meta');
  ValidateMeta;
  if SumOrig <> FHeader.OriginalSize then
    DataError(Format('original size mismatch: header %d, blocks %d',
      [FHeader.OriginalSize, SumOrig]));
  if SumStat <> FFooter.StatSize then
    DataError(Format('stat size mismatch: footer %d, blocks %d',
      [FFooter.StatSize, SumStat]));
  if BlocksCrc <> FFooter.BlocksCrc then
    DataError('blocks CRC mismatch');
  FBlocksCrc := BlocksCrc;
  FSumOrig := SumOrig;
  FSumStat := SumStat;
end;

procedure TArchiveReader.ReadInfo(out Info: TArchiveInfo);
begin
  LoadHeaderFooter;
  Info.BlockCount := FHeader.BlockCount;
  Info.MaxMatch := FHeader.MaxMatch;
  Info.OriginalSize := FHeader.OriginalSize;
  if (FHeader.Flags and 1) <> 0 then
    Info.OutputSize := DupOutputSize
  else
    Info.OutputSize := FHeader.OriginalSize;
  Info.StatSize := FFooter.StatSize;
  Info.MetaSize := FFooter.MetaSize;
  Info.HashId := FHeader.HashId;
  Info.HashSize := FHeader.HashSize;
  Info.Flags := FHeader.Flags;
end;

procedure TArchiveReader.Verify;
begin
  LoadHeaderFooter;
  VerifyBlocks;
end;

procedure TArchiveReader.DecodeToStream(OutStream: TStream);
var
  Body, Dummy: TBytes;
  BodyFile: TFileStream;
  TempName: string;
  AllLocal: Boolean;
begin
  LoadHeaderFooter;
  AllLocal := ScanBlockLocality;
  if (FHeader.Flags and 1) = 0 then
  begin
    if AllLocal then
      DecodeBlocks(OutStream, Dummy)
    else
      DecodeStreaming(OutStream, Dummy);
    Exit;
  end;

  { Large dup bodies are restored from a temporary file, so the body does not
    stay in RAM; a body that cannot be created falls back to memory. }
  BodyFile := nil;
  TempName := '';
  if FHeader.OriginalSize > OsrepDupBodyMemoryLimit then
  begin
    try
      TempName := GetTempFileName(GetTempDir, 'osr');
      BodyFile := TFileStream.Create(TempName, fmCreate);
    except
      if BodyFile <> nil then
        FreeAndNil(BodyFile);
      if TempName <> '' then
        DeleteFile(TempName);
      BodyFile := nil;
      TempName := '';
    end;
  end;

  try
    if BodyFile <> nil then
    begin
      if AllLocal then
        DecodeBlocks(BodyFile, Dummy)
      else
        DecodeStreaming(BodyFile, Dummy);
      RestoreDupFileToStream(BodyFile, FHeader.OriginalSize, OutStream);
    end
    else
    begin
      if AllLocal then
        DecodeBlocks(nil, Body)
      else
        DecodeStreaming(nil, Body);
      RestoreDupToStream(Body, OutStream);
    end;
  finally
    if BodyFile <> nil then
    begin
      BodyFile.Free;
      if TempName <> '' then
        DeleteFile(TempName);
    end;
  end;
end;

procedure TArchiveReader.DecodeToBytes(out Data: TBytes);
var
  Body: TBytes;
  AllLocal: Boolean;
begin
  LoadHeaderFooter;
  AllLocal := ScanBlockLocality;
  if (FHeader.Flags and 1) = 0 then
  begin
    if AllLocal then
      DecodeBlocks(nil, Data)
    else
      DecodeStreaming(nil, Data);
    Exit;
  end;

  if AllLocal then
    DecodeBlocks(nil, Body)
  else
    DecodeStreaming(nil, Body);
  RestoreDup(Body, Data);
end;

end.
