#!/usr/bin/env python3
"""Write a SWF exercising every PlaceObject3 blend mode, one per cell.

    python3 tools/make_blend_demo.py            # -> /tmp/blend_demo.swf
    ./zig-out/bin/handyflash-sdl /tmp/blend_demo.swf --headless-frames 1 \
        --out /tmp/blend_demo.png

Nothing in ruffle's corpus places an object with a blend mode and none of
the sample movies use one, so this is the only way to look at the feature.
Each cell is a steel-blue square with an orange one over it; the orange
square hangs past the blue on two sides, so a mode's effect against the
page is visible as well as against the backdrop.
"""
import struct

class Bits:
    def __init__(self): self.acc=0; self.n=0; self.out=bytearray()
    def w(self,v,n):
        for i in range(n-1,-1,-1):
            self.acc=(self.acc<<1)|((v>>i)&1); self.n+=1
            if self.n==8: self.out.append(self.acc); self.acc=0; self.n=0
    def flush(self):
        if self.n: self.out.append(self.acc<<(8-self.n)); self.acc=0; self.n=0
        return bytes(self.out)

def rect(xmin,xmax,ymin,ymax):
    nb=max(1,max(v.bit_length()+1 for v in (abs(xmin),abs(xmax),abs(ymin),abs(ymax))))
    b=Bits(); b.w(nb,5)
    for v in (xmin,xmax,ymin,ymax): b.w(v & ((1<<nb)-1), nb)
    return b.flush()

def square(cid, w, h, rgb):
    """DefineShape: a solid rectangle w x h twips at the origin."""
    body=struct.pack('<H',cid)+rect(0,w,0,h)
    body+=bytes([1,0x00,rgb[0],rgb[1],rgb[2],0])   # 1 fill, solid; 0 lines
    body+=bytes([0x11])                             # fill bits 1, line bits 1
    b=Bits()
    b.w(0b00101,6); b.w(0,5); b.w(1,1)              # style change: fill1 = 1
    def edge(dx,dy):
        # Deltas are SIGNED: 1200 twips needs 12 bits, not 10, and a short
        # field silently truncates the square down to a speck.
        nb=max(2, max(abs(dx),abs(dy)).bit_length()+1)
        b.w(0b11,2); b.w(nb-2,4); b.w(1 if (dx and dy) else 0,1)
        if dx and dy:
            b.w(dx & ((1<<nb)-1), nb); b.w(dy & ((1<<nb)-1), nb)
        else:
            b.w(0 if dx else 1,1)
            b.w((dx if dx else dy) & ((1<<nb)-1), nb)
    edge(w,0); edge(0,h); edge(-w,0); edge(0,-h)
    b.w(0,6)
    return body+b.flush()

def matrix(tx,ty):
    b=Bits(); b.w(0,1); b.w(0,1)
    nb=max(tx.bit_length(),ty.bit_length())+2
    b.w(nb,5); b.w(tx & ((1<<nb)-1),nb); b.w(ty & ((1<<nb)-1),nb)
    return b.flush()

def tag(code, body):
    if len(body)>=0x3F:
        return struct.pack('<HI',(code<<6)|0x3F,len(body))+body
    return struct.pack('<H',(code<<6)|len(body))+body

MODES=[(3,'multiply'),(4,'screen'),(5,'lighten'),(6,'darken'),(7,'difference'),
       (8,'add'),(9,'subtract'),(10,'invert'),(11,'alpha'),(12,'erase'),
       (13,'overlay'),(14,'hardlight'),(1,'normal'),(2,'layer')]

CELL=80; COLS=7; ROWS=2
W=CELL*COLS; H=CELL*ROWS
body=rect(0,W*20,0,H*20)+bytes([0,12])+struct.pack('<H',1)
body+=tag(9,bytes([250,250,250]))                       # white-ish background
body+=tag(2, square(1, 60*20, 60*20, (60,110,180)))     # backdrop, steel blue
body+=tag(2, square(2, 60*20, 60*20, (245,150,40)))     # source, orange
depth=1
for i,(mode,_name) in enumerate(MODES):
    cx=(i%COLS)*CELL*20 + 4*20
    cy=(i//COLS)*CELL*20 + 4*20
    # backdrop
    p=bytes([0x06])+struct.pack('<H',depth)+struct.pack('<H',1)+matrix(cx,cy)
    body+=tag(26,p); depth+=1
    # source, offset into the backdrop, with the blend mode
    flags=(1<<1)|(1<<2)|(1<<9)
    p=struct.pack('<H',flags)+struct.pack('<H',depth)+struct.pack('<H',2)
    p+=matrix(cx+12*20, cy+12*20)+bytes([mode])
    body+=tag(70,p); depth+=1
body+=tag(1,b'')+tag(0,b'')
swf=b'FWS\x08'+struct.pack('<I',len(body)+8)+body
open('/tmp/blend_demo.swf','wb').write(swf)
print("wrote /tmp/blend_demo.swf", len(swf), "bytes;", len(MODES), "cells")
