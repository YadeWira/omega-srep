#!/usr/bin/env bash
# What the two binaries write to stderr (docs/rust-port.md).
#
# Why this exists. `report.rs` records a deliberate split: `-bar` is
# machine-parseable and its format is a contract, so it is reproduced exactly;
# the human progress and summary lines are reproduced "in shape" only, on the
# stated ground that "nothing -- no test, no wrapper -- reads those".
#
# That ground turned out to be false. A downstream consumer (ytool) was
# scraping the literal "Decompression memory is " out of the C++'s stderr to
# fill a field it shows to users. The port does not emit that line at all in
# the compression path, and no suite noticed, because they all diff archives
# and exit codes and never the text. It surfaced through the consumer.
#
# So this script tests two different things, and deliberately does NOT demand
# the two stderrs match:
#
#   1. **The `-bar` contract, asserted.** Every line `PROGRESS <done> <total>`
#      with plain digits, `done` non-decreasing, never past `total`, and a
#      final line with `done == total == the real input size`. The cadence is
#      time-based, so the *number* of lines is not part of the contract and is
#      not compared.
#
#   2. **An inventory of what each binary reports, recorded.** For a list of
#      facts, which binary mentions each one. This does not require them to
#      agree -- the human lines were never meant to. It requires any change in
#      who reports what to show up as a diff against a committed file, so that
#      dropping or adding a fact is a deliberate, visible act instead of
#      something a consumer discovers years later.
#
# Skips cleanly (exit 0) when the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping stderr conformance"
    exit 0
fi

RS="${OSREP_BIN:-target/release/osrep}"
[ -x "$RS" ] || cargo build --release >/dev/null 2>&1
[ -x "$RS" ] || fail "no Rust binary at $RS"
[ -x ./bin/osrep ] || make bin/osrep >/dev/null 2>&1
[ -x ./bin/osrep ] || fail "no C++ oracle at bin/osrep"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0

# A compressible input with real matches, so the summary lines have something
# to report; 12 MiB is enough for more than one progress tick.
cat tests/corpus/text.bin tests/corpus/text.bin tests/corpus/text.bin > "$TMP/in.bin" 2>/dev/null \
    || head -c 12582912 /dev/zero > "$TMP/in.bin"
INSIZE=$(stat -c%s "$TMP/in.bin")

# ---------------------------------------------------------------- 1. -bar --

# `-bar`'s contract (report.rs): PROGRESS <done> <total>, plain digits, no
# thousands separators, done non-decreasing and never past total, and a
# guaranteed final line at done == total.
check_bar() {
    local name="$1" file="$2"
    [ -s "$file" ] || fail "$name: -bar produced no PROGRESS lines"
    local prev=0 done total last_done last_total
    while read -r word d t rest; do
        [ "$word" = "PROGRESS" ] || fail "$name: stray word in -bar output: $word"
        [ -z "$rest" ] || fail "$name: extra fields on a PROGRESS line: $rest"
        case "$d$t" in *[!0-9]*) fail "$name: PROGRESS carries non-digits: '$d' '$t'";; esac
        [ "$d" -ge "$prev" ] || fail "$name: PROGRESS went backwards: $prev then $d"
        [ "$d" -le "$t" ] || fail "$name: PROGRESS done $d exceeds total $t"
        prev="$d"; last_done="$d"; last_total="$t"
    done < "$file"
    [ "$last_done" = "$last_total" ] \
        || fail "$name: last PROGRESS is $last_done of $last_total, expected them equal"
    [ "$last_done" = "$INSIZE" ] \
        || fail "$name: last PROGRESS totals $last_done, expected the input size $INSIZE"
}

say "the -bar contract holds for both binaries"
for m in m3 m4 m5; do
    ./bin/osrep -bar --seed=7 "-$m" "$TMP/in.bin" "$TMP/c.osr" 2>&1 >/dev/null \
        | grep -a '^PROGRESS' > "$TMP/c.bar" || true
    "$RS" --format=v4 -bar --seed=7 "-$m" "$TMP/in.bin" "$TMP/r.osr" 2>&1 >/dev/null \
        | grep -a '^PROGRESS' > "$TMP/r.bar" || true
    check_bar "C++ -$m"  "$TMP/c.bar"
    check_bar "port -$m" "$TMP/r.bar"
    # The archives must still agree; a -bar run that changed the output would
    # make the contract meaningless.
    cmp -s "$TMP/c.osr" "$TMP/r.osr" || fail "-$m: -bar changed the archive"
    pass=$((pass + 1))
done

# ------------------------------------------------------------ 2. inventory --

# Substrings that stand for a *fact being reported*, not for its formatting:
# each one either appears in a binary's stderr or does not.
FACTS="input size|memory used|hash=|Sorting matches|Decompression memory|matches =|% of file|Cpu |Remains|->"

# Collapse carriage returns (progress redraws in place) so a fact written
# after a \r is still found.
norm() { tr '\r' '\n' < "$1"; }

inventory() { # $1 = label, $2 = C++ stderr, $3 = port stderr
    local label="$1" c="$2" r="$3" fact cf rf
    printf '%s\n' "$label"
    local IFS='|'
    for fact in $FACTS; do
        # `--` matters: one of the facts is "->", which grep would otherwise
        # read as an option.
        if norm "$c" | grep -qaF -- "$fact"; then cf=yes; else cf=no; fi
        if norm "$r" | grep -qaF -- "$fact"; then rf=yes; else rf=no; fi
        printf '  %-22s cpp=%-3s port=%s\n' "$fact" "$cf" "$rf"
    done
}

{
    ./bin/osrep --seed=7 -m3 "$TMP/in.bin" "$TMP/ic.osr" 2>"$TMP/ic.err" >/dev/null
    "$RS" --format=v4 --seed=7 -m3 "$TMP/in.bin" "$TMP/ir.osr" 2>"$TMP/ir.err" >/dev/null
    inventory "compress -m3" "$TMP/ic.err" "$TMP/ir.err"

    ./bin/osrep -d "$TMP/ic.osr" "$TMP/dc.out" 2>"$TMP/dc.err" >/dev/null
    "$RS" -d "$TMP/ir.osr" "$TMP/dr.out" 2>"$TMP/dr.err" >/dev/null
    inventory "decompress" "$TMP/dc.err" "$TMP/dr.err"

    ./bin/osrep -i "$TMP/ic.osr" 2>"$TMP/nc.err" >/dev/null || true
    "$RS" -i "$TMP/ir.osr" 2>"$TMP/nr.err" >/dev/null || true
    inventory "-i" "$TMP/nc.err" "$TMP/nr.err"
} > "$TMP/inventory.txt"

EXPECTED="tests/stderr_inventory.expected"
if [ "${OSREP_BLESS_STDERR:-0}" = "1" ]; then
    cp "$TMP/inventory.txt" "$EXPECTED"
    say "blessed $EXPECTED"
elif [ ! -f "$EXPECTED" ]; then
    fail "$EXPECTED is missing -- run with OSREP_BLESS_STDERR=1 to record it"
else
    if ! diff -u "$EXPECTED" "$TMP/inventory.txt" > "$TMP/inv.diff"; then
        cat "$TMP/inv.diff" >&2
        fail "what the binaries report on stderr changed. If the change is intended,
      re-record with OSREP_BLESS_STDERR=1 and say so in the commit -- this file
      exists so that gaining or losing a reported fact is a visible decision."
    fi
fi
say "the stderr inventory matches $EXPECTED"
pass=$((pass + 1))

echo "  stderr_conformance: passed=$pass mismatches=0"
