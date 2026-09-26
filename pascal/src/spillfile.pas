unit SpillFile;
{ El archivo temporal del spill de Future-LZ, creado como lo crea el Rust
  (`TempFile::new`, util.rs):

    * en el directorio de `std::env::temp_dir()` -- en Unix SOLO $TMPDIR, o
      /tmp si no esta definida. El GetTempDir de FPC mira antes TEMP y TMP, y
      con cualquiera de las dos apuntando a otro lado el spill iba a parar a
      otro disco que el del Rust: exito en uno y fallo en el otro.
    * con nombre `<prefijo>-<pid>-<nanos>-<contador>`. El pid y un contador
      que arrancaba en 0 eran predecibles.
    * en EXCLUSIVA (O_EXCL / CREATE_NEW). Sin eso, un symlink plantado con el
      nombre esperado se seguia: el contenido descomprimido se escribia donde
      apuntara, fuera del directorio temporal, y ahi quedaba. Si el nombre ya
      existe, falla -- una sola vez, sin reintentar, igual que el Rust.

  Todo lo que depende de la plataforma vive aca. La cadena de $IF termina en
  $FATAL: un simbolo mal escrito no puede caer en silencio en la otra rama
  (docs/pascal-port.md, la primera trampa). }

{$MODE OBJFPC}{$H+}
interface

uses Classes;

type
  { THandleStream no cierra su handle al liberarse; este si. }
  TOwnedHandleStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

{ El directorio de `std::env::temp_dir()`, con el separador final (o vacio,
  que es el directorio actual, si $TMPDIR esta definida y vacia). }
function RustTempDir: AnsiString;

{ Crea `<RustTempDir><Prefix>-<pid>-<nanos>-<contador>` en exclusiva. nil si no
  se pudo; en ese caso Path NO es nuestro y no hay que borrarlo. }
function CreateTempExclusive(const Prefix: AnsiString;
                             out Path: AnsiString): TOwnedHandleStream;

implementation

uses SysUtils
{$IF DEFINED(UNIX)}
  , BaseUnix, Unix
{$ELSEIF DEFINED(WINDOWS)}
  , Windows
{$ELSE}
  {$FATAL spillfile.pas: no hay implementacion para esta plataforma}
{$ENDIF}
  ;

var
  Counter: QWord = 0;   { compartido por todo el proceso, como el AtomicU64 }

destructor TOwnedHandleStream.Destroy;
begin
  FileClose(Handle);
  inherited Destroy;
end;

{$IF DEFINED(UNIX)}
function RustTempDir: AnsiString;
var p: PChar;
begin
  { FpGetEnv devuelve nil si no esta definida: distingue "vacia" de "no
    definida", que el Rust tambien distingue. }
  p := FpGetEnv(PChar('TMPDIR'));
  if p = nil then Exit('/tmp/');
  Result := StrPas(p);
  if Result <> '' then Result := IncludeTrailingPathDelimiter(Result);
end;

function NowNanos: QWord;
var tv: TTimeVal;
begin
  fpgettimeofday(@tv, nil);
  Result := QWord(tv.tv_sec) * 1000000000 + QWord(tv.tv_usec) * 1000;
end;

function OpenExclusive(const Path: AnsiString): THandle;
begin
  Result := FpOpen(PChar(Path), O_RDWR or O_CREAT or O_EXCL, &666);
  if Result < 0 then Result := feInvalidHandle;
end;
{$ELSEIF DEFINED(WINDOWS)}
function RustTempDir: AnsiString;
begin
  { GetTempPath, la misma llamada que hace el Rust }
  Result := IncludeTrailingPathDelimiter(GetTempDir(False));
end;

function NowNanos: QWord;
var ft: TFileTime;
begin
  { centenas de ns desde 1601; el Rust cuenta ns desde 1970 }
  GetSystemTimeAsFileTime(ft);
  Result := (((QWord(ft.dwHighDateTime) shl 32) or QWord(ft.dwLowDateTime))
             - QWord(116444736000000000)) * 100;
end;

function OpenExclusive(const Path: AnsiString): THandle;
begin
  { los flags de compartir son los que usa el OpenOptions del Rust }
  Result := CreateFileW(PWideChar(UnicodeString(Path)),
                        GENERIC_READ or GENERIC_WRITE,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                        nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Result = INVALID_HANDLE_VALUE then Result := feInvalidHandle;
end;
{$ENDIF}

function CreateTempExclusive(const Prefix: AnsiString;
                             out Path: AnsiString): TOwnedHandleStream;
var h: THandle; n: QWord;
begin
  Result := nil;
  n := Counter;
  Inc(Counter);
  Path := RustTempDir + Prefix + '-' + IntToStr(GetProcessID) + '-' +
          IntToStr(NowNanos) + '-' + IntToStr(n);
  h := OpenExclusive(Path);
  if h = feInvalidHandle then Exit;
  Result := TOwnedHandleStream.Create(h);
end;

end.
