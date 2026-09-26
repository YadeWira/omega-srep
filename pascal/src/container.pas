unit Container;
{ El armazon del archivo .osr: cabecera, semilla, cabeceras de bloque y footer,
  para v1-v4 y para v5.

  Los dos contenedores viven en la misma unidad a proposito: comparten la misma
  pregunta -- "que dice este archivo que es" -- y tenerlos juntos hace visible
  en que se diferencian, que es justo lo que `docs/format-spec-v5.md` explica.

  Todos los campos usan tipos de ancho explicito. Un `Integer` aca cambiaria el
  tamano del registro segun el modo del compilador y un `SizeInt` segun la
  arquitectura; ver `src/widths.pas`. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes;

const
  { v1-v4 }
  ARCHIVE_HEADER_SIZE   = 16;
  BLOCK_HEADER_SIZE     = 12;
  INDEX_LZ_FOOTER_SIZE  = 24;
  BULAT_SIGNATURE       = DWord($26351817);
  SREP_SIGNATURE        = DWord($5052534F);   { "OSRP" little-endian }
  SREP_FOOTER_VERSION1  = DWord(1);
  { Explicitas y no `not SREP_SIGNATURE`: en FPC el `not` de una constante se
    evalua con mas ancho que un DWord, asi que la comparacion contra el valor
    leido del archivo falla aunque los 32 bits bajos coincidan. }
  SREP_SIGNATURE_INV    = DWord($AFADACB0);
  BULAT_SIGNATURE_INV   = DWord($D9CAE7E8);

  { v5 }
  V5_HEADER_SIZE        = 28;
  V5_FOOTER_SIZE        = 32;
  V5_BLOCK_HEADER_SIZE  = 12;
  V5_MAGIC              = DWord($3552534F);   { "OSR5" little-endian }
  V5_FOOTER_MAGIC       = DWord($4652534F);   { "OSRF" little-endian }
  V5_FLAG_HAS_DUP       = Byte(1);
  V5_KNOWN_FLAGS        = V5_FLAG_HAS_DUP;

type
  TContainerError = (ceOK, ceTruncated, ceNotAnOsrepFile, ceUnsupportedVersion,
                     ceNoFooter, ceUnsupportedFooterVersion, ceBadFlags,
                     ceBadHash, ceBadCrc, ceBlockCountMismatch);

  THashInfo = record
    Name: AnsiString;
    Num: Byte;
    SeedSize: Byte;
    HashSize: Byte;
  end;

  { v1-v4 }
  TArchiveHeader = record
    Version: Byte;          { 1..4 }
    HashNum: Byte;
    HashSeedSize: Byte;
    HashSize: Byte;
    BaseLen: DWord;
  end;

  TBlockHeader = record
    LiteralBytes: DWord;
    OrigSize: DWord;
    StatSize: DWord;        { 0 en v4: el tamano viene de la tabla del footer }
  end;

  TFooterHead = record
    TotalStatSize: QWord;
    FooterSize: DWord;
    FooterVersion: DWord;
  end;

  { v5 }
  TV5Header = record
    Version: Byte;
    Flags: Byte;
    HashId: Byte;
    HashSize: Byte;
    MaxMatch: DWord;
    BlockCount: DWord;
    OriginalSize: QWord;
  end;

  TV5Footer = record
    BlockCount: DWord;
    StatSize: QWord;
    MetaOffset: QWord;
    MetaSize: DWord;
  end;

function HashByNum(Num: Byte; out H: THashInfo): Boolean;
function HashByName(const Name: AnsiString; out H: THashInfo): Boolean;

function DecodeArchiveHeader(const B: TBytes; out H: TArchiveHeader): TContainerError;
function EncodeArchiveHeader(const H: TArchiveHeader): TBytes;
function DecodeBlockHeader(const B: TBytes; At: QWord; out BH: TBlockHeader): TContainerError;
function EncodeBlockHeader(const BH: TBlockHeader): TBytes;
function DecodeFooterHead(const B: TBytes; At: QWord; out F: TFooterHead): TContainerError;
function EncodeFooterHead(TotalStatSize: QWord; BlockCount: DWord): TBytes;

function DecodeV5Header(const B: TBytes; out H: TV5Header): TContainerError;
function EncodeV5Header(const H: TV5Header): TBytes;
function DecodeV5Footer(const B: TBytes; At: QWord; out F: TV5Footer): TContainerError;
function EncodeV5Footer(const F: TV5Footer): TBytes;

function Crc32c(const B: TBytes; At, Len: QWord): DWord;
function IsV5(const B: TBytes): Boolean;

implementation

{ A proposito NO se usa SysUtils aca: define su propio `TBytes`, que en la
  seccion de implementacion tapa al de `Hashes` y hace que las firmas dejen de
  coincidir con las del interface. El compilador lo reporta como "Forward
  declaration not solved", que no dice nada del tipo tapado. Por eso la
  minuscula se hace a mano abajo. }

const
  { El nombre no puede ser HASHES: chocaria con la unidad Hashes, y Pascal no
    distingue mayusculas. }
  HASH_TABLE: array[0..5] of THashInfo = (
    (Name: 'md5';     Num: 0; SeedSize: 0;  HashSize: 16),
    (Name: '';        Num: 1; SeedSize: 0;  HashSize: 16),
    (Name: 'sha1';    Num: 2; SeedSize: 0;  HashSize: 20),
    (Name: 'sha512';  Num: 3; SeedSize: 0;  HashSize: 64),
    (Name: 'vmac';    Num: 4; SeedSize: 32; HashSize: 16),
    (Name: 'siphash'; Num: 5; SeedSize: 16; HashSize: 8));

function HashByNum(Num: Byte; out H: THashInfo): Boolean;
var i: LongInt;
begin
  for i := 0 to High(HASH_TABLE) do
    if HASH_TABLE[i].Num = Num then begin H := HASH_TABLE[i]; Exit(True); end;
  Result := False;
end;

function LowerAscii(const S: AnsiString): AnsiString;
var i: LongInt;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if (Result[i] >= 'A') and (Result[i] <= 'Z') then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function HashByName(const Name: AnsiString; out H: THashInfo): Boolean;
var i: LongInt;
begin
  for i := 0 to High(HASH_TABLE) do
    if LowerAscii(HASH_TABLE[i].Name) = LowerAscii(Name) then
    begin H := HASH_TABLE[i]; Exit(True); end;
  Result := False;
end;

function LE32(const B: TBytes; At: QWord): DWord; inline;
begin
  Result := DWord(B[At]) or (DWord(B[At+1]) shl 8) or
            (DWord(B[At+2]) shl 16) or (DWord(B[At+3]) shl 24);
end;

function LE64(const B: TBytes; At: QWord): QWord; inline;
begin
  Result := QWord(LE32(B, At)) or (QWord(LE32(B, At + 4)) shl 32);
end;

procedure PutLE32(var B: TBytes; At: QWord; V: DWord); inline;
begin
  B[At]   := Byte(V);         B[At+1] := Byte(V shr 8);
  B[At+2] := Byte(V shr 16);  B[At+3] := Byte(V shr 24);
end;

procedure PutLE64(var B: TBytes; At: QWord; V: QWord); inline;
begin
  PutLE32(B, At, DWord(V));
  PutLE32(B, At + 4, DWord(V shr 32));
end;

function IsV5(const B: TBytes): Boolean;
begin
  Result := (QWord(Length(B)) >= 4) and (LE32(B, 0) = V5_MAGIC);
end;

{ ------------------------------------------------------------- v1..v4 --- }

function DecodeArchiveHeader(const B: TBytes; out H: TArchiveHeader): TContainerError;
var w: DWord;
begin
  if QWord(Length(B)) < ARCHIVE_HEADER_SIZE then Exit(ceTruncated);
  if (LE32(B, 0) <> BULAT_SIGNATURE) or (LE32(B, 4) <> SREP_SIGNATURE) then
    Exit(ceNotAnOsrepFile);
  w := LE32(B, 8);
  H.Version := Byte(w and 255);
  if (H.Version < 1) or (H.Version > 4) then Exit(ceUnsupportedVersion);
  H.HashNum      := Byte((w shr 8) and 255);
  H.HashSeedSize := Byte((w shr 16) and 255);
  { El digest se guarda SESGADO -16: `hash_size = ((w >> 24) + 16) & 255`.
    Por eso siphash (8 bytes) deja 0xF8 en ese byte. }
  H.HashSize     := Byte(((w shr 24) + 16) and 255);
  H.BaseLen      := LE32(B, 12);
  Result := ceOK;
end;

function EncodeArchiveHeader(const H: TArchiveHeader): TBytes;
var w: DWord;
begin
  SetLength(Result, ARCHIVE_HEADER_SIZE);
  w := DWord(H.Version) or (DWord(H.HashNum) shl 8) or
       (DWord(H.HashSeedSize) shl 16) or ((DWord(H.HashSize) - 16) shl 24);
  PutLE32(Result, 0, BULAT_SIGNATURE);
  PutLE32(Result, 4, SREP_SIGNATURE);
  PutLE32(Result, 8, w);
  PutLE32(Result, 12, H.BaseLen);
end;

function DecodeBlockHeader(const B: TBytes; At: QWord; out BH: TBlockHeader): TContainerError;
begin
  if QWord(Length(B)) < At + BLOCK_HEADER_SIZE then Exit(ceTruncated);
  BH.LiteralBytes := LE32(B, At);
  BH.OrigSize     := LE32(B, At + 4);
  BH.StatSize     := LE32(B, At + 8);
  Result := ceOK;
end;

function EncodeBlockHeader(const BH: TBlockHeader): TBytes;
begin
  SetLength(Result, BLOCK_HEADER_SIZE);
  PutLE32(Result, 0, BH.LiteralBytes);
  PutLE32(Result, 4, BH.OrigSize);
  PutLE32(Result, 8, BH.StatSize);
end;

function DecodeFooterHead(const B: TBytes; At: QWord; out F: TFooterHead): TContainerError;
begin
  if QWord(Length(B)) < At + INDEX_LZ_FOOTER_SIZE then Exit(ceTruncated);
  F.TotalStatSize := QWord(LE32(B, At)) or (QWord(LE32(B, At + 4)) shl 32);
  F.FooterSize    := LE32(B, At + 8);
  { Solo el byte bajo, como el Rust (`& 255`). Comparar la palabra entera
    rechaza un footer que el Rust acepta. }
  F.FooterVersion := LE32(B, At + 12) and 255;
  { El footer v4 se valida con las dos firmas INVERTIDAS. }
  if (LE32(B, At + 16) <> SREP_SIGNATURE_INV) or
     (LE32(B, At + 20) <> BULAT_SIGNATURE_INV) then Exit(ceNoFooter);
  if F.FooterVersion <> SREP_FOOTER_VERSION1 then Exit(ceUnsupportedFooterVersion);
  Result := ceOK;
end;

function EncodeFooterHead(TotalStatSize: QWord; BlockCount: DWord): TBytes;
begin
  SetLength(Result, INDEX_LZ_FOOTER_SIZE);
  PutLE32(Result, 0, DWord(TotalStatSize));
  PutLE32(Result, 4, DWord(TotalStatSize shr 32));
  PutLE32(Result, 8, DWord(INDEX_LZ_FOOTER_SIZE) + 4 * BlockCount);
  PutLE32(Result, 12, SREP_FOOTER_VERSION1);
  PutLE32(Result, 16, SREP_SIGNATURE_INV);
  PutLE32(Result, 20, BULAT_SIGNATURE_INV);
end;

{ ------------------------------------------------------------------ v5 --- }

var
  Crc32cTable: array[0..255] of DWord;
  CrcReady: Boolean = False;

procedure BuildCrcTable;
var i, j: LongInt; c: DWord;
begin
  if CrcReady then Exit;
  for i := 0 to 255 do
  begin
    c := DWord(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then c := (c shr 1) xor DWord($82F63B78)
      else c := c shr 1;
    Crc32cTable[i] := c;
  end;
  CrcReady := True;
end;

{ CRC-32C (Castagnoli) COMO LO USA ESTE PROYECTO, que NO es la variante
  canonica: arranca en 0 y no hace el XOR final (`rolling.rs:286`,
  `crc32c_of`). La tabla si es la estandar. Usar la canonica --init
  0xFFFFFFFF, xor final 0xFFFFFFFF-- compila, corre, y rechaza como corrupto
  todo archivo v5 sano: sobre el header de prueba da 2b5ff9a1 donde el archivo
  guarda afa4154f. }
function Crc32c(const B: TBytes; At, Len: QWord): DWord;
var i: QWord; c: DWord;
begin
  BuildCrcTable;
  c := 0;
  i := 0;
  while i < Len do
  begin
    c := Crc32cTable[(c xor DWord(B[At + i])) and $FF] xor (c shr 8);
    Inc(i);
  end;
  Result := c;
end;

function DecodeV5Header(const B: TBytes; out H: TV5Header): TContainerError;
begin
  if QWord(Length(B)) < V5_HEADER_SIZE then Exit(ceTruncated);
  if LE32(B, 0) <> V5_MAGIC then Exit(ceNotAnOsrepFile);
  H.Version := B[4];
  if H.Version <> 5 then Exit(ceUnsupportedVersion);
  H.Flags := B[5];
  { Los bits no definidos se RECHAZAN, no se ignoran: asi una extension futura
    falla limpio en un lector viejo en vez de malinterpretar el layout. }
  if (H.Flags and (not V5_KNOWN_FLAGS)) <> 0 then Exit(ceBadFlags);
  H.HashId       := B[6];
  H.HashSize     := B[7];
  H.MaxMatch     := LE32(B, 8);
  H.BlockCount   := LE32(B, 12);
  H.OriginalSize := LE64(B, 16);
  if Crc32c(B, 0, 24) <> LE32(B, 24) then Exit(ceBadCrc);
  Result := ceOK;
end;

function EncodeV5Header(const H: TV5Header): TBytes;
begin
  SetLength(Result, V5_HEADER_SIZE);
  PutLE32(Result, 0, V5_MAGIC);
  Result[4] := H.Version;  Result[5] := H.Flags;
  Result[6] := H.HashId;   Result[7] := H.HashSize;
  PutLE32(Result, 8, H.MaxMatch);
  PutLE32(Result, 12, H.BlockCount);
  PutLE64(Result, 16, H.OriginalSize);
  PutLE32(Result, 24, Crc32c(Result, 0, 24));
end;

function DecodeV5Footer(const B: TBytes; At: QWord; out F: TV5Footer): TContainerError;
begin
  if QWord(Length(B)) < At + V5_FOOTER_SIZE then Exit(ceTruncated);
  if LE32(B, At) <> V5_FOOTER_MAGIC then Exit(ceNoFooter);
  F.BlockCount := LE32(B, At + 4);
  F.StatSize   := LE64(B, At + 8);
  F.MetaOffset := LE64(B, At + 16);
  F.MetaSize   := LE32(B, At + 24);
  if Crc32c(B, At, 28) <> LE32(B, At + 28) then Exit(ceBadCrc);
  Result := ceOK;
end;

function EncodeV5Footer(const F: TV5Footer): TBytes;
begin
  SetLength(Result, V5_FOOTER_SIZE);
  PutLE32(Result, 0, V5_FOOTER_MAGIC);
  PutLE32(Result, 4, F.BlockCount);
  PutLE64(Result, 8, F.StatSize);
  PutLE64(Result, 16, F.MetaOffset);
  PutLE32(Result, 24, F.MetaSize);
  PutLE32(Result, 28, Crc32c(Result, 0, 28));
end;

end.
