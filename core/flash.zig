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
    pub const singletons = @import("avm1/globals/singletons.zig");
    pub const text_binding = @import("avm1/text_binding.zig");
};

pub const bitmap = struct {
    pub const pixels = @import("bitmap/pixels.zig");
    pub const data = @import("bitmap/data.zig");
    pub const operations = @import("bitmap/operations.zig");
    pub const decode = @import("bitmap/decode.zig");
};

pub const display = struct {
    pub const library = @import("display/library.zig");
    pub const display_object = @import("display/display_object.zig");
    pub const bounds = @import("display/bounds.zig");
    pub const movie_clip = @import("display/movie_clip.zig");
    pub const button = @import("display/button.zig");
    pub const text = @import("display/text.zig");
    pub const edit_text = @import("display/edit_text.zig");
    pub const device_font = @import("display/device_font.zig");
    pub const font = @import("display/font.zig");
    pub const text_layout = @import("display/text_layout.zig");
    pub const mouse = @import("display/mouse.zig");
    pub const tab = @import("display/tab.zig");
    // M4: text.zig.
};

pub const text = struct {
    pub const format = @import("text/format.zig");
    pub const spans = @import("text/spans.zig");
    pub const html = @import("text/html.zig");
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
    /// The tick's display context, live only while runOneFrame is on the
    /// stack. Gotos need it to replay IMMEDIATELY, the way ruffle's
    /// goto_frame does, rather than being deferred to the end of the
    /// action — a script can observe the removal its own goto caused.
    cur_ctx: ?*display.movie_clip.Context = null,
    /// What the pointer is over, and what it was pressed on. Both survive
    /// across events — the whole rollOver/dragOut machine is the delta
    /// between the old pair and the new pick.
    hovered: ?*display.display_object.DisplayObject = null,
    pressed: ?*display.display_object.DisplayObject = null,
    /// Flash's `instanceN` counter. Monotonic for the life of the movie;
    /// ruffle resets it only when the root movie is replaced.
    instance_counter: u32 = 0,
    /// DoInitAction runs once, before frame 1 (see `runInitActions`).
    init_actions_done: bool = false,
    /// The host clipboard, as far as a text field is concerned. Owned by
    /// the player because Cut and Paste must see the same one.
    clipboard: std.ArrayList(u16) = .empty,
    /// The parsed device face, owned here and pointed at by the library.
    device_face: ?*display.device_font.DeviceFont = null,
    /// Fixed timestep (ms/frame) from the SWF header, clamped 0.01–120 fps.
    frame_ms: f64,
    acc_ms: f64 = 0,
    /// Milliseconds of wall time since the movie started. Only the
    /// caret's blink reads it, so it need not be precise — just monotone.
    elapsed_ms: f64 = 0,

    /// Safety valve: max timeline frames advanced per tick call.
    const MAX_FRAMES_PER_TICK = 5;

    /// Host facts the movie can observe but `core/` cannot discover for
    /// itself. Everything defaults to the deterministic value the
    /// conformance runner wants, so `create` stays a two-argument call.
    pub const Options = struct {
        /// What `_url` reports. Flash uses the path the movie was loaded
        /// from; the corpus expects the local form "/test.swf".
        url: []const u8 = "",
        /// Wall clock at movie start (Unix epoch ms) and the local zone's
        /// offset in minutes, for `Date`. The defaults are the
        /// deterministic mock the conformance runner needs; a real frontend
        /// passes the real clock.
        epoch_ms: f64 = avm1.runtime.MOCK_EPOCH_MS,
        tz_offset_min: i32 = 345,
        /// The presentation area in DEVICE pixels, and the HiDPI factor.
        /// Zero means "the movie's own stage box at 1:1", which is what a
        /// windowed frontend wants; `test.toml`'s `viewport_dimensions`
        /// overrides it.
        viewport_width: u32 = 0,
        viewport_height: u32 = 0,
        scale_factor: f64 = 1.0,
        /// A TTF for every face the movie did NOT embed. `core/` does no
        /// I/O, so the host reads the file and hands the bytes over; with
        /// none, an unembedded face measures zero and draws nothing,
        /// which is what a machine without the font installed does.
        device_font: ?[]const u8 = null,
    };

    pub fn create(gpa: std.mem.Allocator, file_bytes: []const u8) anyerror!*Player {
        return createWith(gpa, file_bytes, .{});
    }

    /// `anyerror` rather than `LoadError`: frame 1 runs here, and a
    /// script on it can fail in any of the ways a later frame can.
    pub fn createWith(gpa: std.mem.Allocator, file_bytes: []const u8, opts: Options) anyerror!*Player {
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
        // Host facts the VM needs BEFORE frame 1: a frame-1 script can read
        // `_url` or call `getBounds` (whose invalid-value latch consults the
        // root movie's version).
        // AFTER the struct literal above: `Renderer.init` runs inside it,
        // where `&self.movie` is not yet a valid pointer (same reason the
        // root placement is fixed up separately).
        if (opts.device_font) |ttf| {
            const face = try gpa.create(display.device_font.DeviceFont);
            face.* = display.device_font.DeviceFont.init(gpa, ttf) catch {
                gpa.destroy(face);
                return error.InvalidFont;
            };
            self.device_face = face;
            self.movie.lib.device_font = face;
        }
        self.renderer.lib = &self.movie.lib;
        self.renderer.swf_version = self.movie.swf_version;
        self.renderer.display_gpa = gpa;
        self.renderer.jpeg_tables = self.movie.jpeg_tables;
        self.vm.root_swf_version = self.movie.swf_version;
        self.vm.movie_url = avm1.strings.fromSwf(self.vm.arena(), opts.url, 8) catch &.{};
        self.vm.epoch_ms = opts.epoch_ms;
        self.vm.stage_width = w;
        self.vm.stage_height = h;
        self.vm.movie_width = @floatFromInt(w);
        self.vm.movie_height = @floatFromInt(h);
        self.vm.viewport_width = if (opts.viewport_width != 0) opts.viewport_width else w;
        self.vm.viewport_height = if (opts.viewport_height != 0) opts.viewport_height else h;
        self.vm.viewport_scale = if (opts.scale_factor > 0) opts.scale_factor else 1.0;
        // The screen the capabilities report is the viewport corrected for
        // HiDPI (ruffle's test harness feeds them from the same option).
        self.vm.screen_width = @intFromFloat(@round(@as(f64, @floatFromInt(self.vm.viewport_width)) / self.vm.viewport_scale));
        self.vm.screen_height = @intFromFloat(@round(@as(f64, @floatFromInt(self.vm.viewport_height)) / self.vm.viewport_scale));
        _ = avm1.stage_object.recomputeView(self.vm);
        self.vm.use_network_sandbox = self.movie.use_network_sandbox;
        self.vm.tz_offset_min = opts.tz_offset_min;
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
        if (self.device_face) |f| {
            f.deinit();
            gpa.destroy(f);
        }
        self.clipboard.deinit(gpa);
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
        self.elapsed_ms += elapsed_ms;
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

    /// One tick's display Context. Every entry point builds the same one.
    fn makeContext(self: *Player) display.movie_clip.Context {
        return .{
            .gpa = self.gpa,
            .movie = &self.movie,
            .instance_counter = &self.instance_counter,
            .class_lookup = hostRegisteredClass,
            .class_lookup_user = @ptrCast(self),
            .run_inline = hostRunInline,
            .has_button_handler = hostHasButtonHandler,
            .mouse_enabled = hostMouseEnabled,
            .lost_display_object = hostLostDisplayObject,
            .bool_property = hostBoolProperty,
            .key_focus = hostKeyFocus,
            .object_instantiated = hostObjectInstantiated,
        };
    }

    fn runOneFrame(self: *Player) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try self.runInitActions(&ctx);
        try self.root.runFrame(&ctx);
        try self.root.applyPendingGoto(&ctx);
        try self.drainActions(&ctx);
        try self.updateTimers(&ctx);
        self.root.clearRanThisTick();
        self.retireDead(&ctx);
        // Ruffle re-picks at the end of EVERY update, not just on pointer
        // events (player.rs:2386) — a clip that moves, hides or is removed
        // under a stationary pointer changes the hover all by itself.
        try self.updateMouseState(false, false);
        self.vm.now_ms += self.frame_ms;
        self.vm.budget = 5_000_000;
        self.vm.halted = false;
        if (ctx.background_color) |c| self.background = c | 0xFF000000;
    }

    /// Drain the action queue (actions can queue more via gotos — pending
    /// gotos apply between drains; new DoActions from replays stay
    /// suppressed per Ruffle's run_goto rule). A goto here can remove a clip
    /// whose own DoAction is still queued behind us; such clips are marked
    /// `removed` and stay alive until `retireDead`, so the pointer is safe
    /// and scripts see undefined.
    fn drainActions(self: *Player, ctx: *display.movie_clip.Context) !void {
        while (ctx.popAction()) |qa| {
            if (qa.clip.removed and !qa.on_removed) continue;
            // A button's handler runs on the BUTTON's script object; the
            // queued `clip` is only its parent, for the removal check.
            if (qa.display) |d| {
                if (d.removed) continue;
                const h = try avm1.stage_object.displayObject(self.vm, d);
                switch (qa.what) {
                    .method => |name| self.callClipHandler(h, name),
                    else => {},
                }
                try self.root.applyPendingGoto(ctx);
                continue;
            }
            const clip_obj = try self.clipObject(qa.clip);
            switch (qa.what) {
                .code => |code| self.runBytecode(clip_obj, code),
                .method => |name| self.callClipHandler(clip_obj, name),
                .construct => |c| {
                    // Order is load-bearing: the prototype must be in place
                    // before the construct handlers run, and the constructor
                    // itself runs last (ruffle player.rs:2169-2196).
                    if (c.ctor != 0) {
                        const proto = self.vm.objects.getChained(
                            c.ctor,
                            avm1.strings.ascii("prototype"),
                            self.vm.case_sensitive,
                        ) orelse avm1.value.Value.undefined_value;
                        self.vm.objects.get(clip_obj).proto = proto;
                    }
                    for (c.events) |code| self.runBytecode(clip_obj, code);
                    if (c.ctor != 0) {
                        _ = self.vm.constructOnExisting(c.ctor, clip_obj) catch |e|
                            self.reportUncaught(e);
                    }
                },
            }
            try self.root.applyPendingGoto(ctx);
        }
    }

    /// Fire whatever timers came due this frame. Ruffle updates timers in
    /// `Player::tick` AFTER `run_frame`, and drains the action queue between
    /// callbacks, so a timer that gotos sees the effect before the next one
    /// fires. Callbacks run with the ROOT as base clip.
    fn updateTimers(self: *Player, ctx: *display.movie_clip.Context) !void {
        const timers = &self.vm.timers;
        timers.advance(self.frame_ms);
        if (timers.list.items.len == 0) return;
        const root_obj = try self.clipObject(&self.root);
        var fired: u32 = 0;
        while (timers.due()) |timer| {
            fired += 1;
            if (fired > @TypeOf(timers.*).MAX_TICKS) {
                // Too many at once: rewind the clock to just before this
                // one rather than starving the frame.
                timers.backOff(timer);
                break;
            }
            const id = timer.id;
            const callback = timer.callback;
            const params = timer.params;
            const result = switch (callback) {
                .func => |f| self.vm.callFunction(
                    .{ .object = f },
                    .{ .object = root_obj },
                    params,
                ),
                // Resolved at FIRE time, so reassigning the method between
                // ticks changes what runs — and a missing one just no-ops.
                // A timer bound to a clip stops firing once that clip is
                // removed, WITHOUT being cancelled (ruffle timer.rs:97-114).
                .method => |m| blk: {
                    if (avm1.stage_object.isRemovedClip(self.vm, m.this)) {
                        break :blk avm1.value.Value.undefined_value;
                    }
                    const f = self.vm.getProperty(m.this, m.name, .{ .object = m.this }) catch
                        avm1.value.Value.undefined_value;
                    break :blk self.vm.callFunction(f, .{ .object = m.this }, params);
                },
            };
            // A truthy return value cancels the interval (ruffle timer.rs
            // `cancel_timer`).
            const cancelled = if (result) |v|
                avm1.value.toBoolean(v, self.vm.swf_version)
            else |e| blk: {
                self.reportUncaught(e);
                break :blk false;
            };
            timers.reschedule(id, cancelled);
            try self.drainActions(ctx);
        }
    }

    /// Every `DoInitAction` in the main timeline, run once before the first
    /// frame. Ruffle executes these during PRELOAD rather than on the
    /// timeline, so a class registered by `#initclip` is available to
    /// PlaceObject tags that appear before it in the tag stream.
    ///
    /// Init actions nested inside a DefineSprite are skipped: the SWF spec
    /// forbids them and ruffle notes its own handling there is nonsense.
    fn runInitActions(self: *Player, ctx: *display.movie_clip.Context) !void {
        if (self.init_actions_done) return;
        self.init_actions_done = true;
        const root_obj = try self.clipObject(&self.root);
        for (self.movie.frames) |frame| {
            for (frame.controls) |control| {
                if (control != .init_action) continue;
                self.runBytecode(root_obj, control.init_action.code);
                try self.root.applyPendingGoto(ctx);
            }
        }
    }

    fn runBytecode(self: *Player, clip_obj: avm1.runtime.ObjectHandle, code: []const u8) void {
        var act = avm1.activation.Activation.init(
            self.vm,
            code,
            .{ .object = clip_obj },
            clip_obj,
            self.vm.active_pool,
        );
        _ = act.run() catch |e| self.reportUncaught(e);
    }

    /// Invoke a script-assigned event handler (`clip.onEnterFrame = f`)
    /// if one is present. Absent handlers are the common case, so this
    /// must stay a cheap lookup miss.
    fn callClipHandler(self: *Player, clip_obj: avm1.runtime.ObjectHandle, name: []const u8) void {
        var buf: [24]u16 = undefined;
        for (name, 0..) |c, i| buf[i] = c;
        const wide = buf[0..name.len];
        const f = self.vm.objects.getChained(clip_obj, wide, self.vm.case_sensitive) orelse return;
        if (!self.vm.isCallable(f)) return;
        _ = self.vm.callFunction(f, .{ .object = clip_obj }, &.{}) catch |e| self.reportUncaught(e);
    }

    /// A throw that escapes the outermost action is reported and execution
    /// continues — Flash does not stop the movie (ruffle
    /// avm1/runtime.rs:668-684). The message goes to the trace sink,
    /// which is where the corpus expects to see it.
    fn reportUncaught(self: *Player, e: anyerror) void {
        if (e != error.Avm1Thrown) return;
        const S = avm1.strings.ascii;
        const msg = self.vm.toStringValue(self.vm.pending_throw) catch S("[type Object]");
        const prefix = S("Warning: Uncaught exception, ");
        const line = avm1.strings.concat(self.vm.arena(), prefix, msg) catch return;
        self.vm.traceLine(line) catch {};
        self.vm.pending_throw = .undefined_value;
    }

    /// Free the clips removed during this tick, now that no queued action
    /// can still reference them. Their AVM1 objects may outlive them (a
    /// script can hold the reference), so sever the native link first —
    /// otherwise every later property read is a use-after-free.
    fn retireDead(self: *Player, ctx: *display.movie_clip.Context) void {
        for (ctx.graveyard.items) |obj| {
            self.severClipObjects(obj);
            self.rebindMouseTargets(ctx, obj);
        }
        ctx.drainGraveyard(self.gpa);
    }

    /// A goto can destroy the very object the pointer is on. Ruffle keeps
    /// the old one alive and re-acquires at the top of the next
    /// `update_mouse_state`; our display objects are freed at the end of
    /// the tick, so the hand-off has to happen HERE, while both the dead
    /// object and its replacement exist.
    ///
    /// "Replacement" is ruffle's `check_display_object_equality`: same
    /// depth, same character. The button state carries across, which is
    /// what lets a press survive the goto it triggered (corpus
    /// button_goto).
    fn rebindMouseTargets(
        self: *Player,
        ctx: *display.movie_clip.Context,
        dead: *display.display_object.DisplayObject,
    ) void {
        const DO = display.display_object.DisplayObject;
        const inSubtree = struct {
            fn f(root: *DO, needle: *DO) bool {
                if (root == needle) return true;
                for (display.bounds.childrenOf(root)) |child| {
                    if (f(child, needle)) return true;
                }
                if (root.kind == .button) {
                    for (root.kind.button.hit_area.children.items) |child| {
                        if (f(child, needle)) return true;
                    }
                }
                return false;
            }
        }.f;
        for ([_]*?*DO{ &self.hovered, &self.pressed }) |slot| {
            const cur = slot.* orelse continue;
            if (!inSubtree(dead, cur)) continue;
            slot.* = self.findReplacement(&self.root_placement, cur);
            if (slot.*) |fresh| {
                if (fresh.kind == .button and cur.kind == .button) {
                    fresh.kind.button.setState(ctx, fresh, cur.kind.button.state) catch {};
                }
            }
        }
    }

    fn findReplacement(
        self: *Player,
        root: *display.display_object.DisplayObject,
        old: *display.display_object.DisplayObject,
    ) ?*display.display_object.DisplayObject {
        for (display.bounds.childrenOf(root)) |child| {
            if (child.depth == old.depth and child.character_id == old.character_id and
                child.kind != .shape) return child;
            if (self.findReplacement(child, old)) |hit| return hit;
        }
        return null;
    }

    fn severClipObjects(self: *Player, obj: *display.display_object.DisplayObject) void {
        // Buttons and text fields carry their handle on the DisplayObject
        // itself; clips carry theirs on the MovieClip. Both must be cut
        // loose or a retained script reference outlives the memory.
        if (obj.avm_object != 0) self.vm.objects.get(obj.avm_object).native = .removed_display;
        if (obj.kind != .clip) return;
        const mc = obj.kind.clip;
        if (mc.avm_object != 0) self.vm.objects.get(mc.avm_object).native = .removed_display;
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

    fn hostKeyFocus(user: *anyopaque, obj: *display.display_object.DisplayObject) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        return avm1.stage_object.hasKeyFocus(self.vm, obj);
    }

    /// A display object just joined the list. A field gets its broadcaster
    /// object and binds its `variable`; anything else just gives the
    /// parked fields another chance (M4-D7).
    fn hostObjectInstantiated(user: *anyopaque, obj: *display.display_object.DisplayObject) void {
        const self: *Player = @ptrCast(@alignCast(user));
        if (obj.kind == .edit_text) {
            _ = avm1.stage_object.displayObject(self.vm, obj) catch return;
            avm1.text_binding.onFieldCreated(self.vm, obj) catch {};
            return;
        }
        avm1.text_binding.retryUnbound(self.vm) catch {};
    }

    fn hostBoolProperty(
        user: *anyopaque,
        obj: *display.display_object.DisplayObject,
        name: []const u8,
    ) ?bool {
        const self: *Player = @ptrCast(@alignCast(user));
        const handle = switch (obj.kind) {
            .clip => |mc| mc.avm_object,
            else => obj.avm_object,
        };
        if (handle == 0) return null;
        var buf: [24]u16 = undefined;
        for (name, 0..) |c, i| buf[i] = c;
        const v = self.vm.objects.getChained(handle, buf[0..name.len], self.vm.case_sensitive) orelse
            return null;
        if (v == .undefined_value or v == .null_value) return null;
        return avm1.value.toBoolean(v, self.vm.swf_version);
    }

    fn hostLostDisplayObject(user: *anyopaque, obj: *display.display_object.DisplayObject) void {
        const self: *Player = @ptrCast(@alignCast(user));
        avm1.stage_object.dropFocusIf(self.vm, obj) catch {};
        // Fields bound to a variable ON this object go back to waiting
        // rather than pointing at a corpse (ruffle unregister_bindings).
        avm1.text_binding.unregister(self.vm, obj) catch {};
    }

    /// The script-property half of "button mode": does the clip's object
    /// carry any of onPress/onRelease/…? Looked up through the prototype
    /// chain, so a class that defines onRelease makes every instance
    /// pickable (ruffle movie_clip.rs is_button_mode).
    fn hostHasButtonHandler(user: *anyopaque, clip: *display.movie_clip.MovieClip) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        if (clip.avm_object == 0) return false;
        for (display.mouse.BUTTON_EVENT_METHODS) |name| {
            var buf: [24]u16 = undefined;
            for (name, 0..) |c, i| buf[i] = c;
            if (self.vm.objects.hasChained(clip.avm_object, buf[0..name.len], self.vm.case_sensitive)) {
                return true;
            }
        }
        return false;
    }

    /// `obj.enabled`, the AVM1 property. Absent means enabled — only an
    /// explicit false takes a button or clip out of the pick.
    fn hostMouseEnabled(user: *anyopaque, obj: *display.display_object.DisplayObject) bool {
        const self: *Player = @ptrCast(@alignCast(user));
        const handle = switch (obj.kind) {
            .clip => |mc| mc.avm_object,
            else => obj.avm_object,
        };
        if (handle == 0) return true;
        const v = self.vm.objects.getChained(
            handle,
            avm1.strings.ascii("enabled"),
            self.vm.case_sensitive,
        ) orelse return true;
        if (v == .undefined_value or v == .null_value) return true;
        return avm1.value.toBoolean(v, self.vm.swf_version);
    }

    /// `Object.registerClass` maps an ExportAssets SYMBOL to a constructor,
    /// while the display list only knows character ids — so the lookup has
    /// to go back through the export table.
    fn hostRegisteredClass(user: *anyopaque, char_id: u16) u32 {
        const self: *Player = @ptrCast(@alignCast(user));
        if (char_id == 0 or self.vm.class_registry.items.len == 0) return 0;
        var it = self.movie.lib.exports.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != char_id) continue;
            const wide = avm1.strings.fromSwf(self.vm.arena(), e.key_ptr.*, self.movie.swf_version) catch
                return 0;
            if (self.vm.registeredClass(wide)) |ctor| return ctor;
        }
        return 0;
    }

    fn hostRunInline(user: *anyopaque, clip: *MovieClipT, code: []const u8) void {
        const self: *Player = @ptrCast(@alignCast(user));
        const clip_obj = self.clipObject(clip) catch return;
        self.runBytecode(clip_obj, code);
    }

    fn installHost(self: *Player) void {
        self.vm.host = .{
            .ctx = @ptrCast(self),
            .goto_frame = hostGotoFrame,
            .goto_label = hostGotoLabel,
            .set_playing = hostSetPlaying,
            .next_prev = hostNextPrev,
            .focus_roll = hostFocusRoll,
        };
    }

    /// The focus moved, so the hover moves with it. The roll events are
    /// queued like any other, which is why a programmatic `setFocus`
    /// shows them only after the calling script finishes.
    fn hostFocusRoll(ctx: *anyopaque, obj: ?*anyopaque, run_now: bool) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const c = self.cur_ctx orelse return;
        const target: ?*display.display_object.DisplayObject =
            if (obj) |o| @ptrCast(@alignCast(o)) else null;
        const old = self.hovered;
        self.hovered = target;
        if (old) |o| display.mouse.dispatch(c, o, .roll_out) catch {};
        if (target) |t| display.mouse.dispatch(c, t, .roll_over) catch {};
        if (run_now) self.drainActions(c) catch {};
    }

    fn hostGotoFrame(ctx: *anyopaque, clip: *anyopaque, frame: u16, play: bool) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.gotoFrame(frame);
        mc.playing = play;
        self.applyGotoNow(mc);
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
        const target = mc.labelToNumber(buf[0..n]) orelse return false;
        mc.gotoFrame(target);
        mc.playing = play;
        self.applyGotoNow(mc);
        return true;
    }

    /// Replay a pending goto right now, if we are inside a tick.
    fn applyGotoNow(self: *Player, mc: *MovieClipT) void {
        const ctx = self.cur_ctx orelse return;
        mc.applyPendingGoto(ctx) catch {};
    }

    fn hostSetPlaying(ctx: *anyopaque, clip: *anyopaque, playing: bool) void {
        _ = ctx;
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        mc.playing = playing;
    }

    fn hostNextPrev(ctx: *anyopaque, clip: *anyopaque, delta: i2) void {
        const self: *Player = @ptrCast(@alignCast(ctx));
        const mc: *MovieClipT = @ptrCast(@alignCast(clip));
        const cur = mc.current_frame;
        if (delta > 0) {
            mc.gotoFrame(cur + 1);
        } else if (cur > 1) {
            mc.gotoFrame(cur - 1);
        }
        mc.playing = false;
        self.applyGotoNow(mc);
    }

    // --- input seam ---------------------------------------------------------
    //
    // Frontends call these; `core/` never polls anything. Each one updates
    // the VM's input state, re-applies any drag, broadcasts to the clips and
    // then to the Key/Mouse listeners, and drains whatever that queued —
    // input events run script OUTSIDE the frame loop, like timers do.

    pub fn mouseMove(self: *Player, x: f64, y: f64) !void {
        if (self.movie.swf_version < 9) self.resetHighlight();
        const before = [2]f64{ self.vm.mouse_x, self.vm.mouse_y };
        self.setMousePosition(x, y);
        try self.dispatchInput(swf.place.ClipEvent.MOUSE_MOVE, "onMouseMove", self.vm.mouse_object);
        // A move to where the pointer already IS does not count as one:
        // ruffle compares the mapped position with the previous
        // (player.rs:1384), and an unmoved pointer leaves the hover — a
        // Tab may own it — untouched. The broadcast above still fires.
        const moved = self.vm.mouse_x != before[0] or self.vm.mouse_y != before[1];
        // Dragging inside a pressed text field extends its selection.
        if (self.pressed) |p| {
            if (!p.removed) avm1.stage_object.dragSelect(self.vm, p);
        }
        try self.updateMouseState(moved, false);
    }

    /// Re-pick and fire whatever the delta implies. Ruffle's
    /// `update_mouse_state` (player.rs:1523-1850) in the same order: the
    /// roll/drag pair for a changed hover first, then press or release.
    ///
    /// The pick runs on every pointer event AND once per frame, because a
    /// clip can move out from under a stationary pointer.
    /// The player window lost or gained the OS focus. Losing it drops the
    /// AVM1 focus entirely (ruffle `handle_focus_event`); gaining it back
    /// restores nothing.
    pub fn windowFocus(self: *Player, gained: bool) !void {
        if (gained) return;
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        // `reset_focus`, not a plain `set`: the roll events it queues run
        // BEFORE the focus handlers (focus_tracker.rs:95-97).
        try avm1.stage_object.setFocusEx(self.vm, 0, true);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Any left press clears the focus highlight, and below SWF9 so does
    /// every other mouse event (ruffle `should_reset_highlight`).
    fn resetHighlight(self: *Player) void {
        self.vm.focus_highlight = false;
    }

    pub fn updateMouseState(self: *Player, moved: bool, changed_left: bool) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try self.deriveMouseEvents(&ctx, moved, changed_left);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Deliver one event, and forget a DISABLED button afterwards: ruffle
    /// drops it from `hovered`/`pressed` inside `event_dispatch`
    /// (avm1_button.rs:517-524) so that re-enabling it re-fires the roll
    /// from scratch instead of resuming mid-gesture.
    fn sendMouse(
        self: *Player,
        ctx: *display.movie_clip.Context,
        obj: *display.display_object.DisplayObject,
        event: display.mouse.Event,
    ) !void {
        // The check comes FIRST: ruffle reads `enabled` at the top of
        // `event_dispatch`, so a handler that disables the button only
        // takes effect from the NEXT event on.
        const disabled_button = obj.kind == .button and !ctx.mouseEnabled(obj);
        try display.mouse.dispatch(ctx, obj, event);
        if (!disabled_button) return;
        if (self.hovered == obj) self.hovered = null;
        if (self.pressed == obj) self.pressed = null;
    }

    fn deriveMouseEvents(
        self: *Player,
        ctx: *display.movie_clip.Context,
        moved: bool,
        changed_left: bool,
    ) !void {
        const M = display.mouse;
        const DO = display.display_object.DisplayObject;
        const twips = swf.reader.TWIPS_PER_PX;
        const point: [2]i32 = .{
            @intFromFloat(@round(self.vm.mouse_x * twips)),
            @intFromFloat(@round(self.vm.mouse_y * twips)),
        };
        const new_over = M.pick(ctx, &self.root_placement, .identity, point);
        const left_down = (self.vm.mouse_buttons & 1) != 0;

        // Ruffle COLLECTS the events first, updates hovered/pressed, and
        // only then fires them (player.rs:1547 `events`) — the order
        // matters because a handler can invalidate the very state that
        // produced it.
        var events: [6]struct { obj: *DO, ev: M.Event } = undefined;
        var n: usize = 0;

        // An object that has been removed stops being hovered or pressed.
        if (self.hovered) |h| {
            if (h.removed) self.hovered = null;
        }
        if (self.pressed) |p| {
            if (p.removed) self.pressed = null;
        }

        // Nothing moved, no button changed, and something is already
        // hovered: leave it alone. Tab sets the hover too, and an idle
        // pick must not roll straight back out of it (ruffle
        // player.rs:1538 `skip_mouse_hover`). An object that has gone
        // INVISIBLE is the exception — that hover is cancelled even when
        // the pointer never moved.
        var skip_hover = !moved and !changed_left and self.hovered != null;
        if (self.hovered) |h| {
            if (!h.visible) skip_hover = false;
        }

        const cur_over = self.hovered;
        if (!skip_hover and cur_over != new_over) {
            if (left_down) {
                // Dragging: only the DRAG pair fires, and not at all while
                // an AVM1 `startDrag` is in progress.
                if (self.vm.drag == null) {
                    if (self.pressed) |down| {
                        if (cur_over == down) {
                            events[n] = .{ .obj = down, .ev = .drag_out };
                            n += 1;
                        } else if (new_over == down) {
                            events[n] = .{ .obj = down, .ev = .drag_over };
                            n += 1;
                        }
                    }
                    if (cur_over) |c| {
                        if (self.pressed != c) {
                            events[n] = .{ .obj = c, .ev = .drag_out };
                            n += 1;
                        }
                    }
                    if (new_over) |o| {
                        if (self.pressed != o) {
                            events[n] = .{ .obj = o, .ev = .drag_over };
                            n += 1;
                        }
                    }
                }
            } else {
                if (cur_over) |c| {
                    events[n] = .{ .obj = c, .ev = .roll_out };
                    n += 1;
                }
                if (new_over) |o| {
                    events[n] = .{ .obj = o, .ev = .roll_over };
                    n += 1;
                }
            }
        }
        if (!skip_hover) self.hovered = new_over;

        if (changed_left) {
            if (left_down) {
                if (self.hovered) |over| {
                    events[n] = .{ .obj = over, .ev = .press };
                    n += 1;
                    self.pressed = over;
                } else {
                    // A press on NOTHING still moves the focus: it goes
                    // to the stage, which cannot hold it, so a focused
                    // text field loses it.
                    try avm1.stage_object.focusByMousePress(self.vm, null);
                }
            } else {
                const down = self.pressed;
                self.pressed = null;
                if (down) |d| {
                    if (d == self.hovered) {
                        events[n] = .{ .obj = d, .ev = .release };
                        n += 1;
                    } else {
                        events[n] = .{ .obj = d, .ev = .release_outside };
                        n += 1;
                        // Whatever is under the pointer NOW is rolled over
                        // immediately (ruffle player.rs:1835-1845).
                        if (self.hovered) |over| {
                            events[n] = .{ .obj = over, .ev = .roll_over };
                            n += 1;
                        }
                    }
                }
            }
        }

        for (events[0..n]) |e| {
            try self.sendMouse(ctx, e.obj, e.ev);
            // A PRESS moves the focus: onto the pressed object if it can
            // take focus by mouse, off whatever had it otherwise (ruffle
            // `update_focus_on_mouse_press`, fired per press event).
            if (e.ev == .press and !e.obj.removed) {
                try avm1.stage_object.focusByMousePress(self.vm, e.obj);
            }
        }
    }


    /// Move the pointer WITHOUT raising a move event. A button event
    /// carries a position too, and delivering it as a move as well would
    /// double every `onMouseMove` handler.
    pub fn setMousePosition(self: *Player, x_view: f64, y_view: f64) void {
        // The caller speaks VIEWPORT pixels; the stage may be scaled or
        // letterboxed inside it.
        const p = avm1.stage_object.viewportToStage(self.vm, x_view, y_view);
        self.vm.mouse_x = p[0];
        self.vm.mouse_y = p[1];
        avm1.stage_object.applyDrag(self.vm);
    }

    pub fn mouseButton(self: *Player, button: u8, down: bool) !void {
        if (button == 0 and down) {
            self.resetHighlight();
        } else if (self.movie.swf_version < 9 and button != 1) {
            self.resetHighlight();
        }
        const bit = @as(u8, 1) << @intCast(@min(button, 7));
        if (down) {
            self.vm.mouse_buttons |= bit;
        } else {
            self.vm.mouse_buttons &= ~bit;
        }
        // Every mouse button is also a KEY as far as `Key` is concerned:
        // left is 1, right 2, middle 4. They participate in the toggle
        // state too — corpus key_isToggled reads `Key.isToggled(1)`
        // between clicks, and mouse_events_visible_enabled asks
        // `Key.isDown(4)` for the middle one.
        const key: usize = switch (button) {
            0 => 1,
            1 => 4,
            2 => 2,
            else => 0,
        };
        if (key != 0) {
            if (down and !self.vm.keys_down[key]) self.vm.keys_toggled[key] = !self.vm.keys_toggled[key];
            self.vm.keys_down[key] = down;
        }
        // Only the PRIMARY button drives the press/release machine; AVM1
        // has no handler for the other two (ruffle's MiddlePress and
        // RightPress arms are AVM2-only).
        if (button != 0) return;
        if (down) {
            try self.dispatchInput(swf.place.ClipEvent.MOUSE_DOWN, "onMouseDown", self.vm.mouse_object);
        } else {
            try self.dispatchInput(swf.place.ClipEvent.MOUSE_UP, "onMouseUp", self.vm.mouse_object);
        }
        try self.updateMouseState(false, true);
    }

    /// Seed the clipboard the way a host paste-buffer would.
    pub fn setClipboard(self: *Player, utf8: []const u8) !void {
        self.clipboard.clearRetainingCapacity();
        const needed = std.unicode.calcUtf16LeLen(utf8) catch return;
        try self.clipboard.resize(self.gpa, needed);
        _ = std.unicode.utf8ToUtf16Le(self.clipboard.items, utf8) catch {
            self.clipboard.clearRetainingCapacity();
        };
    }

    /// Text typed by the user. This is also where printable ASCII raises
    /// its button `keyPress`, and a handler that CLAIMS the key stops the
    /// character reaching the focused field.
    pub fn textInput(self: *Player, typed: []const u16) !void {
        for (typed) |cp| try self.textInputOne(cp);
    }

    fn textInputOne(self: *Player, cp: u16) !void {
        var handled = false;
        if (display.button.buttonKeyFromChar(cp)) |bk| handled = try self.dispatchKeyPress(bk);
        if (handled) return;
        // Space activates the highlighted focus, and it does so from the
        // TEXT INPUT rather than the key-down (ruffle player.rs:1348).
        if (cp == ' ') try self.activateFocus();

        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        const changed = try t.obj.kind.edit_text.textInput(self.gpa, &.{cp});
        if (changed) try self.afterFieldEdit(t.obj);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// An IME preedit update for the focused field. An empty string ends
    /// the composition.
    pub fn imePreedit(self: *Player, preedit: []const u16, cursor: ?[2]usize) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        try t.obj.kind.edit_text.imePreedit(self.gpa, preedit, cursor);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// One editing command (arrow keys, backspace, cut/paste …).
    pub fn textControl(self: *Player, code: display.edit_text.Control) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const t = self.focusedFieldTarget() orelse return;
        const changed = try t.obj.kind.edit_text.textControl(self.gpa, code, &self.clipboard);
        if (changed) try self.afterFieldEdit(t.obj);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    fn focusedFieldTarget(self: *Player) ?avm1.stage_object.Target {
        if (self.vm.focus == 0) return null;
        const t = avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse return null;
        if (t.obj.kind != .edit_text) return null;
        return t;
    }

    /// An edit made by the USER pushes the variable binding and then
    /// broadcasts `onChanged` from the field itself.
    fn afterFieldEdit(self: *Player, obj: *display.display_object.DisplayObject) !void {
        try avm1.text_binding.propagate(self.vm, obj);
        const h = try avm1.stage_object.handleOf(self.vm, obj);
        _ = avm1.singletons.broadcast(
            self.vm,
            .{ .object = h },
            avm1.strings.ascii("onChanged"),
            &.{.{ .object = h }},
        ) catch {};
    }

    /// `code` is a Flash key code (the Windows virtual-key numbering);
    /// `char` is the ASCII/UTF-16 code unit `Key.getAscii` reports, or 0.
    pub fn keyDown(self: *Player, code: i32, char: i32) !void {
        if (code >= 0 and code < 256) {
            const i: usize = @intCast(code);
            // Toggle keys flip on the PRESS, and only on a fresh press —
            // auto-repeat must not flicker Caps Lock back off.
            if (!self.vm.keys_down[i]) self.vm.keys_toggled[i] = !self.vm.keys_toggled[i];
            self.vm.keys_down[i] = true;
        }
        self.vm.last_key_code = code;
        self.vm.last_key_char = char;
        try self.dispatchInput(swf.place.ClipEvent.KEY_DOWN, "onKeyDown", self.vm.key_object);
        // keyPress comes after keyDown, always (ruffle player.rs:1302).
        var handled = false;
        if (display.button.buttonKeyFromKeyCode(code)) |bk| handled = try self.dispatchKeyPress(bk);
        // Tab cycles the focus — but only when no keyPress claimed the
        // key first (ruffle player.rs:1328-1340).
        if (!handled and code == 9) {
            try self.cycleFocus(self.vm.keys_down[16]);
        } else if (!handled and code == 13) {
            try self.activateFocus();
        }
        try self.updateMouseState(false, false);
    }

    /// Enter or Space on a highlighted focused object presses AND
    /// releases it, without waiting for the key to come up (ruffle
    /// player.rs:1340-1357).
    fn activateFocus(self: *Player) !void {
        if (!avm1.stage_object.highlightVisible(self.vm)) return;
        const t = avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse return;
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try display.mouse.dispatch(&ctx, t.obj, .press);
        try display.mouse.dispatch(&ctx, t.obj, .release);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    /// Move the focus to the next (or previous) tabbable object. Ruffle's
    /// `set_by_key` path: the roll events fire SYNCHRONOUSLY here, unlike
    /// a programmatic `Selection.setFocus`, and the actions they queue are
    /// drained before the focus itself moves (focus_tracker.rs:144-157).
    fn cycleFocus(self: *Player, reverse: bool) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        var order = try display.tab.build(&ctx, &self.root_placement, self.gpa);
        defer order.deinit(self.gpa);
        const current = if (self.vm.focus != 0)
            (avm1.stage_object.targetOf(self.vm, self.vm.focus) orelse null)
        else
            null;
        const cur_obj: ?*display.display_object.DisplayObject =
            if (current) |t| t.obj else null;
        const target = display.tab.next(&order, cur_obj, reverse) orelse return;

        // `setFocus` moves the hover and queues the roll events; a KEY
        // move runs them before the focus handlers, unlike a programmatic
        // one (focus_tracker.rs:150-157).
        const handle = try avm1.stage_object.handleOf(self.vm, target);
        try avm1.stage_object.setFocusEx(self.vm, handle, true);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
    }

    fn dispatchKeyPress(self: *Player, code: u8) !bool {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        const handled = try self.root.broadcastKeyPress(&ctx, code);
        try self.drainActions(&ctx);
        self.retireDead(&ctx);
        return handled;
    }

    pub fn keyUp(self: *Player, code: i32, char: i32) !void {
        if (code >= 0 and code < 256) self.vm.keys_down[@intCast(code)] = false;
        self.vm.last_key_code = code;
        self.vm.last_key_char = char;
        try self.dispatchInput(swf.place.ClipEvent.KEY_UP, "onKeyUp", self.vm.key_object);
        try self.updateMouseState(false, false);
    }

    fn dispatchInput(
        self: *Player,
        flag: u32,
        comptime method: []const u8,
        listener_target: avm1.runtime.ObjectHandle,
    ) !void {
        var ctx = self.makeContext();
        defer ctx.deinit(self.gpa);
        self.cur_ctx = &ctx;
        self.vm.display_ctx = @ptrCast(&ctx);
        defer {
            self.cur_ctx = null;
            self.vm.display_ctx = null;
        }
        try self.root.broadcastClipEvent(&ctx, flag, method);
        try self.drainActions(&ctx);
        // The Key/Mouse listener lists come AFTER the clips.
        if (listener_target != 0) {
            _ = avm1.singletons.broadcast(
                self.vm,
                .{ .object = listener_target },
                avm1.strings.ascii(method),
                &.{},
            ) catch {};
            try self.drainActions(&ctx);
        }
        self.retireDead(&ctx);
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
        self.renderer.focused_field = blk: {
            const t = self.focusedFieldTarget() orelse break :blk null;
            break :blk t.obj.kind.edit_text;
        };
        self.renderer.now_ms = self.elapsed_ms;
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
    _ = @import("display/button.zig");
    _ = @import("display/mouse.zig");
    _ = @import("display/tab.zig");
    _ = @import("display/text.zig");
    _ = @import("display/edit_text.zig");
    _ = @import("display/font.zig");
    _ = @import("display/device_font.zig");
    _ = @import("display/text_layout.zig");
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
    _ = @import("avm1/timers.zig");
    _ = @import("avm1/globals/decl.zig");
    _ = @import("avm1/globals/geom.zig");
    _ = @import("avm1/globals/date.zig");
    _ = @import("avm1/globals/singletons.zig");
    _ = @import("avm1/globals/selection.zig");
    _ = @import("avm1/globals/text_format.zig");
    _ = @import("avm1/globals/text_snapshot.zig");
    _ = @import("avm1/globals/text_field.zig");
    _ = @import("avm1/globals/style_sheet.zig");
    _ = @import("avm1/globals/filters.zig");
    _ = @import("avm1/globals/bitmap_data.zig");
    _ = @import("avm1/text_binding.zig");
    _ = @import("bitmap/pixels.zig");
    _ = @import("bitmap/data.zig");
    _ = @import("bitmap/operations.zig");
    _ = @import("bitmap/decode.zig");
    _ = @import("text/format.zig");
    _ = @import("text/spans.zig");
    _ = @import("text/html.zig");
    _ = @import("avm1/globals/movie_clip.zig");
    _ = @import("avm1/globals/globals.zig");
}
