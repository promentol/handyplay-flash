//! encoder.zig — comptime facade picking the active PNG backend.
//!
//! PNG has two paths in tree:
//!   .stb     — encode/png_stb.zig  (stb_image_write; real DEFLATE; smaller output)
//!   .native  — encode/png.zig      (stored-block; stable across Zig versions)
//!
//! JPEG always goes through stb (no native equivalent in tree).
//!
//! ## Switching backends
//!
//! Edit `png_backend` below and rebuild (`npm test` for native dev,
//! `npm run build && npm run test:built` for the WASM bundle). This is a
//! comptime decision so both paths get dead-code-eliminated; only one
//! ends up in the artifact. Lifting this to a real `-Doption` requires
//! editing `node-zigar/zigar-compiler`'s build.zig (out-of-tree) — not
//! worth the friction for a knob that flips once per release.

const std = @import("std");

pub const PngBackend = enum { stb, native };

pub const png_backend: PngBackend = .stb;

const stb_png = @import("png_stb.zig");
const native_png = @import("png.zig");
const jpeg_enc = @import("jpeg.zig");
const bmp_enc = @import("bmp.zig");

pub fn encodePng(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    return switch (png_backend) {
        .stb => stb_png.encode(allocator, rgba, width, height),
        .native => native_png.encode(allocator, rgba, width, height),
    };
}

/// Per-call PNG compression level (stb scale, 0..9). Forces the stb backend
/// — the native stored-block fallback in `png.zig` doesn't compress at all,
/// so a level knob would be meaningless there.
pub fn encodePngWithLevel(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
    level: u8,
) ![]u8 {
    return stb_png.encodeWithLevel(allocator, rgba, width, height, level);
}

pub fn encodeJpeg(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
    quality: u8,
) ![]u8 {
    return jpeg_enc.encode(allocator, rgba, width, height, quality);
}

pub fn encodeBmp(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    return bmp_enc.encode(allocator, rgba, width, height);
}
