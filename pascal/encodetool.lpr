program encodetool;
{ Espejo del harness Rust encode_conformance, para diffear los archivos:

      encodetool <modo> [--seed=N] [-dN] [-dhN] [-dlN] [-dcN] [-bN] [-lN] [-cN]
                 [-hash=NOMBRE | -hash-] <entrada> <salida>

  modo es m<0..5> seguido de o (I/O-LZ), nada (Index-LZ), f (Future-LZ) o v
  (v5). --dup corre el pre-paso de dedup: la meta va adentro del v5, o como
  trailer ODUP del v4 por defecto. Salida: 0 ok; 1 error (con "ERROR! ..."
  como el Rust); 2 linea de comandos; 3 combinacion no soportada. }
{$MODE OBJFPC}{$H+}
uses OsText, SysUtils, Classes, Widths, OutRaw, Hashes, Encoder, FixedCompress, Dedup, DupWrap,
     LzCodec, SecondPass;

{ encodetool sortfixture: el orden de SortBySrc (el std::sort de libstdc++
  transcripto) sobre los arreglos de oracles/cxx/tools/stdsort_fixture.cpp,
  impreso igual que ese programa, que corre el std::sort real. El generador
  (SplitMix64, las ocho formas, los tamanos) es el mismo, y el del test Rust. }
{$PUSH}{$Q-}{$R-}
procedure PrintSortFixture;
const
  NSIZES = 46;
  SIZES: array[0..NSIZES - 1] of DWord = (
    0, 1, 2, 3, 4, 5, 8, 15, 16, 17, 18, 19, 20, 24, 31, 32, 33, 34, 40, 48,
    63, 64, 65, 100, 127, 128, 129, 200, 255, 256, 257, 300, 500, 511, 512, 513,
    777, 1000, 1023, 1024, 1025, 1500, 1999, 2000, 2047, 2048);
  NKINDS = 8;
var
  kind, si, col: LongInt;
  n, i: DWord;
  s, r, z, k: QWord;
  m, keys: TMatches;
  h: DWord;
  b: LongInt;
  line: AnsiString;
begin
  WriteOut('const STDSORT_EXPECTED: [[u32; ' + IntToStr(NSIZES) + ']; ' + IntToStr(NKINDS) + '] = [' + #10);
  for kind := 0 to NKINDS - 1 do
  begin
    line := '    [';
    col := 0;
    for si := 0 to NSIZES - 1 do
    begin
      n := SIZES[si];
      s := QWord(kind) * 1000003 + n;
      keys.N := n;
      SetLength(keys.W, n);
      i := 0;
      while i < n do
      begin
        s := s + QWord($9E3779B97F4A7C15);
        z := s;
        z := (z xor (z shr 30)) * QWord($BF58476D1CE4E5B9);
        z := (z xor (z shr 27)) * QWord($94D049BB133111EB);
        r := z xor (z shr 31);
        case kind of
          0: k := r mod (QWord(n div 8) + 1);
          1: k := r mod 3;
          2, 3: k := r mod (QWord(n) + 1);
          4: if i < n - i then k := i else k := n - i;
          5: k := r shr 24;
          6: k := 0;
        else
          if Odd(i) then k := (i div 2) div 3 else k := (n - i div 2) div 3;
        end;
        keys.W[i].Src := k;
        Inc(i);
      end;
      { las formas 2 y 3 van ordenadas; con claves solas cualquier orden
        correcto da la misma secuencia }
      if (kind = 2) or (kind = 3) then SortBySrc(keys);
      m.N := n;
      SetLength(m.W, n);
      i := 0;
      while i < n do
      begin
        if kind = 3 then m.W[i].Src := keys.W[n - 1 - i].Src else m.W[i].Src := keys.W[i].Src;
        m.W[i].Dest := i;            { el id: la posicion original }
        Inc(i);
      end;
      SortBySrc(m);
      h := 2166136261;
      i := 0;
      while i < n do
      begin
        for b := 0 to 3 do
        begin
          h := h xor DWord((m.W[i].Dest shr (8 * b)) and $FF);
          h := DWord((QWord(h) * 16777619) and $FFFFFFFF);
        end;
        Inc(i);
      end;
      if col mod 7 = 0 then line := line + #10 + '        ' else line := line + ' ';
      line := line + '0x' + LowerCase(IntToHex(h, 8)) + ',';
      Inc(col);
    end;
    WriteOut(line + #10 + '    ],' + #10);
  end;
  WriteOut('];' + #10);
end;
{$POP}

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
  mode, a, inPath, outPath, aN, aM: AnsiString;
  accN, accM: QWord;
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
  if ArgCount < 1 then
  begin
    WriteErr('usage: encodetool <mode> [--seed=N] [-dN] [-bN] [-lN] [-cN] [-aN[/M]] [-ia-|-ia+] [-hash=NAME] <in> <out>' + #10);
    Halt(2);
  end;
  mode := ArgStr(1);
  if mode = 'sortfixture' then
  begin
    PrintSortFixture;
    Halt(0);
  end;
  DefaultEncodeOptions(opts);
  SetLength(files, 0);
  for i := 2 to ArgCount do
  begin
    a := ArgStr(i);
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
    else if a = '-ia-' then opts.IoAccelerator := -1
    else if a = '-ia+' then opts.IoAccelerator := 1
    else if a = '-a-' then opts.Accel := 0
    else if StartsWith(a, '-a') then
    begin
      { -aN / -aN/M, en decimal: el tamano de bitarr y la variante }
      aN := Copy(a, 3, Length(a));
      aM := '9000';
      if Pos('/', aN) > 0 then
      begin
        aM := Copy(aN, Pos('/', aN) + 1, Length(aN));
        aN := Copy(aN, 1, Pos('/', aN) - 1);
      end;
      if not ParseU64(aN, accN) or not ParseU64(aM, accM) or (accN > High(DWord)) or
         (accM > High(DWord)) then
      begin
        WriteErr('bad option: ' + a + #10);
        Halt(2);
      end;
      opts.Accel := DWord(accN);
      opts.Accelerator := DWord(accM);
    end
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
