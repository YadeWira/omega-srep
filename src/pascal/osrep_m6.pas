{ osrep_m6: OSREP's long-range method (-m6, stream format v7) for programs
  that embed it, memory to memory.  MIT.

  The stream is a standard .osr v7 (spec/format-v7.md): the CLI decodes what
  this unit writes and the other way round.  The encoder reads the input in
  place and writes into the caller's buffer (size it with OsrepM6Bound); the
  decoder writes in place into a buffer of exactly the original size and
  copies match sources from it, so it keeps no window of its own.

    OsrepM6ParamsDefault(P);              -l512, --align=16, no digest
    Cap := OsrepM6Bound(SrcLen, P);
    R := OsrepM6Encode(Src, SrcLen, Dst, Cap, DstLen, P);
    R := OsrepM6OrigSize(Stream, StreamLen, OrigLen);
    R := OsrepM6Decode(Stream, StreamLen, Out, OrigLen);

  Every call returns OSREP_M6_OK or an error code (OsrepM6ErrorText); none
  raises.  The calls keep no global state and may run on several threads at
  once.  Sizes are 64-bit; inputs over 4 GiB work on 64-bit targets. }

unit osrep_m6;

{$mode objfpc}{$H+}

interface

const
  OSREP_M6_OK = 0;
  OSREP_M6_E_DATA = 1;      { damaged, truncated, or not an .osr v7 stream }
  OSREP_M6_E_MEM = 2;       { out of memory }
  OSREP_M6_E_ARG = 3;       { a bad parameter or a nil buffer }
  OSREP_M6_E_DST = 4;       { the output buffer is too small (or, to decode,
                              not the original size) }
  OSREP_M6_E_VERSION = 5;   { a stream this build does not read (v6, or a
                              later version) }
  OSREP_M6_E_INTERNAL = 6;

  { defaults and limits of TOsrepM6Params }
  OSREP_M6_MINLEN_DEFAULT = 512;
  OSREP_M6_MINLEN_MIN = 32;
  OSREP_M6_MINLEN_MAX = 65536;
  OSREP_M6_ALIGN_DEFAULT = 16;
  OSREP_M6_ALIGN_MAX = 4096;
  OSREP_M6_BLOCK_DEFAULT = 8 * 1024 * 1024;
  OSREP_M6_BLOCK_MIN = 64 * 1024;
  OSREP_M6_BLOCK_MAX = 256 * 1024 * 1024;

type
  TOsrepM6Params = record
    { shortest match: 512 in front of an LZ with a context model (lzma,
      zstd, plz), 64 in front of a plain LZ, 32 with no backend }
    MinLen: LongWord;
    { match lengths are multiples of Align: 16 keeps the position modulo 16
      that lzma models; 1 with no backend or a plain LZ }
    Align: LongWord;
    { literal block of the stream; it does not change the matches }
    BlockSize: LongWord;
    { the thread budget: the -m6 search runs on one thread and never starts
      another; values above 1 are accepted for later releases }
    Threads: LongInt;
    { a VHASH-128 digest per block (as the CLI writes by default); off, the
      table and every block still carry a CRC-32C }
    Digest: Boolean;
  end;

procedure OsrepM6ParamsDefault(out P: TOsrepM6Params);
{ OSREP_M6_OK if P is usable }
function OsrepM6Check(const P: TOsrepM6Params): LongInt;

{ the largest stream OsrepM6Encode writes for SrcLen bytes: a buffer of
  this size never gives OSREP_M6_E_DST }
function OsrepM6Bound(SrcLen: QWord; const P: TOsrepM6Params): QWord;
{ the most memory OsrepM6Encode allocates for SrcLen bytes, besides Src and
  Dst (a bound: the match list is counted at its largest) }
function OsrepM6EncMem(SrcLen: QWord; const P: TOsrepM6Params): QWord;
{ the most memory OsrepM6Decode allocates besides the stream and Dst }
function OsrepM6DecMem(Digest: Boolean = False;
  BlockSize: LongWord = OSREP_M6_BLOCK_DEFAULT): QWord;

function OsrepM6Encode(Src: PByte; SrcLen: QWord; Dst: PByte; DstCap: QWord;
  out DstLen: QWord; const P: TOsrepM6Params): LongInt;

