//! `FormatSpans` — a field's text plus the runs of formatting over it.
//!
//! A `TextFormat` is tri-state (every property may be unset); a `TextSpan`
//! is the RESOLVED form, with a concrete value for everything. Spans carry
//! a LENGTH, not a range, and the invariant kept by `normalize` is that
//! the lengths sum to the text length, no span is empty, and no two
//! adjacent spans are identical.
//!
//! `getTextFormat` over a range merges the spans it touches, keeping only
//! the properties they agree on — which is why a range spanning two
//! colours reports `color == null`.
//!
//! Strings owned by a span (the face, the URL, the tab stops) live in this
//! struct's arena, so replacing the text is one reset rather than a walk.
//!
//! Reference: reference/ruffle/core/src/html/text_format.rs.

const std = @import("std");
const format_mod = @import("format.zig");

const TextFormat = format_mod.TextFormat;
pub const Align = format_mod.Align;
pub const Display = format_mod.Display;

pub const SpanFont = struct {
    face: []const u16 = &.{},
    size: f64 = 12.0,
    /// 0xAARRGGBB in SCRIPT order, and the default alpha is ZERO — the
    /// renderer supplies opacity, not the format.
    color: u32 = 0,
    letter_spacing: f64 = 0,
    kerning: bool = false,

    pub fn eql(a: SpanFont, b: SpanFont) bool {
        return std.mem.eql(u16, a.face, b.face) and
            a.size == b.size and a.color == b.color and
            a.letter_spacing == b.letter_spacing and a.kerning == b.kerning;
    }
};

pub const SpanStyle = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    pub fn eql(a: SpanStyle, b: SpanStyle) bool {
        return a.bold == b.bold and a.italic == b.italic and a.underline == b.underline;
    }
};

pub const TextSpan = struct {
    len: usize = 0,
    font: SpanFont = .{},
    style: SpanStyle = .{},
    text_align: Align = .left,
    left_margin: f64 = 0,
    right_margin: f64 = 0,
    indent: f64 = 0,
    block_indent: f64 = 0,
    leading: f64 = 0,
    tab_stops: []const f64 = &.{},
    bullet: bool = false,
    url: []const u16 = &.{},
    target: []const u16 = &.{},
    display: Display = .block,

    /// Everything but the length. Adjacent spans that agree merge.
    pub fn canMerge(a: TextSpan, b: TextSpan) bool {
        return a.font.eql(b.font) and a.style.eql(b.style) and
            a.text_align == b.text_align and
            a.left_margin == b.left_margin and a.right_margin == b.right_margin and
            a.indent == b.indent and a.block_indent == b.block_indent and
            a.leading == b.leading and std.mem.eql(f64, a.tab_stops, b.tab_stops) and
            a.bullet == b.bullet and
            std.mem.eql(u16, a.url, b.url) and std.mem.eql(u16, a.target, b.target) and
            a.display == b.display;
    }

    /// Apply the SET properties of `tf`, leaving the rest alone. An EMPTY
    /// font name is ignored rather than clearing the face.
    pub fn apply(self: *TextSpan, tf: TextFormat) void {
        if (tf.font) |f| if (f.len > 0) {
            self.font.face = f;
        };
        if (tf.size) |v| self.font.size = v;
        if (tf.color) |v| self.font.color = v;
        if (tf.kerning) |v| self.font.kerning = v;
        if (tf.letter_spacing) |v| self.font.letter_spacing = v;
        if (tf.text_align) |v| self.text_align = v;
        if (tf.bold) |v| self.style.bold = v;
        if (tf.italic) |v| self.style.italic = v;
        if (tf.underline) |v| self.style.underline = v;
        if (tf.left_margin) |v| self.left_margin = v;
        if (tf.right_margin) |v| self.right_margin = v;
        if (tf.indent) |v| self.indent = v;
        if (tf.block_indent) |v| self.block_indent = v;
        if (tf.leading) |v| self.leading = v;
        if (tf.tab_stops) |v| self.tab_stops = v;
        if (tf.bullet) |v| self.bullet = v;
        if (tf.url) |v| self.url = v;
        if (tf.target) |v| self.target = v;
        if (tf.display) |v| self.display = v;
    }

    /// The span as a fully-populated `TextFormat` — every property set,
    /// which is what `getTextFormat` on a single-span range reports.
    pub fn asFormat(self: TextSpan) TextFormat {
        return .{
            .font = self.font.face,
            .size = self.font.size,
            .color = self.font.color,
            .text_align = self.text_align,
            .bold = self.style.bold,
            .italic = self.style.italic,
            .underline = self.style.underline,
            .left_margin = self.left_margin,
            .right_margin = self.right_margin,
            .indent = self.indent,
            .block_indent = self.block_indent,
            .kerning = self.font.kerning,
            .leading = self.leading,
            .letter_spacing = self.font.letter_spacing,
            .tab_stops = self.tab_stops,
            .bullet = self.bullet,
            .url = self.url,
            .target = self.target,
            .display = self.display,
        };
    }

    pub fn fromFormat(tf: TextFormat, len: usize) TextSpan {
        var s: TextSpan = .{ .len = len };
        s.apply(tf);
        // Parsing HTML can only ever produce display:block, because the
        // property is applied while parsing rather than while styling.
        s.display = .block;
        return s;
    }
};

