#!/usr/bin/env bash
# Cross-build the Windows binaries and (when wine is available) run a
# round-trip with both. The binaries are the same CLI as the Linux build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-win.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== cross-build =="
bash "$ROOT/scripts/build_windows.sh" "$TMP/win" || fail "scripts/build_windows.sh"
W64="$TMP/win/osrep-windows-x86_64.exe"
W32="$TMP/win/osrep-windows-x86.exe"
[ -f "$W64" ] || fail "missing x64 exe"
[ -f "$W32" ] || fail "missing x86 exe"
file "$W64" | grep -q 'PE32+' || fail "not a PE32+ x64 exe"
file "$W32" | grep -q 'PE32' || fail "not a PE32 x86 exe"

if ! command -v wine >/dev/null 2>&1; then
  echo "wine not found; binaries built, round-trip skipped"
  exit 0
fi

cp "$ROOT/tests/corpus/text.bin" "$TMP/in.bin"
for exe in "$W64" "$W32"; do
  name=$(basename "$exe")
  work="$TMP/$name"
  mkdir -p "$work"
  cp "$TMP/in.bin" "$work/in.bin"
  (cd "$work" && WINEDEBUG=-all wine "$exe" --version > version.txt) || fail "$name --version"
  grep -q 'OSREP 0.0' "$work/version.txt" || fail "$name version"
  (cd "$work" && WINEDEBUG=-all wine "$exe" -m5 in.bin out.osr) || fail "$name encode"
  (cd "$work" && WINEDEBUG=-all wine "$exe" --verify out.osr) || fail "$name verify"
  (cd "$work" && WINEDEBUG=-all wine "$exe" -d out.osr back.bin) || fail "$name decode"
  cmp "$work/back.bin" "$work/in.bin" || fail "$name round-trip"
  echo "$name: version, encode, verify and round-trip OK"
done

echo "windows cross: all checks passed"
