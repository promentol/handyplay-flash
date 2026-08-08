//! What a `BitmapData` can do to its pixels.
//!
//! A leaf module: `std` plus `pixels.zig` and `data.zig`. The AVM1
//! argument handling lives in `core/avm1/globals/bitmap_data.zig`; only
//! the pixel work is here.
//!
//! The recurring rule is which FORM a value is in. Storage is
//! premultiplied, so blending and comparison happen there, but a colour
//! transform is defined on unmultiplied values and has to convert both
//! ways around itself. Getting that backwards produces results that are
//! right to within a rounding error, which the corpus notices.
//!
//! Reference: reference/ruffle/core/src/bitmap/operations.rs.

const std = @import("std");
const pixels = @import("pixels.zig");
const data_mod = @import("data.zig");

const Color = pixels.Color;
const BitmapData = data_mod.BitmapData;

/// A NEGATIVE width or height is not an empty rectangle: it names the
/// box its two corners span, so `Rectangle(10, 10, -3, -3)` fills 7..9 on
/// both axes. `PixelRegion.forRegionI32` is what normalises it.
pub fn fillRect(bd: *BitmapData, x: i32, y: i32, w: i32, h: i32, argb: u32) void {
    var r = PixelRegion.forRegionI32(x, y, w, h);
    r.clampTo(bd.width, bd.height);
    if (r.width() == 0 or r.height() == 0) return;
    const c = Color.fromArgb(argb).toPremultiplied(bd.transparency);
    var py = r.y_min;
    while (py < r.y_max) : (py += 1) {
        var px = r.x_min;
        while (px < r.x_max) : (px += 1) bd.set(px, py, c);
    }
}

/// Four-way flood fill. Replacing a colour with ITSELF is refused rather
/// than looping forever, and that refusal is the `false` return.
pub fn floodFill(gpa: std.mem.Allocator, bd: *BitmapData, x: i64, y: i64, argb: u32) !bool {
    if (!bd.inBounds(x, y)) return false;
    const expected = bd.get(x, y);
    const replace = Color.fromArgb(argb).toPremultiplied(bd.transparency);
    if (expected.toArgb() == replace.toArgb()) return false;

    var pending: std.ArrayList([2]i64) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, .{ x, y });
    while (pending.pop()) |p| {
        if (bd.get(p[0], p[1]).toArgb() != expected.toArgb()) continue;
        bd.set(p[0], p[1], replace);
        if (p[0] > 0) try pending.append(gpa, .{ p[0] - 1, p[1] });
        if (p[1] > 0) try pending.append(gpa, .{ p[0], p[1] - 1 });
        if (p[0] < @as(i64, bd.width) - 1) try pending.append(gpa, .{ p[0] + 1, p[1] });
        if (p[1] < @as(i64, bd.height) - 1) try pending.append(gpa, .{ p[0], p[1] + 1 });
    }
    return true;
}

pub const Channels = packed struct(u4) {
    red: bool = false,
    green: bool = false,
    blue: bool = false,
    alpha: bool = false,

    pub fn fromBits(v: u32) Channels {
        return .{
            .red = (v & 1) != 0,
            .green = (v & 2) != 0,
            .blue = (v & 4) != 0,
            .alpha = (v & 8) != 0,
        };
    }
};

/// `noise` is an exact-match test, so the ORDER of the draws matters as
/// much as the generator: red, green, blue, alpha, each only when its
/// channel is selected, and a skipped channel does NOT consume a value.
pub fn noise(bd: *BitmapData, seed: i32, low: u8, high: u8, ch: Channels, gray: bool) void {
    // A seed of zero or below is reflected rather than clamped.
    const true_seed: u32 = if (seed <= 0) @intCast(-@as(i64, seed) + 1) else @intCast(seed);
    var rng = pixels.LehmerRng.withSeed(true_seed);
    const t = bd.transparency;

    var y: i64 = 0;
    while (y < bd.height) : (y += 1) {
        var x: i64 = 0;
        while (x < bd.width) : (x += 1) {
            const c = if (gray) blk: {
                const g = rng.range(low, high);
                const a: u8 = if (t and ch.alpha) rng.range(low, high) else 255;
                break :blk Color.rgba(g, g, g, a);
            } else blk: {
                const r: u8 = if (ch.red) rng.range(low, high) else 0;
                const g: u8 = if (ch.green) rng.range(low, high) else 0;
                const b: u8 = if (ch.blue) rng.range(low, high) else 0;
                const a: u8 = if (t and ch.alpha) rng.range(low, high) else 255;
                break :blk Color.rgba(r, g, b, a);
            };
            bd.set(x, y, c.toPremultiplied(t));
        }
    }
}

