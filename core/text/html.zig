//! HTML text in and out.
//!
//! Flash's "HTML" is a small tag vocabulary parsed by a deliberately
//! forgiving reader: mismatched end tags are IGNORED rather than fatal, an
//! unknown tag still pushes a format frame, and attributes are matched
//! case-insensitively. What comes out is not a tree — it is the flat
//! `FormatSpans` the layout engine wants.
//!
//! The behaviours the corpus actually pins:
//!
//!   - `\r` is the newline. `<BR>` and `</P>` each contribute one.
//!   - Below SWF8 the alignment is forced to LEFT, whatever the field or
//!     the markup says.
//!   - SWF6 is always multiline, whatever `multiline` says.
//!   - SWF6 and 7 DROP whitespace-only text nodes.
//!   - `</P>` emits a newline whose span takes the font of the last
//!     `</FONT>` seen, and resets style, url and target. That makes no
//!     sense; Flash does it anyway.
//!   - `<FONT SIZE="+2">` is relative; a size stops at the first
//!     non-digit and is clamped to 1..127 below SWF13.
//!   - `KERNING="1"` only takes effect from SWF8; `"0"` always does.
//!
//! Serialising back out is not the inverse: the writer always emits a
//! `<P>` (or `<LI>`), always emits a fully-specified first `<FONT>`, and
//! wraps in `<TEXTFORMAT>` only when a margin, indent, leading or tab stop
//! is non-zero. Tag order is fixed — TEXTFORMAT, P/LI, FONT, A, B, I, U —
//! and a tag that would open out of order is skipped.
//!
//! Reference: reference/ruffle/core/src/html/text_format.rs
//! (`from_html`, `to_html`, `FormatState`).

const std = @import("std");
const format_mod = @import("format.zig");
const spans_mod = @import("spans.zig");

const TextFormat = format_mod.TextFormat;
const Align = format_mod.Align;
const Display = format_mod.Display;
const Spans = spans_mod.Spans;
const TextSpan = spans_mod.TextSpan;
const SpanFont = spans_mod.SpanFont;

pub const NEWLINE: u16 = '\r';

pub const Parsed = struct {
    text: []u16,
    spans: []TextSpan,
};

/// How the parser asks for a CSS rule. The style sheet itself is an AVM1
/// object, so the lookup is a callback rather than a type this module
/// knows: `core/text` stays clear of the interpreter.
pub const StyleResolver = struct {
    ctx: *anyopaque,
    sheet: u32,
    /// Selectors are matched LOWERCASED: `p`, `a`, `li`, or `.class`.
    lookup: *const fn (ctx: *anyopaque, sheet: u32, selector: []const u16) ?TextFormat,

    fn apply(self: StyleResolver, f: TextFormat, selector: []const u8) TextFormat {
        var buf: [64]u16 = undefined;
        if (selector.len > buf.len) return f;
        for (selector, 0..) |c, i| buf[i] = c;
        const style = self.lookup(self.ctx, self.sheet, buf[0..selector.len]) orelse return f;
        return style.mixWith(f);
    }
};

pub const Options = struct {
    multiline: bool,
    condense_white: bool,
    swf_version: u8,
    /// Null when the field has no style sheet, which is the common case.
    styles: ?StyleResolver = null,
};

