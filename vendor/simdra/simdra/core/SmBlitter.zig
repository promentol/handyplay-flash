//! SmBlitter — pixel emission. Mirrors Skia's `SkBlitter`.
//!
//! ONE function — `blitRow` — handles all `(source_kind × blend_mode ×
//! coverage)` combinations through internal dispatch. The Scan converter
//! (`SmScan`) feeds it row-by-row.
//!
//! The signature is **coverage-row-shaped**: the per-pixel coverage array
//! parameter is what makes this Blitter handle scanline rasterization,
//! anti-aliased path rasterization, and tile-based rasterization with
//! the same API. The work distribution is the caller's choice; the
//! Blitter just sees "n pixels to write at (x_start, y), per this paint,
//! modulated by these coverage values".
//!
//! Step 1 implementation: solid color, full coverage, src semantics
//! (overwrite). Matches the legacy `raster.fillRectColor` behavior bit-for-
//! bit. Subsequent steps fill in the dispatch by adding cases:
//!
//!   • coverage != null         → modulate src.a by coverage, then blend
//!   • paint.kind .gradient     → sample SmGradient per row
//!   • paint.kind .image        → bilinear sample SmBitmap per row
//!   • paint.blend_mode .add    → simd.blendAddU32   (Love2D `add`)
//!   • paint.blend_mode .mult   → simd.blendMultiplyU32
//!   • paint.blend_mode .src_over → simd.blendSrcOverU32 (already wired)
//!   ... etc.

const std = @import("std");
const simd = @import("../opts/simd.zig");
const types = @import("types.zig");
const SmPaint = @import("SmPaint.zig");

/// blitRow — write `n` pixels starting at `(x_start, y)` per `paint`,
/// modulated by `coverage` and the optional canvas-wide `clip_mask`.
///
/// Coverage semantics:
///   `coverage == null`  → all-full (0xFF) coverage. Fast paths enabled.
///   `coverage != null`  → per-pixel u8 coverage (AA edges, glyph alpha).
///
/// Clip semantics:
///   `clip_mask == null` → no clip; fast paths run unchanged.
///   `clip_mask != null` → length must equal `pixels.len` (canvas-wide
///                          mask). Each byte is the per-pixel clip cover
///                          (currently always 0 or 0xFF; AA-clip uses the
///                          same byte channel multiplicatively). Combined
///                          with `coverage` row-wise as
///                          `eff[i] = (coverage[i] * clip[i] + 127) / 255`
///                          — for binary clip values this is a pure mask.
pub fn blitRow(
    pixels: []u32,
    dst_w: u32,
    x_start: i32,
    y: i32,
    n: u32,
    coverage: ?[]const u8,
    paint: *const SmPaint,
    clip_mask: ?[]const u8,
) void {
    if (n == 0) return;

    const start_idx: usize =
        @as(usize, @intCast(y)) * @as(usize, dst_w) +
        @as(usize, @intCast(x_start));
    const row = pixels[start_idx..][0..n];
    const clip_row: ?[]const u8 = if (clip_mask) |cm| cm[start_idx..][0..n] else null;

    // `.gradient` / `.pattern` shaders take the per-pixel path — they sample
    // a different source color at every (x, y), so the SIMD kernels (which
    // assume one source color per row) don't apply. Coverage, global_alpha,
    // and clip-mask all modulate the per-pixel alpha; the per-mode blend
    // logic is reused from `dispatchSolid` by wrapping each emitted pixel
    // as a one-pixel solid paint — avoids a 27-mode duplicate switch.
    switch (paint.shader) {
        .solid => {},
        .gradient, .pattern => {
            dispatchShader(row, x_start, y, coverage, paint, clip_row);
            return;
        },
    }

    // Solid-paint fast path: combine coverage + clip into an effective
    // coverage row when either is non-null, then dispatch through the
    // existing per-blend-mode coverage kernels.
    if (clip_row) |cr| {
        // `.src` (clearRect) is true overwrite semantics — coverage-modulated
        // dispatch via the src_over-shaped kernel does NOT produce correct
        // HTML5 clearRect-under-clip output (transparent src would leave
        // dst unchanged). Handle directly with a per-pixel mask write.
        if (paint.blend_mode == .src) {
            const solid_color = resolveSolid(paint);
            if (coverage) |cov| {
                for (0..n) |i| {
                    if (cr[i] != 0 and cov[i] != 0) row[i] = solid_color;
                }
            } else {
                for (0..n) |i| {
                    if (cr[i] != 0) row[i] = solid_color;
                }
            }
            return;
        }
        // Build effective coverage. Allocates a small per-row scratch via
        // page_allocator — cheap relative to the per-pixel blend cost; can
        // be replaced with a per-canvas scratch buffer later.
        const allocator = std.heap.page_allocator;
        const eff = allocator.alloc(u8, n) catch return;
        defer allocator.free(eff);
        if (coverage) |cov| {
            std.debug.assert(cov.len == n);
            for (0..n) |i| {
                eff[i] = @intCast((@as(u16, cov[i]) * @as(u16, cr[i]) + 127) / 255);
            }
        } else {
            @memcpy(eff, cr);
        }
        const solid_color = resolveSolid(paint);
        dispatchCoverage(row, solid_color, eff, paint.blend_mode, paint.dst_color_type);
        return;
    }

    if (coverage) |cov| {
        std.debug.assert(cov.len == n);
        // Per-pixel coverage routes through one kernel per blend mode. Each
        // pre-modulates `solid_color`'s alpha by per-pixel coverage and
        // runs the same blend formula as the no-coverage path — so AA
        // edges, glyph outlines, and tile-based rasterization all produce
        // visually correct output across every HTML5 composite operator.
        // `src_over` / `src` / `copy` keep the optimized fast path.
        const solid_color = resolveSolid(paint);
        dispatchCoverage(row, solid_color, cov, paint.blend_mode, paint.dst_color_type);
        return;
    }
    dispatchSolid(row, paint, paint.dst_color_type);
}

