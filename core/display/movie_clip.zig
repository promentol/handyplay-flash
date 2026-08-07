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

const DisplayObject = display_object.DisplayObject;

pub const Error = std.mem.Allocator.Error;

/// Shared per-tick context threaded through the tree walk.
pub const Context = struct {
    gpa: std.mem.Allocator,
    movie: *const swf.movie.Movie,
    /// Set by SetBackgroundColor during execution.
    background_color: ?swf.reader.Color = null,
    /// DoAction bytecodes queued this tick (drained by the player AFTER
    /// all clips ran — Ruffle's ActionQueue model). Initialize-priority
    /// entries (DoInitAction) occupy the first `init_count` slots.
    actions: std.ArrayList(QueuedAction) = .empty,
    init_count: usize = 0,
};

pub const QueuedAction = struct {
    clip: *MovieClip,
    code: []const u8,
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
    /// Deferred goto target (applied by the tree owner after the action
    /// scan so replay never recurses inside control execution).
    pending_goto: ?u16 = null,
    /// Lazily-created AVM1 object handle for this clip (0 = none yet).
    avm_object: u32 = 0,
    /// True between "placed this tick" and the end of that tick: a clip
    /// runs its first frame on placement, so the parent's child-tick loop
    /// must skip it (otherwise it advances twice in one tick).
    ran_this_tick: bool = false,

    pub fn init(frames: []const library.Frame) MovieClip {
        return .{ .frames = frames };
    }

    pub fn deinit(self: *MovieClip, gpa: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(gpa);
            gpa.destroy(child);
        }
        self.children.deinit(gpa);
    }

    pub fn totalFrames(self: *const MovieClip) u16 {
        return @intCast(self.frames.len);
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
        if (!self.initialized) {
            self.initialized = true;
            // M3: fire onLoad here (instead of EnterFrame, before tags).
        }
        if (self.playing or self.current_frame == 0) {
            const next = self.determineNextFrame();
            if (next != self.current_frame or self.current_frame == 0) {
                try self.executeFrame(ctx, @max(next, 1), true);
                self.current_frame = @max(next, 1);
            }
        }
        // Tick child clips (M3 replaces this tree walk with the global
        // instantiation-order exec list). Clips placed during THIS tick
        // already ran their first frame in `instantiate`.
        for (self.children.items) |child| {
            switch (child.kind) {
                .clip => |mc| {
                    if (mc.ran_this_tick) {
                        mc.ran_this_tick = false;
                        continue;
                    }
                    try mc.runFrame(ctx);
                },
                else => {},
            }
        }
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
            .remove => |ro| self.removeAtDepth(ctx, ro.depth),
            .set_background_color => |c| ctx.background_color = c,
            .do_action => |bytecode| if (run_actions) {
                try ctx.actions.append(ctx.gpa, .{ .clip = self, .code = bytecode });
            },
            .init_action => |ia| if (run_actions) {
                // Initialize priority: runs before this frame's DoActions.
                try ctx.actions.insert(ctx.gpa, ctx.init_count, .{ .clip = self, .code = ia.code });
                ctx.init_count += 1;
            },
            .start_sound, .sound_stream_block => {}, // M6
        };
    }

    /// Record a goto target for applyPendingGoto (public: the host seam
    /// and later the interpreter use it for gotoAndPlay/Stop).
    pub fn gotoFrame(self: *MovieClip, target: u16) void {
        self.pending_goto = @min(@max(target, 1), @as(u16, @intCast(self.frames.len)));
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
        if (target == self.current_frame) return;
        // Rewind: children placed on frames at or before the target
        // SURVIVE (ruffle run_goto survives_rewind) — only later
        // placements are dropped. Replaying from frame 1 is then safe:
        // `placeObject` refuses to place over an occupied depth, so
        // survivors keep their identity (and their timeline position)
        // instead of being destroyed and re-created.
        if (target < self.current_frame) {
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (child.place_frame > target) {
                    _ = self.children.orderedRemove(i);
                    child.deinit(ctx.gpa);
                    ctx.gpa.destroy(child);
                    continue;
                }
                i += 1;
            }
            self.current_frame = 0;
        }
        var f: u16 = self.current_frame + 1;
        while (f <= target) : (f += 1) {
            // Intermediate frames replay display state only; the
            // DESTINATION frame also runs its script (Flash: goto
            // executes the target frame's actions).
            try self.executeFrame(ctx, f, f == target);
        }
        self.current_frame = target;
        for (self.children.items) |child| {
            if (child.kind == .clip) try child.kind.clip.applyPendingGoto(ctx);
        }
    }

    pub fn childAtDepth(self: *MovieClip, depth: u16) ?*DisplayObject {
        for (self.children.items) |child| {
            if (child.depth == depth) return child;
        }
        return null;
    }

    fn removeAtDepth(self: *MovieClip, ctx: *Context, depth: u16) void {
        for (self.children.items, 0..) |child, i| {
            if (child.depth == depth) {
                _ = self.children.orderedRemove(i);
                child.deinit(ctx.gpa);
                ctx.gpa.destroy(child);
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
                self.removeAtDepth(ctx, po.depth);
                try self.instantiate(ctx, id, po, frame_num);
            },
            .modify => {
                const child = self.childAtDepth(po.depth) orelse return;
                applyPlacement(child, po);
            },
        }
    }

    fn instantiate(self: *MovieClip, ctx: *Context, id: u16, po: swf.place.PlaceObject, frame_num: u16) Error!void {
        const character = ctx.movie.lib.getConstPtr(id) orelse return;
        const kind: DisplayObject.Kind = switch (character.*) {
            .shape => |*s| .{ .shape = s },
            .morph_shape => .{ .morph_shape = id },
            .text => |*t| .{ .text = t },
            .edit_text => |*et| .{ .edit_text = et },
            .button => |*btn| .{ .button = btn },
            .bitmap => .{ .bitmap = id },
            .sprite => |sprite| blk: {
                const mc = try ctx.gpa.create(MovieClip);
                mc.* = MovieClip.init(sprite.frames);
                break :blk .{ .clip = mc };
            },
            .sound, .font => return, // not placeable
        };
        const obj = try ctx.gpa.create(DisplayObject);
        obj.* = .{
            .character_id = id,
            .depth = po.depth,
            .place_frame = frame_num,
            .kind = kind,
        };
        applyPlacement(obj, po);
        // Insert keeping depth order (render walks the list directly).
        var insert_at: usize = self.children.items.len;
        for (self.children.items, 0..) |child, i| {
            if (child.depth > po.depth) {
                insert_at = i;
                break;
            }
        }
        try self.children.insert(ctx.gpa, insert_at, obj);
        // New clips run their first frame on the tick they appear (and
        // are skipped by this tick's child loop — see `ran_this_tick`).
        if (obj.kind == .clip) {
            try obj.kind.clip.runFrame(ctx);
            obj.kind.clip.ran_this_tick = true;
        }
    }
};

fn applyPlacement(obj: *DisplayObject, po: swf.place.PlaceObject) void {
    if (po.matrix) |m| obj.matrix = m;
    if (po.color_transform) |t| obj.color_transform = t;
    if (po.ratio) |x| obj.ratio = x;
    if (po.name) |n| obj.name = n;
    if (po.clip_depth) |d| obj.clip_depth = d;
    if (po.blend_mode) |m| obj.blend_mode = m;
    if (po.is_visible) |v| obj.visible = v;
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
    var ctx: Context = .{ .gpa = gpa, .movie = &movie };
    defer ctx.actions.deinit(gpa);

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
    // inline; simulate its effect for the remainder of the test.
    try testing.expectEqual(@as(usize, 1), ctx.actions.items.len);
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
    var ctx: Context = .{ .gpa = gpa, .movie = &movie };
    defer ctx.actions.deinit(gpa);
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
