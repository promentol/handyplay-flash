//! SWF dual-edge shape records → ordinary paths ("distilling").
//!
//! Direct port of ruffle render/src/shape_utils.rs ShapeConverter — the
//! reference implementation for the least-documented part of the SWF
//! format. Flash gives an "edge soup": each edge carries up to two fill
//! styles (fill1 = positive/right side, fill0 = negative/left side) and a
//! line style, and edges for one fill arrive in arbitrary order. Per
//! style: collect segments (fill0 segments FLIPPED so winding is
//! consistent), link segments end-to-start into closed contours, then emit
//! fills (in style order) followed by strokes. A NewStyles record starts a
//! new LAYER: everything pending is emitted first (layers stack in order).
//!
//! Coordinates stay in TWIPS (f64 at the IR boundary); the renderer's CTM
//! applies the ÷20 and object/stage matrices.

const std = @import("std");
const swf_shape = @import("../swf/shape.zig");
const rdr = @import("../swf/reader.zig");
const morph_mod = @import("../swf/morph.zig");

pub const Error = std.mem.Allocator.Error;

pub const Winding = enum { even_odd, non_zero };

pub const DrawCommand = union(enum) {
    move_to: struct { x: i32, y: i32 },
    line_to: struct { x: i32, y: i32 },
    quad_to: struct { cx: i32, cy: i32, ax: i32, ay: i32 },
};

pub const DrawPath = union(enum) {
    fill: struct {
        style: *const swf_shape.FillStyle,
        commands: []DrawCommand,
        winding: Winding,
    },
    stroke: struct {
        style: *const swf_shape.LineStyle,
        is_closed: bool,
        commands: []DrawCommand,
    },
};

const Point = struct { x: i32, y: i32, ctrl: bool };

const Segment = struct {
    points: std.ArrayList(Point) = .empty,

    fn initStart(a: std.mem.Allocator, x: i32, y: i32) Error!Segment {
        var s: Segment = .{};
        try s.points.append(a, .{ .x = x, .y = y, .ctrl = false });
        return s;
    }

    fn reset(self: *Segment, a: std.mem.Allocator, x: i32, y: i32) Error!void {
        self.points.clearRetainingCapacity();
        try self.points.append(a, .{ .x = x, .y = y, .ctrl = false });
    }

    fn isEmpty(self: *const Segment) bool {
        return self.points.items.len <= 1;
    }

    /// Fill style 0 marks the negative side — flip so it links with
    /// fill-style-1 segments in consistent winding.
    fn flip(self: *Segment) void {
        std.mem.reverse(Point, self.points.items);
    }

    fn startPt(self: *const Segment) Point {
        return self.points.items[0];
    }
    fn endPt(self: *const Segment) Point {
        return self.points.items[self.points.items.len - 1];
    }

    fn isClosed(self: *const Segment) bool {
        const s = self.startPt();
        const e = self.endPt();
        return s.x == e.x and s.y == e.y;
    }

    fn appendCommands(self: *const Segment, a: std.mem.Allocator, out: *std.ArrayList(DrawCommand)) Error!void {
        const pts = self.points.items;
        std.debug.assert(pts.len > 1);
        try out.append(a, .{ .move_to = .{ .x = pts[0].x, .y = pts[0].y } });
        var i: usize = 1;
        while (i < pts.len) : (i += 1) {
            const p = pts[i];
            if (p.ctrl) {
                // Control point must be followed by its anchor.
                const anchor = pts[i + 1];
                try out.append(a, .{ .quad_to = .{ .cx = p.x, .cy = p.y, .ax = anchor.x, .ay = anchor.y } });
                i += 1;
            } else {
                try out.append(a, .{ .line_to = .{ .x = p.x, .y = p.y } });
            }
        }
    }
};

const Pending = struct {
    segments: std.ArrayList(Segment) = .empty,

    /// Link a segment onto existing ones by matching endpoints (both the
    /// new segment's start and end can link), then store it.
    fn addSegment(self: *Pending, a: std.mem.Allocator, seg_in: Segment) Error!void {
        var seg = seg_in;
        if (seg.isEmpty()) {
            var s = seg;
            s.points.deinit(a);
            return;
        }
        var start_open = true;
        var end_open = true;
        var i: usize = 0;
        while ((start_open or end_open) and i < self.segments.items.len) {
            const other = &self.segments.items[i];
            const o_end = other.endPt();
            const o_start = other.startPt();
            const s_start = seg.startPt();
            const s_end = seg.endPt();
            if (start_open and o_end.x == s_start.x and o_end.y == s_start.y) {
                try other.points.appendSlice(a, seg.points.items[1..]);
                seg.points.deinit(a);
                seg = self.segments.swapRemove(i);
                start_open = false;
            } else if (end_open and s_end.x == o_start.x and s_end.y == o_start.y) {
                std.mem.swap(std.ArrayList(Point), &other.points, &seg.points);
                try other.points.appendSlice(a, seg.points.items[1..]);
                seg.points.deinit(a);
                seg = self.segments.swapRemove(i);
                end_open = false;
            } else {
                i += 1;
            }
        }
        try self.segments.append(a, seg);
    }

    fn pushSegment(self: *Pending, a: std.mem.Allocator, seg: Segment) Error!void {
        if (seg.isEmpty()) {
            var s = seg;
            s.points.deinit(a);
            return;
        }
        try self.segments.append(a, seg);
    }

    fn clear(self: *Pending, a: std.mem.Allocator) void {
        for (self.segments.items) |*s| s.points.deinit(a);
        self.segments.clearRetainingCapacity();
    }
};

