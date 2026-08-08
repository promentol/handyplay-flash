//! DefineFont1-3, DefineFontInfo1-2, DefineText1-2, DefineEditText decoding.
//!
//! Glyphs are shape records (shape version 1 grammar, per-glyph nbits byte);
//! DefineFont3 glyph coordinates are at 20× resolution (render divides by
//! 20480 instead of 1024 — a render concern, not a parse one).
//!
//! Layout reference: reference/ruffle/swf/src/read.rs
//! (read_define_font_1/2, read_define_font_info, read_define_text,
//! read_define_edit_text) + SWF19. Wild-SWF tolerances mirrored: fonts with
//! zero glyphs may or may not carry a code-table offset; old fonts may end
//! the layout early (before bounds/kerning); indent is SI16 despite spec.

const std = @import("std");
const rdr = @import("reader.zig");
const shape = @import("shape.zig");

pub const Error = shape.Error;

pub const Glyph = struct {
    records: []shape.ShapeRecord,
    /// Codepoint from the code table (Font2/3) or FontInfo; 0 if unmapped.
    code: u16 = 0,
    /// Advance in em units (layout table); 0 without layout.
    advance: u16 = 0,
    bounds: ?rdr.Rectangle = null,
};

/// Glyph outlines carry NO style array: their records reference fill
/// style 1 with an implicit style, and the colour arrives separately from
/// the text record. `shape_utils.distill` drops every segment when the
/// fill array is empty (`Active.flushFill` indexes `pending[style_id-1]`),
/// so hand it this one shared WHITE fill and let the text colour arrive as
/// a colour-transform multiplier, exactly as ruffle does
/// (render/src/shape_utils.rs `swf_glyph_to_shape`).
var glyph_fills = [_]shape.FillStyle{.{ .solid = 0xFFFFFFFF }};

/// A glyph viewed as a `Shape`, by value — the style slice points at the
/// shared global above, so the returned Shape can live on the stack for
/// as long as it takes to distill or hit-test it.
pub fn glyphShape(g: *const Glyph) shape.Shape {
    const box = g.bounds orelse rdr.Rectangle{};
    return .{
        .version = 1,
        .id = 0,
        .bounds = box,
        .edge_bounds = box,
        // Ruffle marks glyph shapes NON-ZERO winding; even-odd punches
        // holes through overlapping contours.
        .uses_fill_winding_rule = true,
        .styles = .{ .fills = &glyph_fills, .lines = &.{} },
        .records = g.records,
    };
}

pub const KerningRecord = struct {
    left_code: u16,
    right_code: u16,
    adjustment: i16,
};

pub const Layout = struct {
    ascent: u16,
    descent: u16,
    leading: i16,
    kerning: []KerningRecord,
};

pub const Font = struct {
    /// 1, 2 or 3 (DefineFontN).
    version: u8,
    id: u16,
    name: []const u8 = "",
    is_bold: bool = false,
    is_italic: bool = false,
    is_ansi: bool = false,
    is_shift_jis: bool = false,
    is_small_text: bool = false,
    language: u8 = 0,
    glyphs: []Glyph,
    layout: ?Layout = null,
};

fn parseGlyphRecords(allocator: std.mem.Allocator, r: *rdr.Reader, swf_version: u8) Error![]shape.ShapeRecord {
    const nbits = try r.readU8();
    var bits: shape.Bits = .{ .fill = @intCast(nbits >> 4), .line = @intCast(nbits & 0x0F) };
    return shape.parseRecords(allocator, r, .{ .swf_version = swf_version, .shape_version = 1 }, &bits);
}

/// DefineFont (tag 10): offset table + glyph shapes only.
pub fn parseFont1(allocator: std.mem.Allocator, body: []const u8, swf_version: u8) Error!Font {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const first_offset = try r.readU16();
    const num_glyphs = first_offset / 2;
    if (num_glyphs > 0) try r.skip((num_glyphs - 1) * 2);
    const glyphs = try allocator.alloc(Glyph, num_glyphs);
    for (glyphs) |*g| {
        g.* = .{ .records = try parseGlyphRecords(allocator, &r, swf_version) };
    }
    return .{ .version = 1, .id = id, .glyphs = glyphs };
}

