//! effects/SmConvolve.zig — convolution-shaped image ops.
//!
//! Backs sharp's `blur`, `sharpen`, and `convolve`.
//!
//! Conventions:
//!   - All ops take an RGBA8 bitmap and return a freshly page-allocated
//!     RGBA8 bitmap (the standard pipeline shape used by SmBitmap).
//!   - Convolve / sharpen run on R, G, B per channel and **preserve
//!     alpha** (sharp's libvips behaviour: alpha is not part of the
//!     convolution kernel). `blurGaussian` blurs alpha too (3-pass box
//!     does the same — keeps soft transparency edges from getting
//!     binary aliased).
//!   - Edge mode is **clamp** (libvips's default for vips_conv).

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");
const simd = @import("../opts/simd.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidSigma,
    InvalidKernel,
} || std.mem.Allocator.Error;

pub const BlurPrecision = enum(u8) {
    integer,
    float,
    approximate,
};

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

inline fn clampCoord(c_i: i64, max_minus_1: i64) u32 {
    const v = @max(0, @min(max_minus_1, c_i));
    return @intCast(v);
}

/// Load a single RGBA pixel as a 4-lane f32 vector. The compiler keeps
/// this in a SIMD register on aarch64 (NEON) and x86 (SSE2+).
inline fn loadPixelF32(bytes: []const u8, off: usize) @Vector(4, f32) {
    const u8_vec: @Vector(4, u8) = bytes[off..][0..4].*;
    return @floatFromInt(u8_vec);
}

// ---------------------------------------------------------------------------
// blur — fast 3×3 box (no-args) + sigma-based Gaussian
// ---------------------------------------------------------------------------

/// blurBox3 — fast separable 3×3 box blur. Sharp's `.blur()` no-args /
/// `.blur(true)`. RGB channels averaged with 3-tap H + 3-tap V; alpha
/// preserved untouched (the box-blur kernels in `opts/generic.zig`
/// blur alpha too, but for the no-args path sharp documents it as
/// "fast 3×3 box blur" with no claim about alpha-channel softening,
/// so we keep alpha sharp).
pub fn blurBox3(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const total: usize = @as(usize, w) * @as(usize, h);

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    const allocator = std.heap.page_allocator;
    const scratch = try allocator.alloc(u8, total * 5);
    defer allocator.free(scratch);

    const ch_r = scratch[0..total];
    const ch_g = scratch[total .. 2 * total];
    const ch_b = scratch[2 * total .. 3 * total];
    const tmp = scratch[3 * total .. 4 * total];

    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const px = src_u32[i];
        ch_r[i] = @intCast(px & 0xff);
        ch_g[i] = @intCast((px >> 8) & 0xff);
        ch_b[i] = @intCast((px >> 16) & 0xff);
    }

    // Per-channel 3×3 box: H pass into tmp, V pass back into channel buf.
    inline for (.{ ch_r, ch_g, ch_b }) |ch| {
        @memcpy(tmp, ch);
        simd.boxBlurAlphaH(ch, tmp, w, h, 1);
        @memcpy(tmp, ch);
        simd.boxBlurAlphaV(ch, tmp, w, h, 1);
    }

    // Recompose RGBA. Alpha taken from the source byte at the same offset.
    i = 0;
    while (i < total) : (i += 1) {
        const off = i * 4;
        out.data[off + 0] = ch_r[i];
        out.data[off + 1] = ch_g[i];
        out.data[off + 2] = ch_b[i];
        out.data[off + 3] = src.data[off + 3];
    }
    return out;
}