/// An IN-PLACE copy, so the iteration direction has to avoid overwriting
/// a source before it is read: bottom-to-top when moving down, and
/// right-to-left when moving right along a single row.
pub fn scroll(bd: *BitmapData, dx: i32, dy: i32) void {
    const w: i64 = bd.width;
    const h: i64 = bd.height;
    if ((dx == 0 and dy == 0) or @abs(@as(i64, dx)) >= w or @abs(@as(i64, dy)) >= h) return;

    const reverse_y = dy > 0;
    const reverse_x = dy == 0 and dx > 0;
    const y_from: i64 = if (reverse_y) h - dy - 1 else -@as(i64, dy);
    const y_to: i64 = if (reverse_y) -1 else h;
    const y_step: i64 = if (reverse_y) -1 else 1;
    const x_from: i64 = if (reverse_x) w - dx - 1 else @max(-@as(i64, dx), 0);
    const x_to: i64 = if (reverse_x) -1 else @min(w, w - dx);
    const x_step: i64 = if (reverse_x) -1 else 1;

    var sy = y_from;
    while (sy != y_to) : (sy += y_step) {
        var sx = x_from;
        while (sx != x_to) : (sx += x_step) {
            bd.set(sx + dx, sy + dy, bd.get(sx, sy));
        }
    }
}

pub const ColorTransform = struct {
    /// 8.8 FIXED multipliers and i16 adds, exactly as a SWF carries them.
    /// Script hands over f64s and Flash snaps them to this grid before
    /// doing anything, so a multiplier of 1.3 really is 332/256 — using
    /// the f64 straight is visibly wrong across a gradient.
    mult: [4]i16 = .{ 256, 256, 256, 256 },
    add: [4]i16 = .{ 0, 0, 0, 0 },

    /// Truncating toward zero, which is what `Fixed8::from_f64` does.
    pub fn fromFloats(mult: [4]f64, add: [4]f64) ColorTransform {
        var out: ColorTransform = .{};
        inline for (0..4) |i| {
            out.mult[i] = fixed8(mult[i] * 256.0);
            out.add[i] = fixed8(add[i]);
        }
        return out;
    }

    pub fn isIdentity(self: ColorTransform) bool {
        for (self.mult) |m| if (m != 256) return false;
        for (self.add) |a| if (a != 0) return false;
        return true;
    }

    /// A transform that only RAISES alpha does nothing at all. It is a
    /// Flash bug and the corpus depends on it.
    fn isNoOp(self: ColorTransform) bool {
        return self.mult[0] == 256 and self.mult[1] == 256 and self.mult[2] == 256 and
            self.mult[3] >= 256 and
            self.add[0] == 0 and self.add[1] == 0 and self.add[2] == 0 and self.add[3] == 0;
    }

    /// A FULLY TRANSPARENT pixel is left exactly as it is — not even the
    /// additive terms reach it.
    pub fn apply(self: ColorTransform, c: Color) Color {
        if (c.a == 0) return c;
        return Color.rgba(
            chan(c.r, self.mult[0], self.add[0]),
            chan(c.g, self.mult[1], self.add[1]),
            chan(c.b, self.mult[2], self.add[2]),
            chan(c.a, self.mult[3], self.add[3]),
        );
    }
};

fn fixed8(n: f64) i16 {
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(n), -32768, 32767));
}

/// The multiply happens at 16-bit precision and only the FINAL value
/// saturates, which is what lets a huge multiplier and a huge negative
/// offset cancel into a sane colour.
fn chan(v: u8, mult: i16, add: i16) u8 {
    const n: i32 = (@as(i32, mult) * @as(i32, v)) >> 8;
    const sum = std.math.clamp(n +| @as(i32, add), -32768, 32767);
    return @intCast(std.math.clamp(sum, 0, 255));
}

/// Applied to UNMULTIPLIED values, so each pixel converts out and back.
pub fn colorTransform(bd: *BitmapData, x0_in: i64, y0_in: i64, x1_in: i64, y1_in: i64, ct: ColorTransform) void {
    if (ct.isNoOp()) return;
    const x0 = @min(x0_in, @as(i64, bd.width));
    const y0 = @min(y0_in, @as(i64, bd.height));
    const x1 = @min(x1_in, @as(i64, bd.width));
    const y1 = @min(y1_in, @as(i64, bd.height));
    if (x1 == 0 or y1 == 0 or x0 == x1 or y0 == y1) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const out = ct.apply(bd.get(x, y).toUnmultiplied());
            bd.set(x, y, out.toPremultiplied(bd.transparency));
        }
    }
}

