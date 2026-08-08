//! `TextFormat` — the value type behind both the AVM1 class and (from D4
//! on) a text field's spans.
//!
//! Every field is OPTIONAL and that is the whole point: an unset field
//! reads back as `null`, not as a default, and merging two formats keeps
//! only the properties they agree on. Flash exposes the tri-state
//! directly, so `typeof format.font` is `"null"` until something sets it.
//!
//! A leaf module: it depends on nothing but `std`, so the interpreter and
//! the display tree can both hold one without either importing the other.
//!
//! Reference: reference/ruffle/core/src/html/text_format.rs.

const std = @import("std");

pub const Align = enum { left, center, right, justify };
pub const Display = enum { block, inline_text, none };

/// `TextFormat::default()` — everything unset EXCEPT `display`, which
/// starts as `block`. A fresh `new TextFormat()` reports "block", not null
/// (corpus text_format_display's first line).
pub fn defaultFormat() TextFormat {
    return .{ .display = .block };
}

pub const TextFormat = struct {
    font: ?[]const u16 = null,
    /// Sizes and spacings are f64 because that is what the AVM1 setters
    /// produce — an i32 below SWF8, a round-half-even f64 above it.
    size: ?f64 = null,
    /// The 32-bit value the script set, round-tripped verbatim; the
    /// display side converts when it paints.
    color: ?u32 = null,
    url: ?[]const u16 = null,
    target: ?[]const u16 = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    text_align: ?Align = null,
    left_margin: ?f64 = null,
    right_margin: ?f64 = null,
    indent: ?f64 = null,
    leading: ?f64 = null,
    block_indent: ?f64 = null,
    tab_stops: ?[]const f64 = null,
    bullet: ?bool = null,
    display: ?Display = null,
    kerning: ?bool = null,
    letter_spacing: ?f64 = null,

    /// Keep only what the two agree on — how `getTextFormat` reports a
    /// range that spans more than one format (ruffle
    /// `merge_matching_properties`).
    pub fn mergeMatching(a: TextFormat, b: TextFormat) TextFormat {
        var out: TextFormat = .{};
        inline for (@typeInfo(TextFormat).@"struct".fields) |f| {
            const av = @field(a, f.name);
            const bv = @field(b, f.name);
            @field(out, f.name) = if (eqlOpt(av, bv)) av else null;
        }
        return out;
    }

    /// Fields set on `self` win; anything unset falls back to `other`.
    pub fn mixWith(self: TextFormat, other: TextFormat) TextFormat {
        var out = self;
        inline for (@typeInfo(TextFormat).@"struct".fields) |f| {
            if (@field(out, f.name) == null) @field(out, f.name) = @field(other, f.name);
        }
        return out;
    }
};

fn eqlOpt(a: anytype, b: @TypeOf(a)) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    const A = @TypeOf(a.?);
    if (A == []const u16 or A == []const f64) return sliceEql(A, a.?, b.?);
    return a.? == b.?;
}

fn sliceEql(comptime T: type, a: T, b: T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "merging keeps only what both agree on" {
    const a: TextFormat = .{ .size = 12, .bold = true, .indent = 4 };
    const b: TextFormat = .{ .size = 12, .bold = false };
    const m = TextFormat.mergeMatching(a, b);
    try testing.expectEqual(@as(?f64, 12), m.size);
    try testing.expectEqual(@as(?bool, null), m.bold);
    try testing.expectEqual(@as(?f64, null), m.indent);
}

test "mixWith fills the gaps without overwriting" {
    const on: TextFormat = .{ .size = 20 };
    const base: TextFormat = .{ .size = 12, .bold = true };
    const m = TextFormat.mixWith(on, base);
    try testing.expectEqual(@as(?f64, 20), m.size);
    try testing.expectEqual(@as(?bool, true), m.bold);
}
