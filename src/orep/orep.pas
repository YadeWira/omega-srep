{ OREP: one-pass streaming long-range dedup (clean-room, MIT).

  The output is meant for a backend (lzma, zstd...): long repeats within
  `Window` bytes become (length, distance) pairs and the rest stays as
  literals.  Format: spec/orep-format.md.

  API (zlib style, no callbacks, no global mutable state, one state per
  thread):

    OrepParamsDefault(P); P.Window := ...;
    OrepEncInit(E, P)  ->  OrepEncRun(E, NextIn, AvailIn, NextOut, AvailOut,
                                      OREP_RUN | OREP_FLUSH | OREP_FINISH)
                       ->  OrepEncEnd(E)
    OrepDecInit(D, MemLimit) -> OrepDecRun(D, ...) -> OrepDecEnd(D)

  P.Threads >= 2 runs the search on a coordinator thread helped by
  Threads - 1 workers, while the caller's thread copies input and writes
  output; the stream is the same with any number of threads.  With threads
  the TOrepEnc must stay where OrepEncInit put it until OrepEncEnd (the
  threads keep its address).  On Unix the program needs a thread manager
  (cthreads); without one OREP runs on the caller's thread only.

  Run returns OREP_OK (call again with more input or more output room),
  OREP_END (the stream is complete and all of it was written), or an error
  (< 0).  OrepEncodeBuf / OrepDecodeBuf do a whole buffer in memory.

  OrepEncMemory(P) / OrepDecMemory(Window, Chunk) give the most memory the
  state will allocate, for a memory limiter.

  The hot loop is native (src/c/orep_core.c, linked as orep_core.o); with
  -dOREP_NO_NATIVE the Pascal reference below is used instead, and both
  give the same bytes. }

unit orep;

{$mode objfpc}{$H+}
{$PACKRECORDS C}
{$Q-}{$R-}{$POINTERMATH ON}

interface

uses SysUtils;

const
  OREP_OK = 0;
  OREP_END = 1;
  OREP_E_PARAM = -1;   { bad parameters or a call in the wrong state }
  OREP_E_MEM = -2;     { allocation failed or over the memory limit }
  OREP_E_DATA = -3;    { corrupt or truncated stream }
  OREP_E_VERSION = -4; { not an OREP stream, or a newer version }

  OREP_RUN = 0;
  OREP_FLUSH = 1;      { end the current block now (the stream goes on) }
  OREP_FINISH = 2;     { no more input: write the end of the stream }

  OREP_VERSION_STR = '0.0.2';
  OREP_FORMAT = 1;

  OREP_MIN_MATCH = 16;               { format minimum match length }
  OREP_MAX_WINDOW = QWord($F0000000); { < 2^32 minus a chunk }
  OREP_MAX_CHUNK = 64 * 1024 * 1024;
  OREP_MIN_CHUNK = 64 * 1024;

