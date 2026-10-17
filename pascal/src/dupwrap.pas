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

{ devuelve el largo del archivo escrito: out.metadata()?.len() }
function DupEncode(const InPath, OutPath: AnsiString; const Opts: TEncodeOptions;
                   Kind: TEncKind; Cont: TEncContainer; const P: TDupParams;
                   Paranoid: Boolean; Mode: TDupMode; Progress: TEncodeProgress = nil): QWord;

{ True si el archivo era -dup y corrio el post-paso; False si es uno comun,
  lo que es un EXITO: el que llama lo decodifica el mismo. StatsOutOfLine es
  el -index= de -d: las listas de un v1-v3 comun estan en el indice, y el
  recorrido que lo distingue de un -dup tiene que saberlo (decode_with). }
function DupDecode(const InPath, OutPath: AnsiString; const Opts: TFutureLzOptions;
                   StatsOutOfLine: Boolean = False): Boolean;

{ container::walk sin el bloque terminador: los primeros Len bytes de S se
  recorren como un v1-v4 entero, que termina donde dicen sus bloques (o su
  footer). OrigSize, la suma de los bloques. }
function WalksAsPlain(S: TStream; Len: QWord; StatsOutOfLine: Boolean; out OrigSize: QWord): Boolean;

implementation

uses Container, Decompress, DecFault, SpillFile, StreamIO, FixedCompress;

const
  ODUP_TRAILER_SIZE = 12;          { meta_size u64 + "ODUP" }

function NewTempPath(const Prefix: AnsiString): AnsiString;
var s: TOwnedHandleStream;
begin
  s := CreateTempExclusive(Prefix, Result);
  if s = nil then raise EDup.Create('Io');
  s.Free;
end;

function DupEncode(const InPath, OutPath: AnsiString; const Opts: TEncodeOptions;
                   Kind: TEncKind; Cont: TEncContainer; const P: TDupParams;
                   Paranoid: Boolean; Mode: TDupMode; Progress: TEncodeProgress): QWord;
var
  body: AnsiString;
  meta, t: TBytes;
  o: TEncodeOptions;
  bs: TFileStream;
  os: TRawFileStream;
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
      { una salida de la corrida (streamio.pas, CreateOutput): O_WRONLY y sin
        el open previo de TFileStream, que sobre un FIFO se bloqueaba }
      os := CreateOutput(OutPath, False);
      if os = nil then raise EDup.Create('Io');
      { el `?` de encoder::encode convierte su error en DupError::Encode: una
        falla de E/S ahi es Encode(Io), no el Io suelto de los otros pasos }
      try
        Encode(bs, os, o, Kind, Cont, Progress);
      except
        on X: EEncode do raise;
        on X: Exception do
          if IsIoException(X) then raise EEncode.Create('Io') else raise;
      end;
      if Mode = dmV4 then
      begin
        { dup_wrapper.cpp:254-262: meta || u64_le(meta_size) || "ODUP" }
        if Length(meta) > 0 then os.WriteBuffer(meta[0], Length(meta));
        SetLength(t, ODUP_TRAILER_SIZE);
        for i := 0 to 7 do t[i] := Byte(QWord(Length(meta)) shr (8 * i));
        t[8] := Ord('O'); t[9] := Ord('D'); t[10] := Ord('U'); t[11] := Ord('P');
        os.WriteBuffer(t[0], ODUP_TRAILER_SIZE);
      end;
      { del handle abierto, como el Rust: un FIFO contesta 0, y medirlo por
        el nombre lo volveria a abrir }
      Result := HandleSize(os.Handle);
    finally
      os.Free;
      bs.Free;
    end;
  finally
    DeleteTemp(body);
  end;
end;

{ seek(..)? de dup.rs: falla solo si falla la llamada al sistema, y entonces
  es DupError::Io. La posicion no se compara con nada (ver SeekOrFault). }
function SeekOrIo(S: TStream; Off: Int64; Origin: TSeekOrigin): QWord;
var r: Int64;
begin
  r := S.Seek(Off, Origin);
  if r < 0 then raise EDup.Create('Io');
  Result := QWord(r);