{ the original size a stream decodes to (header and footer checked) }
function OsrepM6OrigSize(Src: PByte; SrcLen: QWord;
  out OrigLen: QWord): LongInt;
{ decodes a whole stream into Dst; DstLen must be the original size.  On an
  error Dst may hold part of the output. }
function OsrepM6Decode(Src: PByte; SrcLen: QWord; Dst: PByte;
  DstLen: QWord): LongInt;

function OsrepM6ErrorText(Code: LongInt): string;
{ the message of the last error on this thread ('' after a success) }
function OsrepM6LastError: string;

implementation

uses
  SysUtils, Classes, osrep_format, osrep_encoder, osrep_decoder;

threadvar
  LastErr: string;

type
  { a read-only stream over the caller's memory, without a copy }
  TPtrStream = class(TCustomMemoryStream)
  public
    constructor Create(P: Pointer; Len: QWord);
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;

  EDstFull = class(Exception);

  { writes into the caller's fixed buffer }
  TFixedOut = class(TStream)
  private
    FMem: PByte;
    FCap, FPos, FSize: QWord;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(P: PByte; Cap: QWord);
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TPtrStream.Create(P: Pointer; Len: QWord);
begin
  inherited Create;
  SetPointer(P, PtrInt(Len));
end;

function TPtrStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('read-only stream');
  Result := 0;
end;

constructor TFixedOut.Create(P: PByte; Cap: QWord);
begin
  inherited Create;
  FMem := P;
  FCap := Cap;
  FPos := 0;
  FSize := 0;
end;

function TFixedOut.GetSize: Int64;
begin
  Result := Int64(FSize);
end;

function TFixedOut.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('write-only stream');
  Result := 0;
end;

function TFixedOut.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  if Count <= 0 then
    Exit;
  if QWord(Count) > FCap - FPos then
    raise EDstFull.Create('the output buffer is too small');
  Move(Buffer, FMem[FPos], Count);
  Inc(FPos, QWord(Count));
  if FPos > FSize then
    FSize := FPos;
  Result := Count;
end;

function TFixedOut.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  NewPos: Int64;
begin
  case Origin of
    soBeginning: NewPos := Offset;
    soCurrent: NewPos := Int64(FPos) + Offset;
  else
    NewPos := Int64(FSize) + Offset;
  end;
  if (NewPos < 0) or (QWord(NewPos) > FCap) then
    raise EDstFull.Create('seek outside the output buffer');
  FPos := QWord(NewPos);
  Result := NewPos;
end;

procedure OsrepM6ParamsDefault(out P: TOsrepM6Params);
begin
  P.MinLen := OSREP_M6_MINLEN_DEFAULT;
  P.Align := OSREP_M6_ALIGN_DEFAULT;
  P.BlockSize := OSREP_M6_BLOCK_DEFAULT;
  P.Threads := 1;
  P.Digest := False;
end;

function OsrepM6Check(const P: TOsrepM6Params): LongInt;
begin
  Result := OSREP_M6_E_ARG;
  if (P.MinLen < OSREP_M6_MINLEN_MIN) or (P.MinLen > OSREP_M6_MINLEN_MAX) then
    Exit;
  if (P.Align < 1) or (P.Align > OSREP_M6_ALIGN_MAX) then
    Exit;
  if (P.BlockSize < OSREP_M6_BLOCK_MIN) or
     (P.BlockSize > OSREP_M6_BLOCK_MAX) then
    Exit;
  if P.Threads < 0 then
    Exit;
  Result := OSREP_M6_OK;
end;

function VarLen(V: QWord): QWord;
begin
  Result := 1;
  while V >= 128 do
  begin
    V := V shr 7;
    Inc(Result);
  end;
end;

function BlockCount(SrcLen: QWord; const P: TOsrepM6Params): QWord;
begin
  Result := (SrcLen + P.BlockSize - 1) div P.BlockSize;
end;

function OsrepM6Bound(SrcLen: QWord; const P: TOsrepM6Params): QWord;
var
  PerBlock, Seed: QWord;
begin
  { header, seed, an empty table (count + CRC), footer; every block adds its
    header and digest.  A match takes at most 3 varints of the input size
    and saves at least MinLen literal bytes: since MinLen >= 32 > 30, a
    stream with matches is never larger than one without. }
  PerBlock := OsrepBlockHeaderSize;
  Seed := 0;
  if P.Digest then
  begin
    Inc(PerBlock, 16);
    Seed := 32;
  end;
  Result := OsrepHeaderSize + Seed + 12 + OsrepFooterSize +
    BlockCount(SrcLen, P) * PerBlock + SrcLen;
end;

function OsrepM6EncMem(SrcLen: QWord; const P: TOsrepM6Params): QWord;
var
  Entries, Table, Filter, MaxMatch, Matches, TableBytes, Finder,
    Blocks, BS: QWord;
  TBits, FBits: LongWord;
begin
  { the finder: the hash table (6 u32 a bucket, 4 ways; the Pascal reference
    takes 8 u32 and a copy of the input), the bit filter and the match list,
    24 bytes a match, grown by doubling (old and new arrays at once) }
  Entries := SrcLen div (P.MinLen div 2) + 1;
  TBits := 4;
  while (QWord(1) shl TBits) * 4 < Entries * 2 do
    Inc(TBits);
  FBits := 6;
  while (QWord(1) shl FBits) < Entries * 8 do
    Inc(FBits);
{$ifndef OSREP_NO_NATIVE}
  Table := (QWord(1) shl TBits) * 6 * 4;
{$else}
  Table := (QWord(1) shl TBits) * 8 * 4 + SrcLen;
{$endif}
  Filter := (QWord(1) shl FBits) div 8;
  { matches do not overlap and are at least MinLen long }
  MaxMatch := SrcLen div P.MinLen + 1;
  Matches := (3 * MaxMatch + 1024) * 24;
  Finder := Table + Filter + Matches;
  { the blocks: the final match list, the encoded table (grown by doubling
    and copied once), and per block the input, literal and payload buffers }
  TableBytes := 12 + MaxMatch * 3 * VarLen(SrcLen);
  BS := P.BlockSize;
  if BS > SrcLen then
    BS := SrcLen;
  Blocks := MaxMatch * 24 + 3 * TableBytes + 4 * BS + 64;
  if Finder > Blocks then
    Result := Finder
  else
    Result := Blocks;
  Inc(Result, 1024 * 1024);
end;

function OsrepM6DecMem(Digest: Boolean; BlockSize: LongWord): QWord;
begin
  { four 64 KiB column cursors, a 64 KiB table buffer and the reader; with
    a digest, a copy of one block for the VHASH }
  Result := 1024 * 1024;
  if Digest then
    Inc(Result, QWord(BlockSize));
end;

function FromException(E: Exception): LongInt;
begin
  LastErr := E.Message;
  if E is EDstFull then
    Result := OSREP_M6_E_DST
  else if E is EOutOfMemory then
    Result := OSREP_M6_E_MEM
  else if E is EOsrepError then
  begin
    case EOsrepError(E).Code of
      2: Result := OSREP_M6_E_ARG;
      3, 4, 5: Result := OSREP_M6_E_DATA;
      6: Result := OSREP_M6_E_DST;
    else
      Result := OSREP_M6_E_DATA;
    end;
    if Pos('unsupported version', E.Message) > 0 then
      Result := OSREP_M6_E_VERSION;
  end
  else
    Result := OSREP_M6_E_INTERNAL;
end;

function OsrepM6Encode(Src: PByte; SrcLen: QWord; Dst: PByte; DstCap: QWord;
  out DstLen: QWord; const P: TOsrepM6Params): LongInt;
var
  Opt: TEncoderOptions;
  InS: TPtrStream;
  OutS: TFixedOut;
begin
  DstLen := 0;
  LastErr := '';
  Result := OsrepM6Check(P);
  if Result <> OSREP_M6_OK then
  begin
    LastErr := OsrepM6ErrorText(Result);
    Exit;
  end;
  if ((Src = nil) and (SrcLen > 0)) or (Dst = nil) or
     (SrcLen > QWord(High(PtrInt))) then
  begin
    LastErr := 'nil buffer or input too large';
    Exit(OSREP_M6_E_ARG);
  end;
  InS := nil;
  OutS := nil;
  try
    try
      Opt := DefaultEncoderOptions;
      Opt.Method := 6;
      Opt.MinMatch := P.MinLen;
      Opt.Align := P.Align;
      Opt.BlockSize := P.BlockSize;
      Opt.Stride := 1;
      Opt.Threads := 1;
      Opt.UseHash := P.Digest;
      if not P.Digest then
        Opt.Seed := nil;
      InS := TPtrStream.Create(Src, SrcLen);
      OutS := TFixedOut.Create(Dst, DstCap);
      EncodeToStream(InS, OutS, Opt);
      DstLen := OutS.FSize;
      Result := OSREP_M6_OK;
    except
      on E: Exception do
        Result := FromException(E);
    end;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

function OpenReader(Src: PByte; SrcLen: QWord; out S: TPtrStream;
  out R: TArchiveReader): LongInt;
begin
  S := nil;
  R := nil;
  if ((Src = nil) and (SrcLen > 0)) or (SrcLen > QWord(High(PtrInt))) then
  begin
    LastErr := 'nil buffer or stream too large';
    Exit(OSREP_M6_E_ARG);
  end;
  S := TPtrStream.Create(Src, SrcLen);
  R := TArchiveReader.CreateFromStream(S, False);
  Result := OSREP_M6_OK;
end;

{ the version byte, so a v6 stream is reported as such and not as damage }
function IsV6(Src: PByte; SrcLen: QWord): Boolean;
begin
  Result := (SrcLen >= 5) and (Src[0] = Ord('O')) and (Src[1] = Ord('S')) and
    (Src[2] = Ord('R')) and (Src[3] = Ord('6'));
end;

function OsrepM6OrigSize(Src: PByte; SrcLen: QWord;
  out OrigLen: QWord): LongInt;
var
  S: TPtrStream;
  R: TArchiveReader;
  Info: TArchiveInfo;
begin
  OrigLen := 0;
  LastErr := '';
  S := nil;
  R := nil;
  try
    try
      Result := OpenReader(Src, SrcLen, S, R);
      if Result <> OSREP_M6_OK then
        Exit;
      if IsV6(Src, SrcLen) then
      begin
        LastErr := 'a v6 stream: this unit reads v7 (-m6) only';
        Exit(OSREP_M6_E_VERSION);
      end;
      R.ReadInfo(Info);
      if R.Header.Version <> OsrepVersionV7 then
      begin
        LastErr := 'not a v7 stream';
        Exit(OSREP_M6_E_VERSION);
      end;
      OrigLen := R.Header.OriginalSize;
      Result := OSREP_M6_OK;
    except
      on E: Exception do
        Result := FromException(E);
    end;
  finally
    R.Free;
    S.Free;
  end;
end;

function OsrepM6Decode(Src: PByte; SrcLen: QWord; Dst: PByte;
  DstLen: QWord): LongInt;
var
  S: TPtrStream;
  R: TArchiveReader;
begin
  LastErr := '';
  S := nil;
  R := nil;
  try
    try
      Result := OpenReader(Src, SrcLen, S, R);
      if Result <> OSREP_M6_OK then
        Exit;
      if IsV6(Src, SrcLen) then
      begin
        LastErr := 'a v6 stream: this unit reads v7 (-m6) only';
        Exit(OSREP_M6_E_VERSION);
      end;
      R.DecodeToMemory(Dst, DstLen);
      Result := OSREP_M6_OK;
    except
      on E: EOsrepError do
      begin
        Result := FromException(E);
        if Pos('not the original size', E.Message) > 0 then
          Result := OSREP_M6_E_DST
        else if Pos('not a v7 stream', E.Message) > 0 then
          Result := OSREP_M6_E_VERSION;
      end;
      on E: Exception do
        Result := FromException(E);
    end;
  finally
    R.Free;
    S.Free;
  end;
end;

function OsrepM6ErrorText(Code: LongInt): string;
begin
  case Code of
    OSREP_M6_OK: Result := 'ok';
    OSREP_M6_E_DATA: Result := 'damaged or truncated stream';
    OSREP_M6_E_MEM: Result := 'out of memory';
    OSREP_M6_E_ARG: Result := 'bad parameter';
    OSREP_M6_E_DST: Result := 'output buffer too small or not the original size';
    OSREP_M6_E_VERSION: Result := 'not an .osr v7 stream';
    OSREP_M6_E_INTERNAL: Result := 'internal error';
  else
    Result := 'unknown error';
  end;
end;

function OsrepM6LastError: string;
begin
  Result := LastErr;
end;

end.
