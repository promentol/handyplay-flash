//! SmPath — the canonical path object. Mirrors Skia's `SkPath` (one class
//! for both internal current-path state and standalone paths). The HTML5
//! `Path2D` lives JS-side as a thin wrapper around this struct.
//!
//! SmCanvas holds a `path: SmPath` field for the implicit current-path
//! state, just like Skia's SkCanvas owns a current SkPath. JS callers create
//! standalone Paths via `SmPath.empty()` / `existingPath.copy()`.
//!
//! ## Storage — typed verbs + points (post-B8)
//!
//! Two parallel lists (Skia's SkPath shape):
//!
//!   verbs:  `SmList(u8)`   — one Opcode tag byte per segment.
//!   points: `SmList(f64)`  — flat float stream consumed per verb.
//!
//! Float counts per verb (see `floatCount`):
//!
//!   close      — 0 floats
//!   move_to    — 2 floats (x, y)
//!   line_to    — 2 floats (x, y)
//!   quad_to    — 4 floats (cpx, cpy, x, y)
//!   bezier_to  — 6 floats (cp1x, cp1y, cp2x, cp2y, x, y)
//!   rect_path  — 4 floats (x, y, w, h)
//!
//! Consumers walk verbs and advance a points cursor by `floatCount(verb)`
//! per step — see `SmScan.walkOpcodes`.
//!
//! ## Allocator (post-A2)
//!
//! Each SmPath stores its own `std.mem.Allocator`. Default is
//! `std.heap.page_allocator` so JS-binding factories (`empty()`, the JS-
//! constructed Path2D) need no changes. Pure-Zig callers use
//! `SmPath.emptyWithAllocator(...)` or set `.allocator = ...` at struct-
//! literal construction. SmCanvas inherits its surface's allocator into
//! its embedded path.

const std = @import("std");
const SmMatrix = @import("SmMatrix.zig");
const SmList = @import("../utils/SmList.zig").SmList;

const SmPath = @This();

// ── Opcode enum ─────────────────────────────────────────────────────────────

/// Path opcode tags.  Each is a 1-byte discriminant; payload widths are
/// fixed (see module doc comment + `floatCount`).
pub const Opcode = enum(u8) {
    close = 0,
    move_to = 1,
    line_to = 2,
    quad_to = 3,
    bezier_to = 4,
    rect_path = 5,
};

/// Float count consumed by each opcode from the points stream.
pub fn floatCount(op: Opcode) u8 {
    return switch (op) {
        .close => 0,
        .move_to, .line_to => 2,
        .quad_to, .rect_path => 4,
        .bezier_to => 6,
    };
}

// ── SmPath fields ────────────────────────────────────────────────────────────

verbs: SmList(u8) = .{},
points: SmList(f64) = .{},
/// Allocator used for verbs/points growth. Default page_allocator keeps
/// JS-binding factories (`empty()`) unchanged; pure-Zig callers can
/// override via `emptyWithAllocator` or by setting the field directly at
/// construction.
allocator: std.mem.Allocator = std.heap.page_allocator,
/// True when the current sub-path has been started (via moveTo or implicitly)
/// and has not yet been explicitly closed.
subpath_open: bool = false,
/// Current pen position — last (x, y) reached by the path.
/// Required by `arcTo` (the spec uses it as `P0`) and updated by every
/// emit method. `closePath` snaps this back to `last_move_point`.
current_point: [2]f64 = .{ 0, 0 },
/// (x, y) of the most recent `move_to`. `closePath` snaps `current_point`
/// here.
last_move_point: [2]f64 = .{ 0, 0 },

// ── Static factories (Skia-style — `SkPath::Make*`) ─────────────────────────

/// empty() — returns a fresh empty SmPath using `page_allocator`. Backs
/// JS `new Path2D()`. JS bindings can't pass an allocator, so this is the
/// JS-callable shape.
pub fn empty() SmPath {
    return .{};
}

/// emptyWithAllocator(allocator) — pure-Zig variant for tests / explicit
/// allocator threading. Not surfaced to JS.
pub fn emptyWithAllocator(allocator: std.mem.Allocator) SmPath {
    return .{ .allocator = allocator };
}

// ── SmPath methods ──────────────────────────────────────────────────────────

