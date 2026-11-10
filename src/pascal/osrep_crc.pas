unit osrep_crc;
{ CRC-32C used by the v6 container.

  The specification only says "CRC-32C".  The v6 fixtures pin the actual
  parameters: reflected polynomial 0x82F63B78, initial value 0 and no final
  XOR.  This is *not* the usual CRC-32C (which uses init/xorout 0xFFFFFFFF),
  so the difference is kept explicit here and documented in
  docs/implementation-notes.md. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function Crc32CUpdate(Crc: LongWord; const Data; Len: PtrUInt): LongWord;
function Crc32C(const Data; Len: PtrUInt): LongWord; overload;
function Crc32C(const Buf: TBytes): LongWord; overload;
function Crc32C(const Buf: TBytes; Offset, Len: SizeInt): LongWord; overload;

implementation

const
  Crc32cPoly = LongWord($82F63B78);

var
  CrcTable: array[0..255] of LongWord;
  CrcTableReady: Boolean = False;

procedure InitCrcTable;
var
  I, J: Integer;
  C: LongWord;
begin
  if CrcTableReady then
    Exit;
  for I := 0 to 255 do
  begin
    C := LongWord(I);
    for J := 0 to 7 do
      if (C and 1) <> 0 then
        C := (C shr 1) xor Crc32cPoly
      else
        C := C shr 1;
    CrcTable[I] := C;
  end;
  CrcTableReady := True;
end;

function Crc32CUpdate(Crc: LongWord; const Data; Len: PtrUInt): LongWord;
var
  P: PByte;
  I: PtrUInt;
begin
  if Len = 0 then
    Exit(Crc);
  InitCrcTable;
  P := @Data;
  for I := 0 to Len - 1 do
    Crc := CrcTable[(Crc xor P[I]) and $FF] xor (Crc shr 8);
  Result := Crc;
end;

function Crc32C(const Data; Len: PtrUInt): LongWord;
begin
  Result := Crc32CUpdate(0, Data, Len);
end;

function Crc32C(const Buf: TBytes): LongWord;
begin
  if Length(Buf) = 0 then
    Result := 0
  else
    Result := Crc32CUpdate(0, Buf[0], PtrUInt(Length(Buf)));
end;

function Crc32C(const Buf: TBytes; Offset, Len: SizeInt): LongWord;
begin
  if (Len <= 0) or (Offset < 0) then
    Result := 0
  else
    Result := Crc32CUpdate(0, Buf[Offset], PtrUInt(Len));
end;

initialization
  { Build the table once, before any thread can race on it. }
  InitCrcTable;

end.
