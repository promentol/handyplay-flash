//! The classes that exist mainly so that scripts can ASK about them.
//!
//! Every AVM1 player exposes Camera, Microphone, LocalConnection,
//! NetConnection, PrintJob, SharedObject,
//! ContextMenu, ContextMenuItem and the Accessibility namespace, and a
//! movie that feature-detects (`if (SharedObject)`) or enumerates
//! `_global` sees all of them — corpus globals_swf6/7/8 trace the type
//! of every one. What they DO is a workstream each: local connections
//! need a cross-movie bus, shared objects need AMF and a disk, video
//! needs a decoder.
//!
//! So this file declares the shape and nothing else: the constructor,
//! the prototype, and the member names at their documented attributes.
//! Every method answers undefined. When a class grows real behaviour it
//! moves OUT of here into its own file — that is the signal that it is
//! no longer a stub.

const std = @import("std");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const decl = @import("decl.zig");

const Vm = runtime.Vm;
const Value = runtime.Value;
const ObjectHandle = runtime.ObjectHandle;
const S = runtime.S;
const method = decl.method;
const hidden = decl.hidden;

/// A member list: the names go on the prototype, all DONT_ENUM |
/// DONT_DELETE, which is what ruffle's tables carry.
const Class = struct {
    name: []const u8,
    /// Prototype members.
    proto: []const []const u8 = &.{},
    /// Prototype members with no version gate of their own.
    proto_ungated: []const []const u8 = &.{},
    /// READ-ONLY accessors that answer 0. Unlike the methods these are
    /// ENUMERABLE — `for..in` over a PrintJob lists them (corpus
    /// printjob_props_swf7).
    zero_props: []const []const u8 = &.{},
    /// Members on the CONSTRUCTOR itself (`Camera.get`, `SharedObject.getLocal`).
    statics: []const []const u8 = &.{},
    /// The SWF version the class first appears in, as a gate bit.
    version: u16 = 0,
    /// A gate on the prototype MEMBERS only — PrintJob exists at SWF6
    /// but cannot do anything until 7.
    proto_version: u16 = 0,
};

const CLASSES = [_]Class{
    .{
        .name = "Camera",
        .proto = &.{ "setMode", "setQuality", "setKeyFrameInterval", "setMotionLevel", "setLoopback", "setCursor" },
        .statics = &.{ "get", "names" },
    },
    .{
        .name = "Microphone",
        .proto = &.{ "setSilenceLevel", "setRate", "setGain", "setUseEchoSuppression", "setCodec", "setFramesPerPacket", "setEncodeQuality" },
        .statics = &.{ "get", "names" },
    },
    .{
        .name = "PrintJob",
        // The CLASS exists at SWF6; only its methods are gated to 7.
        .proto = &.{ "start", "addPage", "send" },
        .proto_version = decl.V7,
        .zero_props = &.{ "paperHeight", "paperWidth", "pageHeight", "pageWidth", "orientation" },
    },
    .{
        .name = "SharedObject",
        .proto = &.{ "connect", "send", "flush", "close", "getSize", "setFps", "clear", "onStatus", "onSync" },
        .statics = &.{ "deleteAll", "getDiskUsage", "getLocal", "getRemote" },
    },
};

pub fn install(vm: *Vm) !void {
    inline for (CLASSES) |cls| {
        const proto = try vm.objects.create();
        vm.objects.get(proto).proto = .{ .object = vm.object_proto };
        inline for (cls.proto) |m| {
            try method(vm, proto, m, noop, decl.ver(hidden, cls.version | cls.proto_version));
        }
        inline for (cls.proto_ungated) |m| {
            try method(vm, proto, m, noop, decl.ver(hidden, cls.version));
        }
        inline for (cls.zero_props) |m| {
            try decl.property(vm, proto, m, zero, null, decl.ver(
                .{ .dont_delete = true, .read_only = true },
                cls.version,
            ));
        }
        const ctor = try decl.class(vm, cls.name, ctorStub, proto, decl.ver(.{ .dont_enum = true }, cls.version));
        inline for (cls.statics) |m| {
            try method(vm, ctor, m, noop, decl.ver(hidden, cls.version));
        }
    }

    // Accessibility is a NAMESPACE, not a class: no constructor, no
    // prototype, three version-6 methods.
    const acc = try decl.namespace(vm, "Accessibility", .{ .dont_enum = true });
    inline for (.{ "isActive", "sendEvent", "updateProperties" }) |m| {
        try method(vm, acc, m, noop, decl.ver(
            .{ .dont_delete = true, .read_only = true },
            decl.V6,
        ));
    }
}

/// A native constructor's RETURN VALUE is what `super()` evaluates to,
/// and for these classes it is undefined — not the instance
/// (corpus native_subclasses).
fn ctorStub(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn zero(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .number = 0 };
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}
