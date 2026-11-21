#!/bin/bash
# Coverage-guided fuzzing of OREP with AFL++ in frida_mode (binary-only
# coverage: FPC code cannot be instrumented at compile time).  The harness is
# tests/orep_afl.lpr; see its header for the four modes.
#
#   AFL=<AFLplusplus dir> tests/orep_afl.sh build <work>
#       builds <work>/bin/orep_afl (fuzzed) and <work>/bin/orep_afl_chk (cmem
#       + range checks, for the replay), and <work>/seeds
#   AFL=... tests/orep_afl.sh run <work> <seconds> [instances]
#       one main instance in fork mode (stable) and the rest in persistent
#       mode (about 4x faster, less stable); output in <work>/camp
#   tests/orep_afl.sh replay <work>
#       every queue entry, crash and hang through orep_afl_chk under
#       valgrind memcheck
#
# AFL needs AFL=<dir> with afl-fuzz and afl-frida-trace.so built
# (make source-only; make -C frida_mode).  Needs a dynamically linked
# harness (it uses cthreads), since frida is injected with LD_PRELOAD.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD=${1:?usage: orep_afl.sh build|run|replay <work> ...}
WK=${2:?work dir}
mkdir -p "$WK"
WK=$(cd "$WK" && pwd)

build() {
  mkdir -p "$WK/bin/nat" "$WK/chk/src" "$WK/chk/u" "$WK/seeds" "$WK/gen"
  gcc -O2 -fno-builtin -ffreestanding -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-pic -fno-tree-loop-distribute-patterns \
    -c "$ROOT/src/c/orep_core.c" -o "$WK/bin/nat/orep_core.o" || exit 1
  fpc -O3 -gl -Fu"$ROOT/src/orep" -Fo"$WK/bin/nat" -FU"$WK/bin/nat" \
    -o"$WK/bin/orep_afl" "$ROOT/tests/orep_afl.lpr" >"$WK/bin/fpc.log" 2>&1 ||
    { cat "$WK/bin/fpc.log"; exit 1; }
  # replay build: libc malloc (valgrind sees the blocks) and range checks
  cp "$ROOT"/src/orep/*.pas "$WK/chk/src/"
  sed -i 's/^{\$Q-}{\$R-}/{$Q-}{$R+}/' "$WK/chk/src/orep.pas"
  sed 's/^  cthreads, BaseUnix/  cmem, cthreads, BaseUnix/; s/^{\$Q-}{\$R-}/{$Q-}{$R+}/' \
    "$ROOT/tests/orep_afl.lpr" > "$WK/chk/orep_afl_chk.lpr"
  (cd "$WK/chk" && fpc -O1 -gl -Cr -Ct -Fusrc -Fo"$WK/bin/nat" -FUu \
    -o"$WK/bin/orep_afl_chk" orep_afl_chk.lpr >"$WK/chk/fpc.log" 2>&1) ||
    { cat "$WK/chk/fpc.log"; exit 1; }
  # seeds: the pinned streams (decode modes), oracle-made streams, and
  # round-trip inputs
  python3 "$ROOT/tests/orep_spec.py" gen --seed 77 --n 120 --dir "$WK/gen" >/dev/null
  python3 - "$ROOT" "$WK" <<'EOF'
import glob, os, random, sys
root, wk = sys.argv[1], sys.argv[2]
random.seed(5)
k = 0
def put(b):
    global k
    open('%s/seeds/s%04d' % (wk, k), 'wb').write(b)
    k += 1
for f in sorted(glob.glob(root + '/tests/fixtures/orep4/*.orp')):
    s = open(f, 'rb').read()
    for m in range(3):
        put(bytes([m, random.randrange(256)]) + s)
gen = [open(f, 'rb').read() for f in sorted(glob.glob(wk + '/gen/*'))
       if os.path.isfile(f)]
for g in [g for g in gen if len(g) < 32768][:60]:
    put(bytes([random.randrange(3), random.randrange(256)]) + g)
ins = [open(root + '/tests/fixtures/orep4/make_inputs.py', 'rb').read(),
       bytes(3000), bytes(range(256)) * 20]
for d in ins:
    for j in range(3):
        put(bytes([3]) + bytes(random.randrange(256) for _ in range(8)) + d[:20000])
EOF
  printf '%s\n' 'magic="OREP"' 'ver="OREP\x04"' 'hdr="OREP\x04\x10"' \
    'z="\x00\x00\x00\x00"' 'ff="\xff\xff\xff\xff\x0f"' 'v80="\x80\x80\x80\x80"' \
    > "$WK/orep.dict"
  local n=0 s
  for s in "$WK"/seeds/*; do
    "$WK/bin/orep_afl" "$s" >/dev/null || n=$((n + 1))
    "$WK/bin/orep_afl_chk" "$s" >/dev/null || n=$((n + 1))
  done
  [ $n -eq 0 ] || { echo "$n seed runs failed"; exit 1; }
  echo "built; $(ls "$WK/seeds" | wc -l) seeds"
}

fuzz1() { # fuzz1 <name> <-M|-S> <persistent 0/1> <secs>
  (
    export AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
    export AFL_NO_UI=1 AFL_PATH="$AFL"
    if [ "$3" = 1 ]; then
      AFL_FRIDA_PERSISTENT_ADDR=0x$(nm "$WK/bin/orep_afl" | awk '/ orep_afl_one$/{print $1}')
      export AFL_FRIDA_PERSISTENT_ADDR AFL_ENTRYPOINT=$AFL_FRIDA_PERSISTENT_ADDR
      export AFL_FRIDA_PERSISTENT_CNT=1000
    fi
    ulimit -f 200000
    exec "$AFL/afl-fuzz" -O "$2" "$1" -x "$WK/orep.dict" -i "$WK/seeds" \
      -o "$WK/camp" -V "$4" -t 2000 -m none -- "$WK/bin/orep_afl" @@
  ) > "$WK/camp-$1.log" 2>&1
}

run() {
  : "${AFL:?set AFL to the AFLplusplus directory}"
  local secs=${1:?seconds} n=${2:-8} i
  fuzz1 m0 -M 0 "$secs" &
  for i in $(seq 1 $((n - 1))); do fuzz1 "p$i" -S 1 "$secs" & done
  wait
  stats
}

stats() {
  local d
  for d in "$WK"/camp/*/; do
    printf '%s: ' "$(basename "$d")"
    awk -F' *: ' '/^(execs_done|corpus_count|edges_found|saved_crashes|saved_hangs|stability)/{printf "%s=%s ", $1, $2}' "$d/fuzzer_stats"
    echo
  done
}

