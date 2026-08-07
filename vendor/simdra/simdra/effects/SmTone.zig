//! effects/SmTone.zig — tone-curve and small per-pixel arithmetic ops.
//!
//! Backs sharp's `gamma`, `negate`, `linear`, `threshold`, `recomb`,
//! `flatten`, `unflatten`, and `boolean`.
//!
//! All ops operate on RGBA8 bitmaps and return a freshly page-allocated
//! RGBA8 bitmap (the standard pipeline shape used by SmBitmap).
//!
//! ## Channel semantics
//!
//! Sharp's individual ops differ on how they treat alpha; we follow
//! the spec line by line. When in doubt the rule is: per-channel ops
//! (`linear`, `threshold` with `greyscale=false`) leave α untouched
//! unless the caller explicitly opts in. `negate` defaults to also
//! negating α (sharp's default). `flatten` always emits α=255.
//! `boolean` operates on **all four channels** including α (libvips's
//! `vips_boolean` parity, matches our existing `bandbool`).

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidArgument,
    SizeMismatch,
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

inline fn clipU8(f: f64) u8 {
    if (f < 0) return 0;
    if (f > 255) return 255;
    return @intFromFloat(@round(f));
}

inline fn clipU8FromF32(f: f32) u8 {
    if (f < 0) return 0;
    if (f > 255) return 255;
    return @intFromFloat(@round(f));
}

/// Number of bytes per SIMD chunk for the byte-wise ops (negate /
/// booleanWith / threshold). 16 byte chunks = 4 RGBA pixels — natural
/// match for NEON (`v128`) and SSE2 (`m128`).
const BYTE_CHUNK = 16;
const ByteVec = @Vector(BYTE_CHUNK, u8);

/// Lane mask for "RGB lanes only" across 16-byte chunks (4 pixels).
const RGB_BYTE_MASK: @Vector(BYTE_CHUNK, bool) = .{
    true,  true,  true,  false,
    true,  true,  true,  false,
    true,  true,  true,  false,
    true,  true,  true,  false,
};

inline fn rec601Luma(r: u8, g: u8, b: u8) u8 {
    const ru: u32 = r;
    const gu: u32 = g;
    const bu: u32 = b;
    const l: u32 = (ru * 299 + gu * 587 + bu * 114 + 500) / 1000;
    return @intCast(@min(l, 255));
}

// ---------------------------------------------------------------------------
// gamma — single LUT approximation of sharp's pre-/post-resize pair
// ---------------------------------------------------------------------------

/// gamma(src, g_in, g_out) — combined gamma curve `out = (in/255)^(g_in/g_out)·255`.
/// Sharp implements this as two passes around resize (encode pre, decode
/// post); without a resize coupling we collapse to one LUT. When
/// `g_in == g_out` the LUT is identity (sharp parity). Both values must
/// be in [1.0, 3.0]. Alpha is preserved (sharp parity — gamma is a
/// luminance-domain op).
pub fn gamma(src: SmBitmap, g_in: f64, g_out: f64) Error!SmBitmap {
    try check(src);
    if (!std.math.isFinite(g_in) or g_in < 1.0 or g_in > 3.0) return error.InvalidArgument;
    if (!std.math.isFinite(g_out) or g_out < 1.0 or g_out > 3.0) return error.InvalidArgument;

    // Fast path: g_in == g_out → LUT is identity. Skip the 256-entry
    // pow build + per-pixel byte indirection. Returns a fresh bitmap
    // so applyOps's release contract still holds.
    if (g_in == g_out) {
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    var lut: [256]u8 = undefined;
    const ratio = g_in / g_out;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const x = @as(f64, @floatFromInt(i)) / 255.0;
        const y = std.math.pow(f64, x, ratio);
        lut[i] = clipU8(y * 255.0);
    }

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        out.data[p + 0] = lut[src.data[p + 0]];
        out.data[p + 1] = lut[src.data[p + 1]];
        out.data[p + 2] = lut[src.data[p + 2]];
        out.data[p + 3] = src.data[p + 3];
    }
    return out;
}

