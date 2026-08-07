//! The `Date` class — ECMA-262 3rd edition date arithmetic, in Flash's
//! dialect.
//!
//! Every method is one entry in a single dispatcher keyed by ruffle's method
//! INDEX, and the indices are load-bearing: the local and UTC variants are
//! the same code 128 apart, and the multi-argument setters find their extra
//! arguments by subtracting the entry index from the field index
//! (`setHours(h, m, s)` and `setMinutes(m, s)` share one implementation).
//! Reproducing that numbering is what keeps the argument-defaulting rules —
//! several of which are outright quirks — in one place.
//!
//! The clock is deterministic by default: `Vm.epoch_ms` and
//! `Vm.tz_offset_min` start at ruffle's test mock, 2001-02-03 04:05:06 local
//! in a +05:45 zone that has never observed DST (core/src/locale.rs picks
//! Nepal for exactly that reason). Frontends call `Player.setClock` with the
//! real wall clock; the conformance runner leaves the mock in place.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/date.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;

const MS_PER_SECOND: f64 = 1000;
const MS_PER_MINUTE: f64 = 60 * MS_PER_SECOND;
const MS_PER_HOUR: f64 = 60 * MS_PER_MINUTE;
const MS_PER_DAY: f64 = 24 * MS_PER_HOUR;