replay1() { # replay1 <file>: prints FAIL lines
  local e
  e=$(mktemp "$WK/replay.XXXXXX")
  if ! timeout 300 valgrind -q --error-exitcode=99 --leak-check=no \
      "$WK/bin/orep_afl_chk" "$1" >/dev/null 2>"$e"; then
    echo "FAIL $1"; head -20 "$e"
  fi
  rm -f "$e"
}

replay() { # unique files (by content), 4 at a time
  local list=$WK/replay.list
  find "$WK/camp" -type f \( -path '*/queue/id:*' -o -path '*/crashes/id:*' \
    -o -path '*/hangs/id:*' \) -print0 | xargs -0 sha256sum |
    sort -k1,1 -u | cut -c67- > "$list"
  export WK
  export -f replay1
  tr '\n' '\0' < "$list" | xargs -0 -P 4 -n 1 bash -c 'replay1 "$0"' > "$WK/replay.out"
  local n bad
  n=$(wc -l < "$list"); bad=$(grep -c '^FAIL' "$WK/replay.out")
  cat "$WK/replay.out"
  echo "replay: $n unique files, $bad failures"
  [ "$bad" -eq 0 ]
}

case $CMD in
  build) build ;;
  run) run "${3:?seconds}" "${4:-8}" ;;
  stats) stats ;;
  replay) replay ;;
  *) echo "unknown command $CMD"; exit 2 ;;
esac