/// DefineFont2 (48) / DefineFont3 (75).
pub fn parseFont2(
    allocator: std.mem.Allocator,
    body: []const u8,
    font_version: u8,
    swf_version: u8,
) Error!Font {
    var r = rdr.Reader.init(body);
    var f: Font = .{ .version = font_version, .id = try r.readU16(), .glyphs = &.{} };
    const flags = try r.readU8();
    const has_layout = (flags & 0x80) != 0;
    f.is_shift_jis = (flags & 0x40) != 0;
    f.is_small_text = (flags & 0x20) != 0;
    f.is_ansi = (flags & 0x10) != 0;
    const wide_offsets = (flags & 0x08) != 0;
    const wide_codes = (flags & 0x04) != 0;
    f.is_italic = (flags & 0x02) != 0;
    f.is_bold = (flags & 0x01) != 0;
    f.language = try r.readU8();
    const name_len = try r.readU8();
    f.name = try r.readSlice(name_len);
    // Some IDE versions null-terminate the name despite SWF19.
    if (std.mem.indexOfScalar(u8, f.name, 0)) |nul| f.name = f.name[0..nul];

    const num_glyphs = try r.readU16();
    f.glyphs = try allocator.alloc(Glyph, num_glyphs);
    for (f.glyphs) |*g| g.* = .{ .records = &.{} };
    if (num_glyphs == 0) {
        // Code-table offset may or may not be present — swallow either way.
        if (wide_offsets) {
            _ = r.readU32() catch {};
        } else {
            _ = r.readU16() catch {};
        }
        return f;
    }

    // Offsets are relative to the start of the offset table.
    const table_base = r.pos;
    const offsets = try allocator.alloc(u32, num_glyphs);
    defer allocator.free(offsets);
    for (offsets) |*o| o.* = if (wide_offsets) try r.readU32() else try r.readU16();
    const code_table_offset: u32 = if (wide_offsets) try r.readU32() else try r.readU16();

    for (f.glyphs, offsets) |*g, off| {
        if (table_base + off > body.len) return Error.OutOfBounds;
        r.pos = table_base + off;
        r.byteAlign();
        g.records = try parseGlyphRecords(allocator, &r, swf_version);
    }

    if (table_base + code_table_offset > body.len) return Error.OutOfBounds;
    r.pos = table_base + code_table_offset;
    r.byteAlign();
    for (f.glyphs) |*g| g.code = if (wide_codes) try r.readU16() else try r.readU8();

    if (has_layout) {
        var layout: Layout = .{
            .ascent = try r.readU16(),
            .descent = try r.readU16(),
            .leading = try r.readI16(),
            .kerning = &.{},
        };
        for (f.glyphs) |*g| g.advance = try r.readU16();
        // Older SWFs legally end the tag here (bounds/kerning unused < v7).
        if (r.remaining() > 0) {
            for (f.glyphs) |*g| g.bounds = try r.readRectangle();
        }
        if (r.remaining() > 0) {
            const n = try r.readU16();
            const kern = try allocator.alloc(KerningRecord, n);
            for (kern) |*k| {
                k.* = .{
                    .left_code = if (wide_codes) try r.readU16() else try r.readU8(),
                    .right_code = if (wide_codes) try r.readU16() else try r.readU8(),
                    .adjustment = try r.readI16(),
                };
            }
            layout.kerning = kern;
        }
        f.layout = layout;
    }
    return f;
}

/// DefineFontInfo (13) / DefineFontInfo2 (62): maps a DefineFont's glyph
/// order to codepoints and adds face metadata.
pub const FontInfo = struct {
    font_id: u16,
    name: []const u8,
    is_bold: bool,
    is_italic: bool,
    is_ansi: bool,
    is_shift_jis: bool,
    is_small_text: bool,
    language: u8 = 0,
    /// code_table[i] = codepoint of glyph i.
    codes: []u16,
};

