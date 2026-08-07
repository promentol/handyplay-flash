//! AVM1 values + the primitive-only ES3 coercions. Coercions that can hit
//! the object graph (ToPrimitive via valueOf/toString, Add2's object arms,
//! abstract == with objects) live on the Vm (runtime.zig) — this file is
//! dependency-free math and the exact ES3 number↔string conversions, the
//! single biggest source of trace-conformance failures when wrong.
//!
//! References: ECMA-262 3rd ed. §9 (open-flash mirrors it) and ruffle
//! core/src/avm1/value.rs + ecma_conversions.rs.

const std = @import("std");
const strings = @import("string.zig");

pub const ObjectHandle = u32;

pub const Value = union(enum) {
    undefined_value,
    null_value,
    boolean: bool,
    number: f64,
    string: strings.AvmString,
    object: ObjectHandle,

    pub fn fromF64(n: f64) Value {
        return .{ .number = n };
    }
    pub fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn isPrimitive(v: Value) bool {
        return v != .object;
    }
};

/// ES3 §9.2 ToBoolean — with the SWF quirk: in SWF ≤ 6, a number is true
/// only when non-zero AND non-NaN (same as ES3); strings in SWF ≤ 6 coerce
/// via ToNumber first (Flash oddity, ruffle value.rs as_bool).
pub fn toBoolean(v: Value, swf_version: u8) bool {
    return switch (v) {
        .undefined_value, .null_value => false,
        .boolean => |b| b,
        .number => |n| !(n == 0 or std.math.isNan(n)),
        .string => |s| blk: {
            if (swf_version < 7) {
                const n = stringToNumber(s);
                break :blk !(n == 0 or std.math.isNan(n));
            }
            break :blk s.len > 0;
        },
        .object => true,
    };
}

/// ES3 §9.3 ToNumber for primitives. Objects must go through the Vm's
/// ToPrimitive first (valueOf); calling this on an object yields NaN
/// (matching a default-valueOf-less object).
pub fn toNumberPrimitive(v: Value, swf_version: u8) f64 {
    return switch (v) {
        // SWF ≤ 6: undefined coerces to 0 (ruffle value.rs); ES3/SWF7+: NaN.
        .undefined_value => if (swf_version < 7) 0 else std.math.nan(f64),
        .null_value => if (swf_version < 7) 0 else std.math.nan(f64),
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| stringToNumber(s),
        .object => std.math.nan(f64),
    };
}

/// ES3 §9.3.1 ToNumber(String): optional whitespace, optional sign,
/// decimal/hex literal, Infinity; empty → 0; anything else → NaN.
pub fn stringToNumber(s: strings.AvmString) f64 {
    var i: usize = 0;
    while (i < s.len and isWs(s[i])) i += 1;
    var j: usize = s.len;
    while (j > i and isWs(s[j - 1])) j -= 1;
    const t = s[i..j];
    if (t.len == 0) return 0;

    // Hex literal (no sign allowed per ES3).
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        var acc: f64 = 0;
        for (t[2..]) |c| {
            const d = hexDigit(c) orelse return std.math.nan(f64);
            acc = acc * 16 + @as(f64, @floatFromInt(d));
        }
        return acc;
    }

    var buf: [64]u8 = undefined;
    if (t.len > buf.len) return std.math.nan(f64);
    for (t, 0..) |c, k| {
        if (c > 0x7F) return std.math.nan(f64);
        buf[k] = @intCast(c);
    }
    const ascii = buf[0..t.len];

    var body = ascii;
    var neg = false;
    if (body.len > 0 and (body[0] == '+' or body[0] == '-')) {
        neg = body[0] == '-';
        body = body[1..];
    }
    if (std.mem.eql(u8, body, "Infinity")) {
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    }
    // Reject forms parseFloat would accept but ES3 StrToNum shouldn't
    // (e.g. "1f"): parse then require full consumption via parseFloat's
    // strictness — std.fmt.parseFloat rejects trailing garbage already.
    const n = std.fmt.parseFloat(f64, ascii) catch return std.math.nan(f64);
    // parseFloat accepts "nan"/"inf" spellings ES3 doesn't.
    if (std.ascii.indexOfIgnoreCase(ascii, "nan") != null) return std.math.nan(f64);
    if (std.ascii.indexOfIgnoreCase(ascii, "inf") != null) return std.math.nan(f64);
    return n;
}

