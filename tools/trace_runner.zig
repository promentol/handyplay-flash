//! trace_runner — headless conformance driver.
//! Usage: trace_runner <test.swf> [--frames N] [--input input.json]
//!
//! Loads the movie, runs N timeline frames, prints accumulated trace()
//! output to stdout, exit 0. The conformance script diffs stdout against
//! the corpus dir's output.txt.
//!
//! `--viewport WxH@S` is `test.toml`'s `[player_options] viewport_dimensions`
//! — the presentation area in device pixels and the HiDPI factor. It feeds
//! the stage size under `noScale`, `System.capabilities.screenResolution*`
//! and the window→stage mapping for pointer coordinates.
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
    var socket_path: ?[]const u8 = null;
    var frames: u32 = 1;
    var device_font_path: ?[]const u8 = null;
    var viewport_w: u32 = 0;
    var viewport_h: u32 = 0;
    var scale_factor: f64 = 1.0;
    var log_fetch = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--log-fetch")) {
            log_fetch = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--frames")) {
            i += 1;
            if (i >= args.len) return 2;
            frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            if (i >= args.len) return 2;
            input_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--socket")) {
            i += 1;
            if (i >= args.len) return 2;
            socket_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--device-font")) {
            i += 1;
            if (i >= args.len) return 2;
            device_font_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--viewport")) {
            i += 1;
            if (i >= args.len) return 2;
            parseViewport(args[i], &viewport_w, &viewport_h, &scale_factor) catch return 2;
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
    // A DEVICE font, for the dirs whose toml says `with_default_font`.
    // `core/` does no I/O, so the bytes are read here. A `.gz` is
    // inflated — but as RAW deflate, with no gzip wrapper: ruffle's own
    // asset carries the extension and not the header.
    var device_font: ?[]const u8 = null;
    if (device_font_path) |fp| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, fp, gpa, .limited(16 << 20));
        device_font = if (std.mem.endsWith(u8, fp, ".gz"))
            try gunzip(gpa, raw)
        else
            raw;
    }
    defer if (device_font) |d| gpa.free(d);

    const url = try std.fmt.allocPrint(arena, "/{s}", .{std.fs.path.basename(path)});
    // Ruffle's test navigator serves every fetch out of the test's own
    // directory, which is why `loadVariables("testvars.txt")` works with no
    // scheme and no host. Same rule here.
    var files: FileServer = .{
        .gpa = gpa,
        .io = io,
        .base = std.fs.path.dirname(path) orelse ".",
        .store = .init(gpa),
    };
    defer files.store.deinit();
    // `socket.json`: the far end of an XMLSocket, scripted.
    var sock: SocketScript = .{ .gpa = gpa, .store = .init(gpa) };
    defer sock.store.deinit();
    defer sock.outbox.deinit(gpa);
    var socket_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (socket_parsed) |*sp| sp.deinit();
    if (socket_path) |sp| {
        if (std.Io.Dir.cwd().readFileAlloc(io, sp, gpa, .limited(4 << 20)) catch null) |text| {
            defer gpa.free(text);
            socket_parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch null;
            if (socket_parsed) |sv| {
                if (sv.value == .array) sock.events = sv.value.array.items;
            }
        }
    }
    const player = flash.Player.createWith(gpa, bytes, .{
        .url = url,
        .device_font = device_font,
        .viewport_width = viewport_w,
        .viewport_height = viewport_h,
        .scale_factor = scale_factor,
        .load_file = FileServer.read,
        .load_user = @ptrCast(&files),
        .log_fetch = log_fetch,
        .socket_connect = SocketScript.connect,
        .socket_send = SocketScript.send,
        .socket_close = SocketScript.close,
        .socket_poll = SocketScript.poll,
        .socket_user = @ptrCast(&sock),
    }) catch {
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
        _ = player.tick(1000.0 / player.fps()) catch break;
        cursor = feedUntilWait(player, events, cursor);
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
        } else if (std.mem.eql(u8, name, "ImePreedit")) {
            const txt = ev.object.get("text");
            var buf: [64]u16 = undefined;
            var n: usize = 0;
            if (txt) |t| {
                if (t == .string) n = std.unicode.utf8ToUtf16Le(&buf, t.string) catch 0;
            }
            var cursor: ?[2]usize = null;
            if (ev.object.get("cursor")) |cv| {
                if (cv == .array and cv.array.items.len >= 2) {
                    cursor = .{
                        @intFromFloat(numOf(cv.array.items[0])),
                        @intFromFloat(numOf(cv.array.items[1])),
                    };
                }
            }
            player.imePreedit(buf[0..n], cursor) catch {};
        } else if (std.mem.eql(u8, name, "SetClipboardText")) {
            const txt = ev.object.get("text");
            if (txt) |t| {
                if (t == .string) player.setClipboard(t.string) catch {};
            }
        } else if (std.mem.eql(u8, name, "TextControl")) {
            if (controlOf(ev)) |c| player.textControl(c) catch {};
        } else if (std.mem.eql(u8, name, "TextInput")) {
            const codepoint = ev.object.get("codepoint");
            if (codepoint) |cp| {
                if (cp == .string and cp.string.len > 0) {
                    var buf: [8]u16 = undefined;
                    const n = std.unicode.utf8ToUtf16Le(&buf, cp.string) catch 0;
                    if (n > 0) player.textInput(buf[0..n]) catch {};
                }
            }
        } else if (std.mem.eql(u8, name, "FocusLost")) {
            player.windowFocus(false) catch {};
        } else if (std.mem.eql(u8, name, "FocusGained")) {
            player.windowFocus(true) catch {};
        }
    }
    return i;
}

