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

const Rectangle = swf.reader.Rectangle;
const TextFormat = format_mod.TextFormat;
const Tag = swf.font_text.EditText;

/// `autoSize`. Only `none` leaves the bounds alone; the others resize the
/// field to its content and pin a different edge.
pub const AutoSize = enum { none, left, center, right };

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
    /// 0 = unlimited.
    max_chars: u16 = 0,
    /// The timeline variable this field mirrors (D7 wires the sync).
    variable: ?[]const u16 = null,
    hscroll: f64 = 0,
    /// 1-based, like Flash's.
    scroll: u32 = 1,

    pub fn fromTag(gpa: std.mem.Allocator, def: *const Tag) !EditText {
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
            .max_chars = def.max_length orelse 0,
            .variable = null,
        };
        self.default_format = .{
            .size = @floatFromInt(def.height),
            .color = def.color,
            .text_align = switch (def.align_h) {
                .left => .left,
                .center => .center,
                .right => .right,
                .justify => .justify,
                .invalid => .left,
            },
            .left_margin = @floatFromInt(def.left_margin),
            .right_margin = @floatFromInt(def.right_margin),
            .indent = @floatFromInt(def.indent),
            .leading = @floatFromInt(def.leading),
        };
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
            .default_format = .{ .size = 240, .color = 0xFF000000 },
        };
    }

    pub fn deinit(self: *EditText, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
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

fn twips(px: f64) i32 {
    return @intFromFloat(@trunc(px * @as(f64, swf.reader.TWIPS_PER_PX)));
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "a dynamic field is 12px black, read-only and anchored at the origin" {
    const et = EditText.dynamic(100, 20);
    try testing.expectEqual(@as(i32, 0), et.bounds.xmin);
    try testing.expectEqual(@as(i32, 2000), et.bounds.xmax);
    try testing.expectEqual(@as(i32, 400), et.bounds.ymax);
    try testing.expectEqual(@as(?f64, 240), et.default_format.size);
    try testing.expect(et.read_only);
    try testing.expect(et.selectable);
}
