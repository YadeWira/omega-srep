unit DecFault;
(* El error de un decoder CON SU ESTRUCTURA, para imprimir exactamente lo que
  imprime el Rust.

  La CLI del Rust formatea los errores de los decoders con Debug
  (`format!("{e:?}: {finame}")`, modes.rs), no con Display:

      Container(Truncated)
      BadData("v5 footer")
      DigestMismatch { block: 0 }
      Io(Os { code: 28, kind: StorageFull, message: "No space left on device" })

  y hay consumidores que parsean ese stderr. Un texto Display no alcanza para
  reconstruirlo (UnsupportedVersion pierde el numero, un io::Error pierde su
  forma interna), asi que cada sitio de error arma un TDecodeFault con la clase
  y los datos, y FaultDebug lo dibuja como el `#[derive(Debug)]` del Rust.

  Msg es otra cosa: el texto que imprimian hasta ahora las herramientas de
  prueba (decodetool y compania), que sus suites comparan contra el Display de
  los harnesses Rust. Se conserva tal cual; la CLI no lo usa.

  io::Error tiene cuatro formas internas y cada una tiene su Debug (Rust
  1.77.2, library/std/src/io/error/repr_bitpacked.rs y error.rs):

      Os(code)        Os { code: N, kind: K, message: "strerror" }
      Simple(kind)    Kind(K)
      SimpleMessage   Error { kind: K, message: "..." }   (read_exact, write_all)
      Custom          Custom { kind: K, error: "..." }     (io::Error::new)

  El kind y el mensaje de un Os salen de tablas medidas con el Rust pinneado:
  en Linux los dos (strerror de glibc); en Windows el kind de la tabla y el
  mensaje de FormatMessageW, que es lo que llama el Rust. *)

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes;

type
  TFaultKind = (fkNone, fkContainer, fkBadData, fkNotIoLz, fkNotFutureLz,
                fkDigestMismatch, fkIo);

  { ContainerError (container.rs), las variantes que llegan a un DecodeError }
  TContKind = (ckTruncated, ckNotAnOsrepFile, ckUnsupportedVersion, ckNoFooter,
               ckUnsupportedFooterVersion, ckFooterExceedsFile, ckTableMismatch);

  { la forma interna de un io::Error. ioRaw no existe en el Rust: es una
    excepcion que no sabemos mapear, y se imprime su texto tal cual }
  TIoForm = (ioOs, ioSimpleMessage, ioCustom, ioRaw);

  TDecodeFault = record
    Kind: TFaultKind;
    Cont: TContKind;       { fkContainer }
    Num: QWord;            { version, bloque o version de footer }
    Text: AnsiString;      { BadData; el mensaje de un io::Error }
    IoForm: TIoForm;
    IoKind: AnsiString;    { el nombre del ErrorKind }
    OsCode: LongInt;
    Msg: AnsiString;       { el texto de las herramientas (ver arriba) }
  end;

  { lleva el error ya armado a traves de un raise }
  EDecodeFault = class(Exception)
  public
    Fault: TDecodeFault;
    constructor CreateFault(const F: TDecodeFault);
  end;

function NoFault: TDecodeFault;
function FaultContainer(C: TContKind; N: QWord = 0): TDecodeFault;
function FaultBadData(const S: AnsiString): TDecodeFault;
function FaultNotIoLz(Version: QWord): TDecodeFault;
function FaultNotFutureLz(Version: QWord): TDecodeFault;
function FaultDigest(Block: QWord): TDecodeFault;
{ out_of_memory() de decompress.rs: io::Error::new(OutOfMemory, "Out of memory") }
function FaultOutOfMemory: TDecodeFault;
{ el read_exact de std: SimpleMessage UnexpectedEof }
function FaultReadExact: TDecodeFault;
{ io::Error::new(UnexpectedEof, "failed to fill whole buffer"), el del slot
  del spill (future_lz.rs) }
function FaultEofCustom: TDecodeFault;
{ el write_all de std cuando write devuelve 0 }
function FaultWriteZero: TDecodeFault;
function FaultOs(Code: LongInt): TDecodeFault;
{ el error que corresponde a una excepcion atrapada en un decoder }
function FaultOfException(X: Exception): TDecodeFault;
{ una excepcion de E/S (stream, archivo, sistema): lo que en el Rust es un
  io::Error y llega a un `From<io::Error>`, como el EncodeError::Io }
function IsIoException(X: Exception): Boolean;

