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
    pub const stage_object = @import("avm1/stage_object.zig");
};

pub const display = struct {
    pub const library = @import("display/library.zig");
    pub const display_object = @import("display/display_object.zig");
    pub const bounds = @import("display/bounds.zig");
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
    /// The root clip has no parent to hold its placement, but AVM1 can
    /// still write `_root._x`/`_alpha`/`_visible`, so the Player owns one.
    /// `owns_kind` is false — `root` is a field, not a heap allocation.
    root_placement: display.display_object.DisplayObject,
    canvas: render.canvas.Canvas,
    renderer: render.renderer.Renderer,
    background: swf.reader.Color,
    vm: *Vm,
    /// Flash's `instanceN` counter. Monotonic for the life of the movie;
    /// ruffle resets it only when the root movie is replaced.
    instance_counter: u32 = 0,
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
            .root_placement = undefined,
            .canvas = try render.canvas.Canvas.init(gpa, w, h),
            .renderer = render.renderer.Renderer.init(self.movie.allocator()),
            .background = (movie.background_color orelse 0x00FFFFFF) | 0xFF000000,
            .vm = try Vm.create(gpa, movie.swf_version),
            .frame_ms = 1000.0 / @as(f64, fps_clamped),
        };
        // After the literal: both halves need `self` to be at its final
        // address, and frame 1 below can already touch `_root._x`.
        self.root_placement = .{
            .character_id = 0,
            .depth = 0,
            .kind = .{ .clip = &self.root },
            .owns_kind = false,
        };
        self.root.placement = &self.root_placement;
        // The ROOT consumes instance0 without keeping it: ruffle runs
        // post_instantiation (which names it) and only then
        // set_default_root_name, which blanks the name again for AVM1
        // (context.rs:404-405). That is why children start at instance1
        // and why `_root._name` is "" — corpus default_names.
        self.instance_counter = 1;
        self.installHost();
        // Bind `_root` BEFORE frame 1. Lazily creating it in the action
        // drain was a trap: a root frame that places a child before its own
        // DoAction drains the CHILD first, so every `_root`-anchored path
        // resolved against Vm.create's placeholder object instead of the
        // real clip — and a movie with no DoAction at all never bound it.
        _ = try self.clipObject(&self.root);
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
        var ctx: display.movie_clip.Context = .{
            .gpa = self.gpa,
            .movie = &self.movie,
            .instance_counter = &self.instance_counter,
        };
        defer ctx.deinit(self.gpa);
        try self.root.runFrame(&ctx);
        try self.root.applyPendingGoto(&ctx);
        // Drain the action queue (actions can queue more via gotos —
        // pending gotos apply between drains; new DoActions from replays
        // stay suppressed per Ruffle's run_goto rule). A goto here can
        // remove a clip whose own DoAction is still queued behind us; such
        // clips are marked `removed` and stay alive until `retireDead`
        // below, so the pointer is safe and scripts see undefined.
        var i: usize = 0;
        while (i < ctx.actions.items.len) : (i += 1) {
            const qa = ctx.actions.items[i];
            if (qa.clip.removed) continue;
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
        self.retireDead(&ctx);
        self.vm.now_ms += self.frame_ms;
        self.vm.budget = 200_000;
        self.vm.halted = false;
        if (ctx.background_color) |c| self.background = c | 0xFF000000;
    }

    /// Free the clips removed during this tick, now that no queued action
    /// can still reference them. Their AVM1 objects may outlive them (a
    /// script can hold the reference), so sever the native link first —
    /// otherwise every later property read is a use-after-free.
    fn retireDead(self: *Player, ctx: *display.movie_clip.Context) void {
        for (ctx.graveyard.items) |obj| self.severClipObjects(obj);
        ctx.drainGraveyard(self.gpa);
    }

    fn severClipObjects(self: *Player, obj: *display.display_object.DisplayObject) void {
        if (obj.kind != .clip) return;
        const mc = obj.kind.clip;
        if (mc.avm_object != 0) self.vm.objects.get(mc.avm_object).native = .none;
        for (mc.children.items) |child| self.severClipObjects(child);
    }

    /// Fetch (creating once) the AVM1 object for a clip. Object creation
    /// itself lives in `stage_object.clipObject` — this wrapper only adds
    /// the root's global bindings, which nothing below the Player knows
    /// about.
    fn clipObject(self: *Player, mc: *MovieClipT) !avm1.runtime.ObjectHandle {
        const existed = mc.avm_object != 0;
        const h = try avm1.stage_object.clipObject(self.vm, mc);
        if (!existed and mc == &self.root) {
            self.vm.root_scope = h;
            self.vm.root_object = .{ .object = h };
            // NOT registered as _global properties: `_root`/`_levelN` are
            // resolved through the display tree (stage_object's path
            // properties), which correctly yields undefined below SWF5
            // where they do not exist. A _global entry would leak them
            // into SWF4 — corpus target_paths/swf4.
            const S = avm1.strings.ascii;
            _ = self.vm.objects.deleteOwn(self.vm.globals, S("_root"), self.vm.case_sensitive);
            _ = self.vm.objects.deleteOwn(self.vm.globals, S("_level0"), self.vm.case_sensitive);
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
        try self.renderer.renderFrame(
            &self.canvas,
            &self.root,
            &self.root_placement,
            self.background,
            stage,
        );
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
    _ = @import("display/bounds.zig");
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
    _ = @import("avm1/stage_object.zig");
    _ = @import("avm1/globals/globals.zig");
}
