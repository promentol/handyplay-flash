//! libretro core for handyplay-flash: the `retro_*` C ABI over the same
//! frontend-agnostic `core/` the SDL player uses.
//!
//! Three things worth knowing before reading:
//!
//!   * **The pad is bound by the MOVIE.** There is no key table in this
//!     file. `core/key_survey.zig` reads, at load, which keys the movie
//!     can actually notice — button conditions, clip events,
//!     `Key.isDown`, `Key.getCode` comparisons — and each pad button
//!     asks it for the code that answers its ACTION. So D-pad UP sends
//!     38 to a game that reads the arrow keys and `'2'` to a phone game
//!     that only knows the keypad, from the same physical stick. The
//!     resolved map is published as INPUT DESCRIPTORS, so RetroArch's
//!     control menu shows what this particular movie made of the pad.
//!
//!   * **The screen is the movie's own stage box**, at 1:1. A SWF
//!     carries its size and frame rate in its header and every one of
//!     these files was authored against them; there is no device screen
//!     to emulate and nothing is scaled here (docs/FLASH-LITE.md says
//!     why at more length).
//!
//!   * **The clock is a fixed per-frame timestep**, not host elapsed
//!     time — emulated time is frame_count × frame_ms. A slow host
//!     renders fewer real frames while the movie's own clock stays
//!     constant, which is what a replay and a future save-state need.
//!
//! Not here yet: SAVE-STATES (`retro_serialize_size` answers 0 — see the
//! note above it) and AUDIO (silence; M6 owns the mixer).

const std = @import("std");
const flash = @import("flash");
const lr = @import("libretro.zig");
const shell_mod = @import("shell.zig");

const survey = flash.key_survey;
const gpa = std.heap.c_allocator;

/// The mixer's rate; the core pushes one frame's worth per `retro_run`.
const SAMPLE_RATE: f64 = @floatFromInt(flash.audio.mixer.SAMPLE_RATE);

var env_cb: lr.EnvironmentFn = null;
var video_cb: lr.VideoRefreshFn = null;
var audio_batch_cb: lr.AudioSampleBatchFn = null;
var input_poll_cb: lr.InputPollFn = null;
var input_state_cb: lr.InputStateFn = null;
var log_cb: ?*const fn (c_uint, [*:0]const u8, ...) callconv(.c) void = null;

var g_player: ?*flash.Player = null;
var g_swf: []u8 = &.{};
var g_w: u32 = 1;
var g_h: u32 = 1;
var g_fps: f64 = 30.0;
/// One frame of interleaved stereo at 44100 fits in this for any frame
/// rate down to about 10 fps; a slower movie gets its batch split.
var audio_buf: [8192]i16 = @splat(0);

// --- options ----------------------------------------------------------------

/// One option, kept SPLIT rather than as libretro's packed
/// "Description; a|b|c" string. The two interfaces want it in two
/// different shapes, and taking our own packed text back apart meant
/// writing NUL bytes into string literals — which is read-only memory.
const Opt = struct {
    key: [:0]const u8,
    desc: [:0]const u8,
    values: []const [:0]const u8,
};

const OPT_PROFILE = "flash_profile";
const OPT_QUALITY = "flash_quality";
const OPT_CURSOR = "flash_cursor";
const OPT_BOOT = "flash_boot";
const OPT_POINTER = "flash_pointer";
const OPT_STATES = "flash_savestates";
const OPT_SPEED = "flash_speed";

const BASE_OPTS = [_]Opt{
    .{ .key = OPT_PROFILE, .desc = "Player profile", .values = &.{ "auto", "lite", "avm1", "avm2" } },
    .{ .key = OPT_QUALITY, .desc = "Stage quality", .values = &.{ "high", "low" } },
    .{ .key = OPT_CURSOR, .desc = "Analog cursor speed", .values = &.{ "normal", "slow", "fast", "off" } },
    .{ .key = OPT_BOOT, .desc = "Show intro and controls", .values = &.{ "on", "off" } },
    .{ .key = OPT_POINTER, .desc = "Pointer type", .values = &.{ "auto", "joystick", "touch", "off" } },
    .{ .key = OPT_STATES, .desc = "Save states and rewind", .values = &.{ "on", "off" } },
    .{ .key = OPT_SPEED, .desc = "Playback speed", .values = &.{ "1x", "0.5x", "0.75x", "1.5x", "2x", "3x", "4x" } },
};

var g_profile: ?flash.Profile = null;
var g_antialias: bool = true;
/// Stage pixels per frame at full stick deflection, before the
/// stage-width scaling.
var g_cursor_speed: f64 = 4.0;
var g_boot_shell: bool = true;

/// How the movie is POINTED at, in the shape melonDS and DeSmuME use for
/// the same problem — "pointer type" is the setting a player goes looking
/// for, so this one is called that too.
///
///   auto      the stick aims, and the cursor SHOWS ITSELF when it moves
///             and fades when it has not — right for the many movies that
///             are keyboard games with a mouse menu
///   joystick  the stick aims and the cursor is always drawn
///   touch     only a real pointer device (a touchscreen, or the
///             frontend's mouse); the stick does nothing
///   off       no pointing at all
const PointerMode = enum { auto, joystick, touch, off };
var g_pointer: PointerMode = .auto;
/// Save-states are INCOMPLETE — 33 of the 36 games round-trip exactly,
/// the rest differ in ways only a re-save reveals (docs/SAVESTATE.md) —
/// so they are off unless someone asks for them, by core option or by
/// `HANDYPLAY_FLASH_SAVESTATES=1` for the harness that builds them.
var g_states: bool = true;
/// Playback speed. Unlike RetroArch's fast-forward — which runs the core
/// as fast as the host allows and drops the audio — this multiplies the
/// MOVIE's clock: the frontend still gets one frame and 44100/fps samples
/// per `retro_run`, so vsync, rewind and states all behave as usual and
/// the sound is pitched instead of mangled.
var g_speed: f64 = 1.0;
/// Frames since the cursor last moved, for the fade in `auto`.
var cursor_idle: u32 = 1 << 30;