/// Parse `html` into text plus spans. Both slices are allocated from
/// `arena`, which the caller owns — spans point into it.
pub fn parse(
    arena: std.mem.Allocator,
    html: []const u16,
    default_format_in: TextFormat,
    opts: Options,
) !Parsed {
    // SWF6 ignores `multiline` entirely and behaves as if it were set.
    const multiline = opts.multiline or opts.swf_version <= 6;
    var default_format = default_format_in;
    // Below SWF8 an HTML field is always left-aligned, even when HTML was
    // turned on from script.
    if (opts.swf_version < 8) default_format.text_align = .left;

    var text: std.ArrayList(u16) = .empty;
    var spans: std.ArrayList(TextSpan) = .empty;
    var stack: std.ArrayList(TextFormat) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, default_format);

    // Ruffle tracks open tags in one flat buffer so a mismatched end tag
    // can be skipped without unwinding.
    var opened: std.ArrayList(u8) = .empty;
    var opened_starts: std.ArrayList(usize) = .empty;
    defer opened.deinit(arena);
    defer opened_starts.deinit(arena);

    var p_open = false;
    var last_closed_font: ?SpanFont = null;
    var display_block = false;

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            // A text node runs to the next '<'.
            const start = i;
            while (i < html.len and html[i] != '<') i += 1;
            var run = try decodeEntities(arena, html[start..i]);
            const fmt = stack.items[stack.items.len - 1];
            if ((fmt.display orelse .block) == .none) continue;
            if (opts.swf_version <= 7 and isBlank(run)) continue;
            run = if (opts.condense_white)
                try condenseWhite(arena, run)
            else
                try newlinesToCr(arena, run);
            if (run.len == 0) continue;
            try text.appendSlice(arena, run);
            try spans.append(arena, TextSpan.fromFormat(fmt, run.len));
            continue;
        }

        const tag = scanTag(html, i) orelse {
            // A stray '<' with no '>' after it ends the document.
            break;
        };
        i = tag.next;
        var name_buf: [64]u8 = undefined;
        const name = lowerAscii(&name_buf, tag.name);

        if (tag.is_end) {
            // An end tag that does not match the innermost open one is
            // discarded outright.
            if (opened_starts.items.len == 0) continue;
            const start = opened_starts.items[opened_starts.items.len - 1];
            if (!std.mem.eql(u8, name, opened.items[start..])) continue;
            opened.shrinkRetainingCapacity(start);
            _ = opened_starts.pop();

            if (display_block) {
                display_block = false;
                const fmt = stack.items[stack.items.len - 1];
                try text.append(arena, NEWLINE);
                try spans.append(arena, TextSpan.fromFormat(fmt, 1));
            }

            if (std.mem.eql(u8, name, "br") or std.mem.eql(u8, name, "sbr")) continue;
            if (std.mem.eql(u8, name, "li") and multiline) {
                try text.append(arena, NEWLINE);
                try spans.append(arena, TextSpan.fromFormat(stack.items[stack.items.len - 1], 1));
            } else if (std.mem.eql(u8, name, "p") and multiline) {
                if (p_open) {
                    p_open = false;
                    try text.append(arena, NEWLINE);
                    var s = TextSpan.fromFormat(stack.items[stack.items.len - 1], 1);
                    s.style = .{};
                    s.url = &.{};
                    s.target = &.{};
                    s.font = last_closed_font orelse fontOf(default_format);
                    try spans.append(arena, s);
                }
            } else if (std.mem.eql(u8, name, "font")) {
                last_closed_font = fontOf(stack.items[stack.items.len - 1]);
            }
            _ = stack.pop();
            continue;
        }

        var fmt = stack.items[stack.items.len - 1];
        if (std.mem.eql(u8, name, "br")) {
            if (multiline) {
                try text.append(arena, NEWLINE);
                try spans.append(arena, TextSpan.fromFormat(fmt, 1));
            }
            continue;
        }
        if (std.mem.eql(u8, name, "sbr")) {
            // A real `<sbr>` breaks the span without a newline; ruffle
            // approximates it with one, and so do we.
            try text.append(arena, NEWLINE);
            try spans.append(arena, TextSpan.fromFormat(fmt, 1));
            continue;
        }
        if (std.mem.eql(u8, name, "p")) {
            p_open = true;
            if (opts.styles) |st| {
                fmt = st.apply(fmt, "p");
                fmt = applyClass(st, fmt, html, tag);
            }
            if (attr(html, tag, "align")) |a| {
                var abuf: [16]u8 = undefined;
                const al = lowerAscii(&abuf, a);
                if (std.mem.eql(u8, al, "left")) {
                    fmt.text_align = .left;
                } else if (std.mem.eql(u8, al, "center")) {
                    fmt.text_align = .center;
                } else if (std.mem.eql(u8, al, "right")) {
                    fmt.text_align = .right;
                } else if (std.mem.eql(u8, al, "justify")) {
                    fmt.text_align = .justify;
                }
            }
        } else if (std.mem.eql(u8, name, "a")) {
            if (attr(html, tag, "href")) |v| fmt.url = try arena.dupe(u16, v);
            if (attr(html, tag, "target")) |v| fmt.target = try arena.dupe(u16, v);
            if (opts.styles) |st| {
                fmt = st.apply(fmt, "a");
                fmt = applyClass(st, fmt, html, tag);
            }
        } else if (std.mem.eql(u8, name, "font")) {
            if (attr(html, tag, "face")) |v| fmt.font = try arena.dupe(u16, v);
            if (attr(html, tag, "size")) |v| applySize(&fmt, v, opts.swf_version);
            if (attr(html, tag, "color")) |v| applyColor(&fmt, v);
            if (attr(html, tag, "letterspacing")) |v| {
                if (parseF64(v)) |n| fmt.letter_spacing = n;
            }
            if (attr(html, tag, "kerning")) |v| {
                if (v.len == 1 and v[0] == '1' and opts.swf_version >= 8) {
                    fmt.kerning = true;
                } else if (v.len == 1 and v[0] == '0') {
                    fmt.kerning = false;
                }
            }
        } else if (std.mem.eql(u8, name, "b")) {
            fmt.bold = true;
        } else if (std.mem.eql(u8, name, "i")) {
            fmt.italic = true;
        } else if (std.mem.eql(u8, name, "u")) {
            fmt.underline = true;
        } else if (std.mem.eql(u8, name, "li")) {
            if (opts.styles) |st| fmt = st.apply(fmt, "li");
            // An unclosed paragraph is closed here, but only if something
            // was written since the last newline.
            const last_is_nl = text.items.len > 0 and text.items[text.items.len - 1] == NEWLINE;
            if (multiline and !last_is_nl and text.items.len > 0) {
                try text.append(arena, NEWLINE);
                try spans.append(arena, TextSpan.fromFormat(stack.items[stack.items.len - 1], 1));
            }
            fmt.bullet = true;
        } else if (std.mem.eql(u8, name, "textformat")) {
            if (attr(html, tag, "leftmargin")) |v| fmt.left_margin = parseF64(v);
            if (attr(html, tag, "rightmargin")) |v| fmt.right_margin = parseF64(v);
            if (attr(html, tag, "indent")) |v| fmt.indent = parseF64(v);
            if (attr(html, tag, "blockindent")) |v| fmt.block_indent = parseF64(v);
            if (attr(html, tag, "leading")) |v| fmt.leading = parseF64(v);
            if (attr(html, tag, "tabstops")) |v| fmt.tab_stops = try parseStops(arena, v);
        } else if (std.mem.eql(u8, name, "span")) {
            // `<span>` carries nothing but its class.
            if (opts.styles) |st| fmt = applyClass(st, fmt, html, tag);
        } else {
            // An unknown tag is INLINE unless a style sheet says
            // otherwise — Flash applies `display` only when a rule
            // defines it, and a rule that makes it block or none ends the
            // paragraph at the closing tag.
            fmt.display = null;
            if (opts.styles) |st| {
                var nbuf: [64]u16 = undefined;
                if (name.len <= nbuf.len) {
                    for (name, 0..) |ch, k| nbuf[k] = ch;
                    if (st.lookup(st.ctx, st.sheet, nbuf[0..name.len])) |style| {
                        fmt = style.mixWith(fmt);
                    }
                }
                if (fmt.display) |d| {
                    if (d == .block or d == .none) display_block = true;
                }
            }
        }

        try opened_starts.append(arena, opened.items.len);
        try opened.appendSlice(arena, name);
        try stack.append(arena, fmt);
        if (tag.self_closing) {
            // `expand_empty_elements`: `<b/>` is a start immediately
            // followed by its end.
            _ = opened_starts.pop();
            opened.shrinkRetainingCapacity(opened.items.len - name.len);
            _ = stack.pop();
        }
    }

    if (opts.condense_white and opts.swf_version >= 8) {
        try condenseSwf8(arena, &text, &spans);
    }
    return .{ .text = text.items, .spans = spans.items };
}

