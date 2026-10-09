program encodetool;
{ Espejo del harness Rust encode_conformance, para diffear los archivos:

      encodetool <modo> [--seed=N] [-dN] [-dhN] [-dlN] [-dcN] [-bN] [-lN] [-cN]
                 [-hash=NOMBRE | -hash-] <entrada> <salida>

  modo es m<0..5> seguido de o (I/O-LZ), nada (Index-LZ), f (Future-LZ) o v
  (v5). --dup corre el pre-paso de dedup: la meta va adentro del v5, o como
  trailer ODUP del v4 por defecto. Salida: 0 ok; 1 error (con "ERROR! ..."
  como el Rust); 2 linea de comandos; 3 combinacion no soportada. }
{$MODE OBJFPC}{$H+}
uses SysUtils, Classes, Widths, OutRaw, Hashes, Encoder, FixedCompress, Dedup, DupWrap;

{ parseMem (Common.h), con los sufijos que usa el harness, igual que el Rust:
  digitos invalidos dan 0. }
function ParseMem(const S: AnsiString): QWord;
var low, digits: AnsiString; mul, v: QWord; i: LongInt;
begin
  low := LowerCase(S);
  mul := 1;
  digits := low;
  if (Length(low) >= 2) and (Copy(low, Length(low) - 1, 2) = 'gb') then begin digits := Copy(low, 1, Length(low) - 2); mul := QWord(1) shl 30; end
  else if (Length(low) >= 2) and (Copy(low, Length(low) - 1, 2) = 'mb') then begin digits := Copy(low, 1, Length(low) - 2); mul := QWord(1) shl 20; end
  else if (Length(low) >= 2) and (Copy(low, Length(low) - 1, 2) = 'kb') then begin digits := Copy(low, 1, Length(low) - 2); mul := QWord(1) shl 10; end
  else if (Length(low) >= 1) and (low[Length(low)] = 'g') then begin digits := Copy(low, 1, Length(low) - 1); mul := QWord(1) shl 30; end
  else if (Length(low) >= 1) and (low[Length(low)] = 'm') then begin digits := Copy(low, 1, Length(low) - 1); mul := QWord(1) shl 20; end
  else if (Length(low) >= 1) and (low[Length(low)] = 'k') then begin digits := Copy(low, 1, Length(low) - 1); mul := QWord(1) shl 10; end;
  v := 0;
  if digits = '' then Exit(0);
  i := 1;
  if digits[1] = '+' then i := 2;
  if i > Length(digits) then Exit(0);
  while i <= Length(digits) do
  begin
    if not (digits[i] in ['0'..'9']) then Exit(0);
    v := v * 10 + QWord(Ord(digits[i]) - Ord('0'));
    Inc(i);
  end;
  { saturating_mul }
  if (mul > 1) and (v > High(QWord) div mul) then Exit(High(QWord));
  Result := v * mul;
end;

function ParseU64(const S: AnsiString; out N: QWord): Boolean;
var i, start: LongInt; d: QWord;
begin
  Result := False; N := 0; start := 1;
  if (Length(S) > 0) and (S[1] = '+') then start := 2;
  if start > Length(S) then Exit;
  for i := start to Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    d := QWord(Ord(S[i]) - Ord('0'));
    if N > (High(QWord) - d) div 10 then Exit;
    N := N * 10 + d;
  end;
  Result := True;
end;

function StartsWith(const S, P: AnsiString): Boolean;
begin
  Result := Copy(S, 1, Length(P)) = P;
end;

var
  mode, a, inPath, outPath: AnsiString;
  opts: TEncodeOptions;
  files: array of AnsiString;
  i: LongInt;
  kind: TEncKind;
  cont: TEncContainer;
  okMode: Boolean;
  inS, outS: TFileStream;
  rc: LongInt;
  dup: Boolean;
  dp: TDupParams;
  dm: TDupMode;
