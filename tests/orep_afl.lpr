{ Coverage-guided fuzzing harness for OREP (AFL++ frida_mode; tests/orep_afl.sh
  builds and runs it).  It reads one file (argv[1]); the first byte picks
  what to do with the rest:

    0  decode: OrepDecodeBuf (memory limit 64 MiB), then the same stream
       through OrepDecRun with the input and output in pieces of sizes taken
       from the second byte; both must give the same verdict and bytes
    1  OrepDecPeek / OrepDecSkip in odd sizes, against OrepDecodeBuf
    2  OrepDecReset: decode, reset, decode again (same result), and the
       stream after a small valid one on the same decoder
    3  round trip: bytes 1..8 are the encoder's parameters (small window and
       chunk), the rest is the input; OrepEncodeBuf and a streamed encode
       with flushes must give the same bytes, and the stream must decode to
       the input

  Any disagreement, a Pascal runtime error or an exception aborts
  (SIGABRT), which AFL counts as a crash.  A stream the decoder rejects is
  not a failure. }

program orep_afl;

{$mode objfpc}{$H+}
{$Q-}{$R-}

uses
  cthreads, BaseUnix, SysUtils, orep;

const
  MEMLIM = QWord(64) shl 20;

procedure Die(const Why: string);
begin
  WriteLn(StdErr, 'orep_afl: ', Why);
  Flush(StdErr);
  FpKill(FpGetPid, SIGABRT);
  Halt(134);
end;

procedure Check(C: Boolean; const Why: string);
begin
  if not C then Die(Why);
end;

function PtrOf(const B: TBytes): PByte;
begin
  if Length(B) = 0 then Result := nil else Result := @B[0];
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

procedure Append(var Acc: TBytes; var AccLen: SizeUInt; P: PByte; N: SizeUInt);
begin
  if N = 0 then Exit;
  if AccLen + N > SizeUInt(Length(Acc)) then
    SetLength(Acc, (AccLen + N) * 2 + 64);
  Move(P^, Acc[AccLen], N);
  Inc(AccLen, N);
end;

function DecBuf(const S: TBytes; out Code: Integer): TBytes;
var
  P: PByte;
  N: SizeUInt;
begin
  Result := nil;
  Code := OrepDecodeBuf(PtrOf(S), Length(S), MEMLIM, P, N);
  if Code = OREP_OK then
  begin
    SetLength(Result, N);
    if N > 0 then Move(P^, Result[0], N);
    FreeMem(P);
  end
  else Check((P = nil) and (N = 0), 'DecodeBuf error with output');
end;

{ OrepDecRun on D with input pieces of InStep and output pieces of
  OutStep; Code is OREP_END, an error, or OREP_OK when it wants more. }
function DecRun(var D: TOrepDec; const S: TBytes; InStep, OutStep: SizeUInt;
  out Code: Integer): TBytes;
var
  OutB: array[0..4095] of Byte;
  Acc: TBytes;
  AccLen, Given, AvailIn, AvailOut, N: SizeUInt;
  NextIn, NextOut: PByte;
  R: Integer;
begin
  Acc := nil; AccLen := 0; Given := 0; AvailIn := 0; NextIn := nil;
  R := OREP_OK;
  repeat
    if (AvailIn = 0) and (Given < SizeUInt(Length(S))) then
    begin
      N := SizeUInt(Length(S)) - Given;
      if N > InStep then N := InStep;
      NextIn := @S[Given];
      AvailIn := N;
      Inc(Given, N);
    end;
    NextOut := @OutB[0];
    AvailOut := OutStep;
    R := OrepDecRun(D, NextIn, AvailIn, NextOut, AvailOut);
    Append(Acc, AccLen, @OutB[0], OutStep - AvailOut);
    if R <> OREP_OK then Break;
    if (AvailIn = 0) and (Given = SizeUInt(Length(S))) and (AvailOut > 0) then
      Break;
  until False;
  Code := R;
  SetLength(Acc, AccLen);
  Result := Acc;
end;

{ the whole-buffer verdict from a streaming one: OREP_END with nothing
  left over is OREP_OK; trailing bytes or a stream that wants more are data
  errors }
function Verdict(R: Integer; Left: Boolean): Integer;
begin
  if R = OREP_END then
  begin
    if Left then Result := OREP_E_DATA else Result := OREP_OK;
  end
  else if R = OREP_OK then Result := OREP_E_DATA
  else Result := R;
end;

function StepOf(B: Byte; Max: SizeUInt): SizeUInt;
const
  Steps: array[0..7] of SizeUInt = (1, 2, 3, 7, 16, 61, 1000, 4096);
begin
  Result := Steps[B and 7];
  if Result > Max then Result := Max;
end;

procedure ModeDecode(const S: TBytes; Sel: Byte);
var
  D: TOrepDec;
  A, B: TBytes;
  CA, CB: Integer;
  InStep, OutStep: SizeUInt;