/// The tightest box holding pixels that DO (or do not) match `color`
/// under `mask`. Nothing matching yields a zero-sized box.
///
/// The comparison happens in the PREMULTIPLIED colourspace, so the
/// wanted colour is multiplied first — and on an OPAQUE bitmap the alpha
/// byte is folded into the mask, because every stored alpha is 0xFF and
/// would otherwise never match what the caller asked for.
pub fn colorBoundsRect(bd: *const BitmapData, find: bool, mask_in: u32, color_in: u32) [4]i64 {
    var mask = mask_in;
    if (!bd.transparency) mask |= 0xFF00_0000;
    const color = Color.fromArgb(color_in).toPremultiplied(bd.transparency).toArgb();
    var min_x: i64 = bd.width;
    var min_y: i64 = bd.height;
    var max_x: i64 = -1;
    var max_y: i64 = -1;
    var y: i64 = 0;
    while (y < bd.height) : (y += 1) {
        var x: i64 = 0;
        while (x < bd.width) : (x += 1) {
            const c = bd.get(x, y).toArgb();
            const hit = (c & mask) == color;
            if (hit != find) continue;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
    }
    // A match at (0, 0) ALONE counts as no match at all — Flash's own
    // test is `max_x > 0 || max_y > 0`, not "did anything match".
    if (max_x <= 0 and max_y <= 0) return .{ 0, 0, 0, 0 };
    return .{ min_x, min_y, max_x - min_x + 1, max_y - min_y + 1 };
}

pub const CompareResult = union(enum) {
    /// The two are identical.
    same,
    /// They differ in SIZE, which is reported as a negative code rather
    /// than a bitmap.
    different_width,
    different_height,
    /// A difference bitmap, owned by the caller.
    diff: BitmapData,
};

/// A per-pixel difference: equal pixels come out transparent black, a
/// COLOUR difference is the wrapped per-channel subtraction at full
/// alpha, and an ALPHA-only difference is that subtraction in all four
/// channels.
pub fn compare(gpa: std.mem.Allocator, left: *const BitmapData, right: *const BitmapData) !CompareResult {
    if (left.width != right.width) return .different_width;
    if (left.height != right.height) return .different_height;

    var out = try BitmapData.init(gpa, left.width, left.height, true, 0);
    errdefer out.deinit(gpa);
    var different = false;
    for (left.data, right.data, 0..) |lp, rp, i| {
        const l = lp.toUnmultiplied();
        const r = rp.toUnmultiplied();
        if (l.toArgb() == r.toArgb()) {
            out.data[i] = Color.rgba(0, 0, 0, 0);
        } else if (l.withAlpha(0).toArgb() != r.withAlpha(0).toArgb()) {
            different = true;
            out.data[i] = Color.rgba(l.r -% r.r, l.g -% r.g, l.b -% r.b, 0xFF);
        } else {
            different = true;
            const a = l.a -% r.a;
            out.data[i] = Color.rgba(a, a, a, a);
        }
    }
    if (!different) {
        out.deinit(gpa);
        return .same;
    }
    return .{ .diff = out };
}

// --- Regions --------------------------------------------------------------

/// A half-open pixel box. Every source→destination operation works out
/// its two boxes with `clampWithIntersection`, which is the ONLY place
/// the clipping rules live: getting them right once is what keeps
/// `copyChannel`, `merge`, `threshold` and `pixelDissolve` agreeing about
/// what a partly off-bitmap source rectangle means.
///
/// Ruffle stores these unsigned and lets a negative coordinate saturate
/// to zero; the arithmetic below is signed and clamps at the end, which
/// is the same thing without the traps.
pub const PixelRegion = struct {
    x_min: i64 = 0,
    y_min: i64 = 0,
    x_max: i64 = 0,
    y_max: i64 = 0,

    pub fn wholeSize(w: u32, h: u32) PixelRegion {
        return .{ .x_max = w, .y_max = h };
    }

    /// A width or height may be negative, in which case the box is the
    /// one the two corners span rather than an empty one.
    pub fn forRegionI32(x: i32, y: i32, w: i32, h: i32) PixelRegion {
        const bx = @as(i64, x) + @as(i64, w);
        const by = @as(i64, y) + @as(i64, h);
        return .{
            .x_min = @max(@min(@as(i64, x), bx), 0),
            .y_min = @max(@min(@as(i64, y), by), 0),
            .x_max = @max(@max(@as(i64, x), bx), 0),
            .y_max = @max(@max(@as(i64, y), by), 0),
        };
    }

    pub fn clampTo(self: *PixelRegion, w: u32, h: u32) void {
        self.x_min = @min(self.x_min, w);
        self.y_min = @min(self.y_min, h);
        self.x_max = @min(self.x_max, w);
        self.y_max = @min(self.y_max, h);
    }

    pub fn width(self: PixelRegion) i64 {
        return self.x_max - self.x_min;
    }

    pub fn height(self: PixelRegion) i64 {
        return self.y_max - self.y_min;
    }

    /// Narrow BOTH boxes to the pixels valid in each, given that
    /// `self_point` on this one lines up with `other_point` on the other
    /// and the overlap is at most `size`. The two boxes need not share a
    /// coordinate plane — that is the whole point, since a copy names a
    /// source rectangle and a destination corner independently.
    pub fn clampWithIntersection(
        self: *PixelRegion,
        self_point: [2]i32,
        other_point: [2]i32,
        size: [2]i32,
        other: *PixelRegion,
    ) void {
        const r1 = translate(.{ self.x_min, self.y_min, self.x_max, self.y_max }, .{ -@as(i64, self_point[0]), -@as(i64, self_point[1]) });
        const r2 = translate(.{ other.x_min, other.y_min, other.x_max, other.y_max }, .{ -@as(i64, other_point[0]), -@as(i64, other_point[1]) });
        const inter = intersect(intersect(r1, r2), .{ 0, 0, size[0], size[1] });

        const empty = inter[0] == inter[2] or inter[1] == inter[3];
        const a = if (empty) [4]i64{ 0, 0, 0, 0 } else translate(inter, .{ self_point[0], self_point[1] });
        const b = if (empty) [4]i64{ 0, 0, 0, 0 } else translate(inter, .{ other_point[0], other_point[1] });

        self.* = fromClamped(a);
        other.* = fromClamped(b);
    }

    /// A negative edge becomes zero rather than wrapping — ruffle's
    /// `u32::try_from(..).unwrap_or(0)`, which can leave a max BELOW its
    /// min and so an empty box.
    fn fromClamped(r: [4]i64) PixelRegion {
        return .{
            .x_min = @max(r[0], 0),
            .y_min = @max(r[1], 0),
            .x_max = @max(r[2], 0),
            .y_max = @max(r[3], 0),
        };
    }

    fn translate(r: [4]i64, t: [2]i64) [4]i64 {
        return .{ r[0] + t[0], r[1] + t[1], r[2] + t[0], r[3] + t[1] };
    }

    fn intersect(a_in: [4]i64, b_in: [4]i64) [4]i64 {
        // Guard against a min above its max before intersecting.
        const a: [4]i64 = .{ @min(a_in[0], a_in[2]), @min(a_in[1], a_in[3]), a_in[2], a_in[3] };
        const b: [4]i64 = .{ @min(b_in[0], b_in[2]), @min(b_in[1], b_in[3]), b_in[2], b_in[3] };
        const x_max = @min(a[2], b[2]);
        const y_max = @min(a[3], b[3]);
        return .{
            @min(@max(a[0], b[0]), x_max),
            @min(@max(a[1], b[1]), y_max),
            x_max,
            y_max,
        };
    }
};

/// The pair of boxes a source→destination call operates on.
fn overlap(dst: *const BitmapData, src: *const BitmapData, dest_point: [2]i32, src_rect: [4]i32) struct { PixelRegion, PixelRegion } {
    var source = PixelRegion.wholeSize(src.width, src.height);
    var dest = PixelRegion.wholeSize(dst.width, dst.height);
    dest.clampWithIntersection(
        dest_point,
        .{ src_rect[0], src_rect[1] },
        .{ src_rect[2], src_rect[3] },
        &source,
    );
    return .{ dest, source };
}

// --- Source → destination ---------------------------------------------------

/// Copy ONE channel of the source over one channel of the destination.
/// The channel numbers are the `BitmapDataChannel` bits (1/2/4/8), and an
/// unrecognised source channel contributes zero rather than being an
/// error.
pub fn copyChannel(
    dst: *BitmapData,
    src: *const BitmapData,
    dest_point: [2]i32,
    src_rect: [4]i32,
    src_channel: i32,
    dst_channel: i32,
) void {
    const shift: ?u5 = switch (src_channel) {
        1 => 16,
        2 => 8,
        4 => 0,
        8 => 24,
        else => null,
    };
    const regions = overlap(dst, src, dest_point, src_rect);
    const dest = regions[0];
    const source = regions[1];
    if (dest.width() == 0 or dest.height() == 0) return;

    var y: i64 = 0;
    while (y < @min(dest.height(), source.height())) : (y += 1) {
        var x: i64 = 0;
        while (x < @min(dest.width(), source.width())) : (x += 1) {
            const original = dst.get(dest.x_min + x, dest.y_min + y).toUnmultiplied().toArgb();
            const source_color = src.get(source.x_min + x, source.y_min + y).toUnmultiplied().toArgb();
            const part: u32 = if (shift) |s| (source_color >> s) & 0xFF else 0;
            const result: u32 = switch (dst_channel) {
                1 => (original & 0xFF00_FFFF) | (part << 16),
                2 => (original & 0xFFFF_00FF) | (part << 8),
                4 => (original & 0xFFFF_FF00) | part,
                8 => (original & 0x00FF_FFFF) | (part << 24),
                else => original,
            };
            dst.set(dest.x_min + x, dest.y_min + y, Color.fromArgb(result).toPremultiplied(dst.transparency));
        }
    }
}

/// A per-channel LERP between destination and source, where a multiplier
/// of 256 is all source and 0 all destination. Unmultiplied throughout.
pub fn merge(
    dst: *BitmapData,
    src: *const BitmapData,
    dest_point: [2]i32,
    src_rect: [4]i32,
    mult: [4]i32,
) void {
    const regions = overlap(dst, src, dest_point, src_rect);
    const dest = regions[0];
    const source = regions[1];
    if (dest.width() == 0 or dest.height() == 0) return;

    var m: [4]u16 = undefined;
    inline for (0..4) |i| m[i] = @intCast(std.math.clamp(mult[i], 0, 256));

    var y: i64 = 0;
    while (y < dest.height()) : (y += 1) {
        var x: i64 = 0;
        while (x < dest.width()) : (x += 1) {
            const s = src.get(source.x_min + x, source.y_min + y).toUnmultiplied();
            const d = dst.get(dest.x_min + x, dest.y_min + y).toUnmultiplied();
            const out = Color.rgba(
                lerp(s.r, d.r, m[0]),
                lerp(s.g, d.g, m[1]),
                lerp(s.b, d.b, m[2]),
                lerp(s.a, d.a, m[3]),
            );
            dst.set(dest.x_min + x, dest.y_min + y, out.toPremultiplied(dst.transparency));
        }
    }
}

fn lerp(s: u8, d: u8, m: u16) u8 {
    return @intCast((@as(u16, s) * m + @as(u16, d) * (256 - m)) / 256);
}

pub const ThresholdOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    pub fn matches(self: ThresholdOp, value: u32, masked: u32) bool {
        return switch (self) {
            .eq => value == masked,
            .ne => value != masked,
            .lt => value < masked,
            .le => value <= masked,
            .gt => value > masked,
            .ge => value >= masked,
        };
    }
};

