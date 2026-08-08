//! A DefineButton instance: three visual states, a hit area, and the
//! ButtonCondAction table that drives them.
//!
//! A button is a CONTAINER, not a leaf. Its state records are real display
//! objects — they get instance names, they tick, `_parent` chains through
//! the button, and `button._width` measures them. The two child lists are
//! frameless `MovieClip`s purely to reuse the timeline's placement, depth
//! ordering and removal code; neither is scriptable, and anything that
//! asks for the visible container's AVM1 object is handed the BUTTON's
//! instead (avm1/stage_object.zig `clipObject`).
//!
//! Reference: reference/ruffle/core/src/display_object/avm1_button.rs.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const movie_clip = @import("movie_clip.zig");
const display_object = @import("display_object.zig");

const MovieClip = movie_clip.MovieClip;
const DisplayObject = display_object.DisplayObject;
const Context = movie_clip.Context;
const Error = movie_clip.Error;

/// The three states content can see. `hit` is not a state — those records
/// live in their own container and never render.
pub const State = enum {
    up,
    over,
    down,

    pub fn matches(self: State, rec: swf.button.ButtonRecord) bool {
        return switch (self) {
            .up => rec.state_up,
            .over => rec.state_over,
            .down => rec.state_down,
        };
    }
};

pub const Button = struct {
    def: *const swf.button.Button,
    state: State = .up,
    /// The children currently on screen, one per matching state record.
    container: MovieClip,
    /// `state_hit_test` records, instantiated once and never rendered.
    hit_area: MovieClip,
    /// False until the first `setState` has run — the initial state is
    /// built on placement, not at construction, because instantiating
    /// children needs the Context.
    initialized: bool = false,

    pub fn init(def: *const swf.button.Button) Button {
        return .{
            .def = def,
            .container = MovieClip.init(&.{}),
            .hit_area = MovieClip.init(&.{}),
        };
    }

    pub fn deinit(self: *Button, gpa: std.mem.Allocator) void {
        self.container.deinit(gpa);
        self.hit_area.deinit(gpa);
    }

    /// Link both containers to the button's own placement. They then
    /// behave exactly like "the button viewed as a timeline": their
    /// children's `_parent` is the button, and paths run through its name.
    pub fn attach(self: *Button, obj: *DisplayObject) void {
        for ([_]*MovieClip{ &self.container, &self.hit_area }) |c| {
            c.placement = obj;
            c.parent = obj.parent;
            c.owner_button = obj;
        }
    }

    /// Build the initial state and the hit area. Ruffle does both inside
    /// `Avm1Button::set_state` on the frame the button is placed.
    pub fn ensureInit(self: *Button, ctx: *Context, obj: *DisplayObject) Error!void {
        if (self.initialized) return;
        self.initialized = true;
        self.attach(obj);
        try instantiateInto(&self.hit_area, ctx, self.def, null);
        try self.setState(ctx, obj, self.state);
    }

    /// Switch states, REUSING any child whose depth and character both
    /// match — a clip inside a button keeps its timeline position (and its
    /// script object) across an up→over→down cycle, which is what makes
    /// animated buttons animate instead of restarting.
    pub fn setState(self: *Button, ctx: *Context, obj: *DisplayObject, state: State) Error!void {
        self.state = state;
        self.attach(obj);
        try instantiateInto(&self.container, ctx, self.def, state);
    }

    /// One mouse event: the state it moves to, the cond actions it fires,
    /// and the script handler it queues (ruffle avm1_button.rs
    /// event_dispatch). A DISABLED button still tracks state — it just
    /// runs nothing and can never sit in the `over` state.
    pub fn handleEvent(
        self: *Button,
        ctx: *Context,
        obj: *DisplayObject,
        event: @import("mouse.zig").Event,
    ) Error!void {
        const target: State = switch (event) {
            .drag_out, .release, .roll_over => .over,
            .drag_over, .press => .down,
            .release_outside, .roll_out => .up,
        };
        const cond: u16 = switch (event) {
            .drag_out => Cond.OVER_DOWN_TO_OUT_DOWN,
            .drag_over => Cond.OUT_DOWN_TO_OVER_DOWN,
            .press => Cond.OVER_UP_TO_OVER_DOWN,
            .release => Cond.OVER_DOWN_TO_OVER_UP,
            .release_outside => Cond.OUT_DOWN_TO_IDLE,
            .roll_out => Cond.OVER_UP_TO_IDLE,
            .roll_over => Cond.IDLE_TO_OVER_UP,
        };
        if (ctx.mouseEnabled(obj)) {
            try self.runActions(ctx, obj, cond);
            // The script handler is queued AFTER the SWF-defined actions.
            try ctx.queue(ctx.gpa, .{
                .clip = obj.parent orelse return,
                .display = obj,
                .what = .{ .method = event.method() },
            });
            if (self.state != target) try self.setState(ctx, obj, target);
        } else if (target != .over) {
            try self.setState(ctx, obj, .up);
        }
    }

    /// Cond actions run on the button's PARENT timeline, not on the button
    /// (ruffle avm1_button.rs:600-613) — which is why `this` inside
    /// `on(release)` is the clip holding the button.
    pub fn runActions(self: *Button, ctx: *Context, obj: *DisplayObject, cond: u16) Error!void {
        const parent = obj.parent orelse return;
        for (self.def.actions) |action| {
            if (!condMatches(action.conditions, cond)) continue;
            try ctx.queue(ctx.gpa, .{ .clip = parent, .what = .{ .code = action.actions } });
        }
    }

    /// Every visible child, for the renderer and for bounds.
    pub fn children(self: *const Button) []const *DisplayObject {
        return self.container.children.items;
    }

    pub fn hitChildren(self: *const Button) []const *DisplayObject {
        return self.hit_area.children.items;
    }
};