begin
  A := DecBuf(S, CA);
  InStep := StepOf(Sel, High(SizeUInt));
  OutStep := StepOf(Sel shr 3, 4096);
  OrepDecInit(D, MEMLIM);
  B := DecRun(D, S, InStep, OutStep, CB);
  { trailing bytes: DecRun stops at the end and leaves them unread }
  CB := Verdict(CB, (CB = OREP_END) and (D.InPos <> QWord(Length(S))));
  OrepDecEnd(D);
  Check(CA = CB, Format('verdict buf %d run %d (in %d out %d)', [CA, CB, InStep, OutStep]));
  if CA = OREP_OK then
    Check(SameBytes(A, B), 'buf and run give different bytes');
end;

procedure ModePeek(const S: TBytes; Sel: Byte);
var
  D: TOrepDec;
  A, Acc: TBytes;
  AccLen, AvailIn, Cnt, Take: SizeUInt;
  NextIn, Data: PByte;
  CA, R, K: Integer;
begin
  A := DecBuf(S, CA);
  OrepDecInit(D, MEMLIM);
  NextIn := PtrOf(S);
  AvailIn := Length(S);
  Acc := nil; AccLen := 0; K := 0;
  repeat
    R := OrepDecPeek(D, NextIn, AvailIn, Data, Cnt);
    if Cnt > 0 then
    begin
      Take := StepOf(Byte((Sel + K) and 255), Cnt);
      Inc(K);
      Append(Acc, AccLen, Data, Take);
      OrepDecSkip(D, Take);
    end;
    if (R <> OREP_OK) and (Cnt = 0) then Break;
    if (R = OREP_OK) and (Cnt = 0) and (AvailIn = 0) then Break;
  until False;
  R := Verdict(R, (R = OREP_END) and (AvailIn > 0));
  OrepDecEnd(D);
  Check(R = CA, Format('verdict buf %d peek %d', [CA, R]));
  SetLength(Acc, AccLen);
  if CA = OREP_OK then
    Check(SameBytes(A, Acc), 'buf and peek give different bytes');
end;

var
  Small: TBytes;   { a small valid stream, made at start }

procedure ModeReset(const S: TBytes; Sel: Byte);
var
  D: TOrepDec;
  A, B, C: TBytes;
  CA, CB, CC, CS: Integer;
  Step: SizeUInt;
begin
  Step := StepOf(Sel, High(SizeUInt));
  OrepDecInit(D, MEMLIM);
  A := DecRun(D, S, Step, 4096, CA);
  Check(OrepDecReset(D) = OREP_OK, 'reset 1');
  B := DecRun(D, S, Step, 4096, CB);
  Check((CA = CB) and SameBytes(A, B), 'decode after reset differs');
  { a valid stream after it, on the same decoder (after an error too) }
  Check(OrepDecReset(D) = OREP_OK, 'reset 2');
  C := DecRun(D, Small, 4096, 4096, CS);
  Check(CS = OREP_END, 'small stream after reset');
  Check(OrepDecReset(D) = OREP_OK, 'reset 3');
  C := DecRun(D, S, 4096, 4096, CC);
  Check((CC = CA) and SameBytes(A, C), 'decode after a small stream differs');
  OrepDecEnd(D);
end;

procedure ModeRoundTrip(const S: TBytes);
var
  P: TOrepParams;
  E: TOrepEnc;
  Inp, Enc1, Enc2, Dec: TBytes;
  Dst, NextIn, NextOut: PByte;
  DstLen, AvailIn, AvailOut, Given, N, EncLen: SizeUInt;
  OutB: array[0..999] of Byte;
  R, Code, Mode: Integer;
  FlushAt, InStep, InBefore: SizeUInt;
  Flushed, Pending: Boolean;
  Stall: Integer;
