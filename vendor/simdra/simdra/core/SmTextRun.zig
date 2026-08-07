//! SmTextRun — pre-shaped sequence of `(glyph_index, dx, dy)` triples for a
//! text run. Mirrors Skia's `SkTextBlob` in spirit: shaping output is
//! decoupled from rendering so the next round of text features (kerning,
//! sub-pixel positioning, bidi, letter/word spacing) plug into shaping
//! without touching the rendering loop in `SmCanvas.drawTextRun`.
//!
//! v1 shaping is trivial — UTF-8 decode + horizontal advance accumulation.
//! Replacement-on-error: invalid UTF-8 sequences emit U+FFFD via
//! `glyphIndexFor` and continue. The type slot is the future-proof surface;
//! the body is intentionally simple.

const std = @import("std");
const SmFont = @import("SmFont.zig");
const SmList = @import("../utils/SmList.zig").SmList;

const SmTextRun = @This();

pub const Glyph = struct {
    /// Font glyph index (return of `SmFont.glyphIndexFor` for the codepoint).
    index: i32,
    /// Pen offset from the run's start, in pixels at the font's configured size.
    dx: f64,
    /// Vertical pen offset; 0 in v1, reserved for sub-pixel y / vertical text.
    dy: f64,
};

glyphs: SmList(Glyph) = .{},
allocator: std.mem.Allocator = std.heap.page_allocator,

pub fn deinit(self: *SmTextRun) void {
    self.glyphs.deinit(self.allocator);
}

/// shape(allocator, text_utf8, font) — UTF-8 decode + advance-width
/// accumulation, no kerning, no letter/word spacing. Convenience wrapper
/// around `shapeWithSpacing` for the zero-spacing path.
pub fn shape(allocator: std.mem.Allocator, text_utf8: []const u8, font: *const SmFont) std.mem.Allocator.Error!SmTextRun {
    return shapeWithSpacing(allocator, text_utf8, font, 0, 0, false);
}

/// shapeWithSpacing — shape with CSS letter-spacing / word-spacing
/// applied after every glyph (and word-spacing additionally after each
/// U+0020), plus stb_truetype kerning between successive codepoints when
/// `kerning_on` is true. Pen offsets stored on each Glyph reflect the
/// post-spacing/post-kerning positions, so the rendering loop in
/// `SmCanvas.drawTextRun` doesn't need to know about spacing.
pub fn shapeWithSpacing(
    allocator: std.mem.Allocator,
    text_utf8: []const u8,
    font: *const SmFont,
    letter_spacing_px: f64,
    word_spacing_px: f64,
    kerning_on: bool,
) std.mem.Allocator.Error!SmTextRun {
    var run: SmTextRun = .{ .allocator = allocator };
    errdefer run.deinit();

    var dx: f64 = 0;
    var prev_cp: u32 = 0;
    var i: usize = 0;
    while (i < text_utf8.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text_utf8[i]) catch 1;
        const end = @min(i + cp_len, text_utf8.len);
        const cp: u32 = std.unicode.utf8Decode(text_utf8[i..end]) catch 0xFFFD;
        i = end;

        if (kerning_on and prev_cp != 0) {
            dx += font.kernAdvance(prev_cp, cp);
        }

        const idx = font.glyphIndexFor(cp);
        try run.glyphs.append(allocator, .{ .index = idx, .dx = dx, .dy = 0 });
        dx += font.glyphAdvanceWidth(idx);
        dx += letter_spacing_px;
        if (cp == 0x20) dx += word_spacing_px;
        prev_cp = cp;
    }
    return run;
}