// ---------------------------------------------------------------------------
// negate — bit-invert per channel
// ---------------------------------------------------------------------------

/// negate(src, alpha) — `out_C = 255 - src_C` per RGB channel. When
/// `alpha == true` (sharp's default), α is also negated; when false,
/// α is preserved (sharp's `{ alpha: false }`).
///
/// SIMD: process 16 bytes (4 pixels) at a time. The whole-channel
/// negate is `255 - src` over a `@Vector(16, u8)`; for the
/// `alpha=false` case the alpha lanes are restored via `@select`.
pub fn negate(src: SmBitmap, alpha: bool) Error!SmBitmap {
    try check(src);
    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    const ones: ByteVec = @splat(255);
    const n = src.data.len;
    const chunks = n / BYTE_CHUNK;

    var c: usize = 0;
    while (c < chunks) : (c += 1) {
        const off = c * BYTE_CHUNK;
        const src_v: ByteVec = src.data[off..][0..BYTE_CHUNK].*;
        const inv = ones - src_v;
        const out_v: ByteVec = if (alpha) inv else @select(u8, RGB_BYTE_MASK, inv, src_v);
        out.data[off..][0..BYTE_CHUNK].* = out_v;
    }
    // Scalar tail (always a multiple of 4 in practice — total bytes
    // are pixel-aligned — but the check is essentially free).
    var p: usize = chunks * BYTE_CHUNK;
    while (p < n) : (p += 4) {
        out.data[p + 0] = 255 - src.data[p + 0];
        out.data[p + 1] = 255 - src.data[p + 1];
        out.data[p + 2] = 255 - src.data[p + 2];
        out.data[p + 3] = if (alpha) 255 - src.data[p + 3] else src.data[p + 3];
    }
    return out;
}

// ---------------------------------------------------------------------------
// linear — per-channel `a · C + b`
// ---------------------------------------------------------------------------

/// linear(src, a, b) — per-channel linear adjust. `a` and `b` are
/// 4-element arrays (one entry per RGBA channel). The JS layer
/// broadcasts sharp's number / length-3 / length-4 forms into this
/// fixed shape (alpha entry is `a=1, b=0` when the caller omitted
/// alpha — sharp parity for the per-channel form).
///
/// SIMD: per-pixel `@Vector(4, f32)` FMA `a·C + b`, lane-clamped to
/// [0, 255]. The compiler emits a single FMA on aarch64 (NEON `fmla`)
/// and AVX2.
pub fn linear(src: SmBitmap, a: [4]f64, b: [4]f64) Error!SmBitmap {
    try check(src);

    // Fast path: a == [1,1,1,1] && b == [0,0,0,0] → identity. Default
    // microsharp args and explicit `linear(1, 0)` calls land here; skip
    // the per-pixel f32 round-trip.
    if (a[0] == 1.0 and a[1] == 1.0 and a[2] == 1.0 and a[3] == 1.0 and
        b[0] == 0.0 and b[1] == 0.0 and b[2] == 0.0 and b[3] == 0.0)
    {
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    const a_v: @Vector(4, f32) = .{
        @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]), @floatCast(a[3]),
    };
    const b_v: @Vector(4, f32) = .{
        @floatCast(b[0]), @floatCast(b[1]), @floatCast(b[2]), @floatCast(b[3]),
    };
    const zero_v: @Vector(4, f32) = @splat(0);
    const max_v: @Vector(4, f32) = @splat(255);

    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        const u8_in: @Vector(4, u8) = src.data[p..][0..4].*;
        const f_in: @Vector(4, f32) = @floatFromInt(u8_in);
        const result = a_v * f_in + b_v;
        const clipped = @max(zero_v, @min(max_v, result));
        out.data[p + 0] = @intFromFloat(@round(clipped[0]));
        out.data[p + 1] = @intFromFloat(@round(clipped[1]));
        out.data[p + 2] = @intFromFloat(@round(clipped[2]));
        out.data[p + 3] = @intFromFloat(@round(clipped[3]));
    }
    return out;
}

