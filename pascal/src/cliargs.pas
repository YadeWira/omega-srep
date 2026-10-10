unit CliArgs;
{ La linea de comandos (args.rs).

  Dos parsers, en el orden del C++: primero el pre-paso del wrapper de -dup
  (dup_wrapper.cpp:88-155), porque sus opciones (-dup, --chunk-*, --seed=)
  son unas que srep_main rechazaria, y despues el bucle de srep_main
  (srep.cpp:303-430). El orden de las pruebas dentro del bucle importa y se
  conserva: -vmfile= y -vmblock= antes de -v, -hash- antes de -hash=, y -d
  antes de la familia -d... }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Widths, Hashes, Dedup;

const
  KB = QWord(1024);
  MB = QWord(1024) * 1024;
  GB = QWord(1024) * 1024 * 1024;
  { slices_in_block (hash_table.cpp:32): el -c mas chico que le deja a
    SliceHash un slice distinto de cero }
  SLICES_IN_BLOCK = 8;
  { El -l, -c, -dl o -dc mas grande: el C++ los guarda en un unsigned
    (srep.cpp:292) y lo que pasa de ahi da la vuelta (-l4294967296 es -l0, el
    default). El port lo tomaba entero, y en 32 bits lo truncaba como el C++,
    asi que la misma linea daba archivos distintos en cada build; pasado 2^63
    ademas desbordaba el 2 * L del match finder (Access violation; en el Rust
    un panico) y el -l + 1 de -m5. args.rs, MAX_LENGTH_OPTION. }
  MAX_LENGTH_OPTION = QWord(High(DWord));
  { srep.cpp:284: lo que supone la compresion desde stdin si -s no dice nada }
  DEFAULT_STDIN_FILESIZE = QWord(25) * GB;

type
  TCmdMode = (cmCompress, cmDecompress, cmInfo, cmVerify);
  TFormat = (fmtV4, fmtV5);
  TLz = (lzIndex, lzFuture, lzIo);
  TUnit = (uB, uK, uM, uG, uPow);
  { Seed del encoder: Random (la CLI sortea), Value (--seed=N) }
  TSeedKind = (skRandom, skValue);

  TOptions = record
    CmdMode: TCmdMode;
    Format: TFormat;
    Method: Byte;
    Lz: TLz;
    DictSize, DictHashSize: QWord;
    DictChunk, DictMinMatch, MinMatch, L: QWord;    { usize del Rust }
    MaximumSave: DWord;
    BufSize: QWord;
    NumThreads: QWord;
    Accel: DWord;
    IoAccelerator: LongInt;
    { -hash=NOMBRE; HasHash False = el default, Hash '' = -hash- }
    HasHash: Boolean;
    Hash: AnsiString;
    VmMem, VmBlock: QWord;
    HasVmFile: Boolean;
    VmFile: AnsiString;
    HasTempFile: Boolean;
    TempFile: AnsiString;
    IndexFile: AnsiString;
    DeleteInput: Boolean;
    Verbosity: LongInt;
    Bar: Boolean;
    StatsCadence: AnsiString;
    HasDeclaredSize: Boolean;
    DeclaredSize: QWord;
    UseMmap: Boolean;
    Dup, DupParanoid: Boolean;
    Chunk: TDupParams;
    SeedKind: TSeedKind;
    Seed: QWord;
    SeedInvalid: Boolean;
    Files: array of AnsiString;
  end;

  { un error de linea de comandos, listo para imprimir con la forma de error() }
  ECmdLine = class(Exception);

{ parseMem64 (Common.cpp:245-260) }
function ParseMem(const S: AnsiString; Spec: TUnit; out N: QWord): Boolean;
{ parse_mem_option (srep.cpp:192-222): -mem100mb, -mem75%, -mem75%-600mb }
function ParseMemOption(const S: AnsiString; Spec: TUnit; out N: QWord): Boolean;
procedure DefaultOptions(out O: TOptions);
{ argv sin el nombre del programa; ECmdLine si no parsea }
procedure ParseArgs(const Args: array of AnsiString; out O: TOptions);