/// Free the underlying verbs/points buffers.
pub fn deinit(self: *SmPath) void {
    self.verbs.deinit(self.allocator);
    self.points.deinit(self.allocator);
}

/// copy() — return a new SmPath containing a copy of `self`'s storage.
/// The copy inherits `self`'s allocator. Returns error.OutOfMemory on
/// alloc failure.
pub fn copy(self: *const SmPath) !SmPath {
    var p: SmPath = .{ .allocator = self.allocator };
    try p.addPath(self);
    return p;
}

/// Reset the path — equivalent to beginPath() on the canvas.
pub fn clear(self: *SmPath) void {
    self.verbs.clearRetainingCapacity();
    self.points.clearRetainingCapacity();
    self.subpath_open = false;
    self.current_point = .{ 0, 0 };
    self.last_move_point = .{ 0, 0 };
}

/// Append a verb byte with no points.
fn appendVerb(self: *SmPath, op: Opcode) !void {
    try self.verbs.append(self.allocator, @intFromEnum(op));
}

/// Append a verb byte plus its point payload. Capacity reserved up front
/// so a partial write cannot leave the verb without its coords.
fn appendSegment(self: *SmPath, op: Opcode, coords: []const f64) !void {
    std.debug.assert(coords.len == floatCount(op));
    try self.verbs.ensureUnusedCapacity(self.allocator, 1);
    try self.points.ensureUnusedCapacity(self.allocator, coords.len);
    self.verbs.ptr[self.verbs.len] = @intFromEnum(op);
    self.verbs.len += 1;
    @memcpy(self.points.ptr[self.points.len..][0..coords.len], coords);
    self.points.len += coords.len;
}

/// closePath() — emit a close opcode if a sub-path is open; no-op otherwise.
pub fn closePath(self: *SmPath) void {
    if (!self.subpath_open) return;
    self.appendVerb(.close) catch {};
    self.subpath_open = false;
    self.current_point = self.last_move_point;
}

/// moveTo(x, y) — begin a new sub-path at (x, y).  Non-finite args: no-op.
pub fn moveTo(self: *SmPath, x: f64, y: f64) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    self.appendSegment(.move_to, &[_]f64{ x, y }) catch return;
    self.subpath_open = true;
    self.current_point = .{ x, y };
    self.last_move_point = .{ x, y };
}

/// Internal: if no sub-path is open, emit an implicit moveTo(fallback_x, fallback_y).
/// Returns false if the emit failed (OOM) and the caller should bail.
pub fn ensureSubpath(self: *SmPath, fallback_x: f64, fallback_y: f64) bool {
    if (self.subpath_open) return true;
    self.appendSegment(.move_to, &[_]f64{ fallback_x, fallback_y }) catch return false;
    self.subpath_open = true;
    self.current_point = .{ fallback_x, fallback_y };
    self.last_move_point = .{ fallback_x, fallback_y };
    return true;
}

/// lineTo(x, y) — connect the last point to (x, y).  Non-finite args: no-op.
/// Implicit moveTo(x, y) if no sub-path is open.
pub fn lineTo(self: *SmPath, x: f64, y: f64) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    if (!self.ensureSubpath(x, y)) return;
    self.appendSegment(.line_to, &[_]f64{ x, y }) catch return;
    self.current_point = .{ x, y };
}

/// bezierCurveTo — cubic Bézier.  Non-finite args: no-op.
/// Implicit moveTo(cp1x, cp1y) if no sub-path is open.
pub fn bezierCurveTo(
    self: *SmPath,
    cp1x: f64,
    cp1y: f64,
    cp2x: f64,
    cp2y: f64,
    x: f64,
    y: f64,
) void {
    if (!std.math.isFinite(cp1x) or !std.math.isFinite(cp1y) or
        !std.math.isFinite(cp2x) or !std.math.isFinite(cp2y) or
        !std.math.isFinite(x) or !std.math.isFinite(y)) return;
    if (!self.ensureSubpath(cp1x, cp1y)) return;
    self.appendSegment(
        .bezier_to,
        &[_]f64{ cp1x, cp1y, cp2x, cp2y, x, y },
    ) catch return;
    self.current_point = .{ x, y };
}

