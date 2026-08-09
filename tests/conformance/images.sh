#!/bin/sh
# Image-comparison sweep — the SECOND, independent conformance score.
#
#   ~/.zvm/0.16.0/zig build sdl -Doptimize=ReleaseFast   # REQUIRED first
#   sh tests/conformance/images.sh /tmp/images.txt
#
# Ruffle's corpus carries `[image_comparisons.<name>]` in test.toml with a
# per-CHANNEL `tolerance` and an allowed `max_outliers`; the reference sits
# beside the SWF as `<name>.expected.png`. The rule is ruffle's
# (tests/framework/src/runner/image_test.rs:251) and lives in tools/pngdiff.py.
#
# WHY THIS IS SEPARATE FROM sweep.sh: 21 of the 34 image dirs already pass on
# TRACES today (masks, gradients, bitmap data, focus rects). Folding pixels
# into that score would turn most of them red and collapse the ratchet. So
# this reports its own number against its own ratchet:
#
#   grep PASS /tmp/images.txt | sed 's/^PASS //' | sort > /tmp/inew.txt
#   comm -23 <(sort tests/conformance/image_pass_list.txt) /tmp/inew.txt   # LOST
#   comm -13 <(sort tests/conformance/image_pass_list.txt) /tmp/inew.txt   # gained
#   cp /tmp/inew.txt tests/conformance/image_pass_list.txt   # only when LOST is empty
#
# Dirs whose comparisons carry a `trigger` (a mid-run capture driven by
# fscommand) are SKIPPED and reported as such — we only render the final
# frame. That is 6 of the 34.
#
# An `input.json` beside the SWF is replayed, one batch per tick.
set -u
CORPUS="${CORPUS:-reference/ruffle/tests/tests/swfs/avm1}"
BIN=./zig-out/bin/handyflash-sdl
OUT="${1:?usage: images.sh <results-file>}"

[ -x "$BIN" ] || { echo "build $BIN first (zig build sdl -Doptimize=ReleaseFast)" >&2; exit 1; }

: >"$OUT"
skipped=0

for toml in "$CORPUS"/*/test.toml; do
    d=$(basename "$(dirname "$toml")")
    grep -q '^\[image_comparisons\|^image_comparisons' "$toml" 2>/dev/null || continue
    grep -qE '^known_failure( *= *true|\.)' "$toml" 2>/dev/null && continue
    [ -f "$CORPUS/$d/test.swf" ] || continue

    # A trigger means "capture mid-run"; we only have the final frame.
    if grep -q 'trigger' "$toml"; then
        echo "SKIP $d (trigger)" >>"$OUT"
        skipped=$((skipped + 1))
        continue
    fi

    name=$(sed -n 's/^\[image_comparisons\.\{1,\}\("\{0,1\}\)\([A-Za-z0-9_.-]*\)\1\]/\2/p' "$toml" | head -1)
    [ -n "$name" ] || name=output
    exp="$CORPUS/$d/$name.expected.png"
    [ -f "$exp" ] || { echo "SKIP $d (no $name.expected.png)" >>"$OUT"; skipped=$((skipped + 1)); continue; }

    n=$(sed -n 's/^num_frames *= *\([0-9]*\).*/\1/p; s/^num_ticks *= *\([0-9]*\).*/\1/p' "$toml" | head -1)
    [ -n "$n" ] || n=1
    tol=$(sed -n 's/^tolerance *= *\([0-9]*\).*/\1/p' "$toml" | head -1)
    [ -n "$tol" ] || tol=0
    mo=$(sed -n 's/^max_outliers *= *\([0-9]*\).*/\1/p' "$toml" | head -1)
    [ -n "$mo" ] || mo=0

    # A recorded input script drives the run, exactly as it does for the
    # trace score — several image dirs only differ from their expectation
    # by a button that was never pressed.
    inp=""
    [ -f "$CORPUS/$d/input.json" ] && inp="--input $CORPUS/$d/input.json"

    T=$(mktemp -t hfimg).png
    # shellcheck disable=SC2086
    if timeout 30 "$BIN" "$CORPUS/$d/test.swf" --headless-frames "$n" $inp --out "$T" >/dev/null 2>&1 &&
       python3 tools/pngdiff.py "$exp" "$T" --tolerance="$tol" --max-outliers="$mo" >/dev/null 2>&1; then
        echo "PASS $d" >>"$OUT"
    else
        echo "FAIL $d" >>"$OUT"
    fi
    rm -f "$T"
done

printf '%s of %s image comparisons (%s skipped)\n' \
    "$(grep -c '^PASS' "$OUT")" "$(grep -c '^PASS\|^FAIL' "$OUT")" "$skipped"