const Active = struct {
    style_id: u32 = 0,
    segment: Segment,

    fn flushFill(self: *Active, a: std.mem.Allocator, x: i32, y: i32, pending: []Pending, flip: bool) Error!void {
        if (self.style_id > 0 and !self.segment.isEmpty()) {
            var seg = try Segment.initStart(a, 0, 0);
            std.mem.swap(std.ArrayList(Point), &seg.points, &self.segment.points);
            if (flip) seg.flip();
            try pending[self.style_id - 1].addSegment(a, seg);
        }
        try self.segment.reset(a, x, y);
    }

    fn flushStroke(self: *Active, a: std.mem.Allocator, x: i32, y: i32, pending: []Pending) Error!void {
        if (self.style_id > 0 and !self.segment.isEmpty()) {
            var seg = try Segment.initStart(a, 0, 0);
            std.mem.swap(std.ArrayList(Point), &seg.points, &self.segment.points);
            try pending[self.style_id - 1].pushSegment(a, seg);
        }
        try self.segment.reset(a, x, y);
    }
};

/// Distill a parsed shape into ordered draw paths. Allocate from an arena
/// (results reference the shape's style structs; no deep deinit).
pub fn distill(a: std.mem.Allocator, shape: *const swf_shape.Shape) Error![]DrawPath {
    var conv: Converter = .{
        .a = a,
        .fill_styles = shape.styles.fills,
        .line_styles = shape.styles.lines,
        .winding = if (shape.uses_fill_winding_rule) .non_zero else .even_odd,
        .fill0 = .{ .segment = try Segment.initStart(a, 0, 0) },
        .fill1 = .{ .segment = try Segment.initStart(a, 0, 0) },
        .line = .{ .segment = try Segment.initStart(a, 0, 0) },
    };
    try conv.resizePending();
    for (shape.records) |rec| try conv.visit(rec);
    try conv.flushLayer();
    return conv.out.toOwnedSlice(a);
}

const Converter = struct {
    a: std.mem.Allocator,
    x: i32 = 0,
    y: i32 = 0,
    fill_styles: []const swf_shape.FillStyle,
    line_styles: []const swf_shape.LineStyle,
    winding: Winding,
    fill0: Active,
    fill1: Active,
    line: Active,
    fills: std.ArrayList(Pending) = .empty,
    strokes: std.ArrayList(Pending) = .empty,
    out: std.ArrayList(DrawPath) = .empty,

    fn resizePending(self: *Converter) Error!void {
        while (self.fills.items.len < self.fill_styles.len)
            try self.fills.append(self.a, .{});
        while (self.strokes.items.len < self.line_styles.len)
            try self.strokes.append(self.a, .{});
    }

    fn visit(self: *Converter, rec: swf_shape.ShapeRecord) Error!void {
        switch (rec) {
            .style_change => |change| {
                if (change.move_to) |mv| {
                    self.x = mv.x;
                    self.y = mv.y;
                    try self.flushPaths(); // pen lifted — new path
                }
                if (change.new_styles) |styles| {
                    try self.flushLayer();
                    self.fill_styles = styles.fills;
                    self.line_styles = styles.lines;
                    self.fills.clearRetainingCapacity();
                    self.strokes.clearRetainingCapacity();
                    try self.resizePending();
                }
                if (change.fill_style_1) |id| {
                    try self.fill1.flushFill(self.a, self.x, self.y, self.fills.items, false);
                    self.fill1.style_id = if (id <= self.fill_styles.len) id else 0;
                }
                if (change.fill_style_0) |id| {
                    try self.fill0.flushFill(self.a, self.x, self.y, self.fills.items, true);
                    self.fill0.style_id = if (id <= self.fill_styles.len) id else 0;
                }
                if (change.line_style) |id| {
                    try self.line.flushStroke(self.a, self.x, self.y, self.strokes.items);
                    self.line.style_id = if (id <= self.line_styles.len) id else 0;
                }
            },
            .straight => |e| {
                self.x += e.dx;
                self.y += e.dy;
                try self.visitPoint(false);
            },
            .curved => |e| {
                self.x += e.control_dx;
                self.y += e.control_dy;
                try self.visitPoint(true);
                self.x += e.anchor_dx;
                self.y += e.anchor_dy;
                try self.visitPoint(false);
            },
        }
    }

    fn visitPoint(self: *Converter, ctrl: bool) Error!void {
        const p: Point = .{ .x = self.x, .y = self.y, .ctrl = ctrl };
        if (self.fill1.style_id > 0) try self.fill1.segment.points.append(self.a, p);
        if (self.fill0.style_id > 0) try self.fill0.segment.points.append(self.a, p);
        if (self.line.style_id > 0) try self.line.segment.points.append(self.a, p);
    }

    fn flushPaths(self: *Converter) Error!void {
        try self.fill1.flushFill(self.a, self.x, self.y, self.fills.items, false);
        try self.fill0.flushFill(self.a, self.x, self.y, self.fills.items, true);
        try self.line.flushStroke(self.a, self.x, self.y, self.strokes.items);
    }

    /// Emit everything pending: fills in style order, then strokes (which
    /// always draw on top of fills within a layer).
    fn flushLayer(self: *Converter) Error!void {
        try self.flushPaths();
        for (self.fills.items, 0..) |*pending, i| {
            if (pending.segments.items.len == 0) continue;
            var cmds: std.ArrayList(DrawCommand) = .empty;
            for (pending.segments.items) |*seg| {
                if (!seg.isEmpty()) try seg.appendCommands(self.a, &cmds);
            }
            try self.out.append(self.a, .{ .fill = .{
                .style = &self.fill_styles[i],
                .commands = try cmds.toOwnedSlice(self.a),
                .winding = self.winding,
            } });
            pending.clear(self.a);
        }
        for (self.strokes.items, 0..) |*pending, i| {
            for (pending.segments.items) |*seg| {
                if (seg.isEmpty()) continue;
                var cmds: std.ArrayList(DrawCommand) = .empty;
                try seg.appendCommands(self.a, &cmds);
                try self.out.append(self.a, .{ .stroke = .{
                    .style = &self.line_styles[i],
                    .is_closed = seg.isClosed(),
                    .commands = try cmds.toOwnedSlice(self.a),
                } });
            }
            pending.clear(self.a);
        }
    }
};

