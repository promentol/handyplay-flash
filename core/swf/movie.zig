//! SwfMovie — owns the decompressed payload and the preloaded movie:
//! header, character library (definition tags, decoded eagerly) and the
//! per-frame control-tag index. Everything is allocated from one arena
//! owned by the movie; every slice points into the movie body (no copies).
//!
//! Two-pass model (Ruffle): this preload pass registers definitions and
//! indexes control tags; the timeline (display/movie_clip.zig, M2) executes
//! only the indexed controls. DefineSprite recurses with the same walker.
//!
//! AVM2 rejection: FileAttributes.ActionScript3 (bit 3) or any DoABC/
//! SymbolClass tag ⇒ error.Avm2Unsupported.

const std = @import("std");
const decompress = @import("decompress.zig");
const header = @import("header.zig");
const rdr = @import("reader.zig");
const tags = @import("tags.zig");
const shape = @import("shape.zig");
const font_text = @import("font_text.zig");
const button = @import("button.zig");
const bitmap_tags = @import("bitmap_tags.zig");
const sound_tags = @import("sound_tags.zig");
const place = @import("place.zig");
const library = @import("../display/library.zig");

pub const Error = decompress.Error || header.Error || shape.Error || button.Error ||
    place.Error || sound_tags.Error || error{Avm2Unsupported};

pub const Movie = struct {
    /// Arena backing every allocation below (including `body`).
    arena_state: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,

    swf_version: u8,
    compression: decompress.Compression,
    /// Decompressed payload — all tag/action/bitmap slices point into it.
    body: []const u8,
    /// The `file_length` field from the container header: the whole file's
    /// UNCOMPRESSED size, the 8 signature bytes included. This — not
    /// `body.len` — is what `_root.getBytesTotal()` reports.
    file_length: u32,
    /// The file's size ON DISK — the compressed one for a CWS/ZWS. Ruffle
    /// calls it `compressed_len`, and it is what `MovieClipLoader`'s
    /// progress reports, unlike `getBytesTotal`'s uncompressed figure.
    compressed_len: u32,
    header: header.Header,

    lib: library.Library = .{},
    /// Main timeline frames (frames[i] = frame i+1 in Flash speak).
    frames: []library.Frame = &.{},
    /// Shared JPEG encoding tables (tag 8) for DefineBits characters.
    jpeg_tables: ?[]const u8 = null,
    /// First SetBackgroundColor (also replayed per frame via controls).
    background_color: ?rdr.Color = null,
    /// SoundStreamHead for the main timeline (M6).
    stream_head: ?sound_tags.StreamHead = null,
    /// FileAttributes' UseNetwork bit. The only thing separating
    /// `System.security.sandboxType`'s two local values.
    use_network_sandbox: bool = false,
    /// `ScriptLimits`: how deep AVM1 calls may nest before the whole
    /// action is killed. 256 when the tag is absent.
    max_recursion_depth: u16 = 256,
    /// `ImportAssets`/`ImportAssets2`: other SWFs this one borrows
    /// characters from. Loading them is the PLAYER's job — the parser
    /// only records what was asked for.
    imports: []const Import = &.{},

    pub fn allocator(self: *const Movie) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn deinit(self: *Movie) void {
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.* = undefined;
    }

    pub fn frameLabelToNumber(self: *const Movie, name: []const u8) ?u16 {
        for (self.frames, 0..) |f, i| {
            const label = f.label orelse continue;
            if (std.ascii.eqlIgnoreCase(label, name)) return @intCast(i + 1);
        }
        return null;
    }
};

/// One `ImportAssets` tag: a URL and the (id, name) pairs to take from
/// it. The ids are OURS — the exporting movie names the same characters
/// differently.
pub const Import = struct {
    url: []const u8,
    assets: []const Asset,

    pub const Asset = struct { id: u16, name: []const u8 };
};

/// Load a movie from raw file bytes (FWS/CWS container included).
pub fn load(gpa: std.mem.Allocator, file_bytes: []const u8) Error!Movie {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    var dec = try decompress.decompress(a, file_bytes);
    const h = try header.parse(dec.body);

    var movie: Movie = .{
        .arena_state = arena_state,
        .gpa = gpa,
        .swf_version = dec.version,
        .compression = dec.compression,
        .body = dec.body,
        .file_length = dec.declared_length,
        .compressed_len = @intCast(file_bytes.len),
        .header = h,
    };
    movie.frames = try preloadTimeline(&movie, dec.body[h.tags_offset..], true);
    return movie;
}

