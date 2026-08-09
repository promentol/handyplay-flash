#!/usr/bin/env python3
"""Pixel-diff two PNGs: count, max channel delta, and bounding box.

    python3 tools/pngdiff.py a.png b.png

The VISUAL GATE for renderer/timeline changes, paired with the SDL
frontend's headless dump:

    zig build sdl -Doptimize=ReleaseFast
    ./zig-out/bin/handyflash-sdl <file.swf> --headless-frames N --out a.png

Dump the same frames before and after a change and diff them. A bounding
box is far more useful than "differs": a 17x17 box in a 728x90 banner is
one animated element, not a broken renderer. Decodes PNG with zlib and
the five filter types only -- no PIL, per the no-dependencies rule.

CONFORMANCE MODE (`--tolerance N [--max-outliers M]`) applies ruffle's own
rule from tests/framework/src/runner/image_test.rs: a CHANNEL whose
absolute difference exceeds `tolerance` counts as one outlier, and the
comparison passes when the outlier count is <= `max-outliers`. Prints
PASS/FAIL and exits 0/1 so tests/conformance/images.sh can score it.
"""
import sys, zlib, struct


def read(p):
    d = open(p, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', f"{p}: not a PNG"
    i = 8; idat = b''; w = h = bd = ct = None; plte = b''; trns = b''
    while i < len(d):
        ln = struct.unpack_from('>I', d, i)[0]; typ = d[i+4:i+8]
        body = d[i+8:i+8+ln]; i += 12 + ln
        if typ == b'IHDR': w, h, bd, ct = struct.unpack_from('>IIBB', body, 0)
        elif typ == b'PLTE': plte = body
        elif typ == b'tRNS': trns = body
        elif typ == b'IDAT': idat += body
        elif typ == b'IEND': break
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    # Sub-byte depths (1/2/4) pack several pixels into a byte, so the
    # filtering unit is one byte and the stride rounds up.
    if bd < 8:
        bpp = 1; stride = (w * ch * bd + 7) // 8
    else:
        bpp = ch * (bd // 8); stride = w * bpp
    out = bytearray(); prev = bytearray(stride); pos = 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pp = a + b - c; pa = abs(pp-a); pb = abs(pp-b); pc = abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line; prev = line
    # Everything becomes 8-bit RGBA. A stage dump is always four opaque
    # channels; a recorded expectation may be RGB, greyscale, or — for a
    # two-colour mask test — a 1-bit PALETTE image, and all of them have
    # to compare against it on equal terms.
    rgba = bytearray(w * h * 4)
    for y in range(h):
        row = out[y*stride:(y+1)*stride]
        for x in range(w):
            samples = []
            for c in range(ch):
                idx = x * ch + c
                if bd == 8:
                    v = row[idx]
                elif bd == 16:
                    v = row[idx*2]                       # high byte is enough
                else:
                    per = 8 // bd
                    byte = row[idx // per]
                    shift = 8 - bd * (idx % per + 1)
                    raw_v = (byte >> shift) & ((1 << bd) - 1)
                    v = raw_v if ct == 3 else raw_v * 255 // ((1 << bd) - 1)
                samples.append(v)
            if ct == 3:
                e = samples[0] * 3
                px = (plte[e], plte[e+1], plte[e+2], trns[samples[0]] if samples[0] < len(trns) else 255)
            elif ct == 0:
                px = (samples[0], samples[0], samples[0], 255)
            elif ct == 4:
                px = (samples[0], samples[0], samples[0], samples[1])
            elif ct == 2:
                px = (samples[0], samples[1], samples[2], 255)
            else:
                px = tuple(samples)
            o = (y * w + x) * 4
            rgba[o:o+4] = bytes(px)
    return w, h, 4, bytes(rgba)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    tolerance = None
    max_outliers = 0
    for a in argv[1:]:
        if a.startswith('--tolerance='): tolerance = int(a.split('=', 1)[1])
        elif a.startswith('--max-outliers='): max_outliers = int(a.split('=', 1)[1])
    if len(args) != 2:
        print("usage: pngdiff.py a.png b.png [--tolerance=N] [--max-outliers=M]")
        return 2

    try:
        w1, h1, b1, p1 = read(args[0])
        w2, h2, b2, p2 = read(args[1])
    except (OSError, AssertionError) as e:
        print(f"FAIL {e}")
        return 1
    if (w1, h1, b1) != (w2, h2, b2):
        print(f"FAIL size/format differ: {w1}x{h1}x{b1} vs {w2}x{h2}x{b2}")
        return 1

    n = 0; maxd = 0; outliers = 0; box = [w1, h1, -1, -1]
    for y in range(h1):
        for x in range(w1):
            o = (y * w1 + x) * b1
            px1 = p1[o:o+b1]; px2 = p2[o:o+b1]
            if px1 == px2:
                continue
            n += 1
            d = max(abs(a - b) for a, b in zip(px1, px2))
            maxd = max(maxd, d)
            if tolerance is not None:
                # Ruffle counts one outlier per CHANNEL over the tolerance.
                outliers += sum(1 for a, b in zip(px1, px2) if abs(a - b) > tolerance)
            box[0] = min(box[0], x); box[1] = min(box[1], y)
            box[2] = max(box[2], x); box[3] = max(box[3], y)

    tot = w1 * h1
    if tolerance is None:
        print(f"{w1}x{h1}  differing px: {n} ({100.0*n/tot:.3f}%)  max channel delta: {maxd}")
        if n:
            print(f"bbox x{box[0]}..{box[2]} y{box[1]}..{box[3]}")
        return 0

    ok = outliers <= max_outliers
    verdict = "PASS" if ok else "FAIL"
    print(f"{verdict} {w1}x{h1} outliers: {outliers} (allowed {max_outliers}, "
          f"tolerance {tolerance}) differing px: {n} max delta: {maxd}")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
