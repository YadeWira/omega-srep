unit OsText;
{ El texto que cruza la frontera con el sistema operativo: argumentos,
  variables de entorno, el directorio temporal y lo que se escribe a una
  consola. Todo adentro del programa es UTF-8, en las dos plataformas.

  En Linux no hay nada que convertir: argumentos, entorno y nombres de
  archivo son bytes, y pasan tal cual, como en el Rust.

  En Windows el sistema habla UTF-16 y la RTL de FPC 3.2.2, por defecto, la
  pagina de codigos ANSI (cp1252, cp866, cp936...): ParamStr sale de
  GetCommandLineA, GetEnvironmentVariable de GetEnvironmentStringsA (en OEM),
  y un AnsiString se pasa a UnicodeString con la pagina con la que esta
  etiquetado. Un nombre fuera de la pagina ANSI llegaba como '?' y "Can't
  open" con un nombre que no existe. El Rust no tiene el problema: lee la
  linea con GetCommandLineW, todo es WTF-8 adentro, y abre con CreateFileW.

  Lo que hace esta unidad en Windows (docs/pascal-port.md, trampas):

    * Al inicializar fija DefaultSystemCodePage (y la del sistema de
      archivos de la RTL) en CP_UTF8. Desde ahi cada AnsiString nuevo queda
      etiquetado UTF-8, y la RTL lo convierte a UTF-16 con MultiByteToWideChar
      (CP_UTF8) en cada llamada de archivo: TFileStream.Create, FileOpen,
      FileCreate, DeleteFile, RenameFile y FileExists van a las versiones
      RawByteString de sysutils, que hacen UnicodeString(nombre) y llaman a
      CreateFileW/DeleteFileW/MoveFileW (rtl/objpas/sysutils/filutil.inc,
      rtl/win/sysutils.pp). Sin esto, ademas, asignar un UTF8String a un
      AnsiString lo convertia a ANSI y perdia los caracteres.
      Por eso esta unidad no usa SysUtils: tiene que inicializarse ANTES que
      el resto, y va primera en el uses de cada programa.
    * Los argumentos salen de GetCommandLineW, partidos con el MISMO parser
      que el std del Rust (sys/windows/args.rs, parse_lp_cmd_line), no con
      CommandLineToArgvW, que difiere en argv[0] y en algunas comillas.
    * Un argumento que no es UTF-16 valido (un surrogate suelto) hace que el
      Rust, que usa env::args(), entre en panico: exit 101 y un mensaje fijo.
      Se reproduce tal cual.
    * El entorno se lee con GetEnvironmentVariableW, y el temporal con
      GetTempPathW, como std::env::temp_dir (TMP antes que TEMP; el
      GetTempDir de FPC miraba TEMP primero y en ANSI).
    * A una consola se le escribe con WriteConsoleW, como el std del Rust;
      a un pipe o un archivo van los bytes UTF-8 sin tocar. }

{$MODE OBJFPC}{$H+}
interface

type
  TArgv = array of AnsiString;
  TWideArgs = array of UnicodeString;

{ Los argumentos sin el nombre del programa, en UTF-8. False si alguno no es
  UTF-16 valido; entonces Panic trae lo que el Rust escribe a stderr, y el
  codigo de salida es PANIC_EXIT. En Unix nunca falla. }
function OsArgs(out Argv: TArgv; out Panic: AnsiString): Boolean;

const
  PANIC_EXIT = 101;

{ Para las herramientas de prueba: ParamCount/ParamStr, pero en UTF-8 }
function ArgCount: LongInt;
function ArgStr(I: LongInt): AnsiString;

{ parse_lp_cmd_line: la linea de comandos partida como la parte el Rust,
  argv[0] incluido. Puro, compila en todas las plataformas. }
function SplitCommandLine(const CL: UnicodeString): TWideArgs;

{ UTF-16 a UTF-8; False si hay un surrogate suelto (S queda a medias) }
function Utf16ToUtf8(const W: UnicodeString; out S: AnsiString): Boolean;

{ El Debug de un OsString de Windows (core/src/wtf8.rs): entre comillas, con
  los surrogates sueltos como \u(d800), con llaves }
function RustDebugWide(const W: UnicodeString): AnsiString;

{ std::env::var_os(Name).is_some() }
function EnvIsSet(const Name: AnsiString): Boolean;

{ std::env::var(Name): False si no esta definida o no es Unicode }
function EnvUtf8(const Name: AnsiString; out Value: AnsiString): Boolean;