/// Walk one tag stream (main timeline or a sprite), registering
/// definitions into the movie library and collecting per-frame controls.
fn preloadTimeline(movie: *Movie, stream: []const u8, is_root: bool) Error![]library.Frame {
    const a = movie.allocator();
    var frames: std.ArrayList(library.Frame) = .empty;
    var controls: std.ArrayList(library.Control) = .empty;
    var pending_label: ?[]const u8 = null;

    var it = tags.TagIterator.init(stream);
    while (it.next()) |tag| {
        const ctx: shape.Context = .{ .swf_version = movie.swf_version, .shape_version = 0 };
        _ = ctx;
        switch (tag.code) {
            .end => break,
            .show_frame => {
                try frames.append(a, .{
                    .label = pending_label,
                    .controls = try controls.toOwnedSlice(a),
                });
                pending_label = null;
            },
            .frame_label => {
                var r = rdr.Reader.init(tag.body);
                pending_label = r.readString() catch tag.body;
            },

            // --- control tags (indexed per frame) -------------------------
            .place_object => try controls.append(a, .{ .place = try place.parsePlace1(tag.body) }),
            .place_object2 => try controls.append(a, .{
                .place = try place.parsePlace23(a, tag.body, 2, movie.swf_version),
            }),
            .place_object3 => try controls.append(a, .{
                .place = try place.parsePlace23(a, tag.body, 3, movie.swf_version),
            }),
            .remove_object => try controls.append(a, .{ .remove = try place.parseRemove(tag.body, 1) }),
            .remove_object2 => try controls.append(a, .{ .remove = try place.parseRemove(tag.body, 2) }),
            .import_assets, .import_assets2 => {
                var r = rdr.Reader.init(tag.body);
                const url = try r.readString();
                // ImportAssets2 has two reserved bytes after the URL.
                if (tag.code == .import_assets2) {
                    _ = try r.readU8();
                    _ = try r.readU8();
                }
                const count = try r.readU16();
                var assets: std.ArrayList(Import.Asset) = .empty;
                var k: u16 = 0;
                while (k < count) : (k += 1) {
                    const id = try r.readU16();
                    const name = try r.readString();
                    try assets.append(a, .{ .id = id, .name = name });
                }
                var list: std.ArrayList(Import) = .empty;
                try list.appendSlice(a, movie.imports);
                try list.append(a, .{ .url = url, .assets = try assets.toOwnedSlice(a) });
                movie.imports = try list.toOwnedSlice(a);
                try controls.append(a, .{ .import = @intCast(movie.imports.len - 1) });
            },
            .do_action => try controls.append(a, .{ .do_action = tag.body }),
            .do_init_action => {
                var r = rdr.Reader.init(tag.body);
                const sprite_id = try r.readU16();
                try controls.append(a, .{ .init_action = .{
                    .sprite_id = sprite_id,
                    .code = tag.body[2..],
                } });
            },
            .set_background_color => {
                var r = rdr.Reader.init(tag.body);
                const c = try r.readRgb();
                if (movie.background_color == null) movie.background_color = c;
                try controls.append(a, .{ .set_background_color = c });
            },
            .start_sound => try controls.append(a, .{
                .start_sound = try sound_tags.parseStartSound(a, tag.body),
            }),
            .sound_stream_block => try controls.append(a, .{ .sound_stream_block = tag.body }),
            .sound_stream_head, .sound_stream_head2 => {
                if (is_root and movie.stream_head == null) {
                    movie.stream_head = try sound_tags.parseStreamHead(tag.body);
                }
            },

            // --- definition tags (library) --------------------------------
            .define_shape => try putShape(movie, tag.body, 1),
            .define_shape2 => try putShape(movie, tag.body, 2),
            .define_shape3 => try putShape(movie, tag.body, 3),
            .define_shape4 => try putShape(movie, tag.body, 4),
            .define_morph_shape, .define_morph_shape2 => {
                var r = rdr.Reader.init(tag.body);
                const id = try r.readU16();
                try movie.lib.put(a, id, .{ .morph_shape = .{
                    .id = id,
                    .version = if (tag.code == .define_morph_shape) 1 else 2,
                    .body = tag.body,
                } });
            },
            .script_limits => {
                // The movie's own recursion cap. Flash counts FUNCTION
                // frames against it, so a limit of 5 lets four nested
                // calls run and kills the fifth — taking the whole
                // action with it (corpus infinite_recursion_function).
                var r = rdr.Reader.init(tag.body);
                movie.max_recursion_depth = try r.readU16();
            },
            .define_video_stream => {
                var r = rdr.Reader.init(tag.body);
                const id = try r.readU16();
                const num_frames = try r.readU16();
                const width = try r.readU16();
                const height = try r.readU16();
                _ = try r.readU8(); // flags: deblocking + smoothing
                const codec = try r.readU8();
                try movie.lib.put(a, id, .{ .video = .{
                    .id = id,
                    .num_frames = num_frames,
                    .width = width,
                    .height = height,
                    .codec = codec,
                } });
            },
            .define_sprite => {
                var r = rdr.Reader.init(tag.body);
                const id = try r.readU16();
                const frame_count = try r.readU16();
                const sprite_frames = try preloadTimeline(movie, tag.body[4..], false);
                try movie.lib.put(a, id, .{ .sprite = .{
                    .id = id,
                    .frame_count = frame_count,
                    .frames = sprite_frames,
                    // A sprite's getBytesTotal is the length of its OWN tag
                    // stream (ruffle MovieClip::tag_stream_len).
                    .tag_stream_len = tag.body.len -| 4,
                } });
            },
            .define_font => {
                const f = try font_text.parseFont1(a, tag.body, movie.swf_version);
                try movie.lib.put(a, f.id, .{ .font = f });
            },
            .define_font2, .define_font3 => {
                const v: u8 = if (tag.code == .define_font2) 2 else 3;
                const f = try font_text.parseFont2(a, tag.body, v, movie.swf_version);
                try movie.lib.put(a, f.id, .{ .font = f });
            },
            .define_font_info, .define_font_info2 => {
                const v: u8 = if (tag.code == .define_font_info) 1 else 2;
                const info = try font_text.parseFontInfo(a, tag.body, v);
                // Fold codes into the referenced font in place.
                if (movie.lib.getPtr(info.font_id)) |c| switch (c.*) {
                    .font => |*f| {
                        for (f.glyphs, 0..) |*g, i| {
                            if (i < info.codes.len) g.code = info.codes[i];
                        }
                        // DefineFont1 carries no name or style — the
                        // FontInfo beside it is the ONLY place a v1 face
                        // can be looked up by name from.
                        if (f.name.len == 0) f.name = info.name;
                        f.is_bold = info.is_bold;
                        f.is_italic = info.is_italic;
                    },
                    else => {},
                };
            },
            .define_text => {
                const t = try font_text.parseText(a, tag.body, 1);
                try movie.lib.put(a, t.id, .{ .text = t });
            },
            .define_text2 => {
                const t = try font_text.parseText(a, tag.body, 2);
                try movie.lib.put(a, t.id, .{ .text = t });
            },
            .csm_text_settings => {
                const c = try font_text.parseCsmTextSettings(tag.body);
                try movie.lib.csm.put(a, c.id, c);
            },
            .define_edit_text => {
                const et = try font_text.parseEditText(tag.body);
                try movie.lib.put(a, et.id, .{ .edit_text = et });
            },
            .define_button => {
                const btn = try button.parseButton1(a, tag.body);
                try movie.lib.put(a, btn.id, .{ .button = btn });
            },
            .define_button2 => {
                const btn = try button.parseButton2(a, tag.body);
                try movie.lib.put(a, btn.id, .{ .button = btn });
            },
            .jpeg_tables => movie.jpeg_tables = tag.body,
            .define_bits => {
                const bmp = try bitmap_tags.parseBits(tag.body);
                try movie.lib.put(a, bmp.id, .{ .bitmap = .{ .jpeg_needs_tables = bmp } });
            },
            .define_bits_jpeg2 => {
                const bmp = try bitmap_tags.parseJpeg2(tag.body);
                try movie.lib.put(a, bmp.id, .{ .bitmap = .{ .jpeg2 = bmp } });
            },
            .define_bits_jpeg3 => {
                const bmp = try bitmap_tags.parseJpeg3(tag.body);
                try movie.lib.put(a, bmp.id, .{ .bitmap = .{ .jpeg3 = bmp } });
            },
            .define_bits_lossless, .define_bits_lossless2 => {
                const v: u8 = if (tag.code == .define_bits_lossless) 1 else 2;
                const bmp = try bitmap_tags.parseLossless(tag.body, v);
                try movie.lib.put(a, bmp.id, .{ .bitmap = .{ .lossless = bmp } });
            },
            .define_sound => {
                const s = try sound_tags.parseSound(tag.body);
                try movie.lib.put(a, s.id, .{ .sound = s });
            },
            .export_assets => {
                var r = rdr.Reader.init(tag.body);
                const n = try r.readU16();
                for (0..n) |_| {
                    const id = try r.readU16();
                    const name = try r.readString();
                    try movie.lib.exports.put(a, name, id);
                }
            },

            // --- AVM2 gate -------------------------------------------------
            .file_attributes => {
                var r = rdr.Reader.init(tag.body);
                const flags = try r.readU32();
                if ((flags & (1 << 3)) != 0) return Error.Avm2Unsupported;
                movie.use_network_sandbox = (flags & 1) != 0;
            },
            // SymbolClass alone appears in AVM1 movies from newer IDEs —
            // only actual AVM2 bytecode (DoABC) or the FileAttributes AS3
            // bit rejects the file.
            .do_abc, .do_abc_define => return Error.Avm2Unsupported,

            // Everything else: skip by length (tolerance policy).
            else => {},
        }
    }
    // Flush a trailing partial frame (streams that end without ShowFrame).
    if (controls.items.len > 0 or pending_label != null) {
        try frames.append(a, .{
            .label = pending_label,
            .controls = try controls.toOwnedSlice(a),
        });
    }
    return frames.toOwnedSlice(a);
}

