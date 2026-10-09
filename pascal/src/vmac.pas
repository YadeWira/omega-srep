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
{$POINTERMATH ON}
{$IFDEF CPUX86_64}{$ASMMODE INTEL}{$ENDIF}
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
  TVmacTag = array[0..VMAC_TAG_LEN_BYTES - 1] of Byte;

procedure VmacSetKey(const UserKey: TBytes; out V: TVmac);
function VmacCompute(const V: TVmac; const M: TBytes): TBytes;
{ Lo mismo sin copiar ni reservar: Len bytes desde P (P puede ser nil si
  Len = 0). Es lo que deberian usar los llamadores por bloque/chunk. }
procedure VmacTagOf(const V: TVmac; P: PByte; Len: QWord; out Tag: TVmacTag);
{ Que NH quedo compilado ('x86_64-asm' o 'pascal'); hashtool lo imprime para
  probar que el IFDEF tomo la rama que se cree. }
function VmacNhImpl: AnsiString;

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
  ancho nativo de la maquina. Las mitades son DWord y cada producto es
  QWord(DWord) * QWord(DWord) EXPLICITO: asi FPC en i386 emite un solo MUL de
  32x32 -> 64 en vez de llamar a fpc_mul_qword (medido en el .s de
  ppcross386), y en x86_64 es un IMUL de 64. Sin los casts, DWord * DWord se
  evalua con anchos distintos en 32 y 64 bits (ver docs, trampas). }
procedure Mul64(a, b: QWord; out rh, rl: QWord); inline;
var ah, al, bh, bl: DWord; lo, mid1, mid2, t: QWord;
begin
  al := DWord(a);  ah := DWord(a shr 32);
  bl := DWord(b);  bh := DWord(b shr 32);
  lo   := QWord(al) * QWord(bl);
  mid1 := QWord(ah) * QWord(bl);
  mid2 := QWord(al) * QWord(bh);
  t := (lo shr 32) + (mid1 and $FFFFFFFF) + (mid2 and $FFFFFFFF);
  rl := (lo and $FFFFFFFF) or (t shl 32);
  rh := QWord(ah) * QWord(bh) + (mid1 shr 32) + (mid2 shr 32) + (t shr 32);
end;

procedure Add128(var rh, rl: QWord; ih, il: QWord); inline;
var nl: QWord;
begin
  nl := rl + il;
  if nl < rl then rh := rh + ih + 1 else rh := rh + ih;
  rl := nl;
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

{ ------------------------------------------------------------------ NH --- }

{ El camino caliente. `nh_16_2` del C hashea el mismo tramo con dos claves
  desplazadas en 2 palabras (los dos carriles del tag de 128 bits); aca se
  hacen las dos en UNA pasada sobre los datos, que es lo mismo termino a
  termino: cada carril es una suma mod 2^128 de productos independientes, asi
  que intercalarlos no cambia ni un bit. P apunta a NW palabras de 64 bits
  little-endian (NW par, > 0) y K a la clave NH; se leen K[0..NW+1]. }

{$IFDEF CPUX86_64}
const VMAC_NH_IMPL = 'x86_64-asm';

type
  TNhCtx = packed record
    P, K: PQWord;            { 0, 8: apuntan al FINAL del tramo }
    N: Int64;                { 16: -NW, sube hasta 0 }
    rh, rl, rh2, rl2: QWord; { 24, 32, 40, 48 }
    sbx, ssi, sdi, s12, s13: QWord;  { 56..88: callee-saved de las dos ABI }
  end;

{ MUL de 64x64 -> 128 en hardware. rbx/rsi/rdi/r12/r13 los preserva el ABI
  de Win64 (y rbx/r12/r13 el de SysV), asi que se guardan y restauran a mano
  -- en el propio ctx, NO con push: en SysV una hoja puede tener sus locales
  en la red zone debajo de rsp, y un push los pisaria. El asm no toca la pila. }
