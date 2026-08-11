//! SDL3 frontend.
//!
//!   handyplay-flash-sdl <file.swf>                       — windowed playback
//!   handyplay-flash-sdl <file.swf> --headless-frames N   — run N frames, dump
//!       the framebuffer as PNG (default out.png; --out <path>), no window.
//!
//! Streaming XRGB8888 texture (the Player framebuffer is presented as-is);
//! fixed tick gate from the movie's own frame rate. ESC/close quits.

const std = @import("std");
const flash = @import("flash");
const replay = @import("input_replay");
const audio = @import("audio.zig");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
    // For the wall clock and the local UTC offset: Zig's std carries no
    // timezone database, so the C library answers both.
    @cInclude("time.h");
});

/// Unix epoch milliseconds, now.
fn wallClockMs() f64 {
    return @as(f64, @floatFromInt(c.time(null))) * 1000.0;
}

/// Minutes this machine's local time is AHEAD of UTC.
fn localOffsetMinutes() i32 {
    var t: c.time_t = c.time(null);
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&t, &local) == null) return 0;
    return @intCast(@divTrunc(local.tm_gmtoff, 60));
}

/// Window pixels → stage pixels. The window may have been resized, and
/// the movie's coordinate space never changes with it.
fn stagePoint(player: *flash.Player, x: f32, y: f32) [2]f64 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window_handle, &w, &h);
    const sx: f64 = if (w > 0) @as(f64, @floatFromInt(player.width())) / @as(f64, @floatFromInt(w)) else 1;
    const sy: f64 = if (h > 0) @as(f64, @floatFromInt(player.height())) / @as(f64, @floatFromInt(h)) else 1;
    return .{ @as(f64, x) * sx, @as(f64, y) * sy };
}

fn sdlButton(b: u8) u8 {
    return switch (b) {
        c.SDL_BUTTON_MIDDLE => 1,
        c.SDL_BUTTON_RIGHT => 2,
        else => 0,
    };
}

/// SDL keycode → Flash key code. Flash uses the Windows virtual-key
/// numbering, in which letters are their UPPERCASE ASCII value.
fn flashKeyCode(k: c.SDL_Keycode) i32 {
    return switch (k) {
        c.SDLK_BACKSPACE => 8,
        c.SDLK_TAB => 9,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => 13,
        c.SDLK_LSHIFT, c.SDLK_RSHIFT => 16,
        c.SDLK_LCTRL, c.SDLK_RCTRL => 17,
        c.SDLK_LALT, c.SDLK_RALT => 18,
        c.SDLK_CAPSLOCK => 20,
        c.SDLK_ESCAPE => 27,
        c.SDLK_SPACE => 32,
        c.SDLK_PAGEUP => 33,
        c.SDLK_PAGEDOWN => 34,
        c.SDLK_END => 35,
        c.SDLK_HOME => 36,
        c.SDLK_LEFT => 37,
        c.SDLK_UP => 38,
        c.SDLK_RIGHT => 39,
        c.SDLK_DOWN => 40,
        c.SDLK_INSERT => 45,
        c.SDLK_DELETE => 46,
        else => blk: {
            if (k >= 'a' and k <= 'z') break :blk @as(i32, @intCast(k)) - 32;
            if (k >= ' ' and k <= '~') break :blk @intCast(k);
            // The keypad and the function row, which Flash numbers but
            // SDL keeps far outside the ASCII range.
            if (k >= c.SDLK_KP_1 and k <= c.SDLK_KP_9) break :blk 97 + @as(i32, @intCast(k - c.SDLK_KP_1));
            if (k == c.SDLK_KP_0) break :blk 96;
            if (k >= c.SDLK_F1 and k <= c.SDLK_F12) break :blk 112 + @as(i32, @intCast(k - c.SDLK_F1));
            break :blk 0;
        },
    };
}