/// quadraticCurveTo — quadratic Bézier.  Non-finite args: no-op.
/// Implicit moveTo(cpx, cpy) if no sub-path is open.
pub fn quadraticCurveTo(self: *SmPath, cpx: f64, cpy: f64, x: f64, y: f64) void {
    if (!std.math.isFinite(cpx) or !std.math.isFinite(cpy) or
        !std.math.isFinite(x) or !std.math.isFinite(y)) return;
    if (!self.ensureSubpath(cpx, cpy)) return;
    self.appendSegment(.quad_to, &[_]f64{ cpx, cpy, x, y }) catch return;
    self.current_point = .{ x, y };
}

/// rect(x, y, w, h) — add a closed rectangular sub-path.
/// Any non-finite argument is a no-op per spec.
/// After emit, `subpath_open` is false — the rect closes its own sub-path;
/// subsequent path methods start fresh. Per spec the current point ends
/// at (x, y).
pub fn rect(self: *SmPath, x: f64, y: f64, w: f64, h: f64) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(w) or !std.math.isFinite(h)) return;
    self.appendSegment(.rect_path, &[_]f64{ x, y, w, h }) catch return;
    self.subpath_open = false;
    self.current_point = .{ x, y };
    self.last_move_point = .{ x, y };
}

// --- Arcs (T6) -----------------------------------------------------------
//
// `arc` and `ellipse` flatten to line segments at append time. Number of
// segments is chosen so each segment's chord-error against the true arc is
// below `arc_chord_tolerance` (0.1 px). The flattening lives here on
// SmPath so JS Path2D users get arc / ellipse for free; the matching
// methods on SmCanvas apply the CTM via `self.lineTo` per generated point.
//
// 0.1 px (vs the prior 0.25) cuts the per-vertex coverage discontinuity
// along stroked curves — the speckling that put thin and thick stroked
// circles at SSIM ~0.992 vs Skia, which uses analytic cubic-Bézier curves.
// Stroke outline inflation in `SmScan.emitArcFan` also hits this constant
// (round caps + round joins), so cap silhouettes tighten too.

const arc_chord_tolerance: f64 = 0.1;
const two_pi: f64 = 2.0 * std.math.pi;

/// arcSegmentCount(r, sweep) — minimum line-segment count along a circular
/// arc of radius `r` covering `sweep` radians, such that each segment's
/// chord-error is below `arc_chord_tolerance`:
///
///   chord_err = r * (1 - cos(angle_step / 2))
///   step      = 2 · acos(1 - tolerance / r)
///   N         = ⌈|sweep| / step⌉ (floor of 8 segments).
///
/// Public so SmCanvas can match the same heuristic without re-deriving.
pub fn arcSegmentCount(r: f64, sweep: f64) u32 {
    if (r <= 0.5) return 8;
    const ratio = 1.0 - arc_chord_tolerance / r;
    if (ratio <= -1.0) return 8;
    const step = 2.0 * std.math.acos(@max(-1.0, ratio));
    if (step <= 0) return 8;
    const n_f = @abs(sweep) / step;
    if (n_f < 8.0) return 8;
    return @as(u32, @intFromFloat(@ceil(n_f)));
}

/// Normalize an arc sweep per HTML5 spec.
///   ccw = false  → result in [0, 2π]
///   ccw = true   → result in [-2π, 0]
/// Out-of-range inputs are clamped at one full revolution.
pub fn normalizeSweep(start_angle: f64, end_angle: f64, ccw: bool) f64 {
    var sweep: f64 = end_angle - start_angle;
    if (ccw) {
        if (sweep > 0) sweep -= two_pi;
        if (sweep < -two_pi) sweep = -two_pi;
    } else {
        if (sweep < 0) sweep += two_pi;
        if (sweep > two_pi) sweep = two_pi;
    }
    return sweep;
}

/// arc(cx, cy, r, startAngle, endAngle, counterclockwise) — circular arc.
/// Per HTML5 spec: lineTo to arc start (or implicit moveTo if no subpath
/// is open); negative radius is a no-op.
pub fn arc(
    self: *SmPath,
    cx: f64,
    cy: f64,
    r: f64,
    start_angle: f64,
    end_angle: f64,
    ccw: bool,
) void {
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(r) or
        !std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) return;
    if (r < 0) return;
    if (r == 0) {
        self.lineTo(cx, cy);
        return;
    }
    const sweep = normalizeSweep(start_angle, end_angle, ccw);
    const n = arcSegmentCount(r, sweep);
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const a = start_angle + t * sweep;
        self.lineTo(cx + r * @cos(a), cy + r * @sin(a));
    }
}

