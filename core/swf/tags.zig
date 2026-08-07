//! Tag scanner. A tag record is `tagCodeAndLength: u16le` where
//! `code = value >> 6` and `length = value & 0x3F`; length 0x3F means a
//! "long tag" with the real length in a following u32le. Tag code 0 (End)
//! terminates the stream.
//!
//! Tolerance policy (matches Ruffle / real-world SWFs): unknown codes are
//! yielded with their raw body so callers can skip them; a body that runs
//! past the end of the buffer is clamped to what's actually there (the
//! `truncated` flag is set) — never fatal.

const std = @import("std");
const reader = @import("reader.zig");

/// Known tag codes (docs/TAGS.md is the catalog with per-tag status).
/// Non-exhaustive: unknown codes from the wild stay representable.
pub const TagCode = enum(u16) {
    end = 0,
    show_frame = 1,
    define_shape = 2,
    place_object = 4,
    remove_object = 5,
    define_bits = 6,
    define_button = 7,
    jpeg_tables = 8,
    set_background_color = 9,
    define_font = 10,
    define_text = 11,
    do_action = 12,
    define_font_info = 13,
    define_sound = 14,
    start_sound = 15,
    define_button_sound = 17,
    sound_stream_head = 18,
    sound_stream_block = 19,
    define_bits_lossless = 20,
    define_bits_jpeg2 = 21,
    define_shape2 = 22,
    define_button_cxform = 23,
    protect = 24,
    place_object2 = 26,
    remove_object2 = 28,
    define_shape3 = 32,
    define_text2 = 33,
    define_button2 = 34,
    define_bits_jpeg3 = 35,
    define_bits_lossless2 = 36,
    define_edit_text = 37,
    define_sprite = 39,
    name_character = 40, // undocumented (errata)
    product_info = 41, // undocumented (errata)
    frame_label = 43,
    sound_stream_head2 = 45,
    define_morph_shape = 46,
    define_font2 = 48,
    export_assets = 56,
    import_assets = 57,
    enable_debugger = 58,
    do_init_action = 59,
    define_video_stream = 60,
    video_frame = 61,
    define_font_info2 = 62,
    debug_id = 63, // undocumented (errata)
    enable_debugger2 = 64,
    script_limits = 65,
    set_tab_index = 66,
    file_attributes = 69,
    place_object3 = 70,
    import_assets2 = 71,
    do_abc_define = 72,
    define_font_align_zones = 73,
    csm_text_settings = 74,
    define_font3 = 75,
    symbol_class = 76,
    metadata = 77,
    define_scaling_grid = 78,
    do_abc = 82,
    define_shape4 = 83,
    define_morph_shape2 = 84,
    define_scene_and_frame_label_data = 86,
    define_binary_data = 87,
    define_font_name = 88,
    start_sound2 = 89,
    define_bits_jpeg4 = 90,
    define_font4 = 91,
    enable_telemetry = 93,
    _,

    pub fn name(self: TagCode) []const u8 {
        return switch (self) {
            .end => "End",
            .show_frame => "ShowFrame",
            .define_shape => "DefineShape",
            .place_object => "PlaceObject",
            .remove_object => "RemoveObject",
            .define_bits => "DefineBits",
            .define_button => "DefineButton",
            .jpeg_tables => "JPEGTables",
            .set_background_color => "SetBackgroundColor",
            .define_font => "DefineFont",
            .define_text => "DefineText",
            .do_action => "DoAction",
            .define_font_info => "DefineFontInfo",
            .define_sound => "DefineSound",
            .start_sound => "StartSound",
            .define_button_sound => "DefineButtonSound",
            .sound_stream_head => "SoundStreamHead",
            .sound_stream_block => "SoundStreamBlock",
            .define_bits_lossless => "DefineBitsLossless",
            .define_bits_jpeg2 => "DefineBitsJPEG2",
            .define_shape2 => "DefineShape2",
            .define_button_cxform => "DefineButtonCxform",
            .protect => "Protect",
            .place_object2 => "PlaceObject2",
            .remove_object2 => "RemoveObject2",
            .define_shape3 => "DefineShape3",
            .define_text2 => "DefineText2",
            .define_button2 => "DefineButton2",
            .define_bits_jpeg3 => "DefineBitsJPEG3",
            .define_bits_lossless2 => "DefineBitsLossless2",
            .define_edit_text => "DefineEditText",
            .define_sprite => "DefineSprite",
            .name_character => "NameCharacter",
            .product_info => "ProductInfo",
            .frame_label => "FrameLabel",
            .sound_stream_head2 => "SoundStreamHead2",
            .define_morph_shape => "DefineMorphShape",
            .define_font2 => "DefineFont2",
            .export_assets => "ExportAssets",
            .import_assets => "ImportAssets",
            .enable_debugger => "EnableDebugger",
            .do_init_action => "DoInitAction",
            .define_video_stream => "DefineVideoStream",
            .video_frame => "VideoFrame",
            .define_font_info2 => "DefineFontInfo2",
            .debug_id => "DebugId",
            .enable_debugger2 => "EnableDebugger2",
            .script_limits => "ScriptLimits",
            .set_tab_index => "SetTabIndex",
            .file_attributes => "FileAttributes",
            .place_object3 => "PlaceObject3",
            .import_assets2 => "ImportAssets2",
            .do_abc_define => "DoABCDefine",
            .define_font_align_zones => "DefineFontAlignZones",
            .csm_text_settings => "CSMTextSettings",
            .define_font3 => "DefineFont3",
            .symbol_class => "SymbolClass",
            .metadata => "Metadata",
            .define_scaling_grid => "DefineScalingGrid",
            .do_abc => "DoABC",
            .define_shape4 => "DefineShape4",
            .define_morph_shape2 => "DefineMorphShape2",
            .define_scene_and_frame_label_data => "DefineSceneAndFrameLabelData",
            .define_binary_data => "DefineBinaryData",
            .define_font_name => "DefineFontName",
            .start_sound2 => "StartSound2",
            .define_bits_jpeg4 => "DefineBitsJPEG4",
            .define_font4 => "DefineFont4",
            .enable_telemetry => "EnableTelemetry",
            _ => "Unknown",
        };
    }
};

