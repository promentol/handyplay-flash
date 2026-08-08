//! Text layout: spans in, lines and boxes out.
//!
//! One pass builds a line at a time, laying every box out with the CURSOR
//! ON THE BASELINE, then "fixes up" the finished line — shifting every box
//! down by the line's tallest ascent and right by the margins, the indent
//! and whatever the alignment asks for. Doing it in that order is what
//! makes a line with two font sizes share one baseline.
//!
//! Details that are load-bearing and easy to get wrong:
//!
//!   - **`GUTTER` = 40 twips on all four sides.** Every `textWidth`,
//!     `_width` and glyph position is 2px out per side without it.
//!   - **Only the FIRST line contributes its leading** to the measured
//!     text height; every later line's leading is spent moving the cursor.
//!   - **A non-input field drops a trailing empty line** from the measured
//!     height; an input field keeps it, because you have to be able to
//!     click there.
//!   - **Word wrap changed in SWF8**: below it every space breaks and only
//!     the final one is dropped when measuring; from SWF8 only the last
//!     space of a run breaks and the whole run is trimmed.
//!   - **Autosize without word wrap lays out TWICE** — once at width zero
//!     to discover the natural width, then again knowing it.
//!
//! Reference: reference/ruffle/core/src/html/layout.rs and
//! core/src/html/line_wrapping.rs.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const library = @import("library.zig");
const font_mod = @import("font.zig");
const format_mod = @import("../text/format.zig");

const Font = font_mod.Font;
const TextFormat = format_mod.TextFormat;
const Align = format_mod.Align;

/// Padding inside a text field, on all four sides.
pub const GUTTER: i32 = 40;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    fn unionWith(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// A run of text sharing one format. `start` is a character index into the
/// field's text; the run ends where the next span begins.
pub const Span = struct {
    start: usize,
    format: TextFormat,
};

/// One drawable run on a line. `x`/`y` are relative to the layout origin
/// (the inside of the gutter), with `y` at the TOP of the box.
pub const Box = struct {
    start: usize,
    end: usize,
    bounds: Rect,
    font: Font,
    /// Font size in twips.
    size: i32,
    color: u32,
    letter_spacing: i32,
    kerning: bool,
    underline: bool,
    /// The U+2022 a bulleted line opens with, drawn from `font` but not
    /// part of the text.
    is_bullet: bool = false,
};

pub const Line = struct {
    index: usize,
    start: usize,
    end: usize,
    bounds: Rect,
    ascent: i32,
    descent: i32,
    leading: i32,
    boxes: []Box,
};

pub const Layout = struct {
    lines: []Line,
    /// Union of every line's bounds.
    bounds: Rect = .{},
    /// What `textWidth`/`textHeight` report, gutter excluded.
    text_width: i32 = 0,
    text_height: i32 = 0,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        for (self.lines) |l| gpa.free(l.boxes);
        gpa.free(self.lines);
        self.* = .{ .lines = &.{} };
    }

    pub const empty: Layout = .{ .lines = &.{} };
};

pub const Options = struct {
    /// Inner width available to content, in twips. Null means "measure
    /// first" — an autosizing field with no wrapping.
    width: ?i32,
    is_input: bool,
    word_wrap: bool,
    /// `embedFonts`. False resolves every face to nothing, which is what
    /// Flash does when no device font is installed.
    embedded: bool,
    swf_version: u8,
};

