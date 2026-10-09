unit Dedup;
{ El pre-paso -dup: CDC + dedup (dedup.rs, que porta dedup.cpp). El formato
  .dupref y las fronteras de chunk son los del C++, byte a byte.

  Meta (little-endian):
    cabecera (24): magia u32 "DUPR", version u32 = 1, chunk_count u64,
                   unique_count u64
    tabla (chunk_count records): tag u8 (0 = unico, 1 = referencia)
                   tag 0 -> largo u32 (bytes del chunk en el cuerpo)
                   tag 1 -> indice LEB128, < unique_count
  El cuerpo son los chunks unicos concatenados, en orden de aparicion.

  Dos hashes de frontera: FNV (el default) y Gear (opcional, estilo
  FastCDC). La eleccion no llega al formato: el decode solo reproduce los
  records guardados.

  Se porta lo que usa osrep -dup: el encode y el decode por streaming. }

{$MODE OBJFPC}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}
interface

uses SysUtils, Classes, Widths, Hashes, StreamIO;

const
  DUP_MAGIC   = DWord($52505544);   { "DUPR" LE }
  DUP_VERSION = DWord(1);
  DUP_HEADER_SIZE = 24;

  DEFAULT_AVG = 4096;
  DEFAULT_MIN = 1024;
  DEFAULT_MAX = 16384;
  DEFAULT_DUP_BUF_SIZE = 0;
  CDC_HASH_FNV  = 0;
  CDC_HASH_GEAR = 1;

  DEDUP_OK = 0;
  DEDUP_ERR_TRUNCATED = 1;
  DEDUP_ERR_BAD_MAGIC = 2;
  DEDUP_ERR_BAD_VER = 3;
  DEDUP_ERR_BAD_TAG = 4;
  DEDUP_ERR_BAD_REF = 5;
  DEDUP_ERR_BAD_VARINT = 6;
  DEDUP_ERR_BAD_BODY = 7;
  DEDUP_ERR_INVAL = 8;
  DEDUP_ERR_NOMEM = 9;

type
  TDupParams = record
    Avg, MinChunk, MaxChunk, BufSize: QWord;
    HashAlgo: LongInt;
  end;

  { el error del dedup, con su codigo (DupError::Dedup(i32) en el Rust) }
  EDedup = class(Exception)
  public
    Code: LongInt;
    constructor CreateCode(ACode: LongInt);
  end;

procedure DefaultDupParams(out P: TDupParams);

{ encode_streaming: lee InPath, escribe los chunks unicos en BodyPath a
  medida que se deciden, y devuelve la meta. Paranoid agrega una
  comparacion byte a byte contra el cuerpo ya escrito en cada acierto. }
function EncodeStreaming(const InPath, BodyPath: AnsiString; const P: TDupParams;
                         Paranoid: Boolean): TBytes;

{ decode_streaming: la meta en memoria, el cuerpo leido en secuencia, los
  records expandidos en OutPath (las referencias se copian del propio
  archivo de salida). }
procedure DecodeStreaming(const Meta: TBytes; const BodyPath, OutPath: AnsiString);

implementation