{ el Debug de DecodeError }
function FaultDebug(const F: TDecodeFault): AnsiString;
{ el Debug del io::Error solo (sin el Io(...) de afuera) }
function IoDebug(const F: TDecodeFault): AnsiString;
{ el Debug de un &str: entre comillas, con los escapes de escape_debug }
function RustStrDebug(const S: AnsiString): AnsiString;

{ write_all y read_exact sobre un stream, con el errno a mano: un fallo del
  sistema lanza EDecodeFault con el Os(code) que veria el Rust. }
procedure WriteAllOrFault(S: TStream; const Buf; Count: QWord);
procedure ReadExactOrFault(S: TStream; var Buf; Count: QWord);
{ lee hasta Count bytes o el EOF (lo que devuelve); un fallo del sistema es
  un fault, no un EOF }
function ReadUpToOrFault(S: TStream; var Buf; Count: QWord): QWord;
{ una sola lectura, como el read() del Rust: 0 es EOF, y un fallo del sistema
  (EISDIR, EIO) lanza su Os(code) en vez de parecer un EOF }
function ReadOnceOrFault(S: TStream; var Buf; Count: LongInt): LongInt;
{ el ultimo error del sistema (errno / GetLastError) como fault }
function LastOsFault: TDecodeFault;
{ pone el errno / GetLastError en 0, antes de una llamada que lo va a leer }
procedure ClearOsError;
{ el codigo que da el Rust al hacer seek a un offset que no entra en un i64:
  EINVAL en Unix, ERROR_NEGATIVE_SEEK en Windows }
function FaultNegativeSeek: TDecodeFault;

{ el seek del Rust: falla SOLO si falla la llamada al sistema, con su errno,
  y devuelve lo que ella devuelve. La posicion no se compara con la pedida:
  lseek sobre /dev/null devuelve 0 y el Rust sigue (y la lectura que viene
  da EOF); sobre un pipe falla con ESPIPE, y ahi el Rust corta. Leer de un
  pipe sin haber podido hacer el seek era el cuelgue: el sink abierto en
  lectura-escritura se esperaba a si mismo. }
function SeekOrFault(S: TStream; Off: Int64; Origin: TSeekOrigin): QWord;
{ SeekFrom::Start(off) con un u64: lo que no entra en un i64 es el error que
  da el Rust ahi (FaultNegativeSeek) }
function SeekToOrFault(S: TStream; Off: QWord): QWord;

implementation

uses
{$IF DEFINED(UNIX)}
  BaseUnix
{$ELSEIF DEFINED(WINDOWS)}
  Windows
{$ELSE}
  {$FATAL decfault.pas: no hay implementacion para esta plataforma}
{$ENDIF}
  , StreamIO;

const
  SLICE = QWord(1) shl 30;   { el conteo de Read/Write es un LongInt }

constructor EDecodeFault.CreateFault(const F: TDecodeFault);
begin
  inherited Create(F.Msg);
  Fault := F;
end;

function NoFault: TDecodeFault;
begin
  Result.Kind := fkNone;
  Result.Cont := ckTruncated;
  Result.Num := 0;
  Result.Text := '';
  Result.IoForm := ioRaw;
  Result.IoKind := '';
  Result.OsCode := 0;
  Result.Msg := '';
end;

function FaultContainer(C: TContKind; N: QWord): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkContainer;
  Result.Cont := C;
  Result.Num := N;
  { los textos de siempre de las herramientas, no el Display entero }
  case C of
    ckTruncated:                Result.Msg := 'truncated structure';
    ckNotAnOsrepFile:           Result.Msg := 'not an Omega SREP file (.osr)';
    ckUnsupportedVersion:       Result.Msg := 'incompatible compressed data format';
    ckNoFooter:                 Result.Msg := 'no Omega SREP footer';
    ckUnsupportedFooterVersion: Result.Msg := 'incompatible footer format';
    ckFooterExceedsFile:        Result.Msg := 'footer + index exceeds the file size';
    ckTableMismatch:            Result.Msg := 'block-size table disagrees with the block headers';
  end;
end;

function FaultBadData(const S: AnsiString): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkBadData;
  Result.Text := S;
  Result.Msg := S;
end;

function FaultNotIoLz(Version: QWord): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkNotIoLz;
  Result.Num := Version;
  Result.Msg := 'not an I/O-LZ archive (v' + IntToStr(Version) + ')';
end;

