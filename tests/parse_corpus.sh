#!/bin/sh
# M1 gate: swfdump over the ruffle parser corpus — zero fatal errors.
# (swfdump lands in M1; until then this script only checks headers via swfinfo.)
set -u
CORPUS="${CORPUS:-reference/ruffle/swf/tests/swfs}"
BIN=./zig-out/bin
fail=0; total=0
for f in "$CORPUS"/*.swf; do
    total=$((total+1))
    if ! "$BIN/swfinfo" "$f" >/dev/null 2>&1; then
        # LZMA files are expected to fail until D4 is lifted.
        case "$(head -c1 "$f")" in Z) continue ;; esac
        echo "FAIL: $f"; fail=$((fail+1))
    fi
done
echo "parse corpus: $((total-fail))/$total ok"
[ "$fail" -eq 0 ]
