//! Bitmap definition tags — RAW payload capture (slices into the movie
//! buffer). Decoding to pixels (stb JPEG + zlib lossless + JPEG3 alpha
//! merge) is core/codecs/'s job in M4.
//!
//! Layout: reference/ruffle/swf/src/read.rs + SWF19. Note DefineBitsJPEG2
//! payloads may legally be PNG or GIF89a in SWF8+ (sniff at decode time),
//! and JPEG data may carry a leading EOI/SOI pair to strip.

const std = @import("std");
const rdr = @import("reader.zig");

pub const Error = rdr.Error;

/// DefineBits (6): JPEG needing the shared JPEGTables (8) stream.
pub const Bits = struct { id: u16, jpeg_data: []const u8 };

pub fn parseBits(body: []const u8) Error!Bits {
    var r = rdr.Reader.init(body);
    return .{ .id = try r.readU16(), .jpeg_data = r.readRest() };
}

/// DefineBitsJPEG2 (21): self-contained JPEG (or PNG/GIF in SWF8+).
pub const Jpeg2 = struct { id: u16, data: []const u8 };

pub fn parseJpeg2(body: []const u8) Error!Jpeg2 {
    var r = rdr.Reader.init(body);
    return .{ .id = try r.readU16(), .data = r.readRest() };
}

/// DefineBitsJPEG3 (35): JPEG + separate zlib-compressed alpha plane.
pub const Jpeg3 = struct { id: u16, data: []const u8, alpha_zlib: []const u8 };

pub fn parseJpeg3(body: []const u8) Error!Jpeg3 {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const data_len = try r.readU32();
    const data = try r.readSlice(@min(data_len, r.remaining()));
    return .{ .id = id, .data = data, .alpha_zlib = r.readRest() };
}

pub const LosslessFormat = enum(u8) { colormap8 = 3, rgb15 = 4, rgb24 = 5, _ };

/// DefineBitsLossless (20) / DefineBitsLossless2 (36): zlib-compressed
/// indexed/15/24-bit pixels; v2 carries alpha (format 3 = RGBA colormap,
/// format 5 = ARGB32; format 4 is v1-only).
pub const Lossless = struct {
    version: u8,
    id: u16,
    format: LosslessFormat,
    width: u16,
    height: u16,
    /// Colormap entry count (format 3 only): stored byte + 1.
    colormap_len: u16 = 0,
    zlib_data: []const u8,
};

pub fn parseLossless(body: []const u8, version: u8) Error!Lossless {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const format_raw = try r.readU8();
    const width = try r.readU16();
    const height = try r.readU16();
    var colormap_len: u16 = 0;
    if (format_raw == 3) colormap_len = @as(u16, try r.readU8()) + 1;
    return .{
        .version = version,
        .id = id,
        .format = @enumFromInt(format_raw),
        .width = width,
        .height = height,
        .colormap_len = colormap_len,
        .zlib_data = r.readRest(),
    };
}

// --- Tests -----------------------------------------------------------------

test "raw captures slice, never copy" {
    const body = [_]u8{ 5, 0, 0xFF, 0xD8, 0xFF, 0xE0 };
    const b = try parseJpeg2(&body);
    try std.testing.expectEqual(@as(u16, 5), b.id);
    try std.testing.expectEqual(@intFromPtr(&body[2]), @intFromPtr(b.data.ptr));

    const j3 = [_]u8{ 6, 0, 2, 0, 0, 0, 0xAA, 0xBB, 0x78, 0x9C };
    const p = try parseJpeg3(&j3);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, p.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x9C }, p.alpha_zlib);

    const ll = [_]u8{ 7, 0, 3, 100, 0, 50, 0, 15, 0x78, 0x9C };
    const l = try parseLossless(&ll, 2);
    try std.testing.expectEqual(LosslessFormat.colormap8, l.format);
    try std.testing.expectEqual(@as(u16, 100), l.width);
    try std.testing.expectEqual(@as(u16, 16), l.colormap_len);
    try std.testing.expectEqual(@as(usize, 2), l.zlib_data.len);
}
