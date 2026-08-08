//! `flash.display.BitmapData` — a scriptable pixel buffer.
//!
//! It hangs off `flash.display`, not `_global`, and it is the half of
//! workstream E the corpus actually measures: 28 of the 29 bitmap dirs
//! exercise this class and never touch a SWF bitmap tag.
//!
//! Two things the constructor does that look like edge cases and are the
//! test's whole point: fewer than two arguments — or a size that fails
//! `isSizeValid` — yields `undefined` rather than an object, and the fill
//! colour comes back CHANGED, because it round-trips through
//! premultiplication (0xAABBCCDD reads as 0xAABBCCDC).
//!
//! Reference: reference/ruffle/core/src/avm1/globals/bitmap_data.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const pixels = @import("../../bitmap/pixels.zig");
const data_mod = @import("../../bitmap/data.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const BitmapData = data_mod.BitmapData;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

pub fn install(vm: *Vm, display_ns: ObjectHandle) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.bitmapdata_proto = proto;

    const m = ver(decl.hidden, decl.V8);
    try decl.method(vm, proto, "getPixel", getPixel, m);
    try decl.method(vm, proto, "setPixel", setPixel, m);
    try decl.method(vm, proto, "getPixel32", getPixel32, m);
    try decl.method(vm, proto, "setPixel32", setPixel32, m);
    try decl.method(vm, proto, "dispose", dispose, m);
    try decl.method(vm, proto, "clone", clone, m);

    const p = ver(.{ .read_only = true }, decl.V8);
    try decl.property(vm, proto, "width", getWidth, null, p);
    try decl.property(vm, proto, "height", getHeight, null, p);
    try decl.property(vm, proto, "transparent", getTransparent, null, p);
    try decl.property(vm, proto, "rectangle", getRectangle, null, p);

    const ctor = try vm.newNativeFn(construct);
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, decl.hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, decl.hidden, false);
    try vm.objects.putWithAttrs(display_ns, S("BitmapData"), .{ .object = ctor }, .{}, false);
}

/// The buffer behind a receiver, or null when it is not a BitmapData —
/// or has been disposed, which every member treats the same way.
pub fn dataOf(vm: *Vm, this: Value) ?*BitmapData {
    if (this != .object) return null;
    return switch (vm.objects.get(this.object).native) {
        .bitmap_data => |ptr| blk: {
            const bd: *BitmapData = @ptrCast(@alignCast(ptr));
            break :blk if (bd.disposed) null else bd;
        },
        else => null,
    };
}

fn construct(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // A width alone is not enough, and the answer is UNDEFINED rather
    // than a zero-sized object — `instanceof` fails on it too.
    if (args.len < 2) return .undefined_value;
    const width = try toU32(vm, args[0]);
    const height = try toU32(vm, args[1]);
    // An explicitly passed `undefined` is COERCED, not defaulted — only
    // an ABSENT argument falls back (ruffle's `UndefinedAs::Some`). So
    // `new BitmapData(5, 6, undefined)` is OPAQUE, where `new
    // BitmapData(5, 6)` is transparent.
    const transparency = if (args.len > 2)
        value_mod.toBoolean(args[2], vm.swf_version)
    else
        true;
    const fill = if (args.len > 3) try toU32(vm, args[3]) else 0xFFFF_FFFF;

    if (!pixels.isSizeValid(vm.swf_version, width, height)) return .undefined_value;

    const bd = try vm.arena().create(BitmapData);
    bd.* = try BitmapData.init(vm.gpa, width, height, transparency, fill);
    vm.objects.get(this.object).native = .{ .bitmap_data = @ptrCast(bd) };
    return this;
}

fn toU32(vm: *Vm, v: Value) !u32 {
    return @bitCast(value_mod.toInt32(try vm.toNumber(v)));
}

/// Coordinates are UNSIGNED, so a negative one wraps to an enormous
/// positive and lands out of bounds rather than before the origin.
fn coord(vm: *Vm, v: Value) !i64 {
    return @as(i64, try toU32(vm, v));
}

/// Every pixel member answers -1 — not undefined — when it is short of
/// arguments or the receiver is not a live BitmapData.
const BAD: Value = .{ .number = -1 };

// --- properties ----------------------------------------------------------------

/// A DISPOSED bitmap reports -1, not 0 — the object outlives its pixels
/// and says so.
fn getWidth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .number = @floatFromInt(bd.width) };
}

fn getHeight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .number = @floatFromInt(bd.height) };
}

fn getTransparent(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .boolean = bd.transparency };
}

/// A `flash.geom.Rectangle` at the origin. A fresh one every read.
fn getRectangle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.rectangle_proto };
    try vm.objects.put(h, S("x"), .{ .number = 0 }, false);
    try vm.objects.put(h, S("y"), .{ .number = 0 }, false);
    try vm.objects.put(h, S("width"), .{ .number = @floatFromInt(bd.width) }, false);
    try vm.objects.put(h, S("height"), .{ .number = @floatFromInt(bd.height) }, false);
    return .{ .object = h };
}

/// -1 when the receiver IS a BitmapData that has been disposed;
/// undefined when it never was one at all.
fn disposedOr(vm: *Vm, this: Value) Value {
    if (this != .object) return .undefined_value;
    return switch (vm.objects.get(this.object).native) {
        .bitmap_data => .{ .number = -1 },
        else => .undefined_value,
    };
}

// --- pixels ---------------------------------------------------------------------

fn getPixel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    return .{ .number = @floatFromInt(bd.getPixel(try coord(vm, args[0]), try coord(vm, args[1]))) };
}

fn getPixel32(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    // SIGNED: an alpha above 0x7F makes the ARGB word negative in AVM1.
    const raw = bd.getPixel32(try coord(vm, args[0]), try coord(vm, args[1]));
    return .{ .number = @floatFromInt(@as(i32, @bitCast(raw))) };
}

fn setPixel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    bd.setPixel(try coord(vm, args[0]), try coord(vm, args[1]), try toU32(vm, args[2]));
    // ZERO, not undefined — both setters report success as a number.
    return .{ .number = 0 };
}

fn setPixel32(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    bd.setPixel32(try coord(vm, args[0]), try coord(vm, args[1]), try toU32(vm, args[2]));
    return .{ .number = 0 };
}

fn dispose(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return .undefined_value;
    bd.dispose(vm.gpa);
    return .undefined_value;
}

fn clone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return .undefined_value;
    const out = try vm.objects.create();
    vm.objects.get(out).proto = .{ .object = vm.bitmapdata_proto };
    const copy = try vm.arena().create(BitmapData);
    copy.* = try BitmapData.init(vm.gpa, bd.width, bd.height, bd.transparency, 0);
    @memcpy(copy.data, bd.data);
    vm.objects.get(out).native = .{ .bitmap_data = @ptrCast(copy) };
    return .{ .object = out };
}