/// `class="foo"` selects `.foo`, lowercased.
fn applyClass(st: StyleResolver, f: TextFormat, html: []const u16, tag: Tag) TextFormat {
    const cls = attr(html, tag, "class") orelse return f;
    var buf: [64]u16 = undefined;
    if (cls.len + 1 > buf.len) return f;
    buf[0] = '.';
    for (cls, 0..) |c, i| {
        buf[i + 1] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const style = st.lookup(st.ctx, st.sheet, buf[0 .. cls.len + 1]) orelse return f;
    return style.mixWith(f);
}

fn fontOf(tf: TextFormat) SpanFont {
    var s: TextSpan = .{};
    s.apply(tf);
    return s.font;
}

const Tag = struct {
    name: []const u16,
    is_end: bool,
    self_closing: bool,
    /// The attribute region, between the name and the closing `>`.
    attrs: []const u16,
    next: usize,
};

fn scanTag(html: []const u16, at: usize) ?Tag {
    var i = at + 1;
    var is_end = false;
    if (i < html.len and html[i] == '/') {
        is_end = true;
        i += 1;
    }
    const name_start = i;
    while (i < html.len and !isSpace(html[i]) and html[i] != '>' and html[i] != '/') i += 1;
    const name = html[name_start..i];
    const attr_start = i;
    // Quotes may legally contain '>'.
    var in_quote: u16 = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            continue;
        }
        if (c == '>') break;
    }
    if (i >= html.len) return null;
    var attrs = html[attr_start..i];
    var self_closing = false;
    if (attrs.len > 0 and attrs[attrs.len - 1] == '/') {
        self_closing = true;
        attrs = attrs[0 .. attrs.len - 1];
    }
    return .{
        .name = name,
        .is_end = is_end,
        .self_closing = self_closing,
        .attrs = attrs,
        .next = i + 1,
    };
}

