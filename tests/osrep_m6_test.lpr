{ Tests of src/pascal/osrep_m6.pas (the embeddable -m6 / v7 API).

    osrep_m6_test enc <in> <out> <minlen> <align> <block> <digest 0/1>
    osrep_m6_test dec <in.osr> <out>
    osrep_m6_test self            built-in checks (exit 1 on a failure)
    osrep_m6_test reject <file>   the file must decode with an error

  tests/osrep_m6.sh runs them against the CLI and both builds. }
program osrep_m6_test;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif} SysUtils, Classes, osrep_m6;

var
  Fails: Integer = 0;
  Checks: Int64 = 0;

procedure Check(Cond: Boolean; const What: string);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Fails);
    if Fails <= 30 then
      WriteLn(StdErr, 'FAIL: ', What);
  end;
end;

function LoadFile(const Name: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then
      F.ReadBuffer(Result[0], Length(Result));
  finally
    F.Free;
  end;
end;

procedure SaveFile(const Name: string; P: PByte; Len: QWord);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmCreate);
  try
    if Len > 0 then
      F.WriteBuffer(P^, Len);
  finally
    F.Free;
  end;
end;

function BytesPtr(const B: TBytes): PByte;
begin
  if Length(B) = 0 then
    Result := nil
  else
    Result := @B[0];
end;

function Encode(const Src: TBytes; const P: TOsrepM6Params;
  out R: LongInt): TBytes;
var
  Cap, Len: QWord;
begin
  Cap := OsrepM6Bound(Length(Src), P);
  SetLength(Result, Cap);
  R := OsrepM6Encode(BytesPtr(Src), Length(Src), @Result[0], Cap, Len, P);
  if R = OSREP_M6_OK then
    SetLength(Result, Len)
  else
    Result := nil;
end;

function Decode(const S: TBytes; out R: LongInt): TBytes;
var
  Orig: QWord;
begin
  Result := nil;
  R := OsrepM6OrigSize(BytesPtr(S), Length(S), Orig);
  if R <> OSREP_M6_OK then
    Exit;
  if Orig > 1 shl 30 then
  begin
    R := OSREP_M6_E_MEM;
    Exit;
  end;
  SetLength(Result, Orig);
  { a non-nil pointer even for an empty output }
  if Orig = 0 then
    R := OsrepM6Decode(BytesPtr(S), Length(S), PByte(@R), 0)
  else
    R := OsrepM6Decode(BytesPtr(S), Length(S), @Result[0], Orig);
end;

