//! MovieClip.prototype methods that create and destroy clips at runtime.
//!
//! These share one primitive with the SWF4 CloneSprite/RemoveSprite
//! opcodes — `stage_object.createAt` — and the same ActionScript depth
//! space, offset from the display list's by `AVM_DEPTH_BIAS`.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/movie_clip.rs.

const std = @import("std");
const swf = @import("../../swf/swf.zig");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage = @import("../stage_object.zig");
const decl = @import("decl.zig");
const display_object = @import("../../display/display_object.zig");
const activation = @import("../activation.zig");
const geom = @import("geom.zig");
const bitmap_data = @import("bitmap_data.zig");
const filters = @import("filters.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;
const frozen = decl.frozen;
const ver = decl.ver;

/// Flags and version gates are ruffle's, from
/// globals/movie_clip.rs's `declare_properties!` table — the gate is why
/// `getNextHighestDepth` does not exist for a SWF6 movie.
pub fn install(vm: *Vm) !void {
    const proto = vm.movieclip_proto;
    try method(vm, proto, "duplicateMovieClip", duplicateMovieClip, hidden);
    try method(vm, proto, "attachMovie", attachMovie, hidden);
    try method(vm, proto, "attachBitmap", attachBitmap, ver(hidden, decl.V8));
    try method(vm, proto, "createEmptyMovieClip", createEmptyMovieClip, ver(hidden, decl.V6));
    try method(vm, proto, "removeMovieClip", removeMovieClip, hidden);
    try method(vm, proto, "createTextField", createTextField, hidden);
    try method(vm, proto, "swapDepths", swapDepths, hidden);
    try method(vm, proto, "beginFill", beginFill, ver(hidden, decl.V6));
    try method(vm, proto, "beginBitmapFill", beginBitmapFill, ver(hidden, decl.V8));
    try method(vm, proto, "beginGradientFill", beginGradientFill, ver(hidden, decl.V6));
    try method(vm, proto, "lineGradientStyle", lineGradientStyle, ver(hidden, decl.V8));
    try method(vm, proto, "endFill", endFill, ver(hidden, decl.V6));
    try method(vm, proto, "lineStyle", lineStyle, ver(hidden, decl.V6));
    try method(vm, proto, "moveTo", moveTo, ver(hidden, decl.V6));
    try method(vm, proto, "lineTo", lineTo, ver(hidden, decl.V6));
    try method(vm, proto, "curveTo", curveTo, ver(hidden, decl.V6));
    try method(vm, proto, "clear", clearDrawing, ver(hidden, decl.V6));
    try method(vm, proto, "getDepth", getDepth, ver(frozen, decl.V6));
    try method(vm, proto, "getTextSnapshot", getTextSnapshot, ver(hidden, decl.V6));
    try method(vm, proto, "getNextHighestDepth", getNextHighestDepth, ver(hidden, decl.V7));

    // --- timeline control ---------------------------------------------------
    try method(vm, proto, "play", play, hidden);
    try method(vm, proto, "stop", stop, hidden);
    try method(vm, proto, "nextFrame", nextFrame, hidden);
    try method(vm, proto, "prevFrame", prevFrame, hidden);
    try method(vm, proto, "gotoAndPlay", gotoAndPlay, hidden);
    try method(vm, proto, "gotoAndStop", gotoAndStop, hidden);

    // --- queries ------------------------------------------------------------
    try method(vm, proto, "getBytesLoaded", getBytesLoaded, hidden);
    try method(vm, proto, "getBytesTotal", getBytesTotal, hidden);
    try method(vm, proto, "getSWFVersion", getSwfVersion, hidden);
    try method(vm, proto, "getInstanceAtDepth", getInstanceAtDepth, ver(hidden, decl.V7));
    try method(vm, proto, "getBounds", getBounds, hidden);
    try method(vm, proto, "getRect", getBounds, ver(hidden, decl.V8));
    try method(vm, proto, "localToGlobal", localToGlobal, hidden);
    try method(vm, proto, "globalToLocal", globalToLocal, hidden);
    try method(vm, proto, "hitTest", hitTest, hidden);
    try method(vm, proto, "setMask", setMask, ver(hidden, decl.V6));
    try method(vm, proto, "startDrag", startDrag, hidden);
    try method(vm, proto, "stopDrag", stopDrag, hidden);
    try method(vm, proto, "loadVariables", loadVariables, hidden);
    try method(vm, proto, "getURL", getUrl, hidden);
    try method(vm, proto, "loadMovie", loadMovie, hidden);
    try method(vm, proto, "unloadMovie", unloadMovie, hidden);

    // --- the property block --------------------------------------------------
    // Ruffle declares each of these with a getter/setter pair, but the
    // engine has nothing behind most of them: the getter returns a fixed
    // default and the setter stores a value nothing reads. A prototype DATA
    // property is observationally identical there — reads find it on the
    // chain, and a write creates an own property on the clip exactly as a
    // no-op setter would. Only the ones with real state below get accessors.
    try decl.value(vm, proto, "enabled", .{ .boolean = true }, hidden);
    try decl.value(vm, proto, "useHandCursor", .{ .boolean = true }, hidden);
    try decl.value(vm, proto, "tabEnabled", .undefined_value, ver(hidden, decl.V6));
    try decl.property(vm, proto, "tabIndex", getTabIndex, setTabIndex, ver(hidden, decl.V6));
    try decl.value(vm, proto, "tabChildren", .undefined_value, ver(hidden, decl.V6));
    try decl.value(vm, proto, "trackAsMenu", .undefined_value, ver(hidden, decl.V6));
    try decl.value(vm, proto, "menu", .undefined_value, ver(hidden, decl.V7));
    try decl.value(vm, proto, "hitArea", .undefined_value, ver(hidden, decl.V6));
    try decl.value(vm, proto, "_accProps", .undefined_value, ver(hidden, decl.V6));
    try decl.value(vm, proto, "forceSmoothing", .undefined_value, ver(hidden, decl.V8));
    try decl.property(vm, proto, "cacheAsBitmap", getCacheAsBitmap, setCacheAsBitmap, ver(hidden, decl.V8));
    try decl.value(vm, proto, "opaqueBackground", .undefined_value, ver(hidden, decl.V8));
    try decl.value(vm, proto, "scrollRect", .undefined_value, ver(hidden, decl.V8));
    try decl.value(vm, proto, "scale9Grid", .undefined_value, ver(hidden, decl.V8));
    try decl.property(vm, proto, "_lockroot", getLockRoot, setLockRoot, hidden);
    try decl.property(vm, proto, "blendMode", getBlendMode, setBlendMode, ver(hidden, decl.V8));
    try decl.property(vm, proto, "filters", getFilters, setFilters, ver(hidden, decl.V8));
    try decl.property(vm, proto, "transform", getTransform, setTransform, ver(.{ .dont_enum = true }, decl.V8));
}

/// Not a factory of its own: it RESOLVES the name `TextSnapshot` and
/// constructs whatever that names, passing the clip as the only argument.
/// Content can therefore replace the class and see its own constructor run
/// (corpus movieclip_gettextsnapshot swaps it out and traces the calls).
fn getTextSnapshot(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const ctor = vm.objects.getChained(vm.globals, S("TextSnapshot"), vm.case_sensitive) orelse
        return .undefined_value;
    return vm.construct(ctor, &.{this});
}

/// `tabIndex` is a NATIVE slot, not an ordinary property: it survives on
/// the display object and drives the tab order. -1 reads back as
/// undefined, being ruffle's spelling of "unset" (interactive.rs
/// set_tab_index).
pub fn getTabIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const idx = t.obj.tab_index orelse return .undefined_value;
    return .{ .number = @floatFromInt(idx) };
}

