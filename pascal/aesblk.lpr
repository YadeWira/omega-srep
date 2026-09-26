program aesblk;
{$MODE OBJFPC}{$H+}
uses Widths, Hashes, AES, SysUtils, Classes;
var k: TAesKey; key, data, outb, acc: TBytes; fs: TFileStream; i, n: LongInt;
begin
  key := FromHex(ParamStr(1));
  fs := TFileStream.Create(ParamStr(2), fmOpenRead); SetLength(data, fs.Size);
  if fs.Size > 0 then fs.ReadBuffer(data[0], fs.Size); fs.Free;
  AesSetKey(key, k);
  n := Length(data) div 16; SetLength(acc, 0);
  for i := 0 to n - 1 do
  begin
    SetLength(outb, 16);
    AesEncryptBlock(k, Copy(data, i * 16, 16), outb);
    acc := Concat(acc, outb);
  end;
  WriteLn(ToHex(acc));
end.
