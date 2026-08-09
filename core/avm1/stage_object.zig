//! M4: DisplayObject-as-AVM1-object. Display property table _x.._ymouse in
//! LOAD-BEARING order (it IS the GetProperty/SetProperty index). Resolution:
//! path props -> child by instance name -> display props (always case-insensitive).
//!
//! This is the single file under core/avm1/ that imports core/display/ —
//! `NativeInfo.clip` is an opaque pointer everywhere else, so runtime.zig
//! and object.zig stay display-free. The dependency is one-way: display/
//! never imports avm1/ (except string.zig, which is std-only).
//!
//! Ruffle keeps one `DisplayPropertyMap` behind both `get_by_index` (the
//! SWF4 opcodes) and `get_by_name` (GetMember/GetVariable). So does this.
//! Reference: reference/ruffle/core/src/avm1/object/stage_object.rs.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");
const display_object = @import("../display/display_object.zig");
const movie_clip = @import("../display/movie_clip.zig");
const bounds_mod = @import("../display/bounds.zig");
const bitmap_data_mod = @import("../bitmap/data.zig");
pub const drawing = @import("../display/drawing.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const DisplayObject = display_object.DisplayObject;
const MovieClip = movie_clip.MovieClip;
const S = strings.ascii;

const twipsFromPixels = display_object.twipsFromPixels;
const pixelsFromTwips = display_object.pixelsFromTwips;

/// A scriptable display object: always its placement, plus the timeline
/// when it happens to be a clip. Buttons and text fields are scriptable
/// too (ruffle gives object1 to MovieClip, Avm1Button and EditText) but
/// have no timeline, so `clip` is null and the frame properties read
/// undefined.
pub const Target = struct {
    obj: *DisplayObject,
    clip: ?*MovieClip,

    /// The timeline this object sits in — its `_parent`.
    pub fn parent(self: Target) ?*MovieClip {
        if (self.clip) |c| return c.parent;
        return self.obj.parent;
    }
};

/// Unwrap an AVM1 object handle to a display target. Null when the handle
/// is not a display object, or when it has been removed from the display
/// list (ruffle avm1_removed — a retained reference reads as undefined).
pub fn targetOf(vm: *Vm, handle: ObjectHandle) ?Target {
    if (handle == 0) return null;
    switch (vm.objects.get(handle).native) {
        .clip => |ptr| {
            const mc: *MovieClip = @ptrCast(@alignCast(ptr));
            if (mc.removed) return null;
            return .{ .clip = mc, .obj = mc.placement orelse return null };
        },
        .display => |ptr| {
            const obj: *DisplayObject = @ptrCast(@alignCast(ptr));
            if (obj.removed) return null;
            return .{ .clip = null, .obj = obj };
        },
        else => return null,
    }
}

/// Buttons and text fields are scriptable; graphics, static text, morph
/// shapes and bitmaps are not (ruffle: object1 returns None for those).
pub fn isScriptable(kind: DisplayObject.Kind) bool {
    return switch (kind) {
        // A VIDEO is scriptable — that is the whole difference between
        // a placed video and a placed graphic (corpus place_and_lookup).
        .clip, .button, .edit_text, .video => true,
        .shape, .morph_shape, .text, .bitmap, .attached_bitmap => false,
    };
}

/// Lazily create the AVM1 object for a NON-clip display object.
pub fn displayObject(vm: *Vm, obj: *DisplayObject) !ObjectHandle {
    if (obj.avm_object != 0) return obj.avm_object;
    const h = try vm.objects.create();
    const proto: ObjectHandle = switch (obj.kind) {
        .button => vm.button_proto,
        .edit_text => vm.textfield_proto,
        else => 0,
    };
    vm.objects.get(h).proto = .{ .object = if (proto != 0) proto else vm.object_proto };
    vm.objects.get(h).native = .{ .display = @ptrCast(obj) };
    obj.avm_object = h;
    // Every text field is an AsBroadcaster, and it is its OWN first
    // listener — which is how a field's `onChanged` runs before any
    // script listener's (ruffle initialize_as_broadcaster).
    if (obj.kind == .edit_text) {
        const singletons = @import("globals/singletons.zig");
        try singletons.makeBroadcaster(vm, h);
        if (vm.objects.getChained(h, S("_listeners"), false)) |lv| {
            if (lv == .object) try vm.arraySet(lv.object, 0, .{ .object = h });
        }
    }
    return h;
}

/// The AVM1 object for any scriptable display object, ignoring the SWF4
/// value gate — for INTERNAL resolution (target paths), which works at
/// every version even though the result is not a usable script value.
pub fn handleOf(vm: *Vm, obj: *DisplayObject) !ObjectHandle {
    if (obj.kind == .clip) return clipObject(vm, obj.kind.clip);
    return displayObject(vm, obj);
}

/// A display object AS A SCRIPT VALUE (SWF4 has no object model).
pub fn displayValue(vm: *Vm, obj: *DisplayObject) !Value {
    if (vm.swf_version < 5) return .undefined_value;
    if (obj.kind == .clip) return .{ .object = try clipObject(vm, obj.kind.clip) };
    // SWF5 has no object model for buttons and text fields: a reference to
    // one resolves UP to the first MovieClip ancestor, so a button reads
    // back as the timeline holding it (ruffle
    // MovieClipReference::process_swf5_references; corpus button_v5).
    if (vm.swf_version <= 5) {
        var p = obj.parent;
        while (p) |c| {
            if (c.owner_button) |b| {
                p = b.parent;
                continue;
            }
            return .{ .object = try clipObject(vm, c) };
        }
        return .undefined_value;
    }
    return .{ .object = try displayObject(vm, obj) };
}

/// Is this handle a MovieClip that has been removed from the display list?
/// A `setInterval(clip, "method", …)` stops firing when its clip goes away,
/// and ruffle checks for exactly this (timer.rs:97-114) — an ordinary
/// object with the same shape keeps firing.
pub fn isRemovedClip(vm: *Vm, handle: ObjectHandle) bool {
    if (handle == 0) return false;
    const n = vm.objects.get(handle).native;
    // `removed_display` is the state after the instance has actually been
    // freed; `.clip` with `removed` set is the window between the removal
    // and the end of the tick.
    if (n == .removed_display) return true;
    if (n != .clip) return false;
    const mc: *MovieClip = @ptrCast(@alignCast(n.clip));
    return mc.removed;
}

pub fn targetOfValue(vm: *Vm, v: Value) ?Target {
    return if (v == .object) targetOf(vm, v.object) else null;
}

/// The MovieClip behind a handle, for the Player. Unlike `targetOf` this
/// does NOT reject a removed clip: `unloadMovie` revives one, and the
/// completion of a load has to reach the clip it was aimed at.
pub fn clipOfHandle(vm: *Vm, handle: ObjectHandle) ?*MovieClip {
    if (handle == 0) return null;
    return switch (vm.objects.get(handle).native) {
        .clip => |ptr| @ptrCast(@alignCast(ptr)),
        else => null,
    };
}

/// The SWF version of the movie a clip's own timeline came from. A clip
/// filled by `loadMovie` carries its own `movie`; everything else inherits
/// from the nearest ancestor that does. Ruffle spells this
/// `base_clip.swf_version()`, and a function call adopts it when the call
/// is not a closure.
pub fn clipSwfVersion(vm: *Vm, handle: ObjectHandle) ?u8 {
    const mc = clipOfHandle(vm, handle) orelse return null;
    var cur: ?*const MovieClip = mc;
    while (cur) |c| : (cur = c.parent) {
        if (c.movie) |m| if (m.swf_version != 0) return m.swf_version;
    }
    if (vm.root_swf_version != 0) return vm.root_swf_version;
    return null;
}

// --- the table -------------------------------------------------------------

const Getter = *const fn (vm: *Vm, t: Target) anyerror!Value;
const Setter = *const fn (vm: *Vm, t: Target, v: Value) anyerror!void;

pub const Prop = struct {
    name: []const u16,
    get: Getter,
    set: ?Setter = null,

    pub fn isReadOnly(self: Prop) bool {
        return self.set == null;
    }
};

/// ORDER IS THE SWF4 PROPERTY INDEX. Never sort, never insert in the
/// middle. Mirrors stage_object.rs `PROPERTIES`.
pub const PROPERTIES = [_]Prop{
    .{ .name = S("_x"), .get = getX, .set = setX },
    .{ .name = S("_y"), .get = getY, .set = setY },
    .{ .name = S("_xscale"), .get = getXScale, .set = setXScale },
    .{ .name = S("_yscale"), .get = getYScale, .set = setYScale },
    .{ .name = S("_currentframe"), .get = getCurrentFrame },
    .{ .name = S("_totalframes"), .get = getTotalFrames },
    .{ .name = S("_alpha"), .get = getAlpha, .set = setAlpha },
    .{ .name = S("_visible"), .get = getVisible, .set = setVisible },
    .{ .name = S("_width"), .get = getWidth, .set = setWidth },
    .{ .name = S("_height"), .get = getHeight, .set = setHeight },
    .{ .name = S("_rotation"), .get = getRotation, .set = setRotation },
    .{ .name = S("_target"), .get = getTarget },
    .{ .name = S("_framesloaded"), .get = getFramesLoaded },
    .{ .name = S("_name"), .get = getName, .set = setName },
    .{ .name = S("_droptarget"), .get = getDropTarget },
    .{ .name = S("_url"), .get = getUrl },
    .{ .name = S("_highquality"), .get = getHighQuality, .set = setHighQuality },
    .{ .name = S("_focusrect"), .get = getFocusRect, .set = setFocusRect },
    .{ .name = S("_soundbuftime"), .get = getSoundBufTime, .set = setSoundBufTime },
    .{ .name = S("_quality"), .get = getQuality, .set = setQuality },
    .{ .name = S("_xmouse"), .get = getXMouse },
    .{ .name = S("_ymouse"), .get = getYMouse },
};

/// Display property names are case-insensitive at EVERY SWF version, even
/// 7+ where ordinary members are not (stage_object.rs `get_by_name`).
pub fn findByName(name: []const u16) ?usize {
    for (PROPERTIES, 0..) |p, i| {
        if (strings.eqlIgnoreCase(p.name, name)) return i;
    }
    return null;
}

pub fn getByIndex(vm: *Vm, t: Target, index: usize) !Value {
    if (index >= PROPERTIES.len) return .undefined_value;
    return PROPERTIES[index].get(vm, t);
}

pub fn setByIndex(vm: *Vm, t: Target, index: usize, v: Value) !void {
    if (index >= PROPERTIES.len) return;
    if (PROPERTIES[index].set) |setter| try setter(vm, t, v);
}

// --- coercion helpers (stage_object.rs:701-742) -----------------------------

/// Most setters IGNORE the write entirely for undefined/null/NaN rather
/// than storing a garbage value.
fn coerceToNumber(vm: *Vm, v: Value) !?f64 {
    if (v == .undefined_value or v == .null_value) return null;
    const n = try vm.toNumber(v);
    return if (std.math.isNan(n)) null else n;
}

/// SetProperty coerces its value by INDEX even when the write is going to
/// be dropped (bad target, read-only property). The coercion is observable
/// — it calls valueOf/toString — so it has to happen anyway.
pub fn actionPropertyCoerce(vm: *Vm, index: usize, v: Value) !Value {
    return switch (index) {
        0...10, 12 => if (try coerceToNumber(vm, v)) |n| Value{ .number = n } else v,
        16, 18, 20, 21 => Value{ .number = try vm.toNumber(v) },
        13, 19 => Value{ .string = try vm.toStringValue(v) },
        else => v,
    };
}

// --- position --------------------------------------------------------------

/// A TEXT FIELD's reported position is offset by its own bounds: the tag
/// places the box at `bounds.x_min` inside the instance, and `_x` folds
/// that in (ruffle edit_text.rs:2615-2625). Every other kind reports the
/// placement matrix directly.
/// Bring a text field up to date before anything reads its geometry: the
/// layout is rebuilt if stale and any pending AUTOSIZE box is applied.
/// Ruffle calls `apply_autosize_bounds` from exactly these places and
/// never from a setter, and the ordering is observable.
fn syncField(vm: *Vm, t: Target) void {
    if (t.obj.kind != .edit_text) return;
    const et = t.obj.kind.edit_text;
    if (displayCtx(vm)) |ctx| {
        et.ensureLayout(ctx.gpa, &ctx.movie.lib, ctx.movie.swf_version) catch {};
    }
    et.applyAutosizeBounds();
}

fn boundsOffset(t: Target) [2]i32 {
    if (t.obj.kind != .edit_text) return .{ 0, 0 };
    const b = t.obj.kind.edit_text.bounds;
    return .{
        twipsFromPixels(t.obj.scaleX() / 100.0 * pixelsFromTwips(b.xmin)),
        twipsFromPixels(t.obj.scaleY() / 100.0 * pixelsFromTwips(b.ymin)),
    };
}

fn getX(vm: *Vm, t: Target) !Value {
    syncField(vm, t);
    return .{ .number = pixelsFromTwips(t.obj.matrix.tx +% boundsOffset(t)[0]) };
}

fn setX(vm: *Vm, t: Target, v: Value) !void {
    syncField(vm, t);
    const n = try coerceToNumber(vm, v) orelse return;
    // Both infinities land on -inf, which twipsFromPixels saturates.
    const x = twipsFromPixels(if (std.math.isInf(n)) -std.math.inf(f64) else n);
    t.obj.setX(x -% boundsOffset(t)[0]);
}

fn getY(vm: *Vm, t: Target) !Value {
    syncField(vm, t);
    return .{ .number = pixelsFromTwips(t.obj.matrix.ty +% boundsOffset(t)[1]) };
}

fn setY(vm: *Vm, t: Target, v: Value) !void {
    syncField(vm, t);
    const n = try coerceToNumber(vm, v) orelse return;
    const y = twipsFromPixels(if (std.math.isInf(n)) -std.math.inf(f64) else n);
    t.obj.setY(y -% boundsOffset(t)[1]);
}

// --- scale / rotation ------------------------------------------------------

fn getXScale(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = t.obj.scaleX() };
}

