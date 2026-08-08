#!/bin/sh
# Parallel full-corpus sweep — the 10-minute serial run in ~20 seconds.
#
#   ~/.zvm/0.16.0/zig build -Doptimize=ReleaseFast   # REQUIRED first
#   sh tests/conformance/sweep.sh /tmp/results.txt
#   grep -c PASS /tmp/results.txt
#
# Compare against the ratchet to see exactly what moved:
#
#   grep PASS /tmp/results.txt | sed 's/^PASS //' | sort > /tmp/new.txt
#   comm -23 <(sort tests/conformance/pass_list.txt) /tmp/new.txt   # LOST
#   comm -13 <(sort tests/conformance/pass_list.txt) /tmp/new.txt   # gained
#
# Then, once clean:  cp /tmp/new.txt tests/conformance/pass_list.txt
#
# This duplicates run_avm1.sh's comparison rather than calling it, on
# purpose: run_avm1.sh is a single process doing one dir at a time, and
# the whole point here is `xargs -P`. Keep the two comparators in step —
# in particular the [approximations] path below.
set -u
CORPUS="${CORPUS:-reference/ruffle/tests/tests/swfs/avm1}"
# The DEVICE font the `with_default_font` dirs need. Ruffle bundles a Noto
# Sans subset (raw deflate despite the .gz) and its own harness registers
# exactly this file; the corpus was recorded on a machine with a real
# system font, which is why those dirs carry an epsilon.
DEVICE_FONT="${DEVICE_FONT:-reference/ruffle/core/assets/notosans.subset.ttf.gz}"
BIN=./zig-out/bin/trace_runner
OUT="${1:?usage: sweep.sh <results-file> [jobs]}"
JOBS="${2:-8}"

[ -x "$BIN" ] || { echo "build $BIN first (-Doptimize=ReleaseFast)" >&2; exit 1; }

# Scorable dirs: enumeration descends ONE level (generator dirs hold
# per-version subdirs), and `known_failure` dirs are excluded — that flag
# means RUFFLE does not match Flash there, so output.txt is a target
# nobody currently hits.
dirs() {
    cd "$CORPUS" || exit 1
    for dir in */ */*/; do
        d=${dir%/}
        [ "$d" = "__framework__" ] && continue
        [ -f "$d/test.swf" ] && [ -f "$d/output.txt" ] || continue
        grep -q '^known_failure *= *true' "$d/test.toml" 2>/dev/null && continue
        echo "$d"
    done
}

one() {
    d="$2"
    toml="$CORPUS/$d/test.toml"; swf="$CORPUS/$d/test.swf"
    # A few expected files are CRLF in ruffle's tree; its own comparator
    # normalizes them (framework/src/runner/trace.rs:14), so we must too.
    exp=$(mktemp); tr -d '\r' <"$CORPUS/$d/output.txt" >"$exp"
    n=$(sed -n 's/^num_frames *= *\([0-9]*\).*/\1/p; s/^num_ticks *= *\([0-9]*\).*/\1/p' \
        "$toml" 2>/dev/null | head -1)
    [ -n "$n" ] || n=1
    T=$(mktemp)
    # Input-driven dirs ship an input.json; `Wait` in it marks a tick.
    inp=""
    [ -f "$CORPUS/$d/input.json" ] && inp="--input $CORPUS/$d/input.json"
    # [player_options] viewport_dimensions = { width, height, scale_factor }
    vp=$(sed -n 's/^viewport_dimensions *= *{ *width *= *\([0-9]*\) *, *height *= *\([0-9]*\) *\(, *scale_factor *= *\([0-9.]*\)\)\{0,1\}.*/\1x\2@\4/p' "$toml" 2>/dev/null | head -1)
    case "$vp" in
        *@) vp="${vp}1" ;;
    esac
    [ -n "$vp" ] && vp="--viewport $vp"
    # [player_options] with_default_font — the dir needs a DEVICE font,
    # a face the movie did not embed. Flash used a real system font when
    # the expected output was recorded; ruffle approximates it with a
    # Noto Sans subset and these dirs all carry an [approximations]
    # epsilon to absorb the difference. We hand the same file over.
    df=""
    if grep -q '^with_default_font *= *true' "$toml" 2>/dev/null && [ -f "$DEVICE_FONT" ]; then
        df="--device-font $DEVICE_FONT"
    fi
    # [player_options] log_fetch — the harness's navigator traces every
    # request through the SAME sink as trace(), and those lines are part of
    # the expected output.
    lf=""
    grep -q '^log_fetch *= *true' "$toml" 2>/dev/null && lf="--log-fetch"
    # shellcheck disable=SC2086
    timeout 20 "$BIN" "$swf" --frames "$n" $inp $vp $df $lf >"$T" 2>/dev/null
    if grep -q '^bare_numbers *= *true' "$toml" 2>/dev/null; then
        eps=$(sed -n 's/^epsilon *= *\([0-9.eE+-]*\).*/\1/p' "$toml" | head -1)
        [ -n "$eps" ] || eps=2.220446049250313e-16
        mr=$(sed -n 's/^max_relative *= *\([0-9.eE+-]*\).*/\1/p' "$toml" | head -1)
        [ -n "$mr" ] || mr=2.220446049250313e-16
        # NB: `close` and `exp` are awk BUILTINS — hence approxeq/want/got.
        awk -v eps="$eps" -v maxrel="$mr" '
        function isnum(s){return s ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/}
        function isnan(s){return s ~ /^[+-]?[Nn][Aa][Nn]$/}
        function abs(x){return x<0?-x:x}
        function approxeq(a,b, diff,largest){
            if(a==b)return 1; diff=abs(a-b); if(diff<=eps)return 1
            largest=abs(a)>abs(b)?abs(a):abs(b); return diff<=largest*maxrel}
        NR==FNR{want[FNR]=$0;nwant=FNR;next}{got[FNR]=$0;ngot=FNR}
        END{if(nwant!=ngot)exit 1
            for(i=1;i<=nwant;i++){
                if(isnan(got[i])&&isnan(want[i]))continue
                if(isnum(got[i])&&isnum(want[i])){if(approxeq(got[i]+0,want[i]+0))continue;exit 1}
                if(got[i]!=want[i])exit 1}
            exit 0}' "$exp" "$T" \
            && echo "PASS $d" >>"$1" || echo "FAIL $d" >>"$1"
    else
        cmp -s "$T" "$exp" && echo "PASS $d" >>"$1" || echo "FAIL $d" >>"$1"
    fi
    rm -f "$T" "$exp"
}

# Re-entry point for xargs (sh has no exported functions), so the whole
# script re-runs per dir — which is why truncating $OUT must NOT happen
# above this line.
if [ "${SWEEP_ONE:-}" = 1 ]; then one "$OUT" "$2"; exit 0; fi

: >"$OUT"
dirs | SWEEP_ONE=1 xargs -P "$JOBS" -I{} sh "$0" "$OUT" {}
printf '%s of %s\n' "$(grep -c PASS "$OUT")" "$(grep -c . "$OUT")"
