//! Font metrics and glyph iteration — the primitive every text
//! measurement, layout and draw runs on.
//!
//! Wraps the already-parsed `swf.font_text.Font` with the three things the
//! tag does not give directly: a code → glyph index map, a kerning lookup
//! keyed by the code PAIR, and `evaluate`, which walks a string glyph by
//! glyph handing out a transform and an advance.
//!
//! Two numbers matter more than the rest:
//!
//!   - **scale is 20480 for DefineFont3 and 1024 otherwise.** Font3
//!     outlines are authored twenty times larger; miss it and every glyph
//!     is 20× too big.
//!   - **the font's own leading is IGNORED.** Line spacing comes from
//!     `TextFormat.leading` alone (ruffle html/layout.rs:253).
//!
//! `evaluate` calls back for EVERY character, including the ones the font
//! has no glyph for — with a zero advance, so string indices stay aligned
//! with what the caller is building.
//!
//! Reference: reference/ruffle/core/src/font.rs (`evaluate`, `measure`,
//! `FontMetrics`).

const std = @import("std");
const swf = @import("../swf/swf.zig");
const library = @import("library.zig");

const SwfFont = swf.font_text.Font;
const Glyph = swf.font_text.Glyph;
const Matrix = swf.reader.Matrix;

/// The EM-square denominator. DefineFont3 authors its outlines 20× larger
/// than DefineFont1/2 and reports the same nominal size.
pub fn scaleOf(font: *const SwfFont) f32 {
    return if (font.version >= 3) 20480.0 else 1024.0;
}

/// One character placed on a line.
pub const Placed = struct {
    /// Index into the string that produced it — stable even for the
    /// characters that had no glyph.
    index: usize,
    /// Null when the font has no glyph for this character.
    glyph: ?*const Glyph,
    /// Pen position at the START of this glyph, relative to the line.
    x: i32,
    /// How far the pen moves after it; zero for a missing glyph.
    advance: i32,
    /// EM units → twips at this size.
    scale: f32,
};

pub const Params = struct {
    /// Font size in TWIPS.
    height: i32,
    letter_spacing: i32 = 0,
    kerning: bool = false,
};

