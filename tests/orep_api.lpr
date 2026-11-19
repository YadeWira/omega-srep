{ OREP API checks (tests/orep.sh builds and runs it):
  - OrepEncReset gives the same bytes as a new state
  - feeding input in small pieces and draining output into tiny buffers
    gives the same stream as one call
  - OREP_FLUSH in the middle gives a valid stream that decodes to the input
  - OrepEncodeBuf / OrepDecodeBuf round trip, and the decoder's MemLimit

    orep_api <file> [threads] }

program orep_api;

{$mode objfpc}{$H+}

uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes, orep;

var
  Fails: Integer = 0;
  { the thread budget of the hook test }
  HookBusy: LongInt = 0;
  HookMax: LongInt = 0;
  HookCalls: LongInt = 0;
  HookLimit: LongInt = 1;

{ take a token, waiting until one is free }
procedure TestBusy(Ctx: Pointer);
var
  N, M: LongInt;
begin
  InterLockedIncrement(HookCalls);
  repeat
    N := InterLockedIncrement(HookBusy);
    if N <= HookLimit then Break;
    InterLockedDecrement(HookBusy);
    Sleep(1);
  until False;
  repeat
    M := HookMax;
    if N <= M then Break;
  until InterLockedCompareExchange(HookMax, N, M) = M;
  if Ctx = nil then ;
end;

{ take a token only if one is free }
function TestTry(Ctx: Pointer): Boolean;
var
  N, M: LongInt;
begin
  InterLockedIncrement(HookCalls);
  N := InterLockedIncrement(HookBusy);
  if N > HookLimit then
  begin
    InterLockedDecrement(HookBusy);
    Exit(False);
  end;
  repeat
    M := HookMax;
    if N <= M then Break;
  until InterLockedCompareExchange(HookMax, N, M) = M;
  Result := Ctx = Ctx;
end;

procedure TestIdle(Ctx: Pointer);
begin
  InterLockedDecrement(HookBusy);
  if Ctx = nil then ;
end;

{ the caller's thread holds a token too (taken before OrepEncRun); it gives
  it back while it waits for the search }
var
  WaitCalls: LongInt = 0;
  WaitOpen: LongInt = 0;

procedure TestWaitBegin(Ctx: Pointer);
begin
  InterLockedIncrement(WaitCalls);
  Inc(WaitOpen);
  TestIdle(Ctx);
end;

procedure TestWaitEnd(Ctx: Pointer);
begin
  Dec(WaitOpen);
  TestBusy(Ctx);
end;

procedure Check(Ok: Boolean; const What: string);
begin
  if not Ok then
  begin
    WriteLn('FAIL: ', What);
    Inc(Fails);
  end;
end;

function LoadFile(const Name: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

{ encode Src with E (already initialized), feeding InStep bytes at a time
  and draining into OutStep-byte buffers; FlushAt > 0: OREP_FLUSH once
  that many bytes went in }
function EncodeWith(var E: TOrepEnc; const Src: TBytes; InStep,
  OutStep: SizeUInt; FlushAt: SizeUInt): TBytes;
var
  NextIn, NextOut: PByte;
  AvailIn, AvailOut, Given, N: SizeUInt;
  Buf: array of Byte;
  R, Mode: Integer;
  Flushed: Boolean;
begin
  Result := nil;
  SetLength(Buf, OutStep);
  Given := 0;
  NextIn := nil;
  AvailIn := 0;
  Flushed := FlushAt = 0;
  repeat
    if (AvailIn = 0) and (Given < SizeUInt(Length(Src))) then
    begin
      N := InStep;
      if N > SizeUInt(Length(Src)) - Given then N := SizeUInt(Length(Src)) - Given;
      if (not Flushed) and (Given < FlushAt) and (Given + N > FlushAt) then
        N := FlushAt - Given;
      NextIn := @Src[Given];
      AvailIn := N;
      Inc(Given, N);
    end;
    if (AvailIn = 0) and (Given >= SizeUInt(Length(Src))) then Mode := OREP_FINISH
    else if (not Flushed) and (AvailIn = 0) and (Given = FlushAt) then
      Mode := OREP_FLUSH
    else Mode := OREP_RUN;
    NextOut := @Buf[0];
    AvailOut := OutStep;
    R := OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut, Mode);
    N := OutStep - AvailOut;
    if N > 0 then
    begin
      SetLength(Result, Length(Result) + N);
      Move(Buf[0], Result[Length(Result) - N], N);
    end;
    if (Mode = OREP_FLUSH) and (R = OREP_OK) and (AvailOut > 0) then
      Flushed := True;
  until (R <> OREP_OK);
  Check(R = OREP_END, 'encode ended with ' + OrepErrorText(R));
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function Decode(const S: TBytes; MemLimit: QWord; out Code: Integer): TBytes;
var
  P: PByte;
  N: SizeUInt;
