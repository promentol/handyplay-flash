#!/bin/sh
# Author a test in ActionScript 2, run it in BOTH players, compare.
#
#   sh tools/as2/as2.sh build             # both images
#   sh tools/as2/as2.sh record [case...]  # compile + RUN RUFFLE, save expectations
#   sh tools/as2/as2.sh check  [case...]  # run ours against the saved ones
#   sh tools/as2/as2.sh run    [case...]  # record then check
#
# A case is a directory under tests/as2 holding `Test.as` and `test.toml`.
# Everything else in the directory is generated:
#
#   test.swf       compiled by mtasc in the compiler image
#   expected.png   what ruffle's wasm drew, through headless Chromium
#   expected.txt   what it traced
#   hf.png/hf.txt  ours, regenerated on every check
#
# The expectations are CHECKED IN, so `check` needs neither Docker nor a
# network — same bargain as ruffle's own corpus. `record` is the step
# that needs the browser, and it is the one you run deliberately.
#
# WHY TWO IMAGES: compiling is fast, offline and pure; running needs a
# browser. Keeping them apart means a change to one never rebuilds the
# other, and the compiler stays a 141 MB box anyone can run.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CASES_DIR="$ROOT/tests/as2"
COMPILER_IMAGE=${COMPILER_IMAGE:-handyflash-as2c}
RUNNER_IMAGE=${RUNNER_IMAGE:-handyflash-ruffle}
TRACE_BIN="$ROOT/zig-out/bin/trace_runner"
SDL_BIN="$ROOT/zig-out/bin/handyflash-sdl"
# How long ruffle is left running before the screenshot. It has no "tick
# N frames" API, so a case meant for comparison should settle on its
# first frame and then hold still.
SETTLE_MS=${SETTLE_MS:-900}

toml() { sed -n "s/^$2 *= *\"\{0,1\}\([^\"]*\)\"\{0,1\} *\$/\1/p" "$1/test.toml" | head -1; }

cases() {
    if [ $# -gt 0 ]; then
        for c in "$@"; do echo "$c"; done
    else
        for d in "$CASES_DIR"/*/; do
            [ -f "$d/Test.as" ] && basename "$d"
        done
    fi
}

do_build() {
    docker build -t "$COMPILER_IMAGE" "$ROOT/tools/as2/compiler"
    docker build -t "$RUNNER_IMAGE" "$ROOT/tools/as2/runner"
}

do_compile() {
    for c in $(cases "$@"); do
        d="$CASES_DIR/$c"
        w=$(toml "$d" width);   [ -n "$w" ] || w=200
        h=$(toml "$d" height);  [ -n "$h" ] || h=150
        f=$(toml "$d" fps);     [ -n "$f" ] || f=30
        v=$(toml "$d" swf_version); [ -n "$v" ] || v=8
        docker run --rm -v "$d:/work" "$COMPILER_IMAGE" \
            as2-compile Test.as test.swf "$w" "$h" "$f" "$v" >/dev/null
        printf '  compiled %-18s %s bytes\n' "$c" "$(wc -c <"$d/test.swf" | tr -d ' ')"
    done
}

do_record() {
    do_compile "$@"
    for c in $(cases "$@"); do
        d="$CASES_DIR/$c"
        # The reference: ruffle's own wasm, in a browser, in the runner.
        docker run --rm -v "$d:/work" "$RUNNER_IMAGE" \
            node /opt/ruffle-run.mjs test.swf expected.png expected.txt "$SETTLE_MS" 2>/dev/null
    done
}

do_check() {
    fail=0
    for c in $(cases "$@"); do
        d="$CASES_DIR/$c"
        # Ours: traces from the headless runner, pixels from the frontend.
        "$TRACE_BIN" "$d/test.swf" --frames 1 >"$d/hf.txt" 2>/dev/null || true
        "$SDL_BIN" "$d/test.swf" --headless-frames 1 --out "$d/hf.png" >/dev/null 2>&1 || true

        printf '\n%s\n' "$c"
        if diff -q "$d/expected.txt" "$d/hf.txt" >/dev/null 2>&1; then
            n=$(wc -l <"$d/hf.txt" | tr -d ' ')
            printf '  traces  MATCH (%s lines)\n' "$n"
        else
            printf '  traces  DIFFER\n'
            diff "$d/expected.txt" "$d/hf.txt" | head -12 | sed 's/^/    /'
            fail=1
        fi

        if [ "$(toml "$d" image)" = "false" ]; then
            printf '  image   skipped\n'
            continue
        fi
        tol=$(toml "$d" tolerance);      [ -n "$tol" ] || tol=4
        out=$(toml "$d" max_outliers);   [ -n "$out" ] || out=0
        res=$(python3 "$ROOT/tools/pngdiff.py" "$d/expected.png" "$d/hf.png" \
                  --tolerance="$tol" --max-outliers="$out" 2>&1 | head -1)
        printf '  image   %s\n' "$res"
        case "$res" in PASS*) ;; *) fail=1 ;; esac
    done
    return $fail
}

cmd=${1:-run}
[ $# -gt 0 ] && shift
case "$cmd" in
    build)   do_build ;;
    compile) do_compile "$@" ;;
    record)  do_record "$@" ;;
    check)   do_check "$@" ;;
    run)     do_record "$@"; do_check "$@" ;;
    *) echo "usage: as2.sh {build|compile|record|check|run} [case...]" >&2; exit 2 ;;
esac
