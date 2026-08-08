//! DefineShape1-4 decoding: style arrays + edge/style-change records.
//! Decoded (the records are bit-packed — they can't be kept as raw slices),
//! but NOT interpreted: turning dual-edge records into closed paths is
//! render/shape_utils.zig's job (M2).
//!
//! Layout reference: reference/ruffle/swf/src/read.rs read_define_shape /
//! read_shape_styles / read_fill_style / read_line_style / read_shape_record
//! (+ SWF19 §DefineShape). Wild-SWF tolerances mirrored from ruffle:
//! 0-record gradients collapse to solid black; StyleChange records appear
//! in DefineShape1 despite the spec.

const std = @import("std");
const rdr = @import("reader.zig");

pub const Error = rdr.Error || std.mem.Allocator.Error || error{InvalidFillStyle};

pub const GradientSpread = enum(u2) { pad = 0, reflect = 1, repeat = 2, invalid = 3 };
pub const GradientInterpolation = enum(u2) { srgb = 0, linear_rgb = 1, invalid2 = 2, invalid3 = 3 };

pub const GradientRecord = struct {
    ratio: u8,
    color: rdr.Color,
};

pub const Gradient = struct {
    matrix: rdr.Matrix,
    spread: GradientSpread,
    interpolation: GradientInterpolation,
    records: []GradientRecord,
};

pub const FillStyle = union(enum) {
    solid: rdr.Color,
    linear_gradient: Gradient,
    radial_gradient: Gradient,
    focal_gradient: struct { gradient: Gradient, focal_point: f32 },
    bitmap: struct {
        id: u16,
        matrix: rdr.Matrix,
        is_smoothed: bool,
        is_repeating: bool,
        /// A LIVE `BitmapData` instead of a library character — set only
        /// by the script drawing API (`beginBitmapFill`), never by the
        /// parser. Opaque because `swf/` is the parser and must not know
        /// what a `BitmapData` is; `core/render/renderer.zig` casts it.
        live: ?*const anyopaque = null,
    },
};

pub const LineCap = enum(u2) { round = 0, none = 1, square = 2, invalid = 3 };
pub const LineJoin = enum(u2) { round = 0, bevel = 1, miter = 2, invalid = 3 };

pub const LineStyle = struct {
    /// Width in twips (0 = hairline: minimum 1px on screen).
    width: u16,
    /// LineStyle1 wraps its color as a solid fill; LineStyle2 (shape4) may
    /// carry any fill style.
    fill: FillStyle,
    // LineStyle2 extras (defaults model LineStyle1 behavior).
    start_cap: LineCap = .round,
    end_cap: LineCap = .round,
    join: LineJoin = .round,
    miter_limit: f32 = 0,
    no_h_scale: bool = false,
    no_v_scale: bool = false,
    no_close: bool = false,
    pixel_hinting: bool = false,
};

pub const ShapeStyles = struct {
    fills: []FillStyle,
    lines: []LineStyle,
};

pub const StyleChange = struct {
    /// Absolute move-to in twips (not a delta).
    move_to: ?struct { x: i32, y: i32 } = null,
    /// 1-based indices into the ACTIVE style arrays; 0 = none.
    fill_style_0: ?u32 = null,
    fill_style_1: ?u32 = null,
    line_style: ?u32 = null,
    /// Replaces the active style arrays (and their index bit widths).
    new_styles: ?ShapeStyles = null,
};

pub const ShapeRecord = union(enum) {
    style_change: StyleChange,
    /// Deltas in twips.
    straight: struct { dx: i32, dy: i32 },
    curved: struct { control_dx: i32, control_dy: i32, anchor_dx: i32, anchor_dy: i32 },
};

pub const Shape = struct {
    version: u8,
    id: u16,
    bounds: rdr.Rectangle,
    /// Shape4 only (== bounds otherwise).
    edge_bounds: rdr.Rectangle,
    /// Shape4 flag bits.
    uses_fill_winding_rule: bool = false,
    uses_non_scaling_strokes: bool = true,
    uses_scaling_strokes: bool = false,
    styles: ShapeStyles,
    records: []ShapeRecord,
};

pub const Context = struct {
    swf_version: u8,
    shape_version: u8,
};

