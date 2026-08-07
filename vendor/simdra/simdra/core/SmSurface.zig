//! SmSurface — owns the pixel buffer and lazily creates a SmCanvas (drawing
//! API) on demand. Mirrors Skia's `SkSurface`. The HTML5 `Canvas` class
//! (HTMLCanvasElement-shaped) lives JS-side and wraps this struct — distinct
//! concepts at distinct layers: JS `Canvas` is the page-level element;
//! Zig `SmCanvas` is the drawing API returned by `SmSurface.getCanvas()`.
//!
//! ## Allocator (post-A2)
//!
//! SmSurface is the canonical allocator owner — every Sm* type reachable
//! from a Surface (its SmCanvas, that canvas's path, scratch buffer, future
//! gradients/patterns/clip masks) inherits this allocator. JS-binding
//! factory `initDefault(w, h)` defaults to `page_allocator` so node-zigar
//! call sites don't change; pure-Zig callers (tests, embedded uses) call
//! `init(allocator, w, h)` with an explicit allocator.
//!
//! ### zigar marshalling note
//!
//! `std.mem.Allocator` carries function-pointer fields (its vtable) that
//! zigar's WASM type scanner mangles during JS↔WASM struct round-trips.
//! To keep the Allocator usable across the boundary, we heap-store the
//! Allocator value and expose only an opaque `*anyopaque` handle to zigar.
//! `getAllocator()` casts back. Same pattern `SmFont` uses for the
//! `stbtt_fontinfo` it owns.

const std = @import("std");
const simd = @import("../opts/simd.zig");
const types = @import("types.zig");
const encoder = @import("../encode/encoder.zig");
const SmCanvas = @import("SmCanvas.zig");

const SmSurface = @This();

/// Opaque handle to a heap-allocated `std.mem.Allocator`. Hidden from
/// zigar's type scanner via `*anyopaque` — see module docstring.
allocator_handle: *anyopaque,
pixels: []u32,
width: u32,
height: u32,
colorSpace: types.ColorSpace = .srgb,
/// Surface byte order (SkColorType analog). `pixels` are ALWAYS stored in
/// this order; the blitter swizzles source colors at resolution time and
/// the ImageData / encoder boundaries convert back to RGBA. The HTML5
/// facade always creates `.rgba8888` surfaces — `.bgra8888` is the
/// zero-copy libretro XRGB8888 path (Flash renderer).
color_type: types.ColorType = .rgba8888,
ctx_ptr: ?*SmCanvas = null,
/// Most recent encoded payload (PNG or JPEG bytes). One slot — encoding
/// in either format invalidates the previous. JS holds copies (the
/// `zigBytesToU8` defensive copy in `src/index.ts`) so this can be freed
/// freely on the next encode.
last_encoded: ?[]u8 = null,

/// Recover the surface's `std.mem.Allocator`. Inline so the indirect call
/// folds away when the surface is on the hot path.
pub inline fn getAllocator(self: *const SmSurface) std.mem.Allocator {
    return @as(*const std.mem.Allocator, @ptrCast(@alignCast(self.allocator_handle))).*;
}

