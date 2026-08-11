//! A libretro host small enough to test with: dlopen the core, wire the
//! five callbacks, load a SWF, run frames, optionally HOLD a pad button.
//!
//!   libretro_test_host <core.dylib> <game.swf> [--frames N] [--hold BUTTON]
//!                                             [--solid] [--stick x,y] [--quiet]
//!
//! With `--hold`, it runs the movie TWICE — once untouched, once with the
//! button held from frame 1 — and reports how many pixels differ at the
//! end. That is the "does this game react to the pad" measurement, taken
//! through the real C ABI rather than by calling into the core directly,
//! so the ABI itself is under test: a wrong callconv or a missing export
//! shows up here and nowhere else.
//!
//! Exists because the alternative is installing RetroArch to find out
//! whether `retro_run` crashes.

const std = @import("std");

const BUTTONS = [_]struct { name: []const u8, id: c_uint }{
    .{ .name = "b", .id = 0 },
    .{ .name = "y", .id = 1 },
    .{ .name = "select", .id = 2 },
    .{ .name = "start", .id = 3 },
    .{ .name = "up", .id = 4 },
    .{ .name = "down", .id = 5 },
    .{ .name = "left", .id = 6 },
    .{ .name = "right", .id = 7 },
    .{ .name = "a", .id = 8 },
    .{ .name = "x", .id = 9 },
    .{ .name = "l", .id = 10 },
    .{ .name = "r", .id = 11 },
};

const GameInfo = extern struct {
    path: ?[*:0]const u8,
    data: ?*const anyopaque,
    size: usize,
    meta: ?[*:0]const u8,
};

const SystemAvInfo = extern struct {
    base_width: c_uint,
    base_height: c_uint,
    max_width: c_uint,
    max_height: c_uint,
    aspect_ratio: f32,
    fps: f64,
    sample_rate: f64,
};

const LogCallback = extern struct {
    log: ?*const fn (c_uint, [*:0]const u8, ...) callconv(.c) void,
};

// --- the callbacks the core will hold -----------------------------------------

var fb: []u32 = &.{};
var fb_w: c_uint = 0;
var fb_h: c_uint = 0;
var quiet = false;
/// The harness turns the boot shell OFF by default: it measures whether a
/// movie reacted, and an ad in front of it is three seconds of the same
/// picture. `--shell` puts it back.
var want_shell = false;
/// `--audio` reports whether anything came out of the mixer at all.
var want_audio = false;
/// `--state N` runs the save-state gates after N frames.
var state_frames: ?u32 = null;
/// `--pointer <mode>` answers the core's `flash_pointer` option, and the
/// stick is only pushed for the first `stick_frames` — a constant shove
/// pins the cursor in a corner, where it is both useless and invisible.
var pointer_mode: ?[]const u8 = null;
var stick_frames: u32 = 25;

/// Held pad state, driven by `--hold`.
var held_id: ?c_uint = null;
var stick: [2]i16 = .{ 0, 0 };
var frame_no: u32 = 0;
/// `--hold` PULSES by default: two frames down, then up, every ten.
///
/// Holding a button for the whole run finds almost nothing, and the
/// reason is not the mapping — a movie sees key EVENTS, so a button held
/// from frame 1 produces exactly one edge, at a moment when most of these
/// games are still on a preloader. Real play is a series of presses.
/// `--solid` restores the held behaviour for the cases that want it.
var pulse_period: u32 = 10;
var pulse_len: u32 = 2;
/// `--point x,y`, in FRACTIONS of the stage: drives RETRO_DEVICE_POINTER,
/// which is absolute, and pulses its press like a button. The only way to
/// exercise the six movies that never read a key.
var point: ?[2]f64 = null;

fn logFn(_: c_uint, fmt: [*:0]const u8, ...) callconv(.c) void {
    if (quiet) return;
    // The core only ever logs `"%s\n"` with one string; anything else is
    // printed as its format, which is enough for a harness.
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const f = std.mem.sliceTo(fmt, 0);
    if (std.mem.eql(u8, f, "%s\n")) {
        const s = @cVaArg(&ap, [*:0]const u8);
        std.debug.print("  [core] {s}\n", .{std.mem.sliceTo(s, 0)});
    } else std.debug.print("  [core] {s}", .{f});
}

