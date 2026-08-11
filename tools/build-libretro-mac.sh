#!/bin/sh
# Build the libretro core as a UNIVERSAL macOS dylib and, with `install`,
# put it where RetroArch looks.
#
#   sh tools/build-libretro-mac.sh            # -> zig-out/libretro/flash_libretro.dylib
#   sh tools/build-libretro-mac.sh install    # ... and copy it into RetroArch
#
# WHY UNIVERSAL. The RetroArch cask on this machine is an **x86_64**
# build (1.22.2) running under Rosetta, and a core is dlopened INTO the
# frontend's process — so an arm64-only core on an arm64 Mac silently
# fails to appear in the core list, which looks like a broken core rather
# than a mismatched one. Shipping both slices means it loads whichever
# RetroArch the user has.
#
# The `.info` file matters as much as the dylib: without one RetroArch
# shows the core as "Unknown" and will not associate `.swf` with it, so
# "Load Content" filters your movies out of its own file browser.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG=${ZIG:-$HOME/.zvm/0.16.0/zig}
OUT="$ROOT/zig-out/libretro"
CORES="$HOME/Library/Application Support/RetroArch/cores"
INFO="$HOME/Library/Application Support/RetroArch/info"

build() {
    printf 'building %s\n' "$1"
    "$ZIG" build libretro -Dtarget="$1" -Doptimize=ReleaseFast --prefix "$ROOT/zig-out"
    cp "$OUT/flash_libretro.dylib" "$OUT/flash_libretro.$2"
}

build aarch64-macos arm64
build x86_64-macos x86_64

lipo -create \
    "$OUT/flash_libretro.arm64" \
    "$OUT/flash_libretro.x86_64" \
    -output "$OUT/flash_libretro.dylib"
rm -f "$OUT/flash_libretro.arm64" "$OUT/flash_libretro.x86_64"
cp "$ROOT/frontends/libretro/flash_libretro.info" "$OUT/flash_libretro.info"

printf '\n%s\n' "$(lipo -archs "$OUT/flash_libretro.dylib") in $OUT/flash_libretro.dylib"

if [ "${1:-}" = "install" ]; then
    mkdir -p "$CORES" "$INFO"
    cp "$OUT/flash_libretro.dylib" "$CORES/"
    cp "$OUT/flash_libretro.info" "$INFO/"
    printf 'installed to %s\n' "$CORES"
    printf 'RetroArch: Load Core -> handyplay-flash, then Load Content -> a .swf\n'
fi
