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
{ metadata().len() sobre un handle abierto: lo que dice fstat (un directorio
  y un FIFO tambien contestan); 0 si no contesta }
function HandleSize(H: THandle): QWord;
{ std::fs::metadata(path).len(), unwrap_or(0): sin abrir el archivo (abrir un
  FIFO para leer se bloquea hasta que aparezca un escritor) }
function PathSize(const Path: AnsiString): QWord;
{ FileRead, salvo que en Windows el fin de un pipe anonimo es 0 y no -1: el
  ReadFile del lado que lee falla con ERROR_BROKEN_PIPE cuando el escritor
  cierra, y el FileRead de FPC devuelve -1 por cualquier falla. El Rust
  (Handle::read) lo toma por Ok(0). Sin esto `type x | osrep.exe - -` daba
  "Can't read from input file" en un Windows real (wine no lo muestra). }
function OsRead(H: THandle; var Buf; N: LongInt): LongInt;

type
  { la identidad de un archivo: dispositivo e inodo; en Windows el numero de
    serie del volumen y el indice }
  TFileId = record
    A, B: QWord;
  end;

{ la entrada como la corrida la encontro antes de leerla (util.rs,
  InputStamp): el archivo al que lleva el nombre, su largo y sus horas de
  modificacion (y de cambio de estado en Unix). -delete borra un NOMBRE: si
  entre la lectura y el borrado el nombre pasa a llevar a otro archivo (un
  rename encima) o el archivo cambia mientras se lee, el archivo no tiene lo
  que el nombre lleva ahora, y la corrida salia con 0 y lo borraba. }
type
  TInputStamp = record
    Ok: Boolean;
    Id: TFileId;
    Size: QWord;
    T1, T2, T3, T4: Int64;
  end;

function StampInput(const Path: AnsiString): TInputStamp;
function SameStamp(const A, B: TInputStamp): Boolean;

{ ----------------------------------------- los archivos de una corrida ---

  util.rs, "the files of one run": los archivos que una corrida lee y
  escribe, por identidad, y la regla que siguen: NINGUN ARCHIVO QUE LA
  CORRIDA ESCRIBE ES UNO QUE LEE, NI OTRO QUE ESCRIBE.

  Los nombres no lo pueden decir: x, ./x, un hard link o un symlink, /dev/stdin,
  /proc/self/fd/3, X en Windows y el archivo de una redireccion del shell
  (`< x`, `>> x`, `1<> x`) pueden ser el mismo archivo, y hasta la 2.3.0
  cualquiera de ellos hacia de la entrada una salida: `osrep x.bin ./x.bin`
  truncaba la entrada y salia con 0 y un archivo de nada. Entonces:

    * lo que la corrida lee se anota antes de abrir nada: la entrada con
      nombre o el archivo de stdin, y -index= al descomprimir (NoteRead,
      NoteReadStdin);
    * el archivo de stdout, si la salida es '-', se compara como cualquier
      salida y se anota como escrito, pero nunca se trunca (NoteStdout);
      igual el de stderr cuando la corrida escribe ahi al terminar bien (las
      lineas de progreso y resumen, -bar, los avisos: NoteStderr), porque
      esas lineas caen en ese archivo;
    * los nombres que la corrida va a escribir y ya existen se comparan antes
      del primer open (CheckNames): dos nombres de un archivo que existe se
      rechazan antes de truncar cualquiera de los dos;
    * despues cada archivo se abre para escribir SIN truncar, su identidad sale
      del handle abierto, y se rechaza si la corrida lo lee o ya lo escribe;
      uno rechazado que este open creo se borra, uno que existia queda como
      estaba. Recien ahi se trunca y se anota como escrito: el archivo, la
      salida de -d, -index= al comprimir, la del post-paso de -dup
      (CreateOutput), el spool de -temp= y el derrame de -vmfile=
      (CreateScratch), y los temporales (spillfile.pas, NoteTemp).

  Un rechazo es "Input and output files should have different names", exit
  3, sea cual sea el error que el que llamo hizo del open fallido
  (SameFileRefused). Solo cuentan los archivos regulares: una terminal, un
  pipe, un FIFO o un dispositivo (/dev/null, NUL) no son un archivo que
  perder, y /dev/null como entrada y salida sigue andando.

  Nada se anota hasta BeginRun: las herramientas de prueba abren sus salidas
  como siempre. }

{ empieza a anotar los archivos de esta corrida: la CLI, una vez, antes de
  abrir nada }