var logger: LogCallback = .{ .log = logFn };

fn envCb(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    switch (cmd) {
        10 => { // SET_PIXEL_FORMAT
            const fmt: *c_uint = @ptrCast(@alignCast(data orelse return false));
            return fmt.* == 1; // XRGB8888
        },
        15 => { // GET_VARIABLE
            const v: *extern struct { key: ?[*:0]const u8, value: ?[*:0]const u8 } =
                @ptrCast(@alignCast(data orelse return false));
            const key = std.mem.sliceTo(v.key orelse return false, 0);
            if (std.mem.eql(u8, key, "flash_boot")) {
                v.value = if (want_shell) "on" else "off";
                return true;
            }
            if (std.mem.eql(u8, key, "flash_speed")) {
                v.value = speed_opt orelse return false;
                return true;
            }
            if (std.mem.eql(u8, key, "flash_pointer")) {
                const m = pointer_mode orelse return false;
                v.value = if (std.mem.eql(u8, m, "joystick"))
                    "joystick"
                else if (std.mem.eql(u8, m, "touch"))
                    "touch"
                else if (std.mem.eql(u8, m, "off"))
                    "off"
                else
                    "auto";
                return true;
            }
            return false;
        },
        16 => { // SET_VARIABLES — printed, because the per-button binds
            // are BUILT FROM THE MOVIE and are the thing worth checking.
            if (quiet) return true;
            const V = extern struct { key: ?[*:0]const u8, value: ?[*:0]const u8 };
            const p: [*]const V = @ptrCast(@alignCast(data orelse return true));
            var i: usize = 0;
            while (p[i].key) |k| : (i += 1) {
                std.debug.print("  option {s} = {s}\n", .{
                    std.mem.sliceTo(k, 0),
                    std.mem.sliceTo(p[i].value orelse continue, 0),
                });
            }
            return true;
        },
        17 => { // GET_VARIABLE_UPDATE
            const upd: *bool = @ptrCast(@alignCast(data orelse return false));
            upd.* = false;
            return true;
        },
        11 => { // SET_INPUT_DESCRIPTORS
            if (quiet) return true;
            const Desc = extern struct {
                port: c_uint,
                device: c_uint,
                index: c_uint,
                id: c_uint,
                description: ?[*:0]const u8,
            };
            const p: [*]const Desc = @ptrCast(@alignCast(data orelse return true));
            var i: usize = 0;
            while (p[i].description) |d| : (i += 1) {
                std.debug.print("  descriptor id={d}: {s}\n", .{ p[i].id, std.mem.sliceTo(d, 0) });
            }
            return true;
        },
        27 => { // GET_LOG_INTERFACE
            const out: *LogCallback = @ptrCast(@alignCast(data orelse return false));
            out.* = logger;
            return true;
        },
        else => return false,
    }
}

fn videoCb(data: ?*const anyopaque, w: c_uint, h: c_uint, pitch: usize) callconv(.c) void {
    fb_w = w;
    fb_h = h;
    const d = data orelse return;
    if (fb.len < w * h) return;
    const src: [*]const u8 = @ptrCast(d);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        @memcpy(
            std.mem.sliceAsBytes(fb[y * w ..][0..w]),
            src[y * pitch ..][0 .. w * 4],
        );
    }
}

/// The sum of |sample| across the run — how a harness hears. An ear is
/// better at judging music; a number is better at noticing SILENCE, which
/// is the only audio failure that matters before anyone listens.
var audio_energy: u64 = 0;
var audio_frames: u64 = 0;

fn audioBatch(data: ?[*]const i16, frames: usize) callconv(.c) usize {
    audio_frames += frames;
    if (data) |d| {
        var i: usize = 0;
        while (i < frames * 2) : (i += 1) audio_energy += @abs(@as(i32, d[i]));
    }
    return frames;
}
fn inputPoll() callconv(.c) void {}