type
  TOrepParams = record
    Window: QWord;      { max distance, bytes (default 512 MiB) }
    SizeHint: QWord;    { total input if known, 0 = unknown: a smaller
                          input gets a smaller window (same matches) }
    MinLen: LongWord;   { shortest match searched, >= 16 (default 64) }
    Chunk: LongWord;    { block size, 64 KiB..64 MiB (default 4 MiB) }
    Align: LongWord;    { match lengths multiple of this, and literals kept
                          at their input position modulo it (default 4,
                          lzma's pb2) }
    MinDist: QWord;     { matches nearer than this are left to the
                          backend (default 0) }
    Density: LongWord;  { anchors: about one per (MinLen - gram) / Density
                          positions; higher finds more short matches and is
                          slower and uses more table (default 4) }
    Threads: LongWord;  { threads for the encoder, 0 or 1 = the caller's
                          only; OREP creates the others and goes on with
                          fewer if it cannot.  The output is the same with
                          any number. }
  end;

  POrepCfg = ^TOrepCfg;
  TOrepCfg = record      { shared with orep_core.c: same layout }
    T: array[0..255] of QWord;
    Window: QWord;
    RingSize: QWord;
    MinDist: QWord;
    Ring: PByte;
    Table: PQWord;
    MinLen, Gram, SMask, MaxGap, TBits, Align, MinKeep, SShift: LongWord;
  end;

  TOrepEnc = record
    Cfg: TOrepCfg;
    TableRaw: Pointer;
    Chunk: LongWord;
    RingAlloc: QWord;
    SlotAbs: QWord;      { absolute position of the current slot }
    SlotPhys: QWord;     { its offset in the ring }
    Fill: LongWord;      { bytes in the slot }
    BlockStart: LongWord;{ first byte of the slot not yet in a block }
    PrevDist: QWord;
    Cap: LongWord;
    Lit, Len: PLongWord;
    Dist: PQWord;
    NMatch: LongWord;
    Stage: PByte;        { header / columns / crc / end marker }
    StageCap, StageLen, StagePos: LongWord;
    Phase: Integer;      { 0 header, 1 filling, 2 stage, 3 literals, 4 crc, 5 end }
    LitRun, LitOff, LitBase: LongWord;
    BlockCrc: LongWord;
    BlkPhys: QWord;
    BlkLen: LongWord;
    Total: QWord;
    StreamPos: QWord;    { stream bytes staged or written so far }
    Ended, Inited: Boolean;
    { the search of one block, in batches of segments }
    APos, AIdx, ATag, Cand, FL, BL: PLongWord;  { OREP_BATCH * OREP_SUB }
    SegCnt: array[0..7] of LongWord;
    BCAbs, BPhysQ: QWord;                       { the block being searched }
    BLen, BSeg0, BNPos, VCap: LongWord;
    Pool: Pointer;                              { worker threads, or nil }
    NShard: LongWord;
    { the block being searched (by the coordinator thread, or inline) }
    SLit, SLen: PLongWord;
    SDist: PQWord;
    SNM: LongInt;
    InFlight: Boolean;
    Coord: Pointer;                             { coordinator, or nil }
    SList: PLongWord;    { per segment: its anchors grouped by shard }
    SOfs: PLongWord;     { per segment: NShard + 1 offsets into SList }
    CandL: PLongWord;    { the candidates in SList order }
  end;

  TOrepDec = record
    Window: QWord;
    Chunk: LongWord;
    RingSize, RingAlloc: QWord;
    Ring: PByte;
    MemLimit: QWord;
    Total: QWord;        { bytes decoded and checked }
    WPhys: QWord;        { ring offset of Total }
    Phase: Integer;
    Hdr: array[0..31] of Byte;
    HdrLen: LongWord;
    VarIdx: Integer;     { which header varint }
    VarVal: QWord;
    VarShift: LongWord;
    OutSize, NMatch, ColSize: QWord;
    Cols: PByte;
    ColCap, ColLen: LongWord;
    Lit, Len, Dist: PLongWord;
    MCap: LongWord;
    Rec: LongWord;       { current record }
    InRec: Boolean;      { literal run of Rec done, match pending }
    LitLeft: LongWord;
    BlkPos: LongWord;    { bytes of the block written }
    CrcBuf: array[0..7] of Byte;
    CrcLen: LongWord;
    InPos: QWord;        { stream bytes consumed }
    Align: LongWord;
    PadLeft: LongWord;
    EmitPos: LongWord;
    Inited: Boolean;
  end;

procedure OrepParamsDefault(out P: TOrepParams);
function OrepEncMemory(const P: TOrepParams): QWord;
function OrepDecMemory(Window: QWord; Chunk: LongWord): QWord;

function OrepEncInit(out E: TOrepEnc; const P: TOrepParams): Integer;
function OrepEncRun(var E: TOrepEnc; var NextIn: PByte; var AvailIn: SizeUInt;
  var NextOut: PByte; var AvailOut: SizeUInt; Mode: Integer): Integer;
{ start a new stream with the same parameters, keeping the memory and the
  threads (the same bytes as a new state) }
function OrepEncReset(var E: TOrepEnc): Integer;
procedure OrepEncEnd(var E: TOrepEnc);

function OrepDecInit(out D: TOrepDec; MemLimit: QWord): Integer;
function OrepDecRun(var D: TOrepDec; var NextIn: PByte; var AvailIn: SizeUInt;
  var NextOut: PByte; var AvailOut: SizeUInt): Integer;
procedure OrepDecEnd(var D: TOrepDec);

{ whole buffers; Dst is allocated with GetMem and freed with FreeMem }
function OrepEncodeBuf(Src: PByte; SrcLen: SizeUInt; const P: TOrepParams;
  out Dst: PByte; out DstLen: SizeUInt): Integer;
function OrepDecodeBuf(Src: PByte; SrcLen: SizeUInt; MemLimit: QWord;
  out Dst: PByte; out DstLen: SizeUInt): Integer;

function OrepCrc32c(Crc: LongWord; P: PByte; N: SizeUInt): LongWord;
function OrepErrorText(Code: Integer): string;

implementation

{$IFNDEF OREP_NO_NATIVE}
{$L orep_core.o}
function orep_anchors(c: POrepCfg; p: PByte; s0, s1: LongWord;
  apos, aidx, atag: PLongWord): LongWord; cdecl; external name 'orep_anchors';
procedure orep_probe(c: POrepCfg; cabs: QWord; apos, aidx, atag,
  list: PLongWord; nl: LongWord; cand: PLongWord); cdecl;
  external name 'orep_probe';
procedure orep_verify(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand: PLongWord; n, cap: LongWord; fl, bl: PLongWord); cdecl;
  external name 'orep_verify';
function orep_select(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand, fl, bl: PLongWord; n, cap: LongWord; var litstart, nm: LongWord;
  lit, len: PLongWord; dist: PQWord; mcap: LongWord): LongInt; cdecl;
  external name 'orep_select';
function orep_cont(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  prev_dist: QWord): LongWord; cdecl; external name 'orep_cont';
procedure orep_shard(aidx: PLongWord; n, ns, tbits: LongWord;
  list, ofs: PLongWord); cdecl; external name 'orep_shard';
function orep_crc32c(t: PLongWord; crc: LongWord; p: PByte;
  n: SizeUInt): LongWord; cdecl; external name 'orep_crc32c';
{$ENDIF}

const
  OREP_B = QWord($9E3779B97F4A7C15);
  OREP_SUB = 65536;
  OREP_BATCH = 8;      { segments per batch }
  OREP_PF = 16;
  HDR_SIZE = 28;
  Magic: array[0..3] of Char = 'OREP';

var
  { read-only after unit initialization }
  CrcTab: array[0..8 * 256 - 1] of LongWord;

procedure InitCrc;
var
  I, J: Integer;
  C: LongWord;
begin
  for I := 0 to 255 do
  begin
    C := I;
    for J := 0 to 7 do
      if C and 1 <> 0 then C := (C shr 1) xor $82F63B78
      else C := C shr 1;
    CrcTab[I] := C;
  end;
  for I := 0 to 255 do
    for J := 1 to 7 do
      CrcTab[J * 256 + I] := (CrcTab[(J - 1) * 256 + I] shr 8) xor
        CrcTab[CrcTab[(J - 1) * 256 + I] and $FF];
end;

function OrepCrc32c(Crc: LongWord; P: PByte; N: SizeUInt): LongWord;
{$IFDEF OREP_NO_NATIVE}
begin
  Crc := not Crc;
  while N > 0 do
  begin
    Crc := CrcTab[(Crc xor P^) and $FF] xor (Crc shr 8);
    Inc(P);
    Dec(N);
  end;
  Result := not Crc;
end;
{$ELSE}
begin
  Result := orep_crc32c(@CrcTab[0], Crc, P, N);
end;
{$ENDIF}

function OrepErrorText(Code: Integer): string;
begin
  case Code of
    OREP_OK: Result := 'ok';
    OREP_END: Result := 'end of stream';
    OREP_E_PARAM: Result := 'bad parameter or call';
    OREP_E_MEM: Result := 'out of memory or over the memory limit';
    OREP_E_DATA: Result := 'corrupt or truncated OREP stream';
    OREP_E_VERSION: Result := 'not an OREP stream or unsupported version';
  else
    Result := 'error ' + IntToStr(Code);
  end;
end;

{ ---- parameters ---------------------------------------------------- }

procedure OrepParamsDefault(out P: TOrepParams);
begin
  P.Window := 512 * QWord(1024 * 1024);
  P.SizeHint := 0;
  P.MinLen := 64;
  P.Chunk := 4 * 1024 * 1024;
  P.Align := 4;
  P.Density := 4;
  P.MinDist := 0;
  P.Threads := 1;
end;

function CheckParams(const P: TOrepParams): Boolean;
begin
  Result := (P.Window >= 1) and (P.Window <= OREP_MAX_WINDOW) and
    (P.MinLen >= OREP_MIN_MATCH) and (P.MinLen <= 65536) and
    (P.Chunk >= OREP_MIN_CHUNK) and (P.Chunk <= OREP_MAX_CHUNK) and
    (P.Align >= 1) and (P.Align <= 4096) and (P.Align <= P.MinLen) and
    (P.Density >= 1) and (P.Density <= 64) and (P.Threads <= 256);
end;

{ the window the stream actually uses: a known small input gets a smaller
  one, rounded up to a chunk (it never limits a match in that input) }
function EffWindow(const P: TOrepParams): QWord;
begin
  Result := P.Window;
  if (P.SizeHint > 0) and (P.SizeHint < Result) then
  begin
    Result := (P.SizeHint + P.Chunk - 1) div P.Chunk * P.Chunk;
    if Result > P.Window then Result := P.Window;
  end;
end;

function RingFor(Window: QWord; Chunk: LongWord): QWord;
begin
  Result := (Window + Chunk - 1) div Chunk * Chunk + Chunk;
end;

procedure Derive(const P: TOrepParams; W: QWord; out Gram, SMask, MaxGap,
  TBits, MinKeep, SShift: LongWord);
var
  S, Cov, SB: LongWord;
  Ent: QWord;
begin
  Gram := P.MinLen div 2;
  if Gram > 32 then Gram := 32;
  Cov := P.MinLen - Gram + 1;
  S := 1;
  while S * 2 <= Cov div P.Density do S := S * 2;
  SMask := S - 1;
  SB := 0;
  while (LongWord(1) shl SB) < S do Inc(SB);
  SShift := Gram - SB;
  MaxGap := 4 * S;
  Ent := W div S div 4;   { buckets of 4 }
  TBits := 10;
  while (TBits < 30) and ((QWord(1) shl TBits) < Ent) do Inc(TBits);
  MinKeep := OREP_MIN_MATCH;
  if P.Align > MinKeep then MinKeep := P.Align;
end;

function OrepEncMemory(const P: TOrepParams): QWord;
var
  G, SM, MG, TB, MK, SS, Cap: LongWord;
  W: QWord;
begin
  if not CheckParams(P) then Exit(0);
  W := EffWindow(P);
  Derive(P, W, G, SM, MG, TB, MK, SS);
  Cap := P.Chunk div MK + 2;
  Result := RingFor(W, P.Chunk) + P.Chunk + (QWord(32) shl TB) + 64 +
    8 * OREP_BATCH * OREP_SUB * 4 +
    QWord(Cap) * 32 + QWord(Cap) * 15 + 4160 + SizeOf(TOrepEnc);
end;

function OrepDecMemory(Window: QWord; Chunk: LongWord): QWord;
var
  Cap: QWord;
begin
  Cap := Chunk div OREP_MIN_MATCH + 2;
  Result := RingFor(Window, Chunk) + Cap * 12 + Cap * 15 + SizeOf(TOrepDec);
end;

procedure InitTables(var C: TOrepCfg);
var
  X, Z: QWord;
  I: Integer;
begin
  X := QWord($4F52455030303031); { "OREP0001" }
  for I := 0 to 255 do
  begin
    X := X + QWord($9E3779B97F4A7C15);
    Z := X;
    Z := (Z xor (Z shr 30)) * QWord($BF58476D1CE4E5B9);
    Z := (Z xor (Z shr 27)) * QWord($94D049BB133111EB);
    C.T[I] := Z xor (Z shr 31);
  end;
end;

{ ---- Pascal reference of orep_find ------------------------------------ }

{$IFDEF OREP_NO_NATIVE}
function Ld64(P: PByte): QWord; inline;
begin
  Result := QWord(P[0]) or (QWord(P[1]) shl 8) or (QWord(P[2]) shl 16) or
    (QWord(P[3]) shl 24) or (QWord(P[4]) shl 32) or (QWord(P[5]) shl 40) or
    (QWord(P[6]) shl 48) or (QWord(P[7]) shl 56);
end;

function Mix(H: QWord): QWord; inline;
begin
  H := H xor (H shr 29);
  H := H * QWord($BF58476D1CE4E5B9);
  Result := H xor (H shr 32);
end;

function GramHash(P: PByte; G: LongWord): QWord;
var
  K: QWord;
  O: LongWord;
begin
  K := G;
  O := 0;
  while O + 8 < G do
  begin
    K := (K xor Ld64(P + O)) * QWord($9E3779B97F4A7C15);
    K := K xor (K shr 28);
    Inc(O, 8);
  end;
  K := (K xor Ld64(P + G - 8)) * QWord($9E3779B97F4A7C15);
  Result := Mix(K);
end;

function Fwd(const C: TOrepCfg; S, D: QWord; Max: LongWord): LongWord;
var
  L, Run, K: LongWord;
  Room: QWord;
begin
  L := 0;
  while L < Max do
  begin
    Room := C.RingSize - S;
    Run := Max - L;
    if Room < Run then Run := LongWord(Room);
    K := 0;
    while K < Run do
    begin
      if C.Ring[S + K] <> C.Ring[D + K] then Exit(L + K);
      Inc(K);
    end;
    Inc(L, Run);
    Inc(S, Run);
    Inc(D, Run);
    if S = C.RingSize then S := 0;
  end;
  Result := L;
end;

function Bwd(const C: TOrepCfg; S, D: QWord; Max: LongWord): LongWord;
var
  L, Run, K: LongWord;
begin
  L := 0;
  while L < Max do
  begin
    Run := Max - L;
    if S = 0 then S := C.RingSize;
    if S < Run then Run := LongWord(S);
    K := 0;
    while K < Run do
    begin
      if C.Ring[S - K - 1] <> C.Ring[D - K - 1] then Exit(L + K);
      Inc(K);
    end;
    Inc(L, Run);
    Dec(S, Run);
    Dec(D, Run);
  end;
  Result := L;
end;

function Way(B: PQWord; Tag: LongWord): Integer;
var
  W: Integer;
begin
  for W := 0 to 3 do
    if (LongWord(B[W] shr 32) = Tag) and (LongWord(B[W]) <> 0) then Exit(W);
  Result := -1;
end;

function SrcPos(C: POrepCfg; Dp, D: QWord): QWord;
begin
  if Dp >= D then Result := Dp - D else Result := Dp + C^.RingSize - D;
end;

function orep_anchors(c: POrepCfg; p: PByte; s0, s1: LongWord;
  apos, aidx, atag: PLongWord): LongWord;
var
  G, Last, Pos, I, TShift: LongWord;
  H, M: QWord;
begin
  Result := 0;
  if s1 <= s0 then Exit;
  G := c^.Gram;
  TShift := 64 - c^.TBits;
  H := 0;
  Last := s0;
  for I := 0 to G - 2 do H := (H shl 1) + c^.T[p[s0 + I]];
  for Pos := s0 to s1 - 1 do
  begin
    H := (H shl 1) + c^.T[p[Pos + G - 1]];
    if ((LongWord(H shr c^.SShift) and c^.SMask) = 0) or
      (Pos - Last >= c^.MaxGap) then
    begin
      M := GramHash(p + Pos, G);
      apos[Result] := Pos;
      aidx[Result] := LongWord(M shr TShift);
      atag[Result] := LongWord(M);
      Inc(Result);
      Last := Pos;
    end;
  end;
end;

procedure orep_probe(c: POrepCfg; cabs: QWord; apos, aidx, atag,
  list: PLongWord; nl: LongWord; cand: PLongWord);
var
  I, J, A, Cur32, D: LongWord;
  B: PQWord;
  W: Integer;
  DD: QWord;
begin
  for I := 1 to nl do
  begin
    if list <> nil then J := list[I - 1] else J := I - 1;
    B := c^.Table + 4 * aidx[J];
    A := apos[J];
    Cur32 := LongWord(cabs + A);
    W := Way(B, atag[J]);
    D := 0;
    if W >= 0 then
    begin
      DD := LongWord(Cur32 - (LongWord(B[W]) - 1));
      if (DD <> 0) and (DD >= c^.MinDist) and (DD <= c^.Window) and
        (DD <= cabs + A) then D := DD;
    end;
    cand[I - 1] := D;
    if W < 0 then W := 3;
    while W > 0 do
    begin
      B[W] := B[W - 1];
      Dec(W);
    end;
    B[0] := (QWord(atag[J]) shl 32) or LongWord(Cur32 + 1);
  end;
end;

procedure orep_verify(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand: PLongWord; n, cap: LongWord; fl, bl: PLongWord);
var
  J, A, D, MF, MB: LongWord;
  Dp, S: QWord;
begin
  for J := 1 to n do
  begin
    D := cand[J - 1];
    if D <> 0 then
    begin
      A := apos[J - 1];
      MF := clen - A;
      MB := A;
      Dp := cphys + A;
      S := SrcPos(c, Dp, D);
      if MF > cap then MF := cap;
      if QWord(MB) > cabs + A - D then MB := LongWord(cabs + A - D);
      fl[J - 1] := Fwd(c^, S, Dp, MF);
      if MB > cap - fl[J - 1] then MB := cap - fl[J - 1];
      if fl[J - 1] >= c^.Gram then bl[J - 1] := Bwd(c^, S, Dp, MB)
      else bl[J - 1] := 0;
    end;
  end;
end;

function orep_select(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand, fl, bl: PLongWord; n, cap: LongWord; var litstart, nm: LongWord;
  lit, len: PLongWord; dist: PQWord; mcap: LongWord): LongInt;
var
  J, A, D, F, B, Lim, Tot, Ls, K: LongWord;
  Dp, S: QWord;
  BC: Boolean;
begin
  Ls := litstart;
  K := nm;
  for J := 1 to n do
  begin
    A := apos[J - 1];
    D := cand[J - 1];
    if (D = 0) or (A < Ls) then Continue;
    F := fl[J - 1];
    if F < c^.Gram then Continue;
    Lim := A - Ls;
    if QWord(Lim) > cabs + A - D then Lim := LongWord(cabs + A - D);
    B := bl[J - 1];
    BC := B >= cap - F;
    if B > Lim then B := Lim;
    if (F < cap) and ((not BC) or (Lim <= bl[J - 1])) then
    begin
      Tot := B + F;
      Tot := Tot - Tot mod c^.Align;
      if Tot < c^.MinLen then Continue;
    end
    else
    begin
      Dp := cphys + A;
      S := SrcPos(c, Dp, D);
      if F >= cap then F := Fwd(c^, S, Dp, clen - A);
      if BC and (Lim > bl[J - 1]) then B := Bwd(c^, S, Dp, Lim);
      Tot := B + F;
      Tot := Tot - Tot mod c^.Align;
      if Tot < c^.MinLen then Continue;
    end;
    if K >= mcap then Exit(-1);
    lit[K] := A - B - Ls;
    len[K] := Tot;
    dist[K] := D;
    Inc(K);
    Ls := A - B + Tot;
  end;
  litstart := Ls;
  nm := K;
  Result := 0;
end;

procedure orep_shard(aidx: PLongWord; n, ns, tbits: LongWord;
  list, ofs: PLongWord);
var
  J, T: LongWord;
begin
  for T := 0 to ns do ofs[T] := 0;
  for J := 1 to n do
    Inc(ofs[((QWord(aidx[J - 1]) * ns) shr tbits) + 1]);
  for T := 1 to ns do Inc(ofs[T], ofs[T - 1]);
  for J := 1 to n do
  begin
    T := (QWord(aidx[J - 1]) * ns) shr tbits;
    list[ofs[T]] := J - 1;
    Inc(ofs[T]);
  end;
end;

function orep_cont(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  prev_dist: QWord): LongWord;
begin
  Result := 0;
  if (prev_dist = 0) or (prev_dist > cabs) or (prev_dist > c^.Window) or
    (clen = 0) then Exit;
  Result := Fwd(c^, SrcPos(c, cphys, prev_dist), cphys, clen);
  Result := Result - Result mod c^.Align;
  if Result < c^.MinKeep then Result := 0;
end;
{$ENDIF}

{ ---- varints and little-endian ------------------------------------------ }

function PutVar(P: PByte; V: QWord): LongWord;
begin
  Result := 0;
  while V >= $80 do
  begin
    P[Result] := Byte(V) or $80;
    V := V shr 7;
    Inc(Result);
  end;
  P[Result] := Byte(V);
  Inc(Result);
end;

procedure Put32(P: PByte; V: LongWord);
begin
  P[0] := Byte(V); P[1] := Byte(V shr 8); P[2] := Byte(V shr 16);
  P[3] := Byte(V shr 24);
end;

procedure Put64(P: PByte; V: QWord);
begin
  Put32(P, LongWord(V));
  Put32(P + 4, LongWord(V shr 32));
end;

function Get32(P: PByte): LongWord;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or
    (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function Get64(P: PByte): QWord;
begin
  Result := QWord(Get32(P)) or (QWord(Get32(P + 4)) shl 32);
end;

{ ---- worker pool ----------------------------------------------------------

  The caller's thread plus up to Threads - 1 workers run the items of one
  job (0 .. Items - 1) and the call returns when all are done.  Items are
  taken from a shared counter, so the split varies from run to run; the
  jobs write disjoint data and give the same result in any order. }

type
  TOrepJob = procedure(E: Pointer; Item: LongInt);
  POrepPool = ^TOrepPool;
  TOrepWorker = record
    Pool: POrepPool;
    Go: PRTLEvent;
    Id: TThreadID;
  end;
  TOrepPool = record
    N: LongInt;                 { workers started }
    W: array of TOrepWorker;
    Done: PRTLEvent;
    Gen: LongInt;               { bumped for every job }
    Active, NextItem, Items: LongInt;
    Job: TOrepJob;
    Ctx: Pointer;
    Quit: Boolean;
  end;

procedure PoolItems(P: POrepPool);
var
  K: LongInt;
begin
  repeat
    K := InterLockedIncrement(P^.NextItem) - 1;
    if K >= P^.Items then Break;
    P^.Job(P^.Ctx, K);
  until False;
end;

const
  { a waking thread takes ~0.5 ms here: between the jobs of one block the
    workers spin for a while before they sleep }
  OREP_SPIN = 20000;
  OREP_YIELD = 3000;

function PoolWorker(Arg: Pointer): PtrInt;
var
  Wk: ^TOrepWorker;
  P: POrepPool;
  MyGen, I: LongInt;
begin
  Wk := Arg;
  P := Wk^.Pool;
  MyGen := 0;
  repeat
    I := 0;
    while (P^.Gen = MyGen) and (I < OREP_SPIN) do
    begin
      ReadBarrier;
      Inc(I);
    end;
    { then yield for a while (~ms) before sleeping }
    I := 0;
    while (P^.Gen = MyGen) and (I < OREP_YIELD) do
    begin
      ThreadSwitch;
      ReadBarrier;
      Inc(I);
    end;
    while P^.Gen = MyGen do
      RTLEventWaitFor(Wk^.Go, 100);
    ReadBarrier;
    MyGen := P^.Gen;
    if P^.Quit then Break;
    PoolItems(P);
    if InterLockedDecrement(P^.Active) = 0 then RTLEventSetEvent(P^.Done);
  until False;
  Result := 0;
end;

{ start up to Want - 1 workers; nil when none could be started }
function PoolCreate(Want: LongWord): POrepPool;
var
  I: LongInt;
begin
  Result := nil;
  if Want <= 1 then Exit;
  New(Result);
  FillChar(Result^, SizeOf(TOrepPool), 0);
  SetLength(Result^.W, Want - 1);
  try
    Result^.Done := RTLEventCreate;
    for I := 0 to LongInt(Want) - 2 do
    begin
      Result^.W[I].Pool := Result;
      Result^.W[I].Go := RTLEventCreate;
      Result^.W[I].Id := BeginThread(@PoolWorker, @Result^.W[I]);
      if Result^.W[I].Id = TThreadID(0) then
      begin
        RTLEventDestroy(Result^.W[I].Go);
        Break;
      end;
      Inc(Result^.N);
    end;
  except
    { no thread support (a program without cthreads on Unix): go on with
      the ones that started }
  end;
  if Result^.N = 0 then
  begin
    if Result^.Done <> nil then RTLEventDestroy(Result^.Done);
    Result^.W := nil;
    Dispose(Result);
    Result := nil;
  end;
end;

procedure PoolFree(P: POrepPool);
var
  I: LongInt;
begin
  if P = nil then Exit;
  P^.Quit := True;
  WriteBarrier;
  InterLockedIncrement(P^.Gen);
  for I := 0 to P^.N - 1 do RTLEventSetEvent(P^.W[I].Go);
  for I := 0 to P^.N - 1 do
  begin
    WaitForThreadTerminate(P^.W[I].Id, 0);
    CloseThread(P^.W[I].Id);
    RTLEventDestroy(P^.W[I].Go);
  end;
  RTLEventDestroy(P^.Done);
  P^.W := nil;
  Dispose(P);
end;

procedure PoolRun(P: POrepPool; Job: TOrepJob; Ctx: Pointer; Items: LongInt);
var
  I, K: LongInt;
begin
  if Items <= 0 then Exit;
  if (P = nil) or (Items = 1) then
  begin
    for K := 0 to Items - 1 do Job(Ctx, K);
    Exit;
  end;
  P^.Job := Job;
  P^.Ctx := Ctx;
  P^.Items := Items;
  P^.NextItem := 0;
  P^.Active := P^.N;
  WriteBarrier;
  InterLockedIncrement(P^.Gen);
  for I := 0 to P^.N - 1 do RTLEventSetEvent(P^.W[I].Go);
  PoolItems(P);
  { the workers are about to finish: spin, then yield, then sleep }
  I := 0;
  while P^.Active > 0 do
  begin
    Inc(I);
    if I > OREP_SPIN + 10 * OREP_YIELD then RTLEventWaitFor(P^.Done, 1)
    else if I > OREP_SPIN then ThreadSwitch;
    ReadBarrier;
  end;
  ReadBarrier;
end;

{ ---- the search of one block (phases: see orep_core.c) ---------------------- }

type
  POrepEnc = ^TOrepEnc;

procedure SegRange(E: POrepEnc; K: LongInt; out S0, S1: LongWord);
begin
  S0 := (E^.BSeg0 + LongWord(K)) * OREP_SUB;
  S1 := S0 + OREP_SUB;
  if S1 > E^.BNPos then S1 := E^.BNPos;
end;

procedure JobAnchors(Ctx: Pointer; Item: LongInt);
var
  E: POrepEnc;
  S0, S1, O: LongWord;
begin
  E := Ctx;
  SegRange(E, Item, S0, S1);
  O := LongWord(Item) * OREP_SUB;
  E^.SegCnt[Item] := orep_anchors(@E^.Cfg, E^.Cfg.Ring + E^.BPhysQ, S0, S1,
    E^.APos + O, E^.AIdx + O, E^.ATag + O);
  if E^.NShard > 1 then
    orep_shard(E^.AIdx + O, E^.SegCnt[Item], E^.NShard, E^.Cfg.TBits,
      E^.SList + O, E^.SOfs + LongWord(Item) * (E^.NShard + 1));
end;

procedure JobProbe(Ctx: Pointer; Item: LongInt);
var
  E: POrepEnc;
  K, O, S, NS: LongWord;
  Ofs: PLongWord;
begin
  E := Ctx;
  NS := E^.NShard;
  for K := 0 to OREP_BATCH - 1 do
    if E^.SegCnt[K] > 0 then
    begin
      O := K * OREP_SUB;
      if NS = 1 then
        orep_probe(@E^.Cfg, E^.BCAbs, E^.APos + O, E^.AIdx + O, E^.ATag + O,
          nil, E^.SegCnt[K], E^.Cand + O)
      else
      begin
        Ofs := E^.SOfs + K * (NS + 1);
        if Item = 0 then S := 0 else S := Ofs[Item - 1];
        orep_probe(@E^.Cfg, E^.BCAbs, E^.APos + O, E^.AIdx + O, E^.ATag + O,
          E^.SList + O + S, Ofs[Item] - S, E^.CandL + O + S);
      end;
    end;
end;

procedure JobVerify(Ctx: Pointer; Item: LongInt);
var
  E: POrepEnc;
  O, I: LongWord;
begin
  E := Ctx;
  O := LongWord(Item) * OREP_SUB;
  { the candidates back in anchor order }
  if (E^.NShard > 1) and (E^.SegCnt[Item] > 0) then
    for I := O to O + E^.SegCnt[Item] - 1 do
      E^.Cand[O + E^.SList[I]] := E^.CandL[I];
  orep_verify(@E^.Cfg, E^.BCAbs, E^.BPhysQ, E^.BLen, E^.APos + O,
    E^.Cand + O, E^.SegCnt[Item], E^.VCap, E^.FL + O, E^.BL + O);
end;

{ the matches of [BlkPhys, BlkPhys + BlkLen) into Lit/Len/Dist; -1 when
  they do not fit }
{ search the block [BPhysQ, BPhysQ + BLen) (absolute BCAbs) into
  SLit/SLen/SDist; the count, or -1 when it does not fit }
function SearchBlock(var E: TOrepEnc): LongInt;
var
  NSeg, B, NB, K, LitStart, NM, L: LongWord;
  CAbs: QWord;
begin
  CAbs := E.BCAbs;
  E.VCap := E.Cfg.MinLen + E.Cfg.Align;
  NM := 0;
  LitStart := 0;
  L := orep_cont(@E.Cfg, CAbs, E.BPhysQ, E.BLen, E.PrevDist);
  if L > 0 then
  begin
    E.SLit[0] := 0; E.SLen[0] := L; E.SDist[0] := E.PrevDist;
    NM := 1;
    LitStart := L;
  end;
  if E.BLen >= E.Cfg.Gram then E.BNPos := E.BLen - E.Cfg.Gram + 1
  else E.BNPos := 0;
  NSeg := (E.BNPos + OREP_SUB - 1) div OREP_SUB;
  B := 0;
  while B < NSeg do
  begin
    NB := NSeg - B;
    if NB > OREP_BATCH then NB := OREP_BATCH;
    E.BSeg0 := B;
    FillChar(E.SegCnt, SizeOf(E.SegCnt), 0);
    PoolRun(E.Pool, @JobAnchors, @E, NB);
    PoolRun(E.Pool, @JobProbe, @E, E.NShard);
    PoolRun(E.Pool, @JobVerify, @E, NB);
    for K := 0 to NB - 1 do
      if orep_select(@E.Cfg, CAbs, E.BPhysQ, E.BLen, E.APos + K * OREP_SUB,
        E.Cand + K * OREP_SUB, E.FL + K * OREP_SUB, E.BL + K * OREP_SUB,
        E.SegCnt[K], E.VCap, LitStart, NM, E.SLit, E.SLen, E.SDist,
        E.Cap) < 0 then Exit(-1);
    Inc(B, NB);
  end;
  Result := NM;
end;

{ the coordinator: runs SearchBlock while the caller's thread copies input
  and writes output }
type
  POrepCoord = ^TOrepCoord;
  TOrepCoord = record
    E: POrepEnc;
    Go, Done: PRTLEvent;
    Id: TThreadID;
    Quit: Boolean;
  end;

function CoordMain(Arg: Pointer): PtrInt;
var
  C: POrepCoord;
begin
  C := Arg;
  repeat
    RTLEventWaitFor(C^.Go);
    if C^.Quit then Break;
    C^.E^.SNM := SearchBlock(C^.E^);
    RTLEventSetEvent(C^.Done);
  until False;
  Result := 0;
end;

function CoordCreate(E: POrepEnc): POrepCoord;
begin
  New(Result);
  FillChar(Result^, SizeOf(TOrepCoord), 0);
  Result^.E := E;
  try
    Result^.Go := RTLEventCreate;
    Result^.Done := RTLEventCreate;
    Result^.Id := BeginThread(@CoordMain, Result);
  except
    Result^.Id := TThreadID(0);
  end;
  if Result^.Id = TThreadID(0) then
  begin
    if Result^.Go <> nil then RTLEventDestroy(Result^.Go);
    if Result^.Done <> nil then RTLEventDestroy(Result^.Done);
    Dispose(Result);
    Result := nil;
  end;
end;

procedure CoordFree(C: POrepCoord);
begin
  if C = nil then Exit;
  C^.Quit := True;
  RTLEventSetEvent(C^.Go);
  WaitForThreadTerminate(C^.Id, 0);
  CloseThread(C^.Id);
  RTLEventDestroy(C^.Go);
  RTLEventDestroy(C^.Done);
  Dispose(C);
end;

{ ---- encoder ------------------------------------------------------------- }

procedure EncFree(var E: TOrepEnc);
begin
  if E.Cfg.Ring <> nil then FreeMem(E.Cfg.Ring);
  if E.TableRaw <> nil then FreeMem(E.TableRaw);
  E.TableRaw := nil;
  if E.InFlight and (E.Coord <> nil) then
    RTLEventWaitFor(POrepCoord(E.Coord)^.Done);
  E.InFlight := False;
  CoordFree(POrepCoord(E.Coord));
  E.Coord := nil;
  PoolFree(POrepPool(E.Pool));
  E.Pool := nil;
  if E.SList <> nil then FreeMem(E.SList);
  if E.SOfs <> nil then FreeMem(E.SOfs);
  if E.CandL <> nil then FreeMem(E.CandL);
  E.SList := nil; E.SOfs := nil; E.CandL := nil;
  if E.APos <> nil then FreeMem(E.APos);
  if E.AIdx <> nil then FreeMem(E.AIdx);
  if E.ATag <> nil then FreeMem(E.ATag);
  if E.Cand <> nil then FreeMem(E.Cand);
  if E.FL <> nil then FreeMem(E.FL);
  if E.BL <> nil then FreeMem(E.BL);
  E.APos := nil; E.AIdx := nil; E.ATag := nil; E.Cand := nil;
  E.FL := nil; E.BL := nil;
  if E.Lit <> nil then FreeMem(E.Lit);
  if E.Len <> nil then FreeMem(E.Len);
  if E.Dist <> nil then FreeMem(E.Dist);
  if E.SLit <> nil then FreeMem(E.SLit);
  if E.SLen <> nil then FreeMem(E.SLen);
  if E.SDist <> nil then FreeMem(E.SDist);
  E.SLit := nil; E.SLen := nil; E.SDist := nil;
  if E.Stage <> nil then FreeMem(E.Stage);
  E.Cfg.Ring := nil; E.Cfg.Table := nil;
  E.Lit := nil; E.Len := nil; E.Dist := nil; E.Stage := nil;
end;

procedure StageHeader(var E: TOrepEnc);
begin
  Move(Magic, E.Stage[0], 4);
  E.Stage[4] := OREP_FORMAT;
  E.Stage[5] := 0;
  E.Stage[6] := Byte(E.Cfg.Align); E.Stage[7] := Byte(E.Cfg.Align shr 8);
  Put64(E.Stage + 8, E.Cfg.Window);
  Put32(E.Stage + 16, E.Chunk);
  Put32(E.Stage + 20, E.Cfg.MinLen);
  Put32(E.Stage + 24, OrepCrc32c(0, E.Stage, 24));
  E.StageLen := HDR_SIZE;
  E.StreamPos := HDR_SIZE;
  E.StagePos := 0;
  E.Phase := 2;   { drain the header, then fill }
end;

function OrepEncInit(out E: TOrepEnc; const P: TOrepParams): Integer;
var
  W: QWord;
begin
  FillChar(E, SizeOf(E), 0);
  if not CheckParams(P) then Exit(OREP_E_PARAM);
  W := EffWindow(P);
  E.Cfg.Window := W;
  E.Cfg.MinLen := P.MinLen;
  E.Cfg.MinDist := P.MinDist;
  E.Cfg.Align := P.Align;
  Derive(P, W, E.Cfg.Gram, E.Cfg.SMask, E.Cfg.MaxGap, E.Cfg.TBits,
    E.Cfg.MinKeep, E.Cfg.SShift);
  InitTables(E.Cfg);
  E.Chunk := P.Chunk;
  { one slot more than a decoder needs: the caller's thread fills the next
    slot while the search of this one may still read the oldest }
  E.Cfg.RingSize := RingFor(W, P.Chunk) + P.Chunk;
  E.Cap := P.Chunk div E.Cfg.MinKeep + 2;
  E.StageCap := E.Cap * 15 + 64 + 4096;
  try
    E.TableRaw := AllocMem((SizeUInt(32) shl E.Cfg.TBits) + 64);
    E.Cfg.Table := PQWord((PtrUInt(E.TableRaw) + 63) and not PtrUInt(63));
    E.APos := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.AIdx := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.ATag := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.Cand := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.FL := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.BL := GetMem(OREP_BATCH * OREP_SUB * 4);
    E.Lit := GetMem(E.Cap * 4);
    E.Len := GetMem(E.Cap * 4);
    E.Dist := GetMem(E.Cap * 8);
    E.SLit := GetMem(E.Cap * 4);
    E.SLen := GetMem(E.Cap * 4);
    E.SDist := GetMem(E.Cap * 8);
    E.Stage := GetMem(E.StageCap);
    E.RingAlloc := P.Chunk;
    E.Cfg.Ring := GetMem(E.RingAlloc);
  except
    EncFree(E);
    Exit(OREP_E_MEM);
  end;
  { Threads >= 2: a coordinator runs the search, helped by Threads - 1
    workers, while the caller's thread copies input and writes output }
  if P.Threads >= 2 then E.Coord := CoordCreate(@E);
  if E.Coord <> nil then E.Pool := PoolCreate(P.Threads);
  if E.Pool <> nil then E.NShard := POrepPool(E.Pool)^.N + 1
  else E.NShard := 1;
  if E.NShard > 1 then
    try
      E.SList := GetMem(OREP_BATCH * OREP_SUB * 4);
      E.CandL := GetMem(OREP_BATCH * OREP_SUB * 4);
      E.SOfs := GetMem(OREP_BATCH * (E.NShard + 1) * 4);
    except
      EncFree(E);
      Exit(OREP_E_MEM);
    end;
  StageHeader(E);
  E.Inited := True;
  Result := OREP_OK;
end;

function OrepEncReset(var E: TOrepEnc): Integer;
begin
  if not E.Inited then Exit(OREP_E_PARAM);
  if E.InFlight and (E.Coord <> nil) then
    RTLEventWaitFor(POrepCoord(E.Coord)^.Done);
  E.InFlight := False;
  { a fresh stream: the same bytes as a new state would write }
  FillChar(E.Cfg.Table^, SizeUInt(32) shl E.Cfg.TBits, 0);
  E.SlotAbs := 0; E.SlotPhys := 0; E.Fill := 0; E.BlockStart := 0;
  E.PrevDist := 0; E.NMatch := 0; E.BlkLen := 0; E.Total := 0;
  E.LitRun := 0; E.LitOff := 0; E.LitBase := 0;
  E.Ended := False;
  StageHeader(E);
  Result := OREP_OK;
end;

procedure OrepEncEnd(var E: TOrepEnc);
begin
  EncFree(E);
  E.Inited := False;
end;

function GrowRing(var E: TOrepEnc; Need: QWord): Boolean;
var
  NewSize: QWord;
begin
  Result := True;
  if Need <= E.RingAlloc then Exit;
  NewSize := E.RingAlloc * 2;
  if NewSize < Need then NewSize := Need;
  if NewSize > E.Cfg.RingSize then NewSize := E.Cfg.RingSize;
  try
    ReAllocMem(E.Cfg.Ring, NewSize);
  except
    Exit(False);
  end;
  E.RingAlloc := NewSize;
end;

{ hand the block [BlockStart, Fill) of the slot to the search (the
  coordinator, or inline), move on, and make room in the ring for the next
  bytes while no search runs }
function Launch(var E: TOrepEnc): Integer;
begin
  E.BCAbs := E.SlotAbs + E.BlockStart;
  E.BPhysQ := E.SlotPhys + E.BlockStart;
  E.BLen := E.Fill - E.BlockStart;
  if E.Fill = E.Chunk then
  begin
    Inc(E.SlotAbs, E.Chunk);
    Inc(E.SlotPhys, E.Chunk);
    if E.SlotPhys >= E.Cfg.RingSize then E.SlotPhys := 0;
    E.Fill := 0;
    E.BlockStart := 0;
  end
  else
    E.BlockStart := E.Fill;
  if not GrowRing(E, E.SlotPhys + E.Chunk) then Exit(OREP_E_MEM);
  { the search writes the spare match arrays (SLit...); Finalize swaps them
    with the ones being written out, which are done by then }
  E.InFlight := True;
  if E.Coord <> nil then RTLEventSetEvent(POrepCoord(E.Coord)^.Go)
  else E.SNM := SearchBlock(E);
  Result := OREP_OK;
end;

{ wait for the search and stage its block: header, columns, padding; the
  literals are then written straight from the ring }
function Finalize(var E: TOrepEnc): Integer;
var
  T: Pointer;
  TQ: PQWord;
  I, Q, Sum, SumLen, Pad, A: LongWord;
  Tmp: array[0..15] of Byte;
begin
  if E.Coord <> nil then RTLEventWaitFor(POrepCoord(E.Coord)^.Done);
  E.InFlight := False;
  if E.SNM < 0 then Exit(OREP_E_PARAM);
  T := E.SLit; E.SLit := E.Lit; E.Lit := T;
  T := E.SLen; E.SLen := E.Len; E.Len := T;
  TQ := E.SDist; E.SDist := E.Dist; E.Dist := TQ;
  E.NMatch := E.SNM;
  E.BlkPhys := E.BPhysQ;
  E.BlkLen := E.BLen;
  { column bytes, and the distance to continue with in the next block }
  Q := 0;
  Sum := 0;
  SumLen := 0;
  I := 0;
  while I < E.NMatch do
  begin
    Inc(Q, PutVar(@Tmp[0], E.Lit[I]) +
      PutVar(@Tmp[0], E.Len[I] - OREP_MIN_MATCH) +
      PutVar(@Tmp[0], E.Dist[I] - 1));
    Inc(Sum, E.Lit[I] + E.Len[I]);
    Inc(SumLen, E.Len[I]);
    Inc(I);
  end;
  E.PrevDist := 0;
  if (E.NMatch > 0) and (Sum = E.BlkLen) then
    E.PrevDist := E.Dist[E.NMatch - 1];
  { header: out size, matches, column bytes; then the three columns }
  E.StageLen := PutVar(E.Stage, E.BlkLen);
  Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.NMatch));
  Inc(E.StageLen, PutVar(E.Stage + E.StageLen, Q));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Lit[I - 1]));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen,
      E.Len[I - 1] - OREP_MIN_MATCH));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Dist[I - 1] - 1));
  { zeros so that every literal sits at its input position modulo Align }
  A := E.Cfg.Align;
  Pad := ((E.BCAbs mod A) + A - ((E.StreamPos + E.StageLen) mod A)) mod A;
  FillChar(E.Stage[E.StageLen], Pad, 0);
  Inc(E.StageLen, Pad);
  Inc(E.StreamPos, QWord(E.StageLen) + (E.BlkLen - SumLen) + 4);
  E.StagePos := 0;
  E.BlockCrc := OrepCrc32c(0, E.Cfg.Ring + E.BlkPhys, E.BlkLen);
  E.LitRun := 0;
  E.LitOff := 0;
  E.LitBase := 0;
  Inc(E.Total, E.BlkLen);
  E.Phase := 2;
  Result := OREP_OK;
