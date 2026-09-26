unit Help;
{ `--version` and `--help`, byte-for-byte what the C++ prints and the Rust port
  reproduces (`crates/osrep-cli/src/help.rs`, `dup_wrapper.cpp:412-472`).

  A drop-in replacement that prints a different synopsis is a worse drop-in, so
  this is reproduced rather than rewritten. `tests/pascal_cli_conformance.sh`
  diffs it against the shipped Rust binary and fails on a single byte. }

{$MODE OBJFPC}{$H+}
interface

const
  { Kept in step with the released version. The Pascal port reports the same
    line as the Rust one while it is being validated against it; once it is
    what ships, this is what a release bumps. }
  VERSION     = '2.1.0';
  RELEASE_DATE = 'September 22, 2026';
  DESCRIPTION = 'huge-dictionary LZ77 preprocessor (Omega lineage, fork of SREP by Bulat Ziganshin)';
  HOMEPAGE    = 'https://github.com/YadeWira/omega-srep';

function VersionLine: AnsiString;
function HelpText: AnsiString;

implementation

function VersionLine: AnsiString;
begin
  Result := 'Omega SREP ' + VERSION + ' (' + RELEASE_DATE + ')';
end;

{ The synopsis, line by line. LF only -- see Out.WriteRaw for why this never
  goes through a text file. }
function HelpText: AnsiString;
const
  LF = #10;
begin
  Result :=
    VersionLine + LF +
    DESCRIPTION + LF +
    HOMEPAGE + LF +
    LF +
    'Usage:' + LF +
    '  osrep [options] -mN  input  output       compress' + LF +
    '  osrep [options] -d   archive output      decompress' + LF +
    '  osrep -i archive                         show archive info' + LF +
    '  osrep --verify archive                   check it without unpacking' + LF +
    LF +
    'Compression methods:' + LF +
    '  -m0       REP only (in-memory; works with -dBYTES)' + LF +
    '  -m1, -m2  Content-defined chunking (CDC)' + LF +
    '  -m3       Digest-comparison match search (default)' + LF +
    '  -m4       Full match search (best ratio for general data)' + LF +
    '  -m5       Exhaustive match search (slowest, best ratio)' + LF +
    LF +
    'Common options:' + LF +
    '  -lN, -cN          minimum-match / chunk-size tuning' + LF +
    '  -bN               buffer size (default 8mb)' + LF +
    '  -dBYTES           dictionary size for -m0' + LF +
    '  -hash=NAME        select hash (vmac, sha1, ...)' + LF +
    '  -mmap, -nommap    enable/disable POSIX mmap reads' + LF +
    '  -temp=PATH        tempfile path override' + LF +
    '  --format=v4|v5    container to write (default v5). v4 is the' + LF +
    '                    container the 1.0.x releases read, kept for' + LF +
    '                    interoperability; both are always readable.' + LF +
    '  --seed=N          deterministic hash seed (uint64; default is' + LF +
    '                    random per-run). Same seed + same input ->' + LF +
    '                    byte-identical archive. Useful for content-' + LF +
    '                    addressed storage and reproducible builds.' + LF +
    '  -bar              emit "PROGRESS <done> <total>" to stderr every' + LF +
    '                    ~0.5s, plus a guaranteed final line at' + LF +
    '                    done==total. Machine-parseable, for wrapping' + LF +
    '                    osrep as a subprocess.' + LF +
    LF +
    'Dedup pre-pass (Omega F5):' + LF +
    '  -dup              enable FA-style dedup pre-pass' + LF +
    '  --dup-paranoid    byte-compare on every dedup hit (slower, no' + LF +
    '                    silent corruption on 64-bit hash collision)' + LF +
    '  --chunk-avg=N     CDC average chunk size (default 4096)' + LF +
    '  --chunk-min=N     CDC minimum chunk size (default 1024)' + LF +
    '  --chunk-max=N     CDC maximum chunk size (default 16384)' + LF +
    '  --chunk-buf=N     buffer-bounded CDC, bytes (default 8388608)' + LF +
    '  --chunk-hash=NAME CDC boundary hash: fnv (default) or gear.' + LF +
    '                    gear = Gear-hash CDC with an implicit ~64-byte' + LF +
    '                    content window (FastCDC-style normalized' + LF +
    '                    chunking); finds non-buffer-aligned duplicates' + LF +
    '                    that fnv''s unwindowed rolling hash misses.' + LF +
    '                    Opt-in; does not change the .dupref format.' + LF +
    LF +
    'Accepted and not acted on:' + LF +
    '  -tN               the implementation is single-threaded per block,' + LF +
    '                    so there is no worker count to set' + LF +
    '  -aN[/M]           accelerator sizing; allocates nothing here' + LF +
    '  -mmap, -nommap    mmap reads' + LF +
    '  -ia-, -ia+        I/O acceleration' + LF +
    '  -slp, -slp-       large-page mode' + LF +
    '  -pc[N]            progress counters' + LF +
    '  These are parsed and validated so scripts written against the' + LF +
    '  1.0.x C++ keep working unchanged. None of them changes the' + LF +
    '  archive: that was measured before the port, not assumed.' + LF +
    LF +
    'Checking:' + LF +
    '  --verify          v5 only: check an archive''s framing, CRCs and' + LF +
    '                    records without decompressing it. Catches' + LF +
    '                    truncation and framing damage in the time it' + LF +
    '                    takes to read the file. It does NOT cover the' + LF +
    '                    stored block bytes -- damage inside a literal' + LF +
    '                    run still needs a -d. v1-v4 carry no checksum' + LF +
    '                    at all and are refused.' + LF +
    LF +
    'Help:' + LF +
    '  --help, -h, -?    this synopsis' + LF +
    '  --version, -V     version line' + LF +
    LF +
    'Project page: https://github.com/YadeWira/omega-srep' + LF;
end;

end.
