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
                const n = stringToNumber(s, swf_version);
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
        .string => |s| stringToNumber(s, swf_version),
        .object => std.math.nan(f64),
    };
}

/// Flash's ToNumber(String) — NOT ES3's, and it changes with SWF version
/// (ruffle avm1/value.rs `string_to_f64`). Three regimes:
///
///   • SWF ≥ 6: a leading `0x` means hex and a leading `0` followed only by
///     digits 0-7 means OCTAL; both parse as a WRAPPING i32. `"013"` is 11,
///     not 13.
///   • SWF 5: strict decimal — trailing garbage is NaN.
///   • SWF ≤ 4: lenient — parse the numeric prefix and ignore the rest,
///     then turn NaN into 0. `"11ABC"` is 11 and `"ABC"` is 0.
///
/// The `getproperty`/`getproperty_swf4`/`getproperty_swf5` corpus tests are
/// the same script at three versions and exist to pin exactly this.
pub fn stringToNumber(s: strings.AvmString, swf_version: u8) f64 {
    if (swf_version >= 6) {
        const radix = guessRadix(s);
        if (radix != 10) {
            // Bug compatibility: Flash strips the `0x` by position, so a
            // SIGNED hex literal keeps its `x` and fails to parse.
            const body = if (radix == 16) s[@min(2, s.len)..] else s;
            return parseIntRadix(body, radix) orelse std.math.nan(f64);
        }
    }
    const strict = swf_version >= 5;
    const result = parseFloatImpl(s, strict);
    if (!strict and std.math.isNan(result)) return 0;
    return result;
}

/// ruffle `guess_radix`: 16 for `0x`, 8 for a leading `0` with all-octal
/// digits, else 10. One optional sign is skipped first.
fn guessRadix(str: strings.AvmString) u8 {
    var s = str;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];
    if (s.len == 0 or s[0] != '0') return 10;
    s = s[1..];
    if (s.len > 0 and (s[0] == 'x' or s[0] == 'X')) return 16;
    for (s) |c| {
        if (c < '0' or c > '7') return 10;
    }
    return 8;
}

/// ruffle `Wrapping::<i32>::from_wstr_radix` — wraps on overflow, null on
/// an empty body or any digit outside the radix.
fn parseIntRadix(str: strings.AvmString, radix: u8) ?f64 {
    var s = str;
    var neg = false;
    if (s.len == 0) return null;
    if (s[0] == '-' or s[0] == '+') {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;
    var acc: i32 = 0;
    for (s) |c| {
        const d = digitValue(c) orelse return null;
        if (d >= radix) return null;
        acc = acc *% radix;
        acc = if (neg) acc -% @as(i32, d) else acc +% @as(i32, d);
    }
    return @floatFromInt(acc);
}

/// ruffle `parse_float_impl`. Note it has NO `Infinity` literal — AVM1
/// `Number("Infinity")` really is NaN. In lenient mode a numeric prefix is
/// accepted and the tail ignored.
fn parseFloatImpl(str: strings.AvmString, strict: bool) f64 {
    const nan = std.math.nan(f64);
    var s = str;
    while (s.len > 0 and isWs(s[0])) s = s[1..];

    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    const after_sign = s;

    // Integer part. `exp` is the power of ten of the leading digit.
    while (s.len > 0 and isDigit(s[0])) s = s[1..];
    var exp: i32 = @as(i32, @intCast(after_sign.len - s.len)) - 1;

    // Fractional part.
    if (s.len > 0 and s[0] == '.') {
        s = s[1..];
        while (s.len > 0 and isDigit(s[0])) s = s[1..];
    }

    // No digits at all → not a number.
    if (s.len == after_sign.len) return nan;

    if (s.len > 0 and (s[0] == 'e' or s[0] == 'E')) {
        s = s[1..];
        var exp_neg = false;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            exp_neg = s[0] == '-';
            s = s[1..];
        }
        var exponent: i32 = 0;
        while (s.len > 0 and isDigit(s[0])) : (s = s[1..]) {
            exponent = exponent *% 10;
            exponent = exponent +% @as(i32, @intCast(s[0] - '0'));
        }
        if (exp_neg) exponent = -%exponent;
        exp = exp +% exponent;
    }

    if (strict and s.len != 0) return nan;

    // Accumulate digit-by-digit from the sign-stripped head; a second '.'
    // is skipped rather than terminating (Flash allows multiple dots).
    var result: f64 = 0;
    var e = exp;
    for (after_sign) |c| {
        if (isDigit(c)) {
            result += decimalShift(@floatFromInt(c - '0'), e);
            e -%= 1;
        } else if (c == '.') {
            // Allow multiple dots.
        } else break;
    }
    return if (neg) -result else result;
}

