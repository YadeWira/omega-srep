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

  Thread budget (all optional, with P.HookCtx):
  - P.OnWorkerBusy / P.OnWorkerIdle are called by OREP's own threads when
    they start working and before they block, so a program with a global
    thread budget can take and give back one token per thread (Busy may
    wait for a token; the search never waits for a worker that has not
    joined, but it does wait for the coordinator).
  - P.OnCallerWaitBegin / End go around the caller's waits for the search,
    so a caller that holds a token gives it back meanwhile.  If the caller
    holds a token and the budget can run out, set them (or
    OnWorkerTryBusy): otherwise the caller waits for a coordinator that
    waits for the caller's token.
  - P.OnWorkerTryBusy (non-blocking): no OREP thread ever waits for a
    token; a block with no free token is searched by the thread that has
    one, and a block's search takes as helpers only the workers that get
    one.  With a full budget this works like Threads = 1.
  - P.SpinUs: how long an idle thread spins before it sleeps (0 = at once).

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

uses {$IFDEF WINDOWS}Windows,{$ENDIF}{$IFDEF UNIX}Unix,{$ENDIF} SysUtils;

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

  OREP_VERSION_STR = '0.0.9';
  OREP_FORMAT = 3;

  OREP_MIN_MATCH = 16;               { format minimum match length }
  OREP_MAX_WINDOW = QWord($F0000000); { < 2^32 minus a chunk }
  OREP_MAX_CHUNK = 64 * 1024 * 1024;
  OREP_MIN_CHUNK = 64 * 1024;

