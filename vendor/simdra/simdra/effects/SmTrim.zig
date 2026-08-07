//! effects/SmTrim.zig — bounding-box scans for sharp's `.trim()` and
//! the content-aware crop strategies used by `position: 'entropy' |
//! 'attention'` in `.resize({ fit: 'cover' })`.
//!
//! Operates on `SmBitmap` (RGBA8). Read-only — produces rectangle
//! coordinates; the actual sub-rect copy is `SmBitmap.extract` (in
//! `core/SmBitmap.zig`).

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Rect = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,
};

pub const Strategy = enum(u8) { entropy, attention };

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    NoContent,
};

inline fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Find the tight bounding box of pixels that differ from `bg` by more
/// than `threshold` on **any** channel (max-channel-diff metric).
/// Returns `error.NoContent` when every pixel is within threshold of
/// `bg` — the caller (sharp parity) treats this as "trim to nothing"
/// and skips the op.
pub fn findOpaqueBounds(
    src: SmBitmap,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    threshold: u8,
) Error!Rect {
    if (src.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    if (src.width == 0 or src.height == 0) return error.Empty;

    const w = src.width;
    const h = src.height;

    var min_y: u32 = h;
    var max_y: u32 = 0;
    var min_x: u32 = w;
    var max_x: u32 = 0;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src.data[(@as(usize, y)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const off = (@as(usize, x)) * 4;
            const dr = absDiff(row[off + 0], bg_r);
            const dg = absDiff(row[off + 1], bg_g);
            const db = absDiff(row[off + 2], bg_b);
            const da = absDiff(row[off + 3], bg_a);
            const m = @max(@max(dr, dg), @max(db, da));
            if (m > threshold) {
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
            }
        }
    }

    if (min_y == h) return error.NoContent;

    return .{
        .left = min_x,
        .top = min_y,
        .width = max_x - min_x + 1,
        .height = max_y - min_y + 1,
    };
}

/// Pick the `target_w × target_h` window inside `src` that maximizes
/// the content score for the chosen strategy. Source must already be at
/// least the target size on both axes (microsharp's resize path scales
/// the source first — sharp does the same).
///
///   - **entropy** — Shannon entropy of the per-window luminance
///     histogram (256 bins, 8-bit Rec.601 luma). Higher = more
///     information / more "interesting" content.
///   - **attention** — saliency proxy: per-pixel local-luminance
///     variance + saturation magnitude. NO skin-tone bias. Higher =
///     more visually salient.
///
/// Both are computed via a sliding-window sum over an integral image
/// (squared-luma or saliency map) so the cost is `O(W·H)` regardless of
/// target size.
pub fn contentBounds(
    allocator: std.mem.Allocator,
    src: SmBitmap,
    target_w: u32,
    target_h: u32,
    strategy: Strategy,
) (Error || std.mem.Allocator.Error)!Rect {
    if (src.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    if (target_w == 0 or target_h == 0) return error.Empty;
    if (target_w > src.width or target_h > src.height) return error.Empty;

    const w = src.width;
    const h = src.height;
    const n: usize = @as(usize, w) * @as(usize, h);

    // Build a per-pixel score map.
    const score = try allocator.alloc(f64, n);
    defer allocator.free(score);

    switch (strategy) {
        .entropy => try entropyScoreMap(src, score),
        .attention => attentionScoreMap(src, score),
    }

    // Build a 64-bit integral image of `score` so any rectangle sum is
    // `O(1)`. `(w+1) × (h+1)` so the right/bottom column/row of zeros
    // simplifies indexing.
    const iw: usize = @as(usize, w) + 1;
    const ih: usize = @as(usize, h) + 1;
    const integ = try allocator.alloc(f64, iw * ih);
    defer allocator.free(integ);
    @memset(integ, 0.0);

    var y: usize = 1;
    while (y < ih) : (y += 1) {
        var x: usize = 1;
        var row_sum: f64 = 0.0;
        while (x < iw) : (x += 1) {
            row_sum += score[(y - 1) * @as(usize, w) + (x - 1)];
            integ[y * iw + x] = integ[(y - 1) * iw + x] + row_sum;
        }
    }

    // Sliding window: `target_w × target_h` rectangle, find the (left,
    // top) that maximizes the sum.
    const max_left: u32 = w - target_w;
    const max_top: u32 = h - target_h;

    var best_left: u32 = 0;
    var best_top: u32 = 0;
    var best_score: f64 = -1.0;

    var t: u32 = 0;
    while (t <= max_top) : (t += 1) {
        var l: u32 = 0;
        while (l <= max_left) : (l += 1) {
            const x0: usize = @as(usize, l);
            const y0: usize = @as(usize, t);
            const x1: usize = x0 + @as(usize, target_w);
            const y1: usize = y0 + @as(usize, target_h);
            const s = integ[y1 * iw + x1] - integ[y0 * iw + x1] - integ[y1 * iw + x0] + integ[y0 * iw + x0];
            if (s > best_score) {
                best_score = s;
                best_left = l;
                best_top = t;
            }
        }
    }

    return .{
        .left = best_left,
        .top = best_top,
        .width = target_w,
        .height = target_h,
    };
}

inline fn luma8(r: u8, g: u8, b: u8) u8 {
    // Rec.601 luma (matches sharp's stat path)
    const l: u32 = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114 + 500) / 1000;
    return @intCast(@min(l, 255));
}

// `entropy` strategy: per-pixel score is the negative log-probability
// of that pixel's luma bin in the global histogram. Sliding-window sum
// of these per-pixel scores ≈ Shannon entropy of the window's luma
// distribution. Tracks sharp/libvips behaviour.
fn entropyScoreMap(src: SmBitmap, score: []f64) Error!void {
    const w = src.width;
    const h = src.height;
    const n: usize = @as(usize, w) * @as(usize, h);

    // Global luma histogram.
    var hist: [256]u32 = .{0} ** 256;
    {
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const row = src.data[(@as(usize, y)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const off = (@as(usize, x)) * 4;
                const l = luma8(row[off + 0], row[off + 1], row[off + 2]);
                hist[l] += 1;
            }
        }
    }

    // Per-bin contribution: -log2(p_bin). Pixels in zero-count bins
    // can't appear, so leave that slot at 0.
    var per_bin: [256]f64 = .{0.0} ** 256;
    const total_f: f64 = @floatFromInt(n);
    for (hist, 0..) |c, i| {
        if (c == 0) continue;
        const p: f64 = @as(f64, @floatFromInt(c)) / total_f;
        per_bin[i] = -std.math.log2(p);
    }

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src.data[(@as(usize, y)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const off = (@as(usize, x)) * 4;
            const l = luma8(row[off + 0], row[off + 1], row[off + 2]);
            score[(@as(usize, y)) * @as(usize, w) + (@as(usize, x))] = per_bin[l];
        }
    }
}

// `attention` strategy: per-pixel saliency proxy. Two terms summed:
//   - local luminance variance, computed against a 3×3 mean (dropped
//     to a 3×1 + 1×3 separable approximation for speed)
//   - saturation magnitude (max(R,G,B) - min(R,G,B))
// No skin-tone bias — sharp's saturation/redness heuristic is too
// fuzzy to reverse-engineer reliably.
fn attentionScoreMap(src: SmBitmap, score: []f64) void {
    const w = src.width;
    const h = src.height;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = src.data[(@as(usize, y)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];
        // Previous and next rows, clamped to bounds.
        const py: u32 = if (y == 0) 0 else y - 1;
        const ny: u32 = if (y + 1 == h) y else y + 1;
        const prev = src.data[(@as(usize, py)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];
        const next = src.data[(@as(usize, ny)) * (@as(usize, w) * 4) ..][0 .. @as(usize, w) * 4];

        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px: u32 = if (x == 0) 0 else x - 1;
            const nx: u32 = if (x + 1 == w) x else x + 1;
            const off = (@as(usize, x)) * 4;
            const off_p = (@as(usize, px)) * 4;
            const off_n = (@as(usize, nx)) * 4;

            const c = luma8(row[off + 0], row[off + 1], row[off + 2]);
            const l = luma8(row[off_p + 0], row[off_p + 1], row[off_p + 2]);
            const r = luma8(row[off_n + 0], row[off_n + 1], row[off_n + 2]);
            const u = luma8(prev[off + 0], prev[off + 1], prev[off + 2]);
            const d = luma8(next[off + 0], next[off + 1], next[off + 2]);

            // Sum of absolute differences vs. 4 neighbours — proxy for
            // local luminance gradient magnitude.
            const grad: u32 =
                @as(u32, absDiff(c, l)) +
                @as(u32, absDiff(c, r)) +
                @as(u32, absDiff(c, u)) +
                @as(u32, absDiff(c, d));

            // Saturation: max(R,G,B) - min(R,G,B).
            const rr = row[off + 0];
            const gg = row[off + 1];
            const bb = row[off + 2];
            const mx = @max(@max(rr, gg), bb);
            const mn = @min(@min(rr, gg), bb);
            const sat: u32 = @intCast(mx - mn);

            score[(@as(usize, y)) * @as(usize, w) + (@as(usize, x))] = @floatFromInt(grad + sat);
        }
    }
}
