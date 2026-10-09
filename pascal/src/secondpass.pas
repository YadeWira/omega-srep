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
  se re-emiten usan FuturelzBaseLen. Input se relee desde el principio. }
procedure RunSecondPass(const Blocks: TCompressedBlocks; NBlocks: QWord; Input, Output: TStream;
                        RoundMatches: Boolean; BaseLen, FuturelzBaseLen: DWord;
                        FutureLz, IndexLz, V5: Boolean; const DupMeta: TBytes;
                        Index: TStream = nil);

implementation

uses FixedCompress, StreamIO;

type
  TMatches = record
    W: array of TLzMatch;
    N: QWord;
  end;

procedure MPush(var M: TMatches; const V: TLzMatch);
begin
  if M.N >= QWord(Length(M.W)) then
  begin
    if Length(M.W) < 256 then SetLength(M.W, 256) else SetLength(M.W, Length(M.W) * 2);
  end;
  M.W[M.N] := V;
  Inc(M.N);
end;

{ Orden estable por Src (merge sort). El C++ usa std::sort, que no es
  estable, pero el comparador es estricto en src y el encoder nunca emite dos
  matches con el mismo origen: estable es la eleccion reproducible, la misma
  que hace el Rust. }
procedure SortBySrc(var M: TMatches);
var tmp: array of TLzMatch;
  procedure MergeSort(lo, hi: QWord);
  var mid, i, j, k: QWord;
  begin
    if hi - lo < 2 then Exit;
    mid := lo + (hi - lo) div 2;
    MergeSort(lo, mid);
    MergeSort(mid, hi);
    i := lo; j := mid; k := lo;
    while (i < mid) and (j < hi) do
    begin
      if M.W[j].Src < M.W[i].Src then begin tmp[k] := M.W[j]; Inc(j); end
      else begin tmp[k] := M.W[i]; Inc(i); end;
      Inc(k);
    end;
    while i < mid do begin tmp[k] := M.W[i]; Inc(i); Inc(k); end;
    while j < hi do begin tmp[k] := M.W[j]; Inc(j); Inc(k); end;
    k := lo;
    while k < hi do begin M.W[k] := tmp[k]; Inc(k); end;   { QWord: no va en un for en i386 }
  end;
begin
  SetLength(tmp, M.N);
  MergeSort(0, M.N);
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
                        Index: TStream = nil);
var
  matches: TMatches;
  bi, at, used, blockPos, i, savedI, src, len, statSize, totalStat, inPos, lit, vn, got: QWord;
  m: TLzMatch;
  stat: TStatList;
  table: array of DWord;
  header, listBytes, blockBuf, outb, v5bytes, foot: TBytes;
  outN: QWord;
  f: TV5Footer;
begin
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

  { 2. ordenar por origen (srep.cpp:882) }
  SortBySrc(matches);

  { 3. recorrer los bloques, re-emitiendo los matches que empiezan en cada uno }
  SetLength(table, NBlocks);
  totalStat := 0;
  stat.N := 0;
  i := 0;
  Input.Seek(0, soBeginning);       { los literales de Future-LZ se releen, en orden }
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
      WriteBytes(Output, header, Length(header));
    end;

    { la lista se arma una vez y va al sink que la tenga (el archivo, o el
      -index=), asi los dos destinos no pueden separarse }
    if V5 then
    begin
      if Index <> nil then WriteBytes(Index, v5bytes, vn) else WriteBytes(Output, v5bytes, vn);
    end
    else
    begin
      SetLength(listBytes, stat.N * 4);
      at := 0;
      while at < stat.N do begin PutLE32(listBytes, at * 4, stat.W[at]); Inc(at); end;
      if Index <> nil then WriteBytes(Index, listBytes, stat.N * 4)
      else WriteBytes(Output, listBytes, stat.N * 4);
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
      WriteBytes(Output, outb, outN);
    end;
    Inc(bi);
  end;

  if IndexLz then
  begin
    { la tabla de tamanos y despues el footer de 24 }
    SetLength(foot, NBlocks * 4);
    bi := 0;
    while bi < NBlocks do begin PutLE32(foot, bi * 4, table[bi]); Inc(bi); end;
    WriteBytes(Output, foot, NBlocks * 4);
    foot := EncodeFooterHead(totalStat, DWord(NBlocks));
    WriteBytes(Output, foot, Length(foot));
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
      f.MetaOffset := QWord(Output.Position);
      SetLength(foot, Length(DupMeta) + 4);
      Move(DupMeta[0], foot[0], Length(DupMeta));
      PutLE32(foot, Length(DupMeta), Crc32c(DupMeta, 0, Length(DupMeta)));
      WriteBytes(Output, foot, Length(foot));
      f.MetaSize := DWord(Length(foot));
    end;
    foot := EncodeV5Footer(f);
    WriteBytes(Output, foot, Length(foot));
  end;
end;

end.
