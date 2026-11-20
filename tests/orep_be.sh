#!/bin/bash
# OREP on a big-endian CPU (powerpc64 BE, ELFv1) under qemu-user.
#
# Cross-builds the reference CLI (all Pascal, -dOREP_NO_NATIVE) and, when a BE
# gcc is there, the native one (src/c/orep_core.c), then checks against the
# host (x86_64) build:
#   - the BE encoder writes the same bytes as the host for several inputs and
#     options (and -t1 == -t3 on BE);
#   - BE decodes host streams and the host decodes BE streams;
#   - corrupt and truncated streams are rejected by the BE decoder without a
#     crash and never decode to wrong data.
#
#   OREP_BE_TOOLS=<dir> tests/orep_be.sh [host build dir]
#
# Skips (exit 0) when the toolchain or qemu is absent. Environment:
#   OREP_BE_TOOLS   toolchain dir, laid out as
#                     lib/fpc/3.2.2/ppcppc64            FPC 3.2.2 cross compiler
#                     lib/fpc/3.2.2/units/powerpc64-linux/  RTL (+ csu_stub.o)
#                     bin-ppc64/powerpc64-linux-{as,ld,nm,...}  binutils
#                     bin-ppc64/powerpc64-linux-gnu-gcc  (optional) BE gcc
#                     sysroot/usr/powerpc64-linux-gnu/   glibc for the target
#                   (how it was made: see the comment at the end of this file)
#   OREP_BE_BIN     instead of building: a dir with prebuilt BE orep-ref
#                   (and optionally orep)
#   OREP_BE_QEMU    emulator, default qemu-ppc64
#   OREP_BE_NATIVE  0 = do not build/check the BE native (C core) binary
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=${OREP_BE_TOOLS:-}
QEMU=${OREP_BE_QEMU:-qemu-ppc64}
skip() { echo "orep_be: SKIP: $*"; exit 0; }
command -v "$QEMU" >/dev/null 2>&1 || skip "$QEMU not found"
if [ -n "${OREP_BE_BIN:-}" ]; then
  [ -x "$OREP_BE_BIN/orep-ref" ] || skip "no $OREP_BE_BIN/orep-ref"
  [ -n "$T" ] || skip "OREP_BE_TOOLS (for the sysroot) not set"
else
  [ -n "$T" ] || skip "OREP_BE_TOOLS not set"
  [ -x "$T/lib/fpc/3.2.2/ppcppc64" ] || skip "no $T/lib/fpc/3.2.2/ppcppc64"
  [ -x "$T/bin-ppc64/powerpc64-linux-ld" ] || skip "no binutils in $T/bin-ppc64"
fi
SYS=$T/sysroot
[ -d "$SYS/usr/powerpc64-linux-gnu/lib" ] || skip "no glibc in $SYS"
Q=("$QEMU" -L "$SYS/usr/powerpc64-linux-gnu")

W=${TMPDIR:?set TMPDIR}/orep-be.$$
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
ulimit -f 4000000
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# ---- builds ----------------------------------------------------------------
H=${1:-}
if [ -z "$H" ]; then
  H=$W/host
  "$ROOT/scripts/build_orep.sh" "$H" >/dev/null || { echo "host build failed"; exit 1; }
fi
if [ -n "${OREP_BE_BIN:-}" ]; then
  BE=$OREP_BE_BIN
