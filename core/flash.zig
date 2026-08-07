//! Umbrella module root + the host seam (mirrors handyplay-oss exen.zig).
//! Frontend-agnostic, no I/O: frontends create a Player from SWF bytes,
//! feed it elapsed time, and present `framebuffer()` (XRGB8888).

const std = @import("std");

pub const swf = @import("swf/swf.zig");

pub const avm1 = struct {
    pub const opcodes = @import("avm1/opcodes.zig");
    pub const strings = @import("avm1/string.zig");
    pub const value = @import("avm1/value.zig");
    pub const object = @import("avm1/object.zig");
    pub const runtime = @import("avm1/runtime.zig");
    pub const activation = @import("avm1/activation.zig");
};

pub const display = struct {
    pub const library = @import("display/library.zig");
    pub const display_object = @import("display/display_object.zig");
    pub const movie_clip = @import("display/movie_clip.zig");
    // M4: button.zig, text.zig.
};

pub const render = struct {
    pub const canvas = @import("render/canvas.zig");
    pub const shape_utils = @import("render/shape_utils.zig");
    pub const renderer = @import("render/renderer.zig");
    // M4: bitmap fills; M7: masks.
};

pub const LoadError = swf.movie.Error || error{OutOfMemory};

const Vm = avm1.runtime.Vm;
const MovieClipT = display.movie_clip.MovieClip;