function FaultNotFutureLz(Version: QWord): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkNotFutureLz;
  Result.Num := Version;
  Result.Msg := 'not a Future/Index-LZ archive (v' + IntToStr(Version) + ')';
end;

function FaultDigest(Block: QWord): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkDigestMismatch;
  Result.Num := Block;
  Result.Msg := 'checksum of decoded block ' + IntToStr(Block) + ' differs from the stored one';
end;

function FaultIo(Form: TIoForm; const Kind, Text: AnsiString): TDecodeFault;
begin
  Result := NoFault;
  Result.Kind := fkIo;
  Result.IoForm := Form;
  Result.IoKind := Kind;
  Result.Text := Text;
  Result.Msg := Text;
end;

function FaultOutOfMemory: TDecodeFault;
begin
  Result := FaultIo(ioCustom, 'OutOfMemory', 'Out of memory');
end;

function FaultReadExact: TDecodeFault;
begin
  Result := FaultIo(ioSimpleMessage, 'UnexpectedEof', 'failed to fill whole buffer');
end;

function FaultEofCustom: TDecodeFault;
begin
  Result := FaultIo(ioCustom, 'UnexpectedEof', 'failed to fill whole buffer');
end;

function FaultWriteZero: TDecodeFault;
begin
  Result := FaultIo(ioSimpleMessage, 'WriteZero', 'failed to write whole buffer');
end;

{ ------------------------------------------------- the os error tables --- }

{$IF DEFINED(UNIX)}
type
  TErrnoRow = record Kind, Msg: AnsiString; end;

{ `io::Error::from_raw_os_error(n)` del Rust 1.77.2 en x86_64 Linux, de 0 a
  134: el kind (sys::decode_error_kind) y el mensaje (strerror_r de glibc).
  Medido, no transcrito: un programa Rust imprimio la tabla. Lo de afuera es
  "Unknown error N" y Uncategorized, como glibc y el Rust. }