fn inputState(_: c_uint, device: c_uint, index: c_uint, id: c_uint) callconv(.c) i16 {
    if (device == 1) { // JOYPAD
        const want = held_id orelse return 0;
        if (id != want) return 0;
        if (pulse_period == 0) return 1; // --solid
        return if (frame_no % pulse_period < pulse_len) 1 else 0;
    }
    // ANALOG left
    if (device == 5 and index == 0 and frame_no < stick_frames) {
        return stick[if (id == 0) 0 else 1];
    }
    if (device == 6) { // POINTER, absolute in [-0x7fff, 0x7fff]
        const p = point orelse return 0;
        return switch (id) {
            0 => @intFromFloat(p[0] * 65534.0 - 32767.0),
            1 => @intFromFloat(p[1] * 65534.0 - 32767.0),
            2 => if (pulse_period == 0 or frame_no % pulse_period < pulse_len) 1 else 0,
            else => 0,
        };
    }
    return 0;
}

// --- the core's exports --------------------------------------------------------

const Core = struct {
    lib: std.DynLib,
    api_version: *const fn () callconv(.c) c_uint,
    set_environment: *const fn (?*const anyopaque) callconv(.c) void,
    set_video_refresh: *const fn (?*const anyopaque) callconv(.c) void,
    set_audio_sample: *const fn (?*const anyopaque) callconv(.c) void,
    set_audio_sample_batch: *const fn (?*const anyopaque) callconv(.c) void,
    set_input_poll: *const fn (?*const anyopaque) callconv(.c) void,
    set_input_state: *const fn (?*const anyopaque) callconv(.c) void,
    init: *const fn () callconv(.c) void,
    deinit: *const fn () callconv(.c) void,
    get_system_av_info: *const fn (*SystemAvInfo) callconv(.c) void,
    load_game: *const fn (?*const GameInfo) callconv(.c) bool,
    unload_game: *const fn () callconv(.c) void,
    run: *const fn () callconv(.c) void,
    reset: *const fn () callconv(.c) void,
    serialize_size: *const fn () callconv(.c) usize,
    serialize: *const fn (?*anyopaque, usize) callconv(.c) bool,
    unserialize: *const fn (?*const anyopaque, usize) callconv(.c) bool,

    fn open(path: []const u8) !Core {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        return .{
            .lib = lib,
            .api_version = lib.lookup(@FieldType(Core, "api_version"), "retro_api_version") orelse return error.MissingSymbol,
            .set_environment = lib.lookup(@FieldType(Core, "set_environment"), "retro_set_environment") orelse return error.MissingSymbol,
            .set_video_refresh = lib.lookup(@FieldType(Core, "set_video_refresh"), "retro_set_video_refresh") orelse return error.MissingSymbol,
            .set_audio_sample = lib.lookup(@FieldType(Core, "set_audio_sample"), "retro_set_audio_sample") orelse return error.MissingSymbol,
            .set_audio_sample_batch = lib.lookup(@FieldType(Core, "set_audio_sample_batch"), "retro_set_audio_sample_batch") orelse return error.MissingSymbol,
            .set_input_poll = lib.lookup(@FieldType(Core, "set_input_poll"), "retro_set_input_poll") orelse return error.MissingSymbol,
            .set_input_state = lib.lookup(@FieldType(Core, "set_input_state"), "retro_set_input_state") orelse return error.MissingSymbol,
            .init = lib.lookup(@FieldType(Core, "init"), "retro_init") orelse return error.MissingSymbol,
            .deinit = lib.lookup(@FieldType(Core, "deinit"), "retro_deinit") orelse return error.MissingSymbol,
            .get_system_av_info = lib.lookup(@FieldType(Core, "get_system_av_info"), "retro_get_system_av_info") orelse return error.MissingSymbol,
            .load_game = lib.lookup(@FieldType(Core, "load_game"), "retro_load_game") orelse return error.MissingSymbol,
            .unload_game = lib.lookup(@FieldType(Core, "unload_game"), "retro_unload_game") orelse return error.MissingSymbol,
            .run = lib.lookup(@FieldType(Core, "run"), "retro_run") orelse return error.MissingSymbol,
            .reset = lib.lookup(@FieldType(Core, "reset"), "retro_reset") orelse return error.MissingSymbol,
            .serialize_size = lib.lookup(@FieldType(Core, "serialize_size"), "retro_serialize_size") orelse return error.MissingSymbol,
            .serialize = lib.lookup(@FieldType(Core, "serialize"), "retro_serialize") orelse return error.MissingSymbol,
            .unserialize = lib.lookup(@FieldType(Core, "unserialize"), "retro_unserialize") orelse return error.MissingSymbol,
        };
    }

    fn wire(self: *const Core) void {
        self.set_environment(@ptrCast(&envCb));
        self.set_video_refresh(@ptrCast(&videoCb));
        self.set_audio_sample(null);
        self.set_audio_sample_batch(@ptrCast(&audioBatch));
        self.set_input_poll(@ptrCast(&inputPoll));
        self.set_input_state(@ptrCast(&inputState));
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    g_io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) {
        std.debug.print(
            "usage: libretro_test_host <core.dylib> <game.swf> [--frames N] [--hold BUTTON] [--stick x,y] [--quiet]\n" ++
                "buttons: b y select start up down left right a x l r\n",
            .{},
        );
        return 2;
    }
    var frames: u32 = 120;
    var hold: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            i += 1;
            frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--hold") and i + 1 < args.len) {
            i += 1;
            hold = args[i];
        } else if (std.mem.eql(u8, args[i], "--stick") and i + 1 < args.len) {
            i += 1;
            const comma = std.mem.indexOfScalar(u8, args[i], ',') orelse return error.BadStick;
            stick[0] = try std.fmt.parseInt(i16, args[i][0..comma], 10);
            stick[1] = try std.fmt.parseInt(i16, args[i][comma + 1 ..], 10);
        } else if (std.mem.eql(u8, args[i], "--ppm") and i + 1 < args.len) {
            i += 1;
            dump_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--pointer") and i + 1 < args.len) {
            i += 1;
            pointer_mode = args[i];
        } else if (std.mem.eql(u8, args[i], "--stick-frames") and i + 1 < args.len) {
            i += 1;
            stick_frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--speed") and i + 1 < args.len) {
            i += 1;
            speed_opt = try gpa.dupeZ(u8, args[i]);
        } else if (std.mem.eql(u8, args[i], "--reset-at") and i + 1 < args.len) {
            i += 1;
            reset_at = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--state") and i + 1 < args.len) {
            i += 1;
            state_frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--audio")) {
            want_audio = true;
        } else if (std.mem.eql(u8, args[i], "--shell")) {
            want_shell = true;
        } else if (std.mem.eql(u8, args[i], "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, args[i], "--solid")) {
            pulse_period = 0;
        } else if (std.mem.eql(u8, args[i], "--point") and i + 1 < args.len) {
            i += 1;
            const comma = std.mem.indexOfScalar(u8, args[i], ',') orelse return error.BadPoint;
            point = .{
                try std.fmt.parseFloat(f64, args[i][0..comma]),
                try std.fmt.parseFloat(f64, args[i][comma + 1 ..]),
            };
        }
    }

    const swf = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], gpa, .limited(256 << 20));

    var core = try Core.open(args[1]);
    defer core.lib.close();
    if (core.api_version() != 1) {
        std.debug.print("api version {d}, expected 1\n", .{core.api_version()});
        return 1;
    }
    core.wire();
    core.init();
    defer core.deinit();

    fb = try gpa.alloc(u32, 4096 * 4096);

    // Pass 1: untouched — no button, no pointer.
    held_id = null;
    const saved_point = point;
    point = null;
    const idle = try runOnce(&core, gpa, swf, frames);
    point = saved_point;

    if (state_frames) |n| {
        const info: GameInfo = .{ .path = null, .data = swf.ptr, .size = swf.len, .meta = null };
        if (!core.load_game(&info)) return error.LoadFailed;
        defer core.unload_game();
        var av: SystemAvInfo = undefined;
        core.get_system_av_info(&av);
        try stateGates(&core, gpa, n);
        std.debug.print("{s}: state gates passed\n", .{args[2]});
        return 0;
    }

    if (want_audio) {
        std.debug.print("{s}: {d} audio frames, energy {d} ({s})\n", .{
            args[2],
            audio_frames,
            audio_energy,
            if (audio_energy > 0) "AUDIBLE" else "silent",
        });
        return 0;
    }

    if (hold == null and point == null) {
        std.debug.print("{s}: {d}x{d}, {d} frames run\n", .{ args[2], fb_w, fb_h, frames });
        return 0;
    }

    // Pass 2: the same movie, pressed.
    if (hold) |want| {
        var id: ?c_uint = null;
        for (BUTTONS) |b| {
            if (std.mem.eql(u8, b.name, want)) id = b.id;
        }
        held_id = id orelse {
            std.debug.print("unknown button {s}\n", .{want});
            return 2;
        };
    }
    const pressed = try runOnce(&core, gpa, swf, frames);

    var differ: usize = 0;
    for (idle, pressed) |a, b| {
        if (a != b) differ += 1;
    }
    var what: [64]u8 = undefined;
    const label = if (hold) |h|
        std.fmt.bufPrint(&what, "hold {s}", .{h}) catch "hold"
    else
        std.fmt.bufPrint(&what, "point {d:.2},{d:.2}", .{ point.?[0], point.?[1] }) catch "point";
    std.debug.print("{s}: {s} -> {d} px differ of {d} ({s})\n", .{
        args[2],  label, differ, idle.len,
        if (differ > 0) "REACTS" else "no change",
    });
    return 0;
}

