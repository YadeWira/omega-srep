unit V5Verify;
{ --verify (v5.rs: parse y verify) y la inspeccion de un v1-v4
  (container.rs: Archive::parse), que --verify usa para decir "esto es un v1-v4,
  que no se puede verificar" en vez de "esto no es un archivo osrep".

  Verifica todo lo que un v5 permite SIN reconstruirlo -- lo que un v4 no
  ofrece en absoluto: los tres CRC-32C, las magias y los bits de flags, que
  hash_id/hash_size describan una funcion real, los dos conteos de bloques,
  stat_size contra los bloques recorridos, que el archivo termine donde dice el
  footer, cada varint, y cada record contra las mismas reglas de rango que
  aplica el decoder. Lo que NO puede cubrir: un bit dentro de un run de
  literales. Nada en v5 checksumea los bytes guardados.

  Los errores llevan el texto del Debug del Rust (BadVersion(6),
  BadHash con id y size, BadCrc("header")...), porque la CLI los imprime
  tal cual. Por eso el parseo es propio y no reusa DecodeV5Header: el Rust
  chequea el CRC ANTES que las flags, y el nombre del error se ve. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Widths, Hashes, Container;

type
  EV5 = class(Exception);

  TVerifyReport = record
    Blocks: DWord;
    OriginalSize: QWord;
    Records: QWord;
    HasDupMeta: Boolean;
    HasBlockDigests: Boolean;
  end;

  { archive::Info: lo que muestra -i }
  TArchiveInfo = record
    Mode: AnsiString;          { 'v5', 'Index-LZ', 'Future-LZ', 'I/O LZ' }
    HashName: AnsiString;
    BaseLen: DWord;
    Blocks: QWord;
    OrigSize, CompSize, StatSize: QWord;
  end;

{ v5::verify. Lanza EV5 con el Debug del V5Error. }
procedure VerifyV5(const B: TBytes; out R: TVerifyReport);

{ archive::inspect para v1-v4: el contenedor entero se parsea y el hash es
  conocido. }
function InspectV14(const B: TBytes): Boolean;

{ archive::inspect completo (v5 por v5::parse, sin las reglas de verify). }
function Inspect(const B: TBytes; out Info: TArchiveInfo): Boolean;

implementation

const
  HEADER_SIZE = 28;
  FOOTER_SIZE = 32;
  BLOCK_HEADER_SIZE = 12;
  MAGIC = DWord($3552534F);           { "OSR5" }
  FOOTER_MAGIC = DWord($4652534F);    { "OSRF" }
  FLAG_HAS_DUP = 1;
  KNOWN_FLAGS = 1;

type
  TRecord = record LitLen, MatchLen, Distance: QWord; end;
  TBlockView = record
    LiteralBytes, OrigSize, StatSize: DWord;
    Recs: array of TRecord;
  end;

function L32(const B: TBytes; At: QWord): DWord;
begin
  Result := DWord(B[At]) or (DWord(B[At + 1]) shl 8) or (DWord(B[At + 2]) shl 16) or
            (DWord(B[At + 3]) shl 24);
end;

function L64(const B: TBytes; At: QWord): QWord;
begin
  Result := QWord(L32(B, At)) or (QWord(L32(B, At + 4)) shl 32);
end;

procedure Fail(const S: AnsiString);
begin
  raise EV5.Create(S);
end;

{ get_varint: LEB128 de hasta 64 bits }
function GetVarint(const B: TBytes; Limit: QWord; var Pos: QWord): QWord;
var shift: LongInt; c: Byte;
begin
  Result := 0;
  shift := 0;
  while True do
  begin
    if Pos >= Limit then Fail('BadVarint');
    c := B[Pos];
    Inc(Pos);
    if (shift > 63) or ((shift = 63) and ((c and $7F) > 1)) then Fail('BadVarint');
    Result := Result or (QWord(c and $7F) shl shift);
    if (c and $80) = 0 then Exit;
    Inc(shift, 7);
  end;
end;

procedure VerifyCore(const B: TBytes; OnlyParse: Boolean; out R: TVerifyReport;
                     out StatTotal: QWord);
var
  n, pos, seedSize, hashSize, totalStat, blockStart, blockEnd, p, src, dest, metaSize,
  metaOff, metaEnd, k, records, origSize: QWord;
  flags, hashId, hsz: Byte;
  blockCount, crc: DWord;
  info: THashInfo;
  expected: Byte;
  blocks: array of TBlockView;
  bi: QWord;
  fBlockCount: DWord;
  fStatSize, fMetaOffset: QWord;
  fMetaSize: DWord;
  nrec: QWord;
  rr: TRecord;
begin
  n := QWord(Length(B));
  { Header::decode: magia, version, CRC, flags -- en ese orden }
  if n < HEADER_SIZE then Fail('Truncated');
  if L32(B, 0) <> MAGIC then Fail('BadMagic');
  if B[4] <> 5 then Fail('BadVersion(' + IntToStr(B[4]) + ')');
  if L32(B, 24) <> Crc32c(B, 0, 24) then Fail('BadCrc("header")');
  flags := B[5];
  if (flags and not Byte(KNOWN_FLAGS)) <> 0 then Fail('BadFlags(' + IntToStr(flags) + ')');
  hashId := B[6];
  hsz := B[7];
  blockCount := L32(B, 12);
  origSize := L64(B, 16);
  { Header::hash }
  if not HashByNum(hashId, info) then
    Fail('BadHash { id: ' + IntToStr(hashId) + ', size: ' + IntToStr(hsz) + ' }');
  if info.Name = '' then expected := 0 else expected := info.HashSize;
  if hsz <> expected then
    Fail('BadHash { id: ' + IntToStr(hashId) + ', size: ' + IntToStr(hsz) + ' }');
  hashSize := hsz;

  pos := HEADER_SIZE;
  seedSize := info.SeedSize;
  if n < pos + seedSize + FOOTER_SIZE then Fail('Truncated');
  pos := pos + seedSize;

  SetLength(blocks, blockCount);
  totalStat := 0;
  bi := 0;
  while bi < QWord(blockCount) do
  begin
    if n < pos + BLOCK_HEADER_SIZE + hashSize then Fail('Truncated');
    blocks[bi].LiteralBytes := L32(B, pos);
    blocks[bi].OrigSize := L32(B, pos + 4);
    blocks[bi].StatSize := L32(B, pos + 8);
    pos := pos + BLOCK_HEADER_SIZE;
    if n < pos + hashSize + QWord(blocks[bi].StatSize) + QWord(blocks[bi].LiteralBytes) then
      Fail('Truncated');
    pos := pos + hashSize;
    { decode_records sobre la lista del bloque }
    nrec := 0;
    p := pos;
    while p < pos + blocks[bi].StatSize do
    begin
      rr.LitLen := GetVarint(B, pos + blocks[bi].StatSize, p);
      rr.MatchLen := GetVarint(B, pos + blocks[bi].StatSize, p);
      rr.Distance := GetVarint(B, pos + blocks[bi].StatSize, p);
      if nrec >= QWord(Length(blocks[bi].Recs)) then
        SetLength(blocks[bi].Recs, Length(blocks[bi].Recs) * 2 + 16);
      blocks[bi].Recs[nrec] := rr;
      Inc(nrec);
    end;
    SetLength(blocks[bi].Recs, nrec);
    pos := pos + blocks[bi].StatSize + blocks[bi].LiteralBytes;
    totalStat := totalStat + blocks[bi].StatSize;
    Inc(bi);
  end;

  { el footer siempre es lo ultimo del archivo }
  if n < FOOTER_SIZE then Fail('Truncated');
  if L32(B, n - FOOTER_SIZE) <> FOOTER_MAGIC then Fail('BadFooterMagic');
  if L32(B, n - 4) <> Crc32c(B, n - FOOTER_SIZE, 28) then Fail('BadCrc("footer")');
  fBlockCount := L32(B, n - FOOTER_SIZE + 4);
  fStatSize := L64(B, n - FOOTER_SIZE + 8);
  fMetaOffset := L64(B, n - FOOTER_SIZE + 16);
  fMetaSize := L32(B, n - FOOTER_SIZE + 24);
  if (fBlockCount <> blockCount) or (fStatSize <> totalStat) then Fail('BlockCountMismatch');
  if pos + QWord(fMetaSize) + FOOTER_SIZE <> n then Fail('BadMeta');
  { dup_meta: validar el blob aca tambien }
  if (flags and FLAG_HAS_DUP) <> 0 then
  begin
    metaSize := fMetaSize;
    metaOff := fMetaOffset;
    if metaSize = 0 then Fail('BadMeta');
    if metaOff > High(QWord) - metaSize then Fail('BadMeta');
    metaEnd := metaOff + metaSize;
    if metaEnd > n then Fail('BadMeta');
    if metaSize < 24 + 4 then Fail('BadMeta');
    if (B[metaOff] <> Ord('D')) or (B[metaOff + 1] <> Ord('U')) or (B[metaOff + 2] <> Ord('P')) or
       (B[metaOff + 3] <> Ord('R')) or (B[metaOff + 4] <> 1) then Fail('BadMeta');
    crc := L32(B, metaEnd - 4);
    if crc <> Crc32c(B, metaOff, metaSize - 4) then Fail('BadCrc("meta")');
  end;

  StatTotal := fStatSize;
  R.Blocks := blockCount;
  R.OriginalSize := origSize;
  R.Records := 0;
  R.HasDupMeta := fMetaSize > 0;
  R.HasBlockDigests := hsz > 0;
  if OnlyParse then Exit;

  { verify: las reglas de rango del decoder, sin aplicarlas. Los records de
    Future-LZ no son "literales y despues match": lit_len es el hueco hasta el
    ORIGEN del proximo match, el match se copia HACIA ADELANTE a src+distance y
    el cursor avanza al origen. }
  blockStart := 0;
  records := 0;
  bi := 0;
  while bi < QWord(blockCount) do
  begin
    if blockStart > High(QWord) - QWord(blocks[bi].OrigSize) then Fail('BadBlock');
    blockEnd := blockStart + blocks[bi].OrigSize;
    p := blockStart;
    k := 0;
    while k < QWord(Length(blocks[bi].Recs)) do
    begin
      rr := blocks[bi].Recs[k];
      if p > High(QWord) - rr.LitLen then Fail('BadBlock');
      src := p + rr.LitLen;
      if src >= blockEnd then Fail('BadBlock');
      if rr.MatchLen > blockEnd - src then Fail('BadBlock');
      if rr.Distance = 0 then Fail('BadBlock');
      if src > High(QWord) - rr.Distance then Fail('BadBlock');
      dest := src + rr.Distance;
      if dest > High(QWord) - rr.MatchLen then Fail('BadBlock');
      if dest + rr.MatchLen > origSize then Fail('BadBlock');
      p := src;
      Inc(k);
    end;
    records := records + QWord(Length(blocks[bi].Recs));
    blockStart := blockEnd;
    Inc(bi);
  end;
  if blockStart <> origSize then Fail('BadBlock');

  R.Blocks := blockCount;
  R.OriginalSize := origSize;
  R.Records := records;
  R.HasDupMeta := fMetaSize > 0;
  R.HasBlockDigests := hsz > 0;
end;

{ Archive::parse (container.rs) para v1-v4, y que el hash sea conocido. }
procedure VerifyV5(const B: TBytes; out R: TVerifyReport);
var st: QWord;
begin
  VerifyCore(B, False, R, st);
end;

function InspectCore(const B: TBytes; out Info: TArchiveInfo): Boolean; forward;

function InspectV14(const B: TBytes): Boolean;
var info: TArchiveInfo;
begin
  Result := InspectCore(B, info);
end;

function Inspect(const B: TBytes; out Info: TArchiveInfo): Boolean;
var r: TVerifyReport; st: QWord; hi: THashInfo;
begin
  if (Length(B) >= HEADER_SIZE) and (L32(B, 0) = MAGIC) then
  begin
    try
      VerifyCore(B, True, r, st);
    except
      on EV5 do Exit(False);
    end;
    HashByNum(B[6], hi);
    Info.Mode := 'v5';
    Info.HashName := hi.Name;
    Info.BaseLen := 0;
    Info.Blocks := r.Blocks;
    Info.OrigSize := r.OriginalSize;
    Info.CompSize := QWord(Length(B));
    Info.StatSize := st;
    Exit(True);
  end;
  Result := InspectCore(B, Info);
end;

function InspectCore(const B: TBytes; out Info: TArchiveInfo): Boolean;
var
  h: TArchiveHeader;
  hinfo: THashInfo;
  n, bhs, pos, statSize, tableSize, start, matchListStart, need, inlineStat, tableSum, nb, i: QWord;
  footerSize: DWord;
  table: array of DWord;
  lit, orig, st: DWord;
  isV4: Boolean;
  origSum, statSum: QWord;
begin
  Result := False;
  origSum := 0;
  statSum := 0;
  n := QWord(Length(B));
  if DecodeArchiveHeader(B, h) <> ceOK then Exit;
  bhs := BLOCK_HEADER_SIZE + QWord(h.HashSize);
  pos := ARCHIVE_HEADER_SIZE + QWord(h.HashSeedSize);
  if pos > n then Exit;
  isV4 := h.Version = 4;
  SetLength(table, 0);
  statSize := 0;
  footerSize := 0;
  if isV4 then
  begin
    if n < pos + INDEX_LZ_FOOTER_SIZE then Exit;
    { FooterHead::decode: firmas y version }
    if (L32(B, n - 8) <> DWord($AFADACB0)) or (L32(B, n - 4) <> DWord($D9CAE7E8)) then Exit;
    if (L32(B, n - 24 + 12) and 255) <> 1 then Exit;
    statSize := L64(B, n - 24);
    footerSize := L32(B, n - 24 + 8);
    if footerSize < INDEX_LZ_FOOTER_SIZE then Exit;
    tableSize := footerSize - INDEX_LZ_FOOTER_SIZE;
    if QWord(footerSize) > n then Exit;
    if statSize > n - QWord(footerSize) then Exit;
    start := n - QWord(footerSize) - statSize;
    if (start < pos) or ((tableSize mod 4) <> 0) then Exit;
    SetLength(table, tableSize div 4);
    i := 0;
    while i < tableSize div 4 do
    begin
      table[i] := L32(B, n - QWord(footerSize) + i * 4);
      Inc(i);
    end;
    matchListStart := start;
  end
  else
    matchListStart := n;

  nb := 0;
  while True do
  begin
    if pos = matchListStart then Break;
    if matchListStart - pos < bhs then Exit;
    lit := L32(B, pos);
    orig := L32(B, pos + 4);
    st := L32(B, pos + 8);
    if (not isV4) and (lit = 0) and (orig = 0) then Break;   { el terminador }
    if isV4 then
    begin
      if nb >= QWord(Length(table)) then Exit;
      if st <> 0 then Exit;
      inlineStat := 0;
    end
    else
      inlineStat := st;
    need := bhs + inlineStat + QWord(lit);
    if matchListStart - pos < need then Exit;
    origSum := origSum + QWord(orig);
    statSum := statSum + QWord(st);
    Inc(nb);
    pos := pos + need;
  end;

  if isV4 then
  begin
    if QWord(Length(table)) <> nb then Exit;
    tableSum := 0;
    i := 0;
    while i < QWord(Length(table)) do begin tableSum := tableSum + table[i]; Inc(i); end;
    if tableSum <> statSize then Exit;
    if matchListStart + statSize <> n - QWord(footerSize) then Exit;
  end;
  Result := HashByNum(h.HashNum, hinfo);
  if not Result then Exit;
  if isV4 then Info.Mode := 'Index-LZ'
  else if h.Version = 3 then Info.Mode := 'Future-LZ'
  else Info.Mode := 'I/O LZ';
  Info.HashName := hinfo.Name;
  Info.BaseLen := h.BaseLen;
  Info.Blocks := nb;
  Info.OrigSize := origSum;
  Info.CompSize := n;
  { v4 guarda la lista entera al final y anota su tamano en el footer; v1-v3
    llevan la lista de cada bloque adentro }
  if statSize > 0 then Info.StatSize := statSize else Info.StatSize := statSum;
end;

end.
