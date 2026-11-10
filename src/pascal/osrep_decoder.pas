unit osrep_decoder;
{ v6 archive reader: container validation and block reconstruction.

  The record stream is decoded with the Future-LZ semantics observed in the
  Omega SREP 3.0.0 v6 fixtures and described publicly by SREP:

    record = (skip, length, distance)
    source = running sum of skip
    destination = source + distance
    records are stored in source order; the decoder sorts them by destination
    and fills the holes between destinations with the literal stream.

  `spec/payload.md` §3 describes the older normal-LZ ordering.  The v6
  fixtures are all Future-LZ, so that is what this reader implements.  See
  docs/implementation-notes.md for the exact traceability. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, osrep_crc, osrep_format;

type
  TArchiveReader = class
  private
    FStream: TFileStream;
    FSize: Int64;
    FHeader: TArchiveHeader;
    FFooter: TArchiveFooter;
    FSeed: TBytes;
    FDataEnd: Int64;
    FBlocksCrc: LongWord;
    FSumOrig: QWord;
    FSumStat: QWord;
    procedure LoadHeaderFooter;
    procedure ValidateMeta;
    procedure DecodeBlock(const BH: TBlockHeader; const Payload: TBytes;
      out OutBuf: TBytes);
    procedure IterateBlocks(Decode: Boolean; OutStream: TStream);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    procedure ReadInfo(out Info: TArchiveInfo);
    procedure Verify;
    procedure DecodeToStream(OutStream: TStream);
    property Header: TArchiveHeader read FHeader;
    property Footer: TArchiveFooter read FFooter;
  end;

implementation

type
  PMatch = ^TMatch;
  TMatch = record
    Src: QWord;
    Dst: QWord;
    Len: QWord;
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

constructor TArchiveReader.Create(const AFileName: string);
begin
  inherited Create;
  try
    FStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
      raise EOsrepError.Create(3, 'cannot open input: ' + AFileName + ': ' + E.Message);
  end;
  FSize := FStream.Size;
end;

destructor TArchiveReader.Destroy;
begin
  FreeAndNil(FStream);
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

procedure TArchiveReader.ValidateMeta;
var
  Meta: TBytes;
  Stored, Calculated: LongWord;
begin
  if (FHeader.Flags and 1) = 0 then
    Exit;
  if FFooter.MetaSize < OsrepMetaMinSize then
    DataError('dup meta is too short');
  if QWord(FFooter.MetaSize) > QWord(High(SizeInt)) then
    DataError('dup meta is too large');
  SetLength(Meta, SizeInt(FFooter.MetaSize));
  FStream.Position := Int64(FFooter.MetaOffset);
  ReadExact(FStream, Meta[0], Length(Meta), 'dup meta');
  if GetU32LE(Meta, 0) <> OsrepMagicMeta then
    DataError('dup meta magic is not DUPR');
  if GetU32LE(Meta, 4) <> 1 then
    DataError('unsupported dup meta version');
  Stored := GetU32LE(Meta, Length(Meta) - 4);
  Calculated := Crc32C(Meta, 0, Length(Meta) - 4);
  if Stored <> Calculated then
    DataError('dup meta CRC mismatch');
end;

procedure TArchiveReader.DecodeBlock(const BH: TBlockHeader;
  const Payload: TBytes; out OutBuf: TBytes);
var
  HashSize, RecStart, RecEnd, LitStart, LitEnd: SizeInt;
  OutLen, Gap, Tail, P: SizeInt;
  Src, Skip, Len, Dist, Dst: QWord;
  Matches: TList;
  M: PMatch;
  I: Integer;
  J: SizeInt;
begin
  if QWord(BH.OrigSize) > QWord(High(SizeInt)) then
    DataError('block original size does not fit in memory');
  { The digest is present (hash_id=4/hash_size=16 in the fixtures) but its
    algorithm and key/nonce derivation are not in the specification.  The
    on-disk block_crc already covers the digest bytes, so --verify checks
    everything the spec pins.  Reconstruction digest verification is pending
    a spec clarification; see docs/implementation-notes.md §7.3. }
  HashSize := FHeader.HashSize;
  if QWord(HashSize) + QWord(BH.StatSize) + QWord(BH.LiteralBytes) <>
     QWord(Length(Payload)) then
    DataError('block payload size mismatch');
  RecStart := HashSize;
  RecEnd := RecStart + SizeInt(BH.StatSize);
  LitStart := RecEnd;
  LitEnd := LitStart + SizeInt(BH.LiteralBytes);

  SetLength(OutBuf, SizeInt(BH.OrigSize));

  if BH.StatSize = 0 then
  begin
    if BH.LiteralBytes <> BH.OrigSize then
      DataError('stored block has fewer literals than its original size');
    if BH.LiteralBytes > 0 then
      Move(Payload[LitStart], OutBuf[0], BH.LiteralBytes);
    Exit;
  end;

  Matches := TList.Create;
  try
    Src := 0;
    P := RecStart;
    while P < RecEnd do
    begin
      if not ReadVarint(Payload, P, RecEnd, Skip) then
        DataError('bad skip varint in block records');
      if not ReadVarint(Payload, P, RecEnd, Len) then
        DataError('bad match length varint in block records');
      if not ReadVarint(Payload, P, RecEnd, Dist) then
        DataError('bad distance varint in block records');
      if Skip > High(QWord) - Src then
        DataError('match source overflows 64 bits');
      Inc(Src, Skip);
      if (Len = 0) or (Dist = 0) then
        DataError('zero match length or distance');
      if Src >= BH.OrigSize then
        DataError('match source is outside the block');
      if Dist > High(QWord) - Src then
        DataError('match destination overflows 64 bits');
      Dst := Src + Dist;
      if (Len > High(QWord) - Dst) or (Dst + Len > BH.OrigSize) then
        DataError('match destination is outside the block');
      New(M);
      M^.Src := Src;
      M^.Dst := Dst;
      M^.Len := Len;
      Matches.Add(M);
    end;
    if P <> RecEnd then
      DataError('records do not end at statsize');
    if Matches.Count = 0 then
      DataError('block has records but no matches');

    Matches.Sort(@CompareMatches);

    OutLen := 0;
    P := LitStart;
    for I := 0 to Matches.Count - 1 do
    begin
      M := PMatch(Matches[I]);
      if M^.Dst < QWord(OutLen) then
        DataError('overlapping match destinations');
      Gap := SizeInt(M^.Dst) - OutLen;
      if Gap > 0 then
      begin
        if P + Gap > LitEnd then
          DataError('not enough literal bytes before a match');
        Move(Payload[P], OutBuf[OutLen], Gap);
        Inc(P, Gap);
        Inc(OutLen, Gap);
      end;
      for J := 0 to SizeInt(M^.Len) - 1 do
        OutBuf[SizeInt(M^.Dst) + J] := OutBuf[SizeInt(M^.Src) + J];
      OutLen := SizeInt(M^.Dst + M^.Len);
    end;

    Tail := SizeInt(BH.OrigSize) - OutLen;
    if Tail > 0 then
    begin
      if P + Tail > LitEnd then
        DataError('not enough literal bytes at the end of the block');
      Move(Payload[P], OutBuf[OutLen], Tail);
      Inc(P, Tail);
      Inc(OutLen, Tail);
    end;
    if P <> LitEnd then
      DataError('literal bytes left over at the end of the block');
    if OutLen <> SizeInt(BH.OrigSize) then
      DataError('reconstructed block size mismatch');
  finally
    for I := 0 to Matches.Count - 1 do
      Dispose(PMatch(Matches[I]));
    Matches.Free;
  end;
end;

procedure TArchiveReader.IterateBlocks(Decode: Boolean; OutStream: TStream);
var
  I: LongWord;
  Buf: TBytes;
  BH: TBlockHeader;
  Payload: TBytes;
  PayloadLen: QWord;
  Crc: LongWord;
  CrcBytes: array[0..3] of Byte;
  BlockOut: TBytes;
  Pos: Int64;
begin
  FBlocksCrc := 0;
  FSumOrig := 0;
  FSumStat := 0;
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
    FBlocksCrc := Crc32CUpdate(FBlocksCrc, CrcBytes[0], 4);
    Inc(FSumOrig, QWord(BH.OrigSize));
    Inc(FSumStat, QWord(BH.StatSize));

    if Decode then
    begin
      DecodeBlock(BH, Payload, BlockOut);
      if Length(BlockOut) > 0 then
        OutStream.WriteBuffer(BlockOut[0], Length(BlockOut));
    end;
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
  if FBlocksCrc <> FFooter.BlocksCrc then
    DataError('blocks CRC mismatch');
end;

procedure TArchiveReader.ReadInfo(out Info: TArchiveInfo);
begin
  LoadHeaderFooter;
  Info.BlockCount := FHeader.BlockCount;
  Info.OriginalSize := FHeader.OriginalSize;
  Info.StatSize := FFooter.StatSize;
  Info.MetaSize := FFooter.MetaSize;
  Info.HashId := FHeader.HashId;
  Info.HashSize := FHeader.HashSize;
  Info.Flags := FHeader.Flags;
end;

procedure TArchiveReader.Verify;
begin
  LoadHeaderFooter;
  IterateBlocks(False, nil);
end;

procedure TArchiveReader.DecodeToStream(OutStream: TStream);
begin
  LoadHeaderFooter;
  IterateBlocks(True, OutStream);
end;

end.
