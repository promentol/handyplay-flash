//! SmScan — scan converter (shape → coverage rows).
//!
//! Mirrors Skia's `SkScan`. Pure geometry: turns shapes into per-row spans
//! `(y, x_lo, x_hi[, coverage])` that the Blitter consumes. Doesn't touch
//! pixels itself.
//!
//! Rect + triangle scan emit full-coverage spans (axis-aligned shapes don't
//! need AA). `fillPath` / `strokePath` use `sweepEdges` — analytic-edge AA
//! via 8× Y-supersample + analytic-X partial coverage; per-row coverage is
//! quantized to a u8 row and dispatched through `SmBlitter.blitRow` (which
//! routes through every blend mode + clip mask). The clip-mask scan
//! (`sweepEdgesToMask`) intentionally stays binary — `SmCanvas.clipInternal`
//! intersects masks via per-pixel `min`, which assumes 0/0xFF values.

const std = @import("std");
const SmPath = @import("SmPath.zig");
const SmPaint = @import("SmPaint.zig");
const SmBlitter = @import("SmBlitter.zig");
const SmList = @import("../utils/SmList.zig").SmList;

/// HTML5 `fillRule` argument. Default `'nonzero'`. `'evenodd'` flips parity
/// at every edge crossing regardless of direction.
pub const FillRule = enum(u8) {
    nonzero = 0,
    evenodd = 1,
};

inline fn windingInside(winding: i32, fill_rule: FillRule) bool {
    return switch (fill_rule) {
        .nonzero => winding != 0,
        .evenodd => (winding & 1) != 0,
    };
}

/// Clipped axis-aligned rect in canvas pixel coordinates.
/// `x0, y0` inclusive; `x1, y1` exclusive.
pub const ClippedRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