// --- shape hit testing -------------------------------------------------------
//
// Port of ruffle render/src/shape_utils.rs `shape_hit_test`, used by
// `MovieClip.hitTest(x, y, true)`. It walks the RAW edge records rather than
// the distilled paths on purpose: Flash accumulates one winding number per
// LAYER across every style in it, and resets only at a NewStyles record.
// Testing each distilled fill path separately would report a hit inside a
// hole that two overlapping even-odd styles are supposed to cancel out.
//
// Everything is twips, in the shape's OWN space; `local_matrix` is passed
// only to derive the on-screen stroke width (Flash's 1px stroke minimum is a
// DEVICE-space rule, so a scaled-down shape still hit-tests a fat outline).

pub const Point2 = struct { x: i32, y: i32 };

fn windingHit(rule: Winding, winding: i32) bool {
    return switch (rule) {
        .even_odd => (winding & 1) != 0,
        .non_zero => winding != 0,
    };
}

/// Half-width (and its square) of a stroke as it appears after `matrix`,
/// with Flash's 1px (20-twip) minimum applied in device space.
fn strokeHalfWidth(width_twips: u16, min_width: f64) [2]f64 {
    const w: f64 = @floatFromInt(width_twips);
    const half = 0.5 * @max(w, min_width);
    return .{ half, half * half };
}

fn strokeMinimumWidth(m: rdr.Matrix) f64 {
    const sx = @sqrt(m.a * m.a + m.b * m.b);
    const sy = @sqrt(m.c * m.c + m.d * m.d);
    return 20.0 * @max(sx, sy);
}

/// Where a hit test's records come from. A parsed shape hands them over
/// as they are; a MORPH has no records of its own at a given ratio, so it
/// interpolates each one as the walk reaches it — no frame is built and
/// nothing is allocated, which is what lets the hit test stay pure.
pub const Walker = union(enum) {
    slice: struct { recs: []const swf_shape.ShapeRecord, i: usize = 0 },
    morph: MorphWalk,

    pub fn next(self: *Walker) ?swf_shape.ShapeRecord {
        switch (self.*) {
            .slice => |*s| {
                if (s.i >= s.recs.len) return null;
                defer s.i += 1;
                return s.recs[s.i];
            },
            .morph => |*m| return m.next(),
        }
    }

    /// The width of line style `index` (1-based), interpolated for a
    /// morph. `lines` is the currently ACTIVE array, which a NewStyles
    /// record can replace mid-shape.
    pub fn lineWidth(self: *const Walker, lines: []const swf_shape.LineStyle, index: u32) ?u16 {
        if (index == 0 or index > lines.len) return null;
        return switch (self.*) {
            .slice => lines[index - 1].width,
            .morph => |m| blk: {
                if (index > m.shape.end_styles.lines.len) break :blk lines[index - 1].width;
                break :blk morph_mod.lerpWidth(
                    m.shape.start_styles.lines[index - 1].width,
                    m.shape.end_styles.lines[index - 1].width,
                    m.a,
                    m.b,
                );
            },
        };
    }
};

