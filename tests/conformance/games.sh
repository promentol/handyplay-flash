#!/bin/sh
# The save-state gates over every real game in games/.
#
# The corpus dirs (savestate.sh) prove a restore reproduces the SCRIPT
# OUTPUT; this proves the container rules hold on movies big enough to
# have BitmapData, sound and deep timelines: D3 (two saves identical),
# D4 (size stable), restore completeness (a re-save reproduces the blob)
# and the D1 one-frame delta a rewind layer would store.
#
#   sh tests/conformance/games.sh [report] [frames]
#
# Needs `zig build libretro -Doptimize=ReleaseFast` first.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REPORT=${1:-/tmp/hf_games.txt}
AT=${2:-60}
HOST="$ROOT/zig-out/bin/libretro_test_host"
CORE="$ROOT/zig-out/libretro/flash_libretro.dylib"
[ -x "$HOST" ] || { echo "build first: zig build libretro -Doptimize=ReleaseFast"; exit 1; }

: > "$REPORT"
pass=0
total=0
for swf in "$ROOT"/games/*.swf; do
    total=$((total + 1))
    name=$(basename "$swf")
    out=$(HANDYPLAY_FLASH_SAVESTATES=1 timeout 300 "$HOST" "$CORE" "$swf" \
        --frames 0 --state "$AT" --quiet 2>&1)
    if printf '%s' "$out" | grep -q "state gates passed"; then
        pass=$((pass + 1))
        size=$(printf '%s' "$out" | sed -n 's/.*serialize_size=\([0-9]*\)B.*/\1/p')
        delta=$(printf '%s' "$out" | sed -n 's/.*-> ~\([0-9]*\)B\/frame.*/\1/p')
        echo "PASS $name size=${size:-?} delta=${delta:-?}" >> "$REPORT"
    else
        why=$(printf '%s' "$out" | grep -E "\[state\].*(FAIL|error|mismatch)" | head -1)
        echo "FAIL $name ${why:-no gate output}" >> "$REPORT"
    fi
done
echo "$pass of $total games pass the state gates"
grep '^FAIL' "$REPORT"
exit 0