/// Parse a DefineShape1-4 tag body. All lists are allocated from
/// `allocator` — callers use an arena (movie preload / swfdump) so there
/// is deliberately no deep deinit.
pub fn parse(allocator: std.mem.Allocator, body: []const u8, ctx: Context) Error!Shape {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const bounds = try r.readRectangle();
    var shape: Shape = .{
        .version = ctx.shape_version,
        .id = id,
        .bounds = bounds,
        .edge_bounds = bounds,
        .styles = undefined,
        .records = undefined,
    };
    if (ctx.shape_version >= 4) {
        shape.edge_bounds = try r.readRectangle();
        const flags = try r.readU8();
        shape.uses_fill_winding_rule = (flags & 0b100) != 0;
        shape.uses_non_scaling_strokes = (flags & 0b010) != 0;
        shape.uses_scaling_strokes = (flags & 0b001) != 0;
    }
    var bits = Bits{ .fill = 0, .line = 0 };
    shape.styles = try parseStyles(allocator, &r, ctx, &bits);
    shape.records = try parseRecords(allocator, &r, ctx, &bits);
    return shape;
}

/// Active fill/line index bit widths (public: font glyphs reuse the
/// record grammar with their own widths).
pub const Bits = struct { fill: u6, line: u6 };

fn parseStyles(
    allocator: std.mem.Allocator,
    r: *rdr.Reader,
    ctx: Context,
    bits: *Bits,
) Error!ShapeStyles {
    var fills: std.ArrayList(FillStyle) = .empty;
    const nf: usize = blk: {
        const n = try r.readU8();
        if (n == 0xFF and ctx.shape_version >= 2) break :blk try r.readU16();
        break :blk n;
    };
    for (0..nf) |_| try fills.append(allocator, try parseFillStyle(allocator, r, ctx));

    var lines: std.ArrayList(LineStyle) = .empty;
    const nl: usize = blk: {
        const n = try r.readU8();
        if (n == 0xFF and ctx.shape_version >= 2) break :blk try r.readU16();
        break :blk n;
    };
    for (0..nl) |_| try lines.append(allocator, try parseLineStyle(allocator, r, ctx));

    const nbits = try r.readU8();
    bits.fill = @intCast(nbits >> 4);
    bits.line = @intCast(nbits & 0x0F);
    return .{
        .fills = try fills.toOwnedSlice(allocator),
        .lines = try lines.toOwnedSlice(allocator),
    };
}

fn parseColor(r: *rdr.Reader, ctx: Context) rdr.Error!rdr.Color {
    return if (ctx.shape_version >= 3) r.readRgba() else r.readRgb();
}

fn parseGradient(allocator: std.mem.Allocator, r: *rdr.Reader, ctx: Context) Error!?Gradient {
    const matrix = try r.readMatrix();
    const flags = try r.readU8();
    const spread: GradientSpread = @enumFromInt(@as(u2, @intCast((flags >> 6) & 0b11)));
    const interpolation: GradientInterpolation = @enumFromInt(@as(u2, @intCast((flags >> 4) & 0b11)));
    const n: usize = flags & 0x0F;
    // Malformed 0-record gradients exist in the wild — caller substitutes
    // solid black (ruffle behavior).
    if (n == 0) return null;
    const records = try allocator.alloc(GradientRecord, n);
    for (records) |*rec| {
        rec.* = .{ .ratio = try r.readU8(), .color = try parseColor(r, ctx) };
    }
    return .{ .matrix = matrix, .spread = spread, .interpolation = interpolation, .records = records };
}

const BLACK: rdr.Color = 0xFF000000;

fn parseFillStyle(allocator: std.mem.Allocator, r: *rdr.Reader, ctx: Context) Error!FillStyle {
    const t = try r.readU8();
    return switch (t) {
        0x00 => .{ .solid = try parseColor(r, ctx) },
        0x10 => if (try parseGradient(allocator, r, ctx)) |g|
            .{ .linear_gradient = g }
        else
            .{ .solid = BLACK },
        0x12 => if (try parseGradient(allocator, r, ctx)) |g|
            .{ .radial_gradient = g }
        else
            .{ .solid = BLACK },
        0x13 => blk: {
            // SWF19 allows focal gradients only in SWF8+/DefineShape4, but
            // they occur (and play) in earlier content — accept always.
            const g = try parseGradient(allocator, r, ctx);
            const focal = try r.readFixed8();
            break :blk if (g) |grad|
                .{ .focal_gradient = .{ .gradient = grad, .focal_point = focal } }
            else
                .{ .solid = BLACK };
        },
        0x40, 0x41, 0x42, 0x43 => .{
            .bitmap = .{
                .id = try r.readU16(),
                .matrix = try r.readMatrix(),
                // Smoothing exists only in SWF8+; type bit 1 = non-smoothed.
                .is_smoothed = ctx.swf_version >= 8 and (t & 0b10) == 0,
                .is_repeating = (t & 0b01) == 0,
            },
        },
        else => Error.InvalidFillStyle,
    };
}