fn isWs(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C or c == 0xA0;
}

fn hexDigit(c: u16) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// ES3 §9.5/9.6/9.7 modular integer conversions.
pub fn toInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const m = @mod(@trunc(n), 4294967296.0);
    const u: u32 = @intFromFloat(if (m < 0) m + 4294967296.0 else m);
    return @bitCast(u);
}

pub fn toUint32(n: f64) u32 {
    return @bitCast(toInt32(n));
}

pub fn toUint16(n: f64) u16 {
    return @truncate(toUint32(n));
}

/// ES3 §9.8.1 ToString(Number) — exact JS formatting: shortest
/// round-trip digits, integer notation for 1 ≤ |n| < 1e21, fixed decimals
/// down to 1e-6, exponential beyond. `buf` needs ~32 bytes.
pub fn numberToStringBuf(buf: []u8, n: f64) []const u8 {
    if (std.math.isNan(n)) return copyInto(buf, "NaN");
    if (n == 0) return copyInto(buf, "0");
    if (std.math.isInf(n)) {
        return copyInto(buf, if (n < 0) "-Infinity" else "Infinity");
    }

    // Shortest digits via std's scientific renderer: "-d.ddde±x".
    var sci_buf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&sci_buf, n, .{ .mode = .scientific }) catch unreachable;
    var idx: usize = 0;
    var out_len: usize = 0;
    var negative = false;
    if (sci[idx] == '-') {
        negative = true;
        idx += 1;
    }
    var digits: [20]u8 = undefined;
    var ndigits: usize = 0;
    digits[ndigits] = sci[idx];
    ndigits += 1;
    idx += 1;
    if (idx < sci.len and sci[idx] == '.') {
        idx += 1;
        while (idx < sci.len and sci[idx] != 'e') : (idx += 1) {
            digits[ndigits] = sci[idx];
            ndigits += 1;
        }
    }
    while (idx < sci.len and sci[idx] != 'e') idx += 1;
    idx += 1; // past 'e'
    const exp10 = std.fmt.parseInt(i32, sci[idx..], 10) catch 0;
    // Trim trailing zero digits (renderer may emit "1.0e0"-style).
    while (ndigits > 1 and digits[ndigits - 1] == '0') ndigits -= 1;

    // ES3 notation: k digits, value = s × 10^(pos - k) with pos = exp10+1.
    const k: i32 = @intCast(ndigits);
    const pos: i32 = exp10 + 1; // decimal point position
    var w: usize = 0;
    if (negative) {
        buf[w] = '-';
        w += 1;
    }
    if (pos >= 1 and pos <= 21) {
        if (k <= pos) {
            // ddd000
            @memcpy(buf[w..][0..ndigits], digits[0..ndigits]);
            w += ndigits;
            var z: i32 = pos - k;
            while (z > 0) : (z -= 1) {
                buf[w] = '0';
                w += 1;
            }
        } else {
            // dd.ddd
            const ipart: usize = @intCast(pos);
            @memcpy(buf[w..][0..ipart], digits[0..ipart]);
            w += ipart;
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w..][0 .. ndigits - ipart], digits[ipart..ndigits]);
            w += ndigits - ipart;
        }
    } else if (pos <= 0 and pos > -6) {
        // 0.000ddd
        buf[w] = '0';
        w += 1;
        buf[w] = '.';
        w += 1;
        var z: i32 = -pos;
        while (z > 0) : (z -= 1) {
            buf[w] = '0';
            w += 1;
        }
        @memcpy(buf[w..][0..ndigits], digits[0..ndigits]);
        w += ndigits;
    } else {
        // Exponential d.ddde±x with exponent = pos - 1.
        buf[w] = digits[0];
        w += 1;
        if (ndigits > 1) {
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w..][0 .. ndigits - 1], digits[1..ndigits]);
            w += ndigits - 1;
        }
        buf[w] = 'e';
        w += 1;
        const e = pos - 1;
        buf[w] = if (e < 0) '-' else '+';
        w += 1;
        const abs_e: u32 = @intCast(if (e < 0) -e else e);
        const estr = std.fmt.bufPrint(buf[w..], "{d}", .{abs_e}) catch unreachable;
        w += estr.len;
    }
    out_len = w;
    return buf[0..out_len];
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// typeof for primitives (objects/functions decided by the Vm).
pub fn typeOfPrimitive(v: Value) []const u8 {
    return switch (v) {
        .undefined_value => "undefined",
        .null_value => "null", // AVM1: typeof null == "null"
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => "object",
    };
}