/// The pairwise walk over a morph's two edge lists. A StyleChangeRecord
/// can appear on one side without the other, so each side keeps its own
/// pen and only the side that produced a record advances.
pub const MorphWalk = struct {
    shape: *const morph_mod.MorphShape,
    a: f32,
    b: f32,
    si: usize = 0,
    ei: usize = 0,
    start_pen: [2]i32 = .{ 0, 0 },
    end_pen: [2]i32 = .{ 0, 0 },

    pub fn next(self: *MorphWalk) ?swf_shape.ShapeRecord {
        if (self.si >= self.shape.start_records.len) return null;
        if (self.ei >= self.shape.end_records.len) return null;
        const s = self.shape.start_records[self.si];
        const e = self.shape.end_records[self.ei];
        const s_change = s == .style_change;
        const e_change = e == .style_change;
        if (s_change and e_change) {
            var change = s.style_change;
            if (change.move_to != null or e.style_change.move_to != null) {
                if (change.move_to) |mv| self.start_pen = .{ mv.x, mv.y };
                if (e.style_change.move_to) |mv| self.end_pen = .{ mv.x, mv.y };
                change.move_to = .{
                    .x = morph_mod.lerpTwips(self.start_pen[0], self.end_pen[0], self.a, self.b),
                    .y = morph_mod.lerpTwips(self.start_pen[1], self.end_pen[1], self.a, self.b),
                };
            }
            self.si += 1;
            self.ei += 1;
            return .{ .style_change = change };
        }
        // A style change on ONE side only: the styles come from the start
        // side, the pen from whichever side moved.
        if (s_change) {
            var change = s.style_change;
            if (change.move_to) |mv| {
                self.start_pen = .{ mv.x, mv.y };
                change.move_to = .{
                    .x = morph_mod.lerpTwips(self.start_pen[0], self.end_pen[0], self.a, self.b),
                    .y = morph_mod.lerpTwips(self.start_pen[1], self.end_pen[1], self.a, self.b),
                };
            }
            self.si += 1;
            return .{ .style_change = change };
        }
        if (e_change) {
            var change = e.style_change;
            if (change.move_to) |mv| {
                self.end_pen = .{ mv.x, mv.y };
                change.move_to = .{
                    .x = morph_mod.lerpTwips(self.start_pen[0], self.end_pen[0], self.a, self.b),
                    .y = morph_mod.lerpTwips(self.start_pen[1], self.end_pen[1], self.a, self.b),
                };
            }
            self.ei += 1;
            return .{ .style_change = change };
        }
        const out = morph_mod.lerpEdge(self.start_pen, self.end_pen, s, e, self.a, self.b);
        morph_mod.advance(&self.start_pen[0], &self.start_pen[1], s);
        morph_mod.advance(&self.end_pen[0], &self.end_pen[1], e);
        self.si += 1;
        self.ei += 1;
        return out;
    }
};

/// A morph shape at `ratio`, hit-tested against its interpolated outline.
pub fn morphHitTest(
    m: *const morph_mod.MorphShape,
    ratio: u16,
    p: Point2,
    local_matrix: rdr.Matrix,
) bool {
    const w = morph_mod.weights(ratio);
    var walker: Walker = .{ .morph = .{ .shape = m, .a = w[0], .b = w[1] } };
    return walkHitTest(&walker, m.start_styles.lines, .even_odd, p, local_matrix);
}

pub fn shapeHitTest(shape: *const swf_shape.Shape, p: Point2, local_matrix: rdr.Matrix) bool {
    const rule: Winding = if (shape.uses_fill_winding_rule) .non_zero else .even_odd;
    var walker: Walker = .{ .slice = .{ .recs = shape.records } };
    return walkHitTest(&walker, shape.styles.lines, rule, p, local_matrix);
}

fn walkHitTest(
    walker: *Walker,
    initial_lines: []const swf_shape.LineStyle,
    rule: Winding,
    p: Point2,
    local_matrix: rdr.Matrix,
) bool {
    var line_styles = initial_lines;
    var winding: i32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var has_fill0 = false;
    var has_fill1 = false;
    var stroke: ?[2]f64 = null;
    const min_width = strokeMinimumWidth(local_matrix);

    while (walker.next()) |rec| switch (rec) {
        .style_change => |change| {
            // NewStyles starts a new layer: test what we have, then reset.
            if (change.new_styles) |styles| {
                if (windingHit(rule, winding)) return true;
                line_styles = styles.lines;
                winding = 0;
            }
            if (change.move_to) |mv| {
                x = mv.x;
                y = mv.y;
            }
            if (change.fill_style_0) |i| has_fill0 = i > 0;
            if (change.fill_style_1) |i| has_fill1 = i > 0;
            if (change.line_style) |i| {
                stroke = if (walker.lineWidth(line_styles, i)) |w|
                    strokeHalfWidth(w, min_width)
                else
                    null;
            }
        },
        .straight => |e| {
            const ex = x + e.dx;
            const ey = y + e.dy;
            // An edge only counts when exactly ONE side is filled; a shared
            // edge between two fills contributes nothing.
            if (has_fill1) {
                if (!has_fill0) winding += windingLine(p, .{ .x = x, .y = y }, .{ .x = ex, .y = ey });
            } else if (has_fill0) {
                winding += windingLine(p, .{ .x = ex, .y = ey }, .{ .x = x, .y = y });
            }
            if (stroke) |w| {
                if (hitStrokeLine(p, .{ .x = x, .y = y }, .{ .x = ex, .y = ey }, w)) return true;
            }
            x = ex;
            y = ey;
        },
        .curved => |e| {
            const cx = x + e.control_dx;
            const cy = y + e.control_dy;
            const ax = cx + e.anchor_dx;
            const ay = cy + e.anchor_dy;
            const begin: Point2 = .{ .x = x, .y = y };
            const ctrl: Point2 = .{ .x = cx, .y = cy };
            const anchor: Point2 = .{ .x = ax, .y = ay };
            if (has_fill1) {
                if (!has_fill0) winding += windingCurve(p, begin, ctrl, anchor);
            } else if (has_fill0) {
                winding += windingCurve(p, anchor, ctrl, begin);
            }
            if (stroke) |w| {
                if (hitStrokeCurve(p, begin, ctrl, anchor, w)) return true;
            }
            x = ax;
            y = ay;
        },
    };
    return windingHit(rule, winding);
}