pub fn setTabIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    // Only a BOOLEAN or a NUMBER is coerced; a string or an object sets
    // i32::MIN outright, and undefined/null unset it (ruffle
    // globals/movie_clip.rs set_tab_index). -1 is ruffle's spelling of
    // "unset" and never survives as a value.
    t.obj.tab_index = switch (v) {
        .undefined_value, .null_value => null,
        .boolean, .number => blk: {
            const n = value_mod.toInt32(try vm.toNumber(v));
            break :blk if (n == -1) null else n;
        },
        else => std.math.minInt(i32),
    };
    return .undefined_value;
}

// --- timeline control ---------------------------------------------------------

/// The clip a method acts on, or null when `this` is not (or is no longer)
/// a live display object — in which case Flash silently does nothing.
fn clipOf(vm: *Vm, this: Value) ?*@import("../../display/movie_clip.zig").MovieClip {
    const t = stage.targetOfValue(vm, this) orelse return null;
    return t.clip;
}

fn play(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (clipOf(vm, this)) |c| stage.hostSetPlaying(vm, c, true);
    return .undefined_value;
}

fn stop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (clipOf(vm, this)) |c| stage.hostSetPlaying(vm, c, false);
    return .undefined_value;
}

fn nextFrame(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (clipOf(vm, this)) |c| stage.hostNextPrev(vm, c, 1);
    return .undefined_value;
}

fn prevFrame(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (clipOf(vm, this)) |c| stage.hostNextPrev(vm, c, -1);
    return .undefined_value;
}

fn gotoAndPlay(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return gotoAnd(p, this, args, true);
}

fn gotoAndStop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return gotoAnd(p, this, args, false);
}

/// The scene argument (`gotoAndPlay(scene, frame)`) is only meaningful for
/// AVM2 timelines; ruffle ignores it and takes the SECOND argument as the
/// frame when two are given.
fn gotoAnd(p: *anyopaque, this: Value, args: []const Value, playing: bool) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const frame = if (args.len > 1) args[1] else args[0];
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const c = t.clip orelse return .undefined_value;
    switch (try stage.frameArg(vm, frame)) {
        .number => |n| stage.gotoFrameNumber(vm, c, n, 0, playing),
        .label => |s| {
            // A string operand is a full VARIABLE PATH, not just a label —
            // `clip.gotoAndStop("/:5")` sends _root to frame 5 and leaves
            // `clip` alone (ruffle goto_frame's resolve_variable_path).
            if (try activation.framePathFromNative(vm, this.object, s)) |hit| {
                if (hit.frame) |f| stage.hostGoto(vm, hit.clip, f, playing);
            } else {
                _ = stage.hostGotoLabel(vm, c, s, playing);
            }
        },
    }
    return .undefined_value;
}

// --- queries -------------------------------------------------------------------

fn getBytesLoaded(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const c = clipOf(vm, this) orelse return .undefined_value;
    return .{ .number = stage.bytesLoaded(vm, c) };
}

