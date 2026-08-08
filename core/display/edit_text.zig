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
const font_mod = @import("font.zig");
const spans_mod = @import("../text/spans.zig");
const html_mod = @import("../text/html.zig");

const Rectangle = swf.reader.Rectangle;
const TextFormat = format_mod.TextFormat;
const Tag = swf.font_text.EditText;

/// `autoSize`. Only `none` leaves the bounds alone; the others resize the
/// field to its content and pin a different edge.
pub const AutoSize = enum { none, left, center, right };

/// A selection, or just a caret when `from == to`. `from` is where the
/// user STARTED and `to` is where the caret is now, so `from` may be the
/// larger of the two — a right-to-left drag.
pub const Selection = struct {
    from: usize,
    to: usize,

    pub fn at(pos: usize) Selection {
        return .{ .from = pos, .to = pos };
    }

    pub fn start(self: Selection) usize {
        return @min(self.from, self.to);
    }

    pub fn end(self: Selection) usize {
        return @max(self.from, self.to);
    }

    pub fn isCaret(self: Selection) bool {
        return self.from == self.to;
    }

    pub fn clamped(self: Selection, len: usize) Selection {
        return .{ .from = @min(self.from, len), .to = @min(self.to, len) };
    }
};

/// The editing commands the host can send to the focused field. The
/// names are ruffle's `TextControlCode`, which is in turn the set the
/// conformance corpus's `input.json` uses.
pub const Control = enum {
    move_left,
    move_left_word,
    move_left_line,
    move_left_document,
    move_right,
    move_right_word,
    move_right_line,
    move_right_document,
    select_left,
    select_left_word,
    select_left_line,
    select_left_document,
    select_right,
    select_right_word,
    select_right_line,
    select_right_document,
    select_all,
    copy,
    paste,
    cut,
    backspace,
    backspace_word,
    enter,
    delete,
    delete_word,

    /// The commands that CHANGE the text; a read-only field ignores
    /// exactly these and honours the rest.
    pub fn isEdit(self: Control) bool {
        return switch (self) {
            .paste, .cut, .enter, .backspace, .backspace_word, .delete, .delete_word => true,
            else => false,
        };
    }

    fn isSelect(self: Control) bool {
        return switch (self) {
            .select_left, .select_left_word, .select_left_line, .select_left_document, .select_right, .select_right_word, .select_right_line, .select_right_document, .select_all => true,
            else => false,
        };
    }
};