/// Hand the frontend the option list: the fixed ones, then one per
/// remappable button.
///
/// v2 when the frontend has it, because the v0 `SET_VARIABLES` is only
/// ever read ONCE. That was MEASURED, not assumed: RetroArch 1.22 logs
/// both calls, keeps the first list, and the per-movie bindings never
/// reach its menu.
fn publishOptions() void {
    const cb = env_cb orelse return;
    const n = BASE_OPTS.len + n_binds;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = i < BASE_OPTS.len;
        const b = if (base) 0 else i - BASE_OPTS.len;
        const key: [*:0]const u8 = if (base) BASE_OPTS[i].key.ptr else @ptrCast(&opt_key_buf[b]);
        const desc: [*:0]const u8 = if (base) BASE_OPTS[i].desc.ptr else @ptrCast(&opt_desc_buf[b]);
        const values: []const [:0]const u8 = if (base)
            BASE_OPTS[i].values
        else
            bind_values[b][0..n_bind_values[b]];

        // v0: "Description; first|second|…", the first being the default.
        var w: std.Io.Writer = .fixed(&opt_packed[i]);
        w.print("{s}; ", .{std.mem.sliceTo(desc, 0)}) catch {};
        for (values, 0..) |v, k| {
            w.print("{s}{s}", .{ if (k > 0) "|" else "", v }) catch break;
        }
        w.writeByte(0) catch {};
        opt_vars[i] = .{ .key = key, .value = @ptrCast(&opt_packed[i]) };

        // v2: the same list, already split.
        opt_defs[i] = .{ .key = key, .desc = desc };
        for (values, 0..) |v, k| {
            if (k + 1 >= lr.NUM_CORE_OPTION_VALUES_MAX) break;
            opt_defs[i].values[k] = .{ .value = v.ptr };
        }
        opt_defs[i].default_value = if (values.len > 0) values[0].ptr else null;
    }
    opt_vars[n] = .{ .key = null, .value = null };
    opt_defs[n] = .{};

    if (options_v2) {
        var v2: lr.CoreOptionsV2 = .{ .categories = null, .definitions = &opt_defs };
        if (cb(lr.ENVIRONMENT_SET_CORE_OPTIONS_V2, &v2)) return;
    }
    _ = cb(lr.ENVIRONMENT_SET_VARIABLES, @ptrCast(&opt_vars));
}

/// One option per remappable button, whose values are the keys this movie
/// actually reads — plus `auto` (whatever the survey chose) and `none`.
fn buildOptions(p: *flash.Player) void {
    // The names first: every value slot points into this, so it has to
    // outlive the call and be NUL-terminated.
    n_key_names = 0;
    var code: i32 = 0;
    while (code < 256 and n_key_names < key_name_buf.len) : (code += 1) {
        if (!p.keys.all.has(code)) continue;
        const name = survey.keyName(code) orelse continue;
        const take = @min(name.len, key_name_buf[n_key_names].len - 1);
        @memcpy(key_name_buf[n_key_names][0..take], name[0..take]);
        key_name_buf[n_key_names][take] = 0;
        n_key_names += 1;
    }

    n_binds = 0;
    for (PAD, 0..) |pad, i| {
        // The click and the cursor have nothing to choose from, and START
        // belongs to the shell.
        if (pad.role == .click or isAiming(pad)) continue;
        if (pad.id == lr.DEVICE_ID_JOYPAD_START) continue;

        _ = std.fmt.bufPrintZ(&opt_key_buf[n_binds], "flash_bind_{s}", .{padSlug(pad.id)}) catch continue;
        _ = std.fmt.bufPrintZ(&opt_desc_buf[n_binds], "Bind {s}", .{labelFor(pad, i)}) catch continue;

        bind_values[n_binds][0] = "auto";
        bind_values[n_binds][1] = "none";
        var k: usize = 2;
        var j: usize = 0;
        while (j < n_key_names and k + 1 < lr.NUM_CORE_OPTION_VALUES_MAX) : (j += 1) {
            const z: [*:0]const u8 = @ptrCast(&key_name_buf[j]);
            bind_values[n_binds][k] = std.mem.span(z);
            k += 1;
        }
        n_bind_values[n_binds] = k;
        n_binds += 1;
    }
    publishOptions();
    readBindings(p);
}

/// What the frontend CALLS this button. libretro never tells a core the
/// physical controller's own labels — only the RetroPad abstraction — so
/// this is as close to "the actual joystick button name" as exists, and
/// it is the vocabulary RetroArch's own menus use.
fn padName(id: c_uint) []const u8 {
    return switch (id) {
        lr.DEVICE_ID_JOYPAD_UP => "UP",
        lr.DEVICE_ID_JOYPAD_DOWN => "DOWN",
        lr.DEVICE_ID_JOYPAD_LEFT => "LEFT",
        lr.DEVICE_ID_JOYPAD_RIGHT => "RIGHT",
        lr.DEVICE_ID_JOYPAD_A => "A",
        lr.DEVICE_ID_JOYPAD_B => "B",
        lr.DEVICE_ID_JOYPAD_X => "X",
        lr.DEVICE_ID_JOYPAD_Y => "Y",
        lr.DEVICE_ID_JOYPAD_L => "L",
        lr.DEVICE_ID_JOYPAD_R => "R",
        lr.DEVICE_ID_JOYPAD_L2 => "L2",
        lr.DEVICE_ID_JOYPAD_R2 => "R2",
        lr.DEVICE_ID_JOYPAD_L3 => "L3",
        lr.DEVICE_ID_JOYPAD_R3 => "R3",
        lr.DEVICE_ID_JOYPAD_SELECT => "SELECT",
        else => "START",
    };
}

