program osrep;
{ OSREP command line: v6 reader and phase-1b -m3 encoder.

  Exit codes: 0 success, 2 command line, 3 I/O, 4 damaged data. }

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Classes, osrep_format, osrep_decoder, osrep_encoder,
  osrep_dedup;

const
  OsrepVersionText = 'OSREP ' + OsrepProductVersion + ' (' +
    OsrepProductDate + ')';

var
  Mode: string = '';
  PosArgs: array of string;
  EncOptions: TEncoderOptions;
  EncOptionsUsed: Boolean = False;
  DupMode: Boolean = False;

procedure CmdError(const Msg: string);
begin
  WriteLn(StdErr, 'OSREP: ', Msg);
  WriteLn(StdErr, 'try "osrep --help"');
  Halt(2);
end;

procedure Usage;
begin
  WriteLn(OsrepVersionText);
  WriteLn('usage:');
  WriteLn('  osrep -m3 [options] <input> [<output>]');
  WriteLn('  osrep -d <archive> [<output>]');
  WriteLn('  osrep --verify <archive>');
  WriteLn('  osrep -i <archive>');
  WriteLn('  osrep --version');
  WriteLn('encode options:');
  WriteLn('  -bN      block size (default 8mb)');
  WriteLn('  -lN      minimum match length (default 4)');
  WriteLn('  -cN      hash insertion stride (default 1)');
  WriteLn('  -aN[/M]  hash chain depth (default 16)');
  WriteLn('  -tN      encoder threads (default auto, up to 8)');
  WriteLn('  --seed=N deterministic VHASH seed');
  WriteLn('  -hash-   no per-block digest');
  WriteLn('  -dup     deduplicate before encoding');
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

procedure RunDecode;
var
  Reader: TArchiveReader;
  OutStream: TStream;
  OutName: string;
begin
  if Length(PosArgs) < 1 then
    CmdError('-d needs an archive');
  if Length(PosArgs) > 2 then
    CmdError('-d accepts one archive and an optional output');
  if PosArgs[0] = '-' then
    CmdError('stdin input is not implemented yet');

  if Length(PosArgs) = 2 then
    OutName := PosArgs[1]
  else
    OutName := DefaultOutputName(PosArgs[0]);

  Reader := TArchiveReader.Create(PosArgs[0]);
  try
    if OutName = '-' then
      OutStream := THandleStream.Create(1)
    else
      OutStream := TFileStream.Create(OutName, fmCreate);
    try
      Reader.DecodeToStream(OutStream);
    finally
      OutStream.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure RunVerify;
var
  Reader: TArchiveReader;
begin
  if Length(PosArgs) <> 1 then
    CmdError('--verify needs exactly one archive');
  if PosArgs[0] = '-' then
    CmdError('stdin input is not implemented yet');
  Reader := TArchiveReader.Create(PosArgs[0]);
  try
    Reader.Verify;
  finally
    Reader.Free;
  end;
end;

procedure RunInfo;
var
  Reader: TArchiveReader;
  Info: TArchiveInfo;
begin
  if Length(PosArgs) <> 1 then
    CmdError('-i needs exactly one archive');
  if PosArgs[0] = '-' then
    CmdError('stdin input is not implemented yet');
  Reader := TArchiveReader.Create(PosArgs[0]);
  try
    Reader.ReadInfo(Info);
  finally
    Reader.Free;
  end;
  WriteLn('OSREP v6');
  WriteLn('blocks=', Info.BlockCount);
  WriteLn('original_size=', Info.OriginalSize);
  if (Info.Flags and 1) <> 0 then
    WriteLn('restored_size=', Info.OutputSize);
  WriteLn('stat_size=', Info.StatSize);
  WriteLn('meta_size=', Info.MetaSize);
  WriteLn('hash_id=', Info.HashId);
  WriteLn('hash_size=', Info.HashSize);
end;

function DedupChunkerFor(Method: LongInt): TDedupChunker;
begin
  if Method = 1 then
    Result := dcFixedWindow
  else
    Result := dcOrder1;