/// The player instance. Heap-pinned (`create`/`destroy`) because the
/// simdra surface↔canvas pair is self-referential once created.
pub const Player = struct {
    gpa: std.mem.Allocator,
    movie: swf.movie.Movie,
    root: display.movie_clip.MovieClip,
    canvas: render.canvas.Canvas,
    renderer: render.renderer.Renderer,
    background: swf.reader.Color,
    vm: *Vm,
    /// Fixed timestep (ms/frame) from the SWF header, clamped 0.01–120 fps.
    frame_ms: f64,
    acc_ms: f64 = 0,

    /// Safety valve: max timeline frames advanced per tick call.
    const MAX_FRAMES_PER_TICK = 5;

    pub fn create(gpa: std.mem.Allocator, file_bytes: []const u8) LoadError!*Player {
        const self = try gpa.create(Player);
        errdefer gpa.destroy(self);
        var movie = try swf.movie.load(gpa, file_bytes);
        errdefer movie.deinit();
        const fps_clamped = std.math.clamp(movie.header.frame_rate, 0.01, 120.0);
        const w = @max(movie.header.widthPx(), 1);
        const h = @max(movie.header.heightPx(), 1);
        self.* = .{
            .gpa = gpa,
            .movie = movie,
            .root = display.movie_clip.MovieClip.init(movie.frames),
            .canvas = try render.canvas.Canvas.init(gpa, w, h),
            .renderer = render.renderer.Renderer.init(self.movie.allocator()),
            .background = (movie.background_color orelse 0x00FFFFFF) | 0xFF000000,
            .vm = try Vm.create(gpa, movie.swf_version),
            .frame_ms = 1000.0 / @as(f64, fps_clamped),
        };
        self.installHost();
        // Frame 1 executes immediately so the first present isn't blank.
        try self.runOneFrame();
        try self.renderNow();
        return self;
    }

    pub fn destroy(self: *Player) void {
        const gpa = self.gpa;
        self.vm.destroy();
        self.root.deinit(gpa);
        self.canvas.deinit();
        self.movie.deinit();
        gpa.destroy(self);
    }

    /// Advance the fixed-timestep clock; returns how many timeline frames
    /// ran (0 = nothing new to present).
    pub fn tick(self: *Player, elapsed_ms: f64) !u32 {
        self.acc_ms += elapsed_ms;
        var frames: u32 = 0;
        while (self.acc_ms >= self.frame_ms and frames < MAX_FRAMES_PER_TICK) {
            try self.runOneFrame();
            self.acc_ms -= self.frame_ms;
            frames += 1;
        }
        // Cap backlog after pauses/hiccups.
        if (self.acc_ms > self.frame_ms * MAX_FRAMES_PER_TICK) {
            self.acc_ms = self.frame_ms;
        }
        if (frames > 0) try self.renderNow();
        return frames;
    }

    fn runOneFrame(self: *Player) !void {
        var ctx: display.movie_clip.Context = .{ .gpa = self.gpa, .movie = &self.movie };
        defer ctx.actions.deinit(self.gpa);
        try self.root.runFrame(&ctx);
        try self.root.applyPendingGoto(&ctx);
        // Drain the action queue (actions can queue more via gotos —
        // pending gotos apply between drains; new DoActions from replays
        // stay suppressed per Ruffle's run_goto rule).
        var i: usize = 0;
        while (i < ctx.actions.items.len) : (i += 1) {
            const qa = ctx.actions.items[i];
            const clip_obj = try self.clipObject(qa.clip);
            var act = avm1.activation.Activation.init(
                self.vm,
                qa.code,
                .{ .object = clip_obj },
                clip_obj,
                self.vm.active_pool,
            );
            _ = act.run() catch {};
            try self.root.applyPendingGoto(&ctx);
        }
        self.vm.now_ms += self.frame_ms;
        self.vm.budget = 200_000;
        self.vm.halted = false;
        if (ctx.background_color) |c| self.background = c | 0xFF000000;
    }

    /// Lazily create/fetch the AVM1 object for a clip. The clip object IS
    /// the timeline's variable scope (scope_parent = 0 → falls through to
    /// _global), with native = the MovieClip pointer for host dispatch.
    fn clipObject(self: *Player, mc: *MovieClipT) !avm1.runtime.ObjectHandle {
        if (mc.avm_object != 0) return mc.avm_object;
        const h = try self.vm.objects.create();
        self.vm.objects.get(h).proto = .{ .object = self.vm.object_proto };
        self.vm.objects.get(h).native = .{ .clip = @ptrCast(mc) };
        mc.avm_object = h;
        if (mc == &self.root) {
            self.vm.root_scope = h;
            self.vm.root_object = .{ .object = h };
            const S = avm1.strings.ascii;
            try self.vm.objects.put(self.vm.globals, S("_root"), self.vm.root_object, self.vm.case_sensitive);
            try self.vm.objects.put(self.vm.globals, S("_level0"), self.vm.root_object, self.vm.case_sensitive);
        }
        return h;
    }

    fn installHost(self: *Player) void {
        self.vm.host = .{
            .ctx = @ptrCast(self),
            .goto_frame = hostGotoFrame,
            .goto_label = hostGotoLabel,
            .set_playing = hostSetPlaying,
            .next_prev = hostNextPrev,
        };
    }

    fn hostGotoFrame(ctx: *anyopaque, clip: *anyopaque, frame: u16, play: bool) void {
        _ = ctx;
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.gotoFrame(frame);
        mc.playing = play;
    }

    fn hostGotoLabel(ctx: *anyopaque, clip: *anyopaque, label: []const u16, play: bool) bool {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        for (label) |c| {
            if (n >= buf.len or c > 0x7F) break;
            buf[n] = @intCast(c);
            n += 1;
        }
        _ = self;
        const target = mc.labelToNumber(buf[0..n]) orelse return false;
        mc.gotoFrame(target);
        mc.playing = play;
        return true;
    }

    fn hostSetPlaying(ctx: *anyopaque, clip: *anyopaque, playing: bool) void {
        _ = ctx;
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.playing = playing;
    }

    fn hostNextPrev(ctx: *anyopaque, clip: *anyopaque, delta: i2) void {
        _ = ctx;
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        const cur = mc.current_frame;
        if (delta > 0) {
            mc.gotoFrame(cur + 1);
        } else if (cur > 1) {
            mc.gotoFrame(cur - 1);
        }
        mc.playing = false;
    }

    /// Take accumulated trace() output (UTF-8; caller-owned view valid
    /// until the next VM activity).
    pub fn takeTrace(self: *Player) []const u8 {
        return self.vm.trace_buf.items;
    }

    fn renderNow(self: *Player) !void {
        const inv_twips = 1.0 / @as(f64, swf.reader.TWIPS_PER_PX);
        const stage: render.renderer.Transform = .{
            .a = inv_twips,
            .d = inv_twips,
            // Stages with non-zero origins translate here.
            .tx = -@as(f64, @floatFromInt(self.movie.header.xmin)) * inv_twips,
            .ty = -@as(f64, @floatFromInt(self.movie.header.ymin)) * inv_twips,
        };
        try self.renderer.renderFrame(&self.canvas, &self.root, self.background, stage);
    }

    /// XRGB8888 little-endian, width()*height().
    pub fn framebuffer(self: *const Player) []const u32 {
        return self.canvas.pixels();
    }
    pub fn width(self: *const Player) u32 {
        return self.canvas.width();
    }
    pub fn height(self: *const Player) u32 {
        return self.canvas.height();
    }
    pub fn fps(self: *const Player) f64 {
        return 1000.0 / self.frame_ms;
    }
    pub fn currentFrame(self: *const Player) u16 {
        return self.root.current_frame;
    }
    pub fn totalFrames(self: *const Player) u16 {
        return self.root.totalFrames();
    }
};

test {
    // Explicit imports: test blocks are only collected from files that a
    // test-context import reaches (refAllDecls alone proved unreliable —
    // display/render/avm1 tests silently dropped out of the binary).
    @import("std").testing.refAllDecls(@This());
    _ = @import("display/library.zig");
    _ = @import("display/display_object.zig");
    _ = @import("display/movie_clip.zig");
    _ = @import("render/canvas.zig");
    _ = @import("render/shape_utils.zig");
    _ = @import("render/renderer.zig");
    _ = @import("avm1/opcodes.zig");
    _ = @import("avm1/string.zig");
    _ = @import("avm1/value.zig");
    _ = @import("avm1/object.zig");
    _ = @import("avm1/runtime.zig");
    _ = @import("avm1/activation.zig");
    _ = @import("avm1/globals/globals.zig");
}
