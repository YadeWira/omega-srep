{ libosrep: OSREP as a shared library with a C interface (include/osrep.h).

    src/lib/build.sh <out dir>   -> libosrep.so / libosrep.dylib / osrep.dll

  The library is a thin ABI layer over osrep_codec, which is the same core
  the CLI uses (v6 container, -m3 hash-chain encoder, Future-LZ reader).
  Every export catches exceptions and returns an osrep.h code; the detail
  is in a thread-local message, osrep_last_error(). }

library osrep;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Classes, osrep_format, osrep_codec;

{$L osrep7z.o}

const
  VERSION_TEXT: PChar = 'OSREP 0.0.2';

type
  {$packrecords c}
  TOsrepCOptions = record
    struct_size: LongWord;
    method: LongInt;
    format: LongInt;
    dedup: LongInt;
    threads: LongInt;
    seed: QWord;
    block_size: QWord;
    max_output: QWord;
    min_match: LongInt;
    chain_depth: LongInt;
    stride: LongInt;
    digest: LongInt;
    reserved: array[0..7] of LongWord;
  end;
  {$packrecords default}
  POsrepCOptions = ^TOsrepCOptions;

  { osrep7z.c's host7z_t }
  THost7z = record
    bstr: function(bytes: Pointer; len: LongWord): Pointer; cdecl;
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    threads: LongInt;
  end;

  { 7-Zip's calling convention for its exports and interfaces }
  HRESULT = LongInt;

procedure osrep7z_host(constref h: THost7z); cdecl; external;
function osrep7z_GetNumberOfMethods(n: PLongWord): HRESULT; cdecl; external;
function osrep7z_GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; cdecl; external;
function osrep7z_CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function osrep7z_CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function osrep7z_CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function osrep7z_GetModuleProp(prop: LongWord; v: Pointer): HRESULT; cdecl; external;

threadvar
  LastError: array[0..511] of Char;

procedure SetLastError(const S: string);
var
  N: Integer;
begin
  N := Length(S);
  if N > High(LastError) then
    N := High(LastError);
  if N > 0 then
    Move(S[1], LastError[0], N);
  LastError[N] := #0;
end;

function HostAlloc(size: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(size);
  except
    Result := nil;
  end;
end;

procedure HostRelease(p: Pointer); cdecl;
begin
  if p <> nil then
    FreeMem(p);
end;

{$ifdef windows}
function SysAllocStringByteLen(s: Pointer; len: LongWord): Pointer;
  stdcall; external 'oleaut32.dll';

function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
begin
  Result := SysAllocStringByteLen(bytes, len);
end;
{$else}
function malloc(size: SizeUInt): Pointer; cdecl; external 'c';

{ 7-Zip's BSTR outside Windows (CPP/Common/MyWindows.cpp): from malloc, a
  32-bit byte count, the bytes, and two zero bytes; 7-Zip frees it }
function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
var
  p: PByte;
begin
  p := malloc(SizeUInt(len) + 4 + 4);
  if p = nil then
    Exit(nil);
  PLongWord(p)^ := len;
  Result := p + 4;
  if len > 0 then
    Move(bytes^, Result^, len);
  FillChar((p + 4 + len)^, 4, 0);
end;
{$endif}

function MapException(E: Exception): LongInt;
begin
  if E is EOsrepApiError then
    Result := EOsrepApiError(E).Code
  else if E is EOsrepError then
    case EOsrepError(E).Code of
      2: Result := OsrepEArg;
      3: Result := OsrepEIo;
      6: Result := OsrepEMemory;
      else Result := OsrepEData;
    end
  else
    Result := OsrepEMemory;
end;

function OptionsFromC(p: POsrepCOptions): TOsrepOptions;
begin
  if p = nil then
    Exit(DefaultOsrepOptions);
  if (p^.struct_size <> 0) and (p^.struct_size <> SizeOf(TOsrepCOptions)) then
    raise EOsrepApiError.Create(OsrepEArg,
      Format('osrep_options.struct_size is %d, expected %d',
        [p^.struct_size, SizeOf(TOsrepCOptions)]));
  if (p^.min_match < 0) or (p^.chain_depth < 0) or (p^.stride < 0) then
    raise EOsrepApiError.Create(OsrepEArg,
      'min_match, chain_depth and stride must not be negative');
  Result := DefaultOsrepOptions;
  Result.Method := p^.method;
  Result.Format := p^.format;
  Result.Dedup := p^.dedup;
  Result.Threads := p^.threads;
  Result.Seed := p^.seed;
  Result.BlockSize := p^.block_size;
  Result.MaxOutput := p^.max_output;
  Result.MinMatch := LongWord(p^.min_match);
  Result.ChainDepth := LongWord(p^.chain_depth);
  Result.Stride := LongWord(p^.stride);
  Result.Digest := p^.digest;
end;

procedure osrep_options_default(o: POsrepCOptions); cdecl;
var
  D: TOsrepOptions;
begin
  if o = nil then
    Exit;
  FillChar(o^, SizeOf(TOsrepCOptions), 0);
  D := DefaultOsrepOptions;
  o^.struct_size := SizeOf(TOsrepCOptions);
  o^.method := D.Method;
  o^.format := D.Format;
  o^.dedup := D.Dedup;
  o^.threads := D.Threads;
  o^.seed := D.Seed;
  o^.block_size := D.BlockSize;
  o^.max_output := D.MaxOutput;
  o^.min_match := LongInt(D.MinMatch);
  o^.chain_depth := LongInt(D.ChainDepth);
  o^.stride := LongInt(D.Stride);
  o^.digest := D.Digest;
end;

function osrep_version: PChar; cdecl;
begin
  Result := VERSION_TEXT;
end;

function osrep_last_error: PChar; cdecl;
begin
  Result := @LastError[0];
end;

function osrep_compress(input: Pointer; inSize: SizeUInt;
  output: PPointer; outSize: PSizeUInt; opt: POsrepCOptions): LongInt; cdecl;
var
  O: TOsrepOptions;
  Data, Res: TBytes;
  P: Pointer;
begin
  if (output = nil) or (outSize = nil) then
  begin
    SetLastError('osrep_compress: output and out_size are required');
    Exit(OsrepEArg);
  end;
  output^ := nil;
  outSize^ := 0;
  try
    if (input = nil) and (inSize > 0) then
      raise EOsrepApiError.Create(OsrepEArg, 'input is nil');
    if inSize > SizeUInt(High(SizeInt)) then
      raise EOsrepApiError.Create(OsrepEMemory, 'input is too large');
    O := OptionsFromC(opt);
    SetLength(Data, SizeInt(inSize));
    if inSize > 0 then
      Move(input^, Data[0], SizeInt(inSize));
    Res := OsrepCompressBytes(Data, O);
    P := GetMem(Length(Res) + 1);
    if P = nil then
      raise EOsrepApiError.Create(OsrepEMemory, 'out of memory');
    if Length(Res) > 0 then
      Move(Res[0], P^, Length(Res));
    output^ := P;
    outSize^ := SizeUInt(Length(Res));
    SetLastError('');
    Result := OsrepOk;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := MapException(E);
    end;
  end;
end;

function osrep_decompress(input: Pointer; inSize: SizeUInt;
  output: PPointer; outSize: PSizeUInt; opt: POsrepCOptions): LongInt; cdecl;
var
  O: TOsrepOptions;
  Data, Res: TBytes;
  P: Pointer;
begin
  if (output = nil) or (outSize = nil) then
  begin
    SetLastError('osrep_decompress: output and out_size are required');
    Exit(OsrepEArg);
  end;
  output^ := nil;
  outSize^ := 0;
  try
    if (input = nil) and (inSize > 0) then
      raise EOsrepApiError.Create(OsrepEArg, 'input is nil');
    if inSize > SizeUInt(High(SizeInt)) then
      raise EOsrepApiError.Create(OsrepEMemory, 'input is too large');
    O := OptionsFromC(opt);
    SetLength(Data, SizeInt(inSize));
    if inSize > 0 then
      Move(input^, Data[0], SizeInt(inSize));
    Res := OsrepDecompressBytes(Data, O);
    P := GetMem(Length(Res) + 1);
    if P = nil then
      raise EOsrepApiError.Create(OsrepEMemory, 'out of memory');
    if Length(Res) > 0 then
      Move(Res[0], P^, Length(Res));
    output^ := P;
    outSize^ := SizeUInt(Length(Res));
    SetLastError('');
    Result := OsrepOk;
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      Result := MapException(E);
    end;
  end;
end;

procedure osrep_free(p: Pointer); cdecl;
begin
  if p <> nil then
    FreeMem(p);
end;

{ the 7-Zip plugin's exports: STDAPI, __stdcall on Windows x86 }
function GetNumberOfMethods(n: PLongWord): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_GetNumberOfMethods(n);
end;

function GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_GetMethodProperty(index, prop, v);
end;

function CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_CreateDecoder(index, iid, obj);
end;

function CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_CreateEncoder(index, iid, obj);
end;

function CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_CreateObject(clsid, iid, obj);
end;

function GetModuleProp(prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := osrep7z_GetModuleProp(prop, v);
end;

exports
  osrep_options_default, osrep_version, osrep_last_error,
  osrep_compress, osrep_decompress, osrep_free,
  GetNumberOfMethods, GetMethodProperty, CreateDecoder, CreateEncoder,
  CreateObject, GetModuleProp;

var
  Host7z: THost7z;

begin
  IsMultiThread := True;
  Host7z.bstr := @MakeBstr;
  Host7z.alloc := @HostAlloc;
  Host7z.release := @HostRelease;
  Host7z.threads := CpuCount;
  if Host7z.threads > 8 then
    Host7z.threads := 8;
  osrep7z_host(Host7z);
end.