fn parseLineStyle(allocator: std.mem.Allocator, r: *rdr.Reader, ctx: Context) Error!LineStyle {
    const width = try r.readU16();
    if (ctx.shape_version < 4) {
        return .{ .width = width, .fill = .{ .solid = try parseColor(r, ctx) } };
    }
    // LineStyle2 (DefineShape4) — u16le flag layout per ruffle
    // LineStyleFlag (SWF19's bit-stream description maps to these bits).
    const flags = try r.readU16();
    const pixel_hinting = (flags & (1 << 0)) != 0;
    const no_v_scale = (flags & (1 << 1)) != 0;
    const no_h_scale = (flags & (1 << 2)) != 0;
    const has_fill = (flags & (1 << 3)) != 0;
    const join: LineJoin = @enumFromInt(@as(u2, @intCast((flags >> 4) & 0b11)));
    const start_cap: LineCap = @enumFromInt(@as(u2, @intCast((flags >> 6) & 0b11)));
    const end_cap: LineCap = @enumFromInt(@as(u2, @intCast((flags >> 8) & 0b11)));
    const no_close = (flags & (1 << 10)) != 0;
    const miter_limit: f32 = if (join == .miter) try r.readFixed8() else 0;
    const fill: FillStyle = if (has_fill)
        try parseFillStyle(allocator, r, ctx)
    else
        .{ .solid = try r.readRgba() };
    return .{
        .width = width,
        .fill = fill,
        .start_cap = start_cap,
        .end_cap = end_cap,
        .join = join,
        .miter_limit = miter_limit,
        .no_h_scale = no_h_scale,
        .no_v_scale = no_v_scale,
        .no_close = no_close,
        .pixel_hinting = pixel_hinting,
    };
}

/// Parse shape records until the end-of-shape marker. Public because font
/// glyphs (font_text.zig) reuse the record grammar with their own bit
/// widths and no styles.
pub fn parseRecords(
    allocator: std.mem.Allocator,
    r: *rdr.Reader,
    ctx: Context,
    bits: *Bits,
) Error![]ShapeRecord {
    var records: std.ArrayList(ShapeRecord) = .empty;
    while (true) {
        const is_edge = try r.readBit();
        if (is_edge) {
            const is_straight = try r.readBit();
            const n: u6 = @intCast((try r.readUb(4)) + 2);
            if (is_straight) {
                const is_general = try r.readBit();
                var dx: i32 = 0;
                var dy: i32 = 0;
                if (is_general) {
                    dx = try r.readSb(n);
                    dy = try r.readSb(n);
                } else if (try r.readBit()) {
                    dy = try r.readSb(n);
                } else {
                    dx = try r.readSb(n);
                }
                try records.append(allocator, .{ .straight = .{ .dx = dx, .dy = dy } });
            } else {
                try records.append(allocator, .{ .curved = .{
                    .control_dx = try r.readSb(n),
                    .control_dy = try r.readSb(n),
                    .anchor_dx = try r.readSb(n),
                    .anchor_dy = try r.readSb(n),
                } });
            }
            continue;
        }
        const flags = try r.readUb(5);
        if (flags == 0) break; // end of shape
        var sc: StyleChange = .{};
        if ((flags & 0b00001) != 0) {
            const n: u6 = @intCast(try r.readUb(5));
            sc.move_to = .{ .x = try r.readSb(n), .y = try r.readSb(n) };
        }
        if ((flags & 0b00010) != 0) sc.fill_style_0 = try r.readUb(bits.fill);
        if ((flags & 0b00100) != 0) sc.fill_style_1 = try r.readUb(bits.fill);
        if ((flags & 0b01000) != 0) sc.line_style = try r.readUb(bits.line);
        if ((flags & 0b10000) != 0) {
            // NewStyles: byte-aligned style arrays + fresh index bit widths.
            r.byteAlign();
            sc.new_styles = try parseStyles(allocator, r, ctx, bits);
        }
        try records.append(allocator, .{ .style_change = sc });
    }
    r.byteAlign();
    return records.toOwnedSlice(allocator);
}

// --- Tests -----------------------------------------------------------------

