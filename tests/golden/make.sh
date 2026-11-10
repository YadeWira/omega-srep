#!/usr/bin/env bash
# Records tests/golden/manifest.tsv: for every case, the archive the
# references write and the port must reproduce.
#
# This is the seed of the suite that lets the oracles go: after it is recorded,
# tests/golden/check.sh replays the cases with the Pascal alone. Recording
# still needs both references, and refuses to record a case unless:
#   * for --format=v4, the C++ 1.0.7 and the Rust write the same bytes (twice
#     each run, so a racing case is refused rather than pinned);
#   * for --format=v5, the Rust writes it (the C++ cannot);
#   * the port writes the same bytes and the same exit code as the reference
#     (exit 1 is allowed only for the non-power-of-two -l warning, which the
#     references print and the ports reproduce);
#   * every archive decodes back to the input, with the port's decoder and
#     with the reference's.
# A case where the reference is wrong (the C++ drops the ODUP trailer with a
# non-power-of-two -l, or its slice filter wraps with -l < -c) must stay out
# of cases.txt: the differential suites pin those on purpose.
#
# Usage: tests/golden/make.sh      (rewrites the manifest)
#        OSREP_PORT_BIN=... tests/golden/make.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
RUST="${OSREP_RUST_BIN:-$RUST_TARGET/x86_64-unknown-linux-gnu/release/osrep}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
[ -x "$RUST" ] || fail "missing Rust binary $RUST (set OSREP_ORACLES and build the archived Rust (docs/retired-oracles.md))"
[ -x "$CXX_BIN/osrep" ] || make_cxx bin/osrep || fail "cannot build the C++ oracle"

# The references have to be the current version. A stale target/release/osrep
# once made a careful comparison meaningless; refuse instead of pinning it.
pv=$("$PORT" --version) || fail "the port does not run: $PORT"
rv=$("$RUST" --version) || fail "the Rust reference does not run: $RUST"
[ "$pv" = "$rv" ] || fail "the Rust reference is stale: '$rv' vs the port's '$pv' (rebuild it)"
say "port and Rust: $pv"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/in"
bash tests/golden/inputs.sh "$D" >/dev/null

OUT="$TMP/manifest.tsv"
: > "$OUT"
n=0

# run BIN OUT ARGS...: ARGS go before OUT (compression and `-d` both take the
# ok_rc RC: 0, or the warning the references and the port share for a -l that
# is not a power of two ("may be corrupt", exit 1). It reads $TMP/stderr from
# the run being checked.
ok_rc() {
    [ "$1" -eq 0 ] && return 0
    [ "$1" -eq 1 ] && grep -q 'Warning: -l parameter should be power of 2' "$TMP/stderr"
}

# output last); sets rc; does not abort.
run() {
    local bin=$1 out=$2
    shift 2
    rm -f "$out"
    rc=0
    "$bin" "$@" "$out" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
}

while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    input=${line%% *}
    args=${line#* }
    [ -f "$D/$input" ] || fail "no input $D/$input for '$line'"

    if [ "$input" = "$line" ]; then
        fail "malformed case (no args): '$line'"
    fi
    case " $args " in
        *" --format=v5 "*) fmt=v5 ;;
        *" --format=v4 "*) fmt=v4 ;;
        *) fail "case without --format: '$line'" ;;
    esac

    # shellcheck disable=SC2086
    run "$PORT" "$TMP/port.osr" $args --seed=7 "$D/$input"
    prc=$rc
    ok_rc "$prc" || fail "port: '$line' exited $prc: $(tail -1 "$TMP/stderr")"
    psum=$(sha256sum < "$TMP/port.osr" | cut -d' ' -f1)

    if [ "$fmt" = v4 ]; then
        cargs=${args//--format=v4/}
        # shellcheck disable=SC2086
        run "$CXX_BIN/osrep" "$TMP/cxx.osr" -t1 $cargs --seed=7 "$D/$input"
        crc=$rc
        ok_rc "$crc" || fail "C++: '$line' exited $crc: $(tail -1 "$TMP/stderr")"
        # shellcheck disable=SC2086
        run "$CXX_BIN/osrep" "$TMP/cxx2.osr" -t1 $cargs --seed=7 "$D/$input"
        ok_rc "$rc" || fail "C++ (second run): '$line' exited $rc"
        cmp -s "$TMP/cxx.osr" "$TMP/cxx2.osr" \
            || fail "C++: '$line' is not stable between two runs (races? see docs/pascal-port.md)"
        csum=$(sha256sum < "$TMP/cxx.osr" | cut -d' ' -f1)
        [ "$csum" = "$psum" ] || fail "port != C++ on '$line' ($psum vs $csum)"

        # The C++ must read the port's archive, and the port the C++'s.
        run "$CXX_BIN/osrep" "$TMP/cxx.dec" -d "$TMP/port.osr"
        [ "$rc" -eq 0 ] && cmp -s "$D/$input" "$TMP/cxx.dec" \
            || fail "the C++ cannot decode the port's archive for '$line'"
        run "$PORT" "$TMP/port.dec" -d "$TMP/cxx.osr"
        [ "$rc" -eq 0 ] && cmp -s "$D/$input" "$TMP/port.dec" \
            || fail "the port cannot decode the C++'s archive for '$line'"
    fi

    # The Rust reference, always: for v5 it is the only one, and for v4 it is
    # the second opinion that makes a mismatch unambiguous.
    # shellcheck disable=SC2086
    run "$RUST" "$TMP/rust.osr" $args --seed=7 "$D/$input"
    rrc=$rc
    ok_rc "$rrc" || fail "Rust: '$line' exited $rrc: $(tail -1 "$TMP/stderr")"
    # shellcheck disable=SC2086
    run "$RUST" "$TMP/rust2.osr" $args --seed=7 "$D/$input"
    ok_rc "$rc" || fail "Rust (second run): '$line' exited $rc"
    cmp -s "$TMP/rust.osr" "$TMP/rust2.osr" || fail "Rust: '$line' is not stable between two runs"
    rsum=$(sha256sum < "$TMP/rust.osr" | cut -d' ' -f1)
    [ "$rsum" = "$psum" ] || fail "port != Rust on '$line' ($psum vs $rsum)"

    run "$RUST" "$TMP/rust.dec" -d "$TMP/port.osr"
    [ "$rc" -eq 0 ] && cmp -s "$D/$input" "$TMP/rust.dec" \
        || fail "the Rust cannot decode the port's archive for '$line'"
    run "$PORT" "$TMP/port.dec" -d "$TMP/rust.osr"
    [ "$rc" -eq 0 ] && cmp -s "$D/$input" "$TMP/port.dec" \
        || fail "the port cannot decode the Rust's archive for '$line'"

    printf '%s\t%d\t%s\t%s\n' "$psum" "$prc" "$input" \
        "$(printf '%s' "$args" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')" >> "$OUT"
    n=$((n + 1))
done < tests/golden/cases.txt

[ "$n" -gt 0 ] || fail "no cases"
mv "$OUT" tests/golden/manifest.tsv
say "tests/golden/manifest.tsv: $n cases, port == C++ == Rust, all round-trip"
