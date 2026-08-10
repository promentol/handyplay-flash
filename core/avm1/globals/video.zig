//! `Video` — the display object a `NetStream` plays into.
//!
//! A `DefineVideoStream` instance is scriptable for exactly one reason:
//! `attachVideo`. Everything else about it is placement — the size comes
//! from the tag, the position from the matrix — so the class is a
//! prototype with one method that matters and a `clear` that empties it.
//!
//! The link is stored on the DISPLAY object rather than the script one,
//! because the renderer is what needs it and the renderer never sees
//! AVM1 handles.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const decl = @import("decl.zig");
const stage = @import("../stage_object.zig");
const net_stream = @import("net_stream.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;
const vmOf = decl.vmOf;
const arg = decl.arg;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    try decl.method(vm, proto, "attachVideo", attachVideo, decl.hidden);
    try decl.method(vm, proto, "clear", clear, decl.hidden);
    vm.video_proto = proto;
    _ = try decl.class(vm, "Video", ctor, proto, .{ .dont_enum = true });
}

fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

/// `attachVideo(source)`: a NetStream starts feeding this instance, and
/// anything else — including null — detaches whatever was.
fn attachVideo(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    t.obj.video_source = net_stream.streamPtrOf(vm, arg(args, 0));
    return .undefined_value;
}

fn clear(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    t.obj.video_source = null;
    return .undefined_value;
}