/// The RetroPad's own name for a button, as it appears in the option key.
fn padSlug(id: c_uint) []const u8 {
    return switch (id) {
        lr.DEVICE_ID_JOYPAD_UP => "up",
        lr.DEVICE_ID_JOYPAD_DOWN => "down",
        lr.DEVICE_ID_JOYPAD_LEFT => "left",
        lr.DEVICE_ID_JOYPAD_RIGHT => "right",
        lr.DEVICE_ID_JOYPAD_A => "a",
        lr.DEVICE_ID_JOYPAD_B => "b",
        lr.DEVICE_ID_JOYPAD_X => "x",
        lr.DEVICE_ID_JOYPAD_Y => "y",
        lr.DEVICE_ID_JOYPAD_L => "l",
        lr.DEVICE_ID_JOYPAD_R => "r",
        lr.DEVICE_ID_JOYPAD_L2 => "l2",
        lr.DEVICE_ID_JOYPAD_R2 => "r2",
        lr.DEVICE_ID_JOYPAD_L3 => "l3",
        lr.DEVICE_ID_JOYPAD_R3 => "r3",
        lr.DEVICE_ID_JOYPAD_SELECT => "select",
        else => "start",
    };
}

/// Read every `flash_bind_*` back and apply it over the automap. `auto`
/// leaves the surveyed choice alone, which is why the map is rebuilt
/// first rather than patched in place.
fn readBindings(p: *flash.Player) void {
    g_override = @splat(null);
    for (PAD, 0..) |pad, i| {
        if (pad.role == .click or pad.id == lr.DEVICE_ID_JOYPAD_START) continue;
        var buf: [24]u8 = undefined;
        const key = std.fmt.bufPrintZ(&buf, "flash_bind_{s}", .{padSlug(pad.id)}) catch continue;
        const text = optionText(key.ptr) orelse continue;
        if (std.mem.eql(u8, text, "auto")) continue;
        if (std.mem.eql(u8, text, "none")) {
            g_override[i] = 0;
            continue;
        }
        var code: i32 = 0;
        while (code < 256) : (code += 1) {
            const name = survey.keyName(code) orelse continue;
            if (std.mem.eql(u8, name, text)) {
                g_override[i] = code;
                break;
            }
        }
    }
    _ = p;
    for (g_override, 0..) |o, i| {
        if (o) |code| g_map[i] = code;
    }
    publishDescriptors();
    // Logged HERE and not in `buildMap`, because an override applied
    // afterwards would make that one a lie.
    for (PAD, 0..) |pad, i| {
        log("  {s} -> {s}{s}", .{
            labelFor(pad, i),
            keyTextFor(pad, i),
            if (g_override[i] != null) "  (core option)" else "",
        });
    }
}

fn optionText(key: [*:0]const u8) ?[]const u8 {
    const cb = env_cb orelse return null;
    var v: lr.Variable = .{ .key = key, .value = null };
    if (!cb(lr.ENVIRONMENT_GET_VARIABLE, &v)) return null;
    return std.mem.sliceTo(v.value orelse return null, 0);
}

fn readOptions() void {
    g_profile = null;
    if (optionText(OPT_PROFILE)) |t| {
        if (!std.mem.eql(u8, t, "auto")) g_profile = flash.Profile.fromName(t);
    }
    if (optionText(OPT_QUALITY)) |t| g_antialias = !std.mem.eql(u8, t, "low");
    if (optionText(OPT_BOOT)) |t| g_boot_shell = !std.mem.eql(u8, t, "off");
    if (optionText(OPT_STATES)) |t| g_states = !std.mem.eql(u8, t, "off");
    if (optionText(OPT_SPEED)) |t| {
        g_speed = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch 1.0;
        if (g_player) |p| p.setSpeed(g_speed);
    }
    if (optionText(OPT_POINTER)) |t| {
        g_pointer = if (std.mem.eql(u8, t, "joystick"))
            .joystick
        else if (std.mem.eql(u8, t, "touch"))
            .touch
        else if (std.mem.eql(u8, t, "off"))
            .off
        else
            .auto;
    }
    if (optionText(OPT_CURSOR)) |t| {
        g_cursor_speed = if (std.mem.eql(u8, t, "off"))
            0
        else if (std.mem.eql(u8, t, "slow"))
            2
        else if (std.mem.eql(u8, t, "fast"))
            8
        else
            4;
    }
}

fn log(comptime fmt: [:0]const u8, args: anytype) void {
    const f = log_cb orelse return;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    f(lr.LOG_INFO, "%s\n", text.ptr);
}

// --- the pad ------------------------------------------------------------------

/// One pad button: the ACTION it plays, and the code to send when the
/// movie turns out to read nothing like it. The fallbacks are the phone
/// layout these games were authored for, which is also what the SDL
/// frontend falls back to.
const Pad = struct {
    id: c_uint,
    /// A second role, tried when the first resolves to nothing.
    alt: ?survey.Action = null,
    /// `.action` is a role the survey can answer; `.click` is the mouse;
    /// `.spare` is a button with no name of its own, filled from the keys
    /// the roles did not claim.
    role: union(enum) { action: survey.Action, click, spare },
    fallback: i32,
    label: []const u8,
};