procedure BeginRun;
{ un archivo que la corrida lee, por nombre: la entrada, -index= al
  descomprimir }
procedure NoteRead(const Path: AnsiString);
{ el archivo del que se lee stdin (`< x`), si la entrada es '-' }
procedure NoteReadStdin;
{ el archivo al que va stdout (`> x`, `>> x`, `1<> x`), si la salida es '-':
  se escribe, nunca se trunca. False si la corrida lo lee: rechazado. }
function NoteStdout: Boolean;
{ el archivo al que va stderr (`2> x`, `2>&1`), si la corrida escribe ahi
  al terminar bien (WritesStderr en osrep.lpr): los mensajes van a parar
  ahi, asi que se escribe, nunca se trunca. False si la corrida lo lee o ya
  lo escribe: rechazado (y el mensaje del rechazo todavia cae ahi). }
function NoteStderr: Boolean;
{ los nombres que la corrida va a escribir (la salida, -index= al comprimir,
  -temp=, -vmfile=), antes de abrir ninguno: los que existen no pueden ser un
  archivo que la corrida lee, el de stdout, ni uno el otro. False:
  rechazado. Cada uno se compara otra vez al abrirlo; esto es lo que evita
  que una corrida rechazada haya truncado el primero de dos nombres de un
  archivo cuando llega al segundo. }
function CheckNames(const Names: array of AnsiString): Boolean;
{ si un open se rechazo por la regla: el que llamo informa el rechazo, sea
  cual sea el error que hizo del open fallido }
function SameFileRefused: Boolean;

{ Una salida de la corrida -- el archivo, la salida de -d, -index= al
  comprimir, la del post-paso de -dup -- abierta con la regla (ReadToo: para
  leer tambien) y borrada si la corrida falla (RemoveClaimedOutputs); nil si
  no se pudo abrir o se rechazo. Se abre con RustOpen / open(2) sin
  O_TRUNC, y se trunca recien despues de comparar. }
function CreateOutput(const Path: AnsiString; ReadToo: Boolean): TRawFileStream;

type
  { un temporal con un nombre que dio el usuario (-temp=, -vmfile=): si es
    un archivo regular que esta corrida abrio, se borra al final como en el
    C++ (srep.cpp:1336, decompress.cpp:233) -- solo mientras el nombre siga
    siendo ese archivo, y no por un symlink (util.rs, NamedScratch) }
  TNamedScratch = record
    Named: Boolean;
    Path: AnsiString;
    Id: TFileId;
  end;

{ Path abierto con la regla para escribir (y leer, con ReadToo) y truncado;
  THandle(-1) si no se pudo abrir o se rechazo (el errno / GetLastError es el
  del open). Un nombre que no se pudo abrir no es de esta corrida: Named
  queda en falso y RemoveScratch no lo toca. }
function CreateScratch(const Path: AnsiString; ReadToo: Boolean; out Scratch: TNamedScratch): THandle;
{ con los handles ya cerrados: Windows no borra un archivo abierto }
procedure RemoveScratch(var Scratch: TNamedScratch);

{ un temporal propio, recien creado en exclusiva (spillfile.pas): cuenta como
  escrito mientras exista. DeleteTemp lo borra y deja de contarlo: su numero
  puede volver como otro archivo. }
procedure NoteTemp(H: THandle);
procedure DeleteTemp(const Path: AnsiString);

{ La corrida fallo: borra las salidas que creo o trunco, para que no quede un
  archivo a medias. El C++ lo intenta ("Delete output files on error",
  srep.cpp:1339), pero solo llegan ahi sus `goto cleanup`; cada error() sale
  en el acto. Solo archivos regulares, y un nombre se borra solo mientras
  siga siendo el archivo que se abrio, no por un symlink. Un archivo que la
  corrida lee nunca esta entre ellos: se rechaza antes de abrirlo para
  escribir. Con los handles ya cerrados. }
procedure RemoveClaimedOutputs;

implementation

uses
{$IF DEFINED(UNIX)}
  BaseUnix,
{$ELSEIF DEFINED(WINDOWS)}
  Windows,    { antes que SysUtils: trae su propio DeleteFile }
{$ELSE}
  {$FATAL streamio.pas: no hay implementacion para esta plataforma}
{$ENDIF}
  SysUtils, OutRaw;

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

type
  TFileIdArray = array of TFileId;