/// Every source pixel whose masked value passes the test is replaced with
/// `colour`; the rest are copied over only when `copy_source` is set.
/// Returns how many pixels PASSED — the copies are not counted.
///
/// Comparison is against the PREMULTIPLIED stored value, and the written
/// colour is premultiplied as though the bitmap were transparent even
/// when it is not. Both are Flash bugs and both are load-bearing.
pub fn threshold(
    dst: *BitmapData,
    src: *const BitmapData,
    src_rect: [4]i32,
    dest_point: [2]i32,
    op: ThresholdOp,
    value: u32,
    colour: u32,
    mask: u32,
    copy_source: bool,
) u32 {
    const masked_threshold = value & mask;
    const regions = overlap(dst, src, dest_point, src_rect);
    const dest = regions[0];
    const source = regions[1];
    if (dest.width() == 0 or dest.height() == 0) return 0;

    var modified: u32 = 0;
    var y: i64 = 0;
    while (y < dest.height()) : (y += 1) {
        var x: i64 = 0;
        while (x < dest.width()) : (x += 1) {
            const s = src.get(source.x_min + x, source.y_min + y);
            if (op.matches(s.toArgb() & mask, masked_threshold)) {
                modified += 1;
                dst.set(dest.x_min + x, dest.y_min + y, Color.fromArgb(colour).toPremultiplied(true));
            } else if (copy_source) {
                dst.set(dest.x_min + x, dest.y_min + y, s);
            }
        }
    }
    return modified;
}

