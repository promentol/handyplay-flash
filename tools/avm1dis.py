#!/usr/bin/env python3
"""AVM1 disassembler: walks DoAction/DoInitAction tags and recurses into
DefineFunction/DefineFunction2 bodies, printing fn2 preload/suppress flags."""
import struct, zlib, sys

fn = sys.argv[1]
d = open(fn, 'rb').read()
if d[:3] == b'CWS':
    d = d[:8] + zlib.decompress(d[8:])
p = 8
nbits = d[p] >> 3
p += (5 + nbits * 4 + 7) // 8
p += 4


def tags(buf, pp, end):
    out = []
    while pp < end:
        cl = struct.unpack_from('<H', buf, pp)[0]; pp += 2
        code = cl >> 6; ln = cl & 0x3f
        if ln == 0x3f:
            ln = struct.unpack_from('<I', buf, pp)[0]; pp += 4
        out.append((code, buf[pp:pp + ln])); pp += ln
        if code == 0:
            break
    return out


OPN = {
 0x04:'NextFrame',0x05:'PrevFrame',0x06:'Play',0x07:'Stop',0x08:'ToggleQuality',
 0x09:'StopSounds',0x0a:'Add',0x0b:'Subtract',0x0c:'Multiply',0x0d:'Divide',
 0x0e:'Equals',0x0f:'Less',0x10:'And',0x11:'Or',0x12:'Not',0x13:'StringEquals',
 0x14:'StringLength',0x15:'StringExtract',0x17:'Pop',0x18:'ToInteger',
 0x1c:'GetVariable',0x1d:'SetVariable',0x20:'SetTarget2',0x21:'StringAdd',
 0x22:'GetProperty',0x23:'SetProperty',0x24:'CloneSprite',0x25:'RemoveSprite',
 0x26:'Trace',0x27:'StartDrag',0x28:'EndDrag',0x29:'StringLess',0x2a:'Throw',
 0x2b:'CastOp',0x2c:'ImplementsOp',
 # Flash Lite's device call. Not in the SWF spec's action list and not
 # in ruffle's opcode table either: the stack is the arg COUNT on top,
 # then the command name, then that many arguments.
 0x2d:'FSCommand2',
 0x30:'RandomNumber',0x31:'MBStringLength',
 0x32:'CharToAscii',0x33:'AsciiToChar',0x34:'GetTime',0x35:'MBStringExtract',
 0x36:'MBCharToAscii',0x37:'MBAsciiToChar',0x3a:'Delete',0x3b:'Delete2',
 0x3c:'DefineLocal',0x3d:'CallFunction',0x3e:'Return',0x3f:'Modulo',
 0x40:'NewObject',0x41:'DefineLocal2',0x42:'InitArray',0x43:'InitObject',
 0x44:'TypeOf',0x45:'TargetPath',0x46:'Enumerate',0x47:'Add2',0x48:'Less2',
 0x49:'Equals2',0x4a:'ToNumber',0x4b:'ToString',0x4c:'PushDuplicate',
 0x4d:'StackSwap',0x4e:'GetMember',0x4f:'SetMember',0x50:'Increment',
 0x51:'Decrement',0x52:'CallMethod',0x53:'NewMethod',0x54:'InstanceOf',
 0x55:'Enumerate2',0x60:'BitAnd',0x61:'BitOr',0x62:'BitXor',0x63:'BitLShift',
 0x64:'BitRShift',0x65:'BitURShift',0x66:'StrictEquals',0x67:'Greater',
 0x68:'StringGreater',0x69:'Extends',
 0x81:'GotoFrame',0x83:'GetURL',0x87:'StoreRegister',0x88:'ConstantPool',
 0x8a:'WaitForFrame',0x8b:'SetTarget',0x8c:'GotoLabel',0x8d:'WaitForFrame2',
 0x8e:'DefineFunction2',0x8f:'Try',0x94:'With',0x96:'Push',0x99:'Jump',
 0x9a:'GetURL2',0x9b:'DefineFunction',0x9d:'If',0x9e:'Call',0x9f:'GotoFrame2',
}

FLAGS = ['preload_this','suppress_this','preload_args','suppress_args',
         'preload_super','suppress_super','preload_root','preload_parent',
         'preload_global']


def push_items(body):
    j = 0; it = []
    while j < len(body):
        t = body[j]; j += 1
        if t == 0:
            k = body.index(0, j); it.append(repr(body[j:k].decode('latin1'))); j = k + 1
        elif t == 1:
            it.append(struct.unpack_from('<f', body, j)[0]); j += 4
        elif t == 2: it.append('null')
        elif t == 3: it.append('undef')
        elif t == 4: it.append('reg%d' % body[j]); j += 1
        elif t == 5: it.append('bool%d' % body[j]); j += 1
        elif t == 6:
            it.append(struct.unpack_from('<d', body[j+4:j+8] + body[j:j+4], 0)[0]); j += 8
        elif t == 7: it.append(struct.unpack_from('<i', body, j)[0]); j += 4
        elif t == 8: it.append('cp%d' % body[j]); j += 1
        elif t == 9: it.append('cp%d' % struct.unpack_from('<H', body, j)[0]); j += 2
        else:
            it.append('?t%d' % t); break
    return it


