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
#
# A test.toml may carry an [approximations] table, in which case numeric
# lines compare with a tolerance instead of byte-exactly (ruffle
# tests/framework/src/runner/trace.rs + options/approximations.rs).
#
# Some corpus entries are GENERATOR dirs holding per-version subdirs
# (target_paths/swf4, set_property_values/swf5, bitmap_data_thorough/*),
# so enumeration descends one level. Dirs marked `known_failure = true`
# are excluded from scoring entirely: that flag means RUFFLE ITSELF does
# not match Flash there, so output.txt is a target nobody currently hits.
set -u
CORPUS="${CORPUS:-reference/ruffle/tests/tests/swfs/avm1}"
# The DEVICE font the `with_default_font` dirs need. Ruffle bundles a Noto
# Sans subset (raw deflate despite the .gz) and its own harness registers
# exactly this file; the corpus was recorded on a machine with a real
# system font, which is why those dirs carry an epsilon.
DEVICE_FONT="${DEVICE_FONT:-reference/ruffle/core/assets/notosans.subset.ttf.gz}"
BIN=./zig-out/bin/trace_runner
LIST=tests/conformance/pass_list.txt
TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.exp"' EXIT

frames_for() {
    # num_frames or num_ticks from test.toml (default 1).
    n=$(sed -n 's/^num_frames *= *\([0-9]*\).*/\1/p; s/^num_ticks *= *\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1)
    [ -n "$n" ] || n=1
    echo "$n"
}

# [player_options] with_default_font — the dir needs a DEVICE font, a
# face the movie did not embed. Flash used a real system font when the
# expected output was recorded; ruffle approximates it with a Noto Sans
# subset, and those dirs all carry an [approximations] epsilon to absorb
# the difference. We hand the same file over.
device_font_for() {
    if grep -q '^with_default_font *= *true' "$CORPUS/$1/test.toml" 2>/dev/null &&
       [ -f "$DEVICE_FONT" ]; then
        echo "--device-font $DEVICE_FONT"
    fi
}

# [player_options] log_fetch — the harness's navigator traces every request
# through the SAME sink as trace(), so those lines belong in the output.
log_fetch_for() {
    grep -q '^log_fetch *= *true' "$CORPUS/$1/test.toml" 2>/dev/null && echo "--log-fetch"
}

have_approx() {
    # 0 if test.toml has [approximations] with bare_numbers = true.
    grep -q '^bare_numbers *= *true' "$1" 2>/dev/null
}

toml_num() {
    # toml_num <file> <key> <default>
    v=$(sed -n "s/^$2 *= *\([0-9.eE+-]*\).*/\1/p" "$1" 2>/dev/null | head -1)
    [ -n "$v" ] || v="$3"
    echo "$v"
}

# Mirror of ruffle's approximate trace comparison: line counts must match,
# then per line — if BOTH sides parse as numbers, accept them within
# (epsilon, max_relative) per the `approx` crate's relative_eq; two NaNs
# also pass; otherwise the strings must match exactly. The regex-driven
# `number_patterns` mode is unused by every AVM1 corpus dir, so it is not
# implemented.
approx_cmp() {
    # approx_cmp <actual> <expected> <epsilon> <max_relative>
    # NOTE: `close` and `exp` are awk builtins — do not use them as names.
    awk -v eps="$3" -v maxrel="$4" '
    function isnum(s) { return s ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/ }
    function isnan(s) { return s ~ /^[+-]?[Nn][Aa][Nn]$/ }
    function abs(x)   { return x < 0 ? -x : x }
    function approxeq(a, b,   diff, largest) {
        if (a == b) return 1
        diff = abs(a - b)
        if (diff <= eps) return 1
        largest = abs(a) > abs(b) ? abs(a) : abs(b)
        return diff <= largest * maxrel
    }
    NR == FNR { want[FNR] = $0; nwant = FNR; next }
    { got[FNR] = $0; ngot = FNR }
    END {
        if (nwant != ngot) exit 1
        for (i = 1; i <= nwant; i++) {
            if (isnan(got[i]) && isnan(want[i])) continue
            if (isnum(got[i]) && isnum(want[i])) {
                if (approxeq(got[i] + 0, want[i] + 0)) continue
                exit 1
            }
            if (got[i] != want[i]) exit 1
        }
        exit 0
    }' "$2" "$1"
}

is_known_failure() {
    # Ruffle's own harness flag: this dir diverges from Flash even in
    # ruffle, so output.txt is not a target any emulator currently meets.
    grep -q '^known_failure *= *true' "$1" 2>/dev/null
}

# Every scorable dir, one per line, relative to $CORPUS. Descends one
# level so generator dirs' per-version tests are reachable, and requires
# both a test.swf and an output.txt (the generator dirs themselves have
# neither and must not count as failures).
scorable_dirs() {
    (
        cd "$CORPUS" || exit 1
        for dir in */ */*/; do
            d=${dir%/}
            [ "$d" = "__framework__" ] && continue
            [ -f "$d/test.swf" ] && [ -f "$d/output.txt" ] || continue
            is_known_failure "$d/test.toml" && continue
            echo "$d"
        done
    )
}

# Input-driven dirs ship an input.json; `Wait` in it marks a tick boundary.
# [player_options] viewport_dimensions = { width, height, scale_factor }
viewport_for() {
    vp=$(sed -n 's/^viewport_dimensions *= *{ *width *= *\([0-9]*\) *, *height *= *\([0-9]*\) *\(, *scale_factor *= *\([0-9.]*\)\)\{0,1\}.*/\1x\2@\4/p' \
        "$CORPUS/$1/test.toml" 2>/dev/null | head -1)
    case "$vp" in
        "") return 0 ;;
        *@) vp="${vp}1" ;;
    esac
    printf -- '--viewport %s' "$vp"
}

