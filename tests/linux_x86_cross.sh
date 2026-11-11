#!/usr/bin/env bash
# Cross-build for Linux i386 and run a round-trip. A 32-bit Linux binary runs
# natively on the x86_64 host when /lib/ld-linux.so.2 is present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-x86.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== cross-build =="
bash "$ROOT/scripts/build_linux_x86.sh" "$TMP/x86" || fail "scripts/build_linux_x86.sh"
BIN="$TMP/x86/osrep"
[ -f "$BIN" ] || fail "missing i386 binary"
file "$BIN" | grep -q 'ELF 32-bit.*Intel i386' || fail "not an i386 ELF"

echo "== round-trip =="
cp "$ROOT/tests/corpus/text.bin" "$TMP/in.bin"
"$BIN" --version | grep -q 'OSREP 0.0' || fail "version"
"$BIN" -m5 "$TMP/in.bin" "$TMP/out.osr" || fail "encode"
"$BIN" --verify "$TMP/out.osr" || fail "verify"
"$BIN" -d "$TMP/out.osr" "$TMP/back.bin" || fail "decode"
cmp "$TMP/back.bin" "$TMP/in.bin" || fail "round-trip"
cat "$TMP/in.bin" | "$BIN" -m3 - - > "$TMP/pipe.osr" || fail "stdin encode"
"$BIN" -d "$TMP/pipe.osr" "$TMP/pipe.out" || fail "stdin decode"
cmp "$TMP/pipe.out" "$TMP/in.bin" || fail "stdin round-trip"
"$BIN" -dup -m5 "$TMP/in.bin" "$TMP/dup.osr" || fail "-dup encode"
"$BIN" -d "$TMP/dup.osr" "$TMP/dup.out" || fail "-dup decode"
cmp "$TMP/dup.out" "$TMP/in.bin" || fail "-dup round-trip"
echo "linux x86: version, -m5, verify, decode, stdin and -dup OK"
