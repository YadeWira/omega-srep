unit FixedCompress;
{ El compresor de un bloque para -m3/-m4/-m5 (compress.rs, que porta
  compress.cpp). El C++ es una plantilla sobre ACCELERATOR (0, 1, 2, 4, ...,
  64), y las variantes NO dan el mismo archivo: find_match acepta un chunk
  cuyo hash difiere del buscado en los bits que no compara (los del numero
  de chunk en el slot de chunkarr), y -m4/-m5 lo guardan si los bytes
  releidos, con la extension hacia atras, llegan a MIN_MATCH (siempre posible
  con MIN_MATCH == L). El escaneo acelerado solo sondea las posiciones cuyo
  hash pasa bitarr, que filtra casi todas esas, y es el que el C++ usa por
  defecto (accel = min(max(L/32, 1), 4)). Con el -l por defecto casi nunca
  decide nada; con -l16..-l128 o -c chico si. Asi que CompressFixed corre
  CompressFixedAccel (compress<CYCLES>) para las variantes que el C++
  instancia, y compress<0> para -a0/-a- y para los valores donde el C++ no
  tiene comportamiento definido (encoder.pas los lista).
  Lo que se ve en la salida de compress<0>, y se reproduce:

  * solo se prueban posiciones en [last_match_end, match_start): ni adentro del
    match anterior ni adentro del match de entrada pendiente;
  * el escaneo puede saltar a last_match_end redondeado a multiplo de 4 y
    resincronizar el hash ahi -- por eso el avance de a cuatro puede pasarse
    de next_chunk y correr la posicion de add_hash;
  * add_hash corre una vez por vuelta con el valor ACTUAL de hash1, donde sea
    que lo haya dejado el lote;
  * la lista de entrada (los matches del pase en memoria y el cerco len+1) se
    decodifica a medida y sus matches entran justo donde llega el escaneo. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, LzCodec, HashTable;

type
  EEncode = class(Exception);

{ compress<ACCELERATOR>: los records van a Stat y la cuenta de literales a
  LiteralBytes. Dict tiene el bloque en BufOff; InStat es la lista de
  entrada. Accelerator es la variante ya validada por el encoder (0 = el
  escaneo simple); sin bitarr tambien es el simple. }
procedure CompressFixed(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
                        RoundMatches: Boolean; L, MinMatch: QWord; BaseLen: DWord;
                        BlockStart: QWord; const InStat: TStatList; var Stat: TStatList;
                        out LiteralBytes: DWord; Reread: TStream; Accelerator: DWord);

{ El error de ENCODE_LZ_MATCH, con el texto del Debug del Rust. }
procedure MatchTooSmall(MatchLen, BaseLen: DWord);

implementation

uses Rolling;

const
  LOOKAHEAD = 128;      { compress.cpp:134 con ACCELERATOR == 0 }
  X = 4;                { max(CYCLES, 4) }
  LOOKAHEAD_A = 256;    { compress.cpp:134 con ACCELERATOR != 0 }
  MAX_CYCLES = 64;      { la variante mas ancha que el C++ instancia }

procedure MatchTooSmall(MatchLen, BaseLen: DWord);
begin
  raise EEncode.Create('MatchTooSmall { match_len: ' + IntToStr(MatchLen) +
                       ', base_len: ' + IntToStr(BaseLen) + ' }');
end;

function Enc(var S: TStatList; RoundMatches: Boolean; BaseLen, LitLen: DWord; Offset: QWord;
             MatchLen: DWord): Boolean;
begin
  if not EncodeLzMatch(S, RoundMatches, BaseLen, LitLen, Offset, MatchLen) then
    MatchTooSmall(MatchLen, BaseLen);
  Result := True;
end;

{ Cuantos de los Len bytes en el offset Src del archivo son iguales a los del
  bloque en MatchStart (offset Dest), releidos de la entrada; 0 salvo que Src
  este antes de Dest. El decoder copia hacia adelante byte a byte, asi que un
  origen que se solapa (Src + Len > Dest) se compara igual. La entrada se
  relee de a pedazos de 4 KiB que crecen hasta 64 KiB y se corta en la primera
  diferencia: una prueba que falla enseguida lee un pedazo y no todo Len (que
  puede ser el resto del bloque); leerlo entero haria el escaneo cuadratico en
  el largo del bloque (compress.rs, common_prefix). }
function CommonPrefix(const Dict: TBytes; BufOff, MatchStart, Src, Dest: QWord; Len: DWord;
                      Reread: TStream): DWord;
const FIRST_PIECE = 4096; MAX_PIECE = 65536;
var old: TBytes; got, n, want, same, piece, base: QWord;
begin
  if Src >= Dest then Exit(0);
  if Len = 0 then Exit(0);
  if QWord(Len) < FIRST_PIECE then SetLength(old, Len) else SetLength(old, FIRST_PIECE);
  piece := FIRST_PIECE;
  n := 0;
  base := BufOff + MatchStart;
  while n < QWord(Len) do
  begin
    want := QWord(Len) - n;
    if want > piece then want := piece;
    if QWord(Length(old)) < want then SetLength(old, want);
    got := ReadAt(Reread, Src + n, old, want);
    same := 0;
    while (same < got) and (old[same] = Dict[base + n + same]) do Inc(same);
    n := n + same;
    if same < want then Break;
    piece := piece * 2;
    if piece > MAX_PIECE then piece := MAX_PIECE;
  end;
  Result := DWord(n);
end;

{ Si un record redondeado (-m3 sin -d) del match de Len bytes desde el offset
  Src del archivo hasta la posicion MatchStart del bloque descomprime a estos
  mismos bytes aunque Src o Len no caigan en la grilla de B (BASE_LEN). El
  decoder copia, hacia adelante y byte a byte, Len div B * B bytes (redondeado
  desde B, DECODE_LZ_MATCH) desde dest div B * B - offset div B * B: eso da la
  entrada exacta cuando el largo es entero y los bytes de ese origen son los
  del destino. Se releen de la entrada, por el mismo handle que ya usan -m4 y
  -m5 (compress.rs, decodes_as_is). }
function DecodesAsIs(const Dict: TBytes; BufOff, BlockStart, MatchStart, Src: QWord;
                     Len: DWord; B: QWord; Reread: TStream): Boolean;
var dest, decodedSrc: QWord;
begin
  Result := False;
  if ((QWord(Len) mod B) <> 0) or (QWord(Len) < B) then Exit;
  dest := BlockStart + MatchStart;
  decodedSrc := dest div B * B - (dest - Src) div B * B;
  if decodedSrc >= dest then Exit;
  { de a pedazos, como CommonPrefix: la misma respuesta que una sola lectura de
    Len bytes (una lectura corta es una diferencia), sin un buffer del largo
    del match }
  Result := CommonPrefix(Dict, BufOff, MatchStart, decodedSrc, dest, Len, Reread) = Len;
end;

{ El ajuste a la grilla de BASE_LEN (B) de un record redondeado con origen
  Src. Un record redondeado guarda offset y largo en unidades de BASE_LEN, no
  de L (el L1 de ENCODE_LZ_MATCH, srep.cpp:117), y el decoder rearma el origen
  como dest div BASE_LEN * BASE_LEN - offset div BASE_LEN * BASE_LEN y el
  largo como un numero entero de BASE_LEN. Eso es exacto si el origen y el
  largo son multiplos de BASE_LEN: siempre, cuando BASE_LEN divide a L (el
  default). Con -c debajo de BASE_LEN (-m3 -c8 -l16) o un BASE_LEN que no
  divide a L (-m3 -c8 -l17, -m3 -dl17) el C++ escribia un archivo que no
  descomprime (exit 0: perdida de datos silenciosa) o cortaba con "match len
  too small" (exit 4), y el port igual.
  Un record que no va a descomprimir a estos bytes se corre al proximo origen
  de la grilla de BASE_LEN y se recorta a unidades enteras -- sigue adentro
  del match verificado, los bytes son los mismos -- o no se toma (False) si
  no queda ni una unidad. Uno que descomprime bien tal cual (uno exacto, o uno
  con el origen corrido que por casualidad tiene los mismos bytes, como en una
  entrada toda en cero) queda igual: los archivos que descomprimian no cambian.
  Los records sin redondear pasan tal cual (compress.rs, fit_base_len_grid). }
function FitBaseLenGrid(const Dict: TBytes; BufOff, BlockStart: QWord; RoundMatches: Boolean;
                        B, Src: QWord; var MatchStart: QWord; var MatchLen: DWord;
                        Reread: TStream): Boolean;
var skip, cut: QWord;
begin
  Result := True;
  if not RoundMatches then Exit;
  if not (((Src mod B) = 0) and ((QWord(MatchLen) mod B) = 0) and (QWord(MatchLen) >= B))
     and not DecodesAsIs(Dict, BufOff, BlockStart, MatchStart, Src, MatchLen, B, Reread) then
  begin
    skip := (B - Src mod B) mod B;
    if QWord(MatchLen) > skip then cut := (QWord(MatchLen) - skip) div B * B else cut := 0;
    if cut < B then Exit(False);
    MatchStart := MatchStart + skip;
    MatchLen := DWord(cut);
  end;
end;

{ record_match: mide el match del chunk K contra la posicion I y lo emite si
  llega a MinMatch. }
function RecordMatch(const T: THashTableRec; const Dict: TBytes; BufOff, BlockSize,
                     BlockStart: QWord; RoundMatches: Boolean; L, MinMatch: QWord;
                     BaseLen: DWord; Reread: TStream; var Stat: TStatList;
                     LastMatchEnd: QWord; out MatchEnd: QWord; var LiteralBytes: DWord;
                     I: QWord; K: DWord): Boolean;
var addLen, matchLen, oldLen, len: DWord;
    matchStart, oldStart, matchOffset, b, gridSrc, trueSrc, dest, decodedSrc: QWord;
    overrun, shifted, keepOld: Boolean;
begin
  MatchEnd := 0;
  matchLen := HtMatchLen(T, K, Dict, BufOff, BufOff + LastMatchEnd, BufOff + I,
                         BufOff + BlockSize, BlockStart, RoundMatches, Reread, addLen);
  if QWord(matchLen) >= MinMatch then
  begin
    matchStart := I - QWord(addLen);
    b := QWord(BaseLen);
    gridSrc := QWord(K) * L;
    matchOffset := BlockStart + I - gridSrc;

    { Primero el record que escribia la 2.2.0, que supone el chunk K en K*L. }
    oldStart := matchStart;
    if RoundMatches then oldLen := DWord(QWord(matchLen) div L * L) else oldLen := matchLen;
    if not FitBaseLenGrid(Dict, BufOff, BlockStart, RoundMatches, b, gridSrc, oldStart,
                          oldLen, Reread) then Exit(False);

    { K*L es donde estan de verdad los bytes del chunk K solo mientras todos
      los bloques hayan empezado en la grilla de L: uno que empieza en un
      BlockStart que no es multiplo de L (cualquier -b que no sea multiplo de
      L) numera sus chunks desde BlockStart div L pero los digiere y hashea en
      BlockStart + m*L. -m4/-m5 releen los bytes en K*L, asi que ahi solo se
      pierden matches; -m3 confia en los digests y no relee, y el record salia
      con un origen corrido BlockStart mod L (exit 0, -d falla o da otros
      bytes). La extension por digests ademas puede pasar de un bloque en la
      grilla al siguiente, corrido, cuyos chunks no siguen a los del primero.
      Y si L no es multiplo de 4 el escaneo prueba ventanas que terminan hasta
      3 bytes pasado el bloque, y HtMatchLen cuenta ese primer chunk entero:
      el record se pasaba del bloque (exit 4, BadBlockRecord).
      Ese record se compara con los bytes que va a copiar el decoder. Si
      descomprime a estos bytes y entra en el bloque se escribe igual que
      antes, asi que los archivos que descomprimian no cambian; si no, se
      rearma desde el origen verdadero del chunk, recortado a los bytes que de
      verdad coinciden. Los archivos con todos los bloques en la grilla de L y
      ningun record pasado del bloque van por la primera rama sin cambios
      (compress.rs, record_match). }
    overrun := oldStart + QWord(oldLen) > BlockSize;
    shifted := T.CompareDigests and T.AnyShifted;
    if not shifted and not overrun then keepOld := True
    else if overrun then keepOld := False
    else
    begin
      dest := BlockStart + oldStart;
      if RoundMatches then decodedSrc := dest div b * b - matchOffset div b * b
      else decodedSrc := dest - matchOffset;
      keepOld := CommonPrefix(Dict, BufOff, oldStart, decodedSrc, dest, oldLen, Reread) = oldLen;
    end;

    if keepOld then
    begin
      matchStart := oldStart;
      matchLen := oldLen;
    end
    else
    begin
      if T.CompareDigests then trueSrc := HtChunkPos(T, K) else trueSrc := gridSrc;
      { Se mide desde el origen verdadero hasta el fin del bloque, sin el tope
        de matchLen: en un bloque corrido ese salio de los digests de los
        chunks equivocados (los de la grilla) y suele ser un solo chunk; un
        record cortado ahi dejaba casi toda una repeticion larga para volver a
        probarla chunk por chunk (texto de periodo 69 con -m3 -b1000001b: 12.7
        s y 2.9 MB de 4 MB, contra 0.02 s y 4 KB con -b1mb). El record cubre
        solo bytes iguales al origen, asi que descomprime con cualquier largo
        (compress.rs, record_match). }
      dest := BlockStart + matchStart;
      len := CommonPrefix(Dict, BufOff, matchStart, trueSrc, dest, DWord(BlockSize - matchStart),
                          Reread);
      if RoundMatches then len := DWord(QWord(len) div L * L);
      if (len = 0) or (QWord(len) < MinMatch) then Exit(False);
      matchOffset := dest - trueSrc;
      if not FitBaseLenGrid(Dict, BufOff, BlockStart, RoundMatches, b, trueSrc, matchStart,
                            len, Reread) then Exit(False);
      matchLen := len;
    end;
    Enc(Stat, RoundMatches, BaseLen, DWord(matchStart - LastMatchEnd), matchOffset, matchLen);
    MatchEnd := matchStart + QWord(matchLen);
    LiteralBytes := DWord(QWord(LiteralBytes) - QWord(matchLen));
    Exit(True);
  end;
  Result := False;
end;

{ El lote de CompressFixed (compress.cpp:28-35 y 180-185), en una funcion hoja
  para que FPC tenga el hash y el cursor en registros: CompressFixed tiene un
  procedimiento anidado y por eso todos sus locales viven en la pila. Corre el
  hash de a X posiciones mientras I < LastI y guarda en PH/PP las posiciones
  en [Lo, Hi). Misma aritmetica con wrap que PolyUpdate. }
function HashBatch(Pb, PbL: PByte; var I: QWord; LastI, Lo, Hi: QWord; var HV: QWord;
                   Prime, PrimeL: QWord; PH, PP: PQWord; CA: PDWord; HS1: QWord): LongInt;
var ii, h: QWord; n, c: LongInt;
begin
  ii := I;
  h := HV;
  n := 0;
  while ii < LastI do
    for c := 1 to X do
    begin
      h := h * Prime + QWord(PbL[PtrUInt(ii)]) - PrimeL * QWord(Pb[PtrUInt(ii)]);
      Inc(ii);
      if (ii >= Lo) and (ii < Hi) then
      begin
        PH[n] := h;
        PP[n] := ii;
        Inc(n);
        {$IFDEF CPUX86_64}
        { el slot que va a mirar HtNextCandidate: la tabla no entra en cache }
        prefetch(CA[PtrUInt(h and HS1)]);
        {$ENDIF}
      end;
    end;
  I := ii;
  HV := h;
  Result := n;
end;

{ compress<0> }
procedure CompressPlain(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
                        RoundMatches: Boolean; L, MinMatch: QWord; BaseLen: DWord;
                        BlockStart: QWord; const InStat: TStatList; var Stat: TStatList;
                        out LiteralBytes: DWord; Reread: TStream);
var
  lastMatchEnd, matchStart, matchOffset, inAt: QWord;
  matchLen: DWord;
  hash1: TPolyHash;
  pairH, pairP: array[0..LOOKAHEAD + X] of QWord;
  npairs, pi_: LongInt;
  i, nextChunk, nextI, lastI, matchEnd, cut, ms, lit: QWord;
  ml: QWord;
  k: DWord;
  c: LongInt;
  hsh: QWord;
  { el hash rodante en registros y el bloque por puntero: el lote es el lazo
    mas caliente del compresor. Misma aritmetica con wrap que PolyUpdate. }
  hv, prime, primeL: QWord;
  pb, pbL: PByte;

  procedure DecodeNext(BasicPos: QWord);
  var m: TLzMatch; used: QWord;
  begin
    if not DecodeLzMatch(InStat, inAt, RoundMatches, False, BaseLen, BasicPos, m, used) then
      raise EEncode.Create('BadBlockRecord');
    inAt := inAt + used;
    matchStart := m.Dest - BlockStart;
    matchLen := m.Len;
    matchOffset := m.Dest - m.Src;
  end;

begin
  lastMatchEnd := 0;
  LiteralBytes := DWord(BlockSize);
  inAt := 0;
  DecodeNext(BlockStart);

  if 2 * L > BlockSize then Exit;

  PolyInit(hash1, L, PRIME1);
  prime := hash1.Prime;
  primeL := hash1.PrimeL;
  pb := PByte(@Dict[BufOff]);
  pbL := pb + PtrUInt(L);

  { --- los primeros L bytes (compress.cpp:78-94) --- }
  PolyMoveTo(hash1, Dict, BufOff);
  k := HtFindMatch(T, Dict, BufOff, 0, BlockSize, hash1.Value, DWord(hash1.Value shr 32));
  if k <> NOT_FOUND then
    if RecordMatch(T, Dict, BufOff, BlockSize, BlockStart, RoundMatches, L, MinMatch, BaseLen,
                   Reread, Stat, lastMatchEnd, matchEnd, LiteralBytes, 0, k) then
      lastMatchEnd := matchEnd;
  HtAddHash(T, hash1.Value, DWord(hash1.Value shr 32), BlockStart div L);

  { --- el ciclo principal, un bloque de L bytes por paso --- }
  i := 0;
  while i + 2 * L <= BlockSize do
  begin
    nextChunk := i + L;
    while i < nextChunk do
    begin
      { el match de entrada, al llegar a su comienzo }
      if i >= matchStart then
      begin
        if matchStart + QWord(matchLen) - QWord(BaseLen) >= lastMatchEnd then
        begin
          if matchStart > lastMatchEnd then ms := matchStart else ms := lastMatchEnd;
          cut := ms - matchStart;
          ml := QWord(matchLen) - cut;
          lit := ms - lastMatchEnd;
          Enc(Stat, RoundMatches, BaseLen, DWord(lit), matchOffset, DWord(ml));
          lastMatchEnd := ms + ml;
          LiteralBytes := DWord(QWord(LiteralBytes) - ml);
        end;
        { el siguiente, anclado despues del match ORIGINAL (sin recortar) }
        DecodeNext(BlockStart + matchStart + QWord(matchLen));
      end;

      { hash1 hasta last_match_end, redondeado hacia abajo }
      if lastMatchEnd > 0 then nextI := lastMatchEnd - 1 else nextI := 0;
      if nextChunk - 1 < nextI then nextI := nextChunk - 1;
      if nextI >= i + L div 2 then
      begin
        i := nextI and not QWord(X - 1);
        PolyMoveTo(hash1, Dict, BufOff + i);
      end
      else
      begin
        hv := hash1.Value;
        while i + X <= nextI do
          for c := 1 to X do
          begin
            hv := hv * prime + QWord(pbL[PtrUInt(i)]) - primeL * QWord(pb[PtrUInt(i)]);
            Inc(i);
          end;
        hash1.Value := hv;
      end;

      lastI := i + LOOKAHEAD;
      if nextChunk < lastI then lastI := nextChunk;

      { el lote: cuatro posiciones mas, guardando las candidatas }
      npairs := HashBatch(pb, pbL, i, lastI, lastMatchEnd, matchStart, hash1.Value, prime,
                          primeL, @pairH[0], @pairP[0], PDWord(T.ChunkArr), T.HashSize1);

      { chunkarr, buscando un match. HtNextCandidate saltea los pares que
        HtFindMatch daria por NOT_FOUND sin mirar el contenido. }
      pi_ := 0;
      while True do
      begin
        pi_ := HtNextCandidate(T, @pairH[0], pi_, npairs);
        if pi_ >= npairs then Break;
        hsh := pairH[pi_];
        k := HtFindMatch(T, Dict, BufOff, pairP[pi_], BlockSize, hsh, DWord(hsh shr 32));
        if k <> NOT_FOUND then
          if RecordMatch(T, Dict, BufOff, BlockSize, BlockStart, RoundMatches, L, MinMatch,
                         BaseLen, Reread, Stat, lastMatchEnd, matchEnd, LiteralBytes,
                         pairP[pi_], k) then
          begin
            lastMatchEnd := matchEnd;
            Break;                     { goto match_found2 }
          end;
        Inc(pi_);
      end;
    end;

    { add_hash en la frontera de L, con el valor ACTUAL de hash1 }
    HtAddHash(T, hash1.Value, DWord(hash1.Value shr 32), (BlockStart + i) div L);
  end;
end;

{ El lote de CompressFixedAccel que corre hash1 (compress.cpp:138-149): de a
  Cycles posiciones desde I mientras I0 < LastI, guardando en H1 el hash de la
  primera de cada grupo; devuelve cuantos guardo. hash1 cubre los ultimos
  L - OFFSET bytes de la ventana: sale Pb[p], entra Pb[p + L - OFFSET]. Hoja,
  por lo mismo que HashBatch. }
function Hash1Batch(Pb: PByte; I, LastI, Cycles, L: QWord; var HV: QWord;
                    Prime, PrimeL: QWord; H1: PQWord; Bits: PByte; Shift: DWord): LongInt;
var i0, h, p, e: QWord; n: LongInt;
begin
  h := HV;
  n := 0;
  i0 := I;
  while i0 < LastI do
  begin
    { hash1.update(buf[i0+OFFSET], buf[i0+L]) y despues update<CYCLES-1>
      desde buf+i0+1+OFFSET: las dos son, byte a byte, sacar buf[p] y meter
      buf[p + L - OFFSET] para p = i0+OFFSET .. i0+2*OFFSET }
    p := i0 + Cycles - 1;
    h := h * Prime + QWord(Pb[PtrUInt(p + L - Cycles + 1)]) - PrimeL * QWord(Pb[PtrUInt(p)]);
    H1[n] := h;
    Inc(n);
    {$IFDEF CPUX86_64}
    { prefetch_check_match_possibility: el byte de bitarr que mira CheckBatch }
    prefetch(Bits[PtrUInt(h shr Shift)]);
    {$ENDIF}
    e := p + Cycles - 1;
    while p < e do
    begin
      Inc(p);
      h := h * Prime + QWord(Pb[PtrUInt(p + L - Cycles + 1)]) - PrimeL * QWord(Pb[PtrUInt(p)]);
    end;
    i0 := i0 + Cycles;
  end;
  HV := h;
  Result := n;
end;

{ El filtro de bitarr y el calculo de hash2 (compress.cpp:152-184): por cada
  hash de H1 que pasa bitarr se arman los hashes de ventana entera de sus
  Cycles posiciones y se guardan las que caen en [Lo, Hi). }
function CheckBatch(const T: THashTableRec; Pb: PByte; var I: QWord; LastI, Cycles, L, Lo,
                    Hi: QWord; H1: PQWord; Powers: PQWord; Prime, PrimeL: QWord;
                    PH, PP: PQWord): LongInt;
var ii, h2, j, hs1: QWord; n, n1: LongInt; bits: PByte; shift: DWord; hsh1: QWord; ca: PDWord;
begin
  ca := PDWord(T.ChunkArr);
  hs1 := T.HashSize1;
  ii := I;
  n := 0;
  n1 := 0;
  bits := PByte(T.BitArr);
  shift := T.BitShift;
  while ii < LastI do
  begin
    hsh1 := H1[n1];
    Inc(n1);
    if (bits[PtrUInt(hsh1 shr shift)] and (Byte(1) shl (DWord(hsh1) and 7))) <> 0 then
    begin
      Inc(ii);
      h2 := hsh1;
      j := 0;
      while j < Cycles - 1 do
      begin
        h2 := h2 + QWord(Pb[PtrUInt(ii + j)]) * Powers[PtrUInt(j)];
        Inc(j);
      end;
      if (ii >= Lo) and (ii < Hi) then
      begin
        PH[n] := h2;
        PP[n] := ii;
        Inc(n);
        {$IFDEF CPUX86_64}
        prefetch(ca[PtrUInt(h2 and hs1)]);     { prefetch_match }
        {$ENDIF}
      end;
      j := 0;
      while j < Cycles - 1 do
      begin
        h2 := h2 * Prime + QWord(Pb[PtrUInt(ii + L)]) - PrimeL * QWord(Pb[PtrUInt(ii)]);
        if (ii + 1 >= Lo) and (ii + 1 < Hi) then
        begin
          PH[n] := h2;
          PP[n] := ii + 1;
          Inc(n);
          {$IFDEF CPUX86_64}
          prefetch(ca[PtrUInt(h2 and hs1)]);
          {$ENDIF}
        end;
        Inc(ii);
        Inc(j);
      end;
    end
    else
      ii := ii + Cycles;
  end;
  I := ii;
  Result := n;
end;

{ compress<CYCLES> para CYCLES = 1, 2, 4, ..., 64 (compress.cpp:54-212), tal
  cual: hash1 cubre los ultimos L - OFFSET bytes de la ventana, bitarr se
  prueba una vez cada CYCLES posiciones y, si pasa, se hashean las CYCLES
  posiciones enteras y se guardan; LOOKAHEAD es 256. El que llama garantiza
  1 <= Cycles <= min(L, 64) y BitArr no vacio. Lee hasta Cycles - 1 bytes
  pasado el bloque (ver RING_TAIL). }
procedure CompressFixedAccel(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
                             RoundMatches: Boolean; L, MinMatch: QWord; BaseLen: DWord;
                             BlockStart: QWord; const InStat: TStatList; var Stat: TStatList;
                             out LiteralBytes: DWord; Reread: TStream; Cycles: QWord);
var
  lastMatchEnd, matchStart, matchOffset, inAt: QWord;
  matchLen: DWord;
  hash1, hash2: TPolyHash;
  powers: array[0..MAX_CYCLES - 1] of QWord;
  hashes1: array[0..LOOKAHEAD_A - 1] of QWord;
  pairH, pairP: array[0..LOOKAHEAD_A + MAX_CYCLES] of QWord;
  npairs, pi_, nh1: LongInt;
  offset, xx, i, j, nextChunk, nextI, lastI, matchEnd, cut, ms, lit, ml, savedHash1, hv: QWord;
  k: DWord;
  pb: PByte;

  procedure DecodeNext(BasicPos: QWord);
  var m: TLzMatch; used: QWord;
  begin
    if not DecodeLzMatch(InStat, inAt, RoundMatches, False, BaseLen, BasicPos, m, used) then
      raise EEncode.Create('BadBlockRecord');
    inAt := inAt + used;
    matchStart := m.Dest - BlockStart;
    matchLen := m.Len;
    matchOffset := m.Dest - m.Src;
  end;

begin
  lastMatchEnd := 0;
  LiteralBytes := DWord(BlockSize);
  inAt := 0;
  DecodeNext(BlockStart);

  if 2 * L > BlockSize then Exit;

  offset := Cycles - 1;
  if Cycles > 4 then xx := Cycles else xx := 4;          { X = max(CYCLES, 4) }
  PolyInit(hash1, L - offset, PRIME1);
  PolyInit(hash2, L, PRIME1);
  { PRIME1_powers[j] = PRIME1^(L-1-j) (compress.cpp:73-75) }
  powers[Cycles - 1] := Power(PRIME1, DWord(L - Cycles));
  j := Cycles - 1;
  while j > 0 do
  begin
    powers[j - 1] := powers[j] * PRIME1;
    Dec(j);
  end;
  pb := PByte(@Dict[BufOff]);

  { --- los primeros L bytes (compress.cpp:78-94) --- }
  PolyMoveTo(hash1, Dict, BufOff);
  hash2.Value := hash1.Value;
  j := 0;
  while True do
  begin
    HtMarkPossible(T, hash1.Value);
    if j = offset then Break;
    PolyUpdate(hash1, pb[PtrUInt(j)], pb[PtrUInt(L - offset + j)]);
    PolyUpdate(hash2, 0, pb[PtrUInt(L - offset + j)]);
    Inc(j);
  end;
  k := HtFindMatch(T, Dict, BufOff, 0, BlockSize, hash2.Value, DWord(hash2.Value shr 32));
  if k <> NOT_FOUND then
    if RecordMatch(T, Dict, BufOff, BlockSize, BlockStart, RoundMatches, L, MinMatch, BaseLen,
                   Reread, Stat, lastMatchEnd, matchEnd, LiteralBytes, 0, k) then
      lastMatchEnd := matchEnd;
  HtAddHash(T, hash2.Value, DWord(hash2.Value shr 32), BlockStart div L);

  { --- el ciclo principal (compress.cpp:97-210) --- }
  i := 0;
  while i + 2 * L <= BlockSize do
  begin
    savedHash1 := 0;
    nextChunk := i + L;
    while i < nextChunk do
    begin
      { el match de entrada, al llegar a su comienzo }
      if i >= matchStart then
      begin
        if matchStart + QWord(matchLen) - QWord(BaseLen) >= lastMatchEnd then
        begin
          if matchStart > lastMatchEnd then ms := matchStart else ms := lastMatchEnd;
          cut := ms - matchStart;
          ml := QWord(matchLen) - cut;
          lit := ms - lastMatchEnd;
          Enc(Stat, RoundMatches, BaseLen, DWord(lit), matchOffset, DWord(ml));
          lastMatchEnd := ms + ml;
          LiteralBytes := DWord(QWord(LiteralBytes) - ml);
        end;
        DecodeNext(BlockStart + matchStart + QWord(matchLen));
      end;

      { hash1 hasta last_match_end, redondeado hacia abajo a X (124-132) }
      if lastMatchEnd > 0 then nextI := lastMatchEnd - 1 else nextI := 0;
      if nextChunk - Cycles < nextI then nextI := nextChunk - Cycles;
      if nextI >= i + L div 2 then
      begin
        i := nextI and not QWord(xx - 1);
        PolyMoveTo(hash1, Dict, BufOff + i + offset);
      end
      else
      begin
        hv := hash1.Value;
        while i + xx <= nextI do
        begin
          j := 0;
          while j < xx do
          begin
            hv := hv * hash1.Prime + QWord(pb[PtrUInt(i + j + L)]) -
                  hash1.PrimeL * QWord(pb[PtrUInt(i + offset + j)]);
            Inc(j);
          end;
          i := i + xx;
        end;
        hash1.Value := hv;
      end;

      lastI := i + LOOKAHEAD_A;
      if nextChunk < lastI then lastI := nextChunk;

      { hash1 de a CYCLES (138-149) }
      hv := hash1.Value;
      nh1 := Hash1Batch(pb, i, lastI, Cycles, L, hv, hash1.Prime, hash1.PrimeL, @hashes1[0],
                        PByte(T.BitArr), T.BitShift);
      hash1.Value := hv;
      savedHash1 := hashes1[nh1 - 1];

      { bitarr y las candidatas (152-184) }
      npairs := CheckBatch(T, pb, i, lastI, Cycles, L, lastMatchEnd, matchStart, @hashes1[0],
                           @powers[0], hash2.Prime, hash2.PrimeL, @pairH[0], @pairP[0]);

      { chunkarr, buscando un match (187-192) }
      pi_ := 0;
      while True do
      begin
        pi_ := HtNextCandidate(T, @pairH[0], pi_, npairs);
        if pi_ >= npairs then Break;
        k := HtFindMatch(T, Dict, BufOff, pairP[pi_], BlockSize, pairH[pi_],
                         DWord(pairH[pi_] shr 32));
        if k <> NOT_FOUND then
          if RecordMatch(T, Dict, BufOff, BlockSize, BlockStart, RoundMatches, L, MinMatch,
                         BaseLen, Reread, Stat, lastMatchEnd, matchEnd, LiteralBytes,
                         pairP[pi_], k) then
          begin
            lastMatchEnd := matchEnd;
            Break;                     { goto match_found2 }
          end;
        Inc(pi_);
      end;
    end;

    { las ultimas CYCLES posiciones del chunk otra vez (196-208), y add_hash }
    hash1.Value := savedHash1;
    hash2.Value := savedHash1;
    HtMarkPossible(T, hash1.Value);
    j := 1;
    while j < Cycles do
    begin
      PolyUpdate(hash1, pb[PtrUInt(i - Cycles + j + offset)], pb[PtrUInt(i - Cycles + j + L)]);
      HtMarkPossible(T, hash1.Value);
      PolyUpdate(hash2, 0, pb[PtrUInt(i - Cycles + j + L)]);
      Inc(j);
    end;
    HtAddHash(T, hash2.Value, DWord(hash2.Value shr 32), (BlockStart + i) div L);
  end;
end;

procedure CompressFixed(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
                        RoundMatches: Boolean; L, MinMatch: QWord; BaseLen: DWord;
                        BlockStart: QWord; const InStat: TStatList; var Stat: TStatList;
                        out LiteralBytes: DWord; Reread: TStream; Accelerator: DWord);
begin
  { switch (ACCELERATOR) (srep.cpp:748-758) }
  if (Accelerator <> 0) and (Length(T.BitArr) > 0) then
    CompressFixedAccel(T, Dict, BufOff, BlockSize, RoundMatches, L, MinMatch, BaseLen,
                       BlockStart, InStat, Stat, LiteralBytes, Reread, Accelerator)
  else
    CompressPlain(T, Dict, BufOff, BlockSize, RoundMatches, L, MinMatch, BaseLen,
                  BlockStart, InStat, Stat, LiteralBytes, Reread);
end;

end.