pub fn layOut(
    gpa: std.mem.Allocator,
    lib: *const library.Library,
    text: []const u16,
    spans: []const Span,
    opts: Options,
) !Layout {
    const width = opts.width orelse w: {
        // The natural width is the widest line when nothing constrains it.
        var probe = try layOutKnownWidth(gpa, lib, text, spans, 0, opts.is_input, false, opts.embedded, opts.swf_version);
        defer probe.deinit(gpa);
        var max: i32 = 0;
        for (probe.lines) |l| max = @max(max, l.bounds.w);
        break :w max;
    };
    return layOutKnownWidth(gpa, lib, text, spans, width, opts.is_input, opts.word_wrap, opts.embedded, opts.swf_version);
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    lib: *const library.Library,
    text: []const u16,
    max_bounds: i32,
    is_input: bool,
    word_wrap: bool,
    embedded: bool,
    swf_version: u8,

    /// Pen position, y ON THE BASELINE, x relative to the line start.
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,

    max_ascent: i32 = 0,
    max_descent: i32 = 0,
    max_leading: i32 = 0,
    max_font_size: i32 = 0,

    lines: std.ArrayList(Line) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    line_index: usize = 0,
    is_first_line: bool = true,

    bounds: ?Rect = null,
    text_bounds: ?Rect = null,

    /// The format that governs the whole line: the one in force where the
    /// line began, margins and alignment included.
    line_format: TextFormat = .{},
    line_font: Font = .empty,

    fn alignOf(self: *const Ctx) Align {
        // A bulleted line is always left-aligned, whatever it asked for.
        if (self.line_format.bullet orelse false) return .left;
        return self.line_format.text_align orelse .left;
    }

    fn leftOffsetNoBullet(f: TextFormat, first: bool) i32 {
        const base = (f.left_margin orelse 0) + (f.block_indent orelse 0);
        const v = if (first) base + (f.indent orelse 0) else base;
        return @max(twips(v), 0);
    }

    fn leftOffset(f: TextFormat, first: bool) i32 {
        if (f.bullet orelse false) {
            const base = 36.0 + (f.left_margin orelse 0) + (f.block_indent orelse 0);
            const v = if (first) base + (f.indent orelse 0) else base;
            return @max(twips(v), 0);
        }
        return leftOffsetNoBullet(f, first);
    }
};

fn twips(px: f64) i32 {
    return @intFromFloat(px * @as(f64, swf.reader.TWIPS_PER_PX));
}

fn layOutKnownWidth(
    gpa: std.mem.Allocator,
    lib: *const library.Library,
    text: []const u16,
    spans: []const Span,
    width: i32,
    is_input: bool,
    word_wrap: bool,
    embedded: bool,
    swf_version: u8,
) !Layout {
    var ctx: Ctx = .{
        .gpa = gpa,
        .lib = lib,
        .text = text,
        .max_bounds = width,
        .is_input = is_input,
        .word_wrap = word_wrap,
        .embedded = embedded,
        .swf_version = swf_version,
    };
    errdefer {
        for (ctx.lines.items) |l| gpa.free(l.boxes);
        ctx.lines.deinit(gpa);
        ctx.boxes.deinit(gpa);
    }

    var last_format: TextFormat = if (spans.len > 0) spans[0].format else .{};
    for (spans, 0..) |sp, i| {
        const end = if (i + 1 < spans.len) spans[i + 1].start else text.len;
        if (sp.start > end) continue;
        try laySpan(&ctx, sp.start, text[sp.start..end], sp.format);
        last_format = sp.format;
    }
    try fixupLine(&ctx, true, true, text.len, last_format);

    const tb = ctx.text_bounds orelse Rect{};
    ctx.boxes.deinit(gpa);
    return .{
        .lines = try ctx.lines.toOwnedSlice(gpa),
        .bounds = ctx.bounds orelse .{},
        .text_width = tb.w,
        .text_height = tb.h,
    };
}

fn resolveFont(ctx: *Ctx, f: TextFormat) Font {
    const face = f.font orelse &.{};
    const resolved = font_mod.resolve(
        ctx.lib,
        face,
        f.bold orelse false,
        f.italic orelse false,
        ctx.embedded,
    );
    // A DefineFont with no glyph table is not a usable face: ruffle
    // filters on `has_glyphs()` and falls through to the device path,
    // which in a movie with no device fonts means nothing at all.
    if (resolved.swf_font) |sf| {
        if (sf.glyphs.len == 0) return .empty;
    }
    return resolved;
}

fn paramsOf(f: TextFormat, size: i32) font_mod.Params {
    return .{
        .height = size,
        .letter_spacing = twips(f.letter_spacing orelse 0),
        .kerning = f.kerning orelse false,
    };
}

