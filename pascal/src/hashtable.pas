unit HashTable;
{ El match finder (hash_table.rs, que porta hash_table.cpp): una tabla de hash
  sobre chunks de L bytes, donde cada slot de chunkarr empaqueta bits de hash
  y un numero de chunk en un DWord, sondeada por una cadena acotada. Las dos
  mitades del hash de 64 bits se usan -- chunkarr guarda los 32 bajos
  (enmascarados por hash_mask) y hasharr los 32 altos --, asi que mezclarlas
  encuentra los matches "correctos" en el lugar equivocado.

  Lo que el Rust deja afuera queda afuera aca tambien: bitarr y los prefetch
  (probadamente neutros a la salida). speed_opt SI es semantica: find_match
  abandona el sondeo tras un chequeo de slices fallido.

  Por ahora el camino de chunks de tamano fijo (-m3/-m4/-m5); CDC es la 5b. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Classes, Widths, Hashes, Vmac;

const
  MAX_HASH_CHAIN = DWord(12);
  NOT_FOUND      = DWord(0);     { el chunk 0 es "no hay match": nunca se guarda }
  DIGEST_SIZE    = 20;

type
  TSliceHash = record
    Active: Boolean;
    H: array of DWord;
    L, SlicesInBlock, SliceSize: QWord;
    CheckSlices: Int64;
  end;

  THashTableRec = record
    RoundMatches, CompareDigests, PrecomputeDigests, Cdc: Boolean;
    L, FileSize, TotalChunks: QWord;
    ChunknumMask, HashMask: DWord;
    HashSize1: QWord;
    ChunkArr: array of DWord;
    HashArr: array of DWord;
    Slice: TSliceHash;
    DigestArr: TBytes;           { DIGEST_SIZE bytes por chunk }
    CurChunk: DWord;             { CDC numera los chunks a medida que aparecen }
    StartArr: array of QWord;    { CDC: offset de cada chunk }
    Digest: TVmac;               { el VDigest con clave cero }
  end;

procedure HtInit(out T: THashTableRec; RoundMatches, CompareDigests, PrecomputeDigests,
                 Cdc: Boolean; L, MinMatch: QWord; IoAccelerator: LongInt; FileSize: QWord);

{ Libera las tablas de HtInit (las que viven en paginas propias; el resto
  lo libera la finalizacion de siempre). }
procedure HtFree(var T: THashTableRec);

{ prepare_buffer: digests (-m3) y huellas de slices de los chunks enteros del
  bloque de BlockLen bytes que esta en Buf[BufOff] y empieza en Offset. }
procedure HtPrepareBuffer(var T: THashTableRec; const Buf: TBytes; BufOff, BlockLen,
                          Offset: QWord);

function HtAddHash(var T: THashTableRec; Index: QWord; StoredValue: DWord;
                   CurChunk: QWord): DWord;

function HtFindMatch(const T: THashTableRec; const Buf: TBytes; BufOff, I, BlockSize,
                     Index: QWord; StoredValue: DWord): DWord;

{ El filtro barato de HtFindMatch, para un lote de hashes: el primer indice
  en [From, N) cuyo hash PH[idx] tiene en su cadena un candidato que pasa el
  chequeo de hasharr -- el unico punto donde HtFindMatch puede devolver algo
  distinto de NOT_FOUND --, o N. Recorre la cadena igual que HtFindMatch, asi
  que saltear un indice que no pasa no cambia la salida; el que llama se
  ahorra la llamada a HtFindMatch (y su marco) en casi todas las posiciones. }
function HtNextCandidate(const T: THashTableRec; PH: PQWord; From, N: LongInt): LongInt;

{ find_match_CDC: registra el chunk que empieza en Offset con el par de hashes
  VHashes[VAt..VAt+32) (vhash1 ++ vhash2), y devuelve la distancia a un chunk
  anterior con el mismo digest Y el mismo tamano, o 0. }
function HtFindMatchCdc(var T: THashTableRec; Offset, Size: QWord; const VHashes: TBytes;
                        VAt: QWord): QWord;

{ match_len: Dict tiene el bloque en BufOff; Reread es la entrada, que se
  re-lee con seek (el C++ usa un segundo handle). }
function HtMatchLen(const T: THashTableRec; StartChunk: QWord; const Dict: TBytes;
                    BufOff, MinP, StartP, LastP, Offset: QWord; RoundMatches: Boolean;
                    Reread: TStream; out AddLen: DWord): DWord;

{ VDigest::compute: vhash1 en 0 y vhash2 en 4, con la misma clave (cero), asi
  que es tag[0..4) ++ tag[0..16). }
procedure VDigestCompute(const V: TVmac; const B: TBytes; At, Len: QWord; var Out_: TBytes;
                         OutAt: QWord);

implementation

uses Rolling, ZeroPages, StreamIO;

{ ------------------------------------------------------------- slices --- }

function SliceHashOf(const B: TBytes; Off, Size: QWord): DWord;
{ h = h*P + b, mod 2^32, byte a byte. De a cuatro se reescribe como
  h*P^4 + (b0*P^3 + b1*P^2 + b2*P + b3), todo mod 2^32: el mismo valor, pero
  la cadena de multiplicaciones dependientes es un cuarto de larga. }
const
  P1 = DWord(123456791);
  P2 = DWord((QWord(P1) * P1) and $FFFFFFFF);
  P3 = DWord((QWord(P2) * P1) and $FFFFFFFF);
  P4 = DWord((QWord(P3) * P1) and $FFFFFFFF);
var h: DWord; i, n4: QWord; pb: PByte;
begin
  h := 111222341;
  pb := PByte(@B[0]) + PtrUInt(Off);
  i := 0;
  n4 := Size and not QWord(3);
  while i < n4 do
  begin
    h := DWord(h * P4) +
         DWord(DWord(pb[PtrUInt(i)]) * P3) + DWord(DWord(pb[PtrUInt(i) + 1]) * P2) +
         DWord(DWord(pb[PtrUInt(i) + 2]) * P1) + DWord(pb[PtrUInt(i) + 3]);
    Inc(i, 4);
  end;
  while i < Size do
  begin
    h := DWord(QWord(h) * 123456791 + QWord(pb[PtrUInt(i)]));
    Inc(i);
  end;
  h := DWord(QWord(h) * 123456791);
  Result := h shr (32 - 4);
end;

procedure SliceInit(out S: TSliceHash; FileSize, L, MinMatch: QWord; IoAccelerator: LongInt);
var memreq: QWord;
begin
  S.SlicesInBlock := 8;                  { sizeof(entry)*CHAR_BIT/BITS = 32/4 }
  S.L := L;
  S.SliceSize := L div S.SlicesInBlock;
  S.CheckSlices := (Int64(MinMatch) - Int64(L)) div Int64(S.SliceSize) - Int64(IoAccelerator);
  if (IoAccelerator < 0) or (S.CheckSlices <= 0) then memreq := 0
  else memreq := FileSize div L;
  S.Active := memreq <> 0;
  { Una entrada de mas: check lee h[chunk+1], y el escaneo puede llegar al
    ultimo chunk del archivo (el avance de a cuatro se pasa de next_chunk).
    El C++ lee ahi el relleno de pagina de su BigAlloc, que es cero. }
  ZNew(Pointer(S.H), TypeInfo(S.H), memreq + 1, SizeOf(DWord));
end;

procedure SlicePrepareRange(var S: TSliceHash; const Buf: TBytes; BufOff, ChunkStart,
                            ChunkEnd: QWord);
var p, cur, i: QWord; checksum: DWord;
begin
  if not S.Active then Exit;
  p := BufOff;
  cur := ChunkStart;
  while cur < ChunkEnd do
  begin
    checksum := 0;
    i := 0;
    while i < S.SlicesInBlock do
    begin
      checksum := DWord(QWord(checksum) + QWord(DWord(SliceHashOf(Buf, p, S.SliceSize) shl (i * 4))));
      p := p + S.SliceSize;
      Inc(i);
    end;
    S.H[cur] := checksum;
    Inc(cur);
  end;
end;

function SliceCheck(const S: TSliceHash; Chunk: QWord; const Buf: TBytes; BufOff, I,
                    BlockSize: QWord): Boolean;
var p, j, k, slice: QWord; checksum: DWord;
begin
  if not S.Active then Exit(True);
  if (I < S.L) or (BlockSize - I < 2 * S.L) then Exit(True);
  p := BufOff + I;
  checksum := S.H[Chunk + 1];
  j := 0;
  while True do
  begin
    if Int64(j) = S.CheckSlices then Exit(True);
    if ((checksum shr (j * 4)) and $F) <> SliceHashOf(Buf, p + S.L + j * S.SliceSize, S.SliceSize) then
      Break;
    Inc(j);
  end;
  checksum := S.H[Chunk - 1];
  k := 0;
  while True do
  begin
    if Int64(j + k) = S.CheckSlices then Exit(True);
    slice := p - (k + 1) * S.SliceSize;
    if ((checksum shr ((S.SlicesInBlock - (k + 1)) * 4)) and $F) <> SliceHashOf(Buf, slice, S.SliceSize) then
      Break;
    Inc(k);
  end;
  Result := False;
end;

{ ------------------------------------------------------------ digests --- }

procedure VDigestCompute(const V: TVmac; const B: TBytes; At, Len: QWord; var Out_: TBytes;
                         OutAt: QWord);
var t: TVmacTag; p: PByte; i: LongInt;
begin
  if Len > 0 then p := @B[At] else p := nil;   { sin copia }
  VmacTagOf(V, p, Len, t);
  for i := 0 to 3 do Out_[OutAt + QWord(i)] := t[i];
  for i := 0 to 15 do Out_[OutAt + 4 + QWord(i)] := t[i];
end;

{ -------------------------------------------------------------- tabla --- }

function MinHashSize(N: QWord): QWord;
begin
  Result := (N div 4 + 1) * 5;
end;

function NextHashSlot(H: QWord): QWord; inline;
begin
  Result := H * 123456791 + (H shr 16) + 462782923;
end;

procedure HtInit(out T: THashTableRec; RoundMatches, CompareDigests, PrecomputeDigests,
                 Cdc: Boolean; L, MinMatch: QWord; IoAccelerator: LongInt; FileSize: QWord);
var fs, hashsize: QWord; key: TBytes;
begin
  T.RoundMatches := RoundMatches;
  T.CompareDigests := CompareDigests;
  T.PrecomputeDigests := PrecomputeDigests;
  T.Cdc := Cdc;
  T.L := L;
  fs := FileSize;
  if fs < L then fs := L;
  T.FileSize := fs;
  T.TotalChunks := fs div L;
  if Cdc then
  begin
    if T.TotalChunks > 1024 then T.TotalChunks := T.TotalChunks + T.TotalChunks div 10
    else T.TotalChunks := T.TotalChunks + T.TotalChunks;
  end;
  T.ChunknumMask := DWord(RoundupToPowerOfTwo(T.TotalChunks + 2) - 1);
  T.HashMask := not T.ChunknumMask;
  hashsize := RoundupToPowerOfTwo(MinHashSize(T.TotalChunks));
  T.HashSize1 := hashsize - 1;
  { Todas en ceros, y en paginas que el sistema entrega al escribirlas
    (zeropages.pas), como el calloc del Rust: con stdin sin -s se dimensionan
    para 25 GiB y la mayor parte nunca se toca. HtFree las libera. }
  ZNew(Pointer(T.ChunkArr), TypeInfo(T.ChunkArr), hashsize, SizeOf(DWord));
  if Cdc then SetLength(T.HashArr, 0)
  else ZNew(Pointer(T.HashArr), TypeInfo(T.HashArr), T.TotalChunks, SizeOf(DWord));
  T.CurChunk := 0;
  if Cdc then ZNew(Pointer(T.StartArr), TypeInfo(T.StartArr), T.TotalChunks, SizeOf(QWord))
  else SetLength(T.StartArr, 0);
  SliceInit(T.Slice, fs, L, MinMatch, IoAccelerator);
  if CompareDigests then
    ZNew(Pointer(T.DigestArr), TypeInfo(T.DigestArr), T.TotalChunks * DIGEST_SIZE, 1)
  else SetLength(T.DigestArr, 0);
  SetLength(key, VMAC_KEY_LEN_BYTES);                { clave cero: ver VDigestCompute }
  VmacSetKey(key, T.Digest);
end;

procedure HtFree(var T: THashTableRec);
begin
  ZFree(Pointer(T.ChunkArr));
  ZFree(Pointer(T.HashArr));
  ZFree(Pointer(T.StartArr));
  ZFree(Pointer(T.Slice.H));
  ZFree(Pointer(T.DigestArr));
end;

procedure HtPrepareBuffer(var T: THashTableRec; const Buf: TBytes; BufOff, BlockLen,
                          Offset: QWord);
var cur, n, c: QWord;
begin
  cur := Offset div T.L;
  n := BlockLen div T.L;
  if T.PrecomputeDigests then
  begin
    c := cur;
    while c < cur + n do
    begin
      VDigestCompute(T.Digest, Buf, BufOff + (c - cur) * T.L, T.L, T.DigestArr, c * DIGEST_SIZE);
      Inc(c);
    end;
  end;
  SlicePrepareRange(T.Slice, Buf, BufOff, cur, cur + n);
end;

function ChunkarrValue(const T: THashTableRec; Hash: QWord; Chunk: DWord): DWord; inline;
begin
  Result := DWord(QWord(DWord(Hash) and T.HashMask) + QWord(Chunk));
end;

function HtAddHash(var T: THashTableRec; Index: QWord; StoredValue: DWord;
                   CurChunk: QWord): DWord;
var savedHash, value, chunk: DWord; h: QWord; limit: DWord;
begin
  T.HashArr[CurChunk] := StoredValue;
  if DWord(CurChunk) = NOT_FOUND then Exit(NOT_FOUND);
  savedHash := ChunkarrValue(T, Index, 0);
  h := Index;
  limit := MAX_HASH_CHAIN;
  Result := NOT_FOUND;
  while True do
  begin
    value := T.ChunkArr[h and T.HashSize1];
    if value = NOT_FOUND then Break;
    Dec(limit);
    if limit = 0 then Break;
    if (value and T.HashMask) = savedHash then
    begin
      chunk := value and T.ChunknumMask;
      if T.HashArr[chunk] = StoredValue then
      begin
        Result := chunk;
        Break;
      end;
    end;
    Inc(h);
    if (limit and 3) = 0 then h := NextHashSlot(h);
  end;
  T.ChunkArr[h and T.HashSize1] := ChunkarrValue(T, Index, DWord(CurChunk));
end;

function DigestEq(const T: THashTableRec; const D: TBytes; Chunk: QWord): Boolean;
var i: LongInt;
begin
  for i := 0 to DIGEST_SIZE - 1 do
    if D[i] <> T.DigestArr[Chunk * DIGEST_SIZE + QWord(i)] then Exit(False);
  Result := True;
end;

{ El chequeo de digest de -m3, aparte de HtFindMatch a proposito: su TBytes
  local obliga a FPC a armar un marco try/finally implicito (setjmp + push/pop
  de la pila de excepciones + finalize) en CADA llamada de la funcion que lo
  declara. HtFindMatch corre una vez por posicion candidata y casi nunca llega
  aca; con el TBytes adentro, ese marco era ~29% del tiempo de -m3. }
function DigestMatchesAt(const T: THashTableRec; const Buf: TBytes; At, Chunk: QWord): Boolean;
var dig: TBytes;
begin
  SetLength(dig, DIGEST_SIZE);
  VDigestCompute(T.Digest, Buf, At, T.L, dig, 0);
  Result := DigestEq(T, dig, Chunk);
end;

function HtFindMatch(const T: THashTableRec; const Buf: TBytes; BufOff, I, BlockSize,
                     Index: QWord; StoredValue: DWord): DWord;
var savedHash, value, chunk, limit: DWord; h: QWord;
begin
  savedHash := ChunkarrValue(T, Index, 0);
  h := Index;
  limit := MAX_HASH_CHAIN;
  while True do
  begin
    value := T.ChunkArr[h and T.HashSize1];
    if value = NOT_FOUND then Break;
    Dec(limit);
    if limit = 0 then Break;
    if (value and T.HashMask) = savedHash then
    begin
      chunk := value and T.ChunknumMask;
      if T.HashArr[chunk] = StoredValue then
      begin
        if T.CompareDigests then
        begin
          { -m3: el digest de 20 bytes; un fallo NO corta el sondeo }
          if DigestMatchesAt(T, Buf, BufOff + I, chunk) then Exit(chunk);
        end
        else if SliceCheck(T.Slice, chunk, Buf, BufOff, I, BlockSize) then
          Exit(chunk)
        else
          Exit(NOT_FOUND);          { speed_opt: no sigue la cadena }
      end;
    end;
    Inc(h);
    if (limit and 3) = 0 then h := NextHashSlot(h);
  end;
  Result := NOT_FOUND;
end;

function HtNextCandidate(const T: THashTableRec; PH: PQWord; From, N: LongInt): LongInt;
var savedHash, stored, value, limit, hmask, cmask: DWord; h, hs1: QWord; ca, ha: PDWord;
begin
  ca := PDWord(T.ChunkArr);
  ha := PDWord(T.HashArr);
  hmask := T.HashMask;
  cmask := T.ChunknumMask;
  hs1 := T.HashSize1;
  Result := From;
  while Result < N do
  begin
    h := PH[Result];
    stored := DWord(h shr 32);
    savedHash := DWord(h) and hmask;     { ChunkarrValue(T, Index, 0) }
    limit := MAX_HASH_CHAIN;
    while True do
    begin
      value := ca[PtrUInt(h and hs1)];
      if value = NOT_FOUND then Break;
      Dec(limit);
      if limit = 0 then Break;
      if ((value and hmask) = savedHash) and (ha[PtrUInt(value and cmask)] = stored) then Exit;
      Inc(h);
      if (limit and 3) = 0 then h := NextHashSlot(h);
    end;
    Inc(Result);
  end;
end;

{ add_hash0<CDC>: no escribe hasharr, acepta cualquier candidato con el mismo
  digest de 20 bytes (COMPARE_DIGESTS esta prendido en -m1/-m2) e inserta en
  el slot donde termino el recorrido. }
function AddHashCdc(var T: THashTableRec; Index: QWord; CurChunk: QWord): DWord;
var savedHash, value, chunk, limit: DWord; h: QWord; same: Boolean; i: LongInt;
begin
  if DWord(CurChunk) = NOT_FOUND then Exit(NOT_FOUND);
  savedHash := ChunkarrValue(T, Index, 0);
  h := Index;
  limit := MAX_HASH_CHAIN;
  Result := NOT_FOUND;
  while True do
  begin
    value := T.ChunkArr[h and T.HashSize1];
    if value = NOT_FOUND then Break;
    Dec(limit);
    if limit = 0 then Break;
    if (value and T.HashMask) = savedHash then
    begin
      chunk := value and T.ChunknumMask;
      same := True;
      if T.CompareDigests then
        for i := 0 to DIGEST_SIZE - 1 do
          if T.DigestArr[QWord(chunk) * DIGEST_SIZE + QWord(i)] <>
             T.DigestArr[CurChunk * DIGEST_SIZE + QWord(i)] then same := False;
      if same then
      begin
        Result := chunk;
        Break;
      end;
    end;
    Inc(h);
    if (limit and 3) = 0 then h := NextHashSlot(h);
  end;
  T.ChunkArr[h and T.HashSize1] := ChunkarrValue(T, Index, DWord(CurChunk));
end;

function HtFindMatchCdc(var T: THashTableRec; Offset, Size: QWord; const VHashes: TBytes;
                        VAt: QWord): QWord;
var cur, index: QWord; chunk: DWord; i: LongInt;
begin
  Inc(T.CurChunk);
  if QWord(T.CurChunk) >= T.TotalChunks then Exit(0);
  cur := T.CurChunk;
  T.StartArr[cur] := Offset;
  for i := 0 to DIGEST_SIZE - 1 do T.DigestArr[cur * DIGEST_SIZE + QWord(i)] := VHashes[VAt + QWord(i)];
  { el digest son los primeros 20 bytes; el indice, los 8 que siguen (LE) }
  index := 0;
  for i := 7 downto 0 do index := (index shl 8) or QWord(VHashes[VAt + DIGEST_SIZE + QWord(i)]);
  chunk := AddHashCdc(T, index, cur);
  if (chunk <> NOT_FOUND) and (T.StartArr[QWord(chunk) + 1] - T.StartArr[chunk] = Size) then
    Result := Offset - T.StartArr[chunk]
  else
    Result := 0;
end;

{ Un pread: N bytes en Off, devolviendo cuantos se leyeron. }
function ReadAt(S: TStream; Off: QWord; var B: TBytes; N: QWord): QWord;
begin
  Result := 0;
  if (Off > QWord(High(Int64))) or (S.Seek(Int64(Off), soBeginning) <> Int64(Off)) then Exit;
  if N > 0 then Result := ReadUpTo(S, B[0], N);
end;

function HtMatchLen(const T: THashTableRec; StartChunk: QWord; const Dict: TBytes;
                    BufOff, MinP, StartP, LastP, Offset: QWord; RoundMatches: Boolean;
                    Reread: TStream; out AddLen: DWord): DWord;
const BUFSIZE = 4096;
var
  l, oldOffset, p, n, i, q: QWord;
  stopped: Boolean;
  old, oldbuf, dig: TBytes;
begin
  l := T.L;
  oldOffset := StartChunk * l;
  p := StartP;
  AddLen := 0;
  { match_len sale por "goto stop", que cae DESPUES de la comparacion final
    dentro del bloque: toda salida temprana la saltea. stopped es eso. }
  stopped := False;

  if T.CompareDigests then
  begin
    SetLength(dig, DIGEST_SIZE);
    while True do
    begin
      p := p + T.L;
      oldOffset := oldOffset + l;
      if oldOffset >= Offset then Break;
      if p + T.L > LastP then begin stopped := True; Break; end;
      VDigestCompute(T.Digest, Dict, p, T.L, dig, 0);
      if not DigestEq(T, dig, oldOffset div l) then begin stopped := True; Break; end;
    end;
  end
  else if oldOffset < Offset then
  begin
    { el chunk esta en un bloque anterior: se relee de la entrada }
    n := oldOffset;
    if l < n then n := l;
    if StartP - MinP < n then n := StartP - MinP;
    if (n > 0) and (not RoundMatches) then
    begin
      SetLength(old, n);
      if ReadAt(Reread, oldOffset - n, old, n) <> n then
        stopped := True
      else
      begin
        i := 1;
        while (i <= n) and (Dict[StartP - i] = old[n - i]) do Inc(i);
        AddLen := DWord(i - 1);
      end;
    end;
    if not stopped then
    begin
      SetLength(oldbuf, BUFSIZE);
      while oldOffset < Offset do
      begin
        if ReadAt(Reread, oldOffset, oldbuf, BUFSIZE) <> BUFSIZE then begin stopped := True; Break; end;
        q := 0;
        { de a 8 mientras los 8 bytes coinciden y ninguno es LastP; el lazo
          de bytes de abajo encuentra el mismo primer byte distinto }
        while (q + 8 <= BUFSIZE) and (p + 8 <= LastP) and
              (PQWord(@Dict[p])^ = PQWord(@oldbuf[q])^) do
        begin
          Inc(p, 8);
          Inc(q, 8);
        end;
        while q < BUFSIZE do
        begin
          if (p = LastP) or (Dict[p] <> oldbuf[q]) then begin stopped := True; Break; end;
          Inc(p);
          Inc(q);
        end;
        if stopped then Break;
        oldOffset := oldOffset + BUFSIZE;
      end;
    end;
  end
  else if (not T.CompareDigests) and (not RoundMatches) then
  begin
    { el chunk esta en el bloque actual: los bytes de antes del match }
    n := oldOffset - Offset;
    if l < n then n := l;
    if StartP - MinP < n then n := StartP - MinP;
    i := 1;
    while (i <= n) and (Dict[StartP - i] = Dict[BufOff + (oldOffset - Offset) - i]) do Inc(i);
    AddLen := DWord(i - 1);
  end;

  if not stopped then
  begin
    q := BufOff + (oldOffset - Offset);
    while (p + 8 <= LastP) and (PQWord(@Dict[p])^ = PQWord(@Dict[q])^) do
    begin
      Inc(p, 8);
      Inc(q, 8);
    end;
    while (p < LastP) and (Dict[p] = Dict[q]) do
    begin
      Inc(p);
      Inc(q);
    end;
  end;
  Result := DWord((p - StartP) + QWord(AddLen));
end;

end.