end;

function OrepEncRun(var E: TOrepEnc; var NextIn: PByte; var AvailIn: SizeUInt;
  var NextOut: PByte; var AvailOut: SizeUInt; Mode: Integer): Integer;
var
  K, Cnt: LongWord;
  Room: SizeUInt;
  Want: SizeUInt;
begin
  if not E.Inited then Exit(OREP_E_PARAM);
  while True do
    case E.Phase of
      1: begin { filling the slot }
           if (E.Fill = E.Chunk) or ((Mode <> OREP_RUN) and (AvailIn = 0) and
             (E.Fill > E.BlockStart)) then
           begin
             { a block is ready: finish the one in flight, start this one,
               then write the finished one out }
             if E.InFlight then
             begin
               Result := Finalize(E);
               if Result <> OREP_OK then Exit;
               Result := Launch(E);
               if Result <> OREP_OK then Exit;
               Continue;           { phase 2 }
             end;
             Result := Launch(E);
             if Result <> OREP_OK then Exit;
             Continue;
           end;
           if AvailIn > 0 then
           begin
             Want := E.Chunk - E.Fill;
             if Want > AvailIn then Want := AvailIn;
             Move(NextIn^, E.Cfg.Ring[E.SlotPhys + E.Fill], Want);
             Inc(NextIn, Want);
             Dec(AvailIn, Want);
             Inc(E.Fill, Want);
             Continue;
           end;
           if (Mode <> OREP_RUN) and E.InFlight then
           begin
             Result := Finalize(E);
             if Result <> OREP_OK then Exit;
             Continue;             { phase 2 }
           end;
           if (Mode = OREP_FINISH) and not E.Ended then
           begin
             E.StageLen := PutVar(E.Stage, 0);
             Put64(E.Stage + E.StageLen, E.Total);
             Inc(E.StageLen, 8);
             E.StagePos := 0;
             E.Ended := True;
             E.NMatch := 0;
             E.BlkLen := 0;
             E.Phase := 5;
             Continue;
           end;
           Exit(OREP_OK);
         end;
      2, 5: begin { stage bytes }
           if E.StagePos < E.StageLen then
           begin
             if AvailOut = 0 then Exit(OREP_OK);
             Room := E.StageLen - E.StagePos;
             if Room > AvailOut then Room := AvailOut;
             Move(E.Stage[E.StagePos], NextOut^, Room);
             Inc(NextOut, Room);
             Dec(AvailOut, Room);
             Inc(E.StagePos, Room);
             Continue;
           end;
           if E.Phase = 5 then Exit(OREP_END);
           if E.BlkLen = 0 then
           begin
             E.Phase := 1;  { header written }
             Continue;
           end;
           E.Phase := 3;
           Continue;
         end;
      3: begin { literal runs from the ring }
           if E.LitRun > E.NMatch then
           begin
             Put32(E.Stage, E.BlockCrc);
             E.StageLen := 4;
             E.StagePos := 0;
             E.Phase := 4;
             Continue;
           end;
           if E.LitRun < E.NMatch then Cnt := E.Lit[E.LitRun]
           else Cnt := E.BlkLen - E.LitBase;
           if E.LitOff >= Cnt then
           begin
             if E.LitRun < E.NMatch then
               Inc(E.LitBase, Cnt + E.Len[E.LitRun]);
             Inc(E.LitRun);
             E.LitOff := 0;
             Continue;
           end;
           if AvailOut = 0 then Exit(OREP_OK);
           K := Cnt - E.LitOff;
           if K > AvailOut then K := AvailOut;
           Move(E.Cfg.Ring[E.BlkPhys + E.LitBase + E.LitOff], NextOut^, K);
           Inc(NextOut, K);
           Dec(AvailOut, K);
           Inc(E.LitOff, K);
         end;
      4: begin { block crc }
           if E.StagePos < E.StageLen then
           begin
             if AvailOut = 0 then Exit(OREP_OK);
             Room := E.StageLen - E.StagePos;
             if Room > AvailOut then Room := AvailOut;
             Move(E.Stage[E.StagePos], NextOut^, Room);
             Inc(NextOut, Room);
             Dec(AvailOut, Room);
             Inc(E.StagePos, Room);
             Continue;
           end;
           E.BlkLen := 0;
           E.Phase := 1;
         end;
    else
      Exit(OREP_E_PARAM);
    end;