pub const Tag = struct {
    code: TagCode,
    /// Raw body — a slice into the movie buffer, never a copy.
    body: []const u8,
    /// Declared length overran the buffer; `body` was clamped.
    truncated: bool = false,

    pub fn rawCode(self: Tag) u16 {
        return @intFromEnum(self.code);
    }
};

pub const TagIterator = struct {
    r: reader.Reader,

    pub fn init(data: []const u8) TagIterator {
        return .{ .r = reader.Reader.init(data) };
    }

    /// Next tag, or null at a clean end of stream. The End tag (code 0) IS
    /// yielded — callers treat it as the frame-stream terminator (sprites
    /// have their own nested End).
    pub fn next(self: *TagIterator) ?Tag {
        if (self.r.remaining() < 2) return null;
        const code_len = self.r.readU16() catch return null;
        const code: u16 = code_len >> 6;
        var len: usize = code_len & 0x3F;
        if (len == 0x3F) {
            len = self.r.readU32() catch return null;
        }
        var truncated = false;
        const body = self.r.readSlice(len) catch blk: {
            truncated = true;
            break :blk self.r.readRest();
        };
        return .{
            .code = @enumFromInt(code),
            .body = body,
            .truncated = truncated,
        };
    }
};

// --- Tests -----------------------------------------------------------------

fn shortTag(comptime code: u16, comptime body: []const u8) [2 + body.len]u8 {
    const cl: u16 = (code << 6) | @as(u16, body.len);
    return [2]u8{ @truncate(cl), @truncate(cl >> 8) } ++ body[0..body.len].*;
}

test "short and long tag records, End yielded" {
    // ShowFrame (empty), SetBackgroundColor (3 bytes), long DoAction
    // (len 0x3F escape + u32), End.
    const long_body = [_]u8{0xAB} ** 70;
    const stream = shortTag(1, "") ++ shortTag(9, &.{ 1, 2, 3 }) ++
        [2]u8{ @truncate((12 << 6) | 0x3F), @truncate(((12 << 6) | 0x3F) >> 8) } ++
        [4]u8{ 70, 0, 0, 0 } ++ long_body ++ shortTag(0, "");

    var it = TagIterator.init(&stream);
    const t1 = it.next().?;
    try std.testing.expectEqual(TagCode.show_frame, t1.code);
    try std.testing.expectEqual(@as(usize, 0), t1.body.len);
    const t2 = it.next().?;
    try std.testing.expectEqual(TagCode.set_background_color, t2.code);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, t2.body);
    const t3 = it.next().?;
    try std.testing.expectEqual(TagCode.do_action, t3.code);
    try std.testing.expectEqual(@as(usize, 70), t3.body.len);
    const t4 = it.next().?;
    try std.testing.expectEqual(TagCode.end, t4.code);
    try std.testing.expectEqual(@as(?Tag, null), it.next());
}

test "unknown codes are representable and truncated bodies clamp" {
    // Code 300 (unknown), declared len 10 but only 4 bytes present.
    const cl: u16 = (300 << 6) | 10;
    const stream = [2]u8{ @truncate(cl), @truncate(cl >> 8) } ++ [4]u8{ 9, 9, 9, 9 };
    var it = TagIterator.init(&stream);
    const t = it.next().?;
    try std.testing.expectEqual(@as(u16, 300), t.rawCode());
    try std.testing.expectEqualStrings("Unknown", t.code.name());
    try std.testing.expect(t.truncated);
    try std.testing.expectEqual(@as(usize, 4), t.body.len);
    try std.testing.expectEqual(@as(?Tag, null), it.next());
}

test "known tag names" {
    try std.testing.expectEqualStrings("PlaceObject2", TagCode.place_object2.name());
    try std.testing.expectEqualStrings("DefineSprite", TagCode.define_sprite.name());
}
