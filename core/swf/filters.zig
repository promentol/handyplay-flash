//! FILTERLIST (SWF8: DefineButton2 records, PlaceObject3).
//!
//! Two entry points. `skipList` walks the bytes without allocating, for
//! the structures that only need to get PAST a filter list; `parseList`
//! decodes it, for PlaceObject3, whose filters a script can read back
//! through `MovieClip.filters`.
//!
//! Units are the file's: `Fixed16` for lengths and for the angle (which
//! is in RADIANS), `Fixed8` for strength, RGBA for colour. Nothing is
//! converted here — `core/avm1/globals/filters.zig` owns the script-side
//! representation and does its own arithmetic.
//!
//! Reference: reference/ruffle/swf/src/read.rs `read_filter`, and SWF19
//! §Filters — whose BevelFilter colour order is WRONG (see below).

const std = @import("std");
const rdr = @import("reader.zig");

pub const Error = rdr.Error || std.mem.Allocator.Error || error{InvalidFilter};

/// One gradient stop of a gradient glow or bevel.
pub const GradientRecord = struct { color: u32, ratio: u8 };

pub const Filter = union(enum) {
    drop_shadow: DropShadow,
    blur: Blur,
    glow: Glow,
    bevel: Bevel,
    gradient_glow: Gradient,
    convolution: Convolution,
    color_matrix: ColorMatrix,
    gradient_bevel: Gradient,

    pub const DropShadow = struct {
        color: u32,
        blur_x: i32,
        blur_y: i32,
        angle: i32,
        distance: i32,
        strength: u16,
        flags: u8,
    };
    pub const Blur = struct { blur_x: i32, blur_y: i32, flags: u8 };
    pub const Glow = struct {
        color: u32,
        blur_x: i32,
        blur_y: i32,
        strength: u16,
        flags: u8,
    };
    pub const Bevel = struct {
        highlight_color: u32,
        shadow_color: u32,
        blur_x: i32,
        blur_y: i32,
        angle: i32,
        distance: i32,
        strength: u16,
        flags: u8,
    };
    pub const Gradient = struct {
        colors: []const GradientRecord,
        blur_x: i32,
        blur_y: i32,
        angle: i32,
        distance: i32,
        strength: u16,
        flags: u8,
    };
    pub const Convolution = struct {
        cols: u8,
        rows: u8,
        divisor: f32,
        bias: f32,
        matrix: []const f32,
        default_color: u32,
        flags: u8,
    };
    pub const ColorMatrix = struct { matrix: [20]f32 };
};

/// Shared bit positions. Blur is the odd one — its pass count is shifted
/// up by three, and it has no other flags.
pub const INNER_SHADOW: u8 = 1 << 7;
pub const KNOCKOUT: u8 = 1 << 6;
pub const COMPOSITE_SOURCE: u8 = 1 << 5;
/// Bevel and gradient only, and it steals a pass bit to fit.
pub const ON_TOP: u8 = 1 << 4;
pub const CONV_CLAMP: u8 = 1 << 1;
pub const CONV_PRESERVE_ALPHA: u8 = 1 << 0;

pub fn passesOf(flags: u8) u8 {
    return flags & 0b11111;
}

/// Bevel and gradient filters give a bit to `ON_TOP`, so their pass count
/// is four bits, not five.
pub fn bevelPassesOf(flags: u8) u8 {
    return flags & 0b1111;
}

pub fn blurPassesOf(flags: u8) u8 {
    return (flags >> 3) & 0b11111;
}

/// Skip one FILTERLIST (count byte + filters). Returns the filter count.
pub fn skipList(r: *rdr.Reader) Error!u8 {
    const n = try r.readU8();
    for (0..n) |_| try skipOne(r);
    return n;
}

fn skipOne(r: *rdr.Reader) Error!void {
    const id = try r.readU8();
    switch (id) {
        0 => try r.skip(23), // DropShadow: rgba + blurX/Y + angle + distance + strength + flags
        1 => try r.skip(9), // Blur: blurX/Y + flags(passes)
        2 => try r.skip(15), // Glow: rgba + blurX/Y + strength + flags
        3 => try r.skip(27), // Bevel: 2×rgba + blurX/Y + angle + distance + strength + flags
        4, 7 => { // GradientGlow / GradientBevel
            const num = try r.readU8();
            try r.skip(@as(usize, num) * 5 + 19); // n×rgba + n×ratio + geometry
        },
        5 => { // Convolution
            const mx = try r.readU8();
            const my = try r.readU8();
            try r.skip(8 + @as(usize, mx) * @as(usize, my) * 4 + 5); // divisor+bias + matrix + rgba + flags
        },
        6 => try r.skip(80), // ColorMatrix: 20×f32
        else => return Error.InvalidFilter,
    }
}

/// Decode a FILTERLIST. The slices come from `a`, which for a movie is
/// its arena — a placement's filters live as long as the movie does.
pub fn parseList(a: std.mem.Allocator, r: *rdr.Reader) Error![]const Filter {
    const n = try r.readU8();
    if (n == 0) return &.{};
    const out = try a.alloc(Filter, n);
    for (out) |*f| f.* = try parseOne(a, r);
    return out;
}