/// Hit test over the distilled IR — what the script drawing API produces,
/// since it has no SWF edge records to walk. Each fill path is already a
/// set of closed, consistently-wound contours, so one winding number per
/// path is correct here.
pub fn pathsHitTest(paths: []const DrawPath, p: Point2, local_matrix: rdr.Matrix) bool {
    const min_width = strokeMinimumWidth(local_matrix);
    for (paths) |path| switch (path) {
        .fill => |f| {
            var winding: i32 = 0;
            var start: Point2 = .{ .x = 0, .y = 0 };
            var cur: Point2 = .{ .x = 0, .y = 0 };
            for (f.commands) |cmd| switch (cmd) {
                .move_to => |m| {
                    // Close the previous contour before starting a new one.
                    winding += windingLine(p, cur, start);
                    start = .{ .x = m.x, .y = m.y };
                    cur = start;
                },
                .line_to => |l| {
                    const next: Point2 = .{ .x = l.x, .y = l.y };
                    winding += windingLine(p, cur, next);
                    cur = next;
                },
                .quad_to => |q| {
                    const next: Point2 = .{ .x = q.ax, .y = q.ay };
                    winding += windingCurve(p, cur, .{ .x = q.cx, .y = q.cy }, next);
                    cur = next;
                },
            };
            winding += windingLine(p, cur, start);
            if (windingHit(f.winding, winding)) return true;
        },
        .stroke => |s| {
            const w = strokeHalfWidth(s.style.width, min_width);
            var cur: Point2 = .{ .x = 0, .y = 0 };
            for (s.commands) |cmd| switch (cmd) {
                .move_to => |m| cur = .{ .x = m.x, .y = m.y },
                .line_to => |l| {
                    const next: Point2 = .{ .x = l.x, .y = l.y };
                    if (hitStrokeLine(p, cur, next, w)) return true;
                    cur = next;
                },
                .quad_to => |q| {
                    const next: Point2 = .{ .x = q.ax, .y = q.ay };
                    if (hitStrokeCurve(p, cur, .{ .x = q.cx, .y = q.cy }, next, w)) return true;
                    cur = next;
                },
            };
        },
    };
    return false;
}

/// +1 for a downward crossing left of the point, -1 for an upward one.
/// The half-open interval convention is what stops a vertex shared by two
/// edges counting twice.
fn windingLine(p: Point2, begin: Point2, end: Point2) i32 {
    const d0x: i64 = @as(i64, p.x) - begin.x;
    const d0y: i64 = @as(i64, p.y) - begin.y;
    const d1x: i64 = @as(i64, end.x) - begin.x;
    const d1y: i64 = @as(i64, end.y) - begin.y;
    if (p.y >= begin.y and p.y < end.y and d1x * d0y >= d1y * d0x) return 1;
    if (p.y >= end.y and p.y < begin.y and d1x * d0y <= d1y * d0x) return -1;
    return 0;
}

const COEFFICIENT_EPSILON: f64 = 0.0000001;

/// Roots of ax² + bx + c, ordered so root 0 is where the parabola slopes
/// UPWARD and root 1 downward. NaN marks an absent root. Uses the
/// "Citardauq" form for stability near a == 0.
fn solveQuadratic(a: f64, b: f64, c: f64) [2]f64 {
    const nan = std.math.nan(f64);
    if (@abs(a) <= COEFFICIENT_EPSILON) {
        if (b >= 0) return .{ nan, -c / b };
        return .{ -c / b, nan };
    }
    var disc = b * b - 4.0 * a * c;
    if (disc < 0) return .{ nan, nan };
    disc = @sqrt(disc);
    // Ruffle branches on the sign of b here, but both arms compute the
    // same pair — the ordering it wants falls out unconditionally.
    return .{ (-b - disc) / (2.0 * a), (-b + disc) / (2.0 * a) };
}

fn inRange(lo: f64, hi: f64, v: f64) bool {
    return v >= lo and v < hi;
}