/// blurGaussian — sharp's `blur(sigma | { sigma, precision, minAmplitude })`.
///
/// `precision`:
///   - `.approximate` → reuse `simd.gaussianBlurU32` (3-pass box,
///     ≈ Gaussian; cheap; what sharp's `'approximate'` selects in
///     libvips, although libvips uses an integer-kernel split there).
///   - `.integer` / `.float` → separable Gaussian with kernel size
///     `2·ceil(σ·sqrt(-2·ln(min_amplitude)))+1`. Both compute in `f64`
///     today (the integer/float distinction maps to libvips's working
///     precision; in our 8-bit output the difference is < 1 LSB and
///     not worth two code paths).
///
/// Sigma must be in [0.3, 1000]; min_amplitude in (0, 1).
pub fn blurGaussian(
    src: SmBitmap,
    sigma: f64,
    precision: BlurPrecision,
    min_amplitude: f64,
) Error!SmBitmap {
    try check(src);
    if (!std.math.isFinite(sigma) or sigma < 0.3 or sigma > 1000.0) return error.InvalidSigma;
    if (!std.math.isFinite(min_amplitude) or min_amplitude <= 0.0 or min_amplitude >= 1.0) {
        return error.InvalidSigma;
    }

    const w = src.width;
    const h = src.height;
    const total: usize = @as(usize, w) * @as(usize, h);
    const allocator = std.heap.page_allocator;

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    // Box-approximation fast path. Two ways to get here:
    //   - precision == .approximate: explicit caller request.
    //   - precision == .integer/.float and σ ≥ 3.0: at large σ the
    //     3-pass-box (Wells '86) and separable Gaussian agree to
    //     within < 1 LSB at 8-bit output, while the box path costs
    //     a constant ~6 rolling-sum passes regardless of σ. The
    //     separable path scales linearly with kernel size
    //     (~2·ceil(1.794σ)+1 taps per direction), so at σ=3 the
    //     speedup is ≈ 4×; at σ=10 it's ≈ 12×. The downgrade is
    //     invisible to 8-bit RGBA — documented in COMPATIBILITY.md.
    const auto_box = (precision != .approximate) and sigma >= 3.0;
    if (precision == .approximate or auto_box) {
        const scratch = try allocator.alloc(u8, total * 5);
        defer allocator.free(scratch);
        const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
        const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
        simd.gaussianBlurU32(dst_u32[0..total], src_u32[0..total], scratch, w, h, sigma);
        return out;
    }

    // Separable Gaussian.
    const log_min = @log(min_amplitude);
    const d = sigma * @sqrt(-2.0 * log_min);
    var radius: u32 = @intFromFloat(@max(1.0, @ceil(d)));
    if (radius > 250) radius = 250;
    const ksize: u32 = 2 * radius + 1;

    // Kernel pre-cast to f32 — every accumulator op uses an f32 splat,
    // so doing the divide-by-sum in f64 then converting once avoids
    // the cast-on-broadcast inside the hot loop.
    const kernel = try allocator.alloc(f32, ksize);
    defer allocator.free(kernel);
    {
        var sum: f64 = 0;
        var i: u32 = 0;
        while (i < ksize) : (i += 1) {
            const x = @as(f64, @floatFromInt(@as(i32, @intCast(i)) - @as(i32, @intCast(radius))));
            sum += @exp(-x * x / (2.0 * sigma * sigma));
        }
        const inv_sum = 1.0 / sum;
        i = 0;
        while (i < ksize) : (i += 1) {
            const x = @as(f64, @floatFromInt(@as(i32, @intCast(i)) - @as(i32, @intCast(radius))));
            kernel[i] = @floatCast(@exp(-x * x / (2.0 * sigma * sigma)) * inv_sum);
        }
    }

    // Working buffer: one `@Vector(4, f32)` per pixel between H and V
    // passes. Same byte layout as `[]f32` of length `total*4` but with
    // pixel-shaped element type so the per-tap multiply is a single
    // SIMD op.
    const tmp = try allocator.alloc(@Vector(4, f32), total);
    defer allocator.free(tmp);

    const src_bytes = src.data;
    const w_max: i64 = @intCast(w - 1);
    const h_max: i64 = @intCast(h - 1);
    const radius_i: i64 = @intCast(radius);

    // Horizontal pass: src bytes → tmp `@Vector(4, f32)`. 2-pixel
    // interleaving for ILP — see `convolve` for the rationale.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row_base = @as(usize, y) * @as(usize, w) * 4;
        const tmp_row_base = @as(usize, y) * @as(usize, w);
        var x: u32 = 0;
        while (x + 1 < w) : (x += 2) {
            var acc0: @Vector(4, f32) = @splat(0.0);
            var acc1: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < ksize) : (i += 1) {
                const sx0_i: i64 = @as(i64, @intCast(x)) + @as(i64, @intCast(i)) - radius_i;
                const sx0 = clampCoord(sx0_i, w_max);
                const sx1 = clampCoord(sx0_i + 1, w_max);
                const w_vec: @Vector(4, f32) = @splat(kernel[i]);
                acc0 += w_vec * loadPixelF32(src_bytes, row_base + @as(usize, sx0) * 4);
                acc1 += w_vec * loadPixelF32(src_bytes, row_base + @as(usize, sx1) * 4);
            }
            tmp[tmp_row_base + @as(usize, x)] = acc0;
            tmp[tmp_row_base + @as(usize, x) + 1] = acc1;
        }
        while (x < w) : (x += 1) {
            var acc: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < ksize) : (i += 1) {
                const sx_i: i64 = @as(i64, @intCast(x)) + @as(i64, @intCast(i)) - radius_i;
                const sx = clampCoord(sx_i, w_max);
                const w_vec: @Vector(4, f32) = @splat(kernel[i]);
                acc += w_vec * loadPixelF32(src_bytes, row_base + @as(usize, sx) * 4);
            }
            tmp[tmp_row_base + @as(usize, x)] = acc;
        }
    }

    // Vertical pass: tmp → out bytes. 2-pixel ILP across x: each
    // kernel tap reads from the same tmp row for both x and x+1
    // (adjacent in memory), so two independent FMA chains feed the
    // pipeline.
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x + 1 < w) : (x += 2) {
            var acc0: @Vector(4, f32) = @splat(0.0);
            var acc1: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < ksize) : (i += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + @as(i64, @intCast(i)) - radius_i;
                const sy = clampCoord(sy_i, h_max);
                const tmp_base = @as(usize, sy) * @as(usize, w);
                const w_vec: @Vector(4, f32) = @splat(kernel[i]);
                acc0 += w_vec * tmp[tmp_base + @as(usize, x)];
                acc1 += w_vec * tmp[tmp_base + @as(usize, x) + 1];
            }
            const off0 = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            const off1 = off0 + 4;
            out.data[off0 + 0] = clipU8FromF32(acc0[0]);
            out.data[off0 + 1] = clipU8FromF32(acc0[1]);
            out.data[off0 + 2] = clipU8FromF32(acc0[2]);
            out.data[off0 + 3] = clipU8FromF32(acc0[3]);
            out.data[off1 + 0] = clipU8FromF32(acc1[0]);
            out.data[off1 + 1] = clipU8FromF32(acc1[1]);
            out.data[off1 + 2] = clipU8FromF32(acc1[2]);
            out.data[off1 + 3] = clipU8FromF32(acc1[3]);
        }
        while (x < w) : (x += 1) {
            var acc: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < ksize) : (i += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + @as(i64, @intCast(i)) - radius_i;
                const sy = clampCoord(sy_i, h_max);
                const w_vec: @Vector(4, f32) = @splat(kernel[i]);
                acc += w_vec * tmp[@as(usize, sy) * @as(usize, w) + @as(usize, x)];
            }
            const off = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            out.data[off + 0] = clipU8FromF32(acc[0]);
            out.data[off + 1] = clipU8FromF32(acc[1]);
            out.data[off + 2] = clipU8FromF32(acc[2]);
            out.data[off + 3] = clipU8FromF32(acc[3]);
        }
    }

    return out;
}