/// The same, for the LITE profile — a handset keypad on a keyboard.
///
/// The two SOFT KEYS are the point. Flash Lite delivered them as PageUp
/// and PageDown (33 and 34), which is what every game in `games/` binds,
/// so F1/F2 and Q/W become exactly those codes. The rest is a phone:
/// digits, star, hash, a D-pad and one SELECT key.
/// SHIFT is folded in: SDL3 gives `Q` a different keycode from `q`, and a
/// soft key that stopped working because caps lock was on would be a
/// silly way to lose a game.
fn liteKeyCode(k: c.SDL_Keycode) i32 {
    return switch (k) {
        c.SDLK_F1, c.SDLK_Q, 'Q' => 33, // left soft key
        c.SDLK_F2, c.SDLK_W, 'W' => 34, // right soft key
        // Select. A handset had one button in the middle of the D-pad and
        // games read it as Enter; Space is here because a keyboard user
        // will reach for it first.
        c.SDLK_SPACE, c.SDLK_RETURN, c.SDLK_KP_ENTER => 13,
        c.SDLK_KP_0 => '0',
        c.SDLK_KP_1 => '1',
        c.SDLK_KP_2 => '2',
        c.SDLK_KP_3 => '3',
        c.SDLK_KP_4 => '4',
        c.SDLK_KP_5 => '5',
        c.SDLK_KP_6 => '6',
        c.SDLK_KP_7 => '7',
        c.SDLK_KP_8 => '8',
        c.SDLK_KP_9 => '9',
        c.SDLK_KP_MULTIPLY, c.SDLK_ASTERISK => '*',
        c.SDLK_KP_HASH, c.SDLK_HASH => '#',
        // The number row and the arrows already carry the right codes.
        else => flashKeyCode(k),
    };
}

/// What `Key.getAscii` reports — the character as typed, not the key code.
fn asciiOf(k: c.SDL_Keycode) i32 {
    if (k >= ' ' and k <= '~') return @intCast(k);
    return 0;
}

/// What a physical key MEANS, independent of any movie. The core turns
/// this into the code THIS movie listens for (`key_survey.resolve`), so
/// the frontend never has to know whether it is driving a phone game or
/// a desktop one.
fn actionOf(k: c.SDL_Keycode) ?flash.key_survey.Action {
    return switch (k) {
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => .select,
        c.SDLK_SPACE, c.SDLK_Z, 'Z' => .action_a,
        c.SDLK_X, 'X' => .action_b,
        c.SDLK_F1, c.SDLK_Q, 'Q' => .soft_left,
        c.SDLK_F2, c.SDLK_W, 'W' => .soft_right,
        c.SDLK_P, 'P' => .pause,
        c.SDLK_BACKSPACE => .back,
        else => null,
    };
}

/// The code to send for a physical key, decided by the MOVIE.
///
/// The first rule is the one that keeps desktop content working: if the
/// movie already reads what this key IS, send exactly that and change
/// nothing. Only a key the movie has no use for gets repurposed into the
/// code its action resolves to — which is how `Q` becomes a soft key in
/// a phone game and stays a plain `Q` everywhere else.
fn keyCodeFor(player: *flash.Player, k: c.SDL_Keycode) i32 {
    const natural = flashKeyCode(k);
    if (natural != 0 and player.keys.all.has(natural)) return natural;
    if (actionOf(k)) |a| {
        if (flash.key_survey.resolve(player.keys, a)) |code| return code;
    }
    // Nothing surveyed: fall back to the profile's fixed table, which is
    // all we have for a movie whose key handling could not be read (a
    // listener switching on variables leaves no literals behind).
    if (player.profile == .lite) return liteKeyCode(k);
    return natural;
}

/// A key that was REPURPOSED must not also deliver its own character:
/// `Q` as the left soft key may not type a q into a focused field, and
/// `Key.getAscii` must agree.
fn remapped(player: *flash.Player, k: c.SDL_Keycode) bool {
    return keyCodeFor(player, k) != flashKeyCode(k);
}


