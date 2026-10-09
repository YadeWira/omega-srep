unit ZeroPages;
{ Arreglos dinamicos grandes en paginas en cero del sistema, sin tocarlas.

  El Rust pide sus tablas con vec![0; n], que es calloc: para tamanos grandes
  eso es un mmap anonimo, y el sistema no entrega una pagina hasta que se
  escribe. SetLength en cambio hace GetMem + FillChar: escribe los ceros, y
  cada pagina queda ocupada aunque nunca se use. Con stdin sin -s el match
  finder se dimensiona para 25 GiB y la diferencia era 1,5 GB contra 1,0; con
  -m0, el anillo de 528 MiB mas su crecimiento por duplicacion (copia vieja y
  nueva a la vez) daba 1061 MB contra 407.

  ZNew arma el arreglo directamente en un mapeo anonimo (fpmmap en Unix,
  VirtualAlloc con MEM_COMMIT|MEM_RESERVE en Windows: los dos garantizan
  ceros y no tocan nada), con la cabecera de arreglo dinamico de FPC delante
  de los datos, asi que el acceso a los elementos, Length y el pasaje como
  parametro no cambian en nada. La cabecera lleva refcount -1, que es como
  la RTL marca un arreglo constante (dynarr.inc): nunca lo libera ni lo
  cuenta, y un SetLength sobre el hace una copia en vez de un realloc. Lo
  libera ZFree; si nadie lo llama (una excepcion que cruza), queda mapeado
  hasta que el proceso termina, que es lo que pasa enseguida en la CLI.

  Si el mapeo no se puede hacer (o el tamano no entra en el espacio de
  direcciones), ZNew cae a SetLength, con el mismo argumento que recibia
  antes: el comportamiento ante falta de memoria queda igual que el de
  siempre. Debajo de ZNEW_MIN_BYTES tambien va por SetLength.

  La cadena de $IF termina en $FATAL (docs/pascal-port.md, la primera
  trampa): un simbolo mal escrito no cae en silencio en la otra rama. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

const
  ZNEW_MIN_BYTES = 1 shl 20;

{ SetLength(A, Count), en paginas en cero si el arreglo esta vacio (o es de
  ZNew, que se libera antes) y mide al menos ZNEW_MIN_BYTES.
  A es la variable del arreglo (Pointer(arr)), TI su TypeInfo y ElemSize el
  tamano de un elemento. Devuelve True si quedo en un mapeo propio. }
function ZNew(var A: Pointer; TI: Pointer; Count: SizeInt; ElemSize: SizeUInt): Boolean;

{ Solo el mapeo: False (y A sin tocar, salvo liberar un ZNew previo) si es
  chico, no entra o el sistema no lo da; el que llama decide que hacer. }
function ZTryNew(var A: Pointer; Count: QWord; ElemSize: SizeUInt): Boolean;

{ Libera un arreglo armado por ZNew y deja A en nil. Si A es un arreglo
  comun (o nil), no hace nada: lo libera la finalizacion de siempre. Solo
  para variables que paso por ZNew: una constante de arreglo dinamico
  tambien lleva refcount -1. }
procedure ZFree(var A: Pointer);

{ True si A vive en un mapeo de ZNew (para las pruebas). }
function ZIsMapped(A: Pointer): Boolean;

implementation

{$IF DEFINED(UNIX)}
uses BaseUnix;
{$ELSEIF DEFINED(WINDOWS)}
uses Windows;
{$ELSE}
  {$FATAL zeropages.pas: no hay implementacion para esta plataforma}
{$ENDIF}

type
  { la cabecera de dynarr.inc: refcount y high, en ese orden }
  PDynHeader = ^TDynHeader;
  TDynHeader = packed record
    RefCount: PtrInt;
    High: SizeInt;
  end;

const
  { los datos empiezan a 32 bytes del mapeo (alineados a 16 en los dos
    anchos); la cabecera va justo antes, y el largo del mapeo al principio }
  DATA_OFFSET = 32;

function OsMap(Size: PtrUInt): Pointer;
begin
{$IF DEFINED(UNIX)}
  Result := fpmmap(nil, Size, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Result = MAP_FAILED then Result := nil;
{$ELSEIF DEFINED(WINDOWS)}
  Result := VirtualAlloc(nil, Size, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
{$ENDIF}
end;

procedure OsUnmap(P: Pointer; Size: PtrUInt);
begin
{$IF DEFINED(UNIX)}
  fpmunmap(P, Size);
{$ELSEIF DEFINED(WINDOWS)}
  VirtualFree(P, 0, MEM_RELEASE);
{$ENDIF}
end;

function ZTryNew(var A: Pointer; Count: QWord; ElemSize: SizeUInt): Boolean;
var bytes: QWord; base: Pointer; h: PDynHeader;
begin
  Result := False;
  ZFree(A);
  if (A <> nil) or (Count = 0) or (Count > QWord(High(SizeInt))) then Exit;
  bytes := Count * QWord(ElemSize);
  if bytes div QWord(ElemSize) <> Count then Exit;
  if (bytes < ZNEW_MIN_BYTES) or (bytes > QWord(High(PtrUInt)) - DATA_OFFSET) then Exit;
  base := OsMap(PtrUInt(bytes + DATA_OFFSET));
  if base = nil then Exit;
  PPtrUInt(base)^ := PtrUInt(bytes + DATA_OFFSET);
  h := PDynHeader(PByte(base) + DATA_OFFSET - SizeOf(TDynHeader));
  h^.RefCount := -1;
  h^.High := SizeInt(Count) - 1;
  A := PByte(base) + DATA_OFFSET;
  Result := True;
end;

function ZNew(var A: Pointer; TI: Pointer; Count: SizeInt; ElemSize: SizeUInt): Boolean;
begin
  { Count < 0 (un QWord truncado en i386) no mapea, y SetLength falla como
    fallaba antes }
  ZFree(A);
  Result := (Count > 0) and ZTryNew(A, QWord(Count), ElemSize);
  if not Result then DynArraySetLength(A, TI, 1, @Count);
end;

function ZIsMapped(A: Pointer): Boolean;
begin
  Result := (A <> nil) and (PDynHeader(PByte(A) - SizeOf(TDynHeader))^.RefCount < 0);
end;

procedure ZFree(var A: Pointer);
var base: Pointer;
begin
  if A = nil then Exit;
  if PDynHeader(PByte(A) - SizeOf(TDynHeader))^.RefCount >= 0 then Exit;
  base := PByte(A) - DATA_OFFSET;
  A := nil;
  OsUnmap(base, PPtrUInt(base)^);
end;

end.
