//! A `DefineEditText` INSTANCE — a text field with mutable state.
//!
//! Unlike static text, a field is not a view onto the frozen tag: script
//! rewrites its text, its colours, its bounds and its format. So the
//! display object owns one of these, the way it owns a MovieClip or a
//! Button, and the tag is kept only as the defaults it was born with.
//!
//! Reference: reference/ruffle/core/src/display_object/edit_text.rs.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const format_mod = @import("../text/format.zig");
const library = @import("library.zig");
const text_layout = @import("text_layout.zig");
const spans_mod = @import("../text/spans.zig");
const html_mod = @import("../text/html.zig");

const Rectangle = swf.reader.Rectangle;
const TextFormat = format_mod.TextFormat;
const Tag = swf.font_text.EditText;

/// `autoSize`. Only `none` leaves the bounds alone; the others resize the
/// field to its content and pin a different edge.
pub const AutoSize = enum { none, left, center, right };

/// `gridFitType`. Purely reported today — nothing rasterises differently.
pub const GridFit = enum { none, pixel, subpixel };

/// The engine packs a colour ABGR (red in the low byte, matching the
/// order RGBA arrives in on the wire); script reads and writes 0xRRGGBB.
/// Every colour crossing the AVM1 boundary goes through these two.
pub fn rgbFromSwf(c: u32) u32 {
    return ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
}

pub fn swfFromRgb(rgb: u32, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
}

/// Immutable padding on all four sides of every text field, and it is
/// OBSERVABLE: two pixels of it turn up in `textWidth` vs `_width`, in
/// `getTextExtent`, and in where the first glyph sits (ruffle
/// edit_text.rs:257).
pub const GUTTER: i32 = text_layout.GUTTER;

