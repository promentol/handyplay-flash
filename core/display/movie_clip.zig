//! MovieClip — a timeline instance (the root movie or a DefineSprite).
//! Ports Ruffle's semantics (core/src/display_object/movie_clip.rs):
//!
//!   • run_frame: advance when playing; past-the-end loops to frame 1
//!     (implicit loop); single-frame clips implicitly stop.
//!   • Control tags execute in stream order; DoAction is scanned for the
//!     SWF3 timeline actions ONLY in M2 (Play/Stop/GotoFrame/GotoLabel/
//!     NextFrame/PrevFrame) — the queued full interpreter arrives in M3.
//!   • goto: correctness-first replay (Ruffle's delta-aggregation is an
//!     optimization) — rewind clears children and re-runs place/remove for
//!     frames 1..target with actions suppressed.
//!   • New child clips execute their first frame on the tick they are
//!     placed.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const library = @import("library.zig");
const display_object = @import("display_object.zig");
const drawing_mod = @import("drawing.zig");
const button_mod = @import("button.zig");
const edit_text_mod = @import("edit_text.zig");
const bitmap_decode = @import("../bitmap/decode.zig");
const bitmap_data_mod = @import("../bitmap/data.zig");

const DisplayObject = display_object.DisplayObject;

pub const Error = std.mem.Allocator.Error;

/// Shared per-tick context threaded through the tree walk.
pub const Context = struct {
    gpa: std.mem.Allocator,
    movie: *const swf.movie.Movie,
    /// Set by SetBackgroundColor during execution.
    background_color: ?swf.reader.Color = null,
    /// Actions queued this tick, drained by the Player AFTER every clip has
    /// run (Ruffle's ActionQueue). THREE FIFO buckets, not one sorted list:
    /// each pop takes the front of the highest non-empty bucket, so an
    /// Initialize queued while a Normal action is running still overtakes
    /// the Normal actions behind it.
    queues: [3]std.ArrayList(QueuedAction) = @splat(.empty),
    heads: [3]usize = @splat(0),
    /// Children removed this tick, NOT yet freed. The action queue holds
    /// raw `*MovieClip`s and AVM1 objects hold them via `native.clip`, so
    /// freeing at removal time is a use-after-free: a queued script that
    /// calls `gotoAndStop` can destroy a clip whose own DoAction is still
    /// sitting in the queue. Removal marks the subtree `removed` (scripts
    /// then see undefined, as in ruffle's avm1_removed) and defers the
    /// free to the end of the tick.
    graveyard: std.ArrayList(*DisplayObject) = .empty,
    /// Flash's `instanceN` counter, owned by the Player so it survives
    /// across ticks (ruffle's UpdateContext.instance_counter). Every
    /// unnamed display object consumes one at placement.
    instance_counter: *u32,
    /// `Object.registerClass` lookup: character id -> constructor handle
    /// (0 = none). The Player supplies it; display code cannot see the VM,
    /// and pure-display tests leave it null.
    class_lookup: ?*const fn (user: *anyopaque, char_id: u16) u32 = null,
    class_lookup_user: ?*anyopaque = null,

    /// Run bytecode RIGHT NOW with `clip` as the base clip. Only
    /// DoInitAction uses this; everything else goes through the queue.
    run_inline: ?*const fn (user: *anyopaque, clip: *MovieClip, code: []const u8) void = null,

    /// Does this object hold the keyboard focus? A key event's SCRIPT
    /// handler only runs for the focused object (ruffle
    /// `should_fire_event_handlers`); its `onClipEvent` bodies run either
    /// way.
    key_focus: ?*const fn (user: *anyopaque, obj: *DisplayObject) bool = null,

    /// Read an AVM1 BOOLEAN property off the object's script object.
    /// Null when it is absent (undefined/null), which is what lets the
    /// caller apply the per-kind default (ruffle
    /// `get_avm1_boolean_property`).
    bool_property: ?*const fn (user: *anyopaque, obj: *DisplayObject, name: []const u8) ?bool = null,

    /// The object is leaving the display list: if it had focus, drop it
    /// (ruffle display_object.rs:1896 set_parent -> drop_focus).
    lost_display_object: ?*const fn (user: *anyopaque, obj: *DisplayObject) void = null,

    /// Does this clip's SCRIPT OBJECT carry any of onPress/onRelease/…?
    /// The `onClipEvent` half of "button mode" is answered in
    /// display/mouse.zig; this half needs the VM.
    has_button_handler: ?*const fn (user: *anyopaque, clip: *MovieClip) bool = null,
    /// `obj.enabled` — a disabled button or clip is not pickable and gets
    /// no events (ruffle InteractiveObject::mouse_enabled).
    mouse_enabled: ?*const fn (user: *anyopaque, obj: *DisplayObject) bool = null,

    /// An object has just joined the display list. A text field binds its
    /// `variable` here and becomes an AsBroadcaster; a CLIP matters too,
    /// because a field parked on the unbound list may have been waiting
    /// for exactly this timeline to exist (ruffle calls `bind_variables`
    /// from both post_instantiations). Null in pure-display tests.
    object_instantiated: ?*const fn (user: *anyopaque, obj: *DisplayObject) void = null,

    pub fn keyFocused(self: *Context, obj: *DisplayObject) bool {
        const f = self.key_focus orelse return false;
        return f(self.class_lookup_user.?, obj);
    }

    pub fn boolProperty(self: *Context, obj: *DisplayObject, name: []const u8) ?bool {
        const f = self.bool_property orelse return null;
        return f(self.class_lookup_user.?, obj, name);
    }

    pub fn lostDisplayObject(self: *Context, obj: *DisplayObject) void {
        const f = self.lost_display_object orelse return;
        f(self.class_lookup_user.?, obj);
    }

    pub fn clipHasButtonHandler(self: *Context, clip: *MovieClip) bool {
        const f = self.has_button_handler orelse return false;
        return f(self.class_lookup_user.?, clip);
    }

    pub fn mouseEnabled(self: *Context, obj: *DisplayObject) bool {
        const f = self.mouse_enabled orelse return true;
        return f(self.class_lookup_user.?, obj);
    }

    pub fn registeredClass(self: *Context, char_id: u16) u32 {
        const f = self.class_lookup orelse return 0;
        return f(self.class_lookup_user.?, char_id);
    }

    pub fn runInline(self: *Context, clip: *MovieClip, code: []const u8) void {
        const f = self.run_inline orelse return;
        f(self.class_lookup_user.?, clip, code);
    }

    pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
        self.drainGraveyard(gpa);
        self.graveyard.deinit(gpa);
        for (&self.queues) |*q| q.deinit(gpa);
    }

    pub fn queue(self: *Context, gpa: std.mem.Allocator, a: QueuedAction) Error!void {
        try self.queues[@intFromEnum(a.priority)].append(gpa, a);
    }

    pub fn popAction(self: *Context) ?QueuedAction {
        for (&self.queues, &self.heads) |*q, *h| {
            if (h.* < q.items.len) {
                defer h.* += 1;
                return q.items[h.*];
            }
        }
        return null;
    }

    pub fn drainGraveyard(self: *Context, gpa: std.mem.Allocator) void {
        for (self.graveyard.items) |obj| {
            obj.deinit(gpa);
            gpa.destroy(obj);
        }
        self.graveyard.clearRetainingCapacity();
    }
};

