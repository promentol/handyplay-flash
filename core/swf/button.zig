//! DefineButton (7) / DefineButton2 (34) + DefineButtonCxform (23) /
//! DefineButtonSound (17).
//!
//! Layout reference: reference/ruffle/swf/src/read.rs read_button_record /
//! read_define_button_1 / read_define_button_2 + SWF19. Filter lists inside
//! button2 records are skipped (filters.zig) — filters render in a later
//! milestone.

const std = @import("std");
const rdr = @import("reader.zig");
const filters = @import("filters.zig");

pub const Error = rdr.Error || std.mem.Allocator.Error || filters.Error;

pub const ButtonRecord = struct {
    /// State bits: up(1), over(2), down(4), hit_test(8).
    state_up: bool,
    state_over: bool,
    state_down: bool,
    state_hit_test: bool,
    id: u16,
    depth: u16,
    matrix: rdr.Matrix,
    /// Button2 only (identity for button1).
    color_transform: rdr.ColorTransform = .{},
    /// Button2/SWF8: PlaceObject3-style blend mode byte (0/1 = normal).
    blend_mode: u8 = 0,
    /// Filters present but skipped (M1 policy).
    had_filters: bool = false,
};

pub const CondAction = struct {
    /// Transition condition bits (ButtonActionCondition order:
    /// idle→over_up = 1<<0 … over_down→idle = 1<<8; key code in bits 9-15).
    conditions: u16,
    /// AVM1 bytecode slice into the movie buffer.
    actions: []const u8,

    pub fn keyPress(self: CondAction) u7 {
        return @intCast(self.conditions >> 9);
    }
    pub fn onRelease(self: CondAction) bool {
        return (self.conditions & (1 << 3)) != 0; // over_down → over_up
    }
};

pub const Button = struct {
    version: u8,
    id: u16,
    /// Button2 flag: track as menu button.
    is_track_as_menu: bool = false,
    records: []ButtonRecord,
    /// Button1: at most one entry (conditions = over_down→over_up, i.e.
    /// the classic on(release)); button2: one per ButtonCondAction.
    actions: []CondAction,
};

fn parseRecord(r: *rdr.Reader, version: u8) Error!?ButtonRecord {
    const flags = try r.readU8();
    if (flags == 0) return null;
    var rec: ButtonRecord = .{
        .state_up = (flags & 1) != 0,
        .state_over = (flags & 2) != 0,
        .state_down = (flags & 4) != 0,
        .state_hit_test = (flags & 8) != 0,
        .id = try r.readU16(),
        .depth = try r.readU16(),
        .matrix = try r.readMatrix(),
    };
    if (version >= 2) {
        rec.color_transform = try r.readColorTransform(true);
        if ((flags & 0b1_0000) != 0) {
            _ = try filters.skipList(r);
            rec.had_filters = true;
        }
        if ((flags & 0b10_0000) != 0) rec.blend_mode = try r.readU8();
    }
    return rec;
}

/// DefineButton (7): records then one trailing action blob (runs on
/// over_down → over_up, the classic release).
pub fn parseButton1(allocator: std.mem.Allocator, body: []const u8) Error!Button {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    var records: std.ArrayList(ButtonRecord) = .empty;
    while (try parseRecord(&r, 1)) |rec| try records.append(allocator, rec);
    const bytecode = r.readRest();
    var actions: std.ArrayList(CondAction) = .empty;
    if (bytecode.len > 0) {
        try actions.append(allocator, .{ .conditions = 1 << 3, .actions = bytecode });
    }
    return .{
        .version = 1,
        .id = id,
        .records = try records.toOwnedSlice(allocator),
        .actions = try actions.toOwnedSlice(allocator),
    };
}