fn setXScale(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    t.obj.setScaleX(n);
}

fn getYScale(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = t.obj.scaleY() };
}

fn setYScale(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    t.obj.setScaleY(n);
}

fn getRotation(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = t.obj.rotation() };
}

fn setRotation(vm: *Vm, t: Target, v: Value) !void {
    var degrees = try coerceToNumber(vm, v) orelse return;
    // Normalise into [-180, 180] — this is why `_rotation = 190` reads
    // back as -170. @rem, NOT @mod: Rust's `%` keeps the sign of the
    // DIVIDEND, so -180 must stay -180 rather than folding to +180.
    degrees = @rem(degrees, 360.0);
    if (degrees < -180.0) {
        degrees += 360.0;
    } else if (degrees > 180.0) {
        degrees -= 360.0;
    }
    t.obj.setRotation(degrees);
}

// --- size ------------------------------------------------------------------

fn getWidth(vm: *Vm, t: Target) !Value {
    syncField(vm, t);
    // A text field measures its own BOX through the placement matrix; it
    // does not union its content (ruffle edit_text.rs:2641-2647).
    if (t.obj.kind == .edit_text) {
        const b = t.obj.matrix.transformRect(t.obj.kind.edit_text.bounds);
        return .{ .number = pixelsFromTwips(b.width()) };
    }
    const b = bounds_mod.localBounds(t.obj) orelse return .{ .number = 0 };
    return .{ .number = pixelsFromTwips(b.width()) };
}

fn getHeight(vm: *Vm, t: Target) !Value {
    syncField(vm, t);
    if (t.obj.kind == .edit_text) {
        const b = t.obj.matrix.transformRect(t.obj.kind.edit_text.bounds);
        return .{ .number = pixelsFromTwips(b.height()) };
    }
    const b = bounds_mod.localBounds(t.obj) orelse return .{ .number = 0 };
    return .{ .number = pixelsFromTwips(b.height()) };
}

fn setWidth(vm: *Vm, t: Target, v: Value) !void {
    syncField(vm, t);
    const n = try coerceToNumber(vm, v) orelse return;
    // Writing a field's width RESIZES the box — it does not scale the
    // field the way it would scale a clip.
    if (t.obj.kind == .edit_text) {
        const et = t.obj.kind.edit_text;
        et.bounds.xmax = et.bounds.xmin +% twipsFromPixels(n);
        // The box moved, so an AUTOSIZING field has to lay out again —
        // and it pins a different edge, which is how `_width = 19` on a
        // right-aligned autosize field ends up 4px wide somewhere else.
        et.dirty = true;
        t.obj.transformed_by_script = true;
        return;
    }
    setSizeAlong(t, n, .width);
}

fn setHeight(vm: *Vm, t: Target, v: Value) !void {
    syncField(vm, t);
    const n = try coerceToNumber(vm, v) orelse return;
    if (t.obj.kind == .edit_text) {
        const et = t.obj.kind.edit_text;
        et.bounds.ymax = et.bounds.ymin +% twipsFromPixels(n);
        et.dirty = true;
        t.obj.transformed_by_script = true;
        return;
    }
    setSizeAlong(t, n, .height);
}

/// Ruffle's set_width/set_height (display_object.rs:1681-1762). The
/// formula is empirical — it solves for the scales that give a rotated
/// object's AABB the requested side length, and its own comment admits it
/// was found by trial and error. Both axes move, even for `_width`.
fn setSizeAlong(t: Target, target_len: f64, axis: enum { width, height }) void {
    const b = bounds_mod.ownBounds(t.obj) orelse swf.reader.Rectangle{};
    const obj_w = pixelsFromTwips(b.width());
    const obj_h = pixelsFromTwips(b.height());
    const aspect = if (axis == .width) obj_h / obj_w else obj_w / obj_h;

    const divisor = if (axis == .width) obj_w else obj_h;
    var target_sx: f64 = 0;
    var target_sy: f64 = 0;
    if (divisor != 0) {
        target_sx = target_len / obj_w;
        target_sy = target_len / obj_h;
    }

    // The AABB formula works in unit scales, not percent.
    const prev_sx = t.obj.scaleX() / 100.0;
    const prev_sy = t.obj.scaleY() / 100.0;
    const rad = std.math.degreesToRadians(t.obj.rotation());
    const cos = @abs(@cos(rad));
    const sin = @abs(@sin(rad));

    var new_sx: f64 = undefined;
    var new_sy: f64 = undefined;
    if (axis == .width) {
        new_sx = aspect * (cos * target_sx + sin * target_sy) /
            ((cos + aspect * sin) * (aspect * cos + sin));
        new_sy = (sin * prev_sx + aspect * cos * prev_sy) / (aspect * cos + sin);
    } else {
        new_sx = (aspect * cos * prev_sx + sin * prev_sy) / (aspect * cos + sin);
        new_sy = aspect * (sin * target_sx + cos * target_sy) /
            ((cos + aspect * sin) * (aspect * cos + sin));
    }
    if (!std.math.isFinite(new_sx)) new_sx = 0;
    if (!std.math.isFinite(new_sy)) new_sy = 0;
    t.obj.setScaleX(new_sx * 100.0);
    t.obj.setScaleY(new_sy * 100.0);
}

// --- colour / visibility ---------------------------------------------------

fn getAlpha(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = t.obj.alpha() * 100.0 };
}

fn setAlpha(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    t.obj.setAlpha(if (std.math.isInf(n)) 0 else n / 100.0);
}

fn getVisible(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .boolean = t.obj.visible };
}

fn setVisible(vm: *Vm, t: Target, v: Value) !void {
    // A Flash 4-era property, so the value is coerced to a NUMBER:
    // `_visible = "false"` is NaN and therefore does nothing at all.
    const n = try coerceToNumber(vm, v) orelse return;
    t.obj.visible = n != 0;
    // "The focus is dropped when it's made invisible"
    // (ruffle display_object.rs:2075).
    if (!t.obj.visible) try dropFocusIf(vm, t.obj);
}

// --- timeline --------------------------------------------------------------

fn getCurrentFrame(vm: *Vm, t: Target) !Value {
    _ = vm;
    const c = t.clip orelse return .undefined_value;
    return .{ .number = @floatFromInt(c.current_frame) };
}

fn getTotalFrames(vm: *Vm, t: Target) !Value {
    _ = vm;
    const c = t.clip orelse return .undefined_value;
    return .{ .number = @floatFromInt(c.totalFrames()) };
}

fn getFramesLoaded(vm: *Vm, t: Target) !Value {
    // A load that FAILED reports -1, not 0 — the clip is not empty, it
    // is broken (corpus movieclip_state_values).
    if (t.clip) |c| {
        if (c.loadInfoOf()) |l| {
            if (l.failed) return .{ .number = -1 };
        }
    }
    // Local playback: everything else is always loaded.
    return getTotalFrames(vm, t);
}

// --- identity --------------------------------------------------------------

fn getName(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .string = t.obj.name orelse S("") };
}

fn setName(vm: *Vm, t: Target, v: Value) !void {
    // SWF7+ turns a NaN into 0 before stringifying, so `_name = 0/0`
    // becomes "0" rather than "NaN".
    const val = if (v == .number and std.math.isNan(v.number) and vm.swf_version >= 7)
        Value{ .number = 0 }
    else
        v;
    const name = try vm.toStringValue(val);
    try t.obj.setName(vm.gpa, name);
}

/// The clip's root — walk `parent` to the top (ruffle avm1_root).
pub fn rootOf(clip: *MovieClip) *MovieClip {
    var cur = clip;
    while (cur.parent) |p| cur = p;
    return cur;
}

fn clipName(clip: *MovieClip) []const u16 {
    const placement = clip.placement orelse return S("");
    return placement.name orelse S("");
}

/// Path segment + parent for ANY display object, clip or not.
fn pathPartsOf(t: Target) struct { name: []const u16, parent: ?*MovieClip } {
    return .{ .name = t.obj.name orelse S(""), .parent = t.parent() };
}

/// Flash 4 slash syntax: `""` for _level0, `/mc/child` below it. This is
/// the `_target` property. ruffle display_object.rs:1840-1867.
pub fn slashPath(vm: *Vm, t: Target) ![]const u16 {
    const parts = pathPartsOf(t);
    const parent = parts.parent orelse return S("/"); // _level0 is just "/"
    const head = try buildSlashPath(vm, parent);
    const with_slash = try strings.concat(vm.arena(), head, S("/"));
    return strings.concat(vm.arena(), with_slash, parts.name);
}