/// Ruffle's ActionPriority, in drain order (context.rs:670-676).
pub const Priority = enum(u2) { initialize = 0, construct = 1, normal = 2 };

pub const QueuedAction = struct {
    clip: *MovieClip,
    /// A BUTTON's script handler runs on the button's own object, not on
    /// any timeline — `clip` then only says which clip's removal cancels
    /// it. Null for everything else.
    display: ?*DisplayObject = null,
    priority: Priority = .normal,
    /// `unload` handlers run even though their clip is already gone —
    /// that is the whole point of them. Every other entry is dropped when
    /// its clip is removed before the drain reaches it.
    on_removed: bool = false,
    what: union(enum) {
        /// A DoAction / ClipAction bytecode slice.
        code: []const u8,
        /// A handler the SCRIPT installed, e.g. `clip.onEnterFrame = f`.
        /// Queued AFTER the SWF-defined handlers for the same event
        /// (ruffle movie_clip.rs:2956-2970).
        method: []const u8,
        /// A timeline-placed clip being given its registered class: re-point
        /// `__proto__`, run the `onClipEvent(construct)` bodies, then invoke
        /// the constructor. `ctor` is 0 when nothing is registered, in which
        /// case only the event bodies run.
        construct: struct { ctor: u32, events: []const []const u8 },
    },
};

