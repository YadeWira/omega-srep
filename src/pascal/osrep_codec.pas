unit osrep_codec;
{ Clean Pascal API over the v6 core, used by libosrep and available to any
  Pascal program that does not want the CLI.

  The functions work on memory and raise EOsrepApiError on failure.  The C
  wrapper (src/lib/osrep_lib.pas) translates those errors to osrep.h codes
  and never lets an exception cross the ABI. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, osrep_format, osrep_encoder, osrep_decoder;

const
  OsrepApiVersion = 1;

  { osrep.h error codes }
  OsrepOk = 0;
  OsrepEData = 1;
  OsrepEMemory = 2;
  OsrepEIo = 3;
  OsrepEArg = 4;
  OsrepEVersion = 5;
  OsrepENotTaken = 6;
  OsrepEUnsupported = 7;

  OsrepDefaultBlockSize = QWord(8) * 1024 * 1024;

type
  EOsrepApiError = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer; const AMsg: string);
    property Code: Integer read FCode;
  end;

  TOsrepOptions = record
    Method: LongInt;        { 0 or 3 }
    Format: LongInt;        { 0 or 6 }
    Dedup: LongInt;         { 0; 1 is not implemented for encoding }
    Threads: LongInt;       { accepted; the MVP encoder is single-threaded }
    Seed: QWord;            { 0 = the CLI's default deterministic seed }
    BlockSize: QWord;       { 0 = 8 MiB }
    MaxOutput: QWord;       { 0 = no extra cap when decompressing }
    MinMatch: LongWord;     { 0 = 4 }
    ChainDepth: LongWord;   { 0 = 16 }
    Stride: LongWord;       { 0 = 1 }
    Digest: LongInt;        { -1 = default, 0 = none, 1 = VHASH-128 }
  end;

function DefaultOsrepOptions: TOsrepOptions;
procedure OsrepCheckOptions(const Opt: TOsrepOptions; Encoding: Boolean);
function OsrepCompressBytes(const Data: TBytes;
  const Opt: TOsrepOptions): TBytes;
function OsrepDecompressBytes(const Data: TBytes;
  const Opt: TOsrepOptions): TBytes;
procedure OsrepCompressFile(const InPath, OutPath: string;
  const Opt: TOsrepOptions);
procedure OsrepDecompressFile(const InPath, OutPath: string;
  const Opt: TOsrepOptions);

implementation

constructor EOsrepApiError.Create(ACode: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FCode := ACode;
end;

function DefaultOsrepOptions: TOsrepOptions;
begin
  Result.Method := 3;
  Result.Format := OsrepVersion;
  Result.Dedup := 0;
  Result.Threads := 1;
  Result.Seed := 0;
  Result.BlockSize := OsrepDefaultBlockSize;
  Result.MaxOutput := 0;
  Result.MinMatch := 4;
  Result.ChainDepth := 16;
  Result.Stride := 1;
  Result.Digest := 1;
end;

procedure OsrepCheckOptions(const Opt: TOsrepOptions; Encoding: Boolean);
begin
  if (Opt.Method <> 0) and (Opt.Method <> 3) then
    raise EOsrepApiError.Create(OsrepEUnsupported,
      Format('method %d is not implemented (only -m3)', [Opt.Method]));
  if (Opt.Format <> 0) and (Opt.Format <> OsrepVersion) then
    raise EOsrepApiError.Create(OsrepEUnsupported,
      Format('format %d is not implemented (only v6)', [Opt.Format]));
  if Opt.Dedup < -1 then
    raise EOsrepApiError.Create(OsrepEArg,
      Format('invalid dedup value %d', [Opt.Dedup]));
  if Encoding and (Opt.Dedup = 1) then
    raise EOsrepApiError.Create(OsrepEUnsupported,
      'dedup encoding is not implemented yet');
  if Opt.Threads < 0 then
    raise EOsrepApiError.Create(OsrepEArg,
      Format('invalid thread count %d', [Opt.Threads]));
  if (Opt.Digest < -1) or (Opt.Digest > 1) then
    raise EOsrepApiError.Create(OsrepEArg,
      Format('invalid digest value %d', [Opt.Digest]));
  if Encoding and (Opt.BlockSize > QWord(High(LongInt))) then
    raise EOsrepApiError.Create(OsrepEArg, 'block size is too large');
end;

function OptionsToEncoder(const Opt: TOsrepOptions): TEncoderOptions;
begin
  Result := DefaultEncoderOptions;
  if Opt.BlockSize <> 0 then
    Result.BlockSize := Opt.BlockSize;
  if Opt.MinMatch <> 0 then
    if Opt.MinMatch < 4 then
      Result.MinMatch := 4
    else
      Result.MinMatch := Opt.MinMatch;
  if Opt.ChainDepth <> 0 then
    Result.ChainDepth := Opt.ChainDepth;
  if Opt.Stride <> 0 then
    Result.Stride := Opt.Stride;
  if Opt.Seed = 0 then
    Result.Seed := SeedFromNumber(0)
  else
    Result.Seed := SeedFromNumber(Opt.Seed);
  if Opt.Digest >= 0 then
    Result.UseHash := Opt.Digest <> 0;
end;

function OsrepCompressBytes(const Data: TBytes;
  const Opt: TOsrepOptions): TBytes;
var
  InStream, OutStream: TMemoryStream;
  EncOpt: TEncoderOptions;
begin
  OsrepCheckOptions(Opt, True);
  EncOpt := OptionsToEncoder(Opt);
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      InStream.WriteBuffer(Data[0], Length(Data));
    InStream.Position := 0;
    EncodeToStream(InStream, OutStream, EncOpt);
    if OutStream.Size > Int64(High(SizeInt)) then
      raise EOsrepApiError.Create(OsrepEMemory, 'output does not fit in memory');
    SetLength(Result, SizeInt(OutStream.Size));
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], SizeInt(OutStream.Size));
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