fn buildSlashPath(vm: *Vm, clip: *MovieClip) anyerror![]const u16 {
    const parent = clip.parent orelse {
        // _level0 contributes no name; deeper levels add "_levelN".
        return if (clip.level_id == 0) S("") else levelName(vm, clip.level_id);
    };
    const head = try buildSlashPath(vm, parent);
    const with_slash = try strings.concat(vm.arena(), head, S("/"));
    return strings.concat(vm.arena(), with_slash, clipName(clip));
}

/// Dot syntax rooted at a level: `_level0.mc.child`. DISTINCT from
/// `slashPath` — this is what `targetPath()` returns, what a MovieClip
/// coerces to as a string, and what clip equality compares.
/// ruffle display_object.rs:1824-1835.
pub fn dotPath(vm: *Vm, t: Target) std.mem.Allocator.Error![]const u16 {
    const parts = pathPartsOf(t);
    const parent = parts.parent orelse {
        const lv: i32 = if (t.clip) |c| c.level_id else 0;
        return levelName(vm, lv);
    };
    const head = try dotPathOfClip(vm, parent);
    const with_dot = try strings.concat(vm.arena(), head, S("."));
    return strings.concat(vm.arena(), with_dot, parts.name);
}

fn dotPathOfClip(vm: *Vm, clip: *MovieClip) std.mem.Allocator.Error![]const u16 {
    const parent = clip.parent orelse return levelName(vm, clip.level_id);
    const head = try dotPathOfClip(vm, parent);
    const with_dot = try strings.concat(vm.arena(), head, S("."));
    return strings.concat(vm.arena(), with_dot, clipName(clip));
}

/// `dotPath` for callers that only hold the opaque `NativeInfo.clip`
/// pointer — runtime.zig must not name display types.
///
/// A clip that has been REMOVED has no path: it reports the empty string
/// from the moment `removeMovieClip` runs, not from the end of the tick
/// when its object is finally cut loose (corpus string_paths_basic).
pub fn dotPathOf(vm: *Vm, clip: *anyopaque) std.mem.Allocator.Error![]const u16 {
    const mc: *MovieClip = @ptrCast(@alignCast(clip));
    if (mc.placement) |pl| if (pl.path_lost) return S("");
    return dotPathOfClip(vm, mc);
}

/// Same, for the non-clip scriptable kinds (buttons, text fields) whose
/// AVM1 object holds the DisplayObject directly.
pub fn dotPathOfDisplay(vm: *Vm, obj: *anyopaque) std.mem.Allocator.Error![]const u16 {
    const d: *DisplayObject = @ptrCast(@alignCast(obj));
    if (d.path_lost) return S("");
    return dotPath(vm, .{ .obj = d, .clip = null });
}

/// The `_parent` of an object handle, or undefined. Used by the
/// DefineFunction2 register preload.
pub fn parentOf(vm: *Vm, handle: ObjectHandle) !Value {
    const t = targetOf(vm, handle) orelse return .undefined_value;
    const parent = t.parent() orelse return .undefined_value;
    return .{ .object = try clipObject(vm, parent) };
}

/// `_levelN` / `_flashN` (a relic synonym from the earliest Flash
/// versions). ruffle stage_object.rs:174-207. A level that no
/// `loadMovieNum` has created is a valid NAME that resolves to nothing —
/// still different from "not a level name at all" (null).
pub fn parseLevel(vm: *Vm, name: []const u16) ?Value {
    if (name.len < 6) return null;
    const prefix = name[0..6];
    if (!nameEql(vm, prefix, S("_level")) and !nameEql(vm, prefix, S("_flash"))) return null;
    const id = parseLevelId(name[6..]);
    if (id == 0) return vm.root_object;
    for (vm.levels.items) |lv| {
        if (lv.id == id) return .{ .object = lv.obj };
    }
    return .undefined_value;
}

/// `_levelN`. Level 0 is the overwhelmingly common case and its name is
/// a static, so only the loaded levels ever allocate.
fn levelName(vm: *Vm, id: i32) []const u16 {
    if (id == 0) return S("_level0");
    var buf: [24]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "_level{d}", .{id}) catch return S("_level0");
    const out = vm.arena().alloc(u16, ascii.len) catch return S("_level0");
    for (ascii, out) |c, *w| w.* = c;
    return out;
}

fn parseLevelId(digits: []const u16) i32 {
    var s = digits;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    var acc: i32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break; // map_while: stop at the first non-digit
        acc = acc *% 10 +% @as(i32, @intCast(c - '0'));
    }
    return if (neg) -acc else acc;
}

fn getTarget(vm: *Vm, t: Target) !Value {
    return .{ .string = try slashPath(vm, t) };
}

/// While a drag is active this is the slash path of the top-most clip
/// under the pointer, excluding the dragged object itself; otherwise "".
/// Below SWF6 the absence reads as undefined rather than "".
fn getDropTarget(vm: *Vm, t: Target) !Value {
    if (vm.swf_version < 6) return .undefined_value;
    return .{ .string = try dropTargetPath(vm, t) };
}

/// The URL the clip's movie was loaded from. Content only ever compares or
/// prints it, and the corpus expects the leading-slash local form
/// ("/test.swf"), so the Player hands us the path it was given.
fn getUrl(vm: *Vm, t: Target) !Value {
    if (t.clip) |c| {
        if (c.loadInfoOf()) |l| return .{ .string = l.url };
    } else if (t.parent()) |p| {
        if (p.loadInfoOf()) |l| return .{ .string = l.url };
    }
    return .{ .string = vm.movie_url };
}

// --- stage globals ---------------------------------------------------------

fn getHighQuality(vm: *Vm, t: Target) !Value {
    _ = t;
    return .{ .number = switch (vm.quality) {
        .best => 2,
        .high => 1,
        else => 0,
    } };
}

fn setHighQuality(vm: *Vm, t: Target, v: Value) !void {
    _ = t;
    if (v == .null_value or v == .undefined_value) return;
    const n = try vm.toNumber(v);
    if (std.math.isNan(n)) return;
    // 0 -> Low, 1 -> High, 2 -> Best, with odd rules for non-integers.
    vm.quality = if (n > 1.5) .best else if (n == 0) .low else .high;
}

fn getQuality(vm: *Vm, t: Target) !Value {
    _ = t;
    return .{ .string = switch (vm.quality) {
        .low => S("LOW"),
        .medium => S("MEDIUM"),
        .high => S("HIGH"),
        .best => S("BEST"),
    } };
}

fn setQuality(vm: *Vm, t: Target, v: Value) !void {
    _ = t;
    const s = try vm.toStringValue(v);
    // Unparseable values leave the quality untouched.
    if (strings.eqlIgnoreCase(s, S("low"))) {
        vm.quality = .low;
    } else if (strings.eqlIgnoreCase(s, S("medium"))) {
        vm.quality = .medium;
    } else if (strings.eqlIgnoreCase(s, S("high"))) {
        vm.quality = .high;
    } else if (strings.eqlIgnoreCase(s, S("best"))) {
        vm.quality = .best;
    }
}

fn getSoundBufTime(vm: *Vm, t: Target) !Value {
    _ = t;
    return .{ .number = @floatFromInt(vm.sound_buf_time) };
}

fn setSoundBufTime(vm: *Vm, t: Target, v: Value) !void {
    _ = t;
    if (v == .null_value or v == .undefined_value) return;
    const n = try vm.toNumber(v);
    if (std.math.isNan(n)) return;
    vm.sound_buf_time = value_mod.clampToI32(n);
}

/// `_focusrect` on a top-level clip is the STAGE's flag; on a nested clip
/// it is the clip's own override, which defaults to null (inherit).
fn refersToStageFocusRect(vm: *Vm, t: Target) bool {
    return vm.swf_version <= 5 or t.parent() == null;
}

fn getFocusRect(vm: *Vm, t: Target) !Value {
    if (refersToStageFocusRect(vm, t)) {
        if (vm.swf_version <= 5) {
            return .{ .number = if (vm.stage_focus_rect) 1 else 0 };
        }
        return .{ .boolean = vm.stage_focus_rect };
    }
    // Per object: an explicit true/false, or null for "not set" — never
    // undefined (ruffle stage_object.rs focus_rect).
    return if (t.obj.focus_rect) |b| .{ .boolean = b } else .null_value;
}

fn setFocusRect(vm: *Vm, t: Target, v: Value) !void {
    if (!refersToStageFocusRect(vm, t)) {
        // Anything but undefined/null pins the object's own setting;
        // those two clear it back to "follow the stage".
        t.obj.focus_rect = if (v == .undefined_value or v == .null_value)
            null
        else
            value_mod.toBoolean(v, vm.swf_version);
        return;
    }
    if (v == .undefined_value or v == .null_value) return;
    const n = if (v == .object) @as(f64, 0) else try vm.toNumber(v);
    if (std.math.isNan(n)) return;
    vm.stage_focus_rect = n != 0;
}

// --- mouse (M4 workstream C) -----------------------------------------------

fn getXMouse(vm: *Vm, t: Target) !Value {
    return .{ .number = localMouse(vm, t)[0] };
}

fn getYMouse(vm: *Vm, t: Target) !Value {
    return .{ .number = localMouse(vm, t)[1] };
}

/// Stage mouse position pushed down into the clip's own space.
/// Ruffle `local_mouse_position` (display_object.rs:1538), step for step.
///
/// The pointer is pushed out to DEVICE PIXELS and back, and every hop
/// lands on integer twips — that round trip is the whole point. It is why
/// `_xmouse` reads as a whole number on an unscaled clip however
/// fractional the clip's own position is: the position is quantised to a
/// device pixel first, and only then pushed into the object's space.
///
/// A singular matrix (a clip scaled to zero) falls back to the IDENTITY,
/// so the reading becomes the device pixel count read as twips — 15.4 for
/// pixel 308 (corpus mouse_pos's `zs`).
fn localMouse(vm: *Vm, t: Target) [2]f64 {
    const M = swf.reader.Matrix;
    const ratio: f32 = @floatCast(vm.view_scale_x);
    const virtual_to_device: M = .{ .a = ratio, .d = ratio };
    const twips_to_pixels: M = .{
        .a = 1.0 / @as(f32, swf.reader.TWIPS_PER_PX),
        .d = 1.0 / @as(f32, swf.reader.TWIPS_PER_PX),
    };

    // The pointer in whole device pixels, via device twips.
    const g = [2]i32{ twipsFromPixels(vm.mouse_x), twipsFromPixels(vm.mouse_y) };
    const dev_twips = virtual_to_device.transformPoint(g[0], g[1]);
    const dev_px = twips_to_pixels.transformPoint(dev_twips[0], dev_twips[1]);

    // Local twips → device pixels, inverted.
    const to_device = virtual_to_device.mul(twips_to_pixels).mul(localToGlobalMatrix(t));
    const inv = to_device.invert() orelse M{};
    const local = inv.transformPoint(dev_px[0], dev_px[1]);
    return .{ pixelsFromTwips(local[0]), pixelsFromTwips(local[1]) };
}

