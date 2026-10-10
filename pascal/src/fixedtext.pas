unit FixedText;
{ Los numeros con decimales que la CLI escribe (report.rs, modes.rs), byte
  por byte como el Rust.

  Dos cosas tienen que coincidir. La primera es el Double: el Rust hace
  `a as f64 * 100.0 / b as f64` en f64 puro, cada operacion redondeada una
  vez al Double mas cercano. En i386 FPC calcula por defecto en el x87 con
  precision Extended, y redondear primero a 64 bits de mantisa y despues a 53
  puede dar otro Double que redondear una sola vez (doble redondeo); por eso
  esta unidad se compila con SSE2 en i386 (el target i686 del Rust ya lo
  exige) y la conversion de QWord a Double se hace a mano, con el redondeo al
  par del `as f64` del Rust, sin pasar por Extended.

  La segunda es el texto. `format!` con precision N (`:.N`) imprime el valor decimal EXACTO
  del Double redondeado a N decimales, y un empate exacto va al par: 7.175
  como Double es 7.17499999999999982236431605997495353221893310546875 y sale
  "7.17"; 0.125 con dos decimales sale "0.12" y 2.5 con cero sale "2".
  FloatToStrF de FPC redondea otra cosa (sus 15 a 18 digitos significativos)
  y en ~1,5 % de los porcentajes daba otro ultimo digito. Aca se expande el
  Double entero con un entero grande, sin floats en el camino, asi que el
  texto no depende de la FPU ni del target. Tambien como el Rust: el signo
  sale siempre que el bit de signo este prendido ("-0.00"), NaN es "NaN" y
  los infinitos "inf" y "-inf". }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

{ SSE2 para las operaciones con Double. En x86-64 ya es el default (SSE64);
  en i386 hay que pedirlo. Los $FATAL prueban que la rama que uno cree activa
  esta activa: un simbolo mal escrito en un $IFDEF evalua falso en silencio. }
{$IFDEF CPUI386}
  {$FPUTYPE SSE2}
  {$IFNDEF FPUSSE2}{$FATAL fixedtext: no se activo SSE2 en i386}{$ENDIF}
{$ELSE}
  {$IFDEF CPUX86_64}
    {$IFNDEF FPUSSE64}{$FATAL fixedtext: x86-64 sin SSE64}{$ENDIF}
  {$ELSE}
    {$FATAL fixedtext: CPU no prevista, revisar el calculo en Double}
  {$ENDIF}
{$ENDIF}

interface

{ `x` con `Decimals` decimales, como el `format!` del Rust con precision N (`:.N`) }
function FixedStr(X: Double; Decimals: LongInt): AnsiString;
{ `q as f64`: el Double mas cercano, empates al par }
function QWordToDouble(Q: QWord): Double;
{ `num as f64 * 100.0 / den as f64` (den > 0) }
function Percent(Num, Den: QWord): Double;
{ `done as f64 / secs / MB as f64` }
function MbPerSec(Done: QWord; Secs: Double): Double;
{ milisegundos a segundos, `ms as f64 / 1000.0` }
function MsToSecs(Ms: QWord): Double;

implementation

type
  { entero grande sin signo, limbs de 32 bits, el menos significativo primero.
    Count limbs en uso; sin ceros arriba salvo el cero, que es Count = 0 }
  TBig = record
    L: array of DWord;
    Count: LongInt;
  end;

procedure BigFromQWord(out A: TBig; Q: QWord);
begin
  SetLength(A.L, 2);
  A.L[0] := DWord(Q and $FFFFFFFF);
  A.L[1] := DWord(Q shr 32);
  if A.L[1] <> 0 then A.Count := 2
  else if A.L[0] <> 0 then A.Count := 1
  else A.Count := 0;
end;

procedure BigMulSmall(var A: TBig; K: DWord);
var i: LongInt; carry, t: QWord;
begin
  carry := 0;
  for i := 0 to A.Count - 1 do
  begin
    t := QWord(A.L[i]) * K + carry;
    A.L[i] := DWord(t and $FFFFFFFF);
    carry := t shr 32;
  end;
  if carry <> 0 then
  begin
    if A.Count >= Length(A.L) then SetLength(A.L, A.Count + 4);
    A.L[A.Count] := DWord(carry);
    Inc(A.Count);
  end;
end;

procedure BigShl(var A: TBig; S: LongInt);
var limbs, bits, i: LongInt; newCount: LongInt;
begin
  if (A.Count = 0) or (S = 0) then Exit;
  limbs := S div 32;
  bits := S mod 32;
  newCount := A.Count + limbs + 1;
  if Length(A.L) < newCount then SetLength(A.L, newCount);
  A.L[newCount - 1] := 0;
  for i := A.Count - 1 downto 0 do
  begin
    if bits = 0 then
      A.L[i + limbs] := A.L[i]
    else
    begin
      A.L[i + limbs + 1] := A.L[i + limbs + 1] or (A.L[i] shr (32 - bits));
      A.L[i + limbs] := A.L[i] shl bits;
    end;
  end;
  for i := 0 to limbs - 1 do A.L[i] := 0;
  A.Count := newCount;
  while (A.Count > 0) and (A.L[A.Count - 1] = 0) do Dec(A.Count);
end;

function BigBit(const A: TBig; Bit: LongInt): Boolean;
begin
  if Bit div 32 >= A.Count then Exit(False);
  Result := (A.L[Bit div 32] shr (Bit mod 32)) and 1 <> 0;
end;

