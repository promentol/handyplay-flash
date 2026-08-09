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
        // SWF4 has no NaN to speak of: an object that survived `valueOf`
        // reads as 0, which is what makes `{} / {}` the "#ERROR#" of a
        // divide by zero rather than a NaN (ruffle value.rs:165).
        .object => if (swf_version < 5) 0 else std.math.nan(f64),
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

/// ruffle `parse_int_internal` — the global `parseInt`, bugs and all.
/// An explicit radix outside 2..36 is NaN outright; a `0x` prefix is
/// stripped WHATEVER the radix (so `parseInt('0x100', 10)` is 100), but
/// only when it comes before the sign and any spaces; and a signed hex
/// prefix is NaN unless the radix is high enough for "0x" to be digits.
/// A leading zero with only octal digits after it auto-detects base 8.
pub fn parseIntImpl(str: strings.AvmString, radix_in: ?i32) f64 {
    const nan = std.math.nan(f64);
    var radix: u32 = 10;
    var explicit = false;
    if (radix_in) |r| {
        if (r < 2 or r > 36) return nan;
        radix = @intCast(r);
        explicit = true;
    }

    var s = str;
    var ignore_sign = false;
    const has_sign = s.len > 0 and (s[0] == '+' or s[0] == '-');
    const off: usize = if (has_sign) 1 else 0;
    const zero = s.len > off and s[off] == '0';
    const hex = zero and s.len > off + 1 and (s[off + 1] == 'x' or s[off + 1] == 'X');
    if (hex) {
        if (has_sign) {
            if (!explicit or radix <= 33) return nan;
            ignore_sign = true;
        } else {
            if (!explicit) radix = 16;
            s = s[2..];
        }
    } else if (zero and !explicit and allOctal(s[1..])) {
        radix = 8;
    }

    while (s.len > 0 and (s[0] == '\t' or s[0] == '\n' or s[0] == '\r' or s[0] == ' ')) s = s[1..];

    var sign: f64 = 1;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        if (!ignore_sign and s[0] == '-') sign = -1;
        s = s[1..];
    }

    var empty = true;
    var result: f64 = 0;
    for (s) |c| {
        const d = digitValue(c) orelse break;
        if (d >= radix) break;
        result = result * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
        empty = false;
    }
    if (empty) return nan;
    return std.math.copysign(result, sign);
}