/// clipRect — intersect a (possibly off-canvas) rect with canvas bounds.
/// Returns null if the result has zero area.
pub fn clipRect(
    canvas_w: u32,
    canvas_h: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) ?ClippedRect {
    const cw: i32 = @intCast(canvas_w);
    const ch: i32 = @intCast(canvas_h);
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(cw, x + w);
    const y1 = @min(ch, y + h);
    if (x0 >= x1 or y0 >= y1) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

// ---------------------------------------------------------------------------
// Path fill (T5) — flatten Béziers, build edge list, AET scanline sweep.
// ---------------------------------------------------------------------------
//
// Algorithm:
//   1. Walk path opcodes. Emit one Edge per line segment. Béziers are
//      flattened by recursive de Casteljau subdivision until each segment's
//      chord error is below `flatness_tolerance` (0.25 px).
//   2. Find overall y range, clip to canvas.
//   3. For each scanline y:
//      - Collect intersection x-coordinates of every active edge.
//      - Sort intersections by x.
//      - Walk left-to-right tracking winding number; emit a span between
//        every "0 → nonzero" and "nonzero → 0" transition (HTML5 nonzero
//        fill rule, the spec default).
//   4. Each span calls `SmBlitter.blitRow` — same downstream pipeline as
//      drawRect / drawTriangle. Inherits the SIMD blend kernels.
//
// SIMD note: the per-pixel hot path (Blitter.blitRow → simd kernels) is
// already vectorized. Edge intersection math runs O(edges × scanlines)
// — scalar but cache-friendly for typical canvas paths (≤ thousands of
// edges).

const flatness_tolerance: f64 = 0.25;
const flatness_tolerance_sq: f64 = flatness_tolerance * flatness_tolerance;

/// One non-horizontal line segment in the path's edge list.
pub const Edge = struct {
    y_min: f64,
    y_max: f64,
    x_at_y_min: f64,
    inv_slope: f64, // dx/dy
    direction: i8, // +1 if y increasing, -1 if y decreasing (winding contribution)
};

pub const EdgeBuf = SmList(Edge);


/// Add a line segment to the edge list, dropping horizontal segments
/// (no scanline contribution) and tracking direction for winding count.
fn addEdge(edges: *EdgeBuf, allocator: std.mem.Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !void {
    if (y0 == y1) return; // horizontal — no coverage
    var e: Edge = undefined;
    if (y0 < y1) {
        e = .{
            .y_min = y0,
            .y_max = y1,
            .x_at_y_min = x0,
            .inv_slope = (x1 - x0) / (y1 - y0),
            .direction = 1,
        };
    } else {
        e = .{
            .y_min = y1,
            .y_max = y0,
            .x_at_y_min = x1,
            .inv_slope = (x0 - x1) / (y0 - y1),
            .direction = -1,
        };
    }
    try edges.append(allocator, e);
}

/// Read a little-endian f64 at byte offset.
inline fn readF64(data: []const u8, off: usize) f64 {
    var v: f64 = undefined;
    @memcpy(std.mem.asBytes(&v), data[off..][0..8]);
    return v;
}

/// True if quadratic Bézier (p0, cp, p1) is "flat enough" (chord-distance
/// from cp to line p0-p1 below the flatness tolerance).
fn isQuadFlat(p0x: f64, p0y: f64, cpx: f64, cpy: f64, p1x: f64, p1y: f64) bool {
    const dx = p1x - p0x;
    const dy = p1y - p0y;
    const len_sq = dx * dx + dy * dy;
    if (len_sq < 1e-9) return true; // degenerate: p0 ≈ p1
    const cross = (cpx - p0x) * dy - (cpy - p0y) * dx;
    return (cross * cross) < flatness_tolerance_sq * len_sq;
}

/// Recursively flatten a quadratic Bézier into line edges.
fn flattenQuad(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    p0x: f64, p0y: f64,
    cpx: f64, cpy: f64,
    p1x: f64, p1y: f64,
    depth: u32,
) !void {
    if (depth >= 16 or isQuadFlat(p0x, p0y, cpx, cpy, p1x, p1y)) {
        try addEdge(edges, allocator, p0x, p0y, p1x, p1y);
        return;
    }
    // Split at t = 0.5 via de Casteljau.
    const m1x = (p0x + cpx) * 0.5;
    const m1y = (p0y + cpy) * 0.5;
    const m2x = (cpx + p1x) * 0.5;
    const m2y = (cpy + p1y) * 0.5;
    const mx = (m1x + m2x) * 0.5;
    const my = (m1y + m2y) * 0.5;
    try flattenQuad(edges, allocator, p0x, p0y, m1x, m1y, mx, my, depth + 1);
    try flattenQuad(edges, allocator, mx, my, m2x, m2y, p1x, p1y, depth + 1);
}

/// True if cubic Bézier (p0, c1, c2, p1) is "flat enough". Both control
/// points must be within tolerance of chord p0-p1.
fn isCubicFlat(
    p0x: f64, p0y: f64,
    c1x: f64, c1y: f64,
    c2x: f64, c2y: f64,
    p1x: f64, p1y: f64,
) bool {
    const dx = p1x - p0x;
    const dy = p1y - p0y;
    const len_sq = dx * dx + dy * dy;
    if (len_sq < 1e-9) return true;
    const cross1 = (c1x - p0x) * dy - (c1y - p0y) * dx;
    const cross2 = (c2x - p0x) * dy - (c2y - p0y) * dx;
    const max_cross_sq = @max(cross1 * cross1, cross2 * cross2);
    return max_cross_sq < flatness_tolerance_sq * len_sq;
}

/// Recursively flatten a cubic Bézier into line edges.
fn flattenCubic(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    p0x: f64, p0y: f64,
    c1x: f64, c1y: f64,
    c2x: f64, c2y: f64,
    p1x: f64, p1y: f64,
    depth: u32,
) !void {
    if (depth >= 18 or isCubicFlat(p0x, p0y, c1x, c1y, c2x, c2y, p1x, p1y)) {
        try addEdge(edges, allocator, p0x, p0y, p1x, p1y);
        return;
    }
    // Split at t = 0.5 via de Casteljau.
    const m01x = (p0x + c1x) * 0.5;
    const m01y = (p0y + c1y) * 0.5;
    const m12x = (c1x + c2x) * 0.5;
    const m12y = (c1y + c2y) * 0.5;
    const m23x = (c2x + p1x) * 0.5;
    const m23y = (c2y + p1y) * 0.5;
    const m012x = (m01x + m12x) * 0.5;
    const m012y = (m01y + m12y) * 0.5;
    const m123x = (m12x + m23x) * 0.5;
    const m123y = (m12y + m23y) * 0.5;
    const mx = (m012x + m123x) * 0.5;
    const my = (m012y + m123y) * 0.5;
    try flattenCubic(edges, allocator, p0x, p0y, m01x, m01y, m012x, m012y, mx, my, depth + 1);
    try flattenCubic(edges, allocator, mx, my, m123x, m123y, m23x, m23y, p1x, p1y, depth + 1);
}

/// walkOpcodes — single typed walker over a path's `(verbs, points)` pair.
/// Each verb advances the points cursor by `SmPath.floatCount(verb)` and
/// invokes the matching `visitor.onXxx(...)` method. The visitor holds all
/// per-walk state (current point, subpath start, etc.); errors propagate
/// from visitor methods so consumers can fail on alloc.
///
/// Replaces the previous byte-stream loop that lived in both `walkPath`
/// and `strokeWalkPath` with offset arithmetic. Visitors below: `FillVisitor`
/// (edge generation for fillPath), `StrokeVisitor` (polyline accumulation
/// for strokePath).
fn walkOpcodes(verbs: []const u8, points: []const f64, visitor: anytype) !void {
    var pi: usize = 0;
    for (verbs) |tag| {
        const op: SmPath.Opcode = @enumFromInt(tag);
        switch (op) {
            .close => try visitor.onClose(),
            .move_to => try visitor.onMoveTo(points[pi], points[pi + 1]),
            .line_to => try visitor.onLineTo(points[pi], points[pi + 1]),
            .quad_to => try visitor.onQuadTo(
                points[pi], points[pi + 1],
                points[pi + 2], points[pi + 3],
            ),
            .bezier_to => try visitor.onBezierTo(
                points[pi], points[pi + 1],
                points[pi + 2], points[pi + 3],
                points[pi + 4], points[pi + 5],
            ),
            .rect_path => try visitor.onRect(
                points[pi], points[pi + 1],
                points[pi + 2], points[pi + 3],
            ),
        }
        pi += SmPath.floatCount(op);
    }
}

/// FillVisitor — per-walk state for `fillPath`. Emits one Edge per line
/// segment, flattens Béziers, and synthesizes an implicit close edge on
/// subpath transitions (HTML5 spec semantics for `fill()`).
const FillVisitor = struct {
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    cur_x: f64 = 0,
    cur_y: f64 = 0,
    subpath_x: f64 = 0,
    subpath_y: f64 = 0,
    subpath_open: bool = false,

    fn onClose(self: *FillVisitor) !void {
        if (self.subpath_open) {
            try addEdge(self.edges, self.allocator, self.cur_x, self.cur_y, self.subpath_x, self.subpath_y);
            self.cur_x = self.subpath_x;
            self.cur_y = self.subpath_y;
            self.subpath_open = false;
        }
    }

    fn onMoveTo(self: *FillVisitor, x: f64, y: f64) !void {
        if (self.subpath_open) {
            try addEdge(self.edges, self.allocator, self.cur_x, self.cur_y, self.subpath_x, self.subpath_y);
        }
        self.cur_x = x;
        self.cur_y = y;
        self.subpath_x = x;
        self.subpath_y = y;
        self.subpath_open = true;
    }

    fn onLineTo(self: *FillVisitor, x: f64, y: f64) !void {
        try addEdge(self.edges, self.allocator, self.cur_x, self.cur_y, x, y);
        self.cur_x = x;
        self.cur_y = y;
    }

    fn onQuadTo(self: *FillVisitor, cpx: f64, cpy: f64, x: f64, y: f64) !void {
        try flattenQuad(self.edges, self.allocator, self.cur_x, self.cur_y, cpx, cpy, x, y, 0);
        self.cur_x = x;
        self.cur_y = y;
    }

    fn onBezierTo(self: *FillVisitor, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) !void {
        try flattenCubic(self.edges, self.allocator, self.cur_x, self.cur_y, c1x, c1y, c2x, c2y, x, y, 0);
        self.cur_x = x;
        self.cur_y = y;
    }

    fn onRect(self: *FillVisitor, rx: f64, ry: f64, rw: f64, rh: f64) !void {
        if (self.subpath_open) {
            try addEdge(self.edges, self.allocator, self.cur_x, self.cur_y, self.subpath_x, self.subpath_y);
        }
        // 4-edge closed subpath.
        try addEdge(self.edges, self.allocator, rx, ry, rx + rw, ry);
        try addEdge(self.edges, self.allocator, rx + rw, ry, rx + rw, ry + rh);
        try addEdge(self.edges, self.allocator, rx + rw, ry + rh, rx, ry + rh);
        try addEdge(self.edges, self.allocator, rx, ry + rh, rx, ry);
        self.subpath_open = false;
        self.cur_x = rx;
        self.cur_y = ry;
    }
};

/// One edge currently overlapping the row's vertical band. The Active Edge
/// Table holds these for `[y_int, y_int+1)`; per-sub-sample `x` is recomputed
/// from `x_at_y_min + (y_sub - y_min) * inv_slope` rather than incrementally
/// advanced — keeps every sub-sample independent and avoids accumulated
/// rounding error across 8 sub-y steps per row.
const ActiveEdge = struct {
    y_min: f64,
    y_max: f64,
    x_at_y_min: f64,
    inv_slope: f64,
    dir: i8,
};

const ActiveBuf = SmList(ActiveEdge);

/// (x, dir) pair for one active edge intersected with one sub-y sample.
/// Built fresh per sub-sample, sorted by x, then walked for inside spans.
const SubEdge = struct { x: f64, dir: i8 };

const SubEdgeBuf = SmList(SubEdge);

/// Insertion sort by `x`. Optimal for small N (typically ≤ 16); active
/// edges shift by `inv_slope * (1/8)` between sub-samples so the input is
/// nearly-sorted across iterations — worst case is rare.
fn sortSubEdgesByX(xs: []SubEdge) void {
    var i: usize = 1;
    while (i < xs.len) : (i += 1) {
        const key = xs[i];
        var j: usize = i;
        while (j > 0 and xs[j - 1].x > key.x) : (j -= 1) {
            xs[j] = xs[j - 1];
        }
        xs[j] = key;
    }
}

/// Insertion sort the edge list by `y_min`. One-time cost after edge
/// generation; lets the main sweep walk a `next_idx` cursor instead of
/// re-checking every edge per scanline.
fn sortEdgesByYMin(edges: []Edge) void {
    var i: usize = 1;
    while (i < edges.len) : (i += 1) {
        const key = edges[i];
        var j: usize = i;
        while (j > 0 and edges[j - 1].y_min > key.y_min) : (j -= 1) {
            edges[j] = edges[j - 1];
        }
        edges[j] = key;
    }
}

/// flattenPathToFillEdges — populate `edges` with the line-segment edges
/// of `path`'s fill polygon. Béziers are recursively flattened. An
/// implicit close is synthesized at end-of-path. Used by `fillPath`,
/// `fillPathToCoverage`, and the hit-test helper `isPointInPath`.
pub fn flattenPathToFillEdges(
    allocator: std.mem.Allocator,
    path: *const SmPath,
    edges: *EdgeBuf,
) !void {
    if (path.verbs.len == 0) return;
    var visitor: FillVisitor = .{ .edges = edges, .allocator = allocator };
    try walkOpcodes(path.verbs.ptr[0..path.verbs.len], path.points.ptr[0..path.points.len], &visitor);
    if (visitor.subpath_open) {
        try addEdge(visitor.edges, allocator, visitor.cur_x, visitor.cur_y, visitor.subpath_x, visitor.subpath_y);
    }
}

/// pointInEdges — point-in-polygon test against a flattened edge list.
/// For `nonzero`, returns true if the signed winding of the edges crossed
/// to the left of (x, y) is non-zero. For `evenodd`, returns true if the
/// count of edges crossed is odd.
///
/// Edge inclusion rule: the half-open interval [y_min, y_max) — matches the
/// scanline rasterizer. This avoids double-counting when an edge endpoint
/// sits exactly on the query y.
pub fn pointInEdges(edges: []const Edge, x: f64, y: f64, fill_rule: FillRule) bool {
    var winding: i32 = 0;
    for (edges) |e| {
        if (y < e.y_min or y >= e.y_max) continue;
        const x_at_y = e.x_at_y_min + e.inv_slope * (y - e.y_min);
        if (x_at_y < x) winding += @as(i32, e.direction);
    }
    return windingInside(winding, fill_rule);
}

/// fillPath — main entry. Build edges from path, sweep, blit.
///
/// `aa_accum` and `cov_row` are caller-owned per-row scratch buffers,
/// each sized to at least `canvas_w`. Reused across scanlines and
/// across `fill()` / `stroke()` calls (allocated lazily on `SmCanvas`).
pub fn fillPath(
    allocator: std.mem.Allocator,
    pixels: []u32,
    canvas_w: u32,
    canvas_h: u32,
    path: *const SmPath,
    fill_rule: FillRule,
    clip_mask: ?[]const u8,
    paint: *const SmPaint,
    aa_accum: []f32,
    cov_row: []u8,
) !void {
    if (path.verbs.len == 0) return;
    if (canvas_w == 0 or canvas_h == 0) return;

    var edges: EdgeBuf = .{};
    defer edges.deinit(allocator);
    try flattenPathToFillEdges(allocator, path, &edges);
    try sweepEdges(&edges, allocator, pixels, canvas_w, canvas_h, fill_rule, clip_mask, paint, aa_accum, cov_row);
}

/// fillPolygonF — fill an arbitrary simple polygon with anti-aliasing.
/// `vertices` is the closed ring; an implicit close from `vertices[n-1]`
/// to `vertices[0]` is added. Uses `.evenodd` fill rule so the caller
/// doesn't need to worry about winding direction (simple polygons fill
/// identically under either rule). Used by `SmCanvas.drawTriangle` and
/// the rotated-`drawRect` decomposition — keeps those paths AA without
/// going through the SmPath verb stream / Bézier flattener.
pub fn fillPolygonF(
    allocator: std.mem.Allocator,
    pixels: []u32,
    canvas_w: u32,
    canvas_h: u32,
    vertices: []const [2]f64,
    clip_mask: ?[]const u8,
    paint: *const SmPaint,
    aa_accum: []f32,
    cov_row: []u8,
) !void {
    if (vertices.len < 3) return;
    if (canvas_w == 0 or canvas_h == 0) return;
    var edges: EdgeBuf = .{};
    defer edges.deinit(allocator);
    var i: usize = 0;
    while (i < vertices.len) : (i += 1) {
        const j: usize = if (i + 1 == vertices.len) 0 else i + 1;
        try addEdge(
            &edges, allocator,
            vertices[i][0], vertices[i][1],
            vertices[j][0], vertices[j][1],
        );
    }
    try sweepEdges(
        &edges, allocator, pixels, canvas_w, canvas_h,
        .evenodd, clip_mask, paint, aa_accum, cov_row,
    );
}

/// fillPathToCoverage — same scan as `fillPath` but writes per-pixel u8
/// coverage into `mask` for every pixel inside the path. Used to build
/// the clip mask in `SmCanvas.clip`. Existing mask bytes are NOT touched
/// outside the painted region — caller is responsible for zero-initializing
/// if a fresh mask is wanted. Intersection with a prior mask is the
/// caller's job (see `SmCanvas.clipInternal`).
///
/// Coverage emission is AA (matches `sweepEdges`) so curved clip paths
/// produce fractional boundary coverage; the multiplicative intersection
/// in `clipInternal` and the existing `(cov * clip + 127) / 255` clip
/// combination inside `SmBlitter.blitRow` together compose AA shapes
/// correctly across AA clip boundaries.
///
/// Allocates per-row AA scratches (`aa_accum: []f32`, `cov_row: []u8`)
/// locally — clip is a save/restore-time op (rare), no need to thread
/// scratches through from `SmCanvas`.
pub fn fillPathToCoverage(
    allocator: std.mem.Allocator,
    mask: []u8,
    canvas_w: u32,
    canvas_h: u32,
    path: *const SmPath,
    fill_rule: FillRule,
) !void {
    if (path.verbs.len == 0) return;
    if (canvas_w == 0 or canvas_h == 0) return;

    var edges: EdgeBuf = .{};
    defer edges.deinit(allocator);
    try flattenPathToFillEdges(allocator, path, &edges);

    const aa_accum = try allocator.alloc(f32, canvas_w);
    defer allocator.free(aa_accum);
    const cov_row = try allocator.alloc(u8, canvas_w);
    defer allocator.free(cov_row);

    try sweepEdgesToCoverageMask(
        &edges, allocator, mask, canvas_w, canvas_h, fill_rule, aa_accum, cov_row,
    );
}

/// Number of sub-y samples per integer scanline for AA path fills.
/// 8 levels per axis combined with analytic-x partial coverage gives full
/// 256-level alpha output — the per-sub-sample contribution is a float,
/// summed without precision loss before the final u8 quantization.
const aa_sub_count: u32 = 8;
const aa_sub_weight: f32 = 1.0 / @as(f32, @floatFromInt(aa_sub_count));

/// depositSpan — accumulate fractional coverage for one sub-y horizontal
/// span `[x_lo, x_hi)` into the row's f32 accumulator at the per-sub-sample
/// `weight` (`= 1 / aa_sub_count`). Cells fully inside the span receive the
/// full weight; the leftmost / rightmost cells receive a fraction equal to
/// the analytic overlap length (analytic-x partial coverage). After all 8
/// sub-samples the accumulator holds the box-filtered pixel coverage in
/// `[0, 1]` — quantized to a u8 row before being fed to `SmBlitter.blitRow`.
inline fn depositSpan(accum: []f32, x_lo: f64, x_hi: f64, weight: f32, cw: i32) void {
    const cw_f: f64 = @floatFromInt(cw);
    const x_lo_c: f64 = @max(0.0, x_lo);
    const x_hi_c: f64 = @min(cw_f, x_hi);
    if (x_hi_c <= x_lo_c) return;

    const i_first: i32 = @as(i32, @intFromFloat(@floor(x_lo_c)));
    const i_last: i32 = @as(i32, @intFromFloat(@ceil(x_hi_c))) - 1;
    if (i_first == i_last) {
        accum[@intCast(i_first)] += weight * @as(f32, @floatCast(x_hi_c - x_lo_c));
        return;
    }
    const left_partial: f64 = @as(f64, @floatFromInt(i_first + 1)) - x_lo_c;
    accum[@intCast(i_first)] += weight * @as(f32, @floatCast(left_partial));
    var k: i32 = i_first + 1;
    while (k < i_last) : (k += 1) {
        accum[@intCast(k)] += weight;
    }
    const right_partial: f64 = x_hi_c - @as(f64, @floatFromInt(i_last));
    accum[@intCast(i_last)] += weight * @as(f32, @floatCast(right_partial));
}

/// sweepEdges — scanline sweep with anti-aliased per-pixel coverage.
///
/// Per integer row `y_int`:
///   1. Drop active edges whose `y_max ≤ y_top` (left the row band).
///   2. Admit edges whose `y_min < y_bot` (entered the row at any sub-y).
///   3. Zero the f32 accumulator across the row's touched x-range.
///   4. For each of `aa_sub_count` sub-y samples spaced `1 / N` apart:
///      a. Build a (x, dir) sub-list of active edges live at `y_sub`
///         (`y_min ≤ y_sub < y_max`); compute x analytically from
///         `x_at_y_min + (y_sub - y_min) * inv_slope`.
///      b. Sort by x (insertion — input is near-sorted across sub-samples).
///      c. Walk for inside spans per `fill_rule`; deposit each `[x_lo, x_hi)`
///         span into the accumulator with weight `1 / N` and analytic-x
///         partial-pixel coverage on the leftmost / rightmost cells.
///   5. Quantize the accumulator into the u8 `cov_row`; emit one
///      `SmBlitter.blitRow` per non-zero run (blitter combines per-pixel
///      coverage with the optional clip mask, then dispatches by blend mode).
///
/// Acceptance bar: SSIM vs `@napi-rs/canvas` (Skia) on every curve scene.
/// Output is intentionally NOT byte-equal to the previous binary-span path
/// — every shape with a curved or non-axis-aligned edge changes.
fn sweepEdges(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    pixels: []u32,
    canvas_w: u32,
    canvas_h: u32,
    fill_rule: FillRule,
    clip_mask: ?[]const u8,
    paint: *const SmPaint,
    aa_accum: []f32,
    cov_row: []u8,
) !void {
    if (edges.len == 0) return;
    if (aa_accum.len < canvas_w or cov_row.len < canvas_w) return;

    sortEdgesByYMin(edges.ptr[0..edges.len]);

    var y_min_total: f64 = std.math.inf(f64);
    var y_max_total: f64 = -std.math.inf(f64);
    for (edges.ptr[0..edges.len]) |e| {
        if (e.y_min < y_min_total) y_min_total = e.y_min;
        if (e.y_max > y_max_total) y_max_total = e.y_max;
    }

    const ch_i: i32 = @intCast(canvas_h);
    const cw_i: i32 = @intCast(canvas_w);
    const y_start: i32 = @max(0, @as(i32, @intFromFloat(@floor(y_min_total))));
    const y_end: i32 = @min(ch_i, @as(i32, @intFromFloat(@ceil(y_max_total))));
    if (y_start >= y_end) return;

    var active: ActiveBuf = .{};
    defer active.deinit(allocator);
    var sub_list: SubEdgeBuf = .{};
    defer sub_list.deinit(allocator);
    var next_idx: usize = 0;

    var y_int: i32 = y_start;
    while (y_int < y_end) : (y_int += 1) {
        const y_top: f64 = @floatFromInt(y_int);
        const y_bot: f64 = y_top + 1.0;

        // 1. Drop edges fully above this row.
        var k: usize = 0;
        while (k < active.len) {
            if (active.ptr[k].y_max <= y_top) {
                active.ptr[k] = active.ptr[active.len - 1];
                active.len -= 1;
            } else {
                k += 1;
            }
        }

        // 2. Admit edges that touch this row at any sub-y. Edges are sorted
        // by y_min, so once an edge fails the `y_min < y_bot` gate, all
        // later edges also fail.
        while (next_idx < edges.len and edges.ptr[next_idx].y_min < y_bot) {
            const e = edges.ptr[next_idx];
            try active.append(allocator, .{
                .y_min = e.y_min,
                .y_max = e.y_max,
                .x_at_y_min = e.x_at_y_min,
                .inv_slope = e.inv_slope,
                .dir = e.direction,
            });
            next_idx += 1;
        }

        if (active.len < 2) continue;

        // 3. Zero the accumulator over the canvas-width range. The cov_row
        // is written only inside non-zero runs below, so it doesn't need
        // pre-zeroing — the blitter only reads the slice we hand it.
        @memset(aa_accum[0..canvas_w], 0.0);
        var row_x_min: i32 = cw_i;
        var row_x_max: i32 = 0;

        // 4. Sub-y supersample sweep.
        var s: u32 = 0;
        while (s < aa_sub_count) : (s += 1) {
            const y_sub: f64 = y_top + (@as(f64, @floatFromInt(s)) + 0.5) /
                @as(f64, @floatFromInt(aa_sub_count));

            // Build (x, dir) list of edges live at this sub-y.
            sub_list.len = 0;
            for (active.ptr[0..active.len]) |a| {
                if (y_sub < a.y_min or y_sub >= a.y_max) continue;
                const x: f64 = a.x_at_y_min + (y_sub - a.y_min) * a.inv_slope;
                try sub_list.append(allocator, .{ .x = x, .dir = a.dir });
            }
            if (sub_list.len < 2) continue;
            sortSubEdgesByX(sub_list.ptr[0..sub_list.len]);

            // Walk for inside spans, deposit fractional coverage.
            var winding: i32 = 0;
            var span_lo: f64 = 0;
            for (sub_list.ptr[0..sub_list.len]) |se| {
                const prev_inside = windingInside(winding, fill_rule);
                winding += se.dir;
                const new_inside = windingInside(winding, fill_rule);
                if (!prev_inside and new_inside) {
                    span_lo = se.x;
                } else if (prev_inside and !new_inside) {
                    depositSpan(aa_accum, span_lo, se.x, aa_sub_weight, cw_i);
                    const lo_i: i32 = @max(0, @as(i32, @intFromFloat(@floor(span_lo))));
                    const hi_i: i32 = @min(cw_i, @as(i32, @intFromFloat(@ceil(se.x))));
                    if (lo_i < row_x_min) row_x_min = lo_i;
                    if (hi_i > row_x_max) row_x_max = hi_i;
                }
            }
        }

        // 5. Sparse-scan accumulator and emit blits per non-zero run.
        if (row_x_min >= row_x_max) continue;
        var x: i32 = row_x_min;
        while (x < row_x_max) {
            // Skip leading cells that round to coverage 0.
            while (x < row_x_max and aa_accum[@intCast(x)] * 256.0 < 1.0) : (x += 1) {}
            if (x >= row_x_max) break;
            const run_start = x;
            while (x < row_x_max and aa_accum[@intCast(x)] * 256.0 >= 1.0) : (x += 1) {
                const v = aa_accum[@intCast(x)] * 256.0;
                cov_row[@intCast(x)] = if (v >= 255.0) 255 else @intFromFloat(v);
            }
            const n: u32 = @intCast(x - run_start);
            SmBlitter.blitRow(
                pixels,
                canvas_w,
                run_start,
                y_int,
                n,
                cov_row[@intCast(run_start)..@intCast(x)],
                paint,
                clip_mask,
            );
        }
    }
}

/// AA scanline sweep that writes per-pixel u8 coverage into `mask`.
/// Structurally identical to `sweepEdges`: 8× sub-y supersample +
/// analytic-x partial coverage → quantize to u8 → emit. The only
/// difference is the per-row emit step writes the cov_row into the
/// canvas-wide mask buffer instead of calling `SmBlitter.blitRow`.
///
/// AA boundary cells in the mask combine multiplicatively with the AA
/// shape coverage inside `SmBlitter.blitRow` (`(cov * clip + 127) / 255`)
/// — already wired, no further blitter changes needed.
fn sweepEdgesToCoverageMask(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    mask: []u8,
    canvas_w: u32,
    canvas_h: u32,
    fill_rule: FillRule,
    aa_accum: []f32,
    cov_row: []u8,
) !void {
    if (edges.len == 0) return;
    if (aa_accum.len < canvas_w or cov_row.len < canvas_w) return;

    sortEdgesByYMin(edges.ptr[0..edges.len]);

    var y_min_total: f64 = std.math.inf(f64);
    var y_max_total: f64 = -std.math.inf(f64);
    for (edges.ptr[0..edges.len]) |e| {
        if (e.y_min < y_min_total) y_min_total = e.y_min;
        if (e.y_max > y_max_total) y_max_total = e.y_max;
    }

    const ch_i: i32 = @intCast(canvas_h);
    const cw_i: i32 = @intCast(canvas_w);
    const y_start: i32 = @max(0, @as(i32, @intFromFloat(@floor(y_min_total))));
    const y_end: i32 = @min(ch_i, @as(i32, @intFromFloat(@ceil(y_max_total))));
    if (y_start >= y_end) return;

    var active: ActiveBuf = .{};
    defer active.deinit(allocator);
    var sub_list: SubEdgeBuf = .{};
    defer sub_list.deinit(allocator);
    var next_idx: usize = 0;

    var y_int: i32 = y_start;
    while (y_int < y_end) : (y_int += 1) {
        const y_top: f64 = @floatFromInt(y_int);
        const y_bot: f64 = y_top + 1.0;

        // 1. Drop edges fully above this row.
        var k: usize = 0;
        while (k < active.len) {
            if (active.ptr[k].y_max <= y_top) {
                active.ptr[k] = active.ptr[active.len - 1];
                active.len -= 1;
            } else {
                k += 1;
            }
        }

        // 2. Admit edges that touch this row at any sub-y.
        while (next_idx < edges.len and edges.ptr[next_idx].y_min < y_bot) {
            const e = edges.ptr[next_idx];
            try active.append(allocator, .{
                .y_min = e.y_min,
                .y_max = e.y_max,
                .x_at_y_min = e.x_at_y_min,
                .inv_slope = e.inv_slope,
                .dir = e.direction,
            });
            next_idx += 1;
        }

        if (active.len < 2) continue;

        @memset(aa_accum[0..canvas_w], 0.0);
        var row_x_min: i32 = cw_i;
        var row_x_max: i32 = 0;

        // 3. Sub-y supersample sweep.
        var s: u32 = 0;
        while (s < aa_sub_count) : (s += 1) {
            const y_sub: f64 = y_top + (@as(f64, @floatFromInt(s)) + 0.5) /
                @as(f64, @floatFromInt(aa_sub_count));

            sub_list.len = 0;
            for (active.ptr[0..active.len]) |a| {
                if (y_sub < a.y_min or y_sub >= a.y_max) continue;
                const x: f64 = a.x_at_y_min + (y_sub - a.y_min) * a.inv_slope;
                try sub_list.append(allocator, .{ .x = x, .dir = a.dir });
            }
            if (sub_list.len < 2) continue;
            sortSubEdgesByX(sub_list.ptr[0..sub_list.len]);

            var winding: i32 = 0;
            var span_lo: f64 = 0;
            for (sub_list.ptr[0..sub_list.len]) |se| {
                const prev_inside = windingInside(winding, fill_rule);
                winding += se.dir;
                const new_inside = windingInside(winding, fill_rule);
                if (!prev_inside and new_inside) {
                    span_lo = se.x;
                } else if (prev_inside and !new_inside) {
                    depositSpan(aa_accum, span_lo, se.x, aa_sub_weight, cw_i);
                    const lo_i: i32 = @max(0, @as(i32, @intFromFloat(@floor(span_lo))));
                    const hi_i: i32 = @min(cw_i, @as(i32, @intFromFloat(@ceil(se.x))));
                    if (lo_i < row_x_min) row_x_min = lo_i;
                    if (hi_i > row_x_max) row_x_max = hi_i;
                }
            }
        }

        // 4. Quantize accumulator → mask row.
        if (row_x_min >= row_x_max) continue;
        const row_off: usize = @as(usize, @intCast(y_int)) * @as(usize, canvas_w);
        var x: i32 = row_x_min;
        while (x < row_x_max) : (x += 1) {
            const v = aa_accum[@intCast(x)] * 256.0;
            const cov_byte: u8 = if (v >= 255.0) 255 else if (v <= 0.0) 0 else @intFromFloat(v);
            mask[row_off + @as(usize, @intCast(x))] = cov_byte;
        }
    }
}

// ---------------------------------------------------------------------------
// Path stroke (T7) — inflate path to outline polygon, fill via sweepEdges.
// ---------------------------------------------------------------------------
//
// Algorithm (Skia-style polygon inflation):
//   1. Walk path opcodes, building one polyline at a time. Béziers flatten
//      to line points via `flattenQuadPoints` / `flattenCubicPoints`.
//   2. For each polyline, compute per-vertex perpendicular offsets at
//      ±half_w to get "left" and "right" outline points.
//   3. At interior vertices, miter-join: bisector of the two segment normals.
//      If miter would exceed `miter_limit`, fall back to bevel.
//   4. At endpoints of an OPEN polyline, emit butt caps (perpendicular line
//      across the segment direction).
//   5. Emit edges of the outline polygon (left side forward, right side
//      backward, plus caps for open polylines).
//   6. Reuse `sweepEdges` to fill the outline polygon.
//
// All HTML5 caps/joins are now wired (butt/round/square × miter/bevel/round)
// — extension points described above are filled. Same Blitter pipeline; the
// different shapes show up purely as different outline-construction edges.

/// 2D point/vector. Used inside the stroke inflation only — public-facing
/// path coords stay as paired f64 args per the existing convention.
const Vec2 = struct { x: f64, y: f64 };

inline fn v2sub(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
inline fn v2add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
inline fn v2scale(a: Vec2, s: f64) Vec2 {
    return .{ .x = a.x * s, .y = a.y * s };
}
/// Perpendicular (rotated 90° CCW): (x, y) → (-y, x).
inline fn v2perp(a: Vec2) Vec2 {
    return .{ .x = -a.y, .y = a.x };
}
inline fn v2lenSq(a: Vec2) f64 {
    return a.x * a.x + a.y * a.y;
}
inline fn v2normalize(a: Vec2) Vec2 {
    const l_sq = v2lenSq(a);
    if (l_sq < 1e-18) return .{ .x = 0, .y = 0 };
    const inv = 1.0 / @sqrt(l_sq);
    return .{ .x = a.x * inv, .y = a.y * inv };
}

const PointBuf = SmList(Vec2);

/// Recursively flatten a quadratic Bézier into line-endpoint Vec2s.
/// Appends only the chord ENDPOINTS (the starting point is already in
/// `pts`), to match how lineTo accumulates.
fn flattenQuadPoints(
    pts: *PointBuf,
    allocator: std.mem.Allocator,
    p0x: f64, p0y: f64,
    cpx: f64, cpy: f64,
    p1x: f64, p1y: f64,
    depth: u32,
) !void {
    if (depth >= 16 or isQuadFlat(p0x, p0y, cpx, cpy, p1x, p1y)) {
        try pts.append(allocator, .{ .x = p1x, .y = p1y });
        return;
    }
    const m1x = (p0x + cpx) * 0.5;
    const m1y = (p0y + cpy) * 0.5;
    const m2x = (cpx + p1x) * 0.5;
    const m2y = (cpy + p1y) * 0.5;
    const mx = (m1x + m2x) * 0.5;
    const my = (m1y + m2y) * 0.5;
    try flattenQuadPoints(pts, allocator, p0x, p0y, m1x, m1y, mx, my, depth + 1);
    try flattenQuadPoints(pts, allocator, mx, my, m2x, m2y, p1x, p1y, depth + 1);
}

fn flattenCubicPoints(
    pts: *PointBuf,
    allocator: std.mem.Allocator,
    p0x: f64, p0y: f64,
    c1x: f64, c1y: f64,
    c2x: f64, c2y: f64,
    p1x: f64, p1y: f64,
    depth: u32,
) !void {
    if (depth >= 18 or isCubicFlat(p0x, p0y, c1x, c1y, c2x, c2y, p1x, p1y)) {
        try pts.append(allocator, .{ .x = p1x, .y = p1y });
        return;
    }
    const m01x = (p0x + c1x) * 0.5;
    const m01y = (p0y + c1y) * 0.5;
    const m12x = (c1x + c2x) * 0.5;
    const m12y = (c1y + c2y) * 0.5;
    const m23x = (c2x + p1x) * 0.5;
    const m23y = (c2y + p1y) * 0.5;
    const m012x = (m01x + m12x) * 0.5;
    const m012y = (m01y + m12y) * 0.5;
    const m123x = (m12x + m23x) * 0.5;
    const m123y = (m12y + m23y) * 0.5;
    const mx = (m012x + m123x) * 0.5;
    const my = (m012y + m123y) * 0.5;
    try flattenCubicPoints(pts, allocator, p0x, p0y, m01x, m01y, m012x, m012y, mx, my, depth + 1);
    try flattenCubicPoints(pts, allocator, mx, my, m123x, m123y, m23x, m23y, p1x, p1y, depth + 1);
}

/// Append intermediate fan points along an arc of radius `half_w` around
/// `center`, from `start_off` to `end_off`. `sweep_sign` is +1 for CCW
/// (increasing angle), -1 for CW (decreasing angle). The endpoint vectors
/// must already have magnitude `half_w`. Endpoints themselves are NOT
/// appended — the caller is responsible for those, this just fills the arc
/// interior so consecutive-edge emission produces the fan.
fn emitArcFan(
    out: *PointBuf,
    allocator: std.mem.Allocator,
    center: Vec2,
    start_off: Vec2,
    end_off: Vec2,
    half_w: f64,
    sweep_sign: f64,
) !void {
    const two_pi: f64 = 2.0 * std.math.pi;
    const start_angle = std.math.atan2(start_off.y, start_off.x);
    const end_angle = std.math.atan2(end_off.y, end_off.x);
    var sweep = end_angle - start_angle;
    if (sweep_sign > 0) {
        while (sweep < 0) sweep += two_pi;
        if (sweep > two_pi - 1e-12) sweep -= two_pi;
    } else {
        while (sweep > 0) sweep -= two_pi;
        if (sweep < -two_pi + 1e-12) sweep += two_pi;
    }
    if (@abs(sweep) < 1e-9) return;
    const n = SmPath.arcSegmentCount(half_w, sweep);
    if (n <= 1) return;
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const ang = start_angle + sweep * t;
        try out.append(allocator, .{
            .x = center.x + half_w * @cos(ang),
            .y = center.y + half_w * @sin(ang),
        });
    }
}

/// Inflate one polyline (sequence of points) to its stroke outline polygon
/// edges. `closed=true` means wrap-around (last vertex joins first via the
/// configured `line_join`, no caps). `closed=false` adds caps per
/// `line_cap` at the endpoints.
///
/// Outline construction strategy:
///   • Walk vertices forward, appending per-vertex offset points to two
///     parallel buffers `left_pts` (CCW perpendicular) and `right_pts` (CW).
///     A miter join contributes one point to each; a bevel/round join
///     contributes two (or many, for round) points to the outer side and
///     one to the inner.
///   • For OPEN polylines, weld the two strands at the endpoints with the
///     configured `line_cap` (butt = single edge, square = +half_w
///     extension along the segment direction, round = arc fan).
///   • For CLOSED polylines, emit the left and right strands as two
///     separately-closed loops with opposite winding — non-zero fill rule
///     paints the donut and leaves the hole empty.
fn strokePolyline(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    pts: []const Vec2,
    half_w: f64,
    miter_limit: f64,
    line_cap: SmPaint.LineCap,
    line_join: SmPaint.LineJoin,
    closed: bool,
) !void {
    if (pts.len < 2 or half_w <= 0) return;
    const n = pts.len;

    // Threshold on (1 + cos θ) below which we bevel instead of miter.
    // miter_length / half_w = 1 / cos(θ/2). Bound to miter_limit:
    //   1/cos(θ/2) ≤ miter_limit  ⟹  2·cos²(θ/2) ≥ 2/miter_limit²
    //   ⟹  1 + cos θ ≥ 2/miter_limit².
    const miter_threshold: f64 = 2.0 / (miter_limit * miter_limit);

    var left_pts: PointBuf = .{};
    defer left_pts.deinit(allocator);
    var right_pts: PointBuf = .{};
    defer right_pts.deinit(allocator);

    // Cached for square/round end-caps below — the segment directions at the
    // first and last vertices of an OPEN polyline.
    var first_d_next: Vec2 = .{ .x = 1, .y = 0 };
    var last_d_prev: Vec2 = .{ .x = 1, .y = 0 };

    for (0..n) |i| {
        const has_prev = i > 0 or closed;
        const has_next = i < n - 1 or closed;

        var d_prev: ?Vec2 = null;
        var np_off: ?Vec2 = null;
        var d_next: ?Vec2 = null;
        var nn_off: ?Vec2 = null;

        if (has_prev) {
            const idx_prev: usize = if (i == 0) n - 1 else i - 1;
            const dir = v2normalize(v2sub(pts[i], pts[idx_prev]));
            d_prev = dir;
            np_off = v2scale(v2perp(dir), half_w);
            if (i == n - 1 and !closed) last_d_prev = dir;
        }
        if (has_next) {
            const idx_next: usize = if (i == n - 1) 0 else i + 1;
            const dir = v2normalize(v2sub(pts[idx_next], pts[i]));
            d_next = dir;
            nn_off = v2scale(v2perp(dir), half_w);
            if (i == 0 and !closed) first_d_next = dir;
        }

        if (np_off != null and nn_off != null) {
            // Interior vertex.
            const np = np_off.?;
            const nn = nn_off.?;
            const dp = d_prev.?;
            const dn = d_next.?;
            const cos_theta = dp.x * dn.x + dp.y * dn.y;
            const denom = 1.0 + cos_theta;
            // Cross product of segment directions tells turn direction.
            //   cross > 0 → CCW turn → outer corner is on the +perp ('left') side.
            //   cross < 0 → CW turn  → outer corner is on the -perp ('right') side.
            const cross = dp.x * dn.y - dp.y * dn.x;

            const use_miter = (line_join == .miter) and (denom > miter_threshold);

            if (use_miter or denom < 1e-9 or @abs(cross) < 1e-9) {
                // Single-point miter on both sides — covers smooth interior
                // vertices and the "miter is fine" join case. Also used as
                // safe fallback for nearly-collinear / degenerate corners.
                const safe_denom = if (denom > 1e-9) denom else 1.0;
                const sum = v2add(np, nn);
                const miter = v2scale(sum, 1.0 / safe_denom);
                try left_pts.append(allocator, v2add(pts[i], miter));
                try right_pts.append(allocator, v2add(pts[i], v2scale(miter, -1)));
            } else {
                // Bevel or round join: the OUTER side gets two outline
                // points (entrance + exit perpendicular), with an arc fan
                // filling the gap for round. The INNER side keeps a single
                // miter point so the outline polygon stays simple.
                const safe_denom = if (denom > 1e-9) denom else 1e-9;
                const sum = v2add(np, nn);
                const miter = v2scale(sum, 1.0 / safe_denom);

                if (cross > 0) {
                    // CCW turn → outer = left.
                    try left_pts.append(allocator, v2add(pts[i], np));
                    if (line_join == .round) {
                        try emitArcFan(&left_pts, allocator, pts[i], np, nn, half_w, 1.0);
                    }
                    try left_pts.append(allocator, v2add(pts[i], nn));
                    try right_pts.append(allocator, v2add(pts[i], v2scale(miter, -1)));
                } else {
                    // CW turn → outer = right.
                    try left_pts.append(allocator, v2add(pts[i], miter));
                    const np_neg: Vec2 = .{ .x = -np.x, .y = -np.y };
                    const nn_neg: Vec2 = .{ .x = -nn.x, .y = -nn.y };
                    try right_pts.append(allocator, v2add(pts[i], np_neg));
                    if (line_join == .round) {
                        try emitArcFan(&right_pts, allocator, pts[i], np_neg, nn_neg, half_w, -1.0);
                    }
                    try right_pts.append(allocator, v2add(pts[i], nn_neg));
                }
            }
        } else if (np_off != null) {
            // End vertex of OPEN polyline: butt-equivalent perpendicular.
            // Cap shape is emitted later between the end of left_pts and the
            // end of right_pts.
            const np = np_off.?;
            try left_pts.append(allocator, v2add(pts[i], np));
            try right_pts.append(allocator, v2add(pts[i], v2scale(np, -1)));
        } else if (nn_off != null) {
            // Start vertex of OPEN polyline.
            const nn = nn_off.?;
            try left_pts.append(allocator, v2add(pts[i], nn));
            try right_pts.append(allocator, v2add(pts[i], v2scale(nn, -1)));
        }
    }

    if (left_pts.len < 2 or right_pts.len < 2) return;

    const lp = left_pts.ptr[0..left_pts.len];
    const rp = right_pts.ptr[0..right_pts.len];

    if (closed) {
        // Two independent loops; non-zero winding fills the donut.
        // Outer loop (left strand) — forward, then close.
        for (0..lp.len - 1) |i| {
            try addEdge(edges, allocator, lp[i].x, lp[i].y, lp[i + 1].x, lp[i + 1].y);
        }
        try addEdge(edges, allocator, lp[lp.len - 1].x, lp[lp.len - 1].y, lp[0].x, lp[0].y);
        // Inner loop (right strand) — backward (so winding is opposite).
        var i: usize = rp.len - 1;
        while (i > 0) : (i -= 1) {
            try addEdge(edges, allocator, rp[i].x, rp[i].y, rp[i - 1].x, rp[i - 1].y);
        }
        try addEdge(edges, allocator, rp[0].x, rp[0].y, rp[rp.len - 1].x, rp[rp.len - 1].y);
        return;
    }

    // OPEN polyline: single loop = left forward + end cap + right backward + start cap.

    // Left forward.
    for (0..lp.len - 1) |i| {
        try addEdge(edges, allocator, lp[i].x, lp[i].y, lp[i + 1].x, lp[i + 1].y);
    }

    // End cap: connects lp[end] → rp[end].
    const l_end = lp[lp.len - 1];
    const r_end = rp[rp.len - 1];
    try emitCapEdges(edges, allocator, l_end, r_end, pts[n - 1], last_d_prev, half_w, line_cap, true);

    // Right backward.
    var i: usize = rp.len - 1;
    while (i > 0) : (i -= 1) {
        try addEdge(edges, allocator, rp[i].x, rp[i].y, rp[i - 1].x, rp[i - 1].y);
    }

    // Start cap: connects rp[0] → lp[0].
    try emitCapEdges(edges, allocator, rp[0], lp[0], pts[0], first_d_next, half_w, line_cap, false);
}

/// Emit the polygon edges for one stroke endpoint cap.
///   `from` / `to`     — the two outline points the cap must bridge.
///   `center`          — the polyline endpoint position.
///   `tangent`         — unit vector pointing INTO the polyline at the cap
///                       (i.e. d_prev for end caps, d_next for start caps).
///                       Outward direction = `+tangent` for end, `-tangent`
///                       for start (selected via `is_end`).
///   `is_end`          — true for end-of-polyline caps, false for start.
fn emitCapEdges(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    from: Vec2,
    to: Vec2,
    center: Vec2,
    tangent: Vec2,
    half_w: f64,
    line_cap: SmPaint.LineCap,
    is_end: bool,
) !void {
    switch (line_cap) {
        .butt => {
            try addEdge(edges, allocator, from.x, from.y, to.x, to.y);
        },
        .square => {
            // Extend BOTH endpoints along the outward tangent by half_w,
            // forming a 3-edge square cap.
            const sign: f64 = if (is_end) 1.0 else -1.0;
            const ext: Vec2 = .{ .x = sign * tangent.x * half_w, .y = sign * tangent.y * half_w };
            const from_ext = v2add(from, ext);
            const to_ext = v2add(to, ext);
            try addEdge(edges, allocator, from.x, from.y, from_ext.x, from_ext.y);
            try addEdge(edges, allocator, from_ext.x, from_ext.y, to_ext.x, to_ext.y);
            try addEdge(edges, allocator, to_ext.x, to_ext.y, to.x, to.y);
        },
        .round => {
            // Half-circle fan from `from` through outward tangent to `to`.
            // Both end-cap and start-cap sweep CW by π in screen-Y coords.
            var fan: PointBuf = .{};
            defer fan.deinit(allocator);
            const start_off: Vec2 = .{ .x = from.x - center.x, .y = from.y - center.y };
            const end_off: Vec2 = .{ .x = to.x - center.x, .y = to.y - center.y };
            try emitArcFan(&fan, allocator, center, start_off, end_off, half_w, -1.0);
            var prev = from;
            for (fan.ptr[0..fan.len]) |p| {
                try addEdge(edges, allocator, prev.x, prev.y, p.x, p.y);
                prev = p;
            }
            try addEdge(edges, allocator, prev.x, prev.y, to.x, to.y);
        },
    }
}

/// Slice the polyline `pts` per the dash array, calling `strokePolyline`
/// on each "on" sub-polyline. `closed` polylines are treated by appending
/// `pts[0]` to the end so the closing edge is dashed as a regular segment.
fn dashAndStrokePolyline(
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    pts: []const Vec2,
    half_w: f64,
    miter_limit: f64,
    line_cap: SmPaint.LineCap,
    line_join: SmPaint.LineJoin,
    line_dash: []const f64,
    line_dash_offset: f64,
    closed: bool,
) !void {
    if (pts.len < 2 or half_w <= 0 or line_dash.len == 0) return;
    var total_dash: f64 = 0;
    for (line_dash) |d| total_dash += d;
    if (total_dash <= 0) return;

    // Build the working polyline. For closed paths we append pts[0] so the
    // closing edge participates in dashing as a regular segment.
    var pts_buf: PointBuf = .{};
    defer pts_buf.deinit(allocator);
    try pts_buf.appendSlice(allocator, pts);
    if (closed) try pts_buf.append(allocator, pts[0]);
    const work = pts_buf.ptr[0..pts_buf.len];

    // Resolve initial dash phase from `line_dash_offset` (HTML5: positive
    // shifts the pattern in the dash direction; we wrap modulo total_dash).
    var pos: f64 = @mod(line_dash_offset, total_dash);
    if (pos < 0) pos += total_dash;
    var dash_idx: usize = 0;
    var on: bool = true;
    while (pos >= line_dash[dash_idx]) {
        pos -= line_dash[dash_idx];
        dash_idx = (dash_idx + 1) % line_dash.len;
        on = !on;
    }
    var remaining_in_dash: f64 = line_dash[dash_idx] - pos;

    // Sub-polyline accumulator. Flushed on every dash boundary (and at end).
    var sub: PointBuf = .{};
    defer sub.deinit(allocator);

    for (1..work.len) |i| {
        const a = work[i - 1];
        const b = work[i];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const seg_len = @sqrt(dx * dx + dy * dy);
        if (seg_len < 1e-12) continue;

        var seg_pos: f64 = 0;
        while (seg_pos < seg_len) {
            // Some dash entries can be exactly 0 (e.g. `[0, 5]` = "always
            // off, then 5px on"); guard so we don't infinite-loop on those.
            if (remaining_in_dash <= 1e-12) {
                if (on and sub.len >= 2) {
                    try strokePolyline(
                        edges, allocator, sub.ptr[0..sub.len],
                        half_w, miter_limit, line_cap, line_join, false,
                    );
                }
                sub.len = 0;
                on = !on;
                dash_idx = (dash_idx + 1) % line_dash.len;
                remaining_in_dash = line_dash[dash_idx];
                continue;
            }
            const step = @min(remaining_in_dash, seg_len - seg_pos);
            if (on) {
                if (sub.len == 0) {
                    const t_start = seg_pos / seg_len;
                    try sub.append(allocator, .{
                        .x = a.x + dx * t_start,
                        .y = a.y + dy * t_start,
                    });
                }
                const t_end = (seg_pos + step) / seg_len;
                try sub.append(allocator, .{
                    .x = a.x + dx * t_end,
                    .y = a.y + dy * t_end,
                });
            }
            seg_pos += step;
            remaining_in_dash -= step;
            if (remaining_in_dash <= 1e-12) {
                if (on and sub.len >= 2) {
                    try strokePolyline(
                        edges, allocator, sub.ptr[0..sub.len],
                        half_w, miter_limit, line_cap, line_join, false,
                    );
                }
                sub.len = 0;
                on = !on;
                dash_idx = (dash_idx + 1) % line_dash.len;
                remaining_in_dash = line_dash[dash_idx];
            }
        }
    }
    // Flush trailing on-interval.
    if (on and sub.len >= 2) {
        try strokePolyline(
            edges, allocator, sub.ptr[0..sub.len],
            half_w, miter_limit, line_cap, line_join, false,
        );
    }
}

/// StrokeVisitor — per-walk state for `strokePath`. Accumulates a polyline
/// per subpath and emits inflated outline edges to `strokePolyline` at
/// subpath boundaries (close / new moveTo / rect / end-of-path).
const StrokeVisitor = struct {
    edges: *EdgeBuf,
    allocator: std.mem.Allocator,
    pts: PointBuf,
    half_w: f64,
    miter_limit: f64,
    line_cap: SmPaint.LineCap,
    line_join: SmPaint.LineJoin,
    line_dash: []const f64,
    line_dash_offset: f64,

    fn flush(self: *StrokeVisitor, closed: bool) !void {
        if (self.pts.len >= 2) {
            if (self.line_dash.len > 0) {
                try dashAndStrokePolyline(
                    self.edges,
                    self.allocator,
                    self.pts.ptr[0..self.pts.len],
                    self.half_w,
                    self.miter_limit,
                    self.line_cap,
                    self.line_join,
                    self.line_dash,
                    self.line_dash_offset,
                    closed,
                );
            } else {
                try strokePolyline(
                    self.edges,
                    self.allocator,
                    self.pts.ptr[0..self.pts.len],
                    self.half_w,
                    self.miter_limit,
                    self.line_cap,
                    self.line_join,
                    closed,
                );
            }
        }
        self.pts.len = 0;
    }

    fn onClose(self: *StrokeVisitor) !void {
        try self.flush(true);
    }

    fn onMoveTo(self: *StrokeVisitor, x: f64, y: f64) !void {
        try self.flush(false);
        try self.pts.append(self.allocator, .{ .x = x, .y = y });
    }

    fn onLineTo(self: *StrokeVisitor, x: f64, y: f64) !void {
        if (self.pts.len == 0) try self.pts.append(self.allocator, .{ .x = x, .y = y });
        try self.pts.append(self.allocator, .{ .x = x, .y = y });
    }

    fn onQuadTo(self: *StrokeVisitor, cpx: f64, cpy: f64, x: f64, y: f64) !void {
        var p0x: f64 = cpx;
        var p0y: f64 = cpy;
        if (self.pts.len == 0) {
            try self.pts.append(self.allocator, .{ .x = cpx, .y = cpy });
        } else {
            p0x = self.pts.ptr[self.pts.len - 1].x;
            p0y = self.pts.ptr[self.pts.len - 1].y;
        }
        try flattenQuadPoints(&self.pts, self.allocator, p0x, p0y, cpx, cpy, x, y, 0);
    }

    fn onBezierTo(self: *StrokeVisitor, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) !void {
        var p0x: f64 = c1x;
        var p0y: f64 = c1y;
        if (self.pts.len == 0) {
            try self.pts.append(self.allocator, .{ .x = c1x, .y = c1y });
        } else {
            p0x = self.pts.ptr[self.pts.len - 1].x;
            p0y = self.pts.ptr[self.pts.len - 1].y;
        }
        try flattenCubicPoints(&self.pts, self.allocator, p0x, p0y, c1x, c1y, c2x, c2y, x, y, 0);
    }

    fn onRect(self: *StrokeVisitor, rx: f64, ry: f64, rw: f64, rh: f64) !void {
        try self.flush(false);
        try self.pts.append(self.allocator, .{ .x = rx, .y = ry });
        try self.pts.append(self.allocator, .{ .x = rx + rw, .y = ry });
        try self.pts.append(self.allocator, .{ .x = rx + rw, .y = ry + rh });
        try self.pts.append(self.allocator, .{ .x = rx, .y = ry + rh });
        try self.flush(true);
    }
};

/// flattenPathToStrokeEdges — populate `edges` with the inflated outline
/// of `path` rendered with the given line-width/cap/join/miter-limit and
/// optional dash pattern. Outline is the same polygon `strokePath` would
/// rasterize. Used by `strokePath` and the hit-test helper
/// `isPointInStroke`.
pub fn flattenPathToStrokeEdges(
    allocator: std.mem.Allocator,
    path: *const SmPath,
    edges: *EdgeBuf,
    line_width: f64,
    line_cap: SmPaint.LineCap,
    line_join: SmPaint.LineJoin,
    miter_limit: f64,
    line_dash: []const f64,
    line_dash_offset: f64,
) !void {
    if (path.verbs.len == 0 or line_width <= 0) return;
    var visitor: StrokeVisitor = .{
        .edges = edges,
        .allocator = allocator,
        .pts = .{},
        .half_w = line_width / 2.0,
        .miter_limit = miter_limit,
        .line_cap = line_cap,
        .line_join = line_join,
        .line_dash = line_dash,
        .line_dash_offset = line_dash_offset,
    };
    defer visitor.pts.deinit(allocator);
    try walkOpcodes(path.verbs.ptr[0..path.verbs.len], path.points.ptr[0..path.points.len], &visitor);
    try visitor.flush(false);
}

/// strokePath — public entry. Builds inflated outline edges, sweeps, blits.
///
/// `aa_accum` and `cov_row` are caller-owned per-row scratch buffers,
/// each sized to at least `canvas_w`. See `fillPath` for ownership notes.
pub fn strokePath(
    allocator: std.mem.Allocator,
    pixels: []u32,
    canvas_w: u32,
    canvas_h: u32,
    path: *const SmPath,
    line_width: f64,
    line_cap: SmPaint.LineCap,
    line_join: SmPaint.LineJoin,
    miter_limit: f64,
    line_dash: []const f64,
    line_dash_offset: f64,
    clip_mask: ?[]const u8,
    paint: *const SmPaint,
    aa_accum: []f32,
    cov_row: []u8,
) !void {
    if (path.verbs.len == 0 or line_width <= 0) return;
    if (canvas_w == 0 or canvas_h == 0) return;

    var edges: EdgeBuf = .{};
    defer edges.deinit(allocator);
    try flattenPathToStrokeEdges(
        allocator, path, &edges,
        line_width, line_cap, line_join, miter_limit,
        line_dash, line_dash_offset,
    );
    // Stroke outline polygon is filled with the standard non-zero winding
    // rule (the donut is built CCW outer + CW inner) — fill rule is not
    // user-controllable for strokes.
    try sweepEdges(&edges, allocator, pixels, canvas_w, canvas_h, .nonzero, clip_mask, paint, aa_accum, cov_row);
}
