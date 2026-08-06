//! SWF outer container: signature detection and payload decompression.
//!
//! Layout (the first 8 bytes are ALWAYS uncompressed):
//!   signature[3]  "FWS" = none | "CWS" = zlib (SWF >= 6) | "ZWS" = LZMA (SWF >= 13)
//!   version       u8    (0 is invalid — FP9+ behavior)
//!   file_length   u32le total UNCOMPRESSED size, INCLUDING these 8 bytes
//! Everything after byte 8 is the (possibly compressed) movie payload:
//!   RECT stage bounds, FIXED8 frame rate, u16 frame count, then the tag stream.
//!
//! Spec: reference/openflash/open-flash/content/documentation/swf/swf.md
//! Behavior reference: reference/ruffle/swf/src/read.rs `decompress_swf`
//! (tolerate truncated compressed streams — real SWFs lie about lengths).

const std = @import("std");

pub const Compression = enum {
    none,
    zlib,
    lzma,

    pub fn name(c: Compression) []const u8 {
        return switch (c) {
            .none => "none (FWS)",
            .zlib => "zlib (CWS)",
            .lzma => "lzma (ZWS)",
        };
    }
};

pub const Error = error{
    NotSwf,
    TruncatedFile,
    InvalidVersion,
    /// ZWS/LZMA is deferred (ADR D4): SWF >= 13 only, out of AVM1-era scope.
    LzmaUnsupported,
    OutOfMemory,
};

pub const Decompressed = struct {
    compression: Compression,
    version: u8,
    /// Declared uncompressed length of the whole file (including the 8 header bytes).
    declared_length: u32,
    /// Uncompressed movie payload (everything after the 8 outer-header bytes).
    /// May be shorter than declared_length - 8 if the stream was truncated.
    body: []u8,

    pub fn deinit(self: *Decompressed, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// Detect the signature and produce the uncompressed movie payload.
/// `bytes` is the entire file. The returned body is owned by the caller.
pub fn decompress(gpa: std.mem.Allocator, bytes: []const u8) Error!Decompressed {
    if (bytes.len < 8) return Error.TruncatedFile;
    if (bytes[1] != 'W' or bytes[2] != 'S') return Error.NotSwf;
    const compression: Compression = switch (bytes[0]) {
        'F' => .none,
        'C' => .zlib,
        'Z' => .lzma,
        else => return Error.NotSwf,
    };
    const version = bytes[3];
    if (version == 0) return Error.InvalidVersion;
    const declared_length = std.mem.readInt(u32, bytes[4..8], .little);
    const payload = bytes[8..];

    const body: []u8 = switch (compression) {
        .none => try gpa.dupe(u8, payload),
        .zlib => try inflateZlib(gpa, payload, declared_length),
        .lzma => return Error.LzmaUnsupported,
    };

    return .{
        .compression = compression,
        .version = version,
        .declared_length = declared_length,
        .body = body,
    };
}

fn inflateZlib(gpa: std.mem.Allocator, compressed: []const u8, declared_length: u32) Error![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Reserve the declared size up front (cheap; also what Flash Player did),
    // capped so a hostile header can't force a huge allocation.
    const max_capacity: u32 = 128 << 20;
    out.ensureUnusedCapacity(@min(declared_length -| 8, max_capacity)) catch
        return Error.OutOfMemory;

    // Tolerate mid-stream corruption/truncation: keep whatever inflated
    // (many real SWFs have wrong stream lengths; Ruffle does the same).
    _ = inflate.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => {},
        error.WriteFailed => return Error.OutOfMemory,
    };
    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

test "FWS passthrough" {
    const gpa = std.testing.allocator;
    const file = [_]u8{ 'F', 'W', 'S', 6, 12, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD };
    var d = try decompress(gpa, &file);
    defer d.deinit(gpa);
    try std.testing.expectEqual(Compression.none, d.compression);
    try std.testing.expectEqual(@as(u8, 6), d.version);
    try std.testing.expectEqual(@as(u32, 12), d.declared_length);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, d.body);
}

test "rejects non-SWF and version 0" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.NotSwf, decompress(gpa, "XWS\x06\x08\x00\x00\x00"));
    try std.testing.expectError(Error.InvalidVersion, decompress(gpa, "FWS\x00\x08\x00\x00\x00"));
    try std.testing.expectError(Error.TruncatedFile, decompress(gpa, "FWS"));
}

test "CWS zlib roundtrip" {
    const gpa = std.testing.allocator;
    // zlib-compress a known payload with the std deflate writer, then decompress.
    const payload = "hello swf payload, hello swf payload, hello swf payload";
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer compressed.deinit();
    var deflate_buf: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var deflate: std.compress.flate.Compress = try .init(&compressed.writer, &deflate_buf, .zlib, .default);
    try deflate.writer.writeAll(payload);
    try deflate.finish();

    var file: std.array_list.Managed(u8) = .init(gpa);
    defer file.deinit();
    try file.appendSlice("CWS\x06");
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(payload.len + 8), .little);
    try file.appendSlice(&len_bytes);
    try file.appendSlice(compressed.written());

    var d = try decompress(gpa, file.items);
    defer d.deinit(gpa);
    try std.testing.expectEqual(Compression.zlib, d.compression);
    try std.testing.expectEqualStrings(payload, d.body);
}
