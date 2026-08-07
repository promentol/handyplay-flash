//! SmFont — TrueType / OpenType typeface bound to a fixed pixel size.
//! Mirrors Skia's `SkTypeface` + `SkFont` collapsed into one type (the
//! HTML5 surface only needs typeface + size in lockstep, no advantage in
//! splitting today). Backed by stb_truetype.
//!
//! Memory: SmFont owns a copy of the source font bytes (stbtt_fontinfo
//! holds pointers into them) plus a heap-allocated stbtt_fontinfo and a
//! scratch alpha buffer reused by `rasterizeGlyph`. All freed via
//! `release(self)`.
//!
//! The C `stbtt_fontinfo` is held via `*anyopaque` so zigar's type scanner
//! never has to walk its layout — same trick we use for hidden internals.
//! Cast back to `*c.stbtt_fontinfo` at every call site; see helper below.

const std = @import("std");

const c = @cImport({
    @cInclude("simdra/utils/stb_truetype.h");
});

const SmFont = @This();

pub const InitError = error{InvalidFont} || std.mem.Allocator.Error;

pub const Metrics = struct {
    ascent: f64,
    descent: f64,
    lineGap: f64,
    sizePx: f64,
};

pub const GlyphBitmap = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    offsetX: i32,
    offsetY: i32,
    advanceX: f64,
};

allocator: std.mem.Allocator,
font_bytes: []u8,
info_handle: *anyopaque,
size_px: f64,
scale: f64,
last_glyph_pixels: ?[]u8 = null,
/// Faux-bold flag — thickens rasterized glyphs by 1 px horizontally
/// (alpha OR with the left neighbour). Set when face matching picks a
/// regular-weight face for a target weight ≥ 600. Advance is unchanged
/// (matches Skia / node-canvas behavior; the next glyph just overlaps a
/// pixel).
synth_bold: bool = false,
/// Faux-italic flag — applied at draw time in `SmCanvas.drawTextRun`,
/// not in `rasterizeGlyph`. Each glyph row is shifted by
/// `tan(12°) * (distance_above_baseline)` so above-baseline rows lean
/// right, below-baseline rows lean left. Doesn't affect advance.
synth_italic: bool = false,

inline fn info(self: *const SmFont) *c.stbtt_fontinfo {
    return @ptrCast(@alignCast(self.info_handle));
}

/// fromBytes — JS-binding factory using `page_allocator`. Owns a copy of
/// `ttf_bytes`, inits the stb font info, and pre-computes the scale for
/// `size_px`. Errors if size_px <= 0 or stb can't parse the font.
pub fn fromBytes(ttf_bytes: []const u8, size_px: f64) InitError!SmFont {
    return fromBytesWithAllocator(std.heap.page_allocator, ttf_bytes, size_px);
}

/// fromBytesWithAllocator(allocator, ttf_bytes, size_px) — pure-Zig variant
/// for tests / explicit allocator threading.
pub fn fromBytesWithAllocator(allocator: std.mem.Allocator, ttf_bytes: []const u8, size_px: f64) InitError!SmFont {
    if (!(size_px > 0)) return error.InvalidFont;
    if (ttf_bytes.len == 0) return error.InvalidFont;

    const owned = try allocator.alloc(u8, ttf_bytes.len);
    errdefer allocator.free(owned);
    @memcpy(owned, ttf_bytes);

    const fi = try allocator.create(c.stbtt_fontinfo);
    errdefer allocator.destroy(fi);

    const offset = c.stbtt_GetFontOffsetForIndex(owned.ptr, 0);
    if (offset < 0) return error.InvalidFont;
    if (c.stbtt_InitFont(fi, owned.ptr, offset) == 0) return error.InvalidFont;

    const scale: f64 = @floatCast(c.stbtt_ScaleForPixelHeight(fi, @floatCast(size_px)));

    return .{
        .allocator = allocator,
        .font_bytes = owned,
        .info_handle = fi,
        .size_px = size_px,
        .scale = scale,
    };
}

/// setSynth(bold, italic) — toggle faux-bold and faux-italic on this
/// font instance. Called from JS-side face matching when the picked
/// registered face doesn't match the requested weight/style and we need
/// to synthesise the missing styling. No-op for already-correct faces.
pub fn setSynth(self: *SmFont, bold: bool, italic: bool) void {
    self.synth_bold = bold;
    self.synth_italic = italic;
}

/// release — free font bytes, the stbtt_fontinfo allocation, and any
/// cached glyph scratch. Called from JS via FinalizationRegistry.
pub fn release(self: *SmFont) void {
    if (self.last_glyph_pixels) |p| self.allocator.free(p);
    self.last_glyph_pixels = null;
    const fi: *c.stbtt_fontinfo = @ptrCast(@alignCast(self.info_handle));
    self.allocator.destroy(fi);
    self.allocator.free(self.font_bytes);
    self.font_bytes = &.{};
}

/// getMetrics — scaled ascent / descent / lineGap (CSS pixel units, sign
/// per stb: ascent positive, descent negative). Drives textBaseline.
pub fn getMetrics(self: *const SmFont) Metrics {
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(self.info(), &ascent, &descent, &line_gap);
    return .{
        .ascent = @as(f64, @floatFromInt(ascent)) * self.scale,
        .descent = @as(f64, @floatFromInt(descent)) * self.scale,
        .lineGap = @as(f64, @floatFromInt(line_gap)) * self.scale,
        .sizePx = self.size_px,
    };
}

