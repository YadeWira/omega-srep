#!/usr/bin/env bash
# -m3 with blocks that do not start on the chunk grid (2.2.1, F1).
#
# -m3 numbers block j's chunks from block_start / L but digests and hashes
# them at block_start + m*L, and wrote a match's source as chunk * L. When
# -b is not a multiple of L (-b65537b, -b1025b, -l8192 -b100kb, -l17 ...)
# every block after the first starts off that grid, so a match into an
# earlier block got a source off by block_start mod L: exit 0 (or the
# power-of-two warning, exit 1) and an archive that -d refused
# (DigestMismatch) or, with -hash-, decoded to other bytes. The digest walk
# could also run from a block on the grid into the next, shifted one (cr1b
# below is built for exactly that), and with an L that 4 does not divide the
# first chunk of a match could end past the block (z66 -m3 -l9: exit 4,
# BadBlockRecord, a partial archive on disk). 1.0.7 and 2.1.x had all three.
#
# Such a record is now checked against the bytes the decoder will copy and,
# if it would not reproduce them, rebuilt from the chunk's real position and
# measured from there to the end of the block (measuring only as far as the
# digest walk over the wrong chunks went, usually one chunk, took period-69
# text with -b1000001b from 0.02 s to 12.7 s and to 2.9 MB of 4 MB; the third
# table bounds those sizes). An archive that decoded keeps its bytes, so the
# second table pins archives 2.2.0 already wrote. Run by tests/rust_cli_conformance.sh against the Rust
# and (OSREP_PORT_BIN) the Pascal build; both write these same archives.
#
#   OSREP_BIN=<osrep> bash tests/m3_grid_regress.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OSREP="${OSREP_BIN:-target/release/osrep}"
[ -x "$OSREP" ] || { echo "missing $OSREP (set OSREP_BIN)" >&2; exit 1; }
[ -f tests/corpus/text.bin ] || { echo "missing tests/corpus/text.bin" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
text = open("tests/corpus/text.bin", "rb").read()
open(os.path.join(d, "t300k"), "wb").write(text[:300000])
# 3000 random bytes, twice: one long match back across odd blocks.
r = random.Random(3000)
u = r.randbytes(3000)
open(os.path.join(d, "rep3000"), "wb").write(u + u)
# 133 bytes with a 32-byte repeat that -l8 -b20b splits across blocks.
open(os.path.join(d, "craftB"), "wb").write(bytes.fromhex(
    "fd3feb3c9250b7974a9b528b69636321a461b55ef55b7beafd809a9a9e925b79"
    "a6342fa0fdb8b294d97fc6103d92089b25fa5e039f52a8e8a95f64d6589c1f78"
    "44066542ec38008d331dfd3b272416317694e2fe860397b774306378b5437d8a"
    "755622d6f55b7beafd809a9a9e925b79a6342fa0fdb8b294d7a56d3cfcf9a44d"
    "c716691ab8"))
open(os.path.join(d, "z66"), "wb").write(bytes(66))
# With -l16 -b1000b block 0 is on the grid (chunks 0..61 at 0..991) and
# block 1 is not (chunk 62 at 1000). Bytes 960..991 followed by 1000..1015,
# copied into block 5, match chunks 60, 61, 62 by digest although they are
# not contiguous in the file.
r = random.Random(1344)
b = bytearray(r.randbytes(8000))
dd = b[960:992] + b[1000:1016]
b[5100:5100 + len(dd)] = dd
open(os.path.join(d, "cr1b"), "wb").write(b)
PY
cp tests/corpus/text.bin "$TMP/text.bin"

pass=0
# want_rc md5 input options: the exit code, the archive, and a round trip.
check() {
    local rc_want="$1" want="$2" input="$3"; shift 3
    local rc=0
    "$OSREP" --seed=7 "$@" "$TMP/$input" "$TMP/g.osr" >/dev/null 2>"$TMP/g.err" || rc=$?
    [ "$rc" -eq "$rc_want" ] || fail "$* on $input exited $rc, expected $rc_want: $(tr '\r' '\n' < "$TMP/g.err" | grep -a -m1 -E 'panicked|ERROR')"
    "$OSREP" -d "$TMP/g.osr" "$TMP/g.dec" >/dev/null 2>"$TMP/g.derr" \
        || fail "$* on $input: archive does not decode: $(tr '\r' '\n' < "$TMP/g.derr" | grep -a -m1 ERROR)"
    cmp -s "$TMP/$input" "$TMP/g.dec" || fail "$* on $input: round trip differs"
    local got
    got="$(md5sum < "$TMP/g.osr" | cut -c1-32)"
    [ "$got" = "$want" ] || fail "$* on $input: archive md5 $got, expected $want"
    size="$(wc -c < "$TMP/g.osr")"
    rm -f "$TMP/g.osr" "$TMP/g.dec"
    pass=$((pass + 1))
}

# Archives that 2.2.0 wrote and could not decode (each fails there).
while read -r rc want input args; do
    check "$rc" "$want" "$input" $args
done <<'EOF'
0 c7da8437e1a472aa4b51b63d6e508fb4 craftB -m3 -l8 -b20b
0 e195f565f2d084882e4c96c251bc316e rep3000 -m3 -b1025b
0 19b7305637d04f8ed0539f6ed6c76a6e t300k -m3 -b65537b
0 32e278c2c15c0cacb3c250eb99cbbaba t300k -m3 -b65537b -hash-
0 b6f3042bfc195839dc3bb577a98896ad t300k -m3 -b65537b -d1mb
0 b66609678ad43f4f3557f106414c3195 t300k -m3 -b1025b -d64kb
0 f26f693aee7966fe027d859e00f76d3a t300k -m3 -l8192 -b100kb
0 f26f693aee7966fe027d859e00f76d3a t300k -m3f -l8192 -b100kb
0 1c0bf14d160e39d5e992bdc2fb1c31ea t300k -m3o -l8192 -b100kb --format=v4
0 118be04477917236efa9ce93ce02b38e t300k -m3 -l16384 -b40kb
1 74c1f456b282320006dfcd3c52c36ba9 t300k -m3 -l128 -c300 -b117kb
0 8a96c3a1993719a09cabaccc69acd621 cr1b -m3 -l16 -b1000b
0 1fab6dfe267b1b20de74cf8800bde493 cr1b -m3 -l16 -b1000b --format=v4
1 d694b1099b653ea5ef410c8a4cdac986 z66 -m3 -l9
1 d694b1099b653ea5ef410c8a4cdac986 z66 -m3o -l9
1 4ea55e35c3093cd75cfd0085a05a8d66 text.bin -m3 -l17 -b4kb --format=v4
1 3af8578e4c2492c3b949083fb3661110 text.bin -m3f -l17 -b4kb --format=v4
EOF

# Archives that already decoded keep their bytes (these are 2.2.0's).
while read -r rc want input args; do
    check "$rc" "$want" "$input" $args
done <<'EOF'
0 33026558e944336a2b01c398285cce05 craftB -m3 -l8 -b24b
0 9dd7bef115c2138708177e544eb558fd rep3000 -m3 -b65537b
0 6b9f25f0fdc2216ef6867e4536469f8d t300k -m3 -b65536b
0 b83a7cbb98aaae938f9bd280e6bb011a t300k -m3 -l8192 -b100kb -d1mb
EOF

# Periodic text with -b off the grid compresses about as well as with an
# aligned -b (text.bin: 1282 bytes with -b1mb, 3922 with -b64kb). Records
# cut to the digest walk left most of it as literals: 2936114, 1591700,
# 80661 and 2702690 bytes.
while read -r rc want max input args; do
    check "$rc" "$want" "$input" $args
    [ "$size" -le "$max" ] || fail "$args on $input: archive is $size bytes, expected at most $max"
done <<'EOF'
0 a2b33d6835108c9a02686a7e32587b04 8000 text.bin -m3 -b1000001b
0 bccf87152797f89d3d8ae6a631a28f72 80000 text.bin -m3 -b65537b
0 19b7305637d04f8ed0539f6ed6c76a6e 8000 t300k -m3 -b65537b
1 4ea55e35c3093cd75cfd0085a05a8d66 200000 text.bin -m3 -l17 -b4kb --format=v4
EOF

# Through a pipe (-s given) the fix rereads the same bytes: same archive.
rc=0
"$OSREP" --seed=7 -s300000 -m3 -b65537b - - < "$TMP/t300k" > "$TMP/p.osr" 2>"$TMP/p.err" || rc=$?
[ "$rc" -eq 0 ] || fail "-m3 -b65537b from a pipe exited $rc"
got="$(md5sum < "$TMP/p.osr" | cut -c1-32)"
[ "$got" = 19b7305637d04f8ed0539f6ed6c76a6e ] || fail "-m3 -b65537b from a pipe: archive md5 $got"
"$OSREP" -d - - < "$TMP/p.osr" > "$TMP/p.dec" 2>/dev/null || fail "-m3 -b65537b from a pipe: does not decode"
cmp -s "$TMP/t300k" "$TMP/p.dec" || fail "-m3 -b65537b from a pipe: round trip differs"
pass=$((pass + 1))

echo "  m3_grid_regress: passed=$pass"