type
  { called by OREP's own threads (workers and coordinator) when they start
    working and before they block waiting, so a caller with a global thread
    budget can take and give back a token per thread.  Busy may block until
    a token is free: the search does not wait for a thread that has not
    joined. }
  TOrepHook = procedure(Ctx: Pointer);
  { the same, without waiting: True when a token was taken }
  TOrepTryHook = function(Ctx: Pointer): Boolean;

  TOrepParams = record
    Window: QWord;      { max distance, bytes (default 512 MiB) }
    SizeHint: QWord;    { total input if known, 0 = unknown: a smaller
                          input gets a smaller window (same matches) }
    MinLen: LongWord;   { shortest match searched, >= 16 (default 64) }
    Chunk: LongWord;    { block size, a power of two, 64 KiB..64 MiB
                          (default 4 MiB) }
    Align: LongWord;    { match lengths multiple of this, and literals kept
                          at their input position modulo it; 0 (default) =
                          per block: 1 for text, 4 (lzma's pb2) otherwise }
    MinDist: QWord;     { matches nearer than this are left to the
                          backend (default 0) }
    Density: LongWord;  { anchors: about one per (MinLen - gram) / Density
                          positions; higher finds more short matches and is
                          slower and uses more table (default 4) }
    Cands: LongWord;    { candidates tried per anchor, 1..4 (default 4):
                          more finds longer matches and is slower; 1
                          keeps one table entry per gram }
    RunKeep: LongWord;  { a match that only covers a run of one byte and
                          is shorter than this is left to the backend
                          (default 0 = none).  Helps a backend that codes
                          runs almost free (tor, lz4) at MinLen 256; with
                          lzma behind it does not. }
    Threads: LongWord;  { threads for the encoder, 0 or 1 = the caller's
                          only; OREP creates the others and goes on with
                          fewer if it cannot.  The output is the same with
                          any number. }
    OnWorkerBusy, OnWorkerIdle: TOrepHook;  { optional, nil = none }
    HookCtx: Pointer;
    { called by the caller's thread around its waits for the search inside
      OrepEncRun / OrepEncReset / OrepEncEnd (only when it would block), so
      it can give its token back meanwhile; optional, nil = none }
    OnCallerWaitBegin, OnCallerWaitEnd: TOrepHook;
    { if set, OREP's threads never wait for a token: as each block starts
      the caller's thread asks one for the coordinator and searches the
      block itself if it gets none, and the thread searching asks one for
      each worker it would wake and wakes only those (it gives them back
      when the block ends; the workers then call no hook).  With a full budget the encoder then works like Threads = 1,
      and uses the other threads when tokens are free; the stream is the
      same. }
    OnWorkerTryBusy: TOrepTryHook;
    SpinUs: LongWord;   { how long a waiting OREP thread spins (then
                          yields) before it calls OnWorkerIdle and sleeps,
                          microseconds; 0 = sleep at once.  Default 2000.
                          Waking a thread costs ~0.05..0.5 ms, so with no
                          budget a short spin is faster; with a tight
                          budget 0 gives the token back at once. }
  end;

  POrepCfg = ^TOrepCfg;
  TOrepCfg = record      { shared with orep_core.c: same layout }
    T: array[0..255] of QWord;
    Window: QWord;
    RingSize: QWord;
    MinDist: QWord;
    Slots: PPByte;       { RingSize shr CShift slots, each its own GetMem }
    Table: PQWord;
    MinLen, Gram, SMask, MaxGap, PLim, Align, MinKeep, SShift: LongWord;
    Cands, Score: LongWord;
    CShift, NBuck: LongWord;  { NBuck: buckets of 4 entries; anchor bucket = (hash shr 32) * NBuck shr 32 }
    RunKeep, Pad: LongWord;   { PLim: longest period tried at a forced anchor
                                (0 = none); RunKeep: a match over a run of
                                one byte shorter than this is left to the
                                backend (0 = none) }
  end;

  TOrepEnc = record
    Cfg: TOrepCfg;
    TableRaw: Pointer;
    Chunk: LongWord;
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
    { the search of one block, segment by segment: NSlot segments in
      flight, slot k mod NSlot holds segment k }
    APos, AIdx, ATag: PLongWord;                { NSlot * OREP_SUB }
    SegCnt: PLongWord;                          { NSlot: anchors }
    SegSt: PLongWord;                           { NSlot: 1 anchored }
    NSlot: LongWord;
    SLock: TRTLCriticalSection;  { the counters below }
    SNSeg, SNextA, SPrb, SSel: LongWord;
    SProbeBusy, SSelBusy, SFail, SLockInit: Boolean;
    SGen: LongInt;               { bumped when a task ends }
    SDriver: TThreadID;          { the thread that probes }
    SDrvItem: LongInt;           { its participant index, -1 before }
    SLitStart, SNMc: LongWord;   { select's state }
    NPart: LongWord;             { participants: workers + 1 }
    PartEv: PPointer;            { NPart events, to wake a waiting one }
    PartWait: PLongWord;         { NPart: 1 while it sleeps }
    BCAbs, BPhysQ: QWord;                       { the block being searched }
    BLen, BNPos, VCap: LongWord;
    BAlign: LongWord;                           { its alignment }
    AutoAlign: Boolean;
    Pool: Pointer;                              { worker threads, or nil }
    { the block being searched (by the coordinator thread, or inline) }
    SLit, SLen: PLongWord;
    SDist: PQWord;
    SNM: LongInt;
    InFlight: Boolean;
    Coord: Pointer;                             { coordinator, or nil }
    OnBusy, OnIdle: TOrepHook;
    HookCtx: Pointer;
    OnWaitBegin, OnWaitEnd: TOrepHook;
    OnTry: TOrepTryHook;
    ViaCoord: Boolean;   { the block in flight is searched by the coordinator }
    SpinUs: LongWord;
    Cand4: PLongWord;    { 4 candidates per anchor }
  end;

  TOrepDec = record
    Window: QWord;
    Chunk: LongWord;
    RingSize: QWord;
    Slots: PPByte;
    CShift: LongWord;
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
    OldChunk: LongWord;  { after OrepDecReset: the chunk the memory is for }
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
{ without a copy: decode until checked output is ready and point Data at
  it, in the decoder's own memory (Count bytes, Count = 0 when none is
  ready yet); it stays valid until the next call on D.  OrepDecSkip(D, N)
  then marks N of them as used.  Returns as OrepDecRun. }
function OrepDecPeek(var D: TOrepDec; var NextIn: PByte; var AvailIn: SizeUInt;
  out Data: PByte; out Count: SizeUInt): Integer;
procedure OrepDecSkip(var D: TOrepDec; N: SizeUInt);
{ a new stream, keeping the memory when the next one has the same chunk
  and a window that needs the same ring (no page faults to fill it again) }
function OrepDecReset(var D: TOrepDec): Integer;
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
function orep_probe(c: POrepCfg; cabs: QWord; apos, aidx,
  atag: PLongWord; nl: LongWord; cand4: PLongWord): LongWord; cdecl;
  external name 'orep_probe';
function orep_vselect(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand4, clist: PLongWord; nc, cap: LongWord; var litstart,
  nm: LongWord; lit, len: PLongWord; dist: PQWord; mcap: LongWord): LongInt;
  cdecl; external name 'orep_vselect';
function orep_cont(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  prev_dist: QWord): LongWord; cdecl; external name 'orep_cont';
function orep_crc32c(t: PLongWord; crc: LongWord; p: PByte;
  n: SizeUInt): LongWord; cdecl; external name 'orep_crc32c';
{$ENDIF}

const
  OREP_B = QWord($9E3779B97F4A7C15);
  OREP_SUB = 65536;
  OREP_PLIM = 16;      { longest period a forced anchor tries }
  OREP_PF = 16;
  OREP_CRC_L = 2048;   { the same in orep_core.c }
  HDR_MAX = 6 + 5 + 2 + 3 + 4;   { the longest stream header }
  Magic: array[0..3] of Char = 'OREP';

var
  { read-only after unit initialization }
  { slice-by-8, then the shift of the raw state over OREP_CRC_L and
    2 * OREP_CRC_L zero bytes, 4 x 256 each (orep_core.c) }
  CrcTab: array[0..16 * 256 - 1] of LongWord;

procedure InitCrc;
var
  I, J, B, K: Integer;
  C, D: LongWord;
  Col1, Col2: array[0..31] of LongWord;
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
  { the shift tables: the image of each bit over OREP_CRC_L zero bytes,
    then over as many more }
  for B := 0 to 31 do
  begin
    C := LongWord(1) shl B;
    for K := 1 to OREP_CRC_L do C := CrcTab[C and $FF] xor (C shr 8);
    Col1[B] := C;
    for K := 1 to OREP_CRC_L do C := CrcTab[C and $FF] xor (C shr 8);
    Col2[B] := C;
  end;
  for J := 0 to 3 do
    for I := 0 to 255 do
    begin
      C := 0;
      D := 0;
      for B := 0 to 7 do
        if (I shr B) and 1 <> 0 then
        begin
          C := C xor Col1[J * 8 + B];
          D := D xor Col2[J * 8 + B];
        end;
      CrcTab[2048 + J * 256 + I] := C;
      CrcTab[3072 + J * 256 + I] := D;
    end;
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
  P.Align := 0;
  P.Density := 4;
  P.MinDist := 0;
  P.Threads := 1;
  P.Cands := 4;
  P.RunKeep := 0;
  P.OnWorkerBusy := nil;
  P.OnWorkerIdle := nil;
  P.HookCtx := nil;
  P.OnCallerWaitBegin := nil;
  P.OnCallerWaitEnd := nil;
  P.OnWorkerTryBusy := nil;
  P.SpinUs := 2000;
end;

function CheckParams(const P: TOrepParams): Boolean;
begin
  Result := (P.Window >= 1) and (P.Window <= OREP_MAX_WINDOW) and
    (P.MinLen >= OREP_MIN_MATCH) and (P.MinLen <= 65536) and
    (P.Chunk >= OREP_MIN_CHUNK) and (P.Chunk <= OREP_MAX_CHUNK) and
    (P.Chunk and (P.Chunk - 1) = 0) and
    (P.Align <= 4096) and (P.Align <= P.MinLen) and
    (P.Density >= 1) and (P.Density <= 64) and (P.Threads <= 256) and
    (P.Cands >= 1) and (P.Cands <= 4) and (P.RunKeep <= 65536);
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

function Log2Of(X: LongWord): LongWord;
begin
  Result := 0;
  while (LongWord(1) shl Result) < X do Inc(Result);
end;

{ the byte at ring offset P (slots of 1 shl Shift bytes) }
function SlotPtr(Slots: PPByte; Shift: LongWord; P: QWord): PByte; inline;
begin
  Result := Slots[P shr Shift] + (P and ((QWord(1) shl Shift) - 1));
end;

{ make sure the slot that holds ring offset P exists }
function EnsureSlot(Slots: PPByte; Shift: LongWord; P: QWord): Boolean;
var
  I: SizeUInt;
begin
  Result := True;
  I := P shr Shift;
  if Slots[I] <> nil then Exit;
  try
    Slots[I] := GetMem(SizeUInt(1) shl Shift);
  except
    Result := False;
  end;
end;

procedure FreeSlots(var Slots: PPByte; RingSize: QWord; Shift: LongWord);
var
  I: SizeUInt;
begin
  if Slots = nil then Exit;
  for I := 0 to (RingSize shr Shift) - 1 do
    if Slots[I] <> nil then FreeMem(Slots[I]);
  FreeMem(Slots);
  Slots := nil;
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

{ buckets of the anchor table: one per 4 expected anchors of the window,
  rounded up to 64 (not to a power of two: a bucket is picked by a
  multiply), from 1024 to 2^30 }
function NBuckFor(const P: TOrepParams; W: QWord): LongWord;
var
  G, SM, MG, TB, MK, SS: LongWord;
  Ent: QWord;
begin
  Derive(P, W, G, SM, MG, TB, MK, SS);
  Ent := W div (SM + 1) div 4;
  Ent := (Ent + 63) and not QWord(63);
  if Ent < 1024 then Ent := 1024;
  if Ent > (QWord(1) shl 30) then Ent := QWord(1) shl 30;
  Result := Ent;
end;

{ segments in flight for a number of threads }
function SlotsFor(Threads: LongWord): LongWord;
begin
  if Threads <= 1 then Exit(2);
  if Threads > 7 then Exit(16);
  Result := 2 * Threads + 2;
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
  Result := RingFor(W, P.Chunk) + P.Chunk + QWord(32) * NBuckFor(P, W) + 64 +
    QWord(SlotsFor(P.Threads)) * OREP_SUB * 28 +
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

function RB(const C: TOrepCfg; P: QWord): Byte; inline;
begin
  Result := SlotPtr(C.Slots, C.CShift, P)^;
end;

function Fwd(const C: TOrepCfg; S, D: QWord; Max: LongWord): LongWord;
var
  L: LongWord;
begin
  L := 0;
  while L < Max do
  begin
    if RB(C, S) <> RB(C, D + L) then Exit(L);
    Inc(L);
    Inc(S);
    if S = C.RingSize then S := 0;
  end;
  Result := L;
end;

function Bwd(const C: TOrepCfg; S, D: QWord; Max: LongWord): LongWord;
var
  L: LongWord;
begin
  L := 0;
  while L < Max do
  begin
    if S = 0 then S := C.RingSize;
    Dec(S);
    if RB(C, S) <> RB(C, D - L - 1) then Exit(L);
    Inc(L);
  end;
  Result := L;
end;

function SrcPos(C: POrepCfg; Dp, D: QWord): QWord;
begin
  if Dp >= D then Result := Dp - D else Result := Dp + C^.RingSize - D;
end;

function orep_anchors(c: POrepCfg; p: PByte; s0, s1: LongWord;
  apos, aidx, atag: PLongWord): LongWord;
var
  G, Last, Pos, I: LongWord;
  H, M: QWord;
begin
  Result := 0;
  if s1 <= s0 then Exit;
  G := c^.Gram;
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
      aidx[Result] := LongWord(((M shr 32) * QWord(c^.NBuck)) shr 32);
      atag[Result] := LongWord(M);
      Inc(Result);
      Last := Pos;
    end;
  end;
end;

{ the table step of anchors 0..nl-1: candidates into cand4, then insert }
procedure ProbeRef(c: POrepCfg; cabs: QWord; apos, aidx, atag: PLongWord;
  nl: LongWord; cand4: PLongWord);
var
  I, J, A, Cur32, K, W: LongWord;
  O: PLongWord;
  BQ: PQWord;
  DD: QWord;
begin
  for I := 1 to nl do
  begin
    J := I - 1;
    BQ := c^.Table + 4 * aidx[J];
    A := apos[J];
    Cur32 := LongWord(cabs + A);
    O := cand4 + 4 * (I - 1);
    K := 0;
    for W := 0 to 3 do
      if (LongWord(BQ[W] shr 32) = atag[J]) and (LongWord(BQ[W]) <> 0) then
      begin
        DD := LongWord(Cur32 - (LongWord(BQ[W]) - 1));
        if (DD <> 0) and (DD >= c^.MinDist) and (DD <= c^.Window) and
          (DD <= cabs + A) then
        begin
          O[K] := DD;
          Inc(K);
        end;
      end;
    while K < 4 do
    begin
      O[K] := 0;
      Inc(K);
    end;
    W := 3;
    if c^.Cands = 1 then
    begin
      W := 0;
      while (W < 3) and not ((LongWord(BQ[W] shr 32) = atag[J]) and
        (LongWord(BQ[W]) <> 0)) do Inc(W);
    end;
    while W > 0 do
    begin
      BQ[W] := BQ[W - 1];
      Dec(W);
    end;
    BQ[0] := (QWord(atag[J]) shl 32) or LongWord(Cur32 + 1);
  end;
end;

{ the table step, then the list (into aidx) of the anchors orep_vselect
  looks at: those with a candidate and, with PLim, the forced ones (MaxGap
  after the anchor before, or after the segment start), flagged
  OREP_FORCED }
function orep_probe(c: POrepCfg; cabs: QWord; apos, aidx,
  atag: PLongWord; nl: LongWord; cand4: PLongWord): LongWord;
var
  I, Prev: LongWord;
  Fo: Boolean;
begin
  ProbeRef(c, cabs, apos, aidx, atag, nl, cand4);
  Result := 0;
  Prev := 0;
  if nl > 0 then Prev := apos[0] and not LongWord(OREP_SUB - 1);
  for I := 1 to nl do
  begin
    Fo := (c^.PLim <> 0) and (apos[I - 1] - Prev = c^.MaxGap);
    Prev := apos[I - 1];
    if Fo or (cand4[4 * (I - 1)] <> 0) then
    begin
      aidx[Result] := (I - 1) or (LongWord(Ord(Fo)) shl 31);
      Inc(Result);
    end;
  end;
end;

procedure orep_verify(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand4: PLongWord; n, nc, cap: LongWord; cand, fl, bl: PLongWord);
var
  J, K, A, Best, BF, F, MF, MB, SC: LongWord;
  C4: PLongWord;
  Dp, S: QWord;
begin
  SC := cap;
  if SC < c^.Score then SC := c^.Score;
  for J := 1 to n do
  begin
    C4 := cand4 + 4 * (J - 1);
    A := apos[J - 1];
    Dp := cphys + A;
    Best := 0;
    BF := 0;
    K := 0;
    while (K < nc) and (C4[K] <> 0) do
    begin
      MF := clen - A;
      if MF > SC then MF := SC;
      F := Fwd(c^, SrcPos(c, Dp, C4[K]), Dp, MF);
      if (Best = 0) or (F > BF) then
      begin
        Best := C4[K];
        BF := F;
        if BF >= SC then Break;   { the later ones can only tie }
      end;
      Inc(K);
    end;
    cand[J - 1] := Best;
    if Best <> 0 then
    begin
      MB := A;
      S := SrcPos(c, Dp, Best);
      if QWord(MB) > cabs + A - Best then MB := LongWord(cabs + A - Best);
      if BF < cap then fl[J - 1] := BF else fl[J - 1] := cap;
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
  J, A, D, F, B, Lim, Tot, Ls, K, I: LongWord;
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
    if Tot < c^.RunKeep then
    begin
      { a short run of one byte costs the backend less than a match }
      I := 1;
      while (I < Tot) and (RB(c^, cphys + A - B + I) = RB(c^, cphys + A - B)) do
        Inc(I);
      if I = Tot then Continue;
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

{ the shortest period P (max(1, MinDist) <= P <= Lim) of the data at
  block offset A: the gram at A equals the gram P bytes before it; 0 if
  none }
function Period(c: POrepCfg; cphys: QWord; A, Lim: LongWord): LongWord;
var
  P, I: LongWord;
  Dp: QWord;
begin
  Result := 0;
  if Lim > A then Lim := A;
  if c^.MinDist > Lim then Exit;
  P := 1;
  if c^.MinDist > 1 then P := LongWord(c^.MinDist);
  Dp := cphys + A;
  while P <= Lim do
  begin
    I := 0;
    while (I < c^.Gram) and (RB(c^, Dp - P + I) = RB(c^, Dp + I)) do Inc(I);
    if I = c^.Gram then Exit(P);
    Inc(P);
  end;
end;

{ verify and select in one pass over the listed anchors: those inside a
  match already chosen are not verified (orep_select would skip them); a
  forced one tries the period of its gram first }
function orep_vselect(c: POrepCfg; cabs, cphys: QWord; clen: LongWord;
  apos, cand4, clist: PLongWord; nc, cap: LongWord; var litstart,
  nm: LongWord; lit, len: PLongWord; dist: PQWord; mcap: LongWord): LongInt;
var
  I, J, K, Cd, F, B, P, PLim: LongWord;
  C5: array[0..4] of LongWord;
begin
  PLim := c^.PLim;
  if PLim >= c^.MaxGap then PLim := c^.MaxGap - 1;
  for I := 1 to nc do
  begin
    J := clist[I - 1] and $7FFFFFFF;
    if apos[J] < litstart then Continue;
    P := 0;
    if clist[I - 1] and $80000000 <> 0 then
      P := Period(c, cphys, apos[J], PLim);
    if P <> 0 then
    begin
      C5[0] := P;
      for K := 0 to 3 do C5[K + 1] := cand4[4 * J + K];
      orep_verify(c, cabs, cphys, clen, apos + J, @C5[0], 1, c^.Cands + 1,
        cap, @Cd, @F, @B);
    end
    else
    begin
      if cand4[4 * J] = 0 then Continue;
      orep_verify(c, cabs, cphys, clen, apos + J, cand4 + 4 * J, 1,
        c^.Cands, cap, @Cd, @F, @B);
    end;
    if orep_select(c, cabs, cphys, clen, apos + J, @Cd, @F, @B, 1, cap,
      litstart, nm, lit, len, dist, mcap) < 0 then Exit(-1);
  end;
  Result := 0;
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
    Idx: LongInt;
    Go: PRTLEvent;
    Id: TThreadID;
  end;
  TOrepPool = record
    N: LongInt;                 { workers started }
    W: array of TOrepWorker;
    Done: PRTLEvent;
    Lock: TRTLCriticalSection;  { Open, Active, the job fields }
    Gen: LongInt;               { bumped for every job }
    Active, NextItem, Items: LongInt;
    Open: Boolean;              { workers can still join the job }
    Job: TOrepJob;
    Ctx: Pointer;
    Quit: Boolean;
    OnBusy, OnIdle: TOrepHook;
    OnTry: TOrepTryHook;
    HookCtx: Pointer;
    SpinUs: LongWord;
    Allowed: LongInt;           { workers 0 .. Allowed - 1 may join }
    NoSpin: Boolean;            { with OnTry: sleep right after the job }
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
  { the first part of a spin (up to this many microseconds) is a busy loop,
    the rest yields the CPU between checks }
  OREP_SPIN_HOT = 100;

{ a clock in microseconds, for the spins only (not monotonic everywhere;
  a jump only makes one spin shorter or longer) }
function NowUs: QWord;
{$IFDEF WINDOWS}
var
  C, F: Int64;
begin
  C := 0; F := 0;
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  if F <= 0 then Exit(GetTickCount64 * 1000);
  Result := QWord(C div F) * 1000000 + QWord((C mod F) * 1000000 div F);
end;
{$ELSE}
{$IFDEF UNIX}
var
  T: TTimeVal;
begin
  fpgettimeofday(@T, nil);
  Result := QWord(T.tv_sec) * 1000000 + QWord(T.tv_usec);
end;
{$ELSE}
begin
  Result := GetTickCount64 * 1000;
end;
{$ENDIF}
{$ENDIF}

{ spin until Gen differs from MyGen or SpinUs microseconds passed; True
  when Gen changed }
function SpinGen(var Gen: LongInt; MyGen: LongInt; SpinUs: LongWord): Boolean;
var
  T0, T: QWord;
  I: LongWord;
begin
  Result := Gen <> MyGen;
  if Result or (SpinUs = 0) then Exit;
  T0 := NowUs;
  I := 0;
  repeat
    Inc(I);
    if (I and 63) = 0 then
    begin
      T := NowUs;
      if T < T0 then T0 := T;
      if T - T0 >= SpinUs then Break;
      if T - T0 >= OREP_SPIN_HOT then ThreadSwitch;
    end;
    ReadBarrier;
    if Gen <> MyGen then Exit(True);
  until False;
  ReadBarrier;
  Result := Gen <> MyGen;
end;

{ A worker holds its token (OnBusy .. OnIdle) from when it wakes until it
  is about to sleep; the spin between the jobs of a block (SpinUs) counts
  as busy.  It joins a job only while the job is open, so a worker that waits
  in OnBusy never holds the search up. }
function PoolWorker(Arg: Pointer): PtrInt;
var
  Wk: ^TOrepWorker;
  P: POrepPool;
  MyGen: LongInt;
  Holding, Join, Last: Boolean;
begin
  Wk := Arg;
  P := Wk^.Pool;
  MyGen := 0;
  Holding := False;
  Join := False;
  repeat
    { with OnTry the thread searching holds the tokens of its helpers for
      the block, and the workers call no hooks }
    if (P^.OnTry = nil) or (Join and not P^.NoSpin) then
      SpinGen(P^.Gen, MyGen, P^.SpinUs);
    if (P^.Gen = MyGen) and Holding then
    begin
      if P^.OnIdle <> nil then P^.OnIdle(P^.HookCtx);
      Holding := False;
    end;
    while P^.Gen = MyGen do
      RTLEventWaitFor(Wk^.Go, 100);
    ReadBarrier;
    MyGen := P^.Gen;
    if P^.Quit then Break;
    Join := False;
    if Wk^.Idx >= P^.Allowed then Continue;
    if (not Holding) and (P^.OnTry = nil) then
    begin
      if P^.OnBusy <> nil then P^.OnBusy(P^.HookCtx);
      Holding := True;
    end;
    EnterCriticalSection(P^.Lock);
    Join := P^.Open and (P^.Gen = MyGen);
    if Join then Inc(P^.Active);
    LeaveCriticalSection(P^.Lock);
    if Join then
    begin
      PoolItems(P);
      EnterCriticalSection(P^.Lock);
      Dec(P^.Active);
      Last := P^.Active = 0;
      LeaveCriticalSection(P^.Lock);
      if Last then RTLEventSetEvent(P^.Done);
    end;
  until False;
  if Holding and (P^.OnIdle <> nil) then P^.OnIdle(P^.HookCtx);
  Result := 0;
end;

{ start up to Want - 1 workers; nil when none could be started }
function PoolCreate(Want: LongWord; OnBusy, OnIdle: TOrepHook;
  OnTry: TOrepTryHook; HookCtx: Pointer; SpinUs: LongWord): POrepPool;
var
  I: LongInt;
begin
  Result := nil;
  if Want <= 1 then Exit;
  New(Result);
  FillChar(Result^, SizeOf(TOrepPool), 0);
  Result^.OnBusy := OnBusy;
  Result^.OnIdle := OnIdle;
  Result^.HookCtx := HookCtx;
  Result^.SpinUs := SpinUs;
  Result^.OnTry := OnTry;
  InitCriticalSection(Result^.Lock);
  SetLength(Result^.W, Want - 1);
  try
    Result^.Done := RTLEventCreate;
    for I := 0 to LongInt(Want) - 2 do
    begin
      Result^.W[I].Pool := Result;
      Result^.W[I].Idx := I;
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
    DoneCriticalSection(Result^.Lock);
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
  DoneCriticalSection(P^.Lock);
  P^.W := nil;
  Dispose(P);
end;

{ run a job with workers 0 .. Allowed - 1 helping; NoSpin: they sleep
  right after it (with OnTry: the block ends and its tokens go back) }
procedure PoolRun(P: POrepPool; Job: TOrepJob; Ctx: Pointer; Items: LongInt;
  Allowed: LongInt; NoSpin: Boolean);
var
  I, K: LongInt;
  T0, T: QWord;
begin
  if Items <= 0 then Exit;
  if (P = nil) or (Items = 1) or (Allowed <= 0) then
  begin
    for K := 0 to Items - 1 do Job(Ctx, K);
    Exit;
  end;
  if Allowed > P^.N then Allowed := P^.N;
  EnterCriticalSection(P^.Lock);
  P^.Allowed := Allowed;
  P^.NoSpin := NoSpin;
  P^.Job := Job;
  P^.Ctx := Ctx;
  P^.Items := Items;
  P^.NextItem := 0;
  P^.Active := 0;
  P^.Open := True;
  InterLockedIncrement(P^.Gen);
  LeaveCriticalSection(P^.Lock);
  for I := 0 to Allowed - 1 do RTLEventSetEvent(P^.W[I].Go);
  PoolItems(P);
  { every item is taken: no one joins any more; wait for those that did }
  EnterCriticalSection(P^.Lock);
  P^.Open := False;
  LeaveCriticalSection(P^.Lock);
  { the last item of a job is short: spin for it, then sleep }
  ReadBarrier;
  if P^.Active > 0 then
  begin
    T0 := NowUs;
    I := 0;
    while P^.Active > 0 do
    begin
      Inc(I);
      if (I and 63) = 0 then
      begin
        T := NowUs;
        if T < T0 then T0 := T;
        if T - T0 >= P^.SpinUs then RTLEventWaitFor(P^.Done, 1)
        else if T - T0 >= OREP_SPIN_HOT then ThreadSwitch;
      end;
      ReadBarrier;
    end;
  end;
  ReadBarrier;
end;

{ ---- the search of one block (phases: see orep_core.c) ---------------------- }

type
  POrepEnc = ^TOrepEnc;

{ The segments of a block go through three stages (see orep_core.c):
  the anchors run on any thread in any order, the probe and the select
  (which verifies the anchors it looks at) one segment at a time in
  order.  Every thread that helps runs SearchLoop: under SLock it takes
  the most urgent task (probe, select, then the anchors of a new segment
  while a slot is free), runs it outside the lock, and marks it done.
  The probes run in segment order, so the table ends as with one thread,
  and the stream is the same with any number.  With no helpers,
  SearchBlock runs the three in turn, without the lock. }

const
  TASK_NONE = 0; TASK_ANCHORS = 1; TASK_PROBE = 2; TASK_SELECT = 4;
  TASK_DONE = 5;

{ under SLock: the next task, its segment in K.  Only the thread that
  drives the search (Driver) probes: the table, the only thing the probe
  touches, then stays in its caches and near its memory. }
function TakeTask(E: POrepEnc; Driver: Boolean; out K: LongWord): Integer;
begin
  K := 0;
  if E^.SSel >= E^.SNSeg then Exit(TASK_DONE);
  if Driver and (not E^.SProbeBusy) and (E^.SPrb < E^.SNextA) and
    (E^.SegSt[E^.SPrb mod E^.NSlot] = 1) then
  begin
    E^.SProbeBusy := True;
    K := E^.SPrb;
    Exit(TASK_PROBE);
  end;
  if (not E^.SSelBusy) and (E^.SSel < E^.SPrb) then
  begin
    E^.SSelBusy := True;
    K := E^.SSel;
    Exit(TASK_SELECT);
  end;
  if (E^.SNextA < E^.SNSeg) and (E^.SNextA < E^.SSel + E^.NSlot) then
  begin
    K := E^.SNextA;
    E^.SegSt[K mod E^.NSlot] := 0;
    Inc(E^.SNextA);
    Exit(TASK_ANCHORS);
  end;
  Result := TASK_NONE;
end;

{ under SLock: wake up to N participants that sleep }
procedure WakeSome(E: POrepEnc; N: LongWord);
var
  I: LongWord;
begin
  I := 0;
  while (N > 0) and (I < E^.NPart) do
  begin
    if E^.PartWait[I] <> 0 then
    begin
      E^.PartWait[I] := 0;
      RTLEventSetEvent(PRTLEvent(E^.PartEv[I]));
      Dec(N);
    end;
    Inc(I);
  end;
end;

procedure SearchLoop(Ctx: Pointer; Item: LongInt);
var
  E: POrepEnc;
  T: Integer;
  K, Sl, O, S0, S1, LS, NM: LongWord;
  R, G: LongInt;
  Sleeping, Driver: Boolean;
begin
  E := Ctx;
  T := TASK_NONE;
  K := 0;
  R := 0;
  G := 0;
  Sleeping := False;
  Driver := GetCurrentThreadId = E^.SDriver;
  if Driver then
  begin
    EnterCriticalSection(E^.SLock);
    E^.SDrvItem := Item;
    LeaveCriticalSection(E^.SLock);
  end;
  repeat
    EnterCriticalSection(E^.SLock);
    if T <> TASK_NONE then
    begin
      { the task just done }
      Sl := K mod E^.NSlot;
      case T of
        TASK_ANCHORS: E^.SegSt[Sl] := 1;
        TASK_PROBE: begin Inc(E^.SPrb); E^.SProbeBusy := False; end;
        TASK_SELECT:
          begin
            if R < 0 then
            begin
              E^.SFail := True;
              E^.SSel := E^.SNSeg;
            end
            else Inc(E^.SSel);
            E^.SSelBusy := False;
          end;
      end;
      Inc(E^.SGen);
    end;
    T := TakeTask(E, Driver, K);
    { a task ended: wake a sleeper for what it may have opened (this
      thread takes one task itself); all of them at the end }
    if E^.NPart > 1 then
    begin
      if T = TASK_DONE then WakeSome(E, E^.NPart)
      else if T <> TASK_NONE then WakeSome(E, 1);
      { the driver, for a probe the others cannot take }
      if (E^.SDrvItem >= 0) and (E^.PartWait[E^.SDrvItem] <> 0) then
      begin
        E^.PartWait[E^.SDrvItem] := 0;
        RTLEventSetEvent(PRTLEvent(E^.PartEv[E^.SDrvItem]));
      end;
    end;
    if T = TASK_NONE then
    begin
      G := E^.SGen;
      if Sleeping then E^.PartWait[Item] := 1;
    end;
    LeaveCriticalSection(E^.SLock);
    if T = TASK_DONE then Break;
    if T = TASK_NONE then
    begin
      { nothing to do now (only with several threads): spin until a task
        ends or SpinUs passed, then sleep until one ends }
      if Sleeping then
        RTLEventWaitFor(PRTLEvent(E^.PartEv[Item]), 10)
      else if not SpinGen(E^.SGen, G, E^.SpinUs) then
        Sleeping := True;
      Continue;
    end;
    Sleeping := False;
    Sl := K mod E^.NSlot;
    O := Sl * OREP_SUB;
    case T of
      TASK_ANCHORS:
        begin
          S0 := K * OREP_SUB;
          S1 := S0 + OREP_SUB;
          if S1 > E^.BNPos then S1 := E^.BNPos;
          E^.SegCnt[Sl] := orep_anchors(@E^.Cfg,
            SlotPtr(E^.Cfg.Slots, E^.Cfg.CShift, E^.BPhysQ), S0, S1,
            E^.APos + O, E^.AIdx + O, E^.ATag + O);
        end;
      TASK_PROBE:
        { the count becomes that of the anchors with a candidate, listed
          in AIdx }
        if E^.SegCnt[Sl] > 0 then
          E^.SegCnt[Sl] := orep_probe(@E^.Cfg, E^.BCAbs, E^.APos + O,
            E^.AIdx + O, E^.ATag + O, E^.SegCnt[Sl], E^.Cand4 + 4 * O);
      TASK_SELECT:
        begin
          LS := E^.SLitStart;
          NM := E^.SNMc;
          R := orep_vselect(@E^.Cfg, E^.BCAbs, E^.BPhysQ, E^.BLen,
            E^.APos + O, E^.Cand4 + 4 * O, E^.AIdx + O, E^.SegCnt[Sl],
            E^.VCap, LS, NM, E^.SLit, E^.SLen, E^.SDist, E^.Cap);
          E^.SLitStart := LS;
          E^.SNMc := NM;
        end;
    end;
  until False;
end;

{ search the block [BPhysQ, BPhysQ + BLen) (absolute BCAbs) into
  SLit/SLen/SDist; the count, or -1 when it does not fit }
function SearchBlock(var E: TOrepEnc): LongInt;
var
  L, H, Got, K, S0, S1, N: LongWord;
begin
  E.VCap := E.Cfg.MinLen + E.Cfg.Align;
  E.SNMc := 0;
  E.SLitStart := 0;
  L := orep_cont(@E.Cfg, E.BCAbs, E.BPhysQ, E.BLen, E.PrevDist);
  if L > 0 then
  begin
    E.SLit[0] := 0; E.SLen[0] := L; E.SDist[0] := E.PrevDist;
    E.SNMc := 1;
    E.SLitStart := L;
  end;
  if E.BLen >= E.Cfg.Gram then E.BNPos := E.BLen - E.Cfg.Gram + 1
  else E.BNPos := 0;
  E.SNSeg := (E.BNPos + OREP_SUB - 1) div OREP_SUB;
  E.SNextA := 0; E.SPrb := 0; E.SSel := 0;
  E.SProbeBusy := False; E.SSelBusy := False; E.SFail := False;
  if E.SNSeg > 0 then
  begin
    { helpers: all the workers, or with OnWorkerTryBusy those that get a
      token now; no more than there are segments }
    H := E.NPart - 1;
    if H > E.SNSeg - 1 then H := E.SNSeg - 1;
    if (E.OnTry <> nil) and (H > 0) then
    begin
      Got := 0;
      while (Got < H) and E.OnTry(E.HookCtx) do Inc(Got);
      H := Got;
    end;
    if H = 0 then
    begin
      { alone: each segment in turn, with no locks }
      K := 0;
      while (K < E.SNSeg) and not E.SFail do
      begin
        S0 := K * OREP_SUB;
        S1 := S0 + OREP_SUB;
        if S1 > E.BNPos then S1 := E.BNPos;
        N := orep_anchors(@E.Cfg, SlotPtr(E.Cfg.Slots, E.Cfg.CShift,
          E.BPhysQ), S0, S1, E.APos, E.AIdx, E.ATag);
        if N > 0 then
        begin
          N := orep_probe(@E.Cfg, E.BCAbs, E.APos, E.AIdx, E.ATag, N,
            E.Cand4);
          if orep_vselect(@E.Cfg, E.BCAbs, E.BPhysQ, E.BLen, E.APos,
            E.Cand4, E.AIdx, N, E.VCap, E.SLitStart, E.SNMc, E.SLit, E.SLen,
            E.SDist, E.Cap) < 0 then E.SFail := True;
        end;
        Inc(K);
      end;
    end
    else
    begin
      E.SDriver := GetCurrentThreadId;
      E.SDrvItem := -1;
      PoolRun(E.Pool, @SearchLoop, @E, H + 1, H, True);
    end;
    if E.OnTry <> nil then
      for K := 1 to H do
        if E.OnIdle <> nil then E.OnIdle(E.HookCtx);
  end;
  if E.SFail then Exit(-1);
  Result := E.SNMc;
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
    Finished: LongInt;   { 1 once the search of the block is done }
    HasToken: Boolean;   { the caller took the token for this search }
  end;

function CoordMain(Arg: Pointer): PtrInt;
var
  C: POrepCoord;
begin
  C := Arg;
  repeat
    RTLEventWaitFor(C^.Go);
    if C^.Quit then Break;
    if (not C^.HasToken) and (C^.E^.OnBusy <> nil) then
      C^.E^.OnBusy(C^.E^.HookCtx);
    C^.E^.SNM := SearchBlock(C^.E^);
    if C^.E^.OnIdle <> nil then C^.E^.OnIdle(C^.E^.HookCtx);
    WriteBarrier;
    C^.Finished := 1;
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

{ the caller's thread waits for the search of the block in flight; the
  OnCallerWait hooks go around the wait when the search is not done yet }
procedure CoordWait(var E: TOrepEnc);
var
  C: POrepCoord;
  Hook: Boolean;
begin
  C := E.Coord;
  ReadBarrier;
  Hook := (C^.Finished = 0) and (E.OnWaitBegin <> nil);
  if Hook then E.OnWaitBegin(E.HookCtx);
  RTLEventWaitFor(C^.Done);
  if Hook and (E.OnWaitEnd <> nil) then E.OnWaitEnd(E.HookCtx);
  ReadBarrier;
end;

{ ---- encoder ------------------------------------------------------------- }

procedure EncFree(var E: TOrepEnc);
var
  I: LongWord;
begin
  { the search in flight reads the ring and the table: wait for it first }
  if E.InFlight and E.ViaCoord then CoordWait(E);
  E.InFlight := False;
  FreeSlots(E.Cfg.Slots, E.Cfg.RingSize, E.Cfg.CShift);
  if E.TableRaw <> nil then FreeMem(E.TableRaw);
  E.TableRaw := nil;
  CoordFree(POrepCoord(E.Coord));
  E.Coord := nil;
  PoolFree(POrepPool(E.Pool));
  E.Pool := nil;
  if E.PartEv <> nil then
  begin
    for I := 1 to E.NPart do
      if E.PartEv[I - 1] <> nil then RTLEventDestroy(PRTLEvent(E.PartEv[I - 1]));
    FreeMem(E.PartEv);
  end;
  if E.PartWait <> nil then FreeMem(E.PartWait);
  E.PartEv := nil; E.PartWait := nil;
  if E.SLockInit then DoneCriticalSection(E.SLock);
  E.SLockInit := False;
  if E.SegCnt <> nil then FreeMem(E.SegCnt);
  if E.SegSt <> nil then FreeMem(E.SegSt);
  E.SegCnt := nil; E.SegSt := nil;
  if E.Cand4 <> nil then FreeMem(E.Cand4);
  E.Cand4 := nil;
  if E.APos <> nil then FreeMem(E.APos);
  if E.AIdx <> nil then FreeMem(E.AIdx);
  if E.ATag <> nil then FreeMem(E.ATag);
  E.APos := nil; E.AIdx := nil; E.ATag := nil;
  if E.Lit <> nil then FreeMem(E.Lit);
  if E.Len <> nil then FreeMem(E.Len);
  if E.Dist <> nil then FreeMem(E.Dist);
  if E.SLit <> nil then FreeMem(E.SLit);
  if E.SLen <> nil then FreeMem(E.SLen);
  if E.SDist <> nil then FreeMem(E.SDist);
  E.SLit := nil; E.SLen := nil; E.SDist := nil;
  if E.Stage <> nil then FreeMem(E.Stage);
  E.Cfg.Table := nil;
  E.Lit := nil; E.Len := nil; E.Dist := nil; E.Stage := nil;
end;

procedure StageHeader(var E: TOrepEnc);
begin
  Move(Magic, E.Stage[0], 4);
  E.Stage[4] := OREP_FORMAT;
  E.Stage[5] := Log2Of(E.Chunk);
  E.StageLen := 6;
  Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Cfg.Window));
  if E.AutoAlign then Inc(E.StageLen, PutVar(E.Stage + E.StageLen, 0))
  else Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Cfg.Align));
  Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Cfg.MinLen));
  Put32(E.Stage + E.StageLen, OrepCrc32c(0, E.Stage, E.StageLen));
  Inc(E.StageLen, 4);
  E.StreamPos := E.StageLen;
  E.StagePos := 0;
  E.Phase := 2;   { drain the header, then fill }