fn laySpan(ctx: *Ctx, span_start: usize, span_text: []const u16, f: TextFormat) !void {
    const font = resolveFont(ctx, f);
    ctx.line_font = font;
    newSpan(ctx, f, font);

    const size = twips(f.size orelse 12);
    const params = paramsOf(f, size);

    // The span is cut at every \n, \r and \t; the delimiter BEFORE each
    // piece says what to do first.
    var pos: usize = 0;
    var piece_start: usize = 0;
    while (true) {
        const at_end = pos >= span_text.len;
        const c: u16 = if (at_end) 0 else span_text[pos];
        if (!at_end and c != '\n' and c != '\r' and c != '\t') {
            pos += 1;
            continue;
        }
        try layPiece(ctx, span_start, span_text, piece_start, pos, f, font, params);
        if (at_end) break;
        // The delimiter itself belongs to the line it ENDS.
        if (c == '\t') {
            tab(ctx);
        } else {
            try newline(ctx, span_start + pos, f, font, true);
        }
        pos += 1;
        piece_start = pos;
    }
}

fn layPiece(
    ctx: *Ctx,
    span_start: usize,
    span_text: []const u16,
    from: usize,
    to: usize,
    f: TextFormat,
    font: Font,
    params: font_mod.Params,
) !void {
    const text = span_text[from..to];
    const start = span_start + from;
    var last_break: usize = 0;

    if (ctx.word_wrap) {
        var dims = wrapDimensions(ctx, f);
        while (true) {
            const bp = wrapLine(
                font,
                text[last_break..],
                params,
                dims.width,
                dims.offset,
                ctx.boxes.items.len == 0,
                ctx.swf_version,
            ) orelse break;
            const next = last_break + bp;
            if (bp == 0) {
                try newline(ctx, start + next, f, font, false);
                dims = wrapDimensions(ctx, f);
                if (last_break >= text.len) break;
                continue;
            }
            try appendText(ctx, text[last_break..next], start + last_break, start + next, f, font, params);
            last_break = next;
            if (last_break >= text.len) break;
            try newline(ctx, start + next, f, font, false);
            dims = wrapDimensions(ctx, f);
        }
    }
    if (last_break < text.len) {
        try appendText(ctx, text[last_break..], start + last_break, start + text.len, f, font, params);
    }
}

fn wrapDimensions(ctx: *Ctx, f: TextFormat) struct { width: i32, offset: i32 } {
    const w = ctx.max_bounds - twips(ctx.line_format.right_margin orelse 0);
    const o = Ctx.leftOffset(f, ctx.is_first_line) + ctx.cursor_x;
    return .{ .width = w, .offset = o };
}

fn newSpan(ctx: *Ctx, f: TextFormat, font: Font) void {
    const size = twips(f.size orelse 12);
    const a = font.ascent(size);
    const d = font.descent(size);
    const l = twips(f.leading orelse 0);
    if (ctx.boxes.items.len == 0) {
        ctx.line_format = f;
        ctx.max_font_size = size;
        ctx.max_ascent = a;
        ctx.max_descent = d;
        ctx.max_leading = l;
    } else {
        ctx.max_font_size = @max(ctx.max_font_size, size);
        ctx.max_ascent = @max(ctx.max_ascent, a);
        ctx.max_descent = @max(ctx.max_descent, d);
        ctx.max_leading = @max(ctx.max_leading, l);
    }
}

/// A tab either jumps to the next explicit stop or, with no stops, to the
/// next multiple of 2.7 × the font size. That constant is Flash's.
fn tab(ctx: *Ctx) void {
    const stops = ctx.line_format.tab_stops orelse &.{};
    if (stops.len == 0) {
        const modulo = twips((ctx.line_format.size orelse 12) * 2.7);
        if (modulo <= 0) return;
        ctx.cursor_x = (@divTrunc(ctx.cursor_x, modulo) + 1) * modulo;
        return;
    }
    for (stops) |s| {
        const t = twips(s);
        if (t > ctx.cursor_x) {
            ctx.cursor_x = t;
            return;
        }
    }
}

