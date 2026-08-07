//! effects/SmMorphology.zig — morphological + median ops.
//!
//! Backs sharp's `dilate(width)`, `erode(width)`, and `median(size)`.
//!
//! Conventions:
//!   - All ops operate on RGBA8 bitmaps and return a freshly
//!     page-allocated RGBA8 bitmap.
//!   - **RGB-only**: the morphological / median operation runs on R, G, B
//!     per-channel; α is preserved untouched. Sharp's libvips behaviour
//!     for vips_morph / vips_median operates on multi-band greyscale
//!     too; we keep the alpha sharp because the common case (icon
//!     thickening, salt-and-pepper noise removal) doesn't expect alpha
//!     erosion/dilation to leak into the result.
//!   - Edge mode is **clamp** (sample the nearest in-bounds pixel
//!     when the kernel extends past the bitmap border).
//!
//! Both dilate/erode use a per-row / per-column scalar scan rather
//! than the deque-based monotonic O(n) variant. With sharp's typical
//! `width` of 1–5 pixels the difference is negligible at the data
//! sizes we care about; the simple loop keeps the code small and
//! makes per-channel SIMDifying easy in a follow-up.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidWidth,
    InvalidSize,
} || std.mem.Allocator.Error;

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

/// dilate(src, width) — separable max-window expansion of foreground
/// objects. `width` is the per-side radius (sharp's parameter
/// matches libvips). Resulting kernel is a `(2·width+1)`-square.
pub fn dilate(src: SmBitmap, width: u32) Error!SmBitmap {
    return runMorph(src, width, .max);
}

/// erode(src, width) — separable min-window shrinking. Same shape as
/// `dilate`, opposite operation.
pub fn erode(src: SmBitmap, width: u32) Error!SmBitmap {
    return runMorph(src, width, .min);
}

const MorphOp = enum(u8) { max, min };

fn runMorph(src: SmBitmap, radius: u32, op: MorphOp) Error!SmBitmap {
    try check(src);
    if (radius == 0) {
        // No-op morphology — copy through (sharp accepts width ≥ 0).
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }
    if (radius > 250) return error.InvalidWidth;

    const w = src.width;
    const h = src.height;
    const total: usize = @as(usize, w) * @as(usize, h);
    const allocator = std.heap.page_allocator;

    // Working buffers: per-channel u8 pre/post horizontal pass +
    // a deque scratch big enough for the longer of the two passes.
    const deque_cap: usize = @max(@as(usize, w), @as(usize, h));
    const scratch = try allocator.alloc(u8, total * 6 + deque_cap * @sizeOf(u32));
    defer allocator.free(scratch);

    const ch_r = scratch[0..total];
    const ch_g = scratch[total .. 2 * total];
    const ch_b = scratch[2 * total .. 3 * total];
    const tmp_r = scratch[3 * total .. 4 * total];
    const tmp_g = scratch[4 * total .. 5 * total];
    const tmp_b = scratch[5 * total .. 6 * total];
    const deque_buf: []u32 = @as([*]u32, @ptrCast(@alignCast(scratch[6 * total ..].ptr)))[0..deque_cap];

    // Split RGBA into per-channel byte buffers.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const off = i * 4;
        ch_r[i] = src.data[off + 0];
        ch_g[i] = src.data[off + 1];
        ch_b[i] = src.data[off + 2];
    }

    // Horizontal pass into tmp_*.
    morphPassH(tmp_r, ch_r, w, h, radius, op, deque_buf);
    morphPassH(tmp_g, ch_g, w, h, radius, op, deque_buf);
    morphPassH(tmp_b, ch_b, w, h, radius, op, deque_buf);

    // Vertical pass back into ch_* (final).
    morphPassV(ch_r, tmp_r, w, h, radius, op, deque_buf);
    morphPassV(ch_g, tmp_g, w, h, radius, op, deque_buf);
    morphPassV(ch_b, tmp_b, w, h, radius, op, deque_buf);

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

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

