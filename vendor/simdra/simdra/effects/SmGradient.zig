//! SmGradient — list of color stops + geometry. Mirrors Skia's
//! `SkGradientShader`. Constructed via the static factories
//! `SmGradient.linear(...)` / `SmGradient.radial(...)`. The HTML5
//! `CanvasGradient` class is a JS-side re-export of this struct.
//!
//! `addColorStop` parses CSS colors via the shared `parseCssColor`. The
//! per-pixel samplers (`sampleLinear`, `sampleRadial`, `sampleConic`)
//! implement HTML5 pad-mode interpolation in premultiplied-alpha space
//! (no halo around translucent stops).

const std = @import("std");
const css_color = @import("../utils/css_color.zig");
const types = @import("../core/types.zig");
const SmList = @import("../utils/SmList.zig").SmList;

const SmGradient = @This();

pub const Kind = enum(u8) { linear = 0, radial = 1, conic = 2 };

/// How the gradient parameter t behaves outside [0, 1]. HTML5 canvas is
/// pad-only; `.repeat` / `.reflect` are simdra extensions (Skia's
/// `SkTileMode` / SVG `spreadMethod`), used by the Flash (SWF) renderer.
/// Append-only — values cross the JS binding as integers.
pub const Spread = enum(u8) { pad = 0, repeat = 1, reflect = 2 };

/// Stop-lookup strategy. `.exact` (default — the published HTML5 behavior)
/// scans the stop list and premul-lerps in f64 per pixel. `.lut256` bakes a
/// 256-entry ramp once and indexes it per pixel — a large win for
/// gradient-heavy content (Flash), at the cost of quantizing t to 8 bits.
/// The LUT indexes the spread-FOLDED t, so spread changes need no rebuild;
/// stop changes rebuild automatically.
pub const Sampling = enum(u8) { exact = 0, lut256 = 1 };

pub const Stop = struct {
    offset: f64,
    rgba: u32,
};

/// Geometry as a discriminated union — the shape switches with the gradient
/// kind. `stops` is shared regardless and lives flat on `SmGradient`.
pub const Geometry = union(Kind) {
    linear: Linear,
    radial: Radial,
    conic: Conic,

    pub const Linear = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
    pub const Radial = struct { x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64 };
    pub const Conic = struct { startAngle: f64, x: f64, y: f64 };
};

const StopList = SmList(Stop);

/// Insert preserving non-decreasing offset order; equal-offset stops keep
/// insertion order (later inserts go after earlier ones at the same offset).
fn insertStopSorted(stops: *StopList, allocator: std.mem.Allocator, stop: Stop) !void {
    try stops.ensureUnusedCapacity(allocator, 1);
    var i: usize = 0;
    while (i < stops.len and stops.ptr[i].offset <= stop.offset) : (i += 1) {}
    if (i < stops.len) {
        var j: usize = stops.len;
        while (j > i) : (j -= 1) stops.ptr[j] = stops.ptr[j - 1];
    }
    stops.ptr[i] = stop;
    stops.len += 1;
}

geometry: Geometry,
stops: StopList = .{},
/// Spread mode for t outside [0, 1]. Defaulted so every existing
/// struct-literal construction (and the HTML5 facade) keeps pad behavior.
spread: Spread = .pad,
/// Stop-lookup strategy; see `Sampling`. Defaulted to the exact scan.
sampling: Sampling = .exact,
/// Baked 256-entry ramp when `sampling == .lut256`, else null. Owned by
/// `allocator`; freed in `deinit` / when switching back to `.exact`.
lut: ?[]u32 = null,
/// Allocator for stop list growth. JS-binding factories default to
/// `page_allocator`; pure-Zig callers can use `linearWithAllocator` /
/// `radialWithAllocator` or set `.allocator = ...` at struct-literal time.
allocator: std.mem.Allocator = std.heap.page_allocator,

// ---------------------------------------------------------------------------
// Static factories (Skia-style — mirror `SkGradientShader::MakeLinear` etc.).
// ---------------------------------------------------------------------------

/// linear(x0, y0, x1, y1) — linear gradient between two points using
/// `page_allocator`. Backs JS `ctx.createLinearGradient(...)`.
pub fn linear(x0: f64, y0: f64, x1: f64, y1: f64) SmGradient {
    return .{ .geometry = .{ .linear = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } } };
}

