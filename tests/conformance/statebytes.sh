#!/bin/sh
# The save-state CONTAINER gates over the whole AVM1 corpus.
#
# `savestate.sh` proves a restore reproduces the script OUTPUT, which is
# what content can observe. This proves the state is byte-COMPLETE: save,
# restore into a fresh player, re-save, and demand the same bytes. A
# payload that is silently dropped — a native the heap wrote as
# `deferred`, a display object the tree rebuilt as the wrong kind — shows
# up here even when the movie never reads it back.
#
#   sh tests/conformance/statebytes.sh [report]
#
# Needs `zig build libretro -Doptimize=ReleaseFast` first.
#
# Four dirs fail for reasons that have nothing to do with states: the
# libretro host cannot load `define_font_glyph_table_{order,overlap}` at
# all, and the two `file_reference_download_httperror_*` produce no
# output in it either way. Everything else passes.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORPUS="$ROOT/reference/ruffle/tests/tests/swfs/avm1"
HOST="$ROOT/zig-out/bin/libretro_test_host"
CORE="$ROOT/zig-out/libretro/flash_libretro.dylib"

one() {
    d=$1
    out=$(HANDYPLAY_FLASH_SAVESTATES=1 timeout 60 "$HOST" "$CORE" \
        "$CORPUS/$d/test.swf" --frames 0 --state 4 --quiet 2>&1)
    if printf '%s' "$out" | grep -q "state gates passed"; then
        echo "PASS $d"
    else
        why=$(printf '%s' "$out" | grep -E "INCOMPLETE|D3 FAIL|D4 FAIL|in section" | tr '\n' ' ')
        echo "FAIL $d ${why:-no output}"
    fi
}

# Re-entry point for xargs (sh has no exported functions).
if [ "${SB_ONE:-}" = 1 ]; then one "$2"; exit 0; fi

[ -x "$HOST" ] || { echo "build first: zig build libretro -Doptimize=ReleaseFast" >&2; exit 1; }
OUT=${1:-/tmp/hf_statebytes.txt}
JOBS=${2:-8}

dirs() {
    cd "$CORPUS" || exit 1
    for dir in */; do
        d=${dir%/}
        [ -f "$d/test.swf" ] && [ -f "$d/output.txt" ] || continue
        grep -qE '^known_failure( *= *true|\.)' "$d/test.toml" 2>/dev/null && continue
        echo "$d"
    done
}

dirs | SB_ONE=1 xargs -P "$JOBS" -I{} sh "$0" "$OUT" {} > "$OUT"
printf '%s of %s pass the byte gates\n' "$(grep -c '^PASS' "$OUT")" "$(wc -l < "$OUT" | tr -d ' ')"
grep '^FAIL' "$OUT"
exit 0
