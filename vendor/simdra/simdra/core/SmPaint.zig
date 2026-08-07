//! SmPaint — drawing parameters bundled into one value. Mirrors Skia's
//! `SkPaint`. SmCanvas's `draw*` methods take a `*const SmPaint` rather
//! than reading canvas state; the HTML5-named sugar (`fillRect`,
//! `strokeRect`, …) bundles the current ctx state (`fillStyle` /
//! `strokeStyle` / `lineWidth`) into a SmPaint and calls the draw method.
//!
//! Pure value type — no allocator needed.

const std = @import("std");
const types = @import("types.zig");
const SmGradient = @import("../effects/SmGradient.zig");
const SmPattern = @import("../effects/SmPattern.zig");

const SmPaint = @This();

/// Per-paint source-color transform — the shape of a SWF CXFORM: a
/// per-channel multiply (8.8 fixed point) plus a per-channel add, alpha
/// included, applied to straight-alpha source colors post-shader /
/// pre-blend. simdra extension used by the Flash renderer (fades, tints,
/// flashes are all cxform tweens); identity by default so it costs one
/// branch when unused.
pub const ColorTransform = struct {
    /// 8.8 fixed-point multipliers [r, g, b, a]; 256 = 1.0.
    mult: [4]i16 = .{ 256, 256, 256, 256 },
    /// Per-channel adds in [-255, 255], [r, g, b, a].
    add: [4]i16 = .{ 0, 0, 0, 0 },

    pub inline fn isIdentity(self: ColorTransform) bool {
        return self.mult[0] == 256 and self.mult[1] == 256 and
            self.mult[2] == 256 and self.mult[3] == 256 and
            self.add[0] == 0 and self.add[1] == 0 and
            self.add[2] == 0 and self.add[3] == 0;
    }

    /// apply(rgba) — per channel c: clamp(((c · mult) >> 8) + add, 0, 255).
    /// Straight-alpha in, straight-alpha out; pure integer math (the SWF
    /// evaluation order, arithmetic shift for negative multipliers).
    pub inline fn apply(self: ColorTransform, rgba: u32) u32 {
        var out: u32 = 0;
        inline for (0..4) |i| {
            const c: i32 = @intCast((rgba >> (8 * i)) & 0xFF);
            const v = ((c * @as(i32, self.mult[i])) >> 8) + @as(i32, self.add[i]);
            const clamped: u32 = @intCast(std.math.clamp(v, 0, 255));
            out |= clamped << (8 * i);
        }
        return out;
    }

    /// Compose: `self` applied AFTER `inner` (parent ∘ child — the SWF
    /// display-list concatenation rule for nested clips).
    pub fn concat(self: ColorTransform, inner: ColorTransform) ColorTransform {
        var r: ColorTransform = .{};
        inline for (0..4) |i| {
            const m = (@as(i32, self.mult[i]) * @as(i32, inner.mult[i])) >> 8;
            const a = ((@as(i32, inner.add[i]) * @as(i32, self.mult[i])) >> 8) + @as(i32, self.add[i]);
            r.mult[i] = @intCast(std.math.clamp(m, std.math.minInt(i16), std.math.maxInt(i16)));
            r.add[i] = @intCast(std.math.clamp(a, -255, 255));
        }
        return r;
    }
};

/// Source for paint output. The blitter dispatches per-arm:
///   • `.solid`     → SIMD blend kernels (fast path).
///   • `.gradient`  → per-pixel `SmGradient.sampleLinear` / `sampleRadial`
///                    then through the same blend kernels.
///   • `.pattern`   → per-pixel `SmPattern.sample` then blend.
pub const Shader = union(enum) {
    solid: u32,
    gradient: *const SmGradient,
    pattern: *const SmPattern,
};

pub const Style = enum(u8) {
    fill = 0,
    stroke = 1,
    fill_and_stroke = 2,
};

/// Stroke endpoint shape for `lineCap` (HTML5 + Skia parity).
///   .butt   — perpendicular cut at the endpoint (default).
///   .round  — half-circle cap.
///   .square — perpendicular cut extended one half-width along the segment.
pub const LineCap = enum(u8) {
    butt = 0,
    round = 1,
    square = 2,
};

/// Stroke vertex join shape for `lineJoin`.
///   .miter — sharp intersection of outer offsets (bevel fallback when the
///            ratio exceeds `miter_limit`).
///   .bevel — straight chamfer between outer corners.
///   .round — circular fan between outer corners.
pub const LineJoin = enum(u8) {
    miter = 0,
    bevel = 1,
    round = 2,
};

