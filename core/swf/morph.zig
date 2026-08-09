//! DefineMorphShape1-2 — a shape given TWICE, and every ratio in between.
//!
//! The tag pairs up its two ends: one style array where each entry holds
//! both a start and an end value, then two edge lists that walk the same
//! outline. A frame at ratio R is the pairwise interpolation of the two,
//! which is what `render/shape_utils.zig` walks for hit testing (and,
//! from M7, for drawing).
//!
//! The two edge lists are NOT required to line up record for record: a
//! StyleChangeRecord can appear on one side alone, so the walk carries a
//! pen position for each side and only advances the side that moved.
//!
//! Layout reference: reference/ruffle/swf/src/read.rs
//! `read_define_morph_shape`; interpolation:
//! reference/ruffle/core/src/display_object/morph_shape.rs
//! `build_morph_frame`.

const std = @import("std");
const rdr = @import("reader.zig");
const shape = @import("shape.zig");

pub const Error = shape.Error;

pub const MorphShape = struct {
    id: u16,
    version: u8,
    start_bounds: rdr.Rectangle,
    end_bounds: rdr.Rectangle,
    start_edge_bounds: rdr.Rectangle,
    end_edge_bounds: rdr.Rectangle,
    uses_non_scaling_strokes: bool = false,
    uses_scaling_strokes: bool = false,
    /// Both ends of every style, in the same order — index N of one is
    /// index N of the other, which is what makes a style interpolable.
    start_styles: shape.ShapeStyles,
    end_styles: shape.ShapeStyles,
    start_records: []shape.ShapeRecord,
    end_records: []shape.ShapeRecord,
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8, swf_version: u8, version: u8) Error!MorphShape {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const start_bounds = try r.readRectangle();
    const end_bounds = try r.readRectangle();
    var start_edge_bounds = start_bounds;
    var end_edge_bounds = end_bounds;
    var non_scaling = true;
    var scaling = false;
    if (version >= 2) {
        start_edge_bounds = try r.readRectangle();
        end_edge_bounds = try r.readRectangle();
        const flags = try r.readU8();
        non_scaling = (flags & 0b10) != 0;
        scaling = (flags & 0b01) != 0;
    }
    _ = try r.readU32(); // offset to EndEdges — the reader just walks on

    // Morph styles are ALWAYS RGBA, whatever the tag version, so the
    // shape context claims version 3 for the colour reads.
    const ctx: shape.Context = .{ .swf_version = swf_version, .shape_version = if (version >= 2) 4 else 3 };

    var start_fills: std.ArrayList(shape.FillStyle) = .empty;
    var end_fills: std.ArrayList(shape.FillStyle) = .empty;
    const nf: usize = blk: {
        const n = try r.readU8();
        if (n == 0xFF) break :blk try r.readU16();
        break :blk n;
    };
    for (0..nf) |_| {
        const pair = try parseMorphFill(allocator, &r, ctx);
        try start_fills.append(allocator, pair[0]);
        try end_fills.append(allocator, pair[1]);
    }

    var start_lines: std.ArrayList(shape.LineStyle) = .empty;
    var end_lines: std.ArrayList(shape.LineStyle) = .empty;
    const nl: usize = blk: {
        const n = try r.readU8();
        if (n == 0xFF) break :blk try r.readU16();
        break :blk n;
    };
    for (0..nl) |_| {
        const pair = try parseMorphLine(allocator, &r, ctx, version);
        try start_lines.append(allocator, pair[0]);
        try end_lines.append(allocator, pair[1]);
    }

    // The START edges carry the index bit widths; the END edges are
    // written with both widths zeroed, in their own byte.
    const rec_ctx: shape.Context = .{ .swf_version = swf_version, .shape_version = version };
    var bits: shape.Bits = .{ .fill = 0, .line = 0 };
    const nbits = try r.readU8();
    bits.fill = @intCast(nbits >> 4);
    bits.line = @intCast(nbits & 0x0F);
    const start_records = try shape.parseRecords(allocator, &r, rec_ctx, &bits);

    // The end shape's own bit-width byte is written as zero, and ruffle
    // TAKES it as zero whatever it says — the end edges never name a
    // style, so there is nothing for the widths to size.
    _ = try r.readU8();
    var end_bits: shape.Bits = .{ .fill = 0, .line = 0 };
    const end_records = try shape.parseRecords(allocator, &r, rec_ctx, &end_bits);

    return .{
        .id = id,
        .version = version,
        .start_bounds = start_bounds,
        .end_bounds = end_bounds,
        .start_edge_bounds = start_edge_bounds,
        .end_edge_bounds = end_edge_bounds,
        .uses_non_scaling_strokes = non_scaling,
        .uses_scaling_strokes = scaling,
        .start_styles = .{
            .fills = try start_fills.toOwnedSlice(allocator),
            .lines = try start_lines.toOwnedSlice(allocator),
        },
        .end_styles = .{
            .fills = try end_fills.toOwnedSlice(allocator),
            .lines = try end_lines.toOwnedSlice(allocator),
        },
        .start_records = start_records,
        .end_records = end_records,
    };
}