/// Cumulative days before each month, common year then leap year.
const MONTH_OFFSETS = [2][13]u16{
    .{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
    .{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
};

const DAYS_OF_WEEK = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTHS = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

// --- method indices (ruffle date.rs `mod method`) -----------------------------

const GET_FULL_YEAR: u16 = 0;
const GET_YEAR: u16 = 1;
const GET_MONTH: u16 = 2;
const GET_DATE: u16 = 3;
const GET_DAY: u16 = 4;
const GET_HOURS: u16 = 5;
const GET_MINUTES: u16 = 6;
const GET_SECONDS: u16 = 7;
const GET_MILLISECONDS: u16 = 8;
const SET_FULL_YEAR: u16 = 9;
const SET_MONTH: u16 = 10;
const SET_DATE: u16 = 11;
const SET_HOURS: u16 = 12;
const SET_MINUTES: u16 = 13;
const SET_SECONDS: u16 = 14;
const SET_MILLISECONDS: u16 = 15;
const GET_TIME: u16 = 16;
const SET_TIME: u16 = 17;
const GET_TIMEZONE_OFFSET: u16 = 18;
const TO_STRING: u16 = 19;
const SET_YEAR: u16 = 20;
const UTC_BIAS: u16 = 128;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.date_proto = proto;

    const pairs = .{
        .{ "getFullYear", GET_FULL_YEAR },     .{ "getYear", GET_YEAR },
        .{ "getMonth", GET_MONTH },            .{ "getDate", GET_DATE },
        .{ "getDay", GET_DAY },                .{ "getHours", GET_HOURS },
        .{ "getMinutes", GET_MINUTES },        .{ "getSeconds", GET_SECONDS },
        .{ "getMilliseconds", GET_MILLISECONDS }, .{ "setFullYear", SET_FULL_YEAR },
        .{ "setMonth", SET_MONTH },            .{ "setDate", SET_DATE },
        .{ "setHours", SET_HOURS },            .{ "setMinutes", SET_MINUTES },
        .{ "setSeconds", SET_SECONDS },        .{ "setMilliseconds", SET_MILLISECONDS },
        .{ "getTime", GET_TIME },              .{ "setTime", SET_TIME },
        .{ "getTimezoneOffset", GET_TIMEZONE_OFFSET }, .{ "toString", TO_STRING },
        .{ "setYear", SET_YEAR },              .{ "valueOf", GET_TIME },
    };
    inline for (pairs) |p| {
        try decl.method(vm, proto, p[0], entry(p[1]), decl.hidden);
    }
    // The UTC half is the same code with the local/UTC conversion skipped.
    const utc_pairs = .{
        .{ "getUTCFullYear", GET_FULL_YEAR },   .{ "getUTCYear", GET_YEAR },
        .{ "getUTCMonth", GET_MONTH },          .{ "getUTCDate", GET_DATE },
        .{ "getUTCDay", GET_DAY },              .{ "getUTCHours", GET_HOURS },
        .{ "getUTCMinutes", GET_MINUTES },      .{ "getUTCSeconds", GET_SECONDS },
        .{ "getUTCMilliseconds", GET_MILLISECONDS }, .{ "setUTCFullYear", SET_FULL_YEAR },
        .{ "setUTCMonth", SET_MONTH },          .{ "setUTCDate", SET_DATE },
        .{ "setUTCHours", SET_HOURS },          .{ "setUTCMinutes", SET_MINUTES },
        .{ "setUTCSeconds", SET_SECONDS },      .{ "setUTCMilliseconds", SET_MILLISECONDS },
    };
    inline for (utc_pairs) |p| {
        try decl.method(vm, proto, p[0], entry(p[1] + UTC_BIAS), decl.hidden);
    }

    const class = try decl.class(vm, "Date", ctorDate, proto, .{ .dont_enum = true });
    try decl.method(vm, class, "UTC", dateUtc, decl.frozen);
}

/// One native entry point per method index. `comptime index` is the only
/// thing that varies, so the whole class is one function.
fn entry(comptime index: u16) object_mod.NativeFn {
    return struct {
        fn f(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            return dispatch(vmOf(p), this, args, index);
        }
    }.f;
}

// --- the date value ------------------------------------------------------------

/// Milliseconds since the Unix epoch, UTC. NaN is "Invalid Date".
const Date = f64;

fn timeOf(vm: *Vm, this: Value) ?*f64 {
    if (this != .object) return null;
    const o = vm.objects.get(this.object);
    if (o.native != .date) return null;
    return &o.native.date;
}

fn isLeapYear(year: i32) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

/// `getYear` is `getFullYear - 1900`, and the subtraction WRAPS for the
/// out-of-range dates that land on i32::MIN.
fn getYearField(t: Date) i32 {
    return yearOf(t) -% 1900;
}

/// ruffle's `clamp_to_i32`: NaN and ANYTHING out of range — including
/// +infinity — become i32::MIN, not the nearer bound. That asymmetry is
/// visible: an infinite date reports `Month = 0` and `Date = -2147483647`,
/// which are i32::MIN threaded through the month/day arithmetic.
fn toI32(n: f64) i32 {
    if (n >= -2147483648.0 and n <= 2147483647.0) return @intFromFloat(@trunc(n));
    return std.math.minInt(i32);
}

fn remEuclidI32(lhs: f64, rhs: i32) i32 {
    const r = toI32(@mod(lhs, @as(f64, @floatFromInt(rhs))));
    return if (r < 0) r +% rhs else r;
}

fn day(t: Date) f64 {
    return @floor(t / MS_PER_DAY);
}

/// SWF8 switched from a truncating remainder to a Euclidean one, so a
/// pre-epoch date reports a different time-within-day on old players.
fn timeWithinDay(t: Date, swf_version: u8) f64 {
    if (swf_version > 7) return @mod(t, MS_PER_DAY);
    return @rem(t, MS_PER_DAY);
}

fn dayFromYear(year: f64) f64 {
    return 365.0 * (year - 1970.0) + @floor((year - 1969.0) / 4.0) -
        @floor((year - 1901.0) / 100.0) + @floor((year - 1601.0) / 400.0);
}

fn fromYear(year: i32) Date {
    return MS_PER_DAY * dayFromYear(@floatFromInt(year));
}

/// Binary search for the largest year whose January 1st is at or before `t`
/// — the same shape as ruffle's, because a closed form drifts at the
/// century boundaries.
fn yearOf(t: Date) i32 {
    const d = day(t);
    // Wrapping adds: an out-of-range date lands on i32::MIN and Flash lets
    // the +1970 wrap rather than saturating again.
    var low = toI32(@floor(d / (if (t < 0) @as(f64, 365.0) else 366.0))) +% 1970;
    var high = toI32(@ceil(d / (if (t < 0) @as(f64, 366.0) else 365.0))) +% 1970;
    while (low < high) {
        const pivot = toI32((@as(f64, @floatFromInt(low)) + @as(f64, @floatFromInt(high))) / 2.0);
        if (fromYear(pivot) <= t) {
            if (fromYear(pivot + 1) > t) return pivot;
            low = pivot + 1;
        } else {
            high = pivot - 1;
        }
    }
    return low;
}

fn dayWithinYear(t: Date) i32 {
    return toI32(day(t) - dayFromYear(@floatFromInt(yearOf(t))));
}

fn monthOf(t: Date) i32 {
    const d = dayWithinYear(t);
    const leap: usize = if (isLeapYear(yearOf(t))) 1 else 0;
    var i: i32 = 0;
    while (i < 11) : (i += 1) {
        if (d < MONTH_OFFSETS[leap][@intCast(i + 1)]) return i;
    }
    return 11;
}

fn dateOf(t: Date) i32 {
    const leap: usize = if (isLeapYear(yearOf(t))) 1 else 0;
    const offset = MONTH_OFFSETS[leap][@intCast(monthOf(t))];
    return dayWithinYear(t) -% @as(i32, @intCast(offset)) +% 1;
}

fn weekDay(t: Date) i32 {
    return remEuclidI32(day(t) + 4.0, 7);
}

/// The +0.5 is ruffle's, and it is not rounding slop: it makes the hour
/// boundary fall the way Flash's does for negative times.
fn hoursOf(t: Date) i32 {
    return remEuclidI32(@floor((t + 0.5) / MS_PER_HOUR), 24);
}

fn minutesOf(t: Date) i32 {
    return remEuclidI32(@floor(t / MS_PER_MINUTE), 60);
}

fn secondsOf(t: Date) i32 {
    return remEuclidI32(@floor(t / MS_PER_SECOND), 60);
}

fn millisecondsOf(t: Date) i32 {
    return remEuclidI32(t, 1000);
}

fn makeTime(h: f64, m: f64, s: f64, ms: f64) f64 {
    return @floor(h) * MS_PER_HOUR + @floor(m) * MS_PER_MINUTE +
        @floor(s) * MS_PER_SECOND + @floor(ms);
}

fn dayFromMonth(year_in: f64, month_in: f64) f64 {
    const year = toI32(year_in);
    const month = toI32(@floor(month_in));
    if (month < 0 or month >= 12) return std.math.nan(f64);
    const leap: usize = if (isLeapYear(year)) 1 else 0;
    return dayFromYear(@floatFromInt(year)) + @as(f64, @floatFromInt(MONTH_OFFSETS[leap][@intCast(month)]));
}

fn makeDay(year_in: f64, month_in: f64, date_in: f64) f64 {
    var year = @floor(year_in);
    const month = @floor(month_in);
    const d = @floor(date_in);
    year += @floor(month / 12.0);
    return dayFromMonth(year, @mod(month, 12.0)) + d - 1.0;
}

fn makeDate(d: f64, time: f64) Date {
    return d * MS_PER_DAY + time;
}

/// ECMA-262 TimeClip — a date more than 100 million days from the epoch is
/// simply invalid.
fn clip(t: Date) Date {
    const LIMIT: f64 = 100_000_000.0 * MS_PER_DAY;
    if (!std.math.isFinite(t) or @abs(t) > LIMIT) return std.math.nan(f64);
    return @floor(t);
}

/// A year below 100 is taken as 19xx — the two-digit-year rule, applied by
/// the multi-argument constructor and by `setYear`.
fn expandShortYear(year: f64) f64 {
    return if (year < 100.0) year + 1900.0 else year;
}

fn tzMs(vm: *Vm) f64 {
    return @as(f64, @floatFromInt(vm.tz_offset_min)) * MS_PER_MINUTE;
}

fn toLocal(vm: *Vm, t: Date) Date {
    return t + tzMs(vm);
}

fn toUtc(vm: *Vm, t: Date) Date {
    return t - tzMs(vm);
}

fn nowMs(vm: *Vm) Date {
    return vm.epoch_ms + vm.now_ms;
}

// --- formatting ------------------------------------------------------------------

/// `Sat Feb 3 04:05:06 GMT+0545 2001`. The offset sign is INVERTED relative
/// to `getTimezoneOffset`, which reports UTC-minus-local.
fn formatDate(vm: *Vm, local: Date) !strings.AvmString {
    if (!std.math.isFinite(local)) return S("Invalid Date");
    const offset = -toI32(timezoneOffset(vm));
    const abs: u32 = @intCast(@abs(offset));
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT{c}{d:0>2}{d:0>2} {d}", .{
        DAYS_OF_WEEK[@intCast(weekDay(local))],
        MONTHS[@intCast(monthOf(local))],
        dateOf(local),
        // Cast away the sign: Zig's `{d:0>2}` prints a `+` for a signed
        // value, which is not what the format wants.
        @as(u32, @intCast(@max(hoursOf(local), 0))),
        @as(u32, @intCast(@max(minutesOf(local), 0))),
        @as(u32, @intCast(@max(secondsOf(local), 0))),
        @as(u8, if (offset < 0) '-' else '+'),
        abs / 60,
        abs % 60,
        yearOf(local),
    });
    const wide = try vm.arena().alloc(u16, s.len);
    for (s, 0..) |c, i| wide[i] = c;
    return wide;
}