{ algun bit por debajo de Bit (exclusivo) prendido }
function BigAnyBelow(const A: TBig; Bit: LongInt): Boolean;
var i, full: LongInt;
begin
  full := Bit div 32;
  if full > A.Count then full := A.Count;
  for i := 0 to full - 1 do
    if A.L[i] <> 0 then Exit(True);
  if (Bit mod 32 <> 0) and (Bit div 32 < A.Count) then
    if A.L[Bit div 32] and ((DWord(1) shl (Bit mod 32)) - 1) <> 0 then Exit(True);
  Result := False;
end;

procedure BigShr(var A: TBig; S: LongInt);
var limbs, bits, i: LongInt;
begin
  limbs := S div 32;
  bits := S mod 32;
  if limbs >= A.Count then
  begin
    A.Count := 0;
    Exit;
  end;
  for i := 0 to A.Count - limbs - 1 do
  begin
    if bits = 0 then
      A.L[i] := A.L[i + limbs]
    else
    begin
      A.L[i] := A.L[i + limbs] shr bits;
      if i + limbs + 1 < A.Count then
        A.L[i] := A.L[i] or (A.L[i + limbs + 1] shl (32 - bits));
    end;
  end;
  A.Count := A.Count - limbs;
  while (A.Count > 0) and (A.L[A.Count - 1] = 0) do Dec(A.Count);
end;

procedure BigAddOne(var A: TBig);
var i: LongInt;
begin
  for i := 0 to A.Count - 1 do
  begin
    A.L[i] := A.L[i] + 1;
    if A.L[i] <> 0 then Exit;
  end;
  if A.Count >= Length(A.L) then SetLength(A.L, A.Count + 1);
  A.L[A.Count] := 1;
  Inc(A.Count);
end;

{ divide por K y devuelve el resto }
function BigDivSmall(var A: TBig; K: DWord): DWord;
var i: LongInt; rem, t: QWord;
begin
  rem := 0;
  for i := A.Count - 1 downto 0 do
  begin
    t := (rem shl 32) or A.L[i];
    A.L[i] := DWord(t div K);
    rem := t mod K;
  end;
  while (A.Count > 0) and (A.L[A.Count - 1] = 0) do Dec(A.Count);
  Result := DWord(rem);
end;

function BigToDecimal(var A: TBig): AnsiString;
var chunk: DWord; s: AnsiString;
begin
  if A.Count = 0 then Exit('0');
  Result := '';
  while A.Count > 0 do
  begin
    chunk := BigDivSmall(A, 1000000000);
    Str(chunk, s);
    if A.Count > 0 then
      while Length(s) < 9 do s := '0' + s;
    Result := s + Result;
  end;
end;

function FixedStr(X: Double; Decimals: LongInt): AnsiString;
var bits, frac: QWord; expField, e, i: LongInt; neg: Boolean;
    a: TBig; digits, sign: AnsiString; half, rest: Boolean;
begin
  if Decimals < 0 then Decimals := 0;
  Move(X, bits, SizeOf(bits));
  neg := (bits shr 63) <> 0;
  expField := LongInt((bits shr 52) and $7FF);
  frac := bits and ((QWord(1) shl 52) - 1);
  if neg then sign := '-' else sign := '';
  if expField = $7FF then
  begin
    if frac <> 0 then Exit('NaN');
    Exit(sign + 'inf');
  end;
  if expField = 0 then e := -1074
  else
  begin
    frac := frac or (QWord(1) shl 52);
    e := expField - 1075;
  end;

  { a = mantisa * 10^Decimals; el valor por 10^Decimals es a * 2^e }
  BigFromQWord(a, frac);
  for i := 1 to Decimals do BigMulSmall(a, 10);
  if e >= 0 then
    BigShl(a, e)
  else
  begin
    { redondeo al entero mas cercano de a / 2^-e, empates al par }
    half := BigBit(a, -e - 1);
    rest := BigAnyBelow(a, -e - 1);
    BigShr(a, -e);
    if half and (rest or BigBit(a, 0)) then BigAddOne(a);
  end;

  digits := BigToDecimal(a);
  if Decimals > 0 then
  begin
    while Length(digits) <= Decimals do digits := '0' + digits;
    digits := Copy(digits, 1, Length(digits) - Decimals) + '.' +
              Copy(digits, Length(digits) - Decimals + 1, Decimals);
  end;
  Result := sign + digits;
end;

function QWordToDouble(Q: QWord): Double;
var s: LongInt; mant, rem, halfway: QWord; scale: Double;
begin
  { hasta 2^53 la conversion desde Int64 es exacta en cualquier FPU }
  if Q < (QWord(1) shl 53) then
  begin
    Result := Int64(Q);
    Exit;
  end;
  s := 0;
  while (Q shr s) >= (QWord(1) shl 53) do Inc(s);
  mant := Q shr s;
  rem := Q and ((QWord(1) shl s) - 1);
  halfway := QWord(1) shl (s - 1);
  if (rem > halfway) or ((rem = halfway) and (mant and 1 <> 0)) then Inc(mant);
  { mant <= 2^53 y s <= 11: los dos pasos son exactos }
  scale := Int64(QWord(1) shl s);
  Result := Int64(mant);
  Result := Result * scale;
end;

function Percent(Num, Den: QWord): Double;
var a, b: Double;
const Hundred: Double = 100.0;
begin
  a := QWordToDouble(Num);
  b := QWordToDouble(Den);
  a := a * Hundred;
  Result := a / b;
end;

function MbPerSec(Done: QWord; Secs: Double): Double;
var a: Double;
begin
  a := QWordToDouble(Done) / Secs;
  Result := a / QWordToDouble(QWord(1024) * 1024);
end;

function MsToSecs(Ms: QWord): Double;
const Thousand: Double = 1000.0;
begin
  Result := QWordToDouble(Ms) / Thousand;
end;

end.
