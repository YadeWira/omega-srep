#!/usr/bin/env bash
# Cross-build for Linux AArch64 and (when qemu-aarch64 is present) run a
# round-trip. The AArch64 binary uses the portable C paths (no SSE4.2).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-arm64.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== cross-build =="
bash "$ROOT/scripts/build_arm64.sh" "$TMP/arm64" || fail "scripts/build_arm64.sh"
BIN="$TMP/arm64/osrep"
[ -f "$BIN" ] || fail "missing aarch64 binary"
file "$BIN" | grep -q 'ARM aarch64' || fail "not an aarch64 ELF"

if ! command -v qemu-aarch64 >/dev/null 2>&1 || [ ! -d /usr/aarch64-linux-gnu ]; then
  echo "qemu-aarch64 or /usr/aarch64-linux-gnu not found; build only"
  exit 0
fi

echo "== qemu round-trip =="
cp "$ROOT/tests/corpus/text.bin" "$TMP/in.bin"
Q="qemu-aarch64 -L /usr/aarch64-linux-gnu"
$Q "$BIN" --version | grep -q 'OSREP 0.0' || fail "version"
$Q "$BIN" -m5 "$TMP/in.bin" "$TMP/out.osr" || fail "encode"
$Q "$BIN" --verify "$TMP/out.osr" || fail "verify"
$Q "$BIN" -d "$TMP/out.osr" "$TMP/back.bin" || fail "decode"
cmp "$TMP/back.bin" "$TMP/in.bin" || fail "round-trip"
cat "$TMP/in.bin" | $Q "$BIN" -m3 - - > "$TMP/pipe.osr" || fail "stdin encode"
$Q "$BIN" -d "$TMP/pipe.osr" "$TMP/pipe.out" || fail "stdin decode"
cmp "$TMP/pipe.out" "$TMP/in.bin" || fail "stdin round-trip"
echo "aarch64: version, -m5, verify, decode and stdin OK"