/// ellipse(cx, cy, rx, ry, rotation, startAngle, endAngle, counterclockwise)
/// — elliptical arc with axis lengths (rx, ry) and an overall rotation
/// (radians). Segment count uses max(rx, ry) as the conservative radius.
pub fn ellipse(
    self: *SmPath,
    cx: f64,
    cy: f64,
    rx: f64,
    ry: f64,
    rotation: f64,
    start_angle: f64,
    end_angle: f64,
    ccw: bool,
) void {
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(rx) or !std.math.isFinite(ry) or
        !std.math.isFinite(rotation) or
        !std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) return;
    if (rx < 0 or ry < 0) return;
    if (rx == 0 or ry == 0) {
        self.lineTo(cx, cy);
        return;
    }
    const sweep = normalizeSweep(start_angle, end_angle, ccw);
    const n = arcSegmentCount(@max(rx, ry), sweep);
    const cos_rot = @cos(rotation);
    const sin_rot = @sin(rotation);
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const a = start_angle + t * sweep;
        const lx = rx * @cos(a);
        const ly = ry * @sin(a);
        self.lineTo(cx + lx * cos_rot - ly * sin_rot, cy + lx * sin_rot + ly * cos_rot);
    }
}

/// arcTo(x1, y1, x2, y2, r) — emit a line from the current point to the
/// tangent point on the segment (P0, P1), followed by a circular arc of
/// radius `r` ending at the tangent point on (P1, P2). Per HTML5 spec:
///   * Non-finite args ⇒ no-op.
///   * No subpath open ⇒ implicit `moveTo(x1, y1)`, no arc emitted.
///   * Negative `r` ⇒ reject (caller is expected to throw IndexSizeError;
///     here we silently no-op).
///   * Colinear (P0, P1, P2) or `r == 0` ⇒ degenerate to `lineTo(x1, y1)`.
pub fn arcTo(self: *SmPath, x1: f64, y1: f64, x2: f64, y2: f64, r: f64) void {
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1) or
        !std.math.isFinite(x2) or !std.math.isFinite(y2) or
        !std.math.isFinite(r)) return;
    if (r < 0) return;

    if (!self.subpath_open) {
        self.moveTo(x1, y1);
        return;
    }

    const x0 = self.current_point[0];
    const y0 = self.current_point[1];

    // Vectors from P1 → P0 and P1 → P2.
    const ax = x0 - x1;
    const ay = y0 - y1;
    const bx = x2 - x1;
    const by = y2 - y1;
    const a_len = @sqrt(ax * ax + ay * ay);
    const b_len = @sqrt(bx * bx + by * by);

    if (a_len == 0 or b_len == 0 or r == 0) {
        self.lineTo(x1, y1);
        return;
    }

    const ux = ax / a_len;
    const uy = ay / a_len;
    const vx = bx / b_len;
    const vy = by / b_len;

    // cos of the angle at P1, between rays to P0 and P2.
    const cos_theta = ux * vx + uy * vy;
    // Cross product (z-component) — sign tells which side the arc curves.
    const cross = ux * vy - uy * vx;

    // Colinear (cos_theta ≈ ±1, cross ≈ 0).
    if (@abs(cross) < 1e-12) {
        self.lineTo(x1, y1);
        return;
    }

    // Half-angle is half of the angle between (P1→P0) and (P1→P2).
    // tan(half_angle) = sin / (1 + cos) — stable for cos near +1.
    const sin_theta = @abs(cross);
    const tan_half = sin_theta / (1.0 + cos_theta);

    // Distance from P1 to each tangent point along the rays.
    const d = r / tan_half;

    const t0x = x1 + ux * d;
    const t0y = y1 + uy * d;
    const t1x = x1 + vx * d;
    const t1y = y1 + vy * d;

    // Center of the arc lies on the bisector of the angle, at distance
    // r / sin(half_angle) from P1. Compute via the perpendicular of u
    // pointing toward the arc side.
    const sign: f64 = if (cross > 0) -1.0 else 1.0;
    const cx_off = ux + vx;
    const cy_off = uy + vy;
    const bisector_len = @sqrt(cx_off * cx_off + cy_off * cy_off);
    // Distance from P1 to center: r / sin(half_angle).
    // sin(half_angle) = sqrt((1 - cos_theta)/2).
    const half_cos = @sqrt(@max(0.0, (1.0 + cos_theta) / 2.0));
    const half_sin = @sqrt(@max(0.0, (1.0 - cos_theta) / 2.0));
    _ = half_cos;
    if (half_sin == 0 or bisector_len == 0) {
        self.lineTo(x1, y1);
        return;
    }
    const cdist = r / half_sin;
    const cx = x1 + (cx_off / bisector_len) * cdist;
    const cy = y1 + (cy_off / bisector_len) * cdist;

    // Start/end angles measured from the center.
    const start_angle = std.math.atan2(t0y - cy, t0x - cx);
    const end_angle = std.math.atan2(t1y - cy, t1x - cx);

    // Direction follows the cross sign: cross > 0 means anticlockwise
    // from u to v in screen-y-down coords ⇒ the arc goes counterclockwise.
    const ccw = sign < 0;

    // Line to first tangent, then arc (which uses lineTo internally).
    self.lineTo(t0x, t0y);
    self.arc(cx, cy, r, start_angle, end_angle, ccw);
}

