#!/usr/bin/env python3
"""Which keys does this SWF actually handle? Answered statically.

    python3 tools/keymap.py game.swf            # the summary
    python3 tools/keymap.py game.swf --sites    # every call site as well

AVM1 reads the keyboard in four places and a survey that looks at only one
of them is wrong. This walks all four:

  1. BUTTON `keyPress` conditions — DefineButton/DefineButton2, where the
     key is a field of the condition and no bytecode mentions it at all.
  2. CLIP `onClipEvent(keyPress "x")` — the code is a byte in the event
     record, likewise invisible to a bytecode scan.
  3. `Key.isDown(code)` — the polling form, which is what a game running
     off `onEnterFrame` uses.
  4. `Key.getCode()` / `Key.getAscii()` in a listener, plus the numeric
     literals they are COMPARED against, which is where a listener's key
     set is really written down.

WHY A TINY STACK MACHINE. `Key.isDown(90)` is four actions and the method
name usually lives in the CONSTANT POOL, so grepping a disassembly for
"isDown" finds the pool and misses every call. Resolving `cpN` and
modelling the stack across a handful of opcodes is the smallest thing
that actually answers the question.

The model is deliberately shallow: any opcode it does not know clears the
stack. That can only LOSE a call site, never invent one — and the
compilers that made these files emit the argument, the count, the object
and the method name in one tight run, so nothing real is lost.

A key that comes from a VARIABLE is reported as such rather than
resolved: a game with a remappable control screen (Super Mario 63) keeps
its codes in `_root.<something>` and no static answer exists.
"""
import struct
import sys
import zlib
from collections import Counter, defaultdict

# --- Flash key codes (the Windows virtual-key numbering) -------------------
NAMES = {
    8: 'Backspace', 9: 'Tab', 13: 'Enter', 16: 'Shift', 17: 'Ctrl', 18: 'Alt',
    20: 'CapsLock', 27: 'Esc', 32: 'Space', 33: 'PageUp', 34: 'PageDown',
    35: 'End', 36: 'Home', 37: 'Left', 38: 'Up', 39: 'Right', 40: 'Down',
    45: 'Insert', 46: 'Delete', 144: 'NumLock', 186: ';', 187: '=', 188: ',',
    189: '-', 190: '.', 191: '/', 192: '`', 219: '[', 220: '\\', 221: ']',
    222: "'",
}
for _n in range(10):
    NAMES[48 + _n] = str(_n)
    NAMES[96 + _n] = 'Numpad%d' % _n
for _c in range(26):
    NAMES[65 + _c] = chr(65 + _c)
for _f in range(12):
    NAMES[112 + _f] = 'F%d' % (_f + 1)


def keyname(code):
    return NAMES.get(code, '#%d' % code)


# `keyPress` condition codes are their OWN numbering, not the key codes —
# 16 is PageUp there and Shift here (ruffle events.rs ButtonKeyCode).
PRESS_NAMES = {
    1: 'Left', 2: 'Right', 3: 'Home', 4: 'End', 5: 'Insert', 6: 'Delete',
    8: 'Backspace', 13: 'Enter', 14: 'Up', 15: 'Down', 16: 'PageUp',
    17: 'PageDown', 18: 'Tab', 19: 'Esc',
}


def pressname(code):
    if code in PRESS_NAMES:
        return PRESS_NAMES[code]
    if 32 < code < 127:
        return repr(chr(code))
    return '#%d' % code


# --- container ------------------------------------------------------------

def load(path):
    d = open(path, 'rb').read()
    if d[:3] == b'CWS':
        d = d[:8] + zlib.decompress(d[8:])
    elif d[:3] == b'ZWS':
        import lzma
        d = d[:8] + lzma.decompress(d[17:], format=lzma.FORMAT_ALONE)
    return d


def header_end(d):
    p = 8
    nbits = d[p] >> 3
    p += (5 + nbits * 4 + 7) // 8
    return p + 4


def tags(buf, pp, end):
    while pp < end:
        cl = struct.unpack_from('<H', buf, pp)[0]
        pp += 2
        code, ln = cl >> 6, cl & 0x3F
        if ln == 0x3F:
            ln = struct.unpack_from('<I', buf, pp)[0]
            pp += 4
        yield code, buf[pp:pp + ln]
        pp += ln
        if code == 0:
            return


def skip_matrix(b, i):
    bit = i * 8

    def u(n):
        nonlocal bit
        v = 0
        for _ in range(n):
            v = (v << 1) | ((b[bit >> 3] >> (7 - (bit & 7))) & 1)
            bit += 1
        return v
    if u(1):
        n = u(5); u(n); u(n)
    if u(1):
        n = u(5); u(n); u(n)
    n = u(5); u(n); u(n)
    return (bit + 7) // 8


