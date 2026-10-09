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

uses SysUtils, Widths, Hashes, Container, Classes, DecFault;   { SysUtils antes de Hashes: TBytes }

type
  TDecodeError = (deOK, deTruncated, deBadData, deDigestMismatch, deContainer,
                  deNotIoLz, deNotPortedYet, deIo);

  TDecodeStats = record
    Blocks: QWord;
    OrigSize: QWord;
    Verified: Boolean;   { lo que decidio el selector de digest, no una regla aparte }
  end;

  { progreso: Done de Total bytes del archivo (lo que cuenta -bar) }
  TDecodeProgress = procedure(Done, Total: QWord);

{ decode_io_lz: v1/v2 leidos del stream, sin cargar el archivo entero. Index,
  si no es nil, es el archivo de -index= de donde salen las listas de matches.
  Err lleva el error con su estructura (decfault.pas): Err.Msg es el texto de
  las herramientas, FaultDebug(Err) el Debug que imprime la CLI. }
function DecodeIoLz(Input, Sink: TStream; Index: TStream; out St: TDecodeStats;
                    out Err: TDecodeFault; Progress: TDecodeProgress = nil): TDecodeError;

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
    ReadExactOrFault(S, Buf[Off], n);
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
    WriteAllOrFault(S, Buf[off], n);
    Inc(off, n);
    Dec(Len, n);
  end;
end;

function DecompressBlock(RoundMatches: Boolean; L: QWord; Sink: TStream;
                         BlockStart: QWord; const Stats: array of DWord;
                         const Literals: TBytes; var OutBuf: TBytes;
                         OutLen: QWord; out Err: TDecodeFault): TDecodeError;
var
  per, st: LongInt;
  l1, litLen, offset, mlen, basicPos, dest, src, bytes: QWord;
  inPos, outPos: QWord;
begin
  Err := NoFault;
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
    { Un v1 con base_len = 0 divide por cero. El Rust hacia panic justo aca
      hasta el 2026-10-09 (y el C++ muere con SIGFPE); los dos fallan limpio en el
      mismo punto, asi que un v1 asi SIN records sigue decodificando. }
    if l1 = 0 then
    begin
      Err := FaultBadData('v1 archive with a zero base length');
      Exit(deBadData);
    end;
    { Redondea el destino hacia abajo a un multiplo de L1 y resta el offset.
      La resta se envuelve como el `Offset` sin signo del C; el chequeo
      `src >= dest` de abajo descarta el resultado. }
    src := (dest div l1 * l1) - offset;

    if (litLen > QWord(Length(Literals)) - inPos) or
       (litLen + mlen > OutLen - outPos) or
       (src >= dest) then
    begin
      Err := FaultBadData('record does not fit the block');
      Exit(deBadData);
    end;
    if not GrowOut(OutBuf, outPos + litLen + mlen, OutLen) then
    begin
      Err := FaultOutOfMemory;
      Exit(deIo);
    end;

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
  begin
    Err := FaultBadData('literal run does not fill the block');
    Exit(deBadData);
  end;
  { siempre, aunque no sobren literales: el bloque sale del largo exacto }
  if not GrowOut(OutBuf, OutLen, OutLen) then
  begin
    Err := FaultOutOfMemory;
    Exit(deIo);
  end;
  if inPos < QWord(Length(Literals)) then
    Move(Literals[inPos], OutBuf[outPos], QWord(Length(Literals)) - inPos);
  Result := deOK;
end;

type
  TRd = (rdOK, rdEOF, rdPartial);

{ read_exact_or_eof para un largo que declara el archivo: el buffer crece a
  medida que llegan los datos (ver GrowOut). }
function ReadDecl(S: TStream; var B: TBytes; N: QWord): TRd;
var got: LongInt; pos, cap, chunk: QWord;
begin
  if N = 0 then
  begin
    SetLength(B, 0);
    Exit(rdOK);
  end;
  cap := N;
  if cap > OUT_FIRST then cap := OUT_FIRST;
  SetLength(B, SizeInt(cap));
  pos := 0;
  while pos < N do
  begin
    if pos = cap then
    begin
      cap := cap * 2;
      if cap > N then cap := N;
      if cap > QWord(High(SizeInt)) then raise EDecodeFault.CreateFault(FaultOutOfMemory);
      SetLength(B, SizeInt(cap));
    end;
    chunk := cap - pos;
    if chunk > IO_CHUNK then chunk := IO_CHUNK;
    got := ReadOnceOrFault(S, B[pos], LongInt(chunk));
    if got <= 0 then
    begin
      if pos = 0 then Exit(rdEOF) else Exit(rdPartial);
    end;
    Inc(pos, QWord(got));
  end;
  Result := rdOK;
end;

function DecodeIoLz(Input, Sink: TStream; Index: TStream; out St: TDecodeStats;
                    out Err: TDecodeFault; Progress: TDecodeProgress = nil): TDecodeError;
var
  h: TArchiveHeader;
  ce: TContainerError;
  hb, seed, blockBuf, statBytes, literals, outbuf, got: TBytes;
  stats: array of DWord;
  bh: TBlockHeader;
  blockStart, headerSize, total, consumed, i: QWord;
  k: LongInt;
  de: TDecodeError;
  verified: Boolean;
  dig: TDigestSel;
  rd: TRd;
  src: TStream;