/// An attribute's value, matched case-insensitively on the name.
fn attr(html: []const u16, tag: Tag, comptime name: []const u8) ?[]const u16 {
    _ = html;
    const a = tag.attrs;
    var i: usize = 0;
    while (i < a.len) {
        while (i < a.len and (isSpace(a[i]) or a[i] == '/')) i += 1;
        const ks = i;
        while (i < a.len and !isSpace(a[i]) and a[i] != '=') i += 1;
        const key = a[ks..i];
        while (i < a.len and isSpace(a[i])) i += 1;
        if (i < a.len and a[i] == '=') {
            i += 1;
            while (i < a.len and isSpace(a[i])) i += 1;
            var value: []const u16 = &.{};
            if (i < a.len and (a[i] == '"' or a[i] == '\'')) {
                const q = a[i];
                i += 1;
                const vs = i;
                while (i < a.len and a[i] != q) i += 1;
                value = a[vs..i];
                if (i < a.len) i += 1;
            } else {
                const vs = i;
                while (i < a.len and !isSpace(a[i])) i += 1;
                value = a[vs..i];
            }
            if (eqlAsciiIgnoreCase(key, name)) return value;
        } else if (key.len == 0) {
            i += 1;
        }
    }
    return null;
}

fn eqlAsciiIgnoreCase(a: []const u16, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(@intCast(x & 0x7F)) != std.ascii.toLower(y)) return false;
        if (x > 127) return false;
    }
    return true;
}

fn lowerAscii(buf: []u8, s: []const u16) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| {
        buf[i] = if (c < 128) std.ascii.toLower(@intCast(c)) else '?';
    }
    return buf[0..n];
}

fn isSpace(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isBlank(s: []const u16) bool {
    for (s) |c| {
        if (!isSpace(c)) return false;
    }
    return true;
}

/// `<FONT SIZE>`: a leading `+`/`-` makes it relative, digits stop at the
/// first non-digit (the decimal point included), and the result clamps.
fn applySize(fmt: *TextFormat, v: []const u16, swf_version: u8) void {
    var s = v;
    var sign: u8 = 0;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        sign = @intCast(s[0]);
        s = s[1..];
    }
    var n: usize = 0;
    while (n < s.len and s[n] >= '0' and s[n] <= '9') n += 1;
    if (n == 0) return;
    var value: f64 = 0;
    for (s[0..n]) |c| value = value * 10 + @as(f64, @floatFromInt(c - '0'));
    const base = fmt.size;
    const combined: ?f64 = switch (sign) {
        '+' => if (base) |b| b + value else null,
        '-' => if (base) |b| b - value else null,
        else => value,
    };
    const final = combined orelse return;
    fmt.size = if (swf_version < 13) std.math.clamp(final, 1.0, 127.0) else @max(final, 1.0);
}