/// Per-pixel sampler path for `.gradient` / `.pattern` shaders. Walks the
/// destination row, samples the shader at each pixel center, applies
/// `paint.global_alpha` and (optionally) the coverage byte to the source
/// alpha, then blends through the existing single-pixel `dispatchSolid`
/// path. Slow but complete across all 27 blend modes; SIMD row samplers
/// can replace the inner loop later without changing the API.
inline fn dispatchShader(
    row: []u32,
    x_start: i32,
    y: i32,
    coverage: ?[]const u8,
    paint: *const SmPaint,
    clip_row: ?[]const u8,
) void {
    const py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
    var i: usize = 0;
    while (i < row.len) : (i += 1) {
        const px: f64 = @as(f64, @floatFromInt(x_start + @as(i32, @intCast(i)))) + 0.5;
        var src: u32 = switch (paint.shader) {
            .gradient => |g| switch (g.geometry) {
                .linear => g.sampleLinear(px, py),
                .radial => g.sampleRadial(px, py),
                .conic => g.sampleConic(px, py),
            },
            .pattern => |p| p.sample(px, py),
            .solid => unreachable,
        };
        // Per-paint color transform: post-sample, before the alpha
        // modulators — the counterpart of `resolveSolid` on solid paths.
        if (!paint.cxform.isIdentity()) {
            src = paint.cxform.apply(src);
        }
        // Samplers emit logical RGBA; fold to surface order for BGRA
        // destinations (alpha stays in lane 24-31, so ordering vs the
        // alpha modulators below is irrelevant).
        if (paint.dst_color_type == .bgra8888) {
            src = simd.swizzleRB(src);
        }
        // Fold paint.global_alpha into the source alpha (premul-aware via
        // simple 8-bit multiply — the rest of the pipeline uses straight
        // alpha; the per-mode kernel handles its own premul math).
        if (paint.global_alpha != 0xFF) {
            src = modulateAlpha(src, paint.global_alpha);
        }
        if (coverage) |cov| {
            src = modulateAlpha(src, cov[i]);
        }
        if (clip_row) |cr| {
            // Skip the entire per-pixel dispatch when fully clipped out.
            if (cr[i] == 0) continue;
            if (cr[i] != 0xFF) src = modulateAlpha(src, cr[i]);
        }
        var slot = [_]u32{row[i]};
        const single: SmPaint = .{
            .shader = .{ .solid = src },
            .style = paint.style,
            .blend_mode = paint.blend_mode,
        };
        // `single` keeps default dst_color_type/cxform (src is already in
        // surface order) — the kernel choice travels via the ct parameter.
        dispatchSolid(slot[0..1], &single, paint.dst_color_type);
        row[i] = slot[0];
    }
}

