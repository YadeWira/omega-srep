unit AES;
{ AES-256, solo cifrado de bloque -- la primitiva sobre la que se construye vmac.

  Es el build `LTC_RIJNDAEL` + `ENCRYPT_ONLY` de la copia vendorizada de
  LibTomCrypt (`Compression/_Encryption/ciphers/aes/`). Asi llega el C++ a AES:
  `hashes.cpp` define `VMAC_USE_LIB_TOM_CRYPT`, y `vmac.c` llama a
  `aes_enc_setup(key, 32, 0, skey)` + `aes_enc_ecb_encrypt(pt, ct, skey)` con
  `VMAC_KEY_LEN == 256`. Solo ese camino: sin descifrado, sin claves de
  128/192 bits, sin modos.

  Las tablas se DERIVAN en vez de transcribir las 1280 constantes de
  `aes_tab.c` -- el mismo criterio que uso el port a Rust. Transcribir a mano
  1280 numeros es un error esperando a ocurrir, y la derivacion es justamente
  lo que esas tablas codifican. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes;

const
  AES256_KEY_LEN  = 32;
  AES_BLOCK_SIZE  = 16;

type
  TAesKey = record
    RK: array[0..59] of DWord;   { 4 * (14 + 1) palabras de subclave }
    Rounds: LongInt;
  end;

procedure AesSetKey(const Key: TBytes; out K: TAesKey);
procedure AesEncryptBlock(const K: TAesKey; const InB: TBytes; var OutB: TBytes);
function SBoxBytes: TBytes;   { diagnostico: los primeros 8 del S-box }

implementation

var
  SBox: array[0..255] of Byte;
  Te0, Te1, Te2, Te3: array[0..255] of DWord;
  TablesReady: Boolean = False;

function XTime(x: Byte): Byte; inline;
begin
  if (x and $80) <> 0 then Result := Byte((x shl 1) xor $1B)
  else Result := Byte(x shl 1);
end;

function GMul(a, b: Byte): Byte;
var r: Byte; i: LongInt;
begin
  r := 0;
  for i := 0 to 7 do
  begin
    if (b and 1) <> 0 then r := r xor a;
    a := XTime(a);
    b := b shr 1;
  end;
  Result := r;
end;

{ Inverso multiplicativo en GF(2^8) por fuerza bruta: 256 x 256 se calcula una
  sola vez al arrancar y evita depender de tablas exp/log que habria que
  verificar aparte. }
function GInv(a: Byte): Byte;
var i: LongInt;
begin
  Result := 0;
  if a = 0 then Exit;
  for i := 1 to 255 do
    if GMul(a, Byte(i)) = 1 then begin Result := Byte(i); Exit; end;
end;

function RotL32(x: DWord; n: Byte): DWord; inline;
begin
  Result := (x shl n) or (x shr (32 - n));
end;

procedure BuildTables;
var i: LongInt; s, inv: Byte; t: DWord;
begin
  if TablesReady then Exit;
  for i := 0 to 255 do
  begin
    inv := GInv(Byte(i));
    { transformacion afin del S-box }
    s := inv xor Byte((inv shl 1) or (inv shr 7))
             xor Byte((inv shl 2) or (inv shr 6))
             xor Byte((inv shl 3) or (inv shr 5))
             xor Byte((inv shl 4) or (inv shr 4))
             xor $63;
    SBox[i] := s;
  end;
  for i := 0 to 255 do
  begin
    s := SBox[i];
    { Te0[x] = S[x].[02,01,01,03] }
    t := (DWord(GMul(s, 2)) shl 24) or (DWord(s) shl 16) or
         (DWord(s) shl 8) or DWord(GMul(s, 3));
    Te0[i] := t;
    Te1[i] := RotL32(t, 24);   { rotaciones de byte de Te0 }
    Te2[i] := RotL32(t, 16);
    Te3[i] := RotL32(t, 8);
  end;
  TablesReady := True;
end;

function BE32(const B: TBytes; At: LongInt): DWord; inline;
begin
  Result := (DWord(B[At]) shl 24) or (DWord(B[At+1]) shl 16) or
            (DWord(B[At+2]) shl 8) or DWord(B[At+3]);
end;

const
  RCON: array[0..9] of DWord = ($01000000, $02000000, $04000000, $08000000,
    $10000000, $20000000, $40000000, $80000000, $1B000000, $36000000);

function SubWord(w: DWord): DWord; inline;
begin
  Result := (DWord(SBox[(w shr 24) and $FF]) shl 24) or
            (DWord(SBox[(w shr 16) and $FF]) shl 16) or
            (DWord(SBox[(w shr 8) and $FF]) shl 8) or
             DWord(SBox[w and $FF]);
end;

procedure AesSetKey(const Key: TBytes; out K: TAesKey);
var i, nk: LongInt; temp: DWord;
begin
  BuildTables;
  nk := 8;              { 256 bits / 32 }
  K.Rounds := 14;
  for i := 0 to nk - 1 do K.RK[i] := BE32(Key, i * 4);
  for i := nk to 4 * (K.Rounds + 1) - 1 do
  begin
    temp := K.RK[i - 1];
    if (i mod nk) = 0 then
      { RotWord rota la palabra un BYTE a la izquierda: a0a1a2a3 -> a1a2a3a0,
        que en 32 bits big-endian es una rotacion izquierda de 8, no de 24. }
      temp := SubWord(RotL32(temp, 8)) xor RCON[(i div nk) - 1]
    else if (i mod nk) = 4 then
      temp := SubWord(temp);
    K.RK[i] := K.RK[i - nk] xor temp;
  end;
end;

procedure AesEncryptBlock(const K: TAesKey; const InB: TBytes; var OutB: TBytes);
var
  s0, s1, s2, s3, t0, t1, t2, t3: DWord;
  r, rk: LongInt;
begin
  s0 := BE32(InB, 0) xor K.RK[0];
  s1 := BE32(InB, 4) xor K.RK[1];
  s2 := BE32(InB, 8) xor K.RK[2];
  s3 := BE32(InB, 12) xor K.RK[3];

  rk := 4;
  for r := 1 to K.Rounds - 1 do
  begin
    t0 := Te0[(s0 shr 24) and $FF] xor Te1[(s1 shr 16) and $FF] xor
          Te2[(s2 shr 8) and $FF] xor Te3[s3 and $FF] xor K.RK[rk];
    t1 := Te0[(s1 shr 24) and $FF] xor Te1[(s2 shr 16) and $FF] xor
          Te2[(s3 shr 8) and $FF] xor Te3[s0 and $FF] xor K.RK[rk+1];
    t2 := Te0[(s2 shr 24) and $FF] xor Te1[(s3 shr 16) and $FF] xor
          Te2[(s0 shr 8) and $FF] xor Te3[s1 and $FF] xor K.RK[rk+2];
    t3 := Te0[(s3 shr 24) and $FF] xor Te1[(s0 shr 16) and $FF] xor
          Te2[(s1 shr 8) and $FF] xor Te3[s2 and $FF] xor K.RK[rk+3];
    s0 := t0; s1 := t1; s2 := t2; s3 := t3;
    Inc(rk, 4);
  end;

  { Ronda final: sin MixColumns, solo SubBytes + ShiftRows. }
  t0 := (DWord(SBox[(s0 shr 24) and $FF]) shl 24) or
        (DWord(SBox[(s1 shr 16) and $FF]) shl 16) or
        (DWord(SBox[(s2 shr 8) and $FF]) shl 8) or
         DWord(SBox[s3 and $FF]);
  t1 := (DWord(SBox[(s1 shr 24) and $FF]) shl 24) or
        (DWord(SBox[(s2 shr 16) and $FF]) shl 16) or
        (DWord(SBox[(s3 shr 8) and $FF]) shl 8) or
         DWord(SBox[s0 and $FF]);
  t2 := (DWord(SBox[(s2 shr 24) and $FF]) shl 24) or
        (DWord(SBox[(s3 shr 16) and $FF]) shl 16) or
        (DWord(SBox[(s0 shr 8) and $FF]) shl 8) or
         DWord(SBox[s1 and $FF]);
  t3 := (DWord(SBox[(s3 shr 24) and $FF]) shl 24) or
        (DWord(SBox[(s0 shr 16) and $FF]) shl 16) or
        (DWord(SBox[(s1 shr 8) and $FF]) shl 8) or
         DWord(SBox[s2 and $FF]);
  s0 := t0 xor K.RK[rk];   s1 := t1 xor K.RK[rk+1];
  s2 := t2 xor K.RK[rk+2]; s3 := t3 xor K.RK[rk+3];

  SetLength(OutB, 16);
  OutB[0]  := Byte(s0 shr 24); OutB[1]  := Byte(s0 shr 16);
  OutB[2]  := Byte(s0 shr 8);  OutB[3]  := Byte(s0);
  OutB[4]  := Byte(s1 shr 24); OutB[5]  := Byte(s1 shr 16);
  OutB[6]  := Byte(s1 shr 8);  OutB[7]  := Byte(s1);
  OutB[8]  := Byte(s2 shr 24); OutB[9]  := Byte(s2 shr 16);
  OutB[10] := Byte(s2 shr 8);  OutB[11] := Byte(s2);
  OutB[12] := Byte(s3 shr 24); OutB[13] := Byte(s3 shr 16);
  OutB[14] := Byte(s3 shr 8);  OutB[15] := Byte(s3);
end;

function SBoxBytes: TBytes;
var i: LongInt;
begin
  BuildTables;
  SetLength(Result, 8);
  for i := 0 to 7 do Result[i] := SBox[i];
end;

end.
