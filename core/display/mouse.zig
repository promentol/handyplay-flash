//! Mouse picking and the button event state machine.
//!
//! Two halves that only meet at the Player:
//!
//!   * `pick` — what is under the pointer. AVM1 only ever asks with
//!     "button mode required", so the answer is a BUTTON (hit through its
//!     hit-area records) or a clip that has mouse handlers; everything
//!     else is invisible to the pointer no matter what it draws.
//!   * `derive` + `dispatch` — the rollOver/rollOut/press/release state
//!     machine over the hovered and pressed objects the Player keeps.
//!
//! Reference: reference/ruffle/core/src/player.rs `run_mouse_pick` and
//! `update_mouse_state`, `display_object/movie_clip.rs mouse_pick_avm1`,
//! `display_object/avm1_button.rs event_dispatch`.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const movie_clip = @import("movie_clip.zig");
const display_object = @import("display_object.zig");
const button_mod = @import("button.zig");
const bounds = @import("bounds.zig");

const MovieClip = movie_clip.MovieClip;
const DisplayObject = display_object.DisplayObject;
const Context = movie_clip.Context;
const Error = movie_clip.Error;

/// The button-shaped events. `mouse_move`/`mouse_down`/`mouse_up` are NOT
/// here: those are global broadcasts and never depend on what is hovered.
pub const Event = enum {
    roll_over,
    roll_out,
    press,
    release,
    release_outside,
    drag_over,
    drag_out,

    /// The `onClipEvent(...)` bit this event fires.
    pub fn flag(self: Event) u32 {
        const E = swf.place.ClipEvent;
        return switch (self) {
            .roll_over => E.ROLL_OVER,
            .roll_out => E.ROLL_OUT,
            .press => E.PRESS,
            .release => E.RELEASE,
            .release_outside => E.RELEASE_OUTSIDE,
            .drag_over => E.DRAG_OVER,
            .drag_out => E.DRAG_OUT,
        };
    }

    /// The script-object handler name.
    pub fn method(self: Event) []const u8 {
        return switch (self) {
            .roll_over => "onRollOver",
            .roll_out => "onRollOut",
            .press => "onPress",
            .release => "onRelease",
            .release_outside => "onReleaseOutside",
            .drag_over => "onDragOver",
            .drag_out => "onDragOut",
        };
    }

    /// The frame LABEL a clip in button mode jumps to on this event.
    /// Ruffle checks these before anything else in `event_dispatch`, and a
    /// clip without the label simply does not move.
    pub fn frameLabel(self: Event) ?[]const u8 {
        return switch (self) {
            .roll_out, .release_outside => "_up",
            .roll_over, .release, .drag_out => "_over",
            .press, .drag_over => "_down",
        };
    }
};

/// The seven mouse-driven `onClipEvent` bits, plus keyPress: any ONE of
/// them puts a clip in "button mode" and makes it pickable.
pub const BUTTON_EVENT_FLAGS: u32 =
    swf.place.ClipEvent.PRESS | swf.place.ClipEvent.RELEASE |
    swf.place.ClipEvent.RELEASE_OUTSIDE | swf.place.ClipEvent.ROLL_OVER |
    swf.place.ClipEvent.ROLL_OUT | swf.place.ClipEvent.DRAG_OVER |
    swf.place.ClipEvent.DRAG_OUT | swf.place.ClipEvent.KEY_PRESS;

/// The handler names whose PRESENCE on a clip's script object also counts
/// (ruffle events.rs BUTTON_EVENT_METHODS — note keyPress has no method).
pub const BUTTON_EVENT_METHODS = [_][]const u8{
    "onDragOver", "onDragOut", "onPress", "onRelease",
    "onReleaseOutside", "onRollOut", "onRollOver",
};

/// Is `clip` pickable? The `onClipEvent` half is answered here; the
/// script-property half needs the VM and comes back through the Context.
pub fn isButtonMode(ctx: *Context, clip: *MovieClip) bool {
    if (clip.placement) |p| {
        for (p.clip_actions) |handler| {
            if (handler.events & BUTTON_EVENT_FLAGS != 0) return true;
        }
    }
    // The root is never in button mode through its properties (ruffle
    // movie_clip.rs:2308 bails when there is no parent).
    if (clip.parent == null) return false;
    return ctx.clipHasButtonHandler(clip);
}