const PAD = [_]Pad{
    .{ .id = lr.DEVICE_ID_JOYPAD_UP, .role = .{ .action = .up }, .fallback = 38, .label = "Up" },
    .{ .id = lr.DEVICE_ID_JOYPAD_DOWN, .role = .{ .action = .down }, .fallback = 40, .label = "Down" },
    .{ .id = lr.DEVICE_ID_JOYPAD_LEFT, .role = .{ .action = .left }, .fallback = 37, .label = "Left" },
    .{ .id = lr.DEVICE_ID_JOYPAD_RIGHT, .role = .{ .action = .right }, .fallback = 39, .label = "Right" },
    .{ .id = lr.DEVICE_ID_JOYPAD_A, .role = .{ .action = .action_a }, .fallback = 13, .label = "Fire" },
    .{ .id = lr.DEVICE_ID_JOYPAD_B, .role = .{ .action = .select }, .fallback = 13, .label = "Select" },
    .{ .id = lr.DEVICE_ID_JOYPAD_X, .role = .{ .action = .action_b }, .fallback = '5', .label = "Action" },
    // Y is the CLICK, always: six of the shipped games are pointer-driven
    // and never look at a key, and a pad with no click cannot play them.
    .{ .id = lr.DEVICE_ID_JOYPAD_Y, .role = .click, .fallback = 0, .label = "Mouse click" },
    // The shoulders are the soft keys on a handset game and the quality
    // pair on a desktop one — `-`/`+` was the convention there, and the
    // two never appear in the same movie.
    .{ .id = lr.DEVICE_ID_JOYPAD_L, .role = .{ .action = .soft_left }, .alt = .quality_down, .fallback = 33, .label = "Soft left" },
    .{ .id = lr.DEVICE_ID_JOYPAD_R, .role = .{ .action = .soft_right }, .alt = .quality_up, .fallback = 34, .label = "Soft right" },
    // START belongs to the SHELL, so in play it is only a pause key when
    // the movie actually reads one — never a second Enter.
    .{ .id = lr.DEVICE_ID_JOYPAD_START, .role = .{ .action = .pause }, .fallback = 0, .label = "Pause" },
    .{ .id = lr.DEVICE_ID_JOYPAD_SELECT, .role = .{ .action = .back }, .fallback = 0, .label = "Back" },
    // The shoulders and stick clicks have no meaning of their own, which
    // makes them the right home for the keys a game reads that no role
    // asked for — Super Mario 63's Space and C, for instance.
    .{ .id = lr.DEVICE_ID_JOYPAD_L2, .role = .spare, .fallback = 0, .label = "Extra 1" },
    .{ .id = lr.DEVICE_ID_JOYPAD_R2, .role = .spare, .fallback = 0, .label = "Extra 2" },
    .{ .id = lr.DEVICE_ID_JOYPAD_L3, .role = .spare, .fallback = 0, .label = "Extra 3" },
    .{ .id = lr.DEVICE_ID_JOYPAD_R3, .role = .spare, .fallback = 0, .label = "Extra 4" },
};

/// The resolved code per entry, or 0 for "this button clicks the mouse".
var g_map: [PAD.len]i32 = @splat(0);
var prev_down: [PAD.len]bool = @splat(false);
/// The D-pad aims the cursor when the movie reads no directional key —
/// which is the whole input surface of a mouse-only movie.
var g_dpad_aims = false;

// --- the boot shell ------------------------------------------------------------

var g_shell: shell_mod.Shell = .{};
/// The shell draws HERE, never into the movie's canvas: the game is
/// parked at frame 1 the whole time and its framebuffer is what we go
/// back to.
var g_shell_fb: []u32 = &.{};
/// Every key this movie reads, plus "unused", as the remapper's choices.
/// Built once at load, because a runtime list is the only kind that can
/// contain THIS game's keys — a core option's values are fixed before
/// any game exists.
var g_choices: [64]i32 = @splat(0);
var g_n_choices: usize = 0;

// --- the per-button options, rebuilt for each movie ----------------------------
//
// Editing the map belongs to the FRONTEND, not to a menu of ours: it
// already has an options UI, per-game overrides and persistence. What it
// cannot do is know which keys a given SWF reads — so the option list is
// re-declared in `retro_load_game` with THIS movie's keys as the values.
// dosbox-pure builds its mapper the same way.
//
// Buffers, because the frontend keeps every pointer it is handed.
const MAX_OPTS = BASE_OPTS.len + PAD.len;
var opt_key_buf: [PAD.len][24]u8 = @splat(@splat(0));
var opt_desc_buf: [PAD.len][40]u8 = @splat(@splat(0));
var bind_values: [PAD.len][lr.NUM_CORE_OPTION_VALUES_MAX][:0]const u8 = undefined;
var n_bind_values: [PAD.len]usize = @splat(0);
/// One NUL-terminated name per surveyed key; every bind option's value
/// list points into this.
var key_name_buf: [96][16]u8 = @splat(@splat(0));
var n_key_names: usize = 0;
/// The two encodings libretro wants, from the one list above.
var opt_vars: [MAX_OPTS + 1]lr.Variable = undefined;
var opt_packed: [MAX_OPTS][512]u8 = @splat(@splat(0));
var opt_defs: [MAX_OPTS + 1]lr.CoreOptionV2Definition = undefined;
var n_binds: usize = 0;
var options_v2 = false;
/// The override each button's option asked for: `null` is `auto`.
var g_override: [PAD.len]?i32 = @splat(null);
var shell_prev: [PAD.len]bool = @splat(false);
var g_rows: [PAD.len]shell_mod.Row = undefined;
var row_key_buf: [PAD.len][24]u8 = @splat(@splat(0));

var cursor_x: f64 = 0;
var cursor_y: f64 = 0;
var mouse_down = false;

/// Descriptor strings must outlive the call: the frontend keeps the
/// pointers and reads them whenever its control menu is opened.
var desc_buf: [PAD.len][64]u8 = @splat(@splat(0));
var descriptors: [PAD.len + 1]lr.InputDescriptor = undefined;

/// Tell the frontend what each button means now — at load, and again
/// after the player has remapped one, or its control menu would still
/// describe the map the survey guessed.
fn publishDescriptors() void {
    for (PAD, 0..) |pad, i| {
        const text = std.fmt.bufPrintZ(&desc_buf[i], "{s} ({s})", .{
            labelFor(pad, i),
            keyTextFor(pad, i),
        }) catch "?";
        descriptors[i] = .{
            .port = 0,
            .device = lr.DEVICE_JOYPAD,
            .index = 0,
            .id = pad.id,
            .description = text.ptr,
        };
    }
    descriptors[PAD.len] = .{ .port = 0, .device = 0, .index = 0, .id = 0, .description = null };
    if (env_cb) |cb| _ = cb(lr.ENVIRONMENT_SET_INPUT_DESCRIPTORS, &descriptors);
}

