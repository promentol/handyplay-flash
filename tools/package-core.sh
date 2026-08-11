#!/bin/sh
# Wrap one built core into the zip a release ships.
#
#   sh tools/package-core.sh <platform> <path/to/core>
#   sh tools/package-core.sh linux-x86_64 zig-out/libretro/flash_libretro.so
#
# Lives in the repo rather than inside the workflow so the packaging can
# be run — and checked — without pushing a tag. The version comes from
# the tag being built (`TAG`, or GitHub's `GITHUB_REF_NAME`), and falls
# back to `git describe` for a local run.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=${1:?usage: package-core.sh <platform> <core-path>}
CORE=${2:?usage: package-core.sh <platform> <core-path>}
[ -f "$CORE" ] || { echo "no core at $CORE" >&2; exit 1; }

VERSION=${TAG:-${GITHUB_REF_NAME:-}}
[ -n "$VERSION" ] || VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)
VERSION=${VERSION#v}

OUT="$ROOT/dist"
STAGE="$OUT/stage-$PLATFORM"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"

cp "$CORE" "$STAGE/"
# The `.info` file is what makes RetroArch call the core by its name and
# associate `.swf` with it, so it ships beside the binary. Its
# `display_version` is stamped from the tag rather than tracked by hand.
sed "s/^display_version = .*/display_version = \"$VERSION\"/" \
    "$ROOT/frontends/libretro/flash_libretro.info" > "$STAGE/flash_libretro.info"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"

# Only claim a source URL when the build actually knows one.
SOURCE_LINE=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    SOURCE_LINE=" Source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
fi

cat > "$STAGE/README.txt" <<EOF
handyplay-flash $VERSION — a libretro core for Flash (SWF 4-8, AVM1)
platform: $PLATFORM

Install
  Copy $(basename "$CORE") into RetroArch's cores directory and
  flash_libretro.info into its info directory:

    Linux    ~/.config/retroarch/cores        ~/.config/retroarch/info
    macOS    ~/Library/Application Support/RetroArch/cores  (…/info)
    Windows  <RetroArch>\\cores                <RetroArch>\\info
    Android  RetroArch's own core directory (Load Core -> Install from file)

  Then Load Core -> handyplay-flash, Load Content -> a .swf.

The pad is bound to each movie's OWN keys, surveyed from its bytecode at
load. Every binding, plus playback speed and save states, is in Quick
Menu -> Core Options.

AGPL-3.0 — see LICENSE.$SOURCE_LINE
EOF

ZIP="$OUT/flash_libretro-$VERSION-$PLATFORM.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -q -9 -r "$ZIP" .)
rm -rf "$STAGE"
ls -l "$ZIP"