/// morphPassH — sliding-window 1D max/min over each row using a
/// monotonic deque. O(W) per row regardless of `radius` (vs O(W·R)
/// for the naïve scan). Edges are handled by clamping the right-add
/// inside the bounds check and clamping the left-evict via index
/// comparison.
inline fn morphPassH(
    dst: []u8,
    src: []const u8,
    w: u32,
    h: u32,
    radius: u32,
    op: MorphOp,
    deque: []u32,
) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row_off = @as(usize, y) * @as(usize, w);
        morphLine1D(dst[row_off..][0..w], src[row_off..][0..w], w, radius, op, deque);
    }
}

/// morphPassV — same shape as morphPassH but striding by `w` between
/// successive samples to walk down columns. Reuses the same 1D deque
/// kernel.
inline fn morphPassV(
    dst: []u8,
    src: []const u8,
    w: u32,
    h: u32,
    radius: u32,
    op: MorphOp,
    deque: []u32,
) void {
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        morphLineStrided(dst, src, x, @as(usize, w), h, radius, op, deque);
    }
}

/// morphLine1D — monotonic-deque max/min over a contiguous u8 slice.
/// `dst.len == src.len == n`. The deque stores indices into `src`
/// such that values are monotonically non-increasing (max) or
/// non-decreasing (min) from front to back. Front index is always
/// the answer for the current window.
inline fn morphLine1D(
    dst: []u8,
    src: []const u8,
    n: u32,
    radius: u32,
    op: MorphOp,
    deque: []u32,
) void {
    var front: usize = 0;
    var back: usize = 0;
    const r_i: i64 = @intCast(radius);

    // Pre-fill: add src[0..min(radius, n-1)] to the deque so the first
    // output (window covers [-radius, radius] clamped) sees them.
    var i: u32 = 0;
    const prefill = @min(radius, n - 1);
    while (i <= prefill) : (i += 1) {
        // Pop monotone-violating entries off the back.
        while (back > front and switch (op) {
            .max => src[deque[back - 1]] <= src[i],
            .min => src[deque[back - 1]] >= src[i],
        }) back -= 1;
        deque[back] = i;
        back += 1;
    }

    var x: u32 = 0;
    while (x < n) : (x += 1) {
        // Add the right edge of the window if it's a new index.
        const new_i_signed: i64 = @as(i64, @intCast(x)) + r_i;
        if (new_i_signed > @as(i64, @intCast(prefill)) and new_i_signed < @as(i64, @intCast(n))) {
            const new_i: u32 = @intCast(new_i_signed);
            while (back > front and switch (op) {
                .max => src[deque[back - 1]] <= src[new_i],
                .min => src[deque[back - 1]] >= src[new_i],
            }) back -= 1;
            deque[back] = new_i;
            back += 1;
        }
        // Evict any front entries that fell out of the window's left edge.
        const left_signed: i64 = @as(i64, @intCast(x)) - r_i;
        while (front < back and @as(i64, @intCast(deque[front])) < left_signed) front += 1;
        dst[x] = src[deque[front]];
    }
}