procedure NhPair(P, K: PQWord; NW: LongInt; out rh, rl, rh2, rl2: QWord);
var ctx: TNhCtx; pc: ^TNhCtx;
begin
  ctx.P := P + NW;
  ctx.K := K + NW;
  ctx.N := -Int64(NW);
  pc := @ctx;
  asm
    mov   rax, pc
    mov   qword ptr [rax+56], rbx
    mov   qword ptr [rax+64], rsi
    mov   qword ptr [rax+72], rdi
    mov   qword ptr [rax+80], r12
    mov   qword ptr [rax+88], r13
    mov   r13, rax
    mov   r8,  qword ptr [rax]
    mov   r9,  qword ptr [rax+8]
    mov   rcx, qword ptr [rax+16]
    xor   r10, r10
    xor   r11, r11
    xor   rsi, rsi
    xor   rdi, rdi
  @loop:
    mov   rbx, qword ptr [r8+rcx*8]
    mov   r12, qword ptr [r8+rcx*8+8]
    mov   rax, rbx
    add   rax, qword ptr [r9+rcx*8]
    mov   rdx, r12
    add   rdx, qword ptr [r9+rcx*8+8]
    mul   rdx
    add   r11, rax
    adc   r10, rdx
    mov   rax, rbx
    add   rax, qword ptr [r9+rcx*8+16]
    mov   rdx, r12
    add   rdx, qword ptr [r9+rcx*8+24]
    mul   rdx
    add   rdi, rax
    adc   rsi, rdx
    add   rcx, 2
    jnz   @loop
    mov   rax, r13
    mov   qword ptr [rax+24], r10
    mov   qword ptr [rax+32], r11
    mov   qword ptr [rax+40], rsi
    mov   qword ptr [rax+48], rdi
    mov   rbx, qword ptr [rax+56]
    mov   rsi, qword ptr [rax+64]
    mov   rdi, qword ptr [rax+72]
    mov   r12, qword ptr [rax+80]
    mov   r13, qword ptr [rax+88]
  end ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'];
  rh := ctx.rh; rl := ctx.rl; rh2 := ctx.rh2; rl2 := ctx.rl2;
end;
{$ELSE}
const VMAC_NH_IMPL = 'pascal';

procedure NhPair(P, K: PQWord; NW: LongInt; out rh, rl, rh2, rl2: QWord);
var i: LongInt; m0, m1, th, tl, ah, al, ah2, al2: QWord;
begin
  ah := 0; al := 0; ah2 := 0; al2 := 0;
  i := 0;
  while i < NW do
  begin
    m0 := LEtoN(P[i]);
    m1 := LEtoN(P[i + 1]);
    Mul64(m0 + K[i], m1 + K[i + 1], th, tl);
    Add128(ah, al, th, tl);
    Mul64(m0 + K[i + 2], m1 + K[i + 3], th, tl);
    Add128(ah2, al2, th, tl);
    Inc(i, 2);
  end;
  rh := ah; rl := al; rh2 := ah2; rl2 := al2;
end;
{$ENDIF}

procedure PolyStep(var ah, al: QWord; kh, kl, mh, ml: QWord);
var t1h, t1l, t2h, t2l, t3h, t3l, nah, nal: QWord;
begin
  Mul64(al, kh, t3h, t3l);
  Mul64(ah, kl, t2h, t2l);
  Mul64(ah, kh shl 1, t1h, t1l);   { *2 mod 2^64, sin fpc_mul_qword en i386 }
  Mul64(al, kl, nah, nal);
  Add128(nah, nal, t1h, t1l);
  Add128(t2h, t2l, t3h, t3l);
  { El ADD128(t2h, ah, 0, t2l) del macro: `nah` es la mitad baja del par
    (t2h, nah), asi que esto pliega t2l adentro y acarrea a t2h. }
  Add128(t2h, nah, 0, t2l);
  t2h := (t2h shl 1) + (nah shr 63);
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

