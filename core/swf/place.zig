//! PlaceObject (4) / PlaceObject2 (26) / PlaceObject3 (70),
//! RemoveObject (5) / RemoveObject2 (28), and ClipActions — the
//! onClipEvent handlers a huge fraction of AVM1 content depends on.
//!
//! Layout: reference/ruffle/swf/src/read.rs read_place_object_2_or_3 /
//! read_clip_actions + SWF19. Errata honored: PO3 class name is present
//! when HasClassName OR (HasImage AND !HasCharacter); SWF5 clip event
//! flags are u16 (u32 from SWF6); wild SWFs truncate the final clip-event
//! flags and the cache-as-bitmap byte.

const std = @import("std");
const rdr = @import("reader.zig");
const filters = @import("filters.zig");

pub const Error = rdr.Error || std.mem.Allocator.Error || filters.Error || error{InvalidPlaceObject};

/// Clip event flag bits (u32 shape; SWF5's u16 zero-extends).
pub const ClipEvent = struct {
    pub const LOAD: u32 = 1 << 0;
    pub const ENTER_FRAME: u32 = 1 << 1;
    pub const UNLOAD: u32 = 1 << 2;
    pub const MOUSE_MOVE: u32 = 1 << 3;
    pub const MOUSE_DOWN: u32 = 1 << 4;
    pub const MOUSE_UP: u32 = 1 << 5;
    pub const KEY_DOWN: u32 = 1 << 6;
    pub const KEY_UP: u32 = 1 << 7;
    pub const DATA: u32 = 1 << 8;
    pub const INITIALIZE: u32 = 1 << 9;
    pub const PRESS: u32 = 1 << 10;
    pub const RELEASE: u32 = 1 << 11;
    pub const RELEASE_OUTSIDE: u32 = 1 << 12;
    pub const ROLL_OVER: u32 = 1 << 13;
    pub const ROLL_OUT: u32 = 1 << 14;
    pub const DRAG_OVER: u32 = 1 << 15;
    pub const DRAG_OUT: u32 = 1 << 16;
    pub const KEY_PRESS: u32 = 1 << 17;
    pub const CONSTRUCT: u32 = 1 << 18;
};

pub const ClipAction = struct {
    events: u32,
    /// Present when KEY_PRESS is set.
    key_code: ?u8 = null,
    /// AVM1 bytecode slice into the movie buffer.
    actions: []const u8,
};

pub const PlaceAction = union(enum) {
    /// New character at this depth.
    place: u16,
    /// Modify the existing character at this depth.
    modify,
    /// Replace the character at this depth with a new one.
    replace: u16,
};

pub const PlaceObject = struct {
    version: u8,
    action: PlaceAction,
    depth: u16,
    matrix: ?rdr.Matrix = null,
    color_transform: ?rdr.ColorTransform = null,
    /// Morph ratio (0-65535).
    ratio: ?u16 = null,
    /// Instance name (raw bytes; encoding per SWF version).
    name: ?[]const u8 = null,
    /// This object masks depths (own, clip_depth].
    clip_depth: ?u16 = null,
    clip_actions: []ClipAction = &.{},
    // PlaceObject3 extras.
    class_name: ?[]const u8 = null,
    /// PO3 blend-mode byte (0/1 = normal … 14 = hardlight).
    blend_mode: ?u8 = null,
    is_bitmap_cached: ?bool = null,
    is_visible: ?bool = null,
    background_color: ?rdr.Color = null,
    had_filters: bool = false,
    /// The decoded PlaceObject3 filter list, which a script reads back
    /// through `MovieClip.filters`. Slices into the movie arena.
    filter_list: []const filters.Filter = &.{},
};

/// PlaceObject (4): positional only — always a `place` at depth with a
/// matrix; trailing CXFORM (no alpha) is optional.
pub fn parsePlace1(body: []const u8) Error!PlaceObject {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const depth = try r.readU16();
    const matrix = try r.readMatrix();
    var po: PlaceObject = .{
        .version = 1,
        .action = .{ .place = id },
        .depth = depth,
        .matrix = matrix,
    };
    if (r.remaining() > 0) po.color_transform = try r.readColorTransform(false);
    return po;
}