const
  CDC_PRIME = QWord($100000001B3);
  GEAR_DELTA_S = 5;
  GEAR_DELTA_L = 5;
  TAG_UNIQUE = 0;
  TAG_REF = 1;

  GEAR_TABLE: array[0..255] of QWord = (
    QWord($CA8216FA9058D0FA), QWord($ECE45BABCE870479), QWord($87BE93A4A16A73CB), QWord($5A71C08957A50D44),
    QWord($C345D6E168AD2C78), QWord($E47DF32A3A624293), QWord($08CAB724CA100235), QWord($DFA4529422A994BF),
    QWord($1A4C7945EF3E2887), QWord($A3148D0AD0AD2A9A), QWord($62D1D0D9D4002759), QWord($507065D804077EDC),
    QWord($75A5A799430A358C), QWord($DFAA618F05E814AD), QWord($DFDC1F1E3FD80EE5), QWord($AA4F1B082AF8064F),
    QWord($2DD35B22825E9E21), QWord($8258297E8B33077C), QWord($9547A3D84C96AFB2), QWord($14A2E2D414D15ACE),
    QWord($401D2708B1A6F24C), QWord($07E7425232185DF7), QWord($40F1CC64D4F6E966), QWord($62FBD74C6CF6756C),
    QWord($B6E2C223523178D0), QWord($D15193D6622B12A9), QWord($FAFA7D3979287E70), QWord($C3CAC3E16D161A69),
    QWord($23F31DFC3ECB73D1), QWord($A9827391BEC8A294), QWord($1E19E3078153254B), QWord($7DD0207825606CC8),
    QWord($099DC1F55073DEBE), QWord($86CA2CBA13FE4CB8), QWord($0A0F4FCF12D727B5), QWord($A1FDDB44848138BC),
    QWord($B3DE8FA80A8312A2), QWord($FD12F2B74F7EFCFD), QWord($38ADC0A83F9E49C5), QWord($0498B8209519EBF4),
    QWord($07D6DA6CE496B3EF), QWord($9AF4C0EE4D2B954D), QWord($4AFB105F29F066E6), QWord($485BE9E0C0AB7C01),
    QWord($B6C2D889268CF23E), QWord($BE38F54F7A211B90), QWord($993E0F3EC7F8FB5D), QWord($C48F71AFC86DCE2D),
    QWord($546E05CCC2DD8F0C), QWord($0CAC6676C2EE96F9), QWord($BEE5C87F89022FDA), QWord($8ED8B8C0991A945F),
    QWord($CF40C10841B90D6C), QWord($80F4F265A3D68295), QWord($F163669B673B6E74), QWord($D6012B81B39BB79A),
    QWord($3AD56BD0CC64F2D7), QWord($6497BA74EECAA7A0), QWord($AF5C8FE9E41C3B70), QWord($D658D0BEDD5F4FB2),
    QWord($5BD3A48419F36CD3), QWord($BF05FE0B7C822E14), QWord($5E289FD028330A6F), QWord($7FAF20355D9DF546),
    QWord($2385A661EB378F85), QWord($6C3C64E859D466D4), QWord($7B9A958E68EA55E2), QWord($A9E0901A88436E83),
    QWord($86A00465918DBD79), QWord($F15B171086DCA960), QWord($78F7A812703A3AA0), QWord($D86D278D0B030DC1),
    QWord($9845B2D26E56066E), QWord($29281E8D6135F90E), QWord($6E85C3E1E3F391AD), QWord($33AD175B764C99EB),
    QWord($61E9D7FFD8725DA2), QWord($21B7DB0500A53299), QWord($2F880AF58CFD395C), QWord($54A1D27E41A267DF),
    QWord($A2164DCEBC06DA4B), QWord($1B073DFB56FE939B), QWord($17F7503974FA2CD4), QWord($4D30E6F3B8AF66E6),
    QWord($CD33DA64109E6A66), QWord($A5DE441ADA7029CD), QWord($87FF248BD515301D), QWord($2692EE2107A8BCFC),
    QWord($D921539364E848BB), QWord($BFBB0037355A313C), QWord($303AA10EA1A1B4C2), QWord($D37981DA6858F6D8),
    QWord($6AFAA8080F4B3282), QWord($39BB2C389AA33FF8), QWord($6669EE8DDEF70BBF), QWord($21D9CC4ACA626926),
    QWord($5B47DFAA75C325DB), QWord($F7F390220C99B426), QWord($5B1D07A2900A83D5), QWord($D7CCC1259E5526EB),
    QWord($B3B0B7A96BF7884D), QWord($40FF77434D087133), QWord($8C210667F36FA608), QWord($E0EA4D4A9577E127),
    QWord($10F3AC04260E8616), QWord($405DFE51E0EEF9B6), QWord($3A27E95E67710143), QWord($ADE78E0546E539FC),
    QWord($DE8F33EF43979DF1), QWord($802AF2D2376437E3), QWord($679CFE92CD023AD9), QWord($DC82E76283DC4C08),
    QWord($98C94E6B3AA7E83D), QWord($B86598FE74D7396A), QWord($E75A17EAFC5ABC87), QWord($BD24FDCE56D4166F),
    QWord($C674ACFABE3B443A), QWord($9D3B7F64D6C71035), QWord($155D05517984566E), QWord($A310D669E0F0510B),
    QWord($160EFB654E237FF6), QWord($CC402C0AB00A1A6A), QWord($D92A4B0A5AB280D4), QWord($A9887C970C31ED35),
    QWord($CA9447EBCEE330CA), QWord($768DCB82D4A2B18D), QWord($7028116DC8A44676), QWord($FE1DA002E69FDA56),
    QWord($79D087F0742D2C55), QWord($0F04017B24C944A5), QWord($6561523B282FADD9), QWord($6060AE201039E082),
    QWord($575B97CF14452D06), QWord($DF901E7A5A1B6694), QWord($20CF2C098273D243), QWord($D5024729FAB3B903),
    QWord($8E771881A1B0460F), QWord($55D8034CD0D170AB), QWord($01C2A792E9CD902F), QWord($1E20776AF967D136),
    QWord($F07E378B5E366F61), QWord($D9D2DC6E8FEF95E4), QWord($741922BD9CB3F57A), QWord($A379DBC1687554EE),
    QWord($47A9A10331C2E095), QWord($2A0EA02DC1F6E395), QWord($DB97797CE0DD715E), QWord($D6D6CF017F143E67),
    QWord($EA0DBA00B2B20877), QWord($893CCB7CFF00405F), QWord($97C440DCCD6DDAFC), QWord($FEAA90892B727623),
    QWord($EDCEA4BFE988B0A8), QWord($B728A7F916D5EC00), QWord($13E1D51DFA05636D), QWord($8AEF400974FC0707),
    QWord($A149C32CDF8774FE), QWord($0FBDB93A761BF982), QWord($ADDD934F0AED69B7), QWord($91A680196F0B1AA9),
    QWord($94F489D18997FF15), QWord($E8DE8101CF16A5AF), QWord($94409AC12663F454), QWord($F95FD7899FE08CC7),
    QWord($510476542D5A83EF), QWord($88E1C061191518CC), QWord($87AB2FEC3351D9A4), QWord($47C04E17E896D142),
    QWord($853C71808408163C), QWord($BB57D210DB10E4AB), QWord($57AC49333A940FC0), QWord($89EB5DDB06FD0BEB),
    QWord($3C0A758D94DA73D9), QWord($B76383A603B810D1), QWord($39237C4B1F2CF83B), QWord($3302F1C5711EAF7A),
    QWord($9B402BF33C9AE5EA), QWord($E7AAA76F7E2559A5), QWord($CB71970C94555D16), QWord($56B8F2D2814D128D),
    QWord($40C36243DE7FEA10), QWord($3103206774B8F8E0), QWord($FC5F051B7DFD6622), QWord($1615A3E13ED78A79),
    QWord($BA6D1FCB88576B92), QWord($1703743AB31B17CA), QWord($2B4744AD4C32AA79), QWord($ED2B764D4EC841CD),
    QWord($B0E2495891F7CEAC), QWord($AF56EE02DBD67449), QWord($2A16069D634C773F), QWord($089534B56207CE32),
    QWord($C1F7411B5AC1C2A1), QWord($A267A9D566922D9B), QWord($456617AA6CB6BD6D), QWord($8B745FB301D6C5F1),
    QWord($4CED9A5F1AD65800), QWord($B0F7DE11FD6CB79C), QWord($EAC80EAE2F231162), QWord($E86C6D6D36B641A3),
    QWord($8FA8B25FDD101E56), QWord($17FD90456463570D), QWord($2A459DEF280428B5), QWord($84FF8A8B1C9C7A1E),
    QWord($C4131B9C46C58F73), QWord($C74DA225BEA51135), QWord($90C54753D8C2EB8C), QWord($3DE7E6BCAF828AC5),
    QWord($807C608DE42BB460), QWord($6FC8B32CD08386AA), QWord($6296C7200CA2C8D2), QWord($998A95F5D75DD04F),
    QWord($5B72EEF38E353E39), QWord($E563989D4FD74AF2), QWord($7DA65433AE511416), QWord($495A4D08E8BDA6F3),
    QWord($251C0FB1CF7DC4BE), QWord($20DF590F07E49CA0), QWord($54A05DBE6DA42DD7), QWord($D846B0E0B454E971),
    QWord($364499C239E60552), QWord($97B24AC50BF1080A), QWord($C22F0F3774E65E6D), QWord($F5AE335C6A286619),
    QWord($E5BB5D54BF41B52E), QWord($828C9DF52CAD1CB9), QWord($ACA48D5F26569929), QWord($DDC7E30D1EF3A048),
    QWord($DEDC9C339C3F402C), QWord($B5036326DD8D7A7E), QWord($7FA89B9DAF2DFF65), QWord($269D3BFF05CB599E),
    QWord($B5B1BFFA10B007B8), QWord($3009B729BA8B0136), QWord($19B02F619F3A0B64), QWord($691452237FD30257),
    QWord($0878A44A01E9DF91), QWord($7EF047F6042B5249), QWord($E81C45513F6F915F), QWord($B9E4760B60294400),
    QWord($16776CDECE0B193A), QWord($1B9D61DD64D2CF9F), QWord($56FCE4A79BC2A22C), QWord($BB56A2602F15D473),
    QWord($3223CFCD1AE02A49), QWord($8FE4148FCF8F4E23), QWord($8B23C12AF0F1FF9F), QWord($71ECDD934D038B22),
    QWord($D7DC05B9974E993B), QWord($7E93610091AAAC16), QWord($E131E265162F985C), QWord($C3890258DF389EEA),
    QWord($ACE6294D39D61FCF), QWord($925E00FF1CD3C77C), QWord($02A36DB0D4E31BD0), QWord($BFEF09E10E911A8E)  );