end;

function OrepEncInit(out E: TOrepEnc; const P: TOrepParams): Integer;
var
  W: QWord;
  I, TB: LongWord;
begin
  FillChar(E, SizeOf(E), 0);
  if not CheckParams(P) then Exit(OREP_E_PARAM);
  W := EffWindow(P);
  E.Cfg.Window := W;
  E.Cfg.MinLen := P.MinLen;
  E.Cfg.MinDist := P.MinDist;
  E.Cfg.Cands := P.Cands;
  E.Cfg.Score := 256;
  E.AutoAlign := P.Align = 0;
  if E.AutoAlign then E.Cfg.Align := 4 else E.Cfg.Align := P.Align;
  Derive(P, W, E.Cfg.Gram, E.Cfg.SMask, E.Cfg.MaxGap, TB,
    E.Cfg.MinKeep, E.Cfg.SShift);
  E.Cfg.PLim := OREP_PLIM;
  E.Cfg.RunKeep := P.RunKeep;
  InitTables(E.Cfg);
  E.Chunk := P.Chunk;
  { with threads, one slot more than a decoder needs: the caller's thread
    fills the next slot while the search of this one may still read the
    oldest (inline, the search ends first; OrepEncMemory counts the slot
    anyway, since a caller may estimate with one thread) }
  E.Cfg.RingSize := RingFor(W, P.Chunk);
  if P.Threads >= 2 then Inc(E.Cfg.RingSize, P.Chunk);
  E.Cap := P.Chunk div E.Cfg.MinKeep + 2;
  E.StageCap := E.Cap * 15 + 64 + 4096;
  try
    E.Cfg.NBuck := NBuckFor(P, W);
    E.TableRaw := AllocMem(SizeUInt(32) * E.Cfg.NBuck + 64);
    E.Cfg.Table := PQWord((PtrUInt(E.TableRaw) + 63) and not PtrUInt(63));
    E.NSlot := SlotsFor(P.Threads);
    E.APos := GetMem(E.NSlot * OREP_SUB * 4);
    E.AIdx := GetMem(E.NSlot * OREP_SUB * 4);
    E.ATag := GetMem(E.NSlot * OREP_SUB * 4);
    E.Cand4 := GetMem(E.NSlot * OREP_SUB * 16);
    E.SegCnt := AllocMem(E.NSlot * 4);
    E.SegSt := AllocMem(E.NSlot * 4);
    E.Lit := GetMem(E.Cap * 4);
    E.Len := GetMem(E.Cap * 4);
    E.Dist := GetMem(E.Cap * 8);
    E.SLit := GetMem(E.Cap * 4);
    E.SLen := GetMem(E.Cap * 4);
    E.SDist := GetMem(E.Cap * 8);
    E.Stage := GetMem(E.StageCap);
    E.Cfg.CShift := Log2Of(P.Chunk);
    E.Cfg.Slots := AllocMem((E.Cfg.RingSize shr E.Cfg.CShift) * SizeOf(PByte));
    E.Cfg.Slots[0] := GetMem(P.Chunk);
  except
    EncFree(E);
    Exit(OREP_E_MEM);
  end;
  { Threads >= 2: a coordinator runs the search, helped by Threads - 1
    workers, while the caller's thread copies input and writes output }
  if P.Threads >= 2 then E.Coord := CoordCreate(@E);
  E.OnBusy := P.OnWorkerBusy;
  E.OnIdle := P.OnWorkerIdle;
  E.HookCtx := P.HookCtx;
  E.OnWaitBegin := P.OnCallerWaitBegin;
  E.OnWaitEnd := P.OnCallerWaitEnd;
  E.SpinUs := P.SpinUs;
  E.OnTry := P.OnWorkerTryBusy;
  if E.Coord <> nil then
    E.Pool := PoolCreate(P.Threads, P.OnWorkerBusy, P.OnWorkerIdle,
      P.OnWorkerTryBusy, P.HookCtx, P.SpinUs);
  if E.Pool <> nil then E.NPart := POrepPool(E.Pool)^.N + 1
  else E.NPart := 1;
  InitCriticalSection(E.SLock);
  E.SLockInit := True;
  try
    E.PartEv := AllocMem(E.NPart * SizeOf(Pointer));
    E.PartWait := AllocMem(E.NPart * 4);
    if E.NPart > 1 then
      for I := 1 to E.NPart do E.PartEv[I - 1] := RTLEventCreate;
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
  if E.InFlight and E.ViaCoord then CoordWait(E);
  E.InFlight := False;
  { a fresh stream: the same bytes as a new state would write }
  FillChar(E.Cfg.Table^, SizeUInt(32) * E.Cfg.NBuck, 0);
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

{ the alignment of a block when it is chosen per block: 1 for text (at
  least 90% of ~4096 bytes spread over the block are printable ASCII or
  tab/CR/LF), else 4.  It runs before the search starts, so it samples. }
function BlockAlign(P: PByte; N: LongWord): LongWord;
var
  I, T, Cnt, Step: LongWord;
  B: Byte;
begin
  T := 0;
  Cnt := 0;
  I := 0;
  Step := N div 4096;
  if Step < 1 then Step := 1;
  while I < N do
  begin
    B := P[I];
    if ((B >= 32) and (B < 127)) or (B = 9) or (B = 10) or (B = 13) then Inc(T);
    Inc(Cnt);
    Inc(I, Step);
  end;
  if T * 10 >= Cnt * 9 then Result := 1 else Result := 4;
end;

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
  if E.AutoAlign then
    E.Cfg.Align := BlockAlign(SlotPtr(E.Cfg.Slots, E.Cfg.CShift, E.BPhysQ),
      E.BLen);
  E.BAlign := E.Cfg.Align;
  { the slot the caller's thread fills next (no search runs now) }
  if not EnsureSlot(E.Cfg.Slots, E.Cfg.CShift, E.SlotPhys) then
    Exit(OREP_E_MEM);
  { the search writes the spare match arrays (SLit...); Finalize swaps them
    with the ones being written out, which are done by then }
  E.InFlight := True;
  { with OnWorkerTryBusy and no free token, the caller's thread searches
    the block itself }
  E.ViaCoord := (E.Coord <> nil) and ((E.OnTry = nil) or E.OnTry(E.HookCtx));
  if E.ViaCoord then
  begin
    POrepCoord(E.Coord)^.Finished := 0;
    POrepCoord(E.Coord)^.HasToken := E.OnTry <> nil;
    WriteBarrier;
    RTLEventSetEvent(POrepCoord(E.Coord)^.Go);
  end
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
  if E.ViaCoord then CoordWait(E);
  E.InFlight := False;
  E.ViaCoord := False;
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
  Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.BAlign));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Lit[I - 1]));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen,
      E.Len[I - 1] - OREP_MIN_MATCH));
  for I := 1 to E.NMatch do
    Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Dist[I - 1] - 1));
  { zeros so that every literal sits at its input position modulo Align }
  A := E.BAlign;
  Pad := ((E.BCAbs mod A) + A - ((E.StreamPos + E.StageLen) mod A)) mod A;
  FillChar(E.Stage[E.StageLen], Pad, 0);
  Inc(E.StageLen, Pad);
  Inc(E.StreamPos, QWord(E.StageLen) + (E.BlkLen - SumLen) + 4);
  E.StagePos := 0;
  E.BlockCrc := OrepCrc32c(0, SlotPtr(E.Cfg.Slots, E.Cfg.CShift, E.BlkPhys),
    E.BlkLen);
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
             Move(NextIn^, SlotPtr(E.Cfg.Slots, E.Cfg.CShift,
               E.SlotPhys + E.Fill)^, Want);
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
             Inc(E.StageLen, PutVar(E.Stage + E.StageLen, E.Total));
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
           Move(SlotPtr(E.Cfg.Slots, E.Cfg.CShift,
             E.BlkPhys + E.LitBase + E.LitOff)^, NextOut^, K);
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
  FreeSlots(D.Slots, D.RingSize, D.CShift);
  if D.Cols <> nil then FreeMem(D.Cols);
  if D.Lit <> nil then FreeMem(D.Lit);
  if D.Len <> nil then FreeMem(D.Len);
  if D.Dist <> nil then FreeMem(D.Dist);
  D.Cols := nil; D.Lit := nil; D.Len := nil; D.Dist := nil;
  D.Slots := nil; D.ColCap := 0; D.MCap := 0;
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