/// The ButtonCondAction transition bits (SWF19 ButtonCondAction; ruffle
/// swf/src/types.rs ButtonActionCondition). Bits 9-15 are a key code.
pub const Cond = struct {
    pub const IDLE_TO_OVER_UP: u16 = 1 << 0;
    pub const OVER_UP_TO_IDLE: u16 = 1 << 1;
    pub const OVER_UP_TO_OVER_DOWN: u16 = 1 << 2;
    pub const OVER_DOWN_TO_OVER_UP: u16 = 1 << 3;
    pub const OVER_DOWN_TO_OUT_DOWN: u16 = 1 << 4;
    pub const OUT_DOWN_TO_OVER_DOWN: u16 = 1 << 5;
    pub const OUT_DOWN_TO_IDLE: u16 = 1 << 6;
    pub const IDLE_TO_OVER_DOWN: u16 = 1 << 7;
    pub const OVER_DOWN_TO_IDLE: u16 = 1 << 8;
    pub const KEY_PRESS: u16 = 0b111_1111 << 9;
};

/// Ruffle `ButtonActionCondition::matches`: the transition bits must
/// contain the tested one, and a record that names a KEY only matches a
/// test naming the same key.
pub fn condMatches(record: u16, test_cond: u16) bool {
    const rec_key = record & Cond.KEY_PRESS;
    const test_key = test_cond & Cond.KEY_PRESS;
    const rec_bits = record & ~Cond.KEY_PRESS;
    const test_bits = test_cond & ~Cond.KEY_PRESS;
    return (rec_bits & test_bits) == test_bits and (test_key == 0 or test_key == rec_key);
}

/// Reconcile `into` with the records that match `state` (null = the hit
/// records). Depths that the new state drops are removed; depths whose
/// character is unchanged keep their instance.
fn instantiateInto(
    into: *MovieClip,
    ctx: *Context,
    def: *const swf.button.Button,
    state: ?State,
) Error!void {
    // Drop what the new state does not want. Walk backwards: removal
    // shifts the tail.
    var i = into.children.items.len;
    while (i > 0) {
        i -= 1;
        const child = into.children.items[i];
        if (wanted(def, state, child.depth, child.character_id)) continue;
        try into.removeAtDepth(ctx, child.depth);
    }
    for (def.records) |rec| {
        if (!recordMatches(rec, state)) continue;
        const depth: i32 = rec.depth;
        if (into.childAtDepth(depth)) |existing| {
            if (existing.character_id == rec.id) {
                applyRecord(existing, rec);
                continue;
            }
            try into.removeAtDepth(ctx, depth);
        }
        const child = try into.instantiateAt(ctx, rec.id, depth, 1) orelse continue;
        applyRecord(child, rec);
        try into.finishInstantiate(ctx, child, true);
    }
}