type
  TRange = record S, E: QWord; end;
  TRanges = record W: array of TRange; N: QWord; end;
  TRec = record Tag: Byte; Payload: QWord; end;
  TRecs = record W: array of TRec; N: QWord; end;

constructor EDedup.CreateCode(ACode: LongInt);
begin
  inherited Create('Dedup(' + IntToStr(ACode) + ')');
  Code := ACode;
end;

procedure DefaultDupParams(out P: TDupParams);
begin
  P.Avg := DEFAULT_AVG;
  P.MinChunk := DEFAULT_MIN;
  P.MaxChunk := DEFAULT_MAX;
  P.BufSize := DEFAULT_DUP_BUF_SIZE;
  P.HashAlgo := CDC_HASH_FNV;
end;

function ParamsValid(const P: TDupParams): Boolean;
begin
  Result := (P.Avg <> 0) and (P.MinChunk <> 0) and (P.MaxChunk >= P.MinChunk);
end;

procedure RPush(var R: TRanges; S, E: QWord);
begin
  if R.N >= QWord(Length(R.W)) then
  begin
    if Length(R.W) < 256 then SetLength(R.W, 256) else SetLength(R.W, Length(R.W) * 2);
  end;
  R.W[R.N].S := S;
  R.W[R.N].E := E;
  Inc(R.N);