fn appendText(
    ctx: *Ctx,
    text: []const u16,
    start: usize,
    end: usize,
    f: TextFormat,
    font: Font,
    params: font_mod.Params,
) !void {
    // Justify measures and moves each WORD separately, so the gaps between
    // them can be widened; every other alignment keeps the run whole.
    if (start != end and ctx.alignOf() == .justify) {
        var i: usize = 0;
        while (i < text.len) {
            var j = i;
            while (j < text.len and text[j] != ' ') j += 1;
            const word_end = @min(j + 1, text.len);
            if (i == word_end) {
                i += 1;
                continue;
            }
            try appendFragment(ctx, text[i..word_end], start + i, start + word_end, f, font, params);
            i = word_end;
        }
        return;
    }
    try appendFragment(ctx, text, start, end, f, font, params);
}

fn appendFragment(
    ctx: *Ctx,
    text: []const u16,
    start: usize,
    end: usize,
    f: TextFormat,
    font: Font,
    params: font_mod.Params,
) !void {
    const a = font.ascent(params.height);
    const d = font.descent(params.height);
    const w = font.measure(text, params);
    try ctx.boxes.append(ctx.gpa, .{
        .start = start,
        .end = end,
        .bounds = .{ .x = ctx.cursor_x, .y = ctx.cursor_y - a, .w = w, .h = a + d },
        .font = font,
        .size = params.height,
        .color = f.color orelse 0,
        .letter_spacing = params.letter_spacing,
        .kerning = params.kerning,
        .underline = f.underline orelse false,
    });
    ctx.cursor_x += w;
}

fn newline(ctx: *Ctx, end: usize, f: TextFormat, font: Font, end_of_para: bool) !void {
    try fixupLine(ctx, false, end_of_para, end, f);
    ctx.cursor_x = 0;
    ctx.cursor_y += ctx.max_ascent + ctx.max_descent + twips(ctx.line_format.leading orelse 0);
    ctx.is_first_line = end_of_para;

    const size = twips(ctx.line_format.size orelse 12);
    ctx.max_font_size = size;
    ctx.max_ascent = font.ascent(size);
    ctx.max_descent = font.descent(size);
    ctx.max_leading = twips(f.leading orelse 0);
}

fn fixupLine(ctx: *Ctx, last_line: bool, final_of_para: bool, end: usize, f: TextFormat) !void {
    if (ctx.boxes.items.len == 0) {
        // Even an empty line needs a box: it carries the line's position
        // and, for an input field, the place the caret goes.
        const font = ctx.line_font;
        const size = twips(f.size orelse 12);
        try appendFragment(ctx, &.{}, end, end, f, font, paramsOf(f, size));
    }
    const is_empty = ctx.boxes.items[0].start == end;

    var line_size: ?Rect = null;
    var box_count: i32 = 0;
    for (ctx.boxes.items) |*b| {
        // From SWF8 a non-left alignment ignores TRAILING SPACES when it
        // measures — the spaces still exist, they just do not push the
        // line around.
        if (ctx.swf_version >= 8 and ctx.alignOf() != .left and !b.is_bullet) {
            const t = ctx.text[b.start..b.end];
            var n = t.len;
            while (n > 0 and t[n - 1] == ' ') n -= 1;
            b.bounds.w = b.font.measure(t[0..n], .{
                .height = b.size,
                .letter_spacing = b.letter_spacing,
                .kerning = b.kerning,
            });
        }
        line_size = if (line_size) |ls| ls.unionWith(b.bounds) else b.bounds;
        box_count += 1;
    }
    var ls = line_size orelse Rect{};

    const left_adj = Ctx.leftOffset(ctx.line_format, ctx.is_first_line);
    const right_adj = twips(ctx.line_format.right_margin orelse 0);
    const misalign = ctx.max_bounds - left_adj - right_adj - ls.w;
    const align_adj: i32 = @max(switch (ctx.alignOf()) {
        .left, .justify => 0,
        .center => @divTrunc(misalign, 2),
        .right => misalign,
    }, 0);
    // Justify spreads the slack between the WORD boxes, and only on a line
    // that was broken rather than ended.
    const interim: i32 = @max(if (!final_of_para and ctx.alignOf() == .justify)
        @divTrunc(misalign, @max(box_count - 1, 1))
    else
        0, 0);

    if ((ctx.line_format.bullet orelse false) and ctx.is_first_line and box_count > 0) {
        try appendBullet(ctx);
    }

    const baseline = ctx.max_ascent;
    box_count = 0;
    for (ctx.boxes.items) |*b| {
        if (b.is_bullet) {
            b.bounds.y += baseline;
        } else {
            b.bounds.x += left_adj + align_adj + interim * box_count;
            b.bounds.y += baseline;
        }
        box_count += 1;
    }
    ls.x += left_adj + align_adj;
    ls.y += baseline;
    // The FIRST line is the only one whose leading counts towards the
    // measured height; every later line spends it moving the cursor.
    if (ctx.line_index == 0) ls.h += ctx.max_leading;

    if (!(!ctx.is_input and is_empty and last_line)) {
        ctx.text_bounds = if (ctx.text_bounds) |t| t.unionWith(ls) else ls;
    }

    try flushLine(ctx, end);
}