/// A PPM of the last frame — no PNG encoder here, and `tools/pngdiff.py`
/// is one conversion away. Only for looking at the shell by eye.
fn writePpm(path: []const u8, px: []const u32, w: c_uint, h: c_uint) !void {
    const a = std.heap.page_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var buf: [64]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ w, h }));
    for (px) |v| {
        try out.append(a, @intCast((v >> 16) & 0xFF));
        try out.append(a, @intCast((v >> 8) & 0xFF));
        try out.append(a, @intCast(v & 0xFF));
    }
    try std.Io.Dir.cwd().writeFile(g_io, .{ .sub_path = path, .data = out.items });
}

var dump_path: ?[]const u8 = null;
/// `--reset-at N` calls `retro_reset` on frame N. RetroArch's Restart
/// button is the one lifecycle path a player can reach that nothing else
/// here exercises, and it tears the Player down and boots it again.
var reset_at: ?u32 = null;
/// `--speed 2x` answers the core's `flash_speed` option, so the harness
/// exercises the real path rather than poking the Player.
var speed_opt: ?[*:0]const u8 = null;
var g_io: std.Io = undefined;

/// The save-state gates, ported from the sibling core's harness
/// (`handyplay-oss/java-core/frontends/libretro/test_host.zig`). Each one
/// fails differently and closer to its cause than a framebuffer
/// comparison would:
///
///   D3  two serializations of identical state are byte-identical
///   D4  `serialize_size` does not move across a run
///   RC  re-serializing right after a load reproduces the blob exactly —
///       anything the load left behind shows up here
///   D1  how dense a one-frame delta is, which is what rewind pays
fn stateGates(core: *Core, gpa: std.mem.Allocator, frames: u32) !void {
    var f: u32 = 0;
    while (f < frames) : (f += 1) core.run();

    const sz = core.serialize_size();
    if (sz == 0) {
        std.debug.print("[state] serialize_size is 0 — states are off\n", .{});
        return;
    }
    const base = try gpa.alloc(u8, sz);
    defer gpa.free(base);
    if (!core.serialize(base.ptr, sz)) return error.SerializeFailed;
    std.debug.print("[state] serialize_size={d}B\n", .{sz});
    reportSizes(base, sz);

    // D3. Pre-fill the two buffers DIFFERENTLY so a leftover byte cannot
    // agree by luck.
    {
        const a = try gpa.alloc(u8, sz);
        defer gpa.free(a);
        const b = try gpa.alloc(u8, sz);
        defer gpa.free(b);
        @memset(a, 0x00);
        @memset(b, 0xFF);
        if (!core.serialize(a.ptr, sz) or !core.serialize(b.ptr, sz)) return error.SerializeFailed;
        if (!std.mem.eql(u8, a, b)) {
            var first: usize = 0;
            while (first < sz and a[first] == b[first]) first += 1;
            std.debug.print("[state] D3 FAIL: first differing byte at {d}\n", .{first});
            reportSection(a, sz, first);
            return error.NondeterministicState;
        }
        std.debug.print("[state] D3 ok: two saves byte-identical\n", .{});
    }

    // D4.
    {
        var i: u32 = 0;
        while (i < 30) : (i += 1) core.run();
        const sz2 = core.serialize_size();
        if (sz2 != sz) {
            std.debug.print("[state] D4 FAIL: size drifted {d} -> {d}\n", .{ sz, sz2 });
            return error.SerializeSizeDrift;
        }
        std.debug.print("[state] D4 ok: size stable across a run\n", .{});
    }

    // RC: load, then re-serialize and compare.
    {
        if (!core.unserialize(base.ptr, sz)) return error.UnserializeFailed;
        const after = try gpa.alloc(u8, sz);
        defer gpa.free(after);
        @memset(after, 0x5A);
        if (!core.serialize(after.ptr, sz)) return error.SerializeFailed;
        if (!std.mem.eql(u8, base, after)) {
            var first: usize = 0;
            while (first < sz and base[first] == after[first]) first += 1;
            std.debug.print("[state] RESTORE INCOMPLETE: differs at {d}\n", .{first});
            reportSection(base, sz, first);
            return error.RestoreIncomplete;
        }
        std.debug.print("[state] restore ok: re-save reproduces the blob\n", .{});
    }

    // D1: what a rewind layer would actually store per frame. RetroArch
    // XORs in 32-bit words and emits runs of (skip, count, payload), so
    // the cost is changed WORDS plus a header per run — not the state.
    {
        const a = try gpa.alloc(u8, sz);
        defer gpa.free(a);
        const b = try gpa.alloc(u8, sz);
        defer gpa.free(b);
        if (!core.serialize(a.ptr, sz)) return error.SerializeFailed;
        core.run();
        if (!core.serialize(b.ptr, sz)) return error.SerializeFailed;
        var words: usize = 0;
        var runs: usize = 0;
        var in_run = false;
        var off: usize = 0;
        while (off + 4 <= sz) : (off += 4) {
            if (!std.mem.eql(u8, a[off..][0..4], b[off..][0..4])) {
                words += 1;
                if (!in_run) {
                    runs += 1;
                    in_run = true;
                }
            } else in_run = false;
        }
        const encoded = words * 4 + runs * 8;
        std.debug.print("[state] one-frame delta: {d} words in {d} runs -> ~{d}B/frame\n", .{ words, runs, encoded });
        reportDelta(a, b, sz);
        std.debug.print("[state] 60 frames of rewind: {d}B base + ~{d}B\n", .{ sz, encoded * 59 });
    }
}