pub const Spans = struct {
    /// Owns every string a span points at.
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(TextSpan) = .empty,

    pub fn init(gpa: std.mem.Allocator) Spans {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Spans, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
        self.arena.deinit();
    }

    pub fn alloc(self: *Spans) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Drop everything and start again with one span covering `len`.
    pub fn reset(self: *Spans, gpa: std.mem.Allocator, tf: TextFormat, len: usize) !void {
        self.list.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const owned = try dupeFormat(self.alloc(), tf);
        try self.list.append(gpa, TextSpan.fromFormat(owned, len));
    }

    pub fn totalLen(self: *const Spans) usize {
        var n: usize = 0;
        for (self.list.items) |s| n += s.len;
        return n;
    }

    /// Restore the invariants: cover exactly `text_len`, no empty spans,
    /// no two identical neighbours.
    pub fn normalize(self: *Spans, gpa: std.mem.Allocator, tf: TextFormat, text_len: usize) !void {
        var total = self.totalLen();
        if (total < text_len) {
            const owned = try dupeFormat(self.alloc(), tf);
            try self.list.append(gpa, TextSpan.fromFormat(owned, text_len - total));
        } else if (total > text_len) {
            var over = total - text_len;
            while (over > 0 and self.list.items.len > 0) {
                const last = &self.list.items[self.list.items.len - 1];
                if (last.len > over) {
                    last.len -= over;
                    break;
                }
                over -= last.len;
                _ = self.list.pop();
            }
        }
        // A leading empty span has no neighbour to merge backwards into,
        // so it goes first and separately.
        while (self.list.items.len > 0 and self.list.items[0].len == 0) {
            _ = self.list.orderedRemove(0);
        }
        var i: usize = 0;
        while (self.list.items.len > 0 and i < self.list.items.len - 1) {
            const a = self.list.items[i];
            const b = self.list.items[i + 1];
            if (a.canMerge(b) or b.len == 0) {
                self.list.items[i].len += b.len;
                _ = self.list.orderedRemove(i + 1);
            } else {
                i += 1;
            }
        }
        if (self.list.items.len == 0) {
            const owned = try dupeFormat(self.alloc(), tf);
            try self.list.append(gpa, TextSpan.fromFormat(owned, text_len));
        }
        total = self.totalLen();
    }

    /// Split so that a span boundary falls exactly at `pos`.
    fn breakAt(self: *Spans, gpa: std.mem.Allocator, pos: usize) !void {
        var base: usize = 0;
        for (self.list.items, 0..) |s, i| {
            if (pos > base and pos < base + s.len) {
                var tail = s;
                tail.len = base + s.len - pos;
                self.list.items[i].len = pos - base;
                try self.list.insert(gpa, i + 1, tail);
                return;
            }
            base += s.len;
        }
    }

    /// The span indices covering `[from, to)`.
    fn boundaries(self: *const Spans, from: usize, to: usize) struct { start: usize, end: usize } {
        var base: usize = 0;
        var start: usize = self.list.items.len;
        var end: usize = self.list.items.len;
        for (self.list.items, 0..) |s, i| {
            if (start == self.list.items.len and base + s.len > from) start = i;
            if (base >= to) {
                end = i;
                break;
            }
            base += s.len;
        }
        if (start > end) start = end;
        return .{ .start = start, .end = end };
    }

    pub fn setFormat(
        self: *Spans,
        gpa: std.mem.Allocator,
        from: usize,
        to: usize,
        tf: TextFormat,
        default: TextFormat,
        text_len: usize,
    ) !void {
        try self.breakAt(gpa, from);
        try self.breakAt(gpa, to);
        const b = self.boundaries(from, to);
        const owned = try dupeFormat(self.alloc(), tf);
        for (self.list.items[b.start..b.end]) |*s| s.apply(owned);
        try self.normalize(gpa, default, text_len);
    }

    pub fn getFormat(self: *const Spans, from: usize, to: usize) TextFormat {
        const b = self.boundaries(from, to);
        if (b.start >= self.list.items.len) return .{};
        var merged = self.list.items[b.start].asFormat();
        var i = b.start + 1;
        while (i < b.end and i < self.list.items.len) : (i += 1) {
            merged = TextFormat.mergeMatching(merged, self.list.items[i].asFormat());
        }
        return merged;
    }

    /// The spans as (start, format) pairs for the layout engine.
    pub fn layoutSpans(self: *const Spans, gpa: std.mem.Allocator) ![]LayoutSpan {
        const out = try gpa.alloc(LayoutSpan, self.list.items.len);
        var base: usize = 0;
        for (self.list.items, 0..) |s, i| {
            out[i] = .{ .start = base, .format = s.asFormat() };
            base += s.len;
        }
        return out;
    }
};