else
  BE=$W/be
  mkdir -p "$BE/ref" "$BE/nat"
  X=$T/lib/fpc/3.2.2
  U=$X/units/powerpc64-linux
  FPC=("$X/ppcppc64" -Tlinux -Ppowerpc64 -XPpowerpc64-linux- -FD"$T/bin-ppc64"
       -XR"$SYS" -k--sysroot="$SYS" -Fl"$SYS/usr/powerpc64-linux-gnu/lib"
       -Fu"$U" -O3 -Xs)
  GCCLIB=$(ls -d "$SYS"/usr/lib/gcc-cross/powerpc64-linux-gnu/* 2>/dev/null | tail -1)
  [ -n "$GCCLIB" ] && FPC+=(-Fl"$GCCLIB")
  # FPC 3.2.2's si_c.o references __libc_csu_init/fini, gone since glibc 2.34
  [ -f "$U/csu_stub.o" ] && FPC+=(-k"$U/csu_stub.o")
  "${FPC[@]}" -dOREP_NO_NATIVE -Fu"$ROOT/src/orep" -FU"$BE/ref" \
    -o"$BE/orep-ref" "$ROOT/src/orep/orep_cli.lpr" >"$BE/ref/fpc.log" 2>&1 ||
    { tail -20 "$BE/ref/fpc.log"; echo "FAIL: BE reference build"; exit 1; }
  CC=$T/bin-ppc64/powerpc64-linux-gnu-gcc
  if [ "${OREP_BE_NATIVE:-1}" != 0 ] && [ -x "$CC" ]; then
    "$CC" -O2 -fno-builtin -ffreestanding -fno-stack-protector \
      -fno-asynchronous-unwind-tables -fno-pic -fno-tree-loop-distribute-patterns \
      -c "$ROOT/src/c/orep_core.c" -o "$BE/nat/orep_core.o" &&
    "${FPC[@]}" -Fu"$ROOT/src/orep" -Fo"$BE/nat" -Fl"$BE/nat" -FU"$BE/nat" \
      -o"$BE/orep" "$ROOT/src/orep/orep_cli.lpr" >"$BE/nat/fpc.log" 2>&1 ||
      { tail -20 "$BE/nat/fpc.log"; bad "BE native build"; rm -f "$BE/orep"; }
  fi
fi
file "$BE/orep-ref" 2>/dev/null | grep -q 'MSB' || bad "$BE/orep-ref is not a big-endian ELF"
BINS="orep-ref"
[ "${OREP_BE_NATIVE:-1}" != 0 ] && [ -x "$BE/orep" ] && BINS="$BINS orep"
echo "BE binaries: $BINS (host: $H)"
"${Q[@]}" "$BE/orep-ref" 2>&1 | grep -q '^OREP ' || bad "BE orep-ref does not run under $QEMU"

# ---- inputs ----------------------------------------------------------------
C=$ROOT/tests/corpus
python3 - "$W/versions.bin" "$C/random.bin" <<'EOF'
import sys
src = open(sys.argv[2], 'rb').read()[:300000]
out = bytearray()
for v in range(12):
    b = bytearray(src)
    for k in range(40):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
open(sys.argv[1], 'wb').write(out)
EOF
python3 - "$W/periods.bin" "$C/random.bin" <<'EOF'
import sys
src = open(sys.argv[2], 'rb').read()
out = bytearray()
for k in range(160):
    out += src[(k * 4099) % 60000:(k * 4099) % 60000 + 700 + k * 13]
    p = 1 + k % 16
    pat = src[k * 31:k * 31 + p]
    out += (pat * (1 + (200 + k * 37) // p))[:200 + k * 37]
    out += bytes([k & 255]) * (100 + k * 11 % 900)
open(sys.argv[1], 'wb').write(out)
EOF
: > "$W/empty.bin"
INPUTS="$C/text.bin $C/mixed.bin $C/random.bin $C/zeros.bin $C/tiny.bin $W/versions.bin $W/periods.bin $W/empty.bin"

# ---- same bytes, cross decodes ---------------------------------------------
# ck <bin> <file> <opts...>: BE encode == host encode; BE decodes the host
# stream; host decodes the BE stream
ck() {
  local b=$1 f=$2; shift 2
  local n; n=$(basename "$f")
  "$H/orep" -q "$@" "$f" "$W/h.orp" || { bad "host encode $n $*"; return; }
  "${Q[@]}" "$BE/$b" -q "$@" "$f" "$W/b.orp" || { bad "BE $b encode $n $*"; return; }
  cmp -s "$W/h.orp" "$W/b.orp" || bad "BE $b bytes != host: $n $*"
  "${Q[@]}" "$BE/$b" -q -d "$W/h.orp" "$W/b.dec" || bad "BE $b decode of host stream: $n $*"
  cmp -s "$f" "$W/b.dec" || bad "BE $b round trip of host stream: $n $*"
  "$H/orep" -q -d "$W/b.orp" "$W/h.dec" || bad "host decode of BE $b stream: $n $*"
  cmp -s "$f" "$W/h.dec" || bad "host round trip of BE $b stream: $n $*"
}
OPTS=("" "-t1" "-t3" "-l16 -s16" "-w64k -b64k" "-w300k -b64k -l256 -c2 -r512"
      "-w300k -b64k -l32 -a1" "-w1m -b64k -l64 -r100 -D7")
for b in $BINS; do
  echo "== $b: same bytes as the host, cross decodes"
  for f in $INPUTS; do
    for o in "${OPTS[@]}"; do
      # shellcheck disable=SC2086
      ck "$b" "$f" $o
    done
  done
  echo "== $b: -t3 == -t1 on BE"
  for f in "$W/versions.bin" "$C/mixed.bin"; do
    "${Q[@]}" "$BE/$b" -q -b64k -t1 "$f" "$W/t1.orp"
    "${Q[@]}" "$BE/$b" -q -b64k -t3 "$f" "$W/t3.orp"
    cmp -s "$W/t1.orp" "$W/t3.orp" || bad "BE $b -t3 != -t1: $f"
  done
  echo "== $b: stdin / stdout"
  "${Q[@]}" "$BE/$b" -q - - < "$C/mixed.bin" > "$W/s.orp" || bad "BE $b stdin encode"
  "${Q[@]}" "$BE/$b" -q -d - - < "$W/s.orp" > "$W/s.dec" || bad "BE $b stdout decode"
  cmp -s "$C/mixed.bin" "$W/s.dec" || bad "BE $b stdin/stdout round trip"
done

# ---- corrupt streams -------------------------------------------------------
echo "== corrupt and truncated streams (BE decoder)"
"$H/orep" -q -w1m -b64k "$W/versions.bin" "$W/c.orp"
python3 - "$W/c.orp" "$W" <<'EOF'
import sys, random
data = open(sys.argv[1], 'rb').read()
random.seed(11)
for i in range(120):
    b = bytearray(data)
    kind = i % 4
    if kind == 0:
        b = b[:random.randrange(len(b))]
    elif kind == 1:
        for _ in range(random.randint(1, 4)):
            p = random.randrange(len(b))
            b[p] ^= 1 << random.randrange(8)
    elif kind == 2:
        p = random.randrange(28, len(b))
        b[p:p + 2] = bytes([random.randrange(256), random.randrange(256)])
    else:  # header bytes (incl. the version 4 flags varint)
        p = random.randrange(0, 24)
        b[p] = random.randrange(256)
    open('%s/bad%03d.orp' % (sys.argv[2], i), 'wb').write(b)
EOF
crash=0; accepted=0
for f in "$W"/bad*.orp; do
  for b in $BINS; do
    "${Q[@]}" "$BE/$b" -q -d "$f" "$W/bad.dec" 2>/dev/null; rc=$?
    if [ $rc -ge 2 ]; then crash=$((crash + 1)); echo "  BE $b rc=$rc on $(basename "$f")"; fi
    if [ $rc -eq 0 ] && ! cmp -s "$W/bad.dec" "$W/versions.bin"; then
      accepted=$((accepted + 1)); echo "  BE $b accepted $(basename "$f") with wrong output"
    fi
  done
done
[ $crash -eq 0 ] || bad "$crash corrupt streams crashed the BE decoder"
[ $accepted -eq 0 ] || bad "$accepted corrupt streams decoded to wrong data on BE"

if [ $fail -eq 0 ]; then echo "orep_be: all checks passed"; else exit 1; fi

# How the toolchain in OREP_BE_TOOLS was made (FPC 3.2.2, Debian trixie host,
# no root; B = the toolchain dir):
#   cd $B/debs && apt-get download binutils-powerpc64-linux-gnu \
#     libc6-ppc64-cross libc6-dev-ppc64-cross linux-libc-dev-ppc64-cross \
#     gcc-14-powerpc64-linux-gnu cpp-14-powerpc64-linux-gnu \
#     gcc-14-powerpc64-linux-gnu-base libgcc-14-dev-ppc64-cross libgcc-s1-ppc64-cross
#   for f in *.deb; do dpkg -x $f $B/sysroot; done
#   bin-ppc64/powerpc64-linux-{as,ld,ar,nm,objcopy,objdump,ranlib,strip}: sh
#     wrappers that set LD_LIBRARY_PATH=$B/sysroot/usr/lib/x86_64-linux-gnu and
#     exec $B/sysroot/usr/bin/powerpc64-linux-gnu-<tool>; powerpc64-linux-gnu-gcc
#     the same around gcc-14 with --sysroot=$B/sysroot
#   tar xzf fpc-3.2.2.source.tar.gz  (sha256 d542e349...2d44)
#   make -j4 -C fpc-3.2.2/compiler powerpc64 PP=/usr/bin/fpc
#   make -j4 -C fpc-3.2.2/rtl all CPU_TARGET=powerpc64 OS_TARGET=linux \
#     FPC=$B/fpc-3.2.2/compiler/ppcppc64 CROSSBINDIR=$B/bin-ppc64 \
#     BINUTILSPREFIX=powerpc64-linux-
#   cp compiler/ppcppc64 -> lib/fpc/3.2.2/; rtl/units/powerpc64-linux -> lib/fpc/3.2.2/units/
#   csu_stub.o: empty __libc_csu_init/__libc_csu_fini compiled with the BE gcc