pub const EditText = struct {
    /// The tag this was born from; null for `createTextField`.
    def: ?*const Tag,
    /// Live text, UCS-2, owned by the display allocator.
    text: std.ArrayList(u16) = .empty,
    /// The format new text inherits — `getNewTextFormat`'s answer.
    default_format: TextFormat = .{},
    /// The runs of formatting over `text`. Kept apart from
    /// `default_format`, which is what the NEXT character typed would
    /// take — that separation is why `setTextFormat` cannot move
    /// `textColor`.
    spans: spans_mod.Spans = undefined,
    /// UTF-16 copy of the embedded face's name, kept because
    /// `default_format.font` points into it and the tag's name is bytes.
    font_name: []u16 = &.{},
    /// Live bounds in the field's OWN space. `_x` and `_width` are read
    /// through these plus the placement matrix, not from the children.
    bounds: Rectangle,

    border: bool = false,
    background: bool = false,
    word_wrap: bool = false,
    multiline: bool = false,
    password: bool = false,
    read_only: bool = true,
    selectable: bool = true,
    html: bool = false,
    /// The SWF calls it `useOutlines`; script calls it `embedFonts`.
    use_outlines: bool = false,
    was_static: bool = false,
    condense_white: bool = false,
    mouse_wheel_enabled: bool = true,

    border_color: u32 = 0xFF000000,
    background_color: u32 = 0xFFFFFFFF,
    autosize: AutoSize = .none,
    /// 0 = unlimited. Script writes an i32 and Flash keeps the whole
    /// range, so this is NOT the tag's u16.
    max_chars: i32 = 0,
    /// The timeline variable this field mirrors (D7 wires the sync).
    /// Owned.
    variable: ?[]u16 = null,
    /// The allowed-character filter. Owned; null and "" are the same
    /// thing to AVM1.
    restrict: ?[]u16 = null,
    hscroll: f64 = 0,
    /// 1-based, like Flash's.
    scroll: u32 = 1,

    /// The laid-out lines, rebuilt lazily whenever anything that feeds
    /// layout changes.
    layout: text_layout.Layout = .empty,
    dirty: bool = true,
    /// Autosize resizes the box, but the new box is applied LAZILY — at
    /// the top of a render or a geometry read, never inside the setter
    /// that caused it. The ordering is observable: setting `autoSize`
    /// then `wordWrap` then `autoSize` again must not bake the first
    /// answer in (ruffle `apply_autosize_bounds`).
    autosize_lazy_bounds: ?Rectangle = null,

    /// The object this field's `variable` resolved to, or null while the
    /// field is on the unbound list.
    bound_to: ?*anyopaque = null,
    /// Guards the field -> variable direction against the write coming
    /// straight back (ruffle FIRING_VARIABLE_BINDING).
    firing_binding: bool = false,

    /// The AVM1 handle of the `TextField.StyleSheet` assigned to this
    /// field, or 0. Kept as an opaque number so `core/display` stays
    /// clear of the interpreter.
    style_sheet: u32 = 0,

    /// `CSMTextSettings`. Only `antiAliasType` switches engines; the other
    /// three are RETAINED across the switch, which is why they are stored
    /// flat rather than inside the variant (ruffle font.rs:1292-1470).
    advanced_rendering: bool = false,
    grid_fit: GridFit = .pixel,
    thickness: f64 = 0,
    sharpness: f64 = 0,

    pub fn fromTag(
        gpa: std.mem.Allocator,
        def: *const Tag,
        lib: *const library.Library,
        swf_version: u8,
    ) !EditText {
        var self: EditText = .{
            .def = def,
            .bounds = def.bounds,
            .border = def.border,
            // The tag has one bit for both, and they diverge from here on.
            .background = def.border,
            .word_wrap = def.word_wrap,
            .multiline = def.multiline,
            .password = def.password,
            .read_only = def.read_only,
            .selectable = !def.no_select,
            .html = def.is_html,
            .use_outlines = def.use_outlines,
            .was_static = def.was_static,
            .autosize = if (def.auto_size) .left else .none,
            .max_chars = @intCast(def.max_length orelse 0),
        };
        const font = if (def.font_id) |fid| lib.getFont(fid) else null;
        // The face NAME, not the id: a field resolves its font the same
        // way `<font face="…">` does. With no embedded font behind the id
        // Flash names the face "Times New Roman" and then fails to find
        // it, which is why an unfontted field measures zero.
        const face: []const u8 = def.font_class orelse
            if (font) |f| f.name else "Times New Roman";
        self.font_name = try utf16(gpa, face);
        // With HTML on, the tag's alignment is IGNORED and left wins —
        // except from SWF8 when there is initial text to align (ruffle
        // text_format.rs:210-217). Turning HTML on from script later does
        // not do this.
        const html_forces_left = def.is_html and (swf_version < 8 or def.initial_text == null);
        self.default_format = .{
            .font = self.font_name,
            // Every measurement is in PIXELS from here on, and a field
            // with no font at all still defaults to 12.
            .size = if (def.font_id != null or def.font_class != null)
                px(def.height)
            else
                12.0,
            // ALPHA IS DROPPED and the channels are put in SCRIPT order:
            // `getTextFormat().color` on a fresh black field is 0, not
            // 0xFF000000 (ruffle `Color::from_rgb(c.to_rgb(), 0)`).
            .color = rgbFromSwf(def.color),
            .text_align = if (html_forces_left) .left else switch (def.align_h) {
                .left => .left,
                .center => .center,
                .right => .right,
                .justify => .justify,
                .invalid => .left,
            },
            // An HTML field reports its face as neither bold nor italic
            // whatever the embedded font says; the markup carries it.
            .bold = if (def.is_html) false else if (font) |f| f.is_bold else false,
            .italic = if (def.is_html) false else if (font) |f| f.is_italic else false,
            .underline = false,
            .display = .block,
            .left_margin = px(def.left_margin),
            .right_margin = px(def.right_margin),
            .indent = @round(px(def.indent)),
            .block_indent = 0,
            .kerning = false,
            .leading = px(def.leading),
            .letter_spacing = 0,
            .tab_stops = &.{},
            .bullet = false,
            .url = &.{},
            .target = &.{},
        };
        self.spans = spans_mod.Spans.init(gpa);
        try self.spans.reset(gpa, self.default_format, 0);
        if (def.variable_name.len > 0) {
            var buf: std.ArrayList(u16) = .empty;
            for (def.variable_name) |c| try buf.append(gpa, c);
            self.variable = try buf.toOwnedSlice(gpa);
        }
        if (def.initial_text) |t| {
            var wide: std.ArrayList(u16) = .empty;
            defer wide.deinit(gpa);
            for (t) |c| try wide.append(gpa, c);
            // The AUTHORED text is markup when the field is HTML — a
            // Flash-authored HTML field is born holding a whole
            // <P>…</P>, and `text` must report what it says, not what it
            // is written in.
            if (def.is_html) {
                try self.setHtml(gpa, wide.items, swf_version);
            } else {
                try self.setText(gpa, wide.items);
            }
        }
        return self;
    }

    /// `createTextField` — ruffle's `EditText::new`: 12px black text, read
    /// only, selectable, and bounds anchored at the ORIGIN with the
    /// position carried by the placement matrix instead.
    pub fn dynamic(gpa: std.mem.Allocator, width: f64, height: f64) !EditText {
        var self: EditText = .{
            .def = null,
            .bounds = .{
                .xmin = 0,
                .ymin = 0,
                .xmax = twips(width),
                .ymax = twips(height),
            },
            .read_only = true,
            .selectable = true,
            .default_format = dynamicFormat(),
        };
        self.spans = spans_mod.Spans.init(gpa);
        try self.spans.reset(gpa, self.default_format, 0);
        return self;
    }

    pub fn deinit(self: *EditText, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.spans.deinit(gpa);
        self.layout.deinit(gpa);
        gpa.free(self.font_name);
        if (self.variable) |v| gpa.free(v);
        if (self.restrict) |v| gpa.free(v);
    }

    pub fn setVariable(self: *EditText, gpa: std.mem.Allocator, s: ?[]const u16) !void {
        if (self.variable) |v| gpa.free(v);
        self.variable = if (s) |x| try gpa.dupe(u16, x) else null;
    }

    pub fn setRestrict(self: *EditText, gpa: std.mem.Allocator, s: ?[]const u16) !void {
        if (self.restrict) |v| gpa.free(v);
        self.restrict = if (s) |x| try gpa.dupe(u16, x) else null;
    }

    /// Plain text: the whole field takes the new-text format again.
    /// A write of the SAME string is a no-op, and that is observable —
    /// it skips the format reset (ruffle `set_text`).
    pub fn setText(self: *EditText, gpa: std.mem.Allocator, s: []const u16) !void {
        if (std.mem.eql(u16, self.text.items, s)) return;
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, s);
        try self.spans.reset(gpa, self.default_format, s.len);
        self.dirty = true;
    }

    /// `htmlText = …` on an HTML field: parse the markup into text and
    /// spans. On a plain field it is an ordinary text write.
    pub fn setHtml(
        self: *EditText,
        gpa: std.mem.Allocator,
        markup: []const u16,
        swf_version: u8,
    ) !void {
        if (!self.html) return self.setText(gpa, markup);
        // Parsing HTML below SWF8 leaves the field LEFT-aligned for good:
        // `from_html` rewrites the default format it was handed and the
        // field keeps the rewritten one (corpus edittext_html_align_swf7).
        if (swf_version < 8) self.default_format.text_align = .left;
        self.spans.list.clearRetainingCapacity();
        _ = self.spans.arena.reset(.retain_capacity);
        const a = self.spans.alloc();
        const owned_default = try spans_mod.dupeFormat(a, self.default_format);
        const parsed = try html_mod.parse(a, markup, owned_default, .{
            .multiline = self.multiline,
            .condense_white = self.condense_white,
            .swf_version = swf_version,
        });
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, parsed.text);
        try self.spans.list.appendSlice(gpa, parsed.spans);
        try self.spans.normalize(gpa, owned_default, self.text.items.len);
        self.dirty = true;
    }

    /// The field's contents AS MARKUP. A non-HTML field still serialises
    /// — `htmlText` on a plain field reports the generated tags.
    pub fn htmlText(self: *const EditText, arena: std.mem.Allocator) ![]const u16 {
        return html_mod.serialize(arena, self.text.items, self.spans.list.items);
    }

    pub fn setFormatRange(
        self: *EditText,
        gpa: std.mem.Allocator,
        from: usize,
        to: usize,
        tf: TextFormat,
    ) !void {
        try self.spans.setFormat(gpa, from, to, tf, self.default_format, self.text.items.len);
        self.dirty = true;
    }

    pub fn formatRange(self: *const EditText, from: usize, to: usize) TextFormat {
        return self.spans.getFormat(from, to);
    }

    /// Splice `with` into `[from, to)`. The replacement takes the format
    /// of the run it landed in.
    pub fn replaceRange(
        self: *EditText,
        gpa: std.mem.Allocator,
        from_in: usize,
        to_in: usize,
        with: []const u16,
    ) !void {
        const len = self.text.items.len;
        const to = @min(to_in, len);
        const from = @min(from_in, to);
        const fmt = self.spans.getFormat(from, @max(to, from + 1));
        var out: std.ArrayList(u16) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, self.text.items[0..from]);
        try out.appendSlice(gpa, with);
        try out.appendSlice(gpa, self.text.items[to..]);
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, out.items);
        // Rebuild the span list around the splice: everything before,
        // one run for the insertion, everything after.
        try rebuildSpans(self, gpa, from, to, with.len, fmt);
        self.dirty = true;
    }

    /// Rebuild the layout if anything has changed since the last one.
    pub fn ensureLayout(
        self: *EditText,
        gpa: std.mem.Allocator,
        lib: *const library.Library,
        swf_version: u8,
    ) !void {
        if (!self.dirty) return;
        self.dirty = false;
        try self.relayout(gpa, lib, swf_version);
    }

    fn relayout(
        self: *EditText,
        gpa: std.mem.Allocator,
        lib: *const library.Library,
        swf_version: u8,
    ) !void {
        const padding = GUTTER * 2;
        // An autosizing field that does NOT wrap has no width to lay out
        // against — it finds its own.
        const content_width: ?i32 = if (self.autosize == .none or self.word_wrap)
            self.bounds.width() - padding
        else
            null;

        // A password field lays out asterisks, so its width is the width
        // of the mask rather than of the secret.
        var masked: ?[]u16 = null;
        defer if (masked) |m| gpa.free(m);
        var shown: []const u16 = self.text.items;
        if (self.password) {
            const m = try gpa.alloc(u16, self.text.items.len);
            @memset(m, '*');
            masked = m;
            shown = m;
        }

        const laid = try self.spans.layoutSpans(gpa);
        defer gpa.free(laid);
        var conv = try gpa.alloc(text_layout.Span, laid.len);
        defer gpa.free(conv);
        for (laid, 0..) |l, i| conv[i] = .{ .start = l.start, .format = l.format };
        const fresh = try text_layout.layOut(gpa, lib, shown, conv, .{
            .width = content_width,
            .is_input = !self.read_only,
            .word_wrap = self.word_wrap,
            .embedded = self.use_outlines,
            .swf_version = swf_version,
        });
        self.layout.deinit(gpa);
        self.layout = fresh;
        self.hscroll = 0;
        self.scroll = 1;

        if (self.autosize == .none) {
            self.autosize_lazy_bounds = null;
            return;
        }
        var box = self.bounds;
        if (!self.word_wrap) {
            var w = fresh.text_width + padding;
            // An EDITABLE field gets 2.5px more, room for the caret.
            if (!self.read_only) w += 50;
            box.xmin = switch (self.autosize) {
                .left, .none => box.xmin,
                .center => @divTrunc(box.xmin + box.xmax - w, 2),
                .right => box.xmax - w,
            };
            box.xmax = box.xmin +% w;
        }
        box.ymax = box.ymin +% (fresh.text_height + padding);
        self.autosize_lazy_bounds = box;
    }

    /// Take the pending autosize box, if any. Called at the top of every
    /// render and every geometry read — never from a setter.
    pub fn applyAutosizeBounds(self: *EditText) void {
        if (self.autosize_lazy_bounds) |b| {
            self.bounds = b;
            self.autosize_lazy_bounds = null;
        }
    }

};

