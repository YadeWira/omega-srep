unit Encoder;
{ El driver de compresion (encoder.rs): lo que la primera pasada de srep.cpp
  hace alrededor de los compresores de cada modo, y lo que el hilo de fondo de
  io.cpp hace por ella. El C++ solapa leer un bloque con comprimir el anterior
  por un anillo de dos ranuras; las dos ordenes dan los mismos bytes (medido:
  -t1 contra -t8), asi que se corre en secuencia.

  La lectura adelantada no es solo velocidad: compress lee unos bytes pasado
  el final del bloque (el lote de cuatro se pasa de next_chunk), y en el C++
  esos bytes son la ranura siguiente del anillo -- que el hilo de fondo ya
  suele haber llenado con el bloque que sigue. Leer un bloque adelante lo
  reproduce de forma determinista.

  Todos los compresores (-m0 a -m5, con -d) y los cuatro contenedores:
  I/O-LZ (sufijo o, v1/v2) en una pasada; Index-LZ (v4), Future-LZ (sufijo f,
  v3) y v5 con la segunda pasada. -dup es la fase 6. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, Container, LzCodec, HashTable, FixedCompress;


const
  DEFAULT_BUFSIZE  = QWord(8) shl 20;        { -b, srep.cpp:288 }
  DEFAULT_DICTSIZE = QWord(512) shl 20;      { -d de -m0, srep.cpp:285,445 }

type
  TEncKind = (ekInmem, ekCdc, ekCdcZpaq, ekDigest, ekFixed, ekFixedExhaustive);
  TEncContainer = (ecIoLz, ecIndexLz, ecFutureLz, ecV5);

  TEncodeOptions = record
    BufSize: QWord;          { -b }
    DictSize: QWord;         { -d; 0 = sin pase en memoria }
    DictHashSize: QWord;     { -dh }
    MinMatch: QWord;         { -l; 0 = el default del modo }
    DictMinMatch: QWord;     { -dl; 0 = 512 }
    DictChunk: QWord;        { -dc; 0 = DictMinMatch/8 }
    L: QWord;                { -c; 0 = derivado de MinMatch }
    HasSeed: Boolean;
    Seed: QWord;             { --seed=N }
    Hash: AnsiString;        { -hash=; '' = -hash- }
    { la meta .dupref de -dup que viaja adentro de un v5 (vacia = sin -dup) }
    DupMeta: TBytes;
  end;

  { Lo que el modo todavia no tiene portado. }
  ENotPorted = class(Exception);

procedure DefaultEncodeOptions(out O: TEncodeOptions);

{ osrep_fill_seed_from (srep.cpp:251-261): xorshift64, un byte por paso. }
procedure FillSeedFrom(var Out_: TBytes; Seed64: QWord);

{ Comprime Input en Output. Errores: EEncode (el Debug del Rust en el
  mensaje), ENotPorted. }
procedure Encode(Input, Output: TStream; const Opts: TEncodeOptions; Kind: TEncKind;
                 Cont: TEncContainer);

implementation

uses Rolling, HashesKeyed, Vmac, Inmem, Cdc, SecondPass;

const
  BUFFERS = 2;           { io.cpp:90: el anillo lleva dos bloques de margen }

procedure DefaultEncodeOptions(out O: TEncodeOptions);
begin
  O.BufSize := DEFAULT_BUFSIZE;
  O.DictSize := 0;
  O.DictHashSize := 0;
  O.MinMatch := 0;
  O.DictMinMatch := 0;
  O.DictChunk := 0;
  O.L := 0;
  O.HasSeed := False;
  O.Seed := 0;
  O.Hash := 'vmac';
  O.DupMeta := nil;
end;

procedure FillSeedFrom(var Out_: TBytes; Seed64: QWord);
var s: QWord; i: LongInt;
begin
  s := Seed64;
  for i := 0 to Length(Out_) - 1 do
  begin
    s := s xor (s shl 13);
    s := s xor (s shr 7);
    s := s xor (s shl 17);
    Out_[i] := Byte(s and $FF);
  end;
end;

{ ------------------------------------------------------ block hasher --- }

type
  TBlockHasher = record
    Name: AnsiString;
    Key: TBytes;
    VmacKey: TVmac;
  end;

procedure HasherInit(out H: TBlockHasher; const Info: THashInfo; const Seed: TBytes);
begin
  H.Name := Info.Name;
  H.Key := Copy(Seed);
  if H.Name = 'vmac' then VmacSetKey(Seed, H.VmacKey);
end;

{ hash_func(hash_obj, buf, size, header+3). El desactivado nunca corre en el
  C++ -- la cabecera es calloc, asi que el digest queda en ceros. }
function HasherCompute(const H: TBlockHasher; const B: TBytes; At, Len: QWord;
                       out D: TBytes): Boolean;
var m: TBytes;
begin
  Result := H.Name <> '';
  if not Result then Exit;
  SetLength(m, Len);
  if Len > 0 then Move(B[At], m[0], Len);
  if H.Name = 'md5' then D := MD5(m)
  else if H.Name = 'sha1' then D := SHA1(m)
  else if H.Name = 'sha512' then D := SHA512(m)
  else if H.Name = 'vmac' then D := VmacCompute(H.VmacKey, m)
  else if H.Name = 'siphash' then D := SipHash(H.Key, m)
  else Result := False;
end;

{ ------------------------------------------------------------ helpers --- }

function RoundUp(A, B: QWord): QWord;
begin
  if (A <> 0) and (B > 1) then Result := ((A - 1) div B) * B + B else Result := A;
end;

{ Un fread en un offset explicito. El offset no sobra: match_len re-lee el
  MISMO stream en cualquier posicion, asi que las lecturas secuenciales se
  re-anclan cada vez. }
function ReadBlockAt(S: TStream; Off: QWord; var B: TBytes; At, Len: QWord): QWord;
var got: LongInt;
begin
  Result := 0;
  S.Seek(Int64(Off), soBeginning);
  while Result < Len do
  begin
    got := S.Read(B[At + Result], LongInt(Len - Result));
    if got <= 0 then Break;
    Inc(Result, QWord(got));
  end;
end;

procedure PutLE32(var B: TBytes; At: QWord; V: DWord); inline;
begin
  B[At] := Byte(V); B[At + 1] := Byte(V shr 8);
  B[At + 2] := Byte(V shr 16); B[At + 3] := Byte(V shr 24);
end;

{ Hace crecer el anillo (en ceros) hasta cubrir Need bytes, sin pasar de Ring. }
procedure RingEnsure(var D: TBytes; Need, Ring: QWord);
var want: QWord;
begin
  if Need <= QWord(Length(D)) then Exit;
  want := QWord(Length(D)) * 2;
  if want < Need then want := Need;
  if want > Ring then want := Ring;
  SetLength(D, want);
end;

procedure WriteStats(S: TStream; const Stat: TStatList);
var b: TBytes; i: QWord;
begin
  if Stat.N = 0 then Exit;
  SetLength(b, Stat.N * 4);
  i := 0;
  while i < Stat.N do
  begin
    PutLE32(b, i * 4, Stat.W[i]);
    Inc(i);
  end;
  S.WriteBuffer(b[0], LongInt(Length(b)));
end;

{ Los runs de literales que save_data escribe entre los records, en el orden
  de los records. }
procedure WriteLiterals(Output: TStream; const Dict: TBytes; BufOffset, Filled: QWord;
                        const Stat: TStatList; RoundMatches: Boolean; BaseLen: DWord);
var inPos, at, used, lit: QWord; m: TLzMatch;
begin
  inPos := 0;
  at := 0;
  while Stat.N - at >= StatsPerMatch(RoundMatches) do
  begin
    if not DecodeLzMatch(Stat, at, RoundMatches, False, BaseLen, 0, m, used) then
      raise EEncode.Create('BadBlockRecord');
    lit := QWord(m.LitLen);
    if lit > Filled - inPos then raise EEncode.Create('BadBlockRecord');
    if lit > 0 then Output.WriteBuffer(Dict[BufOffset + inPos], LongInt(lit));
    inPos := inPos + lit + QWord(m.Len);
    if inPos > Filled then raise EEncode.Create('BadBlockRecord');
    at := at + used;
  end;
  if Filled > inPos then Output.WriteBuffer(Dict[BufOffset + inPos], LongInt(Filled - inPos));
end;

{ ------------------------------------------------------------- driver --- }

procedure Encode(Input, Output: TStream; const Opts: TEncodeOptions; Kind: TEncKind;
                 Cont: TEncContainer);
var
  info: THashInfo;
  hasher: TBlockHasher;
  seed, dict, header, digest: TBytes;
  minMatch, l, dictMinMatch, baseLen, bufsize, fileSize, ringSize: QWord;
  roundMatches, cdc: Boolean;
  ah: TArchiveHeader;
  bh: TBlockHeader;
  table: THashTableRec;
  bufOffset, nextPos, filled, blockStart, nextOffset, nextFilled: QWord;
  stat, inStat: TStatList;
  literalBytes: DWord;
  hb: TBytes;
  dictChunk: QWord;
  inmem: TDictCompressor;
  hashptr: TQList;
  chunkKey: TVmac;
  ioLz, indexLz, futureLz, v5: Boolean;
  storedHashSize, futurelzBaseLen: QWord;
  v5h: TV5Header;
  blocks: TCompressedBlocks;
  nblocks: QWord;
begin
  if not HashByName(Opts.Hash, info) then
    raise EEncode.Create('UnknownHash("' + Opts.Hash + '")');
  cdc := Kind in [ekCdc, ekCdcZpaq];
  ioLz := Cont = ecIoLz;
  indexLz := Cont = ecIndexLz;
  futureLz := Cont = ecFutureLz;
  v5 := Cont = ecV5;

  { los defaults de las opciones (srep.cpp:448-457), en el orden del C++ }
  minMatch := Opts.MinMatch;
  l := Opts.L;
  if (l = 0) and (minMatch = 0) then
    if cdc then minMatch := 4096 else minMatch := 512;
  if l = 0 then
  begin
    if cdc then begin l := minMatch; minMatch := 0; end
    else if Kind = ekFixedExhaustive then l := RounddownToPowerOfTwo(minMatch + 1) div 2
    else l := minMatch;
  end;
  if minMatch = 0 then
    if cdc then minMatch := 32 else minMatch := l;
  if Opts.DictMinMatch <> 0 then dictMinMatch := Opts.DictMinMatch else dictMinMatch := 512;
  { -dc, NO -c: el compresor en memoria se arma con dict_chunk (srep.cpp:663) }
  if Opts.DictChunk <> 0 then dictChunk := Opts.DictChunk else dictChunk := dictMinMatch div 8;
  baseLen := minMatch;
  if dictMinMatch < baseLen then baseLen := dictMinMatch;
  bufsize := Opts.BufSize;

  { ROUND_MATCHES = (-m3) && dictsize == 0: -m3o escribe v1 con records de 3 }
  roundMatches := (Kind = ekDigest) and (Opts.DictSize = 0);

  { la semilla del archivo: sin --seed el C++ la saca de Fortuna }
  SetLength(seed, info.SeedSize);
  if info.SeedSize > 0 then
  begin
    if not Opts.HasSeed then raise EEncode.Create('NeedsSeed');
    FillSeedFrom(seed, Opts.Seed);
  end;
  HasherInit(hasher, info, seed);

  { v5 no guarda digest con -hash- (hash_size = 0); v1-v4 siempre reservan
    los 16 bytes del descriptor. Dimensionar la cabecera de bloque por el
    descriptor en los dos casos desincroniza todos los bloques de v5. }
  if v5 and (info.Name = '') then storedHashSize := 0 else storedHashSize := info.HashSize;
  { header[3] = FUTURELZ_BASE_LEN = IO_LZ ? BASE_LEN : 0 (srep.cpp:458): el
    decoder v3/v4 lee de aca la base del largo, y 0 da largos crudos }
  if ioLz then futurelzBaseLen := baseLen else futurelzBaseLen := 0;

  ah.HashNum := info.Num;
  ah.HashSeedSize := info.SeedSize;
  ah.HashSize := info.HashSize;
  ah.BaseLen := DWord(futurelzBaseLen);
  if indexLz then ah.Version := 4
  else if futureLz then ah.Version := 3
  else if roundMatches then ah.Version := 1
  else ah.Version := 2;

  fileSize := QWord(Input.Seek(0, soEnd));
  Input.Seek(0, soBeginning);

  if v5 then
  begin
    { format-spec-v5 seccion 2: una magia, el par de hash sin sesgo, y la
      cantidad de bloques y el tamano escritos en vez de inferidos }
    v5h.Version := 5;
    if Length(Opts.DupMeta) > 0 then v5h.Flags := V5_FLAG_HAS_DUP else v5h.Flags := 0;
    v5h.HashId := info.Num;
    if info.Name = '' then v5h.HashSize := 0 else v5h.HashSize := info.HashSize;
    v5h.MaxMatch := DWord(8 * 1024 * 1024 - 24);
    v5h.BlockCount := DWord((fileSize + bufsize - 1) div bufsize);
    v5h.OriginalSize := fileSize;
    hb := EncodeV5Header(v5h);
  end
  else
    hb := EncodeArchiveHeader(ah);
  Output.WriteBuffer(hb[0], Length(hb));
  if Length(seed) > 0 then Output.WriteBuffer(seed[0], Length(seed));
  SetLength(blocks, 0);
  nblocks := 0;

  { COMPARE_DIGESTS = metodo <= -m3; PRECOMPUTE_DIGESTS = -m3; io_accelerator 1.
    -m0 no tiene tabla. }
  if Kind <> ekInmem then
    HtInit(table, roundMatches, Kind in [ekInmem, ekCdc, ekCdcZpaq, ekDigest],
           Kind = ekDigest, cdc, l, minMatch, 1, fileSize);
  DcInit(inmem, Opts.DictSize, Opts.DictHashSize, dictMinMatch, dictChunk, baseLen);
  CdcHasherInit(chunkKey);

  { El anillo: el diccionario redondeado a bloques enteros, mas dos de margen.
    Con el -d por defecto de -m0 son 528 MiB: el Rust los pide en ceros sin
    tocarlos (vec![0u8; n]), y SetLength los ocuparia de verdad aunque la
    entrada fuera de 5 bytes. Como el anillo se llena bloque a bloque y nunca
    se lee una zona sin escribir, crece a medida -- con ceros, que es lo que
    el Rust ve donde todavia no escribio. }
  ringSize := RoundUp(Opts.DictSize, bufsize) + BUFFERS * bufsize;
  SetLength(dict, 0);
  RingEnsure(dict, bufsize, ringSize);

  bufOffset := 0;
  nextPos := 0;
  filled := ReadBlockAt(Input, nextPos, dict, bufOffset, bufsize);
  nextPos := nextPos + filled;
  blockStart := 0;
  stat.N := 0; inStat.N := 0;

  while filled > 0 do
  begin
    { lectura adelantada: llena la ranura siguiente }
    nextOffset := (bufOffset + bufsize) mod ringSize;
    RingEnsure(dict, nextOffset + bufsize, ringSize);
    nextFilled := ReadBlockAt(Input, nextPos, dict, nextOffset, bufsize);

    SetLength(header, BLOCK_HEADER_SIZE + storedHashSize);
    FillChar(header[0], Length(header), 0);
    if HasherCompute(hasher, dict, bufOffset, filled, digest) then
      Move(digest[0], header[BLOCK_HEADER_SIZE], Length(digest));

    if Kind <> ekInmem then HtPrepareBuffer(table, dict, bufOffset, filled, blockStart);

    StatClear(stat);
    StatClear(inStat);
    literalBytes := 0;
    case Kind of
      ekInmem:
        begin
          { -m0: el pase en memoria ES el compresor; sin cerco ni segundo
            compresor (srep.cpp:726-727) }
          DcPrepareBuffer(inmem, hashptr, dict, bufOffset, filled);
          DcCompress(inmem, dict, ringSize, bufOffset, filled, hashptr, literalBytes, stat);
        end;
      ekCdc, ekCdcZpaq:
        CompressCdc(Kind = ekCdcZpaq, l, minMatch, blockStart, table, dict, bufOffset, filled,
                    literalBytes, stat, chunkKey);
    else
      begin
        { srep.cpp:722-724: el pase en memoria (solo con -d) escribe en la
          lista auxiliar, y despues va el cerco len+1 / BASE_LEN / BASE_LEN.
          Empieza pasado el bloque, asi que compress nunca lo alcanza: solo
          corta el recorrido. }
        if Opts.DictSize <> 0 then
        begin
          DcPrepareBuffer(inmem, hashptr, dict, bufOffset, filled);
          DcCompress(inmem, dict, ringSize, bufOffset, filled, hashptr, literalBytes, inStat);
        end;
        if not EncodeLzMatch(inStat, roundMatches, DWord(baseLen), DWord(filled + 1), baseLen,
                             DWord(baseLen)) then
          MatchTooSmall(DWord(baseLen), DWord(baseLen));
        CompressFixed(table, dict, bufOffset, filled, roundMatches, l, minMatch, DWord(baseLen),
                      blockStart, inStat, stat, literalBytes, Input);
      end;
    end;

    bh.LiteralBytes := literalBytes;
    bh.OrigSize := DWord(filled);
    { header[2] = (INDEX_LZ ? 0 : stat_size) (srep.cpp:747) }
    if indexLz then bh.StatSize := 0 else bh.StatSize := DWord(stat.N * 4);
    hb := EncodeBlockHeader(bh);
    Move(hb[0], header[0], BLOCK_HEADER_SIZE);

    if not (futureLz or v5) then
    begin
      { save_data: la cabecera, la lista (vacia en Index-LZ), los literales }
      Output.WriteBuffer(header[0], Length(header));
      if not indexLz then WriteStats(Output, stat);
      WriteLiterals(Output, dict, bufOffset, filled, stat, roundMatches, DWord(baseLen));
    end;
    { no_writes = FUTURE_LZ (io.cpp:270): Future-LZ y v5 no escriben nada en
      la primera pasada; la segunda re-emite cabecera, lista y literales }
    if not ioLz then
    begin
      if nblocks >= QWord(Length(blocks)) then
      begin
        if Length(blocks) < 16 then SetLength(blocks, 16) else SetLength(blocks, Length(blocks) * 2);
      end;
      blocks[nblocks].Start := blockStart;
      blocks[nblocks].EndPos := blockStart + filled;
      blocks[nblocks].Size := filled;
      blocks[nblocks].Header := Copy(header);
      blocks[nblocks].Stat.W := Copy(stat.W, 0, stat.N);
      blocks[nblocks].Stat.N := stat.N;
      Inc(nblocks);
    end;

    blockStart := blockStart + filled;
    nextPos := nextPos + nextFilled;
    bufOffset := nextOffset;
    filled := nextFilled;
  end;

  { Future-LZ, Index-LZ y v5 re-emiten la lista de cada bloque (srep.cpp:820) }
  if not ioLz then
    RunSecondPass(blocks, nblocks, Input, Output, roundMatches, DWord(baseLen),
                  DWord(futurelzBaseLen), futureLz, indexLz, v5, Opts.DupMeta);
end;

end.
