//! The script drawing API's backing store — one per MovieClip.
//!
//! Port of ruffle render/src/drawing.rs. A clip accumulates ONE open fill
//! subpath and ONE open stroke subpath at a time; changing either style
//! commits what is pending and starts a fresh subpath at the cursor. The
//! committed result is exactly the `DrawPath` IR the SWF shape distiller
//! already produces, so the renderer draws script paths and tag shapes
//! through the same code.
//!
//! Coordinates are TWIPS, like everything else under `core/`.
//!
//! Bounds are what `_width`/`_height`/`getBounds` see, so they follow
//! ruffle exactly: only DRAW commands stretch them (a `beginFill` alone
//! does not), and a stroke widens them by half its width on every side.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const shape_utils = @import("../render/shape_utils.zig");

const DrawCommand = shape_utils.DrawCommand;
const DrawPath = shape_utils.DrawPath;
const Rectangle = swf.reader.Rectangle;
const FillStyle = swf.shape.FillStyle;
const LineStyle = swf.shape.LineStyle;

pub const Error = std.mem.Allocator.Error;

const Point = struct { x: i32 = 0, y: i32 = 0 };

/// A subpath being built. `style` is heap-owned so the `DrawPath` pointers
/// handed to the renderer stay valid as the lists grow.
fn Pending(comptime Style: type) type {
    return struct {
        style: *Style,
        commands: std.ArrayList(DrawCommand) = .empty,
    };
}