/// Is this button one of the directions that are aiming the cursor
/// rather than sending a key?
fn isAiming(pad: Pad) bool {
    if (!g_dpad_aims or pad.role != .action) return false;
    return switch (pad.role.action) {
        .up, .down, .left, .right => true,
        else => false,
    };
}

/// What this button sends, in words.
fn keyTextFor(pad: Pad, i: usize) []const u8 {
    if (isAiming(pad)) return "aims the cursor";
    if (g_map[i] == 0) return if (pad.role == .click) "mouse click" else "unused";
    return survey.keyName(g_map[i]) orelse "key";
}

/// What this button ended up MEANING. Only the two-role shoulders can
/// disagree with their table entry: "Quality -" reads better than "Soft
/// left" on a game with no soft keys.
fn labelFor(pad: Pad, i: usize) []const u8 {
    const alt = pad.alt orelse return pad.label;
    for (survey.candidates(alt)) |c| {
        if (c == g_map[i]) return if (alt == .quality_down) "Quality -" else "Quality +";
    }
    return pad.label;
}

/// The remapper's menu for this movie: everything it reads, in code
/// order, with "unused" first so a button can always be silenced. Built
/// at load, because a runtime list is the only kind that can contain THIS
/// game's keys — a core option's values are fixed before any game exists.
fn buildChoices(p: *flash.Player) void {
    g_choices[0] = 0; // unused
    g_n_choices = 1;
    var code: i32 = 0;
    while (code < 256 and g_n_choices < g_choices.len) : (code += 1) {
        if (!p.keys.all.has(code)) continue;
        g_choices[g_n_choices] = code;
        g_n_choices += 1;
    }
}

/// One row per pad button, rebuilt every frame the screen is up so it
/// always shows what the map actually IS.
fn buildRows() []const shell_mod.Row {
    for (PAD, 0..) |pad, i| {
        const key: []const u8 = if (isAiming(pad))
            "CURSOR"
        else if (pad.role == .click)
            "CLICK"
        else if (g_map[i] == 0)
            "-"
        else
            survey.keyName(g_map[i]) orelse "?";
        g_rows[i] = .{
            // The pad's own name, not our word for the role: a player
            // reading this is looking at a controller, not at our table.
            .label = padName(pad.id),
            .key = std.fmt.bufPrint(&row_key_buf[i], "{s}", .{key}) catch "?",
            .bound = isAiming(pad) or pad.role == .click or g_map[i] != 0,
        };
    }
    return g_rows[0..PAD.len];
}

fn buildMap(p: *flash.Player) void {
    const s = p.keys;
    // Pass 1: the roles a pad has words for.
    var claimed: survey.KeySet = .{};
    for (PAD, 0..) |pad, i| {
        switch (pad.role) {
            .click, .spare => g_map[i] = 0,
            .action => |action| {
                // Which of a two-role button comes FIRST is the profile's
                // call: a handset game means the soft keys, anything else
                // the `-`/`+` quality pair. Super Mario 63 reads PageUp
                // and PageDown as well, so asking for soft keys first
                // would hide the convention it actually documents.
                const first: survey.Action = if (pad.alt != null and p.profile != .lite)
                    pad.alt.?
                else
                    action;
                const second: ?survey.Action = if (first == action) pad.alt else action;
                g_map[i] = survey.resolve(s, first) orelse
                    (if (second) |alt| survey.resolve(s, alt) else null) orelse blk: {
                    // Nothing surveyed. A movie whose bindings could not
                    // be read (a listener switching on variables) still
                    // deserves a pad, so the phone layout stands in.
                    if (!s.usesKeyboard() and action == .action_a) break :blk 0;
                    break :blk pad.fallback;
                };
                if (g_map[i] != 0) claimed.add(g_map[i]);
            },
        }
    }

    // Pass 2: the keys the roles left behind. Without this a game is
    // playable but incomplete — Mario reads Space and C and no button
    // would send either.
    var extra: [8]i32 = undefined;
    const n_extra = survey.spares(s, claimed, &extra);
    var next: usize = 0;
    for (PAD, 0..) |pad, i| {
        if (pad.role != .spare) continue;
        if (next >= n_extra) break;
        g_map[i] = extra[next];
        next += 1;
    }

    g_dpad_aims = survey.resolve(s, .up) == null and survey.resolve(s, .down) == null and
        survey.resolve(s, .left) == null and survey.resolve(s, .right) == null;

    publishDescriptors();
    log("handyplay-flash: {d} key(s) surveyed, dpad {s}", .{
        s.all.count(),
        if (g_dpad_aims) "aims the cursor" else "sends keys",
    });
}

// --- lifecycle ----------------------------------------------------------------

export fn retro_api_version() callconv(.c) c_uint {
    return lr.API_VERSION;
}

export fn retro_set_environment(cb: lr.EnvironmentFn) callconv(.c) void {
    env_cb = cb;
    if (cb) |f| {
        var version: c_uint = 0;
        if (f(lr.ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version)) options_v2 = version >= 2;
        // Before any content: just the player-wide settings. The
        // per-button ones need a movie to describe.
        n_binds = 0;
        publishOptions();
        var logger: lr.LogCallback = .{ .log = null };
        if (f(lr.ENVIRONMENT_GET_LOG_INTERFACE, &logger)) log_cb = logger.log;
    }
}
export fn retro_set_video_refresh(cb: lr.VideoRefreshFn) callconv(.c) void {
    video_cb = cb;
}
export fn retro_set_audio_sample(_: ?*anyopaque) callconv(.c) void {}
export fn retro_set_audio_sample_batch(cb: lr.AudioSampleBatchFn) callconv(.c) void {
    audio_batch_cb = cb;
}
export fn retro_set_input_poll(cb: lr.InputPollFn) callconv(.c) void {
    input_poll_cb = cb;
}
export fn retro_set_input_state(cb: lr.InputStateFn) callconv(.c) void {
    input_state_cb = cb;
}

