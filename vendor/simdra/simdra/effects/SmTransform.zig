//! effects/SmTransform.zig — geometric ops backing sharp's `rotate`,
//! `flip`, `flop`, and `affine`.
//!
//! Three families:
//!   * Lossless 90° / 180° / 270° rotation + horizontal / vertical
//!     flips. Index permutation only — no resample, byte-exact.
//!   * Arbitrary-angle rotation about the source centre. Output bbox =
//!     AABB of the rotated source rectangle; the gap around the
//!     rotated content is filled with the requested background colour.
//!   * Generalised affine transform with sharp's `idx`/`idy`/`odx`/`ody`
//!     offsets. Output bbox = forward-mapped AABB of the source.
//!
//! Sampling for arbitrary rotation and affine reuses the existing
//! `opts/simd.sampleImageNearestRow` / `sampleImageBilinearRow` row
//! kernels (the same primitives that power `core/SmCanvas.drawImageScaledSub`).
//! Pixels whose inverse-mapped source coordinate falls outside the
//! source rect are left at their pre-fill value — we seed the output
//! with the background colour first, so unsampled areas come out with
//! the right padding.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");
const simd = @import("../opts/simd.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    Singular,
} || std.mem.Allocator.Error;

pub const Interpolator = enum(u8) {
    nearest,
    bilinear,
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

inline fn packBg(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

/// rotate90 — visual 90° clockwise. Output dims swap (h × w).
/// Mapping: out(X, Y) = src(Y, h-1-X).
pub fn rotate90(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const out = try allocBitmap(h, w);
    errdefer std.heap.page_allocator.free(out.data);
    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
    var Y: u32 = 0;
    while (Y < w) : (Y += 1) {
        var X: u32 = 0;
        while (X < h) : (X += 1) {
            const sx = Y;
            const sy = h - 1 - X;
            dst_u32[@as(usize, Y) * @as(usize, h) + @as(usize, X)] =
                src_u32[@as(usize, sy) * @as(usize, w) + @as(usize, sx)];
        }
    }
    return out;
}

/// rotate180 — same dims; out(X, Y) = src(w-1-X, h-1-Y).
pub fn rotate180(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);
    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
    var Y: u32 = 0;
    while (Y < h) : (Y += 1) {
        var X: u32 = 0;
        while (X < w) : (X += 1) {
            const sx = w - 1 - X;
            const sy = h - 1 - Y;
            dst_u32[@as(usize, Y) * @as(usize, w) + @as(usize, X)] =
                src_u32[@as(usize, sy) * @as(usize, w) + @as(usize, sx)];
        }
    }
    return out;
}

/// rotate270 — visual 270° clockwise (= 90° CCW). Output dims swap (h × w).
/// Mapping: out(X, Y) = src(w-1-Y, X).
pub fn rotate270(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const out = try allocBitmap(h, w);
    errdefer std.heap.page_allocator.free(out.data);
    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
    var Y: u32 = 0;
    while (Y < w) : (Y += 1) {
        var X: u32 = 0;
        while (X < h) : (X += 1) {
            const sx = w - 1 - Y;
            const sy = X;
            dst_u32[@as(usize, Y) * @as(usize, h) + @as(usize, X)] =
                src_u32[@as(usize, sy) * @as(usize, w) + @as(usize, sx)];
        }
    }
    return out;
}

/// flipHorizontal — mirror left↔right (sharp's `flop`). Same dims.
pub fn flipHorizontal(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);
    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
    var Y: u32 = 0;
    while (Y < h) : (Y += 1) {
        const row_off = @as(usize, Y) * @as(usize, w);
        var X: u32 = 0;
        while (X < w) : (X += 1) {
            dst_u32[row_off + @as(usize, X)] = src_u32[row_off + @as(usize, w - 1 - X)];
        }
    }
    return out;
}

/// flipVertical — mirror top↔bottom (sharp's `flip`). Same dims.
pub fn flipVertical(src: SmBitmap) Error!SmBitmap {
    try check(src);
    const w = src.width;
    const h = src.height;
    const out = try allocBitmap(w, h);
    errdefer std.heap.page_allocator.free(out.data);
    const row_bytes: usize = @as(usize, w) * 4;
    var Y: u32 = 0;
    while (Y < h) : (Y += 1) {
        const src_row_off = @as(usize, h - 1 - Y) * row_bytes;
        const dst_row_off = @as(usize, Y) * row_bytes;
        @memcpy(out.data[dst_row_off .. dst_row_off + row_bytes], src.data[src_row_off .. src_row_off + row_bytes]);
    }
    return out;
}