pub const Drawing = struct {
    gpa: std.mem.Allocator,
    paths: std.ArrayList(DrawPath) = .empty,
    fill: ?Pending(FillStyle) = null,
    line: ?Pending(LineStyle) = null,
    cursor: Point = .{},
    /// Where the current fill subpath began — `endFill` closes back to it.
    fill_start: Point = .{},
    /// null until the first draw command: an untouched clip has NO bounds,
    /// which is what makes `_width` on an empty clip read 0 rather than a
    /// degenerate box at the origin.
    bounds: ?Rectangle = null,

    pub fn init(gpa: std.mem.Allocator) Drawing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Drawing) void {
        for (self.paths.items) |p| self.freePath(p);
        self.paths.deinit(self.gpa);
        if (self.fill) |*f| {
            self.gpa.destroy(f.style);
            f.commands.deinit(self.gpa);
        }
        if (self.line) |*l| {
            self.gpa.destroy(l.style);
            l.commands.deinit(self.gpa);
        }
        self.* = undefined;
    }

    fn freePath(self: *Drawing, p: DrawPath) void {
        switch (p) {
            .fill => |f| {
                self.gpa.destroy(@constCast(f.style));
                self.gpa.free(f.commands);
            },
            .stroke => |s| {
                self.gpa.destroy(@constCast(s.style));
                self.gpa.free(s.commands);
            },
        }
    }

    /// A deep copy — `duplicateMovieClip` carries the source's drawing over
    /// (ruffle clone_sprite:1014-1016), so the clone's `_width` reflects
    /// both the inherited geometry and whatever the script draws next.
    pub fn clone(self: *const Drawing, gpa: std.mem.Allocator) Error!Drawing {
        var out: Drawing = .{
            .gpa = gpa,
            .cursor = self.cursor,
            .fill_start = self.fill_start,
            .bounds = self.bounds,
        };
        errdefer out.deinit();
        for (self.paths.items) |p| switch (p) {
            .fill => |f| {
                const style = try gpa.create(FillStyle);
                style.* = f.style.*;
                try out.paths.append(gpa, .{ .fill = .{
                    .style = style,
                    .commands = try gpa.dupe(DrawCommand, f.commands),
                    .winding = f.winding,
                } });
            },
            .stroke => |s| {
                const style = try gpa.create(LineStyle);
                style.* = s.style.*;
                try out.paths.append(gpa, .{ .stroke = .{
                    .style = style,
                    .is_closed = s.is_closed,
                    .commands = try gpa.dupe(DrawCommand, s.commands),
                } });
            },
        };
        if (self.fill) |f| {
            const style = try gpa.create(FillStyle);
            style.* = f.style.*;
            var cmds: std.ArrayList(DrawCommand) = .empty;
            try cmds.appendSlice(gpa, f.commands.items);
            out.fill = .{ .style = style, .commands = cmds };
        }
        if (self.line) |l| {
            const style = try gpa.create(LineStyle);
            style.* = l.style.*;
            var cmds: std.ArrayList(DrawCommand) = .empty;
            try cmds.appendSlice(gpa, l.commands.items);
            out.line = .{ .style = style, .commands = cmds };
        }
        return out;
    }

    pub fn clear(self: *Drawing) void {
        const gpa = self.gpa;
        self.deinit();
        self.* = init(gpa);
    }

    /// `beginFill` (style set) / `endFill` (null): commit the open fill
    /// subpath, then open a new one at the cursor.
    pub fn setFillStyle(self: *Drawing, style: ?FillStyle) Error!void {
        try self.commitFill();
        if (style) |s| {
            const owned = try self.gpa.create(FillStyle);
            owned.* = s;
            var f: Pending(FillStyle) = .{ .style = owned };
            try f.commands.append(self.gpa, .{ .move_to = .{ .x = self.cursor.x, .y = self.cursor.y } });
            self.fill = f;
            self.fill_start = self.cursor;
        }
    }

    /// `lineStyle` (style set) / `lineStyle()` with no args (null).
    pub fn setLineStyle(self: *Drawing, style: ?LineStyle) Error!void {
        try self.commitLine();
        if (style) |s| {
            const owned = try self.gpa.create(LineStyle);
            owned.* = s;
            var l: Pending(LineStyle) = .{ .style = owned };
            try l.commands.append(self.gpa, .{ .move_to = .{ .x = self.cursor.x, .y = self.cursor.y } });
            self.line = l;
        }
    }

    pub fn draw(self: *Drawing, cmd: DrawCommand) Error!void {
        // A fill records MoveTo as a subpath break; a stroke can't span one,
        // so it commits and restarts (ruffle drawing.rs draw_command).
        if (self.fill) |*f| try f.commands.append(self.gpa, cmd);
        if (cmd == .move_to) {
            if (self.line != null) {
                const style = self.line.?.style.*;
                try self.commitLine();
                const owned = try self.gpa.create(LineStyle);
                owned.* = style;
                var l: Pending(LineStyle) = .{ .style = owned };
                try l.commands.append(self.gpa, cmd);
                self.line = l;
            }
        } else if (self.line) |*l| {
            try l.commands.append(self.gpa, cmd);
        }
        const half = if (self.line) |l| @as(i32, @intCast(l.style.width / 2)) else 0;
        self.stretch(cmd, half);
        self.cursor = endPoint(cmd);
    }

    fn stretch(self: *Drawing, cmd: DrawCommand, pad: i32) void {
        switch (cmd) {
            .move_to => |p| self.stretchPoint(p.x, p.y, pad),
            .line_to => |p| self.stretchPoint(p.x, p.y, pad),
            .quad_to => |q| {
                // The control point is an outer bound on the curve, which is
                // what Flash reports too — no tight-fitting is attempted.
                self.stretchPoint(q.cx, q.cy, pad);
                self.stretchPoint(q.ax, q.ay, pad);
            },
        }
    }

    fn stretchPoint(self: *Drawing, x: i32, y: i32, pad: i32) void {
        const box: Rectangle = .{
            .xmin = x -| pad,
            .xmax = x +| pad,
            .ymin = y -| pad,
            .ymax = y +| pad,
        };
        self.bounds = if (self.bounds) |b| .{
            .xmin = @min(b.xmin, box.xmin),
            .xmax = @max(b.xmax, box.xmax),
            .ymin = @min(b.ymin, box.ymin),
            .ymax = @max(b.ymax, box.ymax),
        } else box;
    }

    fn commitFill(self: *Drawing) Error!void {
        var f = self.fill orelse return;
        self.fill = null;
        // A fill is implicitly closed back to where it started.
        if (f.commands.items.len > 1) {
            if (self.cursor.x != self.fill_start.x or self.cursor.y != self.fill_start.y) {
                try f.commands.append(self.gpa, .{
                    .line_to = .{ .x = self.fill_start.x, .y = self.fill_start.y },
                });
            }
            try self.paths.append(self.gpa, .{ .fill = .{
                .style = f.style,
                .commands = try f.commands.toOwnedSlice(self.gpa),
                .winding = .even_odd,
            } });
        } else {
            self.gpa.destroy(f.style);
            f.commands.deinit(self.gpa);
        }
    }

    fn commitLine(self: *Drawing) Error!void {
        var l = self.line orelse return;
        self.line = null;
        if (l.commands.items.len > 1) {
            const first = l.commands.items[0];
            const closed = pointEql(endPoint(first), endPoint(l.commands.items[l.commands.items.len - 1]));
            try self.paths.append(self.gpa, .{ .stroke = .{
                .style = l.style,
                .is_closed = closed,
                .commands = try l.commands.toOwnedSlice(self.gpa),
            } });
        } else {
            self.gpa.destroy(l.style);
            l.commands.deinit(self.gpa);
        }
    }

    /// Everything drawn so far, including subpaths still open — the
    /// renderer must show geometry before `endFill` is ever called.
    pub fn render(self: *Drawing, out: *std.ArrayList(DrawPath), gpa: std.mem.Allocator) Error!void {
        try out.appendSlice(gpa, self.paths.items);
        if (self.fill) |f| {
            if (f.commands.items.len > 1) {
                try out.append(gpa, .{ .fill = .{
                    .style = f.style,
                    .commands = f.commands.items,
                    .winding = .even_odd,
                } });
            }
        }
        if (self.line) |l| {
            if (l.commands.items.len > 1) {
                try out.append(gpa, .{ .stroke = .{
                    .style = l.style,
                    .is_closed = false,
                    .commands = l.commands.items,
                } });
            }
        }
    }
};