// --- Hit testing -------------------------------------------------------------

/// A threshold of 0 behaves as 1 — a fully transparent pixel never hits.
pub fn hitTestPoint(bd: *const BitmapData, alpha_threshold: u8, x: i32, y: i32) bool {
    if (!bd.inBounds(x, y)) return false;
    return bd.get(x, y).a >= @max(alpha_threshold, 1);
}

/// Any pixel in the box at or above the threshold. Here 0 really is 0,
/// so an empty transparent bitmap DOES hit — unlike the point form.
pub fn hitTestRectangle(bd: *const BitmapData, alpha_threshold: u8, top_left: [2]i32, size: [2]i32) bool {
    var region = PixelRegion.forRegionI32(top_left[0], top_left[1], size[0], size[1]);
    region.clampTo(bd.width, bd.height);
    var y = region.y_min;
    while (y < region.y_max) : (y += 1) {
        var x = region.x_min;
        while (x < region.x_max) : (x += 1) {
            if (bd.get(x, y).a >= alpha_threshold) return true;
        }
    }
    return false;
}

/// Two bitmaps overlap where BOTH have a pixel at or above their own
/// threshold. The two points give where each bitmap's origin sits in a
/// shared space, so only their difference matters.
pub fn hitTestBitmapData(
    self_bd: *const BitmapData,
    self_point: [2]i32,
    self_threshold: u8,
    test_bd: *const BitmapData,
    test_point: [2]i32,
    test_threshold: u8,
) bool {
    const xd = @as(i64, test_point[0]) - @as(i64, self_point[0]);
    const yd = @as(i64, test_point[1]) - @as(i64, self_point[1]);
    const sw: i64 = self_bd.width;
    const sh: i64 = self_bd.height;
    const tw: i64 = test_bd.width;
    const th: i64 = test_bd.height;

    const sx0: i64 = if (xd < 0) 0 else xd;
    const tx0: i64 = if (xd < 0) -xd else 0;
    const w: i64 = @max(if (xd < 0) @min(sw, tw + xd) else @min(tw, sw - xd), 0);
    const sy0: i64 = if (yd < 0) 0 else yd;
    const ty0: i64 = if (yd < 0) -yd else 0;
    const h: i64 = @max(if (yd < 0) @min(sh, th + yd) else @min(th, sh - yd), 0);

    var x: i64 = 0;
    while (x < w) : (x += 1) {
        var y: i64 = 0;
        while (y < h) : (y += 1) {
            if (self_bd.get(sx0 + x, sy0 + y).a >= self_threshold and
                test_bd.get(tx0 + x, ty0 + y).a >= test_threshold) return true;
        }
    }
    return false;
}

// --- copyPixels --------------------------------------------------------------

