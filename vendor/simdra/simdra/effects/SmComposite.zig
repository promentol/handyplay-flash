//! effects/SmComposite.zig — overlay one bitmap onto another with a
//! chosen blend mode and offset (or tiled across the base).
//!
//! Sharp's `composite([{input, blend, gravity, top, left, tile, ...}])`
//! maps onto this primitive: the JS layer materializes each overlay,
//! resolves `gravity` to (top, left) pixel offsets, and calls in once
//! per overlay in array order.
//!
//! Internally this leans on `SmCanvas` so we reuse the existing 27
//! blend mode kernels (Porter-Duff, separable + non-separable W3C
//! blends) and the optimized `drawImageAt` row blitter — there's no
//! reason to reimplement that math at the bitmap layer.
//!
//! Pipeline per call:
//!   1. SmSurface.initDefault(base.w, base.h) — fresh transparent
//!      surface, page-allocated.
//!   2. canvas.writePixels(base, 0, 0) — raw copy of base bytes (no
//!      blend, bypasses CTM / globalAlpha — exactly what we want for
//!      seeding the surface).
//!   3. canvas.blendMode = mode — set the global blend mode on the
//!      paint state. drawImageAt picks it up.
//!   4. drawImageAt(overlay, dx, dy) — once for placement mode; many
//!      times in a tile loop for tile mode.
//!   5. canvas.getImageData(0, 0, base.w, base.h) → fresh SmBitmap.
//!
//! Surface + canvas are deinit'd; only the result bitmap survives.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");
const SmSurface = @import("../core/SmSurface.zig");
const SmPaint = @import("../core/SmPaint.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
} || std.mem.Allocator.Error;

pub fn composite(
    base: SmBitmap,
    overlay: SmBitmap,
    mode: SmPaint.BlendMode,
    dx: i32,
    dy: i32,
    tile: bool,
) !SmBitmap {
    if (base.pixelFormat != .rgba_unorm8 or overlay.pixelFormat != .rgba_unorm8) {
        return error.UnsupportedPixelFormat;
    }
    if (base.width == 0 or base.height == 0) return error.Empty;
    if (overlay.width == 0 or overlay.height == 0) return error.Empty;

    var surface = try SmSurface.initDefault(base.width, base.height);
    defer surface.deinit();

    const canvas = try surface.getCanvas();
    canvas.writePixels(base, 0, 0);
    canvas.blendMode = mode;

    if (tile) {
        const ow: i32 = @intCast(overlay.width);
        const oh: i32 = @intCast(overlay.height);
        // Tile starts at the gravity-resolved (dx, dy) and wraps modulo
        // overlay dims. We seed the loop at the largest negative
        // multiple still inside [0, base) so the tile pattern aligns
        // with the requested origin.
        const start_x: i32 = @mod(dx, ow) - ow;
        const start_y: i32 = @mod(dy, oh) - oh;

        const bw: i32 = @intCast(base.width);
        const bh: i32 = @intCast(base.height);

        var ty: i32 = start_y;
        while (ty < bh) : (ty += oh) {
            var tx: i32 = start_x;
            while (tx < bw) : (tx += ow) {
                canvas.drawImageAt(overlay, @floatFromInt(tx), @floatFromInt(ty));
            }
        }
    } else {
        canvas.drawImageAt(overlay, @floatFromInt(dx), @floatFromInt(dy));
    }

    return canvas.getImageData(0, 0, @intCast(base.width), @intCast(base.height));
}