{$IFDEF WINDOWS}
{ GetTempPathW en UTF-8, con la barra final; vacio si fallo }
function WinTempPath: AnsiString;

{ Escribe texto a un handle de salida: a una consola como UTF-16 con
  WriteConsoleW, a todo lo demas los bytes tal cual. False si no se pudo
  escribir todo (pipe cerrado). Nunca para datos: solo texto. En Unix no
  hace falta: outraw.pas escribe los bytes. }
function WriteText(Handle: THandle; const S: AnsiString): Boolean;
{$ENDIF}

implementation

{$IF DEFINED(WINDOWS)}
uses Windows;
{$ELSEIF DEFINED(UNIX)}
uses BaseUnix;
{$ELSE}
  {$FATAL ostext.pas: no hay implementacion para esta plataforma}
{$ENDIF}

const
  HEXDIG: array[0..15] of AnsiChar = '0123456789abcdef';

function HexLower(V: DWord): AnsiString;
begin
  Result := '';
  repeat
    Result := HEXDIG[V and 15] + Result;
    V := V shr 4;
  until V = 0;
end;

procedure AddUtf8(var S: AnsiString; C: DWord);
begin
  if C < $80 then S := S + AnsiChar(C)
  else if C < $800 then
    S := S + AnsiChar($C0 or (C shr 6)) + AnsiChar($80 or (C and $3F))
  else if C < $10000 then
    S := S + AnsiChar($E0 or (C shr 12)) + AnsiChar($80 or ((C shr 6) and $3F)) +
         AnsiChar($80 or (C and $3F))
  else
    S := S + AnsiChar($F0 or (C shr 18)) + AnsiChar($80 or ((C shr 12) and $3F)) +
         AnsiChar($80 or ((C shr 6) and $3F)) + AnsiChar($80 or (C and $3F));
end;

{ El codepoint en I (que avanza), o el surrogate suelto con Lone a True }
function NextCodePoint(const W: UnicodeString; var I: SizeInt; out Lone: Boolean): DWord;
var hi, lo: DWord;
begin
  Lone := False;
  hi := Ord(W[I]);
  Inc(I);
  if (hi >= $D800) and (hi <= $DBFF) and (I <= Length(W)) then
  begin
    lo := Ord(W[I]);
    if (lo >= $DC00) and (lo <= $DFFF) then
    begin
      Inc(I);
      Exit($10000 + ((hi - $D800) shl 10) + (lo - $DC00));
    end;
  end;
  if (hi >= $D800) and (hi <= $DFFF) then Lone := True;
  Result := hi;
end;

function Utf16ToUtf8(const W: UnicodeString; out S: AnsiString): Boolean;
var i: SizeInt; c: DWord; lone: Boolean;
begin
  S := '';
  i := 1;
  while i <= Length(W) do
  begin
    c := NextCodePoint(W, i, lone);
    if lone then Exit(False);
    AddUtf8(S, c);
  end;
  Result := True;
end;

{ char::escape_debug_ext con escape_grapheme_extended y las comillas dobles.
  El Rust escapa todo lo que no es "imprimible" segun sus tablas de Unicode;
  aca van los controles, los de formato mas comunes y las marcas que
  combinan, que es lo que puede aparecer en un nombre de archivo. Un
  caracter exotico fuera de estas listas puede salir literal donde el Rust
  pondria el escape \u: solo afecta el texto del panico. }
function NeedsUnicodeEscape(C: DWord): Boolean;
begin
  case C of
    $00..$1F, $7F..$9F, $AD, $0300..$036F, $0483..$0489, $0591..$05BD,
    $0610..$061A, $061C, $064B..$065F, $180E, $200B..$200F, $2028..$202E,
    $2060..$2064, $2066..$206F, $20D0..$20F0, $D800..$DFFF, $FE00..$FE0F,
    $FE20..$FE2F, $FEFF, $FFF9..$FFFB, $1F3FB..$1F3FF, $E0001, $E0020..$E007F,
    $E0100..$E01EF:
      Result := True;
  else
    Result := False;
  end;
end;