fn getBytesTotal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const c = clipOf(vm, this) orelse return .undefined_value;
    return .{ .number = stage.bytesTotal(vm, c) };
}

/// `MovieClip.getURL(url, window, method)`. The clip is ignored entirely —
/// it is a namespaced alias for the global navigation, and the variables it
/// can send are the CALLING frame's, not the clip's. The method argument
/// only counts when it is literally a string; a Number or a String OBJECT
/// leaves the request variable-free.
fn getUrl(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const l = @import("loader.zig");
    const url = try vm.toStringValue(args[0]);
    if (l.fsCommandOf(url) != null) return .undefined_value;
    const window = if (args.len > 1) try vm.toStringValue(args[1]) else S("");
    const m: runtime.FetchRequest.Method = if (args.len > 2 and args[2] == .string)
        runtime.FetchRequest.Method.fromName(args[2].string) orelse .none
    else
        .none;
    const locals = activation.Activation.localsForNative(vm);
    const vars = if (m == .none or locals == null)
        &[_]runtime.NavigateRequest.Pair{}
    else
        try l.formPairs(vm, locals.?);
    try l.navigate(vm, url, window, m, vars);
    return .undefined_value;
}

/// `MovieClip.loadMovie(url, method)`. The variables it can send are the
/// CLIP's own, not the calling frame's — the one place the method form
/// differs from the opcode.
fn loadMovie(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (clipOf(vm, this) == null) return .undefined_value;
    const url = try vm.toStringValue(arg(args, 0));
    const m = runtime.FetchRequest.Method.fromName(try vm.toStringValue(arg(args, 1))) orelse .none;
    const l = @import("loader.zig");
    l.spawn(vm, try l.buildRequest(vm, url, this.object, m, .{ .movie = .{ .clip = this.object } }));
    return .undefined_value;
}

fn unloadMovie(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (clipOf(vm, this) == null) return .undefined_value;
    const h = vm.host;
    const f = h.unload_movie orelse return .undefined_value;
    f(h.ctx orelse return .undefined_value, this.object);
    return .undefined_value;
}

/// The method form of `loadVariables`. Unlike the opcode it is never
/// demoted to a browser navigation, and it sends the CLIP's own variables
/// rather than the calling frame's locals. Returns undefined either way —
/// success is only observable through the data arriving.
fn loadVariables(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (clipOf(vm, this) == null) return .undefined_value;
    const url = try vm.toStringValue(arg(args, 0));
    const m = runtime.FetchRequest.Method.fromName(try vm.toStringValue(arg(args, 1))) orelse .none;
    const l = @import("loader.zig");
    l.spawn(vm, try l.buildRequest(vm, url, this.object, m, .{ .form = this.object }));
    return .undefined_value;
}

/// -1 when the clip has no movie of its own; every clip here shares the
/// root movie, so that only happens if the VM has no display context.
fn getSwfVersion(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    // A LOADED clip reports its own movie's version; an image has none,
    // and version 0 is what script sees as -1.
    var version = vm.root_swf_version;
    if (clipOf(vm, this)) |c| {
        if (c.loadInfoOf()) |l| version = l.version;
    }
    if (version == 0) return .{ .number = -1 };
    return .{ .number = @floatFromInt(version) };
}

fn getInstanceAtDepth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const c = clipOf(vm, this) orelse return .undefined_value;
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 0)));
    const child = c.childAtDepth(depth) orelse return .undefined_value;
    return stage.childValue(vm, c, child);
}

/// The target argument may be the object itself OR a target path string —
/// `clip.getBounds('/')` measures against the root.
fn getBounds(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const target: ?stage.Target = if (args.len > 0)
        (try activation.targetFromNative(vm, this.object, args[0]) orelse return .undefined_value)
    else
        null;
    return stage.boundsObject(vm, t, target);
}

/// Both mutate the passed object's `x`/`y` IN PLACE and return nothing —
/// the classic AVM1 out-parameter shape.
fn localToGlobal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return convertPoint(p, this, args, true);
}

fn globalToLocal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return convertPoint(p, this, args, false);
}

fn convertPoint(p: *anyopaque, this: Value, args: []const Value, to_global: bool) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const pt = arg(args, 0);
    if (pt != .object) return .undefined_value;
    // NO coercion here, deliberately: ruffle's comment is "it fails if the
    // properties are not numbers. It does not search the prototype chain
    // and ignores virtual properties." So `{x: "10", y: 0}` is left
    // completely untouched, and so is `{x: 10}` with no y — corpus
    // local_to_global checks exactly those.
    const xv = vm.objects.getOwn(pt.object, S("x"), vm.case_sensitive) orelse return .undefined_value;
    const yv = vm.objects.getOwn(pt.object, S("y"), vm.case_sensitive) orelse return .undefined_value;
    if (xv != .number or yv != .number) return .undefined_value;
    const x_px = xv.number;
    const y_px = yv.number;
    const m = if (to_global)
        stage.localToGlobalMatrix(t)
    else
        (stage.globalToLocalMatrix(t) orelse return .undefined_value);
    const out = m.transformPoint(display_object.twipsFromPixels(x_px), display_object.twipsFromPixels(y_px));
    try vm.setProperty(pt.object, S("x"), .{ .number = display_object.pixelsFromTwips(out[0]) }, pt);
    try vm.setProperty(pt.object, S("y"), .{ .number = display_object.pixelsFromTwips(out[1]) }, pt);
    return .undefined_value;
}