fn recordMatches(rec: swf.button.ButtonRecord, state: ?State) bool {
    return if (state) |s| s.matches(rec) else rec.state_hit_test;
}

fn wanted(def: *const swf.button.Button, state: ?State, depth: i32, id: u16) bool {
    for (def.records) |rec| {
        if (!recordMatches(rec, state)) continue;
        if (rec.depth == depth and rec.id == id) return true;
    }
    return false;
}

fn applyRecord(obj: *DisplayObject, rec: swf.button.ButtonRecord) void {
    obj.matrix = rec.matrix;
    obj.color_transform = rec.color_transform;
    obj.blend_mode = rec.blend_mode;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn tagBytes(comptime code: u16, comptime body: []const u8) [2 + body.len]u8 {
    const cl: u16 = (code << 6) | @as(u16, body.len);
    return [2]u8{ @truncate(cl), @truncate(cl >> 8) } ++ body[0..body.len].*;
}

/// A movie whose library holds two minimal shapes, 1 and 2.
fn makeShapeMovie(gpa: std.mem.Allocator) !swf.movie.Movie {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, &.{ 0x00, 0x00, 12, 1, 0 });
    try payload.appendSlice(gpa, &tagBytes(2, &.{ 1, 0, 0x00, 0, 0, 0x00, 0x00 }));
    try payload.appendSlice(gpa, &tagBytes(2, &.{ 2, 0, 0x00, 0, 0, 0x00, 0x00 }));
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

fn makeRec(id: u16, depth: u16, up: bool, over: bool, hit: bool) swf.button.ButtonRecord {
    return .{
        .state_up = up,
        .state_over = over,
        .state_down = false,
        .state_hit_test = hit,
        .id = id,
        .depth = depth,
        .matrix = .{},
    };
}

test "state records instantiate, swap by character, and are reused by depth" {
    const gpa = testing.allocator;
    var movie = try makeShapeMovie(gpa);
    defer movie.deinit();
    var counter: u32 = 0;
    var ctx: Context = .{ .gpa = gpa, .movie = &movie, .instance_counter = &counter };
    defer ctx.deinit(gpa);

    var records = [_]swf.button.ButtonRecord{
        makeRec(1, 1, true, false, false), // up only
        makeRec(2, 1, false, true, false), // over only, SAME depth
        makeRec(1, 2, true, true, false), // both states, unchanged across them
        makeRec(1, 3, false, false, true), // hit area
    };
    const def: swf.button.Button = .{
        .version = 2,
        .id = 9,
        .records = &records,
        .actions = &.{},
    };

    var host = MovieClip.init(&.{});
    defer host.deinit(gpa);
    var obj: DisplayObject = .{ .character_id = 9, .depth = 1, .kind = .{ .button = undefined } };
    var btn = Button.init(&def);
    defer btn.deinit(gpa);
    obj.kind = .{ .button = &btn };
    obj.parent = &host;

    try btn.ensureInit(&ctx, &obj);
    try testing.expectEqual(@as(usize, 2), btn.children().len);
    try testing.expectEqual(@as(u16, 1), btn.children()[0].character_id);
    try testing.expectEqual(@as(usize, 1), btn.hitChildren().len);
    try testing.expectEqual(@as(i32, 3), btn.hitChildren()[0].depth);
    const kept = btn.children()[1];

    try btn.setState(&ctx, &obj, .over);
    try testing.expectEqual(@as(usize, 2), btn.children().len);
    // Depth 1 now holds the OTHER character…
    try testing.expectEqual(@as(u16, 2), btn.children()[0].character_id);
    // …while depth 2, unchanged between the states, is the same instance.
    try testing.expectEqual(kept, btn.children()[1]);

    // A state no record matches empties the container without touching
    // the hit area.
    try btn.setState(&ctx, &obj, .down);
    try testing.expectEqual(@as(usize, 0), btn.children().len);
    try testing.expectEqual(@as(usize, 1), btn.hitChildren().len);
}