function OrepDecReset(var D: TOrepDec): Integer;
var
  K: TOrepDec;
begin
  if not D.Inited then Exit(OREP_E_PARAM);
  K := D;
  FillChar(D, SizeOf(D), 0);
  { kept: the memory and what it was made for }
  D.MemLimit := K.MemLimit;
  D.Slots := K.Slots; D.RingSize := K.RingSize; D.CShift := K.CShift;
  D.Chunk := K.Chunk; D.Window := K.Window; D.OldChunk := K.Chunk;
  D.Lit := K.Lit; D.Len := K.Len; D.Dist := K.Dist; D.MCap := K.MCap;
  D.Cols := K.Cols; D.ColCap := K.ColCap;
  D.Inited := True;
  Result := OREP_OK;
end;

function OrepDecPeek(var D: TOrepDec; var NextIn: PByte; var AvailIn: SizeUInt;
  out Data: PByte; out Count: SizeUInt): Integer;
var
  Z: PByte;
  ZN: SizeUInt;
begin
  Data := nil;
  Count := 0;
  Z := nil;
  ZN := 0;
  Result := OrepDecRun(D, NextIn, AvailIn, Z, ZN);
  if (Result = OREP_OK) and (D.Phase = 5) and (D.EmitPos < D.OutSize) then
  begin
    Data := SlotPtr(D.Slots, D.CShift, D.WPhys + D.EmitPos);
    Count := D.OutSize - D.EmitPos;
  end;