end;

{ ---- decoder ------------------------------------------------------------- }

procedure DecFree(var D: TOrepDec);
begin
  if D.Ring <> nil then FreeMem(D.Ring);
  if D.Cols <> nil then FreeMem(D.Cols);
  if D.Lit <> nil then FreeMem(D.Lit);
  if D.Len <> nil then FreeMem(D.Len);
  if D.Dist <> nil then FreeMem(D.Dist);
  D.Ring := nil; D.Cols := nil; D.Lit := nil; D.Len := nil; D.Dist := nil;
end;

function OrepDecInit(out D: TOrepDec; MemLimit: QWord): Integer;
begin
  FillChar(D, SizeOf(D), 0);
  D.MemLimit := MemLimit;
  D.Phase := 0;
  D.Inited := True;
  Result := OREP_OK;
end;

procedure OrepDecEnd(var D: TOrepDec);
begin
  DecFree(D);
  D.Inited := False;
end;

function DecHeader(var D: TOrepDec): Integer;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if Char(D.Hdr[I]) <> Magic[I] then Exit(OREP_E_VERSION);
  if Get32(@D.Hdr[24]) <> OrepCrc32c(0, @D.Hdr[0], 24) then Exit(OREP_E_DATA);
  if D.Hdr[4] <> OREP_FORMAT then Exit(OREP_E_VERSION);
  if D.Hdr[5] <> 0 then Exit(OREP_E_VERSION);
  D.Align := D.Hdr[6] or (LongWord(D.Hdr[7]) shl 8);
  if (D.Align < 1) or (D.Align > 4096) then Exit(OREP_E_DATA);
  D.Window := Get64(@D.Hdr[8]);
  D.Chunk := Get32(@D.Hdr[16]);
  if (D.Window < 1) or (D.Window > OREP_MAX_WINDOW) or
    (D.Chunk < OREP_MIN_CHUNK) or (D.Chunk > OREP_MAX_CHUNK) then
    Exit(OREP_E_DATA);
  if (D.MemLimit <> 0) and (OrepDecMemory(D.Window, D.Chunk) > D.MemLimit) then
    Exit(OREP_E_MEM);
  D.RingSize := RingFor(D.Window, D.Chunk);
  D.MCap := D.Chunk div OREP_MIN_MATCH + 2;
  try
    D.Lit := GetMem(D.MCap * 4);
    D.Len := GetMem(D.MCap * 4);
    D.Dist := GetMem(D.MCap * 4);
    D.RingAlloc := 0;
  except
    Exit(OREP_E_MEM);
  end;
  Result := OREP_OK;
