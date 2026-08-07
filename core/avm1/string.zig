//! AVM1 runtime strings — UCS-2/UTF-16 code units (ADR D1). Flash string
//! semantics (`length`, `charCodeAt`, `substring`) are code-unit based, so
//! the wide representation is authoritative; UTF-8 exists only at the
//! boundaries (SWF bytes in, trace/output out).

const std = @import("std");

pub const AvmString = []const u16;

/// SWF bytes → UTF-16. SWF6+ is UTF-8 (invalid sequences fall back to
/// Latin-1 per Flash tolerance); SWF5 and below is Latin-1 passthrough
/// (Shift-JIS best-effort is a recorded follow-up, R6).
pub fn fromSwf(a: std.mem.Allocator, bytes: []const u8, swf_version: u8) ![]const u16 {
    if (swf_version >= 6) {
        return std.unicode.utf8ToUtf16LeAlloc(a, bytes) catch latin1(a, bytes);
    }
    return latin1(a, bytes);
}

fn latin1(a: std.mem.Allocator, bytes: []const u8) ![]const u16 {
    const out = try a.alloc(u16, bytes.len);
    for (bytes, out) |b, *w| w.* = b;
    return out;
}

/// ASCII literal → UTF-16 (for built-in names; comptime-friendly).
pub fn ascii(comptime s: []const u8) []const u16 {
    const arr = comptime blk: {
        var out: [s.len]u16 = undefined;
        for (s, 0..) |ch, i| out[i] = ch;
        break :blk out;
    };
    return &arr;
}

pub fn toUtf8(a: std.mem.Allocator, s: AvmString) ![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, s);
}

pub fn eql(x: AvmString, y: AvmString) bool {
    return std.mem.eql(u16, x, y);
}

pub fn eqlIgnoreCase(x: AvmString, y: AvmString) bool {
    if (x.len != y.len) return false;
    for (x, y) |cx, cy| {
        if (foldCase(cx) != foldCase(cy)) return false;
    }
    return true;
}

/// ASCII-range case folding (Flash's case-insensitivity is ASCII-only).
pub inline fn foldCase(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn concat(a: std.mem.Allocator, x: AvmString, y: AvmString) ![]const u16 {
    const out = try a.alloc(u16, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}

/// Code-unit-ordered comparison (ES3 §11.8.5 for strings).
pub fn order(x: AvmString, y: AvmString) std.math.Order {
    const n = @min(x.len, y.len);
    for (x[0..n], y[0..n]) |cx, cy| {
        if (cx != cy) return if (cx < cy) .lt else .gt;
    }
    return std.math.order(x.len, y.len);
}

// --- Tests -----------------------------------------------------------------

test "swf decode: utf8, latin1 fallback, pre-v6 latin1" {
    const ta = std.testing.allocator;
    const s1 = try fromSwf(ta, "héllo", 6); // UTF-8 é
    defer ta.free(s1);
    try std.testing.expectEqual(@as(usize, 5), s1.len);
    try std.testing.expectEqual(@as(u16, 0xE9), s1[1]);
    const s2 = try fromSwf(ta, &.{ 'h', 0xE9 }, 5); // Latin-1 é
    defer ta.free(s2);
    try std.testing.expectEqual(@as(u16, 0xE9), s2[1]);
    const s3 = try fromSwf(ta, &.{ 'x', 0xFF, 'y' }, 6); // invalid UTF-8 → Latin-1
    defer ta.free(s3);
    try std.testing.expectEqual(@as(u16, 0xFF), s3[1]);
}

test "case folding, ordering, concat" {
    const ta = std.testing.allocator;
    try std.testing.expect(eqlIgnoreCase(ascii("Hello"), ascii("hELLO")));
    try std.testing.expect(!eqlIgnoreCase(ascii("a"), ascii("b")));
    try std.testing.expectEqual(std.math.Order.lt, order(ascii("Zoo"), ascii("apple"))); // 'Z' < 'a'
    const c = try concat(ta, ascii("ab"), ascii("cd"));
    defer ta.free(c);
    try std.testing.expect(eql(c, ascii("abcd")));
}