end;

{ read_exact_at: el seek que falla es Io; el read_exact que falla, por EOF o
  por un error del sistema (EISDIR), es Truncated }
function ReadAt(S: TStream; Off, N: QWord): TBytes;
begin
  { mas de lo que entra en un buffer (win32: 2 GB) es una meta que esta build
    no puede deshacer, y SetLength cortaria el largo en silencio (un -m3f de
    un archivo con 2^32+4096 en esos bytes desbordaba el heap) }
  if N > QWord(High(SizeInt)) then raise EDup.Create('BadDup');
  SetLength(Result, N);
  if Off > QWord(High(Int64)) then raise EDup.Create('Io');
  SeekOrIo(S, Int64(Off), soBeginning);
  if N > 0 then
    if ReadUpTo(S, Result[0], N) <> N then raise EDup.Create('Truncated');
end;

{ la meta de un v5, o nil si no la trae. Plain: un v5 sin la flag de -dup
  que termina en un footer v5 valido, que no lleva trailer ODUP (v5_meta) }
function V5Meta(S: TStream; Len: QWord; out Plain: Boolean): TBytes;
var head, tail, blob: TBytes; h: TV5Header; f: TV5Footer; blobLen, ending: QWord;
    crc: DWord;
begin
  Result := nil;
  Plain := False;
  if Len < V5_HEADER_SIZE + V5_FOOTER_SIZE then Exit;
  head := ReadAt(S, 0, V5_HEADER_SIZE);
  if not IsV5(head) then Exit;
  if DecodeV5Header(head, h) <> ceOK then raise EDup.Create('BadDup');
  tail := ReadAt(S, Len - V5_FOOTER_SIZE, V5_FOOTER_SIZE);
  if (h.Flags and V5_FLAG_HAS_DUP) = 0 then
  begin
    { sin un footer valido al final se olfatea el trailer: un cuerpo v5 bajo
      un trailer ODUP es lo que escribe la herramienta de F5.3a
      (tests/dup_native_roundtrip.sh) }
    Plain := DecodeV5Footer(tail, 0, f) = ceOK;
    Exit;
  end;
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

{ el trailer ODUP de un v4, chequeado sin leer la meta (odup_trailer): su
  meta_size, o IsDup False si los ultimos cuatro bytes no son ODUP. De la meta
  se leen solo los cuatro primeros bytes, la marca DUPR. }
function OdupTrailer(S: TStream; Len: QWord; out IsDup: Boolean): QWord;
var magic, sz, tag: TBytes; metaSize: QWord; i: LongInt;
begin
  Result := 0;
  IsDup := False;
  if Len < ODUP_TRAILER_SIZE then Exit;
  magic := ReadAt(S, Len - 4, 4);
  if not ((magic[0] = Ord('O')) and (magic[1] = Ord('D')) and (magic[2] = Ord('U')) and
          (magic[3] = Ord('P'))) then Exit;
  sz := ReadAt(S, Len - ODUP_TRAILER_SIZE, 8);
  metaSize := 0;
  for i := 7 downto 0 do metaSize := (metaSize shl 8) or QWord(sz[i]);
  if (metaSize > Len - ODUP_TRAILER_SIZE) or (metaSize < 4) then raise EDup.Create('BadDup');
  { un trailer ODUP cuya meta no es .dupref se rechaza (salvo que el archivo
    entero se lea como uno comun, que lo decide DupDecode) }
  tag := ReadAt(S, Len - ODUP_TRAILER_SIZE - metaSize, 4);
  if not ((tag[0] = Ord('D')) and (tag[1] = Ord('U')) and (tag[2] = Ord('P')) and
          (tag[3] = Ord('R'))) then raise EDup.Create('BadDup');
  IsDup := True;
  Result := metaSize;
end;

{ la meta de un trailer que paso OdupTrailer (read_meta); pasado
  High(SizeInt) (win32), BadDup, por el chequeo de ReadAt }
function ReadOdupMeta(S: TStream; Len, MetaSize: QWord): TBytes;
begin
  Result := ReadAt(S, Len - ODUP_TRAILER_SIZE - MetaSize, MetaSize);
