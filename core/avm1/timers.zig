//! setInterval / setTimeout — the one place AVM1 code runs outside the
//! timeline.
//!
//! The table is a plain list rather than a heap: content rarely has more
//! than a handful of timers, and the tick loop has to tolerate the list
//! being mutated by the callbacks it invokes (a timer may clear itself, or
//! add more), which a heap makes fiddly for no gain here.
//!
//! Times are in MICROSECONDS. Ruffle scales milliseconds by 1000 so that
//! sub-millisecond frame deltas still accumulate instead of rounding to
//! nothing (core/src/timer.rs TIMER_SCALE).
//!
//! Reference: reference/ruffle/core/src/timer.rs and
//! core/src/avm1/globals.rs create_timer.

const std = @import("std");
const strings = @import("string.zig");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const ObjectHandle = value_mod.ObjectHandle;

/// Flash never hands out timer id 0 — content uses it as "not set up yet".
pub const Callback = union(enum) {
    /// `setInterval(fn, ms, ...args)`
    func: ObjectHandle,
    /// `setInterval(obj, "name", ms, ...args)` — resolved at FIRE time, so
    /// reassigning `obj.name` between ticks changes what runs.
    method: struct { this: ObjectHandle, name: strings.AvmString },
};

pub const Timer = struct {
    id: i32,
    callback: Callback,
    params: []const Value,
    /// Absolute microsecond deadline.
    tick_time: u64,
    interval: u64,
    /// setTimeout: fires once, then removes itself.
    is_timeout: bool,
};

pub const Timers = struct {
    list: std.ArrayList(Timer) = .empty,
    counter: i32 = 0,
    cur_time: u64 = 0,

    /// Below this, content that asks for `setInterval(f, 0)` would spin.
    pub const MIN_INTERVAL_MS: i64 = 10;
    /// Ruffle's sanity cap on callbacks per update.
    pub const MAX_TICKS: u32 = 10;
    const SCALE: u64 = 1000;

    pub fn deinit(self: *Timers, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }

    pub fn add(
        self: *Timers,
        gpa: std.mem.Allocator,
        callback: Callback,
        params: []const Value,
        interval_ms: i64,
        is_timeout: bool,
    ) !i32 {
        const interval = @as(u64, @intCast(@max(interval_ms, MIN_INTERVAL_MS))) * SCALE;
        self.counter +%= 1;
        const id = self.counter;
        try self.list.append(gpa, .{
            .id = id,
            .callback = callback,
            .params = params,
            .tick_time = self.cur_time + interval,
            .interval = interval,
            .is_timeout = is_timeout,
        });
        return id;
    }

    pub fn remove(self: *Timers, id: i32) bool {
        for (self.list.items, 0..) |t, i| {
            if (t.id != id) continue;
            _ = self.list.orderedRemove(i);
            return true;
        }
        return false;
    }

    pub fn exists(self: *const Timers, id: i32) bool {
        for (self.list.items) |t| {
            if (t.id == id) return true;
        }
        return false;
    }

    pub fn advance(self: *Timers, dt_ms: f64) void {
        if (dt_ms <= 0) return;
        self.cur_time +%= @intFromFloat(dt_ms * @as(f64, SCALE));
    }

    /// The timer that should fire next, or null when nothing is due. Due
    /// means STRICTLY before the current time, matching ruffle's `<`.
    pub fn due(self: *Timers) ?*Timer {
        var best: ?*Timer = null;
        for (self.list.items) |*t| {
            if (t.tick_time >= self.cur_time) continue;
            if (best == null or t.tick_time < best.?.tick_time) best = t;
        }
        return best;
    }

    /// After a callback: drop a timeout (or a cancelled interval), re-arm an
    /// interval. The timer may have removed itself, so look it up by id.
    pub fn reschedule(self: *Timers, id: i32, cancelled: bool) void {
        for (self.list.items, 0..) |*t, i| {
            if (t.id != id) continue;
            if (t.is_timeout or cancelled) {
                _ = self.list.orderedRemove(i);
            } else {
                t.tick_time +%= t.interval;
            }
            return;
        }
    }

    /// Pull the clock back just short of `t` — the escape hatch when a
    /// single update would otherwise fire more than MAX_TICKS callbacks.
    pub fn backOff(self: *Timers, t: *const Timer) void {
        self.cur_time = t.tick_time -% 100;
    }
};

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "intervals re-arm, timeouts do not, and the minimum interval holds" {
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    // A 0ms request is clamped to 10ms, so nothing is due after 5ms.
    const a = try timers.add(testing.allocator, .{ .func = 1 }, &.{}, 0, false);
    const b = try timers.add(testing.allocator, .{ .func = 2 }, &.{}, 25, true);
    try testing.expectEqual(@as(i32, 1), a);
    try testing.expectEqual(@as(i32, 2), b);

    timers.advance(5);
    try testing.expectEqual(@as(?*Timer, null), timers.due());

    timers.advance(6); // 11ms total
    try testing.expectEqual(a, timers.due().?.id);
    timers.reschedule(a, false);
    // Re-armed for 20ms, so it is not due again yet.
    try testing.expectEqual(@as(?*Timer, null), timers.due());

    // 31ms: both are overdue and the EARLIEST deadline wins — the
    // re-armed interval at 20ms, not the timeout at 25ms.
    timers.advance(20);
    try testing.expectEqual(a, timers.due().?.id);
    // A callback returning true cancels its own interval.
    timers.reschedule(a, true);
    try testing.expect(!timers.exists(a));

    try testing.expectEqual(b, timers.due().?.id);
    timers.reschedule(b, false);
    try testing.expect(!timers.exists(b)); // a timeout never re-arms
    try testing.expectEqual(@as(?*Timer, null), timers.due());
}