/// One line per `fscommand`/`fscommand2`, whatever it was. This is the
/// "track all commands" half of the feature: a game that asks for
/// something we stub still SAYS so, where a developer can see it.
fn logFsCommand(user: ?*anyopaque, call: flash.avm1.fscommand.Call) void {
    const out: *std.Io.Writer = @ptrCast(@alignCast(user orelse return));
    out.print("[{s}] {s}(", .{
        if (call.kind == .command2) "fscommand2" else "fscommand",
        call.name,
    }) catch return;
    for (call.args, 0..) |a, n| {
        out.print("{s}\"{s}\"", .{ if (n > 0) ", " else "", a }) catch return;
    }
    out.print(") -> {d}\n", .{call.result}) catch return;
    out.flush() catch {};
}

/// Set once the window exists; `stagePoint` needs it and SDL gives no way
/// to reach the window from an event.
var window_handle: ?*c.SDL_Window = null;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const err_out = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var swf_path: ?[]const u8 = null;
    var headless_frames: ?u32 = null;
    var out_path: []const u8 = "out.png";
    var device_font_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var antialias = true;
    var profile: ?flash.Profile = null;
    // `--capture <tick>:<path>`, repeatable: dump the stage after that
    // tick as well as at the end. The corpus's focus-rect dirs compare a
    // whole sequence of mid-run frames.
    var captures: std.ArrayList(struct { tick: u32, path: []const u8 }) = .empty;
    defer captures.deinit(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--headless-frames")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            headless_frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--device-font")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            device_font_path = args[i];
        } else if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            input_path = args[i];
        } else if (std.mem.eql(u8, arg, "--capture")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            const colon = std.mem.indexOfScalar(u8, args[i], ':') orelse return usage(err_out);
            try captures.append(gpa, .{
                .tick = try std.fmt.parseInt(u32, args[i][0..colon], 10),
                .path = args[i][colon + 1 ..],
            });
        } else if (std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            antialias = !std.mem.eql(u8, args[i], "low");
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            profile = flash.Profile.fromName(args[i]) orelse return usage(err_out);
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            out_path = args[i];
        } else if (swf_path == null) {
            swf_path = arg;
        } else return usage(err_out);
    }
    const path = swf_path orelse return usage(err_out);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(bytes);
    // Real content deserves the real clock and the real path; only the
    // conformance runner wants core's deterministic defaults.
    // A face for everything the movie did not embed. The player takes
    // BYTES — `core/` does no I/O — so the frontend reads the file.
    var device_font: ?[]const u8 = null;
    if (device_font_path) |fp| {
        device_font = std.Io.Dir.cwd().readFileAlloc(io, fp, gpa, .limited(16 << 20)) catch null;
    }
    defer if (device_font) |d| gpa.free(d);

    // Files the movie asks for (`loadMovie`, `XML.load`) come from the
    // SWF's own directory. `core/` does no I/O, so this is the frontend's
    // job — same seam the device font uses.
    var files: FileServer = .{
        .gpa = gpa,
        .io = io,
        .base = std.fs.path.dirname(path) orelse ".",
        .store = .init(gpa),
    };
    defer files.store.deinit();

    const player = flash.Player.createWith(gpa, bytes, .{
        .device_font = device_font,
        .url = path,
        .epoch_ms = wallClockMs(),
        .tz_offset_min = localOffsetMinutes(),
        .load_file = FileServer.read,
        .load_user = @ptrCast(&files),
        .antialias = antialias,
        .profile = profile,
        // Every device command the movie makes, on stderr — never
        // through `trace()`, which belongs to the movie.
        .fscommand_log = logFsCommand,
        .fscommand_user = @ptrCast(err_out),
    }) catch |err| {
        try err_out.print("{s}: {t}\n", .{ path, err });
        try err_out.flush();
        return 1;
    };
    defer player.destroy();

    try err_out.print("{s}: {d}x{d} @ {d:.2}fps, {d} frames, profile {t}\n", .{
        path, player.width(), player.height(), player.fps(), player.totalFrames(), player.profile,
    });
    try err_out.flush();

    try reportKeys(player, err_out);

    if (headless_frames) |n| {
        // A recorded input script, one batch per tick — the same cadence
        // the trace runner uses, because the corpus records one script
        // for both scores.
        var parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed) |*pv| pv.deinit();
        var events: []const std.json.Value = &.{};
        if (input_path) |ip| {
            if (std.Io.Dir.cwd().readFileAlloc(io, ip, gpa, .limited(4 << 20)) catch null) |text| {
                defer gpa.free(text);
                parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch null;
                if (parsed) |pv| {
                    if (pv.value == .array) events = pv.value.array.items;
                }
            }
        }
        var cursor: usize = replay.feedUntilWait(player, events, 0);
        // Headless still PULLS the audio, and reports how much of it was
        // not silence. An ear is better at judging a mix; a number is
        // better at catching a movie that plays nothing at all, which is
        // the only audio failure worth automating.
        var sink: [4096]i16 = undefined;
        var energy: u64 = 0;
        var f: u32 = 0;
        while (f < n) : (f += 1) {
            _ = try player.tick(1000.0 / player.fps());
            const want: usize = @min(sink.len / 2, @as(usize, @intFromFloat(44100.0 / player.fps())));
            player.renderAudio(sink[0 .. want * 2], want);
            for (sink[0 .. want * 2]) |v| energy += @abs(@as(i32, v));
            cursor = replay.feedUntilWait(player, events, cursor);
            for (captures.items) |shot| {
                if (shot.tick != f + 1) continue;
                const png = try player.canvas.surface.encodePng();
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = shot.path, .data = png });
            }
        }
        const png = try player.canvas.surface.encodePng();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png });
        try err_out.print("frame {d} → {s} ({d} bytes), audio energy {d}, {d}/{d} sounds started\n", .{
            player.currentFrame(), out_path, png.len, energy,
            player.sounds_played,  player.sounds_seen,
        });
        try err_out.flush();
        return 0;
    }

    return runWindowed(player, err_out);
}