/// `hitTest(x, y[, shapeFlag])` or `hitTest(target)`. A non-finite
/// coordinate is not an error, it is simply a miss.
fn hitTest(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .{ .boolean = false };
    if (args.len > 1) {
        const x = try vm.toNumber(args[0]);
        const y = try vm.toNumber(args[1]);
        const shape_flag = if (args.len > 2) value_mod.toBoolean(args[2], vm.swf_version) else false;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return .{ .boolean = false };
        return .{ .boolean = stage.hitTestPoint(vm, t, x, y, shape_flag) };
    }
    if (args.len == 1) {
        // Like getBounds, the single-argument form accepts a path string.
        const other = try activation.targetFromNative(vm, this.object, args[0]) orelse
            return .{ .boolean = false };
        return .{ .boolean = stage.hitTestObject(vm, t, other) };
    }
    return .{ .boolean = false };
}

/// Masking is rendered in M7; the link itself is script-visible now.
/// The return value distinguishes three cases: no argument at all is
/// `undefined`, `null`/`undefined` CLEARS the mask and reports true, and an
/// argument that names nothing reports false without changing anything
/// (ruffle set_mask).
fn setMask(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    if (args.len == 0) return .undefined_value;
    const v = args[0];
    if (v == .undefined_value or v == .null_value) {
        if (t.obj.mask) |old| old.maskee = null;
        t.obj.mask = null;
        return .{ .boolean = true };
    }
    const m = try activation.targetFromNative(vm, 0, v) orelse
        return .{ .boolean = false };
    if (t.obj.mask) |old| old.maskee = null;
    t.obj.mask = m.obj;
    // Both ends of the link, as ruffle keeps them: a mask has to know it
    // is one, because that is what exempts it from the visibility rule
    // and from being hit itself.
    m.obj.maskee = t.obj;
    return .{ .boolean = true };
}

fn startDrag(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const lock_center = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    var rect: ?[4]f64 = null;
    if (args.len >= 5) {
        rect = .{
            try vm.toNumber(args[1]),
            try vm.toNumber(args[2]),
            try vm.toNumber(args[3]),
            try vm.toNumber(args[4]),
        };
    }
    stage.startDrag(vm, t, lock_center, rect);
    return .undefined_value;
}

/// Ruffle's `stop_drag` ends whatever drag is running, even one started by
/// a different clip — there is only ever one.
fn stopDrag(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    stage.stopDrag(vmOf(p));
    return .undefined_value;
}

// --- properties with real state -------------------------------------------------

fn getLockRoot(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const c = clipOf(vm, this) orelse return .undefined_value;
    return .{ .boolean = c.lock_root };
}

fn setLockRoot(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const c = clipOf(vm, this) orelse return .undefined_value;
    c.lock_root = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    return .undefined_value;
}

/// PlaceObject3's blend byte as its ActionScript name. Index IS the byte:
/// 0 and 1 both mean "normal", so slot 0 is a duplicate on purpose.
const BLEND_NAMES = [_][]const u16{
    S("normal"),  S("normal"), S("layer"),      S("multiply"), S("screen"),
    S("lighten"), S("darken"), S("difference"), S("add"),      S("subtract"),
    S("invert"),  S("alpha"),  S("erase"),      S("overlay"),  S("hardlight"),
};

/// `cacheAsBitmap` reads back what was WRITTEN, not what the renderer
/// decided — a clip whose filters force a cache still reports whatever
/// the script last set (ruffle `is_bitmap_cached_preference`).
pub fn getCacheAsBitmap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    return .{ .boolean = t.obj.cache_as_bitmap };
}

pub fn setCacheAsBitmap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    t.obj.cache_as_bitmap = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    return .undefined_value;
}

pub fn getBlendMode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const i = t.obj.blend_mode;
    if (i >= BLEND_NAMES.len) return .{ .string = S("normal") };
    return .{ .string = BLEND_NAMES[i] };
}

/// Either the name or the numeric index. NULL and UNDEFINED reset it to
/// `normal`; anything else unrecognised — a wrong-case name, an
/// out-of-range number, an object — leaves the current mode ALONE. The
/// name match is case SENSITIVE, so `lAyEr` is not `layer`.
pub fn setBlendMode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v == .null_value or v == .undefined_value) {
        t.obj.blend_mode = 1;
        return .undefined_value;
    }
    if (v == .number) {
        // The number is TRUNCATED to a byte first, so 259 is 3 — and
        // -1 becomes 255, which is out of range and changes nothing.
        const n: u8 = @truncate(@as(u32, @bitCast(value_mod.toInt32(v.number))));
        if (n < BLEND_NAMES.len) t.obj.blend_mode = n;
        return .undefined_value;
    }
    if (v != .string) return .undefined_value;
    for (BLEND_NAMES, 0..) |name, i| {
        if (i == 0) continue; // "normal" is canonically 1
        if (strings.eql(v.string, name)) {
            t.obj.blend_mode = @intCast(i);
            return .undefined_value;
        }
    }
    return .undefined_value;
}