pub const MovieClip = struct {
    /// Preloaded frames (root movie or sprite character).
    frames: []const library.Frame,
    /// 1-based; 0 = nothing executed yet.
    current_frame: u16 = 0,
    playing: bool = true,
    initialized: bool = false,
    /// Depth-sorted children.
    children: std.ArrayList(*DisplayObject) = .empty,
    /// Goto target awaiting replay. Set by gotoFrame and applied by
    /// applyPendingGoto — which the Player now calls IMMEDIATELY from the
    /// host hook, so a script observes its own goto's effects (ruffle
    /// executes goto_frame synchronously). It stays a two-step so replay
    /// never recurses inside executeFrame's own control loop.
    pending_goto: ?u16 = null,
    /// Lazily-created AVM1 object handle for this clip (0 = none yet).
    avm_object: u32 = 0,
    /// True between "placed this tick" and the end of that tick: a clip
    /// runs its first frame on placement, so the parent's child-tick loop
    /// must skip it (otherwise it advances twice in one tick).
    ran_this_tick: bool = false,
    /// The DisplayObject that placed this clip. Null only for the root,
    /// whose placement the Player owns. `matrix`/`color_transform`/`name`
    /// live there, not here, so every display property goes through it.
    placement: ?*DisplayObject = null,
    parent: ?*MovieClip = null,
    /// Off the display list but possibly still referenced by AVM1 (ruffle
    /// avm1_removed): property reads must yield undefined, not garbage.
    removed: bool = false,
    /// Script drawing-API geometry, created on the first draw call. Most
    /// clips never draw, so this stays null and costs a pointer.
    drawing: ?drawing_mod.Drawing = null,
    /// Bytes in this clip's own DefineSprite tag stream — `getBytesTotal`
    /// for anything that is not the root. 0 for the root (which reports the
    /// movie's file length instead) and for an empty scripted clip.
    tag_stream_len: usize = 0,
    /// `_lockroot`: when set, `_root` inside this clip resolves to the clip
    /// itself rather than the main timeline.
    lock_root: bool = false,
    /// Set when this clip is one of a BUTTON's child containers. It is not
    /// scriptable in its own right: every request for its AVM1 object
    /// yields the button's, so `_parent` from inside a button is the
    /// button (avm1/stage_object.zig clipObject).
    owner_button: ?*DisplayObject = null,

    pub fn init(frames: []const library.Frame) MovieClip {
        return .{ .frames = frames };
    }

    pub fn deinit(self: *MovieClip, gpa: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(gpa);
            gpa.destroy(child);
        }
        self.children.deinit(gpa);
        if (self.drawing) |*d| d.deinit();
    }

    /// The drawing, created empty on first use.
    pub fn drawingMut(self: *MovieClip, gpa: std.mem.Allocator) *drawing_mod.Drawing {
        if (self.drawing == null) self.drawing = drawing_mod.Drawing.init(gpa);
        return &self.drawing.?;
    }

    /// A clip with no timeline at all still reports ONE frame: ruffle
    /// builds `createEmptyMovieClip`'s shared data with `header_frames = 1`
    /// (movie_clip.rs MovieClipShared::empty), so `_totalframes` and
    /// `_framesloaded` read 1 while `_currentframe` stays 0.
    pub fn totalFrames(self: *const MovieClip) u16 {
        return @intCast(@max(self.frames.len, 1));
    }

    pub fn labelToNumber(self: *const MovieClip, name: []const u8) ?u16 {
        for (self.frames, 0..) |f, i| {
            const label = f.label orelse continue;
            if (std.ascii.eqlIgnoreCase(label, name)) return @intCast(i + 1);
        }
        return null;
    }

    /// One tick: advance this clip (when playing), then tick children.
    pub fn runFrame(self: *MovieClip, ctx: *Context) Error!void {
        // The FIRST tick fires load instead of enterFrame; every later one
        // fires enterFrame (ruffle run_frame_avm1:449-459).
        if (!self.initialized) {
            self.initialized = true;
            try self.dispatchClipEvent(ctx, swf.place.ClipEvent.LOAD, "onLoad");
        } else {
            try self.dispatchClipEvent(ctx, swf.place.ClipEvent.ENTER_FRAME, "onEnterFrame");
        }
        // A frameless clip (createEmptyMovieClip) has nothing to advance
        // to and stays on frame 0 forever.
        if (self.frames.len > 0 and (self.playing or self.current_frame == 0)) {
            const next = self.determineNextFrame();
            if (next < self.current_frame) {
                // Looping past the last frame is a GOTO, not a bare replay
                // of frame 1 (ruffle determine_next_frame -> First ->
                // run_goto(1)). Without the rewind, frame 1's places land
                // on depths the later frames still occupy and are refused,
                // so the second lap silently loses clips.
                try self.runGoto(ctx, next);
            } else if (next != self.current_frame or self.current_frame == 0) {
                try self.executeFrame(ctx, @max(next, 1), true);
                self.current_frame = @max(next, 1);
            }
        }
        // Tick child clips (M3 replaces this tree walk with the global
        // instantiation-order exec list). Clips placed during THIS tick
        // already ran their first frame in `instantiate`.
        try self.tickChildren(ctx);
    }

    /// Advance every child timeline. A button is not a timeline itself but
    /// its state children are, so it forwards the tick — an animated clip
    /// inside a button keeps playing (corpus button_order).
    pub fn tickChildren(self: *MovieClip, ctx: *Context) Error!void {
        // HIGHEST DEPTH FIRST. Ruffle does not walk the tree at all here:
        // it iterates one global list that new clips are PREPENDED to
        // (avm1/runtime.rs add_to_exec_list), so siblings tick in reverse
        // instantiation order — which for timeline placements is reverse
        // depth (corpus button_order, clip_event_propagation_order).
        var i = self.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = self.children.items[i];
            switch (child.kind) {
                .clip => |mc| {
                    // Placed this tick: it already ran its first frame.
                    if (mc.ran_this_tick) continue;
                    try mc.runFrame(ctx);
                },
                .button => |b| try b.container.tickChildren(ctx),
                else => {},
            }
        }
    }

    /// A global input event: every clip in the subtree gets it, wherever it
    /// is on screen — that is what makes AVM1's `onClipEvent(keyDown)` fire
    /// on clips the pointer is nowhere near.
    ///
    /// Order is children before parent, and among children HIGHEST DEPTH
    /// FIRST (corpus clip_event_propagation_order traces depth30, depth20,
    /// depth10, then Main).
    pub fn broadcastClipEvent(self: *MovieClip, ctx: *Context, flag: u32, comptime method: []const u8) Error!void {
        var i = self.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = self.children.items[i];
            switch (child.kind) {
                .clip => |mc| try mc.broadcastClipEvent(ctx, flag, method),
                // A button forwards the broadcast to its CHILDREN but is
                // not itself a listener: `btn.onKeyDown` only fires when
                // the button has focus (ruffle
                // Avm1Button::should_fire_event_handlers).
                .button => |b| {
                    var j = b.container.children.items.len;
                    while (j > 0) {
                        j -= 1;
                        const inner = b.container.children.items[j];
                        if (inner.kind == .clip) try inner.kind.clip.broadcastClipEvent(ctx, flag, method);
                    }
                    // …and the button itself hears key events only while
                    // it holds the focus.
                    if (isKeyFlag(flag) and ctx.keyFocused(child)) {
                        try ctx.queue(ctx.gpa, .{
                            .clip = child.parent orelse self,
                            .display = child,
                            .what = .{ .method = method },
                        });
                    }
                },
                else => {},
            }
        }
        try self.dispatchClipEvent(ctx, flag, method);
    }

    /// A key press walks the whole tree like any other clip event, but it
    /// is matched by KEY CODE and CONSUMED by the first handler: a button
    /// runs the cond actions naming this key, a clip the
    /// `onClipEvent(keyPress "x")` bodies that do. Unlike mouse events it
    /// travels in RENDER LIST order — low depth to high — and children
    /// still go before their parent (ruffle interactive.rs:233-258).
    /// Fired AFTER the keyDown broadcast (player.rs:1302-1309).
    pub fn broadcastKeyPress(self: *MovieClip, ctx: *Context, code: u8) Error!bool {
        for (self.children.items) |child| {
            if (try keyPressTo(ctx, child, code)) return true;
        }
        return self.dispatchKeyPress(ctx, code);
    }

    /// Offer a key press to one display object, whatever kind it is.
    pub fn keyPressTo(ctx: *Context, obj: *DisplayObject, code: u8) Error!bool {
        return switch (obj.kind) {
            .clip => |mc| try mc.broadcastKeyPress(ctx, code),
            .button => |b| try b.keyPress(ctx, obj, code),
            else => false,
        };
    }

    fn dispatchKeyPress(self: *MovieClip, ctx: *Context, code: u8) Error!bool {
        if (ctx.movie.swf_version < 5) return false;
        const p = self.placement orelse return false;
        var any = false;
        for (p.clip_actions) |handler| {
            if (handler.events & swf.place.ClipEvent.KEY_PRESS == 0) continue;
            const want = handler.key_code orelse continue;
            if (want != code) continue;
            any = true;
            try ctx.queue(ctx.gpa, .{ .clip = self, .what = .{ .code = handler.actions } });
        }
        return any;
    }

    /// Clear the "already ticked" marks for the whole subtree. This must
    /// happen at END of tick: a clip created DURING the action drain sets
    /// the flag after its parent's child loop has already run, so letting
    /// the next tick's loop consume it would swallow that clip's first
    /// enterFrame entirely.
    pub fn clearRanThisTick(self: *MovieClip) void {
        self.ran_this_tick = false;
        for (self.children.items) |child| {
            switch (child.kind) {
                .clip => |mc| mc.clearRanThisTick(),
                .button => |b| b.container.clearRanThisTick(),
                else => {},
            }
        }
    }

    /// Queue this clip's handlers for one event: the SWF-defined
    /// `onClipEvent(...)` bodies first, then the script-assigned method.
    /// Both are QUEUED, never run inline. SWF5+ only.
    fn dispatchClipEvent(self: *MovieClip, ctx: *Context, flag: u32, comptime method: []const u8) Error!void {
        try self.dispatchClipEventEx(ctx, flag, method, false);
    }

    fn dispatchClipEventEx(
        self: *MovieClip,
        ctx: *Context,
        flag: u32,
        comptime method: []const u8,
        on_removed: bool,
    ) Error!void {
        if (ctx.movie.swf_version < 5) return;
        if (self.placement) |p| {
            for (p.clip_actions) |handler| {
                if (handler.events & flag != 0) {
                    try ctx.queue(ctx.gpa, .{
                        .clip = self,
                        .on_removed = on_removed,
                        .what = .{ .code = handler.actions },
                    });
                }
            }
        }
        // A key event's script handler is for the FOCUSED object only.
        if (isKeyFlag(flag) and !(self.placement != null and ctx.keyFocused(self.placement.?))) {
            return;
        }
        try ctx.queue(ctx.gpa, .{
            .clip = self,
            .on_removed = on_removed,
            .what = .{ .method = method },
        });
    }

    fn isKeyFlag(flag: u32) bool {
        return flag == swf.place.ClipEvent.KEY_DOWN or flag == swf.place.ClipEvent.KEY_UP;
    }

    /// The `onClipEvent(press)` bodies plus the script handler, for one
    /// mouse event. Same shape as `dispatchClipEvent`, but the event enum
    /// lives in mouse.zig and carries its own method name.
    pub fn dispatchMouseEvent(self: *MovieClip, ctx: *Context, event: @import("mouse.zig").Event) Error!void {
        if (ctx.movie.swf_version < 5) return;
        const flag = event.flag();
        if (self.placement) |p| {
            for (p.clip_actions) |handler| {
                if (handler.events & flag != 0) {
                    try ctx.queue(ctx.gpa, .{ .clip = self, .what = .{ .code = handler.actions } });
                }
            }
        }
        try ctx.queue(ctx.gpa, .{ .clip = self, .what = .{ .method = event.method() } });
    }

    /// Ruffle determine_next_frame: Same (implicit stop) when there is
    /// nowhere to go; First (loop) past the end.
    fn determineNextFrame(self: *const MovieClip) u16 {
        if (self.frames.len == 0) return 0;
        if (self.current_frame == 0) return 1;
        if (self.current_frame < self.frames.len) return self.current_frame + 1;
        if (self.frames.len > 1) return 1; // loop
        return self.current_frame; // single frame: implicit stop
    }

    fn executeFrame(self: *MovieClip, ctx: *Context, frame_num: u16, run_actions: bool) Error!void {
        if (frame_num == 0 or frame_num > self.frames.len) return;
        const frame = self.frames[frame_num - 1];
        for (frame.controls) |control| switch (control) {
            .place => |po| try self.placeObject(ctx, po, frame_num),
            .remove => |ro| try self.removeAtDepth(ctx, ro.depth),
            .set_background_color => |c| ctx.background_color = c,
            .do_action => |bytecode| if (run_actions) {
                try ctx.queue(ctx.gpa, .{ .clip = self, .what = .{ .code = bytecode } });
            },
            // `#initclip` does NOT run here. Ruffle handles DoInitAction in
            // PRELOAD (movie_clip.rs:556, inside `preload`, not
            // `run_frame_internal`), so every init action in the movie has
            // already executed before frame 1 places anything. That is what
            // lets `Object.registerClass` in an initclip apply to clips
            // whose PlaceObject tag appears EARLIER in the same frame —
            // corpus register_and_init_order and on_construct both depend
            // on it. `Player.runInitActions` does the pass.
            .init_action => {},
            .start_sound, .sound_stream_block => {}, // M6
        };
    }

    /// Record a goto target for applyPendingGoto (public: the host seam
    /// and later the interpreter use it for gotoAndPlay/Stop).
    /// Only the LOWER bound is clamped. A goto past the last frame is not
    /// an error and not a clamp: ruffle's `goto_frame` does `frame.max(1)`
    /// and nothing else, so `run_goto` walks off the end of the tag stream
    /// and the destination's actions simply never run (corpus goto_frame's
    /// `gotoAndStop(999)` prints nothing for frame 6).
    pub fn gotoFrame(self: *MovieClip, target: u16) void {
        self.pending_goto = @max(target, 1);
    }

    /// Apply a pending goto: rewind + replay with actions suppressed
    /// (gotoAndStop(n) shows frame n but frame n's actions don't run —
    /// Ruffle run_goto comment).
    pub fn applyPendingGoto(self: *MovieClip, ctx: *Context) Error!void {
        const target = self.pending_goto orelse {
            for (self.children.items) |child| {
                if (child.kind == .clip) try child.kind.clip.applyPendingGoto(ctx);
            }
            return;
        };
        self.pending_goto = null;
        if (target == self.current_frame) {
            // A no-op goto on THIS clip must still let children apply theirs.
            for (self.children.items) |child| {
                if (child.kind == .clip) try child.kind.clip.applyPendingGoto(ctx);
            }
            return;
        }
        try self.runGoto(ctx, target);
        for (self.children.items) |child| {
            if (child.kind == .clip) try child.kind.clip.applyPendingGoto(ctx);
        }
    }

    /// Rewind (if the target is behind us) and replay up to it.
    ///
    /// Children placed on frames at or before the target SURVIVE (ruffle
    /// run_goto survives_rewind) — only later placements are dropped.
    /// Replaying from frame 1 is then safe: `placeObject` refuses to place
    /// over an occupied depth, so survivors keep their identity (and their
    /// timeline position) instead of being destroyed and re-created.
    pub fn runGoto(self: *MovieClip, ctx: *Context, target: u16) Error!void {
        if (target < self.current_frame) {
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (!survivesRewind(child, target)) {
                    _ = self.children.orderedRemove(i);
                    try retire(ctx, child);
                    continue;
                }
                i += 1;
            }
            self.current_frame = 0;
        }
        // Seeking past the last frame lands ON the last frame — but it
        // never "hits the target", so the destination's actions do NOT run
        // (ruffle movie_clip.rs:1698 clamped_frame, and the
        // `hit_target_frame` branch at 1861: "gotoAndStop(9999) displays
        // the final frame, but actions don't run!").
        const clamped: u16 = @min(target, @as(u16, @intCast(self.frames.len)));
        var f: u16 = self.current_frame + 1;
        while (f <= clamped) : (f += 1) {
            // Intermediate frames replay display state only; the
            // DESTINATION frame also runs its script (Flash: goto
            // executes the target frame's actions).
            try self.executeFrame(ctx, f, f == target);
        }
        self.current_frame = clamped;
    }

    /// Script depths start here — `AVM_DEPTH_BIAS`, duplicated from
    /// avm1/stage_object.zig because core/display never imports the VM.
    const SCRIPT_DEPTH_BASE: i32 = 16384;

    /// ruffle `survives_rewind`, AVM1 branch (movie_clip.rs:1897-1926).
    /// Only objects at TIMELINE depths are candidates for removal at all,
    /// which is why a script-created clip at depth 0 or above sails through
    /// every rewind. Among the candidates, one the script itself created —
    /// or moved there — goes unconditionally, and the rest survive exactly
    /// when the replay will place them again.
    fn survivesRewind(child: *DisplayObject, target: u16) bool {
        if (child.depth >= SCRIPT_DEPTH_BASE) return true;
        if (child.placed_by_script) return false;
        return child.place_frame <= target;
    }

    pub fn childAtDepth(self: *MovieClip, depth: i32) ?*DisplayObject {
        for (self.children.items) |child| {
            if (child.depth == depth) return child;
        }
        return null;
    }

    /// Move `child` to `depth`, exchanging with whoever already sits there.
    /// Both halves of the exchange lose their clip depth and count as
    /// script-transformed, so the timeline stops re-placing them
    /// (ruffle container.rs:1023-1075). Our child list IS the render list,
    /// kept depth-ordered, so re-sorting reproduces both of ruffle's
    /// branches: a swap when the slot was taken, a slide when it was free.
    pub fn swapAtDepth(self: *MovieClip, child: *DisplayObject, depth: i32) void {
        const prev_depth = child.depth;
        if (self.childAtDepth(depth)) |prev| {
            if (prev == child) return;
            prev.depth = prev_depth;
            prev.clip_depth = 0;
            prev.transformed_by_script = true;
        }
        child.depth = depth;
        child.clip_depth = 0;
        std.sort.insertion(*DisplayObject, self.children.items, {}, byDepth);
    }

    fn byDepth(_: void, a: *DisplayObject, b: *DisplayObject) bool {
        return a.depth < b.depth;
    }

    pub fn removeAtDepth(self: *MovieClip, ctx: *Context, depth: i32) Error!void {
        for (self.children.items, 0..) |child, i| {
            if (child.depth == depth) {
                _ = self.children.orderedRemove(i);
                try retire(ctx, child);
                return;
            }
        }
    }

    fn placeObject(self: *MovieClip, ctx: *Context, po: swf.place.PlaceObject, frame_num: u16) Error!void {
        switch (po.action) {
            .place => |id| {
                // Flash refuses to place over an occupied depth.
                if (self.childAtDepth(po.depth) != null) return;
                try self.instantiate(ctx, id, po, frame_num);
            },
            .replace => |id| {
                try self.removeAtDepth(ctx, po.depth);
                try self.instantiate(ctx, id, po, frame_num);
            },
            .modify => {
                const child = self.childAtDepth(po.depth) orelse return;
                try applyPlacement(ctx, child, po, false);
            },
        }
    }

    fn instantiate(self: *MovieClip, ctx: *Context, id: u16, po: swf.place.PlaceObject, frame_num: u16) Error!void {
        const obj = try self.instantiateAt(ctx, id, po.depth, frame_num) orelse return;
        try applyPlacement(ctx, obj, po, true);
        try self.finishInstantiate(ctx, obj, true);
    }

    /// Create a character instance at `depth` and link it to this timeline,
    /// WITHOUT placing it in the child list yet — the caller applies its
    /// placement (a PlaceObject tag, or a script's matrix copy) and then
    /// calls `finishInstantiate`. `char_id == 0` makes an empty clip, which
    /// is what `createEmptyMovieClip` needs.
    pub fn instantiateAt(self: *MovieClip, ctx: *Context, id: u16, depth: i32, frame_num: u16) Error!?*DisplayObject {
        const kind: DisplayObject.Kind = if (id == 0) blk: {
            const mc = try ctx.gpa.create(MovieClip);
            mc.* = MovieClip.init(&.{});
            break :blk .{ .clip = mc };
        } else blk: {
            const character = ctx.movie.lib.getConstPtr(id) orelse return null;
            break :blk switch (character.*) {
                .shape => |*s| .{ .shape = s },
                .morph_shape => .{ .morph_shape = id },
                .text => |*t| .{ .text = t },
                .edit_text => |*et| .{ .edit_text = e: {
                    const inst = try ctx.gpa.create(edit_text_mod.EditText);
                    inst.* = try edit_text_mod.EditText.fromTag(ctx.gpa, et, &ctx.movie.lib, ctx.movie.swf_version);
                    break :e inst;
                } },
                .button => |*btn| .{ .button = b: {
                    const bt = try ctx.gpa.create(button_mod.Button);
                    bt.* = button_mod.Button.init(btn);
                    break :b bt;
                } },
                .bitmap => |b| .{ .bitmap = bm: {
                    const size = bitmap_decode.sizeOf(b) orelse .{ 0, 0 };
                    break :bm .{ .id = id, .width = size[0], .height = size[1] };
                } },
                .sprite => |sprite| .{ .clip = c: {
                    const mc = try ctx.gpa.create(MovieClip);
                    mc.* = MovieClip.init(sprite.frames);
                    mc.tag_stream_len = sprite.tag_stream_len;
                    break :c mc;
                } },
                .sound, .font => return null, // not placeable
            };
        };
        const obj = try ctx.gpa.create(DisplayObject);
        obj.* = .{
            .character_id = id,
            .depth = depth,
            .place_frame = frame_num,
            .kind = kind,
        };
        obj.parent = self;
        if (kind == .clip) {
            kind.clip.placement = obj;
            kind.clip.parent = self;
        }
        return obj;
    }

    /// `createTextField` — a field with no character behind it. Not a
    /// branch of `instantiateAt` because there is no library entry to look
    /// up, and `character_id` stays 0 the way an empty clip's does.
    pub fn instantiateTextField(
        self: *MovieClip,
        ctx: *Context,
        depth: i32,
        width: f64,
        height: f64,
    ) Error!*DisplayObject {
        const inst = try ctx.gpa.create(edit_text_mod.EditText);
        inst.* = try edit_text_mod.EditText.dynamic(ctx.gpa, width, height);
        const obj = try ctx.gpa.create(DisplayObject);
        obj.* = .{
            .character_id = 0,
            .depth = depth,
            .place_frame = 1,
            .kind = .{ .edit_text = inst },
        };
        obj.parent = self;
        return obj;
    }

    /// `attachBitmap`: a script `BitmapData` on the display list. The
    /// buffer is BORROWED — the AVM1 object owns it and outlives this
    /// object, so `owns_kind` stays false for the pixels.
    pub fn instantiateAttachedBitmap(
        self: *MovieClip,
        ctx: *Context,
        depth: i32,
        data: *const bitmap_data_mod.BitmapData,
        smoothing: bool,
    ) Error!*DisplayObject {
        const obj = try ctx.gpa.create(DisplayObject);
        obj.* = .{
            .character_id = 0,
            .depth = depth,
            .place_frame = 1,
            .kind = .{ .attached_bitmap = .{ .data = data, .smoothing = smoothing } },
        };
        obj.parent = self;
        return obj;
    }

    /// Name it, insert it depth-ordered, and run its first frame.
    ///
    /// `queue_construct` is false when the AVM is doing the instantiating
    /// (`attachMovie` and friends): there the registered class is applied
    /// IMMEDIATELY by the caller instead of through the action queue, which
    /// is the whole difference between ruffle's two branches in
    /// `construct_as_avm1_object`.
    pub fn finishInstantiate(self: *MovieClip, ctx: *Context, obj: *DisplayObject, queue_construct: bool) Error!void {
        // Flash names every unnamed instance `instanceN` from one global
        // counter (ruffle set_default_instance_name). This happens BEFORE
        // the child runs its own first frame below, so nested placements
        // number pre-order — the same order ruffle gets by naming in
        // post_instantiation ahead of construct_as_avm1_object.
        if (obj.name == null and takesInstanceName(obj.kind)) try assignInstanceName(ctx, obj);
        // Insert keeping depth order (render walks the list directly).
        var insert_at: usize = self.children.items.len;
        for (self.children.items, 0..) |child, i| {
            if (child.depth > obj.depth) {
                insert_at = i;
                break;
            }
        }
        try self.children.insert(ctx.gpa, insert_at, obj);
        // New clips run their first frame on the tick they appear (and
        // are skipped by this tick's child loop — see `ran_this_tick`).
        // A button builds its initial state (and its hit area) as soon as
        // it is on the list, so its children are named right after it and
        // `_width` measures something on the very first frame.
        if (obj.kind == .button) try obj.kind.button.ensureInit(ctx, obj);
        // A field binds its `variable` the moment it is addressable, which
        // is why the initial value can travel in either direction before
        // any frame script runs.
        if (obj.kind == .edit_text) {
            if (ctx.object_instantiated) |f| f(ctx.class_lookup_user.?, obj);
        }
        if (obj.kind == .clip) {
            // Construct is queued BEFORE the first frame runs. Ruffle's
            // instantiate_child passes `run_frame = false` to
            // post_instantiation and only then calls run_frame_avm1, so a
            // parent's constructor is queued ahead of the children that
            // parent's frame 1 is about to place (corpus
            // register_and_init_order traces the parent first).
            if (queue_construct) try queueConstruct(ctx, obj);
            try obj.kind.clip.runFrame(ctx);
            obj.kind.clip.ran_this_tick = true;
            if (ctx.object_instantiated) |f| f(ctx.class_lookup_user.?, obj);
        }
    }

    /// `onClipEvent(initialize)` bodies go to the Initialize bucket; the
    /// `construct` bodies ride along with the registered constructor in one
    /// Construct entry, because the prototype has to be re-pointed before
    /// they run (ruffle movie_clip.rs:2060-2090).
    fn queueConstruct(ctx: *Context, obj: *DisplayObject) Error!void {
        const clip = obj.kind.clip;
        var events: std.ArrayList([]const u8) = .empty;
        for (obj.clip_actions) |handler| {
            if (handler.events & swf.place.ClipEvent.INITIALIZE != 0) {
                try ctx.queue(ctx.gpa, .{
                    .clip = clip,
                    .priority = .initialize,
                    .what = .{ .code = handler.actions },
                });
            }
            if (handler.events & swf.place.ClipEvent.CONSTRUCT != 0) {
                try events.append(ctx.gpa, handler.actions);
            }
        }
        const ctor = ctx.registeredClass(obj.character_id);
        if (ctor == 0 and events.items.len == 0) {
            events.deinit(ctx.gpa);
            return;
        }
        try ctx.queue(ctx.gpa, .{
            .clip = clip,
            .priority = .construct,
            .what = .{ .construct = .{
                .ctor = ctor,
                .events = try events.toOwnedSlice(ctx.gpa),
            } },
        });
    }
};

