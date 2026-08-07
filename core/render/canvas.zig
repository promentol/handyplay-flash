//! Framebuffer owner: a BGRA simdra surface sized to the SWF stage.
//! `pixels()` IS the libretro XRGB8888 framebuffer (zero-copy present —
//! that's why the surface is .bgra8888). Twips→px happens via the stage
//! transform pushed by the display-list walk (M2); frontends only ever see
//! pixels.

const std = @import("std");
const simdra = @import("simdra");

pub const Canvas = struct {
    surface: simdra.SmSurface,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Canvas {
        return .{
            .surface = try simdra.SmSurface.initWithColorType(allocator, w, h, .bgra8888),
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.surface.deinit();
    }

    pub fn ctx(self: *Canvas) !*simdra.SmCanvas {
        return self.surface.getCanvas();
    }

    /// The presentation buffer: u32 XRGB8888 little-endian (alpha byte
    /// carries surface alpha; libretro ignores it).
    pub fn pixels(self: *const Canvas) []const u32 {
        return self.surface.pixels;
    }

    pub fn width(self: *const Canvas) u32 {
        return self.surface.width;
    }
    pub fn height(self: *const Canvas) u32 {
        return self.surface.height;
    }
};

test "bgra canvas: solid fill lands as XRGB8888" {
    var c = try Canvas.init(std.testing.allocator, 4, 2);
    defer c.deinit();
    const ctx_ = try c.ctx();
    ctx_.setFillStyle(255, 0, 0, 255); // logical red
    ctx_.fillRect(0, 0, 4, 2);
    // BGRA memory bytes B,G,R,A = 0,0,255,255 → u32 LE 0xFFFF0000; masking
    // the ignored X byte gives libretro's 0x00FF0000 (red).
    for (c.pixels()) |p| {
        try std.testing.expectEqual(@as(u32, 0x00FF0000), p & 0x00FFFFFF);
    }
}

test "gradient with spread + cxform renders on the bgra surface" {
    var c = try Canvas.init(std.testing.allocator, 8, 1);
    defer c.deinit();
    const ctx_ = try c.ctx();
    var g = simdra.SmGradient.linearWithAllocator(std.testing.allocator, 0, 0, 4, 0);
    defer g.deinit();
    try g.addColorStop(0, "#000000");
    try g.addColorStop(1, "#ffffff");
    g.setSpread(.reflect);
    ctx_.setFillGradient(&g);
    ctx_.setColorTransform(.{ .mult = .{ 256, 256, 256, 256 }, .add = .{ 0, 0, 0, 0 } });
    ctx_.fillRect(0, 0, 8, 1);
    const px = c.pixels();
    // x=0 near black, x=3/x=4 mirror around the gradient end (reflect).
    try std.testing.expect((px[0] & 0xFF0000) >> 16 < 40); // R lane holds... BGRA: byte2 = R
    try std.testing.expectEqual(px[3] & 0x00FFFFFF, px[4] & 0x00FFFFFF);
}
