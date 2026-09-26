unit Hashes;
{ Digests sin clave: md5, sha1, sha512.

  Se portan contra `tests/hash_test.cpp`, que calcula el digest con el MISMO
  codigo que el encoder guarda en cada bloque -- no contra vectores publicados.
  La diferencia importa: las copias de LibTomCrypt que este repo tiene
  vendorizadas llevan parches locales, asi que un vector de la RFC podria pasar
  y el archivo salir distinto igual. (Es el mismo criterio que uso el port a
  Rust; ver `crates/osrep-core/src/hashes.rs`.)

  Todos los anchos son explicitos: ni `Integer` ni `SizeInt` aparecen en el
  calculo. Ver `src/widths.pas` para por que. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}   { el desborde de DWord es parte de los algoritmos }
{$OVERFLOWCHECKS OFF}
interface

uses Widths;

type
  TBytes = array of Byte;

function MD5(const Data: TBytes): TBytes;
function SHA1(const Data: TBytes): TBytes;
function SHA512(const Data: TBytes): TBytes;
function ToHex(const B: TBytes): AnsiString;
function FromHex(const S: AnsiString): TBytes;

implementation

function ToHex(const B: TBytes): AnsiString;
const HEX: array[0..15] of Char = '0123456789abcdef';
var i: LongInt;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := HEX[B[i] shr 4];
    Result[i * 2 + 2] := HEX[B[i] and $0F];
  end;
end;

function FromHex(const S: AnsiString): TBytes;
var i, n: LongInt; hi, lo: Byte;
  function Nib(c: Char): Byte;
  begin
    case c of
      '0'..'9': Nib := Byte(Ord(c) - Ord('0'));
      'a'..'f': Nib := Byte(Ord(c) - Ord('a') + 10);
      'A'..'F': Nib := Byte(Ord(c) - Ord('A') + 10);
    else Nib := 255;
    end;
  end;
begin
  if (S = 'none') or (S = '') then begin SetLength(Result, 0); Exit; end;
  n := Length(S) div 2;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    hi := Nib(S[i * 2 + 1]); lo := Nib(S[i * 2 + 2]);
    if (hi = 255) or (lo = 255) then begin SetLength(Result, 0); Exit; end;
    Result[i] := Byte(hi shl 4) or lo;
  end;
end;

{ ---------------------------------------------------------------- md5 --- }

const
  MD5_S: array[0..63] of Byte = (
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21);
  MD5_K: array[0..63] of DWord = (
    $d76aa478,$e8c7b756,$242070db,$c1bdceee,$f57c0faf,$4787c62a,$a8304613,$fd469501,
    $698098d8,$8b44f7af,$ffff5bb1,$895cd7be,$6b901122,$fd987193,$a679438e,$49b40821,
    $f61e2562,$c040b340,$265e5a51,$e9b6c7aa,$d62f105d,$02441453,$d8a1e681,$e7d3fbc8,
    $21e1cde6,$c33707d6,$f4d50d87,$455a14ed,$a9e3e905,$fcefa3f8,$676f02d9,$8d2a4c8a,
    $fffa3942,$8771f681,$6d9d6122,$fde5380c,$a4beea44,$4bdecfa9,$f6bb4b60,$bebfbc70,
    $289b7ec6,$eaa127fa,$d4ef3085,$04881d05,$d9d4d039,$e6db99e5,$1fa27cf8,$c4ac5665,
    $f4292244,$432aff97,$ab9423a7,$fc93a039,$655b59c3,$8f0ccc92,$ffeff47d,$85845dd1,
    $6fa87e4f,$fe2ce6e0,$a3014314,$4e0811a1,$f7537e82,$bd3af235,$2ad7d2bb,$eb86d391);

function RotL32(x: DWord; n: Byte): DWord; inline;
begin
  Result := (x shl n) or (x shr (32 - n));
end;

function MD5(const Data: TBytes): TBytes;
var
  h: array[0..3] of DWord;
  msg: TBytes;
  bitlen: QWord;
  i, chunk: QWord;
  bi: LongInt;
  m: array[0..15] of DWord;
  a, b, c, d, f, tmp: DWord;
  g, j: LongInt;
  padlen: QWord;