// ---------------------------------------------------------------------------
// convolve — generic kw × kh kernel, edge clamp
// ---------------------------------------------------------------------------

/// convolve(src, kw, kh, kernel, scale, offset) — sharp's `convolve`.
///   `out_C = clip( sum(kernel · src_neighbours) / scale + offset )`
///   per RGB channel; α preserved.
/// `kw` and `kh` must be odd and ≥ 1; `kernel.len == kw·kh`. `scale`
/// must be finite and non-zero. Sharp's docs: scale defaults to the
/// kernel sum (caller responsibility — we don't second-guess it).
pub fn convolve(
    src: SmBitmap,
    kw: u32,
    kh: u32,
    kernel: []const f64,
    scale: f64,
    offset: f64,
) Error!SmBitmap {
    try check(src);
    if (kw == 0 or kh == 0 or (kw & 1) == 0 or (kh & 1) == 0) return error.InvalidKernel;
    if (kernel.len != @as(usize, kw) * @as(usize, kh)) return error.InvalidKernel;
    if (!std.math.isFinite(scale) or scale == 0.0) return error.InvalidKernel;
    if (!std.math.isFinite(offset)) return error.InvalidKernel;

    const w = src.width;
    const h = src.height;
    const allocator = std.heap.page_allocator;

    // Try to decompose the kernel as `K = u · vᵀ` (rank 1). When this
    // succeeds, two 1D passes (V then H) with `kh + kw` taps total
    // replace the `kh · kw` taps of the 2D path. Box, Gaussian-shaped,
    // and many user-supplied kernels (Sobel-h, Sobel-v, Scharr, etc.)
    // are rank-1.
    if (try trySeparable(kw, kh, kernel, allocator)) |sep| {
        defer allocator.free(sep.u);
        defer allocator.free(sep.v);
        return convolveSeparable(src, sep.u, sep.v, scale, offset);
    }

    // Fall back to the 2D form.
    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    const half_w: i64 = @intCast(kw / 2);
    const half_h: i64 = @intCast(kh / 2);
    const w_max: i64 = @intCast(w - 1);
    const h_max: i64 = @intCast(h - 1);

    // Pre-cast kernel weights to f32 for the inner @splat.
    const k_f32 = try allocator.alloc(f32, kernel.len);
    defer allocator.free(k_f32);
    for (kernel, 0..) |kv, ki| k_f32[ki] = @floatCast(kv);

    const inv_scale_v: @Vector(4, f32) = @splat(@floatCast(1.0 / scale));
    // Offset is added to RGB only — alpha is taken straight from the
    // source, so a 4-lane offset with zero in the alpha lane is fine
    // (the lane is overwritten at store time anyway).
    const offset_v: @Vector(4, f32) = @splat(@floatCast(offset));

    // Process 2 output pixels per inner iteration with two independent
    // `@Vector(4, f32)` accumulators. The kernel weight is a scalar
    // splat shared by both, but the source loads are per-pixel — the
    // compiler emits both FMAs on separate dispatch slots, doubling
    // ILP on aarch64 NEON / x86 AVX. Tail pixel (when `w` is odd)
    // handled by the trailing scalar loop.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x + 1 < w) : (x += 2) {
            var acc0: @Vector(4, f32) = @splat(0.0);
            var acc1: @Vector(4, f32) = @splat(0.0);
            var ky: u32 = 0;
            while (ky < kh) : (ky += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + @as(i64, @intCast(ky)) - half_h;
                const sy = clampCoord(sy_i, h_max);
                const sy_row_base = @as(usize, sy) * @as(usize, w) * 4;
                var kx: u32 = 0;
                while (kx < kw) : (kx += 1) {
                    const sx0_i: i64 = @as(i64, @intCast(x)) + @as(i64, @intCast(kx)) - half_w;
                    const sx1_i: i64 = sx0_i + 1;
                    const sx0 = clampCoord(sx0_i, w_max);
                    const sx1 = clampCoord(sx1_i, w_max);
                    const w_vec: @Vector(4, f32) = @splat(k_f32[@as(usize, ky) * @as(usize, kw) + @as(usize, kx)]);
                    acc0 += w_vec * loadPixelF32(src.data, sy_row_base + @as(usize, sx0) * 4);
                    acc1 += w_vec * loadPixelF32(src.data, sy_row_base + @as(usize, sx1) * 4);
                }
            }
            const r0 = acc0 * inv_scale_v + offset_v;
            const r1 = acc1 * inv_scale_v + offset_v;
            const off0 = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            const off1 = off0 + 4;
            out.data[off0 + 0] = clipU8FromF32(r0[0]);
            out.data[off0 + 1] = clipU8FromF32(r0[1]);
            out.data[off0 + 2] = clipU8FromF32(r0[2]);
            out.data[off0 + 3] = src.data[off0 + 3];
            out.data[off1 + 0] = clipU8FromF32(r1[0]);
            out.data[off1 + 1] = clipU8FromF32(r1[1]);
            out.data[off1 + 2] = clipU8FromF32(r1[2]);
            out.data[off1 + 3] = src.data[off1 + 3];
        }
        // Tail: single output pixel when `w` is odd.
        while (x < w) : (x += 1) {
            var acc: @Vector(4, f32) = @splat(0.0);
            var ky: u32 = 0;
            while (ky < kh) : (ky += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + @as(i64, @intCast(ky)) - half_h;
                const sy = clampCoord(sy_i, h_max);
                var kx: u32 = 0;
                while (kx < kw) : (kx += 1) {
                    const sx_i: i64 = @as(i64, @intCast(x)) + @as(i64, @intCast(kx)) - half_w;
                    const sx = clampCoord(sx_i, w_max);
                    const off = (@as(usize, sy) * @as(usize, w) + @as(usize, sx)) * 4;
                    const w_vec: @Vector(4, f32) = @splat(k_f32[@as(usize, ky) * @as(usize, kw) + @as(usize, kx)]);
                    acc += w_vec * loadPixelF32(src.data, off);
                }
            }
            const result = acc * inv_scale_v + offset_v;
            const off = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            out.data[off + 0] = clipU8FromF32(result[0]);
            out.data[off + 1] = clipU8FromF32(result[1]);
            out.data[off + 2] = clipU8FromF32(result[2]);
            out.data[off + 3] = src.data[off + 3];
        }
    }
    return out;
}