/// radial(x0, y0, r0, x1, y1, r1) — radial gradient using `page_allocator`.
/// Backs JS `ctx.createRadialGradient(...)`.
pub fn radial(x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64) SmGradient {
    return .{
        .geometry = .{ .radial = .{ .x0 = x0, .y0 = y0, .r0 = r0, .x1 = x1, .y1 = y1, .r1 = r1 } },
    };
}

/// linearWithAllocator(allocator, ...) — pure-Zig variant for tests / explicit
/// allocator threading.
pub fn linearWithAllocator(allocator: std.mem.Allocator, x0: f64, y0: f64, x1: f64, y1: f64) SmGradient {
    return .{
        .geometry = .{ .linear = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } },
        .allocator = allocator,
    };
}

/// radialWithAllocator(allocator, ...) — pure-Zig variant.
pub fn radialWithAllocator(allocator: std.mem.Allocator, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64) SmGradient {
    return .{
        .geometry = .{ .radial = .{ .x0 = x0, .y0 = y0, .r0 = r0, .x1 = x1, .y1 = y1, .r1 = r1 } },
        .allocator = allocator,
    };
}

/// conic(startAngle, x, y) — angular sweep gradient using `page_allocator`.
/// Backs JS `ctx.createConicGradient(...)`. `startAngle` is in radians,
/// measured clockwise from the positive x-axis (HTML5 spec §canvas-2d-create-conic).
pub fn conic(startAngle: f64, x: f64, y: f64) SmGradient {
    return .{
        .geometry = .{ .conic = .{ .startAngle = startAngle, .x = x, .y = y } },
    };
}

/// conicWithAllocator(allocator, ...) — pure-Zig variant.
pub fn conicWithAllocator(allocator: std.mem.Allocator, startAngle: f64, x: f64, y: f64) SmGradient {
    return .{
        .geometry = .{ .conic = .{ .startAngle = startAngle, .x = x, .y = y } },
        .allocator = allocator,
    };
}

pub fn deinit(self: *SmGradient) void {
    if (self.lut) |l| {
        self.allocator.free(l);
        self.lut = null;
    }
    self.stops.deinit(self.allocator);
}

/// setSpread(mode) — select pad / repeat / reflect behavior for t outside
/// [0, 1]. Setter (not a factory parameter) so the existing factory
/// arities stay binding-compatible. (The LUT indexes folded t, so no
/// rebuild is needed here.)
pub fn setSpread(self: *SmGradient, mode: Spread) void {
    self.spread = mode;
}

/// setSampling(strategy) — switch between the exact per-pixel stop scan
/// and the baked 256-entry ramp. Building the ramp allocates once; on
/// allocation failure the gradient silently stays `.exact` (correct,
/// just slower).
pub fn setSampling(self: *SmGradient, s: Sampling) void {
    self.sampling = s;
    self.rebuildLut();
}

fn rebuildLut(self: *SmGradient) void {
    if (self.sampling != .lut256) {
        if (self.lut) |l| {
            self.allocator.free(l);
            self.lut = null;
        }
        return;
    }
    const l = self.lut orelse self.allocator.alloc(u32, 256) catch {
        self.sampling = .exact;
        return;
    };
    self.lut = l;
    for (l, 0..) |*e, i| {
        e.* = self.colorAtFolded(@as(f64, @floatFromInt(i)) / 255.0);
    }
}

// addColorStop(offset, color) — MDN: insert a color stop at `offset` ∈ [0,1].
// Spec semantics:
//   * Throws IndexSizeError if offset is non-finite or outside [0, 1].
//   * Throws SyntaxError if the color string can't be parsed.
//   * Equal-offset stops are kept in insertion order.
pub const AddColorStopError = error{ IndexSize, Syntax } || std.mem.Allocator.Error;

pub fn addColorStop(
    self: *SmGradient,
    offset: f64,
    color: []const u8,
) AddColorStopError!void {
    if (!std.math.isFinite(offset) or offset < 0 or offset > 1) {
        return error.IndexSize;
    }
    const rgba = css_color.parse(color) orelse return error.Syntax;
    try insertStopSorted(&self.stops, self.allocator, .{ .offset = offset, .rgba = rgba });
    if (self.sampling == .lut256) self.rebuildLut();
}

