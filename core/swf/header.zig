//! Movie header: the first fields of the (decompressed) SWF payload.
//!
//!   RECT   stage bounds in twips (1 px = 20 twips). Bit-packed:
//!          nbits:UB[5], then xmin/xmax/ymin/ymax as SB[nbits].
//!   FIXED8 frame rate, u16le with the FRACTIONAL byte first (8.8 fixed point).
//!   u16le  frame count of the main timeline.
//!
//! Spec: reference/openflash/open-flash/content/documentation/swf/swf.md
//! and swf-spec PDF §"The SWF header". Reference: ruffle swf/src/read.rs read_header.

const std = @import("std");

pub const TWIPS_PER_PX = 20;

pub const Header = struct {
    /// Stage bounds in twips. xmin/ymin are usually 0 but not always.
    xmin: i32,
    xmax: i32,
    ymin: i32,
    ymax: i32,
    /// Frames per second. Raw 8.8 value; 0 is clamped to 0.01 at the player
    /// layer (R5), not here — the parser reports what the file says.
    frame_rate: f32,
    frame_count: u16,
    /// Offset into the payload where the tag stream begins.
    tags_offset: usize,

    pub fn widthTwips(h: Header) i32 {
        return h.xmax - h.xmin;
    }
    pub fn heightTwips(h: Header) i32 {
        return h.ymax - h.ymin;
    }
    pub fn widthPx(h: Header) u32 {
        return @intCast(@max(0, @divTrunc(h.widthTwips(), TWIPS_PER_PX)));
    }
    pub fn heightPx(h: Header) u32 {
        return @intCast(@max(0, @divTrunc(h.heightTwips(), TWIPS_PER_PX)));
    }
};

pub const Error = error{TruncatedHeader};

/// Parse the movie header from the start of the decompressed payload.
pub fn parse(body: []const u8) Error!Header {
    var bits: BitCursor = .{ .bytes = body };
    const nbits = try bits.readUb(5);
    const xmin = try bits.readSb(nbits);
    const xmax = try bits.readSb(nbits);
    const ymin = try bits.readSb(nbits);
    const ymax = try bits.readSb(nbits);
    const after_rect = bits.byteAligned();

    if (body.len < after_rect + 4) return Error.TruncatedHeader;
    // FIXED8: little-endian u16, low byte = fraction.
    const rate_raw = std.mem.readInt(u16, body[after_rect..][0..2], .little);
    const frame_count = std.mem.readInt(u16, body[after_rect + 2 ..][0..2], .little);

    return .{
        .xmin = xmin,
        .xmax = xmax,
        .ymin = ymin,
        .ymax = ymax,
        .frame_rate = @as(f32, @floatFromInt(rate_raw)) / 256.0,
        .frame_count = frame_count,
        .tags_offset = after_rect + 4,
    };
}

/// Minimal MSB-first bit cursor, enough for the header RECT.
/// The general-purpose reader (UB/SB/FB/strings/matrices) lands in reader.zig (M1).
const BitCursor = struct {
    bytes: []const u8,
    bit: usize = 0,

    fn readUb(self: *BitCursor, n: u5) Error!u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const byte_idx = self.bit / 8;
            if (byte_idx >= self.bytes.len) return Error.TruncatedHeader;
            const shift: u3 = @intCast(7 - (self.bit % 8));
            v = (v << 1) | ((self.bytes[byte_idx] >> shift) & 1);
            self.bit += 1;
        }
        return v;
    }

    fn readSb(self: *BitCursor, n: u32) Error!i32 {
        if (n == 0) return 0;
        const raw = try self.readUb(@intCast(n));
        // Sign-extend from n bits.
        const shift: u5 = @intCast(32 - n);
        return @as(i32, @bitCast(raw << shift)) >> shift;
    }

    /// Byte offset just past the last consumed bit.
    fn byteAligned(self: *const BitCursor) usize {
        return (self.bit + 7) / 8;
    }
};

test "parse a hand-built header" {
    // RECT with nbits=15, bounds (0, 11000, 0, 8000) = 550x400 px.
    // Layout: 01111 000000000000000 010101011111000 000000000000000 001111101000000 pad
    var buf: [16]u8 = @splat(0);
    var w = BitWriter{ .bytes = &buf };
    w.write(15, 5);
    w.write(0, 15);
    w.write(11000, 15);
    w.write(0, 15);
    w.write(8000, 15);
    const rect_len = (w.bit + 7) / 8;
    // frame rate 24.0 (0x1800 le => 00 18), 3 frames
    buf[rect_len] = 0x00;
    buf[rect_len + 1] = 24;
    buf[rect_len + 2] = 3;
    buf[rect_len + 3] = 0;

    const h = try parse(buf[0 .. rect_len + 4]);
    try std.testing.expectEqual(@as(u32, 550), h.widthPx());
    try std.testing.expectEqual(@as(u32, 400), h.heightPx());
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), h.frame_rate, 0.001);
    try std.testing.expectEqual(@as(u16, 3), h.frame_count);
    try std.testing.expectEqual(rect_len + 4, h.tags_offset);
}

test "fractional frame rate" {
    // nbits=0 rect: single byte 0b00000_000; then rate 12.5 (0x0C80 => 80 0C), 1 frame.
    const buf = [_]u8{ 0x00, 0x80, 0x0C, 0x01, 0x00 };
    const h = try parse(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), h.frame_rate, 0.001);
    try std.testing.expectEqual(@as(u16, 1), h.frame_count);
}

const BitWriter = struct {
    bytes: []u8,
    bit: usize = 0,

    fn write(self: *BitWriter, value: u32, n: u5) void {
        var i: u5 = n;
        while (i > 0) {
            i -= 1;
            const b: u1 = @intCast((value >> i) & 1);
            const byte_idx = self.bit / 8;
            const shift: u3 = @intCast(7 - (self.bit % 8));
            self.bytes[byte_idx] |= @as(u8, b) << shift;
            self.bit += 1;
        }
    }
};