/// DefineButton2 (34): flags + action offset + records + ButtonCondActions.
pub fn parseButton2(allocator: std.mem.Allocator, body: []const u8) Error!Button {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    const flags = try r.readU8();
    const action_offset_pos = r.pos;
    const action_offset = try r.readU16();

    var records: std.ArrayList(ButtonRecord) = .empty;
    while (try parseRecord(&r, 2)) |rec| try records.append(allocator, rec);

    var actions: std.ArrayList(CondAction) = .empty;
    if (action_offset != 0) {
        // Offset is relative to its own field position.
        var pos = action_offset_pos + action_offset;
        while (pos + 4 <= body.len) {
            var ar = rdr.Reader.init(body[pos..]);
            const size = try ar.readU16();
            const conditions = try ar.readU16();
            const bytecode: []const u8 = if (size == 0)
                ar.readRest()
            else if (pos + size <= body.len)
                body[pos + 4 .. pos + size]
            else
                body[pos + 4 ..]; // truncated tail — clamp
            try actions.append(allocator, .{ .conditions = conditions, .actions = bytecode });
            if (size == 0) break; // last entry
            pos += size;
        }
    }
    return .{
        .version = 2,
        .id = id,
        .is_track_as_menu = (flags & 1) != 0,
        .records = try records.toOwnedSlice(allocator),
        .actions = try actions.toOwnedSlice(allocator),
    };
}

/// DefineButtonCxform (23): button id + one or MORE color transforms
/// applied in sequence (errata — the spec claims one).
pub fn parseButtonCxform(allocator: std.mem.Allocator, body: []const u8) Error!struct {
    id: u16,
    transforms: []rdr.ColorTransform,
} {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    var list: std.ArrayList(rdr.ColorTransform) = .empty;
    while (r.remaining() > 0) {
        try list.append(allocator, try r.readColorTransform(false));
    }
    return .{ .id = id, .transforms = try list.toOwnedSlice(allocator) };
}

// --- Tests -----------------------------------------------------------------

test "DefineButton2 with two states and one cond action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;

    try b.appendSlice(ta, &.{ 4, 0 }); // id = 4
    try b.append(ta, 0); // flags: not track-as-menu
    // Records: up+over record (char 10, depth 1), hit record (char 11, d 2).
    // Each: flags, id, depth, identity matrix (1 byte 0), empty cxform (1
    // byte 0). Record block = 1 + 2 + 2 + 1 + 1 = 7 bytes ×2 + terminator.
    const rec1 = [_]u8{ 0b0011, 10, 0, 1, 0, 0, 0 };
    const rec2 = [_]u8{ 0b1000, 11, 0, 2, 0, 0, 0 };
    // action_offset = distance from its own field to the first cond action:
    // 2 (offset field) + 14 (records) + 1 (terminator) = 17.
    try b.appendSlice(ta, &.{ 17, 0 });
    try b.appendSlice(ta, &rec1);
    try b.appendSlice(ta, &rec2);
    try b.append(ta, 0); // record terminator
    // CondAction: size=0 (last), conditions = over_down→over_up (1<<3),
    // bytecode = one End action (0x00).
    try b.appendSlice(ta, &.{ 0, 0, 0b1000, 0, 0x00 });

    const btn = try parseButton2(a, b.items);
    try std.testing.expectEqual(@as(u16, 4), btn.id);
    try std.testing.expectEqual(@as(usize, 2), btn.records.len);
    try std.testing.expect(btn.records[0].state_up and btn.records[0].state_over);
    try std.testing.expect(btn.records[1].state_hit_test);
    try std.testing.expectEqual(@as(u16, 11), btn.records[1].id);
    try std.testing.expectEqual(@as(usize, 1), btn.actions.len);
    try std.testing.expect(btn.actions[0].onRelease());
    try std.testing.expectEqual(@as(usize, 1), btn.actions[0].actions.len);
}

test "DefineButton1 trailing actions become an on-release entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 9, 0 } // id
        ++ [_]u8{ 0b0111, 5, 0, 1, 0, 0 } // record: up|over|down, char 5, depth 1, identity matrix
        ++ [_]u8{0} // terminator
        ++ [_]u8{ 0x81, 0x03, 0x00, 0x07, 0x00, 0x00 }; // GotoFrame 7 + End
    const btn = try parseButton1(a, &body);
    try std.testing.expectEqual(@as(usize, 1), btn.records.len);
    try std.testing.expectEqual(@as(usize, 1), btn.actions.len);
    try std.testing.expect(btn.actions[0].onRelease());
    try std.testing.expectEqual(@as(usize, 6), btn.actions[0].actions.len);
}