end;

{ seek + read sin excepciones: False si no se pudo leer todo }
function PeekAt(S: TStream; Off: QWord; var Buf; N: QWord): Boolean;
begin
  Result := False;
  if Off > QWord(High(Int64)) then Exit;
  if S.Seek(Int64(Off), soBeginning) <> Int64(Off) then Exit;
  Result := ReadUpTo(S, Buf, N) = N;
end;

function LE32At(const B: array of Byte; At: LongInt): DWord;
begin
  Result := DWord(B[At]) or (DWord(B[At + 1]) shl 8) or (DWord(B[At + 2]) shl 16) or
            (DWord(B[At + 3]) shl 24);
end;

{ Los mismos chequeos que Archive::parse_with (y InspectCore), en el mismo
  orden, leyendo solo el header, los headers de bloque y (v4) el footer: -d
  no carga el archivo. La tabla del v4 se lee de a una entrada, a medida que
  los bloques llegan a ella, asi que un footer que dice tener una tabla
  enorme no cuesta nada hasta que los bloques la respaldan. }
function WalksAsPlain(S: TStream; Len: QWord; StatsOutOfLine: Boolean; out OrigSize: QWord): Boolean;
var
  hb: TBytes;
  h: TArchiveHeader;
  fh: TFooterHead;
  bh: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  e: array[0..3] of Byte;
  bhs, pos, tableSize, tableAt, entries, mls, need, inlineStat, tableSum, nb, ent: QWord;
  lit, orig, st: DWord;
  isV4: Boolean;
begin
  Result := False;
  OrigSize := 0;
  if Len < ARCHIVE_HEADER_SIZE then Exit;
  SetLength(hb, ARCHIVE_HEADER_SIZE);
  if not PeekAt(S, 0, hb[0], ARCHIVE_HEADER_SIZE) then Exit;
  if DecodeArchiveHeader(hb, h) <> ceOK then Exit;
  bhs := BLOCK_HEADER_SIZE + QWord(h.HashSize);
  pos := ARCHIVE_HEADER_SIZE + QWord(h.HashSeedSize);
  if pos > Len then Exit;
  isV4 := h.Version = 4;
  tableAt := 0;
  entries := 0;
  fh.TotalStatSize := 0;
  if isV4 then
  begin
    if Len < pos + INDEX_LZ_FOOTER_SIZE then Exit;
    SetLength(hb, INDEX_LZ_FOOTER_SIZE);
    if not PeekAt(S, Len - INDEX_LZ_FOOTER_SIZE, hb[0], INDEX_LZ_FOOTER_SIZE) then Exit;
    if DecodeFooterHead(hb, 0, fh) <> ceOK then Exit;
    if fh.FooterSize < INDEX_LZ_FOOTER_SIZE then Exit;
    tableSize := QWord(fh.FooterSize) - INDEX_LZ_FOOTER_SIZE;
    if QWord(fh.FooterSize) > Len then Exit;
    if fh.TotalStatSize > Len - QWord(fh.FooterSize) then Exit;
    mls := Len - QWord(fh.FooterSize) - fh.TotalStatSize;
    if (mls < pos) or ((tableSize mod 4) <> 0) then Exit;
    tableAt := Len - QWord(fh.FooterSize);
    entries := tableSize div 4;
  end
  else
    mls := Len;

  nb := 0;
  tableSum := 0;
  while pos <> mls do
  begin
    if mls - pos < bhs then Exit;
    if not PeekAt(S, pos, bh[0], BLOCK_HEADER_SIZE) then Exit;
    lit := LE32At(bh, 0);
    orig := LE32At(bh, 4);
    st := LE32At(bh, 8);
    { el terminador: los decoders paran ahi, pero ningun encoder lo escribe,
      y un -dup v1-v3 con el comienzo de la meta en cero se leeria como su
      propio cuerpo }
    if (not isV4) and (lit = 0) and (orig = 0) then Exit;
    if isV4 then
    begin
      if (nb >= entries) or (st <> 0) then Exit;
      if not PeekAt(S, tableAt + 4 * nb, e[0], 4) then Exit;
      ent := QWord(LE32At(e, 0));
      tableSum := tableSum + ent;
      inlineStat := 0;
    end
    else if StatsOutOfLine then
      inlineStat := 0
    else
      inlineStat := st;
    need := bhs + inlineStat + QWord(lit);
    if mls - pos < need then Exit;
    OrigSize := OrigSize + QWord(orig);
    Inc(nb);
    pos := pos + need;
  end;
  { cada entrada se sumo en el camino: el conteo coincide solo si los
    bloques las usaron todas }
  if isV4 then
    if (entries <> nb) or (tableSum <> fh.TotalStatSize) or
       (mls + fh.TotalStatSize <> tableAt) then Exit;
  Result := True;