// ---------------------------------------------------------------------------
// threshold — per-channel or luma-driven binary
// ---------------------------------------------------------------------------

/// threshold(src, t, greyscale) — per-channel `(C ≥ t) ? 255 : 0`.
/// When `greyscale == true` (sharp's default), Rec.601 luma is computed
/// first and broadcast to RGB; α is preserved unchanged.
///
/// SIMD: the per-channel branch processes 16 bytes at a time
/// (`@Vector(16, u8)` compare + `@select` for the per-pixel mask, with
/// the alpha lanes restored to source). The greyscale branch keeps a
/// scalar inner loop because the Rec.601 weighting mixes lanes and
/// lane-shuffling would cost more than the byte-wise math saves.
pub fn threshold(src: SmBitmap, t: u8, greyscale: bool) Error!SmBitmap {
    try check(src);
    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);
    if (greyscale) {
        var p: usize = 0;
        while (p < src.data.len) : (p += 4) {
            const l = rec601Luma(src.data[p + 0], src.data[p + 1], src.data[p + 2]);
            const v: u8 = if (l >= t) 255 else 0;
            out.data[p + 0] = v;
            out.data[p + 1] = v;
            out.data[p + 2] = v;
            out.data[p + 3] = src.data[p + 3];
        }
        return out;
    }

    const t_v: ByteVec = @splat(t);
    const all_255: ByteVec = @splat(255);
    const all_0: ByteVec = @splat(0);
    const n = src.data.len;
    const chunks = n / BYTE_CHUNK;

    var c: usize = 0;
    while (c < chunks) : (c += 1) {
        const off = c * BYTE_CHUNK;
        const src_v: ByteVec = src.data[off..][0..BYTE_CHUNK].*;
        const above = src_v >= t_v;
        const thresholded = @select(u8, above, all_255, all_0);
        // Restore alpha lanes from source.
        const out_v = @select(u8, RGB_BYTE_MASK, thresholded, src_v);
        out.data[off..][0..BYTE_CHUNK].* = out_v;
    }
    var p: usize = chunks * BYTE_CHUNK;
    while (p < n) : (p += 4) {
        out.data[p + 0] = if (src.data[p + 0] >= t) 255 else 0;
        out.data[p + 1] = if (src.data[p + 1] >= t) 255 else 0;
        out.data[p + 2] = if (src.data[p + 2] >= t) 255 else 0;
        out.data[p + 3] = src.data[p + 3];
    }
    return out;
}

// ---------------------------------------------------------------------------
// recomb — 3×3 or 4×4 colour-matrix multiply
// ---------------------------------------------------------------------------