inline fn modulateAlpha(rgba: u32, modulator: u8) u32 {
    const a: u32 = (rgba >> 24) & 0xFF;
    const new_a: u32 = (a * @as(u32, modulator) + 0x80) >> 8;
    return (rgba & 0x00FFFFFF) | (new_a << 24);
}

inline fn dispatchCoverage(
    row: []u32,
    solid_color: u32,
    cov: []const u8,
    mode: SmPaint.BlendMode,
    ct: types.ColorType,
) void {
    // Only the four lum-asymmetric non-separable modes care about the
    // surface byte order; every other kernel is R/G/B-symmetric.
    if (ct == .bgra8888) {
        switch (mode) {
            .hue => return simd.blendHueCovBgraU32(row, solid_color, cov),
            .saturation => return simd.blendSaturationCovBgraU32(row, solid_color, cov),
            .color => return simd.blendColorCovBgraU32(row, solid_color, cov),
            .luminosity => return simd.blendLuminosityCovBgraU32(row, solid_color, cov),
            else => {},
        }
    }
    switch (mode) {
        .src, .src_over, .copy => simd.blendSrcOverCovU32(row, solid_color, cov),
        // Porter-Duff family.
        .src_in => simd.blendSrcInCovU32(row, solid_color, cov),
        .src_out => simd.blendSrcOutCovU32(row, solid_color, cov),
        .src_atop => simd.blendSrcAtopCovU32(row, solid_color, cov),
        .dst_over => simd.blendDstOverCovU32(row, solid_color, cov),
        .dst_in => simd.blendDstInCovU32(row, solid_color, cov),
        .dst_out => simd.blendDstOutCovU32(row, solid_color, cov),
        .dst_atop => simd.blendDstAtopCovU32(row, solid_color, cov),
        .xor => simd.blendXorCovU32(row, solid_color, cov),
        .add => simd.blendAddCovU32(row, solid_color, cov),
        // Separable blend.
        .multiply => simd.blendMultiplyCovU32(row, solid_color, cov),
        .screen => simd.blendScreenCovU32(row, solid_color, cov),
        .overlay => simd.blendOverlayCovU32(row, solid_color, cov),
        .darken => simd.blendDarkenCovU32(row, solid_color, cov),
        .lighten => simd.blendLightenCovU32(row, solid_color, cov),
        .color_dodge => simd.blendColorDodgeCovU32(row, solid_color, cov),
        .color_burn => simd.blendColorBurnCovU32(row, solid_color, cov),
        .hard_light => simd.blendHardLightCovU32(row, solid_color, cov),
        .soft_light => simd.blendSoftLightCovU32(row, solid_color, cov),
        .difference => simd.blendDifferenceCovU32(row, solid_color, cov),
        .exclusion => simd.blendExclusionCovU32(row, solid_color, cov),
        // Non-separable blend.
        .hue => simd.blendHueCovU32(row, solid_color, cov),
        .saturation => simd.blendSaturationCovU32(row, solid_color, cov),
        .color => simd.blendColorCovU32(row, solid_color, cov),
        .luminosity => simd.blendLuminosityCovU32(row, solid_color, cov),
        // Flash (SWF) modes.
        .flash_subtract => simd.blendFlashSubtractCovU32(row, solid_color, cov),
        .flash_invert => simd.blendFlashInvertCovU32(row, solid_color, cov),
        .flash_alpha => simd.blendFlashAlphaCovU32(row, solid_color, cov),
        .flash_erase => simd.blendFlashEraseCovU32(row, solid_color, cov),
    }
}

/// Extract the solid u32 from a paint's Shader. Only reached from
/// `.solid` paths — gradient/pattern shaders are siphoned to
/// `dispatchShader` before we get here.
inline fn solidColorOf(shader: SmPaint.Shader) u32 {
    return switch (shader) {
        .solid => |c| c,
        .gradient, .pattern => unreachable,
    };
}

/// Resolve a `.solid` paint to the source color the blend kernels consume.
/// This is THE funnel for per-paint source-color transforms: every solid
/// draw path (rect fast path, AA coverage fill, glyphs, clip variants)
/// resolves its color here exactly once. The one-pixel paints synthesized
/// by `dispatchShader` / `blitRowFromSource` / `blitFull` carry
/// default-initialized transform state, so colors that were already
/// resolved per-pixel are not transformed a second time.
pub inline fn resolveSolid(paint: *const SmPaint) u32 {
    var c = solidColorOf(paint.shader);
    if (!paint.cxform.isIdentity()) c = paint.cxform.apply(c);
    // Late lane fold: paint colors are logical RGBA; BGRA destinations get
    // the R↔B swap here, after the (logical-channel) color transform.
    if (paint.dst_color_type == .bgra8888) c = simd.swizzleRB(c);
    return c;
}