begin
  if Length(S) < 8 then Exit;
  OrepParamsDefault(P);
  P.Window := QWord(1) shl (4 + S[0] mod 14);     { 16 B .. 128 KiB }
  if S[1] and $80 <> 0 then P.Window := P.Window + S[1] * 37;
  P.Chunk := 65536;
  P.MinLen := 16 + S[2] mod 48;
  P.Align := S[3] mod 6;                          { 0 = per block }
  if P.Align > P.MinLen then P.Align := P.MinLen;
  P.Density := 1 + S[4] mod 8;
  P.Cands := 1 + (S[4] shr 3) mod 4;
  P.RunKeep := (S[5] mod 4) * 48;
  if S[5] and $10 <> 0 then P.MinDist := 1 + S[6] * 3;
  FlushAt := S[7] * 97;
  InStep := StepOf(S[6], High(SizeUInt));
  Inp := Copy(S, 8, Length(S) - 8);
  P.Threads := 1;
  { the window EncodeBuf uses (it trims it to the input) }
  P.SizeHint := Length(Inp);
  if P.SizeHint = 0 then P.SizeHint := 1;

  Code := OrepEncodeBuf(PtrOf(Inp), Length(Inp), P, Dst, DstLen);
  Check(Code = OREP_OK, 'EncodeBuf ' + IntToStr(Code));
  SetLength(Enc1, DstLen);
  if DstLen > 0 then Move(Dst^, Enc1[0], DstLen);
  FreeMem(Dst);

  Dec := DecBuf(Enc1, Code);
  Check(Code = OREP_OK, 'decode of an encoded stream ' + IntToStr(Code));
  Check(SameBytes(Dec, Inp), 'round trip differs');

  { streamed, input in pieces, a flush at FlushAt: other blocks, same
    data }
  Check(OrepEncInit(E, P) = OREP_OK, 'EncInit');
  Enc2 := nil; EncLen := 0; Given := 0; AvailIn := 0; NextIn := PtrOf(Inp);
  Flushed := FlushAt > SizeUInt(Length(Inp));
  Stall := 0;
  repeat
    Pending := (not Flushed) and (Given = FlushAt);
    if (AvailIn = 0) and (Given < SizeUInt(Length(Inp))) and not Pending then
    begin
      N := SizeUInt(Length(Inp)) - Given;
      if N > InStep then N := InStep;
      if (not Flushed) and (Given < FlushAt) and (Given + N > FlushAt) then
        N := FlushAt - Given;
      NextIn := @Inp[Given];
      AvailIn := N;
      Inc(Given, N);
      Pending := (not Flushed) and (Given = FlushAt);
    end;
    Pending := Pending and (AvailIn = 0);
    if Pending then Mode := OREP_FLUSH
    else if (AvailIn = 0) and (Given = SizeUInt(Length(Inp))) then
      Mode := OREP_FINISH
    else Mode := OREP_RUN;
    InBefore := AvailIn;
    NextOut := @OutB[0];
    AvailOut := SizeOf(OutB);
    R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut, Mode);
    Append(Enc2, EncLen, @OutB[0], SizeOf(OutB) - AvailOut);
    Check(R >= 0, 'EncRun ' + IntToStr(R));
    if Pending and (AvailOut > 0) then Flushed := True;
    if (InBefore = AvailIn) and (AvailOut = SizeOf(OutB)) and not Pending then
    begin
      Inc(Stall);
      Check(Stall < 100000, 'encoder makes no progress');
    end
    else Stall := 0;
  until R = OREP_END;
  OrepEncEnd(E);
  SetLength(Enc2, EncLen);
  if FlushAt > SizeUInt(Length(Inp)) then
    Check(SameBytes(Enc1, Enc2), 'streamed encode gives other bytes');
  Dec := DecBuf(Enc2, Code);
  Check(Code = OREP_OK, 'decode of a streamed stream ' + IntToStr(Code));
  Check(SameBytes(Dec, Inp), 'streamed round trip differs');
end;

procedure MakeSmall;
var
  P: TOrepParams;
  Src: array[0..299] of Byte;
  Dst: PByte;
  N: SizeUInt;
  I: Integer;
begin
  for I := 0 to High(Src) do Src[I] := Byte(I * 7 mod 50);
  OrepParamsDefault(P);
  P.Window := 4096; P.MinLen := 16; P.Chunk := 65536; P.Threads := 1;
  Check(OrepEncodeBuf(@Src[0], Length(Src), P, Dst, N) = OREP_OK, 'small');
  SetLength(Small, N);
  Move(Dst^, Small[0], N);
  FreeMem(Dst);
end;

procedure RunOne(const FileName: string);
var
  F: File;
  Raw, S: TBytes;
  N: Int64;
begin
  AssignFile(F, FileName);
  Reset(F, 1);
  N := FileSize(F);
  if N > 1 shl 20 then N := 1 shl 20;
  SetLength(Raw, N);
  if N > 0 then BlockRead(F, Raw[0], N);
  CloseFile(F);
  if N < 2 then Exit;
  S := Copy(Raw, 2, N - 2);
  case Raw[0] and 3 of
    0: ModeDecode(S, Raw[1]);
    1: ModePeek(S, Raw[1]);
    2: ModeReset(S, Raw[1]);
    3: ModeRoundTrip(Copy(Raw, 1, N - 1));
  end;
end;

procedure OrepAflOne; public name 'orep_afl_one';
begin
  try
    RunOne(ParamStr(1));
  except
    on X: Exception do
    begin
      DumpExceptionBackTrace(StdErr);
      Die('exception ' + X.ClassName + ': ' + X.Message);
    end;
  end;
end;

procedure AtExit;
begin
  if (ErrorAddr <> nil) or ((ExitCode <> 0) and (ExitCode <> 134)) then
  begin
    WriteLn(StdErr, 'orep_afl: runtime error ', ExitCode);
    Flush(StdErr);
    FpKill(FpGetPid, SIGABRT);
  end;
end;

var
  I: Integer;
begin
  AddExitProc(@AtExit);
  MakeSmall;
  if ParamCount < 1 then
  begin
    WriteLn('usage: orep_afl <file>...');
    Halt(2);
  end;
  for I := 1 to ParamCount do
  begin
    { the persistent loop of AFL (AFL_FRIDA_PERSISTENT_ADDR) re-enters
      orep_afl_one with argv[1]; for a replay every argument is run }
    if I = 1 then OrepAflOne
    else
    begin
      try
        RunOne(ParamStr(I));
      except
        on X: Exception do
    begin
      DumpExceptionBackTrace(StdErr);
      Die('exception ' + X.ClassName + ': ' + X.Message);
    end;
      end;
    end;
  end;
end.
