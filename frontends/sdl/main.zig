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
});

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
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--headless-frames")) {
            i += 1;
            if (i >= args.len) return usage(err_out);
            headless_frames = try std.fmt.parseInt(u32, args[i], 10);
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
    const player = flash.Player.create(gpa, bytes) catch |err| {
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
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) running = false;
                },
                else => {},
            }
        }
        const now = c.SDL_GetTicks();
        const elapsed: f64 = @floatFromInt(now - last_ms);
        last_ms = now;
        if (try player.tick(elapsed) > 0) dirty = true;

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