fn rebuildSpans(
    self: *EditText,
    gpa: std.mem.Allocator,
    from: usize,
    to: usize,
    inserted: usize,
    fmt: TextFormat,
) !void {
    var out: std.ArrayList(spans_mod.TextSpan) = .empty;
    defer out.deinit(gpa);
    var base: usize = 0;
    for (self.spans.list.items) |sp| {
        const lo = base;
        const hi = base + sp.len;
        base = hi;
        // The part of this run before the splice.
        if (lo < from) {
            var head = sp;
            head.len = @min(hi, from) - lo;
            if (head.len > 0) try out.append(gpa, head);
        }
        // The part after it.
        if (hi > to) {
            var tail = sp;
            tail.len = hi - @max(lo, to);
            if (tail.len > 0) try out.append(gpa, tail);
        }
    }
    // The insertion goes at the splice point, in the format of the run it
    // replaced.
    var run = spans_mod.TextSpan.fromFormat(try spans_mod.dupeFormat(self.spans.alloc(), fmt), inserted);
    run.len = inserted;
    var placed: std.ArrayList(spans_mod.TextSpan) = .empty;
    defer placed.deinit(gpa);
    var cursor: usize = 0;
    var done = false;
    for (out.items) |sp| {
        if (!done and cursor >= from) {
            try placed.append(gpa, run);
            done = true;
        }
        try placed.append(gpa, sp);
        cursor += sp.len;
    }
    if (!done) try placed.append(gpa, run);
    self.spans.list.clearRetainingCapacity();
    try self.spans.list.appendSlice(gpa, placed.items);
    try self.spans.normalize(gpa, self.default_format, self.text.items.len);
}