/// One MORPHFILLSTYLE — a single type byte followed by both ends.
fn parseMorphFill(
    allocator: std.mem.Allocator,
    r: *rdr.Reader,
    ctx: shape.Context,
) Error![2]shape.FillStyle {
    const t = try r.readU8();
    switch (t) {
        0x00 => {
            const s = try r.readRgba();
            const e = try r.readRgba();
            return .{ .{ .solid = s }, .{ .solid = e } };
        },
        0x10, 0x12, 0x13 => {
            const g = try parseMorphGradient(allocator, r);
            var start_focal: f32 = 0;
            var end_focal: f32 = 0;
            if (t == 0x13) {
                start_focal = try r.readFixed8();
                end_focal = try r.readFixed8();
            }
            return switch (t) {
                0x10 => .{ .{ .linear_gradient = g[0] }, .{ .linear_gradient = g[1] } },
                0x12 => .{ .{ .radial_gradient = g[0] }, .{ .radial_gradient = g[1] } },
                else => .{
                    .{ .focal_gradient = .{ .gradient = g[0], .focal_point = start_focal } },
                    .{ .focal_gradient = .{ .gradient = g[1], .focal_point = end_focal } },
                },
            };
        },
        0x40, 0x41, 0x42, 0x43 => {
            const id = try r.readU16();
            const start_matrix = try r.readMatrix();
            const end_matrix = try r.readMatrix();
            const smoothed = ctx.swf_version >= 8 and (t & 0b10) == 0;
            const repeating = (t & 0b01) == 0;
            return .{
                .{ .bitmap = .{ .id = id, .matrix = start_matrix, .is_smoothed = smoothed, .is_repeating = repeating } },
                .{ .bitmap = .{ .id = id, .matrix = end_matrix, .is_smoothed = smoothed, .is_repeating = repeating } },
            };
        },
        else => return Error.InvalidFillStyle,
    }
}

/// A MORPHGRADIENT: two matrices, then records that pair a start and an
/// end ratio/colour.
fn parseMorphGradient(allocator: std.mem.Allocator, r: *rdr.Reader) Error![2]shape.Gradient {
    const start_matrix = try r.readMatrix();
    const end_matrix = try r.readMatrix();
    const flags = try r.readU8();
    const spread: shape.GradientSpread = @enumFromInt(@as(u2, @intCast((flags >> 6) & 0b11)));
    const interpolation: shape.GradientInterpolation = @enumFromInt(@as(u2, @intCast((flags >> 4) & 0b11)));
    const n: usize = flags & 0x0F;
    const start_recs = try allocator.alloc(shape.GradientRecord, n);
    const end_recs = try allocator.alloc(shape.GradientRecord, n);
    for (start_recs, end_recs) |*s, *e| {
        s.* = .{ .ratio = try r.readU8(), .color = try r.readRgba() };
        e.* = .{ .ratio = try r.readU8(), .color = try r.readRgba() };
    }
    return .{
        .{ .matrix = start_matrix, .spread = spread, .interpolation = interpolation, .records = start_recs },
        .{ .matrix = end_matrix, .spread = spread, .interpolation = interpolation, .records = end_recs },
    };
}