test "parse the ruffle DefineShape.swf fixture tag" {
    // reference/ruffle/swf/tests/swfs/DefineShape.swf carries one
    // DefineShape (a red 20×20px square). Parsed via the corpus in
    // tests/parse_corpus.sh; here a hand-built minimal shape: bounds
    // (0,0,200,200) twips, one solid red fill, records: StyleChange
    // (move 0,0 + fill1=1), 4 straight edges, end.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try body.appendSlice(ta, &.{ 7, 0 }); // id = 7
    try body.append(ta, 0x40); // rect nbits=8 → 5+32=37 bits
    try body.appendSlice(ta, &.{ 0b0_0110010, 0b0_0000000, 0b0_0110010, 0b00_00000_0 });
    // ^ hand-packed: xmin=0 xmax=200 ymin=0 ymax=200 in 8-bit fields:
    //   bits: 01000 00000000 11001000 00000000 11001000 padded — easier to
    //   just verify parse output below than to eyeball; values written via
    //   the known-good packer:
    body.items.len -= 5; // redo the rect with the packer
    // SB fields: +200 needs 9 bits (sign bit clear). 5+4·9 = 41 bits → 6 B.
    var rect_buf: [6]u8 = @splat(0);
    packBits(&rect_buf, &.{ .{ 9, 5 }, .{ 0, 9 }, .{ 200, 9 }, .{ 0, 9 }, .{ 200, 9 } });
    try body.appendSlice(ta, rect_buf[0..6]);
    // Styles: 1 fill (solid RGB red), 0 lines, nbits fill=1 line=0.
    try body.appendSlice(ta, &.{ 1, 0x00, 255, 0, 0, 0, 0x11 });
    // Records: StyleChange move(0,0)+fill1=1: flags 00101, mbits=0, fill1=1.
    // Then 4 straight edges (nbits stored 6 → 8 real): +200x, +200y, -200x,
    // -200y. End: 000000.
    var rec_buf: [32]u8 = @splat(0);
    // Signed 9-bit deltas (stored nbits 7 → 7+2 = 9 real bits).
    const neg200: u32 = @as(u32, @bitCast(@as(i32, -200))) & 0x1FF;
    packBits(&rec_buf, &.{
        .{ 0b00101, 6 }, // type=0, flags: fill1+move
        .{ 0, 5 }, // move nbits = 0 → x=0, y=0
        .{ 1, 1 }, // fill1 = 1 (fill_bits = 1)
        // straight edges: 1 1 nbits(4)=7 general(1)=1 dx dy
        .{ 0b11_0111_1, 7 },
        .{ 200, 9 },
        .{ 0, 9 },
        .{ 0b11_0111_1, 7 },
        .{ 0, 9 },
        .{ 200, 9 },
        .{ 0b11_0111_1, 7 },
        .{ neg200, 9 },
        .{ 0, 9 },
        .{ 0b11_0111_1, 7 },
        .{ 0, 9 },
        .{ neg200, 9 },
        .{ 0, 6 }, // end
    });
    try body.appendSlice(ta, &rec_buf);

    const s = try parse(a, body.items, .{ .swf_version = 6, .shape_version = 1 });
    try std.testing.expectEqual(@as(u16, 7), s.id);
    try std.testing.expectEqual(@as(i32, 200), s.bounds.xmax);
    try std.testing.expectEqual(@as(usize, 1), s.styles.fills.len);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), s.styles.fills[0].solid);
    try std.testing.expectEqual(@as(usize, 5), s.records.len);
    try std.testing.expectEqual(@as(u32, 1), s.records[0].style_change.fill_style_1.?);
    try std.testing.expectEqual(@as(i32, 200), s.records[1].straight.dx);
    try std.testing.expectEqual(@as(i32, 0), s.records[1].straight.dy);
    try std.testing.expectEqual(@as(i32, -200), s.records[4].straight.dy);
}

test "gradient fill with focal point and 0-record tolerance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Focal gradient: matrix identity (1 byte 0), flags spread=reflect(1)
    // interp=srgb num=2, 2 records (RGBA since v4), focal 0.5.
    const body = [_]u8{0x13} ++ [_]u8{0x00} ++ [_]u8{0b01_00_0010} ++
        [_]u8{ 0, 10, 20, 30, 255 } ++ [_]u8{ 255, 40, 50, 60, 128 } ++
        [_]u8{ 0x80, 0x00 };
    var r = rdr.Reader.init(&body);
    const f = try parseFillStyle(a, &r, .{ .swf_version = 8, .shape_version = 4 });
    try std.testing.expectEqual(GradientSpread.reflect, f.focal_gradient.gradient.spread);
    try std.testing.expectEqual(@as(usize, 2), f.focal_gradient.gradient.records.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f.focal_gradient.focal_point, 0.001);

    // 0-record gradient → solid black.
    const body2 = [_]u8{ 0x10, 0x00, 0x00 };
    var r2 = rdr.Reader.init(&body2);
    const f2 = try parseFillStyle(a, &r2, .{ .swf_version = 6, .shape_version = 3 });
    try std.testing.expectEqual(BLACK, f2.solid);
}

/// Test helper: MSB-first bit packer (same as reader.zig's).
fn packBits(buf: []u8, fields: []const struct { u32, u6 }) void {
    var bit: usize = 0;
    for (fields) |f| {
        var i: u6 = f[1];
        while (i > 0) {
            i -= 1;
            const b: u1 = @intCast((f[0] >> @as(u5, @intCast(i))) & 1);
            buf[bit / 8] |= @as(u8, b) << @intCast(7 - (bit % 8));
            bit += 1;
        }
    }
}