end;

procedure RecPush(var R: TRecs; Tag: Byte; Payload: QWord);
begin
  if R.N >= QWord(Length(R.W)) then
  begin
    if Length(R.W) < 256 then SetLength(R.W, 256) else SetLength(R.W, Length(R.W) * 2);
  end;
  R.W[R.N].Tag := Tag;
  R.W[R.N].Payload := Payload;
  Inc(R.N);
end;

{ ---------------------------------------------------------------- CDC --- }

function GearLog2Floor(V: QWord): LongInt;
begin
  Result := 0;
  while V > 1 do
  begin
    V := V shr 1;
    Inc(Result);
  end;
end;

{ mezcla de 64 bits de span (bytes desde el ultimo corte), estilo splitmix64 }
function GearMixSpan(Span: QWord): QWord;
var x: QWord;
begin
  x := Span;
  x := x xor (x shr 33);
  x := x * QWord($FF51AFD7ED558CCD);
  x := x xor (x shr 33);
  x := x * QWord($C4CEB9FE1A85EC53);
  x := x xor (x shr 33);
  Result := x;
end;

procedure SplitFnv(const D: TBytes; Lo, Hi, Avg, MinChunk, MaxChunk: QWord; var Out_: TRanges);
var mask, start, h, i, span: QWord; useMask, boundary: Boolean;
begin
  if Lo >= Hi then Exit;
  mask := Avg - 1;
  useMask := (Avg > 0) and ((Avg and mask) = 0);
  start := Lo;
  h := 0;
  i := Lo;
  while i < Hi do
  begin
    h := h * CDC_PRIME + QWord(D[i]);
    span := i - start;
    if span < MinChunk then begin Inc(i); Continue; end;
    if span >= MaxChunk then
    begin
      RPush(Out_, start, i + 1);
      start := i + 1;
      h := 0;
      Inc(i);
      Continue;
    end;
    if useMask then boundary := (h and mask) = 0
    else boundary := (Avg > 0) and ((h mod Avg) = 0);
    if boundary then
    begin
      RPush(Out_, start, i + 1);
      start := i + 1;
      h := 0;
    end;
    Inc(i);
  end;
  if start < Hi then RPush(Out_, start, Hi);
end;

procedure SplitGear(const D: TBytes; Lo, Hi, Avg, MinChunk, MaxChunk: QWord; var Out_: TRanges);
var
  haveAvg, boundary: Boolean;
  maskBits, sb, lb: LongInt;
  maskS, maskL, escapeThreshold, escapeWinHi, start, h, i, span, winLo, winHi, window,
  progress, dec, escapeMask, test, m: QWord;
  startBits, bits: Int64;