/// What each section costs. Printed every run, not only on failure: a
/// state that is CORRECT but enormous is still a broken state, because
/// rewind keeps a ring of them.
fn reportSizes(buf: []const u8, sz: usize) void {
    const env_hdr = std.mem.readInt(u32, buf[8..12], .little);
    var off: usize = env_hdr;
    while (off + 48 <= sz) {
        const total = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
        if (total < 48 or off + total > sz) return;
        // HEAP and DISP both begin with a COUNT, and "36 MB" means
        // something different depending on whether it is many objects or
        // a few enormous ones.
        const hdr = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
        const first = if (off + hdr + 4 <= sz) std.mem.readInt(u32, buf[off + hdr ..][0..4], .little) else 0;
        const tag = buf[off..][0..4];
        if (std.mem.eql(u8, tag, "HEAP") or std.mem.eql(u8, tag, "DISP") or std.mem.eql(u8, tag, "STRS")) {
            std.debug.print("[state]   {s} {d}B ({d} entries)\n", .{ tag, total, first });
        } else std.debug.print("[state]   {s} {d}B\n", .{ tag, total });
        off += total;
    }
}

/// WHERE the one-frame delta falls. A state can be small and still cost
/// a fortune to rewind if one section rewrites itself every frame, and
/// the section name says which piece of the engine is doing it.
fn reportDelta(a: []const u8, b: []const u8, sz: usize) void {
    // BOTH section tables are walked in step: a section that changed
    // SIZE shifts every one after it, and comparing the same byte ranges
    // would then report the whole tail as changed when nothing in it
    // moved.
    var off_a: usize = std.mem.readInt(u32, a[8..12], .little);
    var off_b: usize = std.mem.readInt(u32, b[8..12], .little);
    while (off_a + 48 <= sz and off_b + 48 <= sz) {
        const ta = std.mem.readInt(u32, a[off_a + 12 ..][0..4], .little);
        const tb = std.mem.readInt(u32, b[off_b + 12 ..][0..4], .little);
        if (ta < 48 or tb < 48 or off_a + ta > sz or off_b + tb > sz) return;
        if (ta != tb) {
            std.debug.print("[state]     {s}: RESIZED {d} -> {d} bytes\n", .{ a[off_a..][0..4], ta, tb });
        } else {
            var words: usize = 0;
            var i: usize = 0;
            while (i + 4 <= ta) : (i += 4) {
                if (!std.mem.eql(u8, a[off_a + i ..][0..4], b[off_b + i ..][0..4])) words += 1;
            }
            if (words != 0) {
                std.debug.print("[state]     {s}: {d} of {d} words changed\n", .{ a[off_a..][0..4], words, ta / 4 });
            }
        }
        off_a += ta;
        off_b += tb;
    }
}