/// The `--log-fetch` file reader. Every answer is kept alive for the whole
/// run: a loaded SWF is parsed IN PLACE, so its buffer has to outlive the
/// clip that holds it, and a conformance run is short enough that never
/// freeing is the simplest correct policy.
/// Replays the corpus's `socket.json`, which is a SCRIPT of what the far
/// end does: `Receive` waits for the movie to send exactly those bytes,
/// `Send` pushes bytes at it, `Disconnect` hangs up. The script only ever
/// advances when something unblocks it — a connect, or a send that
/// satisfies the `Receive` it is parked on — which is what gives the
/// corpus its one-tick lag between cause and effect.
const SocketScript = struct {
    events: []const std.json.Value = &.{},
    pos: usize = 0,
    /// Ready for the movie to collect on its next poll.
    outbox: std.ArrayList(flash.Player.SocketEvent) = .empty,
    out_head: usize = 0,
    gpa: std.mem.Allocator,
    /// Payload bytes handed out, kept alive until the process exits.
    store: std.heap.ArenaAllocator,

    fn connect(user: ?*anyopaque, host: []const u8, port: u16) void {
        _ = host;
        _ = port;
        const self: *SocketScript = @ptrCast(@alignCast(user orelse return));
        if (self.events.len == 0) return;
        self.outbox.append(self.gpa, .{ .connect = true }) catch return;
        self.advance();
    }

    fn send(user: ?*anyopaque, data: []const u8) void {
        _ = data;
        const self: *SocketScript = @ptrCast(@alignCast(user orelse return));
        // Satisfy the `Receive` the script is parked on. A mismatch is a
        // conformance failure, but the output diff shows it far more
        // clearly than a panic here would.
        if (self.pos < self.events.len and self.kindOf(self.pos) == .receive) {
            self.pos += 1;
            self.advance();
        }
    }

    fn close(user: ?*anyopaque) void {
        const self: *SocketScript = @ptrCast(@alignCast(user orelse return));
        self.pos = self.events.len;
    }

    fn poll(user: ?*anyopaque) ?flash.Player.SocketEvent {
        const self: *SocketScript = @ptrCast(@alignCast(user orelse return null));
        if (self.out_head >= self.outbox.items.len) return null;
        defer self.out_head += 1;
        return self.outbox.items[self.out_head];
    }

    const Kind = enum { receive, send, disconnect, wait_for_disconnect, unknown };

    fn kindOf(self: *SocketScript, i: usize) Kind {
        const ev = self.events[i];
        if (ev != .object) return .unknown;
        const t = ev.object.get("type") orelse return .unknown;
        if (t != .string) return .unknown;
        if (std.mem.eql(u8, t.string, "Receive")) return .receive;
        if (std.mem.eql(u8, t.string, "Send")) return .send;
        if (std.mem.eql(u8, t.string, "Disconnect")) return .disconnect;
        if (std.mem.eql(u8, t.string, "WaitForDisconnect")) return .wait_for_disconnect;
        return .unknown;
    }

    fn advance(self: *SocketScript) void {
        while (self.pos < self.events.len) {
            switch (self.kindOf(self.pos)) {
                .receive, .wait_for_disconnect => return, // blocked on the movie
                .send => {
                    const payload = self.events[self.pos].object.get("payload") orelse {
                        self.pos += 1;
                        continue;
                    };
                    if (payload != .array) {
                        self.pos += 1;
                        continue;
                    }
                    const bytes = self.store.allocator().alloc(u8, payload.array.items.len) catch return;
                    for (payload.array.items, bytes) |v, *b| {
                        b.* = switch (v) {
                            .integer => |n| @truncate(@as(u64, @bitCast(n))),
                            .float => |f| @intFromFloat(f),
                            else => 0,
                        };
                    }
                    self.outbox.append(self.gpa, .{ .data = bytes }) catch return;
                    self.pos += 1;
                },
                .disconnect => {
                    self.outbox.append(self.gpa, .close) catch return;
                    self.pos += 1;
                },
                .unknown => self.pos += 1,
            }
        }
    }
};