export fn retro_init() callconv(.c) void {}
export fn retro_deinit() callconv(.c) void {}

export fn retro_get_system_info(info: *lr.SystemInfo) callconv(.c) void {
    info.* = .{
        .library_name = "handyplay-flash",
        .library_version = "0.1",
        .valid_extensions = "swf",
        .need_fullpath = false, // the bytes are handed to us
        .block_extract = true, // a compressed SWF is not an archive
    };
}

export fn retro_get_system_av_info(info: *lr.SystemAvInfo) callconv(.c) void {
    info.* = .{
        .geometry = .{
            .base_width = g_w,
            .base_height = g_h,
            .max_width = g_w,
            .max_height = g_h,
            .aspect_ratio = @as(f32, @floatFromInt(g_w)) / @as(f32, @floatFromInt(g_h)),
        },
        .timing = .{ .fps = g_fps, .sample_rate = SAMPLE_RATE },
    };
}

export fn retro_set_controller_port_device(_: c_uint, _: c_uint) callconv(.c) void {}

fn boot() bool {
    return bootWith(false);
}

/// A restore boots WITHOUT frame 1: the state carries the display tree,
/// and a frame that ran first would leave its own objects behind.
fn bootQuiet() bool {
    return bootWith(true);
}

fn bootWith(quiet: bool) bool {
    const p = flash.Player.createWith(gpa, g_swf, .{
        .antialias = g_antialias,
        .profile = g_profile,
        .skip_first_frame = quiet,
    }) catch |e| {
        log("handyplay-flash: load failed: {t}", .{e});
        return false;
    };
    g_player = p;
    g_w = p.width();
    g_h = p.height();
    g_fps = p.fps();
    p.setSpeed(g_speed);
    cursor_x = @as(f64, @floatFromInt(g_w)) / 2;
    cursor_y = @as(f64, @floatFromInt(g_h)) / 2;
    prev_down = @splat(false);
    mouse_down = false;
    buildMap(p);
    buildChoices(p);
    buildOptions(p);
    g_shell_fb = gpa.realloc(g_shell_fb, g_w * g_h) catch g_shell_fb;
    // The ad runs for three seconds of the MOVIE's own frame rate, so a
    // 12fps phone game and a 32fps one show it for the same time.
    g_shell.ad_frames = @intFromFloat(@max(1, g_fps * 3));
    g_shell.accept_name = padName(lr.DEVICE_ID_JOYPAD_A);
    // Off means straight into the movie — and L+R still reopens the
    // remapper, because a player who skipped the screen is exactly the
    // one who will need it.
    g_shell.enter(if (g_boot_shell) .ad else .play);
    shell_prev = @splat(false);
    return true;
}

fn teardown() void {
    if (g_player) |p| {
        p.destroy();
        g_player = null;
    }
}

export fn retro_reset() callconv(.c) void {
    if (g_swf.len == 0) return;
    teardown();
    _ = boot();
}

export fn retro_load_game(game: ?*const lr.GameInfo) callconv(.c) bool {
    const g = game orelse return false;
    const data = g.data orelse return false;
    if (g.size == 0) return false;

    var fmt: c_uint = lr.PIXEL_FORMAT_XRGB8888;
    if (env_cb) |cb| {
        if (!cb(lr.ENVIRONMENT_SET_PIXEL_FORMAT, &fmt)) {
            log("handyplay-flash: the frontend refused XRGB8888", .{});
            return false;
        }
    }
    readOptions();

    // The Player's parsed structs SLICE INTO this buffer, so it has to
    // live as long as the content does.
    g_swf = gpa.dupe(u8, @as([*]const u8, @ptrCast(data))[0..g.size]) catch return false;
    if (!boot()) {
        gpa.free(g_swf);
        g_swf = &.{};
        return false;
    }
    return true;
}

export fn retro_unload_game() callconv(.c) void {
    teardown();
    if (g_swf.len != 0) {
        gpa.free(g_swf);
        g_swf = &.{};
    }
}

// --- the frame ----------------------------------------------------------------

/// Stick deflection, as -1..1 with a dead zone. RetroArch reports a
/// resting stick as a few hundred units off centre, and a cursor that
/// drifts on its own is worse than no cursor.
fn axis(state: *const fn (c_uint, c_uint, c_uint, c_uint) callconv(.c) i16, id: c_uint) f64 {
    const raw = state(0, lr.DEVICE_ANALOG, lr.INDEX_ANALOG_LEFT, id);
    if (@abs(@as(i32, raw)) < 6000) return 0;
    return @as(f64, @floatFromInt(raw)) / 32767.0;
}

fn moveCursor(p: *flash.Player, dx: f64, dy: f64) void {
    if (dx == 0 and dy == 0) return;
    cursor_idle = 0;
    // Scaled by stage width so a 176x208 phone game and an 800x600 one
    // take the same number of seconds to cross.
    const scale = g_cursor_speed * @as(f64, @floatFromInt(g_w)) / 240.0;
    const max_x: f64 = @floatFromInt(g_w);
    const max_y: f64 = @floatFromInt(g_h);
    cursor_x = std.math.clamp(cursor_x + dx * scale, 0, max_x);
    cursor_y = std.math.clamp(cursor_y + dy * scale, 0, max_y);
    p.mouseMove(cursor_x, cursor_y) catch {};
}