fn parseMorphLine(
    allocator: std.mem.Allocator,
    r: *rdr.Reader,
    ctx: shape.Context,
    version: u8,
) Error![2]shape.LineStyle {
    const start_width = try r.readU16();
    const end_width = try r.readU16();
    if (version < 2) {
        return .{
            .{ .width = start_width, .fill = .{ .solid = try r.readRgba() } },
            .{ .width = end_width, .fill = .{ .solid = try r.readRgba() } },
        };
    }
    const flags = try r.readU16();
    const pixel_hinting = (flags & (1 << 0)) != 0;
    const no_v_scale = (flags & (1 << 1)) != 0;
    const no_h_scale = (flags & (1 << 2)) != 0;
    const has_fill = (flags & (1 << 3)) != 0;
    const join: shape.LineJoin = @enumFromInt(@as(u2, @intCast((flags >> 4) & 0b11)));
    const start_cap: shape.LineCap = @enumFromInt(@as(u2, @intCast((flags >> 6) & 0b11)));
    const end_cap: shape.LineCap = @enumFromInt(@as(u2, @intCast((flags >> 8) & 0b11)));
    const no_close = (flags & (1 << 10)) != 0;
    const miter_limit: f32 = if (join == .miter) try r.readFixed8() else 0;
    var fills: [2]shape.FillStyle = undefined;
    if (has_fill) {
        fills = try parseMorphFill(allocator, r, ctx);
    } else {
        fills = .{ .{ .solid = try r.readRgba() }, .{ .solid = try r.readRgba() } };
    }
    const common: shape.LineStyle = .{
        .width = 0,
        .fill = fills[0],
        .start_cap = start_cap,
        .end_cap = end_cap,
        .join = join,
        .miter_limit = miter_limit,
        .no_h_scale = no_h_scale,
        .no_v_scale = no_v_scale,
        .no_close = no_close,
        .pixel_hinting = pixel_hinting,
    };
    var start = common;
    start.width = start_width;
    var end = common;
    end.width = end_width;
    end.fill = fills[1];
    return .{ start, end };
}

// --- interpolation ---------------------------------------------------------

/// Ratio 0 is the START shape and 65535 the end, so `b` is the weight of
/// the end (ruffle names them the same way round).
pub fn weights(ratio: u16) [2]f32 {
    const b = @as(f32, @floatFromInt(ratio)) / 65535.0;
    return .{ 1.0 - b, b };
}

pub fn lerpTwips(start: i32, end: i32, a: f32, b: f32) i32 {
    const v = @as(f32, @floatFromInt(start)) * a + @as(f32, @floatFromInt(end)) * b;
    return @intFromFloat(@round(v));
}

pub fn lerpWidth(start: u16, end: u16, a: f32, b: f32) u16 {
    const v = @as(f32, @floatFromInt(start)) * a + @as(f32, @floatFromInt(end)) * b;
    if (v <= 0) return 0;
    if (v >= 65535) return 65535;
    return @intFromFloat(@round(v));
}

/// The pen position after `rec`, given where it was.
pub fn advance(x: *i32, y: *i32, rec: shape.ShapeRecord) void {
    switch (rec) {
        .style_change => |sc| if (sc.move_to) |mv| {
            x.* = mv.x;
            y.* = mv.y;
        },
        .straight => |e| {
            x.* += e.dx;
            y.* += e.dy;
        },
        .curved => |e| {
            x.* += e.control_dx + e.anchor_dx;
            y.* += e.control_dy + e.anchor_dy;
        },
    }
}