// --- Per-pixel sampling --------------------------------------------------
// Pad-mode (HTML5): t outside [0,1] clamps to the nearest stop. Premul-aware
// 8-bit lerp on packed RGBA so translucent stops don't bleed RGB across
// edges (no halo around the alpha=0 side of a stop).

/// 8-bit premul lerp between two packed RGBA32 colors at fractional t∈[0,1].
/// Formula: out_c = (lo_c·(1-t) + hi_c·t)·alpha_factor — but we lerp the
/// already-premultiplied form to avoid the halo. RGBA storage here is *not*
/// premultiplied (the rest of the pipeline uses straight alpha), so we
/// premultiply, lerp, then un-premultiply.
inline fn lerpRgbaPremul(lo: u32, hi: u32, t: f64) u32 {
    const tc = std.math.clamp(t, 0.0, 1.0);
    const lo_r: f64 = @floatFromInt(lo & 0xFF);
    const lo_g: f64 = @floatFromInt((lo >> 8) & 0xFF);
    const lo_b: f64 = @floatFromInt((lo >> 16) & 0xFF);
    const lo_a: f64 = @floatFromInt((lo >> 24) & 0xFF);
    const hi_r: f64 = @floatFromInt(hi & 0xFF);
    const hi_g: f64 = @floatFromInt((hi >> 8) & 0xFF);
    const hi_b: f64 = @floatFromInt((hi >> 16) & 0xFF);
    const hi_a: f64 = @floatFromInt((hi >> 24) & 0xFF);

    // Premultiply (R*A/255 etc.) then linearly interpolate.
    const lo_pr = lo_r * lo_a / 255.0;
    const lo_pg = lo_g * lo_a / 255.0;
    const lo_pb = lo_b * lo_a / 255.0;
    const hi_pr = hi_r * hi_a / 255.0;
    const hi_pg = hi_g * hi_a / 255.0;
    const hi_pb = hi_b * hi_a / 255.0;

    const omt = 1.0 - tc;
    const out_pr = lo_pr * omt + hi_pr * tc;
    const out_pg = lo_pg * omt + hi_pg * tc;
    const out_pb = lo_pb * omt + hi_pb * tc;
    const out_a = lo_a * omt + hi_a * tc;

    // Un-premultiply (out_c * 255 / out_a). out_a == 0 → all channels 0.
    var out_r: f64 = 0;
    var out_g: f64 = 0;
    var out_b: f64 = 0;
    if (out_a > 0) {
        out_r = out_pr * 255.0 / out_a;
        out_g = out_pg * 255.0 / out_a;
        out_b = out_pb * 255.0 / out_a;
    }

    const r: u32 = @intFromFloat(@round(std.math.clamp(out_r, 0.0, 255.0)));
    const g: u32 = @intFromFloat(@round(std.math.clamp(out_g, 0.0, 255.0)));
    const b: u32 = @intFromFloat(@round(std.math.clamp(out_b, 0.0, 255.0)));
    const a: u32 = @intFromFloat(@round(std.math.clamp(out_a, 0.0, 255.0)));
    return r | (g << 8) | (b << 16) | (a << 24);
}

/// colorAt(t) — fold t by the spread mode, then look up: baked ramp when
/// `.lut256` is active, exact stop scan otherwise.
fn colorAt(self: *const SmGradient, t: f64) u32 {
    if (self.stops.len == 0) return 0;
    if (self.stops.len == 1) return self.stops.ptr[0].rgba;
    const tc = switch (self.spread) {
        .pad => std.math.clamp(t, 0.0, 1.0),
        // Fractional part; exact integers land on 0 (Skia repeat rule).
        .repeat => t - @floor(t),
        // Triangle wave with period 2: 0→1→0. @rem keeps the dividend's
        // sign; @abs folds negatives onto the same wave.
        .reflect => blk: {
            const m = @abs(@rem(t, 2.0));
            break :blk if (m > 1.0) 2.0 - m else m;
        },
    };
    if (self.lut) |l| {
        return l[@intFromFloat(@round(tc * 255.0))];
    }
    return self.colorAtFolded(tc);
}