fn handleInput(p: *flash.Player) void {
    if (input_poll_cb) |poll| poll();
    const state = input_state_cb orelse return;

    // A pointer device — a touchscreen, or RetroArch's mouse — is
    // absolute and needs no cursor of ours.
    const pointing = state(0, lr.DEVICE_POINTER, 0, lr.DEVICE_ID_POINTER_PRESSED) != 0 or
        state(0, lr.DEVICE_POINTER, 0, lr.DEVICE_ID_POINTER_X) != 0;
    if (g_pointer != .off and pointing) {
        const px = state(0, lr.DEVICE_POINTER, 0, lr.DEVICE_ID_POINTER_X);
        const py = state(0, lr.DEVICE_POINTER, 0, lr.DEVICE_ID_POINTER_Y);
        cursor_x = (@as(f64, @floatFromInt(px)) + 32767.0) / 65534.0 * @as(f64, @floatFromInt(g_w));
        cursor_y = (@as(f64, @floatFromInt(py)) + 32767.0) / 65534.0 * @as(f64, @floatFromInt(g_h));
        p.mouseMove(cursor_x, cursor_y) catch {};
        cursor_idle = 0;
        const pressed = state(0, lr.DEVICE_POINTER, 0, lr.DEVICE_ID_POINTER_PRESSED) != 0;
        if (pressed != mouse_down) {
            mouse_down = pressed;
            p.mouseButton(0, pressed) catch {};
        }
    }

    const stick_aims = g_pointer == .auto or g_pointer == .joystick;
    var dx = if (stick_aims) axis(state, lr.DEVICE_ID_ANALOG_X) else 0;
    var dy = if (stick_aims) axis(state, lr.DEVICE_ID_ANALOG_Y) else 0;

    var click_now = false;
    for (PAD, 0..) |pad, i| {
        const down = state(0, lr.DEVICE_JOYPAD, 0, pad.id) != 0;
        defer prev_down[i] = down;

        // A direction that aims the cursor is not also a key.
        if (g_dpad_aims and stick_aims and pad.role == .action) {
            switch (pad.role.action) {
                .up => if (down) {
                    dy -= 1;
                },
                .down => if (down) {
                    dy += 1;
                },
                .left => if (down) {
                    dx -= 1;
                },
                .right => if (down) {
                    dx += 1;
                },
                else => {},
            }
            switch (pad.role.action) {
                .up, .down, .left, .right => continue,
                else => {},
            }
        }

        const code = g_map[i];
        if (code == 0) {
            // Only the click button acts when unbound; a spare with
            // nothing to send does nothing.
            if (down and pad.role == .click) click_now = true;
            continue;
        }
        // Flash sees key EVENTS, so only edges are forwarded: a held
        // button must not re-fire every frame.
        if (down == prev_down[i]) continue;
        const ascii: i32 = if (code >= 32 and code <= 126) code else 0;
        if (down) p.keyDown(code, ascii) catch {} else p.keyUp(code, ascii) catch {};
    }

    if (g_cursor_speed > 0 and stick_aims) moveCursor(p, dx, dy);

    if (click_now != mouse_down) {
        mouse_down = click_now;
        p.setMousePosition(cursor_x, cursor_y);
        p.mouseButton(0, click_now) catch {};
    }
}

/// The shell reads the pad ITSELF, in edges, and nothing it sees reaches
/// the movie. Any of START, A or B goes on — a player who has just been
/// shown a control legend should not have to hunt for the one button
/// that dismisses it.
fn shellInput() shell_mod.Input {
    var in: shell_mod.Input = .{};
    const state = input_state_cb orelse return in;
    for (PAD, 0..) |pad, i| {
        const down = state(0, lr.DEVICE_JOYPAD, 0, pad.id) != 0;
        const edge = down and !shell_prev[i];
        shell_prev[i] = down;
        switch (pad.id) {
            lr.DEVICE_ID_JOYPAD_START,
            lr.DEVICE_ID_JOYPAD_A,
            lr.DEVICE_ID_JOYPAD_B,
            => in.accept = in.accept or edge,
            else => {},
        }
    }
    return in;
}

/// A binding that changed under the movie's feet leaves it holding a key
/// nobody will ever release, so the old ones are let go first.
fn releaseHeldKeys(p: *flash.Player) void {
    for (PAD, 0..) |_, i| {
        if (!prev_down[i] or g_map[i] == 0) continue;
        p.keyUp(g_map[i], 0) catch {};
        prev_down[i] = false;
    }
    if (mouse_down) {
        mouse_down = false;
        p.mouseButton(0, false) catch {};
    }
}

/// How long a still cursor stays on screen in `auto`, in frames — about
/// two seconds at any of these frame rates.
const FADE_AFTER: u32 = 60;

fn cursorShown() bool {
    return switch (g_pointer) {
        .off => false,
        .joystick => true,
        // In `auto` it appears when it moves and leaves when it does not,
        // so a keyboard game with a mouse menu is not permanently wearing
        // an arrow it does not need.
        .auto, .touch => cursor_idle < FADE_AFTER,
    };
}

fn src_ptr(p: *flash.Player) [*]const u32 {
    return p.framebuffer().ptr;
}