begin
  h[0] := $67452301; h[1] := $efcdab89; h[2] := $98badcfe; h[3] := $10325476;

  bitlen := QWord(Length(Data)) * 8;
  { Relleno: 0x80, ceros, y el largo en bits (LE), hasta un multiplo de 64.
    El +9 cuenta el 0x80 *y* los 8 del largo; olvidarse del 0x80 da un
    resultado correcto en todos los tamanos MENOS los que caen justo en el
    borde -- una entrada de 56 bytes pasaba a un solo bloque en vez de dos.
    Lo encontro la matriz de tamanos del harness (55, 56, 63, 64, 65), no una
    lectura del codigo. }
  padlen := (64 - ((QWord(Length(Data)) + 9) mod 64)) mod 64;
  SetLength(msg, QWord(Length(Data)) + 1 + padlen + 8);
  if Length(Data) > 0 then Move(Data[0], msg[0], Length(Data));
  msg[Length(Data)] := $80;
  { FillChar en vez de un `for`: los limites son QWord y en i386 FPC no acepta
    un QWord como variable de control. Ademas dice mejor lo que hace. }
  if QWord(Length(msg)) > QWord(Length(Data)) + 9 then
    FillChar(msg[QWord(Length(Data)) + 1], QWord(Length(msg)) - QWord(Length(Data)) - 9, 0);
  for bi := 0 to 7 do msg[QWord(Length(msg)) - 8 + QWord(bi)] := Byte((bitlen shr (8 * bi)) and $FF);

  chunk := 0;
  while chunk < QWord(Length(msg)) do
  begin
    for j := 0 to 15 do
      m[j] := DWord(msg[chunk + QWord(j) * 4]) or
              (DWord(msg[chunk + QWord(j) * 4 + 1]) shl 8) or
              (DWord(msg[chunk + QWord(j) * 4 + 2]) shl 16) or
              (DWord(msg[chunk + QWord(j) * 4 + 3]) shl 24);
    a := h[0]; b := h[1]; c := h[2]; d := h[3];
    for j := 0 to 63 do
    begin
      if j < 16 then      begin f := (b and c) or ((not b) and d); g := j; end
      else if j < 32 then begin f := (d and b) or ((not d) and c); g := (5 * j + 1) mod 16; end
      else if j < 48 then begin f := b xor c xor d;                g := (3 * j + 5) mod 16; end
      else                begin f := c xor (b or (not d));         g := (7 * j) mod 16; end;
      tmp := d; d := c; c := b;
      b := b + RotL32(a + f + MD5_K[j] + m[g], MD5_S[j]);
      a := tmp;
    end;
    h[0] := h[0] + a; h[1] := h[1] + b; h[2] := h[2] + c; h[3] := h[3] + d;
    Inc(chunk, 64);
  end;

  SetLength(Result, 16);
  for j := 0 to 3 do
  begin
    Result[j * 4]     := Byte(h[j] and $FF);
    Result[j * 4 + 1] := Byte((h[j] shr 8) and $FF);
    Result[j * 4 + 2] := Byte((h[j] shr 16) and $FF);
    Result[j * 4 + 3] := Byte((h[j] shr 24) and $FF);
  end;
end;


{ --------------------------------------------------------------- sha1 --- }

{ Mismo relleno que md5 salvo que el largo va BIG-endian. Es el unico cambio y
  es facil de pasar por alto: con el endianness equivocado los dos primeros
  bloques dan igual y solo cambia el ultimo. }
function SHA1(const Data: TBytes): TBytes;
var
  h: array[0..4] of DWord;
  msg: TBytes;
  bitlen: QWord;
  i, chunk, padlen: QWord;
  bi: LongInt;
  w: array[0..79] of DWord;
  a, b, c, d, e, f, k, tmp: DWord;
  j: LongInt;
