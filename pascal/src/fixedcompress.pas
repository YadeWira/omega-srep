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

{ record_match: mide el match del chunk K contra la posicion I y lo emite si
  llega a MinMatch. }
function RecordMatch(const T: THashTableRec; const Dict: TBytes; BufOff, BlockSize,
                     BlockStart: QWord; RoundMatches: Boolean; L, MinMatch: QWord;
                     BaseLen: DWord; Reread: TStream; var Stat: TStatList;
                     LastMatchEnd: QWord; out MatchEnd: QWord; var LiteralBytes: DWord;
                     I: QWord; K: DWord): Boolean;
var addLen, matchLen: DWord; matchStart, matchOffset: QWord;
begin
  MatchEnd := 0;
  matchLen := HtMatchLen(T, K, Dict, BufOff, BufOff + LastMatchEnd, BufOff + I,
                         BufOff + BlockSize, BlockStart, RoundMatches, Reread, addLen);
  if QWord(matchLen) >= MinMatch then
  begin
    matchStart := I - QWord(addLen);
    if RoundMatches then matchLen := DWord(QWord(matchLen) div L * L);
    matchOffset := BlockStart + I - QWord(K) * L;
    Enc(Stat, RoundMatches, BaseLen, DWord(matchStart - LastMatchEnd), matchOffset, matchLen);
    MatchEnd := matchStart + QWord(matchLen);
    LiteralBytes := DWord(QWord(LiteralBytes) - QWord(matchLen));
    Exit(True);
  end;
  Result := False;
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
  { el lazo caliente trabaja sobre copias locales: hash1 en un registro y la
    tabla por puntero, sin pasar por el record ni por el indice dinamico }
  hv, prime, primeL, hmask: QWord;
  pd: PByte;
  chunkArr: PDWord;

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
  pd := @Dict[BufOff];
  chunkArr := @T.ChunkArr[0];
  hmask := T.HashSize1;

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
            hv := hv * prime + QWord(pd[i + L]) - primeL * QWord(pd[i]);
            Inc(i);
          end;
        hash1.Value := hv;
      end;

      lastI := i + LOOKAHEAD;
      if nextChunk < lastI then lastI := nextChunk;

      { el lote: cuatro posiciones mas, guardando las candidatas. Una
        candidata cuyo primer slot de chunkarr esta vacio no se guarda:
        HtFindMatch la descartaria en el primer paso (NOT_FOUND), y entre el
        lote y la busqueda nada escribe chunkarr, asi que el orden y el
        resultado de las que quedan son los mismos. }
      npairs := 0;
      hv := hash1.Value;
      while i < lastI do
        for c := 1 to X do
        begin
          hv := hv * prime + QWord(pd[i + L]) - primeL * QWord(pd[i]);
          Inc(i);
          if (i >= lastMatchEnd) and (i < matchStart) and
             (chunkArr[hv and hmask] <> NOT_FOUND) then
          begin
            pairH[npairs] := hv;
            pairP[npairs] := i;
            Inc(npairs);
          end;
        end;
      hash1.Value := hv;

      { chunkarr, buscando un match }
      for pi_ := 0 to npairs - 1 do
      begin
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
      end;
    end;

    { add_hash en la frontera de L, con el valor ACTUAL de hash1 }
    HtAddHash(T, hash1.Value, DWord(hash1.Value shr 32), (BlockStart + i) div L);
  end;
end;

end.