/// `<FONT COLOR="#RRGGBB">`. Only the LAST six hex digits count, and the
/// alpha is dropped.
fn applyColor(fmt: *TextFormat, v: []const u16) void {
    if (v.len == 0 or v[0] != '#') return;
    var s = v[1..];
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    var end: usize = 0;
    while (end < s.len and isHex(s[end])) end += 1;
    const start = if (end > 6) end - 6 else 0;
    var rgb: u32 = 0;
    for (s[start..end]) |c| rgb = rgb * 16 + hexVal(c);
    if (end == start) return;
    fmt.color = rgb & 0x00FF_FFFF;
}

fn isHex(c: u16) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u16) u32 {
    if (c <= '9') return @intCast(c - '0');
    if (c <= 'F') return @intCast(c - 'A' + 10);
    return @intCast(c - 'a' + 10);
}

fn parseF64(v: []const u16) ?f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (v) |c| {
        if (c > 127 or n == buf.len) return null;
        buf[n] = @intCast(c);
        n += 1;
    }
    const t = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

fn parseStops(arena: std.mem.Allocator, v: []const u16) ![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    var i: usize = 0;
    while (i <= v.len) {
        const start = i;
        while (i < v.len and v[i] != ',') i += 1;
        if (parseF64(v[start..i])) |n| try out.append(arena, n);
        if (i >= v.len) break;
        i += 1;
    }
    return out.items;
}

/// The five named entities plus `&#nnn;` / `&#xhhh;`. An entity that does
/// not resolve is left in the text verbatim.
fn decodeEntities(arena: std.mem.Allocator, s: []const u16) ![]u16 {
    if (std.mem.indexOfScalar(u16, s, '&') == null) return @constCast(s);
    var out: std.ArrayList(u16) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u16, s, i + 1, ';') orelse {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        };
        const body = s[i + 1 .. semi];
        if (entityValue(body)) |c| {
            try out.append(arena, c);
            i = semi + 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn entityValue(body: []const u16) ?u16 {
    if (eqlAsciiIgnoreCase(body, "amp")) return '&';
    if (eqlAsciiIgnoreCase(body, "lt")) return '<';
    if (eqlAsciiIgnoreCase(body, "gt")) return '>';
    if (eqlAsciiIgnoreCase(body, "quot")) return '"';
    if (eqlAsciiIgnoreCase(body, "apos")) return '\'';
    if (eqlAsciiIgnoreCase(body, "nbsp")) return 0xA0;
    if (body.len >= 2 and body[0] == '#') {
        const hex = body[1] == 'x' or body[1] == 'X';
        var s = body[if (hex) 2 else 1..];
        while (s.len > 0 and isSpace(s[0])) s = s[1..];
        var n: u32 = 0;
        var digits: usize = 0;
        for (s) |c| {
            if (hex) {
                if (!isHex(c)) break;
                n = (n *% 16) +% hexVal(c);
            } else {
                if (c < '0' or c > '9') break;
                n = (n *% 10) +% @as(u32, c - '0');
            }
            digits += 1;
        }
        if (digits == 0) return null;
        // Flash wraps rather than rejects an out-of-range codepoint.
        return @truncate(n);
    }
    return null;
}

fn newlinesToCr(arena: std.mem.Allocator, s: []const u16) ![]u16 {
    var out = try arena.alloc(u16, s.len);
    for (s, 0..) |c, i| out[i] = if (c == '\n' or c == '\r') NEWLINE else c;
    return out;
}

/// Every run of whitespace becomes ONE space.
fn condenseWhite(arena: std.mem.Allocator, s: []const u16) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    var last_white = false;
    for (s) |c| {
        if (isSpace(c)) {
            if (!last_white) try out.append(arena, ' ');
            last_white = true;
        } else {
            try out.append(arena, c);
            last_white = false;
        }
    }
    return out.items;
}

