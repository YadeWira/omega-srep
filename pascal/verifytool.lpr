program verifytool;
{ --verify de un .osr, con el mismo texto y los mismos codigos de salida que
  `osrep --verify` del Rust (modes.rs), para diffear los dos:

      verifytool <archivo>

  0 intacto (tres lineas por stderr); 4 danado o no es un .osr; 2 un v1-v4,
  que no se puede verificar sin reconstruirlo. }
{$MODE OBJFPC}{$H+}
uses SysUtils, Classes, Widths, OutRaw, Hashes, Container, V5Verify;

function ReadAll(const Path: AnsiString; out B: TBytes): Boolean;
var fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(B, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(B[0], fs.Size);
    finally
      fs.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

procedure Die(Code: LongInt; const Msg: AnsiString);
begin
  WriteErr(#10 + '  ERROR! ' + Msg + #10);
  Halt(Code);
end;

var
  f, dup, digests: AnsiString;
  b: TBytes;
  r: TVerifyReport;
begin
  if ParamCount <> 1 then
  begin
    WriteErr('usage: verifytool <archivo.osr>' + #10);
    Halt(2);
  end;
  f := ParamStr(1);
  if not ReadAll(f, b) then Die(3, 'Can''t open ' + f + ' for read');

  if not ((Length(b) >= 4) and IsV5(b)) then
  begin
    { "un contenedor que no se puede verificar" contra "no es un archivo":
      el consejo es distinto }
    if InspectV14(b) then
      Die(2, f + ' is a v1-v4 archive, which carries no checksum anywhere, so it cannot be ' +
             'verified without reconstructing it. Decompress it to check it (the per-block ' +
             'digests are verified on the way), or re-create it with --format=v5')
    else
      Die(4, 'Not an Omega SREP compressed file (.osr): ' + f);
  end;

  try
    VerifyV5(b, r);
  except
    on X: EV5 do Die(4, f + ' is damaged: ' + X.Message);
  end;

  if r.HasDupMeta then dup := ', -dup meta checksummed' else dup := '';
  if r.HasBlockDigests then digests := ' (where the per-block digests catch it)' else digests := '';
  WriteErr(f + ': v5 archive intact. ' + IntToStr(r.Blocks) + ' blocks, ' + IntToStr(r.Records) +
           ' records, ' + IntToStr(r.OriginalSize) + ' bytes of original data' + dup + '.' + #10);
  WriteErr('  Checked without decompressing: header, footer and meta CRC-32C, framing, ' +
           'block count, every record, and that the file ends where the footer says.' + #10);
  WriteErr('  Not checked: the stored block bytes carry no checksum, so damage inside a ' +
           'literal run needs a decompress' + digests + '.' + #10);
  Halt(0);
end.