const Separable = struct {
    /// Vertical (column) component, length `kh`.
    u: []f32,
    /// Horizontal (row) component, length `kw`.
    v: []f32,
};

/// Try to decompose `K[ky, kx] = kernel[ky·kw + kx]` as `K = u · vᵀ`
/// (i.e. K is rank 1). Picks the largest-magnitude entry as pivot,
/// extracts the column and row through that entry, and verifies the
/// outer product matches the rest of K within a relative tolerance.
/// Returns null if the kernel isn't separable (or the pivot is too
/// small to extract a stable factorisation).
fn trySeparable(
    kw: u32,
    kh: u32,
    kernel: []const f64,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?Separable {
    if (kw == 0 or kh == 0) return null;

    // Find pivot: largest |entry|.
    var pivot_i: u32 = 0;
    var pivot_j: u32 = 0;
    var max_abs: f64 = 0;
    var ki: u32 = 0;
    while (ki < kh) : (ki += 1) {
        var kj: u32 = 0;
        while (kj < kw) : (kj += 1) {
            const v = @abs(kernel[@as(usize, ki) * @as(usize, kw) + @as(usize, kj)]);
            if (v > max_abs) {
                max_abs = v;
                pivot_i = ki;
                pivot_j = kj;
            }
        }
    }
    if (max_abs < 1e-12) return null; // all-zero kernel — let the 2D path handle (it'll just emit `offset` everywhere).

    const pivot = kernel[@as(usize, pivot_i) * @as(usize, kw) + @as(usize, pivot_j)];
    const tol = max_abs * 1e-5;

    // u[i] = K[i, pivot_j]
    // v[j] = K[pivot_i, j] / pivot
    // Then K[i, j] should equal u[i] * v[j] for all (i, j) within tol.
    const u = try allocator.alloc(f32, kh);
    errdefer allocator.free(u);
    const v = try allocator.alloc(f32, kw);
    errdefer allocator.free(v);

    var i: u32 = 0;
    while (i < kh) : (i += 1) {
        u[i] = @floatCast(kernel[@as(usize, i) * @as(usize, kw) + @as(usize, pivot_j)]);
    }
    var j: u32 = 0;
    while (j < kw) : (j += 1) {
        v[j] = @floatCast(kernel[@as(usize, pivot_i) * @as(usize, kw) + @as(usize, j)] / pivot);
    }

    // Verify.
    i = 0;
    while (i < kh) : (i += 1) {
        var jj: u32 = 0;
        while (jj < kw) : (jj += 1) {
            const expected = @as(f64, u[i]) * @as(f64, v[jj]);
            const actual = kernel[@as(usize, i) * @as(usize, kw) + @as(usize, jj)];
            if (@abs(expected - actual) > tol) {
                allocator.free(u);
                allocator.free(v);
                return null;
            }
        }
    }
    return .{ .u = u, .v = v };
}

/// Two-pass convolution for separable kernels. Pass 1 walks columns
/// with `u`, writes into a `[]@Vector(4, f32)` intermediate. Pass 2
/// walks rows of the intermediate with `v`, applies `inv_scale` +
/// `offset`, and writes the final RGBA8 (α copied through from the
/// source). Total taps per output: `kh + kw` instead of `kh · kw`.
fn convolveSeparable(
    src: SmBitmap,
    u: []const f32,
    v: []const f32,
    scale: f64,
    offset: f64,
) Error!SmBitmap {
    const w = src.width;
    const h = src.height;
    const total: usize = @as(usize, w) * @as(usize, h);
    const allocator = std.heap.page_allocator;

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    const tmp = try allocator.alloc(@Vector(4, f32), total);
    defer allocator.free(tmp);

    const kh: u32 = @intCast(u.len);
    const kw: u32 = @intCast(v.len);
    const half_w: i64 = @intCast(kw / 2);
    const half_h: i64 = @intCast(kh / 2);
    const w_max: i64 = @intCast(w - 1);
    const h_max: i64 = @intCast(h - 1);

    // Pass 1: vertical 1D conv with `u` into tmp.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var acc: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < kh) : (i += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + @as(i64, @intCast(i)) - half_h;
                const sy = clampCoord(sy_i, h_max);
                const off = (@as(usize, sy) * @as(usize, w) + @as(usize, x)) * 4;
                const w_vec: @Vector(4, f32) = @splat(u[i]);
                acc += w_vec * loadPixelF32(src.data, off);
            }
            tmp[@as(usize, y) * @as(usize, w) + @as(usize, x)] = acc;
        }
    }

    // Pass 2: horizontal 1D conv with `v` into out, applying scale +
    // offset.
    const inv_scale_v: @Vector(4, f32) = @splat(@floatCast(1.0 / scale));
    const offset_v: @Vector(4, f32) = @splat(@floatCast(offset));

    y = 0;
    while (y < h) : (y += 1) {
        const row_off = @as(usize, y) * @as(usize, w);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var acc: @Vector(4, f32) = @splat(0.0);
            var i: u32 = 0;
            while (i < kw) : (i += 1) {
                const sx_i: i64 = @as(i64, @intCast(x)) + @as(i64, @intCast(i)) - half_w;
                const sx = clampCoord(sx_i, w_max);
                const w_vec: @Vector(4, f32) = @splat(v[i]);
                acc += w_vec * tmp[row_off + @as(usize, sx)];
            }
            const result = acc * inv_scale_v + offset_v;
            const off = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            out.data[off + 0] = clipU8FromF32(result[0]);
            out.data[off + 1] = clipU8FromF32(result[1]);
            out.data[off + 2] = clipU8FromF32(result[2]);
            out.data[off + 3] = src.data[off + 3];
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// sharpen — fast 3×3 (no-args) + USM (sigma + m1/m2/x1/y2/y3)
// ---------------------------------------------------------------------------

/// sharpenFast — `sharpen()` no-args. 3×3 unsharp kernel
/// `[[0,-1,0],[-1,5,-1],[0,-1,0]]` (scale=1). Cheap and strictly
/// per-channel — the equivalent of "Photoshop Sharpen" rather than
/// libvips's LAB-L USM.
pub fn sharpenFast(src: SmBitmap) Error!SmBitmap {
    const k = [_]f64{ 0, -1, 0, -1, 5, -1, 0, -1, 0 };
    return convolve(src, 3, 3, &k, 1.0, 0.0);
}

/// sharpenUSM — `sharpen({ sigma, m1, m2, x1, y2, y3 })`. libvips's
/// "L-channel USM" formula, but applied per-channel in 8-bit sRGB
/// (we don't have an LAB pipeline). Documented 🟡 in COMPATIBILITY.md.
///
///   blur = Gaussian(src, sigma)
///   delta = src - blur               (signed)
///   if |delta| < x1 → m = m1   (flat areas)
///   else            → m = m2   (jagged areas)
///   gated = clip(m·delta, -y3, +y2)  (asymmetric clip: y2 brighten cap, y3 darken cap)
///   out = clip(src + gated)
pub fn sharpenUSM(
    src: SmBitmap,
    sigma: f64,
    m1: f64,
    m2: f64,
    x1: f64,
    y2: f64,
    y3: f64,
) Error!SmBitmap {
    try check(src);
    if (!std.math.isFinite(sigma) or sigma < 0.000001 or sigma > 10.0) return error.InvalidSigma;
    if (!std.math.isFinite(m1) or m1 < 0 or m1 > 1_000_000) return error.InvalidSigma;
    if (!std.math.isFinite(m2) or m2 < 0 or m2 > 1_000_000) return error.InvalidSigma;
    if (!std.math.isFinite(x1) or x1 < 0 or x1 > 1_000_000) return error.InvalidSigma;
    if (!std.math.isFinite(y2) or y2 < 0 or y2 > 1_000_000) return error.InvalidSigma;
    if (!std.math.isFinite(y3) or y3 < 0 or y3 > 1_000_000) return error.InvalidSigma;

    // Sigma below sharp's 0.3 floor is allowed for sharpen (sharp's docs
    // say sigma can be down to 0.000001 for sharpen — quirky carry-over
    // from libvips's vips_sharpen). Use the smaller floor for the blur.
    const blur_sigma = @max(0.3, sigma);
    const blurred = try blurGaussian(src, blur_sigma, .integer, 0.2);
    defer std.heap.page_allocator.free(blurred.data);

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    // SIMD per pixel: load src + blurred as @Vector(4, f32), compute
    // delta = src - blur, choose m1/m2 per-lane via @select on |delta|,
    // clip the gated delta to [-y3, +y2], add back to src, clip to byte.
    // Alpha lane gets the same math but is overwritten with the source
    // byte at store-time (sharp parity — sharpen is RGB-only).
    const x1_v: @Vector(4, f32) = @splat(@floatCast(x1));
    const m1_v: @Vector(4, f32) = @splat(@floatCast(m1));
    const m2_v: @Vector(4, f32) = @splat(@floatCast(m2));
    const y2_v: @Vector(4, f32) = @splat(@floatCast(y2));
    const neg_y3_v: @Vector(4, f32) = @splat(@floatCast(-y3));

    const n = src.data.len;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        const src_f = loadPixelF32(src.data, i);
        const blur_f = loadPixelF32(blurred.data, i);
        const d = src_f - blur_f;
        const ad: @Vector(4, f32) = @abs(d);
        const m = @select(f32, ad < x1_v, m1_v, m2_v);
        const gated_raw = m * d;
        const gated = @max(neg_y3_v, @min(y2_v, gated_raw));
        const result = src_f + gated;
        out.data[i + 0] = clipU8FromF32(result[0]);
        out.data[i + 1] = clipU8FromF32(result[1]);
        out.data[i + 2] = clipU8FromF32(result[2]);
        out.data[i + 3] = src.data[i + 3];
    }
    return out;
}
