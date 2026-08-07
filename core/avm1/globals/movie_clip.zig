//! MovieClip.prototype methods that create and destroy clips at runtime.
//!
//! These share one primitive with the SWF4 CloneSprite/RemoveSprite
//! opcodes — `stage_object.createAt` — and the same ActionScript depth
//! space, offset from the display list's by `AVM_DEPTH_BIAS`.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/movie_clip.rs.

const std = @import("std");
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
    const obj = try stage.createAt(vm, clip, char_id, depth, name) orelse return .undefined_value;
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
    const obj = try stage.createAt(vm, clip, 0, depth, name) orelse return .undefined_value;
    return newClipValue(vm, obj);
}

fn removeMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    _ = try stage.removeDisplayObject(vm, t);
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
