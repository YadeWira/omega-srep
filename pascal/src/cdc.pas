unit Cdc;
{ Chunking por contenido para -m1/-m2 (cdc.rs, que porta compress_cdc.cpp).

  El bloque se corta donde un hash rodante de los ultimos WINSIZE bytes cruza
  un umbral (~uno cada L bytes), y cada chunk se busca en la tabla por un par
  de VMAC de 32 bytes: los primeros 20 son el digest y los 8 siguientes el
  indice de la tabla.

  Hay dos hashes de frontera y el C++ elige en TIEMPO DE EJECUCION: con SSE4.2
  usa CrcRollingHash<uint32>, si no PolynomialRollingHash<uint64>. Dan
  archivos distintos, asi que se portan los dos y se elige igual (cpufeat).
  OSREP_CDC_POLY=1 fuerza la polinomial, como en el Rust: sin eso es
  inalcanzable en cualquier maquina moderna. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Widths, Hashes, Vmac, LzCodec, HashTable;   { SysUtils antes de Hashes: TBytes }

const
  STRIPE = QWord(116 * 1024);
  WINSIZE = QWord(48);
  MINIMAL_MIN_MATCH = QWord(16);

{ compress_CDC sobre el bloque B[At..At+BlockSize). }
procedure CompressCdc(Zpaq: Boolean; L, MinMatchIn, BlockStart: QWord;
                      var T: THashTableRec; const B: TBytes; At, BlockSize: QWord;
                      out LiteralBytes: DWord; var Stat: TStatList; const ChunkKey: TVmac);

{ La clave cero de los dos VMAC de cada chunk (nunca se guardan: solo se
  comparan, asi que cualquier clave compartida da las mismas decisiones). }
procedure CdcHasherInit(out K: TVmac);

implementation

uses Rolling, CpuFeat, FixedCompress;

type
  TMarks = record
    W: array of QWord;
    N: QWord;
  end;

  { el hash de frontera, normalizado a QWord para que un bucle maneje los dos }
  TBoundary = record
    UseCrc: Boolean;
    Poly: TPolyHash;
    Crc: TCrcHash;
  end;

var
  CrcRoute: Boolean = False;
  CrcRouteKnown: Boolean = False;

function UseCrcRoute: Boolean;
begin
  if not CrcRouteKnown then
  begin
    CrcRoute := HasSse42 and (GetEnvironmentVariable('OSREP_CDC_POLY') = '');
    CrcRouteKnown := True;
  end;
  Result := CrcRoute;
end;

procedure MarkPush(var M: TMarks; V: QWord);
begin
  if M.N >= QWord(Length(M.W)) then
  begin
    if Length(M.W) < 64 then SetLength(M.W, 64) else SetLength(M.W, Length(M.W) * 2);
  end;
  M.W[M.N] := V;
  Inc(M.N);
end;

procedure SortMarks(var M: TMarks);
  procedure Q(lo, hi: Int64);
  var i, j: Int64; p, t: QWord;
  begin
    while lo < hi do
    begin
      p := M.W[(lo + hi) div 2];
      i := lo; j := hi;
      while i <= j do
      begin
        while M.W[i] < p do Inc(i);
        while M.W[j] > p do Dec(j);
        if i <= j then
        begin
          t := M.W[i]; M.W[i] := M.W[j]; M.W[j] := t;
          Inc(i); Dec(j);
        end;
      end;
      if j - lo < hi - i then begin Q(lo, j); lo := i; end
      else begin Q(i, hi); hi := j; end;
    end;
  end;
begin
  if M.N > 1 then Q(0, Int64(M.N) - 1);
end;

function BMax(const H: TBoundary): QWord;
begin
  if H.UseCrc then Result := QWord(High(DWord)) else Result := High(QWord);
end;

procedure BMoveTo(var H: TBoundary; const B: TBytes; At: QWord);
begin
  if H.UseCrc then CrcMoveTo(H.Crc, B, At) else PolyMoveTo(H.Poly, B, At);
end;

function BUpdate(var H: TBoundary; Sub, Add: Byte): QWord; inline;
begin
  if H.UseCrc then
  begin
    CrcUpdate(H.Crc, Sub, Add);
    Result := QWord(H.Crc.Value);
  end
  else
  begin
    PolyUpdate(H.Poly, Sub, Add);
    Result := H.Poly.Value;
  end;
end;

{ fast_find_chunks_in_3_streams: tres escaneos intercalados sobre un stripe,
  por eso las marcas salen desordenadas. }
procedure FindChunksIn3Streams(const B: TBytes; Base, Ptr, Piece, MaxHash, MinMatch: QWord;
                               const H: TBoundary; var Marks: TMarks);
var lastp: array[0..2] of QWord; st: array[0..2] of TBoundary; s: LongInt;
    p, pend, sp, value: QWord;
begin
  for s := 0 to 2 do
  begin
    lastp[s] := Ptr + QWord(s) * Piece;
    st[s] := H;
    BMoveTo(st[s], B, Base + lastp[s]);
  end;
  p := Ptr + WINSIZE;
  pend := Ptr + Piece;
  while p < pend do
  begin
    for s := 0 to 2 do
    begin
      sp := p + QWord(s) * Piece;
      value := BUpdate(st[s], B[Base + sp - WINSIZE], B[Base + sp]);
      if (value > MaxHash) and (sp - lastp[s] >= MinMatch) then
      begin
        MarkPush(Marks, sp);
        lastp[s] := sp;
      end;
    end;
    Inc(p);
  end;
end;

procedure FastFindChunks(const B: TBytes; Base, Ptr, Pend, BufEnd: QWord; var Marks: TMarks;
                         L, MinMatch: QWord; const H: TBoundary);
var maxhash, lastp, p, value: QWord; hh: TBoundary;
begin
  maxhash := BMax(H) - BMax(H) div L;
  if Pend - Ptr >= STRIPE div 3 * 3 then
  begin
    FindChunksIn3Streams(B, Base, Ptr, STRIPE div 3, maxhash, MinMatch, H, Marks);
    SortMarks(Marks);
  end
  else if Pend - Ptr >= WINSIZE then
  begin
    lastp := Ptr;
    hh := H;
    BMoveTo(hh, B, Base + lastp);
    p := Ptr + WINSIZE;
    while p < Pend do
    begin
      value := BUpdate(hh, B[Base + p - WINSIZE], B[Base + p]);
      if (value > maxhash) and (p - lastp >= MinMatch) then
      begin
        MarkPush(Marks, p);
        lastp := p;
      end;
      Inc(p);
    end;
  end;
  if Pend = BufEnd then MarkPush(Marks, BufEnd);
end;

{ zpaq_find_chunks: un modelo de orden 1 decide que bytes se predicen mal, y
  un hash rodante sobre esos elige las fronteras. }
procedure ZpaqFindChunks(const B: TBytes; Base, Ptr, Pend, BufEnd: QWord; var Marks: TMarks;
                         L, MinMatch: QWord);
var maxhash, start, lastp, p: QWord; hash, mul: DWord; c, c1: Byte;
    o1: array[0..255] of Byte;
begin
  maxhash := QWord(High(DWord)) - QWord(High(DWord)) div L;
  hash := 0;
  c1 := 0;
  FillChar(o1, SizeOf(o1), 0);
  { el modelado arranca hasta 8000 bytes antes del stripe }
  if Ptr > 8000 then start := Ptr - 8000 else start := 0;
  lastp := start;
  p := start;
  while p < Pend do
  begin
    c := B[Base + p];
    if c <> o1[c1] then mul := 271828182 else mul := 314159265;
    hash := DWord(QWord(DWord(QWord(hash) + QWord(c) + 1)) * QWord(mul));
    o1[c1] := c;
    c1 := c;
    if (QWord(hash) > maxhash) and (p - lastp >= MinMatch) then
    begin
      { el primer chunk del stripe puede ser mas corto que MIN_MATCH; se
        filtra justo antes de emitir el match }
      if p > Ptr then MarkPush(Marks, p);
      lastp := p;
      c1 := 0;
      hash := 0;
      FillChar(o1, SizeOf(o1), 0);
    end;
    Inc(p);
  end;
  if Pend = BufEnd then MarkPush(Marks, BufEnd);
end;

procedure CdcHasherInit(out K: TVmac);
var key: TBytes;
begin
  SetLength(key, VMAC_KEY_LEN_BYTES);
  VmacSetKey(key, K);
end;

{ compute_single_chunk_hash: vhash1 en 0 y vhash2 en 16 -- NO el layout
  solapado de VDigest, porque la tabla tambien saca un indice de 64 bits de
  los mismos 32 bytes. Las dos claves son cero: los dos tags son iguales. }
procedure ChunkHashes(const K: TVmac; const B: TBytes; At, Len: QWord; var Out_: TBytes;
                      OutAt: QWord);
var m, t: TBytes; i: LongInt;
begin
  SetLength(m, Len);
  if Len > 0 then Move(B[At], m[0], Len);
  t := VmacCompute(K, m);
  for i := 0 to VMAC_TAG_LEN_BYTES - 1 do
  begin
    Out_[OutAt + QWord(i)] := t[i];
    Out_[OutAt + VMAC_TAG_LEN_BYTES + QWord(i)] := t[i];
  end;
end;

procedure CompressCdc(Zpaq: Boolean; L, MinMatchIn, BlockStart: QWord;
                      var T: THashTableRec; const B: TBytes; At, BlockSize: QWord;
                      out LiteralBytes: DWord; var Stat: TStatList; const ChunkKey: TVmac);
var
  minMatch, bufend, lastMatch, lastChunk, ptr, pend, idx, mark, len, matchOffset: QWord;
  marks: TMarks;
  bnd: TBoundary;
  vh: TBytes;
begin
  minMatch := MinMatchIn;
  if minMatch < MINIMAL_MIN_MATCH then minMatch := MINIMAL_MIN_MATCH;
  LiteralBytes := 0;
  bufend := BlockSize;

  bnd.UseCrc := UseCrcRoute;
  PolyInit(bnd.Poly, WINSIZE, PRIME1);
  CrcInit(bnd.Crc, WINSIZE, CRC32_CASTAGNOLI_POLYNOM);

  lastMatch := 0;
  lastChunk := 0;
  ptr := 0;
  marks.N := 0;
  while ptr < bufend do
  begin
    if bufend - ptr < STRIPE then pend := bufend else pend := ptr + STRIPE;
    marks.N := 0;
    { las marcas son relativas al bloque, que esta en B[At] }
    if Zpaq then
      ZpaqFindChunks(B, At, ptr, pend, bufend, marks, L, minMatch)
    else
      FastFindChunks(B, At, ptr, pend, bufend, marks, L, minMatch, bnd);

    { los chunks que este stripe termina: el primero empieza en el stripe (o
      el bloque) anterior, los demas van de marca a marca }
    SetLength(vh, marks.N * 32);
    if marks.N > 0 then
    begin
      ChunkHashes(ChunkKey, B, At + lastChunk, marks.W[0] - lastChunk, vh, 0);
      idx := 0;
      while idx + 1 < marks.N do
      begin
        ChunkHashes(ChunkKey, B, At + marks.W[idx], marks.W[idx + 1] - marks.W[idx], vh,
                    (idx + 1) * 32);
        Inc(idx);
      end;
    end;

    idx := 0;
    while idx < marks.N do
    begin
      mark := marks.W[idx];
      len := mark - lastChunk;
      matchOffset := HtFindMatchCdc(T, BlockStart + lastChunk, len, vh, idx * 32);
      if (matchOffset <> 0) and (len >= minMatch) then
      begin
        if not EncodeLzMatch(Stat, False, DWord(minMatch), DWord(lastChunk - lastMatch),
                             matchOffset, DWord(len)) then
          MatchTooSmall(DWord(len), DWord(minMatch));
        lastMatch := mark;
      end
      else
        LiteralBytes := DWord(QWord(LiteralBytes) + len);
      lastChunk := mark;
      Inc(idx);
    end;
    ptr := pend;
  end;
end;

end.
