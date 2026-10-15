unit SecondPass;
{ La segunda pasada de Future-LZ / Index-LZ (second_pass.rs, que porta
  srep.cpp:820-970), y la de v5, que tiene la misma forma de bloque.

  La primera pasada deja la lista de cada bloque en SU forma de record
  (ROUND_MATCHES / BASE_LEN), que es temporal: aca se juntan todas, se
  ordenan por origen, y se vuelve a emitir la lista de cada bloque con los
  matches que EMPIEZAN en el, recortados al bloque y con FUTURELZ_BASE_LEN (0
  en v3/v4) como base del record.

  Esa re-emision es la que separa las dos colas del formato: Future-LZ (y v5)
  escribe cabecera -> lista -> literales por bloque; Index-LZ deja que la
  primera pasada escriba cabecera -> literales y pone todas las listas despues
  del ultimo bloque, seguidas de la tabla de tamanos y el footer. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, Container, LzCodec;

type
  { COMPRESSED_BLOCK (srep.cpp:172-179): un bloque como lo dejo la primera pasada. }
  TCompressedBlock = record
    Start, EndPos, Size: QWord;
    Header: TBytes;             { los tres STATs y el digest }
    Stat: TStatList;            { los records de la primera pasada }
  end;
  TCompressedBlocks = array of TCompressedBlock;

{ RoundMatches/BaseLen describen los records de la PRIMERA pasada; los que
  se re-emiten usan FuturelzBaseLen. Input se relee desde el principio.
  BaseOffset es lo que ya se escribio en Output antes de esta pasada (la
  cabecera y la semilla): el offset de la meta de -dup se cuenta desde ahi,
  como el Rust, y no se le pregunta a Output.Position, que en un FIFO o un
  pipe no existe (daba -1 y el footer salia con un offset de 2^64-1). }
procedure RunSecondPass(const Blocks: TCompressedBlocks; NBlocks: QWord; Input, Output: TStream;
                        RoundMatches: Boolean; BaseLen, FuturelzBaseLen: DWord;
                        FutureLz, IndexLz, V5: Boolean; const DupMeta: TBytes;
                        Index: TStream; BaseOffset: QWord);

type
  { La lista de matches de todos los bloques: N validos en W, que crece. }
  TMatches = record
    W: array of TLzMatch;
    N: QWord;
  end;

{ Ordena M.W[0..N) por Src como el std::sort de libstdc++ (srep.cpp:899).
  Publica para encodetool sortfixture, que la compara con el std::sort real. }
procedure SortBySrc(var M: TMatches);

implementation

uses FixedCompress, StreamIO;

procedure MPush(var M: TMatches; const V: TLzMatch);
begin
  if M.N >= QWord(Length(M.W)) then
  begin
    if Length(M.W) < 256 then SetLength(M.W, 256) else SetLength(M.W, Length(M.W) * 2);
  end;
  M.W[M.N] := V;
  Inc(M.N);
end;

{ Orden por Src con el MISMO desempate que el C++: transcripcion del
  std::sort de libstdc++ (bits/stl_algo.h __sort/__introsort_loop/
  __final_insertion_sort, y bits/stl_heap.h para el corte por profundidad).
  No es estable, pero como rompe los empates es funcion pura del orden de
  entrada, y los matches con el mismo origen son comunes (todas las copias
  de un bloque que el buscador resuelve a la misma aparicion anterior).
  Hasta la 2.2.1 era un merge sort estable, sobre la premisa (falsa) de que
  el encoder nunca emite dos matches con el mismo origen: ~1 archivo real de
  cada 10 salia con otros bytes que el C++. El test de la transcripcion esta
  en second_pass.rs (libstdcxx_sort_matches_std_sort); esta es la misma
  transcripcion paso por paso, y la prueba `encodetool sortfixture` contra el
  std::sort real (tests/pascal_encode_conformance.sh).
  Indices Int64 y bucles while: nada de SizeInt ni de for con 64 bits. }
procedure SortBySrc(var M: TMatches);
const Threshold = 16;   { _S_threshold }

  function Less(const a, b: TLzMatch): Boolean; inline;
  begin
    Result := a.Src < b.Src;
  end;

  procedure Swap(i, j: Int64);
  var t: TLzMatch;
  begin
    t := M.W[i]; M.W[i] := M.W[j]; M.W[j] := t;
  end;

  procedure UnguardedLinearInsert(last: Int64);
  var val: TLzMatch; next: Int64;
  begin
    val := M.W[last];
    next := last - 1;
    while Less(val, M.W[next]) do
    begin
      M.W[last] := M.W[next];
      last := next;
      Dec(next);
    end;
    M.W[last] := val;
  end;

  procedure InsertionSort(first, last: Int64);
  var i, k: Int64; val: TLzMatch;
  begin
    if first = last then Exit;
    i := first + 1;
    while i < last do
    begin
      if Less(M.W[i], M.W[first]) then
      begin
        val := M.W[i];
        k := i;
        while k > first do begin M.W[k] := M.W[k - 1]; Dec(k); end;
        M.W[first] := val;
      end
      else
        UnguardedLinearInsert(i);
      Inc(i);
    end;
  end;

  procedure AdjustHeap(base, hole, len: Int64; const value: TLzMatch);
  var top, second, parent: Int64;
  begin
    top := hole;
    second := hole;
    while second < (len - 1) div 2 do
    begin
      second := 2 * (second + 1);
      if Less(M.W[base + second], M.W[base + second - 1]) then Dec(second);
      M.W[base + hole] := M.W[base + second];
      hole := second;
    end;
    if ((len and 1) = 0) and (second = (len - 2) div 2) then
    begin
      second := 2 * (second + 1);
      M.W[base + hole] := M.W[base + second - 1];
      hole := second - 1;
    end;
    { __push_heap }
    while hole > top do
    begin
      parent := (hole - 1) div 2;
      if not Less(M.W[base + parent], value) then Break;
      M.W[base + hole] := M.W[base + parent];
      hole := parent;
    end;
    M.W[base + hole] := value;
  end;

  { std::__partial_sort(first, last, last): __make_heap + __sort_heap }
  procedure HeapSort(first, last: Int64);
  var len, parent, en: Int64; value: TLzMatch;
  begin
    len := last - first;
    if len >= 2 then
    begin
      parent := (len - 2) div 2;
      while True do
      begin
        value := M.W[first + parent];
        AdjustHeap(first, parent, len, value);
        if parent = 0 then Break;
        Dec(parent);
      end;
    end;
    en := last;
    while en - first > 1 do
    begin
      Dec(en);
      value := M.W[en];
      M.W[en] := M.W[first];
      AdjustHeap(first, 0, en - first, value);
    end;
  end;

  procedure MoveMedianToFirst(result, a, b, c: Int64);
  var pick: Int64;
  begin
    if Less(M.W[a], M.W[b]) then
    begin
      if Less(M.W[b], M.W[c]) then pick := b
      else if Less(M.W[a], M.W[c]) then pick := c
      else pick := a;
    end
    else if Less(M.W[a], M.W[c]) then pick := a
    else if Less(M.W[b], M.W[c]) then pick := c
    else pick := b;
    Swap(result, pick);
  end;

  function UnguardedPartition(first, last, pivot: Int64): Int64;
  begin
    while True do
    begin
      while Less(M.W[first], M.W[pivot]) do Inc(first);
      Dec(last);
      while Less(M.W[pivot], M.W[last]) do Dec(last);
      if not (first < last) then Exit(first);
      Swap(first, last);
      Inc(first);
    end;
  end;

  procedure IntrosortLoop(first, last, depth: Int64);
  var cut: Int64;
  begin
    while last - first > Threshold do
    begin
      if depth = 0 then
      begin
        HeapSort(first, last);
        Exit;
      end;
      Dec(depth);
      MoveMedianToFirst(first, first + 1, first + (last - first) div 2, last - 1);
      cut := UnguardedPartition(first + 1, last, first);
      IntrosortLoop(cut, last, depth);
      last := cut;
    end;
  end;

var n, lg, i: Int64;
begin
  n := Int64(M.N);
  if n = 0 then Exit;
  lg := -1; i := n;
  while i > 0 do begin Inc(lg); i := i shr 1; end;   { std::__lg }
  IntrosortLoop(0, n, 2 * lg);
  if n > Threshold then
  begin
    InsertionSort(0, Threshold);
    i := Threshold;
    while i < n do begin UnguardedLinearInsert(i); Inc(i); end;
  end
  else
    InsertionSort(0, n);
end;

procedure PutVarint(var B: TBytes; var N: QWord; V: QWord);
  procedure Push(x: Byte);
  begin
    if N >= QWord(Length(B)) then
    begin
      if Length(B) < 256 then SetLength(B, 256) else SetLength(B, Length(B) * 2);
    end;
    B[N] := x;
    Inc(N);
  end;
begin
  while V >= $80 do
  begin
    Push(Byte((V and $7F) or $80));
    V := V shr 7;
  end;
  Push(Byte(V));
end;

procedure PutLE32(var B: TBytes; At: QWord; V: DWord); inline;
begin
  B[At] := Byte(V); B[At + 1] := Byte(V shr 8);
  B[At + 2] := Byte(V shr 16); B[At + 3] := Byte(V shr 24);
end;

procedure WriteBytes(S: TStream; const B: TBytes; N: QWord);
begin
  if N > 0 then WriteAll(S, B[0], N);
end;

procedure RunSecondPass(const Blocks: TCompressedBlocks; NBlocks: QWord; Input, Output: TStream;
                        RoundMatches: Boolean; BaseLen, FuturelzBaseLen: DWord;
                        FutureLz, IndexLz, V5: Boolean; const DupMeta: TBytes;
                        Index: TStream; BaseOffset: QWord);
var
  matches: TMatches;
  bi, at, used, blockPos, i, savedI, src, len, statSize, totalStat, inPos, lit, vn, got: QWord;
  m: TLzMatch;
  stat: TStatList;
  table: array of DWord;
  header, listBytes, blockBuf, outb, v5bytes, foot: TBytes;
  outN: QWord;
  f: TV5Footer;
  emitted: QWord;   { lo escrito en Output por esta pasada: el compsize del Rust }

  procedure Emit(const B: TBytes; N: QWord);
  begin
    WriteBytes(Output, B, N);
    Inc(emitted, N);
  end;

begin
  emitted := 0;
  { 1. juntar los matches de todos los bloques (srep.cpp:863-878) }
  matches.N := 0;
  bi := 0;
  while bi < NBlocks do
  begin
    blockPos := Blocks[bi].Start;
    at := 0;
    while Blocks[bi].Stat.N - at >= StatsPerMatch(RoundMatches) do
    begin
      if not DecodeLzMatch(Blocks[bi].Stat, at, RoundMatches, False, BaseLen, blockPos, m, used) then
        raise EEncode.Create('BadBlockRecord');
      MPush(matches, m);
      blockPos := blockPos + QWord(m.LitLen) + QWord(m.Len);
      at := at + used;
    end;
    Inc(bi);
  end;

  { 2. ordenar por origen (srep.cpp:899), con el desempate del std::sort del C++ }
  SortBySrc(matches);

  { 3. recorrer los bloques, re-emitiendo los matches que empiezan en cada uno }
  SetLength(table, NBlocks);
  totalStat := 0;
  stat.N := 0;
  i := 0;
  { los literales de Future-LZ se releen, en orden; el seek(Start(0))? del
    Rust: si falla, EncodeError::Io }
  if Input.Seek(0, soBeginning) < 0 then raise EEncode.Create('Io');
  bi := 0;
  while bi < NBlocks do
  begin
    StatClear(stat);
    blockPos := Blocks[bi].Start;
    savedI := i;
    while (i < matches.N) and (matches.W[i].Src < Blocks[bi].EndPos) do
    begin
      m := matches.W[i];
      if m.Src + QWord(m.Len) <= Blocks[bi].Start then
      begin
        { entero de un bloque anterior: recordar donde retomar }
        savedI := i;
        Inc(i);
        Continue;
      end;
      if m.Src > Blocks[bi].Start then src := m.Src else src := Blocks[bi].Start;
      len := QWord(m.Len) - (src - m.Src);
      if Blocks[bi].EndPos - src < len then len := Blocks[bi].EndPos - src;
      if not EncodeLzMatch(stat, False, FuturelzBaseLen, DWord(src - blockPos), m.Dest - m.Src,
                           DWord(len)) then
        MatchTooSmall(DWord(len), FuturelzBaseLen);
      blockPos := src;
      Inc(i);
    end;
    i := savedI;

    { v5: la lista se rearma en LEB128 desde las palabras recien emitidas,
      anclada en el ORIGEN (decode con future_lz) }
    vn := 0;
    if V5 then
    begin
      at := 0;
      blockPos := Blocks[bi].Start;
      while stat.N - at >= StatsPerMatch(RoundMatches) do
      begin
        if not DecodeLzMatch(stat, at, False, True, 0, blockPos, m, used) then
          raise EEncode.Create('BadBlockRecord');
        PutVarint(v5bytes, vn, QWord(m.LitLen));
        PutVarint(v5bytes, vn, QWord(m.Len));
        PutVarint(v5bytes, vn, m.Dest - m.Src);
        blockPos := blockPos + QWord(m.LitLen) + QWord(m.Len);
        at := at + used;
      end;
      statSize := vn;
    end
    else
      statSize := stat.N * 4;

    if FutureLz or V5 then
    begin
      { block->header[2] = stat_size: la primera pasada lo dejo en cero }
      header := Copy(Blocks[bi].Header);
      PutLE32(header, 8, DWord(statSize));
      Emit(header, Length(header));
    end;

    { la lista se arma una vez y va al sink que la tenga (el archivo, o el
      -index=), asi los dos destinos no pueden separarse }
    if V5 then
    begin
      if Index <> nil then WriteBytes(Index, v5bytes, vn) else Emit(v5bytes, vn);
    end
    else
    begin
      SetLength(listBytes, stat.N * 4);
      at := 0;
      while at < stat.N do begin PutLE32(listBytes, at * 4, stat.W[at]); Inc(at); end;
      if Index <> nil then WriteBytes(Index, listBytes, stat.N * 4)
      else Emit(listBytes, stat.N * 4);
    end;

    table[bi] := DWord(statSize);
    totalStat := totalStat + statSize;

    if FutureLz or V5 then
    begin
      { los literales que los records (de la primera pasada) del bloque
        dejan sin cubrir (srep.cpp:945-961) }
      SetLength(blockBuf, Blocks[bi].Size);
      got := 0;
      while got < Blocks[bi].Size do
      begin
        lit := ReadOnce(Input, blockBuf[got], Blocks[bi].Size - got);
        if lit = 0 then raise EEncode.Create('Io');
        got := got + lit;
      end;
      SetLength(outb, Blocks[bi].Size);
      outN := 0;
      inPos := 0;
      at := 0;
      while Blocks[bi].Stat.N - at >= StatsPerMatch(RoundMatches) do
      begin
        if not DecodeLzMatch(Blocks[bi].Stat, at, RoundMatches, False, BaseLen, 0, m, used) then
          raise EEncode.Create('BadBlockRecord');
        lit := QWord(m.LitLen);
        if lit > Blocks[bi].Size - inPos then raise EEncode.Create('BadBlockRecord');
        if lit > 0 then Move(blockBuf[inPos], outb[outN], lit);
        outN := outN + lit;
        inPos := inPos + lit + QWord(m.Len);
        if inPos > Blocks[bi].Size then raise EEncode.Create('BadBlockRecord');
        at := at + used;
      end;
      if Blocks[bi].Size > inPos then
      begin
        Move(blockBuf[inPos], outb[outN], Blocks[bi].Size - inPos);
        outN := outN + (Blocks[bi].Size - inPos);
      end;
      Emit(outb, outN);
    end;
    Inc(bi);
  end;

  if IndexLz then
  begin
    { la tabla de tamanos y despues el footer de 24 }
    SetLength(foot, NBlocks * 4);
    bi := 0;
    while bi < NBlocks do begin PutLE32(foot, bi * 4, table[bi]); Inc(bi); end;
    Emit(foot, NBlocks * 4);
    foot := EncodeFooterHead(totalStat, DWord(NBlocks));
    Emit(foot, Length(foot));
  end;
  if V5 then
  begin
    f.BlockCount := DWord(NBlocks);
    f.StatSize := totalStat;
    f.MetaOffset := 0;
    f.MetaSize := 0;
    if Length(DupMeta) > 0 then
    begin
      { la meta de -dup va aca: despues de los bloques, antes del footer que
        la ubica. Es el .dupref sin cambios mas un CRC-32C al final; uno que
        no sea .dupref no se escribe (encode_meta). }
      if (Length(DupMeta) < 24) or (DupMeta[0] <> Ord('D')) or (DupMeta[1] <> Ord('U')) or
         (DupMeta[2] <> Ord('P')) or (DupMeta[3] <> Ord('R')) or (DupMeta[4] <> 1) then
        raise EEncode.Create('BadDupMeta');
      f.MetaOffset := BaseOffset + emitted;
      SetLength(foot, Length(DupMeta) + 4);
      Move(DupMeta[0], foot[0], Length(DupMeta));
      PutLE32(foot, Length(DupMeta), Crc32c(DupMeta, 0, Length(DupMeta)));
      Emit(foot, Length(foot));
      f.MetaSize := DWord(Length(foot));
    end;
    foot := EncodeV5Footer(f);
    Emit(foot, Length(foot));
  end;
end;

end.
