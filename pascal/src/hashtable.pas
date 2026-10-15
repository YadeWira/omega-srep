unit HashTable;
{ El match finder (hash_table.rs, que porta hash_table.cpp): una tabla de hash
  sobre chunks de L bytes, donde cada slot de chunkarr empaqueta bits de hash
  y un numero de chunk en un DWord, sondeada por una cadena acotada. Las dos
  mitades del hash de 64 bits se usan -- chunkarr guarda los 32 bajos
  (enmascarados por hash_mask) y hasharr los 32 altos --, asi que mezclarlas
  encuentra los matches "correctos" en el lugar equivocado.

  Lo que el Rust deja afuera queda afuera aca tambien: los prefetch. bitarr
  NO es neutro: el escaneo acelerado (CompressFixedAccel) solo sondea las
  posiciones cuyo hash pasa ese filtro, y con un -l chico eso cambia el
  archivo (fixedcompress.pas). speed_opt tambien es semantica: find_match
  abandona el sondeo tras un chequeo de slices fallido.

  Por ahora el camino de chunks de tamano fijo (-m3/-m4/-m5); CDC es la 5b. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, Vmac;

const
  MAX_HASH_CHAIN = DWord(12);
  NOT_FOUND      = DWord(0);     { el chunk 0 es "no hay match": nunca se guarda }
  DIGEST_SIZE    = 20;
  { Bytes en cero detras del anillo del encoder, que nunca se escriben. El
    escaneo lee pasado el fin del bloque: el lote de CompressFixed avanza de a
    4 y, si 4 no divide a L (-l o -c que no son potencia de dos), se pasa de
    next_chunk hasta 3 posiciones; el de CompressFixedAccel avanza de a CYCLES
    (hasta 64, con -aN/64) y lee hasta CYCLES - 1 = 63 bytes pasado el bloque.
    Con un bloque lleno en la ultima ranura del anillo eso lee pasado el
    anillo. El C++ lee ahi fuera de su reserva; el Rust lee cero y aca
    tambien, pero sin chequear byte por byte en el lazo mas caliente.
    El invariante, que dos lecturas usan:
    * el byte que entra al hash en el lote (pbL[i], compress.rs: dict.get y
      byte_at);
    * la ventana de L bytes del digest de -m3 en una posicion candidata
      (DigestMatchesAt; hash_table.rs: digest_at), que con esas posiciones
      de mas termina hasta CYCLES - 1 bytes despues del bloque.
    Las dos llegan a lo sumo 63 bytes pasado el fin de un bloque, asi que con
    RING_TAIL >= 63 nunca salen del TBytes, y como la cola esta en cero leen
    exactamente lo que el Rust rellena con ceros: mismos digests, mismos
    archivos. Por eso RingEnsure (encoder.pas) siempre pide RING_TAIL bytes
    detras de la ranura que llena, y nada escribe en ellos. SliceCheck no los
    cuenta como parte del buffer: para el Rust el anillo termina antes. }
  RING_TAIL      = 64;

type
  { (primer chunk, inicio) de un bloque: ver THashTableRec.Grid }
  TGridEntry = record
    Chunk, Start: QWord;
  end;

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
    { (primer chunk, inicio) de cada bloque que vio HtPrepareBuffer desde el
      primero fuera de la grilla de L, en orden; los anteriores estan en la
      grilla, donde K*L (lo que devuelve HtChunkPos sin entrada) es correcto,
      asi que un -b alineado no guarda nada. Un bloque que empieza fuera de la
      grilla de L (un -b que no es multiplo de L) numera sus chunks desde
      Offset div L pero los digiere y hashea en Offset + m*L: el numero de
      chunk solo no da el offset de sus bytes en el archivo, HtChunkPos si. }
    Grid: array of TGridEntry;
    GridN: QWord;
    AnyShifted: Boolean;         { algun bloque con Offset mod L <> 0 }
    { bitarr (hash_table.cpp:137-140, 155-157): un bit por valor de hash visto
      en una frontera de chunk, que el escaneo acelerado prueba antes que
      chunkarr. Vacio con BITARR_ACCELERATOR 0 (-a0, -a-) y en CDC. Se indexa
      con los BitShift = 64 - lb(tamano) bits altos del hash de 64 bits (el
      size_t del C++ en x86-64, tambien en i386). }
    BitArr: array of Byte;
    BitShift: DWord;
  end;

  { bitarr no entra (un -aN enorme, o no cabe en el espacio de direcciones
    de i386): el "Can't allocate memory" del C++; encoder.pas lo convierte en
    EncodeError::OutOfMemory, como el Rust. }
  EHtBitArrMemory = class(Exception);

procedure HtInit(out T: THashTableRec; RoundMatches, CompareDigests, PrecomputeDigests,
                 Cdc: Boolean; L, MinMatch: QWord; IoAccelerator: LongInt;
                 BitarrAccelerator: QWord; FileSize: QWord);

{ check_match_possibility / mark_match_possibility (hash_table.cpp:218-219).
  Solo con BitArr no vacio. }
function HtCheckPossible(const T: THashTableRec; Hash: QWord): Boolean; inline;
procedure HtMarkPossible(var T: THashTableRec; Hash: QWord); inline;

{ Libera las tablas de HtInit (las que viven en paginas propias; el resto
  lo libera la finalizacion de siempre). }
procedure HtFree(var T: THashTableRec);

{ prepare_buffer: digests (-m3) y huellas de slices de los chunks enteros del
  bloque de BlockLen bytes que esta en Buf[BufOff] y empieza en Offset. }
procedure HtPrepareBuffer(var T: THashTableRec; const Buf: TBytes; BufOff, BlockLen,
                          Offset: QWord);

{ Lo unico que el bloque k lee del prepare_buffer del bloque k+1, que el hilo
  de fondo del C++ corre mientras el principal comprime el k (io.cpp:250-265):
  el digest de -m3 del chunk n0 = Offset div L, con el que el bloque k+1
  numera su primer chunk. Se llama con el bloque k+1 (Offset = fin del k)
  justo despues del HtPrepareBuffer del k; el HtPrepareBuffer del k+1 despues
  recalcula ese mismo valor y todo lo demas.

  El escaneo del bloque k se pasa de su ultimo chunk hasta max(CYCLES, 4) - 1
  bytes (compress.cpp:153-174), asi que si Offset no es multiplo de L su
  ultimo add_hash (compress.cpp:209) puede llegar con CurChunk = n0 y comparar
  DigestArr[n0] (hash_table.cpp:272). Nada mas se lee por adelantado:
  find_match y match_len solo leen digests de chunks ya insertados o
  anteriores al bloque, y SliceCheck lee H[chunk + 1] solo con al menos 2*L
  bytes por delante en el bloque (hash_table.cpp:92-94), lo que descarta el
  candidato n0 - 1. Un build instrumentado que registraba cada lectura de
  digests y slices no encontro ninguna otra antes del prepare_buffer que la
  escribe, en 700 casos generados (-b fuera de la grilla, L impar, -m3 a
  -m5). El bloque k+1 escribe el chunk n0 solo si trae al menos L bytes; y
  si para el bloque k block_start mod L + filled mod L >= L, n0 es dos mas
  que su ultimo chunk, y el del medio, al que ese add_hash tambien llega, no
  lo escribe ningun bloque. En los dos casos el C++ lee memoria sin
  inicializar y los ports leen cero.

  En el C++ nada ordena esto: es una carrera entre sus dos hilos, con
  cualquier -t (-t1 incluido). Con bloques grandes el hilo de fondo suele
  terminar mucho antes de que el bloque k llegue a su final; con bloques chicos
  (-m3 -l130 -b261b) el principal a veces llega primero y lee lo que habia,
  y el archivo de la 1.0.7 cambia de una corrida a otra. Los ports siempre
  toman el valor preparado: el bloque k+1 leido y preparado entero antes de
  comprimir el k, que es lo que el C++ escribe en la mayoria de las
  corridas. Ver HashTable::prepare_ahead en el Rust. }
procedure HtPrepareAhead(var T: THashTableRec; const Buf: TBytes; BufOff, BlockLen,
                         Offset: QWord);

function HtAddHash(var T: THashTableRec; Index: QWord; StoredValue: DWord;
                   CurChunk: QWord): DWord;

{ El offset en el archivo de los bytes de los que se saco el digest y el hash
  del chunk K: inicio + (K - primer chunk) * L del bloque que lo numero. Es
  K * L mientras todos los bloques hayan empezado en la grilla de L
  (hash_table.rs, chunk_pos). }
function HtChunkPos(const T: THashTableRec; K: QWord): QWord;

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

{ Un pread: N bytes en Off, devolviendo cuantos se leyeron. }
function ReadAt(S: TStream; Off: QWord; var B: TBytes; N: QWord): QWord;

{ VDigest::compute:vhash1 en 0 y vhash2 en 4, con la misma clave (cero), asi
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
  { Con L menor que 8 el slice queda vacio y el C++ divide por cero (SIGFPE).
    La CLI rechaza todo L asi antes de llegar aca (SmallWindow en osrep.lpr);
    esto solo evita la division si alguien llama directo: sin slice no hay
    filtro. }
  if S.SliceSize = 0 then S.CheckSlices := 0
  else S.CheckSlices := (Int64(MinMatch) - Int64(L)) div Int64(S.SliceSize) - Int64(IoAccelerator);
  if (IoAccelerator < 0) or (S.CheckSlices <= 0) then memreq := 0
  else memreq := FileSize div L;
  S.Active := memreq <> 0;
  { Una entrada de mas: check lee h[chunk+1], y el escaneo puede llegar al
    ultimo chunk del archivo (el avance de a cuatro se pasa de next_chunk).
    El C++ lee ahi lo que haya despues de su BigAlloc: cero cuando malloc
    lo mapea como paginas nuevas (un archivo grande); con uno chico es memoria
    del heap. El port deja esa entrada en cero. Otra
    mas para un -c que no es potencia de dos, donde el ultimo chunk guardado
    puede ser FileSize div L justo (ver HtInit). }
  ZNew(Pointer(S.H), TypeInfo(S.H), memreq + 2, SizeOf(DWord));
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
{ CheckSlices es (MIN_MATCH - L) div slice - 1, y con -m5 llega a 22 cuando
  MIN_MATCH queda justo debajo de una potencia de dos (-l1000, -l2000), no a
  los 8 slices que entran en una entrada. El recorrido sale entonces de los
  chunks vecinos: hasta 3,9*L adelante y 2,75*L atras, cuando la guarda solo
  asegura 2*L y L. Dentro del anillo son otros bytes y da lo mismo que el C++;
  cerca de sus bordes el C++ lee fuera de su reserva, el Rust entraba en
  panico y aca se leia fuera del TBytes sin que nadie se enterara. Un slice
  que no cae entero dentro del anillo (Buf sin su cola RING_TAIL) ahora es
  un no-coincide, igual que en hash_table.rs. Los corrimientos de nibble pasados el octavo slice son los
  del C++ en x86 (la cuenta se enmascara a 5 bits): se escriben con and 31
  para no depender de como el compilador hace el shr con una cuenta QWord. }
var p, j, k, ss, slice, back, len: QWord; checksum: DWord;
begin
  if not S.Active then Exit(True);
  if (I < S.L) or (BlockSize - I < 2 * S.L) then Exit(True);
  ss := S.SliceSize;
  { el anillo sin su cola de ceros (RING_TAIL): lo que el Rust ve como buf }
  len := QWord(Length(Buf));
  if len >= RING_TAIL then len := len - RING_TAIL else len := 0;
  p := BufOff + I;
  checksum := S.H[Chunk + 1];
  j := 0;
  while True do
  begin
    if Int64(j) = S.CheckSlices then Exit(True);
    slice := p + S.L + j * ss;
    if slice + ss > len then Break;
    if ((checksum shr LongInt((j * 4) and 31)) and $F) <> SliceHashOf(Buf, slice, ss) then
      Break;
    Inc(j);
  end;
  checksum := S.H[Chunk - 1];
  k := 0;
  while True do
  begin
    if Int64(j + k) = S.CheckSlices then Exit(True);
    back := (k + 1) * ss;
    if back > p then Break;
    if ((checksum shr LongInt(((S.SlicesInBlock - (k + 1)) * 4) and 31)) and $F) <>
       SliceHashOf(Buf, p - back, ss) then
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
                 Cdc: Boolean; L, MinMatch: QWord; IoAccelerator: LongInt;
                 BitarrAccelerator: QWord; FileSize: QWord);
var fs, hashsize, bitarrSize: QWord; key: TBytes;
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
  { hash_table.cpp:155-157: unos accel bytes por chunk. Primero que las
    demas tablas, como en el Rust: es la que una opcion (-a1000) puede hacer
    tan grande como quiera, y un tamano que no entra es OutOfMemory y no un
    arreglo truncado (un QWord que pasa a SizeInt en i386). En paginas en
    cero, como el BigAllocZero del C++ y el calloc del Rust. }
  if (BitarrAccelerator = 0) or Cdc then bitarrSize := 0
  else
  begin
    bitarrSize := (T.TotalChunks div 8) * BitarrAccelerator;
    if bitarrSize < 2 then bitarrSize := 2;
    bitarrSize := RoundupToPowerOfTwo(bitarrSize);
  end;
  T.BitShift := 64 - Lb(bitarrSize);
  SetLength(T.BitArr, 0);
  if bitarrSize > 0 then
  begin
    if bitarrSize > QWord(High(SizeInt)) then raise EHtBitArrMemory.Create('OutOfMemory');
    try
      ZNew(Pointer(T.BitArr), TypeInfo(T.BitArr), SizeInt(bitarrSize), 1);
    except
      on EOutOfMemory do raise EHtBitArrMemory.Create('OutOfMemory');
    end;
  end;
  T.ChunknumMask := DWord(RoundupToPowerOfTwo(T.TotalChunks + 2) - 1);
  T.HashMask := not T.ChunknumMask;
  hashsize := RoundupToPowerOfTwo(MinHashSize(T.TotalChunks));
  T.HashSize1 := hashsize - 1;
  { Todas en ceros, y en paginas que el sistema entrega al escribirlas
    (zeropages.pas), como el calloc del Rust: con stdin sin -s se dimensionan
    para 25 GiB y la mayor parte nunca se toca. HtFree las libera. }
  ZNew(Pointer(T.ChunkArr), TypeInfo(T.ChunkArr), hashsize, SizeOf(DWord));
  { HashArr y DigestArr llevan un lugar mas que los chunks enteros. Si L no
    divide al bloque (-l o -c que no son potencia de dos: solo un warning),
    los bloques despues del primero empiezan a mitad de chunk y el
    (block_start + i) div L de add_hash llega a TotalChunks justo en el
    ultimo chunk del archivo. El C++ escribe ahi fuera de su BigAlloc, el Rust
    entraba en panico, y aca se escribia fuera del arreglo sin aviso. Mas alla
    de ese no se guarda nada, y el lugar extra solo se lee despues de que
    add_hash lo escribio (o, en DigestArr, como un digest cero que no coincide
    con nada): los archivos que salian bien no cambian. }
  if Cdc then SetLength(T.HashArr, 0)
  else ZNew(Pointer(T.HashArr), TypeInfo(T.HashArr), T.TotalChunks + 1, SizeOf(DWord));
  T.CurChunk := 0;
  if Cdc then ZNew(Pointer(T.StartArr), TypeInfo(T.StartArr), T.TotalChunks, SizeOf(QWord))
  else SetLength(T.StartArr, 0);
  SliceInit(T.Slice, fs, L, MinMatch, IoAccelerator);
  if CompareDigests then
    ZNew(Pointer(T.DigestArr), TypeInfo(T.DigestArr), (T.TotalChunks + 1) * DIGEST_SIZE, 1)
  else SetLength(T.DigestArr, 0);
  SetLength(T.Grid, 0);
  T.GridN := 0;
  T.AnyShifted := False;
  SetLength(key, VMAC_KEY_LEN_BYTES);                { clave cero: ver VDigestCompute }
  VmacSetKey(key, T.Digest);
end;

procedure HtFree(var T: THashTableRec);
begin
  ZFree(Pointer(T.BitArr));
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
  if (Offset mod T.L) <> 0 then T.AnyShifted := True;
  if T.AnyShifted then
  begin
    { crece la mitad mas cada vez: amortizado, y el pico al realocar es 2.5
      veces la lista y no 3 }
    if T.GridN = QWord(Length(T.Grid)) then SetLength(T.Grid, T.GridN + T.GridN div 2 + 16);
    T.Grid[T.GridN].Chunk := cur;
    T.Grid[T.GridN].Start := Offset;
    Inc(T.GridN);
  end;
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

procedure HtPrepareAhead(var T: THashTableRec; const Buf: TBytes; BufOff, BlockLen,
                         Offset: QWord);
var n0: QWord;
begin
  if T.PrecomputeDigests and (BlockLen >= T.L) then
  begin
    n0 := Offset div T.L;
    VDigestCompute(T.Digest, Buf, BufOff, T.L, T.DigestArr, n0 * DIGEST_SIZE);
  end;
end;

function HtChunkPos(const T: THashTableRec; K: QWord): QWord;
var lo, hi, mid: QWord;
begin
  { busqueda binaria: lo = cuantos bloques tienen primer chunk <= K }
  lo := 0;
  hi := T.GridN;
  while lo < hi do
  begin
    mid := lo + (hi - lo) div 2;
    if T.Grid[mid].Chunk <= K then lo := mid + 1 else hi := mid;
  end;
  if lo = 0 then Exit(K * T.L);
  Result := T.Grid[lo - 1].Start + (K - T.Grid[lo - 1].Chunk) * T.L;
end;

function HtCheckPossible(const T: THashTableRec; Hash: QWord): Boolean;
begin
  Result := (T.BitArr[PtrUInt(Hash shr T.BitShift)] and (Byte(1) shl (DWord(Hash) and 7))) <> 0;
end;

procedure HtMarkPossible(var T: THashTableRec; Hash: QWord);
var p: PtrUInt;
begin
  p := PtrUInt(Hash shr T.BitShift);
  T.BitArr[p] := T.BitArr[p] or (Byte(1) shl (DWord(Hash) and 7));
end;

function ChunkarrValue(const T: THashTableRec; Hash: QWord; Chunk: DWord): DWord; inline;
begin
  Result := DWord(QWord(DWord(Hash) and T.HashMask) + QWord(Chunk));
end;

{ memcmp(digestarr[A], digestarr[B]) }
function DigestsEq(const T: THashTableRec; A, B: QWord): Boolean;
var i: LongInt; pa, pb: PByte;
begin
  pa := @T.DigestArr[A * DIGEST_SIZE];
  pb := @T.DigestArr[B * DIGEST_SIZE];
  for i := 0 to DIGEST_SIZE - 1 do
    if pa[i] <> pb[i] then Exit(False);
  Result := True;
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
      { el chunk equivalente: mismo hasharr y, con COMPARE_DIGESTS (-m3), el
        mismo digest precalculado (hash_table.cpp:271-272). Sin el digest dos
        chunks que difieren en el ultimo byte se reemplazaban aca y -m3
        perdia el match contra el mas viejo. }
      if (T.HashArr[chunk] = StoredValue) and
         (not T.CompareDigests or DigestsEq(T, chunk, CurChunk)) then
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
  aca; con el TBytes adentro, ese marco era ~29% del tiempo de -m3.
  At + L puede pasar hasta 63 bytes el fin del anillo (ver RING_TAIL): se leen
  los ceros de la cola, que es lo que el Rust rellena en digest_at. }
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
  { el Rust mira solo is_err() del seek, no la posicion que devuelve }
  if (Off > QWord(High(Int64))) or (S.Seek(Int64(Off), soBeginning) < 0) then Exit;
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
