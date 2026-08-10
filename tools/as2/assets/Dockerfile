# STATIC ASSETS: the half mtasc cannot do.
#
# mtasc compiles code and nothing else — a movie it builds from scratch
# holds a DoAction and an empty sprite, no shapes, no images, no fonts.
# For a test that needs a real `DefineBits` or an embedded font, the
# assets have to exist as TAGS before the code runs, and mtasc's other
# mode (`-swf template.swf`) injects the classes into a file that already
# has them.
#
# This image builds those templates. The tools that do it — swfmill and
# swftools — were dropped from Debian years ago and are not packaged for
# arm64 anywhere, so the image is AMD64 and runs under emulation. That is
# fine: it is a build-time step over tiny files.
#
#   docker build --platform linux/amd64 -t handyflash-swfassets tools/as2/assets
#   docker run --rm --platform linux/amd64 -v "$PWD:/work" handyflash-swfassets \
#       swfmill simple assets.xml assets.swf
#
# What is in here:
#   swfmill    XML <-> SWF. `swfmill simple` turns a small XML manifest of
#              PNG/JPEG/TTF files into a library SWF with linkage names —
#              exactly what `attachMovie` / `attachBitmap` want.
#   swfc       swftools' script compiler, for hand-built timelines.
#   png2swf / jpeg2swf / font2swf / swfcombine / swfdump
#
# bionic is EOL, so the sources are pinned to the archive and no update
# is expected; the image is reproducible precisely because nothing moves.
FROM --platform=linux/amd64 ubuntu:18.04

RUN echo "deb http://archive.ubuntu.com/ubuntu bionic main universe" > /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends swfmill swftools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