fn appendBullet(ctx: *Ctx) !void {
    const f = ctx.line_format;
    const font = ctx.line_font;
    const size = twips(f.size orelse 12);
    const params = paramsOf(f, size);
    const a = font.ascent(size);
    const d = font.descent(size);
    const bullet = [_]u16{0x2022};
    const w = font.measure(&bullet, params);
    const x = twips(18.0) + Ctx.leftOffsetNoBullet(f, ctx.is_first_line);
    const pos = if (ctx.boxes.items.len > 0) ctx.boxes.items[ctx.boxes.items.len - 1].end else 0;
    try ctx.boxes.append(ctx.gpa, .{
        .start = pos,
        .end = pos,
        .bounds = .{ .x = x, .y = ctx.cursor_y - a, .w = w, .h = a + d },
        .font = font,
        .size = size,
        .color = f.color orelse 0,
        .letter_spacing = params.letter_spacing,
        .kerning = params.kerning,
        .underline = false,
        .is_bullet = true,
    });
}

fn flushLine(ctx: *Ctx, end: usize) !void {
    if (ctx.boxes.items.len == 0) return;
    const boxes = try ctx.boxes.toOwnedSlice(ctx.gpa);
    const start = boxes[0].start;
    var b = boxes[0].bounds;
    for (boxes) |x| {
        if (!x.is_bullet) b = b.unionWith(x.bounds);
    }
    // The previous line's end moves up to where this one starts, so the
    // delimiter between them belongs to the line it terminated.
    if (ctx.lines.items.len > 0) ctx.lines.items[ctx.lines.items.len - 1].end = start;
    try ctx.lines.append(ctx.gpa, .{
        .index = ctx.line_index,
        .start = start,
        .end = end,
        .bounds = b,
        .ascent = ctx.max_ascent,
        .descent = ctx.max_descent,
        .leading = ctx.max_leading,
        .boxes = boxes,
    });
    ctx.line_index += 1;
    ctx.bounds = if (ctx.bounds) |o| o.unionWith(b) else b;
}

// --- word wrapping -----------------------------------------------------------

/// The first breakpoint in `text`, or null when the whole thing fits.
/// Zero means "not even the first word fits, break before it" — and that
/// can only happen when the line already has something on it.
fn wrapLine(
    font: Font,
    text: []const u16,
    params: font_mod.Params,
    width: i32,
    offset: i32,
    start_of_line_in: bool,
    swf_version: u8,
) ?usize {
    const swf8 = swf_version >= 8;
    if (text.len == 0) return null;
    var start_of_line = start_of_line_in;
    var remaining = width - offset;
    if (remaining < 0) {
        // Below SWF8 an over-long first character abandons wrapping
        // entirely; from SWF8 something is always written.
        return if (swf8) 1 else null;
    }

    var line_end: usize = 0;
    var last_stop: usize = 0;
    var it = BreakIter{ .text = text, .swf8 = swf8 };
    var i: usize = 0;
    while (it.next()) |word_end| : (i += 1) {
        const word_start = last_stop;
        if (word_start >= word_end) continue;
        const word = text[word_start..word_end];
        const trimmed = if (swf8) trimEndSpaces(word) else dropFinalSpace(word);
        last_stop = word_start + trimmed.len;

        const m = font.measure(trimmed, params);
        if (m <= remaining) {
            line_end = word_end;
            start_of_line = false;
            remaining -= m;
            continue;
        }
        if (start_of_line) {
            // A single word wider than the whole field: break wherever it
            // stops fitting.
            var fit: usize = 0;
            var k: usize = 0;
            while (k <= trimmed.len) : (k += 1) {
                if (font.measure(trimmed[0..k], params) > remaining) break;
                fit = k;
            }
            line_end = fit;
            if (swf8) {
                line_end = @max(line_end, 1);
            } else if (line_end <= 1) {
                return null;
            }
        }
        return line_end;
    }
    return null;
}