pub fn glyphIndexFor(self: *const SmFont, codepoint: u32) i32 {
    return c.stbtt_FindGlyphIndex(self.info(), @intCast(codepoint));
}

pub fn glyphAdvanceWidth(self: *const SmFont, glyph: i32) f64 {
    var adv: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetGlyphHMetrics(self.info(), glyph, &adv, &lsb);
    return @as(f64, @floatFromInt(adv)) * self.scale;
}

/// measureWidth — plain sum of scaled advance widths. No kerning, no
/// letter/word spacing. Backs the simple shaping path used when the
/// canvas state's spacings are zero.
pub fn measureWidth(self: *const SmFont, text_utf8: []const u8) f64 {
    return self.measureWithSpacing(text_utf8, 0, 0, false);
}

/// kernAdvance(prev_cp, cp) — scaled kerning advance between two
/// consecutive codepoints, or 0 if the font has no kerning pair / either
/// codepoint is 0. Wraps `stbtt_GetCodepointKernAdvance`.
pub fn kernAdvance(self: *const SmFont, prev_cp: u32, cp: u32) f64 {
    if (prev_cp == 0 or cp == 0) return 0;
    const k = c.stbtt_GetCodepointKernAdvance(
        self.info(),
        @intCast(prev_cp),
        @intCast(cp),
    );
    return @as(f64, @floatFromInt(k)) * self.scale;
}

/// measureWithSpacing — width with optional CSS letter-spacing /
/// word-spacing additions and stb_truetype kerning. Letter-spacing is
/// added after every glyph; word-spacing is added once per U+0020 (space)
/// in addition to the letter-spacing. Spacing applies to the character
/// itself (so a single character + letterSpacing produces a wider
/// reported width — matching CSS Text 3 §10.2).
pub fn measureWithSpacing(
    self: *const SmFont,
    text_utf8: []const u8,
    letter_spacing_px: f64,
    word_spacing_px: f64,
    kerning_on: bool,
) f64 {
    var total: f64 = 0;
    var prev_cp: u32 = 0;
    var i: usize = 0;
    while (i < text_utf8.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text_utf8[i]) catch 1;
        const end = @min(i + cp_len, text_utf8.len);
        const cp: u32 = std.unicode.utf8Decode(text_utf8[i..end]) catch 0xFFFD;
        i = end;
        if (kerning_on and prev_cp != 0) {
            total += self.kernAdvance(prev_cp, cp);
        }
        const glyph = c.stbtt_FindGlyphIndex(self.info(), @intCast(cp));
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(self.info(), glyph, &adv, &lsb);
        total += @as(f64, @floatFromInt(adv)) * self.scale;
        total += letter_spacing_px;
        if (cp == 0x20) total += word_spacing_px;
        prev_cp = cp;
    }
    return total;
}

/// rasterizeGlyph — draw `glyph` into a fresh page-allocator-backed alpha
/// buffer cached on the SmFont (replacing any previous one). Returns the
/// bitmap dimensions, pen offsets (`offsetX` from pen, `offsetY` from
/// baseline — stb's convention: y0 negative for chars above baseline),
/// and scaled advance.
pub fn rasterizeGlyph(self: *SmFont, glyph: i32) std.mem.Allocator.Error!GlyphBitmap {
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0;
    const fi = self.info();
    const sf: f32 = @floatCast(self.scale);
    c.stbtt_GetGlyphBitmapBox(fi, glyph, sf, sf, &x0, &y0, &x1, &y1);

    const w_i: i32 = x1 - x0;
    const h_i: i32 = y1 - y0;
    const w: u32 = if (w_i > 0) @intCast(w_i) else 0;
    const h: u32 = if (h_i > 0) @intCast(h_i) else 0;

    if (self.last_glyph_pixels) |p| self.allocator.free(p);
    self.last_glyph_pixels = null;

    const len: usize = @as(usize, w) * @as(usize, h);
    const buf = try self.allocator.alloc(u8, len);
    self.last_glyph_pixels = buf;
    if (len > 0) {
        @memset(buf, 0);
        c.stbtt_MakeGlyphBitmap(
            fi,
            buf.ptr,
            @intCast(w),
            @intCast(h),
            @intCast(w), // stride = width (tightly packed)
            sf,
            sf,
            glyph,
        );

        // Faux-bold: 1-pixel horizontal dilation. Walk each row right-to-left
        // so each `out[c] = max(in[c], in[c-1])` reads the *original*
        // left-neighbour, not an already-thickened one. Strokes effectively
        // double in width; advance stays unchanged so the next glyph
        // overlaps the dilated tail (matches Skia's faux-bold).
        if (self.synth_bold and w > 1) {
            var r: u32 = 0;
            while (r < h) : (r += 1) {
                const row_off: usize = @as(usize, r) * @as(usize, w);
                var col: u32 = w - 1;
                while (col >= 1) : (col -= 1) {
                    const here = buf[row_off + col];
                    const left = buf[row_off + col - 1];
                    if (left > here) buf[row_off + col] = left;
                }
            }
        }
    }

    var adv: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetGlyphHMetrics(fi, glyph, &adv, &lsb);

    return .{
        .pixels = buf,
        .width = w,
        .height = h,
        .offsetX = x0,
        .offsetY = y0,
        .advanceX = @as(f64, @floatFromInt(adv)) * self.scale,
    };
}