begin
  Result := nil;
  if Length(S) = 0 then
  begin
    Code := OREP_E_DATA;
    Exit;
  end;
  Code := OrepDecodeBuf(@S[0], Length(S), MemLimit, P, N);
  if Code = OREP_OK then
  begin
    SetLength(Result, N);
    if N > 0 then Move(P^, Result[0], N);
    FreeMem(P);
  end;
end;

var
  Src, Other, A, B, C, D: TBytes;
  P: TOrepParams;
  E, E2: TOrepEnc;
  Code: Integer;
  BP: PByte;
  BN: SizeUInt;
  InP, OutP: PByte;
  InN, OutN: SizeUInt;
  Lim: LongInt;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: orep_api <file> [threads]');
    Halt(2);
  end;
  Src := LoadFile(ParamStr(1));
  Other := Copy(Src, 0, Length(Src));
  { Other: the second half of Src, then a repeat of its start }
  if Length(Src) >= 2 then
  begin
    SetLength(Other, Length(Src) div 2 + Length(Src) div 4);
    Move(Src[Length(Src) div 2], Other[0], Length(Src) - Length(Src) div 2);
    Move(Src[0], Other[Length(Src) - Length(Src) div 2],
      Length(Other) - (Length(Src) - Length(Src) div 2));
  end;

  OrepParamsDefault(P);
  P.Window := 1 shl 20;
  P.Chunk := 64 * 1024;
  P.MinLen := 32;
  if ParamCount >= 2 then P.Threads := StrToInt(ParamStr(2));

  { one call vs small pieces and tiny output buffers }
  Check(OrepEncInit(E, P) = OREP_OK, 'init');
  A := EncodeWith(E, Src, 1 shl 30, 1 shl 24, 0);
  OrepEncEnd(E);
  Check(OrepEncInit(E, P) = OREP_OK, 'init 2');
  B := EncodeWith(E, Src, 1000, 7, 0);
  OrepEncEnd(E);
  Check(SameBytes(A, B), 'small pieces give a different stream');
  C := Decode(A, 0, Code);
  Check((Code = OREP_OK) and SameBytes(C, Src), 'round trip');

  { reset: the second stream as from a new state }
  Check(OrepEncInit(E, P) = OREP_OK, 'init 3');
  B := EncodeWith(E, Src, 5000, 4096, 0);
  Check(OrepEncReset(E) = OREP_OK, 'reset');
  B := EncodeWith(E, Other, 3000, 999, 0);
  OrepEncEnd(E);
  Check(OrepEncInit(E2, P) = OREP_OK, 'init 4');
  C := EncodeWith(E2, Other, 1 shl 30, 1 shl 24, 0);
  OrepEncEnd(E2);
  Check(SameBytes(B, C), 'reset gives a different stream');
  { reset before the first stream ended }
  Check(OrepEncInit(E, P) = OREP_OK, 'init 5');
  B := EncodeWith(E, Src, 1 shl 30, 1 shl 24, 0);
  Check(OrepEncReset(E) = OREP_OK, 'reset 2');
  B := EncodeWith(E, Src, 777, 333, 0);
  OrepEncEnd(E);
  Check(SameBytes(A, B), 'reset after a full stream differs');

  { flush in the middle: a valid stream for the same data }
  if Length(Src) > 10 then
  begin
    Check(OrepEncInit(E, P) = OREP_OK, 'init 6');
    D := EncodeWith(E, Src, 4096, 4096, Length(Src) div 3);
    OrepEncEnd(E);
    C := Decode(D, 0, Code);
    Check((Code = OREP_OK) and SameBytes(C, Src), 'flushed stream round trip');
  end;

  { thread hooks: a budget of HookLimit tokens for OREP's threads }
  if ParamCount >= 2 then
  begin
    P.OnWorkerBusy := @TestBusy;
    P.OnWorkerIdle := @TestIdle;
    P.HookCtx := @Fails;
    HookLimit := 2;
    Check(OrepEncInit(E, P) = OREP_OK, 'init hooks');
    B := EncodeWith(E, Src, 3000, 2000, 0);
    OrepEncEnd(E);
    Check(SameBytes(A, B), 'hooks change the stream');
    Check(HookBusy = 0, 'busy and idle calls do not match: ' + IntToStr(HookBusy));
    Check(HookMax <= HookLimit, 'more threads busy than tokens');
    { with no data no block is searched and no thread works }
    if (P.Threads >= 2) and (Length(Src) > 0) then
      Check(HookCalls > 0, 'the hooks were never called');
    { the caller's thread in the budget too: 3 tokens for everyone, and
      no spin }
    if P.Threads >= 2 then
    begin
      P.OnCallerWaitBegin := @TestWaitBegin;
      P.OnCallerWaitEnd := @TestWaitEnd;
      P.SpinUs := 0;
      HookLimit := 3;
      HookMax := 0;
      HookCalls := 0;
      TestBusy(nil);                       { the caller's own token }
      Check(OrepEncInit(E, P) = OREP_OK, 'init caller hooks');
      B := EncodeWith(E, Src, 3000, 2000, 0);
      OrepEncEnd(E);
      TestIdle(nil);
      Check(SameBytes(A, B), 'caller hooks change the stream');
      Check(HookBusy = 0, 'caller: busy and idle calls do not match: ' +
        IntToStr(HookBusy));
      Check(HookMax <= HookLimit, 'caller: more threads busy than tokens');
      Check(WaitOpen = 0, 'wait begin and end do not match');
      if Length(Src) > 100000 then
        Check(WaitCalls > 0, 'the caller wait hooks were never called');
      { an encoder ended in the middle of a stream, with a search in flight }
      if Length(Src) > 0 then
      begin
        TestBusy(nil);
        Check(OrepEncInit(E, P) = OREP_OK, 'init end early');
        SetLength(D, Length(Src) + 4096);
        InP := @Src[0]; InN := Length(Src);
        OutP := @D[0]; OutN := Length(D);
        Check(OrepEncRun(E, InP, InN, OutP, OutN, OREP_RUN) = OREP_OK,
          'run before an early end');
        OrepEncEnd(E);
        TestIdle(nil);
        Check(HookBusy = 0, 'early end: busy and idle calls do not match');
      end;
      { workers and coordinator that never wait for a token: with 1 token
        (the caller's) every block is searched inline, with 2 some }
      P.OnWorkerTryBusy := @TestTry;
      for Lim := 1 to 2 do
      begin
        HookLimit := Lim;
        HookMax := 0;
        TestBusy(nil);
        Check(OrepEncInit(E, P) = OREP_OK, 'init try');
        B := EncodeWith(E, Src, 3000, 2000, 0);
        OrepEncEnd(E);
        TestIdle(nil);
        Check(SameBytes(A, B), 'try hooks change the stream');
        Check(HookBusy = 0, 'try: busy and idle calls do not match: ' +
          IntToStr(HookBusy));
        Check(HookMax <= HookLimit, 'try: more threads busy than tokens');
      end;
      P.OnWorkerTryBusy := nil;
      P.OnCallerWaitBegin := nil;
      P.OnCallerWaitEnd := nil;
      P.SpinUs := 2000;
    end;
    P.OnWorkerBusy := nil;
    P.OnWorkerIdle := nil;
  end;

  { whole buffers, and the memory limit }
  if Length(Src) > 0 then
  begin
    Code := OrepEncodeBuf(@Src[0], Length(Src), P, BP, BN);
    Check(Code = OREP_OK, 'EncodeBuf');
    if Code = OREP_OK then
    begin
      SetLength(D, BN);
      Move(BP^, D[0], BN);
      FreeMem(BP);
      C := Decode(D, 0, Code);
      Check((Code = OREP_OK) and SameBytes(C, Src), 'EncodeBuf round trip');
      C := Decode(D, 1024, Code);
      Check(Code = OREP_E_MEM, 'MemLimit 1024 accepted');
    end;
  end;

  if Fails = 0 then WriteLn('orep_api: ok') else Halt(1);
end.
