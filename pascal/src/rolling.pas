unit Rolling;
{ Los hashes rodantes de los match finders (rolling.rs, que porta hashes.cpp).

  Deciden en que posiciones prueba -m3/-m4/-m5 y donde corta -m1/-m2, asi que
  los valores tienen que ser los del C++ bit a bit: una diferencia mueve una
  prueba y el archivo diverge desde ahi. Todo es aritmetica con wrap sobre
  QWord, que en FPC es de 64 bits en las dos arquitecturas (medido en la
  fase 0). }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes;

const
  PRIME1 = QWord(153191);   { hashes.cpp:197, el seed de todo PolynomialRollingHash }

type
  { PolynomialRollingHash<uint64>: hash(ventana de L) = sum buf[i]*PRIME^(L-1-i) mod 2^64 }
  TPolyHash = record
    Value: QWord;
    Prime: QWord;
    PrimeL: QWord;
    L: QWord;
  end;

{ power() de hashes.cpp:95, en su propio orden de multiplicaciones. }
function Power(Base: QWord; N: DWord): QWord;

procedure PolyInit(out H: TPolyHash; L: QWord; Seed: QWord);
{ El hash de B[At..At+L). }
procedure PolyMoveTo(var H: TPolyHash; const B: TBytes; At: QWord);
{ Corre la ventana un byte: sale Sub, entra Add. }
procedure PolyUpdate(var H: TPolyHash; Sub, Add: Byte); inline;

const
  CRC32_CASTAGNOLI_POLYNOM = DWord($82F63B78);   { hashes.cpp:307, reflejado }

type
  TCrcTable = array[0..255] of DWord;

  { CrcRollingHash<uint32>: CRC-32C de la ventana de L, corrido sacando el
    byte que sale por RollingCRCTab. }
  TCrcHash = record
    Value: DWord;
    CrcTab, RollingTab: TCrcTable;
    L: QWord;
  end;

{ FastTableBuild (hashes.cpp:267), linea por linea: da la tabla estandar del
  CRC reflejado de Poly sembrada con Seed. }
procedure FastTableBuild(var Table: TCrcTable; Seed, Poly: DWord);
function UpdateCrc(Crc: DWord; const Table: TCrcTable; B: Byte): DWord; inline;
procedure CrcInit(out H: TCrcHash; L: QWord; Poly: DWord);
procedure CrcMoveTo(var H: TCrcHash; const B: TBytes; At: QWord);
procedure CrcUpdate(var H: TCrcHash; Sub, Add: Byte); inline;

{ lb(n) de util.rs: piso de log2(n|1). }
function Lb(N: QWord): DWord;
function RoundupToPowerOfTwo(N: QWord): QWord;
function RounddownToPowerOfTwo(N: QWord): QWord;

implementation

function Power(Base: QWord; N: DWord): QWord;
var r, b: QWord; n2: DWord;
begin
  r := 1;
  b := Base;
  n2 := N;
  while n2 <> 0 do
  begin
    if (n2 mod 2) = 1 then
    begin
      r := r * b;
      Dec(n2);
    end;
    n2 := n2 div 2;
    b := b * b;
  end;
  Result := r;
end;

procedure PolyInit(out H: TPolyHash; L: QWord; Seed: QWord);
begin
  H.Value := 0;
  H.Prime := Seed;
  H.PrimeL := Power(Seed, DWord(L));
  H.L := L;
end;

procedure PolyMoveTo(var H: TPolyHash; const B: TBytes; At: QWord);
var i: QWord;
begin
  H.Value := 0;
  i := 0;
  while i < H.L do
  begin
    H.Value := H.Value * H.Prime + QWord(B[At + i]);
    Inc(i);
  end;
end;

procedure PolyUpdate(var H: TPolyHash; Sub, Add: Byte);
begin
  H.Value := H.Value * H.Prime + QWord(Add) - H.PrimeL * QWord(Sub);
end;

procedure FastTableBuild(var Table: TCrcTable; Seed, Poly: DWord);
var crc, i, j, mask: DWord;
begin
  crc := Seed;
  Table[0] := 0;
  Table[128] := crc;
  i := 64;
  while i <> 0 do
  begin
    { poly & !((crc & 1) - 1): el polinomio si el bit bajo esta prendido }
    if (crc and 1) <> 0 then mask := Poly else mask := 0;
    crc := (crc shr 1) xor mask;
    Table[i] := crc;
    i := i div 2;
  end;
  i := 2;
  while i < 256 do
  begin
    j := 1;
    while j < i do
    begin
      Table[i + j] := Table[i] xor Table[j];
      Inc(j);
    end;
    i := i * 2;
  end;
end;

function UpdateCrc(Crc: DWord; const Table: TCrcTable; B: Byte): DWord;
begin
  Result := Table[(Crc xor DWord(B)) and $FF] xor (Crc shr 8);
end;

procedure CrcInit(out H: TCrcHash; L: QWord; Poly: DWord);
var crc: DWord; i: QWord;
begin
  FastTableBuild(H.CrcTab, Poly, Poly);
  crc := UpdateCrc(0, H.CrcTab, 128);
  i := 0;
  while i < L do
  begin
    crc := UpdateCrc(crc, H.CrcTab, 0);
    Inc(i);
  end;
  FastTableBuild(H.RollingTab, crc, Poly);
  H.Value := 0;
  H.L := L;
end;

procedure CrcUpdate(var H: TCrcHash; Sub, Add: Byte);
begin
  H.Value := UpdateCrc(H.Value, H.CrcTab, Add) xor H.RollingTab[Sub];
end;

procedure CrcMoveTo(var H: TCrcHash; const B: TBytes; At: QWord);
var i: QWord;
begin
  H.Value := 0;
  i := 0;
  while i < H.L do
  begin
    CrcUpdate(H, 0, B[At + i]);
    Inc(i);
  end;
end;

function Lb(N: QWord): DWord;
var x: QWord;
begin
  x := N or 1;
  Result := 0;
  while x > 1 do
  begin
    x := x shr 1;
    Inc(Result);
  end;
end;

function RoundupToPowerOfTwo(N: QWord): QWord;
begin
  if N = 0 then Exit(0);
  if N = 1 then Exit(1);
  Result := QWord(2) shl Lb(N - 1);
end;

function RounddownToPowerOfTwo(N: QWord): QWord;
begin
  if N = 0 then Exit(1);
  Result := QWord(1) shl Lb(N);
end;

end.
