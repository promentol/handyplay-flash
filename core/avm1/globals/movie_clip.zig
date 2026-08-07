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

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

fn vmOf(p: *anyopaque) *Vm {
    return @ptrCast(@alignCast(p));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined_value;
}

pub fn install(vm: *Vm) !void {
    const proto = vm.movieclip_proto;
    try method(vm, proto, "duplicateMovieClip", duplicateMovieClip);
    try method(vm, proto, "attachMovie", attachMovie);
    try method(vm, proto, "createEmptyMovieClip", createEmptyMovieClip);
    try method(vm, proto, "removeMovieClip", removeMovieClip);
    try method(vm, proto, "swapDepths", swapDepths);
    try method(vm, proto, "beginFill", beginFill);
    try method(vm, proto, "endFill", endFill);
    try method(vm, proto, "lineStyle", lineStyle);
    try method(vm, proto, "moveTo", moveTo);
    try method(vm, proto, "lineTo", lineTo);
    try method(vm, proto, "curveTo", curveTo);
    try method(vm, proto, "clear", clearDrawing);
    try method(vm, proto, "getDepth", getDepth);
    try method(vm, proto, "getNextHighestDepth", getNextHighestDepth);
}

fn method(vm: *Vm, target: ObjectHandle, comptime name: []const u8, f: object_mod.NativeFn) !void {
    const h = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(target, S(name), .{ .object = h }, .{ .dont_enum = true }, false);
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
    const obj = try stage.cloneSprite(vm, t, name, depth) orelse return .undefined_value;
    const v = try newClipValue(vm, obj);
    try applyInitObject(vm, v, arg(args, 2));
    // SWF5 and below return nothing at all.
    if (vm.swf_version < 6) return .undefined_value;
    return v;
}

/// The optional trailing `initObject`: every enumerable key is copied onto
/// the new clip before anything else can observe it
/// (ruffle movie_clip.rs:2042-2054).
fn applyInitObject(vm: *Vm, clip: Value, init: Value) !void {
    if (init != .object or clip != .object) return;
    const src = init.object;
    var i: usize = 0;
    while (i < vm.objects.get(src).props.items.len) : (i += 1) {
        const prop = vm.objects.get(src).props.items[i];
        if (prop.attrs.dont_enum) continue;
        try vm.setProperty(clip.object, prop.key, prop.value, clip);
    }
}

fn attachMovie(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const export_name = try vm.toStringValue(arg(args, 0));
    const char_id = try stage.exportedCharacter(vm, export_name) orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 1));
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 2)));
    if (!stage.depthPlaceable(depth)) return .undefined_value;
    const obj = try stage.createAt(vm, clip, char_id, depth, name, null) orelse return .undefined_value;
    const v = try newClipValue(vm, obj);
    try applyInitObject(vm, v, arg(args, 3));
    return v;
}

fn createEmptyMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const clip = t.clip orelse return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    // No depth validation here — ruffle's create_empty_movie_clip has none.
    const depth = stage.biasDepth(try depthArg(vm, arg(args, 1)));
    // Character 0 means "no character": an empty, frameless timeline.
    const obj = try stage.createAt(vm, clip, 0, depth, name, null) orelse return .undefined_value;
    return newClipValue(vm, obj);
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
    const depth: i32 = switch (a) {
        .number => |n| stage.biasDepth(value_mod.toInt32(n)),
        else => blk: {
            const other = stage.targetOfValue(vm, a) orelse return .undefined_value;
            if (other.obj.removed) return .undefined_value;
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

fn getDepth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
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