/// From SWF8 the condensing runs again over the WHOLE text, across span
/// boundaries: a run of spaces collapses to one, and a run at either end
/// disappears entirely. A newline counts as a space for starting a run
/// but is itself preserved (ruffle `condense_white_swf8`).
fn condenseSwf8(
    arena: std.mem.Allocator,
    text: *std.ArrayList(u16),
    spans: *std.ArrayList(TextSpan),
) !void {
    const n = text.items.len;
    if (n == 0) return;
    const remove = try arena.alloc(bool, n);
    @memset(remove, false);
    var run_start: ?usize = 0;
    for (text.items, 0..) |ch, i| {
        const is_nl = ch == NEWLINE;
        const is_sp = ch == ' ';
        if (is_nl or !is_sp) {
            if (run_start) |st| {
                var k = st;
                while (k < i) : (k += 1) remove[k] = true;
            }
            run_start = null;
        }
        if ((is_nl or is_sp) and run_start == null) run_start = i + 1;
    }
    if (run_start) |st| {
        var k = st;
        while (k < n) : (k += 1) remove[k] = true;
    }

    var out: std.ArrayList(u16) = .empty;
    var span_i: usize = 0;
    var consumed: usize = 0;
    const kept = try arena.alloc(usize, spans.items.len);
    @memset(kept, 0);
    for (text.items, 0..) |c, i| {
        while (span_i < spans.items.len and consumed == spans.items[span_i].len) {
            span_i += 1;
            consumed = 0;
        }
        if (span_i < spans.items.len) consumed += 1;
        if (remove[i]) continue;
        try out.append(arena, c);
        if (span_i < kept.len) kept[span_i] += 1;
    }
    for (spans.items, 0..) |*s, i| s.len = kept[i];
    text.* = .empty;
    try text.appendSlice(arena, out.items);
}

// --- serialisation ------------------------------------------------------------

const HtmlTag = enum(u8) {
    textformat = 0,
    p = 1,
    li = 2,
    font = 3,
    a = 4,
    b = 5,
    i = 6,
    u = 7,
};