/// Winding contribution of a quadratic bezier, by splitting it into two
/// y-monotonic subcurves so each has at most one crossing of the +x ray.
fn windingCurve(p: Point2, begin: Point2, control: Point2, anchor: Point2) i32 {
    const x0: f64 = @floatFromInt(begin.x - p.x);
    const y0: f64 = @floatFromInt(begin.y - p.y);
    const x1: f64 = @floatFromInt(control.x - p.x);
    const y1: f64 = @floatFromInt(control.y - p.y);
    const x2: f64 = @floatFromInt(anchor.x - p.x);
    const y2: f64 = @floatFromInt(anchor.y - p.y);

    // Early exit: entirely above, below, or left of the ray.
    if ((y0 < 0 and y1 < 0 and y2 < 0) or
        (y0 > 0 and y1 > 0 and y2 > 0) or
        (x0 <= 0 and x1 <= 0 and x2 <= 0)) return 0;

    const a = y0 - 2.0 * y1 + y2;
    const b = 2.0 * (y1 - y0);
    const c = y0;
    const roots = solveQuadratic(a, b, c);
    const t0_ok = std.math.isFinite(roots[0]);
    const t1_ok = std.math.isFinite(roots[1]);
    if (!t0_ok and !t1_ok) return 0;

    var winding: i32 = 0;
    const ax = x0 - 2.0 * x1 + x2;
    const bx = 2.0 * (x1 - x0);
    const t_extrema = -0.5 * b / a;
    // Written as ruffle writes it, NaN behaviour included: a degenerate
    // `a == 0` makes t_extrema non-finite, which reads as NOT monotonic.
    const monotonic = t_extrema <= 0.0 or t_extrema >= 1.0;
    const sample = struct {
        fn f(sx: f64, sbx: f64, sax: f64, t: f64) f64 {
            return sx + sbx * t + sax * t * t;
        }
    }.f;

    if (a >= 0) { // downward-opening
        const y_min = if (monotonic) @min(y0, y2) else a * t_extrema * t_extrema + b * t_extrema + c;
        if (t0_ok and inRange(y_min, y0, 0) and sample(x0, bx, ax, roots[0]) > 0) winding += 1;
        if (t1_ok and inRange(y_min, y2, 0) and sample(x0, bx, ax, roots[1]) > 0) winding -= 1;
    } else { // upward-opening
        const y_max = if (monotonic) @max(y0, y2) else a * t_extrema * t_extrema + b * t_extrema + c;
        if (t1_ok and inRange(y0, y_max, 0) and sample(x0, bx, ax, roots[1]) > 0) winding -= 1;
        if (t0_ok and inRange(y2, y_max, 0) and sample(x0, bx, ax, roots[0]) > 0) winding += 1;
    }
    return winding;
}

fn hitStrokeLine(p: Point2, begin: Point2, end: Point2, w: [2]f64) bool {
    const px: f64 = @floatFromInt(p.x);
    const py: f64 = @floatFromInt(p.y);
    const x0: f64 = @floatFromInt(begin.x);
    const y0: f64 = @floatFromInt(begin.y);
    const x1: f64 = @floatFromInt(end.x);
    const y1: f64 = @floatFromInt(end.y);
    if (px < @min(x0, x1) - w[0] or px > @max(x0, x1) + w[0]) return false;
    if (py < @min(y0, y1) - w[0] or py > @max(y0, y1) + w[0]) return false;

    const abx = x1 - x0;
    const aby = y1 - y0;
    const apx = px - x0;
    const apy = py - y0;
    const dot_a = abx * apx + aby * apy;
    var dist: f64 = undefined;
    if (dot_a <= 0) {
        dist = apx * apx + apy * apy;
    } else {
        const bpx = px - x1;
        const bpy = py - y1;
        if (abx * bpx + aby * bpy >= 0) {
            dist = bpx * bpx + bpy * bpy;
        } else {
            const len = abx * abx + aby * aby;
            const ex = apx - dot_a * abx / len;
            const ey = apy - dot_a * aby / len;
            dist = ex * ex + ey * ey;
        }
    }
    return dist <= w[1];
}

fn hitStrokeCurve(p: Point2, begin: Point2, control: Point2, anchor: Point2, w: [2]f64) bool {
    const px: f64 = @floatFromInt(p.x);
    const py: f64 = @floatFromInt(p.y);
    const x0: f64 = @floatFromInt(begin.x);
    const y0: f64 = @floatFromInt(begin.y);
    const x1: f64 = @floatFromInt(control.x);
    const y1: f64 = @floatFromInt(control.y);
    const x2: f64 = @floatFromInt(anchor.x);
    const y2: f64 = @floatFromInt(anchor.y);
    if (px < @min(x0, @min(x1, x2)) - w[0] or px > @max(x0, @max(x1, x2)) + w[0]) return false;
    if (py < @min(y0, @min(y1, y2)) - w[0] or py > @max(y0, @max(y1, y2)) + w[0]) return false;

    // The nearest point on the curve is where (P - C(t)) · C'(t) == 0 — a
    // cubic in t (blog.gludion.com/2009/08/distance-to-quadratic-bezier-curve).
    const ax = x1 - x0;
    const ay = y1 - y0;
    const bx = x2 - x1 - ax;
    const by = y2 - y1 - ay;
    const mx = x0 - px;
    const my = y0 - py;
    const ca = bx * bx + by * by;
    const cb = 3.0 * (ax * bx + ay * by);
    const cc = 2.0 * (ax * ax + ay * ay) + (mx * bx + my * by);
    const cd = mx * ax + my * ay;

    const distAt = struct {
        fn f(sx0: f64, sy0: f64, sx1: f64, sy1: f64, sx2: f64, sy2: f64, ppx: f64, ppy: f64, t: f64) f64 {
            const u = 1.0 - t;
            const cx = u * u * sx0 + 2.0 * u * t * sx1 + t * t * sx2;
            const cy = u * u * sy0 + 2.0 * u * t * sy1 + t * t * sy2;
            const dx = cx - ppx;
            const dy = cy - ppy;
            return dx * dx + dy * dy;
        }
    }.f;

    var dist = @min(
        distAt(x0, y0, x1, y1, x2, y2, px, py, 0),
        distAt(x0, y0, x1, y1, x2, y2, px, py, 1),
    );
    var roots: [3]f64 = undefined;
    for (solveCubic(ca, cb, cc, cd, &roots)) |t| {
        if (t >= 0 and t <= 1) dist = @min(dist, distAt(x0, y0, x1, y1, x2, y2, px, py, t));
    }
    return dist <= w[1];
}