pub fn parseFontInfo(
    allocator: std.mem.Allocator,
    body: []const u8,
    info_version: u8,
) Error!FontInfo {
    var r = rdr.Reader.init(body);
    const font_id = try r.readU16();
    const name_len = try r.readU8();
    var name = try r.readSlice(name_len);
    if (std.mem.indexOfScalar(u8, name, 0)) |nul| name = name[0..nul];
    const flags = try r.readU8();
    const language: u8 = if (info_version >= 2) try r.readU8() else 0;
    const wide_codes = (flags & 0b1) != 0;
    var codes: std.ArrayList(u16) = .empty;
    while (r.remaining() >= (if (wide_codes) @as(usize, 2) else 1)) {
        try codes.append(allocator, if (wide_codes) try r.readU16() else try r.readU8());
    }
    return .{
        .font_id = font_id,
        .name = name,
        .is_small_text = (flags & 0b100000) != 0,
        .is_shift_jis = (flags & 0b010000) != 0,
        .is_ansi = (flags & 0b001000) != 0,
        .is_italic = (flags & 0b000100) != 0,
        .is_bold = (flags & 0b000010) != 0,
        .language = language,
        .codes = try codes.toOwnedSlice(allocator),
    };
}

// --- DefineText ------------------------------------------------------------

pub const GlyphEntry = struct {
    /// Index into the font's glyph table.
    index: u32,
    /// Advance in twips.
    advance: i32,
};

/// Sticky-state text block: font/color/offsets/height persist across
/// records until overridden (the render loop applies them in order).
pub const TextRecord = struct {
    font_id: ?u16 = null,
    color: ?rdr.Color = null,
    x_offset: ?i16 = null,
    y_offset: ?i16 = null,
    /// Text height in twips (present iff font_id is).
    height: ?u16 = null,
    glyphs: []GlyphEntry,
};

pub const Text = struct {
    id: u16,
    bounds: rdr.Rectangle,
    matrix: rdr.Matrix,
    records: []TextRecord,
};

/// DefineText (11) / DefineText2 (33) — text2 uses RGBA colors.
pub fn parseText(allocator: std.mem.Allocator, body: []const u8, text_version: u8) Error!Text {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const bounds = try r.readRectangle();
    const matrix = try r.readMatrix();
    const glyph_bits: u6 = @intCast(try r.readU8());
    const advance_bits: u6 = @intCast(try r.readU8());

    var records: std.ArrayList(TextRecord) = .empty;
    while (true) {
        const flags = try r.readU8();
        if (flags == 0) break;
        var rec: TextRecord = .{ .glyphs = &.{} };
        if ((flags & 0b1000) != 0) rec.font_id = try r.readU16();
        if ((flags & 0b0100) != 0) {
            rec.color = if (text_version == 1) try r.readRgb() else try r.readRgba();
        }
        if ((flags & 0b0001) != 0) rec.x_offset = try r.readI16();
        if ((flags & 0b0010) != 0) rec.y_offset = try r.readI16();
        if ((flags & 0b1000) != 0) rec.height = try r.readU16();
        const n = try r.readU8();
        const glyphs = try allocator.alloc(GlyphEntry, n);
        for (glyphs) |*g| {
            g.* = .{ .index = try r.readUb(glyph_bits), .advance = try r.readSb(advance_bits) };
        }
        r.byteAlign();
        rec.glyphs = glyphs;
        try records.append(allocator, rec);
    }
    return .{
        .id = id,
        .bounds = bounds,
        .matrix = matrix,
        .records = try records.toOwnedSlice(allocator),
    };
}

// --- DefineEditText ---------------------------------------------------------

pub const TextAlign = enum(u8) { left = 0, right = 1, center = 2, justify = 3, invalid = 255 };