const Writer = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u16) = .empty,
    font_stack: std.ArrayList(SpanFont) = .empty,
    open: std.ArrayList(HtmlTag) = .empty,
    cur: TextSpan = .{},
    has_cur: bool = false,

    fn put(self: *Writer, s: []const u8) !void {
        for (s) |c| try self.out.append(self.arena, c);
    }

    fn putW(self: *Writer, s: []const u16) !void {
        try self.out.appendSlice(self.arena, s);
    }

    /// Flash prints a whole number without a decimal point and everything
    /// else with as few digits as round-trip.
    fn putNum(self: *Writer, v: f64) !void {
        var buf: [32]u8 = undefined;
        const s = if (v == @trunc(v) and @abs(v) < 1e15)
            try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))})
        else
            try std.fmt.bufPrint(&buf, "{d}", .{v});
        try self.put(s);
    }

    fn lastOpen(self: *const Writer) ?HtmlTag {
        if (self.open.items.len == 0) return null;
        return self.open.items[self.open.items.len - 1];
    }

    fn contains(self: *const Writer, t: HtmlTag) bool {
        for (self.open.items) |x| {
            if (x == t) return true;
        }
        return false;
    }

    fn setSpan(self: *Writer, span: TextSpan) !void {
        if (self.has_cur) {
            // Any style change closes every style tag; they reopen below.
            if (!span.style.eql(self.cur.style)) try self.closeTill(.b);
            if (!std.mem.eql(u16, span.url, self.cur.url)) try self.closeTill(.a);
        }
        try self.closeFontIfFeasible(span.font);
        self.cur = span;
        self.has_cur = true;

        if (span.left_margin != 0 or span.right_margin != 0 or span.indent != 0 or
            span.leading != 0 or span.block_indent != 0 or span.tab_stops.len > 0)
        {
            try self.openTag(.textformat);
        }
        if (!self.contains(.p) and !self.contains(.li)) {
            try self.openTag(if (span.bullet) .li else .p);
        }
        try self.setFont(span.font);
        if (span.url.len > 0) try self.openTag(.a);
        if (span.style.bold) try self.openTag(.b);
        if (span.style.italic) try self.openTag(.i);
        if (span.style.underline) try self.openTag(.u);
    }

    fn openTag(self: *Writer, tag: HtmlTag) !void {
        if (self.contains(tag)) return;
        // Tag order is fixed; one that would nest backwards is skipped.
        if (self.lastOpen()) |last| {
            if (@intFromEnum(last) > @intFromEnum(tag)) return;
        }
        try self.open.append(self.arena, tag);
        switch (tag) {
            .textformat => {
                try self.put("<TEXTFORMAT");
                if (self.cur.left_margin != 0) {
                    try self.put(" LEFTMARGIN=\"");
                    try self.putNum(self.cur.left_margin);
                    try self.put("\"");
                }
                if (self.cur.right_margin != 0) {
                    try self.put(" RIGHTMARGIN=\"");
                    try self.putNum(self.cur.right_margin);
                    try self.put("\"");
                }
                if (self.cur.indent != 0) {
                    try self.put(" INDENT=\"");
                    try self.putNum(self.cur.indent);
                    try self.put("\"");
                }
                if (self.cur.leading != 0) {
                    try self.put(" LEADING=\"");
                    try self.putNum(self.cur.leading);
                    try self.put("\"");
                }
                if (self.cur.block_indent != 0) {
                    try self.put(" BLOCKINDENT=\"");
                    try self.putNum(self.cur.block_indent);
                    try self.put("\"");
                }
                if (self.cur.tab_stops.len > 0) {
                    try self.put(" TABSTOPS=\"");
                    for (self.cur.tab_stops, 0..) |s, i| {
                        if (i > 0) try self.put(",");
                        try self.putNum(s);
                    }
                    try self.put("\"");
                }
                try self.put(">");
            },
            .p => {
                try self.put("<P ALIGN=\"");
                try self.put(switch (self.cur.text_align) {
                    .left => "LEFT",
                    .center => "CENTER",
                    .right => "RIGHT",
                    .justify => "JUSTIFY",
                });
                try self.put("\">");
            },
            .li => try self.put("<LI>"),
            .a => {
                try self.put("<A HREF=\"");
                try self.putW(self.cur.url);
                try self.put("\" TARGET=\"");
                try self.putW(self.cur.target);
                try self.put("\">");
            },
            .b => try self.put("<B>"),
            .i => try self.put("<I>"),
            .u => try self.put("<U>"),
            .font => unreachable,
        }
    }

    /// The FIRST `<FONT>` is fully specified; later ones list only what
    /// changed from the one below them on the stack.
    fn setFont(self: *Writer, font: SpanFont) !void {
        if (self.font_stack.items.len > 0) {
            const last = self.font_stack.items[self.font_stack.items.len - 1];
            if (last.eql(font)) return;
            try self.closeTill(.a);
            try self.put("<FONT");
            if (!std.mem.eql(u16, font.face, last.face)) {
                try self.put(" FACE=\"");
                try self.putW(font.face);
                try self.put("\"");
            }
            if (font.size != last.size) {
                try self.put(" SIZE=\"");
                try self.putNum(font.size);
                try self.put("\"");
            }
            if (font.color != last.color) try self.putColor(font.color);
            if (font.letter_spacing != last.letter_spacing) {
                try self.put(" LETTERSPACING=\"");
                try self.putNum(font.letter_spacing);
                try self.put("\"");
            }
            if (font.kerning != last.kerning) {
                try self.put(" KERNING=\"");
                try self.put(if (font.kerning) "1" else "0");
                try self.put("\"");
            }
            try self.put(">");
            try self.font_stack.append(self.arena, font);
            return;
        }
        try self.closeTill(.a);
        try self.put("<FONT FACE=\"");
        try self.putW(font.face);
        try self.put("\" SIZE=\"");
        try self.putNum(font.size);
        try self.put("\"");
        try self.putColor(font.color);
        try self.put(" LETTERSPACING=\"");
        try self.putNum(font.letter_spacing);
        try self.put("\" KERNING=\"");
        try self.put(if (font.kerning) "1" else "0");
        try self.put("\">");
        try self.font_stack.append(self.arena, font);
        try self.open.append(self.arena, .font);
    }

    fn putColor(self: *Writer, c: u32) !void {
        var buf: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, " COLOR=\"#{X:0>2}{X:0>2}{X:0>2}\"", .{
            (c >> 16) & 0xFF,
            (c >> 8) & 0xFF,
            c & 0xFF,
        });
        try self.put(s);
    }

    /// Reopening an ancestor font means closing back down to it.
    fn closeFontIfFeasible(self: *Writer, font: SpanFont) !void {
        var pos: ?usize = null;
        for (self.font_stack.items, 0..) |f, i| {
            if (f.eql(font)) {
                pos = i;
                break;
            }
        }
        const p = pos orelse return;
        if (p == self.font_stack.items.len - 1) return;
        try self.closeTill(.a);
        var n = self.font_stack.items.len - p - 1;
        while (n > 0) : (n -= 1) try self.put("</FONT>");
        self.font_stack.shrinkRetainingCapacity(p + 1);
    }

    fn closeTill(self: *Writer, tag: HtmlTag) !void {
        while (self.lastOpen()) |last| {
            if (@intFromEnum(last) < @intFromEnum(tag)) break;
            _ = self.open.pop();
            try self.closeTag(last);
        }
    }

    fn closeTag(self: *Writer, tag: HtmlTag) !void {
        if (tag == .font) {
            var n = self.font_stack.items.len;
            while (n > 0) : (n -= 1) try self.put("</FONT>");
            self.font_stack.clearRetainingCapacity();
            return;
        }
        try self.put(switch (tag) {
            .textformat => "</TEXTFORMAT>",
            .p => "</P>",
            .li => "</LI>",
            .a => "</A>",
            .b => "</B>",
            .i => "</I>",
            .u => "</U>",
            .font => unreachable,
        });
    }

    /// A newline CLOSES the paragraph rather than emitting `<BR>`: the
    /// run is split on it, every tag is closed and reopened between the
    /// pieces, and a TRAILING newline just closes.
    fn pushText(self: *Writer, text: []const u16) !void {
        var t = text;
        var ends_nl = false;
        if (t.len > 0 and isNewline(t[t.len - 1])) {
            t = t[0 .. t.len - 1];
            ends_nl = true;
        }
        var first = true;
        var i: usize = 0;
        while (true) {
            const start = i;
            while (i < t.len and !isNewline(t[i])) i += 1;
            if (!first) {
                try self.closeTill(.textformat);
                try self.setSpan(self.cur);
            }
            first = false;
            try self.pushLine(t[start..i]);
            if (i >= t.len) break;
            i += 1;
        }
        if (ends_nl) try self.closeTill(.textformat);
    }

    /// `&`, `<`, `>`, `"` and `'` are escaped on the way out.
    fn pushLine(self: *Writer, line: []const u16) !void {
        for (line) |c| switch (c) {
            '&' => try self.put("&amp;"),
            '<' => try self.put("&lt;"),
            '>' => try self.put("&gt;"),
            '"' => try self.put("&quot;"),
            '\'' => try self.put("&apos;"),
            else => try self.out.append(self.arena, c),
        };
    }
};