/// Only clips, buttons and text fields are auto-named under AVM1 — the
/// other kinds gate `set_default_instance_name` on `is_action_script_3()`
/// (ruffle graphic.rs:308, text.rs:280, morph_shape.rs:177, bitmap.rs:322)
/// while movie_clip.rs:2748, avm1_button.rs:272 and edit_text.rs:2578 call
/// it unconditionally. Naming the rest would BOTH advance the counter too
/// fast and make an unnamed shape reachable as `_root.instanceN`.
fn takesInstanceName(kind: DisplayObject.Kind) bool {
    return switch (kind) {
        .clip, .button, .edit_text => true,
        .shape, .morph_shape, .text, .bitmap, .attached_bitmap => false,
    };
}

fn assignInstanceName(ctx: *Context, obj: *DisplayObject) Error!void {
    var buf: [24]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "instance{d}", .{ctx.instance_counter.*}) catch return;
    ctx.instance_counter.* +%= 1;
    const name = try ctx.gpa.alloc(u16, ascii.len);
    for (ascii, name) |c, *w| w.* = c;
    obj.name = name;
}

/// ruffle `apply_place_object` (display_object.rs). The whole transform
/// block is skipped once a script has moved the object, otherwise a
/// PlaceObject2-with-move on a later frame — or a goto replay — silently
/// undoes every scripted `_x`/`_alpha`.
///
/// `name` and `clip_depth` are deliberately outside that gate AND only
/// applied at initial placement, matching ruffle's instantiate_child.
fn applyPlacement(ctx: *Context, obj: *DisplayObject, po: swf.place.PlaceObject, initial: bool) Error!void {
    if (initial or !obj.transformed_by_script) {
        if (po.matrix) |m| obj.setMatrix(m);
        if (po.color_transform) |t| obj.color_transform = t;
        if (po.ratio) |x| obj.ratio = x;
        if (po.blend_mode) |m| obj.blend_mode = m;
        if (po.had_filters) obj.tag_filters = po.filter_list;
        // PlaceObject's visibility flag is honoured only from SWF 11 on.
        if (po.is_visible) |v| {
            if (ctx.movie.swf_version >= 11) obj.visible = v;
        }
    }
    if (initial) {
        if (po.name) |n| try obj.setNameFromSwf(ctx.gpa, n, ctx.movie.swf_version);
        if (po.clip_depth) |d| obj.clip_depth = d;
        obj.clip_actions = po.clip_actions;
    }
}