const
  ERRNO_TABLE: array[0..134] of TErrnoRow = (
    (Kind: 'Uncategorized'; Msg: 'Success'),
    (Kind: 'PermissionDenied'; Msg: 'Operation not permitted'),
    (Kind: 'NotFound'; Msg: 'No such file or directory'),
    (Kind: 'Uncategorized'; Msg: 'No such process'),
    (Kind: 'Interrupted'; Msg: 'Interrupted system call'),
    (Kind: 'Uncategorized'; Msg: 'Input/output error'),
    (Kind: 'Uncategorized'; Msg: 'No such device or address'),
    (Kind: 'ArgumentListTooLong'; Msg: 'Argument list too long'),
    (Kind: 'Uncategorized'; Msg: 'Exec format error'),
    (Kind: 'Uncategorized'; Msg: 'Bad file descriptor'),
    (Kind: 'Uncategorized'; Msg: 'No child processes'),
    (Kind: 'WouldBlock'; Msg: 'Resource temporarily unavailable'),
    (Kind: 'OutOfMemory'; Msg: 'Cannot allocate memory'),
    (Kind: 'PermissionDenied'; Msg: 'Permission denied'),
    (Kind: 'Uncategorized'; Msg: 'Bad address'),
    (Kind: 'Uncategorized'; Msg: 'Block device required'),
    (Kind: 'ResourceBusy'; Msg: 'Device or resource busy'),
    (Kind: 'AlreadyExists'; Msg: 'File exists'),
    (Kind: 'CrossesDevices'; Msg: 'Invalid cross-device link'),
    (Kind: 'Uncategorized'; Msg: 'No such device'),
    (Kind: 'NotADirectory'; Msg: 'Not a directory'),
    (Kind: 'IsADirectory'; Msg: 'Is a directory'),
    (Kind: 'InvalidInput'; Msg: 'Invalid argument'),
    (Kind: 'Uncategorized'; Msg: 'Too many open files in system'),
    (Kind: 'Uncategorized'; Msg: 'Too many open files'),
    (Kind: 'Uncategorized'; Msg: 'Inappropriate ioctl for device'),
    (Kind: 'ExecutableFileBusy'; Msg: 'Text file busy'),
    (Kind: 'FileTooLarge'; Msg: 'File too large'),
    (Kind: 'StorageFull'; Msg: 'No space left on device'),
    (Kind: 'NotSeekable'; Msg: 'Illegal seek'),
    (Kind: 'ReadOnlyFilesystem'; Msg: 'Read-only file system'),
    (Kind: 'TooManyLinks'; Msg: 'Too many links'),
    (Kind: 'BrokenPipe'; Msg: 'Broken pipe'),
    (Kind: 'Uncategorized'; Msg: 'Numerical argument out of domain'),
    (Kind: 'Uncategorized'; Msg: 'Numerical result out of range'),
    (Kind: 'Deadlock'; Msg: 'Resource deadlock avoided'),
    (Kind: 'InvalidFilename'; Msg: 'File name too long'),
    (Kind: 'Uncategorized'; Msg: 'No locks available'),
    (Kind: 'Unsupported'; Msg: 'Function not implemented'),
    (Kind: 'DirectoryNotEmpty'; Msg: 'Directory not empty'),
    (Kind: 'FilesystemLoop'; Msg: 'Too many levels of symbolic links'),
    (Kind: 'Uncategorized'; Msg: 'Unknown error 41'),
    (Kind: 'Uncategorized'; Msg: 'No message of desired type'),
    (Kind: 'Uncategorized'; Msg: 'Identifier removed'),
    (Kind: 'Uncategorized'; Msg: 'Channel number out of range'),
    (Kind: 'Uncategorized'; Msg: 'Level 2 not synchronized'),
    (Kind: 'Uncategorized'; Msg: 'Level 3 halted'),
    (Kind: 'Uncategorized'; Msg: 'Level 3 reset'),
    (Kind: 'Uncategorized'; Msg: 'Link number out of range'),
    (Kind: 'Uncategorized'; Msg: 'Protocol driver not attached'),
    (Kind: 'Uncategorized'; Msg: 'No CSI structure available'),
    (Kind: 'Uncategorized'; Msg: 'Level 2 halted'),
    (Kind: 'Uncategorized'; Msg: 'Invalid exchange'),
    (Kind: 'Uncategorized'; Msg: 'Invalid request descriptor'),
    (Kind: 'Uncategorized'; Msg: 'Exchange full'),
    (Kind: 'Uncategorized'; Msg: 'No anode'),
    (Kind: 'Uncategorized'; Msg: 'Invalid request code'),
    (Kind: 'Uncategorized'; Msg: 'Invalid slot'),
    (Kind: 'Uncategorized'; Msg: 'Unknown error 58'),
    (Kind: 'Uncategorized'; Msg: 'Bad font file format'),
    (Kind: 'Uncategorized'; Msg: 'Device not a stream'),
    (Kind: 'Uncategorized'; Msg: 'No data available'),
    (Kind: 'Uncategorized'; Msg: 'Timer expired'),
    (Kind: 'Uncategorized'; Msg: 'Out of streams resources'),
    (Kind: 'Uncategorized'; Msg: 'Machine is not on the network'),
    (Kind: 'Uncategorized'; Msg: 'Package not installed'),
    (Kind: 'Uncategorized'; Msg: 'Object is remote'),
    (Kind: 'Uncategorized'; Msg: 'Link has been severed'),
    (Kind: 'Uncategorized'; Msg: 'Advertise error'),
    (Kind: 'Uncategorized'; Msg: 'Srmount error'),
    (Kind: 'Uncategorized'; Msg: 'Communication error on send'),
    (Kind: 'Uncategorized'; Msg: 'Protocol error'),
    (Kind: 'Uncategorized'; Msg: 'Multihop attempted'),
    (Kind: 'Uncategorized'; Msg: 'RFS specific error'),
    (Kind: 'Uncategorized'; Msg: 'Bad message'),
    (Kind: 'Uncategorized'; Msg: 'Value too large for defined data type'),
    (Kind: 'Uncategorized'; Msg: 'Name not unique on network'),
    (Kind: 'Uncategorized'; Msg: 'File descriptor in bad state'),
    (Kind: 'Uncategorized'; Msg: 'Remote address changed'),
    (Kind: 'Uncategorized'; Msg: 'Can not access a needed shared library'),
    (Kind: 'Uncategorized'; Msg: 'Accessing a corrupted shared library'),
    (Kind: 'Uncategorized'; Msg: '.lib section in a.out corrupted'),
    (Kind: 'Uncategorized'; Msg: 'Attempting to link in too many shared libraries'),
    (Kind: 'Uncategorized'; Msg: 'Cannot exec a shared library directly'),
    (Kind: 'Uncategorized'; Msg: 'Invalid or incomplete multibyte or wide character'),
    (Kind: 'Uncategorized'; Msg: 'Interrupted system call should be restarted'),
    (Kind: 'Uncategorized'; Msg: 'Streams pipe error'),
    (Kind: 'Uncategorized'; Msg: 'Too many users'),
    (Kind: 'Uncategorized'; Msg: 'Socket operation on non-socket'),
    (Kind: 'Uncategorized'; Msg: 'Destination address required'),
    (Kind: 'Uncategorized'; Msg: 'Message too long'),
    (Kind: 'Uncategorized'; Msg: 'Protocol wrong type for socket'),
    (Kind: 'Uncategorized'; Msg: 'Protocol not available'),
    (Kind: 'Uncategorized'; Msg: 'Protocol not supported'),
    (Kind: 'Uncategorized'; Msg: 'Socket type not supported'),
    (Kind: 'Uncategorized'; Msg: 'Operation not supported'),
    (Kind: 'Uncategorized'; Msg: 'Protocol family not supported'),
    (Kind: 'Uncategorized'; Msg: 'Address family not supported by protocol'),
    (Kind: 'AddrInUse'; Msg: 'Address already in use'),
    (Kind: 'AddrNotAvailable'; Msg: 'Cannot assign requested address'),
    (Kind: 'NetworkDown'; Msg: 'Network is down'),
    (Kind: 'NetworkUnreachable'; Msg: 'Network is unreachable'),
    (Kind: 'Uncategorized'; Msg: 'Network dropped connection on reset'),
    (Kind: 'ConnectionAborted'; Msg: 'Software caused connection abort'),
    (Kind: 'ConnectionReset'; Msg: 'Connection reset by peer'),
    (Kind: 'Uncategorized'; Msg: 'No buffer space available'),
    (Kind: 'Uncategorized'; Msg: 'Transport endpoint is already connected'),
    (Kind: 'NotConnected'; Msg: 'Transport endpoint is not connected'),
    (Kind: 'Uncategorized'; Msg: 'Cannot send after transport endpoint shutdown'),
    (Kind: 'Uncategorized'; Msg: 'Too many references: cannot splice'),
    (Kind: 'TimedOut'; Msg: 'Connection timed out'),
    (Kind: 'ConnectionRefused'; Msg: 'Connection refused'),
    (Kind: 'Uncategorized'; Msg: 'Host is down'),
    (Kind: 'HostUnreachable'; Msg: 'No route to host'),
    (Kind: 'Uncategorized'; Msg: 'Operation already in progress'),
    (Kind: 'Uncategorized'; Msg: 'Operation now in progress'),
    (Kind: 'StaleNetworkFileHandle'; Msg: 'Stale file handle'),
    (Kind: 'Uncategorized'; Msg: 'Structure needs cleaning'),
    (Kind: 'Uncategorized'; Msg: 'Not a XENIX named type file'),
    (Kind: 'Uncategorized'; Msg: 'No XENIX semaphores available'),
    (Kind: 'Uncategorized'; Msg: 'Is a named type file'),
    (Kind: 'Uncategorized'; Msg: 'Remote I/O error'),
    (Kind: 'FilesystemQuotaExceeded'; Msg: 'Disk quota exceeded'),
    (Kind: 'Uncategorized'; Msg: 'No medium found'),
    (Kind: 'Uncategorized'; Msg: 'Wrong medium type'),
    (Kind: 'Uncategorized'; Msg: 'Operation canceled'),
    (Kind: 'Uncategorized'; Msg: 'Required key not available'),
    (Kind: 'Uncategorized'; Msg: 'Key has expired'),
    (Kind: 'Uncategorized'; Msg: 'Key has been revoked'),
    (Kind: 'Uncategorized'; Msg: 'Key was rejected by service'),
    (Kind: 'Uncategorized'; Msg: 'Owner died'),
    (Kind: 'Uncategorized'; Msg: 'State not recoverable'),
    (Kind: 'Uncategorized'; Msg: 'Operation not possible due to RF-kill'),
    (Kind: 'Uncategorized'; Msg: 'Memory page has hardware error'),
    (Kind: 'Uncategorized'; Msg: 'Unknown error 134')
  );