/// What the movie was found to read, and what each binding became. This
/// is the whole point of surveying: the mapping is DERIVED, so it has to
/// be printable or nobody can tell what it did.
fn reportKeys(player: *flash.Player, out: *std.Io.Writer) !void {
    const s = player.keys;
    if (!s.usesKeyboard()) {
        try out.writeAll("keys: none — this movie never reads the keyboard\n");
        try out.flush();
        return;
    }
    try out.print("keys: {d} code(s) read", .{s.all.count()});
    if (s.listener) try out.writeAll(", a Key listener");
    if (s.dynamic_is_down) try out.writeAll(", REMAPPABLE controls");
    try out.writeAll("\n  ");
    var code: i32 = 0;
    while (code < 256) : (code += 1) {
        if (!s.all.has(code)) continue;
        // A code with no name still has a NUMBER, which is what someone
        // debugging a binding actually needs.
        if (flash.key_survey.keyName(code)) |n|
            try out.print("{s} ", .{n})
        else
            try out.print("#{d} ", .{code});
    }
    try out.writeAll("\n  bind:");
    for (std.enums.values(flash.key_survey.Action)) |a| {
        if (flash.key_survey.resolve(s, a)) |bound| {
            if (flash.key_survey.keyName(bound)) |n|
                try out.print(" {t}={s}", .{ a, n })
            else
                try out.print(" {t}=#{d}", .{ a, bound });
        }
    }
    try out.writeAll("\n");
    try out.flush();
}

fn usage(out: *std.Io.Writer) !u8 {
    try out.writeAll("usage: handyplay-flash-sdl <file.swf> [--headless-frames N] [--input input.json] [--quality low]\n            [--capture TICK:file.png] [--out out.png] [--profile lite|avm1|avm2]\n");
    try out.flush();
    return 2;
}