end;

procedure RunEncode;
var
  InStream, OutStream: TStream;
  BodyStream: TMemoryStream;
  OutName: string;
  Data: TBytes;
  Dedup: TDedupResult;
begin
  if Length(PosArgs) < 1 then
    CmdError('missing input file');
  if Length(PosArgs) > 2 then
    CmdError('compress accepts one input and an optional output');
  if PosArgs[0] = '-' then
    CmdError('stdin input is not implemented yet');

  if Length(PosArgs) = 2 then
    OutName := PosArgs[1]
  else
    OutName := DefaultArchiveName(PosArgs[0]);

  if DupMode then
  begin
    InStream := TFileStream.Create(PosArgs[0], fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Data, SizeInt(InStream.Size));
      if Length(Data) > 0 then
        InStream.ReadBuffer(Data[0], Length(Data));
    finally
      InStream.Free;
    end;
    BuildDedup(Data, DedupChunkerFor(EncOptions.Method), Dedup);
    BodyStream := TMemoryStream.Create;
    try
      if Length(Dedup.Body) > 0 then
        BodyStream.WriteBuffer(Dedup.Body[0], Length(Dedup.Body));
      BodyStream.Position := 0;
      if OutName = '-' then
        OutStream := THandleStream.Create(1)
      else
        OutStream := TFileStream.Create(OutName, fmCreate);
      try
        EncodeToStream(BodyStream, OutStream, EncOptions, Dedup.Meta);
      finally
        OutStream.Free;
      end;
    finally
      BodyStream.Free;
    end;
    Exit;
  end;

  InStream := TFileStream.Create(PosArgs[0], fmOpenRead or fmShareDenyWrite);
  try
    if OutName = '-' then
      OutStream := THandleStream.Create(1)
    else
      OutStream := TFileStream.Create(OutName, fmCreate);
    try
      EncodeToStream(InStream, OutStream, EncOptions);
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

var
  I: Integer;
  A, Rest, HashName: string;
  N: QWord;
  P: Integer;

begin
  {$ifdef windows}
  { the CLI takes UTF-8 paths on every platform, as the library contract }
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  {$endif}
  PosArgs := nil;
  EncOptions := DefaultEncoderOptions;
  try
    I := 1;
    while I <= ParamCount do
    begin
      A := ParamStr(I);
      if A = '--version' then
      begin
        WriteLn(OsrepVersionText);
        Halt(0);
      end
      else if (A = '-h') or (A = '--help') then
      begin
        Usage;
        Halt(0);
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
      else if (A = '-m1') or (A = '-m2') or (A = '-m3') or
              (A = '-m4') or (A = '-m5') then
      begin
        if Mode <> '' then
          CmdError('only one mode can be selected');
        Mode := 'encode';
        EncOptions.Method := StrToInt(Copy(A, 3, 1));
        if EncOptions.Method in [1, 2] then
          DupMode := True;
        EncOptionsUsed := True;
      end
      else if A = '-m0' then
        CmdError('method not implemented yet: ' + A)
      else if Copy(A, 1, 2) = '-t' then
      begin
        if not ParseNumber(Copy(A, 3, MaxInt), N) then
          CmdError('invalid -t thread count: ' + A);
        if N > 64 then
          N := 64;
        EncOptions.Threads := LongInt(N);
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
      Inc(I);
    end;

    if (Mode = '') and (Length(PosArgs) > 0) then
      Mode := 'encode';
    if Mode = '' then
      CmdError('no mode selected');
    if (Mode <> 'encode') and EncOptionsUsed then
      CmdError('encoder options require -m3');

    if Mode = 'd' then
      RunDecode
    else if Mode = 'verify' then
      RunVerify
    else if Mode = 'info' then
      RunInfo
    else
      RunEncode;
    Halt(0);
  except
    on E: EOsrepError do
    begin
      WriteLn(StdErr, 'OSREP: ', E.Message);
      Halt(E.Code);
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, 'OSREP: ', E.Message);
      Halt(3);
    end;
  end;
end.