implementation

uses Classes;

function IsDigit(C: AnsiChar): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

function StartsWith(const S, P: AnsiString): Boolean; inline;
begin
  Result := Copy(S, 1, Length(P)) = P;
end;

function After(const S, P: AnsiString): AnsiString; inline;
begin
  Result := Copy(S, Length(P) + 1, Length(S));
end;

function ParseMem(const S: AnsiString; Spec: TUnit; out N: QWord): Boolean;
var i: LongInt; d: QWord; u: TUnit;
begin
  Result := False;
  N := 0;
  i := 1;
  if (Length(S) >= 1) and (S[1] = '=') then i := 2;
  if (i > Length(S)) or not IsDigit(S[i]) then Exit;
  while (i <= Length(S)) and IsDigit(S[i]) do
  begin
    d := QWord(Ord(S[i]) - Ord('0'));
    { checked_mul(10)?.checked_add(d)? }
    if N > (High(QWord) - d) div 10 then Exit;
    N := N * 10 + d;
    Inc(i);
  end;
  if i > Length(S) then u := Spec
  else
    case S[i] of
      'b': u := uB;
      'k': u := uK;
      'm': u := uM;
      'g': u := uG;
      '^': u := uPow;
    else
      Exit;
    end;
  case u of
    uB: ;
    uK: begin if N > High(QWord) div KB then Exit; N := N * KB; end;
    uM: begin if N > High(QWord) div MB then Exit; N := N * MB; end;
    uG: begin if N > High(QWord) div GB then Exit; N := N * GB; end;
    uPow: begin if N >= 64 then Exit; N := QWord(1) shl N; end;
  end;
  Result := True;
end;

{ GetPhysicalMemory(): solo resuelve -memNN%, y lo que alimenta (el
  presupuesto del derrame) cambia CUANDO se guardan los matches en memoria,
  nunca lo que sale. El Rust solo lo lee en Linux y en el resto supone 4 GB;
  aca igual, para que los dos tomen las mismas decisiones. }