function OsKind(Code: LongInt): AnsiString;
begin
  if (Code >= Low(ERRNO_TABLE)) and (Code <= High(ERRNO_TABLE)) then
    Result := ERRNO_TABLE[Code].Kind
  else
    Result := 'Uncategorized';
end;

function OsMessage(Code: LongInt): AnsiString;
begin
  if (Code >= Low(ERRNO_TABLE)) and (Code <= High(ERRNO_TABLE)) then
    Result := ERRNO_TABLE[Code].Msg
  else
    Result := 'Unknown error ' + IntToStr(Code);
end;

function LastOsCode: LongInt;
begin
  Result := fpgeterrno;
end;

{$ELSEIF DEFINED(WINDOWS)}

{ sys::pal::windows::decode_error_kind del Rust 1.77.2, medido con el binario
  x86_64-pc-windows-gnu para los codigos 0..15999: los que NO dan
  Uncategorized. }
function OsKind(Code: LongInt): AnsiString;
begin
  case Code of
    2, 3, 15, 53, 67: Result := 'NotFound';
    5, 10013: Result := 'PermissionDenied';
    8, 14: Result := 'OutOfMemory';
    17: Result := 'CrossesDevices';
    19: Result := 'ReadOnlyFilesystem';
    39, 112: Result := 'StorageFull';
    80, 183: Result := 'AlreadyExists';
    87, 10022: Result := 'InvalidInput';
    109, 232: Result := 'BrokenPipe';
    120: Result := 'Unsupported';
    121, 258, 594, 995, 1053, 1121, 1460, 5910, 7012, 7040, 8014, 8226, 9705,
    10060, 13805, 15402, 15403: Result := 'TimedOut';
    123, 161, 206: Result := 'InvalidFilename';
    132: Result := 'NotSeekable';
    145: Result := 'DirectoryNotEmpty';
    170: Result := 'ResourceBusy';
    223: Result := 'FileTooLarge';
    267: Result := 'NotADirectory';
    336: Result := 'IsADirectory';
    1131: Result := 'Deadlock';
    1142: Result := 'TooManyLinks';
    1231, 10051: Result := 'NetworkUnreachable';
    1232, 10065: Result := 'HostUnreachable';
    1295: Result := 'FilesystemQuotaExceeded';
    10035: Result := 'WouldBlock';
    10048: Result := 'AddrInUse';
    10049: Result := 'AddrNotAvailable';
    10050: Result := 'NetworkDown';
    10053: Result := 'ConnectionAborted';
    10054: Result := 'ConnectionReset';
    10057: Result := 'NotConnected';
    10061: Result := 'ConnectionRefused';
  else
    Result := 'Uncategorized';
  end;