/// Blend mode — operator that combines a source pixel with a destination
/// pixel. Covers the full HTML5 `globalCompositeOperation` set defined by
/// W3C Compositing and Blending Level 1, plus an internal `.src` mode used
/// by `clearRect` to write raw bytes without honoring composite mode.
///
/// JS-side mapping lives in `src/index.ts` (`HTML5_TO_BLEND` /
/// `BLEND_TO_HTML5`). Three families:
///
///   • Porter-Duff compositing (Fa, Fb pair) — `src_over`, `src_in`,
///     `src_out`, `src_atop`, `dst_over`, `dst_in`, `dst_out`, `dst_atop`,
///     `xor`, `add` ('lighter'), `copy`. `src` is internal — callers go
///     through `copy` for HTML5 semantics; clearRect uses `src` directly.
///   • Separable blend (per-channel B function): `multiply`, `screen`,
///     `overlay`, `darken`, `lighten`, `color_dodge`, `color_burn`,
///     `hard_light`, `soft_light`, `difference`, `exclusion`.
///   • Non-separable blend (HSL-shape color manipulation): `hue`,
///     `saturation`, `color`, `luminosity`.
pub const BlendMode = enum(u8) {
    // Porter-Duff
    src_over = 0,
    src_in = 1,
    src_out = 2,
    src_atop = 3,
    dst_over = 4,
    dst_in = 5,
    dst_out = 6,
    dst_atop = 7,
    src = 8, // internal — overwrite without blending; used by clearRect
    copy = 9, // HTML5 'copy' — same as src + canvas-wide pre-clear (handled in SmCanvas)
    xor = 10,
    add = 11, // HTML5 'lighter'

    // Separable blend
    multiply = 12,
    screen = 13,
    overlay = 14,
    darken = 15,
    lighten = 16,
    color_dodge = 17,
    color_burn = 18,
    hard_light = 19,
    soft_light = 20,
    difference = 21,
    exclusion = 22,

    // Non-separable blend
    hue = 23,
    saturation = 24,
    color = 25,
    luminosity = 26,

    // Flash (SWF PlaceObject3) modes — simdra extensions with no HTML5
    // equivalent; never produced by the JS facade (no
    // globalCompositeOperation mapping). Straight-alpha formulas in
    // opts/generic.zig §Flash blend modes. `flash_alpha` / `flash_erase`
    // are masking ops that Flash only honors inside a cached parent
    // layer; `flash_alpha` requires layer compositing here too (its
    // formula zeroes dst alpha outside the source region).
    flash_subtract = 27,
    flash_invert = 28,
    flash_alpha = 29,
    flash_erase = 30,

    /// Modes whose pixel formula yields a non-`dst` result OUTSIDE the
    /// source region (i.e. when the source has zero alpha). For these the
    /// blitter's row-by-row pass through the affected bbox is insufficient
    /// — the spec's "the shape is drawn as a separate layer, then that
    /// layer is composited with the canvas" model REQUIRES seeing the full
    /// canvas. Routed via `SmCanvas.beginCompositeLayer` /
    /// `endCompositeLayer`: render onto a transparent scratch with
    /// src_over, then composite scratch → canvas across every pixel.
    ///
    /// Derivation: for a Porter-Duff operator with αs=0 (outside source),
    /// αo = αb·Fb(0,αb). When Fb(0,αb)=0 (i.e. src_in, src_out, dst_in,
    /// dst_atop, copy), αo = 0 — pixels outside must be cleared. Other
    /// modes with Fb(0,αb)>0 produce dst unchanged outside, so a row-wise
    /// blit is fine. Source-over isn't here because Fb(0,αb)=1 → αo=αb.
    pub fn requiresLayerComposite(self: BlendMode) bool {
        return switch (self) {
            // flash_alpha: out.a = da·sa, so sa=0 outside the source region
            // yields alpha 0 ≠ dst — same class as src_in.
            .src_in, .src_out, .dst_in, .dst_atop, .copy, .flash_alpha => true,
            else => false,
        };
    }
};