begin
  h[0] := $67452301; h[1] := $EFCDAB89; h[2] := $98BADCFE;
  h[3] := $10325476; h[4] := $C3D2E1F0;

  bitlen := QWord(Length(Data)) * 8;
  padlen := (64 - ((QWord(Length(Data)) + 9) mod 64)) mod 64;
  SetLength(msg, QWord(Length(Data)) + 1 + padlen + 8);
  if Length(Data) > 0 then Move(Data[0], msg[0], Length(Data));
  msg[Length(Data)] := $80;
  { FillChar en vez de un `for`: los limites son QWord y en i386 FPC no acepta
    un QWord como variable de control. Ademas dice mejor lo que hace. }
  if QWord(Length(msg)) > QWord(Length(Data)) + 9 then
    FillChar(msg[QWord(Length(Data)) + 1], QWord(Length(msg)) - QWord(Length(Data)) - 9, 0);
  for bi := 0 to 7 do
    msg[QWord(Length(msg)) - 1 - QWord(bi)] := Byte((bitlen shr (8 * bi)) and $FF);

  chunk := 0;
  while chunk < QWord(Length(msg)) do
  begin
    for j := 0 to 15 do
      w[j] := (DWord(msg[chunk + QWord(j) * 4]) shl 24) or
              (DWord(msg[chunk + QWord(j) * 4 + 1]) shl 16) or
              (DWord(msg[chunk + QWord(j) * 4 + 2]) shl 8) or
               DWord(msg[chunk + QWord(j) * 4 + 3]);
    for j := 16 to 79 do
      w[j] := RotL32(w[j-3] xor w[j-8] xor w[j-14] xor w[j-16], 1);
    a := h[0]; b := h[1]; c := h[2]; d := h[3]; e := h[4];
    for j := 0 to 79 do
    begin
      if j < 20 then      begin f := (b and c) or ((not b) and d); k := $5A827999; end
      else if j < 40 then begin f := b xor c xor d;                k := $6ED9EBA1; end
      else if j < 60 then begin f := (b and c) or (b and d) or (c and d); k := $8F1BBCDC; end
      else                begin f := b xor c xor d;                k := $CA62C1D6; end;
      tmp := RotL32(a, 5) + f + e + k + w[j];
      e := d; d := c; c := RotL32(b, 30); b := a; a := tmp;
    end;
    h[0] := h[0] + a; h[1] := h[1] + b; h[2] := h[2] + c;
    h[3] := h[3] + d; h[4] := h[4] + e;
    Inc(chunk, 64);
  end;

  SetLength(Result, 20);
  for j := 0 to 4 do
  begin
    Result[j * 4]     := Byte((h[j] shr 24) and $FF);
    Result[j * 4 + 1] := Byte((h[j] shr 16) and $FF);
    Result[j * 4 + 2] := Byte((h[j] shr 8) and $FF);
    Result[j * 4 + 3] := Byte(h[j] and $FF);
  end;
end;

{ ------------------------------------------------------------- sha512 --- }

const
  SHA512_K: array[0..79] of QWord = (
    QWord($428a2f98d728ae22),QWord($7137449123ef65cd),QWord($b5c0fbcfec4d3b2f),QWord($e9b5dba58189dbbc),
    QWord($3956c25bf348b538),QWord($59f111f1b605d019),QWord($923f82a4af194f9b),QWord($ab1c5ed5da6d8118),
    QWord($d807aa98a3030242),QWord($12835b0145706fbe),QWord($243185be4ee4b28c),QWord($550c7dc3d5ffb4e2),
    QWord($72be5d74f27b896f),QWord($80deb1fe3b1696b1),QWord($9bdc06a725c71235),QWord($c19bf174cf692694),
    QWord($e49b69c19ef14ad2),QWord($efbe4786384f25e3),QWord($0fc19dc68b8cd5b5),QWord($240ca1cc77ac9c65),
    QWord($2de92c6f592b0275),QWord($4a7484aa6ea6e483),QWord($5cb0a9dcbd41fbd4),QWord($76f988da831153b5),
    QWord($983e5152ee66dfab),QWord($a831c66d2db43210),QWord($b00327c898fb213f),QWord($bf597fc7beef0ee4),
    QWord($c6e00bf33da88fc2),QWord($d5a79147930aa725),QWord($06ca6351e003826f),QWord($142929670a0e6e70),
    QWord($27b70a8546d22ffc),QWord($2e1b21385c26c926),QWord($4d2c6dfc5ac42aed),QWord($53380d139d95b3df),
    QWord($650a73548baf63de),QWord($766a0abb3c77b2a8),QWord($81c2c92e47edaee6),QWord($92722c851482353b),
    QWord($a2bfe8a14cf10364),QWord($a81a664bbc423001),QWord($c24b8b70d0f89791),QWord($c76c51a30654be30),
    QWord($d192e819d6ef5218),QWord($d69906245565a910),QWord($f40e35855771202a),QWord($106aa07032bbd1b8),
    QWord($19a4c116b8d2d0c8),QWord($1e376c085141ab53),QWord($2748774cdf8eeb99),QWord($34b0bcb5e19b48a8),
    QWord($391c0cb3c5c95a63),QWord($4ed8aa4ae3418acb),QWord($5b9cca4f7763e373),QWord($682e6ff3d6b2b8a3),
    QWord($748f82ee5defb2fc),QWord($78a5636f43172f60),QWord($84c87814a1f0ab72),QWord($8cc702081a6439ec),
    QWord($90befffa23631e28),QWord($a4506cebde82bde9),QWord($bef9a3f7b2c67915),QWord($c67178f2e372532b),
    QWord($ca273eceea26619c),QWord($d186b8c721c0c207),QWord($eada7dd6cde0eb1e),QWord($f57d4f7fee6ed178),
    QWord($06f067aa72176fba),QWord($0a637dc5a2c898a6),QWord($113f9804bef90dae),QWord($1b710b35131c471b),
    QWord($28db77f523047d84),QWord($32caab7b40c72493),QWord($3c9ebe0a15c9bebc),QWord($431d67c49c100d4c),
    QWord($4cc5d4becb3e42b6),QWord($597f299cfc657e2a),QWord($5fcb6fab3ad6faec),QWord($6c44198c4a475817));