end;

procedure OrepDecSkip(var D: TOrepDec; N: SizeUInt);
begin
  if (D.Phase <> 5) or (D.EmitPos >= D.OutSize) then Exit;
  if N > D.OutSize - D.EmitPos then N := D.OutSize - D.EmitPos;
  Inc(D.EmitPos, N);
end;

{ the header so far (HdrLen bytes): 1 = complete, 0 = needs more,
  < 0 = an error.  Magic, version, log2 chunk, then varints window, align
  setting, minimum length, then the CRC-32C of all that. }
function DecHeaderState(var D: TOrepDec): Integer;
var
  I, P, N, Sh: LongWord;
  V: array[0..2] of QWord;
begin
  for I := 0 to 3 do
    if (I < D.HdrLen) and (Char(D.Hdr[I]) <> Magic[I]) then
      Exit(OREP_E_VERSION);
  if (D.HdrLen > 4) and (D.Hdr[4] <> OREP_FORMAT) then Exit(OREP_E_VERSION);
  if D.HdrLen < 6 then Exit(0);
  P := 6;
  for N := 0 to 2 do
  begin
    V[N] := 0;
    Sh := 0;
    repeat
      if P >= D.HdrLen then Exit(0);
      if Sh >= 35 then Exit(OREP_E_DATA);   { at most 5 bytes }
      V[N] := V[N] or (QWord(D.Hdr[P] and $7F) shl Sh);
      Inc(Sh, 7);
      Inc(P);
    until D.Hdr[P - 1] < $80;
  end;
  if D.HdrLen < P + 4 then Exit(0);
  if Get32(@D.Hdr[P]) <> OrepCrc32c(0, @D.Hdr[0], P) then Exit(OREP_E_DATA);
  if (D.Hdr[5] < 16) or (D.Hdr[5] > 26) or (V[1] > 4096) then
    Exit(OREP_E_DATA);
  D.Chunk := LongWord(1) shl D.Hdr[5];
  D.Window := V[0];
  Result := 1;