begin
  if Lo >= Hi then Exit;
  haveAvg := Avg > 0;
  if haveAvg then maskBits := GearLog2Floor(Avg) else maskBits := 0;
  sb := maskBits + GEAR_DELTA_S;
  if sb >= 63 then maskS := High(QWord) else maskS := (QWord(1) shl sb) - 1;
  { al menos 1: debajo de --chunk-avg=64 una mascara de 0 bits haria el
    test span >= avg siempre verdadero }
  if maskBits - GEAR_DELTA_L < 1 then lb := 1 else lb := maskBits - GEAR_DELTA_L;
  maskL := (QWord(1) shl lb) - 1;
  escapeThreshold := (MaxChunk div 4) * 3;
  if MaxChunk >= 2 then escapeWinHi := MaxChunk - 1 else escapeWinHi := escapeThreshold + 1;

  start := Lo;
  h := 0;
  i := Lo;
  while i < Hi do
  begin
    h := (h shl 1) + GEAR_TABLE[D[i]];
    span := i - start;
    if span < MinChunk then begin Inc(i); Continue; end;
    if span >= MaxChunk then
    begin
      RPush(Out_, start, i + 1);
      start := i + 1;
      h := 0;
      Inc(i);
      Continue;
    end;
    boundary := False;
    if haveAvg then
    begin
      if span >= escapeThreshold then
      begin
        winLo := escapeThreshold;
        if winLo < escapeWinHi then winHi := escapeWinHi else winHi := winLo + 1;
        window := winHi - winLo;
        if span > winLo then progress := span - winLo else progress := 0;
        startBits := 4;
        if (lb >= 0) and (Int64(lb) < startBits) then startBits := lb;
        dec := (progress * QWord(startBits + 1)) div (window + 1);
        bits := startBits - Int64(dec);
        if bits < 0 then bits := 0;
        if bits <= 0 then escapeMask := 0 else escapeMask := (QWord(1) shl bits) - 1;
        test := h xor GearMixSpan(span);
        m := escapeMask;
      end
      else
      begin
        test := h;
        if span < Avg then m := maskS else m := maskL;
      end;
      boundary := (test and m) = 0;
    end;
    if boundary then
    begin
      RPush(Out_, start, i + 1);
      start := i + 1;
      h := 0;
    end;
    Inc(i);
  end;
  if start < Hi then RPush(Out_, start, Hi);
end;

procedure SplitBuffer(const D: TBytes; Lo, Hi: QWord; const P: TDupParams; var Out_: TRanges);
begin
  if P.HashAlgo = CDC_HASH_GEAR then SplitGear(D, Lo, Hi, P.Avg, P.MinChunk, P.MaxChunk, Out_)
  else SplitFnv(D, Lo, Hi, P.Avg, P.MinChunk, P.MaxChunk, Out_);
end;

{ ------------------------------------------------------------- hashes --- }

function WordLE(const D: TBytes; At: QWord): QWord; inline;
var i: LongInt;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or QWord(D[At + QWord(i)]);
end;

{ memcpy(&tail, p, n) con n < 8: little-endian, relleno con ceros }
function TailLE(const D: TBytes; At, N: QWord): QWord;
var i: QWord;
begin
  Result := 0;
  i := N;
  while i > 0 do
  begin
    Dec(i);
    Result := (Result shl 8) or QWord(D[At + i]);
  end;
end;

function ChunkHash(const D: TBytes; At, N: QWord): QWord;
var h, i: QWord;
begin
  h := QWord($9E3779B97F4A7C15);
  i := 0;
  while i + 8 <= N do
  begin
    h := h xor WordLE(D, At + i);
    h := h * QWord($9E3779B97F4A7C15);
    h := h xor (h shr 32);
    Inc(i, 8);
  end;
  h := h xor TailLE(D, At + i, N - i);
  h := h * QWord($C2B2AE3D27D4EB4F);
  h := h xor (h shr 29);
  Result := h;
end;

function ChunkHashAlt(const D: TBytes; At, N: QWord): QWord;
var h, i: QWord;
begin
  h := QWord($D1B54A32D192ED03);
  i := 0;
  while i + 8 <= N do
  begin
    h := h xor (WordLE(D, At + i) * QWord($C2B2AE3D27D4EB4F));
    h := (h shl 27) or (h shr 37);
    h := h * QWord($165667B19E3779F9);
    Inc(i, 8);
  end;
  h := h xor TailLE(D, At + i, N - i);
  h := h * QWord($9E3779B97F4A7C15);
  h := h xor (h shr 31);
  Result := h;
end;

{ --------------------------------------- el mapa de claves de 128 bits --- }

