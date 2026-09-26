program containertool;
{ Vuelca la estructura de un .osr, para diffear el parseo del port contra el
  binario Rust:  containertool <archivo>

  Imprime una linea por campo, en un formato estable y comparable. No
  reconstruye nada: solo lee el armazon, que es lo que la fase 3 tiene que
  hacer bien antes de que exista un decoder. }
{$MODE OBJFPC}{$H+}
uses Widths, OutRaw, Hashes, Container, SysUtils, Classes;

function ReadAll(const Path: AnsiString): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally fs.Free; end;
end;

function ErrName(E: TContainerError): AnsiString;
begin
  case E of
    ceOK: Result := 'ok';
    ceTruncated: Result := 'truncated';
    ceNotAnOsrepFile: Result := 'not-an-osrep-file';
    ceUnsupportedVersion: Result := 'unsupported-version';
    ceNoFooter: Result := 'no-footer';
    ceUnsupportedFooterVersion: Result := 'unsupported-footer-version';
    ceBadFlags: Result := 'bad-flags';
    ceBadHash: Result := 'bad-hash';
    ceBadCrc: Result := 'bad-crc';
    ceBlockCountMismatch: Result := 'block-count-mismatch';
  else Result := 'unknown';
  end;
end;

{ Reencodea lo parseado y exige los MISMOS bytes que el archivo real. Parsear
  bien y escribir mal es un error que un round-trip contra uno mismo no ve:
  hay que comparar contra bytes que produjo otra implementacion. }
function SameBytes(const A, B: TBytes; AtB: QWord): Boolean;
var i: LongInt;   { header y footer no pasan de 32 bytes; y en i386 un QWord
                    no vale como variable de control de un `for` }
begin
  for i := 0 to Length(A) - 1 do
    if A[i] <> B[AtB + QWord(i)] then Exit(False);
  Result := True;
end;

var
  data, re: TBytes; e: TContainerError;
  h4: TArchiveHeader; h5: TV5Header; f5: TV5Footer; fh: TFooterHead;
  hi: THashInfo; n: QWord;
begin
  if ParamCount < 1 then begin WriteErr('usage: containertool <archivo>' + #10); Halt(2); end;
  data := ReadAll(ParamStr(1));
  n := QWord(Length(data));

  if IsV5(data) then
  begin
    e := DecodeV5Header(data, h5);
    WriteOut('container v5' + #10);
    WriteOut('header ' + ErrName(e) + #10);
    if e <> ceOK then Halt(4);
    WriteOut('hash_id ' + IntToStr(h5.HashId) + #10);
    if HashByNum(h5.HashId, hi) then WriteOut('hash_name ' + hi.Name + #10);
    WriteOut('hash_size ' + IntToStr(h5.HashSize) + #10);
    WriteOut('flags ' + IntToStr(h5.Flags) + #10);
    WriteOut('max_match ' + IntToStr(h5.MaxMatch) + #10);
    WriteOut('block_count ' + IntToStr(h5.BlockCount) + #10);
    WriteOut('original_size ' + IntToStr(h5.OriginalSize) + #10);
    e := DecodeV5Footer(data, n - V5_FOOTER_SIZE, f5);
    WriteOut('footer ' + ErrName(e) + #10);
    if e = ceOK then
    begin
      WriteOut('footer_block_count ' + IntToStr(f5.BlockCount) + #10);
      WriteOut('stat_size ' + IntToStr(f5.StatSize) + #10);
      WriteOut('meta_size ' + IntToStr(f5.MetaSize) + #10);
      re := EncodeV5Footer(f5);
      if SameBytes(re, data, n - V5_FOOTER_SIZE) then
        WriteOut('reencode_footer identical' + #10)
      else WriteOut('reencode_footer DIFFERS' + #10);
    end;
    re := EncodeV5Header(h5);
    if SameBytes(re, data, 0) then WriteOut('reencode_header identical' + #10)
    else WriteOut('reencode_header DIFFERS' + #10);
  end
  else
  begin
    e := DecodeArchiveHeader(data, h4);
    WriteOut('container v1-v4' + #10);
    WriteOut('header ' + ErrName(e) + #10);
    if e <> ceOK then Halt(4);
    WriteOut('version ' + IntToStr(h4.Version) + #10);
    WriteOut('hash_id ' + IntToStr(h4.HashNum) + #10);
    if HashByNum(h4.HashNum, hi) then WriteOut('hash_name ' + hi.Name + #10);
    WriteOut('hash_size ' + IntToStr(h4.HashSize) + #10);
    WriteOut('hash_seed_size ' + IntToStr(h4.HashSeedSize) + #10);
    WriteOut('base_len ' + IntToStr(h4.BaseLen) + #10);
    if h4.Version = 4 then
    begin
      e := DecodeFooterHead(data, n - INDEX_LZ_FOOTER_SIZE, fh);
      WriteOut('footer ' + ErrName(e) + #10);
      if e = ceOK then
      begin
        WriteOut('stat_size ' + IntToStr(fh.TotalStatSize) + #10);
        WriteOut('footer_size ' + IntToStr(fh.FooterSize) + #10);
        re := EncodeFooterHead(fh.TotalStatSize, (fh.FooterSize - INDEX_LZ_FOOTER_SIZE) div 4);
        if SameBytes(re, data, n - INDEX_LZ_FOOTER_SIZE) then
          WriteOut('reencode_footer identical' + #10)
        else WriteOut('reencode_footer DIFFERS' + #10);
      end;
    end;
    re := EncodeArchiveHeader(h4);
    if SameBytes(re, data, 0) then WriteOut('reencode_header identical' + #10)
    else WriteOut('reencode_header DIFFERS' + #10);
  end;
end.