fn runWindowed(player: *flash.Player, err_out: *std.Io.Writer) !u8 {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        try err_out.print("SDL_Init: {s}\n", .{c.SDL_GetError()});
        try err_out.flush();
        return 1;
    }
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var sdl_renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer(
        "handyplay-flash",
        @intCast(player.width()),
        @intCast(player.height()),
        c.SDL_WINDOW_RESIZABLE,
        &window,
        &sdl_renderer,
    )) {
        try err_out.print("SDL_CreateWindowAndRenderer: {s}\n", .{c.SDL_GetError()});
        try err_out.flush();
        return 1;
    }
    defer c.SDL_DestroyRenderer(sdl_renderer);
    defer c.SDL_DestroyWindow(window);
    window_handle = window;
    // Printable characters raise their button `keyPress` from the TEXT
    // INPUT event, not the key-down, so the window has to be asking for
    // one — and it is also what lets a text field be typed into.
    _ = c.SDL_StartTextInput(window);
    audio.init();
    defer audio.deinit();

    const tex = c.SDL_CreateTexture(
        sdl_renderer,
        c.SDL_PIXELFORMAT_XRGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(player.width()),
        @intCast(player.height()),
    ) orelse {
        try err_out.print("SDL_CreateTexture: {s}\n", .{c.SDL_GetError()});
        try err_out.flush();
        return 1;
    };
    defer c.SDL_DestroyTexture(tex);
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);

    var last_ms = c.SDL_GetTicks();
    var running = true;
    var dirty = true; // first frame already rendered by create()
    // `trace()` goes to stderr as it happens. The player's buffer only
    // grows, so remember how much of it has been printed.
    var traced: usize = 0;
    // Set by a key-down whose character the Lite map has taken over, and
    // cleared by the TEXT INPUT it swallows.
    var eat_text = false;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_MOUSE_MOTION => {
                    const p = stagePoint(player, event.motion.x, event.motion.y);
                    try player.mouseMove(p[0], p[1]);
                    dirty = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    const p = stagePoint(player, event.button.x, event.button.y);
                    player.setMousePosition(p[0], p[1]);
                    try player.mouseButton(
                        sdlButton(event.button.button),
                        event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN,
                    );
                    dirty = true;
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) running = false;
                    // SDL raises the TEXT INPUT after the key-down, so the
                    // decision to swallow it is made here.
                    eat_text = remapped(player, event.key.key);
                    try player.keyDown(
                        keyCodeFor(player, event.key.key),
                        asciiFor(player, event.key.key),
                    );
                    dirty = true;
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (eat_text) {
                        eat_text = false;
                        continue;
                    }
                    const utf8 = std.mem.span(event.text.text);
                    var buf: [16]u16 = undefined;
                    const n = std.unicode.utf8ToUtf16Le(&buf, utf8) catch 0;
                    if (n > 0) try player.textInput(buf[0..n]);
                    dirty = true;
                },
                c.SDL_EVENT_KEY_UP => {
                    try player.keyUp(
                        keyCodeFor(player, event.key.key),
                        asciiFor(player, event.key.key),
                    );
                    dirty = true;
                },
                else => {},
            }
        }
        // `fscommand("quit")`, honoured — here and nowhere else. The
        // trace runner never reads this flag, which is what keeps 679
        // corpus movies from stopping on their own last line.
        if (player.quit_requested) running = false;
        const now = c.SDL_GetTicks();
        const elapsed: f64 = @floatFromInt(now - last_ms);
        last_ms = now;
        if (try player.tick(elapsed) > 0) dirty = true;
        audio.pump(player);

        const all = player.takeTrace();
        if (all.len > traced) {
            try err_out.writeAll(all[traced..]);
            try err_out.flush();
            traced = all.len;
        }

        if (dirty) {
            _ = c.SDL_UpdateTexture(
                tex,
                null,
                player.framebuffer().ptr,
                @intCast(player.width() * 4),
            );
            dirty = false;
        }
        _ = c.SDL_RenderClear(sdl_renderer);
        _ = c.SDL_RenderTexture(sdl_renderer, tex, null, null);
        drawSoftKeys(player, sdl_renderer);
        _ = c.SDL_RenderPresent(sdl_renderer);
        c.SDL_Delay(4);
    }
    return 0;
}


