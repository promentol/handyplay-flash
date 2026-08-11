//! Which keys does this movie actually read? Asked once, at load, so a
//! frontend can BIND ITSELF to the content instead of shipping a table
//! per genre of movie.
//!
//! AVM1 reads the keyboard in four places, and a survey that looks at
//! only one of them is wrong:
//!
//!   1. BUTTON `keyPress` conditions — the key is a FIELD of the
//!      condition; no bytecode mentions it at all.
//!   2. CLIP `onClipEvent(keyPress "x")` — likewise a byte in the event
//!      record.
//!   3. `Key.isDown(code)` — the polling form, which is what anything
//!      driven by `onEnterFrame` uses.
//!   4. `Key.getCode()` in a listener, and the literals it is COMPARED
//!      against — where a listener's key set is really written down.
//!
//! (1) and (2) are already parsed, so they cost nothing. (3) and (4) need
//! bytecode: `Key.isDown(90)` is four actions and the method name usually
//! lives in the CONSTANT POOL, so a byte scan for "isDown" finds the pool
//! and misses every call. Hence the small abstract stack below — enough
//! opcodes to follow one method call, and no more.
//!
//! The model is deliberately shallow: an opcode it does not know CLEARS
//! the stack. That can lose a call site; it cannot invent one. The
//! compilers that made these files emit the argument, the count, the
//! object and the name in one tight run, so in practice nothing real is
//! lost.
//!
//! What this is FOR is `resolve`: the frontend says "the player pressed
//! UP" and gets back the key code this particular movie listens for —
//! 38 for a desktop game, `'2'` for a phone game that only reads the
//! keypad, nothing at all for a movie that ignores the keyboard.

const std = @import("std");
const swf = @import("swf/swf.zig");
const library = @import("display/library.zig");
const opcodes = @import("avm1/opcodes.zig");
const rdr = @import("swf/reader.zig");