/// UTC minus local, in minutes — so a zone AHEAD of UTC reports a NEGATIVE
/// offset (+05:45 is -345).
fn timezoneOffset(vm: *Vm) f64 {
    return -@as(f64, @floatFromInt(vm.tz_offset_min));
}

// --- constructor ------------------------------------------------------------------

/// Arguments stop at the first `undefined`: `new Date(2001, undefined, 5)`
/// is a one-argument call, not a three-argument one.
fn coerceArgs(vm: *Vm, args: []const Value, out: *[7]f64) !usize {
    var n: usize = 0;
    for (args) |a| {
        if (n == 7 or a == .undefined_value) break;
        out[n] = try vm.toNumber(a);
        n += 1;
    }
    return n;
}

fn ctorDate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    // Called WITHOUT `new`, `Date()` is just the current local time as a
    // string (ECMA-262 15.9.2).
    if (vm.in_construct == 0 or this != .object) {
        return .{ .string = try formatDate(vm, toLocal(vm, nowMs(vm))) };
    }
    var raw: [7]f64 = @splat(0);
    const n = try coerceArgs(vm, args, &raw);
    const t: Date = switch (n) {
        0 => if (vm.swf_version > 7) @round(nowMs(vm)) else nowMs(vm),
        1 => raw[0],
        else => toUtc(vm, makeDate(
            makeDay(expandShortYear(raw[0]), raw[1], if (n > 2) raw[2] else 1),
            makeTime(
                if (n > 3) raw[3] else 0,
                if (n > 4) raw[4] else 0,
                if (n > 5) raw[5] else 0,
                if (n > 6) raw[6] else 0,
            ),
        )),
    };
    vm.objects.get(this.object).native = .{ .date = t };
    return this;
}

