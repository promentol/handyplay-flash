//! SWF bitmap tags → RGBA pixels.
//!
//! The four `DefineBits*` families reduce to two jobs: hand something to
//! stb (JPEG, and the PNG/GIF that SWF8+ smuggles inside a JPEG tag), or
//! inflate and de-swizzle a raw pixel block ourselves.
//!
//! Output is RGBA8, one byte per channel, and `premultiplied` says which
//! FORM it is in. Most SWF bitmap families store colour already
//! multiplied by alpha — a `DefineBitsLossless2` and the alpha plane of a
//! `DefineBitsJPEG3` both do — and that is also `BitmapData`'s storage
//! form, so `loadBitmap` copies those bytes across untouched. Converting
//! out and back instead costs a unit in the last place per channel, which
//! the corpus reads back and notices.
//!
//! No I/O: the compressed bytes are already slices into the movie buffer.
//!
//! Reference: reference/ruffle/render/src/utils.rs.

const std = @import("std");
const simdra = @import("simdra");
const library = @import("../display/library.zig");
const bitmap_tags = @import("../swf/bitmap_tags.zig");

pub const Error = error{
    /// stb could not make sense of the payload, or a lossless block was
    /// short of the pixels its header promised.
    BadImage,
    OutOfMemory,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4`, row-major, R G B A.
    rgba: []u8,
    /// Is the colour already multiplied by the alpha? True for the tag
    /// families that store it that way; false for a straight-alpha PNG or
    /// GIF smuggled inside a JPEG tag.
    premultiplied: bool = false,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.rgba = &.{};
    }
};

/// `jpeg_tables` is the movie-level JPEGTables (8) stream, needed only by
/// `DefineBits` (6).
pub fn decode(gpa: std.mem.Allocator, bmp: library.Bitmap, jpeg_tables: ?[]const u8) Error!Image {
    return switch (bmp) {
        .jpeg_needs_tables => |b| decodeJpeg(gpa, b.jpeg_data, jpeg_tables, null),
        .jpeg2 => |b| decodeJpeg(gpa, b.data, null, null),
        .jpeg3 => |b| decodeJpeg(gpa, b.data, null, b.alpha_zlib),
        .lossless => |b| decodeLossless(gpa, b),
    };
}

/// The pixel size WITHOUT decoding. A lossless tag states it outright; a
/// JPEG family one needs a header peek, which stb does without allocating
/// the pixels. Bounds need this and nothing else, so a display object that
/// is never drawn is never decoded.
pub fn sizeOf(bmp: library.Bitmap) ?[2]u32 {
    const bytes = switch (bmp) {
        .lossless => |b| return .{ b.width, b.height },
        // A DefineBits payload is headless without its tables, but the
        // SOF marker that carries the dimensions is in the SCAN data, not
        // the tables, so peeking still works.
        .jpeg_needs_tables => |b| b.jpeg_data,
        .jpeg2 => |b| b.data,
        .jpeg3 => |b| b.data,
    };
    const info = simdra.decode.peekInfo(removeInvalidJpegData(bytes)) catch return null;
    return .{ info.width, info.height };
}

// --- JPEG (and whatever else stb recognises) ---------------------------------

fn decodeJpeg(
    gpa: std.mem.Allocator,
    data: []const u8,
    jpeg_tables: ?[]const u8,
    alpha_zlib: ?[]const u8,
) Error!Image {
    const glued = try glueTables(gpa, data, jpeg_tables);
    defer if (glued.owned) gpa.free(@constCast(glued.bytes));
    const clean = removeInvalidJpegData(glued.bytes);

    var bm = simdra.decode.decodeImage(gpa, clean) catch return error.BadImage;
    defer simdra.SmBitmap.releaseWithAllocator(gpa, bm);
    if (bm.width == 0 or bm.height == 0) return error.BadImage;

    const n = @as(usize, bm.width) * @as(usize, bm.height);
    const rgba = try gpa.alloc(u8, n * 4);
    errdefer gpa.free(rgba);
    @memcpy(rgba, bm.data[0 .. n * 4]);

    var premultiplied = false;
    if (alpha_zlib) |az| {
        const alpha = inflateZlib(gpa, az) catch null;
        if (alpha) |a| {
            defer gpa.free(a);
            if (a.len >= n) {
                applyAlphaPlane(rgba, a);
                premultiplied = true;
            }
        }
    }
    return .{ .width = bm.width, .height = bm.height, .rgba = rgba, .premultiplied = premultiplied };
}

/// The JPEG payload of a `DefineBitsJPEG3` IS premultiplied, and in some
/// encoders is not, so a fully transparent pixel can carry colour and
/// show up. Flash clamps each channel to the alpha, which is exactly the
/// invariant premultiplication guarantees.
fn applyAlphaPlane(rgba: []u8, alpha: []const u8) void {
    var i: usize = 0;
    while (i * 4 + 3 < rgba.len and i < alpha.len) : (i += 1) {
        const a = alpha[i];
        rgba[i * 4 + 0] = @min(rgba[i * 4 + 0], a);
        rgba[i * 4 + 1] = @min(rgba[i * 4 + 1], a);
        rgba[i * 4 + 2] = @min(rgba[i * 4 + 2], a);
        rgba[i * 4 + 3] = a;
    }
}

const Glued = struct { bytes: []const u8, owned: bool };

/// `DefineBits` stores only the scan data; the Huffman/quantisation tables
/// live in the movie's one `JPEGTables` tag. Splicing them is dropping the
/// tables' trailing EOI and the data's leading SOI.
fn glueTables(gpa: std.mem.Allocator, data: []const u8, jpeg_tables: ?[]const u8) Error!Glued {
    const tables = jpeg_tables orelse return .{ .bytes = data, .owned = false };
    if (tables.len < 2) return .{ .bytes = data, .owned = false };
    const head = tables[0 .. tables.len - 2];
    const tail = if (data.len >= 2) data[2..] else data[0..0];
    const out = try gpa.alloc(u8, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return .{ .bytes = out, .owned = true };
}

/// SWF JPEGs may carry a stray `FF D9 FF D8` EOI/SOI pair — a relic of the
/// JPEGTables splice, which Flash's decoder skips and a standard one stops
/// at. The errata says it is at the very start; in practice it turns up
/// anywhere before the SOF marker, so the whole marker chain is walked.
///
/// The result always SLICES the input: the pair is at a marker boundary,
/// so dropping it never needs a copy when it is at the front, and when it
/// is not, the bytes before it are the tables — which stb re-reads from
/// the spliced stream anyway.
fn removeInvalidJpegData(data: []const u8) []const u8 {
    const EOI_SOI = [_]u8{ 0xFF, 0xD9, 0xFF, 0xD8 };
    if (std.mem.startsWith(u8, data, &EOI_SOI)) return data[4..];

    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }
        const marker = data[pos + 1];
        switch (marker) {
            // A standalone marker: no length field to skip over.
            0xD8, 0x01, 0xD0...0xD7 => pos += 2,
            0xD9 => {
                if (std.mem.startsWith(u8, data[pos..], &EOI_SOI)) return data[pos + 4 ..];
                pos += 2;
            },
            // Start of frame — the pair never appears past here.
            0xC0 => return data,
            else => {
                if (pos + 4 > data.len) return data;
                const len = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
                if (len < 2) return data;
                pos += 2 + len;
            },
        }
    }
    return data;
}

// --- DefineBitsLossless -------------------------------------------------------

/// Three pixel layouts behind one tag, and the trap in two of them is ROW
/// PADDING: a colour-mapped row rounds up to four bytes and a PIX15 row to
/// two, independent of the image width.
fn decodeLossless(gpa: std.mem.Allocator, tag: bitmap_tags.Lossless) Error!Image {
    const w: usize = tag.width;
    const h: usize = tag.height;
    if (w == 0 or h == 0) return error.BadImage;

    const raw = inflateZlib(gpa, tag.zlib_data) catch return error.BadImage;
    defer gpa.free(raw);

    const rgba = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(rgba);
    const has_alpha = tag.version == 2;

    switch (tag.format) {
        .colormap8 => {
            const entry_size: usize = if (has_alpha) 4 else 3;
            const palette_bytes = @as(usize, tag.colormap_len) * entry_size;
            if (raw.len < palette_bytes) return error.BadImage;
            const palette = raw[0..palette_bytes];
            const padded_width = (w + 3) & ~@as(usize, 3);
            if (raw.len < palette_bytes + padded_width * h - (padded_width - w)) return error.BadImage;

            var i = palette_bytes;
            var o: usize = 0;
            for (0..h) |_| {
                for (0..w) |_| {
                    const entry = raw[i];
                    // An index past the palette is transparent on a v2 tag
                    // and black on a v1 one.
                    if (@as(usize, entry) < tag.colormap_len) {
                        const p = @as(usize, entry) * entry_size;
                        rgba[o + 0] = palette[p + 0];
                        rgba[o + 1] = palette[p + 1];
                        rgba[o + 2] = palette[p + 2];
                        rgba[o + 3] = if (has_alpha) palette[p + 3] else 255;
                    } else {
                        rgba[o + 0] = 0;
                        rgba[o + 1] = 0;
                        rgba[o + 2] = 0;
                        rgba[o + 3] = if (has_alpha) 0 else 255;
                    }
                    i += 1;
                    o += 4;
                }
                i += padded_width - w;
            }
        },
        .rgb15 => {
            if (has_alpha) return error.BadImage;
            const padded_width = (w + 1) & ~@as(usize, 1);
            if (raw.len < (padded_width * h - (padded_width - w)) * 2) return error.BadImage;
            var i: usize = 0;
            var o: usize = 0;
            for (0..h) |_| {
                for (0..w) |_| {
                    const v = std.mem.readInt(u16, raw[i..][0..2], .big);
                    rgba[o + 0] = expand5((v >> 10) & 0x1F);
                    rgba[o + 1] = expand5((v >> 5) & 0x1F);
                    rgba[o + 2] = expand5(v & 0x1F);
                    rgba[o + 3] = 255;
                    i += 2;
                    o += 4;
                }
                i += (padded_width - w) * 2;
            }
        },
        // Stored ARGB, so the rotation is one step left into RGBA. No row
        // padding here: four bytes a pixel is already aligned.
        .rgb24 => {
            if (raw.len < w * h * 4) return error.BadImage;
            for (0..w * h) |p| {
                rgba[p * 4 + 0] = raw[p * 4 + 1];
                rgba[p * 4 + 1] = raw[p * 4 + 2];
                rgba[p * 4 + 2] = raw[p * 4 + 3];
                rgba[p * 4 + 3] = if (has_alpha) raw[p * 4 + 0] else 255;
            }
        },
        _ => return error.BadImage,
    }
    return .{ .width = @intCast(w), .height = @intCast(h), .rgba = rgba, .premultiplied = has_alpha };
}

/// 5 bits to 8 the way Flash does it: `(c * 255 + 15) / 31`, which is not
/// quite the usual bit-replication.
fn expand5(c: u16) u8 {
    return @intCast((c * 255 + 15) / 31);
}

fn inflateZlib(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(data);
    var window: [1 << 16]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn zlibOf(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(64);
    const buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(buf);
    var comp = try std.compress.flate.Compress.init(&out.writer, buf, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    return out.toOwnedSlice();
}

test "a colour-mapped row is padded to four bytes, not to its width" {
    const gpa = testing.allocator;
    // Two colours, a 3-wide image: each row is 3 indices plus one pad byte.
    var raw: [2 * 3 + 4 * 2]u8 = .{
        0xFF, 0x00, 0x00, // palette 0: red
        0x00, 0xFF, 0x00, // palette 1: green
        0, 1, 0, 0xAA, // row 0 + pad
        1, 0, 1, 0xBB, // row 1 + pad
    };
    const z = try zlibOf(gpa, &raw);
    defer gpa.free(z);

    var img = try decodeLossless(gpa, .{
        .version = 1,
        .id = 1,
        .format = .colormap8,
        .width = 3,
        .height = 2,
        .colormap_len = 2,
        .zlib_data = z,
    });
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0, 0, 255 }, img.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0xFF, 0, 255 }, img.rgba[4..8]);
    // Row 1 starts at the pad boundary, so its first pixel is green.
    try testing.expectEqualSlices(u8, &.{ 0, 0xFF, 0, 255 }, img.rgba[12..16]);
}

test "PIX24 is stored ARGB and rotates into RGBA" {
    const gpa = testing.allocator;
    const raw = [_]u8{ 0x80, 0x11, 0x22, 0x33 };
    const z = try zlibOf(gpa, &raw);
    defer gpa.free(z);

    var img = try decodeLossless(gpa, .{
        .version = 2,
        .id = 1,
        .format = .rgb24,
        .width = 1,
        .height = 1,
        .zlib_data = z,
    });
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x80 }, img.rgba);
}

test "a v1 PIX24 ignores the stored alpha byte" {
    const gpa = testing.allocator;
    const raw = [_]u8{ 0x00, 0x11, 0x22, 0x33 };
    const z = try zlibOf(gpa, &raw);
    defer gpa.free(z);

    var img = try decodeLossless(gpa, .{
        .version = 1,
        .id = 1,
        .format = .rgb24,
        .width = 1,
        .height = 1,
        .zlib_data = z,
    });
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), img.rgba[3]);
}

test "the stray EOI/SOI pair is dropped wherever it sits" {
    const at_front = [_]u8{ 0xFF, 0xD9, 0xFF, 0xD8, 0xFF, 0xD8, 0xFF, 0xC0 };
    try testing.expectEqual(@as(usize, 4), removeInvalidJpegData(&at_front).len);
    // A well-formed stream is returned untouched.
    const clean = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0, 0 };
    try testing.expectEqual(@as(usize, 6), removeInvalidJpegData(&clean).len);
}
