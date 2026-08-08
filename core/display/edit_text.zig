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

const Rectangle = swf.reader.Rectangle;
const TextFormat = format_mod.TextFormat;
const Tag = swf.font_text.EditText;

/// `autoSize`. Only `none` leaves the bounds alone; the others resize the
/// field to its content and pin a different edge.
pub const AutoSize = enum { none, left, center, right };

/// `gridFitType`. Purely reported today — nothing rasterises differently.
pub const GridFit = enum { none, pixel, subpixel };

/// Immutable padding on all four sides of every text field, and it is
/// OBSERVABLE: two pixels of it turn up in `textWidth` vs `_width`, in
/// `getTextExtent`, and in where the first glyph sits (ruffle
/// edit_text.rs:257).
pub const GUTTER: i32 = 40;

pub const EditText = struct {
    /// The tag this was born from; null for `createTextField`.
    def: ?*const Tag,
    /// Live text, UCS-2, owned by the display allocator.
    text: std.ArrayList(u16) = .empty,
    /// The format new text inherits — `getNewTextFormat`'s answer.
    default_format: TextFormat = .{},
    /// What `getTextFormat` reports. A real span list arrives with the
    /// layout engine; until then a field carries ONE run, and keeping it
    /// apart from `default_format` is what makes `setTextFormat` visible
    /// to `getTextFormat` without moving `textColor`.
    span_format: TextFormat = .{},
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
            // ALPHA IS DROPPED: script sees the colour as pure RGB, and
            // `getTextFormat().color` on a fresh black field is 0, not
            // 0xFF000000 (ruffle `Color::from_rgb(c.to_rgb(), 0)`).
            .color = def.color & 0x00FF_FFFF,
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
        self.span_format = self.default_format;
        if (def.variable_name.len > 0) {
            var buf: std.ArrayList(u16) = .empty;
            for (def.variable_name) |c| try buf.append(gpa, c);
            self.variable = try buf.toOwnedSlice(gpa);
        }
        if (def.initial_text) |t| try setTextAscii(&self, gpa, t);
        return self;
    }

    /// `createTextField` — ruffle's `EditText::new`: 12px black text, read
    /// only, selectable, and bounds anchored at the ORIGIN with the
    /// position carried by the placement matrix instead.
    pub fn dynamic(width: f64, height: f64) EditText {
        return .{
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
            .span_format = dynamicFormat(),
        };
    }

    pub fn deinit(self: *EditText, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
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

    pub fn setText(self: *EditText, gpa: std.mem.Allocator, s: []const u16) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, s);
    }

    fn setTextAscii(self: *EditText, gpa: std.mem.Allocator, s: []const u8) !void {
        self.text.clearRetainingCapacity();
        for (s) |c| try self.text.append(gpa, c);
    }
};

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
    const et = EditText.dynamic(100, 20);
    try testing.expectEqual(@as(i32, 0), et.bounds.xmin);
    try testing.expectEqual(@as(i32, 2000), et.bounds.xmax);
    try testing.expectEqual(@as(i32, 400), et.bounds.ymax);
    try testing.expectEqual(@as(?f64, 12), et.default_format.size);
    try testing.expect(et.read_only);
    try testing.expect(et.selectable);
}
