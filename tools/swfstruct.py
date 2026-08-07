#!/usr/bin/env python3
"""Dump SWF timeline structure: frames, place/remove/doaction per timeline.

    python3 tools/swfstruct.py <file.swf>

Recurses into DefineSprite, so you get each sprite's own frame list. This
is the tool that settles "which clip traced that line, and in what order"
questions -- read it before theorising about the action queue. NOTE: do
not name a copy of this `struct.py`; it shadows the stdlib module it
imports.
"""
import struct, zlib, sys

d = open(sys.argv[1], 'rb').read()
if d[:3] == b'CWS':
    d = d[:8] + zlib.decompress(d[8:])
p = 8
nbits = d[p] >> 3
p += (5 + nbits * 4 + 7) // 8
p += 4

TAGN = {4:'Place',26:'Place2',70:'Place3',5:'Remove',28:'Remove2',1:'ShowFrame',
        12:'DoAction',39:'DefineSprite',43:'FrameLabel',59:'DoInitAction',
        56:'ExportAssets',0:'End'}


def place_info(body, code):
    if code == 4:
        cid = struct.unpack_from('<H', body, 0)[0]
        dep = struct.unpack_from('<H', body, 2)[0]
        return 'char=%d depth=%d (place)' % (cid, dep)
    f = body[0]
    dep = struct.unpack_from('<H', body, 1)[0]
    j = 3
    if code == 70:
        j += 2
    kind = []
    cid = None
    if f & 0x02:
        cid = struct.unpack_from('<H', body, j)[0]; j += 2
    move = bool(f & 0x01)
    if cid is not None and move: kind.append('replace(%d)' % cid)
    elif cid is not None: kind.append('place(%d)' % cid)
    else: kind.append('modify')
    if f & 0x20: kind.append('hasClipActions')
    return 'depth=%d %s' % (dep, ' '.join(kind))


def walk(buf, pp, end, label, indent=''):
    frame = 1
    print('%s--- %s' % (indent, label))
    while pp < end:
        cl = struct.unpack_from('<H', buf, pp)[0]; pp += 2
        code = cl >> 6; ln = cl & 0x3f
        if ln == 0x3f:
            ln = struct.unpack_from('<I', buf, pp)[0]; pp += 4
        body = buf[pp:pp + ln]; pp += ln
        name = TAGN.get(code, 'tag%d' % code)
        if code == 1:
            print('%s  [frame %d end]' % (indent, frame)); frame += 1
        elif code in (4, 26, 70):
            print('%s  f%d %s %s' % (indent, frame, name, place_info(body, code)))
        elif code in (5, 28):
            print('%s  f%d %s depth=%d' % (indent, frame, name,
                  struct.unpack_from('<H', body, 0 if code == 5 else 0)[0]))
        elif code == 12:
            print('%s  f%d DoAction len=%d' % (indent, frame, ln))
        elif code == 43:
            print('%s  f%d Label %r' % (indent, frame, body[:-1].decode('latin1')))
        elif code == 39:
            sid = struct.unpack_from('<H', body, 0)[0]
            nf = struct.unpack_from('<H', body, 2)[0]
            walk(body, 4, len(body), 'Sprite id=%d frames=%d' % (sid, nf), indent + '    ')
        elif code == 56:
            n = struct.unpack_from('<H', body, 0)[0]; j = 2
            for _ in range(n):
                cid = struct.unpack_from('<H', body, j)[0]; j += 2
                k = body.index(0, j); nm = body[j:k].decode('latin1'); j = k + 1
                print('%s  Export %d -> %r' % (indent, cid, nm))
        elif code == 0:
            break


walk(d, p, len(d), 'ROOT')
