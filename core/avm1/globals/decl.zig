//! Declaration helpers shared by every built-in class.
//!
//! Ruffle declares its globals through a `declare_properties!` macro that
//! carries the FULL attribute set on each member — `DONT_ENUM`,
//! `DONT_DELETE`, `READ_ONLY` and a `VERSION_N` gate. Our two hand-rolled
//! `method()` helpers (one in globals.zig, one in globals/movie_clip.zig)
//! only ever set `dont_enum`, so every built-in was deletable and visible at
//! every SWF version. This module is the single place those flags live.
//!
//! The version gate is not decoration: `Attributes.version_bits` is checked
//! by `object.versionHidden` on every read AND enumeration, which is how
//! `MovieClip.prototype.getNextHighestDepth` correctly does not exist in a
//! SWF6 movie.
//!
//! Reference: reference/ruffle/core/src/avm1/property.rs (the bit values)
//! and core/src/avm1/globals/*.rs (the per-member flags).

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const object_mod = @import("../object.zig");
const runtime = @import("../runtime.zig");

pub const Value = value_mod.Value;
pub const Vm = runtime.Vm;
pub const ObjectHandle = value_mod.ObjectHandle;
pub const Attributes = object_mod.Attributes;
pub const NativeFn = object_mod.NativeFn;
const S = strings.ascii;

/// `Attribute::VERSION_N` from ruffle property.rs. These live in bits 3..15,
/// which is exactly the half of the word `Attributes.version_bits` keeps.
/// VERSION_5 is zero — "available everywhere the object model exists".
pub const V5: u16 = 0;
pub const V6: u16 = 0b0000_0000_1000_0000;
pub const V7: u16 = 0b0000_0101_0000_0000;
pub const V8: u16 = 0b0001_0000_0000_0000;
pub const V9: u16 = 0b0010_0000_0000_0000;
pub const V10: u16 = 0b0100_0000_0000_0000;

/// What ruffle puts on nearly every built-in member: invisible to `for..in`
/// and not deletable by script.
pub const hidden: Attributes = .{ .dont_enum = true, .dont_delete = true };
/// Same, plus unwritable — the flag set on constants and on the methods
/// ruffle marks READ_ONLY (Key's, Color's, `getDepth`).
pub const frozen: Attributes = .{ .dont_enum = true, .dont_delete = true, .read_only = true };

pub fn ver(a: Attributes, bits: u16) Attributes {
    var out = a;
    out.version_bits = bits;
    return out;
}

/// Built-ins install case-PRESERVING; lookup applies the version's case rule.
const CS = false;

pub fn vmOf(p: *anyopaque) *Vm {
    return @ptrCast(@alignCast(p));
}

/// The i-th argument, or undefined. Every native fn needs this.
pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined_value;
}

pub fn method(vm: *Vm, target: ObjectHandle, comptime name: []const u8, f: NativeFn, attrs: Attributes) !void {
    const h = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(target, S(name), .{ .object = h }, attrs, CS);
}

pub fn value(vm: *Vm, target: ObjectHandle, comptime name: []const u8, v: Value, attrs: Attributes) !void {
    try vm.objects.putWithAttrs(target, S(name), v, attrs, CS);
}

pub fn constNum(vm: *Vm, target: ObjectHandle, comptime name: []const u8, n: f64) !void {
    try vm.objects.putWithAttrs(target, S(name), .{ .number = n }, frozen, CS);
}

pub fn constStr(vm: *Vm, target: ObjectHandle, comptime name: []const u8, comptime s: []const u8) !void {
    try vm.objects.putWithAttrs(target, S(name), .{ .string = S(s) }, frozen, CS);
}