fn pointEql(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn endPoint(cmd: DrawCommand) Point {
    return switch (cmd) {
        .move_to => |p| .{ .x = p.x, .y = p.y },
        .line_to => |p| .{ .x = p.x, .y = p.y },
        .quad_to => |q| .{ .x = q.ax, .y = q.ay },
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "bounds follow draw commands only, and survive a clone" {
    var d = Drawing.init(testing.allocator);
    defer d.deinit();

    // beginFill alone must not create bounds: an empty clip has none.
    try d.setFillStyle(.{ .solid = 0xFF0000FF }); // opaque red (A,B,G,R)
    try testing.expectEqual(@as(?Rectangle, null), d.bounds);

    // A 100x100-twip triangle back to the origin.
    try d.draw(.{ .line_to = .{ .x = 2000, .y = 2000 } });
    try d.draw(.{ .line_to = .{ .x = 2000, .y = 0 } });
    try d.draw(.{ .line_to = .{ .x = 0, .y = 0 } });
    try d.setFillStyle(null);
    try testing.expectEqual(@as(i32, 2000), d.bounds.?.width());
    try testing.expectEqual(@as(usize, 1), d.paths.items.len);

    // The clone inherits geometry AND bounds, then extends them.
    var c = try d.clone(testing.allocator);
    defer c.deinit();
    try c.draw(.{ .move_to = .{ .x = 6000, .y = 0 } });
    try c.draw(.{ .line_to = .{ .x = 8000, .y = 2000 } });
    try testing.expectEqual(@as(i32, 8000), c.bounds.?.width());
    // ...without disturbing the original.
    try testing.expectEqual(@as(i32, 2000), d.bounds.?.width());
}