end;

{ UTF-16 a UTF-8 a mano: una conversion de la RTL pasaria por la pagina de
  codigos del sistema y el Rust escribe UTF-8 siempre. }
function Utf16ToUtf8(P: PWideChar; N: LongInt): AnsiString;
var i: LongInt; c, d: DWord;
  procedure Put(B: DWord); begin Result := Result + AnsiChar(Byte(B)); end;
begin
  Result := '';
  i := 0;
  while i < N do
  begin
    c := Ord(P[i]); Inc(i);
    if (c >= $D800) and (c <= $DBFF) and (i < N) then
    begin
      d := Ord(P[i]);
      if (d >= $DC00) and (d <= $DFFF) then
      begin
        Inc(i);
        c := $10000 + ((c - $D800) shl 10) + (d - $DC00);
      end;
    end;
    if c < $80 then Put(c)
    else if c < $800 then begin Put($C0 or (c shr 6)); Put($80 or (c and $3F)); end
    else if c < $10000 then
    begin
      Put($E0 or (c shr 12)); Put($80 or ((c shr 6) and $3F)); Put($80 or (c and $3F));
    end
    else
    begin
      Put($F0 or (c shr 18)); Put($80 or ((c shr 12) and $3F));
      Put($80 or ((c shr 6) and $3F)); Put($80 or (c and $3F));
    end;
  end;
end;

{ sys::pal::windows::os::error_string: FormatMessageW con langId 0, sin
  inserts, y trim_end }
