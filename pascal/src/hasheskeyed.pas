unit HashesKeyed;
{ Digests con clave: siphash (y vmac vive aparte, en su propia unidad, porque
  arrastra AES).

  siphash es SipHash-2-4 con tag de 8 bytes y clave de 16. Portado contra
  `bin/hash_test`, igual que el resto. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes;

const
  SIPHASH_KEY_LEN = 16;
  SIPHASH_TAG_LEN = 8;

function SipHash(const Key, M: TBytes): TBytes;

implementation

function RotL64(x: QWord; n: Byte): QWord; inline;
begin
  Result := (x shl n) or (x shr (64 - n));
end;

function LE64(const B: TBytes; At: QWord): QWord; inline;
var i: LongInt;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or QWord(B[At + QWord(i)]);
end;

type
  TSipState = array[0..3] of QWord;

procedure SipRound(var v: TSipState); inline;
begin
  v[0] := v[0] + v[1];  v[2] := v[2] + v[3];
  v[1] := RotL64(v[1], 13);  v[3] := RotL64(v[3], 16);
  v[1] := v[1] xor v[0];  v[3] := v[3] xor v[2];
  v[0] := RotL64(v[0], 32);
  v[2] := v[2] + v[1];  v[0] := v[0] + v[3];
  v[1] := RotL64(v[1], 17);  v[3] := RotL64(v[3], 21);
  v[1] := v[1] xor v[2];  v[3] := v[3] xor v[0];
  v[2] := RotL64(v[2], 32);
end;

function SipHash(const Key, M: TBytes): TBytes;
var
  v: TSipState;
  k0, k1, mi, last7, outv: QWord;
  len, blocks, i: QWord;
  j: LongInt;
begin
  if QWord(Length(Key)) <> SIPHASH_KEY_LEN then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  k0 := LE64(Key, 0);
  k1 := LE64(Key, 8);
  v[0] := k0 xor QWord($736f6d6570736575);
  v[1] := k1 xor QWord($646f72616e646f6d);
  v[2] := k0 xor QWord($6c7967656e657261);
  v[3] := k1 xor QWord($7465646279746573);

  len := QWord(Length(M));
  { El byte alto del ultimo word es el largo modulo 256. }
  last7 := (len and $FF) shl 56;
  blocks := len and (not QWord(7));

  i := 0;
  while i < blocks do
  begin
    mi := LE64(M, i);
    v[3] := v[3] xor mi;
    SipRound(v); SipRound(v);
    v[0] := v[0] xor mi;
    Inc(i, 8);
  end;

  { La cola (0..7 bytes) entra por los bytes bajos de ese mismo word. }
  j := 0;
  while blocks + QWord(j) < len do
  begin
    last7 := last7 or (QWord(M[blocks + QWord(j)]) shl (8 * j));
    Inc(j);
  end;

  v[3] := v[3] xor last7;
  SipRound(v); SipRound(v);
  v[0] := v[0] xor last7;
  v[2] := v[2] xor $FF;
  SipRound(v); SipRound(v); SipRound(v); SipRound(v);

  outv := v[0] xor v[1] xor v[2] xor v[3];
  SetLength(Result, SIPHASH_TAG_LEN);
  for j := 0 to 7 do Result[j] := Byte((outv shr (8 * j)) and $FF);
end;

end.
