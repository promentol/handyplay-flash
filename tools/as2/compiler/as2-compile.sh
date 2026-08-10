#!/bin/sh
# Compile one AS2 source into a SWF with mtasc.
#
#   as2-compile <source.as> <out.swf> [width] [height] [fps] [swf-version]
#
# The source is a class named after the file, with a `static function
# main()`, which is the shape ruffle's CONTRIBUTING describes. mtasc's
# `-main` calls it once the movie's first frame runs.
set -eu
src=$1
out=$2
w=${3:-200}
h=${4:-150}
fps=${5:-30}
ver=${6:-8}
# BOTH class paths: `std8` carries the SWF8 additions and `std` the base
# headers, and mtasc refuses to start without the latter.
mtasc -version "$ver" \
      -cp /usr/local/share/mtasc/std8 -cp /usr/local/share/mtasc/std -main \
      -header "${w}:${h}:${fps}" "$src" -swf "$out"