begin
  dup := False;
  if ParamCount < 1 then
  begin
    WriteErr('usage: encodetool <mode> [--seed=N] [-dN] [-bN] [-lN] [-cN] [-hash=NAME] <in> <out>' + #10);
    Halt(2);
  end;
  mode := ParamStr(1);
  DefaultEncodeOptions(opts);
  SetLength(files, 0);
  for i := 2 to ParamCount do
  begin
    a := ParamStr(i);
    if StartsWith(a, '--seed=') then
    begin
      if not ParseU64(Copy(a, 8, Length(a)), opts.Seed) then
      begin
        WriteErr('bad --seed value: ' + Copy(a, 8, Length(a)) + #10);
        Halt(2);
      end;
      opts.HasSeed := True;
    end
    else if a = '--dup' then dup := True
    else if StartsWith(a, '-dh') then opts.DictHashSize := ParseMem(Copy(a, 4, Length(a)))
    else if StartsWith(a, '-dl') then opts.DictMinMatch := ParseMem(Copy(a, 4, Length(a)))
    else if StartsWith(a, '-dc') then opts.DictChunk := ParseMem(Copy(a, 4, Length(a)))
    else if StartsWith(a, '-d') then opts.DictSize := ParseMem(Copy(a, 3, Length(a)))
    else if StartsWith(a, '-b') then opts.BufSize := ParseMem(Copy(a, 3, Length(a)))
    else if StartsWith(a, '-l') then opts.MinMatch := ParseMem(Copy(a, 3, Length(a)))
    else if StartsWith(a, '-c') then opts.L := ParseMem(Copy(a, 3, Length(a)))
    else if StartsWith(a, '-hash=') then opts.Hash := Copy(a, 7, Length(a))
    else if a = '-hash-' then opts.Hash := ''
    else if (Length(a) > 0) and (a[1] <> '-') then
    begin
      SetLength(files, Length(files) + 1);
      files[High(files)] := a;
    end
    else
    begin
      WriteErr('unknown option: ' + a + #10);
      Halt(2);
    end;
  end;
  if Length(files) <> 2 then
  begin
    WriteErr('need exactly <in> <out>' + #10);
    Halt(2);
  end;
  inPath := files[0];
  outPath := files[1];
  { -m0 sin -d usa el default de 512 MiB (srep.cpp:445) }
  if StartsWith(mode, 'm0') and (opts.DictSize = 0) then opts.DictSize := DEFAULT_DICTSIZE;

  okMode := (Length(mode) >= 2) and (mode[1] = 'm') and (mode[2] in ['0'..'5']);
  if okMode then
  begin
    case mode[2] of
      '0': kind := ekInmem;
      '1': kind := ekCdc;
      '2': kind := ekCdcZpaq;
      '3': kind := ekDigest;
      '4': kind := ekFixed;
    else kind := ekFixedExhaustive;
    end;
    a := Copy(mode, 3, Length(mode));
    if a = 'o' then cont := ecIoLz
    else if a = '' then cont := ecIndexLz
    else if a = 'f' then cont := ecFutureLz
    else if a = 'v' then cont := ecV5
    else okMode := False;
  end;

  rc := 0;
  if dup and okMode then
  begin
    { el wrapper abre sus propios archivos: en Windows la salida no se puede
      tener abierta dos veces }
    if cont = ecV5 then dm := dmV5
    else if cont = ecIndexLz then dm := dmV4
    else
    begin
      WriteErr(mode + ': -dup needs the v5 (`v`) or the default (no suffix) container' + #10);
      Halt(3);
    end;
    DefaultDupParams(dp);
    try
      DupEncode(inPath, outPath, opts, kind, cont, dp, False, dm);
    except
      on X: Exception do
      begin
        WriteErr('ERROR! ' + X.Message + #10);
        rc := 1;
      end;
    end;
    Halt(rc);
  end;
  inS := nil; outS := nil;
  try
    try
      inS := TFileStream.Create(inPath, fmOpenRead or fmShareDenyNone);
      outS := TFileStream.Create(outPath, fmCreate);
      if not okMode then raise ENotPorted.Create(mode + ': not ported to Pascal yet');
      Encode(inS, outS, opts, kind, cont);
    except
      on X: ENotPorted do
      begin
        WriteErr(X.Message + #10);
        rc := 3;
      end;
      on X: Exception do
      begin
        WriteErr('ERROR! ' + X.Message + #10);
        rc := 1;
      end;
    end;
  finally
    outS.Free;
    inS.Free;
  end;
  Halt(rc);
end.