/// PlaceObject3 filters are parsed but not applied (M7). Reading yields a
/// fresh empty Array every time, which is what ruffle does — the returned
/// array is a COPY, so mutating it does not change the object.
/// The object's filter list. Both directions COPY: the array is fresh
/// and so is every filter in it, so neither `mc.filters[0].blurX = 9` nor
/// holding on to the array you assigned reaches the object.
pub fn getFilters(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const out = try vm.newArray();
    if (this != .object) return .{ .object = out };
    const stored = vm.objects.getOwn(this.object, S(FILTERS_SLOT), false) orelse
        return tagFilters(vm, this, out);
    if (stored != .object) return .{ .object = out };

    const len = filterListLen(vm, stored.object);
    var n: u32 = 0;
    for (0..len) |i| {
        const got = vm.objects.getChained(stored.object, try indexName(vm, i), false) orelse continue;
        const copy = (try filters.cloneFilter(vm, got)) orelse continue;
        try vm.objects.put(out, try indexName(vm, n), copy, false);
        n += 1;
    }
    try vm.setArrayLength(out, n);
    return .{ .object = out };
}

pub fn setFilters(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const list = try vm.newArray();
    var n: u32 = 0;
    const v = arg(args, 0);
    if (v == .object) {
        const len = filterListLen(vm, v.object);
        for (0..len) |i| {
            const got = vm.objects.getChained(v.object, try indexName(vm, i), false) orelse continue;
            // Anything that is not a filter is DROPPED, not stored.
            const copy = (try filters.cloneFilter(vm, got)) orelse continue;
            try vm.objects.put(list, try indexName(vm, n), copy, false);
            n += 1;
        }
    }
    try vm.setArrayLength(list, n);
    try vm.objects.putWithAttrs(this.object, S(FILTERS_SLOT), .{ .object = list }, decl.frozen, false);
    return .undefined_value;
}

/// Until a script assigns a list, `filters` reports what the PLACEMENT
/// carried — and builds fresh objects for it every read, like the
/// script-set path.
fn tagFilters(vm: *Vm, this: Value, out: ObjectHandle) !Value {
    const t = stage.targetOfValue(vm, this) orelse return .{ .object = out };
    var n: u32 = 0;
    for (t.obj.tag_filters) |f| {
        try vm.objects.put(out, try indexName(vm, n), try filters.fromTag(vm, f), false);
        n += 1;
    }
    try vm.setArrayLength(out, n);
    return .{ .object = out };
}

/// Where the list lives. Hidden and undeletable, like every other native
/// slot parked on a script object.
const FILTERS_SLOT = "__filters";

fn filterListLen(vm: *Vm, h: ObjectHandle) usize {
    const v = vm.objects.getChained(h, S("length"), false) orelse return 0;
    if (v != .number) return 0;
    return @intFromFloat(std.math.clamp(v.number, 0, 1024));
}

fn indexName(vm: *Vm, i: usize) !strings.AvmString {
    var buf: [16]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    const wide = try vm.arena().alloc(u16, ascii.len);
    for (ascii, wide) |c, *w| w.* = c;
    return wide;
}

/// A NEW flash.geom.Transform view every read, which is why
/// `mc.transform == mc.transform` is false.
fn getTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    _ = stage.targetOfValue(vm, this) orelse return .undefined_value;
    return geom.newTransform(vm, this.object);
}

/// Assignment COPIES the source's matrix and colour transform; anything
/// that is not a Transform is ignored.
fn setTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    try geom.assignTransform(vm, t, arg(args, 0));
    return .undefined_value;
}

/// The AS depth operand. Ruffle coerces to i32 (wrapping), so a fractional
/// or out-of-range value still lands somewhere deterministic.
fn depthArg(vm: *Vm, v: Value) !i32 {
    return value_mod.toInt32(try vm.toNumber(v));
}

fn duplicateMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    // The METHOD biases the depth; the CloneSprite opcode does not
    // (ruffle globals/movie_clip.rs:928).
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 1)));
    const obj = try stage.cloneSprite(vm, t, name, depth, arg(args, 2)) orelse return .undefined_value;
    // SWF5 and below return nothing at all.
    if (vm.swf_version < 6) return .undefined_value;
    return newClipValue(vm, obj);
}

fn attachMovie(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const export_name = try vm.toStringValue(arg(args, 0));
    const char_id = try stage.exportedCharacter(vm, clip, export_name) orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 1));
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 2)));
    if (!stage.depthPlaceable(depth)) return .undefined_value;
    const obj = try stage.createAt(vm, clip, char_id, depth, name, null, arg(args, 3)) orelse
        return .undefined_value;
    return newClipValue(vm, obj);
}

fn createEmptyMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    // No depth validation here — ruffle's create_empty_movie_clip has none.
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 1)));
    // Character 0 means "no character": an empty, frameless timeline.
    const obj = try stage.createAt(vm, clip, 0, depth, name, null, .undefined_value) orelse
        return .undefined_value;
    const v = try newClipValue(vm, obj);
    // `onConstruct` fires HERE, synchronously, before the call returns —
    // it is the one creation path ruffle dispatches it from. An
    // exception out of it is reported and swallowed, not propagated
    // (corpus movieclip_onconstruct).
    if (v == .object) {
        const f = try vm.getProperty(v.object, S("onConstruct"), v);
        if (vm.isCallable(f)) {
            vm.call_special = true;
            _ = vm.callFunction(f, v, &.{}) catch |e| vm.reportUncaught(e);
        }
    }
    return v;
}

