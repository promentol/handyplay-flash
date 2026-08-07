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

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const DisplayObject = display_object.DisplayObject;
const MovieClip = movie_clip.MovieClip;
const S = strings.ascii;

const twipsFromPixels = display_object.twipsFromPixels;
const pixelsFromTwips = display_object.pixelsFromTwips;

/// A clip plus the placement that carries its transform. The root's
/// placement is owned by the Player; every other clip's by its parent.
pub const Target = struct {
    clip: *MovieClip,
    obj: *DisplayObject,
};

/// Unwrap an AVM1 object handle to a display target. Null when the handle
/// is not a clip, or when the clip has been removed from the display list
/// (ruffle avm1_removed — a retained reference reads as undefined).
pub fn targetOf(vm: *Vm, handle: ObjectHandle) ?Target {
    if (handle == 0) return null;
    const native = vm.objects.get(handle).native;
    if (native != .clip) return null;
    const mc: *MovieClip = @ptrCast(@alignCast(native.clip));
    if (mc.removed) return null;
    return .{ .clip = mc, .obj = mc.placement orelse return null };
}

pub fn targetOfValue(vm: *Vm, v: Value) ?Target {
    return if (v == .object) targetOf(vm, v.object) else null;
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

fn getX(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = pixelsFromTwips(t.obj.matrix.tx) };
}

fn setX(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    // Both infinities land on -inf, which twipsFromPixels saturates.
    t.obj.setX(twipsFromPixels(if (std.math.isInf(n)) -std.math.inf(f64) else n));
}

fn getY(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = pixelsFromTwips(t.obj.matrix.ty) };
}

fn setY(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    t.obj.setY(twipsFromPixels(if (std.math.isInf(n)) -std.math.inf(f64) else n));
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
    _ = vm;
    const b = bounds_mod.localBounds(t.obj) orelse return .{ .number = 0 };
    return .{ .number = pixelsFromTwips(b.width()) };
}

fn getHeight(vm: *Vm, t: Target) !Value {
    _ = vm;
    const b = bounds_mod.localBounds(t.obj) orelse return .{ .number = 0 };
    return .{ .number = pixelsFromTwips(b.height()) };
}

fn setWidth(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
    setSizeAlong(t, n, .width);
}

fn setHeight(vm: *Vm, t: Target, v: Value) !void {
    const n = try coerceToNumber(vm, v) orelse return;
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
}

// --- timeline --------------------------------------------------------------

fn getCurrentFrame(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = @floatFromInt(t.clip.current_frame) };
}

fn getTotalFrames(vm: *Vm, t: Target) !Value {
    _ = vm;
    return .{ .number = @floatFromInt(t.clip.totalFrames()) };
}

