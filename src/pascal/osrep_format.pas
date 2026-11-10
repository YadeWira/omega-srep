unit osrep_format;
{ v6 container structures and small byte/stream helpers.

  Traceability: spec/format-v6.md §2 and the v6 fixtures in
  tests/fixtures/v6/.  The footer is 36 bytes even though one line of the
  specification says "32 bytes"; the field list and "CRC of the previous 32
  bytes" fix the real size, and the fixtures confirm it. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  OsrepMagicHeader = LongWord($3652534F); { "OSR6", little endian }
  OsrepMagicFooter = LongWord($4652534F); { "OSRF", little endian }
  OsrepMagicMeta   = LongWord($52505544); { "DUPR", little endian }

  OsrepVersion          = 6;
  OsrepHeaderSize       = 28;
  OsrepFooterSize       = 36;
  OsrepBlockHeaderSize  = 16;
  OsrepMetaMinSize      = 8;  { magic + version u32 }

  { fixture-observed hash ids: 4 = 16-byte digest with a 32-byte seed.
    The specification has no hash-id table; see docs/implementation-notes.md. }
  OsrepHashIdVmac     = 4;
  OsrepHashSizeVmac   = 16;
  OsrepSeedSizeVmac   = 32;

type
  EOsrepError = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer; const AMsg: string);
    property Code: Integer read FCode;
  end;

  TArchiveHeader = record
    Version: Byte;
    Flags: Byte;
    HashId: Byte;
    HashSize: Byte;
    MaxMatch: LongWord;
    BlockCount: LongWord;
    OriginalSize: QWord;
    HeaderCrc: LongWord;
  end;

  TArchiveFooter = record
    BlockCount: LongWord;
    StatSize: QWord;
    MetaOffset: QWord;
    MetaSize: LongWord;
    BlocksCrc: LongWord;
    FooterCrc: LongWord;
  end;

  TBlockHeader = record
    LiteralBytes: LongWord;
    OrigSize: LongWord;
    StatSize: LongWord;
    BlockCrc: LongWord;
  end;

  TArchiveInfo = record
    BlockCount: LongWord;
    OriginalSize: QWord;
    StatSize: QWord;
    MetaSize: LongWord;
    HashId: Byte;
    HashSize: Byte;
    Flags: Byte;
  end;

function GetU32LE(const Buf: TBytes; Offset: SizeInt): LongWord;
function GetU64LE(const Buf: TBytes; Offset: SizeInt): QWord;
procedure PutU32LE(var Buf: array of Byte; Offset: SizeInt; Value: LongWord);
procedure ReadExact(Stream: TStream; var Buf; Count: SizeInt; const What: string);
function SeedSizeFor(HashId, HashSize: Byte; out SeedSize: SizeInt): Boolean;
procedure DataError(const Msg: string);

implementation

constructor EOsrepError.Create(ACode: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FCode := ACode;
end;

function GetU32LE(const Buf: TBytes; Offset: SizeInt): LongWord;
begin
  Result := LongWord(Buf[Offset]) or
            (LongWord(Buf[Offset + 1]) shl 8) or
            (LongWord(Buf[Offset + 2]) shl 16) or
            (LongWord(Buf[Offset + 3]) shl 24);
end;

function GetU64LE(const Buf: TBytes; Offset: SizeInt): QWord;
begin
  Result := QWord(GetU32LE(Buf, Offset)) or
            (QWord(GetU32LE(Buf, Offset + 4)) shl 32);
end;

procedure PutU32LE(var Buf: array of Byte; Offset: SizeInt; Value: LongWord);
begin
  Buf[Offset] := Byte(Value);
  Buf[Offset + 1] := Byte(Value shr 8);
  Buf[Offset + 2] := Byte(Value shr 16);
  Buf[Offset + 3] := Byte(Value shr 24);
end;

procedure ReadExact(Stream: TStream; var Buf; Count: SizeInt; const What: string);
begin
  if Count = 0 then
    Exit;
  try
    Stream.ReadBuffer(Buf, Count);
  except
    on E: Exception do
      raise EOsrepError.Create(4, 'truncated archive: ' + What);
  end;
end;

function SeedSizeFor(HashId, HashSize: Byte; out SeedSize: SizeInt): Boolean;
begin
  SeedSize := 0;
  if HashSize = 0 then
  begin
    { No per-block digest.  The fixtures always use hash 4/16; a future
      writer may use 0/0 for "no hash". }
    Result := HashId = 0;
    Exit;
  end;
  if (HashId = OsrepHashIdVmac) and (HashSize = OsrepHashSizeVmac) then
  begin
    SeedSize := OsrepSeedSizeVmac;
    Result := True;
    Exit;
  end;
  Result := False;
end;

procedure DataError(const Msg: string);
begin
  raise EOsrepError.Create(4, Msg);
end;

end.
