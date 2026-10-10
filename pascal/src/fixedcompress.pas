unit FixedCompress;
{ El compresor de un bloque para -m3/-m4/-m5 (compress.rs, que porta
  compress.cpp con ACCELERATOR == 0 -- todas las variantes dan el mismo
  archivo, medido). Lo que si se ve en la salida, y se reproduce:

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

{ compress<0>: los records van a Stat y la cuenta de literales a LiteralBytes.
  Dict tiene el bloque en BufOff; InStat es la lista de entrada. }
procedure CompressFixed(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
                        RoundMatches: Boolean; L, MinMatch: QWord; BaseLen: DWord;
                        BlockStart: QWord; const InStat: TStatList; var Stat: TStatList;
                        out LiteralBytes: DWord; Reread: TStream);

{ El error de ENCODE_LZ_MATCH, con el texto del Debug del Rust. }
procedure MatchTooSmall(MatchLen, BaseLen: DWord);

implementation

uses Rolling;

const
  LOOKAHEAD = 128;      { compress.cpp:134 con ACCELERATOR == 0 }
  X = 4;                { max(CYCLES, 4) }

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
var dest, decodedSrc: QWord; old: TBytes;
begin
  Result := False;
  if ((QWord(Len) mod B) <> 0) or (QWord(Len) < B) then Exit;
  dest := BlockStart + MatchStart;
  decodedSrc := dest div B * B - (dest - Src) div B * B;
  if decodedSrc >= dest then Exit;
  SetLength(old, Len);
  if ReadAt(Reread, decodedSrc, old, Len) <> QWord(Len) then Exit;
  Result := CompareByte(old[0], Dict[BufOff + MatchStart], Len) = 0;
end;

{ record_match: mide el match del chunk K contra la posicion I y lo emite si
  llega a MinMatch. }
function RecordMatch(const T: THashTableRec; const Dict: TBytes; BufOff, BlockSize,
                     BlockStart: QWord; RoundMatches: Boolean; L, MinMatch: QWord;
                     BaseLen: DWord; Reread: TStream; var Stat: TStatList;
                     LastMatchEnd: QWord; out MatchEnd: QWord; var LiteralBytes: DWord;
                     I: QWord; K: DWord): Boolean;
var addLen, matchLen: DWord; matchStart, matchOffset, b, src, skip, cut: QWord;
begin
  MatchEnd := 0;
  matchLen := HtMatchLen(T, K, Dict, BufOff, BufOff + LastMatchEnd, BufOff + I,
                         BufOff + BlockSize, BlockStart, RoundMatches, Reread, addLen);
  if QWord(matchLen) >= MinMatch then
  begin
    matchStart := I - QWord(addLen);
    if RoundMatches then matchLen := DWord(QWord(matchLen) div L * L);
    matchOffset := BlockStart + I - QWord(K) * L;
    { Un record redondeado guarda offset y largo en unidades de BASE_LEN, no
      de L (el L1 de ENCODE_LZ_MATCH, srep.cpp:117), y el decoder rearma el
      origen como dest div BASE_LEN * BASE_LEN - offset div BASE_LEN *
      BASE_LEN y el largo como un numero entero de BASE_LEN. Eso es exacto si
      el origen (K*L) y el largo son multiplos de BASE_LEN: siempre, cuando
      BASE_LEN divide a L (el default). Con -c debajo de BASE_LEN (-m3 -c8
      -l16) o un BASE_LEN que no divide a L (-m3 -c8 -l17, -m3 -dl17) el C++
      escribia un archivo que no descomprime (exit 0: perdida de datos
      silenciosa) o cortaba con "match len too small" (exit 4), y el port
      igual.
      Un record que no va a descomprimir a estos bytes ahora se corre al
      proximo origen de la grilla de BASE_LEN y se recorta a unidades enteras
      -- sigue adentro del match verificado, los bytes son los mismos -- o no
      se toma si no queda ni una unidad. Uno que descomprime bien tal cual (uno
      exacto, o uno con el origen corrido que por casualidad tiene los mismos
      bytes, como en una entrada toda en cero) se escribe igual que antes: los
      archivos que descomprimian no cambian (compress.rs, record_match). }
    if RoundMatches then
    begin
      b := QWord(BaseLen);
      src := QWord(K) * L;
      if not (((src mod b) = 0) and ((QWord(matchLen) mod b) = 0) and (QWord(matchLen) >= b))
         and not DecodesAsIs(Dict, BufOff, BlockStart, matchStart, src, matchLen, b, Reread) then
      begin
        skip := (b - src mod b) mod b;
        if QWord(matchLen) > skip then cut := (QWord(matchLen) - skip) div b * b else cut := 0;
        if cut < b then Exit(False);
        matchStart := matchStart + skip;
        matchLen := DWord(cut);
      end;
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

procedure CompressFixed(var T: THashTableRec; const Dict: TBytes; BufOff, BlockSize: QWord;
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

end.
