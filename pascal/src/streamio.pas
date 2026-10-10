unit StreamIO;
{ Lecturas y escrituras de streams con cuentas de 64 bits.

  TStream.Read/Write/ReadBuffer/WriteBuffer toman la cuenta como LongInt. Un
  `LongInt(n)` con n >= 2 GiB no es un error para FPC: se trunca, y si el bit
  31 queda prendido la cuenta sale negativa, Read devuelve 0 y el que llama lo
  toma por EOF. Asi `-b2g`/`-b3g`/`-b4g` escribian un archivo SIN bloques con
  exit 0 (el Rust los comprime bien). Todo lo que pueda pasar de 2 GiB va por
  aca, en tramos de IO_SLICE. }

{$MODE OBJFPC}{$H+}
interface

uses Classes;

const
  IO_SLICE = QWord(1) shl 30;

{ Lee hasta Count bytes, repitiendo hasta llenar o hasta EOF. Devuelve lo
  leido (menos que Count solo en EOF). }
function ReadUpTo(S: TStream; var Buf; Count: QWord): QWord;
{ Una sola lectura, como un read(2): puede devolver menos que Count. }
function ReadOnce(S: TStream; var Buf; Count: QWord): QWord;
{ ReadUpTo que exige los Count bytes (EReadError si faltan). }
procedure ReadExact(S: TStream; var Buf; Count: QWord);
procedure WriteAll(S: TStream; const Buf; Count: QWord);

type
  { un THandleStream que cierra su handle al liberarse }
  TRawFileStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

{ Abre para leer como el File::open del Rust, o nil. En Unix es el open(2)
  pelado: el FileOpen de FPC rechaza los directorios, y el Rust los abre y
  falla despues, en el seek o en el read, con el errno que corresponda (EISDIR,
  o lo que conteste el sistema de archivos). Con el handle crudo esos errores
  salen solos por los helpers con errno de DecFault, sin casos especiales.
  En Windows es el CreateFileW del Rust, con su share mode (ver RustOpen). }
function OpenReadRaw(const Path: AnsiString): TRawFileStream;
{ Crea (o trunca) para leer y escribir, como el OpenOptions read+write+create+
  truncate del Rust, o nil. En Unix es un solo open(2) con O_RDWR. El
  TFileStream.Create(fmCreate) de FPC abre ANTES el archivo con O_RDONLY para
  revisar el lock, y sobre un FIFO ese open se bloquea hasta que aparezca un
  escritor: con un lector esperando del otro lado (`osrep -d x.osr fifo`)
  colgaba para siempre, donde el Rust abre, falla el seek (ESPIPE) y termina. }
function CreateRaw(const Path: AnsiString): TRawFileStream;
{ File::create: crea (o trunca) solo para escribir, o nil. Sin el open previo
  de TFileStream (ver CreateRaw), y con O_WRONLY como el Rust: un archivo
  con permiso de escritura y no de lectura tambien se puede crear. }
function CreateWriteRaw(const Path: AnsiString): TRawFileStream;
{ metadata().len() sobre un handle abierto: lo que dice fstat (un directorio
  y un FIFO tambien contestan); 0 si no contesta }
function HandleSize(H: THandle): QWord;
{ std::fs::metadata(path).len(), unwrap_or(0): sin abrir el archivo (abrir un
  FIFO para leer se bloquea hasta que aparezca un escritor) }
function PathSize(const Path: AnsiString): QWord;

implementation

uses
{$IF DEFINED(UNIX)}
  BaseUnix,
{$ELSEIF DEFINED(WINDOWS)}
  Windows,    { antes que SysUtils: trae su propio DeleteFile }
{$ELSE}
  {$FATAL streamio.pas: no hay implementacion para esta plataforma}
{$ENDIF}
  SysUtils;

{$IF DEFINED(WINDOWS)}
const
  FILE_END_OF_FILE_INFO_CLASS = 6;   { FileEndOfFileInfo }

function SetFileInformationByHandle(H: THandle; InfoClass: DWord; Info: Pointer;
  Size: DWord): BOOL; stdcall; external 'kernel32' name 'SetFileInformationByHandle';