def skip_cxform(b, i):
    bit = i * 8

    def u(n):
        nonlocal bit
        v = 0
        for _ in range(n):
            v = (v << 1) | ((b[bit >> 3] >> (7 - (bit & 7))) & 1)
            bit += 1
        return v
    has_add, has_mult = u(1), u(1)
    n = u(4)
    if has_mult:
        [u(n) for _ in range(4)]
    if has_add:
        [u(n) for _ in range(4)]
    return (bit + 7) // 8


# --- the stack machine ----------------------------------------------------

class Report:
    def __init__(self):
        self.press = Counter()          # button keyPress conditions
        self.clip_press = Counter()     # onClipEvent(keyPress "x")
        self.clip_events = Counter()    # keyDown / keyUp handlers
        self.isdown = Counter()         # Key.isDown(<literal>)
        self.isdown_dyn = Counter()     # Key.isDown(<not a literal>)
        self.compared = Counter()       # getCode() == <literal>
        self.calls = Counter()          # Key.<method> overall
        self.sites = defaultdict(list)  # what → where
        self.skipped = 0                # place tags this walker gave up on


UNKNOWN = ('?', None, None)


def num(v):
    """The int behind a pushed value, or None."""
    if isinstance(v, tuple) and v[0] == 'lit' and isinstance(v[1], (int, float)):
        f = float(v[1])
        return int(f) if f == int(f) else None
    return None


def text(v):
    if isinstance(v, tuple) and v[0] == 'lit' and isinstance(v[1], str):
        return v[1]
    return None


def describe(v):
    if v[0] == 'lit':
        return repr(v[1])
    if v[0] == 'var':
        return v[1]
    if v[0] == 'member':
        return '%s.%s' % (v[1], v[2])
    if v[0] == 'call':
        return '%s.%s()' % (v[1], v[2])
    return '?'


def push_items(body, pool):
    j, out = 0, []
    while j < len(body):
        t = body[j]
        j += 1
        try:
            if t == 0:
                k = body.index(0, j)
                out.append(('lit', body[j:k].decode('latin1')))
                j = k + 1
            elif t == 1:
                out.append(('lit', struct.unpack_from('<f', body, j)[0])); j += 4
            elif t in (2, 3):
                out.append(UNKNOWN)
            elif t == 4:
                out.append(('reg', body[j])); j += 1
            elif t == 5:
                out.append(('lit', bool(body[j]))); j += 1
            elif t == 6:
                out.append(('lit', struct.unpack_from(
                    '<d', body[j + 4:j + 8] + body[j:j + 4], 0)[0])); j += 8
            elif t == 7:
                out.append(('lit', struct.unpack_from('<i', body, j)[0])); j += 4
            elif t in (8, 9):
                if t == 8:
                    idx = body[j]; j += 1
                else:
                    idx = struct.unpack_from('<H', body, j)[0]; j += 2
                out.append(('lit', pool[idx]) if idx < len(pool) else UNKNOWN)
            else:
                out.append(UNKNOWN)
                break
        except (IndexError, struct.error, ValueError):
            out.append(UNKNOWN)
            break
    return out