pub const LayoutSpan = struct { start: usize, format: TextFormat };

/// Copy every string a format points at into `a`, so the span can outlive
/// whatever produced it.
pub fn dupeFormat(a: std.mem.Allocator, tf: TextFormat) !TextFormat {
    var out = tf;
    if (tf.font) |v| out.font = try a.dupe(u16, v);
    if (tf.url) |v| out.url = try a.dupe(u16, v);
    if (tf.target) |v| out.target = try a.dupe(u16, v);
    if (tf.tab_stops) |v| out.tab_stops = try a.dupe(f64, v);
    return out;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "normalize merges identical neighbours and covers the text" {
    var s = Spans.init(testing.allocator);
    defer s.deinit(testing.allocator);
    try s.list.append(testing.allocator, .{ .len = 3 });
    try s.list.append(testing.allocator, .{ .len = 2 });
    try s.normalize(testing.allocator, .{}, 5);
    try testing.expectEqual(@as(usize, 1), s.list.items.len);
    try testing.expectEqual(@as(usize, 5), s.list.items[0].len);
}

test "a range spanning two formats reports only what they share" {
    var s = Spans.init(testing.allocator);
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, .{ .size = 12 }, 6);
    try s.setFormat(testing.allocator, 0, 3, .{ .bold = true }, .{ .size = 12 }, 6);
    try testing.expectEqual(@as(usize, 2), s.list.items.len);
    try testing.expectEqual(@as(?bool, null), s.getFormat(0, 6).bold);
    try testing.expectEqual(@as(?bool, true), s.getFormat(0, 3).bold);
    try testing.expectEqual(@as(?f64, 12), s.getFormat(0, 6).size);
}