/// roundRect(x, y, w, h, r_tl, r_tr, r_br, r_bl) — closed rectangular
/// sub-path with the given corner radii (already normalized + clamped by
/// the JS layer). Negative w / h flip orientation (HTML5 spec).
/// Each corner is a quarter-circle approximated via the same flattening
/// used by `arc()`. After emit, `subpath_open` is false (the rect closes
/// its own sub-path); current point ends at (x, y) per spec.
pub fn roundRect(
    self: *SmPath,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    r_tl: f64,
    r_tr: f64,
    r_br: f64,
    r_bl: f64,
) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(w) or !std.math.isFinite(h) or
        !std.math.isFinite(r_tl) or !std.math.isFinite(r_tr) or
        !std.math.isFinite(r_br) or !std.math.isFinite(r_bl)) return;
    // All-zero radii ⇒ plain rect, faster + identical.
    if (r_tl == 0 and r_tr == 0 and r_br == 0 and r_bl == 0) {
        self.rect(x, y, w, h);
        return;
    }
    // Spec §canvas-path-roundrect: if w or h is zero, no path is added.
    if (w == 0 or h == 0) {
        self.moveTo(x, y);
        return;
    }
    // Negative w/h flip the orientation. Per spec, when w/h is negative,
    // the corner radii rotate so that "top-left" stays at the top-left of
    // the actual drawn rectangle. Implement by swapping the appropriate
    // radii so the drawn shape matches the spec's normalization.
    var rtl = r_tl;
    var rtr = r_tr;
    var rbr = r_br;
    var rbl = r_bl;
    var ax = x;
    var ay = y;
    var aw = w;
    var ah = h;
    if (aw < 0) {
        ax += aw;
        aw = -aw;
        // Horizontal flip: tl<->tr, bl<->br.
        const t1 = rtl; rtl = rtr; rtr = t1;
        const t2 = rbl; rbl = rbr; rbr = t2;
    }
    if (ah < 0) {
        ay += ah;
        ah = -ah;
        // Vertical flip: tl<->bl, tr<->br.
        const t1 = rtl; rtl = rbl; rbl = t1;
        const t2 = rtr; rtr = rbr; rbr = t2;
    }
    // Clamp radii so adjacent corners don't overlap (spec §scale-radii).
    const top = rtl + rtr;
    const right = rtr + rbr;
    const bottom = rbl + rbr;
    const left = rtl + rbl;
    var scale: f64 = 1.0;
    if (top > aw) scale = @min(scale, aw / top);
    if (bottom > aw) scale = @min(scale, aw / bottom);
    if (left > ah) scale = @min(scale, ah / left);
    if (right > ah) scale = @min(scale, ah / right);
    if (scale < 1.0) {
        rtl *= scale;
        rtr *= scale;
        rbr *= scale;
        rbl *= scale;
    }

    const x0 = ax;
    const y0 = ay;
    const x1 = ax + aw;
    const y1 = ay + ah;

    // Trace clockwise starting at the top edge just past the top-left arc.
    self.moveTo(x0 + rtl, y0);
    self.lineTo(x1 - rtr, y0);
    if (rtr > 0) {
        // Top-right corner, sweeping from -π/2 to 0.
        self.arc(x1 - rtr, y0 + rtr, rtr, -std.math.pi / 2.0, 0.0, false);
    }
    self.lineTo(x1, y1 - rbr);
    if (rbr > 0) {
        self.arc(x1 - rbr, y1 - rbr, rbr, 0.0, std.math.pi / 2.0, false);
    }
    self.lineTo(x0 + rbl, y1);
    if (rbl > 0) {
        self.arc(x0 + rbl, y1 - rbl, rbl, std.math.pi / 2.0, std.math.pi, false);
    }
    self.lineTo(x0, y0 + rtl);
    if (rtl > 0) {
        self.arc(x0 + rtl, y0 + rtl, rtl, std.math.pi, 3.0 * std.math.pi / 2.0, false);
    }
    self.closePath();
    // Per spec the current point ends at (x, y).
    self.current_point = .{ x, y };
    self.last_move_point = .{ x, y };
}

