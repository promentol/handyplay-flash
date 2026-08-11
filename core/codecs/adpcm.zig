//! SWF ADPCM (2-5 bit) — hand-written and self-contained, as this file's
//! contract has always said. Ported from ruffle
//! `core/src/backend/audio/decoders/adpcm.rs`, which is the behaviour
//! authority; the tables below are IMA's, as SWF uses them.
//!
//! Two things about this format catch people out, and both are load-
//! bearing here:
//!
//!   * Nothing is byte-aligned. The 2-bit "bits per sample minus two"
//!     header, each channel's initial 16-bit sample and 6-bit step index,
//!     and every sample after them are read from one continuous BIT
//!     stream, big-endian.
//!   * The initial sample/step pair repeats every 4095 samples, not just
//!     at the start — the format resynchronises so a long clip cannot
//!     drift.
//!
//! A sample word is SIGN-MAGNITUDE, not two's complement: the top bit is
//! the sign and the rest is the magnitude, so `-0` exists and means "step
//! down by the smallest delta".

const std = @import("std");

const MAX_STEP: i16 = STEP_TABLE.len - 1;

const STEP_TABLE = [_]u16{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
    19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
    337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
    876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
    5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

const INDEX_2 = [_]i16{ -1, 2 };
const INDEX_3 = [_]i16{ -1, -1, 2, 4 };
const INDEX_4 = [_]i16{ -1, -1, -1, -1, 2, 4, 6, 8 };
const INDEX_5 = [_]i16{ -1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16 };

fn indexTable(bits: u8) []const i16 {
    return switch (bits) {
        2 => &INDEX_2,
        3 => &INDEX_3,
        4 => &INDEX_4,
        else => &INDEX_5,
    };
}

/// `(magnitude + 0.5) * step / 2^(bits - 2)`, done in integers exactly the
/// way the format specifies it — one shifted term per magnitude bit.
fn delta(bits: u8, step: u16, magnitude: u32) u16 {
    var d: u32 = step >> @intCast(bits - 1);
    var bit: u3 = 0;
    while (bit < bits - 1) : (bit += 1) {
        if (magnitude & (@as(u32, 1) << bit) != 0) {
            d += step >> @intCast(bits - 2 - bit);
        }
    }
    return @intCast(@min(d, std.math.maxInt(u16)));
}

/// A big-endian bit reader. Small enough to keep here rather than share:
/// `swf.reader` reads bits too, but only inside a tag it already owns.
const Bits = struct {
    data: []const u8,
    pos: usize = 0, // in bits

    fn read(self: *Bits, n: u6) ?u32 {
        if (n == 0) return 0;
        if (self.pos + n > self.data.len * 8) return null;
        var out: u32 = 0;
        var left = n;
        while (left > 0) : (left -= 1) {
            const byte = self.data[self.pos >> 3];
            const bit: u3 = @intCast(7 - (self.pos & 7));
            out = (out << 1) | ((byte >> bit) & 1);
            self.pos += 1;
        }
        return out;
    }

    fn readSigned16(self: *Bits) ?i16 {
        const raw = self.read(16) orelse return null;
        return @bitCast(@as(u16, @intCast(raw)));
    }
};

const Channel = struct { sample: i16 = 0, step_index: i16 = 0 };

/// Decode a whole ADPCM block to interleaved signed 16-bit. `frames` is
/// the sample count the tag declares — the bit stream carries no length
/// of its own, so this is where it comes from.
pub fn decode(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    is_stereo: bool,
    frames: u32,
) std.mem.Allocator.Error![]i16 {
    const channels: usize = if (is_stereo) 2 else 1;
    var out: std.ArrayList(i16) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, @as(usize, frames) * channels);

    var bits: Bits = .{ .data = bytes };
    const header = bits.read(2) orelse return out.toOwnedSlice(gpa);
    const per_sample: u8 = @intCast(header + 2);
    const table = indexTable(per_sample);

    var ch: [2]Channel = .{ .{}, .{} };
    var n: u32 = 0;
    while (n < frames) : (n += 1) {
        // The initial pair, again every 4095 samples.
        if (n % 4095 == 0) {
            for (ch[0..channels]) |*c| {
                c.sample = bits.readSigned16() orelse return out.toOwnedSlice(gpa);
                c.step_index = @intCast(bits.read(6) orelse return out.toOwnedSlice(gpa));
                c.step_index = std.math.clamp(c.step_index, 0, MAX_STEP);
            }
        } else {
            for (ch[0..channels]) |*c| {
                const step = STEP_TABLE[@intCast(c.step_index)];
                const word = bits.read(@intCast(per_sample)) orelse return out.toOwnedSlice(gpa);
                const sign_mask = @as(u32, 1) << @intCast(per_sample - 1);
                const magnitude = word & ~sign_mask;
                const d = delta(per_sample, step, magnitude);
                const moved: i32 = if (word & sign_mask != 0)
                    @as(i32, c.sample) - @as(i32, d)
                else
                    @as(i32, c.sample) + @as(i32, d);
                c.sample = @intCast(std.math.clamp(
                    moved,
                    std.math.minInt(i16),
                    std.math.maxInt(i16),
                ));
                c.step_index += table[@intCast(magnitude)];
                c.step_index = std.math.clamp(c.step_index, 0, MAX_STEP);
            }
        }
        for (ch[0..channels]) |c| out.appendAssumeCapacity(c.sample);
    }
    return out.toOwnedSlice(gpa);
}

test "the first sample comes straight out of the header" {
    // 2-bit words (header 0), then a mono channel starting at 1000 with
    // step index 0, then one sample word.
    var buf: [8]u8 = @splat(0);
    var w: usize = 0;
    var acc: u32 = 0;
    var nbits: u5 = 0;
    const put = struct {
        fn go(b: *[8]u8, i: *usize, a: *u32, n: *u5, v: u32, count: u5) void {
            var k = count;
            while (k > 0) : (k -= 1) {
                a.* = (a.* << 1) | ((v >> @intCast(k - 1)) & 1);
                n.* += 1;
                if (n.* == 8) {
                    b[i.*] = @intCast(a.* & 0xFF);
                    i.* += 1;
                    a.* = 0;
                    n.* = 0;
                }
            }
        }
    }.go;
    put(&buf, &w, &acc, &nbits, 0, 2); // 2 bits per sample
    put(&buf, &w, &acc, &nbits, 1000, 16); // initial sample
    put(&buf, &w, &acc, &nbits, 0, 6); // step index 0
    put(&buf, &w, &acc, &nbits, 0, 2); // one word: +smallest delta
    if (nbits > 0) buf[w] = @intCast((acc << @intCast(8 - nbits)) & 0xFF);

    const out = try decode(std.testing.allocator, &buf, false, 2);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(i16, 1000), out[0]);
    // step 7 at index 0, magnitude 0: delta = 7 >> 1 = 3.
    try std.testing.expectEqual(@as(i16, 1003), out[1]);
}

test "a truncated stream stops rather than reading past its end" {
    const out = try decode(std.testing.allocator, &.{0x00}, false, 100);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len < 100);
}