function PhysicalMemory: QWord;
{$IFDEF LINUX}
var sl: TStringList; i, j: LongInt; line, num: AnsiString; kb_: QWord;
{$ENDIF}
begin
  {$IFDEF LINUX}
  try
    sl := TStringList.Create;
    try
      sl.LoadFromFile('/proc/meminfo');
      for i := 0 to sl.Count - 1 do
      begin
        line := sl[i];
        if not StartsWith(line, 'MemTotal:') then Continue;
        line := Trim(After(line, 'MemTotal:'));
        j := 1;
        while (j <= Length(line)) and not (line[j] in [' ', #9]) do Inc(j);
        num := Copy(line, 1, j - 1);
        if TryStrToQWord(num, kb_) then Exit(kb_ * KB);
      end;
    finally
      sl.Free;
    end;
  except
    { el fallback }
  end;
  {$ENDIF}
  Result := 4 * GB;
end;

function ParseMemOption(const S: AnsiString; Spec: TUnit; out N: QWord): Boolean;
var i: LongInt; percent, minus, p: QWord;
begin
  if ParseMem(S, Spec, N) then Exit(True);
  Result := False;
  i := 1;
  percent := 0;
  while (i <= Length(S)) and IsDigit(S[i]) do
  begin
    percent := percent * 10 + QWord(Ord(S[i]) - Ord('0'));   { wrapping, como el Rust en release }
    Inc(i);
  end;
  if (i > Length(S)) or not (S[i] in ['%', 'p']) then Exit;
  Inc(i);
  { -mem75% no lleva nada despues del signo; -mem75%-600mb resta }
  if (i <= Length(S)) and (S[i] = '-') then
  begin
    if not ParseMem(Copy(S, i + 1, Length(S)), Spec, minus) then Exit;
  end
  else if i > Length(S) then minus := 0
  else Exit;
  p := percent * (PhysicalMemory div 100);
  if p > minus then N := p - minus else N := 0;
  Result := True;
end;

{ `str::parse::<i64>`: un signo opcional y digitos, sin desbordar }
function ParseI64Dec(const S: AnsiString; out N: Int64): Boolean;
var i, start: LongInt; neg: Boolean; v, d, lim: QWord;
begin
  Result := False; N := 0;
  start := 1; neg := False;
  if (Length(S) >= 1) and (S[1] in ['+', '-']) then
  begin
    neg := S[1] = '-';
    start := 2;
  end;
  if start > Length(S) then Exit;
  if neg then lim := QWord(High(Int64)) + 1 else lim := QWord(High(Int64));
  v := 0;
  for i := start to Length(S) do
  begin
    if not IsDigit(S[i]) then Exit;
    d := QWord(Ord(S[i]) - Ord('0'));
    if v > (lim - d) div 10 then Exit;
    v := v * 10 + d;
  end;
  if neg then N := -Int64(v - 1) - 1 else N := Int64(v);
  Result := True;
end;

{ `i64::from_str_radix(s, 16)` }
function ParseI64Hex(const S: AnsiString; out N: Int64): Boolean;
var i, start: LongInt; neg: Boolean; v, d, lim: QWord; c: AnsiChar;
begin
  Result := False; N := 0;
  start := 1; neg := False;
  if (Length(S) >= 1) and (S[1] in ['+', '-']) then
  begin
    neg := S[1] = '-';
    start := 2;
  end;
  if start > Length(S) then Exit;
  if neg then lim := QWord(High(Int64)) + 1 else lim := QWord(High(Int64));
  v := 0;
  for i := start to Length(S) do
  begin
    c := S[i];
    if IsDigit(c) then d := QWord(Ord(c) - Ord('0'))
    else if c in ['a'..'f'] then d := QWord(Ord(c) - Ord('a') + 10)
    else if c in ['A'..'F'] then d := QWord(Ord(c) - Ord('A') + 10)
    else Exit;
    if v > (lim - d) div 16 then Exit;
    v := v * 16 + d;
  end;
  if neg then N := -Int64(v - 1) - 1 else N := Int64(v);
  Result := True;
end;

function ParseInt(const S0: AnsiString; out N: Int64): Boolean;
var s: AnsiString;
begin
  s := S0;
  if StartsWith(s, '=') then s := After(s, '=');
  if StartsWith(s, '0x') or StartsWith(s, '0X') then
    Result := ParseI64Hex(After(s, '0x'), N)
  else
    Result := ParseI64Dec(s, N);
end;

{ `str::parse::<usize>`: '+' opcional y digitos; en 32 bits el tope es 4 GiB }
function ParseUsize(const S: AnsiString; out N: QWord): Boolean;
var i, start: LongInt; d: QWord;
begin
  Result := False; N := 0; start := 1;
  if (Length(S) > 0) and (S[1] = '+') then start := 2;
  if start > Length(S) then Exit;
  for i := start to Length(S) do
  begin
    if not IsDigit(S[i]) then Exit;
    d := QWord(Ord(S[i]) - Ord('0'));
    if N > (QWord(High(PtrUInt)) - d) div 10 then Exit;
    N := N * 10 + d;
  end;
  Result := True;
end;

{ `as usize`: en 32 bits trunca }
function AsUsize(N: QWord): QWord; inline;
begin
  Result := QWord(PtrUInt(N));
end;

{ --seed=N: decimal o hex con 0x (dup_wrapper.cpp:117-132) }
function ParseSeed(const V: AnsiString; out N: QWord): Boolean;
var x: Int64;
begin
  Result := False;
  if V = '' then Exit;
  if not ParseInt(V, x) then Exit;
  if x < 0 then Exit;
  N := QWord(x);
  Result := True;
end;

procedure DefaultOptions(out O: TOptions);
begin
  O.CmdMode := cmCompress;
  O.Format := fmtV5;
  O.Method := 3;
  O.Lz := lzIndex;
  O.DictSize := 0;
  O.DictHashSize := 0;
  O.DictChunk := 0;
  O.DictMinMatch := 0;
  O.MinMatch := 0;
  O.L := 0;
  O.MaximumSave := High(DWord);
  O.BufSize := 8 * MB;
  O.NumThreads := 0;
  O.Accel := 9000;
  O.IoAccelerator := 1;
  O.HasHash := False;
  O.Hash := '';
  if not ParseMemOption('75%', uM, O.VmMem) then O.VmMem := 0;
  O.VmBlock := 8 * MB;
  O.HasVmFile := False;
  O.VmFile := '';
  O.HasTempFile := False;
  O.TempFile := '';
  O.IndexFile := '';
  O.DeleteInput := False;
  O.Verbosity := 2;
  O.Bar := False;
  O.StatsCadence := '+';
  O.HasDeclaredSize := False;
  O.DeclaredSize := 0;
  O.UseMmap := False;
  O.Dup := False;
  O.DupParanoid := False;
  DefaultDupParams(O.Chunk);
  O.SeedKind := skRandom;
  O.Seed := 0;
  O.SeedInvalid := False;
  SetLength(O.Files, 0);
end;

procedure Bad(const A: AnsiString);
begin
  raise ECmdLine.Create('Invalid option: ' + A);
end;

procedure AddFile(var O: TOptions; const F: AnsiString);
begin
  SetLength(O.Files, Length(O.Files) + 1);
  O.Files[High(O.Files)] := F;
end;

{ -l, -c, -dl y -dc, con el tope MAX_LENGTH_OPTION (args.rs, length_option) }
function LengthOption(const A: AnsiString; N: QWord; const What: AnsiString): QWord;
begin
  if N > MAX_LENGTH_OPTION then
    raise ECmdLine.Create('Invalid option: ' + A + ' -- the ' + What + ' must be at most ' +
                          IntToStr(MAX_LENGTH_OPTION) + ' bytes');
  Result := AsUsize(N);
end;

procedure ParseDictPart(var O: TOptions; const Part: AnsiString);
var head, tail: AnsiString; n: QWord; x: Int64; ok: Boolean;
begin
  head := Copy(Part, 1, 1);
  tail := Copy(Part, 2, Length(Part));
  if head = 'a' then ok := ParseInt(tail, x)
  else if head = 'c' then
  begin
    ok := ParseMem(tail, uB, n);
    if ok then O.DictChunk := LengthOption('-d' + Part, n, 'dictionary chunk length');
  end
  else if head = 'l' then
  begin
    ok := ParseMem(tail, uB, n);
    if ok then O.DictMinMatch := LengthOption('-d' + Part, n, 'dictionary match length');
  end
  else if head = 'd' then begin ok := ParseMemOption(tail, uM, n); if ok then O.DictSize := n; end
  else if head = 'h' then begin ok := ParseMemOption(tail, uM, n); if ok then O.DictHashSize := n; end
  else begin ok := ParseMemOption(Part, uM, n); if ok then O.DictSize := n; end;
  if not ok then raise ECmdLine.Create('Invalid option: -d' + Part);
end;

{ `v.split(':')`: siempre al menos una parte, y ':' seguidos o en los
  extremos dan partes vacias }
procedure ParseDictParts(var O: TOptions; const V: AnsiString);
var start, k: LongInt;
begin
  start := 1;
  for k := 1 to Length(V) do
    if V[k] = ':' then
    begin
      ParseDictPart(O, Copy(V, start, k - start));
      start := k + 1;
    end;
  ParseDictPart(O, Copy(V, start, Length(V) - start + 1));
end;

procedure ParseArgs(const Args: array of AnsiString; out O: TOptions);
var
  i, j, slash, method: LongInt;
  a, v, body, accelS: AnsiString;
  n: QWord;
  x: Int64;
  ok: Boolean;
  m: AnsiChar;
begin
  DefaultOptions(O);
  i := 0;
  while i <= High(Args) do
  begin
    a := Args[i];
    if a = '--' then
    begin
      { no hay mas opciones; lo que queda son nombres }
      for j := i + 1 to High(Args) do AddFile(O, Args[j]);
      Break;
    end;

    { ---- las opciones del wrapper de -dup, que srep_main rechazaria ---- }
    if a = '-dup' then O.Dup := True
    else if a = '--dup-paranoid' then O.DupParanoid := True
    else if StartsWith(a, '--seed=') then
    begin
      if ParseSeed(After(a, '--seed='), n) then
      begin
        O.SeedKind := skValue;
        O.Seed := n;
      end
      else O.SeedInvalid := True;
    end
    else if StartsWith(a, '--chunk-avg=') then
    begin if not ParseUsize(After(a, '--chunk-avg='), O.Chunk.Avg) then Bad(a); end
    else if StartsWith(a, '--chunk-min=') then
    begin if not ParseUsize(After(a, '--chunk-min='), O.Chunk.MinChunk) then Bad(a); end
    else if StartsWith(a, '--chunk-max=') then
    begin if not ParseUsize(After(a, '--chunk-max='), O.Chunk.MaxChunk) then Bad(a); end
    else if StartsWith(a, '--chunk-buf=') then
    begin if not ParseUsize(After(a, '--chunk-buf='), O.Chunk.BufSize) then Bad(a); end
    else if StartsWith(a, '--chunk-hash=') then
    begin
      v := After(a, '--chunk-hash=');
      if v = 'fnv' then O.Chunk.HashAlgo := CDC_HASH_FNV
      else if v = 'gear' then O.Chunk.HashAlgo := CDC_HASH_GEAR
      else raise ECmdLine.Create('--chunk-hash must be ''fnv'' or ''gear''');
    end
    else if StartsWith(a, '--format=') then
    begin
      v := After(a, '--format=');
      if v = 'v4' then O.Format := fmtV4
      else if v = 'v5' then O.Format := fmtV5
      else Bad(a);
    end
    else if a = '-d' then O.CmdMode := cmDecompress
    else if a = '-i' then O.CmdMode := cmInfo
    else if a = '--verify' then O.CmdMode := cmVerify
    else if a = '-delete' then O.DeleteInput := True
    else if a = '-mmap' then O.UseMmap := True
    else if a = '-nommap' then O.UseMmap := False
    else if (a = '-s') or (a = '-s-') or (a = '-s+') or (StartsWith(a, '-s') and (Pos('.', a) > 0)) then
      O.StatsCadence := Copy(a, 3, Length(a))
    else if StartsWith(a, '-m') and (Length(a) >= 3) and (IsDigit(a[3]) or (a[3] = 'x')) then
    begin
      m := a[3];
      if m = 'x' then method := 5 else method := Ord(m) - Ord('0');
      ok := (method >= 0) and (method <= 5);
      if ok then
      begin
        v := Copy(a, 4, Length(a));
        if v = '' then O.Lz := lzIndex
        else if v = 'f' then O.Lz := lzFuture
        else if v = 'o' then O.Lz := lzIo
        else begin ok := False; O.Lz := lzIndex; end;
        if ok then O.Method := Byte(method);
      end;
      if not ok then
      begin
        { no era un metodo: el C++ lo relee como -mBYTES, "no guardar
          matches mas largos que esto" }
        if not ParseMem(Copy(a, 3, Length(a)), uB, n) or (n > High(DWord)) then Bad(a);
        O.MaximumSave := DWord(n);
      end;
    end
    else if a = '-f' then O.Lz := lzFuture
    else if a = '-a-' then O.Accel := 0
    else if StartsWith(a, '-a') and (Length(a) >= 3) and IsDigit(a[3]) then
    begin
      { -aN o -aN/M; los dos no cambian la salida, asi que solo se revisa la sintaxis }
      body := Copy(a, 3, Length(a));
      slash := Pos('/', body);
      if slash > 0 then accelS := Copy(body, 1, slash - 1) else accelS := body;
      if not ParseInt(accelS, x) then Bad(a);
      if (slash > 0) and not ParseInt(Copy(body, slash + 1, Length(body)), x) then Bad(a);
    end
    else if a = '-ia-' then O.IoAccelerator := -1
    else if a = '-ia+' then O.IoAccelerator := 1
    else if (a = '-slp') or (a = '-slp-') or (a = '-slp+') then
      { paginas grandes: una perilla del host, sin efecto en los bytes }
    else if (a = '-hash-') or (a = '-nomd5') then
    begin
      O.HasHash := True;
      O.Hash := '';
    end
    else if StartsWith(a, '-hash=') then
    begin
      { un nombre vacio elegiria sin querer el descriptor "sin checksums";
        para eso esta -hash- }
      v := After(a, '-hash=');
      if v = '' then Bad(a);
      O.HasHash := True;
      O.Hash := v;
    end
    else if StartsWith(a, '-vmfile=') then
    begin
      O.HasVmFile := True;
      O.VmFile := After(a, '-vmfile=');
    end
    else if StartsWith(a, '-vmblock=') then
    begin
      if not ParseMem(After(a, '-vmblock='), uM, O.VmBlock) then Bad(a);
    end
    else if a = '-v' then O.Verbosity := 1
    else if StartsWith(a, '-v') then
    begin
      if not ParseInt(After(a, '-v'), x) then Bad(a);
      O.Verbosity := LongInt(x);   { `as i32` }
    end
    else if StartsWith(a, '-pc') then
    begin
      { contadores de progreso, un diagnostico: se parsean, no se reportan }
      body := After(a, '-pc');
      if (body <> '') and not ParseMem(body, uM, n) then Bad(a);
    end
    else if StartsWith(a, '-index=') then O.IndexFile := After(a, '-index=')
    else if StartsWith(a, '-temp=') then
    begin
      O.HasTempFile := True;
      O.TempFile := After(a, '-temp=');
    end
    else if StartsWith(a, '-mem') then
    begin
      if not ParseMemOption(After(a, '-mem'), uM, O.VmMem) then Bad(a);
    end
    else if StartsWith(a, '-l') then
    begin
      if not ParseMem(After(a, '-l'), uB, n) then Bad(a);
      O.MinMatch := LengthOption(a, n, 'match length');
    end
    else if StartsWith(a, '-c') then
    begin
      if not ParseMem(After(a, '-c'), uB, n) then Bad(a);
      O.L := LengthOption(a, n, 'chunk length');
      { SliceHash divide por L / slices_in_block, que es 8: con L de 1 a 7
        eso es cero. El C++ muere con SIGFPE; aca es un error de linea de
        comandos. 0 es "no dado" y deja el default. }
      if (O.L > 0) and (O.L < SLICES_IN_BLOCK) then
        raise ECmdLine.Create('Invalid option: ' + a + ' -- the chunk length must be 0 (default) ' +
                              'or at least ' + IntToStr(SLICES_IN_BLOCK) + ' bytes');
    end
    else if StartsWith(a, '-s') then
    begin
      if not ParseMem(After(a, '-s'), uB, n) then Bad(a);
      O.HasDeclaredSize := True;
      O.DeclaredSize := n;
    end
    else if a = '-bar' then O.Bar := True
    else if StartsWith(a, '-b') then
    begin
      if not ParseMem(After(a, '-b'), uM, O.BufSize) then Bad(a);
    end
    else if a = '-d-' then O.DictSize := 0
    else if a = '-d+' then O.DictSize := 512 * MB
    else if StartsWith(a, '-d') then ParseDictParts(O, After(a, '-d'))
    else if StartsWith(a, '-t') then
    begin
      { aceptado e ignorado: la cantidad de hilos no cambia la salida }
      if not ParseInt(After(a, '-t'), x) then Bad(a);
      O.NumThreads := QWord(x);
    end
    else if StartsWith(a, '-rem') then
      { un comentario en la linea de comandos }
    else if StartsWith(a, '-') and (a <> '-') then Bad(a)
    else AddFile(O, a);
    Inc(i);
  end;
end;

end.