fn allOctal(s: strings.AvmString) bool {
    for (s) |c| {
        if (c < '0' or c > '7') return false;
    }
    return true;
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
pub fn parseFloatImpl(str: strings.AvmString, strict: bool) f64 {
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

/// Flash's OTHER number→i32 rule, and not ES3's: anything outside the
/// range — including both infinities and NaN — becomes `i32::MIN`
/// rather than wrapping or saturating (ruffle avm1/clamp.rs
/// `clamp_to_i32`). `toInt32` above is ToInt32 and wraps; the two are
/// used in different places and the corpus tells them apart
/// (set_property_values sets `_soundbuftime` to +Infinity and reads
/// -2147483648 back).
pub fn clampToI32(n: f64) i32 {
    if (n >= -2147483648.0 and n <= 2147483647.0) return @intFromFloat(@trunc(n));
    return -2147483648;
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
/// Flash's own float→string, bugs included.
///
/// This is NOT ES3 `ToString(Number)`. Flash Player shifts the value into
/// [0, 10), pulls 15 digits out by repeated multiplication, then rounds —
/// and the rounding mishandles a 9.999→10 carry. The visible consequences
/// are part of the format: at most 15 significant digits (so 0.1 + 0.2
/// prints "0.30000000000000004" nowhere and "0.3" everywhere), exponent
/// notation from 1e15 rather than 1e21, and `-9999999999999996` printing as
/// the digit-less "-e+16".
///
/// Port of ruffle core/src/avm1/value.rs `f64_to_string`.
pub fn numberToStringBuf(buf: []u8, n_in: f64) []const u8 {
    if (std.math.isNan(n_in)) return copyInto(buf, "NaN");
    if (n_in == 0) return copyInto(buf, "0");
    if (std.math.isInf(n_in)) {
        return copyInto(buf, if (n_in < 0) "-Infinity" else "Infinity");
    }
    // Integers in i32 range print directly — the common case, and it avoids
    // the digit machinery rounding e.g. 2147483647 to 15 digits.
    if (n_in >= -2147483648.0 and n_in <= 2147483647.0 and @rem(n_in, 1) == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(n_in))}) catch
            copyInto(buf, "0");
    }

    var work: [64]u8 = undefined;
    var len: usize = 0;
    var n = n_in;
    const is_negative = n < 0;
    if (is_negative) {
        n = -n;
        work[len] = '-';
        len += 1;
    }

    // Base-2 exponent straight out of the bit pattern.
    const MANTISSA_BITS = 52;
    const EXPONENT_MASK: u64 = 0x7ff;
    const EXPONENT_BIAS: i32 = 1023;
    var exp_base2: i32 = @as(i32, @intCast((@as(u64, @bitCast(n)) >> MANTISSA_BITS) & EXPONENT_MASK)) - EXPONENT_BIAS;
    if (exp_base2 == -EXPONENT_BIAS) {
        // Subnormal: scale into the normal range and re-read the exponent.
        const NORMAL_SCALE: f64 = 1.801439850948198e16; // 2^54
        const scaled = n * NORMAL_SCALE;
        exp_base2 = @as(i32, @intCast((@as(u64, @bitCast(scaled)) >> MANTISSA_BITS) & EXPONENT_MASK)) - EXPONENT_BIAS - 54;
    }

    // Flash's less-precise log10(2) — using the exact one shifts edge cases.
    const LOG10_2: f64 = 0.301029995663981;
    var exp: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(exp_base2)) * LOG10_2));

    var mantissa = decimalShift(n, -exp);
    // The estimate can be off by one in either direction.
    if (truncI32(mantissa) == 0) {
        exp -= 1;
        mantissa = decimalShift(n, -exp);
    }
    if (truncI32(mantissa) >= 10) {
        exp += 1;
        mantissa = decimalShift(n, -exp);
    }

    const Digits = struct {
        m: f64,
        fn next(self: *@This()) u8 {
            const d = truncI32(self.m);
            self.m -= @floatFromInt(d);
            self.m *= 10.0;
            return '0' + @as(u8, @intCast(@max(@min(d, 9), 0)));
        }
    };
    var digits: Digits = .{ .m = mantissa };

    const MAX_DECIMAL_PLACES: i32 = 15;
    if (exp >= 15) {
        // 1.2345e+15. No extra digit is pushed for a 9.9999→10 carry, which
        // is precisely the "-e+16" bug.
        work[len] = digits.next();
        len += 1;
        work[len] = '.';
        len += 1;
        var i: i32 = 0;
        while (i < MAX_DECIMAL_PLACES - 1) : (i += 1) {
            work[len] = digits.next();
            len += 1;
        }
    } else if (exp >= 0) {
        // 12345.678901234
        work[len] = '0';
        len += 1;
        var i: i32 = 0;
        while (i <= exp) : (i += 1) {
            work[len] = digits.next();
            len += 1;
        }
        work[len] = '.';
        len += 1;
        i = 0;
        while (i < MAX_DECIMAL_PLACES - exp - 1) : (i += 1) {
            work[len] = digits.next();
            len += 1;
        }
        exp = 0;
    } else if (exp >= -5) {
        // 0.0012345678901234
        work[len] = '0';
        work[len + 1] = '0';
        work[len + 2] = '.';
        len += 3;
        var z: i32 = 0;
        while (z < -exp - 1) : (z += 1) {
            work[len] = '0';
            len += 1;
        }
        var i: i32 = 0;
        while (i < MAX_DECIMAL_PLACES) : (i += 1) {
            work[len] = digits.next();
            len += 1;
        }
        exp = 0;
    } else {
        // 1.345e-15
        work[len] = '0';
        len += 1;
        const first = digits.next();
        if (first != '0') {
            work[len] = first;
            len += 1;
        }
        work[len] = '.';
        len += 1;
        var i: i32 = 0;
        while (i < MAX_DECIMAL_PLACES - 1) : (i += 1) {
            work[len] = digits.next();
            len += 1;
        }
    }

    // Peek one more digit and round away from zero on a tie.
    if (digits.next() >= '5') {
        var i = len;
        while (i > 0) {
            i -= 1;
            if (work[i] == '9') {
                work[i] = '0';
            } else if (work[i] >= '0') {
                work[i] += 1;
                break;
            }
        }
    }

    while (len > 0 and work[len - 1] == '0') len -= 1;
    if (len > 0 and work[len - 1] == '.') len -= 1;

    var start: usize = 0;
    if (exp != 0) {
        // Exponent form. The fix-ups below are Flash's own, and they do not
        // cover the negative cases — hence "-e+16".
        var pos: usize = 0;
        while (pos < len and work[pos] == '0') pos += 1;
        if (pos != 0) {
            std.mem.copyForwards(u8, work[0 .. len - pos], work[pos..len]);
            len -= pos;
        }
        if (len == 0) {
            // 9.99999 rounded to 0.00000 with no room for the carry.
            work[0] = '1';
            len = 1;
            exp += 1;
        } else {
            // 100e15 becomes 1e17.
            var last: usize = 0;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                if (work[i] != '0') {
                    last = i;
                    break;
                }
            }
            if (last == 0) {
                exp += @as(i32, @intCast(len)) - 1;
                len = 1;
            }
        }
        const tail = std.fmt.bufPrint(work[len..], "e{c}{d}", .{
            @as(u8, if (exp < 0) '-' else '+'),
            @abs(exp),
        }) catch "";
        len += tail.len;
    }

    // Strip a leading zero the digit machinery left behind.
    const i: usize = if (is_negative) 1 else 0;
    if (len > i and work[i] == '0' and !(len > i + 1 and work[i + 1] == '.')) {
        if (i > 0) work[i] = work[i - 1];
        start = 1;
    }
    return copyInto(buf, work[start..len]);
}


