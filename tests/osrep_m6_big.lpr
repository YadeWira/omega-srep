{ The embeddable -m6 API (osrep_m6) on inputs larger than RAM allows here:
  the input and the output are files mapped into memory (file pages, which
  the kernel can drop or write back), so only what the API itself allocates
  is anonymous memory.  A thread samples RssAnon and reports its peak next
  to OsrepM6EncMem / OsrepM6DecMem.  Unix, 64-bit.

    osrep_m6_big enc <in> <out.osr> [minlen align]
    osrep_m6_big dec <in.osr> <out>

  tests/osrep_m6_big.sh runs it on 6.5 GiB from tests/orep_bigsrc.c. }
program osrep_m6_big;

{$mode objfpc}{$H+}

uses
  cthreads, BaseUnix, Unix, SysUtils, Classes, osrep_m6;

type
  TSampler = class(TThread)
  public
    Peak: QWord;
    procedure Execute; override;
  end;

function RssAnon: QWord;
var
  F: TextFile;
  L: string;
begin
  Result := 0;
  AssignFile(F, '/proc/self/status');
  {$I-}Reset(F);{$I+}
  if IOResult <> 0 then
    Exit;
  while not Eof(F) do
  begin
    ReadLn(F, L);
    if Copy(L, 1, 8) = 'RssAnon:' then
    begin
      L := Trim(Copy(L, 9, 100));
      L := Copy(L, 1, Pos(' ', L) - 1);
      Result := StrToQWordDef(L, 0) * 1024;
      Break;
    end;
  end;
  CloseFile(F);
end;

procedure TSampler.Execute;
var
  R: QWord;
begin
  Peak := 0;
  while not Terminated do
  begin
    R := RssAnon;
    if R > Peak then
      Peak := R;
    Sleep(20);
  end;
end;

procedure Die(const Msg: string);
begin
  WriteLn(StdErr, 'osrep_m6_big: ', Msg);
  Halt(1);
end;

function MapRead(const Name: string; out Len: QWord): PByte;
var
  Fd: cint;
  St: Stat;
begin
  Fd := FpOpen(Name, O_RDONLY);
  if Fd < 0 then
    Die('cannot open ' + Name);
  if FpFStat(Fd, St) <> 0 then
    Die('stat ' + Name);
  Len := St.st_size;
  Result := nil;
  if Len > 0 then
  begin
    Result := FpMMap(nil, Len, PROT_READ, MAP_SHARED, Fd, 0);
    if Result = PByte(MAP_FAILED) then
      Die('mmap ' + Name);
  end;
  FpClose(Fd);
end;

function MapWrite(const Name: string; Len: QWord; out Fd: cint): PByte;
begin
  Fd := FpOpen(Name, O_RDWR or O_CREAT or O_TRUNC, &644);
  if Fd < 0 then
    Die('cannot create ' + Name);
  if FpFTruncate(Fd, Len) <> 0 then
    Die('ftruncate ' + Name);
  Result := nil;
  if Len > 0 then
  begin
    Result := FpMMap(nil, Len, PROT_READ or PROT_WRITE, MAP_SHARED, Fd, 0);
    if Result = PByte(MAP_FAILED) then
      Die('mmap ' + Name);
  end;
end;

var
  P: TOsrepM6Params;
  Src, Dst: PByte;
  SrcLen, Cap, Len, Orig: QWord;
  Fd: cint;
  R: LongInt;
  S: TSampler;
  T0: QWord;
  One: Byte;
begin
  if ParamCount < 3 then
    Die('usage: enc <in> <out> [minlen align] | dec <in> <out>');
  OsrepM6ParamsDefault(P);
  if ParamCount >= 5 then
  begin
    P.MinLen := StrToInt(ParamStr(4));
    P.Align := StrToInt(ParamStr(5));
  end;
  S := TSampler.Create(False);
  T0 := GetTickCount64;
  Src := MapRead(ParamStr(2), SrcLen);
  if ParamStr(1) = 'enc' then
  begin
    Cap := OsrepM6Bound(SrcLen, P);
    Dst := MapWrite(ParamStr(3), Cap, Fd);
    R := OsrepM6Encode(Src, SrcLen, Dst, Cap, Len, P);
    if R <> OSREP_M6_OK then
      Die('encode: ' + OsrepM6LastError);
    FpMUnMap(Dst, Cap);
    if FpFTruncate(Fd, Len) <> 0 then
      Die('ftruncate');
    FpClose(Fd);
    S.Terminate;
    S.WaitFor;
    WriteLn(Format('enc %d -> %d bytes, %.1f s, anon peak %d MB, EncMem %d MB',
      [SrcLen, Len, (GetTickCount64 - T0) / 1000, S.Peak shr 20,
       OsrepM6EncMem(SrcLen, P) shr 20]));
  end
  else if ParamStr(1) = 'dec' then
  begin
    R := OsrepM6OrigSize(Src, SrcLen, Orig);
    if R <> OSREP_M6_OK then
      Die('origsize: ' + OsrepM6LastError);
    Dst := MapWrite(ParamStr(3), Orig, Fd);
    if Orig = 0 then
      R := OsrepM6Decode(Src, SrcLen, @One, 0)
    else
      R := OsrepM6Decode(Src, SrcLen, Dst, Orig);
    if R <> OSREP_M6_OK then
      Die('decode: ' + OsrepM6LastError);
    if Orig > 0 then
      FpMUnMap(Dst, Orig);
    FpClose(Fd);
    S.Terminate;
    S.WaitFor;
    WriteLn(Format('dec %d -> %d bytes, %.1f s, anon peak %d MB, DecMem %d MB',
      [SrcLen, Orig, (GetTickCount64 - T0) / 1000, S.Peak shr 20,
       OsrepM6DecMem shr 20]));
  end
  else
    Die('unknown command');
end.