/// `EditText::new`'s tag: font id 0 at 12px, black, no layout. The face
/// resolves to nothing, which is correct — a dynamic field has no
/// embedded font until script gives it one.
fn dynamicFormat() TextFormat {
    return .{
        .font = &.{},
        .size = 12.0,
        .color = 0,
        .text_align = .left,
        .bold = false,
        .italic = false,
        .underline = false,
        .display = .block,
        .left_margin = 0,
        .right_margin = 0,
        .indent = 0,
        .block_indent = 0,
        .kerning = false,
        .leading = 0,
        .letter_spacing = 0,
        .tab_stops = &.{},
        .bullet = false,
        .url = &.{},
        .target = &.{},
    };
}

fn utf16(gpa: std.mem.Allocator, s: []const u8) ![]u16 {
    const out = try gpa.alloc(u16, s.len);
    for (s, out) |c, *o| o.* = c;
    return out;
}

fn px(t: anytype) f64 {
    return @as(f64, @floatFromInt(t)) / @as(f64, swf.reader.TWIPS_PER_PX);
}

fn twips(v: f64) i32 {
    return @intFromFloat(@trunc(v * @as(f64, swf.reader.TWIPS_PER_PX)));
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "a dynamic field is 12px black, read-only and anchored at the origin" {
    var et = try EditText.dynamic(testing.allocator, 100, 20);
    defer et.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 0), et.bounds.xmin);
    try testing.expectEqual(@as(i32, 2000), et.bounds.xmax);
    try testing.expectEqual(@as(i32, 400), et.bounds.ymax);
    try testing.expectEqual(@as(?f64, 12), et.default_format.size);
    try testing.expect(et.read_only);
    try testing.expect(et.selectable);
}