pub const EditText = struct {
    id: u16,
    bounds: rdr.Rectangle,
    // Flag byte 1 (low).
    has_text: bool,
    word_wrap: bool,
    multiline: bool,
    password: bool,
    read_only: bool,
    // Flag byte 2 (high).
    auto_size: bool,
    no_select: bool,
    border: bool,
    was_static: bool,
    is_html: bool,
    use_outlines: bool,
    font_id: ?u16 = null,
    font_class: ?[]const u8 = null,
    /// Font height in twips (present with font_id OR font_class — SWF19
    /// errata).
    height: u16 = 0,
    color: rdr.Color = 0xFF000000,
    max_length: ?u16 = null,
    align_h: TextAlign = .left,
    left_margin: u16 = 0,
    right_margin: u16 = 0,
    indent: i16 = 0,
    leading: i16 = 0,
    /// AVM1 variable this field binds to ("" = none).
    variable_name: []const u8,
    initial_text: ?[]const u8 = null,
};

pub fn parseEditText(body: []const u8) Error!EditText {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const bounds = try r.readRectangle();
    const flags = try r.readU16();
    const has_font = (flags & (1 << 0)) != 0;
    const has_max_length = (flags & (1 << 1)) != 0;
    const has_color = (flags & (1 << 2)) != 0;
    const has_font_class = (flags & (1 << 15)) != 0;
    const has_layout = (flags & (1 << 13)) != 0;
    var et: EditText = .{
        .id = id,
        .bounds = bounds,
        .read_only = (flags & (1 << 3)) != 0,
        .password = (flags & (1 << 4)) != 0,
        .multiline = (flags & (1 << 5)) != 0,
        .word_wrap = (flags & (1 << 6)) != 0,
        .has_text = (flags & (1 << 7)) != 0,
        .use_outlines = (flags & (1 << 8)) != 0,
        .is_html = (flags & (1 << 9)) != 0,
        .was_static = (flags & (1 << 10)) != 0,
        .border = (flags & (1 << 11)) != 0,
        .no_select = (flags & (1 << 12)) != 0,
        .auto_size = (flags & (1 << 14)) != 0,
        .variable_name = "",
    };
    if (has_font) et.font_id = try r.readU16();
    if (has_font_class) et.font_class = try r.readString();
    if (has_font or has_font_class) et.height = try r.readU16();
    if (has_color) et.color = try r.readRgba();
    if (has_max_length) et.max_length = try r.readU16();
    if (has_layout) {
        const raw_align = try r.readU8();
        et.align_h = if (raw_align <= 3) @enumFromInt(raw_align) else .invalid;
        et.left_margin = try r.readU16();
        et.right_margin = try r.readU16();
        et.indent = try r.readI16(); // SI16 despite the spec (ruffle note)
        et.leading = try r.readI16();
    }
    et.variable_name = try r.readString();
    if (et.has_text) et.initial_text = try r.readString();
    return et;
}

// --- Tests -----------------------------------------------------------------

test "DefineText with sticky record state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // id=3, empty rect (1 byte 0), identity matrix (1 byte 0), glyph_bits=7,
    // advance_bits=8; one record: flags 0b1000_1100 (type bit 7 set per
    // spec — ruffle treats any nonzero as record; has_font(8)+has_color(4)):
    // font 2, RGB red, height 240, 2 glyphs (idx 5 adv 100; idx 6 adv -20).
    var buf: [64]u8 = @splat(0);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try b.appendSlice(ta, &.{ 3, 0, 0, 0, 7, 8 });
    try b.appendSlice(ta, &.{ 0b1000_1100, 2, 0, 255, 0, 0, 240, 0, 2 });
    var gb: [4]u8 = @splat(0);
    const neg20: u32 = @as(u32, @bitCast(@as(i32, -20))) & 0xFF;
    packBits(&gb, &.{ .{ 5, 7 }, .{ 100, 8 }, .{ 6, 7 }, .{ neg20, 8 } });
    try b.appendSlice(ta, &gb);
    try b.append(ta, 0); // end of records
    _ = &buf;

    const t = try parseText(a, b.items, 1);
    try std.testing.expectEqual(@as(u16, 3), t.id);
    try std.testing.expectEqual(@as(usize, 1), t.records.len);
    const rec = t.records[0];
    try std.testing.expectEqual(@as(u16, 2), rec.font_id.?);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), rec.color.?);
    try std.testing.expectEqual(@as(u16, 240), rec.height.?);
    try std.testing.expectEqual(@as(u32, 5), rec.glyphs[0].index);
    try std.testing.expectEqual(@as(i32, 100), rec.glyphs[0].advance);
    try std.testing.expectEqual(@as(i32, -20), rec.glyphs[1].advance);
}

