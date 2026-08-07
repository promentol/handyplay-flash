//! AVM1 object model: one concrete ScriptObject (modern-Ruffle shape — no
//! vtables) + a NativeInfo payload, living in a handle-indexed table
//! (ADR D2: u32 handles keep save-states a table walk; collection is a
//! recorded follow-up — objects free with the VM arena).
//!
//! Properties are an insertion-ordered list (enumeration order) with
//! ASCII case-insensitive lookup below SWF7 (property names; ruffle
//! property_map.rs). Attribute flags per ES3: DontEnum/DontDelete/ReadOnly.

const std = @import("std");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const opcodes = @import("opcodes.zig");

const Value = value_mod.Value;
pub const ObjectHandle = value_mod.ObjectHandle;

pub const Attributes = packed struct {
    dont_enum: bool = false,
    dont_delete: bool = false,
    read_only: bool = false,
    /// ASSetPropFlags bits 3..15 are SWF-VERSION GATES, not unknown
    /// flags: a property is hidden when `raw & VERSION_MASKS[version]`
    /// is non-zero (ruffle property.rs). Stored raw so the gate survives.
    version_bits: u16 = 0,
};

/// ruffle property.rs VERSION_MASKS — index by SWF version (clamped 0-9).
pub const VERSION_MASKS = [10]u16{
    0b0111_1111_1111_1000, 0b0111_1111_1111_1000, 0b0111_1111_1111_1000,
    0b0111_1111_1111_1000, 0b0111_1111_1111_1000,
    0b0111_0100_1000_0000, // v5
    0b0111_0101_0000_0000, // v6
    0b0111_0000_0000_0000, // v7
    0b0110_0000_0000_0000, // v8
    0b0100_0000_0000_0000, // v9
};

/// A property is invisible when its version gate matches the player's
/// SWF version, or when DontEnum is set (enumeration only).
pub fn versionHidden(attrs: Attributes, swf_version: u8) bool {
    const idx: usize = @min(swf_version, 9);
    return (attrs.version_bits & VERSION_MASKS[idx]) != 0;
}

pub const Property = struct {
    key: strings.AvmString,
    value: Value,
    attrs: Attributes = .{},
    /// Object.addProperty accessors (0 = plain data property). Reads call
    /// the getter with `this`; writes call the setter (a getter-only
    /// property silently ignores writes, like ES3/Flash).
    getter: ObjectHandle = 0,
    setter: ObjectHandle = 0,
};

/// Native function signature. `vm` is *runtime.Vm behind anyopaque to keep
/// this module cycle-light; runtime.zig provides a typed wrapper.
pub const NativeFn = *const fn (vm: *anyopaque, this: Value, args: []const Value) anyerror!Value;

/// Bytecode-defined function (DefineFunction / DefineFunction2).
pub const Avm1Function = struct {
    body: []const u8,
    param_count: u16,
    params_raw: []const u8,
    /// DefineFunction2 extras (with_registers selects param decoding).
    with_registers: bool = false,
    register_count: u8 = 0,
    flags: opcodes.Function2Flags = @bitCast(@as(u16, 0)),
    /// Captured scope (handle of the defining scope object chain).
    scope: ObjectHandle = 0,
    /// Constant pool active at definition time (index into Vm pools).
    constant_pool: u32 = 0,
    /// swf_version of the defining movie (drives case rules inside).
    swf_version: u8 = 6,
};

pub const FunctionKind = union(enum) {
    native: NativeFn,
    avm1: Avm1Function,
};

/// "What is this object really" — grows per milestone (movie clips land
/// with the display glue, boxed primitives with the globals).
pub const NativeInfo = union(enum) {
    none,
    function: FunctionKind,
    array,
    boxed_bool: bool,
    boxed_number: f64,
    boxed_string: strings.AvmString,
    /// Display glue: an on-stage MovieClip (pointer into the display tree).
    clip: *anyopaque,
};

pub const ScriptObject = struct {
    proto: Value = .undefined_value,
    props: std.ArrayList(Property) = .empty,
    native: NativeInfo = .none,
    /// Marks scope objects created by With (barrier rules differ slightly).
    is_with_scope: bool = false,
    /// Scope-chain parent link (scope objects only; 0 = none).
    scope_parent: ObjectHandle = 0,

    pub fn find(self: *const ScriptObject, name: strings.AvmString, case_sensitive: bool) ?usize {
        for (self.props.items, 0..) |p, i| {
            const match = if (case_sensitive)
                strings.eql(p.key, name)
            else
                strings.eqlIgnoreCase(p.key, name);
            if (match) return i;
        }
        return null;
    }
};