{ El resto de un mensaje que no llena un bloque de 4096: las palabras de 16
  bytes completas directo, y la ultima parcial rellenada con ceros en un
  buffer de pila (el C la copia igual a un buffer alineado). }
procedure NHTail(const V: TVmac; P: PByte; Remaining: QWord;
                 out rh, rl, rh2, rl2: QWord);
var whole, part: QWord; h, l, h2, l2: QWord; buf: array[0..1] of QWord;
begin
  whole := Remaining div 16;
  if whole > 0 then
    NhPair(PQWord(P), @V.NHKey[0], LongInt(2 * whole), rh, rl, rh2, rl2)
  else begin rh := 0; rl := 0; rh2 := 0; rl2 := 0; end;

  part := Remaining mod 16;
  if part > 0 then
  begin
    buf[0] := 0; buf[1] := 0;
    Move(P[whole * 16], buf[0], part);
    NhPair(@buf[0], @V.NHKey[2 * whole], 2, h, l, h2, l2);
    Add128(rh, rl, h, l);
    Add128(rh2, rl2, h2, l2);
  end;
end;

procedure VmacTagOf(const V: TVmac; P: PByte; Len: QWord; out Tag: TVmacTag);
var
  pkh, pkl, pkh2, pkl2: QWord;
  ch, cl, ch2, cl2, rh, rl, rh2, rl2: QWord;
  remaining, i, len8: QWord;
  tag64, tagl: QWord;
  j: LongInt;
  done: Boolean;
begin
  pkh := V.PolyKey[0]; pkl := V.PolyKey[1];
  pkh2 := V.PolyKey[2]; pkl2 := V.PolyKey[3];

  remaining := Len mod NHBYTES;
  i := Len div NHBYTES;
  ch := 0; cl := 0; ch2 := 0; cl2 := 0;
  done := False;

  if i > 0 then
  begin
    { El primer bloque completo se absorbe en la clave, no se multiplica. }
    NhPair(PQWord(P), @V.NHKey[0], NHW, rh, rl, rh2, rl2);
    ch2 := rh2 and M62; cl2 := rl2;  Add128(ch2, cl2, pkh2, pkl2);
    ch  := rh  and M62; cl  := rl;   Add128(ch,  cl,  pkh,  pkl);
    Inc(P, NHBYTES);
    Dec(i);
  end
  else if remaining > 0 then
  begin
    NHTail(V, P, remaining, rh, rl, rh2, rl2);
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
      NhPair(PQWord(P), @V.NHKey[0], NHW, rh, rl, rh2, rl2);
      PolyStep(ch2, cl2, pkh2, pkl2, rh2 and M62, rl2);
      PolyStep(ch,  cl,  pkh,  pkl,  rh  and M62, rl);
      Inc(P, NHBYTES);
      Dec(i);
    end;
    if remaining > 0 then
    begin
      NHTail(V, P, remaining, rh, rl, rh2, rl2);
      PolyStep(ch2, cl2, pkh2, pkl2, rh2 and M62, rl2);
      PolyStep(ch,  cl,  pkh,  pkl,  rh  and M62, rl);
    end;
  end;

  len8 := remaining * 8;
  tagl  := L3Hash(ch2, cl2, V.L3Key[2], V.L3Key[3], len8);
  tag64 := L3Hash(ch,  cl,  V.L3Key[0], V.L3Key[1], len8);

  for j := 0 to 7 do Tag[j]     := Byte((tag64 shr (8 * j)) and $FF);
  for j := 0 to 7 do Tag[8 + j] := Byte((tagl  shr (8 * j)) and $FF);
end;

function VmacCompute(const V: TVmac; const M: TBytes): TBytes;
var t: TVmacTag;
begin
  Result := nil;
  VmacTagOf(V, PByte(M), QWord(Length(M)), t);
  SetLength(Result, VMAC_TAG_LEN_BYTES);
  Move(t[0], Result[0], VMAC_TAG_LEN_BYTES);
end;

function VmacNhImpl: AnsiString;
begin
  Result := VMAC_NH_IMPL;
end;

end.