fn asciiFor(player: *flash.Player, k: c.SDL_Keycode) i32 {
    return if (remapped(player, k)) 0 else asciiOf(k);
}

/// The soft-key strip: two labels over the bottom corners of the stage,
/// which on a handset was the only clue what the two keys under the
/// screen did. `SDL_RenderDebugText` draws them — SDL3 carries its own
/// 8x8 font, so this needs no asset and no font loading.
fn drawSoftKeys(player: *flash.Player, renderer: ?*c.SDL_Renderer) void {
    if (player.profile != .lite) return;
    const left = player.softKey(0);
    const right = player.softKey(1);
    if (left.len == 0 and right.len == 0) return;

    var ow: c_int = 0;
    var oh: c_int = 0;
    _ = c.SDL_GetCurrentRenderOutputSize(renderer, &ow, &oh);
    const scale: f32 = 2.0;
    const char: f32 = @floatFromInt(c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE);
    const strip = char * scale + 6;
    const w: f32 = @floatFromInt(ow);
    const h: f32 = @floatFromInt(oh);

    // A translucent strip, so a label stays readable over game art.
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 160);
    var bar = c.SDL_FRect{ .x = 0, .y = h - strip, .w = w, .h = strip };
    _ = c.SDL_RenderFillRect(renderer, &bar);
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);

    // Text is drawn in SCALED coordinates, so every position below is
    // divided by the scale.
    _ = c.SDL_SetRenderScale(renderer, scale, scale);
    defer _ = c.SDL_SetRenderScale(renderer, 1, 1);
    const y = (h - strip + 3) / scale;
    var buf: [flash.Player.MAX_SOFT_KEY + 1]u8 = undefined;
    if (left.len > 0) {
        @memcpy(buf[0..left.len], left);
        buf[left.len] = 0;
        _ = c.SDL_RenderDebugText(renderer, 3 / scale, y, &buf);
    }
    if (right.len > 0) {
        @memcpy(buf[0..right.len], right);
        buf[right.len] = 0;
        const text_w = char * @as(f32, @floatFromInt(right.len));
        _ = c.SDL_RenderDebugText(renderer, (w - 3) / scale - text_w, y, &buf);
    }
}

/// Serves whatever the movie loads, out of the SWF's own directory.
/// Everything read stays alive for the session: a loaded SWF is parsed in
/// place and its buffer backs every clip below it.
const FileServer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    store: std.heap.ArenaAllocator,

    fn read(user: ?*anyopaque, url: []const u8, status: *flash.Player.FetchStatus) ?[]const u8 {
        const self: *FileServer = @ptrCast(@alignCast(user orelse return null));
        status.* = .ok;
        var rel = url;
        // Flash allows a query string on a local URL; the filesystem does not.
        if (std.mem.indexOfScalar(u8, rel, '?')) |q| rel = rel[0..q];
        // An absolute URL becomes HOST/path under the base directory —
        // ruffle's virtual filesystem maps `http://localhost:8000/a/b.swf`
        // to `<dir>/localhost/a/b.swf`, port and all discarded.
        if (std.mem.indexOf(u8, rel, "://")) |scheme| {
            const after = rel[scheme + 3 ..];
            const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            var host = after[0..slash];
            if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
            const tail = after[slash..];
            var joined_buf: [1024]u8 = undefined;
            rel = std.fmt.bufPrint(&joined_buf, "{s}{s}", .{ host, tail }) catch return null;
            // `joined_buf` dies with this frame, so resolve now.
            const full_abs = std.fs.path.join(self.gpa, &.{ self.base, rel }) catch return null;
            defer self.gpa.free(full_abs);
            return std.Io.Dir.cwd().readFileAlloc(
                self.io,
                full_abs,
                self.store.allocator(),
                .limited(256 << 20),
            ) catch null;
        }
        while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len == 0) return null;
        const full = std.fs.path.join(self.gpa, &.{ self.base, rel }) catch return null;
        defer self.gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(
            self.io,
            full,
            self.store.allocator(),
            .limited(256 << 20),
        ) catch null;
    }
};
