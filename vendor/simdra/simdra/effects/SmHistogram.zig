//! effects/SmHistogram.zig — histogram-based contrast ops.
//!
//! Backs sharp's `normalise` (and its alias `normalize`) and `clahe`.
//! Both ops compute a luminance distribution and remap the image
//! contrast based on it; `clahe` does so in tiles with bilinear
//! interpolation between tile centres so the equalisation stays
//! locally-adaptive without producing tile-boundary artifacts.
//!
//! Both ops preserve α.
//!
//! ## Colour preservation
//!
//! When the input/output transform is computed in luma space, we apply
//! it to the RGB triple via a multiplicative factor `factor = newL/oldL`,
//! clipped to [0, 255]. This preserves the colour ratio at the cost of
//! some clipping near pure black; sharp's libvips path does the same
//! shape internally for both ops.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidArgument,
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

inline fn rec601Luma(r: u8, g: u8, b: u8) u8 {
    const ru: u32 = r;
    const gu: u32 = g;
    const bu: u32 = b;
    const l: u32 = (ru * 299 + gu * 587 + bu * 114 + 500) / 1000;
    return @intCast(@min(l, 255));
}

inline fn clipU8FromF64(f: f64) u8 {
    if (f < 0) return 0;
    if (f > 255) return 255;
    return @intFromFloat(@round(f));
}

// ---------------------------------------------------------------------------
// normalise — global luma percentile stretch
// ---------------------------------------------------------------------------

/// normalise(src, lower_pct, upper_pct) — stretch luma so that the
/// `lower_pct`-percentile maps to 0 and the `upper_pct`-percentile maps
/// to 255. Default sharp values are 1 and 99; both must be in [0, 100]
/// with `lower < upper`.
///
/// The same affine map `(C - lo) * 255 / (hi - lo)` is applied to all
/// three RGB channels (per-pixel, not per-channel) so colour ratios are
/// preserved. α is left untouched.
pub fn normalise(src: SmBitmap, lower_pct: f64, upper_pct: f64) Error!SmBitmap {
    try check(src);
    if (!std.math.isFinite(lower_pct) or !std.math.isFinite(upper_pct)) return error.InvalidArgument;
    if (lower_pct < 0 or lower_pct >= upper_pct or upper_pct > 100) return error.InvalidArgument;

    // Build luma histogram.
    var hist: [256]u32 = .{0} ** 256;
    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        hist[rec601Luma(src.data[p + 0], src.data[p + 1], src.data[p + 2])] += 1;
    }

    const total: u64 = @as(u64, src.width) * @as(u64, src.height);
    const lo_target: u64 = @intFromFloat(@floor(@as(f64, @floatFromInt(total)) * lower_pct / 100.0));
    const hi_target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * upper_pct / 100.0));

    // Walk to find lo_luma and hi_luma.
    var cum: u64 = 0;
    var lo_luma: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        cum += hist[i];
        if (cum > lo_target) {
            lo_luma = i;
            break;
        }
    }
    cum = 0;
    var hi_luma: u32 = 255;
    i = 0;
    while (i < 256) : (i += 1) {
        cum += hist[i];
        if (cum >= hi_target) {
            hi_luma = i;
            break;
        }
    }

    if (hi_luma <= lo_luma) {
        // No usable contrast. Return an unchanged copy so the apply-loop
        // still owns a fresh page-allocated bitmap.
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    // Affine map: out = (in - lo) * 255 / (hi - lo). Build a 256-entry
    // LUT once and apply per channel.
    var lut: [256]u8 = undefined;
    const range_f: f64 = @floatFromInt(hi_luma - lo_luma);
    var k: u32 = 0;
    while (k < 256) : (k += 1) {
        const v = (@as(f64, @floatFromInt(k)) - @as(f64, @floatFromInt(lo_luma))) * 255.0 / range_f;
        lut[k] = clipU8FromF64(v);
    }

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    p = 0;
    while (p < src.data.len) : (p += 4) {
        out.data[p + 0] = lut[src.data[p + 0]];
        out.data[p + 1] = lut[src.data[p + 1]];
        out.data[p + 2] = lut[src.data[p + 2]];
        out.data[p + 3] = src.data[p + 3];
    }
    return out;
}

