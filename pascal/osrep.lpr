program osrep;
{ Omega SREP -- port a Pascal (FPC). Ver docs/pascal-port.md.

  Fase 7: la CLI completa, intercambiable con el binario Rust: las mismas
  opciones, los mismos bytes en el archivo, los mismos codigos de salida.
  src/cliargs.pas es args.rs, src/clireport.pas es report.rs, y este
  programa es main.rs mas modes.rs: las reglas de nombres, el spool de
  stdin/stdout, -delete, y los defaults con que se arma el encoder. }

{$MODE OBJFPC}{$H+}
{ IMAGE_FILE_LARGE_ADDRESS_AWARE en el .exe de 32 bits, como el i686 del
  Rust: sin el, Windows le da 2 GB de direcciones, y comprimir desde stdin sin
  -s dimensiona el match finder para 25 GiB y no entra ("Out of memory"). Con
  el, un Windows de 64 bits le da 4 GB. }
{$IFDEF WIN32}{$SETPEFLAGS $20}{$ENDIF}
{ DEP y ASLR, como los .exe de MinGW del Rust: NX_COMPAT ($100) y
  DYNAMIC_BASE ($40), mas HIGH_ENTROPY_VA ($20) en x64. FPC los deja en 0;
  DYNAMIC_BASE necesita la seccion .reloc, que build.sh pide con -WR. }
{$IFDEF WIN64}{$SETPEOPTFLAGS $160}{$ENDIF}
{$IFDEF WIN32}{$SETPEOPTFLAGS $140}{$ENDIF}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

uses
  { OsText primero: en Windows pone la RTL en UTF-8 al inicializarse, y
    tiene que ser antes que cualquier otra unidad (src/ostext.pas) }
  OsText,
  { Windows antes que SysUtils: trae su propio DeleteFile (con PChar) }
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  {$IFDEF UNIX} termio, BaseUnix, {$ENDIF}
  SysUtils, Classes,
  Widths, OutRaw, Hashes, Help, Container, Decompress, FutureLz, Encoder, FixedCompress,
  Dedup, DupWrap, DecFault,
  V5Verify, SpillFile, CliArgs, CliReport, RandBytes, StreamIO;

const
  { srep.cpp:45-51 }
  NO_ERRORS         = 0;
  WARNINGS          = 1;
  ERROR_CMDLINE     = 2;
  ERROR_IO          = 3;
  ERROR_COMPRESSION = 4;

type
  { lo que main imprime con la forma de error() }
  ERun = class(Exception)
  public
    Code: LongInt;
    constructor CreateCode(ACode: LongInt; const AMsg: AnsiString);
  end;

  { cuenta lo que pasa, para que el resumen sepa cuanto midio un archivo
    mandado a stdout: un archivo se mide despues, un pipe no. Con buffer: el
    encoder escribe de a pedazos chicos y cada uno seria una syscall. La
    unica posicion que contesta es la actual, que es lo que el segundo pase
    pregunta para el offset de la meta del v5. }
  TCountWriter = class(TStream)
  private
    FHandle: THandle;
    FCount: QWord;
    FBuf: array of Byte;
    FUsed: LongInt;
    FSawNewline: Boolean;
    procedure Drain;
  public
    constructor Create(AHandle: THandle);
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    procedure Flush;
    { si el stdout del Rust (un LineWriter de 1024 bytes) ya habria escrito
      algo al fd antes de terminar el encode: con un '\n' en lo escrito, o
      con 1024 bytes o mas. Si no, todo esperaba al flush final. }
    function RustWroteEarly: Boolean;
    property Written: QWord read FCount;
  end;

constructor ERun.CreateCode(ACode: LongInt; const AMsg: AnsiString);
begin
  inherited Create(AMsg);
  Code := ACode;
end;

procedure Fail(Code: LongInt; const Msg: AnsiString);
begin
  raise ERun.CreateCode(Code, Msg);
end;

