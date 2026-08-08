//! Static text: a `DefineText` instance walked glyph by glyph.
//!
//! The tag is a list of RECORDS, each of which may override the font, the
//! colour, the size or the pen position — and each override STICKS until
//! the next one changes it. A record with no `x_offset` continues from
//! wherever the previous record's advances left the pen. That single rule
//! is most of what makes static text look right.
//!
//! The walk is shared: the renderer draws what it yields, and the hit test
//! inverts the same matrices. Reference:
//! reference/ruffle/core/src/display_object/text.rs:135-185.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const library = @import("library.zig");

const Matrix = swf.reader.Matrix;
const Color = swf.reader.Color;
const Font = swf.font_text.Font;
const Glyph = swf.font_text.Glyph;
const Text = swf.font_text.Text;

/// One glyph, positioned in the TEXT's own coordinate space (the tag's
/// `matrix` is applied by the caller, once, around the whole walk).
pub const Placed = struct {
    font: *const Font,
    glyph: *const Glyph,
    /// Index into the font's glyph table — the distill cache key.
    index: u32,
    /// `a`/`d` carry the size scale, `tx`/`ty` the pen position.
    matrix: Matrix,
    color: Color,
};

/// DefineFont3 stores glyph outlines at TWENTY TIMES the resolution of
/// DefineFont1/2 (SWF19 p.164). Getting this wrong is a silent 20× size
/// bug, so it lives in one place.
pub fn fontScale(font: *const Font) f32 {
    return if (font.version >= 3) 20480.0 else 1024.0;
}

/// Walks a `DefineText`'s records, yielding one `Placed` per drawable
/// glyph. Sticky state lives here so the renderer and the hit test cannot
/// disagree about it.
pub const Walker = struct {
    text: *const Text,
    lib: *const library.Library,

    record: usize = 0,
    glyph: usize = 0,
    // Sticky across records, exactly as the tag intends.
    font: ?*const Font = null,
    color: Color = 0xFF000000,
    scale: f32 = 0,
    pen_x: i32 = 0,
    pen_y: i32 = 0,
    /// Set when the current record names a font we do not have: its
    /// glyphs are skipped WITHOUT advancing the pen.
    skip_record: bool = false,

    pub fn init(text: *const Text, lib: *const library.Library) Walker {
        return .{ .text = text, .lib = lib };
    }

    pub fn next(self: *Walker) ?Placed {
        while (self.record < self.text.records.len) {
            const rec = &self.text.records[self.record];
            if (self.glyph == 0) self.beginRecord(rec);

            if (self.glyph < rec.glyphs.len) {
                const entry = rec.glyphs[self.glyph];
                self.glyph += 1;
                if (self.skip_record) continue;
                const font = self.font orelse continue;
                if (entry.index >= font.glyphs.len) {
                    // An out-of-range index draws nothing AND advances
                    // nothing — ruffle's advance sits inside the
                    // glyph-found branch.
                    continue;
                }
                const placed: Placed = .{
                    .font = font,
                    .glyph = &font.glyphs[entry.index],
                    .index = entry.index,
                    .matrix = .{
                        .a = self.scale,
                        .d = self.scale,
                        .tx = self.pen_x,
                        .ty = self.pen_y,
                    },
                    .color = self.color,
                };
                self.pen_x +%= entry.advance;
                return placed;
            }

            self.record += 1;
            self.glyph = 0;
        }
        return null;
    }

    /// Apply a record's overrides. Each one is optional and each STICKS.
    fn beginRecord(self: *Walker, rec: *const swf.font_text.TextRecord) void {
        if (rec.x_offset) |x| self.pen_x = x;
        if (rec.y_offset) |y| self.pen_y = y;
        if (rec.color) |c| self.color = c;
        if (rec.font_id) |id| {
            self.font = fontOf(self.lib, id);
            self.skip_record = self.font == null;
        }
        if (rec.height) |h| {
            if (self.font) |f| {
                self.scale = @as(f32, @floatFromInt(h)) / fontScale(f);
            }
        }
        // A record that names no font at all inherits the last one.
        if (rec.font_id == null) self.skip_record = self.font == null;
    }
};

fn fontOf(lib: *const library.Library, id: u16) ?*const Font {
    const ch = @constCast(lib).getConstPtr(id) orelse return null;
    return switch (ch.*) {
        .font => |*f| f,
        else => null,
    };
}

/// The text colour as a colour-transform MULTIPLIER over the all-white
/// glyph shapes — ruffle tints rather than repainting
/// (`ColorTransform::set_mult_color`: `Fixed8::from_f32(channel / 255)`,
/// i.e. truncation toward zero at 8 fractional bits).
pub fn colorAsMult(c: Color) swf.reader.ColorTransform {
    return .{
        .mult = .{
            channelMult(c & 0xFF),
            channelMult((c >> 8) & 0xFF),
            channelMult((c >> 16) & 0xFF),
            channelMult((c >> 24) & 0xFF),
        },
        .add = .{ 0, 0, 0, 0 },
    };
}

fn channelMult(v: u32) i16 {
    // Fixed8::from_f32 truncates, so 255 -> 256 and 128 -> 128.
    return @intFromFloat(@as(f32, @floatFromInt(v)) / 255.0 * 256.0);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "colour becomes an 8.8 multiplier, white stays identity" {
    try testing.expectEqual(@as(i16, 256), channelMult(255));
    try testing.expectEqual(@as(i16, 0), channelMult(0));
    try testing.expectEqual(@as(i16, 128), channelMult(128));
    const white = colorAsMult(0xFFFFFFFF);
    try testing.expect(white.isIdentity());
}

test "DefineFont3 glyphs are 20x" {
    var f3: Font = .{ .version = 3, .id = 1, .glyphs = &.{} };
    var f2: Font = .{ .version = 2, .id = 2, .glyphs = &.{} };
    try testing.expectEqual(@as(f32, 20480.0), fontScale(&f3));
    try testing.expectEqual(@as(f32, 1024.0), fontScale(&f2));
}