// --- coordinate spaces -------------------------------------------------------

/// The object's own space → stage space: its matrix with every ancestor
/// placement concatenated on the left, the root's included (a script that
/// moved `_root._x` shifts everything under it).
pub fn localToGlobalMatrix(t: Target) swf.reader.Matrix {
    var m = t.obj.matrix;
    var parent = t.parent();
    while (parent) |p| {
        const placement = p.placement orelse break;
        m = placement.matrix.mul(m);
        parent = p.parent;
    }
    return m;
}

/// Stage space → the object's own space. Null when the matrix is singular
/// (a clip scaled to zero), which Flash treats as "nothing maps here".
pub fn globalToLocalMatrix(t: Target) ?swf.reader.Matrix {
    return localToGlobalMatrix(t).invert();
}

// --- clip object model -----------------------------------------------------

/// Lazily create (or fetch) the AVM1 object for a clip. Clip objects double
/// as their timeline's variable scope, so `scope_parent` stays 0 and lookup
/// falls through to _global.
pub fn clipObject(vm: *Vm, mc: *MovieClip) !ObjectHandle {
    // A button's child container has no identity of its own: it IS the
    // button as far as scripts are concerned, which is what makes
    // `_parent` from inside a button the button itself.
    if (mc.owner_button) |obj| return displayObject(vm, obj);
    if (mc.avm_object != 0) return mc.avm_object;
    const h = try vm.objects.create();
    vm.objects.get(h).native = .{ .clip = @ptrCast(mc) };
    mc.avm_object = h;
    // The prototype comes from the clip's OWN movie's environment: a
    // SWF8 movie loaded into `_level2` gets the SWF7+ side's
    // `MovieClip.prototype`, and the SWF6 movie that loaded it cannot
    // reach it by extending its own (corpus
    // loadmovienum_cross_version_prototype).
    const env = envFor(vm, mc);
    vm.objects.get(h).proto = .{
        .object = if (env.movieclip_proto != 0) env.movieclip_proto else env.object_proto,
    };
    return h;
}

fn envFor(vm: *Vm, mc: *MovieClip) *const runtime.Env {
    const v = clipSwfVersion(vm, mc.avm_object) orelse vm.swf_version;
    const hi = v >= 7;
    if (hi == vm.env_hi_active) return vm.activeEnv();
    return if (hi) &vm.env_hi else &vm.env_lo;
}

/// A clip AS A SCRIPT VALUE. SWF4 has no object model, so a clip simply
/// has no value representation there: `trace(a)` and `eval("a:child")`
/// are undefined even though `getProperty("a", _name)` and
/// `tellTarget("a")` resolve the very same path. Internal resolution goes
/// through `clipObject` and is unaffected.
pub fn clipValue(vm: *Vm, mc: *MovieClip) !Value {
    if (vm.swf_version < 5) return .undefined_value;
    if (mc.owner_button) |obj| return displayValue(vm, obj);
    return .{ .object = try clipObject(vm, mc) };
}

/// The clip's children as `for..in` keys. Ruffle appends these AFTER the
/// object's own keys and yields them HIGHEST DEPTH FIRST
/// (stage_object.rs:127-141). Every NAMED child counts, including kinds
/// AVM1 cannot otherwise reach — a MorphShape has no script object but its
/// name still enumerates.
pub fn enumerateKeys(vm: *Vm, handle: ObjectHandle, out: *std.ArrayList([]const u16)) !void {
    const t = targetOf(vm, handle) orelse return;
    const c = containerOf(t) orelse return;
    const kids = c.children.items;
    var i = kids.len;
    while (i > 0) { // children are depth-ascending, so walk back to front
        i -= 1;
        const name = kids[i].name orelse continue;
        try out.append(vm.arena(), name);
    }
}

/// A child AS A SCRIPT VALUE. A child with no script object of its own
/// (graphic, static text, bitmap, morph shape) resolves to its CONTAINER
/// rather than to nothing — ruffle stage_object.rs:32-43. Both name lookup
/// and `getInstanceAtDepth` go through here, which is why
/// `_root.getInstanceAtDepth(<a graphic>)` traces `_level0`.
pub fn childValue(vm: *Vm, container: *MovieClip, child: *DisplayObject) !Value {
    if (!isScriptable(child.kind)) return clipValue(vm, container);
    return displayValue(vm, child);
}

/// The child list a target exposes to scripts: a clip's own, or the
/// button's CURRENT STATE children (ruffle's Avm1Button is a container).
pub fn containerOf(t: Target) ?*MovieClip {
    if (t.clip) |c| return c;
    if (t.obj.kind == .button) return &t.obj.kind.button.container;
    return null;
}

pub fn childByName(mc: *MovieClip, name: []const u16, case_sensitive: bool) ?*DisplayObject {
    for (mc.children.items) |child| {
        const n = child.name orelse continue;
        const hit = if (case_sensitive)
            strings.eql(n, name)
        else
            strings.eqlIgnoreCase(n, name);
        if (hit) return child;
    }
    return null;
}

/// ruffle `stage_object::get_property` — the fallback a clip's ScriptObject
/// consults when it has no binding of its own (script_object.rs:239-247, so
/// ORDINARY PROPERTIES WIN over everything here). In order:
///   1. path properties `_root`/`_parent`/`_global`/`_levelN`
///   2. a child display object by instance name
///   3. the display property table
/// Steps 1 and 3 only fire for names starting with `_`. Null means "not
/// ours" and the caller keeps looking.
pub fn resolveMember(vm: *Vm, handle: ObjectHandle, name: []const u16) !?Value {
    const t = targetOf(vm, handle) orelse return null;
    const magic = name.len > 0 and name[0] == '_';

    if (magic) {
        if (try resolvePathProperty(vm, t, name)) |v| return v;
    }

    // A text field has no children, but it still has `_x` and friends —
    // the child lookup must not short-circuit the property table.
    if (containerOf(t)) |container| {
        if (childByName(container, name, vm.case_sensitive)) |child| {
            return try childValue(vm, container, child);
        }
    }

    if (magic) {
        if (findByName(name)) |index| return try PROPERTIES[index].get(vm, t);
    }
    return null;
}

/// ruffle `resolve_path_property`. SWF4 has none of these; `_global` waits
/// until SWF6. Unlike the display properties, these obey the version's
/// case-sensitivity rule.
pub fn resolvePathProperty(vm: *Vm, t: Target, name: []const u16) !?Value {
    if (vm.swf_version < 5) return null;
    if (nameEql(vm, name, S("_root"))) return try rootValueFor(vm, t);
    if (nameEql(vm, name, S("_parent"))) {
        const parent = t.parent() orelse return .undefined_value;
        return try clipValue(vm, parent);
    }
    if (vm.swf_version >= 6 and nameEql(vm, name, S("_global"))) {
        return .{ .object = vm.globals };
    }
    return parseLevel(vm, name);
}

/// `_root` as seen from `t`: normally the main timeline, but a clip with
/// `_lockroot` set becomes the root for everything inside it — the nearest
/// such ancestor wins (ruffle DisplayObject::avm1_root).
pub fn rootValueFor(vm: *Vm, t: Target) !Value {
    var clip: ?*MovieClip = t.clip orelse t.obj.parent;
    while (clip) |c| {
        if (c.lock_root) return .{ .object = try clipObject(vm, c) };
        // A clip with NO parent is a root in its own right: that is what
        // makes `_root` inside `_level1` mean `_level1` and not the main
        // timeline (ruffle walks `avm1_parent` and stops when there is
        // none — corpus cross_movie_root).
        const parent = c.parent orelse {
            if (c == rootClip(vm)) return vm.root_object;
            return .{ .object = try clipObject(vm, c) };
        };
        clip = parent;
    }
    return vm.root_object;
}

/// The main timeline's clip, or null in pure-VM tests.
fn rootClip(vm: *Vm) ?*MovieClip {
    if (vm.root_object != .object) return null;
    return clipOfHandle(vm, vm.root_object.object);
}

pub fn nameEql(vm: *Vm, a: []const u16, b: []const u16) bool {
    return if (vm.case_sensitive) strings.eql(a, b) else strings.eqlIgnoreCase(a, b);
}

/// True if the write was consumed by a display property. Ruffle's rule
/// (script_object.rs:278-292): display properties beat PROTOTYPE
/// properties but lose to the object's OWN ones.
pub fn assignMember(vm: *Vm, handle: ObjectHandle, name: []const u16, v: Value) !bool {
    const t = targetOf(vm, handle) orelse return false;
    if (vm.objects.hasOwn(handle, name, vm.case_sensitive)) return false;
    const index = findByName(name) orelse return false;
    if (PROPERTIES[index].set) |setter| try setter(vm, t, v);
    return true;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "property table order IS the SWF4 index" {
    // These indices are an ABI: SWF bytecode encodes them numerically.
    const expected = [_][]const u8{
        "_x",         "_y",           "_xscale",  "_yscale",
        "_currentframe", "_totalframes", "_alpha", "_visible",
        "_width",     "_height",      "_rotation", "_target",
        "_framesloaded", "_name",     "_droptarget", "_url",
        "_highquality", "_focusrect", "_soundbuftime", "_quality",
        "_xmouse",    "_ymouse",
    };
    try testing.expectEqual(expected.len, PROPERTIES.len);
    inline for (expected, 0..) |name, i| {
        try testing.expect(strings.eql(PROPERTIES[i].name, S(name)));
    }
    // Lookup is case-insensitive at every version.
    try testing.expectEqual(@as(?usize, 0), findByName(S("_X")));
    try testing.expectEqual(@as(?usize, 19), findByName(S("_Quality")));
    try testing.expectEqual(@as(?usize, null), findByName(S("_nope")));

    // Read-only entries match ruffle's table exactly.
    for ([_]usize{ 4, 5, 11, 12, 14, 15, 20, 21 }) |i| {
        try testing.expect(PROPERTIES[i].isReadOnly());
    }
    for ([_]usize{ 0, 1, 2, 3, 6, 7, 8, 9, 10, 13, 16, 17, 18, 19 }) |i| {
        try testing.expect(!PROPERTIES[i].isReadOnly());
    }
}

test "SetProperty coerces by index even when the write is dropped" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();
    // 0..10 and 12 coerce to number...
    try testing.expectEqual(
        @as(f64, 10),
        (try actionPropertyCoerce(vm, 0, .{ .string = S("10") })).number,
    );
    // ...but an uncoercible value passes through untouched.
    try testing.expect(try actionPropertyCoerce(vm, 0, .undefined_value) == .undefined_value);
    // 13 and 19 coerce to string.
    try testing.expect(strings.eql(
        (try actionPropertyCoerce(vm, 13, .{ .number = 5 })).string,
        S("5"),
    ));
    // Everything else is left alone (_target, _droptarget, _url, _focusrect).
    try testing.expect(try actionPropertyCoerce(vm, 11, .{ .number = 5 }) == .number);
}