end;

{ El cuerpo de un -dup, decodificado como lo hace dup.rs: un v5 directo por
  decode_v5, el cuerpo de un ODUP por archive::decode. Un rechazo sale como
  DupError::Decode, con el Debug del DecodeError adentro. La salida se abre en
  lectura-escritura: el decoder relee de ella los matches que caen en bloques
  anteriores (el Rust 2.1.2 la abria solo para escribir, con File::create, y
  esos archivos fallaban con EBADF). }
procedure DecodeAny(InS: TStream; const OutPath: AnsiString; const Opts: TFutureLzOptions;
                    V5: Boolean);
var outS: TRawFileStream; st: TFutureLzStats; err: TDecodeFault; ok: Boolean;
begin
  outS := CreateRaw(OutPath);
  if outS = nil then raise EDup.Create('Io');
  try
    if V5 then ok := DecodeV5(InS, outS, Opts, st, err) = deOK
    else ok := DecodeArchive(InS, outS, Opts, nil, err);
    if not ok then raise EDup.Create('Decode(' + FaultDebug(err) + ')');
  finally
    outS.Free;
  end;
end;

{ std::io::copy(&mut archive.take(n), &mut out)?: lo que haya hasta n bytes;
  un EOF antes no es un error, una falla de lectura o escritura es Io }
procedure CopyPrefix(Src: TStream; const OutPath: AnsiString; N: QWord);
var outS: TRawFileStream; buf: TBytes; want, got: QWord;
begin
  outS := CreateRaw(OutPath);
  if outS = nil then raise EDup.Create('Io');
  try
    SeekOrIo(Src, 0, soBeginning);
    SetLength(buf, 1 shl 16);
    while N > 0 do
    begin
      want := N;
      if want > QWord(Length(buf)) then want := Length(buf);
      try
        got := QWord(ReadOnceOrFault(Src, buf[0], LongInt(want)));
        if got = 0 then Break;
        WriteAllOrFault(outS, buf[0], got);
      except
        on X: EDecodeFault do raise EDup.Create('Io');
      end;
      Dec(N, got);
    end;
  finally
    outS.Free;
  end;
end;

function DupDecode(const InPath, OutPath: AnsiString; const Opts: TFutureLzOptions;
                   StatsOutOfLine: Boolean): Boolean;
var
  s: TRawFileStream;
  bodyIn: TFileStream;
  len, bodyLen, orig, metaSize: QWord;
  meta: TBytes;
  isOdup, isV5Plain, holds, haveMeta: Boolean;
  sm: TMetaSummary;
  sniffErr: AnsiString;
  body, decoded: AnsiString;
