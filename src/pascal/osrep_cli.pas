unit osrep_cli;
{ The OSREP command line as a function: the `osrep` program and the
  library's osrep_run() are this code.

    OsrepRunArgs(Args, InH, OutH, ErrH, Close)

  runs one command line (Args without the program name) with "-" bound to
  the given handles (POSIX descriptors, Windows HANDLEs; -1 = the
  process's own standard one) and returns the exit code: 0 success,
  2 command line, 3 I/O or memory, 4 damaged data.  It never ends the
  process; every message goes to ErrH; with Close, the handles it was given
  (not -1) are closed before it returns.  Each call keeps its state on its
  own, so calls may run in parallel, and frees what it allocated.  When a
  call fails, the output file it created (not "-") is deleted. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, osrep_format;

function OsrepRunArgs(const Args: array of string; InH, OutH, ErrH: PtrInt;
  CloseHandles: Boolean): LongInt;

{ the C form (include/osrep.h): argv[0] is the program name, the strings
  are UTF-8 }
function osrep_run(argc: LongInt; argv: PPChar; in_handle, out_handle,
  err_handle: PtrInt): LongInt; cdecl;
function osrep_run_version: PChar; cdecl;

const
  OsrepVersionText = 'OSREP ' + OsrepProductVersion + ' (' +
    OsrepProductDate + ')';

implementation

uses
  {$ifdef windows}Windows,{$else}BaseUnix,{$endif}
  Classes, osrep_decoder, osrep_encoder, osrep_dedup,
  osrep_tempfile;

const
  { stdin up to this size stays in memory; beyond it, the whole input goes
    to a temporary file that the system deletes on close (osrep_tempfile) }
  StdinMemLimit = 32 * 1024 * 1024;
  NoHandle = PtrInt(-1);

type
  { CmdError and the early exits (--help, --version) }
  ECliExit = class(Exception)
  public
    ExitCode: LongInt;
    constructor CreateCode(ACode: LongInt);
  end;

  TOsrepCli = class
  private
    InH, OutH, ErrH: THandle;
    Mode: string;
    PosArgs: array of string;
    EncOptions: TEncoderOptions;
    EncOptionsUsed: Boolean;
    DupMode: Boolean;
    MethodGiven: Boolean;
    TempDir: string;
    procedure WriteTo(H: THandle; const S: string);
    procedure Say(const S: string);
    procedure CmdError(const Msg: string);
    procedure Usage;
    function NewStdinStream: TStream;
    function OpenArchiveReader(const Name: string;
      out StdinStream: TStream): TArchiveReader;
    function CreateOutputStream(const Name: string): TStream;
    procedure DropOutput(const Name: string; var S: TStream);
    procedure RunDecode;
    procedure RunVerify;
    procedure RunInfo;
    procedure RunEncode;
    procedure ParseArgs(const Args: array of string);
  public
    function Run(const Args: array of string): LongInt;
  end;

constructor ECliExit.CreateCode(ACode: LongInt);
begin
  inherited Create('');
  ExitCode := ACode;
end;

function ParseNumber(const S: string; out V: QWord): Boolean;
var
  T: string;
  Code: Integer;
begin
  T := Trim(S);
  if T = '' then
    Exit(False);
  if (Length(T) > 2) and (T[1] = '0') and ((T[2] = 'x') or (T[2] = 'X')) then
    T := '$' + Copy(T, 3, Length(T) - 2);
  Val(T, V, Code);
  Result := Code = 0;
end;

function ParseSize(const S: string; out V: QWord): Boolean;
var
  T: string;
  Mult, N: QWord;
begin
  T := LowerCase(Trim(S));
  Mult := 1;
  if (Length(T) >= 2) and (Copy(T, Length(T) - 1, 2) = 'kb') then
  begin
    Mult := 1024;
    Delete(T, Length(T) - 1, 2);
  end
  else if (Length(T) >= 2) and (Copy(T, Length(T) - 1, 2) = 'mb') then
  begin
    Mult := 1024 * 1024;
    Delete(T, Length(T) - 1, 2);
  end
  else if (Length(T) >= 2) and (Copy(T, Length(T) - 1, 2) = 'gb') then
  begin
    Mult := 1024 * 1024 * 1024;
    Delete(T, Length(T) - 1, 2);
  end
  else if (Length(T) >= 1) and (T[Length(T)] = 'k') then
  begin
    Mult := 1024;
    Delete(T, Length(T), 1);
  end
  else if (Length(T) >= 1) and (T[Length(T)] = 'm') then
  begin
    Mult := 1024 * 1024;
    Delete(T, Length(T), 1);
  end
  else if (Length(T) >= 1) and (T[Length(T)] = 'g') then
  begin
    Mult := 1024 * 1024 * 1024;
    Delete(T, Length(T), 1);
  end;
  if not ParseNumber(T, N) then
    Exit(False);
  if (Mult <> 0) and (N > High(QWord) div Mult) then
    Exit(False);
  V := N * Mult;
  Result := True;
end;

function DefaultOutputName(const InputName: string): string;
begin
  if LowerCase(Copy(InputName, Length(InputName) - 3, 4)) = '.osr' then
    Result := Copy(InputName, 1, Length(InputName) - 4)
  else
    Result := InputName + '.out';
end;

function DefaultArchiveName(const InputName: string): string;
begin
  Result := InputName + '.osr';
end;

function StdHandle(N: Integer): THandle;
begin
{$ifdef windows}
  case N of
    0: Result := GetStdHandle(STD_INPUT_HANDLE);
    1: Result := GetStdHandle(STD_OUTPUT_HANDLE);
  else
    Result := GetStdHandle(STD_ERROR_HANDLE);
  end;
{$else}
  Result := THandle(N);
{$endif}
end;

{ the whole text in one write per call, through the handle (no Text buffer
  shared with the host program); a failed write is not an error here }
procedure TOsrepCli.WriteTo(H: THandle; const S: string);
var
  P: PChar;
  Left, N: LongInt;
begin
  P := PChar(S);
  Left := Length(S);
  while Left > 0 do
  begin
    N := FileWrite(H, P^, Left);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Dec(Left, N);
  end;
end;

procedure TOsrepCli.Say(const S: string);
begin
  WriteTo(OutH, S + LineEnding);
end;

procedure TOsrepCli.CmdError(const Msg: string);
begin
  WriteTo(ErrH, 'OSREP: ' + Msg + LineEnding + 'try "osrep --help"' +
    LineEnding);
  raise ECliExit.CreateCode(2);
end;

procedure TOsrepCli.Usage;
begin
  Say(OsrepVersionText);
  Say('usage:');
  Say('  osrep [-m6] [options] <input> [<output>]');
  Say('  osrep -d <archive> [<output>]');
  Say('  osrep --verify <archive>');
  Say('  osrep -i <archive>');
  Say('  osrep --version');
  Say('methods: -m6 long range, format v7 (default); -m0..-m5 block LZ, v6');
  Say('encode options:');
  Say('  -bN      block size (default 8mb)');
  Say('  -lN      minimum match length (default 512 with -m6, 4 with -m0..-m5;');
  Say('           -m6 -l32 --align=1 without a backend)');
  Say('  -cN      hash insertion stride (default 1)');
  Say('  -aN[/M]  hash chain depth (default 16)');
  Say('  -tN      encoder threads (default auto, up to 8)');
  Say('  -memN    encoder memory budget, N is MB (or use kb/mb/gb)');
  Say('  --align=N -m6: match lengths are multiples of N (default 16;');
  Say('           1 for plain LZ77 backends such as zpaq -m1)');
  Say('  --seed=N deterministic VHASH seed');
  Say('  -hash-   no per-block digest');
  Say('  -dup     deduplicate before encoding');
  Say('  input -  stdin, output -  stdout');
  Say('  --temp=DIR  stdin over 32 MiB goes to a temporary file in DIR');
  Say('              (default the system''s); it is deleted on exit');
end;

{ All of stdin in a seekable stream: in memory up to StdinMemLimit, else in
  a temporary file in TempDir (deleted when the stream is freed, or by the
  system if the process dies). }
function TOsrepCli.NewStdinStream: TStream;
var
  H: THandleStream;
  M: TMemoryStream;
  T: TStream;
  Buf: array of Byte;
  N: LongInt;
begin
  SetLength(Buf, 65536);
  M := TMemoryStream.Create;
  T := nil;
  H := THandleStream.Create(InH);
  try
    try
      repeat
        N := H.Read(Buf[0], Length(Buf));
        if N > 0 then
        begin
          if (T = nil) and (M.Size + N > StdinMemLimit) then
          begin
            T := OsrepCreateTempStream(TempDir);
            if M.Size > 0 then
              T.WriteBuffer(M.Memory^, M.Size);
            FreeAndNil(M);
          end;
          if T <> nil then
            T.WriteBuffer(Buf[0], N)
          else
            M.WriteBuffer(Buf[0], N);
        end;
      until N <= 0;
    except
      M.Free;
      T.Free;
      raise;
    end;
  finally
    H.Free;
  end;
  if T <> nil then
    Result := T
  else
    Result := M;
  Result.Position := 0;
end;

function TOsrepCli.OpenArchiveReader(const Name: string;
  out StdinStream: TStream): TArchiveReader;
begin
  StdinStream := nil;
  if Name = '-' then
  begin
    StdinStream := NewStdinStream;
    try
      Result := TArchiveReader.CreateFromStream(StdinStream, False);
    except
      FreeAndNil(StdinStream);
      raise;
    end;
  end
  else
    Result := TArchiveReader.Create(Name);
end;

function TOsrepCli.CreateOutputStream(const Name: string): TStream;
begin
  if Name = '-' then
    Result := THandleStream.Create(OutH)
  else
    Result := TFileStream.Create(Name, fmCreate);
end;

{ after a failure: close the output and delete it if it is a file }
procedure TOsrepCli.DropOutput(const Name: string; var S: TStream);
begin
  try
    FreeAndNil(S);
  except
    S := nil;
  end;
  if Name <> '-' then
    SysUtils.DeleteFile(Name);
end;

procedure TOsrepCli.RunDecode;
var
  Reader: TArchiveReader;
  OutStream: TStream;
  OutName: string;
  StdinStream: TStream;
begin
  if Length(PosArgs) < 1 then
    CmdError('-d needs an archive');
  if Length(PosArgs) > 2 then
    CmdError('-d accepts one archive and an optional output');

  if Length(PosArgs) = 2 then
    OutName := PosArgs[1]
  else if PosArgs[0] = '-' then
    OutName := '-'
  else
    OutName := DefaultOutputName(PosArgs[0]);

  Reader := OpenArchiveReader(PosArgs[0], StdinStream);
  try
    OutStream := CreateOutputStream(OutName);
    try
      Reader.DecodeToStream(OutStream);
      FreeAndNil(OutStream);
    except
      DropOutput(OutName, OutStream);
      raise;
    end;
  finally
    Reader.Free;
    StdinStream.Free;
  end;
end;

procedure TOsrepCli.RunVerify;
var
  Reader: TArchiveReader;
  StdinStream: TStream;
begin
  if Length(PosArgs) <> 1 then
    CmdError('--verify needs exactly one archive');
  Reader := OpenArchiveReader(PosArgs[0], StdinStream);
  try
    Reader.Verify;
  finally
    Reader.Free;
    StdinStream.Free;
  end;
end;

procedure TOsrepCli.RunInfo;
var
  Reader: TArchiveReader;
  Info: TArchiveInfo;
  StdinStream: TStream;
begin
  if Length(PosArgs) <> 1 then
    CmdError('-i needs exactly one archive');
  Reader := OpenArchiveReader(PosArgs[0], StdinStream);
  try
    Reader.ReadInfo(Info);
  finally
    Reader.Free;
    StdinStream.Free;
  end;
  Say('OSREP v6');
  Say('blocks=' + IntToStr(Info.BlockCount));
  Say('max_match=' + IntToStr(Info.MaxMatch));
  Say('original_size=' + IntToStr(Info.OriginalSize));
  if (Info.Flags and 1) <> 0 then
    Say('restored_size=' + IntToStr(Info.OutputSize));
  Say('stat_size=' + IntToStr(Info.StatSize));
  Say('meta_size=' + IntToStr(Info.MetaSize));
  Say('hash_id=' + IntToStr(Info.HashId));
  Say('hash_size=' + IntToStr(Info.HashSize));
end;

function DedupChunkerFor(Method: LongInt): TDedupChunker;
begin
  if Method = 1 then
    Result := dcFixedWindow
  else
    Result := dcOrder1;
end;

procedure TOsrepCli.RunEncode;
var
  InStream, OutStream: TStream;
  BodyStream: TMemoryStream;
  OutName: string;
  Data: TBytes;
  Dedup: TDedupResult;

  procedure ReadAllInput;
  var
    S: TStream;
  begin
    if PosArgs[0] = '-' then
      S := NewStdinStream
    else
      S := TFileStream.Create(PosArgs[0], fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Data, SizeInt(S.Size));
      if Length(Data) > 0 then
        S.ReadBuffer(Data[0], Length(Data));
    finally
      S.Free;
    end;
  end;

begin
  if Length(PosArgs) < 1 then
    CmdError('missing input file');
  if Length(PosArgs) > 2 then
    CmdError('compress accepts one input and an optional output');
  if Length(PosArgs) = 2 then
    OutName := PosArgs[1]
  else if PosArgs[0] = '-' then
    OutName := '-'
  else
    OutName := DefaultArchiveName(PosArgs[0]);

  if DupMode then
  begin
    ReadAllInput;
    BuildDedup(Data, DedupChunkerFor(EncOptions.Method), Dedup);
    Data := nil;
    BodyStream := TMemoryStream.Create;
    try
      if Length(Dedup.Body) > 0 then
        BodyStream.WriteBuffer(Dedup.Body[0], Length(Dedup.Body));
      Dedup.Body := nil;
      BodyStream.Position := 0;
      OutStream := CreateOutputStream(OutName);
      try
        EncodeToStream(BodyStream, OutStream, EncOptions, Dedup.Meta);
        FreeAndNil(OutStream);
      except
        DropOutput(OutName, OutStream);
        raise;
      end;
    finally
      BodyStream.Free;
    end;
    Exit;
  end;

  if PosArgs[0] = '-' then
    InStream := NewStdinStream
  else
    InStream := TFileStream.Create(PosArgs[0], fmOpenRead or fmShareDenyWrite);
  try
    OutStream := CreateOutputStream(OutName);
    try
      EncodeToStream(InStream, OutStream, EncOptions);
      FreeAndNil(OutStream);
    except
      DropOutput(OutName, OutStream);
      raise;
    end;
  finally
    InStream.Free;
  end;
end;

procedure TOsrepCli.ParseArgs(const Args: array of string);
var
  I: Integer;
  A, Rest, HashName: string;
  N: QWord;
  P: Integer;
begin
  for I := 0 to High(Args) do
  begin
    A := Args[I];
    if A = '--version' then
    begin
      Say(OsrepVersionText);
      raise ECliExit.CreateCode(0);
    end
    else if (A = '-h') or (A = '--help') then
    begin
      Usage;
      raise ECliExit.CreateCode(0);
    end
    else if A = '-d' then
    begin
      if Mode <> '' then
        CmdError('only one mode can be selected');
      Mode := 'd';
    end
    else if A = '--verify' then
    begin
      if Mode <> '' then
        CmdError('only one mode can be selected');
      Mode := 'verify';
    end
    else if A = '-i' then
    begin
      if Mode <> '' then
        CmdError('only one mode can be selected');
      Mode := 'info';
    end
    else if (A = '-m0') or (A = '-m1') or (A = '-m2') or (A = '-m3') or
            (A = '-m4') or (A = '-m5') or (A = '-m6') then
    begin
      if Mode <> '' then
        CmdError('only one mode can be selected');
      Mode := 'encode';
      EncOptions.Method := StrToInt(Copy(A, 3, 1));
      MethodGiven := True;
      if EncOptions.Method in [1, 2] then
        DupMode := True;
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 2) = '-t' then
    begin
      if not ParseNumber(Copy(A, 3, MaxInt), N) then
        CmdError('invalid -t thread count: ' + A);
      if N > 64 then
        N := 64;
      EncOptions.Threads := LongInt(N);
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 4) = '-mem' then
    begin
      Rest := Copy(A, 5, MaxInt);
      if (Rest <> '') and (Rest[1] = '=') then
        Delete(Rest, 1, 1);
      if (Rest = '') or not ParseSize(Rest, N) or (N = 0) then
        CmdError('invalid -mem budget: ' + A);
      { a bare number is megabytes: -mem128 = 128 MB, -mem2gb = 2 GB. }
      if (Rest[Length(Rest)] >= '0') and (Rest[Length(Rest)] <= '9') then
        N := N * 1024 * 1024;
      EncOptions.MemLimit := N;
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 2) = '-b' then
    begin
      if not ParseSize(Copy(A, 3, MaxInt), N) or (N = 0) then
        CmdError('invalid -b block size: ' + A);
      EncOptions.BlockSize := N;
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 2) = '-l' then
    begin
      if not ParseSize(Copy(A, 3, MaxInt), N) or (N = 0) then
        CmdError('invalid -l minimum match: ' + A);
      if N < 4 then
        N := 4;
      EncOptions.MinMatch := LongWord(N);
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 2) = '-c' then
    begin
      if not ParseNumber(Copy(A, 3, MaxInt), N) or (N = 0) then
        CmdError('invalid -c stride: ' + A);
      EncOptions.Stride := LongWord(N);
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 2) = '-a' then
    begin
      Rest := Copy(A, 3, MaxInt);
      P := Pos('/', Rest);
      if P > 0 then
        Rest := Copy(Rest, 1, P - 1);
      if not ParseNumber(Rest, N) or (N = 0) then
        CmdError('invalid -a chain depth: ' + A);
      EncOptions.ChainDepth := LongWord(N);
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 8) = '--align=' then
    begin
      if not ParseNumber(Copy(A, 9, MaxInt), N) or (N = 0) or (N > 4096) then
        CmdError('invalid --align (1..4096): ' + A);
      EncOptions.Align := LongWord(N);
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 7) = '--temp=' then
    begin
      TempDir := Copy(A, 8, MaxInt);
      if (TempDir = '') or not DirectoryExists(TempDir) then
        CmdError('--temp: not a directory: ' + TempDir);
    end
    else if Copy(A, 1, 7) = '--seed=' then
    begin
      if not ParseNumber(Copy(A, 8, MaxInt), N) then
        CmdError('invalid --seed value');
      EncOptions.Seed := SeedFromNumber(N);
      EncOptionsUsed := True;
    end
    else if A = '-hash-' then
    begin
      EncOptions.UseHash := False;
      EncOptionsUsed := True;
    end
    else if Copy(A, 1, 6) = '-hash=' then
    begin
      HashName := LowerCase(Copy(A, 7, MaxInt));
      if (HashName = 'vmac') or (HashName = 'vhash') or (HashName = 'on') then
        EncOptions.UseHash := True
      else if (HashName = 'none') or (HashName = '-') then
        EncOptions.UseHash := False
      else
        CmdError('unsupported hash: ' + HashName);
      EncOptionsUsed := True;
    end
    else if A = '-dup' then
    begin
      DupMode := True;
      EncOptionsUsed := True;
    end
    else if (A <> '') and (A[1] = '-') and (A <> '-') then
      CmdError('unknown option: ' + A)
    else
    begin
      SetLength(PosArgs, Length(PosArgs) + 1);
      PosArgs[High(PosArgs)] := A;
    end;
  end;

  if (Mode = '') and (Length(PosArgs) > 0) then
    Mode := 'encode';
  if Mode = '' then
    CmdError('no mode selected');
  if (Mode <> 'encode') and EncOptionsUsed then
    CmdError('encoder options require an encode mode (-m0..-m6)');
  { The default method is -m6 (long range, v7); -dup alone, which -m6 does
    not combine with, keeps the old default -m3. }
  if not MethodGiven then
    if DupMode then
      EncOptions.Method := 3
    else
      EncOptions.Method := 6;