function OsMessage(Code: LongInt): AnsiString;
var buf: array[0..2047] of WideChar; n: DWord; fm: DWord;
begin
  n := FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM or FORMAT_MESSAGE_IGNORE_INSERTS,
                      nil, DWord(Code), 0, @buf[0], Length(buf), nil);
  if n = 0 then
  begin
    fm := GetLastError;
    Exit('OS Error ' + IntToStr(Code) + ' (FormatMessageW() returned error ' + IntToStr(fm) + ')');
  end;
  Result := Utf16ToUtf8(@buf[0], LongInt(n));
  while (Length(Result) > 0) and (Result[Length(Result)] in [#9, #10, #11, #12, #13, ' ']) do
    SetLength(Result, Length(Result) - 1);
end;

function LastOsCode: LongInt;
begin
  Result := LongInt(GetLastError);
end;
{$ENDIF}

function FaultOs(Code: LongInt): TDecodeFault;
begin
  Result := FaultIo(ioOs, OsKind(Code), OsMessage(Code));
  Result.OsCode := Code;
  { el Display del Rust: "<mensaje> (os error N)" }
  Result.Msg := Result.Text + ' (os error ' + IntToStr(Code) + ')';
end;

function LastOsFault: TDecodeFault;
begin
  Result := FaultOs(LastOsCode);
end;

function FaultNegativeSeek: TDecodeFault;
begin
{$IF DEFINED(UNIX)}
  Result := FaultOs(22);
{$ELSE}
  Result := FaultOs(131);
{$ENDIF}
end;

{ Que excepcion llega aca, y que se imprime:
    * EDecodeFault: el error ya armado, el caso normal.
    * EOutOfMemory: un SetLength que no pudo; el Rust reserva con try_reserve
      y da out_of_memory().
    * EOSError con codigo: trae el errno / GetLastError de verdad, y el Rust
      ahi tiene un Os(code).
    * cualquier otra (un EReadError de un TStream, un range check): en el
      Rust no existe, es un bug del port. Toda la E/S de los decoders va por
      los helpers de esta unidad (ReadExactOrFault, WriteAllOrFault,
      SeekOrFault...), que lanzan EDecodeFault, asi que esto no deberia pasar
      nunca. Si pasa, sale con forma de io::Error del Rust (para no romper a
      quien parsea el stderr) pero con la clase de FPC adentro, para que se
      vea que es del port: Io(Custom { kind: Other, error: "EReadError: .." }).
      El texto de las herramientas (Msg) sigue siendo el mensaje solo. }
function FaultOfException(X: Exception): TDecodeFault;
begin
  if X is EDecodeFault then Exit(EDecodeFault(X).Fault);
  if X is EOutOfMemory then Exit(FaultOutOfMemory);
  if (X is EOSError) and (EOSError(X).ErrorCode <> 0) then
    Exit(FaultOs(LongInt(EOSError(X).ErrorCode)));
  Result := FaultIo(ioCustom, 'Other', X.ClassName + ': ' + X.Message);
  Result.Msg := X.Message;
end;

function SeekOrFault(S: TStream; Off: Int64; Origin: TSeekOrigin): QWord;
var r: Int64; f: TDecodeFault;
begin
  ClearOsError;
  r := S.Seek(Off, Origin);
  if r < 0 then
  begin
    { -1 sin errno no lo da ningun sistema; si un stream propio lo devuelve,
      es el EINVAL de un seek invalido }
    if LastOsCode <> 0 then f := LastOsFault else f := FaultNegativeSeek;
    raise EDecodeFault.CreateFault(f);
  end;
  Result := QWord(r);
end;

function SeekToOrFault(S: TStream; Off: QWord): QWord;
begin
  if Off > QWord(High(Int64)) then raise EDecodeFault.CreateFault(FaultNegativeSeek);
  Result := SeekOrFault(S, Int64(Off), soBeginning);
end;

function IsIoException(X: Exception): Boolean;
begin
  Result := (X is EStreamError) or (X is EInOutError) or (X is EOSError) or
            (X is EDecodeFault);
end;

{ ------------------------------------------------------------- render --- }

function RustStrDebug(const S: AnsiString): AnsiString;
var i: LongInt; c: AnsiChar;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #0:   Result := Result + '\0';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #13:  Result := Result + '\r';
      #1..#8, #11, #12, #14..#31, #127:
        Result := Result + '\u{' + LowerCase(IntToHex(Ord(c), 1)) + '}';
    else
      Result := Result + c;   { UTF-8 pasa tal cual, como en escape_debug }
    end;
  end;
  Result := Result + '"';
end;

function IoDebug(const F: TDecodeFault): AnsiString;
begin
  case F.IoForm of
    ioOs: Result := 'Os { code: ' + IntToStr(F.OsCode) + ', kind: ' + F.IoKind +
                    ', message: ' + RustStrDebug(F.Text) + ' }';
    ioSimpleMessage: Result := 'Error { kind: ' + F.IoKind + ', message: ' +
                               RustStrDebug(F.Text) + ' }';
    ioCustom: Result := 'Custom { kind: ' + F.IoKind + ', error: ' + RustStrDebug(F.Text) + ' }';
  else
    Result := F.Text;
  end;
end;

function ContDebug(const F: TDecodeFault): AnsiString;
begin
  case F.Cont of
    ckTruncated:                Result := 'Truncated';
    ckNotAnOsrepFile:           Result := 'NotAnOsrepFile';
    ckUnsupportedVersion:       Result := 'UnsupportedVersion(' + IntToStr(F.Num) + ')';
    ckNoFooter:                 Result := 'NoFooter';
    ckUnsupportedFooterVersion: Result := 'UnsupportedFooterVersion(' + IntToStr(F.Num) + ')';
    ckFooterExceedsFile:        Result := 'FooterExceedsFile';
    ckTableMismatch:            Result := 'TableMismatch';
  end;
end;

function FaultDebug(const F: TDecodeFault): AnsiString;
begin
  case F.Kind of
    fkContainer:      Result := 'Container(' + ContDebug(F) + ')';
    fkBadData:        Result := 'BadData(' + RustStrDebug(F.Text) + ')';
    fkNotIoLz:        Result := 'NotIoLz(V' + IntToStr(F.Num) + ')';
    fkNotFutureLz:    Result := 'NotFutureLz(V' + IntToStr(F.Num) + ')';
    fkDigestMismatch: Result := 'DigestMismatch { block: ' + IntToStr(F.Num) + ' }';
    fkIo:
      if F.IoForm = ioRaw then Result := F.Text
      else Result := 'Io(' + IoDebug(F) + ')';
  else
    Result := 'decode failed';
  end;
end;

{ ---------------------------------------------------------- the I/O --- }

procedure ClearOsError;
begin
{$IF DEFINED(UNIX)}
  fpseterrno(0);
{$ELSEIF DEFINED(WINDOWS)}
  SetLastError(0);
{$ENDIF}
end;

{ Con un THandleStream se llama a FileWrite/FileRead directo: el Write del
  stream convierte el -1 en 0 y un 0 no dice si hubo error. }
function RawWrite(S: TStream; const Buf; N: LongInt): LongInt;
begin
  ClearOsError;
  if S is THandleStream then
    Result := FileWrite(THandleStream(S).Handle, Buf, N)
  else
    Result := S.Write(Buf, N);
end;

function RawRead(S: TStream; var Buf; N: LongInt): LongInt;
begin
  ClearOsError;
  if S is THandleStream then
    Result := OsRead(THandleStream(S).Handle, Buf, N)
  else
    Result := S.Read(Buf, N);
end;

procedure WriteAllOrFault(S: TStream; const Buf; Count: QWord);
var done, n: QWord; r: LongInt;
begin
  done := 0;
  while done < Count do
  begin
    n := Count - done;
    if n > SLICE then n := SLICE;
    r := RawWrite(S, PByte(@Buf)[done], LongInt(n));
    if r < 0 then raise EDecodeFault.CreateFault(LastOsFault);
    { write devolvio 0: el WriteZero de write_all, salvo que haya un errno }
    if r = 0 then
    begin
      if LastOsCode <> 0 then raise EDecodeFault.CreateFault(LastOsFault);
      raise EDecodeFault.CreateFault(FaultWriteZero);
    end;
    Inc(done, QWord(r));
  end;
end;

function ReadOnceOrFault(S: TStream; var Buf; Count: LongInt): LongInt;
begin
  Result := RawRead(S, Buf, Count);
  if Result < 0 then raise EDecodeFault.CreateFault(LastOsFault);
end;

function ReadUpToOrFault(S: TStream; var Buf; Count: QWord): QWord;
var n: QWord; r: LongInt;
begin
  Result := 0;
  while Result < Count do
  begin
    n := Count - Result;
    if n > SLICE then n := SLICE;
    r := RawRead(S, PByte(@Buf)[Result], LongInt(n));
    if r < 0 then raise EDecodeFault.CreateFault(LastOsFault);
    if r = 0 then Break;
    Inc(Result, QWord(r));
  end;
end;

procedure ReadExactOrFault(S: TStream; var Buf; Count: QWord);
var done, n: QWord; r: LongInt;
begin
  done := 0;
  while done < Count do
  begin
    n := Count - done;
    if n > SLICE then n := SLICE;
    r := RawRead(S, PByte(@Buf)[done], LongInt(n));
    if r < 0 then raise EDecodeFault.CreateFault(LastOsFault);
    if r = 0 then raise EDecodeFault.CreateFault(FaultReadExact);
    Inc(done, QWord(r));
  end;
end;

end.