/// The handle-indexed object table. Handle 0 is reserved/invalid.
pub const Objects = struct {
    arena: std.mem.Allocator,
    slots: std.ArrayList(ScriptObject) = .empty,

    pub fn init(arena: std.mem.Allocator) Objects {
        return .{ .arena = arena };
    }

    pub fn create(self: *Objects) !ObjectHandle {
        try self.slots.append(self.arena, .{});
        return @intCast(self.slots.items.len); // 1-based
    }

    pub fn createWith(self: *Objects, obj: ScriptObject) !ObjectHandle {
        try self.slots.append(self.arena, obj);
        return @intCast(self.slots.items.len);
    }

    pub fn get(self: *Objects, h: ObjectHandle) *ScriptObject {
        return &self.slots.items[h - 1];
    }

    pub fn getConst(self: *const Objects, h: ObjectHandle) *const ScriptObject {
        return &self.slots.items[h - 1];
    }

    /// Find the own property SLOT (accessor-aware callers use this).
    pub fn findOwn(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?*Property {
        const o = self.get(h);
        const i = o.find(name, cs) orelse return null;
        return &o.props.items[i];
    }

    /// Find a property slot anywhere on the proto chain.
    pub fn findChained(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?*Property {
        var current = h;
        var depth: u32 = 0;
        while (depth < 256) : (depth += 1) {
            if (self.findOwn(current, name, cs)) |p| return p;
            const proto = self.get(current).proto;
            if (proto != .object) return null;
            current = proto.object;
        }
        return null;
    }

    /// Own-property read (no proto chain).
    pub fn getOwn(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?Value {
        const o = self.get(h);
        const i = o.find(name, cs) orelse return null;
        return o.props.items[i].value;
    }

    /// Proto-chain read (ES3 [[Get]]), depth-capped against cycles.
    pub fn getChained(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?Value {
        var current = h;
        var depth: u32 = 0;
        while (depth < 256) : (depth += 1) {
            if (self.getOwn(current, name, cs)) |v| return v;
            const proto = self.get(current).proto;
            if (proto != .object) return null;
            current = proto.object;
        }
        return null;
    }

    /// [[Put]] — respects ReadOnly on the own property; otherwise writes
    /// locally (AVM1 has no setters until watch/addProperty, M4+).
    pub fn put(self: *Objects, h: ObjectHandle, name: strings.AvmString, v: Value, cs: bool) !void {
        const o = self.get(h);
        if (o.find(name, cs)) |i| {
            const p = &o.props.items[i];
            if (p.attrs.read_only) return;
            p.value = v;
            return;
        }
        const key = try self.arena.dupe(u16, name);
        try o.props.append(self.arena, .{ .key = key, .value = v });
    }

    pub fn putWithAttrs(
        self: *Objects,
        h: ObjectHandle,
        name: strings.AvmString,
        v: Value,
        attrs: Attributes,
        cs: bool,
    ) !void {
        const o = self.get(h);
        if (o.find(name, cs)) |i| {
            o.props.items[i] = .{ .key = o.props.items[i].key, .value = v, .attrs = attrs };
            return;
        }
        const key = try self.arena.dupe(u16, name);
        try o.props.append(self.arena, .{ .key = key, .value = v, .attrs = attrs });
    }

    /// delete — false when absent or DontDelete.
    pub fn deleteOwn(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) bool {
        const o = self.get(h);
        const i = o.find(name, cs) orelse return false;
        if (o.props.items[i].attrs.dont_delete) return false;
        _ = o.props.orderedRemove(i);
        return true;
    }

    pub fn hasOwn(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) bool {
        return self.get(h).find(name, cs) != null;
    }

    pub fn hasChained(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) bool {
        return self.getChained(h, name, cs) != null;
    }
};

// --- Tests -----------------------------------------------------------------

test "put/get with case rules, proto chain, delete, read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var objs = Objects.init(arena.allocator());
    const S = strings.ascii;

    const proto = try objs.create();
    try objs.put(proto, S("inherited"), .{ .number = 7 }, true);
    const obj = try objs.create();
    objs.get(obj).proto = .{ .object = proto };

    try objs.put(obj, S("Foo"), .{ .number = 1 }, true);
    // Case-insensitive (SWF < 7): "foo" finds "Foo" and overwrites it.
    try objs.put(obj, S("foo"), .{ .number = 2 }, false);
    try std.testing.expectEqual(@as(f64, 2), objs.getOwn(obj, S("FOO"), false).?.number);
    // Case-sensitive: "foo" is absent as its own key.
    try std.testing.expectEqual(@as(?Value, null), objs.getOwn(obj, S("foo"), true));

    // Proto chain.
    try std.testing.expectEqual(@as(f64, 7), objs.getChained(obj, S("inherited"), true).?.number);
    try std.testing.expectEqual(@as(?Value, null), objs.getChained(obj, S("missing"), true));

    // ReadOnly + DontDelete.
    try objs.putWithAttrs(obj, S("locked"), .{ .number = 3 }, .{ .read_only = true, .dont_delete = true }, true);
    try objs.put(obj, S("locked"), .{ .number = 9 }, true);
    try std.testing.expectEqual(@as(f64, 3), objs.getOwn(obj, S("locked"), true).?.number);
    try std.testing.expect(!objs.deleteOwn(obj, S("locked"), true));
    try std.testing.expect(objs.deleteOwn(obj, S("Foo"), true));
    try std.testing.expect(!objs.hasOwn(obj, S("Foo"), true));
}