shader: Shader = .{ .solid = 0xFF000000 },
style: Style = .fill,
/// Stroke width in canvas pixels (HTML5 `lineWidth`, MDN
/// `unrestricted double`). f64 to match WebIDL semantics.
stroke_width: f64 = 1,
/// HTML5 `lineCap`. Applied at endpoints of OPEN polylines only.
line_cap: LineCap = .butt,
/// HTML5 `lineJoin`. Applied at interior polyline vertices and at the
/// closing seam of CLOSED subpaths.
line_join: LineJoin = .miter,
/// HTML5 `miterLimit`. Joins exceeding this ratio fall back to bevel.
miter_limit: f64 = 10.0,
blend_mode: BlendMode = .src_over,
/// Per-paint alpha modulator (0..255). Solid paints fold this into their
/// `Shader.solid` color at construction time (`SmCanvas.applyAlphaModulation`).
/// Gradient paints carry it through to `SmBlitter.dispatchGradient`, which
/// applies it per pixel after the sampler — so changing `globalAlpha`
/// between draw calls doesn't require resampling stops.
global_alpha: u8 = 0xFF,
/// Destination surface byte order (SkColorType analog). Drives the late
/// R↔B swizzle of resolved source colors and the choice of the four
/// lum-asymmetric non-separable blend kernels. Set by `SmCanvas` from
/// `surface.color_type`; the one-pixel paints the blitter synthesizes
/// keep the `.rgba8888` default because their colors are already in
/// surface order (the kernel choice travels separately).
dst_color_type: types.ColorType = .rgba8888,
/// Per-paint color transform. Same fold/carry split as `global_alpha`:
/// solid paints fold it at construction (`SmCanvas.paintFromShader`) and
/// emit identity here; gradient/pattern/drawImage paints carry it and
/// `SmBlitter` applies it per pixel post-sample, BEFORE the alpha
/// modulators. The one-pixel paints the blitter synthesizes stay identity
/// so already-transformed colors are never transformed twice.
cxform: ColorTransform = .{},

// ---------------------------------------------------------------------------
// Static factories — Skia-style.
// ---------------------------------------------------------------------------

/// Solid-color fill paint.
pub fn fill(color: u32) SmPaint {
    return .{ .shader = .{ .solid = color }, .style = .fill };
}

/// Solid-color stroke paint.
pub fn stroke(color: u32, width: f64) SmPaint {
    return .{ .shader = .{ .solid = color }, .style = .stroke, .stroke_width = width };
}

// ---------------------------------------------------------------------------
// Style predicates — used by Canvas drawing dispatch.
// ---------------------------------------------------------------------------

pub inline fn includesFill(self: Style) bool {
    return self == .fill or self == .fill_and_stroke;
}

pub inline fn includesStroke(self: Style) bool {
    return self == .stroke or self == .fill_and_stroke;
}

// --- Tests ---------------------------------------------------------------

test "ColorTransform identity" {
    const id: ColorTransform = .{};
    try std.testing.expect(id.isIdentity());
    try std.testing.expectEqual(@as(u32, 0x80FF8040), id.apply(0x80FF8040));
}

test "ColorTransform mult+add per channel with clamping" {
    // src (r,g,b,a) = (200, 100, 50, 255)
    const src: u32 = 200 | (100 << 8) | (50 << 16) | (255 << 24);
    const t: ColorTransform = .{
        .mult = .{ 128, 256, 256, 256 }, // r × 0.5
        .add = .{ 0, 64, 0, -128 },
    };
    try std.testing.expect(!t.isIdentity());
    const out = t.apply(src);
    try std.testing.expectEqual(@as(u32, 100), out & 0xFF); // (200·128)>>8
    try std.testing.expectEqual(@as(u32, 164), (out >> 8) & 0xFF); // 100+64
    try std.testing.expectEqual(@as(u32, 50), (out >> 16) & 0xFF);
    try std.testing.expectEqual(@as(u32, 127), (out >> 24) & 0xFF); // 255-128

    const sat: ColorTransform = .{ .add = .{ 255, -255, 0, 0 } };
    const out2 = sat.apply(src);
    try std.testing.expectEqual(@as(u32, 255), out2 & 0xFF); // clamped high
    try std.testing.expectEqual(@as(u32, 0), (out2 >> 8) & 0xFF); // clamped low
}

test "ColorTransform concat matches sequential application" {
    const parent: ColorTransform = .{ .mult = .{ 128, 256, 256, 256 }, .add = .{ 100, 0, 0, 0 } };
    const child: ColorTransform = .{ .mult = .{ 128, 256, 256, 256 }, .add = .{ 50, 0, 0, 0 } };
    const combined = parent.concat(child);
    // Sequential vs concat can differ by 1 LSB from double rounding; the
    // chosen fixtures land exactly.
    const src: u32 = 200; // red channel only
    try std.testing.expectEqual(parent.apply(child.apply(src)), combined.apply(src));
    try std.testing.expectEqual(@as(i16, 64), combined.mult[0]); // 0.5·0.5
    try std.testing.expectEqual(@as(i16, 125), combined.add[0]); // 50·0.5+100
}