/// blitRowFromSource — write a row of per-pixel source colors onto `dst`
/// per `paint.blend_mode`, modulated by `paint.global_alpha` and the
/// optional row-shaped `clip_row`. Used by `SmCanvas.drawImageScaledSub`
/// after sampling an image into a row scratch — replaces the legacy direct
/// row-write that bypassed the blitter and ignored `globalCompositeOperation`.
///
/// Mirrors the per-pixel shape of `dispatchShader` (gradient / pattern
/// branch of `blitRow`) but takes a pre-sampled `src` row instead of
/// invoking a shader sampler. Slow but complete across all 27 blend
/// modes; SIMD-vectorized per-pixel-source kernels can replace the inner
/// loop later without changing the API.
pub fn blitRowFromSource(
    dst: []u32,
    src: []const u32,
    paint: *const SmPaint,
    clip_row: ?[]const u8,
) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        var s: u32 = src[i];
        // Per-paint color transform for pre-sampled rows (drawImage tint),
        // before the alpha modulators below.
        if (!paint.cxform.isIdentity()) {
            s = paint.cxform.apply(s);
        }
        // Sampled bitmap rows are logical RGBA; fold for BGRA destinations.
        if (paint.dst_color_type == .bgra8888) {
            s = simd.swizzleRB(s);
        }
        if (paint.global_alpha != 0xFF) {
            s = modulateAlpha(s, paint.global_alpha);
        }
        if (clip_row) |cr| {
            // Skip the entire per-pixel dispatch when fully clipped out.
            if (cr[i] == 0) continue;
            if (cr[i] != 0xFF) s = modulateAlpha(s, cr[i]);
        }
        var slot = [_]u32{dst[i]};
        const single: SmPaint = .{
            .shader = .{ .solid = s },
            .style = paint.style,
            .blend_mode = paint.blend_mode,
        };
        dispatchSolid(slot[0..1], &single, paint.dst_color_type);
        dst[i] = slot[0];
    }
}

/// blitFull — composite an entire `src` pixel buffer onto `dst` using a
/// blend mode that reads PER-PIXEL source colors (rather than a single
/// solid color). Used by `SmCanvas.endCompositeLayer` to merge a scratch
/// layer into the real canvas across the WHOLE canvas. Required for the
/// non-row-friendly modes (src-in / src-out / dst-in / dst-atop / copy)
/// whose pixel formula yields a non-`dst` result outside the shape's
/// affected region — those modes need to see every canvas pixel.
pub fn blitFull(dst: []u32, src: []const u32, mode: SmPaint.BlendMode, ct: types.ColorType) void {
    std.debug.assert(dst.len == src.len);
    // For each pixel, build a one-pixel "paint" and dispatch the same blend
    // logic the row blitter uses. Avoids duplicating per-mode code. Both
    // buffers are already in surface order (`ct` selects the lum-aware
    // non-separable kernels; no source swizzling happens here).
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const single_src = src[i];
        var single_dst = [_]u32{dst[i]};
        const paint: SmPaint = .{ .shader = .{ .solid = single_src }, .style = .fill, .blend_mode = mode };
        dispatchSolid(single_dst[0..1], &paint, ct);
        dst[i] = single_dst[0];
    }
}

test "resolveSolid forwards the solid color unchanged" {
    const p: SmPaint = .{ .shader = .{ .solid = 0x80FF8040 } };
    try std.testing.expectEqual(@as(u32, 0x80FF8040), resolveSolid(&p));
}

test "blitRow src_over on opaque solid overwrites the row" {
    var px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000 };
    const p: SmPaint = .{ .shader = .{ .solid = 0xFF0000FF }, .blend_mode = .src_over };
    blitRow(&px, 3, 0, 0, 3, null, &p, null);
    for (px) |c| try std.testing.expectEqual(@as(u32, 0xFF0000FF), c);
}