/// A resolved face. `null` inside stands for a face that did not resolve —
/// a non-embedded ("device") font, which under the conformance harness is
/// every face the movie did not embed. It lays out nothing and measures
/// zero, which is exactly what Flash does with no font to fall back on.
pub const Font = struct {
    swf_font: ?*const SwfFont,

    pub const empty: Font = .{ .swf_font = null };

    pub fn scale(self: Font) f32 {
        const f = self.swf_font orelse return 1024.0;
        return scaleOf(f);
    }

    /// EM-square ascent, or 0 without layout data. Flash reports a
    /// fontless field as zero-tall, not as some default.
    pub fn ascentEm(self: Font) i32 {
        const f = self.swf_font orelse return 0;
        const l = f.layout orelse return 0;
        return l.ascent;
    }

    pub fn descentEm(self: Font) i32 {
        const f = self.swf_font orelse return 0;
        const l = f.layout orelse return 0;
        return l.descent;
    }

    /// Baseline offset from the top of the line, in twips, at `height`.
    pub fn ascent(self: Font, height: i32) i32 {
        return scaled(self.ascentEm(), height, self.scale());
    }

    pub fn descent(self: Font, height: i32) i32 {
        return scaled(self.descentEm(), height, self.scale());
    }

    pub fn hasKerning(self: Font) bool {
        const f = self.swf_font orelse return false;
        const l = f.layout orelse return false;
        return l.kerning.len > 0;
    }

    pub fn glyphFor(self: Font, code: u16) ?*const Glyph {
        const f = self.swf_font orelse return null;
        for (f.glyphs) |*g| {
            if (g.code == code) return g;
        }
        return null;
    }

    pub fn glyphIndexFor(self: Font, code: u16) ?u32 {
        const f = self.swf_font orelse return null;
        for (f.glyphs, 0..) |*g, i| {
            if (g.code == code) return @intCast(i);
        }
        return null;
    }

    pub fn kerning(self: Font, left: u16, right: u16) i32 {
        const f = self.swf_font orelse return 0;
        const l = f.layout orelse return 0;
        for (l.kerning) |k| {
            if (k.left_code == left and k.right_code == right) return k.adjustment;
        }
        return 0;
    }

    /// Walk `text`, handing each character to `ctx.glyph(...)`. Returns
    /// the total advance.
    ///
    /// `ctx` is any struct with a `glyph(self, Placed) !void` method, so
    /// measurement and drawing share one loop.
    pub fn evaluate(self: Font, text: []const u16, params: Params, ctx: anytype) !i32 {
        const sc = self.scale();
        const kern_on = self.hasKerning() and params.kerning;
        var x: i32 = 0;
        for (text, 0..) |c, i| {
            const g = self.glyphFor(c);
            if (g == null) {
                // A missing character still gets a callback, with no
                // advance, so the caller's per-character bookkeeping does
                // not drift out of step with the string.
                try ctx.glyph(Placed{ .index = i, .glyph = null, .x = x, .advance = 0, .scale = 0 });
                continue;
            }
            var advance: i32 = g.?.advance;
            if (kern_on and i + 1 < text.len) advance += self.kerning(c, text[i + 1]);
            const twips = scaled(advance, params.height, sc) + params.letter_spacing;
            try ctx.glyph(Placed{
                .index = i,
                .glyph = g,
                .x = x,
                .advance = twips,
                .scale = @as(f32, @floatFromInt(params.height)) / sc,
            });
            x += twips;
        }
        return x;
    }

    /// The width of `text` in twips. The gutter is NOT included — callers
    /// that report `textWidth` add it themselves.
    pub fn measure(self: Font, text: []const u16, params: Params) i32 {
        var m: Measurer = .{};
        _ = self.evaluate(text, params, &m) catch return m.width;
        return m.width;
    }
};

/// `x + advance` maximised rather than summed: ruffle measures that way,
/// and it is the difference that makes a trailing zero-advance glyph not
/// shorten the line.
const Measurer = struct {
    width: i32 = 0,
    fn glyph(self: *Measurer, p: Placed) !void {
        self.width = @max(self.width, p.x + p.advance);
    }
};

fn scaled(em: i32, height: i32, scale: f32) i32 {
    const s = @as(f32, @floatFromInt(height)) / scale;
    return @intFromFloat(@as(f32, @floatFromInt(em)) * s);
}

/// Resolve a face the way a text field does: by NAME, with the style pair
/// as a tiebreak, and only among EMBEDDED fonts. `embedded` false means
/// the field asked for a device font, which never resolves here.
pub fn resolve(lib: *const library.Library, name: []const u16, bold: bool, italic: bool, embedded: bool) Font {
    if (!embedded) return .empty;
    if (name.len == 0) return .empty;
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return .empty;
    for (name, 0..) |c, i| buf[i] = if (c < 128) @intCast(c) else '?';
    return .{ .swf_font = lib.fontByName(buf[0..name.len], bold, italic) };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "DefineFont3 outlines are twenty times larger" {
    var f3: SwfFont = .{ .version = 3, .id = 1, .glyphs = &.{} };
    var f2: SwfFont = .{ .version = 2, .id = 2, .glyphs = &.{} };
    try testing.expectEqual(@as(f32, 20480.0), scaleOf(&f3));
    try testing.expectEqual(@as(f32, 1024.0), scaleOf(&f2));
}

test "an unresolved face measures nothing" {
    const f: Font = .empty;
    try testing.expectEqual(@as(i32, 0), f.measure(&[_]u16{ 'h', 'i' }, .{ .height = 240 }));
    try testing.expectEqual(@as(i32, 0), f.ascent(240));
}
