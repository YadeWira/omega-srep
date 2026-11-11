#!/bin/bash
# Build the tarball zpaq-std vendors for -osrep: only what it links (the
# fragmenter, the SHA-1 the fragmenter's whole-buffer API calls, and the
# header), the MIT LICENSE, and VENDOR.md with the tag, the commit and the
# sha256 of every file.
#
#   tools/zpaq-vendor/make-vendor.sh OUTDIR
#
# The tree must be clean: the tarball names the commit it comes from.
set -euo pipefail
[ "$#" -eq 1 ] || { echo "usage: $0 OUTDIR" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$1"
cd "$ROOT"
if [ -n "$(git status --porcelain -- src/c/osrep_fragment.c src/c/osrep_fragment.h src/c/osrep_sha1.c LICENSE)" ]; then
  echo "the vendored files have uncommitted changes" >&2; exit 1
fi
COMMIT=$(git rev-parse HEAD)
DESC=$(git describe --tags --always HEAD)
NAME="osrep-fragment-${DESC}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME"
cp src/c/osrep_fragment.c src/c/osrep_fragment.h src/c/osrep_sha1.c LICENSE "$STAGE/$NAME/"
{
  echo "# OSREP fragmenter, vendored"
  echo
  echo "From https://github.com/YadeWira/omega-srep, branch \`osrep\`."
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| version | \`$DESC\` |"
  echo "| commit | \`$COMMIT\` |"
  echo "| license | MIT (\`LICENSE\`) |"
  echo
  echo "Plain C99, no dependencies beyond the C library. Checked with gcc,"
  echo "clang, gcc -m32, x86_64/i686-w64-mingw32-gcc and aarch64-linux-gnu-gcc"
  echo "(\`-std=c99 -Wall -Wextra -pedantic\`, no warnings); macOS by the OSREP CI."
  echo
  echo "What zpaq-std uses: \`osrep_frag_state_reset()\` and"
  echo "\`osrep_frag_state_push()\` (per byte, they keep the cut hash, \`hits\` and"
  echo "\`o1\`), and \`osrep_frag_params_osrep()\` for the -fragment N average."
  echo "\`osrep_sha1.c\` is here only because \`osrep_fragment_buffer()\` calls it."
  echo
  echo "## sha256"
  echo
  echo '```'
  (cd "$STAGE/$NAME" && sha256sum osrep_fragment.c osrep_fragment.h osrep_sha1.c LICENSE)
  echo '```'
} > "$STAGE/$NAME/VENDOR.md"
mkdir -p "$OUT"
tar -C "$STAGE" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$(git log -1 --format=%ct)" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "$OUT/$NAME.tar.gz"