/// init(allocator, w, h) — explicit-allocator factory. Pure-Zig callers
/// pass an arena / GPA / testing allocator here. JS callers go through
/// `initDefault` instead (node-zigar can't pass an Allocator value).
pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !SmSurface {
    const handle = try allocator.create(std.mem.Allocator);
    errdefer allocator.destroy(handle);
    handle.* = allocator;

    const pixels = try allocator.alloc(u32, @as(usize, width) * @as(usize, height));
    simd.fillU32(pixels, 0);
    return .{
        .allocator_handle = handle,
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// initDefault(w, h) — JS-binding shim. Uses `std.heap.page_allocator`,
/// matching the pre-A2 hardcoded behavior. node-zigar binds this name as
/// the JS-callable static factory; the `Canvas` constructor in
/// `src/index.ts` calls `SmSurface.initDefault(w, h)`.
pub fn initDefault(width: u32, height: u32) !SmSurface {
    return init(std.heap.page_allocator, width, height);
}

/// initWithColorType(allocator, w, h, ct) — explicit-allocator factory with
/// a surface byte order. Additive variant (existing factory arities are
/// binding-frozen).
pub fn initWithColorType(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    ct: types.ColorType,
) !SmSurface {
    var s = try init(allocator, width, height);
    s.color_type = ct;
    return s;
}

/// resize(new_w, new_h) — HTML5 spec: assigning to canvas.width/.height
/// reallocates the bitmap to transparent black AND resets the rendering
/// context state, even when the new dims equal the old. Same surface
/// pointer, same ctx_ptr identity — JS wrappers stay valid across the call.
pub fn resize(self: *SmSurface, new_width: u32, new_height: u32) !void {
    const allocator = self.getAllocator();

    if (self.last_encoded) |p| {
        allocator.free(p);
        self.last_encoded = null;
    }

    const new_pixels = try allocator.alloc(u32, @as(usize, new_width) * @as(usize, new_height));
    errdefer allocator.free(new_pixels);
    simd.fillU32(new_pixels, 0);

    allocator.free(self.pixels);
    self.pixels = new_pixels;
    self.width = new_width;
    self.height = new_height;

    if (self.ctx_ptr) |c| c.adoptResizedSurface();
}

pub fn deinit(self: *SmSurface) void {
    const allocator = self.getAllocator();
    if (self.ctx_ptr) |c| {
        c.deinit();
        allocator.destroy(c);
        self.ctx_ptr = null;
    }
    if (self.last_encoded) |p| {
        allocator.free(p);
        self.last_encoded = null;
    }
    allocator.free(self.pixels);
    self.pixels = &.{};
    // Free the heap-stored Allocator struct itself last — after its final use.
    allocator.destroy(@as(*std.mem.Allocator, @ptrCast(@alignCast(self.allocator_handle))));
}

// getCanvas() — return the SmCanvas (drawing API) bound to this surface's
// pixel buffer. Mirrors `SkSurface::getCanvas`. Repeat calls return the
// same SmCanvas (one-canvas-per-surface model — Skia's contract too).
pub fn getCanvas(self: *SmSurface) !*SmCanvas {
    if (self.ctx_ptr) |c| return c;
    const c = try self.getAllocator().create(SmCanvas);
    c.* = SmCanvas.initFromSurface(self);
    self.ctx_ptr = c;
    return c;
}

// encodePng() — encode the surface's pixel buffer as a PNG and return the
// raw bytes. JS-side wraps this with the data:image/png;base64, prefix to
// implement HTML5 toDataURL(). For zero-sized surfaces the result is empty.
pub fn encodePng(self: *SmSurface) ![]const u8 {
    const allocator = self.getAllocator();
    if (self.last_encoded) |old| {
        allocator.free(old);
        self.last_encoded = null;
    }

    if (self.width == 0 or self.height == 0) {
        const empty = try allocator.alloc(u8, 0);
        self.last_encoded = empty;
        return empty;
    }

    var scratch: ?[]u32 = null;
    defer if (scratch) |s| allocator.free(s);
    const rgba: []const u8 = try self.pixelsAsRgbaBytes(allocator, &scratch);
    const bytes = try encoder.encodePng(allocator, rgba, self.width, self.height);
    self.last_encoded = bytes;
    return bytes;
}

/// Encoders consume RGBA byte order. For `.rgba8888` this is the pixel
/// buffer as-is (zero copy); for `.bgra8888` a swizzled copy is produced
/// into `*scratch` (caller frees).
fn pixelsAsRgbaBytes(self: *const SmSurface, allocator: std.mem.Allocator, scratch: *?[]u32) ![]const u8 {
    if (self.color_type == .rgba8888) return std.mem.sliceAsBytes(self.pixels);
    const copy = try allocator.alloc(u32, self.pixels.len);
    simd.swizzleRBCopyU32(copy, self.pixels);
    scratch.* = copy;
    return std.mem.sliceAsBytes(copy);
}

// encodeJpeg(quality) — encode the surface's pixel buffer as a JPEG.
// `quality` is stb's 1–100 scale; the JS `toDataURL('image/jpeg', q)`
// path maps the HTML5 0.0–1.0 range. Empty surfaces return empty bytes.
pub fn encodeJpeg(self: *SmSurface, quality: u8) ![]const u8 {
    const allocator = self.getAllocator();
    if (self.last_encoded) |old| {
        allocator.free(old);
        self.last_encoded = null;
    }

    if (self.width == 0 or self.height == 0) {
        const empty = try allocator.alloc(u8, 0);
        self.last_encoded = empty;
        return empty;
    }

    var scratch: ?[]u32 = null;
    defer if (scratch) |s| allocator.free(s);
    const rgba: []const u8 = try self.pixelsAsRgbaBytes(allocator, &scratch);
    const bytes = try encoder.encodeJpeg(allocator, rgba, self.width, self.height, quality);
    self.last_encoded = bytes;
    return bytes;
}