/// `createTextField(name, depth, x, y, width, height)`. The four
/// geometry arguments are INTEGERS — ruffle coerces each to i32 before
/// widening, so 10.9 is 10 and NaN is 0. SWF8 and up get the field back;
/// earlier versions get undefined and have to look it up by name.
fn createTextField(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 1)));
    const x = try coerceInt(vm, arg(args, 2));
    const y = try coerceInt(vm, arg(args, 3));
    const w = try coerceInt(vm, arg(args, 4));
    const h = try coerceInt(vm, arg(args, 5));
    const obj = try stage.createTextFieldAt(vm, clip, depth, name, x, y, w, h) orelse
        return .undefined_value;
    if (vm.swf_version < 8) return .undefined_value;
    return .{ .object = try stage.handleOf(vm, obj) };
}

fn coerceInt(vm: *Vm, v: Value) !f64 {
    return @floatFromInt(value_mod.toInt32(try vm.toNumber(v)));
}

fn removeMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    _ = try stage.removeDisplayObject(vm, t);
    return .undefined_value;
}

/// `swapDepths(n)` takes an AS depth; `swapDepths(clip)` takes that clip's
/// depth verbatim — and only when it shares our parent and is still alive
/// (ruffle globals/movie_clip.rs:1343-1394). Content uses the object form
/// to hoist a timeline-placed object into the script depth range, which is
/// the only way `removeMovieClip` will ever touch it.
///
/// A string argument would resolve as a target path rooted at THIS clip,
/// which a native fn has no activation to do; since such a path can only
/// name a descendant, it fails ruffle's same-parent test anyway.
fn swapDepths(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const a = arg(args, 0);
    // A NUMBER is a script depth; anything else names another clip —
    // including as a target PATH, which has to be resolved against the
    // running frame rather than read as a depth.
    const depth: i32 = switch (a) {
        .number => |n| stage.biasDepth(value_mod.toInt32(n)),
        else => blk: {
            const other = stage.targetOfValue(vm, a) orelse other_blk: {
                const s = try vm.toStringValue(a);
                // Relative to the RECEIVER, not to the timeline running
                // the call: `clip2.swapDepths('../clip1')` walks up from
                // clip2.
                const from = if (this == .object) this.object else return .undefined_value;
                const h = (try activation.Activation.resolveTargetForNative(vm, from, s)) orelse
                    return .undefined_value;
                break :other_blk stage.targetOf(vm, h) orelse return .undefined_value;
            };
            if (other.obj.removed) return .undefined_value;
            // The two must share a PARENT — a swap across timelines is
            // refused outright rather than reparenting anything.
            if (other.parent() != t.parent()) return .undefined_value;
            break :blk other.obj.depth;
        },
    };
    _ = stage.swapDepths(vm, t, depth);
    return .undefined_value;
}

// --- drawing API ----------------------------------------------------------
//
// Coordinates arrive in PIXELS and become twips by truncation; colours are
// 0xRRGGBB with a separate 0-100 alpha. See core/display/drawing.zig for
// the subpath model these five methods drive.

fn drawingFor(vm: *Vm, this: Value) ?*stage.drawing.Drawing {
    const t = stage.targetOfValue(vm, this) orelse return null;
    return stage.drawingOf(vm, t);
}

/// 0xRRGGBB + a 0-100 alpha → the engine's 0xAABBGGRR.
fn rgbaFrom(rgb: u32, alpha_pct: f64) u32 {
    const a: u32 = @intFromFloat(std.math.clamp(alpha_pct, 0, 100) / 100.0 * 255.0);
    return ((rgb >> 16) & 0xFF) | (((rgb >> 8) & 0xFF) << 8) | ((rgb & 0xFF) << 16) | (a << 24);
}

fn alphaArg(vm: *Vm, args: []const Value, i: usize) !f64 {
    if (i >= args.len) return 100;
    const n = try vm.toNumber(args[i]);
    return if (std.math.isNan(n)) 0 else n;
}

fn beginFill(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    // No colour at all means "stop filling", exactly like endFill.
    if (args.len == 0 or arg(args, 0) == .undefined_value) {
        try d.setFillStyle(null);
        return .undefined_value;
    }
    const rgb: u32 = @bitCast(value_mod.toInt32(try vm.toNumber(args[0])));
    try d.setFillStyle(.{ .solid = rgbaFrom(rgb, try alphaArg(vm, args, 1)) });
    return .undefined_value;
}

/// `beginBitmapFill(bitmapData, matrix, repeating, smoothed)`. The
/// matrix maps bitmap PIXELS to clip pixels, which is the same thing a
/// tag's bitmap fill matrix does one scale factor apart — `matrixOf`
/// already converts its translation, so nothing else is needed.
///
/// Anything but a live BitmapData in the first argument stops the fill,
/// exactly as `beginFill()` with no colour does.
fn beginBitmapFill(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    const bd = bitmap_data.dataOf(vm, arg(args, 0)) orelse {
        try d.setFillStyle(null);
        return .undefined_value;
    };
    // A tag's bitmap fill matrix maps a texel to TWIPS; a script's maps it
    // to PIXELS. The renderer speaks the tag's language, so the twenty
    // between them is applied here, where the pixel convention lives,
    // rather than in the renderer, where it would corrupt every fill that
    // came from a tag.
    var m: swf.reader.Matrix = .{ .a = 20, .d = 20 };
    if (arg(args, 1) == .object) {
        m = try geom.matrixOf(vm, args[1].object);
        m.a *= 20;
        m.b *= 20;
        m.c *= 20;
        m.d *= 20;
    }
    // `repeating` defaults to TRUE and `smoothed` to false — the opposite
    // pair of defaults, and neither is what the documentation says.
    const repeating = if (args.len > 2) value_mod.toBoolean(args[2], vm.swf_version) else true;
    const smoothed = args.len > 3 and value_mod.toBoolean(args[3], vm.swf_version);
    try d.setFillStyle(.{ .bitmap = .{
        .id = 0,
        .matrix = m,
        .is_smoothed = smoothed,
        .is_repeating = repeating,
        .live = @ptrCast(bd),
    } });
    return .undefined_value;
}

