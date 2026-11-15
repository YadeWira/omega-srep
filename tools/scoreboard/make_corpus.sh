#!/bin/bash
# Build the scoreboard corpus into $1 (copies only; sources are read-only).
#
#   tools/scoreboard/make_corpus.sh /mnt/IA_LAB/agentes/osrep/score/corpus
#
# Every tar is built with fixed owner/mtime and sorted names, so the same
# sources give the same bytes.
set -euo pipefail
OUT=${1:?usage: make_corpus.sh <out dir>}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ZPAQSTD=${ZPAQSTD_REPO:-/home/forum/git/zpaq-std}
SAMPLES=${SAMPLES:-/mnt/OSR_D3/fileFormatSamples/fileFormatSamples/archive}
TARFLAGS=(--sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --format=gnu)

cp_if_missing() { [ -f "$2" ] || cp "$1" "$2"; }
cp_if_missing /home/forum/.osrep-bench-multi/enwik8 "$OUT/enwik8"
cp_if_missing /mnt/IA_LAB/agentes/syc/silesia.tar "$OUT/silesia.tar"
cp_if_missing /mnt/IA_LAB/agentes/osrep/inputs/real64.bin "$OUT/real64.bin"
cp_if_missing /mnt/IA_LAB/agentes/osrep/zpaqclean/corpus/versions.tar "$OUT/versions.tar"
cp_if_missing /mnt/IA_LAB/agentes/osrep/zpaqclean/corpus/pja.tar "$OUT/pja.tar"

# Source history: 8 tags of zpaq-std, oldest first, one tar (read-only
# `git archive`; the repo is not touched).
if [ ! -f "$OUT/zpaqstd-history.tar" ]; then
  W=$(mktemp -d "$OUT/.hist.XXXX")
  for t in v1.5.1 v1.8.0 v1.10.0 v2.2.0 v2.5.0 v2.7.0 v2.9.0 v2.11.0; do
    git -C "$ZPAQSTD" archive --format=tar --prefix="$t/" "$t" | tar -x -C "$W"
  done
  tar -C "$W" "${TARFLAGS[@]}" -cf "$OUT/zpaqstd-history.tar" \
    v1.5.1 v1.8.0 v1.10.0 v2.2.0 v2.5.0 v2.7.0 v2.9.0 v2.11.0
  rm -rf "$W"
fi

# Game assets: 13 distinct game archives (pak/grp/bif/wad/mpq/pck), 584 MB.
if [ ! -f "$OUT/game-assets.tar" ]; then
  W=$(mktemp -d "$OUT/.game.XXXX")
  while read -r f; do
    mkdir -p "$W/$(dirname "$f")"
    cp "$SAMPLES/$f" "$W/$f"
  done <<'LIST'
quakePAK/pak0.PAK
buildEngineGroupGameArchive/DUKE3D.GRP
buildEngineGroupGameArchive/SW.GRP
buildEngineGroupGameArchive/NAM.GRP
infinityEngineBIFFArchive/demo_aurora_gui.bif
infinityEngineBIFFArchive/demo_models_01.bif
sbpak/basedata.pak
conquestEarthArchive/flic01.wad
dwfbWAD/Frontend.WAD
pakArchive/speech.pak
aGameEngineArchive/AGameEngine.pak
mpq/Patch_D2.mpq
godotPackageFormat/last_gleam.pck
LIST
  tar -C "$W" "${TARFLAGS[@]}" -cf "$OUT/game-assets.tar" .
  rm -rf "$W"
fi
ls -l "$OUT"