/// Real roots of ax³ + bx² + cx + d, written into `out`. Not necessarily
/// unique; ruffle notes this is not especially numerically robust, and it
/// only feeds a distance minimisation, so that is tolerable.
fn solveCubic(a: f64, b: f64, c: f64, d: f64, out: *[3]f64) []f64 {
    if (@abs(a) <= COEFFICIENT_EPSILON) {
        const q = solveQuadratic(b, c, d);
        out[0] = q[0];
        out[1] = q[1];
        return out[0..2];
    }
    const p = (b * b - 3.0 * a * c) / (9.0 * a * a);
    const q = (9.0 * a * b * c - 27.0 * a * a * d - 2.0 * b * b * b) / (54.0 * a * a * a);
    const offset = b / (3.0 * a);
    const disc = p * p * p - q * q;
    if (disc > 0) {
        const theta = std.math.acos(q / (p * @sqrt(p)));
        const r = 2.0 * @sqrt(p);
        out[0] = r * @cos(theta / 3.0) - offset;
        out[1] = r * @cos((theta + 2.0 * std.math.pi) / 3.0) - offset;
        out[2] = r * @cos((theta + 4.0 * std.math.pi) / 3.0) - offset;
        return out[0..3];
    }
    const g1 = std.math.cbrt(q + @sqrt(-disc));
    const g2 = std.math.cbrt(q - @sqrt(-disc));
    out[0] = g1 + g2 - offset;
    if (disc == 0) {
        out[1] = -0.5 * (g1 + g2) - offset;
        return out[0..2];
    }
    return out[0..1];
}

// --- Tests -----------------------------------------------------------------

fn sc(mv: ?[2]i32, f0: ?u32, f1: ?u32, ln: ?u32) swf_shape.ShapeRecord {
    return .{ .style_change = .{
        .move_to = if (mv) |m| .{ .x = m[0], .y = m[1] } else null,
        .fill_style_0 = f0,
        .fill_style_1 = f1,
        .line_style = ln,
    } };
}

fn edge(dx: i32, dy: i32) swf_shape.ShapeRecord {
    return .{ .straight = .{ .dx = dx, .dy = dy } };
}

test "single closed square becomes one fill path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fills = [_]swf_shape.FillStyle{.{ .solid = 0xFF0000FF }};
    var records = [_]swf_shape.ShapeRecord{
        sc(.{ 0, 0 }, null, 1, null),
        edge(200, 0),
        edge(0, 200),
        edge(-200, 0),
        edge(0, -200),
    };
    const s: swf_shape.Shape = .{
        .version = 1,
        .id = 1,
        .bounds = .{},
        .edge_bounds = .{},
        .styles = .{ .fills = &fills, .lines = &.{} },
        .records = &records,
    };
    const paths = try distill(a, &s);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    const fill = paths[0].fill;
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), fill.style.solid);
    try std.testing.expectEqual(Winding.even_odd, fill.winding);
    try std.testing.expectEqual(@as(usize, 5), fill.commands.len); // move + 4 lines
    try std.testing.expectEqual(@as(i32, 0), fill.commands[0].move_to.x);
    try std.testing.expectEqual(@as(i32, 200), fill.commands[1].line_to.x);
}