test "for..in keys: named children, highest depth first" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();

    var parent = movie_clip.MovieClip.init(&.{});
    // Children here are stack objects, so free only the list itself.
    defer parent.children.deinit(testing.allocator);
    var placement: DisplayObject = .{
        .character_id = 0,
        .depth = 0,
        .kind = .{ .clip = &parent },
        .owns_kind = false,
    };
    parent.placement = &placement;

    var lo: DisplayObject = .{ .character_id = 1, .depth = 1, .name = S("lo"), .kind = .{ .morph_shape = 0 }, .owns_kind = false };
    var anon: DisplayObject = .{ .character_id = 2, .depth = 3, .kind = .{ .morph_shape = 0 }, .owns_kind = false };
    var hi: DisplayObject = .{ .character_id = 3, .depth = 5, .name = S("hi"), .kind = .{ .morph_shape = 0 }, .owns_kind = false };
    try parent.children.append(testing.allocator, &lo);
    try parent.children.append(testing.allocator, &anon);
    try parent.children.append(testing.allocator, &hi);

    const h = try clipObject(vm, &parent);
    var keys: std.ArrayList([]const u16) = .empty;
    defer keys.deinit(vm.arena());
    try enumerateKeys(vm, h, &keys);

    // Highest depth first, and the unnamed child contributes nothing.
    try testing.expectEqual(@as(usize, 2), keys.items.len);
    try testing.expect(strings.eql(keys.items[0], S("hi")));
    try testing.expect(strings.eql(keys.items[1], S("lo")));
}

// --- clip creation / removal (A4) ------------------------------------------

/// Scripts address depth N; the display list stores N + 16384. That offset
/// is what keeps script-created clips above timeline ones, and it doubles
/// as the "was this placed by a script" test — which is why removal needs
/// no separate flag. ruffle avm1/globals.rs:858-872.
pub const AVM_DEPTH_BIAS: i32 = 16384;
const AVM_MAX_DEPTH: i32 = 2130706428;
const AVM_MAX_REMOVE_DEPTH: i32 = 2130706416;

pub fn displayCtxOf(vm: *Vm) ?*movie_clip.Context {
    return displayCtx(vm);
}

fn displayCtx(vm: *Vm) ?*movie_clip.Context {
    const p = vm.display_ctx orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Is this a depth the AVM will place at? Applied to the BIASED value —
/// so a script depth of -16384 (biased 0) is legal while -20000 is not.
/// `createEmptyMovieClip` deliberately skips this; ruffle validates only
/// in attachMovie and clone_sprite.
pub fn depthPlaceable(swf_depth: i32) bool {
    return swf_depth >= 0 and swf_depth <= AVM_MAX_DEPTH;
}

pub fn biasDepth(as_depth: i32) i32 {
    return as_depth +% AVM_DEPTH_BIAS;
}

/// Create a character instance on `parent` at a FINAL display-list depth
/// (already biased by the caller, which is also where validation lives).
/// `char_id == 0` yields an empty clip (createEmptyMovieClip).
pub fn createAt(
    vm: *Vm,
    parent: *MovieClip,
    char_id: u16,
    depth: i32,
    name: []const u16,
    copy_from: ?*const DisplayObject,
    init_object: Value,
) !?*DisplayObject {
    const ctx = displayCtx(vm) orelse return null;
    // The character, and the class registered for it, both come from the
    // PARENT's movie — a script inside a loaded SWF attaching onto
    // `_root` must resolve both against the root's library.
    const outer_movie = ctx.movie;
    ctx.movie = parent.movieOf(ctx);
    defer ctx.movie = outer_movie;
    // Occupying a depth replaces whatever is there (ruffle
    // replace_at_depth), unlike a timeline `.place` which refuses.
    try parent.removeAtDepth(ctx, depth);
    const obj = try parent.instantiateAt(ctx, char_id, depth, 1) orelse return null;
    obj.placed_by_script = true;
    try obj.setName(ctx.gpa, name);
    // Everything a clone inherits must be in place BEFORE the first frame
    // runs — that frame dispatches `load`, and the handler it dispatches
    // is one of the things being copied.
    if (copy_from) |src| {
        obj.matrix = src.matrix;
        obj.color_transform = src.color_transform;
        obj.clip_actions = src.clip_actions;
        // Script-drawn geometry comes across too (clone_sprite:1014-1016),
        // so the clone's `_width` covers the inherited paths as well.
        if (src.kind == .clip and obj.kind == .clip) {
            if (src.kind.clip.drawing) |*d| obj.kind.clip.drawing = try d.clone(ctx.gpa);
        }
    }
    // A registered class replaces the clip's prototype BEFORE its first
    // frame runs, so frame-1 code already sees the class's methods
    // (ruffle construct_as_avm1_object, AVM branch).
    const ctor = ctx.registeredClass(char_id);
    if (ctor != 0 and obj.kind == .clip) {
        const h = try clipObject(vm, obj.kind.clip);
        if (vm.objects.getChained(ctor, S("prototype"), vm.case_sensitive)) |proto| {
            vm.objects.get(h).proto = proto;
        }
    }
    try parent.finishInstantiate(ctx, obj, ctor == 0);
    if (ctor != 0 and obj.kind == .clip) {
        const h = try clipObject(vm, obj.kind.clip);
        // The init object lands BETWEEN the first frame and the
        // constructor. Ruffle reverses ENUMERATION order here, and AVM1
        // enumeration is already reverse-insertion, so a constructed clip
        // sees the keys in insertion order — the opposite of the plain
        // attachMovie case below. Corpus init_object_order pins both.
        try applyInitObject(vm, h, init_object, false);
        try vm.constructOnExisting(ctor, h);
    } else if (init_object == .object) {
        const h = try handleOf(vm, obj);
        try applyInitObject(vm, h, init_object, true);
    }
    return obj;
}

/// `createTextField`'s display-side half: a characterless field placed the
/// way `createAt` places a character, minus everything that needs a
/// library entry (no registered class, no init object, no first frame of
/// its own).
pub fn createTextFieldAt(
    vm: *Vm,
    parent: *MovieClip,
    depth: i32,
    name: []const u16,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) !?*DisplayObject {
    const ctx = displayCtx(vm) orelse return null;
    try parent.removeAtDepth(ctx, depth);
    const obj = try parent.instantiateTextField(ctx, depth, width, height);
    obj.placed_by_script = true;
    obj.matrix.tx = twipsFromPixels(x);
    obj.matrix.ty = twipsFromPixels(y);
    try obj.setName(ctx.gpa, name);
    try parent.finishInstantiate(ctx, obj, false);
    return obj;
}

/// `MovieClip.attachBitmap`: a script `BitmapData` placed at a depth,
/// replacing whatever was there. No character, so nothing to construct.
pub fn attachBitmapAt(
    vm: *Vm,
    parent: *MovieClip,
    data: *const bitmap_data_mod.BitmapData,
    depth: i32,
    smoothing: bool,
) !?*DisplayObject {
    const ctx = displayCtx(vm) orelse return null;
    try parent.removeAtDepth(ctx, depth);
    const obj = try parent.instantiateAttachedBitmap(ctx, depth, data, smoothing);
    obj.placed_by_script = true;
    try parent.finishInstantiate(ctx, obj, false);
    return obj;
}

/// Copy every enumerable key of `init` onto `dest`, in insertion order or
/// its reverse. The order is observable through setters and content depends
/// on it (ruffle movie_clip.rs:2042-2054).
pub fn applyInitObject(vm: *Vm, dest: ObjectHandle, init: Value, reverse: bool) !void {
    if (init != .object) return;
    const src = init.object;
    const n = vm.objects.get(src).props.items.len;
    var i: usize = 0;
    while (i < n and i < vm.objects.get(src).props.items.len) : (i += 1) {
        const idx = if (reverse) n - 1 - i else i;
        const prop = vm.objects.get(src).props.items[idx];
        if (prop.attrs.dont_enum) continue;
        try vm.setProperty(dest, prop.key, prop.value, .{ .object = dest });
    }
}

/// ruffle `clone_sprite` (globals/movie_clip.rs:954-1031): a NEW instance
/// of the source's character on the SOURCE'S PARENT, carrying the source's
/// matrix and colour transform, playing from frame 1. The root cannot be
/// duplicated because it has no parent.
pub fn cloneSprite(vm: *Vm, source: Target, name: []const u16, depth: i32, init_object: Value) !?*DisplayObject {
    const parent = source.parent() orelse return null;
    if (!depthPlaceable(depth)) return null;
    // A dynamically created TEXT FIELD has no character to re-instantiate,
    // and Flash does not copy it: the clone is a FRESH 0x0 field that
    // inherits only the matrix, the colour transform and `editable`
    // (ruffle clone_sprite:982-1023). Its text, bounds, format and every
    // flag start over.
    if (source.obj.character_id == 0 and source.obj.kind == .edit_text) {
        const ctx = displayCtx(vm) orelse return null;
        try parent.removeAtDepth(ctx, depth);
        const obj = try parent.instantiateTextField(ctx, depth, 0, 0);
        obj.placed_by_script = true;
        obj.matrix = source.obj.matrix;
        obj.color_transform = source.obj.color_transform;
        obj.kind.edit_text.read_only = source.obj.kind.edit_text.read_only;
        try obj.setName(ctx.gpa, name);
        try parent.finishInstantiate(ctx, obj, false);
        if (init_object == .object) {
            try applyInitObject(vm, try handleOf(vm, obj), init_object, true);
        }
        return obj;
    }
    // Matrix, colour transform and onClipEvent handlers all come from the
    // source (ruffle clone_sprite:1004-1013).
    return createAt(vm, parent, source.obj.character_id, depth, name, source.obj, init_object);
}

/// The clip's script-drawing store, created on first use. Null when the
/// target is not a MovieClip (shapes and text fields cannot be drawn on).
pub fn drawingOf(vm: *Vm, t: Target) ?*drawing.Drawing {
    const ctx = displayCtx(vm) orelse return null;
    const clip = t.clip orelse return null;
    return clip.drawingMut(ctx.gpa);
}

/// A pixel argument as twips, truncating like `Twips::from_pixels`.
pub fn drawCoord(n: f64) i32 {
    return twipsFromPixels(n);
}

/// ruffle `swap_depths` (globals/movie_clip.rs:1343-1394). The one way a
/// script moves a timeline-placed object into the AS depth range, which is
/// how content makes such an object removable at all. `depth` is the FINAL
/// display-list depth; the caller applies the bias only for the numeric
/// form, since the object form takes the target's depth verbatim.
pub fn swapDepths(vm: *Vm, t: Target, depth: i32) bool {
    _ = displayCtx(vm) orelse return false;
    if (t.obj.removed) return false;
    if (depth < 0 or depth > AVM_MAX_DEPTH) return false;
    const parent = t.parent() orelse return false;
    if (depth == t.obj.depth) return false;
    parent.swapAtDepth(t.obj, depth);
    t.obj.transformed_by_script = true;
    return true;
}

/// ruffle `remove_display_object` (globals.rs:886-897). Only depths in the
/// script range can be removed, which is what stops a script deleting a
/// clip the timeline placed.
pub fn removeDisplayObject(vm: *Vm, t: Target) !bool {
    const ctx = displayCtx(vm) orelse return false;
    const depth: i32 = t.obj.depth;
    if (depth < AVM_DEPTH_BIAS or depth >= AVM_MAX_REMOVE_DEPTH) return false;
    const parent = t.parent() orelse return false;
    try parent.removeAtDepth(ctx, t.obj.depth);
    return true;
}

/// A `DefineSound`'s length in milliseconds, from its sample count and
/// rate — the only thing `attachSound` needs from a sound it cannot yet
/// play. Null when the character is not a sound at all.
pub fn soundDurationMs(vm: *Vm, owner: ?*MovieClip, id: u16) ?f64 {
    const ctx = displayCtx(vm) orelse return null;
    const movie = if (owner) |c| c.movieOf(ctx) else ctx.movie;
    const ch = movie.lib.characters.get(id) orelse return null;
    const snd = switch (ch) {
        .sound => |s| s,
        else => return null,
    };
    if (snd.format.sample_rate == 0) return null;
    const n: f64 = @floatFromInt(snd.num_samples);
    const r: f64 = @floatFromInt(snd.format.sample_rate);
    return @round(n * 1000.0 / r);
}

/// ExportAssets name -> character id. The library stores the raw SWF bytes,
/// so the UCS-2 argument comes back down to UTF-8 first.
pub fn exportedCharacter(vm: *Vm, owner: ?*MovieClip, name: []const u16) !?u16 {
    const ctx = displayCtx(vm) orelse return null;
    // The TARGET clip's movie decides which library is searched — a
    // script inside a loaded SWF calling `_root.attachMovie` must find
    // the ROOT's exports, not its own.
    const movie = if (owner) |c| c.movieOf(ctx) else ctx.movie;
    const utf8 = strings.toUtf8(vm.arena(), name) catch return null;
    if (movie.lib.exports.get(utf8)) |id| return id;
    // Export names are matched case-INSENSITIVELY at every SWF version
    // (ruffle instantiate_by_export_name passes case_sensitive = false),
    // so `attachMovie("cLiP", ...)` finds the asset exported as "clip".
    var it = movie.lib.exports.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, utf8)) return e.value_ptr.*;
    }
    return null;
}