/// A set of Flash key codes. 256 is the whole space a `Key` code can
/// occupy — anything else a movie asks for cannot be pressed.
pub const KeySet = struct {
    bits: [4]u64 = @splat(0),

    pub fn add(self: *KeySet, code: i32) void {
        if (code < 0 or code > 255) return;
        const c: u8 = @intCast(code);
        self.bits[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
    }

    pub fn has(self: KeySet, code: i32) bool {
        if (code < 0 or code > 255) return false;
        const c: u8 = @intCast(code);
        return self.bits[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0;
    }

    pub fn merge(self: *KeySet, other: KeySet) void {
        for (&self.bits, other.bits) |*a, b| a.* |= b;
    }

    pub fn count(self: KeySet) u32 {
        var n: u32 = 0;
        for (self.bits) |b| n += @popCount(b);
        return n;
    }

    pub fn isEmpty(self: KeySet) bool {
        return self.count() == 0;
    }
};

pub const Survey = struct {
    /// The union of every source below: everything the movie can notice.
    all: KeySet = .{},
    /// How many places read each code, saturating. A key polled from an
    /// `onEnterFrame` is worth more of a gamepad button than one compared
    /// once in a cheat handler, and this is the only evidence of that.
    hits: [256]u8 = @splat(0),
    button_press: KeySet = .{},
    clip_press: KeySet = .{},
    is_down: KeySet = .{},
    /// Literals a `Key.getCode()` result was compared against.
    compared: KeySet = .{},
    /// `Key.addListener`, `getCode` or `getAscii` appear. A listener that
    /// switches on a variable leaves no literals, so this is the flag
    /// that says "there is key handling here we could not enumerate".
    listener: bool = false,
    /// `Key.isDown(<not a literal>)` — a remappable control scheme. Super
    /// Mario 63 has one; no static answer exists for those bindings.
    dynamic_is_down: bool = false,
    /// Flash Lite's device call, which is what makes a movie Flash Lite.
    /// Surveyed here because it is the same walk.
    fs_command2: bool = false,

    pub fn usesKeyboard(self: Survey) bool {
        return !self.all.isEmpty() or self.listener or self.dynamic_is_down;
    }

    /// Record one sighting of a key.
    fn note(self: *Survey, code: i32) void {
        self.all.add(code);
        if (code >= 0 and code <= 255) {
            const i: usize = @intCast(code);
            self.hits[i] +|= 1;
        }
    }
};

/// What a frontend BINDS. A physical key, a gamepad button or a touch
/// zone maps to one of these, and `resolve` turns it into the key code
/// this movie is actually listening for.
pub const Action = enum {
    up,
    down,
    left,
    right,
    /// The centre of the D-pad: fire, jump, "OK".
    select,
    /// The two extra buttons a game usually has beyond select.
    action_a,
    action_b,
    /// A handset's two soft keys, under the screen.
    soft_left,
    soft_right,
    /// `-` and `+`, which desktop Flash games bound to STAGE QUALITY
    /// often enough to be a convention — Super Mario 63 does. Worth a
    /// role of its own because the shoulder buttons are free on anything
    /// that is not a handset game.
    quality_down,
    quality_up,
    pause,
    back,
};

/// Candidates in PREFERENCE order. The first one the movie actually
/// reads wins, so a game that only knows the phone keypad gets `'2'` for
/// DOWN and a desktop game gets 40 — from the same binding.
///
/// Public because they are also SYNONYMS: a game that reads both `Left`
/// and `'4'` means one thing by them, so once the D-pad has `Left`, `'4'`
/// is not a spare key looking for a button (see `spares`).
pub fn candidates(a: Action) []const i32 {
    return switch (a) {
        .up => &.{ 38, '2', 104, 'W' },
        .down => &.{ 40, '8', 98, 'S' },
        .left => &.{ 37, '4', 100, 'A' },
        .right => &.{ 39, '6', 102, 'D' },
        .select => &.{ 13, 32, '5', 101, 'Z' },
        .action_a => &.{ 'Z', 32, 13, 'X', 17, '5' },
        .action_b => &.{ 'X', 16, 17, 'C' },
        .soft_left => &.{ 33, 'Q', 112 },
        .soft_right => &.{ 34, 'W', 113 },
        // 189/187 are the `-` and `=` keys; 109/107 the keypad pair.
        .quality_down => &.{ 189, 109 },
        .quality_up => &.{ 187, 107 },
        .pause => &.{ 'P', 27, 19, 13 },
        .back => &.{ 27, 8, 34, 'B' },
    };
}

/// The key code this movie listens for, or null when it listens for
/// none of them — in which case the frontend should send whatever the
/// physical key means, since guessing would be worse than passing it on.
///
/// UP and DOWN read `'2'` and `'8'` the way a phone keypad is LAID OUT,
/// not the way a number line runs: 2 is above 8.
pub fn resolve(s: Survey, a: Action) ?i32 {
    for (candidates(a)) |code| {
        if (s.all.has(code)) return code;
    }
    return null;
}

/// A Flash key code, for reading. Both frontends print these — the SDL
/// player in its load banner, the libretro core in the input descriptors
/// RetroArch shows — and two tables would drift the first time one of
/// them learned a key.
///
/// Codes with no name are the caller's problem: it knows whether to print
/// the number or drop it.
pub fn keyName(code: i32) ?[]const u8 {
    return switch (code) {
        8 => "Backspace",
        9 => "Tab",
        13 => "Enter",
        16 => "Shift",
        17 => "Ctrl",
        18 => "Alt",
        20 => "CapsLock",
        27 => "Esc",
        32 => "Space",
        33 => "PageUp",
        34 => "PageDown",
        35 => "End",
        36 => "Home",
        37 => "Left",
        38 => "Up",
        39 => "Right",
        40 => "Down",
        45 => "Insert",
        46 => "Delete",
        144 => "NumLock",
        186 => ";",
        187 => "=",
        188 => ",",
        189 => "-",
        190 => ".",
        191 => "/",
        192 => "`",
        219 => "[",
        220 => "\\",
        221 => "]",
        222 => "'",
        else => blk: {
            if (code >= '0' and code <= '9') break :blk DIGITS[@intCast(code - '0')];
            if (code >= 'A' and code <= 'Z') break :blk LETTERS[@intCast(code - 'A')];
            if (code >= 96 and code <= 111) break :blk PAD[@intCast(code - 96)];
            if (code >= 112 and code <= 123) break :blk FKEYS[@intCast(code - 112)];
            break :blk null;
        },
    };
}

const DIGITS = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
const LETTERS = [_][]const u8{
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
};
const PAD = [_][]const u8{
    "Pad0", "Pad1", "Pad2",   "Pad3", "Pad4",   "Pad5", "Pad6", "Pad7",
    "Pad8", "Pad9", "Pad*",   "Pad+", "PadSep", "Pad-", "Pad.", "Pad/",
};
const FKEYS = [_][]const u8{
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
};

/// The keys the fixed roles did NOT claim, best first.
///
/// `resolve` only ever asks for the eleven roles a pad has words for, and
/// a real game reads more than that: Super Mario 63 reads `Space`, `C`,
/// `A`, `S` and `D` on top of `Z` and `X`, and without this pass they
/// reach no button at all. Feed the leftovers to whatever buttons are
/// still free.
///
/// Ranked by what a key LOOKS like it is for, then by how many places
/// read it, then by code so the answer never depends on iteration order:
///
///   1. `Space` — the one key every author reaches for after the arrows
///   2. letters — a named action (`Z` jump, `C` camera)
///   3. digits — a keypad, or a menu selector
///   4. modifiers — Shift and Ctrl are usually an alternate fire
///   5. everything else — punctuation, Delete, the function row
///
/// Returns how many were written to `out`.
pub fn spares(s: Survey, claimed_in: KeySet, out: []i32) usize {
    // A DIRECTION has true synonyms: arrows, the 2/4/6/8 keypad and WASD
    // are three spellings of one intent, so once the D-pad has one of
    // them the others are not spare keys looking for a button. Tetrix
    // reads two of the three and would otherwise spend all four shoulders
    // on a direction the stick already covers.
    //
    // The ACTION roles are not like that, and claiming their alternates
    // is how Super Mario 63 lost `Space` and `C` the first time this was
    // written: `Space` is a candidate for `action_a`, but in a game that
    // binds `Z` to jump it is a different button, not another word for
    // the same one.
    var claimed = claimed_in;
    for ([_]Action{ .up, .down, .left, .right }) |a| {
        if (resolve(s, a) == null) continue;
        for (candidates(a)) |code| {
            if (s.all.has(code)) claimed.add(code);
        }
    }
    var buf: [256]i32 = undefined;
    var n: usize = 0;
    var code: i32 = 0;
    while (code < 256) : (code += 1) {
        if (!s.all.has(code) or claimed.has(code)) continue;
        // A direction or a soft key that went unclaimed is unclaimed for
        // a reason — the pad already has those, under their own roles.
        if (isReserved(code)) continue;
        buf[n] = code;
        n += 1;
    }
    std.mem.sort(i32, buf[0..n], s, lessUseful);
    const take = @min(n, out.len);
    @memcpy(out[0..take], buf[0..take]);
    return take;
}

fn isReserved(code: i32) bool {
    return switch (code) {
        37, 38, 39, 40 => true, // the D-pad
        33, 34 => true, // the soft keys
        13 => true, // select
        else => false,
    };
}

fn tierOf(code: i32) u8 {
    if (code == 32) return 0;
    if (code >= 'A' and code <= 'Z') return 1;
    if (code >= '0' and code <= '9') return 2;
    if (code >= 96 and code <= 105) return 2; // the numeric keypad
    if (code == 16 or code == 17 or code == 18) return 3;
    return 4;
}

fn lessUseful(s: Survey, a: i32, b: i32) bool {
    const ta = tierOf(a);
    const tb = tierOf(b);
    if (ta != tb) return ta < tb;
    const ha = s.hits[@intCast(a)];
    const hb = s.hits[@intCast(b)];
    if (ha != hb) return ha > hb;
    return a < b;
}

// --- the walk ---------------------------------------------------------------

pub fn survey(movie: *const swf.movie.Movie) Survey {
    var s: Survey = .{};
    frames(&s, movie.frames);
    var it = movie.lib.characters.valueIterator();
    while (it.next()) |ch| switch (ch.*) {
        .sprite => |sp| frames(&s, sp.frames),
        .button => |b| for (b.actions) |a| {
            // The condition's own key field, in the keyPress numbering.
            const key = (a.conditions >> 9) & 0x7F;
            if (key != 0) {
                const code = fromPressCode(@intCast(key));
                s.button_press.add(code);
                s.note(code);
            }
            scan(&s, a.actions, null, 0);
        },
        else => {},
    };
    return s;
}

fn frames(s: *Survey, list: []const library.Frame) void {
    for (list) |f| for (f.controls) |c| switch (c) {
        .do_action => |code| scan(s, code, null, 0),
        .init_action => |ia| scan(s, ia.code, null, 0),
        .place => |po| for (po.clip_actions) |ca| {
            if (ca.key_code) |k| {
                const code = fromPressCode(k);
                s.clip_press.add(code);
                s.note(code);
            }
            scan(s, ca.actions, null, 0);
        },
        else => {},
    };
}

/// `keyPress` codes are their OWN numbering, not `Key`'s: 16 is PageUp
/// there and Shift here (ruffle events.rs ButtonKeyCode). Anything else
/// is a CHARACTER, whose key code is its uppercase form.
pub fn fromPressCode(k: u8) i32 {
    return switch (k) {
        1 => 37, // left
        2 => 39, // right
        3 => 36, // home
        4 => 35, // end
        5 => 45, // insert
        6 => 46, // delete
        8 => 8, // backspace
        13 => 13, // enter
        14 => 38, // up
        15 => 40, // down
        16 => 33, // page up — a handset's LEFT soft key
        17 => 34, // page down — the right one
        18 => 9, // tab
        19 => 27, // escape
        else => if (k >= 'a' and k <= 'z') @as(i32, k) - 32 else @as(i32, k),
    };
}

// --- the abstract stack -----------------------------------------------------

const Val = union(enum) {
    num: f64,
    str: []const u8,
    /// A variable read: `Key` is the only name that matters here.
    variable: []const u8,
    /// The result of `Key.getCode()`.
    key_code_call,
    /// The result of `Key.getAscii()`, which answers in ASCII and not in
    /// key codes — `'z'` is 122 there and 90 as a key.
    key_ascii_call,
    unknown,
};

const MAX_STACK = 64;
const MAX_REGS = 8;
/// How many local names we will remember as "holds a key code". Four is
/// enough for `var k = Key.getCode()` and its rewrites; a fifth would
/// mean the blob is doing something this model has no business guessing
/// at.
const MAX_TRACKED = 4;

/// Where a `Key.getCode()` result went, so a later comparison can be
/// recognised as a key binding. Without this a listener written the
/// ordinary way — `var k = Key.getCode(); if (k == 13) …` — surveys as
/// zero keys, which is what three of the shipped games did.
const Tracked = struct {
    /// `.unknown` means "not a key answer"; the other two say WHICH
    /// question was asked, because they answer in different alphabets.
    regs: [MAX_REGS]Val = @splat(.unknown),
    names: [MAX_TRACKED][]const u8 = @splat(""),
    kinds: [MAX_TRACKED]Val = @splat(.unknown),
    n_names: usize = 0,

    fn remember(self: *Tracked, name: []const u8, kind: Val) void {
        for (self.names[0..self.n_names], self.kinds[0..self.n_names]) |n, *k| {
            if (std.mem.eql(u8, n, name)) {
                k.* = kind;
                return;
            }
        }
        if (self.n_names == MAX_TRACKED) return;
        self.names[self.n_names] = name;
        self.kinds[self.n_names] = kind;
        self.n_names += 1;
    }

    fn forget(self: *Tracked, name: []const u8) void {
        var i: usize = 0;
        while (i < self.n_names) : (i += 1) {
            if (std.mem.eql(u8, self.names[i], name)) {
                self.names[i] = self.names[self.n_names - 1];
                self.kinds[i] = self.kinds[self.n_names - 1];
                self.n_names -= 1;
                return;
            }
        }
    }

    /// What that name holds — `.unknown` when it is not a key answer.
    fn holds(self: Tracked, name: []const u8) Val {
        for (self.names[0..self.n_names], self.kinds[0..self.n_names]) |n, k| {
            if (std.mem.eql(u8, n, name)) return k;
        }
        return .unknown;
    }
};

const Stack = struct {
    items: [MAX_STACK]Val = @splat(.unknown),
    len: usize = 0,

    fn push(self: *Stack, v: Val) void {
        if (self.len == MAX_STACK) return;
        self.items[self.len] = v;
        self.len += 1;
    }

    fn pop(self: *Stack) Val {
        if (self.len == 0) return .unknown;
        self.len -= 1;
        return self.items[self.len];
    }

    fn clear(self: *Stack) void {
        self.len = 0;
    }
};

fn numOf(v: Val) ?i32 {
    return switch (v) {
        .num => |n| if (std.math.isFinite(n) and n >= -2147483648 and n <= 2147483647)
            @intFromFloat(@trunc(n))
        else
            null,
        else => null,
    };
}

fn strOf(v: Val) ?[]const u8 {
    return switch (v) {
        .str => |t| t,
        else => null,
    };
}

/// One action blob. `pool` is inherited by nested bodies — a
/// DefineFunction shares its parent's constant pool.
fn scan(s: *Survey, code: []const u8, pool_in: ?ConstPool, depth: u8) void {
    if (depth > 16) return;
    var pool = pool_in orelse ConstPool{};
    var stack: Stack = .{};
    var tracked: Tracked = .{};
    var r = rdr.Reader.init(code);
    while (opcodes.readAction(&r) catch return) |action| switch (action) {
        .push => |raw| {
            var it = opcodes.PushIterator.init(raw);
            while (it.next()) |v| stack.push(switch (v) {
                .string => |t| .{ .str = t },
                .float => |f| .{ .num = f },
                .double => |d| .{ .num = d },
                .int => |n| .{ .num = @floatFromInt(n) },
                .const8 => |i| pool.get(i),
                .const16 => |i| pool.get(i),
                .register => |i| if (i < MAX_REGS) tracked.regs[i] else Val{ .unknown = {} },
                else => .unknown,
            });
        },
        .constant_pool => |cp| pool = .{ .count = cp.count, .raw = cp.raw },
        // `StoreRegister` COPIES the top of the stack, it does not pop.
        .store_register => |reg| if (reg < MAX_REGS) {
            tracked.regs[reg] = if (stack.len > 0) stack.items[stack.len - 1] else .unknown;
        },
        .define_function => |f| {
            scan(s, f.body, pool, depth + 1);
            stack.clear();
        },
        .define_function2 => |f| {
            scan(s, f.body, pool, depth + 1);
            stack.clear();
        },
        .with_op => |w| {
            scan(s, w.body, pool, depth + 1);
            stack.clear();
        },
        .try_op => |t| {
            scan(s, t.try_body, pool, depth + 1);
            scan(s, t.catch_body, pool, depth + 1);
            scan(s, t.finally_body, pool, depth + 1);
            stack.clear();
        },
        .simple => |op| switch (op) {
            .fs_command2 => {
                s.fs_command2 = true;
                stack.clear();
            },
            .get_variable => {
                const name = strOf(stack.pop());
                if (name) |n| {
                    const held = tracked.holds(n);
                    stack.push(if (held == .unknown) .{ .variable = n } else held);
                } else stack.push(.unknown);
            },
            // `var k = Key.getCode()` — remember where the answer went.
            .set_variable, .define_local => {
                const v = stack.pop();
                const name = strOf(stack.pop());
                if (name) |n| {
                    if (v == .key_code_call or v == .key_ascii_call)
                        tracked.remember(n, v)
                    else
                        tracked.forget(n);
                }
            },
            .get_member => {
                _ = stack.pop();
                _ = stack.pop();
                stack.push(.unknown);
            },
            .call_method => {
                const name = strOf(stack.pop());
                const obj = stack.pop();
                const argc = numOf(stack.pop());
                var args: [4]Val = @splat(.unknown);
                var n: usize = 0;
                if (argc) |c| {
                    const want: usize = @intCast(@max(0, @min(c, MAX_STACK)));
                    while (n < want) : (n += 1) {
                        const v = stack.pop();
                        if (n < args.len) args[n] = v;
                    }
                }
                const on_key = switch (obj) {
                    .variable => |v| std.mem.eql(u8, v, "Key"),
                    else => false,
                };
                var result: Val = .unknown;
                if (on_key) if (name) |m| {
                    if (std.mem.eql(u8, m, "isDown")) {
                        if (argc != null and argc.? > 0) {
                            if (numOf(args[0])) |c| {
                                s.is_down.add(c);
                                s.note(c);
                            } else s.dynamic_is_down = true;
                        } else s.dynamic_is_down = true;
                    } else if (std.mem.eql(u8, m, "getCode")) {
                        s.listener = true;
                        result = .key_code_call;
                    } else if (std.mem.eql(u8, m, "getAscii")) {
                        s.listener = true;
                        result = .key_ascii_call;
                    } else if (std.mem.eql(u8, m, "addListener")) {
                        s.listener = true;
                    }
                };
                stack.push(result);
            },
            // The equalities: a `getCode()` on one side and a literal on
            // the other is a listener writing down its key set.
            .equals, .equals2, .strict_equals => {
                const b = stack.pop();
                const a = stack.pop();
                const pair: [2][2]Val = .{ .{ a, b }, .{ b, a } };
                for (pair) |p| {
                    const n = numOf(p[1]) orelse continue;
                    const bound = switch (p[0]) {
                        .key_code_call => n,
                        // An ASCII answer names a CHARACTER; the key that
                        // produced it is the uppercase one.
                        .key_ascii_call => if (n >= 'a' and n <= 'z') n - 32 else n,
                        else => continue,
                    };
                    s.compared.add(bound);
                    s.note(bound);
                }
                stack.push(.unknown);
            },
            .push_duplicate => {
                const v = if (stack.len > 0) stack.items[stack.len - 1] else Val.unknown;
                stack.push(v);
            },
            .pop => _ = stack.pop(),
            else => stack.clear(),
        },
        else => stack.clear(),
    };
}

/// The raw ConstantPool payload, indexed on demand — the strings slice
/// into the movie buffer, so nothing is copied.
const ConstPool = struct {
    count: u16 = 0,
    raw: []const u8 = &.{},

    fn get(self: ConstPool, idx: u16) Val {
        if (idx >= self.count) return .unknown;
        var i: usize = 0;
        var n: u16 = 0;
        while (i < self.raw.len) {
            const end = std.mem.indexOfScalarPos(u8, self.raw, i, 0) orelse return .unknown;
            if (n == idx) return .{ .str = self.raw[i..end] };
            n += 1;
            i = end + 1;
        }
        return .unknown;
    }
};

test "keyPress codes are their own numbering" {
    try std.testing.expectEqual(@as(i32, 33), fromPressCode(16));
    try std.testing.expectEqual(@as(i32, 38), fromPressCode(14));
    try std.testing.expectEqual(@as(i32, 'Z'), fromPressCode('z'));
    try std.testing.expectEqual(@as(i32, '5'), fromPressCode('5'));
}

test "resolve prefers what the movie actually reads" {
    var s: Survey = .{};
    // A phone game: the keypad, no arrows.
    s.all.add('2');
    s.all.add('8');
    s.all.add('5');
    try std.testing.expectEqual(@as(?i32, '2'), resolve(s, .up));
    try std.testing.expectEqual(@as(?i32, '8'), resolve(s, .down));
    try std.testing.expectEqual(@as(?i32, '5'), resolve(s, .select));
    try std.testing.expectEqual(@as(?i32, null), resolve(s, .soft_left));

    // A desktop game: arrows win over the keypad when both are read.
    var d: Survey = .{};
    d.all.add(38);
    d.all.add('2');
    try std.testing.expectEqual(@as(?i32, 38), resolve(d, .up));
}