/// Take a child off the display list without freeing it yet. Marks the
/// whole clip subtree `removed` so AVM1 reads return undefined, and hands
/// the object to the tick's graveyard.
fn retire(ctx: *Context, obj: *DisplayObject) Error!void {
    // Focus goes FIRST — ruffle drops it inside `set_parent(None)`,
    // before the unload handlers are even queued.
    ctx.lostDisplayObject(obj);
    // `unload` fires on the way out, deepest child first, and is queued
    // BEFORE the subtree is marked removed so the handlers survive the
    // drain's removed-clip filter (they carry `on_removed`).
    try dispatchUnload(ctx, obj);
    markRemoved(obj);
    try ctx.graveyard.append(ctx.gpa, obj);
}

fn dispatchUnload(ctx: *Context, obj: *DisplayObject) Error!void {
    if (obj.kind == .button) {
        var j = obj.kind.button.container.children.items.len;
        while (j > 0) {
            j -= 1;
            try dispatchUnload(ctx, obj.kind.button.container.children.items[j]);
        }
        return;
    }
    if (obj.kind != .clip) return;
    const mc = obj.kind.clip;
    var i = mc.children.items.len;
    while (i > 0) {
        i -= 1;
        try dispatchUnload(ctx, mc.children.items[i]);
    }
    try mc.dispatchClipEventEx(ctx, swf.place.ClipEvent.UNLOAD, "onUnload", true);
}

