{ orep: command-line front end of the OREP streaming dedup (MIT).

    orep [options] <in> <out>       encode
    orep -d [options] <in> <out>    decode
    "-" is stdin / stdout. }

program orep_cli;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes, orep;

const
  BufSize = 1 shl 20;

procedure Usage;
begin
  WriteLn(StdErr, 'OREP ', OREP_VERSION_STR,
    ' - streaming long-range dedup for a backend compressor (MIT)');
  WriteLn(StdErr, 'usage: orep [options] <in> <out>     encode');
  WriteLn(StdErr, '       orep -d [options] <in> <out>  decode   ("-" = stdin/stdout)');
  WriteLn(StdErr, 'options:');
  WriteLn(StdErr, '  -w<size>   window (max distance), default 512m; k/m/g suffixes');
  WriteLn(StdErr, '  -l<n>      shortest match, >= 16, default 64 (32 for text)');
  WriteLn(StdErr, '  -b<size>   block size, 64k..64m, default 4m');
  WriteLn(StdErr, '  -a<n>      keep literals aligned to n, default 4 (1 for text)');
  WriteLn(StdErr, '  -s<n>      anchor density 1..64, default 4 (higher: more short matches, slower)');
  WriteLn(StdErr, '  -D<size>   leave matches nearer than this to the backend, default 0');
  WriteLn(StdErr, '  -c<n>      candidates per anchor 1..4, default 4 (1: fastest)');
  WriteLn(StdErr, '  -t<n>      encoder threads, default 1 (the output is the same with any n)');
  WriteLn(StdErr, '  -M<size>   decode: refuse streams that need more memory');
  WriteLn(StdErr, '  -q         quiet');
  Halt(2);
end;

function ParseSize(const S: string; out V: QWord): Boolean;
var
  N: string;
  M: QWord;
  C: Char;
begin
  Result := False;
  if S = '' then Exit;
  M := 1;
  N := S;
  C := LowerCase(S[Length(S)]);
  case C of
    'k': M := 1024;
    'm': M := 1024 * 1024;
    'g': M := 1024 * 1024 * 1024;
  end;
  if M > 1 then N := Copy(S, 1, Length(S) - 1);
  Result := TryStrToQWord(N, V);
  if Result then V := V * M;
end;

function OpenIn(const Name: string): TStream;
begin
  if Name = '-' then Result := THandleStream.Create(StdInputHandle)
  else Result := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
end;

function OpenOut(const Name: string): TStream;
begin
  if Name = '-' then Result := THandleStream.Create(StdOutputHandle)
  else Result := TFileStream.Create(Name, fmCreate);
end;

procedure WriteAll(S: TStream; P: PByte; N: SizeUInt);
begin
  if N > 0 then S.WriteBuffer(P^, N);
end;

var
  P: TOrepParams;
  Decode, Quiet: Boolean;
  MemLimit, V: QWord;
  InName, OutName, A: string;
  I, R: Integer;
  Fin, Fout: TStream;
  InBuf, OutBuf, NextIn, NextOut: PByte;
  AvailIn, AvailOut: SizeUInt;
  E: TOrepEnc;
  D: TOrepDec;
  InTotal, OutTotal: QWord;
  Eof: Boolean;
  T0: QWord;
  Secs: Double;