var
  Armed: Boolean = False;
  Refused: Boolean = False;
  Reads, Writes: TFileIdArray;
  ClaimedPath: array of AnsiString;
  ClaimedId: TFileIdArray;

{$IF DEFINED(UNIX)}
{ fstat: un archivo regular, nada mas }
function IdOfHandle(H: THandle; out Id: TFileId): Boolean;
var st: BaseUnix.Stat;
begin
  Result := (fpFStat(H, st) = 0) and fpS_ISREG(st.st_mode);
  Id.A := QWord(st.st_dev);
  Id.B := QWord(st.st_ino);
end;

{ lstat: el nombre mismo es un archivo regular (un symlink no) }
function IdOfName(const Path: AnsiString; out Id: TFileId): Boolean;
var st: BaseUnix.Stat;
begin
  Result := (fpLStat(PChar(Path), st) = 0) and fpS_ISREG(st.st_mode);
  Id.A := QWord(st.st_dev);
  Id.B := QWord(st.st_ino);
end;

{ stat: el nombre lleva a un archivo regular }
function IdOfPathRegular(const Path: AnsiString; out Id: TFileId): Boolean;
var st: BaseUnix.Stat;
begin
  Result := (fpStat(PChar(Path), st) = 0) and fpS_ISREG(st.st_mode);
  Id.A := QWord(st.st_dev);
  Id.B := QWord(st.st_ino);
end;
{$ELSE}
const
  ID_FILE_TYPE_DISK = 1;
  ID_ATTR_DIRECTORY = $10;
  ID_ATTR_REPARSE_POINT = $400;
  ID_FLAG_BACKUP_SEMANTICS = $02000000;
  ID_FLAG_OPEN_REPARSE_POINT = $00200000;

function IdOfInfo(H: THandle; out Attr: DWord; out Id: TFileId): Boolean;
var info: BY_HANDLE_FILE_INFORMATION;
begin
  FillChar(info, SizeOf(info), 0);
  Result := GetFileInformationByHandle(H, info);
  Attr := info.dwFileAttributes;
  Id.A := QWord(info.dwVolumeSerialNumber);
  Id.B := (QWord(info.nFileIndexHigh) shl 32) or QWord(info.nFileIndexLow);
end;

{ un archivo de disco que no es un directorio: NUL, CON y los pipes no son
  FILE_TYPE_DISK }
function IdOfHandle(H: THandle; out Id: TFileId): Boolean;
var attr: DWord;
begin
  Id.A := 0; Id.B := 0;
  if GetFileType(H) <> ID_FILE_TYPE_DISK then Exit(False);
  Result := IdOfInfo(H, attr, Id) and ((attr and ID_ATTR_DIRECTORY) = 0);
end;

{ abre el nombre sin pedir acceso, para preguntar; Flags decide si sigue un
  reparse point (un symlink, una juntura) }
function IdOfOpen(const Path: AnsiString; Flags: DWord; out Attr: DWord; out Id: TFileId): Boolean;
var w: UnicodeString; h: THandle;
begin
  Attr := 0; Id.A := 0; Id.B := 0;
  w := UnicodeString(Path);
  h := CreateFileW(PWideChar(w), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                   nil, OPEN_EXISTING, Flags, 0);
  if h = INVALID_HANDLE_VALUE then Exit(False);
  Result := IdOfInfo(h, Attr, Id);
  CloseHandle(h);
end;

function IdOfName(const Path: AnsiString; out Id: TFileId): Boolean;
var attr: DWord;
begin
  Result := IdOfOpen(Path, ID_FLAG_BACKUP_SEMANTICS or ID_FLAG_OPEN_REPARSE_POINT, attr, Id) and
            ((attr and (ID_ATTR_DIRECTORY or ID_ATTR_REPARSE_POINT)) = 0);
end;

{ el nombre lleva a un archivo de disco que no es un directorio (IdOfHandle
  sobre lo que abre) }
function IdOfPathRegular(const Path: AnsiString; out Id: TFileId): Boolean;
var w: UnicodeString; h: THandle;
begin
  Id.A := 0; Id.B := 0;
  w := UnicodeString(Path);
  h := CreateFileW(PWideChar(w), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                   nil, OPEN_EXISTING, ID_FLAG_BACKUP_SEMANTICS, 0);
  if h = INVALID_HANDLE_VALUE then Exit(False);
  Result := IdOfHandle(h, Id);
  CloseHandle(h);
end;
{$ENDIF}