function Same(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

{ inputs: empty, tiny, runs, random, repeated text with edits, data with
  repeats far apart and across blocks }
function MakeInput(Kind: Integer; Size: Integer; Seed: LongWord): TBytes;
var
  I, J, K: Integer;
  X: LongWord;
  Base: TBytes;
begin
  X := Seed * 2654435761 + 1;
  SetLength(Result, Size);
  case Kind of
    0: ;
    1: for I := 0 to Size - 1 do
         Result[I] := Byte(I div 1000);
    2: for I := 0 to Size - 1 do
       begin
         X := X * 1103515245 + 12345;
         Result[I] := Byte(X shr 16);
       end;
  else
    begin
      { a random base of 40 KB repeated with edits, and random gaps }
      SetLength(Base, 40000);
      for I := 0 to High(Base) do
      begin
        X := X * 1103515245 + 12345;
        Base[I] := Byte(X shr 16);
      end;
      I := 0;
      K := 0;
      while I < Size do
      begin
        X := X * 1103515245 + 12345;
        if (X shr 20) and 3 = 0 then
        begin
          { a random gap }
          J := 100 + Integer((X shr 8) mod 3000);
          while (J > 0) and (I < Size) do
          begin
            X := X * 1103515245 + 12345;
            Result[I] := Byte(X shr 16);
            Inc(I);
            Dec(J);
          end;
        end
        else
        begin
          J := Integer((X shr 4) mod 20000);
          while (J < Length(Base)) and (I < Size) do
          begin
            Result[I] := Base[J];
            Inc(I);
            Inc(J);
          end;
          Base[(K * 7919) mod Length(Base)] := Byte(K);
          Inc(K);
        end;
      end;
    end;
  end;
end;

type
  TWorker = class(TThread)
  public
    Input: TBytes;
    P: TOsrepM6Params;
    Expect: TBytes;
    Ok: Boolean;
    procedure Execute; override;
  end;

procedure TWorker.Execute;
var
  S, D: TBytes;
  R, I: LongInt;
begin
  Ok := True;
  for I := 1 to 3 do
  begin
    S := Encode(Input, P, R);
    if (R <> OSREP_M6_OK) or not Same(S, Expect) then
      Ok := False;
    D := Decode(S, R);
    if (R <> OSREP_M6_OK) or not Same(D, Input) then
      Ok := False;
  end;
end;

procedure SelfTest;
var
  P, Q: TOsrepM6Params;
  Src, S, D, T: TBytes;
  R: LongInt;
  Kind, Size, PI, I, J, Step: Integer;
  Len, Orig: QWord;
  Ws: array[0..3] of TWorker;
  Sizes: array[0..5] of Integer = (0, 1, 31, 4096, 300000, 1100000);
begin
  { parameter checks }
  OsrepM6ParamsDefault(P);
  Check(OsrepM6Check(P) = OSREP_M6_OK, 'default params');
  Q := P; Q.MinLen := 31;
  Check(OsrepM6Check(Q) = OSREP_M6_E_ARG, 'MinLen 31 rejected');
  Q := P; Q.Align := 0;
  Check(OsrepM6Check(Q) = OSREP_M6_E_ARG, 'Align 0 rejected');
  Q := P; Q.BlockSize := 1000;
  Check(OsrepM6Check(Q) = OSREP_M6_E_ARG, 'small block rejected');
  SetLength(S, 100);
  Check(OsrepM6Encode(nil, 10, @S[0], 100, Len, P) = OSREP_M6_E_ARG,
    'nil source rejected');

  for PI := 0 to 4 do
  begin
    OsrepM6ParamsDefault(P);
    case PI of
      1: begin P.MinLen := 64; P.Align := 1; end;
      2: begin P.MinLen := 32; P.Align := 1; P.BlockSize := 65536; end;
      3: P.Digest := True;
      4: begin P.MinLen := 128; P.Align := 32; P.BlockSize := 65536;
           P.Threads := 8; end;
    end;
    for Kind := 0 to 3 do
      for I := 0 to High(Sizes) do
      begin
        Size := Sizes[I];
        if (Kind = 0) and (Size > 0) then
          Continue;
        Src := MakeInput(Kind, Size, LongWord(PI * 100 + I));
        S := Encode(Src, P, R);
        Check(R = OSREP_M6_OK, Format('encode p%d k%d n%d: %d %s',
          [PI, Kind, Size, R, OsrepM6LastError]));
        if R <> OSREP_M6_OK then
          Continue;
        Check(QWord(Length(S)) <= OsrepM6Bound(Size, P), 'bound');
        Check(OsrepM6OrigSize(@S[0], Length(S), Orig) = OSREP_M6_OK, 'origsize');
        Check(Orig = QWord(Size), 'origsize value');
        D := Decode(S, R);
        Check((R = OSREP_M6_OK) and Same(D, Src),
          Format('round trip p%d k%d n%d: %d %s',
          [PI, Kind, Size, R, OsrepM6LastError]));
        { the same bytes again (deterministic) }
        T := Encode(Src, P, R);
        Check(Same(S, T), 'deterministic');
        { a buffer one byte short of what is written }
        SetLength(T, Length(S) - 1);
        if Length(T) > 0 then
          Check(OsrepM6Encode(BytesPtr(Src), Size, @T[0], Length(T), Len, P) =
            OSREP_M6_E_DST, 'short output buffer');
        { decode into a buffer of the wrong size }
        SetLength(T, Size + 1);
        Check(OsrepM6Decode(@S[0], Length(S), @T[0], Size + 1) = OSREP_M6_E_DST,
          'decode into a larger buffer');
        { truncations and byte flips must fail (never succeed with other
          bytes); every position for small streams, a sample for large }
        Step := 1;
        if Length(S) > 3000 then
          Step := Length(S) div 1500;
        J := 0;
        while J < Length(S) do
        begin
          T := Copy(S, 0, J);
          D := Decode(T, R);
          Check(R <> OSREP_M6_OK, Format('truncated at %d accepted', [J]));
          T := Copy(S, 0, Length(S));
          T[J] := T[J] xor Byte(1 shl (J mod 8));
          D := Decode(T, R);
          Check((R <> OSREP_M6_OK) or Same(D, Src),
            Format('flip at %d gave other bytes', [J]));
          Inc(J, Step);
        end;
        { trailing bytes after the footer }
        T := Copy(S, 0, Length(S));
        SetLength(T, Length(T) + 1);
        D := Decode(T, R);
        Check(R <> OSREP_M6_OK, 'trailing byte accepted');
      end;
  end;

  { a v6-like header is reported as a version error }
  SetLength(T, 64);
  FillChar(T[0], 64, 0);
  T[0] := Ord('O'); T[1] := Ord('S'); T[2] := Ord('R'); T[3] := Ord('6');
  Check(OsrepM6OrigSize(@T[0], 64, Orig) = OSREP_M6_E_VERSION, 'v6 header');
  Check(OsrepM6ErrorText(OSREP_M6_E_DST) <> '', 'error text');

  { four threads at once, each with its own input }
  OsrepM6ParamsDefault(P);
  P.MinLen := 64;
  for I := 0 to 3 do
  begin
    Ws[I] := TWorker.Create(True);
    Ws[I].Input := MakeInput(3, 600000 + I * 1000, LongWord(I + 50));
    Ws[I].P := P;
    Ws[I].Expect := Encode(Ws[I].Input, P, R);
    Ws[I].Start;
  end;
  for I := 0 to 3 do
  begin
    Ws[I].WaitFor;
    Check(Ws[I].Ok, Format('thread %d', [I]));
    Ws[I].Free;
  end;
end;

var
  P: TOsrepM6Params;
  Src, S: TBytes;
  R: LongInt;
begin
  if (ParamCount >= 1) and (ParamStr(1) = 'self') then
  begin
    SelfTest;
    WriteLn('osrep_m6 self: ', Checks, ' checks, ', Fails, ' failures');
    if Fails > 0 then
      Halt(1);
  end
  else if (ParamCount = 7) and (ParamStr(1) = 'enc') then
  begin
    OsrepM6ParamsDefault(P);
    P.MinLen := StrToInt(ParamStr(4));
    P.Align := StrToInt(ParamStr(5));
    P.BlockSize := StrToInt(ParamStr(6));
    P.Digest := ParamStr(7) = '1';
    Src := LoadFile(ParamStr(2));
    S := Encode(Src, P, R);
    if R <> OSREP_M6_OK then
    begin
      WriteLn(StdErr, 'encode: ', OsrepM6LastError);
      Halt(1);
    end;
    SaveFile(ParamStr(3), BytesPtr(S), Length(S));
  end
  else if (ParamCount = 3) and (ParamStr(1) = 'dec') then
  begin
    S := LoadFile(ParamStr(2));
    Src := Decode(S, R);
    if R <> OSREP_M6_OK then
    begin
      WriteLn(StdErr, 'decode: ', OsrepM6LastError);
      Halt(1);
    end;
    SaveFile(ParamStr(3), BytesPtr(Src), Length(Src));
  end
  else if (ParamCount = 2) and (ParamStr(1) = 'reject') then
  begin
    S := LoadFile(ParamStr(2));
    Src := Decode(S, R);
    if R = OSREP_M6_OK then
    begin
      WriteLn(StdErr, 'accepted: ', ParamStr(2));
      Halt(1);
    end;
  end
  else
  begin
    WriteLn(StdErr, 'usage: osrep_m6_test self | enc <in> <out> <minlen> ',
      '<align> <block> <digest> | dec <in> <out> | reject <file>');
    Halt(2);
  end;
end.