type
  TSeenSlot = record
    K1, K2, V: QWord;
    Used: Boolean;
  end;
  TSeen = record
    S: array of TSeenSlot;
    Count: QWord;
  end;

procedure SeenInit(out M: TSeen);
begin
  SetLength(M.S, 1024);
  M.Count := 0;
end;

function SeenSlot(const M: TSeen; K1, K2: QWord): QWord;
var mask, h: QWord;
begin
  mask := QWord(Length(M.S)) - 1;
  h := (K1 xor (K2 * QWord($9E3779B97F4A7C15))) and mask;
  while M.S[h].Used and not ((M.S[h].K1 = K1) and (M.S[h].K2 = K2)) do
    h := (h + 1) and mask;
  Result := h;
end;

function SeenGet(const M: TSeen; K1, K2: QWord; out V: QWord): Boolean;
var h: QWord;
begin
  h := SeenSlot(M, K1, K2);
  Result := M.S[h].Used;
  if Result then V := M.S[h].V;
end;

{ insert: con la clave ya presente, la pisa (como HashMap::insert) }
procedure SeenPut(var M: TSeen; K1, K2, V: QWord);
var h, i: QWord; old: array of TSeenSlot;
begin
  if (M.Count + 1) * 2 > QWord(Length(M.S)) then
  begin
    old := M.S;
    M.S := nil;
    SetLength(M.S, Length(old) * 2);
    M.Count := 0;
    i := 0;
    while i < QWord(Length(old)) do
    begin
      if old[i].Used then SeenPut(M, old[i].K1, old[i].K2, old[i].V);
      Inc(i);
    end;
  end;
  h := SeenSlot(M, K1, K2);
  if not M.S[h].Used then Inc(M.Count);
  M.S[h].K1 := K1;
  M.S[h].K2 := K2;
  M.S[h].V := V;
  M.S[h].Used := True;
end;

{ -------------------------------------------------------------- codec --- }

procedure PutLE32(var B: TBytes; At: QWord; V: DWord);
begin
  B[At] := Byte(V); B[At + 1] := Byte(V shr 8); B[At + 2] := Byte(V shr 16); B[At + 3] := Byte(V shr 24);
end;

procedure PutLE64(var B: TBytes; At, V: QWord);
var i: LongInt;
begin
  for i := 0 to 7 do B[At + QWord(i)] := Byte(V shr (8 * i));
end;

function GetLE32(const B: TBytes; At: QWord): DWord;
begin
  Result := DWord(B[At]) or (DWord(B[At + 1]) shl 8) or (DWord(B[At + 2]) shl 16) or (DWord(B[At + 3]) shl 24);
end;

function GetLE64(const B: TBytes; At: QWord): QWord;
begin
  Result := WordLE(B, At);
end;

{ LEB128 sin signo de dedup.rs: a diferencia del de v5, solo corta por shift > 63 }
function VarintDecode(const B: TBytes; At: QWord; out V: QWord; out Used: QWord): LongInt;
var shift: LongInt; n: QWord; c: Byte;
begin
  V := 0;
  shift := 0;
  n := 0;
  while At + n < QWord(Length(B)) do
  begin
    c := B[At + n];
    V := V or (QWord(c and $7F) shl shift);
    if (c and $80) = 0 then
    begin
      Used := n + 1;
      Exit(DEDUP_OK);
    end;
    Inc(shift, 7);
    if shift > 63 then Exit(DEDUP_ERR_BAD_VARINT);
    Inc(n);
  end;
  Result := DEDUP_ERR_TRUNCATED;
end;

{ parse_meta: valida la cabecera y la tabla }
procedure ParseMeta(const Meta: TBytes; var Recs: TRecs; out UniqueCount: QWord);
var chunkCount, pos, k, v, used: QWord; tag: Byte; e: LongInt;
begin
  Recs.N := 0;
  if QWord(Length(Meta)) < DUP_HEADER_SIZE then raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
  if GetLE32(Meta, 0) <> DUP_MAGIC then raise EDedup.CreateCode(DEDUP_ERR_BAD_MAGIC);
  if GetLE32(Meta, 4) <> DUP_VERSION then raise EDedup.CreateCode(DEDUP_ERR_BAD_VER);
  chunkCount := GetLE64(Meta, 8);
  UniqueCount := GetLE64(Meta, 16);
  { cada record ocupa al menos 2 bytes: un UINT64_MAX corrupto no reserva sin limite }
  if chunkCount > (QWord(Length(Meta)) - DUP_HEADER_SIZE) div 2 then
    raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
  if UniqueCount > chunkCount then raise EDedup.CreateCode(DEDUP_ERR_BAD_REF);
  pos := DUP_HEADER_SIZE;
  k := 0;
  while k < chunkCount do
  begin
    if pos >= QWord(Length(Meta)) then raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
    tag := Meta[pos];
    Inc(pos);
    if tag = TAG_UNIQUE then
    begin
      if pos + 4 > QWord(Length(Meta)) then raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
      v := QWord(GetLE32(Meta, pos));
      Inc(pos, 4);
    end
    else if tag = TAG_REF then
    begin
      e := VarintDecode(Meta, pos, v, used);
      if e <> DEDUP_OK then raise EDedup.CreateCode(e);
      if v >= UniqueCount then raise EDedup.CreateCode(DEDUP_ERR_BAD_REF);
      Inc(pos, used);
    end
    else
      raise EDedup.CreateCode(DEDUP_ERR_BAD_TAG);
    RecPush(Recs, tag, v);
    Inc(k);
  end;