/// rotateArbitrary — rotate by an arbitrary angle about the source
/// centre. Output dims = AABB of the rotated source rectangle. The
/// gap around the rotated content is filled with the bg colour.
///
/// Visual semantics match sharp: a positive `angle_deg` rotates
/// clockwise. In screen-space (y-down) that corresponds to the
/// standard mathematical rotation matrix `R = [[cos, -sin], [sin, cos]]`.
///
/// Multiples of 90° are handled by the lossless rotators (caller picks
/// the right primitive); this function is for everything else.
pub fn rotateArbitrary(
    src: SmBitmap,
    angle_deg: f64,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    interp: Interpolator,
) Error!SmBitmap {
    try check(src);
    const a_rad = angle_deg * std.math.pi / 180.0;
    const c = @cos(a_rad);
    const s = @sin(a_rad);

    const w_f: f64 = @floatFromInt(src.width);
    const h_f: f64 = @floatFromInt(src.height);

    // Forward bbox of the four corners under R(a).
    const corners = [_][2]f64{
        .{ 0, 0 },
        .{ w_f, 0 },
        .{ 0, h_f },
        .{ w_f, h_f },
    };
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    for (corners) |corn| {
        const fx = c * corn[0] - s * corn[1];
        const fy = s * corn[0] + c * corn[1];
        if (fx < min_x) min_x = fx;
        if (fx > max_x) max_x = fx;
        if (fy < min_y) min_y = fy;
        if (fy > max_y) max_y = fy;
    }

    const out_w_f = @ceil(max_x - min_x);
    const out_h_f = @ceil(max_y - min_y);
    if (out_w_f < 1 or out_h_f < 1) return error.Empty;
    const out_w: u32 = @intFromFloat(out_w_f);
    const out_h: u32 = @intFromFloat(out_h_f);

    // Inverse rotation matrix R^-1(a) = [[c, s], [-s, c]]. The forward
    // map shifts the source by (min_x, min_y) so its bbox lands at
    // origin; the inverse undoes that shift.
    //   src_x = c*(canvas_x + min_x) + s*(canvas_y + min_y)
    //         = c*canvas_x + s*canvas_y + (c*min_x + s*min_y)
    //   src_y = -s*(canvas_x + min_x) + c*(canvas_y + min_y)
    //         = -s*canvas_x + c*canvas_y + (-s*min_x + c*min_y)
    const inv_a = c;
    const inv_c = s;
    const inv_e = c * min_x + s * min_y;
    const inv_b = -s;
    const inv_d = c;
    const inv_f = -s * min_x + c * min_y;

    return sampleIntoBg(
        src, out_w, out_h,
        inv_a, inv_b, inv_c, inv_d, inv_e, inv_f,
        bg_r, bg_g, bg_b, bg_a,
        interp,
    );
}

