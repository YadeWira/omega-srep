unit RandBytes;
{ `random_bytes` (util.rs): la clave por corrida de un hash con semilla.

  En Unix sale de /dev/urandom. Si no se puede leer -- y en Windows, donde el
  Rust tampoco lo intenta -- un splitmix64 sembrado con la hora, el pid y una
  direccion de memoria, igual que el Rust. No es criptografico ni lo pretende:
  la clave solo tiene que diferir entre corridas, no ser secreta. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Widths, Hashes;

function RandomBytes(N: LongInt): TBytes;

implementation

uses Classes, DateUtils;

function RandomBytes(N: LongInt): TBytes;
var
  s, z: QWord;
  i: LongInt;
  {$IFDEF UNIX}
  fs: TFileStream;
  got: LongInt;
  {$ENDIF}
begin
  SetLength(Result, N);
  if N = 0 then Exit;
  {$IFDEF UNIX}
  try
    fs := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
    try
      got := fs.Read(Result[0], N);
    finally
      fs.Free;
    end;
    if got = N then Exit;
  except
    { sigue con el fallback }
  end;
  {$ENDIF}
  { los nanosegundos desde 1970 del Rust; aca la resolucion es de
    milisegundos, que alcanza para lo que es }
  s := QWord(MilliSecondsBetween(Now, UnixDateDelta)) * 1000000;
  s := s xor (QWord(GetProcessID) * QWord($9E3779B97F4A7C15));
  s := s xor QWord(PtrUInt(@Result[0]));
  for i := 0 to N - 1 do
  begin
    s := s + QWord($9E3779B97F4A7C15);
    z := s;
    z := (z xor (z shr 30)) * QWord($BF58476D1CE4E5B9);
    z := (z xor (z shr 27)) * QWord($94D049BB133111EB);
    Result[i] := Byte(z xor (z shr 31));
  end;
end;

end.
