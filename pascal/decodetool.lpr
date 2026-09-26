program decodetool;
{ Descomprime un .osr:  decodetool <archivo> <salida>
  Fase 4a: solo I/O-LZ (v1/v2). Lo demas se rechaza diciendolo. }
{$MODE OBJFPC}{$H+}
uses Widths, OutRaw, Hashes, Container, Decompress, SysUtils, Classes;

function ReadAll(const Path: AnsiString): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally fs.Free; end;
end;

function ErrName(E: TDecodeError): AnsiString;
begin
  case E of
    deOK: Result := 'ok';
    deTruncated: Result := 'truncated';
    deBadData: Result := 'broken compressed data';
    deDigestMismatch: Result := 'digest mismatch';
    deContainer: Result := 'not an omega srep compressed file';
    deNotIoLz: Result := 'not an I/O-LZ archive';
    deNotPortedYet: Result := 'a valid archive this decoder does not handle yet: only I/O-LZ (-mNo) is ported';
  else Result := 'unknown';
  end;
end;

var arc: TBytes; out_: TFileStream; st: TDecodeStats; e: TDecodeError;
begin
  if ParamCount < 2 then
  begin
    WriteErr('usage: decodetool <archivo.osr> <salida>' + #10);
    Halt(2);
  end;
  arc := ReadAll(ParamStr(1));
  out_ := TFileStream.Create(ParamStr(2), fmCreate);
  try
    e := DecodeIoLz(arc, out_, st);
  finally out_.Free; end;
  if e <> deOK then
  begin
    WriteErr(#10 + '  ERROR! ' + ErrName(e) + #10);
    DeleteFile(ParamStr(2));
    if (e = deNotIoLz) or (e = deNotPortedYet) then Halt(3);
    Halt(4);
  end;
  WriteErr(IntToStr(st.Blocks) + ' bloques, ' + IntToStr(st.OrigSize) + ' bytes' + #10);
end.