// ---------------------------------------------------------------------------
// CLAHE — Contrast-Limited Adaptive Histogram Equalisation
// ---------------------------------------------------------------------------

/// clahe(src, tile_w, tile_h, max_slope) — apply CLAHE to luma and
/// re-broadcast to RGB via a multiplicative factor.
///
/// `tile_w` / `tile_h` are the search-window dims in pixels; both must
/// be ≥ 1. `max_slope` ∈ [0, 100]; 0 disables the contrast clip
/// (degenerates to plain AHE), sharp's default is 3.
///
/// Algorithm (Zuiderveld 1994):
///   1. Tile the image into ⌈W/tile_w⌉ × ⌈H/tile_h⌉ tiles.
///   2. For each tile build a 256-bin luma histogram.
///   3. Clip histogram bins above `max_slope · tile_pixels / 256`,
///      redistribute the excess uniformly.
///   4. Build a per-tile CDF mapping (luma → equalised luma).
///   5. For each pixel, bilinear-interpolate between the four nearest
///      tile-centre CDFs to get the new luma.
///   6. Multiply RGB by `new_luma / old_luma` (with a small guard to
///      avoid division by zero).
pub fn clahe(
    src: SmBitmap,
    tile_w: u32,
    tile_h: u32,
    max_slope: f64,
) Error!SmBitmap {
    try check(src);
    if (tile_w == 0 or tile_h == 0) return error.InvalidArgument;
    if (!std.math.isFinite(max_slope) or max_slope < 0 or max_slope > 100) return error.InvalidArgument;

    const w = src.width;
    const h = src.height;
    const allocator = std.heap.page_allocator;

    // Tile counts (round up; the last tile may be partial).
    const n_x: u32 = (w + tile_w - 1) / tile_w;
    const n_y: u32 = (h + tile_h - 1) / tile_h;

    // Build per-tile LUT: shape [n_y][n_x][256]. Stored flat for
    // straightforward indexing.
    const tile_count: usize = @as(usize, n_x) * @as(usize, n_y);
    const luts = try allocator.alloc(u8, tile_count * 256);
    defer allocator.free(luts);

    var ty: u32 = 0;
    while (ty < n_y) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < n_x) : (tx += 1) {
            const x0 = tx * tile_w;
            const y0 = ty * tile_h;
            const x1 = @min(x0 + tile_w, w);
            const y1 = @min(y0 + tile_h, h);
            buildTileLut(src, x0, y0, x1, y1, max_slope, luts[(@as(usize, ty) * @as(usize, n_x) + @as(usize, tx)) * 256 ..][0..256]);
        }
    }

    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);

    // For each pixel, bilinear interpolate between the four tile-centre
    // CDFs surrounding it.
    const tw_f: f64 = @floatFromInt(tile_w);
    const th_f: f64 = @floatFromInt(tile_h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        // Fractional tile-y coordinate (centre at tile_h/2, etc.).
        const fy: f64 = (@as(f64, @floatFromInt(y)) + 0.5) / th_f - 0.5;
        const ty_lo_f = @floor(fy);
        const wy = fy - ty_lo_f;
        const ty_lo: i32 = @intFromFloat(ty_lo_f);
        const ty_hi: i32 = ty_lo + 1;
        const ty_lo_c: u32 = @intCast(@max(0, @min(@as(i32, @intCast(n_y - 1)), ty_lo)));
        const ty_hi_c: u32 = @intCast(@max(0, @min(@as(i32, @intCast(n_y - 1)), ty_hi)));

        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const fx: f64 = (@as(f64, @floatFromInt(x)) + 0.5) / tw_f - 0.5;
            const tx_lo_f = @floor(fx);
            const wx = fx - tx_lo_f;
            const tx_lo: i32 = @intFromFloat(tx_lo_f);
            const tx_hi: i32 = tx_lo + 1;
            const tx_lo_c: u32 = @intCast(@max(0, @min(@as(i32, @intCast(n_x - 1)), tx_lo)));
            const tx_hi_c: u32 = @intCast(@max(0, @min(@as(i32, @intCast(n_x - 1)), tx_hi)));

            const off = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            const r = src.data[off + 0];
            const g = src.data[off + 1];
            const b = src.data[off + 2];
            const old_l = rec601Luma(r, g, b);

            // Sample each of the four tile CDFs at `old_l`.
            const lut_tl = luts[(@as(usize, ty_lo_c) * @as(usize, n_x) + @as(usize, tx_lo_c)) * 256 + @as(usize, old_l)];
            const lut_tr = luts[(@as(usize, ty_lo_c) * @as(usize, n_x) + @as(usize, tx_hi_c)) * 256 + @as(usize, old_l)];
            const lut_bl = luts[(@as(usize, ty_hi_c) * @as(usize, n_x) + @as(usize, tx_lo_c)) * 256 + @as(usize, old_l)];
            const lut_br = luts[(@as(usize, ty_hi_c) * @as(usize, n_x) + @as(usize, tx_hi_c)) * 256 + @as(usize, old_l)];

            const top = @as(f64, @floatFromInt(lut_tl)) * (1 - wx) + @as(f64, @floatFromInt(lut_tr)) * wx;
            const bot = @as(f64, @floatFromInt(lut_bl)) * (1 - wx) + @as(f64, @floatFromInt(lut_br)) * wx;
            const new_l_f = top * (1 - wy) + bot * wy;

            // Apply scale factor newL / oldL (with guard for zero luma).
            if (old_l == 0) {
                // Pure black — no colour info; emit the equalised luma as grey.
                const v = clipU8FromF64(new_l_f);
                out.data[off + 0] = v;
                out.data[off + 1] = v;
                out.data[off + 2] = v;
            } else {
                const factor = new_l_f / @as(f64, @floatFromInt(old_l));
                out.data[off + 0] = clipU8FromF64(@as(f64, @floatFromInt(r)) * factor);
                out.data[off + 1] = clipU8FromF64(@as(f64, @floatFromInt(g)) * factor);
                out.data[off + 2] = clipU8FromF64(@as(f64, @floatFromInt(b)) * factor);
            }
            out.data[off + 3] = src.data[off + 3];
        }
    }
    return out;
}