fn getFramesLoaded(vm: *Vm, t: Target) !Value {
    // Local playback: everything is always loaded.
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

/// Slash path from the root: `""` for _level0, `/mc/child` below it.
/// ruffle display_object.rs:1840-1867.
pub fn slashPath(vm: *Vm, clip: *MovieClip) ![]const u16 {
    if (clip.parent == null) return S("/"); // _target of _level0 is just "/"
    return buildSlashPath(vm, clip);
}

fn buildSlashPath(vm: *Vm, clip: *MovieClip) anyerror![]const u16 {
    const parent = clip.parent orelse {
        // _level0 contributes no name; deeper levels would add "_levelN".
        return S("");
    };
    const head = try buildSlashPath(vm, parent);
    const name = if (clip.placement) |p| (p.name orelse S("")) else S("");
    const with_slash = try strings.concat(vm.arena(), head, S("/"));
    return strings.concat(vm.arena(), with_slash, name);
}

fn getTarget(vm: *Vm, t: Target) !Value {
    return .{ .string = try slashPath(vm, t.clip) };
}

fn getDropTarget(vm: *Vm, t: Target) !Value {
    _ = t;
    // No drag support yet (M4-C). Below SWF6 the absence reads as
    // undefined rather than "".
    if (vm.swf_version < 6) return .undefined_value;
    return .{ .string = S("") };
}

fn getUrl(vm: *Vm, t: Target) !Value {
    _ = vm;
    _ = t;
    return .{ .string = S("") };
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
    vm.sound_buf_time = @intFromFloat(std.math.clamp(n, -2147483648.0, 2147483647.0));
}

/// `_focusrect` on a top-level clip is the STAGE's flag; on a nested clip
/// it is the clip's own override, which defaults to null (inherit).
fn refersToStageFocusRect(vm: *Vm, t: Target) bool {
    return vm.swf_version <= 5 or t.clip.parent == null;
}

fn getFocusRect(vm: *Vm, t: Target) !Value {
    if (refersToStageFocusRect(vm, t)) {
        if (vm.swf_version <= 5) {
            return .{ .number = if (vm.stage_focus_rect) 1 else 0 };
        }
        return .{ .boolean = vm.stage_focus_rect };
    }
    return .null_value;
}

fn setFocusRect(vm: *Vm, t: Target, v: Value) !void {
    if (!refersToStageFocusRect(vm, t)) return;
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

/// Stage mouse position pushed down into the clip's own space. Until the
/// frontend feeds real coordinates (M4-C) `vm.mouse_*` stay at 0, so this
/// reports the clip-space image of the stage origin — which is what a
/// never-moved pointer would give.
fn localMouse(vm: *Vm, t: Target) [2]f64 {
    var m = t.obj.matrix;
    var clip = t.clip;
    while (clip.parent) |parent| {
        const placement = parent.placement orelse break;
        m = placement.matrix.mul(m);
        clip = parent;
    }
    const inv = m.invert() orelse return .{ 0, 0 };
    const p = inv.transformPoint(twipsFromPixels(vm.mouse_x), twipsFromPixels(vm.mouse_y));
    return .{ pixelsFromTwips(p[0]), pixelsFromTwips(p[1]) };
}

// --- clip object model -----------------------------------------------------

/// Lazily create (or fetch) the AVM1 object for a clip. Clip objects double
/// as their timeline's variable scope, so `scope_parent` stays 0 and lookup
/// falls through to _global.
pub fn clipObject(vm: *Vm, mc: *MovieClip) !ObjectHandle {
    if (mc.avm_object != 0) return mc.avm_object;
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.object_proto };
    vm.objects.get(h).native = .{ .clip = @ptrCast(mc) };
    mc.avm_object = h;
    return h;
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

    if (childByName(t.clip, name, vm.case_sensitive)) |child| {
        // Non-scriptable children (shapes, text) resolve to their PARENT
        // rather than to nothing — ruffle stage_object.rs:32-43.
        if (child.kind == .clip) return .{ .object = try clipObject(vm, child.kind.clip) };
        return .{ .object = handle };
    }

    if (magic) {
        if (findByName(name)) |index| return try PROPERTIES[index].get(vm, t);
    }
    return null;
}

/// ruffle `resolve_path_property`. SWF4 has none of these; `_global` waits
/// until SWF6. Unlike the display properties, these obey the version's
/// case-sensitivity rule.
fn resolvePathProperty(vm: *Vm, t: Target, name: []const u16) !?Value {
    if (vm.swf_version < 5) return null;
    if (nameEql(vm, name, S("_root"))) return vm.root_object;
    if (nameEql(vm, name, S("_parent"))) {
        const parent = t.clip.parent orelse return .undefined_value;
        return .{ .object = try clipObject(vm, parent) };
    }
    if (vm.swf_version >= 6 and nameEql(vm, name, S("_global"))) {
        return .{ .object = vm.globals };
    }
    // Only _level0 exists — loading into other levels is not supported.
    if (nameEql(vm, name, S("_level0")) or nameEql(vm, name, S("_flash0"))) {
        return vm.root_object;
    }
    return null;
}

fn nameEql(vm: *Vm, a: []const u16, b: []const u16) bool {
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