begin
  Result := False;
  { File::open(input)?: con el open crudo, como el Rust (un directorio abre, y
    falla despues en el read: Truncated) }
  s := OpenReadRaw(InPath);
  if s = nil then raise EDup.Create('Io');
  try
    len := SeekOrIo(s, 0, soEnd);
    meta := V5Meta(s, len, isV5Plain);
    isOdup := False;
    haveMeta := False;
    metaSize := 0;
    { un v5 que termina en su propio footer no lleva trailer ODUP: sus
      ultimos cuatro bytes son el CRC del footer, que es "ODUP" en uno de cada
      2^32 archivos, y 2.3.0 entonces rechazaba un archivo sano }
    if (meta = nil) and isV5Plain then Exit(False);
    if meta = nil then
    begin
      { decode_odup: el trailer se olfatea, y un Future-LZ/I/O LZ comun
        termina en sus ultimos literales, asi que el de un archivo que termina
        en "ODUP" (cualquier v4 -dup) termina en algo con forma de trailer,
        meta y todo. 2.3.0 y el C++ 1.0.7 lo cortaban y fallaban con lo que
        quedaba en -d archivo salida (-d - salida < archivo lo restauraba: el
        trailer se olfatea solo entre dos archivos con nombre). El trailer se
        toma solo si el archivo de atras se sostiene; si no, y el archivo
        entero se recorre como uno comun, se decodifica como uno comun (y sus
        bloques pasan sus chequeos, digests incluidos). Si ninguno se
        sostiene, corre el camino -dup y falla con el error de siempre: un
        -dup danado no se decodifica a su cuerpo.
        La meta se lee recien cuando el archivo de adelante se recorrio, o,
        en el camino -dup que falla, cuando el cuerpo ya se decodifico: en un
        archivo comun meta_size son bytes de la entrada, hasta el largo del
        archivo, y leerla primero costaba esa memoria (y en win32 desbordaba
        el buffer). }
      sniffErr := '';
      try
        metaSize := OdupTrailer(s, len, isOdup);
      except
        on X: EDup do sniffErr := X.Message;
      end;
      if (sniffErr = '') and not isOdup then Exit(False);
      { el -dup: el archivo delante de la meta se recorre entero, y la meta no
        pide mas cuerpo que el que decodifican sus bloques (la regla de
        with_dup, que aplica -i tambien) }
      holds := False;
      if (sniffErr = '') and WalksAsPlain(s, len - ODUP_TRAILER_SIZE - metaSize,
                                          StatsOutOfLine, orig) then
      begin
        meta := ReadOdupMeta(s, len, metaSize);
        haveMeta := True;
        try
          SummarizeMeta(meta, sm);
          holds := sm.BodySize <= orig;
        except
          on EDedup do holds := False;
        end;
      end;
      if (not holds) and WalksAsPlain(s, len, StatsOutOfLine, orig) then Exit(False);
      if sniffErr <> '' then raise EDup.Create(sniffErr);
    end;

    if not isOdup then
    begin
      { v5: el cuerpo se decodifica a un temporal, porque el post-paso vuelve
        a leerlo para expandir las referencias }
      body := NewTempPath('osrep-dup-body');
      try
        SeekOrIo(s, 0, soBeginning);
        DecodeAny(s, body, Opts, True);
        try
          DecodeStreaming(meta, body, OutPath);
        except
          on X: EDedup do raise EDup.Create(X.Message);
        end;
      finally
        DeleteTemp(body);
      end;
      Exit(True);
    end;

    { v4: el cuerpo esta en el archivo, tapado por el trailer; se recorta a un
      temporal antes de decodificarlo, como hace el C++ }
    bodyLen := len - ODUP_TRAILER_SIZE - metaSize;
    body := NewTempPath('osrep-dup-body-osr');
    decoded := '';
    try
      CopyPrefix(s, body, bodyLen);
      decoded := NewTempPath('osrep-dup-body-dec');
      try
        bodyIn := TFileStream.Create(body, fmOpenRead or fmShareDenyNone);
      except
        raise EDup.Create('Io');
      end;
      try
        DecodeAny(bodyIn, decoded, Opts, False);
      finally
        bodyIn.Free;
      end;
      { en el camino que falla la meta se lee al final: un cuerpo que no
        decodifica falla como siempre, sin reservar meta_size antes }
      if not haveMeta then meta := ReadOdupMeta(s, len, metaSize);
      try
        DecodeStreaming(meta, decoded, OutPath);
      except
        on X: EDedup do raise EDup.Create(X.Message);
      end;
    finally
      DeleteTemp(body);
      if decoded <> '' then DeleteTemp(decoded);
    end;
    Result := True;
  finally
    s.Free;
  end;
end;

end.
