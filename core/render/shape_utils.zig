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
        // Outer edges of the right triangle (fill1 = 2): (0,0)→(200,0)→(200,200)
        sc(.{ 0, 0 }, null, 2, null),
        edge(200, 0),
        edge(0, 200),
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
