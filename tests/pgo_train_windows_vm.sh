#!/usr/bin/env bash
# tests/pgo_train_windows_vm.sh -- maintainer-only helper that collects a
# REAL Windows-native PGO profile for the Windows release binary, using the
# real Windows VM documented in CONEXION-IA.md (dockur/windows over SSH).
#
# Why this exists: reusing the Linux-collected profile (tests/pgo_train.sh)
# for the MinGW cross-compiled binary does NOT work -- confirmed empirically.
# GCC's -fprofile-use ties LTO profile data to the exact GIMPLE structure
# recorded during -fprofile-generate, and Compression/Common.cpp's
# FREEARC_WIN-gated code paths are never even compiled into the Linux
# (FREEARC_UNIX) instrumented binary, so there is no profile data for them at
# all -- not a lookup bug, a genuine absence of data for Windows-only code.
# The real fix is to instrument a WINDOWS-targeted binary and run IT against
# the training corpus, which is what this script does (over SSH, on the real
# VM -- not Wine, whose own startup overhead dominates timings this small).
#
# Usage: bash tests/pgo_train_windows_vm.sh
#   Requires: the win10 VM from CONEXION-IA.md reachable at
#   ia@localhost:2222 with the ~/.ssh/winvm key (adjust the variables below
#   if your VM's connection details differ). Starts/stops the VM itself.
#
# Output: Compression-flavored .gcda profile data restored under
# ./pgo-data-win/, ready for a final -fprofile-use=pgo-data-win rebuild with
# THE SAME -o path used below for the instrumented binary (GCC's LTO profile
# lookup is keyed to that exact absolute path -- see docs/research-notes.md).
set -eu

SSH_KEY="${WINVM_SSH_KEY:-$HOME/.ssh/winvm}"
SSH_PORT="${WINVM_SSH_PORT:-2222}"
SSH_HOST="${WINVM_SSH_HOST:-localhost}"
SSH_USER="${WINVM_SSH_USER:-ia}"
DOCKER_NAME="${WINVM_DOCKER_NAME:-win10}"
SSH="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o BatchMode=yes"
SCP="scp -i $SSH_KEY -P $SSH_PORT -o StrictHostKeyChecking=no"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTRUMENTED_OUT="$REPO_ROOT/bin/osrep-pgo-instrumented-win.exe"
PGO_DIR_WIN="$REPO_ROOT/pgo-data-win"
SHIM_DIR="$(mktemp -d)"
printf '#include <shobjidl.h>\n' > "$SHIM_DIR/ShObjIdl.h"

echo "-- starting $DOCKER_NAME --"
sudo docker start "$DOCKER_NAME" >/dev/null
for i in $(seq 1 20); do
  $SSH -o ConnectTimeout=8 "$SSH_USER@$SSH_HOST" "echo UP" 2>/dev/null | grep -q UP && { echo "up"; break; }
  sleep 6
done

echo "-- cross-compiling instrumented Windows binary --"
x86_64-w64-mingw32-g++ -DFREEARC_WIN -DUNICODE -D_UNICODE \
  -DFREEARC_INTEL_BYTE_ORDER -D_FILE_OFFSET_BITS=64 \
  -I"$SHIM_DIR" \
  -I"$REPO_ROOT/Compression" -I"$REPO_ROOT/Compression/_Encryption" \
  -I"$REPO_ROOT/Compression/_Encryption/headers" -I"$REPO_ROOT/Compression/_Encryption/hashes" \
  -O3 -flto -mtune=generic -funroll-all-loops -msse2 \
  -fprofile-generate=pgo-data-win \
  -Wno-write-strings -Wno-unused-result \
  "$REPO_ROOT/Compression/Common.cpp" "$REPO_ROOT/Compression/SREP/srep.cpp" \
  -lstdc++ -lole32 -luuid -lshell32 -ladvapi32 -static \
  -o "$INSTRUMENTED_OUT"

echo "-- copying instrumented binary + training corpus to VM --"
if [[ ! -d "$REPO_ROOT/tests/corpus" ]] || [[ -z "$(ls -A "$REPO_ROOT/tests/corpus" 2>/dev/null)" ]]; then
  bash "$REPO_ROOT/tests/gen_corpus.sh" "$REPO_ROOT/tests/corpus"
fi
$SCP "$INSTRUMENTED_OUT" "$REPO_ROOT"/tests/corpus/*.bin "$SSH_USER@$SSH_HOST:C:/Users/$SSH_USER/"

cat > "$SHIM_DIR/pgo_train_win.ps1" <<'PS1'
$ProgressPreference = "SilentlyContinue"
$bin = "C:\Users\ia\osrep-pgo-instrumented-win.exe"
$corpus = @("tiny.bin","zeros.bin","random.bin","mixed.bin","text.bin")
$work = "C:\Users\ia\pgotrain"
New-Item -ItemType Directory -Force -Path $work | Out-Null
foreach ($c in $corpus) {
  $input = "C:\Users\ia\$c"
  if (-not (Test-Path $input)) { continue }
  foreach ($m in 0..5) {
    foreach ($t in @(1,8)) {
      $out = "$work\train.osr"; $dec = "$work\train.dec"
      & $bin "-m$m" "-t$t" $input $out *> $null
      & $bin "-d" "-t$t" $out $dec *> $null
      Remove-Item -Force -ErrorAction SilentlyContinue $out, $dec
    }
  }
  Write-Host "trained on $c"
}
PS1
$SCP "$SHIM_DIR/pgo_train_win.ps1" "$SSH_USER@$SSH_HOST:C:/Users/$SSH_USER/pgo_train_win.ps1"

echo "-- training on the VM (all -mN, -t1 and -t8) --"
$SSH "$SSH_USER@$SSH_HOST" 'pwsh -NoProfile -File C:\Users\ia\pgo_train_win.ps1'

echo "-- copying profile data back --"
rm -rf "$PGO_DIR_WIN"
mkdir -p "$PGO_DIR_WIN"
$SCP -r "$SSH_USER@$SSH_HOST:C:/Users/$SSH_USER/pgo-data-win/home" "$PGO_DIR_WIN/"

echo "-- stopping $DOCKER_NAME --"
sudo docker stop "$DOCKER_NAME" >/dev/null

rm -rf "$SHIM_DIR"
echo "Done. Profile data restored under $PGO_DIR_WIN."
echo "Final rebuild MUST use -o $INSTRUMENTED_OUT verbatim (or re-derive it identically) for -fprofile-use=$PGO_DIR_WIN to find a match."
