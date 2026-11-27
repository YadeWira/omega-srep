{ A temporary file that the operating system deletes when it is closed,
  also when the process dies: on Unix it is unlinked right after it is
  created (the open handle keeps it alive), on Windows it is opened with
  FILE_FLAG_DELETE_ON_CLOSE.  MIT. }
unit osrep_tempfile;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  { a THandleStream that closes its handle (and so deletes the file) }
  TOsrepTempStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

{ Creates an empty temporary file in Dir ('' = the system's temporary
  directory) for reading and writing.  Raises EOsrepError (code 3) when it
  cannot. }
function OsrepCreateTempStream(const Dir: string): TOsrepTempStream;

implementation

uses
  {$ifdef windows}Windows,{$else}BaseUnix,{$endif} osrep_format;

var
  Counter: LongInt = 0;

destructor TOsrepTempStream.Destroy;
begin
  if Handle <> THandle(-1) then
    FileClose(Handle);
  inherited Destroy;
end;

function OsrepCreateTempStream(const Dir: string): TOsrepTempStream;
var
  Base, Name: string;
  Attempt: Integer;
{$ifdef windows}
  H: THandle;
{$else}
  H: cint;
{$endif}
begin
  Base := Dir;
  if Base = '' then
    Base := GetTempDir(False);
  Base := IncludeTrailingPathDelimiter(Base);
  for Attempt := 1 to 100 do
  begin
    InterLockedIncrement(Counter);
    Name := Base + Format('osrep-%d-%x-%d.tmp',
      [GetProcessID, GetTickCount64 and $FFFFFFFF, Counter]);
{$ifdef windows}
    H := CreateFileW(PWideChar(UnicodeString(Name)),
      GENERIC_READ or GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE, 0);
    if H <> INVALID_HANDLE_VALUE then
      Exit(TOsrepTempStream.Create(H));
    if GetLastError <> ERROR_FILE_EXISTS then
      Break;
{$else}
    H := FpOpen(Name, O_RDWR or O_CREAT or O_EXCL, &600);
    if H >= 0 then
    begin
      FpUnlink(Name);
      Exit(TOsrepTempStream.Create(H));
    end;
    if fpgeterrno <> ESysEEXIST then
      Break;
{$endif}
  end;
  raise EOsrepError.Create(3, 'cannot create a temporary file in ' + Base);
end;

end.