fn isNewline(c: u16) bool {
    return c == '\n' or c == '\r';
}

/// Serialise `text` + `spans` back to Flash's HTML. Empty text yields an
/// empty string — no wrapper tags at all.
pub fn serialize(
    arena: std.mem.Allocator,
    text: []const u16,
    spans: []const TextSpan,
) ![]const u16 {
    if (text.len == 0) return &.{};
    var w: Writer = .{ .arena = arena };
    var base: usize = 0;
    for (spans) |s| {
        const end = @min(base + s.len, text.len);
        if (base >= end and s.len != 0) break;
        try w.setSpan(s);
        try w.pushText(text[base..end]);
        base = end;
    }
    try w.closeTill(.textformat);
    return w.out.items;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn wide(a: std.mem.Allocator, s: []const u8) ![]u16 {
    const out = try a.alloc(u16, s.len);
    for (s, 0..) |c, i| out[i] = c;
    return out;
}

test "a bare paragraph parses to its text and one newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = try wide(a, "<P ALIGN=\"LEFT\">hi</P>");
    const r = try parse(a, html, .{ .size = 12 }, .{
        .multiline = true,
        .condense_white = false,
        .swf_version = 8,
    });
    try testing.expectEqual(@as(usize, 3), r.text.len);
    try testing.expectEqual(@as(u16, 'h'), r.text[0]);
    try testing.expectEqual(NEWLINE, r.text[2]);
}

test "entities decode, and an unknown one stays put" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try wide(a, "a&amp;b&#65;c&zzz;");
    const out = try decodeEntities(a, s);
    const expect = try wide(a, "a&bAc&zzz;");
    try testing.expectEqualSlices(u16, expect, out);
}

test "a relative font size adds to the one in force" {
    var f: TextFormat = .{ .size = 12 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    applySize(&f, try wide(arena.allocator(), "+3"), 8);
    try testing.expectEqual(@as(?f64, 15), f.size);
    applySize(&f, try wide(arena.allocator(), "200"), 8);
    try testing.expectEqual(@as(?f64, 127), f.size);
}