/// An in-flight IME composition. The preedit text sits IN the field
/// (that is what makes it visible) and is replaced wholesale by each new
/// preedit; committing simply stops tracking it and types it for real.
pub const Ime = struct {
    start: usize,
    end: usize,
    /// The last preedit string, kept so a COMMIT can re-type it as
    /// ordinary input — which is what fires `onChanged`.
    text: []u16,
};

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

    /// Null when the field is not focused: AVM1 clears the selection on
    /// focus loss, and every index query answers -1 without one.
    selection: ?Selection = null,
    /// Where the last click landed. A drag selects from HERE to wherever
    /// the pointer is now, so the anchor has to outlive the press.
    click_anchor: ?usize = null,
    /// The IME composition in progress: the range it occupies in the text
    /// and the string it last produced. Null when nothing is composing.
    ime: ?Ime = null,

    /// The object this field's `variable` resolved to, or null while the
    /// field is on the unbound list.
    bound_to: ?*anyopaque = null,
    /// Guards the field -> variable direction against the write coming
    /// straight back (ruffle FIRING_VARIABLE_BINDING).
    firing_binding: bool = false,

    /// The AVM1 handles of the filters set on this field, in order. The
    /// filter's EFFECT is M7; the list is stored and reported because
    /// script reads it back (and a clone must NOT inherit it).
    filters: std.ArrayList(u32) = .empty,

    /// The `TextField.StyleSheet` assigned to this field, or null. It is
    /// a callback rather than a type because the sheet lives in the
    /// interpreter (M4-D8).
    styles: ?html_mod.StyleResolver = null,
    /// The markup a styled field was last given, VERBATIM. A field with a
    /// style sheet reports that string back from `htmlText` instead of
    /// re-serialising, and re-parses it when the sheet changes.
    original_html: ?[]u16 = null,

    /// `CSMTextSettings`. Only `antiAliasType` switches engines; the other
    /// three are RETAINED across the switch, which is why they are stored
    /// flat rather than inside the variant (ruffle font.rs:1292-1470).
    /// The SWF version the last parse ran at, so a re-parse triggered by
    /// a style-sheet change uses the same rules.
    parse_version: u8 = 8,

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
        // The field's anti-aliasing comes from a SEPARATE tag that may
        // sit on either side of the DefineEditText.
        if (lib.csm.get(def.id)) |c| {
            self.advanced_rendering = c.use_advanced_rendering;
            self.grid_fit = switch (c.grid_fit) {
                0 => .none,
                1 => .pixel,
                else => .subpixel,
            };
            self.thickness = c.thickness;
            self.sharpness = c.sharpness;
        }
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
        if (self.original_html) |h| gpa.free(h);
        if (self.ime) |d| gpa.free(d.text);
        self.filters.deinit(gpa);
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

    /// A field is HTML if its flag says so OR it has a style sheet —
    /// setting CSS does not turn the flag on, but it does turn the
    /// behaviour on.
    pub fn isEffectivelyHtml(self: *const EditText) bool {
        return self.html or self.styles != null;
    }

    /// Plain text: the whole field takes the new-text format again.
    /// A write of the SAME string is a no-op, and that is observable —
    /// it skips the format reset (ruffle `set_text`).
    ///
    /// With CSS set, even a plain `text =` is parsed as MARKUP.
    pub fn setText(self: *EditText, gpa: std.mem.Allocator, s: []const u16) !void {
        if (std.mem.eql(u16, self.text.items, s)) return;
        if (self.styles != null) return self.parseHtml(gpa, s, self.parse_version);
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, s);
        try self.spans.reset(gpa, self.default_format, s.len);
        self.dirty = true;
    }

    /// Assign or drop the style sheet. Dropping it forgets the original
    /// markup; assigning one re-parses whatever markup is remembered.
    pub fn setStyleSheet(
        self: *EditText,
        gpa: std.mem.Allocator,
        resolver: ?html_mod.StyleResolver,
        swf_version: u8,
    ) !void {
        self.styles = resolver;
        self.parse_version = swf_version;
        if (resolver == null) {
            if (self.original_html) |h| gpa.free(h);
            self.original_html = null;
            self.dirty = true;
            return;
        }
        if (self.original_html) |h| {
            const copy = try gpa.dupe(u16, h);
            defer gpa.free(copy);
            try self.parseHtml(gpa, copy, swf_version);
        }
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
        if (!self.isEffectivelyHtml()) return self.setText(gpa, markup);
        try self.parseHtml(gpa, markup, swf_version);
    }

    fn parseHtml(
        self: *EditText,
        gpa: std.mem.Allocator,
        markup: []const u16,
        swf_version: u8,
    ) !void {
        // Parsing HTML below SWF8 leaves the field LEFT-aligned for good:
        // `from_html` rewrites the default format it was handed and the
        // field keeps the rewritten one (corpus edittext_html_align_swf7).
        if (swf_version < 8) self.default_format.text_align = .left;
        self.parse_version = swf_version;
        // The markup is remembered ONLY while a style sheet is set: it is
        // what `htmlText` reports and what a change of sheet re-parses.
        const remembered = if (self.styles != null) try gpa.dupe(u16, markup) else null;
        if (self.original_html) |h| gpa.free(h);
        self.original_html = remembered;

        self.spans.list.clearRetainingCapacity();
        _ = self.spans.arena.reset(.retain_capacity);
        const a = self.spans.alloc();
        const owned_default = try spans_mod.dupeFormat(a, self.default_format);
        const parsed = try html_mod.parse(a, markup, owned_default, .{
            .multiline = self.multiline,
            .condense_white = self.condense_white,
            .swf_version = swf_version,
            .styles = self.styles,
        });
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, parsed.text);
        try self.spans.list.appendSlice(gpa, parsed.spans);
        try self.spans.normalize(gpa, owned_default, self.text.items.len);
        self.dirty = true;
    }

    /// The field's contents AS MARKUP: the string it was GIVEN when a
    /// style sheet is set, and the re-serialised spans otherwise.
    pub fn htmlText(self: *const EditText, arena: std.mem.Allocator) ![]const u16 {
        if (self.original_html) |h| return h;
        return html_mod.serialize(arena, self.text.items, self.spans.list.items);
    }

    pub fn setSelection(self: *EditText, sel: ?Selection) void {
        self.selection = if (sel) |x| x.clamped(self.text.items.len) else null;
    }

    /// How many more characters `maxChars` allows, counting the selection
    /// about to be replaced as already free.
    fn availableChars(self: *const EditText) usize {
        if (self.max_chars == 0) return std.math.maxInt(usize);
        const text_len: i64 = @intCast(self.text.items.len);
        const sel_len: i64 = if (self.selection) |s| @intCast(s.end() - s.start()) else 0;
        const room = @max(self.max_chars, 0) - (text_len - sel_len);
        return if (room <= 0) 0 else @intCast(room);
    }

    /// Type `input` over the selection. Control characters other than a
    /// newline never make it in, a single-line field drops newlines
    /// entirely, and `restrict` filters what is left.
    ///
    /// Returns whether the text actually changed, so the caller knows
    /// whether to fire `onChanged` and push the variable binding.
    pub fn textInput(self: *EditText, gpa: std.mem.Allocator, input: []const u16) !bool {
        if (self.read_only or self.availableChars() == 0) return false;
        const sel = self.selection orelse return false;

        var filtered: std.ArrayList(u16) = .empty;
        defer filtered.deinit(gpa);
        for (input) |c| {
            const newline = c == '\n' or c == '\r';
            if (newline and !self.multiline) continue;
            if (c < 0x20 and !newline) continue;
            const kept = self.toAllowed(c) orelse continue;
            try filtered.append(gpa, if (newline) '\r' else kept);
        }
        if (filtered.items.len == 0) return false;
        const room = self.availableChars();
        const text = filtered.items[0..@min(filtered.items.len, room)];
        try self.replaceRange(gpa, sel.start(), sel.end(), text);
        self.setSelection(Selection.at(sel.start() + text.len));
        return true;
    }

    /// A character as `restrict` will take it — CONVERTING its case when
    /// only the other case is allowed. That is why pasting "aAbB" into a
    /// field restricted to "bc" yields "bb", not "b".
    fn toAllowed(self: *const EditText, c: u16) ?u16 {
        if (self.restrict == null) return c;
        if (self.allows(c)) return c;
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (upper != c and self.allows(upper)) return upper;
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower != c and self.allows(lower)) return lower;
        return null;
    }

    /// `restrict` as Flash actually parses it: a token stream of chars,
    /// `^` and `-`, folded into ALLOW and DENY interval lists.
    ///
    /// The corner cases are the whole point of the corpus dir:
    ///
    ///   - `\\` escapes the NEXT character whatever it is (`\\a` is `a`),
    ///     and a trailing backslash is ignored;
    ///   - `^` SWITCHES between allowing and denying rather than only
    ///     starting a deny list, and a leading one means "all, except";
    ///   - `-z` is `\0-z`, `a-` is just `a`, and an inverted `z-a` is
    ///     just `z`.
    fn allows(self: *const EditText, c: u16) bool {
        const r = self.restrict orelse return true;
        var allowed: [64][2]u16 = undefined;
        var na: usize = 0;
        var denied: [64][2]u16 = undefined;
        var nd: usize = 0;
        var cur: [64][2]u16 = undefined;
        var nc: usize = 0;
        var last: ?u16 = null;
        var allowing = true;

        var i: usize = 0;
        while (i < r.len) {
            const t = r[i];
            i += 1;
            if (t == '\\') {
                if (i >= r.len) break;
                const e = r[i];
                i += 1;
                if (nc < cur.len) {
                    cur[nc] = .{ e, e };
                    nc += 1;
                }
                last = e;
            } else if (t == '^') {
                if (allowing) {
                    if (nc == 0 and na == 0) {
                        allowed[0] = .{ 0, 0xFFFF };
                        na = 1;
                    } else {
                        na = append(&allowed, na, cur[0..nc]);
                    }
                } else {
                    nd = append(&denied, nd, cur[0..nc]);
                }
                nc = 0;
                allowing = !allowing;
                last = null;
            } else if (t == '-') {
                var start: u16 = 0;
                if (last) |lc| {
                    if (nc > 0) nc -= 1;
                    start = lc;
                }
                var end = start;
                if (i < r.len) {
                    if (r[i] == '\\' and i + 1 < r.len) {
                        end = r[i + 1];
                        i += 2;
                    } else if (r[i] != '^' and r[i] != '-') {
                        end = r[i];
                        i += 1;
                    }
                }
                if (nc < cur.len) {
                    cur[nc] = .{ start, @max(end, start) };
                    nc += 1;
                }
                last = null;
            } else {
                if (nc < cur.len) {
                    cur[nc] = .{ t, t };
                    nc += 1;
                }
                last = t;
            }
        }
        if (allowing) {
            na = append(&allowed, na, cur[0..nc]);
        } else {
            nd = append(&denied, nd, cur[0..nc]);
        }
        return inAny(allowed[0..na], c) and !inAny(denied[0..nd], c);
    }

    /// Apply an editing command. Returns whether the TEXT changed.
    pub fn textControl(self: *EditText, gpa: std.mem.Allocator, code: Control, clipboard: *std.ArrayList(u16)) !bool {
        if (self.read_only and code.isEdit()) return false;
        const sel = self.selection orelse return false;
        if (code.isSelect() and !self.selectable) return false;
        // Neither Copy nor Cut touches a PASSWORD field at all — Cut does
        // not even delete — and neither does anything with no selection
        // to act on (ruffle `is_text_control_applicable`).
        if ((code == .copy or code == .cut) and (self.password or sel.isCaret())) return false;
        const len = self.text.items.len;

        switch (code) {
            .enter => return self.textInput(gpa, &[_]u16{'\r'}),
            .move_left, .move_left_word, .move_left_line, .move_left_document => {
                const pos = if (sel.isCaret()) self.newPosition(code, sel.to) else sel.start();
                self.setSelection(Selection.at(pos));
            },
            .move_right, .move_right_word, .move_right_line, .move_right_document => {
                const pos = if (sel.isCaret() and sel.to < len)
                    self.newPosition(code, sel.to)
                else
                    sel.end();
                self.setSelection(Selection.at(pos));
            },
            .select_left, .select_left_word, .select_left_line, .select_left_document => {
                if (sel.to > 0) self.setSelection(.{ .from = sel.from, .to = self.newPosition(code, sel.to) });
            },
            .select_right, .select_right_word, .select_right_line, .select_right_document => {
                if (sel.to < len) self.setSelection(.{ .from = sel.from, .to = self.newPosition(code, sel.to) });
            },
            .select_all => self.setSelection(.{ .from = 0, .to = len }),
            .copy => {
                clipboard.clearRetainingCapacity();
                try clipboard.appendSlice(gpa, self.text.items[sel.start()..sel.end()]);
            },
            .paste => {
                // An EMPTY clipboard pastes nothing AND leaves the
                // selection intact; a clipboard with no allowed
                // characters still deletes it.
                if (clipboard.items.len == 0) return false;
                return self.textInput(gpa, clipboard.items);
            },
            .cut => {
                clipboard.clearRetainingCapacity();
                try clipboard.appendSlice(gpa, self.text.items[sel.start()..sel.end()]);
                try self.replaceRange(gpa, sel.start(), sel.end(), &.{});
                self.setSelection(Selection.at(if (self.selectable) sel.start() else self.text.items.len));
                return true;
            },
            .backspace, .backspace_word, .delete, .delete_word => {
                if (!sel.isCaret()) {
                    try self.replaceRange(gpa, sel.start(), sel.end(), &.{});
                    self.setSelection(Selection.at(sel.start()));
                    return true;
                }
                if (code == .backspace or code == .backspace_word) {
                    if (sel.start() == 0) return false;
                    const start = self.newPosition(code, sel.start());
                    try self.replaceRange(gpa, start, sel.start(), &.{});
                    self.setSelection(Selection.at(start));
                    return true;
                }
                if (sel.end() >= len) return false;
                const end = self.newPosition(code, sel.start());
                try self.replaceRange(gpa, sel.start(), end, &.{});
                return true;
            },
        }
        return false;
    }

    fn newPosition(self: *const EditText, code: Control, pos: usize) usize {
        const t = self.text.items;
        return switch (code) {
            .select_right, .move_right, .delete => @min(pos + 1, t.len),
            .select_left, .move_left, .backspace => if (pos > 0) pos - 1 else 0,
            .select_right_word, .move_right_word, .delete_word => nextWord(t, pos),
            .select_left_word, .move_left_word, .backspace_word => prevWord(t, pos),
            .select_right_line, .move_right_line => nextLine(t, pos),
            .select_left_line, .move_left_line => prevLine(t, pos),
            .select_right_document, .move_right_document => t.len,
            .select_left_document, .move_left_document => 0,
            else => pos,
        };
    }

    /// Map a point in the FIELD's own space (twips) to a character
    /// index: the nearest line by y, the nearest box on it by x, then the
    /// glyph whose half-width the point has passed.
    ///
    /// Null when the field has no text boxes at all, which the caller
    /// treats as "caret at the end".
    pub fn positionToIndex(self: *const EditText, local: [2]i32) ?usize {
        const lines = self.layout.lines;
        if (lines.len == 0) return null;
        const x = local[0] - self.bounds.xmin - GUTTER;
        const y = local[1] - self.bounds.ymin - GUTTER;

        var line = lines[0];
        for (lines) |l| {
            line = l;
            if (y < l.bounds.y + l.bounds.h + l.leading) break;
        }

        var closest: ?text_layout.Box = null;
        for (line.boxes) |b| {
            if (b.is_bullet) continue;
            if (x >= b.bounds.x or closest == null) {
                closest = b;
            } else {
                break;
            }
        }
        const box = closest orelse return null;

        // The layout can lag the text by one edit; a box that now points
        // past the end contributes nothing rather than panicking.
        const hi = @min(box.end, self.text.items.len);
        const lo = @min(box.start, hi);
        var finder: IndexFinder = .{ .want = x - box.bounds.x };
        _ = box.font.evaluate(self.text.items[lo..hi], .{
            .height = box.size,
            .letter_spacing = box.letter_spacing,
            .kerning = box.kerning,
        }, &finder) catch {};
        return lo + finder.index;
    }

    /// A preedit update. An EMPTY one ends the composition, discarding
    /// what it had put in the field.
    pub fn imePreedit(
        self: *EditText,
        gpa: std.mem.Allocator,
        text: []const u16,
        cursor: ?[2]usize,
    ) !void {
        if (text.len == 0) return self.imeFinish(gpa);
        const started = try self.imeStart(gpa);
        try self.replaceRange(gpa, started.start, started.end, text);
        if (self.ime) |old| gpa.free(old.text);
        self.ime = .{
            .start = started.start,
            .end = started.start + text.len,
            .text = try gpa.dupe(u16, text),
        };
        if (cursor) |c| {
            self.setSelection(.{ .from = started.start + c[0], .to = started.start + c[1] });
        } else {
            self.selection = null;
        }
    }

    /// Begin composing at the caret, removing whatever was selected.
    fn imeStart(self: *EditText, gpa: std.mem.Allocator) !Ime {
        if (self.ime) |d| return d;
        const sel = self.selection orelse Selection.at(self.text.items.len);
        try self.replaceRange(gpa, sel.start(), sel.end(), &.{});
        const d: Ime = .{ .start = sel.start(), .end = sel.start(), .text = &.{} };
        self.ime = .{ .start = d.start, .end = d.end, .text = try gpa.dupe(u16, &.{}) };
        return d;
    }

    /// Abandon the composition: its text leaves the field.
    fn imeFinish(self: *EditText, gpa: std.mem.Allocator) !void {
        const d = self.ime orelse return;
        try self.replaceRange(gpa, d.start, d.end, &.{});
        self.setSelection(Selection.at(d.start));
        gpa.free(d.text);
        self.ime = null;
    }

    /// Losing focus COMMITS: the preedit leaves and is typed back as real
    /// input, which is what makes `onChanged` fire for it.
    /// Returns whether anything was typed.
    pub fn imeCommit(self: *EditText, gpa: std.mem.Allocator) !bool {
        const d = self.ime orelse return false;
        const text = try gpa.dupe(u16, d.text);
        defer gpa.free(text);
        try self.imeFinish(gpa);
        return self.textInput(gpa, text);
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
/// `EditText::new`'s tag has font id 0, which resolves to nothing — so
/// the face NAME defaults the same way a tag with an unknown font does.
const TIMES: [15]u16 = .{ 'T', 'i', 'm', 'e', 's', ' ', 'N', 'e', 'w', ' ', 'R', 'o', 'm', 'a', 'n' };

fn dynamicFormat() TextFormat {
    return .{
        .font = &TIMES,
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

/// The last glyph the point has reached, rounded to the nearer edge.
const IndexFinder = struct {
    want: i32,
    index: usize = 0,

    pub fn glyph(self: *IndexFinder, p: font_mod.Placed) !void {
        if (self.want < p.x) return;
        self.index = if (self.want > p.x + @divTrunc(p.advance, 2)) p.index + 1 else p.index;
    }
};

fn append(dst: *[64][2]u16, n: usize, src: []const [2]u16) usize {
    var k = n;
    for (src) |iv| {
        if (k >= dst.len) break;
        dst[k] = iv;
        k += 1;
    }
    return k;
}

fn inAny(intervals: []const [2]u16, c: u16) bool {
    for (intervals) |iv| {
        if (c >= iv[0] and c <= iv[1]) return true;
    }
    return false;
}

fn isWordChar(c: u16) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or c == '_' or c > 127;
}

fn nextWord(t: []const u16, pos: usize) usize {
    var i = pos;
    while (i < t.len and !isWordChar(t[i])) i += 1;
    while (i < t.len and isWordChar(t[i])) i += 1;
    return i;
}

fn prevWord(t: []const u16, pos: usize) usize {
    var i = pos;
    while (i > 0 and !isWordChar(t[i - 1])) i -= 1;
    while (i > 0 and isWordChar(t[i - 1])) i -= 1;
    return i;
}

fn nextLine(t: []const u16, pos: usize) usize {
    var i = pos;
    while (i < t.len and t[i] != '\r' and t[i] != '\n') i += 1;
    return i;
}

fn prevLine(t: []const u16, pos: usize) usize {
    var i = pos;
    while (i > 0 and t[i - 1] != '\r' and t[i - 1] != '\n') i -= 1;
    return i;
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