function OsrepDecompressBytes(const Data: TBytes;
  const Opt: TOsrepOptions): TBytes;
var
  InStream: TMemoryStream;
  Reader: TArchiveReader;
  Info: TArchiveInfo;
begin
  OsrepCheckOptions(Opt, False);
  if (Length(Data) >= OsrepHeaderSize) and
     (GetU32LE(Data, 0) = OsrepMagicHeader) and
     (Data[4] > OsrepVersion) then
    raise EOsrepApiError.Create(OsrepEVersion,
      Format('archive version %d is newer than %d',
        [Data[4], OsrepVersion]));
  InStream := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      InStream.WriteBuffer(Data[0], Length(Data));
    InStream.Position := 0;
    Reader := TArchiveReader.CreateFromStream(InStream, False);
    try
      Reader.MaxOutput := Opt.MaxOutput;
      Reader.ReadInfo(Info);
      if (Opt.MaxOutput > 0) and (Info.OutputSize > Opt.MaxOutput) then
        raise EOsrepApiError.Create(OsrepEMemory,
          Format('output size %d exceeds max_output %d',
            [Info.OutputSize, Opt.MaxOutput]));
      Reader.DecodeToBytes(Result);
    finally
      Reader.Free;
    end;
  finally
    InStream.Free;
  end;
end;

procedure OsrepCompressFile(const InPath, OutPath: string;
  const Opt: TOsrepOptions);
var
  InStream, OutStream: TFileStream;
  EncOpt: TEncoderOptions;
begin
  OsrepCheckOptions(Opt, True);
  EncOpt := OptionsToEncoder(Opt);
  try
    InStream := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
      raise EOsrepApiError.Create(OsrepEIo,
        'cannot open input: ' + InPath + ': ' + E.Message);
  end;
  try
    try
      OutStream := TFileStream.Create(OutPath, fmCreate);
    except
      on E: Exception do
        raise EOsrepApiError.Create(OsrepEIo,
          'cannot create output: ' + OutPath + ': ' + E.Message);
    end;
    try
      EncodeToStream(InStream, OutStream, EncOpt);
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

procedure OsrepDecompressFile(const InPath, OutPath: string;
  const Opt: TOsrepOptions);
var
  Reader: TArchiveReader;
  OutStream: TFileStream;
  Info: TArchiveInfo;
begin
  OsrepCheckOptions(Opt, False);
  Reader := TArchiveReader.Create(InPath);
  try
    Reader.MaxOutput := Opt.MaxOutput;
    Reader.ReadInfo(Info);
    if (Opt.MaxOutput > 0) and (Info.OutputSize > Opt.MaxOutput) then
      raise EOsrepApiError.Create(OsrepEMemory,
        Format('output size %d exceeds max_output %d',
          [Info.OutputSize, Opt.MaxOutput]));
    try
      OutStream := TFileStream.Create(OutPath, fmCreate);
    except
      on E: Exception do
        raise EOsrepApiError.Create(OsrepEIo,
          'cannot create output: ' + OutPath + ': ' + E.Message);
    end;
    try
      Reader.DecodeToStream(OutStream);
    finally
      OutStream.Free;
    end;
  finally
    Reader.Free;
  end;
end;

end.