{ El File::open del Rust 1.77 en Windows (sys/pal/windows/fs.rs): CreateFileW
  con el share READ|WRITE|DELETE y, para create+truncate, OPEN_ALWAYS y el
  truncado a mano (#115745): si el archivo ya existia, SetFileInformationByHandle
  con FileEndOfFileInfo = 0, y si eso falla, el open falla. Sobre NUL o un
  pipe ese truncado falla, asi que `osrep -d x.osr NUL` da "Can't open NUL for
  write" en el Rust; con el FileCreate de FPC (CREATE_ALWAYS) el Pascal seguia
  y terminaba bien. }
function RustOpen(const Path: AnsiString; Access, Disposition: DWord; Truncate: Boolean): THandle;
var w: UnicodeString; eof: Int64;
begin
  w := UnicodeString(Path);
  Result := CreateFileW(PWideChar(w), Access,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                        nil, Disposition, 0, 0);
  if Result = INVALID_HANDLE_VALUE then Exit(THandle(-1));
  if Truncate and (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    eof := 0;
    if not SetFileInformationByHandle(Result, FILE_END_OF_FILE_INFO_CLASS, @eof, SizeOf(eof)) then
    begin
      CloseHandle(Result);
      Result := THandle(-1);
    end;
  end;
end;
{$ENDIF}

destructor TRawFileStream.Destroy;
begin
  FileClose(Handle);
  inherited Destroy;
end;

function OpenReadRaw(const Path: AnsiString): TRawFileStream;
var h: THandle;
begin
{$IF DEFINED(UNIX)}
  repeat
    h := fpOpen(PChar(Path), O_RDONLY);
  until (h <> THandle(-1)) or (fpgeterrno <> ESysEINTR);
{$ELSE}
  h := RustOpen(Path, GENERIC_READ, OPEN_EXISTING, False);
{$ENDIF}
  if h = THandle(-1) then Exit(nil);
  Result := TRawFileStream.Create(h);
end;

function CreateWriteRaw(const Path: AnsiString): TRawFileStream;
var h: THandle;
begin
{$IF DEFINED(UNIX)}
  repeat
    h := fpOpen(PChar(Path), O_WRONLY or O_CREAT or O_TRUNC, &666);
  until (h <> THandle(-1)) or (fpgeterrno <> ESysEINTR);
{$ELSE}
  h := RustOpen(Path, GENERIC_WRITE, OPEN_ALWAYS, True);
{$ENDIF}
  if h = THandle(-1) then Exit(nil);
  Result := TRawFileStream.Create(h);
end;

function HandleSize(H: THandle): QWord;
{$IF DEFINED(UNIX)}
var st: BaseUnix.Stat;
begin
  if fpFStat(H, st) = 0 then Result := QWord(st.st_size) else Result := 0;
end;
{$ELSE}
var info: BY_HANDLE_FILE_INFORMATION;
begin
  if GetFileInformationByHandle(H, info) then
    Result := (QWord(info.nFileSizeHigh) shl 32) or QWord(info.nFileSizeLow)
  else Result := 0;
end;
{$ENDIF}

function PathSize(const Path: AnsiString): QWord;
{$IF DEFINED(UNIX)}
var st: BaseUnix.Stat;
begin
  if fpStat(PChar(Path), st) = 0 then Result := QWord(st.st_size) else Result := 0;
end;
{$ELSE}
var h: THandle;
begin
  { como antes: abrir y medir; en Windows abrir no se bloquea }
  h := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit(0);
  Result := HandleSize(h);
  FileClose(h);
end;
{$ENDIF}

function CreateRaw(const Path: AnsiString): TRawFileStream;
var h: THandle;
begin
{$IF DEFINED(UNIX)}
  { FileCreate(nombre, permisos) es el open(O_RDWR|O_CREAT|O_TRUNC) pelado,
    sin el open previo de la variante con ShareMode }
  h := FileCreate(Path, 438);
{$ELSE}
  h := RustOpen(Path, GENERIC_READ or GENERIC_WRITE, OPEN_ALWAYS, True);
{$ENDIF}
  if h = THandle(-1) then Exit(nil);
  Result := TRawFileStream.Create(h);
end;

function Slice(N: QWord): LongInt; inline;
begin
  if N > IO_SLICE then Result := LongInt(IO_SLICE) else Result := LongInt(N);
end;

function ReadUpTo(S: TStream; var Buf; Count: QWord): QWord;
var got: LongInt;
begin
  Result := 0;
  while Result < Count do
  begin
    got := S.Read(PByte(@Buf)[Result], Slice(Count - Result));
    if got <= 0 then Break;
    Inc(Result, QWord(got));
  end;
end;

function ReadOnce(S: TStream; var Buf; Count: QWord): QWord;
var got: LongInt;
begin
  if Count = 0 then Exit(0);
  got := S.Read(Buf, Slice(Count));
  if got < 0 then got := 0;
  Result := QWord(got);
end;

procedure ReadExact(S: TStream; var Buf; Count: QWord);
begin
  if ReadUpTo(S, Buf, Count) <> Count then
    raise EReadError.Create('Stream read error');
end;

procedure WriteAll(S: TStream; const Buf; Count: QWord);
var done: QWord; n: LongInt;
begin
  done := 0;
  while done < Count do
  begin
    n := Slice(Count - done);
    S.WriteBuffer(PByte(@Buf)[done], n);
    Inc(done, QWord(n));
  end;
end;

end.