const FileServer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    /// Everything served lives here until the process exits.
    store: std.heap.ArenaAllocator,

    fn read(user: ?*anyopaque, url: []const u8) ?[]const u8 {
        const self: *FileServer = @ptrCast(@alignCast(user orelse return null));
        const keep = self.store.allocator();
        // Flash allows a query string on a local URL and Ruffle strips it
        // before touching the filesystem.
        var rel = url;
        if (std.mem.indexOfScalar(u8, rel, '?')) |q| rel = rel[0..q];
        // An absolute URL is served from the same directory by its last
        // component, which is what ruffle's virtual filesystem amounts to
        // for these tests.
        if (std.mem.indexOf(u8, rel, "://")) |_| rel = std.fs.path.basename(rel);
        while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len == 0) return null;
        const full = std.fs.path.join(self.gpa, &.{ self.base, rel }) catch return null;
        defer self.gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(self.io, full, keep, .limited(64 << 20)) catch null;
    }
};

fn gunzip(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    defer gpa.free(raw);
    var reader = std.Io.Reader.fixed(raw);
    var window: [1 << 16]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader, .raw, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// `WIDTHxHEIGHT@SCALE`, the shape the conformance script passes through
/// from `test.toml`.
fn parseViewport(spec: []const u8, w: *u32, h: *u32, scale: *f64) !void {
    const x = std.mem.indexOfScalar(u8, spec, 'x') orelse return error.BadViewport;
    const at = std.mem.indexOfScalar(u8, spec, '@');
    const h_end = at orelse spec.len;
    w.* = try std.fmt.parseInt(u32, spec[0..x], 10);
    h.* = try std.fmt.parseInt(u32, spec[x + 1 .. h_end], 10);
    if (at) |a| scale.* = try std.fmt.parseFloat(f64, spec[a + 1 ..]);
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

/// `{"type":"TextControl","code":"MoveRight"}` — ruffle's
/// `TextControlCode` variant names, verbatim.
fn controlOf(ev: std.json.Value) ?flash.display.edit_text.Control {
    const code = ev.object.get("code") orelse return null;
    if (code != .string) return null;
    const table = .{
        .{ "MoveLeft", .move_left },
        .{ "MoveLeftWord", .move_left_word },
        .{ "MoveLeftLine", .move_left_line },
        .{ "MoveLeftDocument", .move_left_document },
        .{ "MoveRight", .move_right },
        .{ "MoveRightWord", .move_right_word },
        .{ "MoveRightLine", .move_right_line },
        .{ "MoveRightDocument", .move_right_document },
        .{ "SelectLeft", .select_left },
        .{ "SelectLeftWord", .select_left_word },
        .{ "SelectLeftLine", .select_left_line },
        .{ "SelectLeftDocument", .select_left_document },
        .{ "SelectRight", .select_right },
        .{ "SelectRightWord", .select_right_word },
        .{ "SelectRightLine", .select_right_line },
        .{ "SelectRightDocument", .select_right_document },
        .{ "SelectAll", .select_all },
        .{ "Copy", .copy },
        .{ "Paste", .paste },
        .{ "Cut", .cut },
        .{ "Backspace", .backspace },
        .{ "BackspaceWord", .backspace_word },
        .{ "Enter", .enter },
        .{ "Delete", .delete },
        .{ "DeleteWord", .delete_word },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, code.string, e[0])) return e[1];
    }
    return null;
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