fn markRemoved(obj: *DisplayObject) void {
    obj.removed = true;
    if (obj.kind == .button) {
        for (obj.kind.button.container.children.items) |child| markRemoved(child);
        for (obj.kind.button.hit_area.children.items) |child| markRemoved(child);
        return;
    }
    if (obj.kind != .clip) return;
    const mc = obj.kind.clip;
    mc.removed = true;
    for (mc.children.items) |child| markRemoved(child);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn makeMovie(gpa: std.mem.Allocator) !swf.movie.Movie {
    // 3-frame movie: F1 places shape 1; F2 places sprite 2 at depth 2;
    // F3 removes depth 1 + Stop.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, &.{ 0x00, 0x00, 12, 3, 0 });
    // DefineShape id=1 (minimal: bounds nbits=0, 0 fills, 0 lines, nbits 0, end record).
    try payload.appendSlice(gpa, &tagBytes(2, &.{ 1, 0, 0x00, 0, 0, 0x00, 0x00 }));
    // DefineSprite id=2, 1 frame: ShowFrame + End.
    const sprite_body = comptime [_]u8{ 2, 0, 1, 0 } ++ tagBytes(1, "") ++ tagBytes(0, "");
    try payload.appendSlice(gpa, &tagBytes(39, &sprite_body));
    try payload.appendSlice(gpa, &tagBytes(26, &.{ 2, 1, 0, 1, 0 })); // place 1 @ depth 1
    try payload.appendSlice(gpa, &tagBytes(1, ""));
    try payload.appendSlice(gpa, &tagBytes(26, &.{ 2, 2, 0, 2, 0 })); // place 2 @ depth 2
    try payload.appendSlice(gpa, &tagBytes(1, ""));
    try payload.appendSlice(gpa, &tagBytes(28, &.{ 1, 0 })); // remove depth 1
    try payload.appendSlice(gpa, &tagBytes(12, &.{ 0x07, 0x00 })); // Stop
    try payload.appendSlice(gpa, &tagBytes(1, ""));
    try payload.appendSlice(gpa, &tagBytes(0, ""));

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "FWS\x06");
    var len4: [4]u8 = undefined;
    std.mem.writeInt(u32, &len4, @intCast(payload.items.len + 8), .little);
    try file.appendSlice(gpa, &len4);
    try file.appendSlice(gpa, payload.items);
    return swf.movie.load(gpa, file.items);
}

