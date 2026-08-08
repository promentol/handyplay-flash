//! A `BitmapData`'s pixels: a flat ARGB buffer plus the two facts every
//! operation branches on — its size and whether it keeps alpha.
//!
//! A leaf module beside `pixels.zig`; the AVM1 class that owns one lives
//! in `core/avm1/globals/bitmap_data.zig`.
//!
//! Pixels are stored PREMULTIPLIED (see `pixels.zig`). `getPixel32` is the
//! only reader that un-multiplies, and `setPixel32` the only writer that
//! multiplies — everything else works in storage form.
//!
//! `dispose()` frees the buffer but leaves the object alive: script can
//! still hold a reference, and Flash answers -1 for the dimensions of a
//! disposed one rather than throwing.
//!
//! Reference: reference/ruffle/core/src/bitmap/bitmap_data.rs.

const std = @import("std");
const pixels = @import("pixels.zig");

const Color = pixels.Color;

pub const BitmapData = struct {
    width: u32,
    height: u32,
    /// False makes every stored alpha 255 — an opaque bitmap cannot be
    /// written a translucent pixel.
    transparency: bool,
    /// Row-major, `width * height` entries, premultiplied. Empty once
    /// disposed.
    data: []Color = &.{},
    disposed: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
        transparency: bool,
        fill_argb: u32,
    ) !BitmapData {
        const n = @as(usize, width) * @as(usize, height);
        const buf = try gpa.alloc(Color, n);
        const fill = Color.fromArgb(fill_argb).toPremultiplied(transparency);
        @memset(buf, fill);
        return .{
            .width = width,
            .height = height,
            .transparency = transparency,
            .data = buf,
        };
    }

    pub fn deinit(self: *BitmapData, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.data = &.{};
    }

    pub fn dispose(self: *BitmapData, gpa: std.mem.Allocator) void {
        self.deinit(gpa);
        self.disposed = true;
        self.width = 0;
        self.height = 0;
    }

    pub fn inBounds(self: *const BitmapData, x: i64, y: i64) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    /// Storage form. Out of bounds reads transparent black, which is what
    /// the sampling operations expect at an edge.
    pub fn get(self: *const BitmapData, x: i64, y: i64) Color {
        if (!self.inBounds(x, y)) return Color.fromArgb(0);
        return self.data[@intCast(y * @as(i64, self.width) + x)];
    }

    /// Storage form. Out of bounds is silently dropped.
    pub fn set(self: *BitmapData, x: i64, y: i64, c: Color) void {
        if (!self.inBounds(x, y)) return;
        self.data[@intCast(y * @as(i64, self.width) + x)] = c;
    }

    /// What script sees. An OPAQUE bitmap is not un-multiplied at all —
    /// its stored alpha is normally 255, so the raw value already IS the
    /// script value. That stops being true when `threshold` or
    /// `paletteMap` writes a translucent pixel to an opaque bitmap (both
    /// premultiply as though it were transparent), and the raw value is
    /// then exactly what Flash reports back.
    pub fn getPixel32(self: *const BitmapData, x: i64, y: i64) u32 {
        if (!self.inBounds(x, y)) return 0;
        const c = self.get(x, y);
        return if (self.transparency) c.toUnmultiplied().toArgb() else c.toArgb();
    }

    pub fn setPixel32(self: *BitmapData, x: i64, y: i64, argb: u32) void {
        self.set(x, y, Color.fromArgb(argb).toPremultiplied(self.transparency));
    }

    /// `getPixel` is not `getPixel32` masked: it un-multiplies whatever
    /// the transparency flag says, and only then drops the alpha byte.
    pub fn getPixel(self: *const BitmapData, x: i64, y: i64) u32 {
        if (!self.inBounds(x, y)) return 0;
        return self.get(x, y).toUnmultiplied().withAlpha(0).toArgb();
    }

    /// `setPixel` keeps the pixel's EXISTING alpha and replaces only the
    /// colour — it is not `setPixel32` with 0xFF.
    pub fn setPixel(self: *BitmapData, x: i64, y: i64, rgb: u32) void {
        if (!self.inBounds(x, y)) return;
        const old = self.get(x, y).toUnmultiplied();
        const c = Color.fromArgb((rgb & 0x00FF_FFFF) | (@as(u32, old.a) << 24));
        self.set(x, y, c.toPremultiplied(self.transparency));
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the fill colour survives the premultiply round-trip the way Flash's does" {
    var b = try BitmapData.init(testing.allocator, 2, 2, true, 0xAABBCCDD);
    defer b.deinit(testing.allocator);
    // Flash reports 0xaabbccdc, not 0xaabbccdd: the blue channel loses one
    // going through premultiplication (corpus bitmap_data_thorough/constructor).
    try testing.expectEqual(@as(u32, 0xAABBCCDC), b.getPixel32(0, 0));
}

test "an opaque bitmap forces alpha to 255" {
    var b = try BitmapData.init(testing.allocator, 1, 1, false, 0x12345678);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xFF345678), b.getPixel32(0, 0));
}

test "setPixel keeps the alpha that was there" {
    var b = try BitmapData.init(testing.allocator, 1, 1, true, 0x80000000);
    defer b.deinit(testing.allocator);
    b.setPixel(0, 0, 0xFF0000);
    try testing.expectEqual(@as(u32, 0x80), b.getPixel32(0, 0) >> 24);
}

test "out of bounds reads zero and writes nothing" {
    var b = try BitmapData.init(testing.allocator, 1, 1, true, 0xFFFFFFFF);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), b.getPixel32(5, 5));
    b.setPixel32(5, 5, 0xFF00FF00);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), b.getPixel32(0, 0));
}
