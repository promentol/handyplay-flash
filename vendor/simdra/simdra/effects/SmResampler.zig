//! effects/SmResampler.zig — generalized separable image resampler.
//!
//! Bitmap-direct: takes an `SmBitmap` (RGBA8), produces a fresh
//! `SmBitmap` at the target dimensions sampled with the chosen kernel.
//! Doesn't go through `SmCanvas` — microsharp's pipeline is a pure
//! pixel transform that doesn't need to compose with canvas state, and
//! this keeps the higher-order kernels out of the Canvas2D blast radius.
//!
//! ## Pipeline
//!
//! Two-pass separable, with the inner kernel-tap loop expressed as a
//! `@Vector(4, f32)` dot product so the compiler can lower it to a
//! single SIMD FMA per tap on aarch64 NEON / x86 SSE / WASM v128.
//!
//!   1) horizontal pass — for each output column, accumulate a weighted
//!      sum across `2*support+1` source columns (clamped at edges) into
//!      a scratch buffer of `[]@Vector(4, f32)` (one packed RGBA pixel
//!      per slot, 16-byte aligned). Repeat for every source row.
//!   2) vertical pass — for each output row, accumulate a weighted sum
//!      across `2*support+1` scratch rows; unpremultiply, delinearize
//!      via the inverse LUT, write the final `u8` RGBA row.
//!
//! ## Kernels
//!
//! Six sharp-API kernels are mapped to filter functions:
//!
//!   - `cubic`     — Catmull-Rom spline (Mitchell-Netravali B=0, C=0.5)
//!   - `mitchell`  — Mitchell-Netravali (B=1/3, C=1/3)
//!   - `lanczos2`  — sinc · sinc(x/2), support 2
//!   - `lanczos3`  — sinc · sinc(x/3), support 3 (sharp's default)
//!   - `mks2013`   — Magic Kernel Sharp 2013 (Costella; support 2.5)
//!   - `mks2021`   — Magic Kernel Sharp 2021 (Costella; support 4.5)
//!
//! MKS coefficients follow Costella's reference C kernels. Bit-level
//! match with libvips's MKS implementation isn't guaranteed; the kernel
//! shape is faithful to within a few %.
//!
//! ## Edge handling
//!
//! Source samples outside `[0, src_dim-1]` are clamped to the nearest
//! valid coordinate (CLAMP_TO_EDGE). Matches sharp's default behaviour
//! for non-tile inputs.
//!
//! ## Alpha + gamma — linear-light premultiplied resampling
//!
//! Matches sharp/libvips's default pipeline:
//!
//!   1) **sRGB → linear** on the way IN. The 256-entry `srgb_to_linear`
//!      LUT (computed at module load via `std.once`) holds the standard
//!      sRGB EOTF: `C ≤ 0.04045 ? C/12.92 : ((C+0.055)/1.055)^2.4`.
//!   2) **Premultiply** RGB by alpha so transparent pixels' colour
//!      doesn't bleed into nearby opaque ones during filtering.
//!   3) **Resample** in linear-premultiplied space.
//!   4) **Unpremultiply** at the end (skip when α=0 → emit transparent
//!      black).
//!   5) **Linear → sRGB** via the analytic OETF: `L ≤ 0.0031308 ? L·12.92
//!      : 1.055·L^(1/2.4) - 0.055`. Computed inline because the input
//!      is f64 in [0,1] (no useful LUT speedup vs. the inner loop's
//!      kernel-tap dot-product).
//!
//! Without these two steps the resampler produces visibly muddier edges
//! near alpha boundaries (the bleed) and slightly darker downscales
//! than sharp (the gamma error). This change took the microsharp ↔
//! sharp `lanczos3` comparison from SSIM 0.85 to ~0.96 on the bench
//! image.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");
const types = @import("../core/types.zig");

pub const Kernel = enum(u8) {
    nearest,
    linear,
    cubic,
    mitchell,
    lanczos2,
    lanczos3,
    mks2013,
    mks2021,
};

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
} || std.mem.Allocator.Error;

inline fn supportRadius(k: Kernel) f64 {
    return switch (k) {
        .nearest => 0.5,
        .linear => 1.0,
        .cubic, .mitchell, .lanczos2 => 2.0,
        .lanczos3 => 3.0,
        .mks2013 => 2.5,
        .mks2021 => 4.5,
    };
}