/// affineTransform — sharp's `affine(matrix, { idx, idy, odx, ody, ... })`.
/// Forward map: F(x, y) = M·(x + idx, y + idy) + (odx, ody) where
/// M = [[m00, m01], [m10, m11]].
/// Output dims = AABB of forward-mapped (0..w) × (0..h). The bbox is
/// translated to origin so the rotated content sits flush against
/// (0, 0); odx/ody offset within the bbox.
pub fn affineTransform(
    src: SmBitmap,
    m00: f64,
    m01: f64,
    m10: f64,
    m11: f64,
    idx: f64,
    idy: f64,
    odx: f64,
    ody: f64,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    interp: Interpolator,
) Error!SmBitmap {
    try check(src);
    const w_f: f64 = @floatFromInt(src.width);
    const h_f: f64 = @floatFromInt(src.height);

    const det = m00 * m11 - m01 * m10;
    if (det == 0.0 or !std.math.isFinite(det)) return error.Singular;

    // Forward bbox of corners: F(corner) = M·(corner + (idx, idy)) + (odx, ody).
    const corners = [_][2]f64{
        .{ 0, 0 },
        .{ w_f, 0 },
        .{ 0, h_f },
        .{ w_f, h_f },
    };
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    for (corners) |corn| {
        const x_in = corn[0] + idx;
        const y_in = corn[1] + idy;
        const fx = m00 * x_in + m01 * y_in + odx;
        const fy = m10 * x_in + m11 * y_in + ody;
        if (fx < min_x) min_x = fx;
        if (fx > max_x) max_x = fx;
        if (fy < min_y) min_y = fy;
        if (fy > max_y) max_y = fy;
    }

    const out_w_f = @ceil(max_x - min_x);
    const out_h_f = @ceil(max_y - min_y);
    if (!std.math.isFinite(out_w_f) or !std.math.isFinite(out_h_f) or
        out_w_f < 1 or out_h_f < 1) return error.Empty;
    const out_w: u32 = @intFromFloat(out_w_f);
    const out_h: u32 = @intFromFloat(out_h_f);

    // M^-1 = (1/det) · [[m11, -m01], [-m10, m00]].
    const inv_M_00 = m11 / det;
    const inv_M_01 = -m01 / det;
    const inv_M_10 = -m10 / det;
    const inv_M_11 = m00 / det;

    // Inverse map (output canvas → source pixel). The forward bbox is
    // shifted to origin: a canvas coord `(cx, cy)` corresponds to
    // forward-space `(cx + min_x, cy + min_y)`. Inverting and folding
    // odx/ody/idx/idy in:
    //   src_x = inv_M_00·(cx + min_x − odx) + inv_M_01·(cy + min_y − ody) − idx
    //   src_y = inv_M_10·(cx + min_x − odx) + inv_M_11·(cy + min_y − ody) − idy
    const inv_a = inv_M_00;
    const inv_c = inv_M_01;
    const inv_e = inv_M_00 * (min_x - odx) + inv_M_01 * (min_y - ody) - idx;
    const inv_b = inv_M_10;
    const inv_d = inv_M_11;
    const inv_f = inv_M_10 * (min_x - odx) + inv_M_11 * (min_y - ody) - idy;

    return sampleIntoBg(
        src, out_w, out_h,
        inv_a, inv_b, inv_c, inv_d, inv_e, inv_f,
        bg_r, bg_g, bg_b, bg_a,
        interp,
    );
}

/// sampleIntoBg — allocate `out_w × out_h`, prefill with bg, then run
/// the inverse-map row sampler. Shared apex of `rotateArbitrary` and
/// `affineTransform`. The samplers leave out-of-source pixels
/// untouched, so the bg prefill is what gives padded rotation its
/// edge fill.
fn sampleIntoBg(
    src: SmBitmap,
    out_w: u32,
    out_h: u32,
    inv_a: f64,
    inv_b: f64,
    inv_c: f64,
    inv_d: f64,
    inv_e: f64,
    inv_f: f64,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    interp: Interpolator,
) Error!SmBitmap {
    const out = try allocBitmap(out_w, out_h);
    errdefer std.heap.page_allocator.free(out.data);

    const dst_u32: [*]u32 = @ptrCast(@alignCast(out.data.ptr));
    const total: usize = @as(usize, out_w) * @as(usize, out_h);
    const dst_full = dst_u32[0..total];
    simd.fillU32(dst_full, packBg(bg_r, bg_g, bg_b, bg_a));

    const src_u32: [*]const u32 = @ptrCast(@alignCast(src.data.ptr));
    const w_f: f64 = @floatFromInt(src.width);
    const h_f: f64 = @floatFromInt(src.height);

    var y: i32 = 0;
    while (y < @as(i32, @intCast(out_h))) : (y += 1) {
        const row_start: usize = @as(usize, @intCast(y)) * @as(usize, out_w);
        const row = dst_u32[row_start .. row_start + @as(usize, out_w)];
        switch (interp) {
            .nearest => simd.sampleImageNearestRow(
                row,
                src_u32,
                src.width,
                src.height,
                0,
                0,
                w_f,
                h_f,
                inv_a,
                inv_b,
                inv_c,
                inv_d,
                inv_e,
                inv_f,
                0,
                y,
            ),
            .bilinear => simd.sampleImageBilinearRow(
                row,
                src_u32,
                src.width,
                src.height,
                0,
                0,
                w_f,
                h_f,
                inv_a,
                inv_b,
                inv_c,
                inv_d,
                inv_e,
                inv_f,
                0,
                y,
            ),
        }
    }
    return out;
}