/// `attachBitmap(bitmapData, depth, pixelSnapping, smoothing)`. Every
/// argument but the first two is advisory; a missing depth means the
/// call does nothing at all rather than defaulting.
fn attachBitmap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const bd = bitmap_data.dataOf(vm, arg(args, 0)) orelse return .undefined_value;
    if (args.len < 2) return .undefined_value;
    const depth = stage.biasDepth(try depthArg(vm, args[1]));
    // Pixel snapping (argument 2) is not modelled: the rasteriser has no
    // texel grid to snap to.
    const smoothing = args.len > 3 and value_mod.toBoolean(args[3], vm.swf_version);
    _ = try stage.attachBitmapAt(vm, clip, bd, depth, smoothing);
    return .undefined_value;
}

fn endFill(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    try d.setFillStyle(null);
    return .undefined_value;
}

fn lineStyle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    if (args.len == 0 or arg(args, 0) == .undefined_value) {
        try d.setLineStyle(null);
        return .undefined_value;
    }
    // Thickness is CLAMPED to 0..255px before conversion (ruffle
    // line_style), so a wild value cannot blow up the stroke bounds.
    const thickness = std.math.clamp(try vm.toNumber(args[0]), 0, 255);
    const rgb: u32 = if (args.len > 1) @bitCast(value_mod.toInt32(try vm.toNumber(args[1]))) else 0;
    var style: swf.shape.LineStyle = .{
        .width = @intFromFloat(@trunc(thickness * 20)),
        .fill = .{ .solid = rgbaFrom(rgb, try alphaArg(vm, args, 2)) },
    };
    if (args.len > 3) style.pixel_hinting = value_mod.toBoolean(args[3], vm.swf_version);
    if (args.len > 4) {
        const s = try vm.toStringValue(args[4]);
        style.no_h_scale = strings.eqlIgnoreCase(s, S("none")) or strings.eqlIgnoreCase(s, S("vertical"));
        style.no_v_scale = strings.eqlIgnoreCase(s, S("none")) or strings.eqlIgnoreCase(s, S("horizontal"));
    }
    if (args.len > 5) style.start_cap = capOf(try vm.toStringValue(args[5]));
    style.end_cap = style.start_cap;
    if (args.len > 6) style.join = joinOf(try vm.toStringValue(args[6]));
    if (args.len > 7) style.miter_limit = @floatCast(try vm.toNumber(args[7]));
    try d.setLineStyle(style);
    return .undefined_value;
}

/// `beginGradientFill(type, colors, alphas, ratios, matrix, spread,
/// interpolation, focalPoint)`. Five arguments are required and NINE is
/// too many — Flash silently draws nothing rather than complaining, and
/// so does every other malformed call here (corpus
/// movieclip_begin_gradient_fill).
fn beginGradientFill(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    if (args.len == 0 or args[0] == .undefined_value) {
        try d.setFillStyle(null);
        return .undefined_value;
    }
    // SWF7 and below have no spread or interpolation arguments at all.
    if (args.len > 8 or (args.len > 5 and vm.swf_version < 8)) return .undefined_value;
    const style = try gradientStyle(vm, args) orelse return .undefined_value;
    try d.setFillStyle(style);
    return .undefined_value;
}

/// The same arguments, painting the STROKE instead. It has no
/// "undefined clears it" case: without a line style already set there is
/// nothing to paint.
fn lineGradientStyle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    if (args.len > 8) return .undefined_value;
    const style = try gradientStyle(vm, args) orelse return .undefined_value;
    try d.setLineFillStyle(style);
    return .undefined_value;
}

/// Shared by the two: null for anything malformed, which the callers
/// turn into "draw nothing" rather than an error.
fn gradientStyle(vm: *Vm, args: []const Value) !?swf.shape.FillStyle {
    if (args.len < 5) return null;
    const kind = try vm.toStringValue(args[0]);
    const radial = strings.eql(kind, S("radial"));
    if (!radial and !strings.eql(kind, S("linear"))) return null;
    if (args[1] != .object or args[2] != .object or args[3] != .object) return null;
    const records = try gradientRecords(vm, args[1].object, args[2].object, args[3].object) orelse
        return null;
    const matrix = if (args[4] == .object)
        try geom.gradientMatrixOf(vm, args[4].object)
    else
        swf.reader.Matrix{};
    const gradient: swf.shape.Gradient = .{
        .matrix = matrix,
        .spread = spreadOf(if (args.len > 5) try vm.toStringValue(args[5]) else S("")),
        .interpolation = interpolationOf(if (args.len > 6) try vm.toStringValue(args[6]) else S("")),
        .records = records,
    };
    const focal = if (args.len > 7) try vm.toNumber(args[7]) else 0;
    if (!radial) return .{ .linear_gradient = gradient };
    if (focal == 0) return .{ .radial_gradient = gradient };
    return .{ .focal_gradient = .{ .gradient = gradient, .focal_point = fixed8(focal) } };
}