begin
  St.Blocks := 0; St.OrigSize := 0; St.Verified := False;
  Err := NoFault;
  outbuf := nil;
  total := 0;
  try
    { -bar cuenta el archivo: el total se mide antes de leer nada }
    if Assigned(Progress) then
    begin
      total := QWord(Input.Seek(0, soEnd));
      Input.Seek(0, soBeginning);
    end;
    if ReadDecl(Input, hb, ARCHIVE_HEADER_SIZE) <> rdOK then
    begin
      Err := FaultContainer(ckTruncated);
      Exit(deTruncated);
    end;
    if IsV5(hb) then
    begin
      Err := FaultNotIoLz(5);
      Exit(deNotIoLz);
    end;
    ce := DecodeArchiveHeader(hb, h);
    if ce = ceNotAnOsrepFile then begin Err := FaultContainer(ckNotAnOsrepFile); Exit(deContainer); end;
    if ce <> ceOK then begin Err := FaultContainer(ckUnsupportedVersion, h.Version); Exit(deContainer); end;
    if (h.Version <> 1) and (h.Version <> 2) then
    begin
      Err := FaultNotIoLz(h.Version);
      Exit(deNotIoLz);
    end;

    if ReadDecl(Input, seed, QWord(h.HashSeedSize)) <> rdOK then
    begin
      Err := FaultContainer(ckTruncated);
      Exit(deTruncated);
    end;
    { Digest::for_archive: un hash desconocido o tamanos que exceden al
      descriptor NO son error, simplemente no se verifica }
    DigestForArchive(h.HashNum, h.HashSeedSize, h.HashSize, seed, dig);
    verified := DigestEnabled(dig);
    St.Verified := verified;

    headerSize := QWord(BLOCK_HEADER_SIZE) + QWord(h.HashSize);
    blockStart := 0;
    consumed := QWord(ARCHIVE_HEADER_SIZE) + QWord(h.HashSeedSize);
    if Index <> nil then src := Index else src := Input;

    while True do
    begin
      rd := ReadDecl(Input, blockBuf, headerSize);
      if rd = rdEOF then Break;
      if rd = rdPartial then begin Err := FaultContainer(ckTruncated); Exit(deTruncated); end;
      DecodeBlockHeader(blockBuf, 0, bh);
      { un bloque de largo cero cierra el stream }
      if (bh.LiteralBytes = 0) and (bh.OrigSize = 0) then Break;

      { primero que este, DESPUES que sea multiplo de 4 }
      if ReadDecl(src, statBytes, QWord(bh.StatSize)) <> rdOK then
      begin
        Err := FaultContainer(ckTruncated);
        Exit(deTruncated);
      end;
      if (bh.StatSize mod 4) <> 0 then
      begin
        Err := FaultBadData('match list is not a whole number of STATs');
        Exit(deBadData);
      end;
      SetLength(stats, bh.StatSize div 4);
      i := 0;
      while i < QWord(bh.StatSize) div 4 do
      begin
        stats[i] := DWord(statBytes[i * 4]) or (DWord(statBytes[i * 4 + 1]) shl 8) or
                    (DWord(statBytes[i * 4 + 2]) shl 16) or (DWord(statBytes[i * 4 + 3]) shl 24);
        Inc(i);
      end;
      if ReadDecl(Input, literals, QWord(bh.LiteralBytes)) <> rdOK then
      begin
        Err := FaultContainer(ckTruncated);
        Exit(deTruncated);
      end;

      if QWord(Length(outbuf)) > QWord(bh.OrigSize) then SetLength(outbuf, bh.OrigSize);
      de := DecompressBlock(h.Version = 1, QWord(h.BaseLen), Sink, blockStart,
                            stats, literals, outbuf, QWord(bh.OrigSize), Err);
      if de <> deOK then Exit(de);

      if verified then
      begin
        got := DigestCompute(dig, outbuf);
        { un digest declarado mas corto que el hash no puede coincidir }
        if QWord(h.HashSize) < QWord(Length(got)) then
        begin
          Err := FaultDigest(St.Blocks);
          Exit(deDigestMismatch);
        end;
        for k := 0 to Length(got) - 1 do
          if blockBuf[BLOCK_HEADER_SIZE + k] <> got[k] then
          begin
            Err := FaultDigest(St.Blocks);
            Exit(deDigestMismatch);
          end;
      end;

      Sink.Seek(Int64(blockStart), soBeginning);
      SinkWrite(Sink, outbuf, QWord(bh.OrigSize));
      Inc(blockStart, bh.OrigSize);
      Inc(St.Blocks);
      consumed := consumed + headerSize + QWord(bh.StatSize) + QWord(bh.LiteralBytes);
      if Assigned(Progress) then Progress(consumed, total);
    end;
    { un ultimo tick asegurado: el consumidor siempre ve done == total }
    if Assigned(Progress) then Progress(total, total);
    St.OrigSize := blockStart;
    Result := deOK;
  except
    on X: Exception do
    begin
      Err := FaultOfException(X);
      Result := deIo;
    end;
  end;
end;

end.
