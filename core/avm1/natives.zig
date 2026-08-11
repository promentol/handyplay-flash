//! Stable ids for native functions that can be installed AFTER boot.
//!
//! A save-state does not write function POINTERS: a fresh boot installs
//! every built-in at the same handle, so the live slot already holds the
//! right one (core/savestate.zig `readNative`). That reasoning holds for
//! everything the globals installer puts on a prototype — and fails for
//! the handful of natives that land on an INSTANCE at runtime, because
//! the restored heap slot is brand new and has no pointer to keep.
//!
//! `Sound`'s `duration` and `position` are the only two today: they are
//! defined on the object when its bytes arrive, and without an id here a
//! restored sound reports `undefined` for both (corpus
//! sound_duration_position_props). Anything else installed outside an
//! `install*` function belongs in this table too — one line each.

const object = @import("object.zig");
const sound = @import("globals/sound.zig");
const globals = @import("globals/globals.zig");

pub const NativeFn = object.NativeFn;

/// Append only: the index IS the serialized id.
pub const TABLE = [_]NativeFn{
    sound.getDuration,
    sound.getPosition,
};

/// 1-based, so 0 can mean "not in the table — keep the live pointer".
pub fn idOf(f: NativeFn) u16 {
    inline for (TABLE, 0..) |entry, i| {
        if (entry == f) return @intCast(i + 1);
    }
    return 0;
}

pub fn get(id: u16) ?NativeFn {
    if (id == 0 or id > TABLE.len) return null;
    return TABLE[id - 1];
}

/// The `ASnative` categories, which are what a TABLE native's function
/// pointer really is. A script can make one at runtime — `ASnative(200,
/// 1)` is a live `Math.abs` — so the same reasoning as above applies:
/// there is no boot-installed slot to inherit the pointer from, and the
/// category number is the stable name for it.
pub const CATEGORIES = [_]u32{ 2, 4, 100, 103, 200, 1109 };

pub fn categoryOf(f: object.TableNativeFn) u32 {
    for (CATEGORIES) |cat| {
        if (globals.nativeCategory(cat)) |g| {
            if (g == f) return cat;
        }
    }
    return 0;
}

pub fn tableFn(cat: u32) ?object.TableNativeFn {
    if (cat == 0) return null;
    return globals.nativeCategory(cat);
}

test "every ASnative category round-trips" {
    const std = @import("std");
    for (CATEGORIES) |cat| {
        const f = tableFn(cat) orelse return error.MissingCategory;
        try std.testing.expectEqual(cat, categoryOf(f));
    }
    try std.testing.expect(tableFn(0) == null);
}

test "the table round-trips its own entries" {
    const std = @import("std");
    for (TABLE) |f| {
        const id = idOf(f);
        try std.testing.expect(id != 0);
        try std.testing.expectEqual(f, get(id).?);
    }
    try std.testing.expect(get(0) == null);
    try std.testing.expect(get(TABLE.len + 1) == null);
}
