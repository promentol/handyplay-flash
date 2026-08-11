#!/bin/sh
# Build the release matrix locally — the same targets, flags and zips the
# `release` workflow produces, so a tag can be rehearsed before it is
# pushed.
#
#   sh tools/build-release.sh                 # every desktop platform
#   sh tools/build-release.sh linux-x86_64    # just one
#   ANDROID_NDK_HOME=... sh tools/build-release.sh android-arm64-v8a
#
# macOS hosts also get the universal Darwin build (it needs `lipo`).
# Android needs an NDK: set ANDROID_NDK_HOME (or ANDROID_NDK_LATEST_HOME)
# and the script finds the sysroot for this host.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
ZIG=${ZIG:-$HOME/.zvm/0.16.0/zig}
command -v "$ZIG" >/dev/null 2>&1 || ZIG=zig
WANT=${1:-all}

# platform            zig target            extra flags        library name
MATRIX='
linux-x86_64          x86_64-linux-gnu      -                  flash_libretro.so
linux-i686            x86-linux-gnu         -                  flash_libretro.so
linux-aarch64         aarch64-linux-gnu     -                  flash_libretro.so
linux-armhf           arm-linux-gnueabihf   -                  flash_libretro.so
windows-x86_64        x86_64-windows-gnu    -                  flash_libretro.dll
windows-i686          x86-windows-gnu       -                  flash_libretro.dll
android-arm64-v8a     aarch64-linux-android -                  flash_libretro.so
android-armeabi-v7a   arm-linux-androideabi -Dcpu=cortex_a8    flash_libretro.so
android-x86_64        x86_64-linux-android  -                  flash_libretro.so
android-x86           x86-linux-android     -                  flash_libretro.so
'

ndk_sysroot() {
    ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}
    [ -n "$ndk" ] || return 1
    for host in darwin-x86_64 linux-x86_64; do
        s="$ndk/toolchains/llvm/prebuilt/$host/sysroot"
        [ -d "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

echo "$MATRIX" | while read -r plat target extra lib; do
    [ -n "${plat:-}" ] || continue
    case "$WANT" in all) ;; "$plat") ;; *) continue ;; esac
    [ "$extra" = "-" ] && extra=""
    sysroot_arg=""
    case "$plat" in
        android-*)
            if s=$(ndk_sysroot); then
                sysroot_arg="--sysroot $s -Dandroid-api=29"
            else
                echo "skip $plat (no NDK: set ANDROID_NDK_HOME)"
                continue
            fi
            ;;
    esac
    printf '=== %s (%s)\n' "$plat" "$target"
    out="$ROOT/.release/$plat"
    rm -rf "$out"
    # shellcheck disable=SC2086
    "$ZIG" build libretro -Doptimize=ReleaseFast -Dstrip=true \
        -Dtarget="$target" $extra $sysroot_arg -p "$out"
    core="$out/libretro/$lib"
    case "$plat" in
        android-*)
            # RetroArch's Android build looks for the `_android` suffix.
            mv "$core" "$out/libretro/flash_libretro_android.so"
            core="$out/libretro/flash_libretro_android.so"
            ;;
    esac
    sh "$ROOT/tools/package-core.sh" "$plat" "$core"
done

# Darwin is built on a Mac so `lipo` can fuse the two arches into the one
# universal binary RetroArch loads whichever way it was itself built.
if [ "$(uname -s)" = "Darwin" ]; then
    case "$WANT" in all|macos-universal)
        printf '=== macos-universal\n'
        for arch in aarch64 x86_64; do
            "$ZIG" build libretro -Doptimize=ReleaseFast -Dstrip=true \
                -Dtarget="$arch-macos" -p "$ROOT/.release/macos-$arch"
        done
        mkdir -p "$ROOT/.release/universal"
        lipo -create \
            "$ROOT/.release/macos-aarch64/libretro/flash_libretro.dylib" \
            "$ROOT/.release/macos-x86_64/libretro/flash_libretro.dylib" \
            -output "$ROOT/.release/universal/flash_libretro.dylib"
        lipo -archs "$ROOT/.release/universal/flash_libretro.dylib"
        sh "$ROOT/tools/package-core.sh" macos-universal \
            "$ROOT/.release/universal/flash_libretro.dylib"
        ;;
    esac
fi

printf '\nzips in %s/dist:\n' "$ROOT"
ls -1 "$ROOT/dist" 2>/dev/null || true
