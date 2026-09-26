unit Digest;
{ Que digest verifica cada bloque, elegido a partir de la cabecera del archivo.
  Es `Digest::for_archive` (`decompress.rs`), compartido por los decoders de
  I/O-LZ y de Future/Index-LZ.

  Tres reglas que no son obvias y que el decoder de la fase 4a no seguia:
    * un `hash_num` desconocido NO es un error: el bloque se decodifica sin
      verificar;
    * si la cabecera declara mas semilla o mas digest que el descriptor, tampoco
      se verifica;
    * si declara MENOS semilla de la que el algoritmo necesita, la clave es de
      ceros -- nunca una semilla parcial.
  Y la clave de vmac se prepara UNA vez por archivo. Prepararla por bloque (como
  hacia la 4a) es correcto pero cuesta una expansion de clave AES mas 257
  cifrados por bloque. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes, HashesKeyed, AES, Vmac, Container;

type
  TDigestKind = (dkNone, dkMD5, dkSHA1, dkSHA512, dkSipHash, dkVmac);

  TDigestSel = record
    Kind: TDigestKind;
    SipKey: TBytes;
    VmacKey: TVmac;
  end;

procedure DigestForArchive(HashNum, HashSeedSize, HashSize: Byte;
                           const Seed: TBytes; out D: TDigestSel);
function DigestEnabled(const D: TDigestSel): Boolean;
function DigestCompute(const D: TDigestSel; const Data: TBytes): TBytes;

implementation

procedure DigestForArchive(HashNum, HashSeedSize, HashSize: Byte;
                           const Seed: TBytes; out D: TDigestSel);
var
  info: THashInfo;
  key: TBytes;
  i: LongInt;
begin
  D.Kind := dkNone;
  SetLength(D.SipKey, 0);
  if not HashByNum(HashNum, info) then Exit;
  if (HashSeedSize > info.SeedSize) or (HashSize > info.HashSize) then Exit;

  if info.Name = 'md5' then D.Kind := dkMD5
  else if info.Name = 'sha1' then D.Kind := dkSHA1
  else if info.Name = 'sha512' then D.Kind := dkSHA512
  else if info.Name = 'siphash' then
  begin
    D.Kind := dkSipHash;
    SetLength(D.SipKey, SIPHASH_KEY_LEN);
    { semilla completa o ceros; nunca un prefijo }
    if Length(Seed) >= SIPHASH_KEY_LEN then
      for i := 0 to SIPHASH_KEY_LEN - 1 do D.SipKey[i] := Seed[i]
    else
      for i := 0 to SIPHASH_KEY_LEN - 1 do D.SipKey[i] := 0;
  end
  else if info.Name = 'vmac' then
  begin
    D.Kind := dkVmac;
    SetLength(key, VMAC_KEY_LEN_BYTES);
    if Length(Seed) >= VMAC_KEY_LEN_BYTES then
      for i := 0 to VMAC_KEY_LEN_BYTES - 1 do key[i] := Seed[i]
    else
      for i := 0 to VMAC_KEY_LEN_BYTES - 1 do key[i] := 0;
    VmacSetKey(key, D.VmacKey);
  end;
  { el descriptor '' (num 1) es "checksums apagados": queda en dkNone }
end;

function DigestEnabled(const D: TDigestSel): Boolean;
begin
  Result := D.Kind <> dkNone;
end;

function DigestCompute(const D: TDigestSel; const Data: TBytes): TBytes;
begin
  case D.Kind of
    dkMD5:     Result := MD5(Data);
    dkSHA1:    Result := SHA1(Data);
    dkSHA512:  Result := SHA512(Data);
    dkSipHash: Result := SipHash(D.SipKey, Data);
    dkVmac:    Result := VmacCompute(D.VmacKey, Data);
  else
    SetLength(Result, 0);
  end;
end;

end.