def dis(b, ind='  '):
    i = 0
    while i < len(b):
        op = b[i]
        name = OPN.get(op, hex(op))
        if op < 0x80:
            print('%s%04x %s' % (ind, i, name)); i += 1; continue
        ln = struct.unpack_from('<H', b, i + 1)[0]
        body = b[i + 3:i + 3 + ln]
        nxt = i + 3 + ln
        extra = ''
        if op == 0x96:
            extra = ' ' + repr(push_items(body))
        elif op == 0x9a:  # GetURL2 — flag order is reversed vs the spec
            f = body[0]
            bits = []
            if f & 1: bits.append('load_vars')
            if f & 2: bits.append('target_sprite')
            bits.append(('none', 'GET', 'POST', '?')[(f >> 6) & 3])
            extra = ' %s (0x%02x)' % (','.join(bits), f)
        elif op == 0x88:
            n = struct.unpack_from('<H', body, 0)[0]
            j = 2; strs = []
            for _ in range(n):
                k = body.index(0, j); strs.append(body[j:k].decode('latin1')); j = k + 1
            extra = ' ' + repr(strs)
        elif op == 0x87:
            extra = ' r%d' % body[0]
        elif op in (0x99, 0x9d):
            extra = ' %+d -> %04x' % (struct.unpack_from('<h', body, 0)[0],
                                      nxt + struct.unpack_from('<h', body, 0)[0])
        elif op == 0x9b:  # DefineFunction
            k = body.index(0, 0); fname = body[:k].decode('latin1'); j = k + 1
            nparams = struct.unpack_from('<H', body, j)[0]; j += 2
            params = []
            for _ in range(nparams):
                k = body.index(0, j); params.append(body[j:k].decode('latin1')); j = k + 1
            blen = struct.unpack_from('<H', body, j)[0]; j += 2
            print('%s%04x DefineFunction %r(%s) len=%d' % (ind, i, fname, ','.join(params), blen))
            dis(b[nxt:nxt + blen], ind + '  |')
            i = nxt + blen; continue
        elif op == 0x8e:  # DefineFunction2
            k = body.index(0, 0); fname = body[:k].decode('latin1'); j = k + 1
            nparams = struct.unpack_from('<H', body, j)[0]; j += 2
            nregs = body[j]; j += 1
            fl = struct.unpack_from('<H', body, j)[0]; j += 2
            params = []
            for _ in range(nparams):
                reg = body[j]; j += 1
                k = body.index(0, j); params.append('r%d=%s' % (reg, body[j:k].decode('latin1'))); j = k + 1
            blen = struct.unpack_from('<H', body, j)[0]; j += 2
            on = [FLAGS[bit] for bit in range(9) if fl & (1 << bit)]
            print('%s%04x DefineFunction2 %r(%s) regs=%d flags=%04x[%s] len=%d'
                  % (ind, i, fname, ','.join(params), nregs, fl, ' '.join(on), blen))
            dis(b[nxt:nxt + blen], ind + '  |')
            i = nxt + blen; continue
        elif op == 0x94:  # With
            blen = struct.unpack_from('<H', body, 0)[0]
            print('%s%04x With len=%d' % (ind, i, blen))
            dis(b[nxt:nxt + blen], ind + '  |')
            i = nxt + blen; continue
        print('%s%04x %s%s' % (ind, i, name, extra))
        i = nxt


# Where AVM1 hides: not only DoAction. A Flash Lite game keeps ALL of its
# input handling in button condition actions and clip events, and a
# sprite's timeline has its own DoActions.
KEYPRESS = {1:'<Left>',2:'<Right>',3:'<Home>',4:'<End>',5:'<Insert>',6:'<Delete>',
            8:'<Backspace>',13:'<Enter>',14:'<Up>',15:'<Down>',16:'<PageUp/SoftL>',
            17:'<PageDown/SoftR>',18:'<Tab>',19:'<Escape>'}
MOUSE_COND = ['idleToOverUp','outDownToIdle','outDownToOverDown','overDownToOutDown',
              'overDownToOverUp','overUpToOverDown','overUpToIdle','idleToOverDown',
              'overDownToIdle']

def condname(cond):
    key = (cond >> 9) & 0x7F
    bits = [MOUSE_COND[i] for i in range(9) if cond & (1 << i)]
    if key:
        bits.append('keyPress ' + (KEYPRESS.get(key) or repr(chr(key)) if 32 < key < 127 else KEYPRESS.get(key, '#%d' % key)))
    return ', '.join(bits) or 'none'