fn trimEndSpaces(s: []const u16) []const u16 {
    var n = s.len;
    while (n > 0 and s[n - 1] == ' ') n -= 1;
    return s[0..n];
}

fn dropFinalSpace(s: []const u16) []const u16 {
    if (s.len > 0 and s[s.len - 1] == ' ') return s[0 .. s.len - 1];
    return s;
}

/// The indices that end a non-breakable run. Below SWF8 every space is a
/// break; from SWF8 only the LAST space of a run is.
const BreakIter = struct {
    text: []const u16,
    swf8: bool,
    i: usize = 1,
    done: bool = false,

    fn next(self: *BreakIter) ?usize {
        if (self.done) return null;
        while (self.i < self.text.len) {
            const prev = self.text[self.i - 1];
            const curr = self.text[self.i];
            const at = self.i;
            self.i += 1;
            if (self.swf8 and curr == ' ') continue;
            if (prev == ' ') return at;
            if (prev == '-' or (!self.swf8 and curr == '-')) return at;
            if (isCjkLike(prev) or isCjkLike(curr)) {
                if (!isOpening(prev) and !isClosing(curr)) return at;
            }
        }
        self.done = true;
        return self.text.len;
    }
};

/// The blocks Flash treats as breakable on either side.
fn isCjkLike(c: u16) bool {
    return (c >= 0x1100 and c <= 0x11FF) or // Hangul Jamo
        (c >= 0x2E80 and c <= 0x9FFF) or // radicals … CJK unified
        (c >= 0xA960 and c <= 0xA97F) or
        (c >= 0xAC00 and c <= 0xD7FF) or // Hangul syllables
        (c >= 0xF900 and c <= 0xFAFF) or
        (c >= 0xFE30 and c <= 0xFE4F) or
        (c >= 0xFF00 and c <= 0xFFEF);
}

fn isOpening(c: u16) bool {
    return switch (c) {
        '(', '[', '{', 0x2018, 0x201C, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0xFF08, 0xFF3B, 0xFF5B => true,
        else => false,
    };
}

fn isClosing(c: u16) bool {
    return switch (c) {
        ')', ']', '}', ',', '.', 0x2019, 0x201D, 0x3001, 0x3002, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0xFF09, 0xFF3D, 0xFF5D => true,
        else => false,
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "an empty field still lays out one line" {
    const lib: library.Library = .{};
    const spans = [_]Span{.{ .start = 0, .format = .{ .size = 12 } }};
    var l = try layOut(testing.allocator, &lib, &.{}, &spans, .{
        .width = 2000,
        .is_input = false,
        .word_wrap = false,
        .embedded = true,
        .swf_version = 8,
    });
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), l.lines.len);
    // No font resolves, so the text measures nothing at all.
    try testing.expectEqual(@as(i32, 0), l.text_width);
}

test "SWF8 breaks only after the last space of a run" {
    var it = BreakIter{ .text = &[_]u16{ 'a', ' ', ' ', 'b' }, .swf8 = true };
    try testing.expectEqual(@as(?usize, 3), it.next());
    try testing.expectEqual(@as(?usize, 4), it.next());
    try testing.expectEqual(@as(?usize, null), it.next());

    var it7 = BreakIter{ .text = &[_]u16{ 'a', ' ', ' ', 'b' }, .swf8 = false };
    try testing.expectEqual(@as(?usize, 2), it7.next());
    try testing.expectEqual(@as(?usize, 3), it7.next());
    try testing.expectEqual(@as(?usize, 4), it7.next());
}
