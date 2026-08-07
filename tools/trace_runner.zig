//! trace_runner — headless conformance driver.
//! Usage: trace_runner <test.swf> [--frames N] [--input input.json]
//!
//! Loads the movie, runs N timeline frames, prints accumulated trace()
//! output to stdout, exit 0. The conformance script diffs stdout against
//! the corpus dir's output.txt.
//!
//! `--input` replays ruffle's `input.json` format: an array of events,
//! where `Wait` marks the end of a tick. Everything before the next `Wait`
//! is delivered, then one frame runs — that is exactly what ruffle's
//! `InputInjector::next` does per tick.

const std = @import("std");
const flash = @import("flash");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var swf_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var frames: u32 = 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames")) {
            i += 1;
            if (i >= args.len) return 2;
            frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            if (i >= args.len) return 2;
            input_path = args[i];
        } else if (swf_path == null) {
            swf_path = args[i];
        } else return 2;
    }
    const path = swf_path orelse {
        try out.writeAll("usage: trace_runner <test.swf> [--frames N] [--input input.json]\n");
        try out.flush();
        return 2;
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    // `_url` is the path Flash loaded from. Ruffle's test harness serves
    // each corpus SWF from the root of a virtual filesystem, so the
    // expected output says "/test.swf" — mirror that with the basename.
    const url = try std.fmt.allocPrint(arena, "/{s}", .{std.fs.path.basename(path)});
    const player = flash.Player.createWith(gpa, bytes, .{ .url = url }) catch {
        // A movie we can't run produces no trace output (several corpus
        // dirs are AVM2/image-comparison tests whose expected stdout is
        // empty). Diagnostics go to stderr, never stdout.
        try out.flush();
        return 0;
    };
    defer player.destroy();

    var events: []const std.json.Value = &.{};
    var cursor: usize = 0;
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*pv| pv.deinit();
    if (input_path) |ip| {
        const json = std.Io.Dir.cwd().readFileAlloc(io, ip, gpa, .limited(4 << 20)) catch null;
        if (json) |text| {
            defer gpa.free(text);
            parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch null;
            if (parsed) |pv| {
                if (pv.value == .array) events = pv.value.array.items;
            }
        }
    }

    // One event batch per TICK. Ruffle feeds before each of its
    // `num_frames` ticks; our frame 1 already ran inside `create`, so the
    // first batch is delivered immediately after it and the rest keep the
    // before-the-tick position. Getting this off by one drops the events
    // after the final `Wait` entirely.
    cursor = feedUntilWait(player, events, cursor);
    var f: u32 = 1;
    while (f < frames) : (f += 1) {
        cursor = feedUntilWait(player, events, cursor);
        _ = player.tick(1000.0 / player.fps()) catch break;
    }

    try out.writeAll(player.takeTrace());
    try out.flush();
    return 0;
}

/// Deliver events up to and including the next `Wait`, and return the new
/// cursor. Unknown event types are skipped — the corpus has plenty that
/// only mean something to a text field or a clipboard.
fn feedUntilWait(player: *flash.Player, events: []const std.json.Value, start: usize) usize {
    var i = start;
    while (i < events.len) : (i += 1) {
        const ev = events[i];
        if (ev != .object) continue;
        const kind = ev.object.get("type") orelse continue;
        if (kind != .string) continue;
        const name = kind.string;
        if (std.mem.eql(u8, name, "Wait")) return i + 1;
        if (std.mem.eql(u8, name, "MouseMove")) {
            const p = posOf(ev);
            player.mouseMove(p[0], p[1]) catch {};
        } else if (std.mem.eql(u8, name, "MouseDown")) {
            // The position rides along but is NOT a move event of its own.
            const p = posOf(ev);
            player.setMousePosition(p[0], p[1]);
            player.mouseButton(buttonOf(ev), true) catch {};
        } else if (std.mem.eql(u8, name, "MouseUp")) {
            const p = posOf(ev);
            player.setMousePosition(p[0], p[1]);
            player.mouseButton(buttonOf(ev), false) catch {};
        } else if (std.mem.eql(u8, name, "KeyDown")) {
            const k = keyOf(ev);
            player.keyDown(k[0], k[1]) catch {};
        } else if (std.mem.eql(u8, name, "KeyUp")) {
            const k = keyOf(ev);
            player.keyUp(k[0], k[1]) catch {};
        }
    }
    return i;
}

fn posOf(ev: std.json.Value) [2]f64 {
    const pos = ev.object.get("pos") orelse return .{ 0, 0 };
    if (pos != .array or pos.array.items.len < 2) return .{ 0, 0 };
    return .{ numOf(pos.array.items[0]), numOf(pos.array.items[1]) };
}

fn numOf(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => 0,
    };
}

fn buttonOf(ev: std.json.Value) u8 {
    const btn = ev.object.get("btn") orelse return 0;
    if (btn != .string) return 0;
    if (std.mem.eql(u8, btn.string, "Middle")) return 1;
    if (std.mem.eql(u8, btn.string, "Right")) return 2;
    return 0;
}

/// `{"key": "Tab"}` or `{"key": {"Char": "a"}}` → (Flash key code, ASCII).
///
/// Flash's key codes are the Windows virtual-key numbering, in which a
/// letter's code is its UPPERCASE ASCII value while `Key.getAscii` reports
/// the character as typed.
fn keyOf(ev: std.json.Value) [2]i32 {
    const key = ev.object.get("key") orelse return .{ 0, 0 };
    switch (key) {
        .string => |name| return .{ namedKeyCode(name), 0 },
        .object => |o| {
            const ch = o.get("Char") orelse o.get("Numpad") orelse return .{ 0, 0 };
            if (ch != .string or ch.string.len == 0) return .{ 0, 0 };
            const c: i32 = ch.string[0];
            const upper: i32 = if (c >= 'a' and c <= 'z') c - 32 else c;
            return .{ upper, c };
        },
        else => return .{ 0, 0 },
    }
}

fn namedKeyCode(name: []const u8) i32 {
    const table = .{
        .{ "Backspace", 8 },  .{ "Tab", 9 },       .{ "Enter", 13 },
        .{ "LeftShift", 16 }, .{ "RightShift", 16 }, .{ "LeftControl", 17 },
        .{ "RightControl", 17 }, .{ "LeftAlt", 18 }, .{ "RightAlt", 18 },
        .{ "CapsLock", 20 },  .{ "Escape", 27 },   .{ "Space", 32 },
        .{ "PageUp", 33 },    .{ "PageDown", 34 }, .{ "End", 35 },
        .{ "Home", 36 },      .{ "ArrowLeft", 37 }, .{ "ArrowUp", 38 },
        .{ "ArrowRight", 39 }, .{ "ArrowDown", 40 }, .{ "Insert", 45 },
        .{ "Delete", 46 },    .{ "F1", 112 },      .{ "F2", 113 },
        .{ "F3", 114 },       .{ "F4", 115 },      .{ "F5", 116 },
        .{ "F6", 117 },       .{ "F7", 118 },      .{ "F8", 119 },
        .{ "F9", 120 },       .{ "F10", 121 },     .{ "F11", 122 },
        .{ "F12", 123 },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return 0;
}