/// morphLineStrided — vertical-pass equivalent. Walks `n` samples
/// along `src[col + k*row_stride]` and writes to `dst[col + k*row_stride]`.
/// Otherwise identical to morphLine1D (could share code via a
/// small abstraction; kept inline for the no-deref-overhead form).
inline fn morphLineStrided(
    dst: []u8,
    src: []const u8,
    col: u32,
    row_stride: usize,
    n: u32,
    radius: u32,
    op: MorphOp,
    deque: []u32,
) void {
    const colu: usize = col;
    var front: usize = 0;
    var back: usize = 0;
    const r_i: i64 = @intCast(radius);

    var i: u32 = 0;
    const prefill = @min(radius, n - 1);
    while (i <= prefill) : (i += 1) {
        const sv = src[@as(usize, i) * row_stride + colu];
        while (back > front and switch (op) {
            .max => src[@as(usize, deque[back - 1]) * row_stride + colu] <= sv,
            .min => src[@as(usize, deque[back - 1]) * row_stride + colu] >= sv,
        }) back -= 1;
        deque[back] = i;
        back += 1;
    }

    var x: u32 = 0;
    while (x < n) : (x += 1) {
        const new_i_signed: i64 = @as(i64, @intCast(x)) + r_i;
        if (new_i_signed > @as(i64, @intCast(prefill)) and new_i_signed < @as(i64, @intCast(n))) {
            const new_i: u32 = @intCast(new_i_signed);
            const nv = src[@as(usize, new_i) * row_stride + colu];
            while (back > front and switch (op) {
                .max => src[@as(usize, deque[back - 1]) * row_stride + colu] <= nv,
                .min => src[@as(usize, deque[back - 1]) * row_stride + colu] >= nv,
            }) back -= 1;
            deque[back] = new_i;
            back += 1;
        }
        const left_signed: i64 = @as(i64, @intCast(x)) - r_i;
        while (front < back and @as(i64, @intCast(deque[front])) < left_signed) front += 1;
        dst[@as(usize, x) * row_stride + colu] = src[@as(usize, deque[front]) * row_stride + colu];
    }
}

// ---------------------------------------------------------------------------
// median — square `size × size` window per RGB channel; α preserved.
// ---------------------------------------------------------------------------

/// median(src, size) — `size × size` window median per RGB channel.
/// `size` defaults to 3 in sharp; must be odd and ≥ 1. We don't accept
/// even sizes (the median of an even-count window is interpolative,
/// and libvips's vips_median itself enforces odd).
pub fn median(src: SmBitmap, size: u32) Error!SmBitmap {
    try check(src);
    if (size == 0 or (size & 1) == 0) return error.InvalidSize;
    if (size > 99) return error.InvalidSize; // sharp accepts only sensible sizes

    if (size == 1) {
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    const w = src.width;
    const h = src.height;
    const half: u32 = size / 2;
    const window: usize = @as(usize, size) * @as(usize, size);

    const allocator = std.heap.page_allocator;
    const buf_r = try allocator.alloc(u8, window);
    defer allocator.free(buf_r);
    const buf_g = try allocator.alloc(u8, window);
    defer allocator.free(buf_g);
    const buf_b = try allocator.alloc(u8, window);
    defer allocator.free(buf_b);

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    const w_max: i64 = @intCast(w - 1);
    const h_max: i64 = @intCast(h - 1);
    const half_i: i64 = @intCast(half);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var n: usize = 0;
            var ky: i64 = -half_i;
            while (ky <= half_i) : (ky += 1) {
                const sy_i: i64 = @as(i64, @intCast(y)) + ky;
                const sy: u32 = @intCast(@max(0, @min(h_max, sy_i)));
                var kx: i64 = -half_i;
                while (kx <= half_i) : (kx += 1) {
                    const sx_i: i64 = @as(i64, @intCast(x)) + kx;
                    const sx: u32 = @intCast(@max(0, @min(w_max, sx_i)));
                    const off = (@as(usize, sy) * @as(usize, w) + @as(usize, sx)) * 4;
                    buf_r[n] = src.data[off + 0];
                    buf_g[n] = src.data[off + 1];
                    buf_b[n] = src.data[off + 2];
                    n += 1;
                }
            }
            std.mem.sort(u8, buf_r[0..n], {}, std.sort.asc(u8));
            std.mem.sort(u8, buf_g[0..n], {}, std.sort.asc(u8));
            std.mem.sort(u8, buf_b[0..n], {}, std.sort.asc(u8));
            const off = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            out.data[off + 0] = buf_r[n / 2];
            out.data[off + 1] = buf_g[n / 2];
            out.data[off + 2] = buf_b[n / 2];
            out.data[off + 3] = src.data[off + 3];
        }
    }
    return out;
}
