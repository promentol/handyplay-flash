//! FLV "Screen video" (codec 3) — the screencast codec.
//!
//! The simplest video format Flash ever shipped: the frame is a grid of
//! fixed-size blocks, each one either UNCHANGED (a zero-length record,
//! so the previous frame shows through) or a zlib stream of raw BGR
//! pixels. No motion, no transforms, no colour space — which is why a
//! screen recording of flat UI compresses so well and a camera feed does
//! not.
//!
//! Two orderings are upside down and both matter: the blocks run from
//! the BOTTOM-LEFT of the image rightwards and then up, and the pixel
//! rows inside a block run bottom-up too.
//!
//! Layout reference: reference/ruffle/video/software/src/decoder/screen.rs
//! and SWF19's "Screen video" annex.

const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{Corrupt};

/// A decoded frame, RGBA8888 in the player's logical order. Owned by the
/// allocator it was decoded with.
pub const Frame = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.* = undefined;
    }
};

/// Decode one frame. `prev` supplies the blocks this frame does not
/// carry; without it, a missing block is left transparent.
pub fn decode(gpa: std.mem.Allocator, data: []const u8, prev: ?Frame) Error!Frame {
    if (data.len < 4) return error.Corrupt;
    const block_w: u32 = (@as(u32, data[0] >> 4) + 1) * 16;
    const width: u32 = (@as(u32, data[0] & 0x0F) << 8) | data[1];
    const block_h: u32 = (@as(u32, data[2] >> 4) + 1) * 16;
    const height: u32 = (@as(u32, data[2] & 0x0F) << 8) | data[3];
    if (width == 0 or height == 0 or block_w == 0 or block_h == 0) return error.Corrupt;

    const rgba = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(rgba);
    if (prev) |p| {
        if (p.width == width and p.height == height) {
            @memcpy(rgba, p.rgba);
        } else {
            @memset(rgba, 0);
        }
    } else {
        @memset(rgba, 0);
    }

    const cols = (width + block_w - 1) / block_w;
    const rows = (height + block_h - 1) / block_h;
    var pos: usize = 4;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            if (pos + 2 > data.len) return error.Corrupt;
            const len = (@as(usize, data[pos]) << 8) | data[pos + 1];
            pos += 2;
            if (len == 0) continue; // unchanged: the previous frame stands
            if (pos + len > data.len) return error.Corrupt;
            const chunk = data[pos .. pos + len];
            pos += len;

            // Blocks are addressed from the bottom-left.
            const x0 = col * block_w;
            const y_bottom = height - row * block_h;
            const this_w = @min(block_w, width - x0);
            const this_h = @min(block_h, y_bottom);
            const y0 = y_bottom - this_h;

            scratch.clearRetainingCapacity();
            inflate(gpa, chunk, &scratch) catch continue;
            const want = @as(usize, this_w) * this_h * 3;
            if (scratch.items.len < want) continue;

            // Rows inside the block are bottom-up as well.
            var by: u32 = 0;
            while (by < this_h) : (by += 1) {
                const src = scratch.items[@as(usize, by) * this_w * 3 ..];
                const y = y0 + (this_h - 1 - by);
                var bx: u32 = 0;
                while (bx < this_w) : (bx += 1) {
                    const o = (@as(usize, y) * width + x0 + bx) * 4;
                    rgba[o + 0] = src[bx * 3 + 2]; // B G R on the wire
                    rgba[o + 1] = src[bx * 3 + 1];
                    rgba[o + 2] = src[bx * 3 + 0];
                    rgba[o + 3] = 255;
                }
            }
        }
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn inflate(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayList(u8)) !void {
    var reader = std.Io.Reader.fixed(src);
    var window: [1 << 16]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    _ = try decompress.reader.streamRemaining(&writer.writer);
    try out.appendSlice(gpa, writer.written());
}

/// A zlib stream holding one STORED deflate block — enough to exercise
/// the framing without dragging the compressor into a unit test.
fn storedZlib(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    const n: u16 = @intCast(raw.len);
    try out.appendSlice(gpa, &.{ @intCast(n & 0xFF), @intCast(n >> 8) });
    try out.appendSlice(gpa, &.{ @intCast(~n & 0xFF), @intCast((~n >> 8) & 0xFF) });
    try out.appendSlice(gpa, raw);
    var a: u32 = 1;
    var b: u32 = 0;
    for (raw) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    const adler = (b << 16) | a;
    try out.appendSlice(gpa, &.{
        @intCast((adler >> 24) & 0xFF), @intCast((adler >> 16) & 0xFF),
        @intCast((adler >> 8) & 0xFF),  @intCast(adler & 0xFF),
    });
    return out.toOwnedSlice(gpa);
}

test "a one-block keyframe decodes bottom-up" {
    const gpa = std.testing.allocator;
    // 16x16 blocks, a 1x2 image: one block, two BGR pixels, bottom row
    // first — so the SECOND pixel on the wire is the TOP one.
    const z = try storedZlib(gpa, &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 });
    defer gpa.free(z);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &.{ 0x00, 0x01, 0x00, 0x02 });
    try body.append(gpa, @intCast(z.len >> 8));
    try body.append(gpa, @intCast(z.len & 0xFF));
    try body.appendSlice(gpa, z);

    var frame = try decode(gpa, body.items, null);
    defer frame.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), frame.width);
    try std.testing.expectEqual(@as(u32, 2), frame.height);
    try std.testing.expectEqual(@as(u8, 0x66), frame.rgba[0]); // top row R
    try std.testing.expectEqual(@as(u8, 0x33), frame.rgba[4]); // bottom row R
}
