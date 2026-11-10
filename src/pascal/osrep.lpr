program osrep;
{ OSREP command line, phase 1a: v6 reader only.

  Exit codes: 0 success, 2 command line, 3 I/O, 4 damaged data. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, osrep_format, osrep_decoder;

const
  OsrepVersionText = 'OSREP 0.0.2 (2026-11-10)';

var
  Mode: string = '';
  PosArgs: array of string;

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
  WriteLn('  osrep -d <archive> [<output>]');
  WriteLn('  osrep --verify <archive>');
  WriteLn('  osrep -i <archive>');
  WriteLn('  osrep --version');
end;

function DefaultOutputName(const InputName: string): string;
begin
  if LowerCase(Copy(InputName, Length(InputName) - 3, 4)) = '.osr' then
    Result := Copy(InputName, 1, Length(InputName) - 4)
  else
    Result := InputName + '.out';
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
  WriteLn('stat_size=', Info.StatSize);
  WriteLn('meta_size=', Info.MetaSize);
  WriteLn('hash_id=', Info.HashId);
  WriteLn('hash_size=', Info.HashSize);
end;

var
  I: Integer;
  A: string;

begin
  PosArgs := nil;
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
      else if (A = '-h') or (A = '--help') then
      begin
        Usage;
        Halt(0);
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

    if Mode = '' then
      CmdError('no mode selected');
    if Mode = 'd' then
      RunDecode
    else if Mode = 'verify' then
      RunVerify
    else
      RunInfo;
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