constructor TCountWriter.Create(AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
  SetLength(FBuf, 1 shl 20);
  FUsed := 0;
end;

procedure TCountWriter.Drain;
var off, w: LongInt;
begin
  off := 0;
  while off < FUsed do
  begin
    w := FileWrite(FHandle, FBuf[off], FUsed - off);
    if w <= 0 then raise EWriteError.Create('Can''t write to stdout');
    Inc(off, w);
  end;
  FUsed := 0;
end;

function TCountWriter.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise EReadError.Create('stdout is write-only');
  Result := 0;
end;

function TCountWriter.Write(const Buffer; Count: LongInt): LongInt;
var p: PByte; n: LongInt;
begin
  Result := Count;
  p := @Buffer;
  if (not FSawNewline) and (Count > 0) then
    FSawNewline := IndexByte(p^, Count, 10) >= 0;
  while Count > 0 do
  begin
    n := Length(FBuf) - FUsed;
    if n > Count then n := Count;
    Move(p^, FBuf[FUsed], n);
    Inc(FUsed, n);
    Inc(p, n);
    Dec(Count, n);
    if FUsed = Length(FBuf) then Drain;
  end;
  Inc(FCount, QWord(Result));
end;

function TCountWriter.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then Exit(Int64(FCount));
  raise EStreamError.Create('stdout cannot seek');
end;

procedure TCountWriter.Flush;
begin
  Drain;
end;

function TCountWriter.RustWroteEarly: Boolean;
begin
  Result := FSawNewline or (FCount >= 1024);
end;

{ ------------------------------------------------------------ helpers --- }

function IsTerminal(H: THandle): Boolean;
{$IFDEF WINDOWS}
var mode: DWORD;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := IsATTY(H) = 1;
  {$ELSE}
  Result := GetConsoleMode(H, mode);
  {$ENDIF}
end;

function FileSizeOf(const Path: AnsiString): QWord;
var fs: TFileStream;
begin
  Result := 0;
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := QWord(fs.Size);
    finally
      fs.Free;
    end;
  except
    Result := 0;
  end;
end;

{ un temporal unico en $TMPDIR/%TEMP%, como TempFile::new; el que llama lo borra }
function NewTemp: AnsiString;
var s: TOwnedHandleStream;
begin
  s := CreateTempExclusive('osrep-data', Result);
  if s = nil then Fail(ERROR_IO, 'Can''t allocate a unique tempfile under $TMPDIR/%TEMP%');
  s.Free;
end;

procedure CopyStdinTo(const Path: AnsiString);
var f: TFileStream; buf: array of Byte; n: LongInt;
begin
  try
    f := TFileStream.Create(Path, fmCreate);
  except
    Fail(ERROR_IO, 'Can''t open tempfile');
  end;
  try
    SetLength(buf, 1 shl 20);
    repeat
      n := FileRead(InHandle, buf[0], Length(buf));
      if n < 0 then Fail(ERROR_IO, 'Can''t read from input file');
      { el std::io::copy del Rust falla igual al leer o al escribir, y los dos
        dan el mismo texto: con el disco lleno tambien es "Can't read" }
      if n > 0 then
        try
          f.WriteBuffer(buf[0], n);
        except
          Fail(ERROR_IO, 'Can''t read from input file');
        end;
    until n = 0;
  finally
    f.Free;
  end;
end;

function ReadAllStdin: TBytes;
var n: LongInt; used, room: SizeInt;
begin
  SetLength(Result, 1 shl 20);
  used := 0;
  repeat
    if used = Length(Result) then SetLength(Result, Length(Result) * 2);
    { FileRead toma LongInt: pasado 2 GiB la cuenta truncada saldria negativa }
    room := Length(Result) - used;
    if room > SizeInt(IO_SLICE) then room := SizeInt(IO_SLICE);
    n := FileRead(InHandle, Result[used], LongInt(room));
    if n < 0 then Fail(ERROR_IO, 'Can''t read from stdin');
    Inc(used, n);
  until n = 0;
  SetLength(Result, used);
end;

function ReadAllFile(const Path: AnsiString): TBytes;
var fs: TFileStream;
begin
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then ReadExact(fs, Result[0], QWord(fs.Size));
    finally
      fs.Free;
    end;
  except
    on X: ERun do raise;
    on X: Exception do Fail(ERROR_IO, 'Can''t open ' + Path + ' for read');
  end;
end;

function ReadArchive(const FiName: AnsiString): TBytes;
begin
  if FiName = '-' then Result := ReadAllStdin else Result := ReadAllFile(FiName);
end;

{ ----------------------------------------------------------- progress --- }

var
  GBar: TBar;
  GStats: TStats;

procedure OnProgress(Done, Total: QWord);
begin
  BarTick(GBar, Done, Total);
  StatsTick(GStats, Done, Total);
end;

{ -------------------------------------------------------------- names --- }

{ srep.cpp:477: sin entrada ninguna, la sinopsis por stdout y exito }
function WantsHelp(const O: TOptions): Boolean;
begin
  Result := (Length(O.Files) = 0) and (IsTerminal(InHandle) or IsTerminal(OutHandle));
end;

{ las reglas de nombres (srep.cpp:569-583). Con un nombre, la extension .osr
  decide la direccion y el otro sale de el; sin ninguno, con las dos puntas
  redirigidas, es stdin/stdout. }
procedure ResolveNames(const O: TOptions; out FiName, FoutName: AnsiString);
var files: array of AnsiString; i: LongInt;
begin
  SetLength(files, Length(O.Files));
  for i := 0 to High(O.Files) do files[i] := O.Files[i];
  if (Length(files) = 0) and not IsTerminal(InHandle) and not IsTerminal(OutHandle) then
  begin
    SetLength(files, 2);
    files[0] := '-';
    files[1] := '-';
  end;
  if (O.CmdMode in [cmInfo, cmVerify]) and (Length(files) > 1) then
    Fail(ERROR_CMDLINE, 'Too much filenames: ' + files[0] + ' ' + files[1]);
  if Length(files) > 2 then
    Fail(ERROR_CMDLINE, 'Too much filenames: ' + files[0] + ' ' + files[1] + ' ' + files[2]);
  if Length(files) = 0 then Fail(ERROR_CMDLINE, 'No input file');

  FiName := files[0];
  if (Length(files) > 1) and not (O.CmdMode in [cmInfo, cmVerify]) then FoutName := files[1]
  else if (Length(FiName) >= 4) and (Copy(FiName, Length(FiName) - 3, 4) = '.osr') then
    FoutName := Copy(FiName, 1, Length(FiName) - 4)
  else
    FoutName := FiName + '.osr';

  if (FiName <> '-') and (FoutName = FiName) then
    Fail(ERROR_IO, 'Input and output files should have different names');
end;

{ -------------------------------------------------------- compression --- }

function KindOf(const O: TOptions): TEncKind;
begin
  case O.Method of
    0: Result := ekInmem;
    1: Result := ekCdc;
    2: Result := ekCdcZpaq;
    3: Result := ekDigest;
    4: Result := ekFixed;
  else Result := ekFixedExhaustive;
  end;
end;

function ContainerOf(const O: TOptions): TEncContainer;
begin
  if O.Format = fmtV5 then Exit(ecV5);
  case O.Lz of
    lzIndex: Result := ecIndexLz;
    lzFuture: Result := ecFutureLz;
  else Result := ecIoLz;
  end;
end;

function DecodeHex(const S: AnsiString; out B: TBytes): Boolean;
var i: LongInt; hi, lo: LongInt;
  function Nib(C: AnsiChar): LongInt;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else Result := -1;
    end;
  end;
begin
  Result := False;
  if Length(S) mod 2 <> 0 then Exit;
  SetLength(B, Length(S) div 2);
  for i := 0 to Length(B) - 1 do
  begin
    hi := Nib(S[2 * i + 1]);
    lo := Nib(S[2 * i + 2]);
    if (hi < 0) or (lo < 0) then Exit;
    B[i] := Byte(hi * 16 + lo);
  end;
  Result := True;
end;

{ de donde sale la clave del archivo, en el orden del C++ (srep.cpp:646-652):
  OSREP_SEED_HEX primero, despues --seed=N, despues una por corrida. Un
  OSREP_SEED_HEX mal formado se ignora, como en el C++. }
procedure ResolveSeed(const O: TOptions; var E: TEncodeOptions);
var h: THashInfo; size: LongInt; hex: AnsiString; b: TBytes;
begin
  E.HasSeed := O.SeedKind = skValue;
  E.Seed := O.Seed;
  E.SeedBytes := nil;
  if HashByName(E.Hash, h) then size := h.SeedSize else size := 0;
  { los hashes sin clave (md5/sha1/sha512, -hash-) no llevan semilla }
  if size = 0 then Exit;
  { env::var: en Windows leida en UTF-16; la de FPC iba por
    GetEnvironmentStringsA, y la conversion "best fit" a ANSI puede hacer
    hexadecimal lo que no lo es (U+FF41, la a de ancho completo, sale 'a') }
  if not EnvUtf8('OSREP_SEED_HEX', hex) then hex := '';
  if (Length(hex) = size * 2) and DecodeHex(hex, b) then
  begin
    E.SeedBytes := b;
    Exit;
  end;
  if O.SeedKind = skRandom then E.SeedBytes := RandomBytes(size);
end;

procedure EncodeOptionsOf(const O: TOptions; HasDeclared: Boolean; Declared: QWord;
                          out E: TEncodeOptions);
begin
  DefaultEncodeOptions(E);
  E.BufSize := QWord(PtrUInt(O.BufSize));
  { srep.cpp:445: -m0 sin -d toma los 512 mb por defecto }
  if (O.Method = 0) and (O.DictSize = 0) then E.DictSize := 512 * MB else E.DictSize := O.DictSize;
  E.DictHashSize := O.DictHashSize;
  E.MinMatch := O.MinMatch;
  E.DictMinMatch := O.DictMinMatch;
  E.DictChunk := O.DictChunk;
  E.L := O.L;
  if O.HasHash then E.Hash := O.Hash else E.Hash := 'vmac';
  E.HasDeclaredSize := HasDeclared;
  E.DeclaredSize := Declared;
  ResolveSeed(O, E);
end;

{ el spool de stdin, cuando el encoder necesita una entrada que se pueda
  releer. Devuelve el camino a leer; Owned dice si hay que borrarlo. }
function SpoolStdin(const O: TOptions; out Owned: Boolean): AnsiString;
begin
  Owned := False;
  if O.HasTempFile and (O.TempFile = '') then
    Fail(ERROR_IO, 'Reading data to compress from stdin without tempfile isn''t supported for this method');
  if O.HasTempFile then
  begin
    CopyStdinTo(O.TempFile);
    Exit(O.TempFile);
  end;
  Result := NewTemp;
  Owned := True;
  try
    CopyStdinTo(Result);
  except
    DeleteFile(Result);
    raise;
  end;
end;

procedure DupFail(X: Exception);
var m: AnsiString;
begin
  m := X.Message;
  if m = 'IncompatibleMethod' then Fail(ERROR_CMDLINE, '-dup is incompatible with -m0; use -m3/-m4/-m5');
  if m = 'UnsupportedContainer' then Fail(ERROR_CMDLINE, '-dup needs the default (Index-LZ) or v5 container');
  if m = 'BadDup' then Fail(ERROR_COMPRESSION, 'the -dup meta is missing or corrupt');
  if (Copy(m, 1, 6) = 'Dedup(') and (Length(m) > 7) then
    Fail(ERROR_COMPRESSION, 'dedup failed, rc=' + Copy(m, 7, Length(m) - 7));
  if X is EEncode then Fail(ERROR_IO, 'Encode(' + m + ')');
  if X is EDup then Fail(ERROR_IO, m);
  Fail(ERROR_IO, 'Io');
end;

(* `format!("{e:?}")` de un EncodeError: los EEncode ya traen el Debug; toda
  falla de E/S es EncodeError::Io en el Rust (From<io::Error>), sin detalle *)
function EncodeErrorText(X: Exception): AnsiString;
begin
  if X is EEncode then Exit(X.Message);
  if IsIoException(X) then Exit('Io');
  Result := X.Message;
end;

{ Sin -c, -l tambien fija el L del match finder (srep.cpp:466-470): L =
  MIN_MATCH con -m1..-m4, y con -m5 la potencia de dos debajo de MIN_MATCH+1,
  partida al medio. SliceHash divide despues por L div 8, asi que un L de 1 a
  7 es la misma division por cero por la que cliargs rechaza -c1..-c7: el C++
  muere con SIGFPE y aca salia "Division by zero" con codigo 4. Por eso -l1..-l7
  no valen con -m1..-m4, ni -l1..-l14 con -m5; -m0 no arma la tabla y acepta
  cualquier -l. Devuelve '' si el -l sirve (modes.rs, small_window). }
function SmallWindow(const O: TOptions): AnsiString;
var least: QWord;
begin
  Result := '';
  if (O.L <> 0) or (O.MinMatch = 0) or (O.Method < 1) or (O.Method > 5) then Exit;
  if O.Method = 5 then least := 2 * SLICES_IN_BLOCK - 1 else least := SLICES_IN_BLOCK;
  if O.MinMatch >= least then Exit;
  Result := 'Invalid option: -l' + IntToStr(O.MinMatch) + ' -- with -m' + IntToStr(O.Method) +
            ' the match length must be 0 (default) or at least ' + IntToStr(least) + ' bytes';
end;

function Compress(const O: TOptions; const FiName, FoutName: AnsiString): LongInt;
var
  warnings: LongInt;
  window: QWord;
  inputPath: AnsiString;
  spoolOwned, hasDeclared: Boolean;
  declared, read_, written: QWord;
  enc: TEncodeOptions;
  indexS: TFileStream;
  inS, outS: TFileStream;
  cw: TCountWriter;
  dp: TDupParams;
  dm: TDupMode;
begin
  if O.Dup and ((O.Method = 1) or (O.Method = 2)) then
    WriteErr('  WARNING: -dup with -m' + IntToStr(O.Method) +
             ' does CDC twice; -m3/-m4/-m5 recommended' + #10);
  if O.Dup and ((FiName = '-') or (FoutName = '-')) then
    Fail(ERROR_CMDLINE, '-dup mode does not support stdin/stdout');
  { srep.cpp:446: el chunking por contenido y el diccionario en memoria no se mezclan }
  if ((O.Method = 1) or (O.Method = 2)) and (O.DictSize <> 0) then
    Fail(ERROR_CMDLINE, 'Incompatible options: -m' + IntToStr(O.Method) + ' -d' + ShowMem(O.DictSize, True));
  if SmallWindow(O) <> '' then Fail(ERROR_CMDLINE, SmallWindow(O));

  { srep.cpp:459-462: la ventana tiene que ser potencia de dos. Es -c si se
    dio, -l si no; CDC y -m5 nunca pueden fallar la prueba. }
  warnings := 0;
  window := 0;
  if not (O.Method in [1, 2, 5]) then
    if O.L <> 0 then window := O.L
    else if O.MinMatch <> 0 then window := O.MinMatch;
  if (window <> 0) and ((window and (window - 1)) <> 0) then
  begin
    WriteErr('Warning: -l parameter should be power of 2, otherwise compressed file may be corrupt' + #10);
    Inc(warnings);
  end;

  spoolOwned := False;
  if FiName = '-' then inputPath := SpoolStdin(O, spoolOwned) else inputPath := FiName;
  try
    { con '-' el tamano no se puede medir al leer, asi que vale el declarado
      (o el default): la rama finame == "-" del C++ }
    hasDeclared := FiName = '-';
    if O.HasDeclaredSize then declared := O.DeclaredSize else declared := DEFAULT_STDIN_FILESIZE;
    if not hasDeclared then declared := 0;
    { -s es una promesa sobre el tamano, y el match finder se dimensiona con
      ella: una entrada que la rompe desborda la tabla. Se revisa aca ademas
      del encoder para que el mensaje nombre la opcion. }
    if hasDeclared and (FileSizeOf(inputPath) > declared) then
      Fail(ERROR_CMDLINE, '-s' + IntToStr(declared) + ' is smaller than the ' +
           IntToStr(FileSizeOf(inputPath)) + ' bytes read from stdin; ' +
           'give the real size or leave -s out');
    EncodeOptionsOf(O, hasDeclared, declared, enc);

    BarInit(GBar, O.Bar);
    StatsInit(GStats, O.Verbosity > 0);
    if O.Dup or not hasDeclared then read_ := FileSizeOf(inputPath) else read_ := declared;

    { srep.cpp:606: el indice se abre antes de la corrida, asi un camino malo
      falla antes de hacer nada }
    indexS := nil;
    inS := nil;
    outS := nil;
    cw := nil;
    try
      if O.IndexFile <> '' then
      begin
        try
          indexS := TFileStream.Create(O.IndexFile, fmCreate);
        except
          Fail(ERROR_IO, 'Can''t open index file ' + O.IndexFile + ' for write');
        end;
        enc.Index := indexS;
      end;

      if O.Dup then
      begin
        if O.Format = fmtV5 then dm := dmV5 else dm := dmV4;
        dp := O.Chunk;
        try
          DupEncode(inputPath, FoutName, enc, KindOf(O), ContainerOf(O), dp, O.DupParanoid, dm,
                    @OnProgress);
        except
          on X: ERun do raise;
          on X: Exception do DupFail(X);
        end;
        written := FileSizeOf(FoutName);
      end
      else
      begin
        try
          inS := TFileStream.Create(inputPath, fmOpenRead or fmShareDenyNone);
        except
          Fail(ERROR_IO, 'Can''t open ' + FiName + ' for read');
        end;
        { '-' es stdout, no un archivo que se llama "-" }
        if FoutName = '-' then
        begin
          cw := TCountWriter.Create(OutHandle);
          try
            Encode(inS, cw, enc, KindOf(O), ContainerOf(O), @OnProgress);
          except
            on X: ERun do raise;
            on X: Exception do Fail(ERROR_COMPRESSION, EncodeErrorText(X));
          end;
          { El Rust escribe por un LineWriter: lo que no entro en el flush
            final ya fue al fd DURANTE el encode, y una falla ahi es un
            EncodeError::Io. Este buffer es mas grande, asi que la falla
            puede llegar recien aca; se reporta donde la veria el Rust. }
          try
            cw.Flush;
          except
            if cw.RustWroteEarly then Fail(ERROR_COMPRESSION, 'Io')
            else Fail(ERROR_IO, 'Can''t write to stdout');
          end;
          written := cw.Written;
        end
        else
        begin
          try
            outS := TFileStream.Create(FoutName, fmCreate);
          except
            Fail(ERROR_IO, 'Can''t open ' + FoutName + ' for write');
          end;
          try
            Encode(inS, outS, enc, KindOf(O), ContainerOf(O), @OnProgress);
          except
            on X: ERun do raise;
            on X: Exception do Fail(ERROR_COMPRESSION, EncodeErrorText(X));
          end;
          written := QWord(outS.Seek(0, soEnd));
        end;
      end;
    finally
      cw.Free;
      outS.Free;
      inS.Free;
      indexS.Free;
    end;

    StatsFinish(GStats, read_, written);
  finally
    if spoolOwned then DeleteFile(inputPath);
  end;
  if (warnings = 0) and O.DeleteInput then DeleteFile(FiName);
  if warnings > 0 then Result := WARNINGS else Result := NO_ERRORS;
end;

{ ------------------------------------------------------ decompression --- }

{ srep.cpp:475: el tope de los matches guardados tiene su propio tope, asi un
  match enorme toma el camino de "releer de la salida" en vez de anular el
  desalojo del derrame }
procedure DecodeOptionsOf(const O: TOptions; out D: TFutureLzOptions);
begin
  DefaultFutureLzOptions(D);
  D.MemLimit := O.VmMem;
  D.VmBlock := O.VmBlock;
  if (O.VmBlock > 24) and (QWord(O.MaximumSave) > O.VmBlock - 24) then
    D.MaximumSave := DWord(O.VmBlock - 24)
  else
    D.MaximumSave := O.MaximumSave;
  D.HasVmFile := O.HasVmFile;
  D.VmFile := O.VmFile;
end;

{$IFDEF UNIX}
{ Un directorio como entrada de -d. El FileOpen de FPC rechaza los
  directorios; el File::open del Rust en Unix no: abre, y lo que falla despues
  es el seek o el read, con un error distinto segun el sistema de archivos
  (ext4 da un largo enorme al seek, tmpfs da EINVAL, /proc da 0). Se recorre
  el mismo camino que el Rust con las mismas llamadas, para dar su error: el
  sniff de -dup (dup.rs: Io si falla el seek, Truncated si falla el read) y
  despues archive::decode (el Io(Os ..) del seek o del read). }
procedure DirectoryInput(const O: TOptions; const FiName, FoutName: AnsiString);
var fd: cint; len: Int64; b: array[0..15] of Byte; seekErr, readErr: LongInt;
    t: TFileStream;
begin
  fd := fpOpen(PChar(FiName), O_RDONLY);
  if fd < 0 then Exit;            { tampoco el Rust lo abre: el camino de siempre }
  len := fpLseek(fd, 0, Seek_End);
  seekErr := 0;
  if len < 0 then seekErr := fpgeterrno;
  readErr := 0;
  if len >= 0 then
  begin
    fpLseek(fd, 0, Seek_Set);
    if fpRead(fd, b[0], SizeOf(b)) < 0 then readErr := fpgeterrno;
  end;
  fpClose(fd);
  if readErr = 0 then readErr := 21;   { EISDIR, lo que da todo read de un directorio }
  if FoutName <> '-' then
  begin
    { dup::decode: seek(End)? es Io; con 12 bytes o mas lee la cola (read_exact_at,
      que da Truncated) }
    if len < 0 then Fail(ERROR_IO, 'Io');
    if len >= 12 then Fail(ERROR_IO, 'Truncated');
    try
      t := TFileStream.Create(FoutName, fmCreate);
      t.Free;
    except
      Fail(ERROR_IO, 'Can''t open ' + FoutName + ' for write');
    end;
  end;
  if O.IndexFile <> '' then
    if not (FileExists(O.IndexFile) or DirectoryExists(O.IndexFile)) then
      Fail(ERROR_IO, 'Can''t open index file ' + O.IndexFile + ' for read');
  if len < 0 then Fail(ERROR_COMPRESSION, FaultDebug(FaultOs(seekErr)) + ': ' + FiName);
  Fail(ERROR_COMPRESSION, FaultDebug(FaultOs(readErr)) + ': ' + FiName);
end;
{$ENDIF}

function Decompress(const O: TOptions; const FiName, FoutName: AnsiString): LongInt;
var
  opts: TFutureLzOptions;
  isDup: Boolean;
  inputPath, sinkPath, stdinSpool, stdoutSpool: AnsiString;
  err: TDecodeFault;
  inS, sink, f: TFileStream;
  indexS: TStream;
{$IFDEF UNIX}
  ixfd: cint;
{$ENDIF}
  total, decoded: QWord;
  ok: Boolean;
  buf: array of Byte;
  n, off, w: LongInt;
begin
  DecodeOptionsOf(O, opts);
{$IFDEF UNIX}
  if (FiName <> '-') and DirectoryExists(FiName) then DirectoryInput(O, FiName, FoutName);
{$ENDIF}

  { -dup primero: el C++ lo detecta en cada descompresion, con o sin la
    opcion. Reescribe la cola del archivo, asi que necesita dos archivos de
    verdad. }
  if (FiName <> '-') and (FoutName <> '-') then
  begin
    isDup := False;
    try
      isDup := DupDecode(FiName, FoutName, opts);
    except
      on X: Exception do DupFail(X);
    end;
    if isDup then
    begin
      if O.DeleteInput then DeleteFile(FiName);
      Exit(NO_ERRORS);
    end;
  end;

  stdinSpool := '';
  stdoutSpool := '';
  inS := nil;
  sink := nil;
  indexS := nil;
  try
    { '-' es stdin, y el decoder hace seek sobre su entrada, asi que stdin se
      vuelca a un temporal antes de parsear nada }
    if FiName = '-' then
    begin
      stdinSpool := NewTemp;
      CopyStdinTo(stdinSpool);
      inputPath := stdinSpool;
    end
    else inputPath := FiName;

    try
      inS := TFileStream.Create(inputPath, fmOpenRead or fmShareDenyNone);
    except
      Fail(ERROR_IO, 'Can''t open ' + FiName + ' for read');
    end;
    total := QWord(inS.Size);

    BarInit(GBar, O.Bar);
    StatsInit(GStats, O.Verbosity > 0);

    { el decoder relee lo que ya escribio, asi que la salida es un archivo
      siempre; si la de verdad es stdout, es uno temporal que se copia al
      final (srep.cpp:1150-1162, la misma idea) }
    if FoutName = '-' then
    begin
      stdoutSpool := NewTemp;
      sinkPath := stdoutSpool;
    end
    else sinkPath := FoutName;
    try
      sink := TFileStream.Create(sinkPath, fmCreate);
    except
      Fail(ERROR_IO, 'Can''t open ' + FoutName + ' for write');
    end;

    { -index= de vuelta: las listas salen del archivo nombrado }
    if O.IndexFile <> '' then
      try
      begin
{$IFDEF UNIX}
        { un directorio: el File::open del Rust lo abre y falla al leerlo
          (un Io(Os) con EISDIR), o no lo lee nunca si el archivo no usa el
          indice. FileOpen lo rechazaria antes. }
        if DirectoryExists(O.IndexFile) then
        begin
          ixfd := fpOpen(PChar(O.IndexFile), O_RDONLY);
          if ixfd < 0 then raise EFOpenError.Create(O.IndexFile);
          indexS := TOwnedHandleStream.Create(ixfd);
        end
        else
{$ENDIF}
        indexS := TFileStream.Create(O.IndexFile, fmOpenRead or fmShareDenyNone);
      end
      except
        Fail(ERROR_IO, 'Can''t open index file ' + O.IndexFile + ' for read');
      end;

    { un rechazo es una salida limpia distinta de cero: nunca un crash ni un
      cuelgue, que es lo que asertan los tests de corrupcion }
    try
      ok := DecodeArchive(inS, sink, opts, indexS, err, @OnProgress);
    except
      on X: ERun do raise;
      on X: Exception do begin ok := False; err := FaultOfException(X); end;
    end;
    (* el Debug del DecodeError, como modes.rs: `format!("{e:?}: {finame}")` *)
    if not ok then Fail(ERROR_COMPRESSION, FaultDebug(err) + ': ' + FiName);
    decoded := QWord(sink.Seek(0, soEnd));
    FreeAndNil(sink);

    if stdoutSpool <> '' then
    begin
      f := TFileStream.Create(stdoutSpool, fmOpenRead or fmShareDenyNone);
      try
        SetLength(buf, 1 shl 20);
        repeat
          n := f.Read(buf[0], Length(buf));
          off := 0;
          while off < n do
          begin
            w := FileWrite(OutHandle, buf[off], n - off);
            if w <= 0 then Fail(ERROR_IO, 'Can''t write to stdout');
            Inc(off, w);
          end;
        until n <= 0;
      finally
        f.Free;
      end;
    end;

    StatsFinish(GStats, total, decoded);
  finally
    indexS.Free;
    sink.Free;
    inS.Free;
    if stdinSpool <> '' then DeleteFile(stdinSpool);
    if stdoutSpool <> '' then DeleteFile(stdoutSpool);
  end;
  if O.DeleteInput and (FiName <> '-') then DeleteFile(FiName);
  Result := NO_ERRORS;
end;

{ --------------------------------------------------------------- info --- }

{ --verify: decir si un archivo esta sano SIN reconstruirlo. Solo v5 puede
  contestarlo: v4 no lleva checksum en ningun lado. La salida dice que NO se
  reviso, a proposito: nada en v5 cubre los bytes guardados de los bloques. }
function Verify(const FiName: AnsiString): LongInt;
var b: TBytes; r: TVerifyReport; dup, digests: AnsiString;
begin
  b := ReadArchive(FiName);
  if not ((Length(b) >= 4) and IsV5(b)) then
  begin
    { "un contenedor que no se puede verificar" contra "no es un archivo":
      el consejo es distinto }
    if InspectV14(b) then
      Fail(ERROR_CMDLINE, FiName + ' is a v1-v4 archive, which carries no checksum anywhere, so it cannot be ' +
           'verified without reconstructing it. Decompress it to check it (the per-block ' +
           'digests are verified on the way), or re-create it with --format=v5')
    else
      Fail(ERROR_COMPRESSION, 'Not an Omega SREP compressed file (.osr): ' + FiName);
  end;
  try
    VerifyV5(b, r);
  except
    on X: EV5 do Fail(ERROR_COMPRESSION, FiName + ' is damaged: ' + X.Message);
  end;
  if r.HasDupMeta then dup := ', -dup meta checksummed' else dup := '';
  if r.HasBlockDigests then digests := ' (where the per-block digests catch it)' else digests := '';
  WriteErr(FiName + ': v5 archive intact. ' + IntToStr(r.Blocks) + ' blocks, ' + IntToStr(r.Records) +
           ' records, ' + IntToStr(r.OriginalSize) + ' bytes of original data' + dup + '.' + #10);
  WriteErr('  Checked without decompressing: header, footer and meta CRC-32C, framing, ' +
           'block count, every record, and that the file ends where the footer says.' + #10);
  WriteErr('  Not checked: the stored block bytes carry no checksum, so damage inside a ' +
           'literal run needs a decompress' + digests + '.' + #10);
  Result := NO_ERRORS;
end;

function Info(const O: TOptions; const FiName: AnsiString): LongInt;
var opts: TFutureLzOptions; b: TBytes; ai: TArchiveInfo; head: AnsiString; pct: Double;
begin
  DecodeOptionsOf(O, opts);
  b := ReadArchive(FiName);
  if not Inspect(b, ai) then
    Fail(ERROR_COMPRESSION, 'Not an Omega SREP compressed file (.osr): ' + FiName);

  head := ai.Mode + ':';
  if ai.BaseLen <> 0 then head := head + ' -l' + IntToStr(ai.BaseLen);
  head := head + ' -hash=' + ai.HashName;
  { Index-LZ deja la linea abierta para el tamano que sigue; los demas la
    cierran aca (srep.cpp:1074-1075) }
  if ai.Mode = 'Index-LZ' then WriteErr(head) else WriteErr(head + #10);

  { el C++ llega a la linea del tamano solo con Index-LZ; v5 trae la misma
    respuesta en su header, asi que lleva la misma linea }
  if (ai.Mode = 'Index-LZ') or (ai.Mode = 'v5') then
  begin
    pct := PercentOf(ai.CompSize, ai.OrigSize);
    WriteErr('.  ' + Show3(ai.OrigSize) + ' -> ' + Show3(ai.CompSize) + ': ' + Fixed(pct, 2) + '%' + #10);
    { el C++ reporta el pico de RAM que necesitaria su derrame; el port no
      mide un pico, asi que ese campo es un marcador. El resto es real. }
    PrintInfo('', 0, opts.MaximumSave <> High(DWord), opts.MaximumSave, ai.StatSize, False, ai.CompSize);
    WriteErr(#10);
  end;
  Result := NO_ERRORS;
end;

{ --------------------------------------------------------------- main --- }

function Run(const O: TOptions): LongInt;
var fi, fo: AnsiString;
begin
  { -index= saca las listas de matches a un segundo archivo (srep.cpp:606).
    Solo los dos contenedores que las emiten desde el segundo pase pueden.
    El C++ acepta la opcion igual y escribe un archivo que no puede releer:
    perdida silenciosa, asi que se rechaza la combinacion. }
  if (O.IndexFile <> '') and (O.CmdMode = cmCompress) then
  begin
    if O.Format = fmtV5 then
      Fail(ERROR_CMDLINE, '-index= is a v4 feature: the v5 footer locates everything by ' +
           'offset, so the lists cannot move out. Use --format=v4');
    if O.Lz = lzIndex then
      Fail(ERROR_CMDLINE, '-index= needs -mNf or -mNo: the default (Index-LZ) container ' +
           'reads its match lists from the archive, so an archive written ' +
           'with an index could not be decompressed');
  end;
  if O.Dup and O.SeedInvalid then
    Fail(ERROR_CMDLINE, '--seed= needs an integer (decimal or 0x-prefixed hex)');
  if O.Dup and (O.Method = 0) then
    Fail(ERROR_CMDLINE, '-dup is incompatible with -m0; use -m3/-m4/-m5');

  ResolveNames(O, fi, fo);
  case O.CmdMode of
    cmInfo: Result := Info(O, fi);
    cmVerify: Result := Verify(fi);
    cmCompress: Result := Compress(O, fi, fo);
  else Result := Decompress(O, fi, fo);
  end;
end;

{ error() (io.cpp:9-19) }
function Report(Code: LongInt; const Msg: AnsiString): LongInt;
begin
  WriteErr(#10 + '  ERROR! ' + Msg + #10);
  Result := Code;
end;

function Main: LongInt;
var
  argv: TArgv;
  i: LongInt;
  a, panic: AnsiString;
  o: TOptions;
begin
  { en Windows, de GetCommandLineW y en UTF-8, partida como la parte el
    Rust; un argumento que no es UTF-16 valido es el panico de env::args() }
  if not OsArgs(argv, panic) then
  begin
    WriteErr(panic);
    Exit(PANIC_EXIT);
  end;

  { --version y --help se contestan antes de que corra ningun parser
    (dup_wrapper.cpp:477-488), porque el parser principal rechaza todo lo
    que empieza con -- }
  for i := 0 to High(argv) do
  begin
    a := argv[i];
    if (a = '--version') or (a = '-V') then
    begin
      WriteOut(VersionLine + #10);
      Exit(NO_ERRORS);
    end;
    if (a = '--help') or (a = '-h') or (a = '-?') then
    begin
      WriteOut(HelpText);
      Exit(NO_ERRORS);
    end;
  end;

  try
    ParseArgs(argv, o);
  except
    on X: ECmdLine do Exit(Report(ERROR_CMDLINE, X.Message));
  end;

  if WantsHelp(o) then
  begin
    WriteOut(HelpText);
    Exit(NO_ERRORS);
  end;

  try
    Result := Run(o);
  except
    on X: ERun do Result := Report(X.Code, X.Message);
    on X: Exception do Result := Report(ERROR_IO, X.Message);
  end;
end;

begin
  ExitCode := Main;
end.