fn tagBytes(comptime code: u16, comptime body: []const u8) [2 + body.len]u8 {
    const cl: u16 = (code << 6) | @as(u16, body.len);
    return [2]u8{ @truncate(cl), @truncate(cl >> 8) } ++ body[0..body.len].*;
}

test "timeline: place, sprite instantiation, remove, implicit stop, goto replay" {
    const gpa = testing.allocator;
    var movie = try makeMovie(gpa);
    defer movie.deinit();
    var counter: u32 = 0;
    var ctx: Context = .{ .gpa = gpa, .movie = &movie, .instance_counter = &counter };
    defer ctx.deinit(gpa);

    var root = MovieClip.init(movie.frames);
    defer root.deinit(gpa);

    try root.runFrame(&ctx);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 1), root.current_frame);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqual(@as(u16, 1), root.children.items[0].character_id);

    try root.runFrame(&ctx);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 2), root.current_frame);
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expect(root.children.items[1].kind == .clip);
    // Sprite child ran its first frame on placement.
    try testing.expectEqual(@as(u16, 1), root.children.items[1].kind.clip.current_frame);

    try root.runFrame(&ctx);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 3), root.current_frame);
    try testing.expectEqual(@as(usize, 1), root.children.items.len); // depth 1 removed
    // The Stop DoAction is QUEUED for the interpreter (M3 model), not run
    // inline; simulate its effect for the remainder of the test. Count
    // only BYTECODE entries — every clip also queues an onLoad/
    // onEnterFrame method entry per tick.
    var code_entries: usize = 0;
    for (ctx.queues) |q| {
        for (q.items) |qa| {
            if (qa.what == .code) code_entries += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), code_entries);
    try testing.expectEqual(root.frames[2].controls.len, 2); // remove + do_action
    root.playing = false;

    // Stopped: further ticks don't advance.
    try root.runFrame(&ctx);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 3), root.current_frame);

    // Goto replay back to frame 1: children rebuilt, actions suppressed.
    root.gotoFrame(1);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 1), root.current_frame);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqual(@as(u16, 1), root.children.items[0].character_id);
    try testing.expect(!root.playing); // goto alone doesn't resume playback
}

test "single-frame clip implicitly stops; multi-frame loops" {
    const gpa = testing.allocator;
    var movie = try makeMovie(gpa);
    defer movie.deinit();
    var counter: u32 = 0;
    var ctx: Context = .{ .gpa = gpa, .movie = &movie, .instance_counter = &counter };
    defer ctx.deinit(gpa);
    var root = MovieClip.init(movie.frames);
    defer root.deinit(gpa);
    // Play through 3 frames, tick again → loops to 1.
    for (0..3) |_| {
        try root.runFrame(&ctx);
        try root.applyPendingGoto(&ctx);
    }
    try root.runFrame(&ctx);
    try root.applyPendingGoto(&ctx);
    try testing.expectEqual(@as(u16, 1), root.current_frame);
}