/// The three arrays are read in parallel and must be the same length.
/// An alpha is a PERCENTAGE clamped to 0..100; a ratio outside
/// (-1, 256) rejects the whole call, and one inside is truncated toward
/// zero with the ends saturating.
fn gradientRecords(
    vm: *Vm,
    colors: ObjectHandle,
    alphas: ObjectHandle,
    ratios: ObjectHandle,
) !?[]swf.shape.GradientRecord {
    const n = vm.arrayLength(colors);
    if (vm.arrayLength(alphas) != n or vm.arrayLength(ratios) != n) return null;
    const out = try vm.arena().alloc(swf.shape.GradientRecord, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const rgb: u32 = @bitCast(value_mod.toInt32(try vm.toNumber(try elementAt(vm, colors, i))));
        const alpha = std.math.clamp(try vm.toNumber(try elementAt(vm, alphas, i)), 0, 100);
        const ratio = try vm.toNumber(try elementAt(vm, ratios, i));
        // NaN passes: it fails BOTH comparisons, and lands as zero.
        if (ratio <= -1.0 or ratio >= 256.0) return null;
        out[i] = .{
            .ratio = saturatingU8(ratio),
            .color = rgbaFrom(rgb, alpha),
        };
    }
    return out;
}

fn elementAt(vm: *Vm, h: ObjectHandle, i: u32) !Value {
    var buf: [12]u8 = undefined;
    const name = try strings.fromSwf(
        vm.arena(),
        std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0",
        8,
    );
    return vm.getProperty(h, name, .{ .object = h });
}

/// Rust's `as u8` on a float: NaN is zero and the ends saturate.
fn saturatingU8(v: f64) u8 {
    if (std.math.isNan(v) or v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(@trunc(v));
}

/// 8.8 fixed point, saturating — which is why a focal point of -1000
/// comes back as -128 rather than wrapping.
fn fixed8(v: f64) f32 {
    // NaN is ZERO, not a saturated end — a focal point of "???" coerces
    // to NaN and Flash draws an ordinary radial (corpus
    // movieclip_begin_gradient_fill's `"???"` row).
    if (std.math.isNan(v)) return 0;
    const scaled = std.math.clamp(v * 256.0, -32768.0, 32767.0);
    return @floatCast(@trunc(scaled) / 256.0);
}

fn spreadOf(s: strings.AvmString) swf.shape.GradientSpread {
    if (strings.eql(s, S("reflect"))) return .reflect;
    if (strings.eql(s, S("repeat"))) return .repeat;
    return .pad;
}

fn interpolationOf(s: strings.AvmString) swf.shape.GradientInterpolation {
    if (strings.eql(s, S("linearRGB"))) return .linear_rgb;
    return .srgb;
}

fn capOf(s: strings.AvmString) swf.shape.LineCap {
    if (strings.eqlIgnoreCase(s, S("none"))) return .none;
    if (strings.eqlIgnoreCase(s, S("square"))) return .square;
    return .round;
}

fn joinOf(s: strings.AvmString) swf.shape.LineJoin {
    if (strings.eqlIgnoreCase(s, S("miter"))) return .miter;
    if (strings.eqlIgnoreCase(s, S("bevel"))) return .bevel;
    return .round;
}

fn moveTo(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    try d.draw(.{ .move_to = .{
        .x = stage.drawCoord(try vm.toNumber(arg(args, 0))),
        .y = stage.drawCoord(try vm.toNumber(arg(args, 1))),
    } });
    return .undefined_value;
}

fn lineTo(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    try d.draw(.{ .line_to = .{
        .x = stage.drawCoord(try vm.toNumber(arg(args, 0))),
        .y = stage.drawCoord(try vm.toNumber(arg(args, 1))),
    } });
    return .undefined_value;
}

fn curveTo(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    try d.draw(.{ .quad_to = .{
        .cx = stage.drawCoord(try vm.toNumber(arg(args, 0))),
        .cy = stage.drawCoord(try vm.toNumber(arg(args, 1))),
        .ax = stage.drawCoord(try vm.toNumber(arg(args, 2))),
        .ay = stage.drawCoord(try vm.toNumber(arg(args, 3))),
    } });
    return .undefined_value;
}

fn clearDrawing(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const d = drawingFor(vm, this) orelse return .undefined_value;
    d.clear();
    return .undefined_value;
}

/// Shared with Button.prototype and TextField.prototype — ruffle serves
/// all three from one `globals::get_depth`.
pub fn getDepth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const depth: i32 = t.obj.depth;
    return .{ .number = @floatFromInt(depth -% stage.AVM_DEPTH_BIAS) };
}

/// One above the highest occupied depth, in AS space, floored at 0
/// (ruffle globals/movie_clip.rs:1081-1091). Content leans on this to
/// stack attached clips, so without it every attach lands on depth 0 and
/// silently replaces the last one.
fn getNextHighestDepth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    var highest: i32 = 0;
    for (clip.children.items) |child| {
        if (child.depth > highest) highest = child.depth;
    }
    const next = highest -% (stage.AVM_DEPTH_BIAS - 1);
    return .{ .number = @floatFromInt(@max(next, 0)) };
}

fn newClipValue(vm: *Vm, obj: *@import("../../display/display_object.zig").DisplayObject) !Value {
    return stage.displayValue(vm, obj);
}