/// The DoAction bytecodes on a clip's 1-based frame. `Call` runs these
/// INLINE, where the timeline queues them (movie_clip.zig executeFrame).
pub fn frameActions(clip: *MovieClip, frame: u16, out: *std.ArrayList([]const u8), a: std.mem.Allocator) !void {
    if (frame == 0 or frame > clip.frames.len) return;
    for (clip.frames[frame - 1].controls) |control| {
        if (control == .do_action) try out.append(a, control.do_action);
    }
}

// --- timeline control (shared by the SWF4 opcodes and the methods) ----------

/// How ActionScript spells a frame: a direct 1-based index, or a label.
pub const FrameArg = union(enum) { number: i32, label: strings.AvmString };

/// The gotoAndPlay/gotoAndStop/GotoFrame2 operand rule, in one place so the
/// opcode and the prototype methods cannot drift. Only an INTEGER number is
/// a direct index; anything else stringifies and is treated as a label —
/// unless the whole string parses as a number, which is how
/// `gotoAndPlay("3")` reaches frame 3 while `gotoAndPlay("3x")` looks for a
/// label. ruffle globals/movie_clip.rs goto_frame:1109-1157.
/// A NUMBER operand is a frame index only when it is a whole number:
/// ruffle's arm is `Value::Number(n) if n.fract() == 0.0`, and everything
/// else — including 4.123 — falls through to the variable-path branch,
/// where the dot splits it into the target path "4" and the variable
/// "123" and the goto quietly does nothing (corpus goto_frame2).
pub fn frameArg(vm: *Vm, v: Value) !FrameArg {
    if (v == .number and std.math.isFinite(v.number) and @rem(v.number, 1) == 0) {
        return .{ .number = value_mod.toInt32(v.number) };
    }
    if (v == .number) return .{ .label = try vm.toStringValue(v) };
    const s = try vm.toStringValue(v);
    if (strictFrameNumber(s)) |n| return .{ .number = n };
    return .{ .label = s };
}

/// A string operand is a frame NUMBER only when the whole string parses;
/// ruffle uses Rust's strict `parse()` here, so "3x" is a label.
pub fn strictFrameNumber(s: strings.AvmString) ?i32 {
    if (s.len == 0 or s.len > 32) return null;
    var buf: [32]u8 = undefined;
    for (s, 0..) |c, i| {
        if (c > 0x7F) return null;
        buf[i] = @intCast(c);
    }
    const n = std.fmt.parseFloat(f64, buf[0..s.len]) catch return null;
    return value_mod.toInt32(n);
}

pub fn hostGoto(vm: *Vm, clip: *MovieClip, frame: u16, play: bool) void {
    const host = vm.host;
    if (host.goto_frame) |f| f(host.ctx.?, @ptrCast(clip), frame, play);
}

pub fn hostGotoLabel(vm: *Vm, clip: *MovieClip, label: strings.AvmString, play: bool) bool {
    const host = vm.host;
    const f = host.goto_label orelse return false;
    return f(host.ctx.?, @ptrCast(clip), label, play);
}

pub fn hostSetPlaying(vm: *Vm, clip: *MovieClip, playing: bool) void {
    const host = vm.host;
    if (host.set_playing) |f| f(host.ctx.?, @ptrCast(clip), playing);
}

pub fn hostNextPrev(vm: *Vm, clip: *MovieClip, delta: i2) void {
    const host = vm.host;
    if (host.next_prev) |f| f(host.ctx.?, @ptrCast(clip), delta);
}

/// Goto a 1-based frame INDEX. `scene_offset` is GotoFrame2's; the
/// prototype methods pass 0.
///
/// The arithmetic looks pointless and is not: ruffle goes 1-based → 0-based
/// → back with WRAPPING subtract, WRAPPING add and SATURATING add, then
/// TRUNCATES to u16. That is what turns `gotoAndPlay(2147483648)` — which
/// ToInt32 makes -2147483648, seemingly a no-op — into frame 65535, and
/// thence into the last frame. `gotoAndPlay(-2147483647)` really does stay
/// put. Corpus goto_methods pins every one of these.
pub fn gotoFrameNumber(vm: *Vm, clip: *MovieClip, n: i32, scene_offset: u16, play: bool) void {
    var f = n -% 1;
    f = f +% @as(i32, scene_offset);
    f = if (f == std.math.maxInt(i32)) f else f + 1;
    if (f > 0) hostGoto(vm, clip, @truncate(@as(u32, @bitCast(f))), play);
}

// --- viewport ----------------------------------------------------------------

/// Rebuild the stage→viewport matrix and the stage size from the current
/// scale mode. Returns whether the STAGE SIZE changed, which is what makes
/// `Stage.onResize` fire (ruffle Stage::build_matrices).
pub fn recomputeView(vm: *Vm) bool {
    const mw = vm.movie_width;
    const mh = vm.movie_height;
    if (mw <= 0 or mh <= 0) return false;
    const vw: f64 = @floatFromInt(vm.viewport_width);
    const vh: f64 = @floatFromInt(vm.viewport_height);
    switch (vm.stage_scale_mode) {
        0 => { // showAll: fit inside, letterboxed
            const s = @min(vw / mw, vh / mh);
            vm.view_scale_x = s;
            vm.view_scale_y = s;
        },
        1 => { // noBorder: fill, cropping
            const s = @max(vw / mw, vh / mh);
            vm.view_scale_x = s;
            vm.view_scale_y = s;
        },
        2 => { // exactFit: stretch
            vm.view_scale_x = vw / mw;
            vm.view_scale_y = vh / mh;
        },
        3 => { // noScale: device pixels, HiDPI aside
            vm.view_scale_x = vm.viewport_scale;
            vm.view_scale_y = vm.viewport_scale;
        },
    }
    vm.view_tx = (vw - mw * vm.view_scale_x) / 2;
    vm.view_ty = (vh - mh * vm.view_scale_y) / 2;

    const old_w = vm.stage_width;
    const old_h = vm.stage_height;
    if (vm.stage_scale_mode == 3) {
        vm.stage_width = @intFromFloat(@round(vw / vm.viewport_scale));
        vm.stage_height = @intFromFloat(@round(vh / vm.viewport_scale));
    } else {
        vm.stage_width = @intFromFloat(mw);
        vm.stage_height = @intFromFloat(mh);
    }
    return old_w != vm.stage_width or old_h != vm.stage_height;
}

/// A pointer position in VIEWPORT pixels, in stage pixels.
pub fn viewportToStage(vm: *Vm, x: f64, y: f64) [2]f64 {
    if (vm.view_scale_x == 0 or vm.view_scale_y == 0)
        return .{ x + vm.stage_origin_x, y + vm.stage_origin_y };
    return .{
        (x - vm.view_tx) / vm.view_scale_x + vm.stage_origin_x,
        (y - vm.view_ty) / vm.view_scale_y + vm.stage_origin_y,
    };
}

// --- focus -------------------------------------------------------------------

/// Can this object take focus? Ruffle's `is_focusable`: interactive
/// objects can by default, a MovieClip only when it is in button mode or
/// has `focusEnabled` set, and the root never can
/// (movie_clip.rs:3244-3252).
pub fn isFocusable(vm: *Vm, handle: ObjectHandle) bool {
    const t = targetOf(vm, handle) orelse return false;
    const clip = t.clip orelse return true; // buttons and text fields
    if (clip.parent == null) return false; // the root movie
    const ctx = displayCtx(vm) orelse return false;
    if (@import("../display/mouse.zig").isButtonMode(ctx, clip)) return true;
    const v = vm.objects.getChained(handle, S("focusEnabled"), vm.case_sensitive) orelse
        return false;
    return value_mod.toBoolean(v, vm.swf_version);
}

/// Move the focus, firing the three handlers in ruffle's order: the old
/// object's `onKillFocus`, the new object's `onSetFocus`, then the
/// `Selection` listeners (focus_tracker.rs set_internal). All three run
/// INLINE — focus handlers are not queued.
pub fn setFocus(vm: *Vm, new: ObjectHandle) anyerror!void {
    return setFocusEx(vm, new, false);
}

/// What moved the focus. Only a KEY or a script selects the whole text of
/// the field it lands on; a MOUSE places a caret instead (ruffle
/// `update_edittext_selection`, deliberately not called by
/// `set_by_mouse`).
pub const FocusCause = enum { script, key, mouse };

/// `run_now` runs the roll events synchronously — what a Tab does, where
/// a programmatic `Selection.setFocus` leaves them queued.
pub fn setFocusEx(vm: *Vm, new: ObjectHandle, run_now: bool) anyerror!void {
    return setFocusBy(vm, new, run_now, if (run_now) .key else .script);
}