end;

function DecHeader(var D: TOrepDec): Integer;
begin
  if (D.Window < 1) or (D.Window > OREP_MAX_WINDOW) or
    (D.Chunk < OREP_MIN_CHUNK) or (D.Chunk > OREP_MAX_CHUNK) or
    (D.Chunk and (D.Chunk - 1) <> 0) then
    Exit(OREP_E_DATA);
  if (D.MemLimit <> 0) and (OrepDecMemory(D.Window, D.Chunk) > D.MemLimit) then
    Exit(OREP_E_MEM);
  { after OrepDecReset: keep the memory if it fits this stream as is }
  if D.Slots <> nil then
  begin
    if (D.OldChunk = D.Chunk) and (D.RingSize = RingFor(D.Window, D.Chunk)) then
      Exit(OREP_OK);
    DecFree(D);
  end;
  D.RingSize := RingFor(D.Window, D.Chunk);
  D.MCap := D.Chunk div OREP_MIN_MATCH + 2;
  try
    D.Lit := GetMem(D.MCap * 4);
    D.Len := GetMem(D.MCap * 4);
    D.Dist := GetMem(D.MCap * 4);
    D.CShift := Log2Of(D.Chunk);
    D.Slots := AllocMem((D.RingSize shr D.CShift) * SizeOf(PByte));
  except
    Exit(OREP_E_MEM);
  end;
  Result := OREP_OK;
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
  Sp: QWord;
  Run, K, Off: LongWord;
  Src, Dst: PByte;