end;

function DecGrow(var D: TOrepDec; Need: QWord): Boolean;
var
  NewSize: QWord;
begin
  Result := True;
  if Need <= D.RingAlloc then Exit;
  NewSize := D.RingAlloc * 2;
  if NewSize < D.Chunk then NewSize := D.Chunk;
  if NewSize < Need then NewSize := Need;
  if NewSize > D.RingSize then NewSize := D.RingSize;
  try
    ReAllocMem(D.Ring, NewSize);
  except
    Exit(False);
  end;
  D.RingAlloc := NewSize;
end;

{ parse and check the columns of the current block }
function DecCols(var D: TOrepDec): Integer;
var
  P, I, C: LongWord;
  Col: Integer;
  V: QWord;
  Sh: LongWord;
  B: Byte;
  Pos, Dst: QWord;
begin
  P := 0;
  for Col := 0 to 2 do
    for I := 1 to D.NMatch do
    begin
      V := 0; Sh := 0;
      repeat
        if (P >= D.ColLen) or (Sh > 28) then Exit(OREP_E_DATA);
        B := D.Cols[P];
        Inc(P);
        V := V or (QWord(B and $7F) shl Sh);
        Inc(Sh, 7);
      until B < $80;
      if V > $FFFFFFFF then Exit(OREP_E_DATA);
      case Col of
        0: D.Lit[I - 1] := V;
        1: begin
             if V > $FFFFFFFF - OREP_MIN_MATCH then Exit(OREP_E_DATA);
             D.Len[I - 1] := V + OREP_MIN_MATCH;
           end;
        2: begin
             if V >= $FFFFFFFF then Exit(OREP_E_DATA);
             D.Dist[I - 1] := V + 1;
           end;
      end;
    end;
  if P <> D.ColLen then Exit(OREP_E_DATA);
  { the matches fit in the block and point inside the window and the data }
  Pos := 0;
  I := 0;
  while I < D.NMatch do
  begin
    Pos := Pos + D.Lit[I];
    if Pos > D.OutSize then Exit(OREP_E_DATA);
    Dst := D.Total + Pos;
    C := D.Len[I];
    if QWord(C) > D.OutSize - Pos then Exit(OREP_E_DATA);
    if (D.Dist[I] > D.Window) or (D.Dist[I] > Dst) then Exit(OREP_E_DATA);
    Pos := Pos + C;
    Inc(I);
  end;
  Result := OREP_OK;