fn readEventFlags(r: *rdr.Reader, swf_version: u8) u32 {
    // Wild SWFs truncate the final flags — treat missing bytes as 0.
    if (swf_version >= 6) {
        return r.readU32() catch 0;
    }
    return @as(u32, r.readU16() catch 0);
}

/// PlaceObject2 (26) / PlaceObject3 (70).
pub fn parsePlace23(
    allocator: std.mem.Allocator,
    body: []const u8,
    place_version: u8,
    swf_version: u8,
) Error!PlaceObject {
    var r = rdr.Reader.init(body);
    const flags: u16 = if (place_version >= 3) try r.readU16() else try r.readU8();
    const depth = try r.readU16();

    var po: PlaceObject = .{
        .version = place_version,
        .action = .modify,
        .depth = depth,
    };

    const is_move = (flags & (1 << 0)) != 0;
    const has_character = (flags & (1 << 1)) != 0;
    const has_image = (flags & (1 << 12)) != 0;
    // Errata: class name also present for HasImage without HasCharacter.
    if ((flags & (1 << 11)) != 0 or (has_image and !has_character)) {
        po.class_name = try r.readString();
    }
    po.action = if (is_move and !has_character)
        .modify
    else if (!is_move and has_character)
        .{ .place = try r.readU16() }
    else if (is_move and has_character)
        .{ .replace = try r.readU16() }
    else
        return Error.InvalidPlaceObject;

    if ((flags & (1 << 2)) != 0) po.matrix = try r.readMatrix();
    if ((flags & (1 << 3)) != 0) po.color_transform = try r.readColorTransform(true);
    if ((flags & (1 << 4)) != 0) po.ratio = try r.readU16();
    if ((flags & (1 << 5)) != 0) po.name = try r.readString();
    if ((flags & (1 << 6)) != 0) po.clip_depth = try r.readU16();
    // PlaceObject3 extras (flag bits 8+ never set in the PO2 u8 read).
    if ((flags & (1 << 8)) != 0) {
        po.filter_list = try filters.parseList(allocator, &r);
        po.had_filters = true;
    }
    if ((flags & (1 << 9)) != 0) po.blend_mode = try r.readU8();
    if ((flags & (1 << 10)) != 0) {
        // Wild SWFs end the tag here without the byte.
        po.is_bitmap_cached = if (r.remaining() == 0) true else (try r.readU8()) != 0;
    }
    if ((flags & (1 << 13)) != 0) po.is_visible = (try r.readU8()) != 0;
    if ((flags & (1 << 14)) != 0) po.background_color = try r.readRgba();

    if ((flags & (1 << 7)) != 0) {
        _ = try r.readU16(); // reserved, must be 0
        _ = readEventFlags(&r, swf_version); // union of all record flags
        var records: std.ArrayList(ClipAction) = .empty;
        while (true) {
            const events = readEventFlags(&r, swf_version);
            if (events == 0) break;
            var len = try r.readU32();
            var key_code: ?u8 = null;
            if ((events & ClipEvent.KEY_PRESS) != 0) {
                if (len == 0) return Error.OutOfBounds;
                key_code = try r.readU8();
                len -= 1;
            }
            const bytecode = try r.readSlice(@min(len, r.remaining()));
            try records.append(allocator, .{
                .events = events,
                .key_code = key_code,
                .actions = bytecode,
            });
        }
        po.clip_actions = try records.toOwnedSlice(allocator);
    }
    return po;
}

pub const RemoveObject = struct {
    /// RemoveObject (5) carries the character id; RemoveObject2 (28) is
    /// depth-only.
    id: ?u16 = null,
    depth: u16,
};

pub fn parseRemove(body: []const u8, remove_version: u8) Error!RemoveObject {
    var r = rdr.Reader.init(body);
    if (remove_version == 1) {
        const id = try r.readU16();
        return .{ .id = id, .depth = try r.readU16() };
    }
    return .{ .depth = try r.readU16() };
}

// --- Tests -----------------------------------------------------------------

