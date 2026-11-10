#!/usr/bin/env bash
# Mutation audit: for every tests/mutations/NN-*.py, copy HEAD into a scratch
# dir, apply the mutation, build the Pascal natively, and run the core gates.
# A mutation is CAUGHT when the core fails; SURVIVED when it passes, which
# means the suite does not cover what that mutation broke and a case is
# missing.
#
# Usage: tests/mutations/run.sh [substring]
#        OSREP_MUTATION_LOGS=dir tests/mutations/run.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FILTER=${1:-}
LOGS=${OSREP_MUTATION_LOGS:-}
[ -n "$LOGS" ] || LOGS="$(mktemp -d)"
mkdir -p "$LOGS"

caught=0; survived=0; broken=0; survived_names=""

for m in tests/mutations/[0-9]*.py; do
    [ -f "$m" ] || continue
    name=$(basename "$m" .py)
    case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    printf '== %s\n' "$name"
    T=$(mktemp -d) || exit 1
    mkdir -p "$LOGS/$name"
    if ! git archive HEAD | tar -x -C "$T"; then
        printf 'FAIL: cannot export HEAD\n' >&2; exit 1
    fi
    if ! ( cd "$T" && python3 "$ROOT/$m" ); then
        printf '   BROKEN: the mutation does not apply\n'
        broken=$((broken + 1)); rm -rf "$T"; continue
    fi
    mkdir -p "$T/u" "$T/pascal/bin"
    if ! ( cd "$T" && fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FU"$T/u" \
             -opascal/bin/osrep-linux-x86_64 pascal/osrep.lpr ) \
             > "$LOGS/$name/build.log" 2>&1; then
        printf '   BROKEN: the mutated tree does not build\n'
        broken=$((broken + 1)); rm -rf "$T"; continue
    fi
    if ! ( cd "$T" && fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FU"$T/u" \
             -opascal/bin/hashtool pascal/hashtool.lpr ) \
             > "$LOGS/$name/build-hashtool.log" 2>&1; then
        printf '   BROKEN: hashtool does not build\n'
        broken=$((broken + 1)); rm -rf "$T"; continue
    fi
    ( cd "$T" && timeout 1800 env \
        OSREP_PORT_BIN="$T/pascal/bin/osrep-linux-x86_64" \
        OSREP_GATES_LOGS="$LOGS/$name/gates" \
        bash tests/gates.sh core > "$LOGS/$name/core.log" 2>&1 )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '   SURVIVED: the core passed\n'
        survived=$((survived + 1)); survived_names="$survived_names $name"
    else
        printf '   caught by: %s\n' "$(grep -E 'rc=[1-9]|FAILED' "$LOGS/$name/core.log" | head -2 | tr '\n' ' ')"
        caught=$((caught + 1))
    fi
    rm -rf "$T"
done

printf '\nmutations: caught=%d survived=%d broken=%d\n' "$caught" "$survived" "$broken"
[ -z "$survived_names" ] || printf 'survivors:%s\n' "$survived_names"
[ -n "$OSREP_MUTATION_LOGS" ] || { [ "$survived" -eq 0 ] && rm -rf "$LOGS" || printf 'logs: %s\n' "$LOGS"; }
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