{$IF DEFINED(UNIX)}
function StampInput(const Path: AnsiString): TInputStamp;
var st: BaseUnix.Stat;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Ok := (fpStat(PChar(Path), st) = 0) and fpS_ISREG(st.st_mode);
  if not Result.Ok then Exit;
  Result.Id.A := QWord(st.st_dev);
  Result.Id.B := QWord(st.st_ino);
  Result.Size := QWord(st.st_size);
  Result.T1 := Int64(st.st_mtime); Result.T2 := Int64(st.st_mtime_nsec);
  Result.T3 := Int64(st.st_ctime); Result.T4 := Int64(st.st_ctime_nsec);
end;
{$ELSE}
function StampInput(const Path: AnsiString): TInputStamp;
var w: UnicodeString; h: THandle; info: BY_HANDLE_FILE_INFORMATION;
begin
  FillChar(Result, SizeOf(Result), 0);
  w := UnicodeString(Path);
  h := CreateFileW(PWideChar(w), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                   nil, OPEN_EXISTING, ID_FLAG_BACKUP_SEMANTICS, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  FillChar(info, SizeOf(info), 0);
  Result.Ok := (GetFileType(h) = ID_FILE_TYPE_DISK) and GetFileInformationByHandle(h, info) and
               ((info.dwFileAttributes and ID_ATTR_DIRECTORY) = 0);
  CloseHandle(h);
  Result.Id.A := QWord(info.dwVolumeSerialNumber);
  Result.Id.B := (QWord(info.nFileIndexHigh) shl 32) or QWord(info.nFileIndexLow);
  Result.Size := (QWord(info.nFileSizeHigh) shl 32) or QWord(info.nFileSizeLow);
  Result.T1 := Int64(info.ftLastWriteTime.dwHighDateTime);
  Result.T2 := Int64(info.ftLastWriteTime.dwLowDateTime);
end;
{$ENDIF}

{ ---------------------------------------------- abrir sin truncar --- }

{$IF DEFINED(UNIX)}
{ open(O_CREAT) sin O_TRUNC, y si el archivo ya estaba (util.rs,
  open_no_truncate): primero en exclusiva (O_EXCL) y, si el nombre existe, un
  open comun. Un symlink colgado falla los dos, y el tercer open crea lo que
  nombra, como File::create; cualquier otra falla del open exclusivo da con
  el tercero el error que daba File::create. }
function OpenNoTrunc(const Path: AnsiString; ReadToo: Boolean; out Existed: Boolean): THandle;
var acc: cint;

  function OpenWith(Flags: cint): THandle;
  begin
    repeat
      Result := fpOpen(PChar(Path), Flags, &666);
    until (Result <> THandle(-1)) or (fpgeterrno <> ESysEINTR);
  end;

begin
  if ReadToo then acc := O_RDWR else acc := O_WRONLY;
  Existed := False;
  Result := OpenWith(acc or O_CREAT or O_EXCL);
  if Result <> THandle(-1) then Exit;
  if fpgeterrno = ESysEEXIST then
  begin
    Result := OpenWith(acc);
    if Result <> THandle(-1) then
    begin
      Existed := True;
      Exit;
    end;
    if fpgeterrno <> ESysENOENT then Exit(THandle(-1));
  end
  else Existed := True;
  Result := OpenWith(acc or O_CREAT);
end;

{ el O_TRUNC despues de comparar: sobre un archivo regular, y sobre nada mas
  (un FIFO, una terminal o /dev/null ignoran O_TRUNC, y ftruncate falla ahi) }
function TruncateOpened(H: THandle; Regular: Boolean): Boolean;
begin
  Result := (not Regular) or (fpFtruncate(H, 0) = 0);
end;

function SaveOsError: LongInt;
begin
  Result := fpgeterrno;
end;

procedure RestoreOsError(E: LongInt);
begin
  fpseterrno(E);
end;
{$ELSE}
{ CreateFileW con OPEN_ALWAYS, la disposicion del OpenOptions del Rust 1.77
  para create+truncate, pero sin su truncado (RustOpen), y si el archivo ya
  estaba (ERROR_ALREADY_EXISTS). El mismo acceso y el mismo share mode. }
function OpenNoTrunc(const Path: AnsiString; ReadToo: Boolean; out Existed: Boolean): THandle;
var w: UnicodeString; acc: DWord;
begin
  w := UnicodeString(Path);
  acc := GENERIC_WRITE;
  if ReadToo then acc := acc or GENERIC_READ;
  Result := CreateFileW(PWideChar(w), acc, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                        nil, OPEN_ALWAYS, 0, 0);
  Existed := (Result <> INVALID_HANDLE_VALUE) and (GetLastError = ERROR_ALREADY_EXISTS);
  if Result = INVALID_HANDLE_VALUE then Result := THandle(-1);
end;

{ el truncado del create+truncate del Rust 1.77 (#115745): el fin de archivo
  en 0 sea lo que sea el handle, y si falla, falla el open (NUL o un pipe:
  "Can't open NUL for write", como antes) }
function TruncateOpened(H: THandle; Regular: Boolean): Boolean;
var eof: Int64;
begin
  eof := 0;
  Result := SetFileInformationByHandle(H, FILE_END_OF_FILE_INFO_CLASS, @eof, SizeOf(eof));
end;

function SaveOsError: LongInt;
begin
  Result := LongInt(GetLastError);
end;

procedure RestoreOsError(E: LongInt);
begin
  SetLastError(DWord(E));
end;
{$ENDIF}

{ ------------------------------------------ los archivos de una corrida --- }

function SameId(const A, B: TFileId): Boolean; inline;
begin
{$IF DEFINED(WINDOWS)}
  { el indice decide; un numero de serie 0 es desconocido y vale por
    cualquiera (wine da 0 en los handles estandar y en un archivo al que se
    llega por Z:, y el serial del drive al mismo archivo por C:). El limite,
    bajo wine (util.rs, FileId::eq): todo camino por Z: tiene serial 0 y el
    indice es el inodo de Unix sin el dispositivo, asi que dos archivos en
    sistemas de archivos de Linux distintos con el mismo inodo (los tmpfs
    reparten numeros chicos) son uno aca, y la corrida se rechaza (exit 3,
    nada cambia). No hay nada mejor ahi (la hora de creacion de wine es la
    de modificacion, FileIdInformation lleva el mismo inodo), y desempatar
    por tamano u hora perderia un caso real (-vmfile= contra una salida que
    ya se esta escribiendo) }
  Result := (A.B = B.B) and ((A.A = B.A) or (A.A = 0) or (B.A = 0));
{$ELSE}
  Result := (A.A = B.A) and (A.B = B.B);
{$ENDIF}
end;

function SameStamp(const A, B: TInputStamp): Boolean;
begin
  Result := A.Ok and B.Ok and SameId(A.Id, B.Id) and (A.Size = B.Size) and
            (A.T1 = B.T1) and (A.T2 = B.T2) and (A.T3 = B.T3) and (A.T4 = B.T4);
end;

function InIds(const L: TFileIdArray; const Id: TFileId): Boolean;
var i: SizeInt;
begin
  Result := False;
  for i := 0 to High(L) do
    if SameId(L[i], Id) then Exit(True);
end;

procedure AddId(var L: TFileIdArray; const Id: TFileId);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := Id;
end;

procedure DropId(var L: TFileIdArray; const Id: TFileId);
var i: SizeInt;
begin
  for i := 0 to High(L) do
    if SameId(L[i], Id) then
    begin
      L[i] := L[High(L)];
      SetLength(L, Length(L) - 1);
      Exit;
    end;
end;

function Taken(const Id: TFileId): Boolean;
begin
  Result := InIds(Reads, Id) or InIds(Writes, Id);
end;

procedure RemoveIfStill(const Path: AnsiString; const Id: TFileId);
var now_: TFileId;
begin
  if IdOfName(Path, now_) and SameId(now_, Id) then
    SysUtils.DeleteFile(Path);
end;

procedure BeginRun;
begin
  Armed := True;
end;

procedure NoteRead(const Path: AnsiString);
var id: TFileId;
begin
  if Armed and IdOfPathRegular(Path, id) then AddId(Reads, id);
end;

procedure NoteReadStdin;
var id: TFileId;
begin
  if Armed and IdOfHandle(InHandle, id) then AddId(Reads, id);
end;

function NoteStdWritten(H: THandle): Boolean;
var id: TFileId;
begin
  Result := True;
  if not (Armed and IdOfHandle(H, id)) then Exit;
  if Taken(id) then
  begin
    Refused := True;
    Exit(False);
  end;
  AddId(Writes, id);
end;

function CheckNames(const Names: array of AnsiString): Boolean;
var ids: TFileIdArray; id: TFileId; i, j, n: SizeInt;
begin
  Result := True;
  SetLength(ids, Length(Names));
  n := 0;
  for i := 0 to High(Names) do
    if IdOfPathRegular(Names[i], id) then
    begin
      ids[n] := id;
      Inc(n);
    end;
  for i := 0 to n - 1 do
  begin
    for j := 0 to i - 1 do
      if SameId(ids[j], ids[i]) then
      begin
        Refused := True;
        Exit(False);
      end;
    if Taken(ids[i]) then
    begin
      Refused := True;
      Exit(False);
    end;
  end;
end;

function NoteStdout: Boolean;
begin
  Result := NoteStdWritten(OutHandle);
end;

function NoteStderr: Boolean;
begin
  Result := NoteStdWritten(ErrHandle);
end;

function SameFileRefused: Boolean;
begin
  Result := Refused;
end;

{ Path abierto con la regla (util.rs, Files::open): sin truncar, rechazado si
  es un archivo que la corrida lee o escribe, y recien despues truncado.
  IsReg e Id: si es un archivo regular, y su identidad. }
function OpenChecked(const Path: AnsiString; ReadToo: Boolean; out IsReg: Boolean;
                     out Id: TFileId): THandle;
var existed: Boolean; now_: TFileId; e: LongInt;
begin
  IsReg := False;
  Id.A := 0; Id.B := 0;
  Result := OpenNoTrunc(Path, ReadToo, existed);
  if Result = THandle(-1) then Exit;
  IsReg := IdOfHandle(Result, Id);
  if Armed and IsReg and Taken(Id) then
  begin
    Refused := True;
    FileClose(Result);
    if (not existed) and IdOfName(Path, now_) and SameId(now_, Id) then SysUtils.DeleteFile(Path);
    Exit(THandle(-1));
  end;
  if existed and not TruncateOpened(Result, IsReg) then
  begin
    e := SaveOsError;
    FileClose(Result);
    RestoreOsError(e);
    Exit(THandle(-1));
  end;
  if Armed and IsReg then AddId(Writes, Id);
end;

function CreateOutput(const Path: AnsiString; ReadToo: Boolean): TRawFileStream;
var h: THandle; isReg: Boolean; id: TFileId; n: SizeInt;
begin
  h := OpenChecked(Path, ReadToo, isReg, id);
  if h = THandle(-1) then Exit(nil);
  if Armed and isReg then
  begin
    n := Length(ClaimedPath);
    SetLength(ClaimedPath, n + 1);
    SetLength(ClaimedId, n + 1);
    ClaimedPath[n] := Path;
    ClaimedId[n] := id;
  end;
  Result := TRawFileStream.Create(h);
end;

function CreateScratch(const Path: AnsiString; ReadToo: Boolean; out Scratch: TNamedScratch): THandle;
var isReg: Boolean; id: TFileId;
begin
  Scratch.Named := False;
  Scratch.Path := Path;
  Scratch.Id.A := 0; Scratch.Id.B := 0;
  Result := OpenChecked(Path, ReadToo, isReg, id);
  if Result = THandle(-1) then Exit;
  Scratch.Named := isReg;
  Scratch.Id := id;
end;

procedure RemoveScratch(var Scratch: TNamedScratch);
begin
  if not Scratch.Named then Exit;
  Scratch.Named := False;
  RemoveIfStill(Scratch.Path, Scratch.Id);
  DropId(Writes, Scratch.Id);
end;

procedure NoteTemp(H: THandle);
var id: TFileId;
begin
  if Armed and IdOfHandle(H, id) then AddId(Writes, id);
end;

procedure DeleteTemp(const Path: AnsiString);
var id: TFileId;
begin
  if IdOfName(Path, id) then DropId(Writes, id);
  SysUtils.DeleteFile(Path);
end;

procedure RemoveClaimedOutputs;
var i: SizeInt;
begin
  for i := 0 to High(ClaimedPath) do RemoveIfStill(ClaimedPath[i], ClaimedId[i]);
  ClaimedPath := nil;
  ClaimedId := nil;
end;

function OsRead(H: THandle; var Buf; N: LongInt): LongInt;
begin
  Result := FileRead(H, Buf, N);
{$IF DEFINED(WINDOWS)}
  if (Result < 0) and (GetLastError = ERROR_BROKEN_PIPE) then
  begin
    SetLastError(0);
    Result := 0;
  end;
{$ENDIF}
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