function RotR64(x: QWord; n: Byte): QWord; inline;
begin
  Result := (x shr n) or (x shl (64 - n));
end;

{ Bloques de 128 bytes y campo de largo de 16, no de 8. Reusar la aritmetica
  de sha1 aca da un digest plausible y equivocado. }
function SHA512(const Data: TBytes): TBytes;
var
  h: array[0..7] of QWord;
  msg: TBytes;
  bitlen: QWord;
  i, chunk, padlen: QWord;
  { Indices chicos aparte: en i386 FPC no acepta un QWord como variable de
    control de un `for`, y ademas no hace falta -- ninguno pasa de 79. }
  bi: LongInt;
  w: array[0..79] of QWord;
  a, b, c, d, e, f, g, hh, s0, s1, ch, maj, t1, t2: QWord;
  j: LongInt;
begin
  h[0] := QWord($6a09e667f3bcc908); h[1] := QWord($bb67ae8584caa73b);
  h[2] := QWord($3c6ef372fe94f82b); h[3] := QWord($a54ff53a5f1d36f1);
  h[4] := QWord($510e527fade682d1); h[5] := QWord($9b05688c2b3e6c1f);
  h[6] := QWord($1f83d9abfb41bd6b); h[7] := QWord($5be0cd19137e2179);

  bitlen := QWord(Length(Data)) * 8;
  padlen := (128 - ((QWord(Length(Data)) + 17) mod 128)) mod 128;
  SetLength(msg, QWord(Length(Data)) + 1 + padlen + 16);
  if Length(Data) > 0 then Move(Data[0], msg[0], Length(Data));
  msg[Length(Data)] := $80;
  if QWord(Length(msg)) > QWord(Length(Data)) + 17 then
    FillChar(msg[QWord(Length(Data)) + 1], QWord(Length(msg)) - QWord(Length(Data)) - 17, 0);
  for bi := 0 to 15 do msg[QWord(Length(msg)) - 16 + QWord(bi)] := 0;
  for bi := 0 to 7 do
    msg[QWord(Length(msg)) - 1 - QWord(bi)] := Byte((bitlen shr (8 * bi)) and $FF);

  chunk := 0;
  while chunk < QWord(Length(msg)) do
  begin
    for j := 0 to 15 do
    begin
      w[j] := 0;
      for bi := 0 to 7 do
        w[j] := (w[j] shl 8) or QWord(msg[chunk + QWord(j) * 8 + QWord(bi)]);
    end;
    for j := 16 to 79 do
    begin
      s0 := RotR64(w[j-15], 1) xor RotR64(w[j-15], 8) xor (w[j-15] shr 7);
      s1 := RotR64(w[j-2], 19) xor RotR64(w[j-2], 61) xor (w[j-2] shr 6);
      w[j] := w[j-16] + s0 + w[j-7] + s1;
    end;
    a := h[0]; b := h[1]; c := h[2]; d := h[3];
    e := h[4]; f := h[5]; g := h[6]; hh := h[7];
    for j := 0 to 79 do
    begin
      s1 := RotR64(e, 14) xor RotR64(e, 18) xor RotR64(e, 41);
      ch := (e and f) xor ((not e) and g);
      t1 := hh + s1 + ch + SHA512_K[j] + w[j];
      s0 := RotR64(a, 28) xor RotR64(a, 34) xor RotR64(a, 39);
      maj := (a and b) xor (a and c) xor (b and c);
      t2 := s0 + maj;
      hh := g; g := f; f := e; e := d + t1;
      d := c; c := b; b := a; a := t1 + t2;
    end;
    h[0] := h[0] + a; h[1] := h[1] + b; h[2] := h[2] + c; h[3] := h[3] + d;
    h[4] := h[4] + e; h[5] := h[5] + f; h[6] := h[6] + g; h[7] := h[7] + hh;
    Inc(chunk, 128);
  end;

  SetLength(Result, 64);
  for j := 0 to 7 do
    for bi := 0 to 7 do
      Result[j * 8 + bi] := Byte((h[j] shr (8 * (7 - bi))) and $FF);
end;

end.