fn parseOne(a: std.mem.Allocator, r: *rdr.Reader) Error!Filter {
    return switch (try r.readU8()) {
        0 => .{ .drop_shadow = .{
            .color = try r.readU32(),
            .blur_x = try readFixed16(r),
            .blur_y = try readFixed16(r),
            .angle = try readFixed16(r),
            .distance = try readFixed16(r),
            .strength = try r.readU16(),
            .flags = try r.readU8(),
        } },
        1 => .{ .blur = .{
            .blur_x = try readFixed16(r),
            .blur_y = try readFixed16(r),
            .flags = try r.readU8(),
        } },
        2 => .{ .glow = .{
            .color = try r.readU32(),
            .blur_x = try readFixed16(r),
            .blur_y = try readFixed16(r),
            .strength = try r.readU16(),
            .flags = try r.readU8(),
        } },
        // SWF19 has the two colours the other way round. Flash writes
        // HIGHLIGHT first and reads it that way; the spec is simply wrong.
        3 => .{ .bevel = .{
            .highlight_color = try r.readU32(),
            .shadow_color = try r.readU32(),
            .blur_x = try readFixed16(r),
            .blur_y = try readFixed16(r),
            .angle = try readFixed16(r),
            .distance = try readFixed16(r),
            .strength = try r.readU16(),
            .flags = try r.readU8(),
        } },
        4 => .{ .gradient_glow = try parseGradient(a, r) },
        5 => .{ .convolution = try parseConvolution(a, r) },
        6 => blk: {
            var m: [20]f32 = undefined;
            for (&m) |*x| x.* = @bitCast(try r.readU32());
            break :blk .{ .color_matrix = .{ .matrix = m } };
        },
        7 => .{ .gradient_bevel = try parseGradient(a, r) },
        else => Error.InvalidFilter,
    };
}

/// All the colours come first and all the ratios after, not interleaved.
fn parseGradient(a: std.mem.Allocator, r: *rdr.Reader) Error!Filter.Gradient {
    const n = try r.readU8();
    const records = try a.alloc(GradientRecord, n);
    for (records) |*g| g.color = try r.readU32();
    for (records) |*g| g.ratio = try r.readU8();
    return .{
        .colors = records,
        .blur_x = try readFixed16(r),
        .blur_y = try readFixed16(r),
        .angle = try readFixed16(r),
        .distance = try readFixed16(r),
        .strength = try r.readU16(),
        .flags = try r.readU8(),
    };
}

fn parseConvolution(a: std.mem.Allocator, r: *rdr.Reader) Error!Filter.Convolution {
    const cols = try r.readU8();
    const rows = try r.readU8();
    const divisor: f32 = @bitCast(try r.readU32());
    const bias: f32 = @bitCast(try r.readU32());
    const matrix = try a.alloc(f32, @as(usize, cols) * @as(usize, rows));
    for (matrix) |*x| x.* = @bitCast(try r.readU32());
    return .{
        .cols = cols,
        .rows = rows,
        .divisor = divisor,
        .bias = bias,
        .matrix = matrix,
        .default_color = try r.readU32(),
        .flags = try r.readU8(),
    };
}

fn readFixed16(r: *rdr.Reader) Error!i32 {
    return @bitCast(try r.readU32());
}

// --- Tests -----------------------------------------------------------------

test "skip a mixed filter list" {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try b.append(ta, 3); // 3 filters
    try b.append(ta, 1); // blur
    try b.appendSlice(ta, &(.{0} ** 9));
    try b.append(ta, 4); // gradient glow, 2 colors
    try b.append(ta, 2);
    try b.appendSlice(ta, &(.{0} ** (2 * 5 + 19)));
    try b.append(ta, 6); // color matrix
    try b.appendSlice(ta, &(.{0} ** 80));
    try b.appendSlice(ta, &.{ 0xAA, 0xBB }); // trailing sentinel

    var r = rdr.Reader.init(b.items);
    const n = try skipList(&r);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqual(@as(u8, 0xAA), try r.readU8());
}

test "parsing and skipping consume exactly the same bytes" {
    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(ta);
    try b.append(ta, 2);
    try b.append(ta, 3); // bevel
    try b.appendSlice(ta, &(.{7} ** 27));
    try b.append(ta, 5); // convolution, 2x2
    try b.appendSlice(ta, &.{ 2, 2 });
    try b.appendSlice(ta, &(.{0} ** (8 + 16 + 5)));
    try b.append(ta, 0xAA);

    var skip_r = rdr.Reader.init(b.items);
    _ = try skipList(&skip_r);
    var parse_r = rdr.Reader.init(b.items);
    const list = try parseList(arena.allocator(), &parse_r);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u8, 0xAA), try parse_r.readU8());
    try std.testing.expectEqual(@as(u8, 0xAA), try skip_r.readU8());
    try std.testing.expectEqual(@as(usize, 4), list[1].convolution.matrix.len);
}

test "a bevel reads its highlight colour FIRST, against the spec" {
    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(ta);
    try b.append(ta, 1);
    try b.append(ta, 3);
    try b.appendSlice(ta, &.{ 0x11, 0x22, 0x33, 0x44 }); // highlight
    try b.appendSlice(ta, &.{ 0x55, 0x66, 0x77, 0x88 }); // shadow
    try b.appendSlice(ta, &(.{0} ** 19));

    var r = rdr.Reader.init(b.items);
    const list = try parseList(arena.allocator(), &r);
    try std.testing.expectEqual(@as(u32, 0x44332211), list[0].bevel.highlight_color);
    try std.testing.expectEqual(@as(u32, 0x88776655), list[0].bevel.shadow_color);
}