/// Exact stop scan over an already-folded tc ∈ [0, 1].
fn colorAtFolded(self: *const SmGradient, tc: f64) u32 {
    if (self.stops.len == 0) return 0;
    if (self.stops.len == 1) return self.stops.ptr[0].rgba;
    var i: usize = 0;
    while (i < self.stops.len and self.stops.ptr[i].offset < tc) : (i += 1) {}
    if (i == 0) return self.stops.ptr[0].rgba;
    if (i == self.stops.len) return self.stops.ptr[self.stops.len - 1].rgba;
    const lo = self.stops.ptr[i - 1];
    const hi = self.stops.ptr[i];
    const span = hi.offset - lo.offset;
    if (span <= 0) return hi.rgba;
    const local = (tc - lo.offset) / span;
    return lerpRgbaPremul(lo.rgba, hi.rgba, local);
}

/// sampleLinear — project (x,y) onto the gradient line and look up the
/// stop color at the resulting parameter t. Degenerate (zero-length)
/// gradients return the first stop's color (matches Chrome/Firefox).
pub fn sampleLinear(self: *const SmGradient, x: f64, y: f64) u32 {
    const lin = self.geometry.linear;
    const dx = lin.x1 - lin.x0;
    const dy = lin.y1 - lin.y0;
    const len_sq = dx * dx + dy * dy;
    if (len_sq < 1e-12) return self.colorAt(0);
    const t = ((x - lin.x0) * dx + (y - lin.y0) * dy) / len_sq;
    return self.colorAt(t);
}

/// sampleRadial — solve the two-circle gradient quadratic at (x,y) for the
/// parameter t along the cone of interpolating circles between
/// (x0,y0,r0) and (x1,y1,r1). Picks the larger root that yields a
/// non-negative interpolated radius (Skia's rule); returns transparent if
/// no valid root exists at that point.
pub fn sampleRadial(self: *const SmGradient, x: f64, y: f64) u32 {
    const rad = self.geometry.radial;
    const cdx = rad.x1 - rad.x0;
    const cdy = rad.y1 - rad.y0;
    const cdr = rad.r1 - rad.r0;
    const dx = x - rad.x0;
    const dy = y - rad.y0;
    const A = cdx * cdx + cdy * cdy - cdr * cdr;
    const B = -2.0 * (dx * cdx + dy * cdy + rad.r0 * cdr);
    const C = dx * dx + dy * dy - rad.r0 * rad.r0;

    if (@abs(A) < 1e-12) {
        // Concentric / focal-on-edge cases collapse the quadratic to linear
        // in t. If B ≈ 0 too, the point is at the focal singularity —
        // return the first stop's color.
        if (@abs(B) < 1e-12) return self.colorAt(0);
        const t = -C / B;
        if (rad.r0 + t * cdr < 0) return 0;
        return self.colorAt(t);
    }

    const disc = B * B - 4.0 * A * C;
    if (disc < 0) return 0;
    const sqrt_disc = @sqrt(disc);
    const inv_2a = 1.0 / (2.0 * A);
    // Try the larger root first (Skia rule: pick the root with non-negative
    // interpolated radius; among valid roots, the larger t is correct for
    // expanding cones).
    const t_plus = (-B + sqrt_disc) * inv_2a;
    if (rad.r0 + t_plus * cdr >= 0) return self.colorAt(t_plus);
    const t_minus = (-B - sqrt_disc) * inv_2a;
    if (rad.r0 + t_minus * cdr >= 0) return self.colorAt(t_minus);
    return 0;
}

/// sampleConic — angular sweep gradient. Compute angle from the center,
/// subtract `startAngle`, normalize to [0, 1], and look up the stop color.
/// HTML5 spec measures the angle clockwise from the positive x-axis;
/// `atan2(dy, dx)` matches that since y grows downward in canvas space.
pub fn sampleConic(self: *const SmGradient, x: f64, y: f64) u32 {
    const c = self.geometry.conic;
    const dx = x - c.x;
    const dy = y - c.y;
    if (dx == 0 and dy == 0) return self.colorAt(0);
    const two_pi = 2.0 * std.math.pi;
    var angle = std.math.atan2(dy, dx) - c.startAngle;
    angle = @mod(angle, two_pi);
    if (angle < 0) angle += two_pi;
    return self.colorAt(angle / two_pi);
}

// --- Tests ---------------------------------------------------------------