// --- Tests -----------------------------------------------------------------

fn expectNum(expected: []const u8, n: f64) !void {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings(expected, numberToStringBuf(&buf, n));
}

test "ES3 ToString(Number) formatting" {
    try expectNum("0", 0.0);
    try expectNum("0", -0.0);
    try expectNum("NaN", std.math.nan(f64));
    try expectNum("Infinity", std.math.inf(f64));
    try expectNum("-Infinity", -std.math.inf(f64));
    try expectNum("1", 1.0);
    try expectNum("-7", -7.0);
    try expectNum("42", 42.0);
    try expectNum("1000000", 1e6);
    try expectNum("0.5", 0.5);
    try expectNum("1.5", 1.5);
    try expectNum("0.1", 0.1);
    // Runtime addition (comptime 0.1+0.2 folds in f128 and lands on a
    // different f64 that legitimately prints "0.3").
    var x: f64 = 0.1;
    x += 0.2;
    try expectNum("0.30000000000000004", x);
    try expectNum("3.141592653589793", std.math.pi);
    try expectNum("100000000000000000000", 1e20);
    try expectNum("1e+21", 1e21);
    try expectNum("0.000001", 1e-6);
    try expectNum("1e-7", 1e-7);
    try expectNum("1.25e-7", 1.25e-7);
    try expectNum("123456.789", 123456.789);
    try expectNum("2147483647", 2147483647.0);
    try expectNum("-2147483648", -2147483648.0);
}

test "ToNumber(String) and integer conversions" {
    const S = strings.ascii;
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S("")));
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S("  ")));
    try std.testing.expectEqual(@as(f64, 42), stringToNumber(S(" 42 ")));
    try std.testing.expectEqual(@as(f64, -1.5), stringToNumber(S("-1.5")));
    try std.testing.expectEqual(@as(f64, 255), stringToNumber(S("0xFF")));
    try std.testing.expect(std.math.isNan(stringToNumber(S("12ab"))));
    try std.testing.expect(std.math.isNan(stringToNumber(S("Zoo"))));
    try std.testing.expect(std.math.isPositiveInf(stringToNumber(S("Infinity"))));
    try std.testing.expectEqual(@as(f64, 3e2), stringToNumber(S("3e2")));

    try std.testing.expectEqual(@as(i32, -1), toInt32(4294967295.0));
    try std.testing.expectEqual(@as(i32, 0), toInt32(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, -2147483648), toInt32(2147483648.0));
    try std.testing.expectEqual(@as(u32, 4294967295), toUint32(-1.0));
    try std.testing.expectEqual(@as(i32, 5), toInt32(5.9));
    try std.testing.expectEqual(@as(i32, -5), toInt32(-5.9));
}

test "ToBoolean quirks by SWF version" {
    const S = strings.ascii;
    try std.testing.expect(!toBoolean(.{ .string = S("abc") }, 6)); // NaN → false
    try std.testing.expect(toBoolean(.{ .string = S("abc") }, 7)); // non-empty → true
    try std.testing.expect(toBoolean(.{ .string = S("3") }, 6));
    try std.testing.expect(!toBoolean(.{ .string = S("0") }, 7) == false); // "0" non-empty → true in v7
    try std.testing.expect(!toBoolean(.{ .number = 0 }, 7));
    try std.testing.expect(!toBoolean(.undefined_value, 7));
}