begin
  Dst := SlotPtr(D.Slots, D.CShift, D.WPhys + D.BlkPos);
  Sp := D.WPhys + D.BlkPos;
  if Sp >= Dist then Sp := Sp - Dist else Sp := Sp + D.RingSize - Dist;
  while Len > 0 do
  begin
    { the source run stays in one slot (the end of the ring is a slot end) }
    Off := LongWord(Sp and (D.Chunk - 1));
    Run := Len;
    if D.Chunk - Off < Run then Run := D.Chunk - Off;
    Src := SlotPtr(D.Slots, D.CShift, Sp);
    if Dist >= Run then
      Move(Src^, Dst^, Run)
    else
      for K := 0 to Run - 1 do Dst[K] := Src[K];
    Inc(Dst, Run);
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
      0: begin { stream header, a byte at a time (it is short) }
           R := DecHeaderState(D);
           if R < 0 then begin D.Phase := 99; Exit(R); end;
           if R = 0 then
           begin
             if AvailIn = 0 then Exit(OREP_OK);
             if D.HdrLen >= HDR_MAX then begin D.Phase := 99; Exit(OREP_E_DATA); end;
             D.Hdr[D.HdrLen] := NextIn^;
             Inc(NextIn); Dec(AvailIn); Inc(D.InPos); Inc(D.HdrLen);
             Continue;
           end;
           R := DecHeader(D);
           if R <> OREP_OK then begin D.Phase := 99; Exit(R); end;
           D.Phase := 1;
           D.VarIdx := 0; D.VarVal := 0; D.VarShift := 0;
         end;
      1: begin { block header: out size, matches, column bytes, align }
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
             3: D.Align := D.VarVal;
           end;
           D.VarVal := 0; D.VarShift := 0;
           if (D.VarIdx = 0) and (D.OutSize = 0) then
           begin
             D.Phase := 6; D.CrcLen := 0;
             Continue;
           end;
           Inc(D.VarIdx);
           if D.VarIdx < 4 then Continue;
           D.VarIdx := 0;
           { a block stays inside its chunk-aligned slot }
           if (D.Align < 1) or (D.Align > 4096) or (D.OutSize > D.Chunk) or
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
           if not EnsureSlot(D.Slots, D.CShift, D.WPhys) then
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
             Move(NextIn^, SlotPtr(D.Slots, D.CShift, D.WPhys + D.BlkPos)^, K);
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
             OrepCrc32c(0, SlotPtr(D.Slots, D.CShift, D.WPhys), D.OutSize) then
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
             Move(SlotPtr(D.Slots, D.CShift, D.WPhys + D.EmitPos)^, NextOut^, K);
             Inc(NextOut, K); Dec(AvailOut, K); Inc(D.EmitPos, K);
             Continue;
           end;
           Inc(D.Total, D.OutSize);
           Inc(D.WPhys, D.OutSize);
           if D.WPhys >= D.RingSize then D.WPhys := 0;
           D.Phase := 1;
         end;
      6: begin { end: total size, a varint }
           if AvailIn = 0 then Exit(OREP_OK);
           B := NextIn^;
           Inc(NextIn); Dec(AvailIn); Inc(D.InPos);
           if D.VarShift > 63 then begin D.Phase := 99; Exit(OREP_E_DATA); end;
           D.VarVal := D.VarVal or (QWord(B and $7F) shl D.VarShift);
           Inc(D.VarShift, 7);
           if B >= $80 then Continue;
           if D.VarVal <> D.Total then
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