/// recomb(src, m) — recombine each pixel via a 3×3 or 4×4 matrix.
/// `m.len == 9` → operate on RGB only, α preserved.
/// `m.len == 16` → 4×4 form, α-included.
/// Matrix is row-major: `m[row * cols + col]`.
pub fn recomb(src: SmBitmap, m: []const f64) Error!SmBitmap {
    try check(src);
    if (m.len != 9 and m.len != 16) return error.InvalidArgument;
    var i: usize = 0;
    while (i < m.len) : (i += 1) {
        if (!std.math.isFinite(m[i])) return error.InvalidArgument;
    }

    // Fast path: identity matrix (3×3 or 4×4). Common when callers
    // construct matrices programmatically and skip the diagonal.
    const ident_3x3 = m.len == 9 and
        m[0] == 1.0 and m[1] == 0.0 and m[2] == 0.0 and
        m[3] == 0.0 and m[4] == 1.0 and m[5] == 0.0 and
        m[6] == 0.0 and m[7] == 0.0 and m[8] == 1.0;
    const ident_4x4 = m.len == 16 and
        m[0] == 1.0 and m[1] == 0.0 and m[2] == 0.0 and m[3] == 0.0 and
        m[4] == 0.0 and m[5] == 1.0 and m[6] == 0.0 and m[7] == 0.0 and
        m[8] == 0.0 and m[9] == 0.0 and m[10] == 1.0 and m[11] == 0.0 and
        m[12] == 0.0 and m[13] == 0.0 and m[14] == 0.0 and m[15] == 1.0;
    if (ident_3x3 or ident_4x4) {
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    var p: usize = 0;
    if (m.len == 9) {
        // SIMD: each output channel is a 3-lane dot product
        // `row · [R, G, B]`. f32 lanes hit NEON's `fmla` / SSE FMA.
        const row0: @Vector(3, f32) = .{ @floatCast(m[0]), @floatCast(m[1]), @floatCast(m[2]) };
        const row1: @Vector(3, f32) = .{ @floatCast(m[3]), @floatCast(m[4]), @floatCast(m[5]) };
        const row2: @Vector(3, f32) = .{ @floatCast(m[6]), @floatCast(m[7]), @floatCast(m[8]) };
        while (p < src.data.len) : (p += 4) {
            const rgb: @Vector(3, f32) = .{
                @floatFromInt(src.data[p + 0]),
                @floatFromInt(src.data[p + 1]),
                @floatFromInt(src.data[p + 2]),
            };
            out.data[p + 0] = clipU8FromF32(@reduce(.Add, row0 * rgb));
            out.data[p + 1] = clipU8FromF32(@reduce(.Add, row1 * rgb));
            out.data[p + 2] = clipU8FromF32(@reduce(.Add, row2 * rgb));
            out.data[p + 3] = src.data[p + 3];
        }
    } else {
        // 4×4 form. Same shape as 3×3 with a 4-lane dot product per
        // output channel, alpha included.
        const row0: @Vector(4, f32) = .{ @floatCast(m[0]), @floatCast(m[1]), @floatCast(m[2]), @floatCast(m[3]) };
        const row1: @Vector(4, f32) = .{ @floatCast(m[4]), @floatCast(m[5]), @floatCast(m[6]), @floatCast(m[7]) };
        const row2: @Vector(4, f32) = .{ @floatCast(m[8]), @floatCast(m[9]), @floatCast(m[10]), @floatCast(m[11]) };
        const row3: @Vector(4, f32) = .{ @floatCast(m[12]), @floatCast(m[13]), @floatCast(m[14]), @floatCast(m[15]) };
        while (p < src.data.len) : (p += 4) {
            const u8_in: @Vector(4, u8) = src.data[p..][0..4].*;
            const rgba: @Vector(4, f32) = @floatFromInt(u8_in);
            out.data[p + 0] = clipU8FromF32(@reduce(.Add, row0 * rgba));
            out.data[p + 1] = clipU8FromF32(@reduce(.Add, row1 * rgba));
            out.data[p + 2] = clipU8FromF32(@reduce(.Add, row2 * rgba));
            out.data[p + 3] = clipU8FromF32(@reduce(.Add, row3 * rgba));
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// flatten — composite onto opaque background, drop alpha
// ---------------------------------------------------------------------------

/// flatten(src, bg_r, bg_g, bg_b) — `out_C = α·src_C + (1-α)·bg_C` per
/// RGB channel; α=255. Sharp's spec: "Merge alpha transparency
/// channel, if any, with a background, then remove the alpha channel."
/// The buffer remains 4-channel for pipeline-shape invariance.
///
/// SIMD: per-pixel `@Vector(3, u32)` integer alpha blend. The fourth
/// channel is set to 255 unconditionally so we don't bother including
/// it in the vector.
pub fn flatten(src: SmBitmap, bg_r: u8, bg_g: u8, bg_b: u8) Error!SmBitmap {
    try check(src);
    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    const bg_v: @Vector(3, u32) = .{ bg_r, bg_g, bg_b };
    const half_v: @Vector(3, u32) = @splat(127);

    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        const a: u32 = src.data[p + 3];
        const inv: u32 = 255 - a;
        const a_v: @Vector(3, u32) = @splat(a);
        const inv_v: @Vector(3, u32) = @splat(inv);
        const src_v: @Vector(3, u32) = .{ src.data[p + 0], src.data[p + 1], src.data[p + 2] };
        const blended = (a_v * src_v + inv_v * bg_v + half_v) / @as(@Vector(3, u32), @splat(255));
        out.data[p + 0] = @intCast(blended[0]);
        out.data[p + 1] = @intCast(blended[1]);
        out.data[p + 2] = @intCast(blended[2]);
        out.data[p + 3] = 255;
    }
    return out;
}

// ---------------------------------------------------------------------------
// unflatten — make pure-white pixels transparent
// ---------------------------------------------------------------------------

/// unflatten(src) — for every pixel where `R == G == B == 255`, set
/// α=0; other pixels are unchanged. Sharp's exact rule (libvips
/// vips_unflatten parity).
///
/// SIMD: per-pixel `@Vector(3, u8)` equality + `@reduce(.And, ...)` to
/// fold the three lanes into a single `is_white` bool. RGB are copied
/// straight via a 4-byte `@Vector(4, u8)` load/store.
pub fn unflatten(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    const ones3: @Vector(3, u8) = @splat(255);
    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        const px: @Vector(4, u8) = src.data[p..][0..4].*;
        const rgb: @Vector(3, u8) = .{ px[0], px[1], px[2] };
        const is_white = @reduce(.And, rgb == ones3);
        out.data[p + 0] = px[0];
        out.data[p + 1] = px[1];
        out.data[p + 2] = px[2];
        out.data[p + 3] = if (is_white) 0 else px[3];
    }
    return out;
}

// ---------------------------------------------------------------------------
// boolean — bitwise AND/OR/EOR between two bitmaps
// ---------------------------------------------------------------------------

/// booleanWith(base, operand, op) — per-pixel bitwise `op` between
/// `base` and `operand` across all four RGBA bands. Mirrors libvips's
/// `vips_boolean`, which sharp's `boolean(operand, operator)` wraps.
/// Both bitmaps must have the same dimensions.
///
/// SIMD: 16-byte chunks of bytewise `&` / `|` / `^`. Hits NEON's
/// `v{and,orr,eor}` and SSE's `p{and,or,xor}`.
pub fn booleanWith(base: SmBitmap, operand: SmBitmap, op: BoolOp) Error!SmBitmap {
    try check(base);
    try check(operand);
    if (base.width != operand.width or base.height != operand.height) {
        return error.SizeMismatch;
    }
    const out = try allocBitmap(base.width, base.height);
    errdefer std.heap.page_allocator.free(out.data);

    const n = base.data.len;
    const chunks = n / BYTE_CHUNK;
    var c: usize = 0;
    while (c < chunks) : (c += 1) {
        const off = c * BYTE_CHUNK;
        const a_v: ByteVec = base.data[off..][0..BYTE_CHUNK].*;
        const b_v: ByteVec = operand.data[off..][0..BYTE_CHUNK].*;
        const out_v: ByteVec = switch (op) {
            .@"and" => a_v & b_v,
            .@"or" => a_v | b_v,
            .eor => a_v ^ b_v,
        };
        out.data[off..][0..BYTE_CHUNK].* = out_v;
    }
    var p: usize = chunks * BYTE_CHUNK;
    while (p < n) : (p += 1) {
        const a = base.data[p];
        const b = operand.data[p];
        out.data[p] = switch (op) {
            .@"and" => a & b,
            .@"or" => a | b,
            .eor => a ^ b,
        };
    }
    return out;
}