test "resolveSolid applies a non-identity cxform exactly once" {
    // (200,100,50,255) with r×0.5, g+64, a−128 → (100,164,50,127).
    const src: u32 = 200 | (100 << 8) | (50 << 16) | (255 << 24);
    const expect: u32 = 100 | (164 << 8) | (50 << 16) | (127 << 24);
    const p: SmPaint = .{
        .shader = .{ .solid = src },
        .cxform = .{ .mult = .{ 128, 256, 256, 256 }, .add = .{ 0, 64, 0, -128 } },
    };
    try std.testing.expectEqual(expect, resolveSolid(&p));
}

test "cxform identity blit is byte-identical to a plain blit" {
    var a = [_]u32{ 0xFF336699, 0xFF336699 };
    var b = a;
    const plain: SmPaint = .{ .shader = .{ .solid = 0x80FF8040 }, .blend_mode = .src_over };
    var with_id = plain;
    with_id.cxform = .{};
    blitRow(&a, 2, 0, 0, 2, null, &plain, null);
    blitRow(&b, 2, 0, 0, 2, null, &with_id, null);
    try std.testing.expectEqualSlices(u32, &a, &b);
}

test "cxform alpha-mult zero leaves dst unchanged under src_over" {
    var px = [_]u32{0xFF112233};
    const p: SmPaint = .{
        .shader = .{ .solid = 0xFFFFFFFF },
        .blend_mode = .src_over,
        .cxform = .{ .mult = .{ 256, 256, 256, 0 } },
    };
    blitRow(&px, 1, 0, 0, 1, null, &p, null);
    try std.testing.expectEqual(@as(u32, 0xFF112233), px[0]);
}

test "blitRowFromSource applies cxform to sampled rows (drawImage tint)" {
    var dst = [_]u32{0x00000000};
    const src = [_]u32{200 | (100 << 8) | (50 << 16) | (255 << 24)};
    const p: SmPaint = .{
        .shader = .{ .solid = 0 },
        .blend_mode = .src_over,
        .cxform = .{ .mult = .{ 128, 256, 256, 256 }, .add = .{ 0, 64, 0, 0 } },
    };
    blitRowFromSource(&dst, &src, &p, null);
    try std.testing.expectEqual(@as(u32, 100 | (164 << 8) | (50 << 16) | (255 << 24)), dst[0]);
}

test "flash blend modes: exact formulas on one pixel" {
    const dst0: u32 = 100 | (150 << 8) | (200 << 16) | (255 << 24);
    const src_half: u32 = 60 | (80 << 8) | (255 << 16) | (128 << 24);

    // subtract: out.rgb = max(dst − src·sa, 0), out.a = da.
    {
        var px = [_]u32{dst0};
        const p: SmPaint = .{ .shader = .{ .solid = src_half }, .blend_mode = .flash_subtract };
        blitRow(&px, 1, 0, 0, 1, null, &p, null);
        try std.testing.expectEqual(@as(u32, 70 | (110 << 8) | (72 << 16) | (255 << 24)), px[0]);
    }
    // subtract with transparent src is a no-op.
    {
        var px = [_]u32{dst0};
        const p: SmPaint = .{ .shader = .{ .solid = 0x00FFFFFF }, .blend_mode = .flash_subtract };
        blitRow(&px, 1, 0, 0, 1, null, &p, null);
        try std.testing.expectEqual(dst0, px[0]);
    }
    // invert at full source alpha: out.rgb = 255 − dst.
    {
        var px = [_]u32{dst0};
        const p: SmPaint = .{ .shader = .{ .solid = 0xFF000000 }, .blend_mode = .flash_invert };
        blitRow(&px, 1, 0, 0, 1, null, &p, null);
        try std.testing.expectEqual(@as(u32, 155 | (105 << 8) | (55 << 16) | (255 << 24)), px[0]);
    }
    // alpha: out.a = da·sa, rgb untouched.
    {
        var px = [_]u32{100 | (150 << 8) | (200 << 16) | (200 << 24)};
        const p: SmPaint = .{ .shader = .{ .solid = src_half }, .blend_mode = .flash_alpha };
        blitRow(&px, 1, 0, 0, 1, null, &p, null);
        try std.testing.expectEqual(@as(u32, 100 | (150 << 8) | (200 << 16) | (100 << 24)), px[0]);
    }
    // erase: out.a = da·(1 − sa), rgb untouched.
    {
        var px = [_]u32{100 | (150 << 8) | (200 << 16) | (200 << 24)};
        const p: SmPaint = .{ .shader = .{ .solid = src_half }, .blend_mode = .flash_erase };
        blitRow(&px, 1, 0, 0, 1, null, &p, null);
        try std.testing.expectEqual(@as(u32, 100 | (150 << 8) | (200 << 16) | (100 << 24)), px[0]);
    }
    // flash_alpha zeroes dst alpha outside the source → layer-composite class.
    try std.testing.expect(SmPaint.BlendMode.flash_alpha.requiresLayerComposite());
    try std.testing.expect(!SmPaint.BlendMode.flash_erase.requiresLayerComposite());
}