/// Composite `source` over `self` in PREMULTIPLIED space — the standard
/// source-over, with the per-channel divide by 255 truncating.
fn blendOver(under: Color, over: Color) Color {
    const inv: u16 = 255 - @as(u16, over.a);
    return Color.rgba(
        over.r +% @as(u8, @intCast((@as(u16, under.r) * inv) / 255)),
        over.g +% @as(u8, @intCast((@as(u16, under.g) * inv) / 255)),
        over.b +% @as(u8, @intCast((@as(u16, under.b) * inv) / 255)),
        over.a +% @as(u8, @intCast((@as(u16, under.a) * inv) / 255)),
    );
}

/// The shared body of every rectangular copy. `blend` decides whether the
/// destination shows through; an OPAQUE source can never blend, so the
/// flag is dropped in that case rather than producing a slow no-op.
fn copyOnCpu(
    dst: *BitmapData,
    src: *const BitmapData,
    source_region: PixelRegion,
    dest_region: PixelRegion,
    blend_in: bool,
) void {
    const blend = blend_in and src.transparency;
    const same = src == @as(*const BitmapData, dst);
    // Copying an area of a bitmap onto ITSELF, unblended, is nothing.
    if (!blend and same and std.meta.eql(source_region, dest_region)) return;

    var y: i64 = 0;
    while (y < dest_region.height()) : (y += 1) {
        var x: i64 = 0;
        while (x < dest_region.width()) : (x += 1) {
            var c = src.get(source_region.x_min + x, source_region.y_min + y);
            if (blend) c = blendOver(dst.get(dest_region.x_min + x, dest_region.y_min + y), c);
            if (!dst.transparency) c = c.withAlpha(255);
            dst.set(dest_region.x_min + x, dest_region.y_min + y, c);
        }
    }
}

/// A rectangular copy. Note the blend rule: `merge_alpha` asks for it,
/// but so does copying a TRANSPARENT source onto an OPAQUE destination,
/// where there is nowhere for the alpha to go.
pub fn copyPixels(
    dst: *BitmapData,
    src: *const BitmapData,
    src_rect: [4]i32,
    dest_point: [2]i32,
    merge_alpha: bool,
) void {
    const regions = overlap(dst, src, dest_point, src_rect);
    if (regions[0].width() == 0 or regions[0].height() == 0) return;
    copyOnCpu(dst, src, regions[1], regions[0], (src.transparency and !dst.transparency) or merge_alpha);
}

/// The five-argument form: alpha comes from a THIRD bitmap rather than
/// from the source. Naming the source as the alpha bitmap at the same
/// offset is the plain copy again.
///
/// This one does not go through `clampWithIntersection` — it walks the
/// source rectangle as given and skips coordinates that fall outside any
/// of the three bitmaps, which is a different (and observably different)
/// clipping rule.
pub fn copyPixelsWithAlphaSource(
    dst: *BitmapData,
    src: *const BitmapData,
    src_rect: [4]i32,
    dest_point: [2]i32,
    alpha_bd: *const BitmapData,
    alpha_point: [2]i32,
    merge_alpha: bool,
) void {
    if (src == alpha_bd and alpha_point[0] == src_rect[0] and alpha_point[1] == src_rect[1]) {
        copyPixels(dst, src, src_rect, dest_point, merge_alpha);
        return;
    }

    var dest_region = PixelRegion.forRegionI32(dest_point[0], dest_point[1], src_rect[2], src_rect[3]);
    dest_region.clampTo(dst.width, dst.height);
    if (dest_region.width() == 0 or dest_region.height() == 0) return;

    var src_y: i64 = src_rect[1];
    while (src_y < @as(i64, src_rect[1]) + src_rect[3]) : (src_y += 1) {
        var src_x: i64 = src_rect[0];
        while (src_x < @as(i64, src_rect[0]) + src_rect[2]) : (src_x += 1) {
            const dest_x = src_x - src_rect[0] + dest_point[0];
            const dest_y = src_y - src_rect[1] + dest_point[1];
            if (!dst.inBounds(dest_x, dest_y)) continue;
            if (!src.inBounds(src_x, src_y)) continue;
            const source_color = src.get(src_x, src_y);

            const alpha_x = src_x - src_rect[0] + alpha_point[0];
            const alpha_y = src_y - src_rect[1] + alpha_point[1];
            if (alpha_bd.transparency and !alpha_bd.inBounds(alpha_x, alpha_y)) continue;

            const final_alpha: u8 = if (alpha_bd.transparency) blk: {
                const a = alpha_bd.get(alpha_x, alpha_y).a;
                break :blk if (src.transparency)
                    @intCast((@as(u16, a) * @as(u16, source_color.a)) >> 8)
                else
                    a;
            } else if (src.transparency) source_color.a else 255;

            // Un-premultiply by an actual divide here rather than through
            // the lookup table — Flash's own rounding, and the reason a
            // fully transparent source pixel comes out white.
            const af = @as(f64, @floatFromInt(source_color.a)) / 255.0;
            const intermediate = Color.rgba(
                satU8(@round(@as(f64, @floatFromInt(source_color.r)) / af)),
                satU8(@round(@as(f64, @floatFromInt(source_color.g)) / af)),
                satU8(@round(@as(f64, @floatFromInt(source_color.b)) / af)),
                source_color.a,
            ).withAlpha(final_alpha).toPremultiplied(true);

            const out = if (merge_alpha or !dst.transparency)
                blendOver(dst.get(dest_x, dest_y), intermediate)
            else
                intermediate;
            dst.set(dest_x, dest_y, out);
        }
    }
}