begin
  OrepParamsDefault(P);
  Decode := False; Quiet := False; MemLimit := 0;
  InName := ''; OutName := '';
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (Length(A) > 1) and (A[1] = '-') then
    begin
      case A[2] of
        'd': Decode := True;
        'q': Quiet := True;
        'w': if ParseSize(Copy(A, 3, 99), V) then P.Window := V else Usage;
        'l': if ParseSize(Copy(A, 3, 99), V) and (V <= 65536) then P.MinLen := V else Usage;
        'b': if ParseSize(Copy(A, 3, 99), V) and (V <= OREP_MAX_CHUNK) then P.Chunk := V else Usage;
        'a': if ParseSize(Copy(A, 3, 99), V) and (V <= 4096) then P.Align := V else Usage;
        's': if ParseSize(Copy(A, 3, 99), V) and (V <= 64) then P.Density := V else Usage;
        'D': if ParseSize(Copy(A, 3, 99), V) then P.MinDist := V else Usage;
        'c': if ParseSize(Copy(A, 3, 99), V) and (V >= 1) and (V <= 4) then P.Cands := V else Usage;
        't': if ParseSize(Copy(A, 3, 99), V) and (V <= 256) then P.Threads := V else Usage;
        'M': if ParseSize(Copy(A, 3, 99), V) then MemLimit := V else Usage;
        'h', '?': Usage;
      else
        Usage;
      end;
    end
    else if InName = '' then InName := A
    else if OutName = '' then OutName := A
    else Usage;
  end;
  if (InName = '') or (OutName = '') then Usage;

  try
    Fin := OpenIn(InName);
  except
    on Ex: Exception do
    begin
      WriteLn(StdErr, 'orep: cannot open ', InName, ': ', Ex.Message);
      Halt(1);
    end;
  end;
  if (not Decode) and (Fin is TFileStream) then P.SizeHint := Fin.Size;
  try
    Fout := OpenOut(OutName);
  except
    on Ex: Exception do
    begin
      WriteLn(StdErr, 'orep: cannot create ', OutName, ': ', Ex.Message);
      Halt(1);
    end;
  end;
  InBuf := GetMem(BufSize);
  OutBuf := GetMem(BufSize);
  T0 := GetTickCount64;
  if Decode then R := OrepDecInit(D, MemLimit)
  else R := OrepEncInit(E, P);
  if R <> OREP_OK then
  begin
    WriteLn(StdErr, 'orep: ', OrepErrorText(R));
    Halt(1);
  end;
  InTotal := 0; OutTotal := 0;
  AvailIn := 0; NextIn := InBuf;
  Eof := False;
  try
    repeat
      if (AvailIn = 0) and not Eof then
      begin
        AvailIn := Fin.Read(InBuf^, BufSize);
        NextIn := InBuf;
        Inc(InTotal, AvailIn);
        if AvailIn = 0 then Eof := True;
      end;
      NextOut := OutBuf;
      AvailOut := BufSize;
      if Decode then
        R := OrepDecRun(D, NextIn, AvailIn, NextOut, AvailOut)
      else if Eof then
        R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut, OREP_FINISH)
      else
        R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut, OREP_RUN);
      WriteAll(Fout, OutBuf, BufSize - AvailOut);
      Inc(OutTotal, BufSize - AvailOut);
      if (R = OREP_OK) and Decode and Eof and (AvailIn = 0) and
        (AvailOut = BufSize) then R := OREP_E_DATA; { truncated }
    until R <> OREP_OK;
    if (R = OREP_END) and Decode and ((AvailIn > 0) or
      (Fin.Read(InBuf^, 1) > 0)) then R := OREP_E_DATA; { trailing bytes }
  except
    on Ex: Exception do
    begin
      WriteLn(StdErr, 'orep: ', Ex.Message);
      Halt(1);
    end;
  end;
  if Decode then OrepDecEnd(D) else OrepEncEnd(E);
  Fout.Free;
  Fin.Free;
  if R <> OREP_END then
  begin
    WriteLn(StdErr, 'orep: ', OrepErrorText(R));
    Halt(1);
  end;
  Secs := (GetTickCount64 - T0) / 1000;
  if not Quiet then
  begin
    Write(StdErr, InTotal, ' -> ', OutTotal);
    if InTotal > 0 then
      Write(StdErr, Format(' (%.2f%%)', [OutTotal * 100.0 / InTotal]));
    if Secs > 0 then
      Write(StdErr, Format(', %.2f s, %.1f MB/s',
        [Secs, (InTotal / 1e6) / Secs]));
    WriteLn(StdErr);
  end;
end.
