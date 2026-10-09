unit DupWrap;
{ El wrapper de -dup (dup.rs, como dup_wrapper.cpp lo arma en la CLI).

  -dup son dos pasadas. El dedup reescribe la entrada en un CUERPO (los chunks
  unicos, en orden de aparicion) y una meta que dice como armar el original;
  el encoder comprime el cuerpo, que es de donde sale la ganancia. La meta
  nunca pasa por el encoder.

  Donde vive la meta es lo unico en que v4 y v5 difieren: v4 la agrega como
  trailer ODUP y la encuentra olfateando los ultimos cuatro bytes; v5 la
  guarda entre los bloques y el footer, que apunta a ella. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, Encoder, Dedup, FutureLz;

type
  TDupMode = (dmV5, dmV4);

  { DupError, con el texto del Debug del Rust en el mensaje }
  EDup = class(Exception);

procedure DupEncode(const InPath, OutPath: AnsiString; const Opts: TEncodeOptions;
                    Kind: TEncKind; Cont: TEncContainer; const P: TDupParams;
                    Paranoid: Boolean; Mode: TDupMode);

{ True si el archivo era -dup y corrio el post-paso; False si es uno comun,
  lo que es un EXITO: el que llama lo decodifica el mismo. }
function DupDecode(const InPath, OutPath: AnsiString; const Opts: TFutureLzOptions): Boolean;

implementation

uses Container, Decompress, SpillFile;

const
  ODUP_TRAILER_SIZE = 12;          { meta_size u64 + "ODUP" }

function NewTempPath(const Prefix: AnsiString): AnsiString;
var s: TOwnedHandleStream;
begin
  s := CreateTempExclusive(Prefix, Result);
  if s = nil then raise EDup.Create('Io');
  s.Free;
end;

procedure DupEncode(const InPath, OutPath: AnsiString; const Opts: TEncodeOptions;
                    Kind: TEncKind; Cont: TEncContainer; const P: TDupParams;
                    Paranoid: Boolean; Mode: TDupMode);
var
  body: AnsiString;
  meta, t: TBytes;
  o: TEncodeOptions;
  bs, os: TFileStream;
  i: LongInt;
begin
  { -dup no tiene sentido con -m0: no hay tabla de chunks contra que deduplicar }
  if Kind = ekInmem then raise EDup.Create('IncompatibleMethod');
  { el trailer ODUP solo esta definido sobre el Index-LZ por defecto }
  if (Mode = dmV4) and (Cont <> ecIndexLz) then raise EDup.Create('UnsupportedContainer');

  body := NewTempPath('osrep-dup-body');
  try
    try
      meta := EncodeStreaming(InPath, body, P, Paranoid);
    except
      on X: EDedup do raise EDup.Create(X.Message);
    end;
    o := Opts;
    if Mode = dmV5 then o.DupMeta := meta else o.DupMeta := nil;
    bs := nil; os := nil;
    try
      bs := TFileStream.Create(body, fmOpenRead or fmShareDenyNone);
      os := TFileStream.Create(OutPath, fmCreate);
      Encode(bs, os, o, Kind, Cont);
      if Mode = dmV4 then
      begin
        { dup_wrapper.cpp:254-262: meta || u64_le(meta_size) || "ODUP" }
        if Length(meta) > 0 then os.WriteBuffer(meta[0], Length(meta));
        SetLength(t, ODUP_TRAILER_SIZE);
        for i := 0 to 7 do t[i] := Byte(QWord(Length(meta)) shr (8 * i));
        t[8] := Ord('O'); t[9] := Ord('D'); t[10] := Ord('U'); t[11] := Ord('P');
        os.WriteBuffer(t[0], ODUP_TRAILER_SIZE);
      end;
    finally
      os.Free;
      bs.Free;
    end;
  finally
    DeleteFile(body);
  end;
end;

function ReadAt(S: TStream; Off, N: QWord): TBytes;
begin
  SetLength(Result, N);
  S.Seek(Int64(Off), soBeginning);
  if N > 0 then
    if QWord(S.Read(Result[0], LongInt(N))) <> N then raise EDup.Create('Truncated');
end;

{ la meta de un v5, o nil si no es v5 o no la trae }
function V5Meta(S: TStream; Len: QWord): TBytes;
var head, tail, blob: TBytes; h: TV5Header; f: TV5Footer; blobLen, ending: QWord;
    crc: DWord;
begin
  Result := nil;
  if Len < V5_HEADER_SIZE + V5_FOOTER_SIZE then Exit;
  head := ReadAt(S, 0, V5_HEADER_SIZE);
  if not IsV5(head) then Exit;
  if DecodeV5Header(head, h) <> ceOK then raise EDup.Create('BadDup');
  if (h.Flags and V5_FLAG_HAS_DUP) = 0 then Exit;
  tail := ReadAt(S, Len - V5_FOOTER_SIZE, V5_FOOTER_SIZE);
  if DecodeV5Footer(tail, 0, f) <> ceOK then raise EDup.Create('BadDup');
  blobLen := QWord(f.MetaSize);
  if f.MetaOffset > High(QWord) - blobLen then raise EDup.Create('BadDup');
  ending := f.MetaOffset + blobLen;
  if (blobLen = 0) or (ending > Len) then raise EDup.Create('BadDup');
  blob := ReadAt(S, f.MetaOffset, blobLen);
  { decode_meta: el .dupref con su CRC verificado }
  if blobLen < 24 + 4 then raise EDup.Create('BadDup');
  if (blob[0] <> Ord('D')) or (blob[1] <> Ord('U')) or (blob[2] <> Ord('P')) or
     (blob[3] <> Ord('R')) or (blob[4] <> 1) then raise EDup.Create('BadDup');
  crc := DWord(blob[blobLen - 4]) or (DWord(blob[blobLen - 3]) shl 8) or
         (DWord(blob[blobLen - 2]) shl 16) or (DWord(blob[blobLen - 1]) shl 24);
  if crc <> Crc32c(blob, 0, blobLen - 4) then raise EDup.Create('BadDup');
  Result := Copy(blob, 0, blobLen - 4);
end;

{ la meta del trailer ODUP de un v4, o nil si los ultimos cuatro bytes no son ODUP }
function OdupMeta(S: TStream; Len: QWord; out IsDup: Boolean): TBytes;
var magic, sz: TBytes; metaSize: QWord; i: LongInt;
begin
  Result := nil;
  IsDup := False;
  if Len < ODUP_TRAILER_SIZE then Exit;
  magic := ReadAt(S, Len - 4, 4);
  if not ((magic[0] = Ord('O')) and (magic[1] = Ord('D')) and (magic[2] = Ord('U')) and
          (magic[3] = Ord('P'))) then Exit;
  sz := ReadAt(S, Len - ODUP_TRAILER_SIZE, 8);
  metaSize := 0;
  for i := 7 downto 0 do metaSize := (metaSize shl 8) or QWord(sz[i]);
  if (metaSize > Len - ODUP_TRAILER_SIZE) or (metaSize < 4) then raise EDup.Create('BadDup');
  Result := ReadAt(S, Len - ODUP_TRAILER_SIZE - metaSize, metaSize);
  { un trailer ODUP cuya meta no es .dupref es casi seguro una casualidad }
  if not ((Result[0] = Ord('D')) and (Result[1] = Ord('U')) and (Result[2] = Ord('P')) and
          (Result[3] = Ord('R'))) then raise EDup.Create('BadDup');
  IsDup := True;
end;

{ archive::decode: el decoder que corresponde a la version }
procedure DecodeAny(const InPath, OutPath: AnsiString; const Opts: TFutureLzOptions);
var inS, outS: TFileStream; st: TFutureLzStats; dst: TDecodeStats; msg: AnsiString;
    e: TDecodeError; head, arc: TBytes; h: TArchiveHeader;
begin
  inS := nil; outS := nil;
  try
    inS := TFileStream.Create(InPath, fmOpenRead or fmShareDenyNone);
    outS := TFileStream.Create(OutPath, fmCreate);
    SetLength(head, ARCHIVE_HEADER_SIZE);
    msg := '';
    if inS.Read(head[0], ARCHIVE_HEADER_SIZE) <> ARCHIVE_HEADER_SIZE then
      raise EDup.Create('Decode(Container(Truncated))');
    inS.Seek(0, soBeginning);
    if IsV5(head) then e := DecodeV5(inS, outS, Opts, st, msg)
    else
    begin
      if DecodeArchiveHeader(head, h) <> ceOK then raise EDup.Create('Decode(Container(NotAnOsrepFile))');
      if (h.Version = 1) or (h.Version = 2) then
      begin
        SetLength(arc, inS.Size);
        if Length(arc) > 0 then inS.ReadBuffer(arc[0], Length(arc));
        e := DecodeIoLz(arc, outS, dst);
      end
      else
        e := DecodeFutureLz(inS, outS, Opts, st, msg);
    end;
    if e <> deOK then
    begin
      if msg = '' then msg := 'decode failed';
      raise EDup.Create('Decode(' + msg + ')');
    end;
  finally
    outS.Free;
    inS.Free;
  end;
end;

function DupDecode(const InPath, OutPath: AnsiString; const Opts: TFutureLzOptions): Boolean;
var
  s, cut: TFileStream;
  len, bodyLen: QWord;
  meta: TBytes;
  isOdup: Boolean;
  body, decoded: AnsiString;
begin
  Result := False;
  s := TFileStream.Create(InPath, fmOpenRead or fmShareDenyNone);
  try
    len := QWord(s.Size);
    meta := V5Meta(s, len);
    isOdup := False;
    if meta = nil then meta := OdupMeta(s, len, isOdup);
    if (meta = nil) and not isOdup then Exit(False);

    if not isOdup then
    begin
      { v5: el cuerpo se decodifica a un temporal, porque el post-paso vuelve
        a leerlo para expandir las referencias }
      s.Free; s := nil;
      body := NewTempPath('osrep-dup-body');
      try
        DecodeAny(InPath, body, Opts);
        try
          DecodeStreaming(meta, body, OutPath);
        except
          on X: EDedup do raise EDup.Create(X.Message);
        end;
      finally
        DeleteFile(body);
      end;
      Exit(True);
    end;

    { v4: el cuerpo esta en el archivo, tapado por el trailer; se recorta a un
      temporal antes de decodificarlo, como hace el C++ }
    bodyLen := len - ODUP_TRAILER_SIZE - QWord(Length(meta));
    body := NewTempPath('osrep-dup-body-osr');
    decoded := '';
    try
      cut := TFileStream.Create(body, fmCreate);
      try
        s.Seek(0, soBeginning);
        if bodyLen > 0 then cut.CopyFrom(s, Int64(bodyLen));
      finally
        cut.Free;
      end;
      s.Free; s := nil;
      decoded := NewTempPath('osrep-dup-body-dec');
      DecodeAny(body, decoded, Opts);
      try
        DecodeStreaming(meta, decoded, OutPath);
      except
        on X: EDedup do raise EDup.Create(X.Message);
      end;
    finally
      DeleteFile(body);
      if decoded <> '' then DeleteFile(decoded);
    end;
    Result := True;
  finally
    s.Free;
  end;
end;

end.