/// addPath(other) — append `other`'s verbs+points verbatim to self.
/// Returns error.OutOfMemory on allocation failure.
pub fn addPath(self: *SmPath, other: *const SmPath) !void {
    if (other.verbs.len == 0) return;
    try self.verbs.appendSlice(self.allocator, other.verbs.ptr[0..other.verbs.len]);
    try self.points.appendSlice(self.allocator, other.points.ptr[0..other.points.len]);
    self.subpath_open = self.subpath_open or other.subpath_open;
}

/// addPathTransform(other, m) — walk `other`'s verbs and append them to
/// self with every coordinate pair transformed through the matrix `m`.
///
/// A rect_path opcode is decomposed into its four corners and emitted as a
/// closed polygon (move_to + 3×line_to + close), because an affine transform
/// of a rectangle is generally a parallelogram, not a rect.
///
/// Paired-form variant of `addPath(other)` per the project's
/// `…Settings` / `…Transform` convention. Returns error.OutOfMemory on
/// allocation failure.
pub fn addPathTransform(self: *SmPath, other: *const SmPath, m: *const SmMatrix) !void {
    var pi: usize = 0;
    for (other.verbs.ptr[0..other.verbs.len]) |tag| {
        const op: Opcode = @enumFromInt(tag);
        const points = other.points.ptr[pi..][0..floatCount(op)];
        switch (op) {
            .close => {
                try self.appendVerb(.close);
            },
            .move_to => {
                const p = m.applyToPoint(points[0], points[1]);
                try self.appendSegment(.move_to, &[_]f64{ p[0], p[1] });
            },
            .line_to => {
                const p = m.applyToPoint(points[0], points[1]);
                try self.appendSegment(.line_to, &[_]f64{ p[0], p[1] });
            },
            .quad_to => {
                const cp = m.applyToPoint(points[0], points[1]);
                const ep = m.applyToPoint(points[2], points[3]);
                try self.appendSegment(.quad_to, &[_]f64{ cp[0], cp[1], ep[0], ep[1] });
            },
            .bezier_to => {
                const c1 = m.applyToPoint(points[0], points[1]);
                const c2 = m.applyToPoint(points[2], points[3]);
                const ep = m.applyToPoint(points[4], points[5]);
                try self.appendSegment(.bezier_to, &[_]f64{
                    c1[0], c1[1], c2[0], c2[1], ep[0], ep[1],
                });
            },
            .rect_path => {
                // A transformed rect is a parallelogram — decompose into
                // move_to + 3×line_to + close so the shape is faithful.
                const rx = points[0];
                const ry = points[1];
                const rw = points[2];
                const rh = points[3];
                const tl = m.applyToPoint(rx, ry);
                const tr = m.applyToPoint(rx + rw, ry);
                const br = m.applyToPoint(rx + rw, ry + rh);
                const bl = m.applyToPoint(rx, ry + rh);
                try self.appendSegment(.move_to, &[_]f64{ tl[0], tl[1] });
                try self.appendSegment(.line_to, &[_]f64{ tr[0], tr[1] });
                try self.appendSegment(.line_to, &[_]f64{ br[0], br[1] });
                try self.appendSegment(.line_to, &[_]f64{ bl[0], bl[1] });
                try self.appendVerb(.close);
            },
        }
        pi += floatCount(op);
    }

    self.subpath_open = self.subpath_open or other.subpath_open;
}
