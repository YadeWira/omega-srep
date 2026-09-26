unit Vmac;
{ VMAC / VHASH-128 -- el checksum de bloque por defecto.

  Port de la copia vendorizada `hashes/vmac/vmac.c` tal como la configura
  `Compression/SREP/hashes.cpp`: `VMAC_TAG_LEN 128`, `VMAC_KEY_LEN 256`,
  `VMAC_NHBYTES 4096`, `VMAC_PREFER_BIG_ENDIAN 0`, sin `VMAC_REQUIRE_FILL16`.
  Solo el `vhash()` de un tiro, que es lo que usa el encoder.

  POR QUE ESTE ES EL ARCHIVO DELICADO DEL PORT. `vmac.c` llega al producto de
  64x64 -> 128 y a la suma de 128 bits por asm especifico en x86_64 y por un
  fallback en C portable en todo lo demas -- y ese fallback lo miscompilaba GCC
  en -O2 sobre i386 hasta los parches locales de no-strict-aliasing (ver
  `docs/32bit-support.md`; fue un bug real que tardo en encontrarse porque solo
  aparecia en Windows de 32 bits y no bajo Wine). Aca `Mul64` y `Add128` son la
  operacion de 128 bits completa escrita con mitades de 32, asi que el
  resultado es independiente de la arquitectura por construccion, no por
  suerte. El harness lo diffea contra el C vendorizado en los dos anchos. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes, AES;

const
  VMAC_KEY_LEN_BYTES = 32;
  VMAC_TAG_LEN_BYTES = 16;

type
  TVmac = record
    NHKey:   array[0..513] of QWord;   { NHW + 2*(128/64 - 1) }
    PolyKey: array[0..3] of QWord;
    L3Key:   array[0..3] of QWord;
  end;

procedure VmacSetKey(const UserKey: TBytes; out V: TVmac);
function VmacCompute(const V: TVmac; const M: TBytes): TBytes;

implementation

const
  NHBYTES = 4096;
  NHW     = NHBYTES div 8;          { 512 }
  P64     = QWord($fffffffffffffeff);   { 2^64 - 257, primo }
  M62     = QWord($3fffffffffffffff);
  { OJO: la mascara de las claves poly NO es M62. Son constantes distintas y
    estan a tres lineas una de otra en el original (`vmac.c:62`); confundirlas
    da un vmac que deriva bien todas las claves, pasa AES, pasa L3Hash, y
    devuelve el digest equivocado para toda entrada. }
  MPOLY   = QWord($1fffffff1fffffff);
  M63     = QWord($7fffffffffffffff);
  M64     = QWord($ffffffffffffffff);

{ 64x64 -> 128 con mitades de 32. Todos los productos parciales entran en un
  QWord, asi que no hay desborde intermedio y el resultado no depende del
  ancho nativo de la maquina. }
procedure Mul64(a, b: QWord; out rh, rl: QWord); inline;
var ah, al, bh, bl, lo, mid1, mid2, t: QWord;
begin
  al := a and $FFFFFFFF;  ah := a shr 32;
  bl := b and $FFFFFFFF;  bh := b shr 32;
  lo   := al * bl;
  mid1 := ah * bl;
  mid2 := al * bh;
  t := (lo shr 32) + (mid1 and $FFFFFFFF) + (mid2 and $FFFFFFFF);
  rl := (lo and $FFFFFFFF) or (t shl 32);
  rh := (ah * bh) + (mid1 shr 32) + (mid2 shr 32) + (t shr 32);
end;

procedure Add128(var rh, rl: QWord; ih, il: QWord); inline;
var nl: QWord;
begin
  nl := rl + il;
  if nl < rl then rh := rh + ih + 1 else rh := rh + ih;
  rl := nl;
end;

function WordLE(const D: TBytes; Off: QWord): QWord; inline;
var i: LongInt;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or QWord(D[Off + QWord(i)]);
end;

function WordBE(const D: TBytes; Off: QWord): QWord; inline;
var i: LongInt;
begin
  Result := 0;
  for i := 0 to 7 do Result := (Result shl 8) or QWord(D[Off + QWord(i)]);
end;

procedure VmacSetKey(const UserKey: TBytes; out V: TVmac);
var
  K: TAesKey;
  blk, outb: TBytes;
  i: LongInt;
begin
  AesSetKey(UserKey, K);
  SetLength(blk, 16);

  { claves NH }
  FillChar(blk[0], 16, 0);  blk[0] := $80;
  i := 0;
  while i < 514 do
  begin
    AesEncryptBlock(K, blk, outb);
    V.NHKey[i]     := WordBE(outb, 0);
    V.NHKey[i + 1] := WordBE(outb, 8);
    blk[15] := Byte(blk[15] + 1);
    Inc(i, 2);
  end;

  { claves poly, enmascaradas a su modulo }
  FillChar(blk[0], 16, 0);  blk[0] := $C0;
  i := 0;
  while i < 4 do
  begin
    AesEncryptBlock(K, blk, outb);
    V.PolyKey[i]     := WordBE(outb, 0) and MPOLY;
    V.PolyKey[i + 1] := WordBE(outb, 8) and MPOLY;
    blk[15] := Byte(blk[15] + 1);
    Inc(i, 2);
  end;

  { claves L3, rechazando las que no caen por debajo del primo }
  FillChar(blk[0], 16, 0);  blk[0] := $E0;
  i := 0;
  while i < 4 do
  begin
    repeat
      AesEncryptBlock(K, blk, outb);
      V.L3Key[i]     := WordBE(outb, 0);
      V.L3Key[i + 1] := WordBE(outb, 8);
      blk[15] := Byte(blk[15] + 1);
    until (V.L3Key[i] < P64) and (V.L3Key[i + 1] < P64);
    Inc(i, 2);
  end;
end;

procedure NH16(const D: TBytes; ByteOff: QWord; const KP: array of QWord;
               KPOff, NW: LongInt; out rh, rl: QWord);
var i: LongInt; t1, t2, th, tl: QWord;
begin
  rh := 0; rl := 0;
  i := 0;
  while i < NW do
  begin
    t1 := WordLE(D, ByteOff + QWord(i) * 8) + KP[KPOff + i];
    t2 := WordLE(D, ByteOff + QWord(i + 1) * 8) + KP[KPOff + i + 1];
    Mul64(t1, t2, th, tl);
    Add128(rh, rl, th, tl);
    Inc(i, 2);
  end;
end;

procedure NH16_2(const D: TBytes; ByteOff: QWord; const KP: array of QWord;
                 KPOff, NW: LongInt; out rh, rl, rh2, rl2: QWord);
begin
  NH16(D, ByteOff, KP, KPOff, NW, rh, rl);
  NH16(D, ByteOff, KP, KPOff + 2, NW, rh2, rl2);
end;

procedure PolyStep(var ah, al: QWord; kh, kl, mh, ml: QWord);
var t1h, t1l, t2h, t2l, t3h, t3l, nah, nal: QWord;
begin
  Mul64(al, kh, t3h, t3l);
  Mul64(ah, kl, t2h, t2l);
  Mul64(ah, kh * 2, t1h, t1l);
  Mul64(al, kl, nah, nal);
  Add128(nah, nal, t1h, t1l);
  Add128(t2h, t2l, t3h, t3l);
  { El ADD128(t2h, ah, 0, t2l) del macro: `nah` es la mitad baja del par
    (t2h, nah), asi que esto pliega t2l adentro y acarrea a t2h. }
  Add128(t2h, nah, 0, t2l);
  t2h := t2h * 2 + (nah shr 63);
  nah := nah and M63;
  Add128(nah, nal, mh, ml);
  Add128(nah, nal, 0, t2h);
  ah := nah; al := nal;
end;

function L3Hash(p1, p2, k1, k2, len: QWord): QWord;
var t, rh, rl, shifted: QWord;
begin
  t := p1 shr 63;
  p1 := p1 and M63;
  Add128(p1, p2, len, t);

  t := 0;
  if p1 > M63 then t := t + 1;
  if (p1 = M63) and (p2 = M64) then t := t + 1;
  Add128(p1, p2, 0, t);
  p1 := p1 and M63;

  t := p1 + (p2 shr 32);
  t := t + (t shr 32);
  if DWord(t) > $fffffffe then t := t + 1;
  p1 := p1 + (t shr 32);
  p2 := p2 + (p1 shl 32);

  p1 := p1 + k1;  if p1 < k1 then p1 := p1 + 257;
  p2 := p2 + k2;  if p2 < k2 then p2 := p2 + 257;

  Mul64(p1, p2, rh, rl);
  t := rh shr 56;
  Add128(t, rl, 0, rh);
  shifted := rh shl 8;
  Add128(t, rl, 0, shifted);
  t := t + (t shl 8);
  rl := rl + t;   if rl < t then rl := rl + 257;
  if rl > P64 - 1 then rl := rl + 257;
  Result := rl;
end;

procedure NHTail(const V: TVmac; const M: TBytes; MOff, Remaining: QWord;
                 out rh, rl, rh2, rl2: QWord);
var whole, part, start: QWord; h, l, h2, l2: QWord; buf: TBytes;
    bi: LongInt;   { la cola nunca pasa de 15 bytes; QWord no vale como indice de `for` en i386 }
begin
  whole := Remaining div 16;
  if whole > 0 then
    NH16_2(M, MOff, V.NHKey, 0, LongInt(2 * whole), rh, rl, rh2, rl2)
  else begin rh := 0; rl := 0; rh2 := 0; rl2 := 0; end;

  part := Remaining mod 16;
  if part > 0 then
  begin
    start := MOff + whole * 16;
    SetLength(buf, 16);
    FillChar(buf[0], 16, 0);
    for bi := 0 to LongInt(part) - 1 do buf[bi] := M[start + QWord(bi)];
    NH16_2(buf, 0, V.NHKey, LongInt(2 * whole), 2, h, l, h2, l2);
    Add128(rh, rl, h, l);
    Add128(rh2, rl2, h2, l2);
  end;
end;

function VmacCompute(const V: TVmac; const M: TBytes): TBytes;
var
  pkh, pkl, pkh2, pkl2: QWord;
  ch, cl, ch2, cl2, rh, rl, rh2, rl2: QWord;
  mbytes, remaining, i, moff, len: QWord;
  tag, tagl: QWord;
  j: LongInt;
  done: Boolean;
begin
  pkh := V.PolyKey[0]; pkl := V.PolyKey[1];
  pkh2 := V.PolyKey[2]; pkl2 := V.PolyKey[3];

  mbytes := QWord(Length(M));
  remaining := mbytes mod NHBYTES;
  i := mbytes div NHBYTES;
  moff := 0;
  ch := 0; cl := 0; ch2 := 0; cl2 := 0;
  done := False;

  if i > 0 then
  begin
    { El primer bloque completo se absorbe en la clave, no se multiplica. }
    NH16_2(M, moff, V.NHKey, 0, NHW, rh, rl, rh2, rl2);
    ch2 := rh2 and M62; cl2 := rl2;  Add128(ch2, cl2, pkh2, pkl2);
    ch  := rh  and M62; cl  := rl;   Add128(ch,  cl,  pkh,  pkl);
    Inc(moff, NHBYTES);
    Dec(i);
  end
  else if remaining > 0 then
  begin
    NHTail(V, M, moff, remaining, rh, rl, rh2, rl2);
    ch2 := rh2 and M62; cl2 := rl2;  Add128(ch2, cl2, pkh2, pkl2);
    ch  := rh  and M62; cl  := rl;   Add128(ch,  cl,  pkh,  pkl);
    done := True;
  end
  else
  begin
    ch := pkh; cl := pkl; ch2 := pkh2; cl2 := pkl2;
    done := True;
  end;

  if not done then
  begin
    while i > 0 do
    begin
      NH16_2(M, moff, V.NHKey, 0, NHW, rh, rl, rh2, rl2);
      PolyStep(ch2, cl2, pkh2, pkl2, rh2 and M62, rl2);
      PolyStep(ch,  cl,  pkh,  pkl,  rh  and M62, rl);
      Inc(moff, NHBYTES);
      Dec(i);
    end;
    if remaining > 0 then
    begin
      NHTail(V, M, moff, remaining, rh, rl, rh2, rl2);
      PolyStep(ch2, cl2, pkh2, pkl2, rh2 and M62, rl2);
      PolyStep(ch,  cl,  pkh,  pkl,  rh  and M62, rl);
    end;
  end;

  len := remaining * 8;
  tagl := L3Hash(ch2, cl2, V.L3Key[2], V.L3Key[3], len);
  tag  := L3Hash(ch,  cl,  V.L3Key[0], V.L3Key[1], len);

  SetLength(Result, VMAC_TAG_LEN_BYTES);
  for j := 0 to 7 do Result[j]     := Byte((tag  shr (8 * j)) and $FF);
  for j := 0 to 7 do Result[8 + j] := Byte((tagl shr (8 * j)) and $FF);
end;

end.
