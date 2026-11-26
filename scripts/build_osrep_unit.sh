#!/bin/sh
# Package the embeddable -m6 API (src/pascal/osrep_m6.pas) for programs that
# vendor it (PArc): the Pascal units it needs, the C sources, the C objects
# for each target, LICENSE, VERSION and a README.
#
#   scripts/build_osrep_unit.sh <out dir>   -> <out>/osrep-unit-<ver>.tar.gz
#
# The objects are freestanding (no libc calls; checked with nm).  A build
# with -dOSREP_NO_NATIVE needs no object at all (all Pascal, same streams).
set -eu
OUT=${1:?usage: build_osrep_unit.sh <out dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
VER=$(sed -n "s/.*OsrepProductVersion *= *'\(.*\)';.*/\1/p" "$ROOT/src/pascal/osrep_format.pas")
NAME=osrep-unit-$VER
D=$OUT/$NAME
rm -rf "$D"
mkdir -p "$D/src/pascal" "$D/src/c" "$D/obj"
UNITS="osrep_m6 osrep_encoder osrep_decoder osrep_format osrep_crc osrep_vhash osrep_aes"
CSRC="osrep_lr osrep_match osrep_vhash_nh osrep_crc_native"
for u in $UNITS; do cp "$ROOT/src/pascal/$u.pas" "$D/src/pascal/"; done
for c in $CSRC; do cp "$ROOT/src/c/$c.c" "$D/src/c/"; done
cp "$ROOT/LICENSE" "$D/"
FLAGS="-O3 -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables"

objs() { # objs <target> <cc> [flags]
  t=$1 cc=$2; shift 2
  mkdir -p "$D/obj/$t"
  for c in $CSRC; do
    # shellcheck disable=SC2086
    $cc $FLAGS "$@" -c "$ROOT/src/c/$c.c" -o "$D/obj/$t/$c.o"
    if nm "$D/obj/$t/$c.o" | grep -q ' U '; then
      echo "$t/$c.o calls out:"; nm "$D/obj/$t/$c.o" | grep ' U '
      exit 1
    fi
  done
}
objs linux-x86_64 gcc -fno-pic
objs linux-x86 gcc -m32 -fno-pic
objs linux-arm64 aarch64-linux-gnu-gcc
objs win64 x86_64-w64-mingw32-gcc
objs win32 i686-w64-mingw32-gcc

cat > "$D/VERSION" <<EOF
OSREP $VER, embeddable -m6 API (osrep_m6.pas), stream format .osr v7 (frozen)
EOF
cat > "$D/README.md" <<'EOF'
# OSREP embeddable -m6 API

`src/pascal/osrep_m6.pas` is OSREP's long-range method (`-m6`) memory to
memory: `OsrepM6Encode` writes a standard `.osr` v7 stream (the `osrep` CLI
decodes it, and this unit decodes the CLI's), `OsrepM6Decode` writes the
original in place into a buffer of its exact size. See the unit's header
and `TOsrepM6Params`.

Build: put `src/pascal` on the unit path (`-Fu`) and the object directory
of the target on the object path (`-Fo`, the units link `osrep_lr.o`,
`osrep_match.o`, `osrep_vhash_nh.o` and `osrep_crc_native.o` with `{$L}`).
`obj/<target>/` has them for linux-x86_64, linux-x86, linux-arm64, win64
and win32; for another target compile `src/c/*.c` with
`-O3 -fno-builtin -fno-stack-protector` (they call nothing from libc).
With `-dOSREP_NO_NATIVE` the units are all Pascal and need no object: the
streams are byte for byte the same, slower.

Memory: `OsrepM6EncMem` and `OsrepM6DecMem` (besides the input and output
buffers). Threads: the search runs on the calling thread and starts none.
License: MIT (`LICENSE`).
EOF
(cd "$OUT" && tar czf "$NAME.tar.gz" "$NAME")
echo "$OUT/$NAME.tar.gz"