end;

{ ---------------------------------------------------------- streaming --- }

function ReadSome(S: TStream; var B: TBytes; N: QWord): QWord;
begin
  { read_fill: llena el buffer como un fread. El llamador toma got < buf por
    fin de la entrada, asi que una lectura corta (un pipe, mas de 2 GiB) no
    puede cortar ahi. }
  if N = 0 then Exit(0);
  Result := ReadUpTo(S, B[0], N);
end;

function EncodeStreaming(const InPath, BodyPath: AnsiString; const P: TDupParams;
                         Paranoid: Boolean): TBytes;
var
  fi, fb: TFileStream;
  effectiveBuf, got, ci, clen, uidx, bodyPos, uniqueCount, tableSize, v, pos, n: QWord;
  work, cmpBuf: TBytes;
  chunks: TRanges;
  recs: TRecs;
  seen: TSeen;
  k1, k2: QWord;
  isDup: Boolean;
  uniqueOff: array of QWord;
  uniqueLen: array of DWord;
  tmp: array[0..9] of Byte;
begin
  if not ParamsValid(P) then raise EDedup.CreateCode(DEDUP_ERR_INVAL);
  fi := nil; fb := nil;
  try
    try
      fi := TFileStream.Create(InPath, fmOpenRead or fmShareDenyNone);
      fb := TFileStream.Create(BodyPath, fmCreate);
    except
      raise EDedup.CreateCode(DEDUP_ERR_INVAL);
    end;
    if P.BufSize > 0 then effectiveBuf := P.BufSize else effectiveBuf := QWord(8) shl 20;
    SetLength(work, effectiveBuf);
    recs.N := 0;
    SeenInit(seen);
    uniqueCount := 0;
    bodyPos := 0;
    SetLength(uniqueOff, 0);
    SetLength(uniqueLen, 0);
    while True do
    begin
      got := ReadSome(fi, work, effectiveBuf);
      if got = 0 then Break;
      chunks.N := 0;
      SplitBuffer(work, 0, got, P, chunks);
      ci := 0;
      while ci < chunks.N do
      begin
        clen := chunks.W[ci].E - chunks.W[ci].S;
        k1 := ChunkHash(work, chunks.W[ci].S, clen);
        k2 := ChunkHashAlt(work, chunks.W[ci].S, clen);
        isDup := SeenGet(seen, k1, k2, uidx);
        if Paranoid and isDup then
        begin
          if QWord(uniqueLen[uidx]) <> clen then isDup := False
          else
          begin
            if QWord(Length(cmpBuf)) < clen then SetLength(cmpBuf, clen);
            fb.Seek(Int64(uniqueOff[uidx]), soBeginning);
            ReadExact(fb, cmpBuf[0], clen);
            fb.Seek(Int64(bodyPos), soBeginning);
            if not CompareMem(@cmpBuf[0], @work[chunks.W[ci].S], clen) then isDup := False;
          end;
        end;
        if isDup then
        begin
          RecPush(recs, TAG_REF, uidx);
          Inc(ci);
          Continue;
        end;
        SeenPut(seen, k1, k2, uniqueCount);
        RecPush(recs, TAG_UNIQUE, clen);
        if Paranoid then
        begin
          SetLength(uniqueOff, Length(uniqueOff) + 1);
          uniqueOff[High(uniqueOff)] := bodyPos;
          SetLength(uniqueLen, Length(uniqueLen) + 1);
          uniqueLen[High(uniqueLen)] := DWord(clen);
        end;
        WriteAll(fb, work[chunks.W[ci].S], clen);
        bodyPos := bodyPos + clen;
        Inc(uniqueCount);
        Inc(ci);
      end;
      if got < effectiveBuf then Break;
    end;
  finally
    fb.Free;
    fi.Free;
  end;

  tableSize := 0;
  n := 0;
  while n < recs.N do
  begin
    Inc(tableSize);
    if recs.W[n].Tag = TAG_UNIQUE then Inc(tableSize, 4)
    else
    begin
      v := recs.W[n].Payload;
      repeat
        Inc(tableSize);
        v := v shr 7;
      until v = 0;
    end;
    Inc(n);
  end;
  SetLength(Result, DUP_HEADER_SIZE + tableSize);
  PutLE32(Result, 0, DUP_MAGIC);
  PutLE32(Result, 4, DUP_VERSION);
  PutLE64(Result, 8, recs.N);
  PutLE64(Result, 16, uniqueCount);
  pos := DUP_HEADER_SIZE;
  n := 0;
  while n < recs.N do
  begin
    Result[pos] := recs.W[n].Tag;
    Inc(pos);
    if recs.W[n].Tag = TAG_UNIQUE then
    begin
      PutLE32(Result, pos, DWord(recs.W[n].Payload));
      Inc(pos, 4);
    end
    else
    begin
      v := recs.W[n].Payload;
      k1 := 0;
      while v >= $80 do
      begin
        tmp[k1] := Byte((v and $7F) or $80);
        v := v shr 7;
        Inc(k1);
      end;
      tmp[k1] := Byte(v);
      Inc(k1);
      Move(tmp[0], Result[pos], k1);
      Inc(pos, k1);
    end;
    Inc(n);
  end;
