#!/bin/sh
# AVM1 trace-conformance runner over the ruffle corpus.
#
#   sh tests/conformance/run_avm1.sh              # run everything, summary
#   sh tests/conformance/run_avm1.sh --ratchet    # verify pass_list.txt only
#   sh tests/conformance/run_avm1.sh --update     # rewrite pass_list.txt
#   sh tests/conformance/run_avm1.sh <dir-name>   # run one test, show diff
#
# Each corpus dir has test.swf + output.txt (expected trace, line-exact)
# + test.toml (num_frames / num_ticks). pass_list.txt is APPEND-ONLY in
# normal use — a formerly-passing test that fails is a regression.
set -u
CORPUS="${CORPUS:-reference/ruffle/tests/tests/swfs/avm1}"
BIN=./zig-out/bin/trace_runner
LIST=tests/conformance/pass_list.txt
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

frames_for() {
    # num_frames or num_ticks from test.toml (default 1).
    n=$(sed -n 's/^num_frames *= *\([0-9]*\).*/\1/p; s/^num_ticks *= *\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1)
    [ -n "$n" ] || n=1
    echo "$n"
}

run_one() {
    d="$1"
    swf="$CORPUS/$d/test.swf"
    exp="$CORPUS/$d/output.txt"
    toml="$CORPUS/$d/test.toml"
    [ -f "$swf" ] && [ -f "$exp" ] || return 2
    "$BIN" "$swf" --frames "$(frames_for "$toml")" >"$TMP" 2>/dev/null || return 1
    diff -q "$TMP" "$exp" >/dev/null 2>&1
}

case "${1:-}" in
--ratchet)
    fail=0
    total=0
    while IFS= read -r d; do
        case "$d" in ''|\#*) continue ;; esac
        total=$((total+1))
        if ! run_one "$d"; then
            echo "REGRESSION: $d"
            fail=$((fail+1))
        fi
    done < "$LIST"
    echo "ratchet: $((total-fail))/$total"
    exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
    ;;
--update|"")
    pass=0; total=0
    PASSED=$(mktemp)
    for dir in "$CORPUS"/*/; do
        d=$(basename "$dir")
        [ "$d" = "__framework__" ] && continue
        total=$((total+1))
        if run_one "$d"; then
            pass=$((pass+1))
            echo "$d" >> "$PASSED"
        fi
    done
    echo "conformance: $pass/$total pass"
    if [ "${1:-}" = "--update" ]; then
        {
            echo "# dirs under reference/ruffle/tests/tests/swfs/avm1/ that pass exactly."
            echo "# RATCHET: append-only — never remove a passing entry."
            sort "$PASSED"
        } > "$LIST"
        echo "pass_list.txt updated ($pass entries)"
    fi
    rm -f "$PASSED"
    ;;
*)
    d="$1"
    swf="$CORPUS/$d/test.swf"
    "$BIN" "$swf" --frames "$(frames_for "$CORPUS/$d/test.toml")" >"$TMP" 2>&1
    echo "--- ours vs expected ($d):"
    diff "$TMP" "$CORPUS/$d/output.txt" | head -40
    ;;
esac
