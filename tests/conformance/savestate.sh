#!/bin/sh
# Save-state conformance: for every scorable corpus dir, run it twice —
# once straight through, once with a serialize/restore in the MIDDLE — and
# demand the two traces match.
#
#   sh tests/conformance/savestate.sh <results-file> [jobs]
#
# A state that restores wrong shows up here as diverging script output,
# which is both sharper and easier to localise than a pixel difference.
# The runner does the save at frame N/2 into a FRESH player (see
# `trace_runner --save-at`).
set -eu
OUT=${1:?usage: savestate.sh <results-file> [jobs]}
JOBS=${2:-8}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORPUS="$ROOT/reference/ruffle/tests/tests/swfs/avm1"
BIN="$ROOT/zig-out/bin/trace_runner"
[ -x "$BIN" ] || { echo "build $BIN first (-Doptimize=ReleaseFast)" >&2; exit 1; }

one() {
    d="$2"
    OUT="$1"
    toml="$CORPUS/$d/test.toml"
    swf="$CORPUS/$d/test.swf"
    n=$(sed -n 's/^num_ticks *= *\([0-9]*\).*/\1/p;s/^num_frames *= *\([0-9]*\).*/\1/p' "$toml" 2>/dev/null | head -1)
    n=${n:-1}
    [ "$n" -lt 2 ] && { echo "SKIP $d" >>"$OUT"; return; }
    inp=""
    [ -f "$CORPUS/$d/input.json" ] && inp="--input $CORPUS/$d/input.json"
    a=$(timeout 20 "$BIN" "$swf" --frames "$n" $inp 2>/dev/null) || { echo "SKIP $d" >>"$OUT"; return; }
    b=$(timeout 20 "$BIN" "$swf" --frames "$n" --save-at $((n / 2)) $inp 2>/dev/null) || { echo "FAIL $d" >>"$OUT"; return; }
    if [ "$a" = "$b" ]; then echo "PASS $d" >>"$OUT"; else echo "FAIL $d" >>"$OUT"; fi
}

dirs() {
    cd "$CORPUS" || exit 1
    for dir in */; do
        d=${dir%/}
        [ -f "$d/test.swf" ] && [ -f "$d/output.txt" ] || continue
        grep -qE '^known_failure( *= *true|\.)' "$d/test.toml" 2>/dev/null && continue
        echo "$d"
    done
}

# Re-entry point for xargs (sh has no exported functions), the same
# idiom sweep.sh uses — which is why $OUT must not be truncated below.
if [ "${SS_ONE:-}" = 1 ]; then one "$OUT" "$2"; exit 0; fi

: >"$OUT"
dirs | SS_ONE=1 xargs -P "$JOBS" -I{} sh "$0" "$OUT" {}
printf '%s of %s dirs survive a save/restore (%s skipped as single-frame)\n' \
    "$(grep -c '^PASS' "$OUT" || true)" \
    "$(grep -cE '^(PASS|FAIL)' "$OUT" || true)" \
    "$(grep -c '^SKIP' "$OUT" || true)"