/// Rust's `f64 as u8`: saturating, and NaN is zero.
fn satU8(n: f64) u8 {
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(std.math.clamp(n, 0, 255));
}

/// Remap each channel through its own 256-entry table and SUM the four
/// results, so a table may carry a value in any channel — that is how one
/// array can tint a greyscale image.
pub fn paletteMap(
    dst: *BitmapData,
    src: *const BitmapData,
    src_rect: [4]i32,
    dest_point: [2]i32,
    tables: [4][256]u32,
) void {
    const regions = overlap(dst, src, dest_point, src_rect);
    const dest = regions[0];
    const source = regions[1];
    if (dest.width() == 0 or dest.height() == 0) return;

    var y: i64 = 0;
    while (y < dest.height()) : (y += 1) {
        var x: i64 = 0;
        while (x < dest.width()) : (x += 1) {
            const c = src.get(source.x_min + x, source.y_min + y).toUnmultiplied();
            const sum = tables[0][c.r] +% tables[1][c.g] +% tables[2][c.b] +% tables[3][c.a];
            // Premultiplied as though transparent even on an opaque
            // bitmap — the same Flash bug `threshold` has.
            dst.set(dest.x_min + x, dest.y_min + y, Color.fromArgb(sum).toPremultiplied(true));
        }
    }
}

// --- draw ---------------------------------------------------------------------

/// `BitmapData.draw` when the source is another BitmapData and the matrix
/// has no scale or skew. Flash takes a plain blit here rather than going
/// through the renderer, and the result differs from a real render — so
/// this is the correct answer, not a shortcut.
///
/// `clip` is in destination PIXELS and defaults to the whole target. Note
/// which point each region is anchored at: the clip's own corner on the
/// destination, and that corner MINUS the translation on the source.
pub fn drawBitmapData(
    dst: *BitmapData,
    src: *const BitmapData,
    tx: i32,
    ty: i32,
    clip: ?[4]i32,
    ct: ?ColorTransform,
) void {
    var source = PixelRegion.wholeSize(src.width, src.height);
    var dest = PixelRegion.wholeSize(dst.width, dst.height);
    const c = clip orelse [4]i32{ 0, 0, @intCast(dst.width), @intCast(dst.height) };
    dest.clampWithIntersection(
        .{ c[0], c[1] },
        .{ c[0] -% tx, c[1] -% ty },
        .{ c[2], c[3] },
        &source,
    );
    if (dest.width() == 0 or dest.height() == 0) return;

    if (ct) |transform| {
        var y: i64 = 0;
        while (y < dest.height()) : (y += 1) {
            var x: i64 = 0;
            while (x < dest.width()) : (x += 1) {
                const s = src.get(source.x_min + x, source.y_min + y).toUnmultiplied();
                var out = transform.apply(s).toPremultiplied(true);
                out = blendOver(dst.get(dest.x_min + x, dest.y_min + y), out);
                if (!dst.transparency) out = out.withAlpha(255);
                dst.set(dest.x_min + x, dest.y_min + y, out);
            }
        }
        return;
    }
    // An OPAQUE source has nothing to blend — every alpha is already 255.
    copyOnCpu(dst, src, source, dest, src.transparency);
}

// --- pixelDissolve -----------------------------------------------------------

/// Returns at least 2, and always even — a balanced Feistel network needs
/// to split its block into two equal halves.
fn feistelBlockSize(sequence_length: u32) u5 {
    var num = @max(sequence_length, 2) - 1;
    var bits: u5 = 0;
    while (num > 0) {
        num /= 2;
        bits += 1;
    }
    return bits + (bits % 2);
}

/// One round of a Feistel network: a bijection on `0 ..< 2^block`, used
/// to visit every pixel of the region in an order that looks random and
/// never repeats. The mixing function `n² + 1` is arbitrary — it is what
/// Flash's output was matched against, so it cannot be improved.
fn feistelIndex(raw: u32, block: u5) u32 {
    const half: u5 = block / 2;
    const h1 = raw >> half;
    const h2 = raw & ((@as(u32, 1) << half) - 1);
    const mixed = (h2 *% h2 +% 1) % (@as(u32, 1) << half);
    return ((h1 ^ mixed) << half) | h2;
}