test "shared edge: fill0 flips and segments link into closed contours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two adjacent triangles sharing the diagonal: left fill 1, right
    // fill 2. The diagonal edge carries fill0=1/fill1=2; the outer edges
    // carry one fill each. Segment linking must close both contours.
    var fills = [_]swf_shape.FillStyle{ .{ .solid = 0xFF0000FF }, .{ .solid = 0xFF00FF00 } };
    var records = [_]swf_shape.ShapeRecord{
        // Outer edges of the left triangle (fill1 = 1): (0,0)→(0,200)→(200,200)
        sc(.{ 0, 0 }, null, 1, null),
        edge(0, 200),
        edge(200, 0),
        // Diagonal (200,200)→(0,0): left of travel = fill 2, right = fill 1
        sc(null, 2, 1, null),
        edge(-200, -200),
        // Outer edges of the right triangle (fill1 = 2), travelling
        // (200,200)→(200,0)→(0,0) so fill 2 stays on the right side and
        // the contour links onto the flipped diagonal. fill0 cleared.
        sc(.{ 200, 200 }, 0, 2, null),
        edge(0, -200),
        edge(-200, 0),
    };
    const s: swf_shape.Shape = .{
        .version = 1,
        .id = 1,
        .bounds = .{},
        .edge_bounds = .{},
        .styles = .{ .fills = &fills, .lines = &.{} },
        .records = &records,
    };
    const paths = try distill(a, &s);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    for (paths) |p| {
        const cmds = p.fill.commands;
        // Each fill must be a single closed contour: 1 move + 3 edges,
        // ending back at its start.
        try std.testing.expectEqual(@as(usize, 4), cmds.len);
        const first = cmds[0].move_to;
        const last = cmds[cmds.len - 1].line_to;
        try std.testing.expectEqual(first.x, last.x);
        try std.testing.expectEqual(first.y, last.y);
    }
}

test "curved edges emit quad_to and strokes report closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines = [_]swf_shape.LineStyle{.{ .width = 20, .fill = .{ .solid = 0xFF000000 } }};
    var records = [_]swf_shape.ShapeRecord{
        sc(.{ 0, 0 }, null, null, 1),
        .{ .curved = .{ .control_dx = 100, .control_dy = 0, .anchor_dx = 0, .anchor_dy = 100 } },
        edge(-100, -100),
    };
    const s: swf_shape.Shape = .{
        .version = 1,
        .id = 1,
        .bounds = .{},
        .edge_bounds = .{},
        .styles = .{ .fills = &.{}, .lines = &lines },
        .records = &records,
    };
    const paths = try distill(a, &s);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    const stroke = paths[0].stroke;
    try std.testing.expect(stroke.is_closed);
    try std.testing.expectEqual(@as(usize, 3), stroke.commands.len);
    try std.testing.expectEqual(@as(i32, 100), stroke.commands[1].quad_to.cx);
    try std.testing.expectEqual(@as(i32, 100), stroke.commands[1].quad_to.ay);
}

test "shape hit test: inside, outside, and the even-odd hole" {
    // A 100x100-twip square with a 50x50 square punched out of its middle.
    // Both contours use fill style 1, so under EVEN-ODD the inner one is a
    // hole; under NON-ZERO (same winding direction) it is filled solid.
    const records = [_]swf_shape.ShapeRecord{
        sc(.{ 0, 0 }, null, 1, null),
        edge(100, 0),  edge(0, 100),  edge(-100, 0), edge(0, -100),
        sc(.{ 25, 25 }, null, 1, null),
        edge(50, 0),   edge(0, 50),   edge(-50, 0),  edge(0, -50),
    };
    var fills = [_]swf_shape.FillStyle{.{ .solid = 0xFF0000FF }};
    var s: swf_shape.Shape = .{
        .version = 3,
        .id = 1,
        .bounds = .{ .xmin = 0, .xmax = 100, .ymin = 0, .ymax = 100 },
        .edge_bounds = .{ .xmin = 0, .xmax = 100, .ymin = 0, .ymax = 100 },
        .styles = .{ .fills = &fills, .lines = &.{} },
        .records = @constCast(&records),
    };

    try std.testing.expect(shapeHitTest(&s, .{ .x = 10, .y = 50 }, .identity)); // in the ring
    try std.testing.expect(!shapeHitTest(&s, .{ .x = -5, .y = 50 }, .identity)); // outside
    try std.testing.expect(!shapeHitTest(&s, .{ .x = 50, .y = 50 }, .identity)); // in the hole

    // Shape4's non-zero flag fills the hole in.
    s.uses_fill_winding_rule = true;
    try std.testing.expect(shapeHitTest(&s, .{ .x = 50, .y = 50 }, .identity));
}

test "stroke hit test honours Flash's 1px device-space minimum" {
    // A hairline (0-twip) diagonal: nothing is inside it, but the 1px
    // minimum makes points within half a pixel of the line count.
    var lines = [_]swf_shape.LineStyle{.{ .width = 0, .fill = .{ .solid = 0xFF000000 } }};
    const records = [_]swf_shape.ShapeRecord{
        sc(.{ 0, 0 }, null, null, 1),
        edge(200, 0),
    };
    const s: swf_shape.Shape = .{
        .version = 1,
        .id = 1,
        .bounds = .{},
        .edge_bounds = .{},
        .styles = .{ .fills = &.{}, .lines = &lines },
        .records = @constCast(&records),
    };
    try std.testing.expect(shapeHitTest(&s, .{ .x = 100, .y = 0 }, .identity));
    try std.testing.expect(shapeHitTest(&s, .{ .x = 100, .y = 9 }, .identity));
    try std.testing.expect(!shapeHitTest(&s, .{ .x = 100, .y = 11 }, .identity));
    // Scaling the shape up scales the minimum with it.
    try std.testing.expect(shapeHitTest(&s, .{ .x = 100, .y = 30 }, .{ .a = 4, .d = 4 }));
}