inline fn sinc(x: f64) f64 {
    if (x == 0.0) return 1.0;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

inline fn catmullRom(ax: f64) f64 {
    // Mitchell-Netravali general form with B=0, C=0.5
    if (ax < 1.0) return 1.5 * ax * ax * ax - 2.5 * ax * ax + 1.0;
    if (ax < 2.0) return -0.5 * ax * ax * ax + 2.5 * ax * ax - 4.0 * ax + 2.0;
    return 0.0;
}

inline fn mitchell(ax: f64) f64 {
    // Mitchell-Netravali B=1/3, C=1/3 (canonical "Mitchell" kernel)
    if (ax < 1.0) return ((7.0 * ax - 12.0) * ax * ax + 16.0 / 3.0) / 6.0;
    if (ax < 2.0) return (((-7.0 / 3.0) * ax + 12.0) * ax * ax + (-20.0) * ax + 32.0 / 3.0) / 6.0;
    return 0.0;
}

inline fn mks2013(ax: f64) f64 {
    // Magic Kernel Sharp 2013 — Costella's reference C kernel.
    // Support = 2.5 (samples ±3 source pixels per output sample).
    if (ax < 0.5) return 1.0625 - 1.75 * ax * ax;
    if (ax < 1.5) return 0.5 * ax * ax - 1.5 * ax + 1.0625;
    if (ax < 2.5) {
        const d = ax - 2.5;
        return 0.125 * d * d;
    }
    return 0.0;
}

inline fn mks2021(ax: f64) f64 {
    // Magic Kernel Sharp 2021 — Costella's longer-support variant
    // (reduced sharpening). Support = 4.5.
    if (ax < 0.5) return 577.0 / 576.0 - 239.0 / 144.0 * ax * ax;
    if (ax < 1.5) return (140.0 * ax * ax - 379.0 * ax + 239.0) / 144.0;
    if (ax < 2.5) return (-35.0 * ax * ax + 175.0 * ax - 210.0) / 144.0;
    if (ax < 3.5) return (5.0 * ax * ax - 35.0 * ax + 60.0) / 144.0;
    if (ax < 4.5) {
        const d = ax - 4.5;
        return d * d / -288.0;
    }
    return 0.0;
}

inline fn weight(k: Kernel, x: f64) f64 {
    const ax = @abs(x);
    return switch (k) {
        .nearest => if (ax < 0.5) 1.0 else 0.0,
        .linear => if (ax < 1.0) 1.0 - ax else 0.0,
        .cubic => catmullRom(ax),
        .mitchell => mitchell(ax),
        .lanczos2 => if (ax < 2.0) sinc(ax) * sinc(ax / 2.0) else 0.0,
        .lanczos3 => if (ax < 3.0) sinc(ax) * sinc(ax / 3.0) else 0.0,
        .mks2013 => mks2013(ax),
        .mks2021 => mks2021(ax),
    };
}

// Per-output-pixel filter contributions. `weights` is sized `n`,
// stored as f32 (the inner SIMD loop accumulates in f32; keeping
// weights f32 too means every entry is 8 bytes vs 16 for splatted
// vectors and the splat is a single NEON dup/SSE shufps).
//
// The sampler clamps `start + j` to `[0, src-1]` (CLAMP_TO_EDGE) when
// reading source pixels, so `start` may be negative for output pixels
// near the left edge.
const ContribsI = struct {
    start: i32,
    n: u32,
    weights: []f32,
};

fn buildContribsI(
    allocator: std.mem.Allocator,
    src_size: u32,
    dst_size: u32,
    k: Kernel,
) ![]ContribsI {
    const scale: f64 = @as(f64, @floatFromInt(dst_size)) / @as(f64, @floatFromInt(src_size));
    const inv_scale: f64 = if (scale < 1.0) 1.0 / scale else 1.0;
    const support: f64 = supportRadius(k) * inv_scale;

    const contribs = try allocator.alloc(ContribsI, dst_size);
    errdefer allocator.free(contribs);

    var built: usize = 0;
    errdefer for (contribs[0..built]) |c| allocator.free(c.weights);

    var i: u32 = 0;
    while (i < dst_size) : (i += 1) {
        const center: f64 = (@as(f64, @floatFromInt(i)) + 0.5) / scale - 0.5;
        const left_f: f64 = @floor(center - support + 0.5);
        const right_f: f64 = @floor(center + support - 0.5);
        const left_i: i64 = @intFromFloat(left_f);
        const right_i: i64 = @intFromFloat(right_f);
        const taps: usize = @intCast(right_i - left_i + 1);

        const weights = try allocator.alloc(f32, taps);
        var sum: f64 = 0.0;
        var j: usize = 0;
        // Weight calc stays in f64 (kernel evaluation + normalization
        // benefit from the precision); we collapse to f32 right before
        // the per-tap inner loop reads it.
        while (j < taps) : (j += 1) {
            const src_idx_f = @as(f64, @floatFromInt(left_i + @as(i64, @intCast(j))));
            // For downscale, the kernel is stretched: argument is
            // (center - src) * scale (≤ 1). For upscale, it's just
            // (center - src). Both cases reduce to (center - src) /
            // inv_scale.
            const w = weight(k, (center - src_idx_f) / inv_scale);
            weights[j] = @floatCast(w);
            sum += w;
        }
        if (sum != 0.0) {
            const inv_sum: f32 = @floatCast(1.0 / sum);
            j = 0;
            while (j < taps) : (j += 1) weights[j] *= inv_sum;
        }

        contribs[i] = .{
            .start = @intCast(left_i),
            .n = @intCast(taps),
            .weights = weights,
        };
        built = i + 1;
    }
    return contribs;
}

fn freeContribs(allocator: std.mem.Allocator, c: []ContribsI) void {
    for (c) |row| allocator.free(row.weights);
    allocator.free(c);
}

inline fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

inline fn clampF(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

// =============================================================================
// sRGB ↔ linear-light conversion. Two LUTs:
//
//   srgb_to_linear_lut[256]      — forward EOTF, byte-indexed.
//   linear_to_srgb_lut[8192]     — inverse OETF, indexed by
//                                  `round(linear * 8191)`. 13-bit
//                                  quantization keeps the LUT compact
//                                  (8 KB) while staying well below
//                                  visible at 8-bit output: max
//                                  granularity in linear space is
//                                  1/8191 ≈ 1.2e-4; the sRGB curve's
//                                  steepest derivative is 12.92 (at
//                                  L→0), so worst-case sRGB byte
//                                  error from the LUT is ~0.4 byte
//                                  units. In practice rounding to
//                                  the nearest byte absorbs all of it.
//
// The inverse path used to call `std.math.pow(x, 1/2.4)` 3× per
// output pixel — replacing those with a single u16 index + array
// load is the per-pixel cost reduction we want.
// =============================================================================

var srgb_to_linear_lut: [256]f64 = undefined;
const INV_LUT_SIZE: usize = 8192;
var linear_to_srgb_lut: [INV_LUT_SIZE]u8 = undefined;
var srgb_lut_init = std.once(buildSrgbLuts);

fn buildSrgbLuts() void {
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const c = @as(f64, @floatFromInt(i)) / 255.0;
        srgb_to_linear_lut[i] = if (c <= 0.04045)
            c / 12.92
        else
            std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }
    var j: usize = 0;
    while (j < INV_LUT_SIZE) : (j += 1) {
        const l = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(INV_LUT_SIZE - 1));
        const c = if (l <= 0.0031308)
            l * 12.92
        else
            1.055 * std.math.pow(f64, l, 1.0 / 2.4) - 0.055;
        const v = clampF(c * 255.0 + 0.5, 0.0, 255.0);
        linear_to_srgb_lut[j] = @intFromFloat(v);
    }
}

