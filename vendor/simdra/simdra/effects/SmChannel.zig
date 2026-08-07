//! effects/SmChannel.zig — channel-level bitmap ops.
//!
//! Backs sharp's `removeAlpha`, `ensureAlpha`, `extractChannel`, and
//! `bandbool`. Each op produces a fresh page-allocated SmBitmap (the
//! pipeline pattern; the previous bitmap is released by the caller).
//!
//! All ops operate on RGBA8 bitmaps. Greyscale output (from
//! `extractChannel` and `bandbool`) is materialised as an RGBA bitmap
//! with R=G=B=L and α=255 — keeps the rest of the pipeline shape-
//! invariant and the encoder doesn't need a per-call channel-count
//! switch.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidChannel,
} || std.mem.Allocator.Error;

pub const BoolOp = enum(u8) { @"and", @"or", eor };

inline fn allocBitmap(width: u32, height: u32) Error!SmBitmap {
    const allocator = std.heap.page_allocator;
    const data = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    return .{
        .data = data,
        .width = width,
        .height = height,
        .colorSpace = .srgb,
        .pixelFormat = .rgba_unorm8,
    };
}

inline fn check(src: SmBitmap) Error!void {
    if (src.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    if (src.width == 0 or src.height == 0) return error.Empty;
}

inline fn rec601Luma(r: u8, g: u8, b: u8) u8 {
    // Same integer Rec.601 formula used by joinAlphaFromMask / SmTrim.luma8;
    // keeps the channel-op suite self-consistent.
    const ru: u32 = r;
    const gu: u32 = g;
    const bu: u32 = b;
    const l: u32 = (ru * 299 + gu * 587 + bu * 114 + 500) / 1000;
    return @intCast(@min(l, 255));
}

/// greyscale — return a copy with R=G=B=L (Rec.601 luma). Alpha is
/// preserved. Backs sharp's `greyscale()` / `grayscale()`. Sharp's docs
/// note it's a "linear operation"; for the best perceptual result on
/// sRGB input, callers should chain with a future `gamma()` op (sharp
/// parity). Today simdra computes luma directly in 8-bit sRGB space.
pub fn greyscale(src: SmBitmap) Error!SmBitmap {
    try check(src);
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        const l = rec601Luma(src.data[i + 0], src.data[i + 1], src.data[i + 2]);
        out.data[i + 0] = l;
        out.data[i + 1] = l;
        out.data[i + 2] = l;
        out.data[i + 3] = src.data[i + 3];
    }
    return out;
}

/// tint — recolour the image with the given RGB tint while keeping the
/// per-pixel luminance pattern intact. Computed as
/// `out_C = L * tint_C / 255` for `C ∈ {R, G, B}` where `L` is Rec.601
/// luma; alpha is preserved per sharp spec ("An alpha channel may be
/// present and will be unchanged by the operation"). Sharp's libvips
/// implementation does the same shaping in LAB space; this 8-bit
/// scaled-luma approximation is cheap and visibly close for the
/// monochrome-style tints sharp's docs demonstrate.
pub fn tint(src: SmBitmap, tint_r: u8, tint_g: u8, tint_b: u8) Error!SmBitmap {
    try check(src);
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        const l: u32 = rec601Luma(src.data[i + 0], src.data[i + 1], src.data[i + 2]);
        // Round-half-up multiplication: (L * tint + 127) / 255.
        out.data[i + 0] = @intCast((l * @as(u32, tint_r) + 127) / 255);
        out.data[i + 1] = @intCast((l * @as(u32, tint_g) + 127) / 255);
        out.data[i + 2] = @intCast((l * @as(u32, tint_b) + 127) / 255);
        out.data[i + 3] = src.data[i + 3];
    }
    return out;
}

/// removeAlpha — return a copy with α forced to 255 on every pixel.
/// Visibly equivalent to dropping the alpha channel; the buffer
/// remains 4-channel for pipeline-shape invariance.
pub fn removeAlpha(src: SmBitmap) Error!SmBitmap {
    try check(src);
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        out.data[i + 0] = src.data[i + 0];
        out.data[i + 1] = src.data[i + 1];
        out.data[i + 2] = src.data[i + 2];
        out.data[i + 3] = 255;
    }
    return out;
}

