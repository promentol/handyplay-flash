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
        return decodeUtf8(a, bytes) catch latin1(a, bytes);
    }
    return latin1(a, bytes);
}

/// UTF-8, but ACCEPTING the surrogate encodings a strict decoder rejects.
/// Flash's compilers emit CESU-8 — a character above the BMP written as
/// its two surrogate halves, three bytes each — and a strict pass would
/// throw the whole string back to Latin-1, turning four units into six
/// and comparing wrong (corpus string_relational_compare).
fn decodeUtf8(a: std.mem.Allocator, bytes: []const u8) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidUtf8;
        if (i + len > bytes.len) return error.InvalidUtf8;
        const seq = bytes[i .. i + len];
        i += len;
        // A surrogate half: ED A0..BF 80..BF, which `utf8Decode` refuses.
        if (len == 3 and seq[0] == 0xED and seq[1] >= 0xA0 and seq[1] <= 0xBF and
            seq[2] >= 0x80 and seq[2] <= 0xBF)
        {
            const unit: u16 = 0xD000 |
                (@as(u16, seq[1] & 0x3F) << 6) |
                @as(u16, seq[2] & 0x3F);
            try out.append(a, unit);
            continue;
        }
        const cp = std.unicode.utf8Decode(seq) catch return error.InvalidUtf8;
        if (cp < 0x10000) {
            try out.append(a, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.append(a, @intCast(0xD800 + (v >> 10)));
            try out.append(a, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return out.toOwnedSlice(a);
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

/// LOSSY: an unpaired surrogate becomes U+FFFD rather than aborting the
/// whole conversion. Flash keeps unpaired halves in its strings and
/// prints them as the replacement character, so a strict encoder would
/// silently drop the entire line.
pub fn toUtf8(a: std.mem.Allocator, s: AvmString) ![]const u8 {
    if (std.unicode.utf16LeToUtf8Alloc(a, s)) |ok| return ok else |_| {}
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < s.len) {
        const hi = s[i];
        var cp: u21 = hi;
        if (hi >= 0xD800 and hi <= 0xDBFF and i + 1 < s.len and
            s[i + 1] >= 0xDC00 and s[i + 1] <= 0xDFFF)
        {
            cp = @intCast(0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (@as(u32, s[i + 1]) - 0xDC00));
            i += 2;
        } else {
            if (hi >= 0xD800 and hi <= 0xDFFF) cp = 0xFFFD;
            i += 1;
        }
        const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
            break :blk std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
        };
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
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
/// Ordering is by CODE POINT, not code unit. The two differ only when a
/// surrogate pair meets a BMP character above U+E000 — "\uFF61" sorts
/// BELOW "\uD800\uDC02" because U+FF61 is below U+10002, though the raw
/// units say the opposite (corpus string_relational_compare).
pub fn order(x: AvmString, y: AvmString) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        const cx = codePointAt(x, &i);
        const cy = codePointAt(y, &j);
        if (cx != cy) return if (cx < cy) .lt else .gt;
    }
    return std.math.order(x.len - i, y.len - j);
}

/// The code point at `i`, advancing past the whole surrogate pair. A LONE
/// surrogate is its own value — Flash keeps unpaired halves and so must
/// any comparison over them.
fn codePointAt(s: AvmString, i: *usize) u32 {
    const hi = s[i.*];
    if (hi >= 0xD800 and hi <= 0xDBFF and i.* + 1 < s.len) {
        const lo = s[i.* + 1];
        if (lo >= 0xDC00 and lo <= 0xDFFF) {
            i.* += 2;
            return 0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (@as(u32, lo) - 0xDC00);
        }
    }
    i.* += 1;
    return hi;
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