end;

function TOsrepCli.Run(const Args: array of string): LongInt;
begin
  Result := 0;
  PosArgs := nil;
  EncOptions := DefaultEncoderOptions;
  try
    ParseArgs(Args);
    if Mode = 'd' then
      RunDecode
    else if Mode = 'verify' then
      RunVerify
    else if Mode = 'info' then
      RunInfo
    else
      RunEncode;
  except
    on E: ECliExit do
      Result := E.ExitCode;
    on E: EOsrepError do
    begin
      WriteTo(ErrH, 'OSREP: ' + E.Message + LineEnding);
      Result := E.Code;
    end;
    on E: Exception do
    begin
      WriteTo(ErrH, 'OSREP: ' + E.Message + LineEnding);
      Result := 3;
    end;
  end;
end;

procedure CloseGiven(H: PtrInt);
begin
  if H = NoHandle then
    Exit;
{$ifdef windows}
  CloseHandle(THandle(H));
{$else}
  fpClose(cint(H));
{$endif}
end;

function OsrepRunArgs(const Args: array of string; InH, OutH, ErrH: PtrInt;
  CloseHandles: Boolean): LongInt;
var
  Cli: TOsrepCli;
begin
  Result := 3;
  try
    Cli := TOsrepCli.Create;
    try
      if InH = NoHandle then Cli.InH := StdHandle(0) else Cli.InH := THandle(InH);
      if OutH = NoHandle then Cli.OutH := StdHandle(1) else Cli.OutH := THandle(OutH);
      if ErrH = NoHandle then Cli.ErrH := StdHandle(2) else Cli.ErrH := THandle(ErrH);
      Result := Cli.Run(Args);
    finally
      Cli.Free;
    end;
  except
    Result := 3;
  end;
  if CloseHandles then
  begin
    CloseGiven(InH);
    if OutH <> InH then
      CloseGiven(OutH);
    if (ErrH <> InH) and (ErrH <> OutH) then
      CloseGiven(ErrH);
  end;
end;

function osrep_run(argc: LongInt; argv: PPChar; in_handle, out_handle,
  err_handle: PtrInt): LongInt; cdecl;
var
  Args: array of string;
  U: UTF8String;
  I: LongInt;
begin
  Args := nil;
  try
    if (argv <> nil) and (argc > 1) then
    begin
      SetLength(Args, argc - 1);
      for I := 1 to argc - 1 do
        if argv[I] <> nil then
        begin
          U := UTF8String(argv[I]);
          SetCodePage(RawByteString(U), CP_UTF8, False);
          Args[I - 1] := string(U);
        end;
    end;
  except
    Args := nil;
    CloseGiven(in_handle);
    if out_handle <> in_handle then
      CloseGiven(out_handle);
    if (err_handle <> in_handle) and (err_handle <> out_handle) then
      CloseGiven(err_handle);
    Exit(3);
  end;
  Result := OsrepRunArgs(Args, in_handle, out_handle, err_handle, True);
end;

const
  RunVersionText: PChar = OsrepVersionText;

function osrep_run_version: PChar; cdecl;
begin
  Result := RunVersionText;
end;

end.