/// `value * 10^exp` by repeated squaring. The multiply and divide branches
/// are deliberately separate — that asymmetry is Flash's rounding.
fn decimalShift(value: f64, exp: i32) f64 {
    var v = value;
    var base: f64 = 10.0;
    if (exp > 0) {
        var e = exp;
        while (e > 0) {
            if (e & 1 != 0) v *= base;
            e >>= 1;
            base *= base;
        }
    } else {
        var e: u32 = @abs(exp);
        while (e > 0) {
            if (e & 1 != 0) v /= base;
            e >>= 1;
            base *= base;
        }
    }
    return v;
}

fn isDigit(c: u16) bool {
    return c >= '0' and c <= '9';
}

fn isWs(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C or c == 0xA0;
}

fn digitValue(c: u16) ?u8 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'z' => @intCast(c - 'a' + 10),
        'A'...'Z' => @intCast(c - 'A' + 10),
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
    // Common ground across versions.
    for ([_]u8{ 4, 5, 6 }) |v| {
        try std.testing.expectEqual(@as(f64, 42), stringToNumber(S(" 42"), v));
        try std.testing.expectEqual(@as(f64, -1.5), stringToNumber(S("-1.5"), v));
        try std.testing.expectEqual(@as(f64, 3e2), stringToNumber(S("3e2"), v));
    }
    // Only LEADING whitespace is trimmed, so a trailing space is garbage
    // and strict mode rejects it (ruffle parse_float_impl `trim_start`).
    try std.testing.expect(std.math.isNan(stringToNumber(S(" 42 "), 5)));
    try std.testing.expectEqual(@as(f64, 42), stringToNumber(S(" 42 "), 4));
    // SWF≥6 guesses a radix — this is the `getproperty` index table.
    try std.testing.expectEqual(@as(f64, 11), stringToNumber(S("013"), 6)); // octal!
    try std.testing.expectEqual(@as(f64, 19), stringToNumber(S("0x13"), 6));
    try std.testing.expectEqual(@as(f64, 255), stringToNumber(S("0xFF"), 6));
    try std.testing.expect(std.math.isNan(stringToNumber(S("11ABC"), 6)));
    try std.testing.expect(std.math.isNan(stringToNumber(S("ABC"), 6)));
    // Flash strips `0x` by position, so a signed hex literal keeps its `x`.
    try std.testing.expect(std.math.isNan(stringToNumber(S("-0x10"), 6)));
    try std.testing.expectEqual(@as(f64, 8), stringToNumber(S("08"), 6)); // not octal
    // SWF5: strict decimal, no radix guessing.
    try std.testing.expectEqual(@as(f64, 13), stringToNumber(S("013"), 5));
    try std.testing.expect(std.math.isNan(stringToNumber(S("0x13"), 5)));
    try std.testing.expect(std.math.isNan(stringToNumber(S("11ABC"), 5)));
    try std.testing.expect(std.math.isNan(stringToNumber(S("ABC"), 5)));
    try std.testing.expect(std.math.isNan(stringToNumber(S("12ab"), 5)));
    // SWF4: lenient prefix parse, NaN collapses to 0.
    try std.testing.expectEqual(@as(f64, 13), stringToNumber(S("013"), 4));
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S("0x13"), 4));
    try std.testing.expectEqual(@as(f64, 11), stringToNumber(S("11ABC"), 4));
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S("ABC"), 4));
    // AVM1 has no `Infinity` literal (ruffle parse_float_impl).
    try std.testing.expect(std.math.isNan(stringToNumber(S("Infinity"), 6)));
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S("Infinity"), 4));
    // Empty is NaN at SWF5+, 0 below (no digits consumed).
    try std.testing.expect(std.math.isNan(stringToNumber(S(""), 6)));
    try std.testing.expectEqual(@as(f64, 0), stringToNumber(S(""), 4));

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