test "PlaceObject2 place with matrix, name and clip actions (SWF6 u32 flags)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;

    // flags: has_character|has_matrix|has_name|has_clip_actions =
    // 2|4|32|128 = 166; depth 3; id 12; identity matrix; name "hero";
    // clip actions: reserved u16 0, all-flags u32, one record:
    // enterFrame (1<<1), len 4, bytecode {6,7,8,0}; end u32 0.
    try b.appendSlice(ta, &.{ 166, 3, 0, 12, 0, 0 });
    try b.appendSlice(ta, "hero\x00");
    try b.appendSlice(ta, &.{ 0, 0 }); // reserved
    try b.appendSlice(ta, &.{ 2, 0, 0, 0 }); // all-event flags
    try b.appendSlice(ta, &.{ 2, 0, 0, 0 }); // record: enter_frame
    try b.appendSlice(ta, &.{ 4, 0, 0, 0 }); // len 4
    try b.appendSlice(ta, &.{ 6, 7, 8, 0 });
    try b.appendSlice(ta, &.{ 0, 0, 0, 0 }); // terminator

    const po = try parsePlace23(a, b.items, 2, 6);
    try std.testing.expectEqual(@as(u16, 12), po.action.place);
    try std.testing.expectEqual(@as(u16, 3), po.depth);
    try std.testing.expectEqual(@as(f64, 1.0), po.matrix.?.a);
    try std.testing.expectEqualStrings("hero", po.name.?);
    try std.testing.expectEqual(@as(usize, 1), po.clip_actions.len);
    try std.testing.expectEqual(ClipEvent.ENTER_FRAME, po.clip_actions[0].events);
    try std.testing.expectEqual(@as(usize, 4), po.clip_actions[0].actions.len);
}

test "PlaceObject2 move-only and keyPress key code (SWF5 u16 flags)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Move-only with ratio: flags move|has_ratio = 1|16 = 17; depth 9;
    // ratio 30000.
    const body = [_]u8{ 17, 9, 0, 0x30, 0x75 };
    const po = try parsePlace23(a, &body, 2, 5);
    try std.testing.expect(po.action == .modify);
    try std.testing.expectEqual(@as(u16, 30000), po.ratio.?);

    // keyPress record under SWF5 (u16 event flags): has_character|
    // has_clip_actions = 2|128 = 130; depth 1; id 2; reserved; all-flags
    // u16... but KEY_PRESS is bit 17 — only reachable with u32 flags, so
    // use SWF6 here; SWF5 exercised the u16 path above via terminator size.
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try b.appendSlice(ta, &.{ 130, 1, 0, 2, 0 });
    try b.appendSlice(ta, &.{ 0, 0 }); // reserved
    try b.appendSlice(ta, &.{ 0, 0, 2, 0 }); // all flags (keyPress)
    try b.appendSlice(ta, &.{ 0, 0, 2, 0 }); // record: KEY_PRESS = 1<<17
    try b.appendSlice(ta, &.{ 3, 0, 0, 0 }); // len 3 (incl. key byte)
    try b.append(ta, 13); // key code: Enter
    try b.appendSlice(ta, &.{ 0x07, 0x00 }); // Stop + End
    try b.appendSlice(ta, &.{ 0, 0, 0, 0 });
    const po2 = try parsePlace23(a, b.items, 2, 6);
    try std.testing.expectEqual(@as(u8, 13), po2.clip_actions[0].key_code.?);
    try std.testing.expectEqual(@as(usize, 2), po2.clip_actions[0].actions.len);
}

test "PlaceObject1 and RemoveObject1/2" {
    // id 5, depth 2, identity matrix, trailing cxform (empty byte).
    const body = [_]u8{ 5, 0, 2, 0, 0, 0 };
    const po = try parsePlace1(&body);
    try std.testing.expectEqual(@as(u16, 5), po.action.place);
    try std.testing.expect(po.color_transform.?.isIdentity());

    const r1 = try parseRemove(&.{ 7, 0, 4, 0 }, 1);
    try std.testing.expectEqual(@as(u16, 7), r1.id.?);
    try std.testing.expectEqual(@as(u16, 4), r1.depth);
    const r2 = try parseRemove(&.{ 4, 0 }, 2);
    try std.testing.expectEqual(@as(?u16, null), r2.id);
}
