unit FutureLz;
{ El decoder de Future-LZ (v3, sufijo `f`) e Index-LZ (v4, el default de las
  1.0.x), con su memory manager y el derrame a disco.

  Port de `crates/osrep-core/src/future_lz.rs` lineas 1-876. La especificacion
  de la que sale este codigo la produjeron cuatro lectores independientes, uno
  por componente, mas un critico que reviso la cobertura y resolvio
  contradicciones contra el Rust (docs/pascal-port.md, fase 4b).

  Por que este formato es el dificil. En I/O-LZ un match apunta HACIA ATRAS y
  el bloque se reconstruye solo. Aca apunta HACIA ADELANTE: los bytes de origen
  se producen en el bloque B y hacen falta en un bloque posterior. Hay que
  guardarlos mientras tanto (el memory manager), y cuando no entran en el
  presupuesto se derraman a un archivo temporal (la memoria virtual), de a
  bloques de -vmblock, desalojando primero los de destino mas lejano.

  El derrame es transparente: no cambia los bytes reconstruidos. Pero cambia
  CUANTOS bytes pasan por disco, y eso se observa (`vmw`/`vmr`).
  tests/pascal_futurelz_conformance.sh exige que esos contadores sean
  identicos a los del Rust, no solo distintos de cero: una politica de
  desalojo distinta todavia da la salida correcta.

  Reglas que este archivo sigue en TODAS las lineas, porque violarlas compila
  y corre:
    * Toda posicion o tamano se calcula en QWord, con CADA operando casteado.
      En i386 FPC evalua `DWord + DWord` en 32 bits y en x86-64 en 64; lo que el
      Rust ensancha a u64 antes de operar tiene que ensancharse aca tambien.
    * Nunca comparar un QWord contra algo con signo (Length() devuelve SizeInt):
      FPC compara en Int64 y `High(QWord) > -1` da falso. Siempre
      `QWord(Length(x))`.
    * Los centinelas van como High(QWord)/High(DWord): un literal hex mayor que
      $7FFFFFFFFFFFFFFF es Int64 para FPC.
    * Ningun `for` con variable QWord (en i386 no compila); `while`. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

{ Hashes despues de SysUtils: las dos definen TBytes, y la ultima gana. Asi
  interface e implementacion ven la misma. }
uses SysUtils, Classes, avl_tree, Widths, Hashes, Container, Digest, Decompress,
     SpillFile;

type
  TFutureLzOptions = record
    MemLimit: QWord;      { presupuesto del memory manager, en bytes }
    VmBlock: QWord;       { tamano de un slot del archivo de derrame }
    MaximumSave: DWord;   { antes del recorte vm_block-24 }
    HasVmFile: Boolean;   { -vmfile= dado, aunque sea vacio }
    VmFile: AnsiString;
  end;

  TFutureLzStats = record
    Blocks: QWord;
    OrigSize: QWord;
    Verified: Boolean;
    VmBytesWritten: QWord;
    VmBytesRead: QWord;
  end;

  TFlzProgress = procedure(Done, Total: QWord);

  EFlz = class(Exception)
  public
    Kind: TDecodeError;
    constructor CreateKind(AKind: TDecodeError; const AMsg: AnsiString);
  end;

{ FutureLzOptions::default: 1 GiB, 8 MiB, u32::MAX, sin -vmfile. }
procedure DefaultFutureLzOptions(out O: TFutureLzOptions);

function DecodeFutureLz(Input, Sink: TStream; const Opts: TFutureLzOptions;
                        out St: TFutureLzStats; out ErrMsg: AnsiString;
                        Progress: TFlzProgress = nil): TDecodeError;

implementation

const
  INVALID_INDEX      = DWord(0);
  CHUNK_SIZE         = QWord(64);
  USEFUL_CHUNK_SPACE = QWord(60);        { CHUNK_SIZE - sizeof(u32) }
  A_BLOCK_SIZE       = QWord(1048576);   { 1 MiB }
  VM_RECORD_HEADER   = QWord(20);        { len u32 + src u64 + dest u64 }
  { El chequeo de espacio usa 24, NO el encabezado de 20: son los 20 mas los
    4 del terminador. Confundirlos cambia cuantos matches entran por slot. }
  VM_FIT_MARGIN      = QWord(24);

constructor EFlz.CreateKind(AKind: TDecodeError; const AMsg: AnsiString);
begin
  inherited Create(AMsg);
  Kind := AKind;
end;

procedure Fail(K: TDecodeError; const Msg: AnsiString);
begin
  raise EFlz.CreateKind(K, Msg);
end;

procedure DefaultFutureLzOptions(out O: TFutureLzOptions);
begin
  O.MemLimit := QWord(1) shl 30;
  O.VmBlock := QWord(8) shl 20;
  O.MaximumSave := High(DWord);
  O.HasVmFile := False;
  O.VmFile := '';
end;

{ ----------------------------------------------------------- bytes LE --- }

function LE32(const B: TBytes; At: QWord): DWord; inline;
begin
  Result := DWord(B[At]) or (DWord(B[At + 1]) shl 8) or
            (DWord(B[At + 2]) shl 16) or (DWord(B[At + 3]) shl 24);
end;

function LE64(const B: TBytes; At: QWord): QWord; inline;
begin
  { El cast a QWord ANTES del shl: `DWord shl 32` no desplaza nada en FPC (la
    cuenta se enmascara), asi que sin el la palabra alta se pierde. }
  Result := QWord(LE32(B, At)) or (QWord(LE32(B, At + 4)) shl 32);
end;

procedure PutLE32(var B: TBytes; At: QWord; V: DWord); inline;
begin
  B[At] := Byte(V); B[At + 1] := Byte(V shr 8);
  B[At + 2] := Byte(V shr 16); B[At + 3] := Byte(V shr 24);
end;

procedure PutLE64(var B: TBytes; At: QWord; V: QWord); inline;
begin
  PutLE32(B, At, DWord(V));
  PutLE32(B, At + 4, DWord(V shr 32));
end;

{ ----------------------------------------------------- memory manager --- }

type
  TChunk = record
    Data: array[0..59] of Byte;
    Len: Byte;
    Next: DWord;
  end;

  TMemoryManager = record
    UsefulMemory: QWord;
    UsedChunks: QWord;       { QWord para que el *60 se haga en 64 bits }
    FreeStack: array of DWord;
    FreeCount: LongInt;
    NextIndex: DWord;
    Chunks: array of TChunk; { indexado por el indice de chunk; el 0 no se usa }
  end;

procedure MMInit(out MM: TMemoryManager; MemLimit: QWord);
var chunks: QWord;
begin
  { Redondear a MiB enteros PRIMERO, despues pasar a chunks: no es MemLimit
    div 64. }
  chunks := (MemLimit div A_BLOCK_SIZE) * A_BLOCK_SIZE div CHUNK_SIZE;
  { `wrapping_sub(1)`: con MemLimit < 1 MiB chunks es 0 y esto envuelve a
    $FFFFFFFFFFFFFFC4 -- presupuesto ILIMITADO, no cero. Es una comparacion sin
    signo mas adelante la que lo hace funcionar. }
  MM.UsefulMemory := (chunks - QWord(1)) * USEFUL_CHUNK_SPACE;
  MM.UsedChunks := 0;
  SetLength(MM.FreeStack, 64);
  MM.FreeCount := 0;
  MM.NextIndex := 1;
  SetLength(MM.Chunks, 1024);
end;

function MMAvailable(const MM: TMemoryManager): QWord;
var used: QWord;
begin
  used := MM.UsedChunks * USEFUL_CHUNK_SPACE;
  { `>` estricto y sin signo. El guard no es cosmetico: restore_from_disk puede
    dejar used*60 por encima de useful_memory. }
  if MM.UsefulMemory > used then Result := MM.UsefulMemory - used
  else Result := 0;
end;

function MMAllocate(var MM: TMemoryManager): DWord;
begin
  if MM.FreeCount > 0 then
  begin
    Dec(MM.FreeCount);
    Result := MM.FreeStack[MM.FreeCount];      { LIFO }
  end
  else
  begin
    Result := MM.NextIndex;
    Inc(MM.NextIndex);
    while QWord(Result) >= QWord(Length(MM.Chunks)) do
      SetLength(MM.Chunks, Length(MM.Chunks) * 2);
  end;
  Inc(MM.UsedChunks);
end;

{ Nunca falla y nunca mira el presupuesto: el presupuesto es blando y lo
  chequea quien llama. }
function MMSave(var MM: TMemoryManager; const Buf: TBytes; Off, Len: QWord): DWord;
var pos, n: QWord; idx, prev: DWord;
begin
  Result := INVALID_INDEX;
  if Len = 0 then Exit;
  pos := 0; prev := INVALID_INDEX;
  while pos < Len do
  begin
    n := Len - pos;
    if n > USEFUL_CHUNK_SPACE then n := USEFUL_CHUNK_SPACE;
    idx := MMAllocate(MM);    { puede redimensionar Chunks: nada de punteros }
    Move(Buf[Off + pos], MM.Chunks[idx].Data[0], n);
    MM.Chunks[idx].Len := Byte(n);
    MM.Chunks[idx].Next := INVALID_INDEX;
    if prev = INVALID_INDEX then Result := idx
    else MM.Chunks[prev].Next := idx;
    prev := idx;
    Inc(pos, n);
  end;
end;

{ Sin efectos: no libera nada ni cambia UsedChunks. }
procedure MMRestore(const MM: TMemoryManager; Index: DWord; var OutB: TBytes;
                    Off, Len: QWord);
var pos, n: QWord;
begin
  pos := 0;
  while (pos < Len) and (Index <> INVALID_INDEX) do
  begin
    n := Len - pos;
    if n > QWord(MM.Chunks[Index].Len) then n := QWord(MM.Chunks[Index].Len);
    Move(MM.Chunks[Index].Data[0], OutB[Off + pos], n);
    Inc(pos, n);
    Index := MM.Chunks[Index].Next;
  end;
end;

{ free(0) es un no-op, y hace falta: decompress_block lo llama siempre. Se
  apila de la cabeza a la cola, asi que el tope queda en la cola. }
procedure MMFree(var MM: TMemoryManager; Index: DWord);
var nxt: DWord;
begin
  while Index <> INVALID_INDEX do
  begin
    nxt := MM.Chunks[Index].Next;   { leer Next ANTES de reusar el slot }
    Dec(MM.UsedChunks);
    if MM.FreeCount >= Length(MM.FreeStack) then
      SetLength(MM.FreeStack, Length(MM.FreeStack) * 2);
    MM.FreeStack[MM.FreeCount] := Index;
    Inc(MM.FreeCount);
    Index := nxt;
  end;
end;

{ --------------------------------------------------------- match heap --- }

type
  TFlzMatch = record
    Src, Dest: QWord;
    Len, Index: DWord;     { Len = 0: punto de marca (un slot de VM) }
  end;
  TFlzMatchArray = array of TFlzMatch;
  TQWordArray = array of QWord;

  { Una "clase": todos los matches con el mismo destino, en orden de insercion. }
  PMatchClass = ^TMatchClass;
  TMatchClass = record
    Key: QWord;
    Items: TFlzMatchArray;
    Count: LongInt;
  end;

  TMatchHeap = record
    Tree: TAVLTree;
    Count: QWord;          { elementos totales, barrera incluida }
  end;

{ La firma la impone TListSortCompare y devuelve Integer; en modo objfpc eso es
  un LongInt, y widths.pas garantiza el modo. Comparacion EXPLICITA y sin
  signo: una resta rompe el orden de los QWord. }
function CmpClass(A, B: Pointer): Integer;
begin
  if PMatchClass(A)^.Key < PMatchClass(B)^.Key then Result := -1
  else if PMatchClass(A)^.Key > PMatchClass(B)^.Key then Result := 1
  else Result := 0;
end;

{ FindKey llama Compare(clave, dato). }
function CmpKeyClass(Key, Data: Pointer): Integer;
begin
  if PQWord(Key)^ < PMatchClass(Data)^.Key then Result := -1
  else if PQWord(Key)^ > PMatchClass(Data)^.Key then Result := 1
  else Result := 0;
end;

procedure HeapInsert(var H: TMatchHeap; const M: TFlzMatch);
var node: TAVLTreeNode; c: PMatchClass; key: QWord;
begin
  key := M.Dest;
  node := H.Tree.FindKey(@key, @CmpKeyClass);
  if node = nil then
  begin
    New(c);
    c^.Key := key;
    c^.Count := 0;
    SetLength(c^.Items, 1);
    H.Tree.Add(c);
  end
  else
    c := PMatchClass(node.Data);
  if c^.Count >= Length(c^.Items) then SetLength(c^.Items, Length(c^.Items) * 2);
  c^.Items[c^.Count] := M;      { al FINAL: nunca reordenar ni deduplicar }
  Inc(c^.Count);
  Inc(H.Count);
end;

procedure HeapInit(out H: TMatchHeap);
var b: TFlzMatch;
begin
  H.Tree := TAVLTree.Create(@CmpClass);
  H.Count := 0;
  { La barrera: la clave mas grande posible, para que siempre sea la ultima.
    Len es High(DWord) y NO 0, asi que no es un punto de marca. }
  b.Src := High(QWord);
  b.Dest := High(QWord);
  b.Len := High(DWord);
  b.Index := INVALID_INDEX;
  HeapInsert(H, b);
end;

procedure HeapDone(var H: TMatchHeap);
var node: TAVLTreeNode; c: PMatchClass;
begin
  if H.Tree = nil then Exit;
  node := H.Tree.FindLowest;
  while node <> nil do
  begin
    c := PMatchClass(node.Data);
    Dispose(c);
    node := H.Tree.FindSuccessor(node);
  end;
  H.Tree.Free;
  H.Tree := nil;
end;

function HeapMinDest(const H: TMatchHeap; out D: QWord): Boolean;
var node: TAVLTreeNode;
begin
  D := 0;
  node := H.Tree.FindLowest;
  if node = nil then Exit(False);
  D := PMatchClass(node.Data)^.Key;
  Result := True;
end;

{ Saca la clase ENTERA. Solo el llamador decide que liberar: el Rust libera
  unicamente cls[0], y los demas miembros se quedan con sus chunks. }
procedure HeapTakeClass(var H: TMatchHeap; Dest: QWord; out Items: TFlzMatchArray);
var node: TAVLTreeNode; c: PMatchClass;
begin
  node := H.Tree.FindKey(@Dest, @CmpKeyClass);
  if node = nil then
  begin
    SetLength(Items, 0);
    Exit;
  end;
  c := PMatchClass(node.Data);
  Items := Copy(c^.Items, 0, c^.Count);
  H.Count := H.Count - QWord(c^.Count);
  H.Tree.Delete(node);
  Dispose(c);
end;

function HeapClassFirst(const H: TMatchHeap; Dest: QWord; out M: TFlzMatch): Boolean;
var node: TAVLTreeNode; c: PMatchClass;
begin
  node := H.Tree.FindKey(@Dest, @CmpKeyClass);
  if node = nil then Exit(False);
  c := PMatchClass(node.Data);
  if c^.Count = 0 then Exit(False);
  M := c^.Items[0];
  Result := True;
end;

{ Foto de las claves distintas, de mayor a menor, tomada ANTES de mutar. }
function HeapDestsDescending(const H: TMatchHeap): TQWordArray;
var node: TAVLTreeNode; n: LongInt;
begin
  SetLength(Result, 16);
  n := 0;
  node := H.Tree.FindHighest;
  while node <> nil do
  begin
    if n >= Length(Result) then SetLength(Result, Length(Result) * 2);
    Result[n] := PMatchClass(node.Data)^.Key;
    Inc(n);
    node := H.Tree.FindPrecessor(node);
  end;
  SetLength(Result, n);
end;

{ ----------------------------------------------------- virtual memory --- }

type
  TVirtualMemory = record
    VmBlock: QWord;
    FreeBlocks: array of DWord;
    FreeCount: LongInt;
    NewBlock: DWord;
    HasVmFile: Boolean;
    VmFileName: AnsiString;
    SpillOpen: Boolean;
    Spill: THandleStream;          { TFileStream con -vmfile=, si no el temporal }
    SpillPath: AnsiString;
    TotalRead, TotalWrite: QWord;
  end;

procedure VmInit(out VM: TVirtualMemory; VmBlock: QWord; HasVmFile: Boolean;
                 const VmFile: AnsiString);
begin
  { Sin acceso al disco: el archivo se crea recien en el primer derrame. Si
    nunca hay derrame, nunca existe -- y el test de fugas de temporales cuenta
    exactamente eso. }
  VM.VmBlock := VmBlock;
  SetLength(VM.FreeBlocks, 16);
  VM.FreeCount := 0;
  VM.NewBlock := 0;
  VM.HasVmFile := HasVmFile;
  VM.VmFileName := VmFile;
  VM.SpillOpen := False;
  VM.Spill := nil;
  VM.SpillPath := '';
  VM.TotalRead := 0;
  VM.TotalWrite := 0;
end;

procedure VmDone(var VM: TVirtualMemory);
begin
  { Se cierra y DESPUES se borra; solo si llego a abrirse. Un -vmfile= que
    nunca se uso no se toca. }
  if VM.SpillOpen then
  begin
    VM.Spill.Free;
    VM.Spill := nil;
    DeleteFile(VM.SpillPath);
    VM.SpillOpen := False;
  end;
end;

function VmSpillFile(var VM: TVirtualMemory): THandleStream;
begin
  if VM.SpillOpen then Exit(VM.Spill);
  if VM.HasVmFile then
  begin
    VM.SpillPath := VM.VmFileName;
    try
      VM.Spill := TFileStream.Create(VM.SpillPath, fmCreate);   { trunca }
    except
      DeleteFile(VM.SpillPath);   { el Rust suelta el VmPath, que borra }
      Fail(deIo, 'cannot open the VM file ' + VM.SpillPath);
    end;
  end
  else
  begin
    { si falla, SpillPath NO es nuestro (puede ser de otro) y no se borra:
      SpillOpen sigue en falso }
    VM.Spill := CreateTempExclusive('osrep-virtual-memory', VM.SpillPath);
    if VM.Spill = nil then Fail(deBadData, 'cannot allocate the VM scratch file');
  end;
  VM.SpillOpen := True;
  Result := VM.Spill;
end;

function VmAllocBlock(var VM: TVirtualMemory): DWord;
begin
  if VM.FreeCount > 0 then
  begin
    Dec(VM.FreeCount);
    Result := VM.FreeBlocks[VM.FreeCount];    { LIFO: el ultimo leido }
  end
  else
  begin
    Result := VM.NewBlock;                    { post-incremento: el primero es 0 }
    Inc(VM.NewBlock);
  end;
end;

procedure VmPushFreeBlock(var VM: TVirtualMemory; B: DWord);
begin
  if VM.FreeCount >= Length(VM.FreeBlocks) then
    SetLength(VM.FreeBlocks, Length(VM.FreeBlocks) * 2);
  VM.FreeBlocks[VM.FreeCount] := B;
  Inc(VM.FreeCount);
end;

procedure StreamReadExact(S: TStream; var B: TBytes; Off, Len: QWord);
var got: LongInt; pos, n: QWord;
begin
  pos := 0;
  while pos < Len do
  begin
    n := Len - pos;
    if n > (QWord(1) shl 30) then n := QWord(1) shl 30;   { Read toma un LongInt }
    got := S.Read(B[Off + pos], LongInt(n));
    if got <= 0 then Fail(deIo, 'failed to fill whole buffer');
    Inc(pos, QWord(got));
  end;
end;

{ THandleStream.Seek no lanza: con un offset que no entra en un Int64 devuelve
  -1 y deja la posicion donde estaba, y lo que se lea despues sale de otro
  lado. El Rust falla ahi (EINVAL). Solo es alcanzable con -vmblock enorme. }
procedure SeekExact(S: TStream; Off: QWord);
begin
  if (Off > QWord(High(Int64))) or (S.Seek(Int64(Off), soBeginning) <> Int64(Off)) then
    Fail(deIo, 'Invalid argument');
end;

procedure WriteZeros(S: TStream; N: QWord);
var z: TBytes; k: QWord;
begin
  if N = 0 then Exit;
  k := N;
  if k > (QWord(1) shl 20) then k := QWord(1) shl 20;
  SetLength(z, k);                { en ceros }
  while N > 0 do
  begin
    if k > N then k := N;
    S.WriteBuffer(z[0], LongInt(k));
    Dec(N, k);
  end;
end;

{ Desaloja, de mayor a menor destino, lo que entre en UN slot. Devuelve cuantas
  clases desalojo; 0 significa que no toco NADA.

  El slot se arma a medida (GrowOut): se reserva lo empaquetado, no el
  -vmblock entero. Antes era `SetLength(buf, VmBlock)` en CADA llamada, aunque
  no hubiera nada que desalojar -- 258 MiB contra 10 del Rust con un -vmblock
  grande --, y en i386 un -vmblock >= 2^31 llegaba negativo a SetLength y uno
  >= 2^32 llegaba truncado: el empaquetado escribia fuera del buffer. En el
  archivo queda lo mismo que escribe el Rust: lo empaquetado, el terminador y
  ceros hasta completar el slot. }
function VmSaveToDisk(var VM: TVirtualMemory; var MM: TMemoryManager;
                      var H: TMatchHeap): QWord;
var
  buf: TBytes;
  p, evicted, minDest, w: QWord;
  dests: TQWordArray;
  i: LongInt;
  m: TFlzMatch;
  dropped: TFlzMatchArray;
  blk: DWord;
  f: THandleStream;
begin
  buf := nil;
  p := 0;
  evicted := 0;
  minDest := High(QWord);
  dests := HeapDestsDescending(H);
  for i := 0 to High(dests) do
  begin
    if dests[i] = High(QWord) then Continue;             { la barrera }
    if not HeapClassFirst(H, dests[i], m) then Continue;
    if m.Index = INVALID_INDEX then Continue;            { toda la clase }
    { BREAK, no continue: termina aunque entren otros mas chicos. }
    if VM.VmBlock - p < VM_FIT_MARGIN + QWord(m.Len) then Break;
    { el margen de 24 cubre este registro (20 + len) y el terminador }
    if not GrowOut(buf, p + VM_FIT_MARGIN + QWord(m.Len), VM.VmBlock) then
      Fail(deIo, 'Out of memory');
    PutLE32(buf, p, m.Len);
    PutLE64(buf, p + 4, m.Src);
    PutLE64(buf, p + 12, m.Dest);
    MMRestore(MM, m.Index, buf, p + VM_RECORD_HEADER, QWord(m.Len));
    p := p + VM_RECORD_HEADER + QWord(m.Len);
    minDest := m.Dest;            { el ULTIMO, que es el menor: no un min() }
    MMFree(MM, m.Index);          { solo cls[0] }
    HeapTakeClass(H, dests[i], dropped);
    Inc(evicted);
  end;
  if evicted = 0 then Exit(0);

  PutLE32(buf, p, 0);             { terminador }
  blk := VmAllocBlock(VM);
  f := VmSpillFile(VM);
  SeekExact(f, QWord(blk) * VM.VmBlock);
  { buf ya viene en ceros despues del terminador; lo que falta del slot se
    completa sin reservarlo }
  w := QWord(Length(buf));
  SinkWrite(f, buf, w);
  WriteZeros(f, VM.VmBlock - w);
  VM.TotalWrite := VM.TotalWrite + VM.VmBlock;   { el slot entero }
  { La marca se inserta DESPUES de escribir. Su Src es el numero de slot. }
  m.Src := QWord(blk);
  m.Dest := minDest;
  m.Len := 0;
  m.Index := INVALID_INDEX;
  HeapInsert(H, m);
  Result := evicted;
end;

{ El Rust lee el slot ENTERO y recien despues lo recorre. Aca se recorre
  leyendo registro por registro: un slot de -vmblock=2G no entra en un proceso
  de 32 bits (y en i386 un -vmblock >= 2^32 llegaba truncado a SetLength, con
  la lectura escribiendo fuera del buffer). Para fallar en el mismo lugar que
  el read_exact del Rust, antes de tocar nada se exige que el slot entero
  exista en el archivo. Los registros los escribio VmSaveToDisk, asi que
  siempre terminan dentro del slot; si no, el Rust hace panic y aca se falla. }
procedure VmRestoreFromDisk(var VM: TVirtualMemory; var MM: TMemoryManager;
                            var H: TMatchHeap; Block: QWord);
var
  blk, len: DWord;
  hdr, rec: TBytes;
  p, off: QWord;
  m: TFlzMatch;
  f: THandleStream;
begin
  { Primero hacer lugar -- antes de leer el slot y antes de liberarlo, asi
    estos desalojos nunca lo pisan. }
  while MMAvailable(MM) < VM.VmBlock do
    if VmSaveToDisk(VM, MM, H) = 0 then
      Fail(deBadData, 'cannot free enough VM space to restore a spilled block');
  if VM.VmBlock < 4 then
    Fail(deBadData, 'VM block too small to hold a spilled block');
  blk := DWord(Block);            { truncado a 32 bits, como el `as u32` }
  off := QWord(blk) * VM.VmBlock;
  f := VmSpillFile(VM);
  { en el orden del Rust: primero el seek (que puede fallar con EINVAL), despues
    la lectura (que falla si el slot no esta entero) }
  SeekExact(f, off);
  if (VM.VmBlock > QWord(High(Int64)) - off) or (QWord(f.Size) < off + VM.VmBlock) then
    Fail(deIo, 'failed to fill whole buffer');
  VM.TotalRead := VM.TotalRead + VM.VmBlock;
  VmPushFreeBlock(VM, blk);       { DESPUES de leer }
  SetLength(hdr, VM_RECORD_HEADER);
  rec := nil;
  p := 0;
  while True do
  begin
    if VM.VmBlock - p < 4 then Fail(deBadData, 'spilled block overruns its slot');
    StreamReadExact(f, hdr, 0, 4);
    len := LE32(hdr, 0);
    if len = 0 then Break;
    if VM.VmBlock - p - 4 < QWord(VM_RECORD_HEADER - 4) + QWord(len) then
      Fail(deBadData, 'spilled block overruns its slot');
    StreamReadExact(f, hdr, 4, VM_RECORD_HEADER - 4);
    m.Src := LE64(hdr, 4);
    m.Dest := LE64(hdr, 12);
    m.Len := len;
    if QWord(Length(rec)) < QWord(len) then
    begin
      if QWord(len) > QWord(High(SizeInt)) then Fail(deIo, 'Out of memory');
      SetLength(rec, SizeInt(len));
    end;
    StreamReadExact(f, rec, 0, QWord(len));
    m.Index := MMSave(MM, rec, 0, QWord(len));
    HeapInsert(H, m);             { en el orden del slot: destino descendente }
    p := p + VM_RECORD_HEADER + QWord(len);
  end;
end;

{ ---------------------------------------------------------- the block --- }

{ Un record de v3/v4: 4 STATs. lit_len es la DISTANCIA ENTRE ORIGENES
  consecutivos -- no un run de literales. El largo suma L con wrap de 32 bits,
  y se guarda en un DWord antes de compararlo con nada. }
procedure DecodeRec(const S: array of DWord; R: LongInt; L: DWord;
                    out Lit, Off: QWord; out Len: DWord);
var i: LongInt; t: DWord;
begin
  i := R * 4;
  Lit := QWord(S[i]);
  Off := QWord(S[i + 1]) or (QWord(S[i + 2]) shl 32);
  t := S[i + 3] + L;
  Len := t;
end;

{ OutLen es el largo del bloque; OutBuf crece hasta el a medida que se escribe
  (ver GrowOut en decompress.pas) y termina exactamente de ese largo. }
procedure DecompressBlockFlz(L: DWord; Sink: TStream; BlockStart: QWord;
                             const Stats: array of DWord; const Literals: TBytes;
                             var OutBuf: TBytes; OutLen: QWord;
                             var MM: TMemoryManager;
                             var VM: TVirtualMemory; var H: TMatchHeap;
                             MaximumSave: DWord);
var
  blockEnd, blockPos, src, dest, lit, off, litLen, inPos, outPos, d: QWord;
  nlit, nout: QWord;
  r, nrec: LongInt;
  rl, idx: DWord;
  cls: TFlzMatchArray;
  m: TFlzMatch;
begin
  blockEnd := BlockStart + OutLen;
  nrec := Length(Stats) div 4;       { 1..3 STATs sueltos se ignoran }
  nlit := QWord(Length(Literals));
  nout := OutLen;

  { PASO 1: validar TODOS los records e insertar los que caen en este bloque. }
  blockPos := BlockStart;
  for r := 0 to nrec - 1 do
  begin
    DecodeRec(Stats, r, L, lit, off, rl);
    src := blockPos + lit;
    dest := src + off;
    if (src < blockPos) or (src >= blockEnd) or
       (QWord(rl) > blockEnd - src) or (dest <= src) then
      Fail(deBadData, 'future-lz record out of range');
    if dest < blockEnd then
    begin
      m.Src := src; m.Dest := dest; m.Len := rl; m.Index := INVALID_INDEX;
      HeapInsert(H, m);
    end;
    blockPos := src;                 { el ORIGEN, no src+len }
  end;

  { PASO 2: llenar el bloque en orden de destino. }
  inPos := 0;
  outPos := 0;
  while True do
  begin
    if not HeapMinDest(H, d) then Break;
    if d >= blockEnd then Break;
    { Sacar la clase ANTES de restaurar: al reves, se borra el match recien
      restaurado en cada decode que derrama. }
    HeapTakeClass(H, d, cls);
    m := cls[0];
    if m.Len = 0 then
    begin
      VmRestoreFromDisk(VM, MM, H, m.Src);   { Src es el numero de slot }
      Continue;
    end;
    litLen := (m.Dest - BlockStart) - outPos;
    if (m.Dest < BlockStart + outPos) or (litLen > nlit - inPos) or
       (outPos + litLen + QWord(m.Len) > nout) then
      Fail(deBadData, 'future-lz match does not fit the block');
    if not GrowOut(OutBuf, outPos + litLen + QWord(m.Len), nout) then
      Fail(deIo, 'Out of memory');
    if litLen > 0 then Move(Literals[inPos], OutBuf[outPos], litLen);
    Inc(inPos, litLen);
    Inc(outPos, litLen);

    if (m.Len >= MaximumSave) and (m.Src < BlockStart) then
    begin
      { demasiado grande para guardarlo: se relee de la salida ya escrita }
      Sink.Seek(Int64(m.Src), soBeginning);
      StreamReadExact(Sink, OutBuf, outPos, QWord(m.Len));
    end
    else if m.Index <> INVALID_INDEX then
      MMRestore(MM, m.Index, OutBuf, outPos, QWord(m.Len))
    else
      { dentro del bloque: copia LZ hacia adelante, que replica el patron
        cuando se solapa. Un Move daria otra cosa. }
      LzCopy(OutBuf, m.Src - BlockStart, outPos, QWord(m.Len));
    Inc(outPos, QWord(m.Len));
    MMFree(MM, m.Index);             { no-op con indice 0 }
  end;

  if (nlit - inPos) <> (nout - outPos) then
    Fail(deBadData, 'future-lz literal run does not fill the block');
  { siempre, aunque no sobren literales: el bloque sale del largo exacto }
  if not GrowOut(OutBuf, nout, nout) then Fail(deIo, 'Out of memory');
  if inPos < nlit then Move(Literals[inPos], OutBuf[outPos], nlit - inPos);

  { PASO 3: guardar los matches que salen de este bloque. Corre con el bloque
    ya COMPLETO, porque copia los bytes de origen desde OutBuf. }
  blockPos := BlockStart;
  for r := 0 to nrec - 1 do
  begin
    DecodeRec(Stats, r, L, lit, off, rl);
    src := blockPos + lit;
    dest := src + off;
    if dest >= blockEnd then
    begin
      if rl >= MaximumSave then
        idx := INVALID_INDEX           { se releera de la salida en su destino }
      else
      begin
        while QWord(rl) > MMAvailable(MM) do
          if VmSaveToDisk(VM, MM, H) = 0 then
            Fail(deBadData, 'cannot free enough memory to store a match');
        idx := MMSave(MM, OutBuf, src - BlockStart, QWord(rl));
      end;
      m.Src := src; m.Dest := dest; m.Len := rl; m.Index := idx;
      HeapInsert(H, m);
    end;
    blockPos := src;
  end;
end;

{ --------------------------------------------------------- the driver --- }

type
  TReadRes = (rrOK, rrEOF, rrPartial);

{ read_exact_or_eof: pedir 0 bytes siempre anda, incluso en EOF. 0 bytes leidos
  sin haber leido nada es un EOF limpio; despues de un llenado parcial es un
  truncamiento.

  N sale del archivo, asi que el buffer crece a medida que LLEGAN los datos en
  vez de reservarse entero: un bloque que declara 3 GiB de literales en un
  archivo de 109 bytes falla por truncado habiendo ocupado lo que habia, como
  el Rust (ver GrowOut en decompress.pas). Al terminar bien, Length(B) = N. }
function ReadExactOrEof(S: TStream; var B: TBytes; N: QWord): TReadRes;
const FIRST = QWord(16) shl 20;
var got: LongInt; pos, cap, chunk: QWord;
begin
  if N = 0 then
  begin
    SetLength(B, 0);
    Exit(rrOK);
  end;
  cap := N;
  if cap > FIRST then cap := FIRST;
  SetLength(B, SizeInt(cap));
  pos := 0;
  while pos < N do
  begin
    if pos = cap then
    begin
      cap := cap * 2;
      if cap > N then cap := N;
      if cap > QWord(High(SizeInt)) then Fail(deIo, 'Out of memory');
      SetLength(B, SizeInt(cap));
    end;
    chunk := cap - pos;
    if chunk > (QWord(1) shl 30) then chunk := QWord(1) shl 30;   { Read toma un LongInt }
    got := S.Read(B[pos], LongInt(chunk));
    if got <= 0 then
    begin
      if pos = 0 then Exit(rrEOF) else Exit(rrPartial);
    end;
    Inc(pos, QWord(got));
  end;
  Result := rrOK;
end;

procedure ReadOrTruncated(S: TStream; var B: TBytes; N: QWord);
begin
  if ReadExactOrEof(S, B, N) <> rrOK then Fail(deContainer, 'truncated structure');
end;

function DecodeFutureLz(Input, Sink: TStream; const Opts: TFutureLzOptions;
                        out St: TFutureLzStats; out ErrMsg: AnsiString;
                        Progress: TFlzProgress = nil): TDecodeError;
var
  hdr, seed, blockBuf, literals, outbuf, want, footer, tableBytes, statBytes: TBytes;
  h: TArchiveHeader;
  ce: TContainerError;
  dig: TDigestSel;
  verified, isV4, mmReady, vmReady, heapReady: Boolean;
  maxSave: DWord;
  bhs, fahs, consumed, total: QWord;
  filesize, footerSize, statSize, tableSize, stSum: QWord;
  stats, table, blockStats: array of DWord;
  mm: TMemoryManager;
  vm: TVirtualMemory;
  heap: TMatchHeap;
  blockStart, blockEnd, blocks, statCursor, sz, nwords, k: QWord;
  lb, osz, ssz, fv: DWord;
  rr: TReadRes;
  i: LongInt;
begin
  St.Blocks := 0; St.OrigSize := 0; St.Verified := False;
  St.VmBytesWritten := 0; St.VmBytesRead := 0;
  ErrMsg := '';
  Result := deOK;
  mmReady := False; vmReady := False; heapReady := False;
  outbuf := nil;                   { GrowOut parte de lo que haya }
  heap.Tree := nil;
  total := 0;
  try
    try
      if Assigned(Progress) then
      begin
        total := QWord(Input.Seek(0, soEnd));
        Input.Seek(0, soBeginning);
      end;

      ReadOrTruncated(Input, hdr, ARCHIVE_HEADER_SIZE);
      ce := DecodeArchiveHeader(hdr, h);
      case ce of
        ceOK: ;
        ceNotAnOsrepFile: Fail(deContainer, 'not an Omega SREP file (.osr)');
        ceUnsupportedVersion: Fail(deContainer, 'incompatible compressed data format');
      else Fail(deContainer, 'truncated structure');
      end;
      if (h.Version = 1) or (h.Version = 2) then
        Fail(deNotIoLz, 'not a Future/Index-LZ archive (v' + IntToStr(h.Version) + ')');
      isV4 := h.Version = 4;

      ReadOrTruncated(Input, seed, QWord(h.HashSeedSize));
      DigestForArchive(h.HashNum, h.HashSeedSize, h.HashSize, seed, dig);
      verified := DigestEnabled(dig);

      { El recorte: estricto y con cast que TRUNCA. }
      maxSave := Opts.MaximumSave;
      if Opts.VmBlock > QWord(24) then
        if DWord(Opts.VmBlock - QWord(24)) < maxSave then
          maxSave := DWord(Opts.VmBlock - QWord(24));

      bhs := QWord(BLOCK_HEADER_SIZE) + QWord(h.HashSize);
      fahs := QWord(ARCHIVE_HEADER_SIZE) + QWord(h.HashSeedSize);
      consumed := fahs;

      SetLength(stats, 0);
      SetLength(table, 0);
      if isV4 then
      begin
        { [cabecera][semilla][bloques][listas][tabla][footer de 24] }
        filesize := QWord(Input.Seek(0, soEnd));
        if filesize < QWord(INDEX_LZ_FOOTER_SIZE) then Fail(deContainer, 'truncated structure');
        Input.Seek(Int64(filesize - QWord(INDEX_LZ_FOOTER_SIZE)), soBeginning);
        SetLength(footer, INDEX_LZ_FOOTER_SIZE);
        StreamReadExact(Input, footer, 0, INDEX_LZ_FOOTER_SIZE);
        if (LE32(footer, 16) <> SREP_SIGNATURE_INV) or (LE32(footer, 20) <> BULAT_SIGNATURE_INV) then
          Fail(deContainer, 'no Omega SREP footer');
        fv := LE32(footer, 12) and 255;        { solo el byte bajo }
        if fv <> 1 then Fail(deContainer, 'incompatible footer format');
        statSize := QWord(LE32(footer, 0)) or (QWord(LE32(footer, 4)) shl 32);
        footerSize := QWord(LE32(footer, 8));
        stSum := fahs + footerSize + statSize;  { suma con wrap, como el Rust }
        if stSum > filesize then Fail(deContainer, 'footer + index exceeds the file size');
        if footerSize < QWord(INDEX_LZ_FOOTER_SIZE) then
          Fail(deContainer, 'footer + index exceeds the file size');
        tableSize := footerSize - QWord(INDEX_LZ_FOOTER_SIZE);
        Input.Seek(Int64(filesize - footerSize), soBeginning);
        { con la suma de arriba envuelta, footerSize puede superar al archivo:
          no reservar lo que dice, leer lo que hay }
        if ReadExactOrEof(Input, tableBytes, tableSize) <> rrOK then
          Fail(deIo, 'failed to fill whole buffer');
        if (tableSize mod 4) <> 0 then
          Fail(deContainer, 'block-size table disagrees with the block headers');
        SetLength(table, tableSize div 4);
        k := 0;
        while k < tableSize div 4 do
        begin
          table[k] := LE32(tableBytes, k * 4);
          Inc(k);
        end;
        Input.Seek(Int64(filesize - footerSize - statSize), soBeginning);
        if ReadExactOrEof(Input, statBytes, statSize) <> rrOK then
          Fail(deIo, 'failed to fill whole buffer');
        if (statSize mod 4) <> 0 then
          Fail(deBadData, 'match list is not a whole number of STATs');
        SetLength(stats, statSize div 4);
        k := 0;
        while k < statSize div 4 do
        begin
          stats[k] := LE32(statBytes, k * 4);
          Inc(k);
        end;
        Input.Seek(Int64(fahs), soBeginning);
      end;

      { Se crean DESPUES de parsear el footer: un footer roto nunca toca el VM. }
      MMInit(mm, Opts.MemLimit); mmReady := True;
      VmInit(vm, Opts.VmBlock, Opts.HasVmFile, Opts.VmFile); vmReady := True;
      HeapInit(heap); heapReady := True;

      blockStart := 0;
      blocks := 0;
      statCursor := 0;
      while True do
      begin
        { v4 sabe cuantos bloques hay y para ANTES de leer. }
        if isV4 and (blocks = QWord(Length(table))) then Break;
        rr := ReadExactOrEof(Input, blockBuf, bhs);
        if rr = rrPartial then Fail(deContainer, 'truncated structure');
        if rr = rrEOF then
        begin
          { v3 termina cuando el heap quedo solo con la barrera }
          if (not isV4) and (heap.Count = 1) then Break;
          Fail(deContainer, 'truncated structure');
        end;
        lb := LE32(blockBuf, 0);
        osz := LE32(blockBuf, 4);
        ssz := LE32(blockBuf, 8);
        { la marca de fin de v3, valida solo con el heap drenado }
        if (not isV4) and (lb = 0) and (osz = 0) and (heap.Count = 1) then Break;
        blockEnd := blockStart + QWord(osz);

        if isV4 then
        begin
          if blocks >= QWord(Length(table)) then
            Fail(deContainer, 'block-size table disagrees with the block headers');
          sz := QWord(table[blocks]);
          nwords := sz div 4;
          if ((sz mod 4) <> 0) or (statCursor + nwords > QWord(Length(stats))) then
            Fail(deContainer, 'block-size table disagrees with the block headers');
          SetLength(blockStats, nwords);
          k := 0;
          while k < nwords do
          begin
            blockStats[k] := stats[statCursor + k];
            Inc(k);
          end;
          Inc(statCursor, nwords);
        end
        else
        begin
          { leer PRIMERO, recien despues el chequeo de multiplo de 4: al reves,
            un archivo truncado da BadData donde el Rust da Truncated }
          ReadOrTruncated(Input, statBytes, QWord(ssz));
          if (QWord(ssz) mod 4) <> 0 then
            Fail(deBadData, 'match list is not a whole number of STATs');
          SetLength(blockStats, QWord(ssz) div 4);
          k := 0;
          while k < QWord(ssz) div 4 do
          begin
            blockStats[k] := LE32(statBytes, k * 4);
            Inc(k);
          end;
        end;

        ReadOrTruncated(Input, literals, QWord(lb));
        { se reusa el buffer del bloque anterior; solo tiene que no sobrar }
        if QWord(Length(outbuf)) > QWord(osz) then SetLength(outbuf, osz);
        DecompressBlockFlz(h.BaseLen, Sink, blockStart, blockStats, literals,
                           outbuf, QWord(osz), mm, vm, heap, maxSave);

        if verified then
        begin
          want := DigestCompute(dig, outbuf);
          { el Rust hace panic si el digest guardado es mas corto; se trata
            como discrepancia, igual que en v5 }
          if QWord(h.HashSize) < QWord(Length(want)) then
            Fail(deDigestMismatch, 'checksum of decoded block ' + IntToStr(blocks) +
                 ' differs from the stored one');
          for i := 0 to Length(want) - 1 do
            if blockBuf[QWord(BLOCK_HEADER_SIZE) + QWord(i)] <> want[i] then
              Fail(deDigestMismatch, 'checksum of decoded block ' + IntToStr(blocks) +
                   ' differs from the stored one');
        end;

        { recien con el digest aprobado se escribe }
        Sink.Seek(Int64(blockStart), soBeginning);
        SinkWrite(Sink, outbuf, QWord(osz));
        blockStart := blockEnd;
        Inc(blocks);

        consumed := consumed + bhs + QWord(ssz) + QWord(lb);
        if Assigned(Progress) then Progress(consumed, total);
      end;
      if Assigned(Progress) then Progress(total, total);

      St.Blocks := blocks;
      St.OrigSize := blockStart;
      St.Verified := verified;
      St.VmBytesWritten := vm.TotalWrite;
      St.VmBytesRead := vm.TotalRead;
    except
      on E: EFlz do
      begin
        Result := E.Kind;
        ErrMsg := E.Message;
      end;
      on E: Exception do
      begin
        { errores de stream: seek fuera de rango, lectura corta, escritura }
        Result := deIo;
        ErrMsg := E.Message;
      end;
    end;
  finally
    if heapReady then HeapDone(heap);
    if vmReady then VmDone(vm);
  end;
end;

end.