end;

{ copy a match inside the ring: Len bytes from Dist back to the block
  position BlkPos (forward, so an overlapping copy repeats) }
procedure DecCopy(var D: TOrepDec; Len, Dist: LongWord);
var
  Dp, Sp: QWord;
  Run, K: LongWord;
begin
  Dp := D.WPhys + D.BlkPos;
  if Dp >= Dist then Sp := Dp - Dist else Sp := Dp + D.RingSize - Dist;
  while Len > 0 do
  begin
    Run := Len;
    if D.RingSize - Sp < Run then Run := LongWord(D.RingSize - Sp);
    if Dist >= Run then
      Move(D.Ring[Sp], D.Ring[Dp], Run)
    else
      for K := 0 to Run - 1 do D.Ring[Dp + K] := D.Ring[Sp + K];
    Inc(Dp, Run);
    Inc(Sp, Run);
    if Sp = D.RingSize then Sp := 0;
    Dec(Len, Run);
    Inc(D.BlkPos, Run);
  end;
end;

function OrepDecRun(var D: TOrepDec; var NextIn: PByte; var AvailIn: SizeUInt;
  var NextOut: PByte; var AvailOut: SizeUInt): Integer;
var
  K: SizeUInt;
  B: Byte;
  R: Integer;
begin
  if not D.Inited then Exit(OREP_E_PARAM);
  while True do
    case D.Phase of
      0: begin { stream header }
           if D.HdrLen < HDR_SIZE then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             K := HDR_SIZE - D.HdrLen;
             if K > AvailIn then K := AvailIn;
             Move(NextIn^, D.Hdr[D.HdrLen], K);
             Inc(NextIn, K); Dec(AvailIn, K); Inc(D.InPos, K); Inc(D.HdrLen, K);
             Continue;
           end;
           R := DecHeader(D);
           if R <> OREP_OK then begin D.Phase := 99; Exit(R); end;
           D.Phase := 1;
           D.VarIdx := 0; D.VarVal := 0; D.VarShift := 0;
         end;
      1: begin { block header: out size, matches, column bytes }
           if AvailIn = 0 then Exit(OREP_OK);
           B := NextIn^;
           Inc(NextIn); Dec(AvailIn); Inc(D.InPos);
           if D.VarShift > 63 then begin D.Phase := 99; Exit(OREP_E_DATA); end;
           D.VarVal := D.VarVal or (QWord(B and $7F) shl D.VarShift);
           Inc(D.VarShift, 7);
           if B >= $80 then Continue;
           case D.VarIdx of
             0: D.OutSize := D.VarVal;
             1: D.NMatch := D.VarVal;
             2: D.ColSize := D.VarVal;
           end;
           D.VarVal := 0; D.VarShift := 0;
           if (D.VarIdx = 0) and (D.OutSize = 0) then
           begin
             D.Phase := 6; D.CrcLen := 0;
             Continue;
           end;
           Inc(D.VarIdx);
           if D.VarIdx < 3 then Continue;
           D.VarIdx := 0;
           { a block stays inside its chunk-aligned slot }
           if (D.OutSize > D.Chunk) or
             ((D.WPhys mod D.Chunk) + D.OutSize > D.Chunk) or
             (D.NMatch > D.OutSize div OREP_MIN_MATCH) or
             (D.ColSize < 3 * D.NMatch) or (D.ColSize > 15 * D.NMatch) then
           begin
             D.Phase := 99; Exit(OREP_E_DATA);
           end;
           if D.ColSize > D.ColCap then
           begin
             try
               ReAllocMem(D.Cols, D.ColSize);
             except
               D.Phase := 99; Exit(OREP_E_MEM);
             end;
             D.ColCap := D.ColSize;
           end;
           if not DecGrow(D, D.WPhys + D.OutSize) then
           begin
             D.Phase := 99; Exit(OREP_E_MEM);
           end;
           D.ColLen := 0;
           D.Phase := 2;
         end;
      2: begin { columns }
           if D.ColLen < D.ColSize then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             K := D.ColSize - D.ColLen;
             if K > AvailIn then K := AvailIn;
             Move(NextIn^, D.Cols[D.ColLen], K);
             Inc(NextIn, K); Dec(AvailIn, K); Inc(D.InPos, K); Inc(D.ColLen, K);
             Continue;
           end;
           R := DecCols(D);
           if R <> OREP_OK then begin D.Phase := 99; Exit(R); end;
           D.PadLeft := ((D.Total mod D.Align) + D.Align -
             (D.InPos mod D.Align)) mod D.Align;
           D.Phase := 8;
         end;
      8: begin { zero padding before the literals }
           if D.PadLeft > 0 then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             if NextIn^ <> 0 then begin D.Phase := 99; Exit(OREP_E_DATA); end;
             Inc(NextIn); Dec(AvailIn); Inc(D.InPos);
             Dec(D.PadLeft);
             Continue;
           end;
           D.Rec := 0;
           D.InRec := False;
           D.BlkPos := 0;
           if D.NMatch > 0 then D.LitLeft := D.Lit[0]
           else D.LitLeft := D.OutSize;
           D.Phase := 3;
         end;
      3: begin { literals and matches }
           if D.LitLeft > 0 then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             K := D.LitLeft;
             if K > AvailIn then K := AvailIn;
             Move(NextIn^, D.Ring[D.WPhys + D.BlkPos], K);
             Inc(NextIn, K); Dec(AvailIn, K); Inc(D.InPos, K);
             Inc(D.BlkPos, K); Dec(D.LitLeft, K);
             Continue;
           end;
           if D.Rec < D.NMatch then
           begin
             DecCopy(D, D.Len[D.Rec], D.Dist[D.Rec]);
             Inc(D.Rec);
             if D.Rec < D.NMatch then D.LitLeft := D.Lit[D.Rec]
             else D.LitLeft := D.OutSize - D.BlkPos;
             Continue;
           end;
           D.CrcLen := 0;
           D.Phase := 4;
         end;
      4: begin { block crc }
           if D.CrcLen < 4 then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             D.CrcBuf[D.CrcLen] := NextIn^;
             Inc(NextIn); Dec(AvailIn); Inc(D.InPos); Inc(D.CrcLen);
             Continue;
           end;
           if Get32(@D.CrcBuf[0]) <>
             OrepCrc32c(0, D.Ring + D.WPhys, D.OutSize) then
           begin
             D.Phase := 99; Exit(OREP_E_DATA);
           end;
           D.EmitPos := 0;
           D.Phase := 5;
         end;
      5: begin { emit the checked block }
           if D.EmitPos < D.OutSize then
           begin
             if AvailOut = 0 then Exit(OREP_OK);
             K := D.OutSize - D.EmitPos;
             if K > AvailOut then K := AvailOut;
             Move(D.Ring[D.WPhys + D.EmitPos], NextOut^, K);
             Inc(NextOut, K); Dec(AvailOut, K); Inc(D.EmitPos, K);
             Continue;
           end;
           Inc(D.Total, D.OutSize);
           Inc(D.WPhys, D.OutSize);
           if D.WPhys >= D.RingSize then D.WPhys := 0;
           D.Phase := 1;
         end;
      6: begin { end: total size }
           if D.CrcLen < 8 then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             D.CrcBuf[D.CrcLen] := NextIn^;
             Inc(NextIn); Dec(AvailIn); Inc(D.InPos); Inc(D.CrcLen);
             Continue;
           end;
           if Get64(@D.CrcBuf[0]) <> D.Total then
           begin
             D.Phase := 99; Exit(OREP_E_DATA);
           end;
           D.Phase := 7;
         end;
      7: Exit(OREP_END);
    else
      Exit(OREP_E_DATA);
    end;