def button2(body, label):
    """DefineButton2: skip the character records, then walk the cond actions."""
    if len(body) < 6: return
    bid = struct.unpack_from('<H', body, 0)[0]
    off = struct.unpack_from('<H', body, 3)[0]
    if off == 0:
        print('== %s button id=%d (no actions)' % (label, bid)); return
    q = 3 + off
    while q + 4 <= len(body):
        size = struct.unpack_from('<H', body, q)[0]
        cond = struct.unpack_from('<H', body, q + 2)[0]
        end = q + size if size else len(body)
        print('== %s button id=%d on(%s)' % (label, bid, condname(cond)))
        dis(body[q + 4:end])
        if size == 0: break
        q = end

def button1(body, label):
    """DefineButton: one implicit `on(press, release…)` action block."""
    bid = struct.unpack_from('<H', body, 0)[0]
    i = 2
    while i < len(body) and body[i] != 0:      # BUTTONRECORDs
        flags = body[i]
        i += 1 + 2 + 2                          # flags, char id, depth
        i = skip_matrix(body, i)
    i += 1
    print('== %s button id=%d on(press/release)' % (label, bid))
    dis(body[i:])

def skip_matrix(b, i):
    bit = i * 8
    def u(n):
        nonlocal bit
        v = 0
        for _ in range(n):
            v = (v << 1) | ((b[bit >> 3] >> (7 - (bit & 7))) & 1); bit += 1
        return v
    if u(1): n = u(5); u(n); u(n)
    if u(1): n = u(5); u(n); u(n)
    n = u(5); u(n); u(n)
    return (bit + 7) // 8

CLIP_EVENTS = ['load','enterFrame','unload','mouseMove','mouseDown','mouseUp',
               'keyDown','keyUp','data','initialize','press','release',
               'releaseOutside','rollOver','rollOut','dragOver','dragOut',
               'keyPress','construct']

def place_clip_actions(body, label, swf_version):
    """PlaceObject2's ClipActions — where a clip keeps its own handlers.

    Reaching them means stepping over every optional field first, which is
    the only reason this is fiddly."""
    if len(body) < 3: return
    flags = body[0]
    if not (flags & 0x80): return
    i = 3                                        # flags + depth
    if flags & 0x02: i += 2                      # character id
    if flags & 0x04: i = skip_matrix(body, i)    # matrix
    if flags & 0x08: i = skip_cxform(body, i)    # colour transform
    if flags & 0x10: i += 2                      # ratio
    if flags & 0x20:                             # name
        while i < len(body) and body[i]: i += 1
        i += 1
    if flags & 0x40: i += 2                      # clip depth
    wide = swf_version >= 6
    i += 2 + (4 if wide else 2)                  # reserved + AllEventFlags
    while i + (4 if wide else 2) + 4 <= len(body):
        ev = struct.unpack_from('<I' if wide else '<H', body, i)[0]
        i += 4 if wide else 2
        if ev == 0: break
        size = struct.unpack_from('<I', body, i)[0]; i += 4
        key = ''
        if ev & (1 << 17):                       # keyPress carries a code
            key = ' ' + (KEYPRESS.get(body[i]) or repr(chr(body[i])) if 32 < body[i] < 127 else KEYPRESS.get(body[i], '#%d' % body[i]))
            i += 1; size -= 1
        names = [CLIP_EVENTS[b] for b in range(19) if ev & (1 << b)]
        print('== %sonClipEvent(%s%s)' % (label, ', '.join(names), key))
        dis(body[i:i + size])
        i += size

def skip_cxform(b, i):
    bit = i * 8
    def u(n):
        nonlocal bit
        v = 0
        for _ in range(n):
            v = (v << 1) | ((b[bit >> 3] >> (7 - (bit & 7))) & 1); bit += 1
        return v
    has_add, has_mult = u(1), u(1)
    n = u(4)
    if has_mult: [u(n) for _ in range(4)]
    if has_add: [u(n) for _ in range(4)]
    return (bit + 7) // 8

def walk(data, start, end, label=''):
    for code, body in tags(data, start, end):
        if code in (12, 59):
            off = 2 if code == 59 else 0
            print('== %stag %d DoAction len=%d' % (label, code, len(body) - off))
            dis(body[off:])
        elif code == 34:
            button2(body, label)
        elif code == 7:
            button1(body, label)
        elif code == 26:                        # PlaceObject2
            place_clip_actions(body, label, d[3])
        elif code == 39 and len(body) > 4:      # DefineSprite
            sid = struct.unpack_from('<H', body, 0)[0]
            walk(body, 4, len(body), '%ssprite %d ' % (label, sid))

walk(d, p, len(d))