function RustDebugWide(const W: UnicodeString): AnsiString;
var i: SizeInt; c: DWord; lone: Boolean;
begin
  Result := '"';
  i := 1;
  while i <= Length(W) do
  begin
    c := NextCodePoint(W, i, lone);
    case c of
      0: Result := Result + '\0';
      9: Result := Result + '\t';
      10: Result := Result + '\n';
      13: Result := Result + '\r';
      Ord('"'): Result := Result + '\"';
      Ord('\'): Result := Result + '\\';
    else
      if lone or NeedsUnicodeEscape(c) then
        Result := Result + '\u{' + HexLower(c) + '}'
      else
        AddUtf8(Result, c);
    end;
  end;
  Result := Result + '"';
end;

{ sys/windows/args.rs, parse_lp_cmd_line, linea por linea. Las reglas:
    * argv[0] es especial: una comilla siempre conmuta, no hay escapes, y
      el primer blanco fuera de comillas lo termina.
    * despues, blanco y tab fuera de comillas separan (varios cuentan uno).
    * N barras seguidas de una comilla dan N/2 barras, y si N es impar la
      comilla es literal; barras que no van antes de una comilla son
      literales.
    * dentro de comillas, "" es una comilla literal; una comilla al final de
      la linea con las comillas abiertas igual empuja el argumento (vacio
      si hace falta). }
function SplitCommandLine(const CL: UnicodeString): TWideArgs;
var
  i, n, bs, k: SizeInt;
  inq: Boolean;
  cur: UnicodeString;
  w: WideChar;

  procedure Push;
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := cur;
    cur := '';
  end;

  procedure SkipBlanks;
  begin
    while (i <= n) and ((CL[i] = ' ') or (CL[i] = #9)) do Inc(i);
  end;

begin
  Result := nil;
  cur := '';
  n := Length(CL);
  { linea vacia: el Rust pone solo el nombre del ejecutable }
  if n = 0 then
  begin
    Push;
    Exit;
  end;

  i := 1;
  inq := False;
  while i <= n do
  begin
    w := CL[i];
    Inc(i);
    if w = '"' then inq := not inq
    else if ((w = ' ') or (w = #9)) and not inq then Break
    else cur := cur + w;
  end;
  SkipBlanks;
  Push;

  inq := False;
  while i <= n do
  begin
    w := CL[i];
    Inc(i);
    if ((w = ' ') or (w = #9)) and not inq then
    begin
      Push;
      SkipBlanks;
    end
    else if w = '\' then
    begin
      bs := 1;
      while (i <= n) and (CL[i] = '\') do
      begin
        Inc(bs);
        Inc(i);
      end;
      if (i <= n) and (CL[i] = '"') then
      begin
        for k := 1 to bs div 2 do cur := cur + '\';
        if Odd(bs) then
        begin
          Inc(i);
          cur := cur + '"';
        end;
      end
      else
        for k := 1 to bs do cur := cur + '\';
    end
    else if (w = '"') and inq then
    begin
      if i > n then Break                { fin de la linea, comillas abiertas }
      else if CL[i] = '"' then
      begin
        cur := cur + '"';
        Inc(i);
      end
      else inq := False;
    end
    else if w = '"' then inq := True
    else cur := cur + w;
  end;
  if (cur <> '') or inq then Push;
end;

{$IF DEFINED(WINDOWS)}

function OsArgs(out Argv: TArgv; out Panic: AnsiString): Boolean;
var all: TWideArgs; i: LongInt; s: AnsiString;
begin
  Panic := '';
  all := SplitCommandLine(UnicodeString(PWideChar(GetCommandLineW)));
  Argv := nil;
  if Length(all) > 1 then SetLength(Argv, Length(all) - 1);
  { env::args().skip(1).collect(): cada argumento se desenvuelve en orden,
    argv[0] incluido, y el primero que no es Unicode entra en panico. El
    texto es el del std 1.77.2 compilado para Windows (medido bajo wine). }
  for i := 0 to High(all) do
  begin
    if not Utf16ToUtf8(all[i], s) then
    begin
      Panic := 'thread ''main'' panicked at library\std\src\env.rs:837:51:' + #10 +
               'called `Result::unwrap()` on an `Err` value: ' + RustDebugWide(all[i]) + #10 +
               'note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace' + #10;
      Argv := nil;
      Exit(False);
    end;
    if i > 0 then Argv[i - 1] := s;
  end;
  Result := True;
end;

function WideEnv(const Name: AnsiString; out Value: UnicodeString): Boolean;
var wname: UnicodeString; buf: array of WideChar; n: DWord;
begin
  Value := '';
  wname := UnicodeString(Name);
  SetLength(buf, 512);
  repeat
    { como fill_utf16_buf: 0 con el error en 0 es una variable vacia }
    SetLastError(0);
    n := GetEnvironmentVariableW(PWideChar(wname), @buf[0], Length(buf));
    if n = 0 then Exit(GetLastError = 0);
    if n < DWord(Length(buf)) then Break;
    SetLength(buf, n + 1);
  until False;
  SetLength(Value, n);
  Move(buf[0], Value[1], n * SizeOf(WideChar));
  Result := True;
end;

function EnvIsSet(const Name: AnsiString): Boolean;
var v: UnicodeString;
begin
  Result := WideEnv(Name, v);
end;

function EnvUtf8(const Name: AnsiString; out Value: AnsiString): Boolean;
var v: UnicodeString;
begin
  Value := '';
  Result := WideEnv(Name, v) and Utf16ToUtf8(v, Value);
end;

function WinTempPath: AnsiString;
var buf: array of WideChar; n: DWord; w: UnicodeString;
begin
  Result := '';
  SetLength(buf, MAX_PATH + 1);
  repeat
    n := GetTempPathW(Length(buf), @buf[0]);
    if n = 0 then Exit;
    if n < DWord(Length(buf)) then Break;
    SetLength(buf, n + 1);
  until False;
  SetLength(w, n);
  Move(buf[0], w[1], n * SizeOf(WideChar));
  { un surrogate suelto no tiene UTF-8: el Rust lo llevaria en WTF-8, aca
    queda vacio y la creacion del temporal falla }
  if not Utf16ToUtf8(w, Result) then Result := '';
end;

function WriteText(Handle: THandle; const S: AnsiString): Boolean;
var
  mode, done: DWord;
  w: UnicodeString;
  n, off, total, written: LongInt;
begin
  Result := True;
  if S = '' then Exit;
  if GetConsoleMode(Handle, mode) then
  begin
    { sys/windows/stdio.rs: a una consola, UTF-8 -> UTF-16 y WriteConsoleW,
      de a pedazos (el Rust usa 4096 unidades por llamada) }
    n := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(S), Length(S), nil, 0);
    if n <= 0 then Exit(False);
    SetLength(w, n);
    MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(S), Length(S), PWideChar(w), n);
    off := 0;
    while off < n do
    begin
      total := n - off;
      if total > 4096 then total := 4096;
      { sin partir un par de surrogates entre dos llamadas }
      if (total < n - off) and (Ord(w[off + total]) >= $D800) and (Ord(w[off + total]) <= $DBFF) then
        Dec(total);
      if not WriteConsoleW(Handle, @w[off + 1], total, done, nil) or (done = 0) then Exit(False);
      Inc(off, LongInt(done));
    end;
    Exit;
  end;
  total := 0;
  while total < Length(S) do
  begin
    if not WriteFile(Handle, S[total + 1], Length(S) - total, done, nil) or (done = 0) then
      Exit(False);
    written := LongInt(done);
    Inc(total, written);
  end;
end;

function ArgCount: LongInt;
var a: TArgv; p: AnsiString;
begin
  if not OsArgs(a, p) then Exit(0);
  Result := Length(a);
end;

function ArgStr(I: LongInt): AnsiString;
var a: TArgv; p: AnsiString;
begin
  Result := '';
  if not OsArgs(a, p) then Exit;
  if (I >= 1) and (I <= Length(a)) then Result := a[I - 1];
end;

{$ELSE}

function OsArgs(out Argv: TArgv; out Panic: AnsiString): Boolean;
var i: LongInt;
begin
  Panic := '';
  SetLength(Argv, ParamCount);
  for i := 1 to ParamCount do Argv[i - 1] := ParamStr(i);
  Result := True;
end;

function EnvIsSet(const Name: AnsiString): Boolean;
begin
  { FpGetEnv da nil si no esta definida: distingue "vacia" de "no definida" }
  Result := FpGetEnv(PAnsiChar(Name)) <> nil;
end;

function EnvUtf8(const Name: AnsiString; out Value: AnsiString): Boolean;
var p: PAnsiChar;
begin
  { el Rust ademas rechaza lo que no es UTF-8; los que llaman solo aceptan
    hexadecimal, asi que eso no cambia nada }
  p := FpGetEnv(PAnsiChar(Name));
  Result := p <> nil;
  if Result then Value := AnsiString(p) else Value := '';
end;

function ArgCount: LongInt;
begin
  Result := ParamCount;
end;

function ArgStr(I: LongInt): AnsiString;
begin
  Result := ParamStr(I);
end;

{$ENDIF}

{$IFDEF WINDOWS}
initialization
  { antes que SysUtils y que cualquier otra unidad del programa: los
    AnsiString que se creen desde aca quedan etiquetados UTF-8 }
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
{$ENDIF}
end.