fn putShape(movie: *Movie, body: []const u8, version: u8) Error!void {
    const a = movie.allocator();
    const s = try shape.parse(a, body, .{
        .swf_version = movie.swf_version,
        .shape_version = version,
    });
    try movie.lib.put(a, s.id, .{ .shape = s });
}

// --- Tests -----------------------------------------------------------------

test "load squares.swf: library + frames + rejection of AVM2" {
    // Corpus-backed integration lives in tests/parse_corpus.sh; here a
    // synthetic movie: header + DefineSprite wrapping 2 frames + main
    // timeline placing it, 1 ShowFrame.
    const gpa = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);

    // Payload: rect nbits=0 (1 byte), rate 12.0, 1 frame.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, &.{ 0x00, 0x00, 12, 1, 0 });
    // DefineSprite id=1, 2 frames, body: ShowFrame, DoAction{Stop,End}, ShowFrame, End.
    const sprite_body = comptime [_]u8{ 1, 0, 2, 0 } ++
        tagBytes(1, "") ++ tagBytes(12, &.{ 0x07, 0x00 }) ++ tagBytes(1, "") ++ tagBytes(0, "");
    try payload.appendSlice(gpa, &tagBytes(39, &sprite_body));
    // PlaceObject2: place id 1 at depth 1 (flags=2, depth, id).
    try payload.appendSlice(gpa, &tagBytes(26, &.{ 2, 1, 0, 1, 0 }));
    try payload.appendSlice(gpa, &tagBytes(43, "intro\x00")); // FrameLabel
    try payload.appendSlice(gpa, &tagBytes(1, "")); // ShowFrame
    try payload.appendSlice(gpa, &tagBytes(0, "")); // End

    // FWS container.
    try b.appendSlice(gpa, "FWS\x06");
    var len4: [4]u8 = undefined;
    std.mem.writeInt(u32, &len4, @intCast(payload.items.len + 8), .little);
    try b.appendSlice(gpa, &len4);
    try b.appendSlice(gpa, payload.items);

    var m = try load(gpa, b.items);
    defer m.deinit();
    try std.testing.expectEqual(@as(u8, 6), m.swf_version);
    try std.testing.expectEqual(@as(usize, 1), m.frames.len);
    try std.testing.expectEqualStrings("intro", m.frames[0].label.?);
    try std.testing.expectEqual(@as(u16, 1), m.frameLabelToNumber("INTRO").?);
    try std.testing.expectEqual(@as(usize, 1), m.frames[0].controls.len);
    try std.testing.expectEqual(@as(u16, 1), m.frames[0].controls[0].place.action.place);
    const sprite = m.lib.get(1).?.sprite;
    try std.testing.expectEqual(@as(u16, 2), sprite.frame_count);
    try std.testing.expectEqual(@as(usize, 2), sprite.frames.len);
    try std.testing.expectEqual(@as(usize, 1), sprite.frames[1].controls.len);

    // AVM2 gate: FileAttributes with the AS3 bit.
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(gpa);
    var payload2: std.ArrayList(u8) = .empty;
    defer payload2.deinit(gpa);
    try payload2.appendSlice(gpa, &.{ 0x00, 0x00, 12, 1, 0 });
    try payload2.appendSlice(gpa, &tagBytes(69, &.{ 0x08, 0, 0, 0 }));
    try payload2.appendSlice(gpa, &tagBytes(0, ""));
    try b2.appendSlice(gpa, "FWS\x09");
    std.mem.writeInt(u32, &len4, @intCast(payload2.items.len + 8), .little);
    try b2.appendSlice(gpa, &len4);
    try b2.appendSlice(gpa, payload2.items);
    try std.testing.expectError(Error.Avm2Unsupported, load(gpa, b2.items));
}

fn tagBytes(comptime code: u16, comptime body: []const u8) [2 + body.len]u8 {
    const cl: u16 = (code << 6) | @as(u16, body.len);
    return [2]u8{ @truncate(cl), @truncate(cl >> 8) } ++ body[0..body.len].*;
}