fn testGradientBW(allocator: std.mem.Allocator) !SmGradient {
    var g = linearWithAllocator(allocator, 0, 0, 1, 0);
    try g.addColorStop(0.0, "black"); // 0xFF000000
    try g.addColorStop(1.0, "white"); // 0xFFFFFFFF
    return g;
}

fn gray(v: u32) u32 {
    return v | (v << 8) | (v << 16) | 0xFF000000;
}

test "colorAt pad clamps outside [0,1]" {
    var g = try testGradientBW(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectEqual(gray(0), g.colorAt(-1.5));
    try std.testing.expectEqual(gray(0), g.colorAt(-0.25));
    try std.testing.expectEqual(gray(0), g.colorAt(0.0));
    try std.testing.expectEqual(gray(128), g.colorAt(0.5));
    try std.testing.expectEqual(gray(255), g.colorAt(1.0));
    try std.testing.expectEqual(gray(255), g.colorAt(1.25));
    try std.testing.expectEqual(gray(255), g.colorAt(2.0));
}

test "colorAt repeat wraps to the fractional part" {
    var g = try testGradientBW(std.testing.allocator);
    defer g.deinit();
    g.setSpread(.repeat);
    try std.testing.expectEqual(gray(128), g.colorAt(-1.5)); // frac 0.5
    try std.testing.expectEqual(gray(0), g.colorAt(-1.0)); // exact int → 0
    try std.testing.expectEqual(gray(191), g.colorAt(-0.25)); // frac 0.75
    try std.testing.expectEqual(gray(128), g.colorAt(0.5));
    try std.testing.expectEqual(gray(0), g.colorAt(1.0)); // exact int → 0
    try std.testing.expectEqual(gray(64), g.colorAt(1.25)); // frac 0.25
    try std.testing.expectEqual(gray(0), g.colorAt(2.0));
}

test "colorAt reflect mirrors on odd periods" {
    var g = try testGradientBW(std.testing.allocator);
    defer g.deinit();
    g.setSpread(.reflect);
    try std.testing.expectEqual(gray(128), g.colorAt(-1.5)); // |rem|=1.5 → 0.5
    try std.testing.expectEqual(gray(255), g.colorAt(-1.0)); // |rem|=1 → 1
    try std.testing.expectEqual(gray(64), g.colorAt(-0.25)); // |rem|=.25
    try std.testing.expectEqual(gray(128), g.colorAt(0.5));
    try std.testing.expectEqual(gray(255), g.colorAt(1.0));
    try std.testing.expectEqual(gray(191), g.colorAt(1.25)); // 2-1.25=0.75
    try std.testing.expectEqual(gray(0), g.colorAt(2.0)); // full period
    try std.testing.expectEqual(gray(128), g.colorAt(2.5));
}

test "default spread is pad and factories stay 4/6-arg" {
    const g = linear(0, 0, 10, 0);
    try std.testing.expectEqual(Spread.pad, g.spread);
    try std.testing.expectEqual(Sampling.exact, g.sampling);
}

test "lut256 sampling matches exact at ramp sample points, folds spread" {
    var g = try testGradientBW(std.testing.allocator);
    defer g.deinit();
    g.setSpread(.repeat);
    g.setSampling(.lut256);
    try std.testing.expect(g.lut != null);
    // At exact ramp sample points t = i/255 the LUT is byte-identical to
    // the exact scan.
    var i: usize = 0;
    while (i < 256) : (i += 4) {
        const t = @as(f64, @floatFromInt(i)) / 255.0;
        try std.testing.expectEqual(g.colorAtFolded(t), g.colorAt(t));
    }
    // Spread folding happens before the LUT: repeat(1.25) hits the same
    // entry as 0.25.
    try std.testing.expectEqual(g.colorAt(0.25), g.colorAt(1.25));
    // Adding a stop rebuilds the ramp (compare at a ramp grid point —
    // t = 128/255; t = 0.5 itself sits between grid entries).
    try g.addColorStop(0.5, "#ff0000");
    const grid = 128.0 / 255.0;
    try std.testing.expectEqual(g.colorAtFolded(grid), g.colorAt(grid));
    // Switching back to exact frees the ramp.
    g.setSampling(.exact);
    try std.testing.expect(g.lut == null);
}
