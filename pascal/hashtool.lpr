program hashtool;
{ Espejo de `tests/hash_test.cpp`, para que el harness pueda diffear los dos
  lado a lado:  hashtool <algo> <seed-hex|none> <archivo>
  Imprime el digest en hex minuscula por stdout. }
{$MODE OBJFPC}{$H+}
uses Widths, OutRaw, Hashes, HashesKeyed, AES, Vmac, SysUtils, Classes;

function ReadAll(const Path: AnsiString): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

var algo, seed, path: AnsiString; data, k: TBytes; vk: TVmac;
begin
  if ParamCount < 3 then
  begin
    WriteErr('usage: hashtool <algo> <seed-hex|none> <input-file>' + #10);
    Halt(2);
  end;
  algo := ParamStr(1); seed := ParamStr(2); path := ParamStr(3);
  data := ReadAll(path);
  if algo = 'md5' then
    WriteOut(ToHex(MD5(data)) + #10)
  else if algo = 'sha1' then
    WriteOut(ToHex(SHA1(data)) + #10)
  else if algo = 'sha512' then
    WriteOut(ToHex(SHA512(data)) + #10)
  else if algo = 'siphash' then
    WriteOut(ToHex(SipHash(FromHex(seed), data)) + #10)
  else if algo = 'vmac' then
  begin
    k := FromHex(seed);
    if Length(k) <> VMAC_KEY_LEN_BYTES then
    begin
      WriteErr('vmac necesita una semilla de 32 bytes' + #10);
      Halt(2);
    end;
    VmacSetKey(k, vk);
    WriteOut(ToHex(VmacCompute(vk, data)) + #10);
  end
  else
  begin
    { Honesto mientras no este: mejor rechazar que imprimir algo plausible. }
    WriteErr('hashtool: "' + algo + '" no portado todavia' + #10);
    Halt(3);
  end;
end.
