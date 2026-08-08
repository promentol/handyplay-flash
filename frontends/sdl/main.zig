//! SDL3 frontend.
//!
//!   handyflash-sdl <file.swf>                       — windowed playback
//!   handyflash-sdl <file.swf> --headless-frames N   — run N frames, dump
//!       the framebuffer as PNG (default out.png; --out <path>), no window.
//!
//! Streaming XRGB8888 texture (the Player framebuffer is presented as-is);
//! fixed tick gate from the movie's own frame rate. ESC/close quits.

const std = @import("std");
const flash = @import("flash");

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
            break :blk 0;
        },
    };
}

/// What `Key.getAscii` reports — the character as typed, not the key code.
fn asciiOf(k: c.SDL_Keycode) i32 {
    if (k >= ' ' and k <= '~') return @intCast(k);
    return 0;
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

    const player = flash.Player.createWith(gpa, bytes, .{
        .device_font = device_font,
        .url = path,
        .epoch_ms = wallClockMs(),
        .tz_offset_min = localOffsetMinutes(),
    }) catch |err| {
        try err_out.print("{s}: {t}\n", .{ path, err });
        try err_out.flush();
        return 1;
    };
    defer player.destroy();

    try err_out.print("{s}: {d}x{d} @ {d:.2}fps, {d} frames\n", .{
        path, player.width(), player.height(), player.fps(), player.totalFrames(),
    });
    try err_out.flush();

    if (headless_frames) |n| {
        var f: u32 = 0;
        while (f < n) : (f += 1) {
            _ = try player.tick(1000.0 / player.fps());
        }
        const png = try player.canvas.surface.encodePng();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png });
        try err_out.print("frame {d} → {s} ({d} bytes)\n", .{ player.currentFrame(), out_path, png.len });
        try err_out.flush();
        return 0;
    }

    return runWindowed(player, err_out);
}

fn usage(out: *std.Io.Writer) !u8 {
    try out.writeAll("usage: handyflash-sdl <file.swf> [--headless-frames N] [--out out.png]\n");
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
        "handyflash",
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
                    try player.keyDown(flashKeyCode(event.key.key), asciiOf(event.key.key));
                    dirty = true;
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const utf8 = std.mem.span(event.text.text);
                    var buf: [16]u16 = undefined;
                    const n = std.unicode.utf8ToUtf16Le(&buf, utf8) catch 0;
                    if (n > 0) try player.textInput(buf[0..n]);
                    dirty = true;
                },
                c.SDL_EVENT_KEY_UP => {
                    try player.keyUp(flashKeyCode(event.key.key), asciiOf(event.key.key));
                    dirty = true;
                },
                else => {},
            }
        }
        const now = c.SDL_GetTicks();
        const elapsed: f64 = @floatFromInt(now - last_ms);
        last_ms = now;
        if (try player.tick(elapsed) > 0) dirty = true;

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
        _ = c.SDL_RenderPresent(sdl_renderer);
        c.SDL_Delay(4);
    }
    return 0;
}
