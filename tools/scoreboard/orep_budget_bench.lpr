{ orep_budget_bench <file> <jobs> <tokens> <threads> <spinus> <callerhooks 0|1> [minlen] [try 0|1]
  <jobs> encoders run at once, each on the whole file, sharing <tokens>
  tokens (each job's caller thread holds one while it works). Prints wall
  time. }
program orep_budget_bench;
{$mode objfpc}{$H+}
uses cthreads, SysUtils, Classes, orep;

var
  Busy: LongInt = 0;
  Limit: LongInt = 4;
  Src: TBytes;
  P0: TOrepParams;
  OutSize: array of QWord;

procedure TBusy(Ctx: Pointer);
begin
  repeat
    if InterLockedIncrement(Busy) <= Limit then Exit;
    InterLockedDecrement(Busy);
    Sleep(0);
  until False;
end;

function TTry(Ctx: Pointer): Boolean;
begin
  if InterLockedIncrement(Busy) <= Limit then Exit(True);
  InterLockedDecrement(Busy);
  Result := False;
end;

procedure TIdle(Ctx: Pointer);
begin
  InterLockedDecrement(Busy);
end;

function Job(Arg: Pointer): PtrInt;
var
  E: TOrepEnc;
  InP, OutP: PByte;
  InN, OutN: SizeUInt;
  Buf: array of Byte;
  R: Integer;
  Tot: QWord;
begin
  SetLength(Buf, 1 shl 20);
  TBusy(nil);
  OrepEncInit(E, P0);
  InP := @Src[0]; InN := Length(Src);
  Tot := 0;
  repeat
    OutP := @Buf[0]; OutN := Length(Buf);
    R := OrepEncRun(E, InP, InN, OutP, OutN, OREP_FINISH);
    Inc(Tot, SizeUInt(Length(Buf)) - OutN);
  until R <> OREP_OK;
  OrepEncEnd(E);
  TIdle(nil);
  OutSize[PtrInt(Arg)] := Tot;
  Result := 0;
end;

var
  F: TFileStream;
  Jobs, I: LongInt;
  Ids: array of TThreadID;
  T0: QWord;
begin
  F := TFileStream.Create(ParamStr(1), fmOpenRead);
  SetLength(Src, F.Size);
  F.ReadBuffer(Src[0], F.Size);
  F.Free;
  Jobs := StrToInt(ParamStr(2));
  Limit := StrToInt(ParamStr(3));
  OrepParamsDefault(P0);
  P0.Window := 96 shl 20;
  P0.Threads := StrToInt(ParamStr(4));
  P0.SpinUs := StrToInt(ParamStr(5));
  P0.OnWorkerBusy := @TBusy;
  P0.OnWorkerIdle := @TIdle;
  if ParamStr(6) = '1' then
  begin
    P0.OnCallerWaitBegin := @TIdle;
    P0.OnCallerWaitEnd := @TBusy;
  end;
  if ParamCount >= 7 then P0.MinLen := StrToInt(ParamStr(7));
  if (ParamCount >= 8) and (ParamStr(8) = '1') then P0.OnWorkerTryBusy := @TTry;
  SetLength(Ids, Jobs);
  SetLength(OutSize, Jobs);
  T0 := GetTickCount64;
  for I := 0 to Jobs - 1 do Ids[I] := BeginThread(@Job, Pointer(PtrInt(I)));
  for I := 0 to Jobs - 1 do WaitForThreadTerminate(Ids[I], 0);
  WriteLn(Format('jobs=%d tokens=%d t=%d spin=%s caller=%s l=%d try=%s  %.2f s  out=%d',
    [Jobs, Limit, P0.Threads, ParamStr(5), ParamStr(6), P0.MinLen, ParamStr(8),
     (GetTickCount64 - T0) / 1000, OutSize[0]]));
end.