/// `Date.UTC(...)` builds a timestamp without applying the local offset.
/// Fewer than two arguments yields undefined rather than NaN.
fn dateUtc(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    var raw: [7]f64 = @splat(0);
    const n = try coerceArgs(vm, args, &raw);
    if (n < 2) return .undefined_value;
    return .{ .number = makeDate(
        makeDay(expandShortYear(raw[0]), raw[1], if (n > 2) raw[2] else 1),
        makeTime(
            if (n > 3) raw[3] else 0,
            if (n > 4) raw[4] else 0,
            if (n > 5) raw[5] else 0,
            if (n > 6) raw[6] else 0,
        ),
    ) };
}

// --- the dispatcher ---------------------------------------------------------------

fn dispatch(vm: *Vm, this: Value, args: []const Value, index_in: u16) anyerror!Value {
    var raw: [7]f64 = @splat(0);
    const argc = try coerceArgs(vm, args, &raw);

    const slot = timeOf(vm, this) orelse return .undefined_value;

    switch (index_in) {
        GET_TIME => return .{ .number = slot.* },
        SET_TIME => {
            slot.* = clip(if (argc > 0) raw[0] else std.math.nan(f64));
            return .{ .number = slot.* };
        },
        // Computed FROM the date so an invalid one reports NaN rather
        // than the zone's constant offset.
        GET_TIMEZONE_OFFSET => return .{ .number = (slot.* - toLocal(vm, slot.*)) / MS_PER_MINUTE },
        else => {},
    }

    const is_utc = index_in >= UTC_BIAS;
    var index = if (is_utc) index_in - UTC_BIAS else index_in;

    // Every getter on an invalid date is NaN.
    if (index <= GET_MILLISECONDS and std.math.isNan(slot.*)) {
        return .{ .number = std.math.nan(f64) };
    }

    // `setYear` IS `setFullYear` with the two-digit-year rule bolted on.
    const is_set_year = index == SET_YEAR;
    if (is_set_year) index = SET_FULL_YEAR;

    const t: Date = if (is_utc) slot.* else toLocal(vm, slot.*);

    // A setter's extra arguments are positional relative to the entry
    // point: `setHours(h, m, s)` fills SET_HOURS, SET_MINUTES, SET_SECONDS.
    // Null means "not supplied — keep the current value"; NaN means
    // "supplied as the entry's own field but missing", which invalidates.
    const argFor = struct {
        fn f(field: u16, base: u16, values: *const [7]f64, count: usize) ?f64 {
            if (field < base) return null;
            const i = field - base;
            if (i < count) return values[i];
            return if (field == base) std.math.nan(f64) else null;
        }
    }.f;

    const store = struct {
        fn f(m: *Vm, dst: *f64, utc: bool, d: f64, time: f64) f64 {
            var out = makeDate(d, time);
            if (!utc) out = toUtc(m, out);
            out = clip(out);
            dst.* = out;
            return out;
        }
    }.f;

    return switch (index) {
        GET_FULL_YEAR => .{ .number = @floatFromInt(yearOf(t)) },
        GET_YEAR => .{ .number = @floatFromInt(getYearField(t)) },
        GET_MONTH => .{ .number = @floatFromInt(monthOf(t)) },
        GET_DATE => .{ .number = @floatFromInt(dateOf(t)) },
        GET_DAY => .{ .number = @floatFromInt(weekDay(t)) },
        GET_HOURS => .{ .number = @floatFromInt(hoursOf(t)) },
        GET_MINUTES => .{ .number = @floatFromInt(minutesOf(t)) },
        GET_SECONDS => .{ .number = @floatFromInt(secondsOf(t)) },
        GET_MILLISECONDS => .{ .number = @floatFromInt(millisecondsOf(t)) },
        SET_FULL_YEAR, SET_MONTH, SET_DATE => blk: {
            var year: f64 = @floatFromInt(yearOf(t));
            if (argFor(SET_FULL_YEAR, index, &raw, argc)) |y| {
                year = if (is_set_year and y >= 0.0 and y <= 99.0) y + 1900.0 else y;
            }
            var month: f64 = @floatFromInt(monthOf(t));
            if (argFor(SET_MONTH, index, &raw, argc)) |m| month = m;
            // `setMonth()` with no argument means month 0, not NaN.
            if (index == SET_MONTH and std.math.isNan(month)) month = 0;
            var d: f64 = @floatFromInt(dateOf(t));
            if (argFor(SET_DATE, index, &raw, argc)) |v| d = v;
            break :blk .{ .number = store(
                vm,
                slot,
                is_utc,
                makeDay(year, month, d),
                timeWithinDay(t, vm.swf_version),
            ) };
        },
        SET_HOURS, SET_MINUTES, SET_SECONDS, SET_MILLISECONDS => blk: {
            var h: f64 = @floatFromInt(hoursOf(t));
            if (argFor(SET_HOURS, index, &raw, argc)) |v| h = v;
            var m: f64 = @floatFromInt(minutesOf(t));
            if (argFor(SET_MINUTES, index, &raw, argc)) |v| m = v;
            var s: f64 = @floatFromInt(secondsOf(t));
            if (argFor(SET_SECONDS, index, &raw, argc)) |v| s = v;
            var ms: f64 = @floatFromInt(millisecondsOf(t));
            if (argFor(SET_MILLISECONDS, index, &raw, argc)) |v| ms = v;
            // `setMinutes` truncates its arguments to i32 first; the other
            // three do not. Undocumented, and the corpus checks it.
            if (index == SET_MINUTES) {
                m = @floatFromInt(toI32(m));
                s = @floatFromInt(toI32(s));
                ms = @floatFromInt(toI32(ms));
            }
            break :blk .{ .number = store(vm, slot, is_utc, day(t), makeTime(h, m, s, ms)) };
        },
        TO_STRING => .{ .string = try formatDate(vm, t) },
        else => .undefined_value,
    };
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "the mock clock reads back as Flash prints it" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();
    // Defaults are the deterministic mock: 2001-02-03 04:05:06 at +05:45.
    const utc_now = nowMs(vm);
    const local = toLocal(vm, utc_now);
    try testing.expectEqual(@as(i32, 2001), yearOf(local));
    try testing.expectEqual(@as(i32, 1), monthOf(local)); // February
    try testing.expectEqual(@as(i32, 3), dateOf(local));
    try testing.expectEqual(@as(i32, 6), weekDay(local)); // Saturday
    try testing.expectEqual(@as(i32, 4), hoursOf(local));
    try testing.expectEqual(@as(i32, 5), minutesOf(local));
    try testing.expectEqual(@as(i32, 6), secondsOf(local));
    try testing.expectEqual(@as(f64, -345), timezoneOffset(vm));

    const s = try formatDate(vm, local);
    var u8buf: [80]u8 = undefined;
    for (s, 0..) |c, i| u8buf[i] = @intCast(c);
    try testing.expectEqualStrings("Sat Feb 3 04:05:06 GMT+0545 2001", u8buf[0..s.len]);
}

test "epoch and leap-year edges" {
    try testing.expectEqual(@as(i32, 1970), yearOf(0));
    try testing.expectEqual(@as(i32, 4), weekDay(0)); // 1970-01-01 was a Thursday
    try testing.expect(isLeapYear(2000) and !isLeapYear(1900) and isLeapYear(2004));
    // 2000-02-29 exists; the day count must land on it.
    const feb29 = makeDate(makeDay(2000, 1, 29), 0);
    try testing.expectEqual(@as(i32, 1), monthOf(feb29));
    try testing.expectEqual(@as(i32, 29), dateOf(feb29));
    // Month 12 rolls into the next year rather than failing.
    try testing.expectEqual(@as(i32, 2001), yearOf(makeDate(makeDay(2000, 12, 1), 0)));
}