def scan(code, rep, where, pool=None):
    """One action blob. `pool` is inherited by nested function bodies —
    a DefineFunction shares its parent's constant pool.

    `regs` and `named` follow a `Key.getCode()` answer into the register
    or local it was stored in, which is how a listener is actually
    written: `var k = Key.getCode(); if (k == 13)`. Without them three of
    the shipped games survey as zero keys."""
    pool = list(pool or [])
    stack = []
    regs, named = {}, {}
    i = 0
    while i < len(code):
        op = code[i]
        if op == 0:
            break
        if op < 0x80:
            i += 1
            if op == 0x1C:                                   # GetVariable
                v = stack.pop() if stack else UNKNOWN
                name = text(v)
                if name and name in named:
                    stack.append(named[name])
                else:
                    stack.append(('var', name) if name else UNKNOWN)
            elif op in (0x1D, 0x3C):                         # Set/DefineLocal
                val = stack.pop() if stack else UNKNOWN
                name = text(stack.pop() if stack else UNKNOWN)
                if name:
                    if val[0] == 'call':
                        named[name] = val
                    else:
                        named.pop(name, None)
            elif op == 0x4E:                                 # GetMember
                name = stack.pop() if stack else UNKNOWN
                obj = stack.pop() if stack else UNKNOWN
                n, o = text(name), describe(obj)
                stack.append(('member', o, n) if n else UNKNOWN)
            elif op == 0x52:                                 # CallMethod
                name = stack.pop() if stack else UNKNOWN
                obj = stack.pop() if stack else UNKNOWN
                argc = num(stack.pop()) if stack else None
                args = []
                if argc is not None:
                    for _ in range(min(argc, len(stack))):
                        args.append(stack.pop())
                method, target = text(name), describe(obj)
                if target in ('Key', 'var:Key', 'flash.ui.Keyboard') or \
                        (obj[0] == 'var' and obj[1] == 'Key'):
                    rep.calls[method or '?'] += 1
                    if method == 'isDown':
                        if args and num(args[0]) is not None:
                            c = num(args[0])
                            rep.isdown[c] += 1
                            rep.sites['isDown %s' % keyname(c)].append(where)
                        else:
                            d = describe(args[0]) if args else '(no args)'
                            rep.isdown_dyn[d] += 1
                            rep.sites['isDown %s' % d].append(where)
                    stack.append(('call', 'Key', method or '?'))
                else:
                    stack.append(UNKNOWN)
            elif op in (0x0E, 0x49, 0x66, 0x48, 0x67):       # the equalities
                b = stack.pop() if stack else UNKNOWN
                a = stack.pop() if stack else UNKNOWN
                for x, y in ((a, b), (b, a)):
                    if x[0] == 'call' and x[1] == 'Key' and x[2] in ('getCode', 'getAscii'):
                        n = num(y)
                        if n is None:
                            continue
                        if x[2] == 'getAscii' and ord('a') <= n <= ord('z'):
                            n -= 32
                        rep.compared[n] += 1
                        rep.sites['%s == %s' % (x[2], keyname(n))].append(where)
                stack.append(UNKNOWN)
            elif op == 0x4C:                                 # PushDuplicate
                stack.append(stack[-1] if stack else UNKNOWN)
            elif op == 0x17:                                 # Pop
                if stack:
                    stack.pop()
            else:
                stack.clear()
            continue

        ln = struct.unpack_from('<H', code, i + 1)[0]
        body = code[i + 3:i + 3 + ln]
        nxt = i + 3 + ln
        if op == 0x96:                                       # Push
            for v in push_items(body, pool):
                stack.append(regs.get(v[1], UNKNOWN) if v[0] == 'reg' else v)
        elif op == 0x88:                                     # ConstantPool
            n = struct.unpack_from('<H', body, 0)[0]
            j, pool = 2, []
            for _ in range(n):
                k = body.index(0, j)
                pool.append(body[j:k].decode('latin1'))
                j = k + 1
        elif op == 0x87:                                     # StoreRegister
            # A COPY: the value stays on the stack.
            top = stack[-1] if stack else UNKNOWN
            if top[0] == 'call':
                regs[body[0]] = top
            else:
                regs.pop(body[0], None)
        elif op in (0x9B, 0x8E, 0x94):                       # function / with
            if op == 0x94:
                blen = struct.unpack_from('<H', body, 0)[0]
            else:
                k = body.index(0, 0)
                j = k + 1
                nparams = struct.unpack_from('<H', body, j)[0]
                j += 2
                if op == 0x8E:
                    j += 1 + 2                               # regs + flags
                for _ in range(nparams):
                    if op == 0x8E:
                        j += 1                               # register
                    k = body.index(0, j)
                    j = k + 1
                blen = struct.unpack_from('<H', body, j)[0]
            scan(code[nxt:nxt + blen], rep, where, pool)
            stack.clear()
            i = nxt + blen
            continue
        else:
            stack.clear()
        i = nxt
    return pool


# --- the four places a key can hide ---------------------------------------

def button2(body, rep, where):
    if len(body) < 6:
        return
    off = struct.unpack_from('<H', body, 3)[0]
    if off == 0:
        return
    q = 3 + off
    while q + 4 <= len(body):
        size = struct.unpack_from('<H', body, q)[0]
        cond = struct.unpack_from('<H', body, q + 2)[0]
        end = q + size if size else len(body)
        key = (cond >> 9) & 0x7F
        if key:
            rep.press[key] += 1
            rep.sites['keyPress %s' % pressname(key)].append(where)
        scan(body[q + 4:end], rep, where)
        if size == 0:
            break
        q = end


def skip_filters(b, i):
    """A PlaceObject3 FILTERLIST. Fixed sizes except the two gradient
    filters, which carry a colour count, and Convolution, whose matrix is
    sized by two of its own fields."""
    n = b[i]
    i += 1
    for _ in range(n):
        fid = b[i]
        i += 1
        if fid in (4, 7):                       # GradientGlow / GradientBevel
            ncolors = b[i]
            i += 1 + ncolors * 5 + 23
        elif fid == 5:                          # Convolution
            mx, my = b[i], b[i + 1]
            i += 2 + 4 + 4 + mx * my * 4 + 4 + 1
        else:
            i += {0: 23, 1: 9, 2: 15, 3: 27, 6: 80}[fid]
    return i