/// Replace `num_pixels` pixels of the region, in Feistel order, either
/// with `fill_color` (when the source IS the target) or with the matching
/// source pixel. Returns the raw permutation index to carry into the next
/// call, which is how a script animates a dissolve frame by frame.
pub fn pixelDissolve(
    dst: *BitmapData,
    src: *const BitmapData,
    src_rect: [4]i32,
    dest_point: [2]i32,
    random_seed: i32,
    num_pixels: i32,
    fill_color: u32,
) i32 {
    const src_w = @max(src_rect[2], 0);
    const src_h = @max(src_rect[3], 0);
    if (src_w == 0 or src_h == 0) return 0;

    const regions = overlap(dst, src, dest_point, .{ src_rect[0], src_rect[1], src_w, src_h });
    const dest = regions[0];
    const source = regions[1];
    if (dest.width() == 0 or dest.height() == 0) return 0;

    const same = src == @as(*const BitmapData, dst);
    const total: u32 = @intCast(dest.width() * dest.height());
    const count = @min(num_pixels, @as(i32, @intCast(@min(total, @as(u32, std.math.maxInt(i32))))));

    // The pixel at the region's own origin is ALWAYS written, before the
    // permutation starts and outside the count.
    writeDissolved(dst, src, same, fill_color, 0, dest, source);

    const block = feistelBlockSize(total);
    const permutation_length = @as(u32, 1) << block;
    var raw: u32 = @as(u32, @bitCast(@rem(random_seed, @as(i32, @bitCast(permutation_length)))));

    var n: i32 = 0;
    while (n < count) : (n += 1) {
        var index: u32 = 0;
        var guard: u32 = 0;
        // Index 0 is already written, and the permutation covers a power
        // of two that may overshoot the region — both are skipped.
        while ((index == 0 or index >= total) and total != 1) {
            raw = (raw +% 1) % permutation_length;
            index = feistelIndex(raw, block);
            guard += 1;
            if (guard > permutation_length + 2) break;
        }
        writeDissolved(dst, src, same, fill_color, index, dest, source);
    }
    return @bitCast(raw);
}

fn writeDissolved(
    dst: *BitmapData,
    src: *const BitmapData,
    same: bool,
    fill_color: u32,
    index: u32,
    dest: PixelRegion,
    source: PixelRegion,
) void {
    const bx = @as(i64, index % @as(u32, @intCast(dest.width())));
    const by = @as(i64, index / @as(u32, @intCast(dest.width())));
    const c = if (same)
        Color.fromArgb(fill_color).toPremultiplied(dst.transparency)
    else
        src.get(source.x_min + bx, source.y_min + by);
    dst.set(dest.x_min + bx, dest.y_min + by, c);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "fillRect clips to the bitmap and drops an empty region" {
    var b = try BitmapData.init(testing.allocator, 4, 4, true, 0xFF000000);
    defer b.deinit(testing.allocator);
    fillRect(&b, 2, 2, 100, 100, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), b.getPixel32(3, 3));
    try testing.expectEqual(@as(u32, 0xFF000000), b.getPixel32(1, 1));
    fillRect(&b, 10, 10, 4, 4, 0xFF00FF00);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), b.getPixel32(3, 3));
}

test "a negative size names the box between the two corners" {
    var b = try BitmapData.init(testing.allocator, 4, 4, true, 0xFF000000);
    defer b.deinit(testing.allocator);
    fillRect(&b, 4, 4, -2, -2, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), b.getPixel32(3, 3));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), b.getPixel32(2, 2));
    try testing.expectEqual(@as(u32, 0xFF000000), b.getPixel32(1, 1));
}

test "flood fill refuses to replace a colour with itself" {
    var b = try BitmapData.init(testing.allocator, 3, 3, true, 0xFF112233);
    defer b.deinit(testing.allocator);
    try testing.expect(!try floodFill(testing.allocator, &b, 0, 0, 0xFF112233));
    try testing.expect(try floodFill(testing.allocator, &b, 0, 0, 0xFF445566));
    try testing.expectEqual(@as(u32, 0xFF445566), b.getPixel32(2, 2));
}

test "a colour transform that only raises alpha does nothing" {
    var b = try BitmapData.init(testing.allocator, 1, 1, true, 0x80112233);
    defer b.deinit(testing.allocator);
    colorTransform(&b, 0, 0, 1, 1, .{ .mult = .{ 256, 256, 256, 512 } });
    try testing.expectEqual(@as(u32, 0x80), b.getPixel32(0, 0) >> 24);
}

test "scroll moves pixels without eating its own source" {
    var b = try BitmapData.init(testing.allocator, 3, 1, true, 0);
    defer b.deinit(testing.allocator);
    b.setPixel32(0, 0, 0xFF0000FF);
    scroll(&b, 1, 0);
    try testing.expectEqual(@as(u32, 0xFF0000FF), b.getPixel32(1, 0));
}

test "compare reports sameness rather than an empty bitmap" {
    var a = try BitmapData.init(testing.allocator, 2, 2, true, 0xFF112233);
    defer a.deinit(testing.allocator);
    var c = try BitmapData.init(testing.allocator, 2, 2, true, 0xFF112233);
    defer c.deinit(testing.allocator);
    try testing.expect(try compare(testing.allocator, &a, &c) == .same);
    c.setPixel32(0, 0, 0xFF000000);
    var r = try compare(testing.allocator, &a, &c);
    try testing.expect(r == .diff);
    r.diff.deinit(testing.allocator);
}
