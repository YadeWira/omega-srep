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
                  deNotIoLz, deNotPortedYet);

  TDecodeStats = record
    Blocks: QWord;
    OrigSize: QWord;
  end;

function DecodeIoLz(const Arc: TBytes; Sink: TStream; out St: TDecodeStats): TDecodeError;

implementation

uses HashesKeyed, AES, Vmac;

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

{ El digest del bloque, segun el descriptor del archivo. }
function BlockDigest(HashNum: Byte; const Seed, Data: TBytes): TBytes;
var vk: TVmac;
begin
  case HashNum of
    0: Result := MD5(Data);
    2: Result := SHA1(Data);
    3: Result := SHA512(Data);
    4: begin VmacSetKey(Seed, vk); Result := VmacCompute(vk, Data); end;
    5: Result := SipHash(Seed, Data);
  else
    SetLength(Result, 0);   { num 1: checksums deshabilitados }
  end;
end;

function DecompressBlock(RoundMatches: Boolean; L: QWord; Sink: TStream;
                         BlockStart: QWord; const Stats: array of DWord;
                         const Literals: TBytes; var OutBuf: TBytes): TDecodeError;
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
    { Redondea el destino hacia abajo a un multiplo de L1 y resta el offset.
      La resta se envuelve como el `Offset` sin signo del C; el chequeo
      `src >= dest` de abajo descarta el resultado. }
    src := (dest div l1 * l1) - offset;

    if (litLen > QWord(Length(Literals)) - inPos) or
       (litLen + mlen > QWord(Length(OutBuf)) - outPos) or
       (src >= dest) then Exit(deBadData);

    if litLen > 0 then Move(Literals[inPos], OutBuf[outPos], litLen);
    Inc(inPos, litLen); Inc(outPos, litLen);

    { Lo que cae antes de este bloque viene del archivo de salida. }
    if src < BlockStart then
    begin
      bytes := BlockStart - src;
      if bytes > mlen then bytes := mlen;
      Sink.Seek(Int64(src), soBeginning);
      Sink.ReadBuffer(OutBuf[outPos], bytes);
      Inc(outPos, bytes); Inc(src, bytes); Dec(mlen, bytes);
    end;

    if mlen > 0 then LzCopy(OutBuf, src - BlockStart, outPos, mlen);
    Inc(outPos, mlen);
  end;

  { Los literales que sobran tienen que llenar exactamente el resto. }
  if (QWord(Length(Literals)) - inPos) <> (QWord(Length(OutBuf)) - outPos) then
    Exit(deBadData);
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
begin
  St.Blocks := 0; St.OrigSize := 0;
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
  verified := h.HashNum <> 1;

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

    if (bh.StatSize mod 4) <> 0 then Exit(deBadData);
    if QWord(Length(Arc)) < pos + bh.StatSize then Exit(deTruncated);
    SetLength(stats, bh.StatSize div 4);
    for i := 0 to High(stats) do
      stats[i] := DWord(Arc[pos + QWord(i)*4]) or (DWord(Arc[pos + QWord(i)*4+1]) shl 8) or
                  (DWord(Arc[pos + QWord(i)*4+2]) shl 16) or (DWord(Arc[pos + QWord(i)*4+3]) shl 24);
    Inc(pos, bh.StatSize);

    if QWord(Length(Arc)) < pos + bh.LiteralBytes then Exit(deTruncated);
    SetLength(literals, bh.LiteralBytes);
    if bh.LiteralBytes > 0 then Move(Arc[pos], literals[0], bh.LiteralBytes);
    Inc(pos, bh.LiteralBytes);

    SetLength(outbuf, bh.OrigSize);
    de := DecompressBlock(h.Version = 1, QWord(h.BaseLen), Sink, blockStart,
                          stats, literals, outbuf);
    if de <> deOK then Exit(de);

    if verified and (h.HashSize > 0) then
      if ToHex(BlockDigest(h.HashNum, seed, outbuf)) <> ToHex(want) then
        Exit(deDigestMismatch);

    Sink.Seek(Int64(blockStart), soBeginning);
    if bh.OrigSize > 0 then Sink.WriteBuffer(outbuf[0], bh.OrigSize);
    Inc(blockStart, bh.OrigSize);
    Inc(St.Blocks);
  end;

  St.OrigSize := blockStart;
  Result := deOK;
end;

end.
