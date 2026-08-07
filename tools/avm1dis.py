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
 0x2b:'CastOp',0x2c:'ImplementsOp',0x30:'RandomNumber',0x31:'MBStringLength',
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


for code, body in tags(d, p, len(d)):
    if code in (12, 59):
        off = 2 if code == 59 else 0
        print('== tag %d DoAction len=%d' % (code, len(body) - off))
        dis(body[off:])