test "swizzleRBCopyU32 kernel matches scalar on vector body + tail" {
    var src: [37]u32 = undefined;
    for (&src, 0..) |*p, i| p.* = @as(u32, @truncate(i *% 0x01020304)) ^ 0xA5C3;
    var dst: [37]u32 = undefined;
    simd.swizzleRBCopyU32(&dst, &src);
    for (src, dst) |s, d| try std.testing.expectEqual(simd.swizzleRB(s), d);
    try std.testing.expectEqual(@as(u32, 0x80CC9944), simd.swizzleRB(0x804499CC));
}

test "bgra output is the exact R/B swap of rgba output — all blend modes" {
    const dst_init = [4]u32{ 0xFF204060, 0x80A0FF10, 0x00000000, 0x33112233 };
    const cov = [4]u8{ 255, 128, 7, 0 };
    const src_color: u32 = 0x99CC5522; // partial alpha, distinct R/B

    inline for (@typeInfo(SmPaint.BlendMode).@"enum".fields) |f| {
        const mode: SmPaint.BlendMode = @enumFromInt(f.value);
        var p_rgba: SmPaint = .{ .shader = .{ .solid = src_color }, .blend_mode = mode };
        var p_bgra = p_rgba;
        p_bgra.dst_color_type = .bgra8888;

        // Full-coverage path.
        var a = dst_init;
        var b: [4]u32 = undefined;
        for (dst_init, 0..) |c, i| b[i] = simd.swizzleRB(c);
        blitRow(&a, 4, 0, 0, 4, null, &p_rgba, null);
        blitRow(&b, 4, 0, 0, 4, null, &p_bgra, null);
        for (a, b) |x, y| try std.testing.expectEqual(simd.swizzleRB(x), y);

        // Coverage path.
        a = dst_init;
        for (dst_init, 0..) |c, i| b[i] = simd.swizzleRB(c);
        blitRow(&a, 4, 0, 0, 4, &cov, &p_rgba, null);
        blitRow(&b, 4, 0, 0, 4, &cov, &p_bgra, null);
        for (a, b) |x, y| try std.testing.expectEqual(simd.swizzleRB(x), y);

        // blitFull path (both buffers already in surface order).
        a = dst_init;
        for (dst_init, 0..) |c, i| b[i] = simd.swizzleRB(c);
        const full_src = [4]u32{ src_color, 0x10FF0080, 0xFF012345, 0x7F654321 };
        var full_src_b: [4]u32 = undefined;
        for (full_src, 0..) |c, i| full_src_b[i] = simd.swizzleRB(c);
        blitFull(&a, &full_src, mode, .rgba8888);
        blitFull(&b, &full_src_b, mode, .bgra8888);
        for (a, b) |x, y| try std.testing.expectEqual(simd.swizzleRB(x), y);
    }
}