pub fn setFocusBy(vm: *Vm, new: ObjectHandle, run_now: bool, cause: FocusCause) anyerror!void {
    const old = vm.focus;
    // The HOVER follows the focus, and the roll events it fires are
    // QUEUED here — synchronous only when the move came from a key
    // (focus_tracker.rs:144-157). Before the focus itself changes, so a
    // handler sees the old one, exactly as ruffle orders it.
    // Note there is no "same object" shortcut: re-focusing what is
    // already focused still rolls out and back over it.
    if (vm.host.focus_roll) |f| {
        const t = if (new != 0) targetOf(vm, new) else null;
        f(vm.host.ctx.?, if (t) |tt| @ptrCast(tt.obj) else null, run_now);
    }
    if (old == new) {
        // The selection is refreshed even when the focus did not move —
        // re-focusing a field re-selects all of it.
        selectAllOnFocus(vm, new, cause);
        return;
    }
    vm.focus = new;
    // Losing focus COMMITS any IME composition and then clears the
    // selection, whatever moved the focus. Both happen BEFORE the
    // handlers run, as they do in ruffle's set_internal.
    if (old != 0) {
        if (targetOf(vm, old)) |t| {
            if (t.obj.kind == .edit_text) {
                if (displayCtx(vm)) |ctx| {
                    const changed = t.obj.kind.edit_text.imeCommit(ctx.gpa) catch false;
                    if (changed) try fieldEdited(vm, t.obj);
                }
                t.obj.kind.edit_text.setSelection(null);
            }
        }
    }
    // The highlight follows the focus (focus_tracker.rs update_highlight).
    vm.focus_highlight = new != 0;

    const old_v: Value = if (old != 0) .{ .object = old } else .null_value;
    const new_v: Value = if (new != 0) .{ .object = new } else .null_value;
    if (old != 0) try callFocusHandler(vm, old, S("onKillFocus"), new_v);
    if (new != 0) try callFocusHandler(vm, new, S("onSetFocus"), old_v);
    if (vm.selection_object != 0) {
        _ = @import("globals/singletons.zig").broadcast(
            vm,
            .{ .object = vm.selection_object },
            S("onSetFocus"),
            &.{ old_v, new_v },
        ) catch {};
    }
    selectAllOnFocus(vm, new, cause);
}

fn selectAllOnFocus(vm: *Vm, new: ObjectHandle, cause: FocusCause) void {
    if (cause == .mouse or new == 0) return;
    const t = targetOf(vm, new) orelse return;
    if (t.obj.kind != .edit_text) return;
    const et = t.obj.kind.edit_text;
    et.setSelection(.{ .from = 0, .to = et.text.items.len });
}

/// Is the focus highlight actually SHOWING? Being active is not enough:
/// `_focusrect` (the object's own from SWF6, the stage's otherwise) can
/// leave it active-but-hidden, and the keyboard's press simulation needs
/// the VISIBLE state, not the active one (ruffle `calculate_highlight` /
/// `is_highlight_enabled`).
///
/// A text field cannot render a highlight at all, so it is never visible.
pub fn highlightVisible(vm: *Vm) bool {
    if (!vm.focus_highlight or vm.focus == 0) return false;
    const t = targetOf(vm, vm.focus) orelse return false;
    if (t.obj.kind == .edit_text) return false;
    if (vm.swf_version >= 6) {
        if (t.obj.focus_rect) |b| return b;
    }
    return vm.stage_focus_rect;
}

/// A click landed on `obj` at `index`: if the character there carries an
/// `asfunction:` URL, call what it names.
///
/// The address is split at the FIRST comma only, so
/// `asfunction:f,a,b,c` passes ONE argument, the string "a,b,c".
/// Anything else — a real URL, `event:` — needs a navigator we do not
/// have (M5), and is ignored rather than guessed at.
fn followLink(vm: *Vm, obj: *DisplayObject, index: usize) !void {
    const et = obj.kind.edit_text;
    const url = et.urlAt(index) orelse return;
    const prefix = S("asfunction:");
    if (url.len < prefix.len or !strings.eql(url[0..prefix.len], prefix)) return;
    const address = url[prefix.len..];
    if (address.len == 0) return;

    const timeline = obj.parent orelse return;
    const start = try clipObject(vm, timeline);
    const comma = std.mem.indexOfScalar(u16, address, ',');
    if (comma) |c| {
        const arg_str = try vm.arena().dupe(u16, address[c + 1 ..]);
        try @import("activation.zig").Activation.callNamed(vm, start, address[0..c], &.{.{ .string = arg_str }});
    } else {
        try @import("activation.zig").Activation.callNamed(vm, start, address, &.{});
    }
}

/// A field's text changed from the ENGINE side (an IME commit, typing):
/// push the variable binding and broadcast `onChanged` from the field.
pub fn fieldEdited(vm: *Vm, obj: *DisplayObject) !void {
    try @import("text_binding.zig").propagate(vm, obj);
    const h = try handleOf(vm, obj);
    _ = @import("globals/singletons.zig").broadcast(
        vm,
        .{ .object = h },
        S("onChanged"),
        &.{.{ .object = h }},
    ) catch {};
}

/// Extend a field's selection to the pointer. Called while the pointer
/// is DOWN on it: the anchor is where the click landed and the caret
/// follows the drag, so dragging right to left leaves `to` below `from`.
pub fn dragSelect(vm: *Vm, obj: *DisplayObject) void {
    if (obj.kind != .edit_text) return;
    const et = obj.kind.edit_text;
    if (!et.selectable) return;
    const anchor = et.click_anchor orelse return;
    const t: Target = .{ .obj = obj, .clip = null };
    syncField(vm, t);
    const p = localMouse(vm, t);
    const idx = et.positionToIndex(.{ twipsFromPixels(p[0]), twipsFromPixels(p[1]) }) orelse return;
    et.setSelection(.{ .from = anchor, .to = idx });
}

/// The field that currently has the focus, or null.
pub fn focusedField(vm: *Vm) ?*@import("../display/edit_text.zig").EditText {
    if (vm.focus == 0) return null;
    const t = targetOf(vm, vm.focus) orelse return null;
    if (t.obj.kind != .edit_text) return null;
    return t.obj.kind.edit_text;
}

/// A click focuses only a field that is editable or selectable; anything
/// else clears the focus, but only when what was focused was itself
/// mouse-focusable (ruffle `update_focus_on_mouse_press`).
pub fn focusByMousePress(vm: *Vm, obj: ?*DisplayObject) anyerror!void {
    // A LINK is followed on press whatever the field's selectability —
    // that is the only thing a non-selectable field reacts to at all.
    if (obj) |o| {
        if (o.kind == .edit_text) {
            syncField(vm, .{ .obj = o, .clip = null });
            const p = localMouse(vm, .{ .obj = o, .clip = null });
            const at = o.kind.edit_text.positionToIndex(
                .{ twipsFromPixels(p[0]), twipsFromPixels(p[1]) },
            );
            if (at) |idx| try followLink(vm, o, idx);
        }
    }
    const focusable = blk: {
        const o = obj orelse break :blk false;
        if (o.kind != .edit_text) break :blk false;
        const et = o.kind.edit_text;
        break :blk !et.read_only or et.selectable;
    };
    if (focusable) {
        const h = try handleOf(vm, obj.?);
        try setFocusBy(vm, h, false, .mouse);
        // The click also places the CARET — that is the whole reason a
        // mouse focus does not select the field.
        const et = obj.?.kind.edit_text;
        if (et.selectable) {
            syncField(vm, .{ .obj = obj.?, .clip = null });
            const t: Target = .{ .obj = obj.?, .clip = null };
            const p = localMouse(vm, t);
            const idx = et.positionToIndex(.{ twipsFromPixels(p[0]), twipsFromPixels(p[1]) }) orelse
                et.text.items.len;
            et.setSelection(@import("../display/edit_text.zig").Selection.at(idx));
            et.click_anchor = idx;
        }
        return;
    }
    if (focusedField(vm)) |et| {
        if (!et.read_only or et.selectable) try setFocusBy(vm, 0, false, .mouse);
    }
}

fn callFocusHandler(vm: *Vm, handle: ObjectHandle, name: []const u16, other: Value) !void {
    const f = vm.objects.getChained(handle, name, vm.case_sensitive) orelse return;
    if (!vm.isCallable(f)) return;
    _ = vm.callFunction(f, .{ .object = handle }, &.{other}) catch {};
}

/// Drop the focus if it is on `obj` (or anything inside it) — removal and
/// hiding both do this (ruffle `drop_focus`).
pub fn dropFocusIf(vm: *Vm, obj: *DisplayObject) anyerror!void {
    if (vm.focus == 0) return;
    const t = targetOf(vm, vm.focus) orelse {
        vm.focus = 0;
        return;
    };
    var cur: ?*DisplayObject = t.obj;
    while (cur) |o| {
        if (o == obj) return setFocus(vm, 0);
        const parent = o.parent orelse break;
        cur = parent.placement;
    }
}

/// Does this object have the keyboard focus, highlight and all? Only then
/// do its `onKeyDown`/`onKeyUp` handlers run.
pub fn hasKeyFocus(vm: *Vm, obj: *DisplayObject) bool {
    if (vm.focus == 0 or !vm.focus_highlight) return false;
    const t = targetOf(vm, vm.focus) orelse return false;
    return t.obj == obj;
}

/// `Selection.getFocus()` — the focused object's PATH, or null.
pub fn focusPath(vm: *Vm) !Value {
    if (vm.focus == 0) return .null_value;
    if (targetOf(vm, vm.focus) == null) return .null_value;
    return .{ .string = try vm.toStringValue(.{ .object = vm.focus }) };
}

// --- movie facts -------------------------------------------------------------

/// `getBytesTotal`: the file's declared uncompressed length for the root,
/// the clip's own DefineSprite tag stream otherwise (ruffle
/// MovieClip::total_bytes). A scripted empty clip has neither, hence 0.
pub fn bytesTotal(vm: *Vm, clip: *MovieClip) f64 {
    // A runtime load answers with the FILE it brought — for an image
    // that is the only size there is.
    if (clip.loadInfoOf()) |l| return if (l.failed) -1 else @floatFromInt(l.bytes);
    if (clip.parent == null) {
        const ctx = displayCtx(vm) orelse return 0;
        return @floatFromInt(ctx.root_movie.file_length);
    }
    return @floatFromInt(clip.tag_stream_len);
}

/// Every movie is local and fully present, so loaded == total.
pub fn bytesLoaded(vm: *Vm, clip: *MovieClip) f64 {
    // A FAILED load has loaded nothing, which is 0 — only the TOTAL
    // reports the -1 that says "there is no movie here".
    if (clip.loadInfoOf()) |l| {
        if (l.failed) return 0;
    }
    return bytesTotal(vm, clip);
}

// --- bounds ------------------------------------------------------------------

/// Two different "no bounds" markers, and the corpus tells them apart.
///
/// `Rectangle::INVALID` — 0x7ffffff twips, 6710886.35 px — is what ruffle
/// stores for an object with no geometry, and it is returned VERBATIM when
/// the measurement is in the object's own space. Push it through a
/// coordinate change and, once `use_new_invalid_bounds_value` has latched,
/// the answer becomes 0x8000000 (6710886.4) instead. `movieclip_default_
/// state` prints both, one line apart, so neither can be collapsed into
/// zeroes.
const INVALID_TWIPS: i32 = 0x7ffffff;
const NEW_INVALID_TWIPS: i32 = 0x8000000;

const INVALID_RECT: swf.reader.Rectangle = .{
    .xmin = INVALID_TWIPS,
    .xmax = INVALID_TWIPS,
    .ymin = INVALID_TWIPS,
    .ymax = INVALID_TWIPS,
};