def place_clip_actions(body, rep, where, swf_version, po3=False):
    """PlaceObject2/3's ClipActions — reaching them means stepping over
    every optional field first, and PlaceObject3 has eight more of them."""
    if len(body) < 3 or not (body[0] & 0x80):
        return
    flags = body[0]
    flags2 = body[1] if po3 else 0
    i = 4 if po3 else 3
    if po3 and (flags2 & 0x08 or (flags2 & 0x10 and flags & 0x02)):
        while i < len(body) and body[i]:        # class name
            i += 1
        i += 1
    if flags & 0x02:
        i += 2
    if flags & 0x04:
        i = skip_matrix(body, i)
    if flags & 0x08:
        i = skip_cxform(body, i)
    if flags & 0x10:
        i += 2
    if flags & 0x20:
        while i < len(body) and body[i]:
            i += 1
        i += 1
    if flags & 0x40:
        i += 2
    if po3:
        if flags2 & 0x01:
            i = skip_filters(body, i)
        if flags2 & 0x02:
            i += 1                              # blend mode
        if flags2 & 0x04:
            i += 1                              # cacheAsBitmap
        if flags2 & 0x20:
            i += 1                              # visible
        if flags2 & 0x40:
            i += 4                              # opaque background
    wide = swf_version >= 6
    i += 2 + (4 if wide else 2)
    while i + (4 if wide else 2) + 4 <= len(body):
        ev = struct.unpack_from('<I' if wide else '<H', body, i)[0]
        i += 4 if wide else 2
        if ev == 0:
            break
        size = struct.unpack_from('<I', body, i)[0]
        i += 4
        if ev & (1 << 17):                                   # keyPress
            rep.clip_press[body[i]] += 1
            rep.sites['clip keyPress %s' % pressname(body[i])].append(where)
            i += 1
            size -= 1
        if ev & (1 << 6):
            rep.clip_events['keyDown'] += 1
        if ev & (1 << 7):
            rep.clip_events['keyUp'] += 1
        scan(body[i:i + size], rep, where)
        i += size


def walk(data, start, end, rep, swf_version, where='root'):
    for code, body in tags(data, start, end):
        if code in (12, 59):
            scan(body[2:] if code == 59 else body, rep, where)
        elif code == 34:
            button2(body, rep, where)
        elif code == 7:
            bid = struct.unpack_from('<H', body, 0)[0]
            i = 2
            while i < len(body) and body[i] != 0:
                i += 1 + 2 + 2
                i = skip_matrix(body, i)
            scan(body[i + 1:], rep, '%s button %d' % (where, bid))
        elif code in (26, 70):
            try:
                place_clip_actions(body, rep, where, swf_version, code == 70)
            except (IndexError, KeyError, struct.error):
                # A tag this walker cannot step over is skipped, not
                # guessed at: a misparse would invent key codes.
                rep.skipped += 1
        elif code == 39 and len(body) > 4:
            sid = struct.unpack_from('<H', body, 0)[0]
            walk(body, 4, len(body), rep, swf_version, 'sprite %d' % sid)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    show_sites = '--sites' in sys.argv
    if not args:
        print('usage: keymap.py <file.swf> [--sites]', file=sys.stderr)
        return 2
    d = load(args[0])
    rep = Report()
    walk(d, header_end(d), len(d), rep, d[3])

    def table(title, counter, name):
        if not counter:
            return
        print('\n%s' % title)
        for code, n in sorted(counter.items(), key=lambda kv: -kv[1]):
            print('  %-14s %4d' % (name(code) if callable(name) else code, n))

    table('BUTTON keyPress conditions', rep.press, pressname)
    table('CLIP keyPress events', rep.clip_press, pressname)
    table('Key.isDown(<literal>)', rep.isdown, keyname)
    if rep.isdown_dyn:
        print('\nKey.isDown(<not a literal>) — a remappable control scheme')
        for what, n in rep.isdown_dyn.most_common():
            print('  %-40s %4d' % (what, n))
    table('Key.getCode()/getAscii() compared against', rep.compared, keyname)
    if rep.clip_events:
        print('\nonClipEvent  ' + ', '.join(
            '%s x%d' % (k, v) for k, v in rep.clip_events.items()))
    if rep.calls:
        print('Key methods  ' + ', '.join(
            '%s x%d' % (k, v) for k, v in rep.calls.most_common()))
    if not (rep.press or rep.clip_press or rep.isdown or rep.isdown_dyn or
            rep.compared or rep.calls):
        print('no keyboard handling found')
    if rep.skipped:
        print('\n%d place tag(s) skipped — their clip events were not read'
              % rep.skipped)
    if show_sites:
        print('\nsites')
        for what, wheres in sorted(rep.sites.items()):
            uniq = Counter(wheres)
            print('  %-28s %s' % (what, ', '.join(
                '%s(%d)' % (w, n) for w, n in uniq.most_common(6))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