/// setAlphaConstant — set α to a fixed byte value. Used by sharp's
/// `ensureAlpha(α)` when called with an explicit transparency level on
/// our always-RGBA model.
pub fn setAlphaConstant(src: SmBitmap, alpha: u8) Error!SmBitmap {
    try check(src);
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        out.data[i + 0] = src.data[i + 0];
        out.data[i + 1] = src.data[i + 1];
        out.data[i + 2] = src.data[i + 2];
        out.data[i + 3] = alpha;
    }
    return out;
}

/// extractChannel — pick one channel (0=R, 1=G, 2=B, 3=A) and return a
/// greyscale bitmap with R=G=B=that channel and α=255. Sharp returns a
/// b-w (8-bit) image at this point; we use the same RGBA shape so the
/// rest of the pipeline doesn't need to learn a 1-channel format.
pub fn extractChannel(src: SmBitmap, channel: u8) Error!SmBitmap {
    try check(src);
    if (channel > 3) return error.InvalidChannel;
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        const v = src.data[i + @as(usize, channel)];
        out.data[i + 0] = v;
        out.data[i + 1] = v;
        out.data[i + 2] = v;
        out.data[i + 3] = 255;
    }
    return out;
}

/// joinAlphaFromMask — return a copy of `base` with its alpha channel
/// replaced by Rec.601 luma of `mask.RGB`. Backs sharp's
/// `joinChannel(image)` for the common-case "use this image as the new
/// alpha mask". For greyscale (R=G=B) masks the luma collapses to R, so
/// 1-channel inputs round-trip exactly. For RGB masks the conversion is
/// `0.299·R + 0.587·G + 0.114·B`.
///
/// `mask` must match `base` dimensions; throws `error.InvalidChannel`
/// (re-using the slot) for size mismatch — the caller surfaces a
/// friendlier message.
pub fn joinAlphaFromMask(base: SmBitmap, mask: SmBitmap) Error!SmBitmap {
    try check(base);
    try check(mask);
    if (mask.width != base.width or mask.height != base.height) return error.InvalidChannel;

    var out = try allocBitmap(base.width, base.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < base.data.len) : (i += 4) {
        out.data[i + 0] = base.data[i + 0];
        out.data[i + 1] = base.data[i + 1];
        out.data[i + 2] = base.data[i + 2];
        // Rec.601 integer luma. Same formula simdra uses elsewhere
        // (effects/SmTrim.zig::luma8) so the channel-op suite is
        // self-consistent.
        const r: u32 = mask.data[i + 0];
        const g: u32 = mask.data[i + 1];
        const b: u32 = mask.data[i + 2];
        const l: u32 = (r * 299 + g * 587 + b * 114 + 500) / 1000;
        out.data[i + 3] = @intCast(@min(l, 255));
    }
    return out;
}

/// bandbool — per-pixel bitwise op across **all** four bands of an
/// RGBA input (R, G, B, AND alpha). Mirrors libvips's `vips_bandbool`
/// which sharp wraps: "perform various boolean operations across the
/// bands of an image". Including alpha matters for parity — for an
/// RGBA source with α=255 (binary `0xff`):
///   - `and` is unaffected (255 & X = X)
///   - `or`  collapses to 0xff for every pixel
///   - `eor` becomes ~(R^G^B)
/// The result lands in R, G, B (broadcast) with α=255. `eor` is
/// libvips's name for XOR.
pub fn bandbool(src: SmBitmap, op: BoolOp) Error!SmBitmap {
    try check(src);
    var out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var i: usize = 0;
    while (i < src.data.len) : (i += 4) {
        const r = src.data[i + 0];
        const g = src.data[i + 1];
        const b = src.data[i + 2];
        const a = src.data[i + 3];
        const v: u8 = switch (op) {
            .@"and" => r & g & b & a,
            .@"or" => r | g | b | a,
            .eor => r ^ g ^ b ^ a,
        };
        out.data[i + 0] = v;
        out.data[i + 1] = v;
        out.data[i + 2] = v;
        out.data[i + 3] = 255;
    }
    return out;
}
