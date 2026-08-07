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
"""
import sys, zlib, struct
def read(p):
    d=open(p,'rb').read(); assert d[:8]==b'\x89PNG\r\n\x1a\n'
    i=8; idat=b''; w=h=bd=ct=None
    while i<len(d):
        ln=struct.unpack_from('>I',d,i)[0]; typ=d[i+4:i+8]; body=d[i+8:i+8+ln]; i+=12+ln
        if typ==b'IHDR': w,h,bd,ct=struct.unpack_from('>IIBB',body,0)
        elif typ==b'IDAT': idat+=body
        elif typ==b'IEND': break
    raw=zlib.decompress(idat)
    ch={0:1,2:3,3:1,4:2,6:4}[ct]; bpp=ch*(bd//8); stride=w*bpp
    out=bytearray(); prev=bytearray(stride); pos=0
    for y in range(h):
        f=raw[pos]; pos+=1; line=bytearray(raw[pos:pos+stride]); pos+=stride
        for x in range(stride):
            a=line[x-bpp] if x>=bpp else 0; b=prev[x]; c=prev[x-bpp] if x>=bpp else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+((a+b)>>1))&255
            elif f==4:
                pp=a+b-c; pa=abs(pp-a); pb=abs(pp-b); pc=abs(pp-c)
                pr=a if (pa<=pb and pa<=pc) else (b if pb<=pc else c)
                line[x]=(line[x]+pr)&255
        out+=line; prev=line
    return w,h,bpp,bytes(out)
w1,h1,b1,p1=read(sys.argv[1]); w2,h2,b2,p2=read(sys.argv[2])
assert (w1,h1,b1)==(w2,h2,b2), "size/format differ"
n=0; maxd=0; box=[w1,h1,-1,-1]
for y in range(h1):
    for x in range(w1):
        o=(y*w1+x)*b1
        px1=p1[o:o+b1]; px2=p2[o:o+b1]
        if px1!=px2:
            n+=1; maxd=max(maxd,max(abs(a-b) for a,b in zip(px1,px2)))
            box[0]=min(box[0],x); box[1]=min(box[1],y); box[2]=max(box[2],x); box[3]=max(box[3],y)
tot=w1*h1
print(f"{w1}x{h1}  differing px: {n} ({100.0*n/tot:.3f}%)  max channel delta: {maxd}")
if n: print(f"bbox x{box[0]}..{box[2]} y{box[1]}..{box[3]}")