test "bgra swap property holds for gradient and pattern shaders + cxform" {
    const SmGradient = @import("../effects/SmGradient.zig");
    const SmPattern = @import("../effects/SmPattern.zig");
    const ta = std.testing.allocator;

    var g = SmGradient.linearWithAllocator(ta, 0, 0, 4, 0);
    defer g.deinit();
    try g.addColorStop(0.0, "rgba(255, 32, 8, 0.8)");
    try g.addColorStop(1.0, "#0040ff");
    g.setSpread(.reflect);

    const tile = [8]u8{ 250, 60, 10, 255, 20, 90, 200, 128 };
    var pat = try SmPattern.createWithAllocator(ta, &tile, 2, 1, .repeat);
    defer pat.deinit();
    pat.setFilter(.bilinear);

    const cx: SmPaint.ColorTransform = .{ .mult = .{ 200, 256, 300, 256 }, .add = .{ 10, -20, 0, 5 } };
    const dst_init = [4]u32{ 0xFF204060, 0x80A0FF10, 0x00000000, 0x33112233 };
    const shaders = [2]SmPaint.Shader{ .{ .gradient = &g }, .{ .pattern = &pat } };

    for (shaders) |shader| {
        var p_rgba: SmPaint = .{ .shader = shader, .blend_mode = .src_over, .cxform = cx, .global_alpha = 200 };
        var p_bgra = p_rgba;
        p_bgra.dst_color_type = .bgra8888;
        var a = dst_init;
        var b: [4]u32 = undefined;
        for (dst_init, 0..) |c, i| b[i] = simd.swizzleRB(c);
        blitRow(&a, 4, 0, 0, 4, null, &p_rgba, null);
        blitRow(&b, 4, 0, 0, 4, null, &p_bgra, null);
        for (a, b) |x, y| try std.testing.expectEqual(simd.swizzleRB(x), y);
    }

    // drawImage row path (sampled RGBA source rows).
    const src_row = [4]u32{ 0x99CC5522, 0x10FF0080, 0xFF012345, 0x7F654321 };
    var p_rgba: SmPaint = .{ .shader = .{ .solid = 0 }, .blend_mode = .src_over, .cxform = cx, .global_alpha = 200 };
    var p_bgra = p_rgba;
    p_bgra.dst_color_type = .bgra8888;
    var a = dst_init;
    var b: [4]u32 = undefined;
    for (dst_init, 0..) |c, i| b[i] = simd.swizzleRB(c);
    blitRowFromSource(&a, &src_row, &p_rgba, null);
    blitRowFromSource(&b, &src_row, &p_bgra, null);
    for (a, b) |x, y| try std.testing.expectEqual(simd.swizzleRB(x), y);
}

inline fn dispatchSolid(row: []u32, paint: *const SmPaint, ct: types.ColorType) void {
    const solid = resolveSolid(paint);
    // See dispatchCoverage: only the non-separable modes branch on order.
    if (ct == .bgra8888) {
        switch (paint.blend_mode) {
            .hue => return simd.blendHueBgraU32(row, solid),
            .saturation => return simd.blendSaturationBgraU32(row, solid),
            .color => return simd.blendColorBgraU32(row, solid),
            .luminosity => return simd.blendLuminosityBgraU32(row, solid),
            else => {},
        }
    }
    switch (paint.blend_mode) {
        // Internal — clearRect uses this directly.
        .src, .copy => simd.fillU32(row, solid),
        // Porter-Duff family.
        .src_over => simd.blendSrcOverU32(row, solid),
        .src_in => simd.blendSrcInU32(row, solid),
        .src_out => simd.blendSrcOutU32(row, solid),
        .src_atop => simd.blendSrcAtopU32(row, solid),
        .dst_over => simd.blendDstOverU32(row, solid),
        .dst_in => simd.blendDstInU32(row, solid),
        .dst_out => simd.blendDstOutU32(row, solid),
        .dst_atop => simd.blendDstAtopU32(row, solid),
        .xor => simd.blendXorU32(row, solid),
        .add => simd.blendAddU32(row, solid),
        // Separable blend.
        .multiply => simd.blendMultiplyU32(row, solid),
        .screen => simd.blendScreenU32(row, solid),
        .overlay => simd.blendOverlayU32(row, solid),
        .darken => simd.blendDarkenU32(row, solid),
        .lighten => simd.blendLightenU32(row, solid),
        .color_dodge => simd.blendColorDodgeU32(row, solid),
        .color_burn => simd.blendColorBurnU32(row, solid),
        .hard_light => simd.blendHardLightU32(row, solid),
        .soft_light => simd.blendSoftLightU32(row, solid),
        .difference => simd.blendDifferenceU32(row, solid),
        .exclusion => simd.blendExclusionU32(row, solid),
        // Non-separable blend.
        .hue => simd.blendHueU32(row, solid),
        .saturation => simd.blendSaturationU32(row, solid),
        .color => simd.blendColorU32(row, solid),
        .luminosity => simd.blendLuminosityU32(row, solid),
        // Flash (SWF) modes.
        .flash_subtract => simd.blendFlashSubtractU32(row, solid),
        .flash_invert => simd.blendFlashInvertU32(row, solid),
        .flash_alpha => simd.blendFlashAlphaU32(row, solid),
        .flash_erase => simd.blendFlashEraseU32(row, solid),
    }
}