/// Latch ruffle's `use_new_invalid_bounds_value`. It flips the first time
/// getBounds/getRect runs with a SWF8+ activation OR under a SWF8+ root
/// movie, and never flips back.
fn latchInvalidBounds(vm: *Vm) void {
    if (vm.use_new_invalid_bounds) return;
    if (vm.swf_version >= 8 or vm.root_swf_version >= 8) vm.use_new_invalid_bounds = true;
}

/// `getBounds(target)` as a plain object with xMin/xMax/yMin/yMax in
/// pixels. `getRect` shares this: it is documented to exclude stroke
/// widths, but ruffle defers to getBounds and so does the recorded Flash
/// output for movieclip_default_state, so a separate edge-bounds path
/// would be inventing a difference nothing measures.
///
/// The transform is deliberately AABB-of-AABB — ruffle notes Flash
/// transforms the already-axis-aligned box into the target's space rather
/// than re-fitting the geometry, so a rotated clip reports a looser box
/// than a direct `bounds_with_transform` would give.
pub fn boundsObject(vm: *Vm, t: Target, target: ?Target) !Value {
    latchInvalidBounds(vm);
    const same_space = if (target) |o| o.obj == t.obj else true;
    var box: swf.reader.Rectangle = bounds_mod.ownBounds(t.obj) orelse INVALID_RECT;
    if (!same_space) {
        const to_global = localToGlobalMatrix(t);
        const to_target = globalToLocalMatrix(target.?) orelse swf.reader.Matrix.identity;
        // Transforming an invalid box yields an invalid box (ruffle's
        // `Matrix * Rectangle` short-circuits on `!is_valid()`).
        const transformed = if (isInvalid(box)) INVALID_RECT else to_target.mul(to_global).transformRect(box);
        if (vm.use_new_invalid_bounds and isInvalid(box) and isInvalid(transformed)) {
            box = .{
                .xmin = NEW_INVALID_TWIPS,
                .xmax = NEW_INVALID_TWIPS,
                .ymin = NEW_INVALID_TWIPS,
                .ymax = NEW_INVALID_TWIPS,
            };
        } else {
            box = transformed;
        }
    }
    const h = try vm.newObject();
    try vm.objects.put(h, S("xMin"), .{ .number = pixelsFromTwips(box.xmin) }, vm.case_sensitive);
    try vm.objects.put(h, S("xMax"), .{ .number = pixelsFromTwips(box.xmax) }, vm.case_sensitive);
    try vm.objects.put(h, S("yMin"), .{ .number = pixelsFromTwips(box.ymin) }, vm.case_sensitive);
    try vm.objects.put(h, S("yMax"), .{ .number = pixelsFromTwips(box.ymax) }, vm.case_sensitive);
    return .{ .object = h };
}

/// Ruffle's `is_valid` tests only `x_min` against the sentinel.
fn isInvalid(r: swf.reader.Rectangle) bool {
    return r.xmin == INVALID_TWIPS;
}

// --- hit testing --------------------------------------------------------------

/// `hitTest(x, y[, shapeFlag])`. Despite the docs, x/y are in the AVM1
/// ROOT's space, not the stage's — a script that moved `_root._x` moves the
/// coordinate system with it (ruffle hit_test's comment).
pub fn hitTestPoint(vm: *Vm, t: Target, x_px: f64, y_px: f64, shape_flag: bool) bool {
    var gx = twipsFromPixels(x_px);
    var gy = twipsFromPixels(y_px);
    if (targetOfValue(vm, vm.root_object)) |root| {
        const p = localToGlobalMatrix(root).transformPoint(gx, gy);
        gx = p[0];
        gy = p[1];
    }
    const parent_to_global = parentToGlobalMatrix(t);
    if (shape_flag) {
        const l: ?*const @import("../display/library.zig").Library =
            if (displayCtx(vm)) |c| &c.movie.lib else null;
        return bounds_mod.hitTestShape(t.obj, .{ gx, gy }, parent_to_global, l);
    }
    return bounds_mod.hitTestBounds(t.obj, .{ gx, gy }, parent_to_global);
}

/// `hitTest(otherClip)` — bounding boxes overlapping in stage space.
pub fn hitTestObject(a: Target, b: Target) bool {
    const ba = bounds_mod.boundsWithTransform(a.obj, localToGlobalMatrix(a)) orelse return false;
    const bb = bounds_mod.boundsWithTransform(b.obj, localToGlobalMatrix(b)) orelse return false;
    return bounds_mod.intersects(ba, bb);
}

/// The object's colour transform with every ancestor's applied on top of
/// it — what `Transform.concatenatedColorTransform` reports. Composition is
/// parent-then-child and does NOT clamp the offsets.
pub fn concatenatedColorTransform(t: Target) swf.reader.ColorTransform {
    var ct = t.obj.color_transform;
    var parent = t.parent();
    while (parent) |p| {
        const placement = p.placement orelse break;
        ct = placement.color_transform.concat(ct);
        parent = p.parent;
    }
    return ct;
}

/// Bounds in STAGE space, children included.
pub fn worldBounds(t: Target) ?swf.reader.Rectangle {
    return bounds_mod.boundsWithTransform(t.obj, localToGlobalMatrix(t));
}

/// The object's PARENT space → stage space (its own matrix excluded).
pub fn parentToGlobalMatrix(t: Target) swf.reader.Matrix {
    var m: swf.reader.Matrix = .identity;
    var parent = t.parent();
    while (parent) |p| {
        const placement = p.placement orelse break;
        m = placement.matrix.mul(m);
        parent = p.parent;
    }
    return m;
}

// --- dragging ------------------------------------------------------------------

/// `startDrag(lockCenter, l, t, r, b)`. The constraint rectangle arrives in
/// the PARENT's coordinate space, in pixels, and is stored in twips.
pub fn startDrag(vm: *Vm, t: Target, lock_center: bool, rect: ?[4]f64) void {
    var d: runtime.Drag = .{
        .target = t.obj.avm_object,
        .lock_center = lock_center,
    };
    if (t.clip) |c| d.target = c.avm_object;
    if (rect) |r| d.bounds = .{
        .xmin = twipsFromPixels(@min(r[0], r[2])),
        .ymin = twipsFromPixels(@min(r[1], r[3])),
        .xmax = twipsFromPixels(@max(r[0], r[2])),
        .ymax = twipsFromPixels(@max(r[1], r[3])),
    };
    if (!lock_center) {
        // Keep the grab offset: where the pointer sits relative to the
        // object's origin, both expressed in the parent's space.
        const inv = parentToGlobalMatrix(t).invert() orelse swf.reader.Matrix.identity;
        const p = inv.transformPoint(twipsFromPixels(vm.mouse_x), twipsFromPixels(vm.mouse_y));
        d.offset_x = t.obj.matrix.tx - p[0];
        d.offset_y = t.obj.matrix.ty - p[1];
    }
    vm.drag = d;
    applyDrag(vm);
}

pub fn stopDrag(vm: *Vm) void {
    vm.drag = null;
}

/// Move the dragged object to follow the pointer. Called by the Player on
/// every mouse move and once at startDrag, so a drag started with the
/// pointer already elsewhere snaps immediately.
pub fn applyDrag(vm: *Vm) void {
    const d = vm.drag orelse return;
    const t = targetOf(vm, d.target) orelse {
        // The dragged clip went away; Flash drops the drag with it.
        vm.drag = null;
        return;
    };
    const inv = parentToGlobalMatrix(t).invert() orelse return;
    const p = inv.transformPoint(twipsFromPixels(vm.mouse_x), twipsFromPixels(vm.mouse_y));
    var x = p[0] + d.offset_x;
    var y = p[1] + d.offset_y;
    if (d.bounds) |b| {
        x = std.math.clamp(x, b.xmin, b.xmax);
        y = std.math.clamp(y, b.ymin, b.ymax);
    }
    t.obj.setX(x);
    t.obj.setY(y);
    // `_droptarget` is recomputed HERE, while the drag is live, and the
    // answer sticks to the clip afterwards (ruffle player.rs:1505-1518).
    vm.drop_target = .{
        .clip = if (t.clip) |c| @ptrCast(c) else null,
        .path = computeDropTarget(vm) catch S(""),
    };
}

fn computeDropTarget(vm: *Vm) ![]const u16 {
    const root = targetOfValue(vm, vm.root_object) orelse return S("");
    const rc = root.clip orelse return S("");
    const gx = twipsFromPixels(vm.mouse_x);
    const gy = twipsFromPixels(vm.mouse_y);
    const found = topmostUnder(vm, rc, .{ gx, gy }, localToGlobalMatrix(root)) orelse return S("");
    return slashPath(vm, found);
}

/// Is `obj` the object currently being dragged (or inside it)? `_droptarget`
/// must not report the thing in your hand.
fn insideDrag(vm: *Vm, obj: *DisplayObject) bool {
    const d = vm.drag orelse return false;
    const t = targetOf(vm, d.target) orelse return false;
    if (t.obj == obj) return true;
    var p = obj.parent;
    while (p) |parent| {
        if (parent.placement == t.obj) return true;
        p = parent.parent;
    }
    return false;
}

/// The slash path of the top-most clip under the pointer, excluding the
/// dragged object itself — what `_droptarget` reports while a drag is
/// active. Empty string when nothing is under it.
pub fn dropTargetPath(vm: *Vm, t: Target) ![]const u16 {
    const clip = t.clip orelse return S("");
    const stored = vm.drop_target.clip orelse return S("");
    if (@as(*anyopaque, @ptrCast(clip)) != stored) return S("");
    return vm.drop_target.path;
}

/// Depth-first, back to front, so the LAST match wins — that is the one
/// drawn on top.
fn topmostUnder(vm: *Vm, container: *MovieClip, point: [2]i32, to_global: swf.reader.Matrix) ?Target {
    var best: ?Target = null;
    const lib: ?*const @import("../display/library.zig").Library =
        if (displayCtx(vm)) |c| &c.movie.lib else null;
    for (container.children.items) |child| {
        if (insideDrag(vm, child)) continue;
        if (child.kind == .clip) {
            const child_to_global = to_global.mul(child.matrix);
            // The INNERMOST clip wins: a nested clip's own pick is the
            // answer, and its container only stands in when the recursion
            // found nothing (corpus drag_drop's /drop2/drop3).
            if (topmostUnder(vm, child.kind.clip, point, child_to_global)) |inner| {
                best = inner;
            } else if (bounds_mod.hitTestShape(child, point, to_global, lib)) {
                best = .{ .obj = child, .clip = child.kind.clip };
            }
        } else if (bounds_mod.hitTestShape(child, point, to_global, lib)) {
            // Only CLIPS can be drop targets; a bare shape reports its
            // container instead (ruffle drop_target is a MovieClip).
            best = .{ .obj = container.placement orelse continue, .clip = container };
        }
    }
    return best;
}

/// A frame LABEL on a clip, case-insensitively (labels are ASCII in
/// practice; `labelToNumber` already folds case).
pub fn frameLabel(vm: *Vm, clip: *MovieClip, label: []const u16) ?u16 {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (label) |c| {
        if (n >= buf.len or c > 0x7F) return null;
        buf[n] = @intCast(c);
        n += 1;
    }
    _ = vm;
    return clip.labelToNumber(buf[0..n]);
}