input_for() {
    [ -f "$CORPUS/$1/input.json" ] && printf -- '--input %s' "$CORPUS/$1/input.json"
}

run_one() {
    d="$1"
    swf="$CORPUS/$d/test.swf"
    toml="$CORPUS/$d/test.toml"
    [ -f "$swf" ] && [ -f "$CORPUS/$d/output.txt" ] || return 2
    # A few expected files are CRLF in ruffle's tree; its own comparator
    # normalizes them (framework/src/runner/trace.rs:14), so we must too.
    exp="$TMP.exp"; tr -d '\r' <"$CORPUS/$d/output.txt" >"$exp"
    # shellcheck disable=SC2086
    "$BIN" "$swf" --frames "$(frames_for "$toml")" $(input_for "$d") $(viewport_for "$d") $(device_font_for "$d") $(log_fetch_for "$d") >"$TMP" 2>/dev/null || return 1
    if have_approx "$toml"; then
        # `approx`'s defaults are f64::EPSILON for both knobs.
        approx_cmp "$TMP" "$exp" \
            "$(toml_num "$toml" epsilon 2.220446049250313e-16)" \
            "$(toml_num "$toml" max_relative 2.220446049250313e-16)"
    else
        diff -q "$TMP" "$exp" >/dev/null 2>&1
    fi
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
    for d in $(scorable_dirs); do
        total=$((total+1))
        if run_one "$d"; then
            pass=$((pass+1))
            echo "$d" >> "$PASSED"
        fi
    done
    skipped=$(cd "$CORPUS" && for dir in */ */*/; do
        d=${dir%/}
        [ -f "$d/test.toml" ] && is_known_failure "$d/test.toml" && echo "$d"
    done | wc -l)
    echo "conformance: $pass/$total pass ($(echo $skipped) known_failure dirs excluded)"
    if [ "${1:-}" = "--update" ]; then
        {
            echo "# dirs under reference/ruffle/tests/tests/swfs/avm1/ that pass."
            echo "# RATCHET: append-only — never remove a passing entry."
            echo "# Byte-exact unless test.toml has [approximations]."
            echo "# Dirs marked known_failure = true are excluded (ruffle fails them too)."
            sort "$PASSED"
        } > "$LIST"
        echo "pass_list.txt updated ($pass entries)"
    fi
    rm -f "$PASSED"
    ;;
*)
    d="$1"
    swf="$CORPUS/$d/test.swf"
    toml="$CORPUS/$d/test.toml"
    if run_one "$d"; then verdict=PASS; else verdict=FAIL; fi
    have_approx "$toml" && verdict="$verdict (approximate)"
    # Re-run with stderr merged so panics show up in the diff.
    # shellcheck disable=SC2086
    "$BIN" "$swf" --frames "$(frames_for "$toml")" $(input_for "$d") $(viewport_for "$d") $(device_font_for "$d") $(log_fetch_for "$d") >"$TMP" 2>&1
    echo "--- $verdict: ours vs expected ($d):"
    tr -d '\r' <"$CORPUS/$d/output.txt" >"$TMP.exp"
    diff "$TMP" "$TMP.exp" | head -40
    ;;
esac
