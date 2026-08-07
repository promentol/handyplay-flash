//! Character dictionary: id → decoded definition. Populated by the movie
//! preload pass (swf/movie.zig); read by the timeline when instantiating
//! children and by the renderer.
//!
//! Decoding is EAGER (at preload, into the movie's arena): SWF dictionaries
//! are small relative to the pixel work, and eager decode keeps run_frame /
//! run_goto allocation-free.

const std = @import("std");
const swf = @import("../swf/swf.zig");

pub const Sprite = struct {
    id: u16,
    frame_count: u16,
    frames: []Frame,
    /// Bytes of DefineSprite payload after the id/frame-count header —
    /// what `getBytesTotal()` reports for a clip that is not the root.
    tag_stream_len: usize = 0,
};

/// One timeline frame: the control tags to execute, in stream order.
pub const Frame = struct {
    /// Label attached to this frame (FrameLabel tag), if any.
    label: ?[]const u8 = null,
    controls: []Control = &.{},
};

pub const Control = union(enum) {
    place: swf.place.PlaceObject,
    remove: swf.place.RemoveObject,
    /// AVM1 bytecode (queued, never run inline).
    do_action: []const u8,
    /// DoInitAction — runs ONCE, before the sprite's first frame, at
    /// Initialize priority (ruffle ActionType::Initialize).
    init_action: struct { sprite_id: u16, code: []const u8 },
    set_background_color: swf.reader.Color,
    start_sound: swf.sound_tags.StartSound,
    /// Raw frame-synced audio block (M6).
    sound_stream_block: []const u8,
};

pub const Character = union(enum) {
    shape: swf.shape.Shape,
    /// Raw DefineMorphShape body (decoded in M7).
    morph_shape: struct { id: u16, version: u8, body: []const u8 },
    font: swf.font_text.Font,
    text: swf.font_text.Text,
    edit_text: swf.font_text.EditText,
    button: swf.button.Button,
    bitmap: Bitmap,
    sound: swf.sound_tags.Sound,
    sprite: Sprite,
};

pub const Bitmap = union(enum) {
    /// DefineBits — needs the movie-level JPEGTables stream.
    jpeg_needs_tables: swf.bitmap_tags.Bits,
    jpeg2: swf.bitmap_tags.Jpeg2,
    jpeg3: swf.bitmap_tags.Jpeg3,
    lossless: swf.bitmap_tags.Lossless,
};

pub const Library = struct {
    characters: std.AutoHashMapUnmanaged(u16, Character) = .empty,
    /// ExportAssets: name → id (attachMovie / AVM1 linkage).
    exports: std.StringHashMapUnmanaged(u16) = .empty,

    pub fn put(self: *Library, allocator: std.mem.Allocator, id: u16, c: Character) !void {
        // First definition wins (Flash ignores duplicate ids).
        const gop = try self.characters.getOrPut(allocator, id);
        if (!gop.found_existing) gop.value_ptr.* = c;
    }

    pub fn get(self: *const Library, id: u16) ?Character {
        return self.characters.get(id);
    }

    pub fn getPtr(self: *Library, id: u16) ?*Character {
        return self.characters.getPtr(id);
    }

    /// Const lookup with a stable pointer (the library is frozen after
    /// preload, so hashmap pointers never move afterwards).
    pub fn getConstPtr(self: *const Library, id: u16) ?*const Character {
        return self.characters.getPtr(id);
    }
};
