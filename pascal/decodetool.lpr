program decodetool;
{ Descomprime un .osr, espejo del harness Rust (`decode_conformance`):

      decodetool <archivo> <salida> [--mem=N] [--vmblock=N] [--maxsave=N]

  En exito imprime por stdout la misma linea que el harness, para que los dos
  se puedan diffear tal cual:

      I/O-LZ (v1/v2):        ok blocks=N origsize=N verified=0|1
      Future/Index-LZ (v3/v4): ok blocks=N origsize=N verified=0|1 vmw=N vmr=N

  Salida: 0 ok; 2 linea de comandos; 3 archivo valido que todavia no se
  soporta (v5); 4 archivo danado, o que no se pudo leer o escribir. En error
  se borra la salida si la creamos nosotros: nunca queda un archivo a medias,
  y nunca se borra uno que ya estaba. Ninguna excepcion llega a ser un runtime
  error: antes, no poder abrir el archivo o crear la salida terminaba en 217. }
{$MODE OBJFPC}{$H+}
uses SysUtils, Classes, Widths, OutRaw, Hashes, Container, Decompress, FutureLz;

function ReadAll(const Path: AnsiString): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally fs.Free; end;
end;

{ `str::parse::<u64>` del Rust: un '+' opcional y uno o mas digitos, nada
  mas. TryStrToQWord (Val) acepta ademas '$', '0x', '%', '&' y espacios al
  principio, y el harness Rust rechaza todo eso. }
function ParseU64(const S: AnsiString; out N: QWord): Boolean;
var i, start: LongInt; d: QWord;
begin
  Result := False;
  N := 0;
  start := 1;
  if (Length(S) > 0) and (S[1] = '+') then start := 2;
  if start > Length(S) then Exit;
  for i := start to Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    d := QWord(Ord(S[i]) - Ord('0'));
    if N > (High(QWord) - d) div 10 then Exit;   { desborda }
    N := N * 10 + d;
  end;
  Result := True;
end;

procedure Die(Code: LongInt; const Msg: AnsiString);
begin
  WriteErr(#10 + '  ERROR! ' + Msg + #10);
  Halt(Code);
end;

function PeekHeader(const Path: AnsiString; out H: TArchiveHeader; out V5: Boolean): Boolean;
var fs: TFileStream; b: TBytes; n: LongInt;
begin
  Result := False; V5 := False;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(b, ARCHIVE_HEADER_SIZE);
    n := fs.Read(b[0], ARCHIVE_HEADER_SIZE);
  finally fs.Free; end;
  if n >= 4 then
  begin
    SetLength(b, n);
    if IsV5(b) then begin V5 := True; Exit(True); end;
  end;
  if n < ARCHIVE_HEADER_SIZE then Exit(False);
  Result := DecodeArchiveHeader(b, H) = ceOK;
end;

var
  arcPath, outPath, a, key, val: AnsiString;
  opts: TFutureLzOptions;
  i, eq: LongInt;
  h: TArchiveHeader;
  isV5: Boolean;
  e: TDecodeError;
  st: TDecodeStats;
  fst: TFutureLzStats;
  msg: AnsiString;
  inS, outS: TFileStream;
  n: QWord;
  ok, created: Boolean;
  arc: TBytes;
begin
  if ParamCount < 2 then
  begin
    WriteErr('usage: decodetool <archivo.osr> <salida> [--mem=N] [--vmblock=N] [--maxsave=N]' + #10);
    Halt(2);
  end;
  arcPath := ParamStr(1);
  outPath := ParamStr(2);
  DefaultFutureLzOptions(opts);
  for i := 3 to ParamCount do
  begin
    a := ParamStr(i);
    eq := Pos('=', a);
    if (Copy(a, 1, 2) <> '--') or (eq = 0) then
    begin
      WriteErr('expected --key=value, got ' + a + #10);
      Halt(2);
    end;
    key := Copy(a, 1, eq - 1);
    val := Copy(a, eq + 1, Length(a));
    if not ParseU64(val, n) then
    begin
      WriteErr(a + ': not a number' + #10);
      Halt(2);
    end;
    if key = '--mem' then opts.MemLimit := n
    else if key = '--vmblock' then opts.VmBlock := n
    else if key = '--maxsave' then opts.MaximumSave := DWord(n)   { `as u32` }
    else
    begin
      WriteErr('unknown option ' + key + #10);
      Halt(2);
    end;
  end;

  ok := False;
  isV5 := False;
  try
    ok := PeekHeader(arcPath, h, isV5);
  except
    on X: Exception do Die(4, arcPath + ': ' + X.Message);
  end;
  if not ok then Die(4, 'not an Omega SREP compressed file (.osr)');
  if isV5 then Die(3, 'a valid v5 archive; this decoder does not handle v5 yet');

  msg := '';
  e := deIo;
  inS := nil;
  outS := nil;
  created := False;
  try
    try
      { la entrada se abre ANTES de crear la salida: si no se puede leer, la
        salida (que quizas ya existia) no se toca }
      if (h.Version = 1) or (h.Version = 2) then
      begin
        arc := ReadAll(arcPath);
        outS := TFileStream.Create(outPath, fmCreate);
        created := True;
        e := DecodeIoLz(arc, outS, st);
      end
      else
      begin
        inS := TFileStream.Create(arcPath, fmOpenRead or fmShareDenyNone);
        outS := TFileStream.Create(outPath, fmCreate);
        created := True;
        e := DecodeFutureLz(inS, outS, opts, fst, msg);
      end;
    except
      { la division por cero de v1, un disco lleno, lo que sea }
      on X: Exception do          { no E: taparia a la variable e }
      begin
        e := deIo;
        msg := X.Message;
      end;
    end;
  finally
    { cerrar ANTES de borrar: en Windows un archivo abierto no se borra }
    outS.Free;
    inS.Free;
  end;

  if e = deOK then
  begin
    if (h.Version = 1) or (h.Version = 2) then
      WriteOut('ok blocks=' + IntToStr(st.Blocks) + ' origsize=' + IntToStr(st.OrigSize) +
               ' verified=' + IntToStr(Ord(st.Verified)) + #10)
    else
      WriteOut('ok blocks=' + IntToStr(fst.Blocks) + ' origsize=' + IntToStr(fst.OrigSize) +
               ' verified=' + IntToStr(Ord(fst.Verified)) +
               ' vmw=' + IntToStr(fst.VmBytesWritten) + ' vmr=' + IntToStr(fst.VmBytesRead) + #10);
    Halt(0);
  end;

  if created then DeleteFile(outPath);
  if msg = '' then msg := 'decode failed';
  Die(4, msg);
end.
