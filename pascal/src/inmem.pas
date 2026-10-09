unit Inmem;
{ El match finder REP en memoria de -m0 (inmem.rs, que porta
  compress_inmem.cpp). La entrada pasa por un diccionario rotativo -- el
  anillo del driver --, y para cada ventana de L bytes se busca la ventana
  ANTERIOR con el mismo "maximo local del hash". Los matches pueden ir a
  bloques leidos antes, por eso la aritmetica es modular sobre el anillo.

  TIndex es size_t en el C++: el hash es de 64 bits en las builds de 64 y de
  32 en i686 (una build C++ de 32 bits da otros bytes en -m0). El Rust es
  siempre de 64, y aca tambien: el oraculo es el de x86-64, en los dos
  targets. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses Widths, Hashes, LzCodec;

const
  INMEM_PREFETCH = 100;   { su efecto visible: los ceros al final de hashptr }

type
  TQList = record
    W: array of QWord;
    N: QWord;
  end;

  TDictCompressor = record
    L, MinMatch, BaseLen: QWord;
    MaxDist: QWord;           { MAX_DIST: nada llega mas atras que esto }
    HashMask: QWord;
    HashArr: array of QWord;
  end;

procedure DcInit(out D: TDictCompressor; InmemDictSize, HashSizeHint, MinMatch, L,
                 BaseLen: QWord);
{ prepare_buffer sobre B[At..At+Len): el maximo local del hash rodante en cada
  bloque de L bytes, y donde ocurrio. }
procedure DcPrepareBuffer(const D: TDictCompressor; var HashPtr: TQList; const B: TBytes;
                          At, Len: QWord);
{ compress: Dict es el anillo de DictSize bytes y el bloque esta en BufStart. }
procedure DcCompress(var D: TDictCompressor; const Dict: TBytes; DictSize, BufStart,
                     BufSize: QWord; const HashPtr: TQList; out LiteralBytes: DWord;
                     var Out_: TStatList);

implementation

uses Rolling, FixedCompress;

function MinHashSize(N: QWord): QWord;
begin
  Result := (N div 4 + 1) * 5;
end;

procedure QPush(var Q: TQList; V: QWord);
begin
  if Q.N >= QWord(Length(Q.W)) then
  begin
    if Length(Q.W) < 256 then SetLength(Q.W, 256) else SetLength(Q.W, Length(Q.W) * 2);
  end;
  Q.W[Q.N] := V;
  Inc(Q.N);
end;

procedure DcInit(out D: TDictCompressor; InmemDictSize, HashSizeHint, MinMatch, L,
                 BaseLen: QWord);
var hint, hashsize: QWord;
begin
  D.L := L;
  D.MinMatch := MinMatch;
  D.BaseLen := BaseLen;
  D.MaxDist := InmemDictSize;
  D.HashMask := 0;
  SetLength(D.HashArr, 0);
  if InmemDictSize <> 0 then
  begin
    if HashSizeHint <> 0 then hint := HashSizeHint
    else hint := MinHashSize(8 * (InmemDictSize div L));
    hashsize := RoundupToPowerOfTwo(hint);
    { hashsize cuenta BYTES en el C++; la tabla son elementos de 8 }
    D.HashMask := hashsize div 8 - 1;
    SetLength(D.HashArr, hashsize div 8);
  end;
end;

procedure DcPrepareBuffer(const D: TDictCompressor; var HashPtr: TQList; const B: TBytes;
                          At, Len: QWord);
var numBlocks, blk, i, ptr, maxi: QWord; hash: TPolyHash; maxhash: QWord; pf: LongInt;
begin
  HashPtr.N := 0;
  if D.MaxDist = 0 then Exit;
  numBlocks := Len div D.L;                { bloques enteros }
  if numBlocks <= 1 then Exit;
  PolyInit(hash, D.L, PRIME1);
  PolyMoveTo(hash, B, At);
  ptr := At;
  blk := 1;
  while blk < numBlocks do
  begin
    maxhash := hash.Value;
    maxi := 0;
    i := 0;
    while i < D.L do
    begin
      if hash.Value > maxhash then
      begin
        maxhash := hash.Value;
        maxi := i;
      end;
      PolyUpdate(hash, B[ptr], B[ptr + D.L]);
      Inc(ptr);
      Inc(i);
    end;
    QPush(HashPtr, maxhash and D.HashMask);
    QPush(HashPtr, maxi);
    Inc(blk);
  end;
  for pf := 1 to INMEM_PREFETCH * 2 do QPush(HashPtr, 0);   { pf LongInt: QWord no va en un for en i386 }
end;

function FindMatchStart(const Dict: TBytes; P, Q, Start: QWord): QWord;
begin
  while Q > Start do
  begin
    Dec(P);
    Dec(Q);
    if Dict[P] <> Dict[Q] then Exit(Q + 1);
  end;
  Result := Q;
end;

function FindMatchEnd(const Dict: TBytes; P, Q, EndQ: QWord): QWord;
begin
  while (Q < EndQ) and (Dict[P] = Dict[Q]) do
  begin
    Inc(P);
    Inc(Q);
  end;
  Result := Q;
end;

procedure DcCompress(var D: TDictCompressor; const Dict: TBytes; DictSize, BufStart,
                     BufSize: QWord; const HashPtr: TQList; out LiteralBytes: DWord;
                     var Out_: TStatList);
var
  l, bufend, lastMatchEnd, dataStart, hp, lastI, i, hash, found: QWord;
  matchDistance, lowBound, highBound, start, endq, matchLen, litLen, sb: QWord;
begin
  LiteralBytes := DWord(BufSize);
  if D.MaxDist = 0 then Exit;
  l := D.L;
  bufend := BufStart + BufSize;
  lastMatchEnd := BufStart;
  dataStart := (BufStart + DictSize - D.MaxDist) mod DictSize;
  hp := 0;
  lastI := BufStart;
  while lastI + 2 * l <= bufend do
  begin
    hash := HashPtr.W[hp]; Inc(hp);
    i := lastI + HashPtr.W[hp]; Inc(hp);
    if i >= lastMatchEnd then
    begin
      found := D.HashArr[hash];
      if found <> 0 then
      begin
        if found < i then matchDistance := i - found
        else matchDistance := DictSize - found + i;
        if matchDistance > D.MaxDist then
        begin
          { no_match }
          D.HashArr[hash] := i;
          lastI := lastI + l;
          Continue;
        end;
        if found >= dataStart then
        begin
          if found - dataStart > i then lowBound := 0
          else lowBound := i - (found - dataStart);
        end
        else
          lowBound := i - found;
        if found < i then highBound := DictSize
        else highBound := DictSize - found + i;
        if lastMatchEnd > lowBound then sb := lastMatchEnd else sb := lowBound;
        start := FindMatchStart(Dict, found, i, sb);
        if bufend < highBound then endq := FindMatchEnd(Dict, found, i, bufend)
        else endq := FindMatchEnd(Dict, found, i, highBound);
        matchLen := endq - start;
        litLen := start - lastMatchEnd;
        if matchLen >= D.MinMatch then
        begin
          if not EncodeLzMatch(Out_, False, DWord(D.BaseLen), DWord(litLen), matchDistance,
                               DWord(matchLen)) then
            MatchTooSmall(DWord(matchLen), DWord(D.BaseLen));
          LiteralBytes := DWord(QWord(LiteralBytes) - matchLen);
          lastMatchEnd := endq;
        end;
      end;
    end;
    { la etiqueta no_match cae aca: se registra la ventana }
    D.HashArr[hash] := i;
    lastI := lastI + l;
  end;
end;

end.