test "DefineEditText flags and optional fields" {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    // id=9, empty rect, flags: has_font|has_color|has_text|word_wrap|
    // multiline|html|has_layout = 1 + 4 + 128 + 64 + 32 + 512 + 8192.
    const flags: u16 = 1 | 4 | 128 | 64 | 32 | 512 | 8192;
    try b.appendSlice(ta, &.{ 9, 0, 0 });
    try b.appendSlice(ta, &.{ @truncate(flags), @truncate(flags >> 8) });
    try b.appendSlice(ta, &.{ 7, 0 }); // font_id = 7
    try b.appendSlice(ta, &.{ 0xC8, 0x00 }); // height = 200
    try b.appendSlice(ta, &.{ 10, 20, 30, 128 }); // RGBA
    try b.appendSlice(ta, &.{ 2, 0x0A, 0, 0x14, 0, 0xFB, 0xFF, 0x02, 0x00 }); // layout: center, m10, m20, indent -5, leading 2
    try b.appendSlice(ta, "myVar\x00");
    try b.appendSlice(ta, "<b>hi</b>\x00");

    const et = try parseEditText(b.items);
    try std.testing.expectEqual(@as(u16, 9), et.id);
    try std.testing.expect(et.word_wrap and et.multiline and et.is_html);
    try std.testing.expect(!et.read_only and !et.border);
    try std.testing.expectEqual(@as(u16, 7), et.font_id.?);
    try std.testing.expectEqual(@as(u16, 200), et.height);
    try std.testing.expectEqual(@as(u32, 10 | (20 << 8) | (30 << 16) | (128 << 24)), et.color);
    try std.testing.expectEqual(TextAlign.center, et.align_h);
    try std.testing.expectEqual(@as(i16, -5), et.indent);
    try std.testing.expectEqualStrings("myVar", et.variable_name);
    try std.testing.expectEqualStrings("<b>hi</b>", et.initial_text.?);
}

test "DefineFont1 with two square glyphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two glyphs, each: nbits byte 0x10 (fill 1, line 0), records:
    // move+fill1 then end (a degenerate 0-edge glyph keeps the fixture
    // small; grammar exercised is what matters).
    var glyph: [4]u8 = @splat(0);
    packBits(&glyph, &.{
        .{ 0b00101, 6 }, .{ 0, 5 }, .{ 1, 1 }, // style change: move(0,0), fill1=1
        .{ 0, 6 }, // end
    });
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try b.appendSlice(ta, &.{ 5, 0 }); // id
    try b.appendSlice(ta, &.{ 4, 0, 4 + 1 + 3, 0 }); // offsets: 4, 8 (2 glyphs)
    try b.append(ta, 0x10);
    try b.appendSlice(ta, glyph[0..3]); // 18 record bits → 3 bytes
    try b.append(ta, 0x10);
    try b.appendSlice(ta, glyph[0..3]);

    const f = try parseFont1(a, b.items, 6);
    try std.testing.expectEqual(@as(u16, 5), f.id);
    try std.testing.expectEqual(@as(usize, 2), f.glyphs.len);
    try std.testing.expectEqual(@as(usize, 1), f.glyphs[0].records.len);
}

/// Test helper: MSB-first bit packer.
fn packBits(buf: []u8, fields: []const struct { u32, u6 }) void {
    var bit: usize = 0;
    for (fields) |f| {
        var i: u6 = f[1];
        while (i > 0) {
            i -= 1;
            const b: u1 = @intCast((f[0] >> @as(u5, @intCast(i))) & 1);
            buf[bit / 8] |= @as(u8, b) << @intCast(7 - (bit % 8));
            bit += 1;
        }
    }
}