/// A native accessor pair — the same `Property.getter/setter` slots
/// `Object.addProperty` fills, so reads and writes route through the
/// existing accessor-aware paths in `Vm.getProperty`/`setProperty`.
/// A null setter makes the property read-only in the ES3 sense: writes are
/// silently dropped rather than shadowing it.
pub fn property(
    vm: *Vm,
    target: ObjectHandle,
    comptime name: []const u8,
    get: NativeFn,
    set: ?NativeFn,
    attrs: Attributes,
) !void {
    const getter = try vm.newNativeFn(get);
    const setter: ObjectHandle = if (set) |s| try vm.newNativeFn(s) else 0;
    try putAccessor(vm, target, S(name), getter, setter, attrs);
}

pub fn putAccessor(
    vm: *Vm,
    target: ObjectHandle,
    name: strings.AvmString,
    getter: ObjectHandle,
    setter: ObjectHandle,
    attrs: Attributes,
) !void {
    const o = vm.objects.get(target);
    if (o.find(name, CS)) |i| {
        o.props.items[i].value = .undefined_value;
        o.props.items[i].attrs = attrs;
        o.props.items[i].getter = getter;
        o.props.items[i].setter = setter;
        return;
    }
    const key = try vm.arena().dupe(u16, name);
    vm.objects.next_prop_gen +%= 1;
    try o.props.append(vm.arena(), .{
        .key = key,
        .value = .undefined_value,
        .attrs = attrs,
        .getter = getter,
        .setter = setter,
        .gen = vm.objects.next_prop_gen,
    });
}

/// A constructor on _global with its prototype cross-linked. Returns the
/// constructor handle so callers can hang statics off it.
pub fn class(
    vm: *Vm,
    comptime name: []const u8,
    f: NativeFn,
    proto: ObjectHandle,
    attrs: Attributes,
) !ObjectHandle {
    const h = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(h, S("prototype"), .{ .object = proto }, hidden, CS);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = h }, hidden, CS);
    try vm.objects.putWithAttrs(vm.globals, S(name), .{ .object = h }, attrs, CS);
    return h;
}

/// A plain object hung off _global (Math, Key, Mouse, Stage, System …).
pub fn namespace(vm: *Vm, comptime name: []const u8, attrs: Attributes) !ObjectHandle {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.object_proto };
    try vm.objects.putWithAttrs(vm.globals, S(name), .{ .object = h }, attrs, CS);
    return h;
}

/// A child object of an existing one (System.capabilities, System.security).
pub fn subObject(vm: *Vm, parent: ObjectHandle, comptime name: []const u8, attrs: Attributes) !ObjectHandle {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.object_proto };
    try vm.objects.putWithAttrs(parent, S(name), .{ .object = h }, attrs, CS);
    return h;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "version gates hide a member from older players" {
    // getNextHighestDepth is VERSION_7: absent in SWF6, present in SWF7.
    for ([_]struct { v: u8, visible: bool }{
        .{ .v = 6, .visible = false },
        .{ .v = 7, .visible = true },
        .{ .v = 8, .visible = true },
    }) |case| {
        const vm = try Vm.create(testing.allocator, case.v);
        defer vm.destroy();
        const obj = try vm.newObject();
        try method(vm, obj, "gated", stubFn, ver(hidden, V7));
        try testing.expectEqual(
            case.visible,
            vm.objects.getOwn(obj, S("gated"), false) != null,
        );
    }
}

test "accessor properties route through Vm.getProperty" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();
    const obj = try vm.newObject();
    try property(vm, obj, "answer", getAnswer, null, hidden);

    const v = try vm.getProperty(obj, S("answer"), .{ .object = obj });
    try testing.expectEqual(@as(f64, 42), v.number);

    // Getter-only: the write is dropped, not shadowed.
    try vm.setProperty(obj, S("answer"), .{ .number = 1 }, .{ .object = obj });
    const after = try vm.getProperty(obj, S("answer"), .{ .object = obj });
    try testing.expectEqual(@as(f64, 42), after.number);

    // ...and DONT_DELETE really holds.
    try testing.expect(!vm.objects.deleteOwn(obj, S("answer"), false));
}

fn stubFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn getAnswer(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .number = 42 };
}