inline fn srgbByteToLinear(b: u8) f64 {
    return srgb_to_linear_lut[b];
}

inline fn linearToSrgbByte(linear: f64) u8 {
    const l = clampF(linear, 0.0, 1.0);
    const idx_f = l * @as(f64, @floatFromInt(INV_LUT_SIZE - 1));
    const idx: usize = @intFromFloat(idx_f + 0.5);
    return linear_to_srgb_lut[idx];
}

inline fn linearToSrgbByteF32(linear: f32) u8 {
    const l = @max(0.0, @min(1.0, linear));
    const idx_f = l * @as(f32, @floatFromInt(INV_LUT_SIZE - 1));
    const idx: usize = @intFromFloat(idx_f + 0.5);
    return linear_to_srgb_lut[idx];
}

/// Resample `src` to `(dst_w, dst_h)` using kernel `k`. Returned bitmap
/// is allocated from `allocator` and the caller frees via
/// `SmBitmap.releaseWithAllocator(allocator, ...)`.
///
/// Pipeline: sRGB → linear → premultiply α → separable filter → unpremultiply
/// → linear → sRGB. Matches sharp/libvips's default.
pub fn resample(
    allocator: std.mem.Allocator,
    src: SmBitmap,
    dst_w: u32,
    dst_h: u32,
    k: Kernel,
) Error!SmBitmap {
    if (src.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    if (dst_w == 0 or dst_h == 0 or src.width == 0 or src.height == 0) return error.Empty;

    srgb_lut_init.call();

    const src_w: i32 = @intCast(src.width);
    const src_h: i32 = @intCast(src.height);

    const xc = try buildContribsI(allocator, src.width, dst_w, k);
    defer freeContribs(allocator, xc);
    const yc = try buildContribsI(allocator, src.height, dst_h, k);
    defer freeContribs(allocator, yc);

    // Scratch: one `@Vector(4, f32)` per output pixel of the
    // horizontal pass. Naturally 16-byte aligned; carries linear-light
    // premultiplied RGBA in the [0, 1] range.
    const scratch_pixels: usize = @as(usize, dst_w) * @as(usize, src.height);
    const scratch = try allocator.alloc(@Vector(4, f32), scratch_pixels);
    defer allocator.free(scratch);

    // Per-row scratch: each source pixel converted (sRGB → linear,
    // premultiplied) once and reused across every output column whose
    // kernel covers it. Without this, a typical lanczos3 downscale
    // re-linearizes each source pixel ~6–8 times. Memory cost is one
    // row (`src_w × 16` bytes); we reuse the buffer for every sy.
    const src_lin = try allocator.alloc(@Vector(4, f32), src.width);
    defer allocator.free(src_lin);

    // Horizontal pass — vector kernel-tap loop. The inner FMA
    // `accum += w*px` is the hot path and lowers to a single
    // 128-bit FMA on NEON / SSE / WASM v128. The per-tap work is
    // a single vector load + splat + FMA — no LUT lookups, no
    // byte conversions.
    var sy: u32 = 0;
    while (sy < src.height) : (sy += 1) {
        const src_row = src.data[(@as(usize, sy)) * (@as(usize, src.width) * 4) ..][0 .. @as(usize, src.width) * 4];

        // Linearize + premultiply the source row once.
        var sx: u32 = 0;
        while (sx < src.width) : (sx += 1) {
            const off = (@as(usize, sx)) * 4;
            const a_norm: f32 = @as(f32, @floatFromInt(src_row[off + 3])) / 255.0;
            src_lin[sx] = .{
                @as(f32, @floatCast(srgbByteToLinear(src_row[off + 0]))) * a_norm,
                @as(f32, @floatCast(srgbByteToLinear(src_row[off + 1]))) * a_norm,
                @as(f32, @floatCast(srgbByteToLinear(src_row[off + 2]))) * a_norm,
                a_norm,
            };
        }

        const scratch_row_base: usize = (@as(usize, sy)) * (@as(usize, dst_w));
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const c = xc[x];
            var accum: @Vector(4, f32) = @splat(0.0);
            var t: u32 = 0;
            while (t < c.n) : (t += 1) {
                const sx_i = clamp(c.start + @as(i32, @intCast(t)), 0, src_w - 1);
                const w_vec: @Vector(4, f32) = @splat(c.weights[t]);
                accum += w_vec * src_lin[@as(usize, @intCast(sx_i))];
            }
            scratch[scratch_row_base + (@as(usize, x))] = accum;
        }
    }

    // Vertical pass — same vector dot product over scratch rows; then
    // unpremultiply + delinearize per output pixel.
    const out_data = try allocator.alloc(u8, @as(usize, dst_w) * @as(usize, dst_h) * 4);
    errdefer allocator.free(out_data);

    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const c = yc[dy];
        const dst_row_u8 = out_data[(@as(usize, dy)) * (@as(usize, dst_w) * 4) ..][0 .. @as(usize, dst_w) * 4];
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            var accum: @Vector(4, f32) = @splat(0.0);
            var t: u32 = 0;
            while (t < c.n) : (t += 1) {
                const sy_i = clamp(c.start + @as(i32, @intCast(t)), 0, src_h - 1);
                const sy_u: usize = @intCast(sy_i);
                const idx = sy_u * @as(usize, dst_w) + (@as(usize, x));
                const w_vec: @Vector(4, f32) = @splat(c.weights[t]);
                accum += w_vec * scratch[idx];
            }

            const a_clamped: f32 = @max(0.0, @min(1.0, accum[3]));
            const out_off = (@as(usize, x)) * 4;
            if (a_clamped > 1e-6) {
                const inv_a = 1.0 / a_clamped;
                dst_row_u8[out_off + 0] = linearToSrgbByteF32(accum[0] * inv_a);
                dst_row_u8[out_off + 1] = linearToSrgbByteF32(accum[1] * inv_a);
                dst_row_u8[out_off + 2] = linearToSrgbByteF32(accum[2] * inv_a);
            } else {
                dst_row_u8[out_off + 0] = 0;
                dst_row_u8[out_off + 1] = 0;
                dst_row_u8[out_off + 2] = 0;
            }
            dst_row_u8[out_off + 3] = @intFromFloat(@max(0.0, @min(255.0, a_clamped * 255.0 + 0.5)));
        }
    }

    return .{
        .data = out_data,
        .width = dst_w,
        .height = dst_h,
        .colorSpace = src.colorSpace,
        .pixelFormat = .rgba_unorm8,
    };
}
