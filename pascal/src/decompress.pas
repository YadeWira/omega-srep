unit Decompress;
{ El decoder de I/O-LZ (formatos v1 y v2, el sufijo `o`).

  Es el contenedor mas simple: cada bloque trae su lista de matches en linea y
  los matches apuntan HACIA ATRAS, asi que se reconstruye leyendo de una pasada
  y sin estado entre bloques. Future/Index-LZ (v3/v4) no es asi -- ahi los
  matches apuntan hacia adelante y hace falta el memory manager -- y va en su
  propia unidad.

  El destino se lee y se escribe, porque un match puede referirse a bloques ya
  emitidos: la parte que cae antes del bloque actual se trae del archivo de
  salida, no del buffer. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes, Container, Classes;

type
  TDecodeError = (deOK, deTruncated, deBadData, deDigestMismatch, deContainer,
                  deNotIoLz, deNotPortedYet, deIo);

  TDecodeStats = record
    Blocks: QWord;
    OrigSize: QWord;
    Verified: Boolean;   { lo que decidio el selector de digest, no una regla aparte }
  end;

function DecodeIoLz(const Arc: TBytes; Sink: TStream; out St: TDecodeStats): TDecodeError;

{ Copia con semantica LZ, compartida con el decoder Future-LZ. }
procedure LzCopy(var Buf: TBytes; Src, Dest, Len: QWord);

{ Asegura que el buffer de salida tenga al menos Need bytes, sin pasar de
  Logical (el largo que declara el bloque). False si no se puede reservar. }
function GrowOut(var Buf: TBytes; Need, Logical: QWord): Boolean;

{ ReadBuffer/WriteBuffer por tramos, para largos de 2 GiB o mas. }
procedure SinkRead(S: TStream; var Buf: TBytes; Off, Len: QWord);
procedure SinkWrite(S: TStream; const Buf: TBytes; Len: QWord);

implementation

uses Digest;

{ Copia con semantica LZ: `dest[i] := src[i]` evaluado EN ORDEN, asi que las
  lecturas posteriores ven lo ya escrito. Con distancia menor al largo eso
  replica un patron; un `Move` daria otra cosa. }
procedure LzCopy(var Buf: TBytes; Src, Dest, Len: QWord);
var i: QWord;
begin
  { `while` y no `for`: el largo es un QWord y en i386 FPC no acepta un QWord
    como variable de control. Aca no alcanza con un indice LongInt -- un match
    puede pasar los 2 GiB. Cuarta vez que aparece esta restriccion en el port;
    esta es la unica donde el tipo chico no sirve. }
  i := 0;
  while i < Len do
  begin
    Buf[Dest + i] := Buf[Src + i];
    Inc(i);
  end;
end;

{ El buffer de salida NO se reserva entero de entrada. El largo del bloque sale
  del archivo, y SetLength llena de ceros todo lo que reserva: un archivo roto
  de 109 bytes que declaraba un bloque de 3 GiB ocupaba 3 GiB reales antes de
  fallar, donde el Rust ocupa 11 MiB, porque su `vec![0u8; n]` pide paginas en
  cero que el sistema no entrega hasta que se escriben. Decenas de esos en
  paralelo (un fuzzer) tumbaron la maquina por OOM el 2026-09-26. En i386 era
  peor: el largo no entra en un SizeInt y fallaba con "Range check error" en vez
  del error del archivo.

  Se puede crecer sobre la marcha porque las escrituras en la salida son
  estrictamente SECUENCIALES en los dos decoders: el cursor solo avanza, cada
  paso escribe contiguo a partir de el, y el relleno final llega exacto al
  largo declarado. Asi un bloque sano termina del tamano exacto -- el digest
  no cambia -- y uno roto falla habiendo ocupado lo que escribio. }
const
  OUT_FIRST = QWord(16) shl 20;   { 16 MiB: un bloque normal entra de una vez }
  IO_CHUNK = QWord(1) shl 30;     { el conteo de Read/Write es un LongInt }

function GrowOut(var Buf: TBytes; Need, Logical: QWord): Boolean;
var want: QWord;
begin
  Result := True;
  if Need <= QWord(Length(Buf)) then Exit;
  if Need > Logical then Exit(False);
  want := QWord(Length(Buf)) * 2;
  if want < OUT_FIRST then want := OUT_FIRST;
  if want < Need then want := Need;
  if want > Logical then want := Logical;
  { en i386 SizeInt no llega a 2 GiB: un largo mayor se vuelve negativo }
  if want > QWord(High(SizeInt)) then Exit(False);
  SetLength(Buf, SizeInt(want));
end;

procedure SinkRead(S: TStream; var Buf: TBytes; Off, Len: QWord);
var n: QWord;
begin
  while Len > 0 do
  begin
    n := Len;
    if n > IO_CHUNK then n := IO_CHUNK;
    S.ReadBuffer(Buf[Off], LongInt(n));
    Inc(Off, n);
    Dec(Len, n);
  end;
end;

procedure SinkWrite(S: TStream; const Buf: TBytes; Len: QWord);
var off, n: QWord;
begin
  off := 0;
  while Len > 0 do
  begin
    n := Len;
    if n > IO_CHUNK then n := IO_CHUNK;
    S.WriteBuffer(Buf[off], LongInt(n));
    Inc(off, n);
    Dec(Len, n);
  end;
end;

function DecompressBlock(RoundMatches: Boolean; L: QWord; Sink: TStream;
                         BlockStart: QWord; const Stats: array of DWord;
                         const Literals: TBytes; var OutBuf: TBytes;
                         OutLen: QWord): TDecodeError;
var
  per, st: LongInt;
  l1, litLen, offset, mlen, basicPos, dest, src, bytes: QWord;
  inPos, outPos: QWord;
begin
  if RoundMatches then begin per := 3; l1 := L; end
  else begin per := 4; l1 := 1; end;

  st := 0; inPos := 0; outPos := 0;
  while (Length(Stats) - st) >= per do
  begin
    litLen := QWord(Stats[st]); Inc(st);
    offset := QWord(Stats[st]); Inc(st);
    if not RoundMatches then
    begin
      offset := offset + (QWord(Stats[st]) shl 32);
      Inc(st);
    end;
    offset := offset * l1;
    mlen := QWord(Stats[st]) * l1 + L; Inc(st);

    basicPos := BlockStart + outPos;
    dest := basicPos + litLen;
    { Un v1 con base_len = 0 divide por cero. El Rust hace panic justo aca (y
      el C++ muere con SIGFPE); se falla limpio en el mismo punto, asi que un
      v1 asi SIN records sigue decodificando, como en el Rust. }
    if l1 = 0 then Exit(deBadData);
    { Redondea el destino hacia abajo a un multiplo de L1 y resta el offset.
      La resta se envuelve como el `Offset` sin signo del C; el chequeo
      `src >= dest` de abajo descarta el resultado. }
    src := (dest div l1 * l1) - offset;

    if (litLen > QWord(Length(Literals)) - inPos) or
       (litLen + mlen > OutLen - outPos) or
       (src >= dest) then Exit(deBadData);
    if not GrowOut(OutBuf, outPos + litLen + mlen, OutLen) then Exit(deIo);

    if litLen > 0 then Move(Literals[inPos], OutBuf[outPos], litLen);
    Inc(inPos, litLen); Inc(outPos, litLen);

    { Lo que cae antes de este bloque viene del archivo de salida. }
    if src < BlockStart then
    begin
      bytes := BlockStart - src;
      if bytes > mlen then bytes := mlen;
      Sink.Seek(Int64(src), soBeginning);
      SinkRead(Sink, OutBuf, outPos, bytes);
      Inc(outPos, bytes); Inc(src, bytes); Dec(mlen, bytes);
    end;

    if mlen > 0 then LzCopy(OutBuf, src - BlockStart, outPos, mlen);
    Inc(outPos, mlen);
  end;

  { Los literales que sobran tienen que llenar exactamente el resto. }
  if (QWord(Length(Literals)) - inPos) <> (OutLen - outPos) then
    Exit(deBadData);
  { siempre, aunque no sobren literales: el bloque sale del largo exacto }
  if not GrowOut(OutBuf, OutLen, OutLen) then Exit(deIo);
  if inPos < QWord(Length(Literals)) then
    Move(Literals[inPos], OutBuf[outPos], QWord(Length(Literals)) - inPos);
  Result := deOK;
end;

function DecodeIoLz(const Arc: TBytes; Sink: TStream; out St: TDecodeStats): TDecodeError;
var
  h: TArchiveHeader;
  ce: TContainerError;
  seed, literals, outbuf, want: TBytes;
  stats: array of DWord;
  bh: TBlockHeader;
  pos, blockStart: QWord;
  headerSize: QWord;
  i: LongInt;
  de: TDecodeError;
  verified: Boolean;
  dig: TDigestSel;
  got: TBytes;
  k: LongInt;
begin
  St.Blocks := 0; St.OrigSize := 0; St.Verified := False;
  outbuf := nil;                   { GrowOut parte de lo que haya }
  { Un archivo v5 es valido, solo que su decoder es otra fase. Decir "no es un
    archivo omega srep" seria mentir sobre un archivo sano, que es justo el
    tipo de mensaje que este proyecto trata de no dar. }
  if IsV5(Arc) then Exit(deNotPortedYet);
  ce := DecodeArchiveHeader(Arc, h);
  if ce <> ceOK then Exit(deContainer);
  { Idem v3/v4: son archivos buenos que este decoder todavia no hace. }
  if (h.Version <> 1) and (h.Version <> 2) then Exit(deNotPortedYet);

  pos := ARCHIVE_HEADER_SIZE;
  SetLength(seed, h.HashSeedSize);
  if h.HashSeedSize > 0 then
  begin
    if QWord(Length(Arc)) < pos + h.HashSeedSize then Exit(deTruncated);
    Move(Arc[pos], seed[0], h.HashSeedSize);
    Inc(pos, h.HashSeedSize);
  end;
  { Digest::for_archive: un hash desconocido o tamanos que exceden al
    descriptor NO son error, simplemente no se verifica. La 4a tenia
    `HashNum <> 1`, que falla en esos casos. }
  DigestForArchive(h.HashNum, h.HashSeedSize, h.HashSize, seed, dig);
  verified := DigestEnabled(dig);
  St.Verified := verified;

  headerSize := QWord(BLOCK_HEADER_SIZE) + QWord(h.HashSize);
  blockStart := 0;

  while pos < QWord(Length(Arc)) do
  begin
    if QWord(Length(Arc)) < pos + headerSize then Exit(deTruncated);
    ce := DecodeBlockHeader(Arc, pos, bh);
    if ce <> ceOK then Exit(deContainer);
    { Un bloque de largo cero cierra el stream. }
    if (bh.LiteralBytes = 0) and (bh.OrigSize = 0) then Break;

    SetLength(want, h.HashSize);
    if h.HashSize > 0 then Move(Arc[pos + BLOCK_HEADER_SIZE], want[0], h.HashSize);
    Inc(pos, headerSize);

    { Primero que este, DESPUES que sea multiplo de 4: al reves, un archivo
      truncado da BadData donde el Rust da Truncated. Lo encontro el critico de
      la fase 4b. }
    if QWord(Length(Arc)) < pos + QWord(bh.StatSize) then Exit(deTruncated);
    if (bh.StatSize mod 4) <> 0 then Exit(deBadData);
    SetLength(stats, bh.StatSize div 4);
    for i := 0 to High(stats) do
      stats[i] := DWord(Arc[pos + QWord(i)*4]) or (DWord(Arc[pos + QWord(i)*4+1]) shl 8) or
                  (DWord(Arc[pos + QWord(i)*4+2]) shl 16) or (DWord(Arc[pos + QWord(i)*4+3]) shl 24);
    Inc(pos, bh.StatSize);

    if QWord(Length(Arc)) < pos + bh.LiteralBytes then Exit(deTruncated);
    SetLength(literals, bh.LiteralBytes);
    if bh.LiteralBytes > 0 then Move(Arc[pos], literals[0], bh.LiteralBytes);
    Inc(pos, bh.LiteralBytes);

    { se reusa el buffer del bloque anterior; solo tiene que no sobrar }
    if QWord(Length(outbuf)) > QWord(bh.OrigSize) then SetLength(outbuf, bh.OrigSize);
    de := DecompressBlock(h.Version = 1, QWord(h.BaseLen), Sink, blockStart,
                          stats, literals, outbuf, QWord(bh.OrigSize));
    if de <> deOK then Exit(de);

    if verified then
    begin
      got := DigestCompute(dig, outbuf);
      if QWord(h.HashSize) < QWord(Length(got)) then Exit(deDigestMismatch);
      for k := 0 to Length(got) - 1 do
        if want[k] <> got[k] then Exit(deDigestMismatch);
    end;

    Sink.Seek(Int64(blockStart), soBeginning);
    SinkWrite(Sink, outbuf, QWord(bh.OrigSize));
    Inc(blockStart, bh.OrigSize);
    Inc(St.Blocks);
  end;

  St.OrigSize := blockStart;
  Result := deOK;
end;

end.
