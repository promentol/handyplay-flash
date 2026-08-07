#!/bin/sh
# M1 gate: swfdump over the ruffle parser corpus — zero fatal errors, and
# no per-tag decode errors on in-scope tags. LZMA (ZWS) files are expected
# to fail until ADR D4 is lifted.
set -u
CORPUS="${CORPUS:-reference/ruffle/swf/tests/swfs}"
BIN=./zig-out/bin
fail=0; total=0; decode_warn=0
for f in "$CORPUS"/*.swf; do
    total=$((total+1))
    case "$(head -c1 "$f")" in Z) continue ;; esac
    out=$("$BIN/swfdump" "$f" 2>&1)
    if [ $? -ne 0 ]; then
        echo "FATAL: $f"
        echo "$out" | tail -2
        fail=$((fail+1))
        continue
    fi
    if echo "$out" | grep -q '!decode-error'; then
        echo "DECODE: $f"
        echo "$out" | grep '!decode-error' | head -3
        decode_warn=$((decode_warn+1))
    fi
done
echo "parse corpus: $((total-fail)) scanned / $total ok, $decode_warn with decode errors"
[ "$fail" -eq 0 ] && [ "$decode_warn" -eq 0 ]