end;

{ ---- whole buffers ------------------------------------------------------- }

function OrepEncodeBuf(Src: PByte; SrcLen: SizeUInt; const P: TOrepParams;
  out Dst: PByte; out DstLen: SizeUInt): Integer;
var
  E: TOrepEnc;
  PP: TOrepParams;
  Cap, Room: SizeUInt;
  NOut: PByte;
begin
  Dst := nil; DstLen := 0;
  PP := P;
  if PP.SizeHint = 0 then PP.SizeHint := SrcLen;
  if PP.SizeHint = 0 then PP.SizeHint := 1;
  Result := OrepEncInit(E, PP);
  if Result <> OREP_OK then Exit;
  Cap := SrcLen + SrcLen div 64 + 4096;
  try
    Dst := GetMem(Cap);
  except
    OrepEncEnd(E);
    Exit(OREP_E_MEM);
  end;
  repeat
    NOut := Dst + DstLen;
    Room := Cap - DstLen;
    Result := OrepEncRun(E, Src, SrcLen, NOut, Room, OREP_FINISH);
    DstLen := Cap - Room;
    if (Result = OREP_OK) and (Room = 0) then
    begin
      Cap := Cap * 2;
      try
        ReAllocMem(Dst, Cap);
      except
        Result := OREP_E_MEM;
      end;
    end;
  until Result <> OREP_OK;
  OrepEncEnd(E);
  if Result = OREP_END then Result := OREP_OK
  else
  begin
    FreeMem(Dst); Dst := nil; DstLen := 0;
  end;