export fn retro_run() callconv(.c) void {
    const p = g_player orelse return;

    if (env_cb) |cb| {
        var updated: bool = false;
        if (cb(lr.ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) and updated) {
            const old_profile = g_profile;
            readOptions();
            // Quality and cursor speed apply live; the profile decides
            // how the movie was BOUND, so it needs a fresh load.
            if (g_profile != old_profile) {
                retro_reset();
                return;
            }
            if (g_player) |cur| {
                cur.antialias = g_antialias;
                // A binding that changed under the movie's feet: let go
                // of whatever the old one was holding, then re-apply.
                releaseHeldKeys(cur);
                buildMap(cur);
                readBindings(cur);
            }
        }
    }

    // --- the shell owns the frame until it is done ------------------------
    if (g_shell.state != .play) {
        if (input_poll_cb) |poll| poll();
        if (g_shell.update(shellInput()) == .done) shell_prev = @splat(false);
        if (g_shell.state != .play) {
            const c = shell_mod.Canvas.init(g_shell_fb, g_w, g_h);
            g_shell.draw(c, buildRows());
            if (video_cb) |refresh| refresh(g_shell_fb.ptr, g_w, g_h, g_w * 4);
            // The shell is not the movie: no frame ran, so no audio was
            // mixed. Silence keeps the frontend's timing loop fed.
            if (audio_batch_cb) |acb| {
                const n: usize = @intFromFloat(@min(SAMPLE_RATE / g_fps, @as(f64, audio_buf.len / 2)));
                @memset(audio_buf[0 .. n * 2], 0);
                _ = acb(&audio_buf, n);
            }
            return;
        }
    }

    handleInput(p);
    // One frame period TIMES the speed: the accumulator inside `tick`
    // turns that into two frames at 2x and a frame every other call at
    // 0.5x, so nothing here needs to know which.
    _ = p.tick(1000.0 / g_fps * g_speed) catch {};

    // `fscommand("quit")`, honoured the way a player should: stop
    // ticking, keep presenting. RetroArch has no "the content ended".
    if (p.quit_requested) {
        p.quit_requested = false;
        log("handyplay-flash: the movie asked to quit", .{});
    }

    // What the movie made this frame. `renderAudio` never advances the
    // mixer — the frame loop already did — so a frontend that pulls
    // twice, or not at all, cannot change what a script observes.
    const frames: usize = @intFromFloat(@min(SAMPLE_RATE / g_fps, @as(f64, audio_buf.len / 2)));
    if (audio_batch_cb) |acb| {
        p.renderAudio(audio_buf[0 .. frames * 2], frames);
        _ = acb(&audio_buf, frames);
    }

    cursor_idle +|= 1;
    if (video_cb) |refresh| {
        if (cursorShown()) {
            // The only frame that is not zero-copy: drawing the pointer
            // means owning a copy of the picture, so it is done ONLY
            // while the pointer is worth seeing.
            const src = p.framebuffer();
            if (g_shell_fb.len >= src.len) {
                @memcpy(g_shell_fb[0..src.len], src);
                const c = shell_mod.Canvas.init(g_shell_fb, g_w, g_h);
                // `joystick` means the pointer is always there, so it
                // stays bright; in `auto` it dims on its way out.
                const fading = g_pointer != .joystick and cursor_idle > FADE_AFTER / 2;
                shell_mod.drawCursor(c, cursor_x, cursor_y, fading);
                refresh(g_shell_fb.ptr, g_w, g_h, g_w * 4);
                return;
            }
        }
        // Zero-copy: the Player's canvas IS the framebuffer we present.
        refresh(@ptrCast(src_ptr(p)), g_w, g_h, g_w * 4);
    }
}

// --- save-states ----------------------------------------------------------------
//
// NOT IMPLEMENTED, and deliberately reported as 0 rather than guessed at:
// a core that claims a size it cannot honour gets rewind enabled and then
// corrupts it. `core/savestate.zig` holds the HFS0 container contract this
// will use; it is the other half of M5.

/// Latched once and never moved (D4): a frontend calls this before the
/// first save and reuses the answer for every rewind frame after it.
var g_state_size: usize = 0;

/// Save-states are UNFINISHED — the display tree and the scalars are in
/// the blob, the AVM1 heap is not — so the ABI answers 0 and RetroArch
/// never offers a save that would restore a movie with the right picture
/// and the wrong variables. `HANDYPLAY_FLASH_SAVESTATES=1` turns them on for
/// the harness that is building them (see docs/SAVESTATE.md).
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn statesEnabled() bool {
    return g_states or getenv("HANDYPLAY_FLASH_SAVESTATES") != null;
}

export fn retro_serialize_size() callconv(.c) usize {
    if (!statesEnabled()) return 0;
    const p = g_player orelse return 0;
    if (g_state_size == 0) g_state_size = p.stateUpperBound();
    return g_state_size;
}

export fn retro_serialize(data: ?*anyopaque, len: usize) callconv(.c) bool {
    if (!statesEnabled()) return false;
    const p = g_player orelse return false;
    const out = @as([*]u8, @ptrCast(data orelse return false))[0..len];
    const used = p.saveState(out) catch return false;
    // Everything past the state is zeroed, not left as whatever the
    // frontend's buffer held: a rewind layer XORs consecutive states and
    // an unzeroed tail turns a near-zero delta into noise (D3).
    @memset(out[used..], 0);
    return true;
}

export fn retro_unserialize(data: ?*const anyopaque, len: usize) callconv(.c) bool {
    if (!statesEnabled()) return false;
    if (g_swf.len == 0) return false;
    const in = @as([*]const u8, @ptrCast(data orelse return false))[0..len];
    // Restore is a FRESH PLAYER plus the state: everything derivable from
    // the movie is re-derived rather than carried (core/savestate.zig).
    teardown();
    if (!bootQuiet()) return false;
    const p = g_player orelse return false;
    p.loadState(in) catch return false;
    // The shell has already been through; a restore drops straight into
    // the movie.
    g_shell.enter(.play);
    return true;
}

// --- unused-but-required ABI ------------------------------------------------------

export fn retro_cheat_reset() callconv(.c) void {}
export fn retro_cheat_set(_: c_uint, _: bool, _: ?[*:0]const u8) callconv(.c) void {}
export fn retro_load_game_special(_: c_uint, _: ?*const lr.GameInfo, _: usize) callconv(.c) bool {
    return false;
}
export fn retro_get_region() callconv(.c) c_uint {
    return lr.REGION_NTSC;
}
export fn retro_get_memory_data(_: c_uint) callconv(.c) ?*anyopaque {
    return null;
}
export fn retro_get_memory_size(_: c_uint) callconv(.c) usize {
    return 0;
}