/// The topmost interactive object under `point` (twips, STAGE space), or
/// null. `parent_matrix` maps the object's parent space to the stage.
pub fn pick(
    ctx: *Context,
    obj: *DisplayObject,
    parent_matrix: swf.reader.Matrix,
    point: [2]i32,
) ?*DisplayObject {
    if (!obj.visible) return null;
    const world = parent_matrix.mul(obj.matrix);
    switch (obj.kind) {
        .clip => |mc| {
            // The clip ITSELF wins over its own children when it is in
            // button mode — ruffle tests self before recursing.
            // NOTE: `enabled` is not consulted here. In AVM1 it is a
            // BUTTON-only property, read when the event is dispatched
            // (ruffle Avm1Button::enabled); the pick's `mouse_enabled`
            // gate is the AVM2 flag, which AVM1 never clears.
            if (containsPoint(obj, world, point) and
                isButtonMode(ctx, mc) and bounds.hitTestShape(obj, point, parent_matrix))
            {
                return obj;
            }
            return pickChildren(ctx, mc.children.items, world, point);
        },
        .button => |b| {
            // A child of a button can be a button in its own right.
            if (pickChildren(ctx, b.container.children.items, world, point)) |hit| return hit;
            for (b.hit_area.children.items) |child| {
                if (bounds.hitTestShape(child, point, world)) return obj;
            }
            // A button with no hit records is hit through what it shows.
            if (b.hit_area.children.items.len == 0) {
                for (b.container.children.items) |child| {
                    if (bounds.hitTestShape(child, point, world)) return obj;
                }
            }
            return null;
        },
        // A SELECTABLE field is pickable through its whole box — that is
        // how a click lands the caret. A dynamic, non-selectable one is
        // invisible to the mouse, which is why it neither takes focus nor
        // blocks what is behind it (ruffle `mouse_pick_avm1`).
        .edit_text => |et| {
            if (!et.selectable) return null;
            return if (containsPoint(obj, world, point)) obj else null;
        },
        else => return null,
    }
}

/// Front to back — the LAST child in a depth-ascending list draws on top,
/// so it is tested first.
fn pickChildren(
    ctx: *Context,
    children: []const *DisplayObject,
    world: swf.reader.Matrix,
    point: [2]i32,
) ?*DisplayObject {
    var i = children.len;
    while (i > 0) {
        i -= 1;
        const child = children[i];
        // A masker is not itself pickable (M7 applies the mask proper).
        if (child.clip_depth != 0) continue;
        if (pick(ctx, child, world, point)) |hit| return hit;
    }
    return null;
}

fn containsPoint(obj: *const DisplayObject, world: swf.reader.Matrix, point: [2]i32) bool {
    const box = bounds.boundsWithTransform(obj, world) orelse return false;
    return bounds.contains(box, point[0], point[1]);
}

/// Deliver one event to whatever kind of object is under it.
pub fn dispatch(ctx: *Context, obj: *DisplayObject, event: Event) Error!void {
    if (obj.removed) return;
    switch (obj.kind) {
        .button => |b| try b.handleEvent(ctx, obj, event),
        .clip => |mc| try dispatchToClip(ctx, mc, obj, event),
        else => {},
    }
}

/// A clip in button mode reacts three ways: it jumps to the `_up`/`_over`/
/// `_down` frame label if it has one, runs its `onClipEvent` bodies, and
/// then its script handler.
fn dispatchToClip(ctx: *Context, mc: *MovieClip, obj: *DisplayObject, event: Event) Error!void {
    if (event.frameLabel()) |label| {
        if (mc.labelToNumber(label)) |frame| {
            if (isButtonMode(ctx, mc)) {
                mc.gotoFrame(frame);
                mc.playing = false;
            }
        }
    }
    try mc.dispatchMouseEvent(ctx, event);
    _ = obj;
}