/// Which section a byte offset lands in, walking only the 48-byte
/// prefixes — no payload knowledge needed.
fn reportSection(buf: []const u8, sz: usize, at: usize) void {
    const env_hdr = std.mem.readInt(u32, buf[8..12], .little);
    var off: usize = env_hdr;
    while (off + 48 <= sz) {
        const total = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
        if (total < 48) return;
        if (at >= off and at < off + total) {
            std.debug.print("[state]   in section {s} at +{d} of {d}\n", .{ buf[off..][0..4], at - off, total });
            return;
        }
        off += total;
    }
}

/// One load-run-unload cycle, answering with a copy of the last frame.
fn runOnce(core: *Core, gpa: std.mem.Allocator, swf: []const u8, frames: u32) ![]u32 {
    const info: GameInfo = .{
        .path = null,
        .data = swf.ptr,
        .size = swf.len,
        .meta = null,
    };
    if (!core.load_game(&info)) return error.LoadFailed;
    defer core.unload_game();

    var av: SystemAvInfo = undefined;
    core.get_system_av_info(&av);
    if (!quiet) {
        std.debug.print("  av: {d}x{d} @ {d:.2}fps\n", .{ av.base_width, av.base_height, av.fps });
    }

    frame_no = 0;
    while (frame_no < frames) : (frame_no += 1) {
        if (reset_at) |at| {
            if (frame_no == at) core.reset();
        }
        core.run();
    }
    if (dump_path) |path| try writePpm(path, fb[0 .. fb_w * fb_h], fb_w, fb_h);
    return gpa.dupe(u32, fb[0 .. fb_w * fb_h]);
}