fn truncI32(n: f64) i32 {
    if (std.math.isNan(n)) return 0;
    if (n >= 2147483647.0) return std.math.maxInt(i32);
    if (n <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(@trunc(n));
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

test "Flash's ToString(Number), quirks included" {
    // The vectors below are ruffle's own f64_to_string test cases, which
    // were recorded against Flash Player — NOT ES3. Several are wrong by
    // ECMA's lights and right by Flash's.
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
    try expectNum("1.4", 1.4);
    try expectNum("-990.123", -990.123);
    try expectNum("3.14159265358979", std.math.pi); // 15 significant digits
    try expectNum("2147483647", 2147483647.0);
    try expectNum("-2147483648", -2147483648.0);

    // 15 digits is the whole budget, so double-rounding artefacts vanish.
    var x: f64 = 0.1;
    x += 0.2;
    try expectNum("0.3", x);
    try expectNum("0.2", 0.19999999999999996);
    try expectNum("100000.123456789", 100000.12345678912);
    try expectNum("0.800000000000001", 0.8000000000000005);
    try expectNum("0.83", 0.8300000000000005);

    // Exponent notation starts at 1e15, not ES3's 1e21.
    try expectNum("999990000000000", 9.9999e14);
    try expectNum("1e+15", 1e15);
    try expectNum("-1e+15", -1e15);
    try expectNum("0.00001", 1e-5);
    try expectNum("9.99e-6", 0.999e-5);

    // Flash's rounding carry is broken, and these are the visible results.
    try expectNum("10", 9.999999999999999);
    try expectNum("1e+16", 9999999999999996.0);
    try expectNum("-e+16", -9999999999999996.0); // no digit at all — Flash's bug
    try expectNum("1e-5", 0.000009999999999999996);
    try expectNum("-10e-6", -0.000009999999999999996);
    try expectNum("0.0001", 0.00009999999999999996);

    // Subnormals and the extremes.
    try expectNum("9.99988867182684e-321", 1e-320);
    try expectNum("1.79769313486231e+308", std.math.floatMax(f64));
    try expectNum("-1.79769313486231e+308", -std.math.floatMax(f64));
    try expectNum("2.2250738585072e-308", std.math.floatMin(f64));
    try expectNum("4.94065645841247e-324", 5e-324);
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
