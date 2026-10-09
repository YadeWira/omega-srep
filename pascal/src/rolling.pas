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