fn buildTileLut(
    src: SmBitmap,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    max_slope: f64,
    lut_out: []u8,
) void {
    std.debug.assert(lut_out.len == 256);
    var hist: [256]u32 = .{0} ** 256;
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        var x: u32 = x0;
        while (x < x1) : (x += 1) {
            const off = (@as(usize, y) * @as(usize, src.width) + @as(usize, x)) * 4;
            hist[rec601Luma(src.data[off + 0], src.data[off + 1], src.data[off + 2])] += 1;
        }
    }
    const tile_pixels: u32 = (x1 - x0) * (y1 - y0);
    if (tile_pixels == 0) {
        // Empty tile (shouldn't happen given x1>x0,y1>y0). Emit an
        // identity LUT.
        var k: u32 = 0;
        while (k < 256) : (k += 1) lut_out[k] = @intCast(k);
        return;
    }

    // Clip + redistribute.
    if (max_slope > 0) {
        const clip_f = max_slope * @as(f64, @floatFromInt(tile_pixels)) / 256.0;
        const clip_lim: u32 = @intFromFloat(@max(1.0, @ceil(clip_f)));
        var excess: u32 = 0;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            if (hist[i] > clip_lim) {
                excess += hist[i] - clip_lim;
                hist[i] = clip_lim;
            }
        }
        const incr: u32 = excess / 256;
        const remainder: u32 = excess % 256;
        i = 0;
        while (i < 256) : (i += 1) hist[i] += incr;
        // Distribute the remainder one per bin from the start.
        i = 0;
        while (i < remainder) : (i += 1) hist[i] += 1;
    }

    // CDF.
    var cum: u64 = 0;
    const inv = 255.0 / @as(f64, @floatFromInt(tile_pixels));
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        cum += hist[i];
        const v = @as(f64, @floatFromInt(cum)) * inv;
        lut_out[i] = clipU8FromF64(v);
    }
}