end;

procedure DecodeStreaming(const Meta: TBytes; const BodyPath, OutPath: AnsiString);
var
  recs: TRecs;
  uniqueCount, n, need, take, outPos, readAt, writeAt, remaining, uidx: QWord;
  fb, fo: TFileStream;
  slotOff: array of QWord;
  slotLen: array of DWord;
  nslots: QWord;
  ioBuf: TBytes;
begin
  ParseMeta(Meta, recs, uniqueCount);
  fb := nil; fo := nil;
  try
    try
      fb := TFileStream.Create(BodyPath, fmOpenRead or fmShareDenyNone);
      fo := TFileStream.Create(OutPath, fmCreate);
    except
      raise EDedup.CreateCode(DEDUP_ERR_INVAL);
    end;
    SetLength(slotOff, 0);
    SetLength(slotLen, 0);
    nslots := 0;
    outPos := 0;
    SetLength(ioBuf, 64 * 1024);
    n := 0;
    while n < recs.N do
    begin
      if recs.W[n].Tag = TAG_UNIQUE then
      begin
        need := recs.W[n].Payload;
        while need > 0 do
        begin
          take := need;
          if take > QWord(Length(ioBuf)) then take := Length(ioBuf);
          if QWord(fb.Read(ioBuf[0], LongInt(take))) <> take then
            raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
          fo.WriteBuffer(ioBuf[0], LongInt(take));
          Dec(need, take);
        end;
        if nslots >= QWord(Length(slotOff)) then
        begin
          SetLength(slotOff, Length(slotOff) * 2 + 64);
          SetLength(slotLen, Length(slotOff));
        end;
        slotOff[nslots] := outPos;
        slotLen[nslots] := DWord(recs.W[n].Payload);
        Inc(nslots);
        outPos := outPos + recs.W[n].Payload;
      end
      else
      begin
        uidx := recs.W[n].Payload;
        { una referencia tiene que apuntar a un chunk ya visto }
        if uidx >= nslots then raise EDedup.CreateCode(DEDUP_ERR_BAD_REF);
        readAt := slotOff[uidx];
        writeAt := outPos;
        remaining := slotLen[uidx];
        while remaining > 0 do
        begin
          take := remaining;
          if take > QWord(Length(ioBuf)) then take := Length(ioBuf);
          fo.Seek(Int64(readAt), soBeginning);
          if QWord(fo.Read(ioBuf[0], LongInt(take))) <> take then
            raise EDedup.CreateCode(DEDUP_ERR_TRUNCATED);
          fo.Seek(Int64(writeAt), soBeginning);
          fo.WriteBuffer(ioBuf[0], LongInt(take));
          readAt := readAt + take;
          writeAt := writeAt + take;
          Dec(remaining, take);
        end;
        outPos := writeAt;
      end;
      Inc(n);
    end;
  finally
    fo.Free;
    fb.Free;
  end;
end;

end.