/// Interpolate a pair of EDGE records, given both pens. Deltas cannot be
/// interpolated directly — the two sides' pens differ — so both edges are
/// resolved to absolute points first and the result is taken back to a
/// delta from the interpolated pen.
pub fn lerpEdge(
    start_pen: [2]i32,
    end_pen: [2]i32,
    s: shape.ShapeRecord,
    e: shape.ShapeRecord,
    a: f32,
    b: f32,
) shape.ShapeRecord {
    const pen_x = lerpTwips(start_pen[0], end_pen[0], a, b);
    const pen_y = lerpTwips(start_pen[1], end_pen[1], a, b);
    switch (s) {
        .straight => |sd| switch (e) {
            .straight => |ed| {
                const ax = lerpTwips(start_pen[0] + sd.dx, end_pen[0] + ed.dx, a, b);
                const ay = lerpTwips(start_pen[1] + sd.dy, end_pen[1] + ed.dy, a, b);
                return .{ .straight = .{ .dx = ax - pen_x, .dy = ay - pen_y } };
            },
            // A straight edge against a curved one: the straight side is
            // read as a curve with its control point at the midpoint,
            // which is what Flash's own tweens assume.
            .curved => |ed| {
                const s_cx = start_pen[0] + @divTrunc(sd.dx, 2);
                const s_cy = start_pen[1] + @divTrunc(sd.dy, 2);
                const e_cx = end_pen[0] + ed.control_dx;
                const e_cy = end_pen[1] + ed.control_dy;
                const cx = lerpTwips(s_cx, e_cx, a, b);
                const cy = lerpTwips(s_cy, e_cy, a, b);
                const ax = lerpTwips(start_pen[0] + sd.dx, e_cx + ed.anchor_dx, a, b);
                const ay = lerpTwips(start_pen[1] + sd.dy, e_cy + ed.anchor_dy, a, b);
                return .{ .curved = .{
                    .control_dx = cx - pen_x,
                    .control_dy = cy - pen_y,
                    .anchor_dx = ax - cx,
                    .anchor_dy = ay - cy,
                } };
            },
            else => return s,
        },
        .curved => |sd| switch (e) {
            .curved => |ed| {
                const s_cx = start_pen[0] + sd.control_dx;
                const s_cy = start_pen[1] + sd.control_dy;
                const e_cx = end_pen[0] + ed.control_dx;
                const e_cy = end_pen[1] + ed.control_dy;
                const cx = lerpTwips(s_cx, e_cx, a, b);
                const cy = lerpTwips(s_cy, e_cy, a, b);
                const ax = lerpTwips(s_cx + sd.anchor_dx, e_cx + ed.anchor_dx, a, b);
                const ay = lerpTwips(s_cy + sd.anchor_dy, e_cy + ed.anchor_dy, a, b);
                return .{ .curved = .{
                    .control_dx = cx - pen_x,
                    .control_dy = cy - pen_y,
                    .anchor_dx = ax - cx,
                    .anchor_dy = ay - cy,
                } };
            },
            .straight => |ed| {
                const s_cx = start_pen[0] + sd.control_dx;
                const s_cy = start_pen[1] + sd.control_dy;
                const e_cx = end_pen[0] + @divTrunc(ed.dx, 2);
                const e_cy = end_pen[1] + @divTrunc(ed.dy, 2);
                const cx = lerpTwips(s_cx, e_cx, a, b);
                const cy = lerpTwips(s_cy, e_cy, a, b);
                const ax = lerpTwips(s_cx + sd.anchor_dx, end_pen[0] + ed.dx, a, b);
                const ay = lerpTwips(s_cy + sd.anchor_dy, end_pen[1] + ed.dy, a, b);
                return .{ .curved = .{
                    .control_dx = cx - pen_x,
                    .control_dy = cy - pen_y,
                    .anchor_dx = ax - cx,
                    .anchor_dy = ay - cy,
                } };
            },
            else => return s,
        },
        else => return s,
    }
}