end;

function OrepDecodeBuf(Src: PByte; SrcLen: SizeUInt; MemLimit: QWord;
  out Dst: PByte; out DstLen: SizeUInt): Integer;
var
  D: TOrepDec;
  Cap, Room: SizeUInt;
  NOut: PByte;
begin
  Dst := nil; DstLen := 0;
  OrepDecInit(D, MemLimit);
  Cap := SrcLen * 2 + 4096;
  try
    Dst := GetMem(Cap);
  except
    Exit(OREP_E_MEM);
  end;
  repeat
    NOut := Dst + DstLen;
    Room := Cap - DstLen;
    Result := OrepDecRun(D, Src, SrcLen, NOut, Room);
    DstLen := Cap - Room;
    if Result = OREP_OK then
    begin
      if Room = 0 then
      begin
        Cap := Cap * 2;
        try
          ReAllocMem(Dst, Cap);
        except
          Result := OREP_E_MEM;
        end;
      end
      else if SrcLen = 0 then Result := OREP_E_DATA; { truncated }
    end;
  until Result <> OREP_OK;
  OrepDecEnd(D);
  if (Result = OREP_END) and (SrcLen = 0) then Result := OREP_OK
  else
  begin
    if Result = OREP_END then Result := OREP_E_DATA; { trailing bytes }
    FreeMem(Dst); Dst := nil; DstLen := 0;
  end;
end;

initialization
  InitCrc;
end.
