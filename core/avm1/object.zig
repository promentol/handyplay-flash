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

/// ruffle property.rs VERSION_MASKS — index by SWF version. Above v9 the
/// table simply runs out and NOTHING is gated; see `versionHidden`.
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
    // Past the table the mask is ZERO, not the last row: ruffle indexes
    // with `.get(version).unwrap_or_default()`, so a SWF10 movie hides
    // nothing at all (corpus mcl_events_swf_version detects v10 exactly
    // by finding the highest gate bit still visible).
    if (swf_version >= VERSION_MASKS.len) return false;
    return (attrs.version_bits & VERSION_MASKS[swf_version]) != 0;
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
    /// A serial number handed out when the property is CREATED. Ruffle's
    /// `Property::id` (property.rs `NEXT_PROPERTY_ID`), and it exists for
    /// exactly one purpose: the per-property recursion limit counts
    /// activations of the SAME property, so a getter that deletes and
    /// re-adds its own property escapes that limit and hits the call-depth
    /// one instead (corpus virtual_property_recursion_scope).
    gen: u32 = 0,
};

/// An `Object.prototype.watch` registration. Kept in a list of its own, not
/// on `Property`: a watch can be installed on a name that has no property
/// yet, and it must survive that property being deleted.
pub const Watcher = struct {
    key: strings.AvmString,
    callback: ObjectHandle,
    user_data: Value,
};

/// Native function signature. `vm` is *runtime.Vm behind anyopaque to keep
/// this module cycle-light; runtime.zig provides a typed wrapper.
pub const NativeFn = *const fn (vm: *anyopaque, this: Value, args: []const Value) anyerror!Value;

/// A native that dispatches on an ASnative INDEX. Flash's builtins are
/// not individual functions but numbered slots inside a category:
/// `ASnative(200, 0)` IS `Math.abs`, and `Math.abs` is that slot. One
/// Zig function per category, keyed by index, mirrors that exactly
/// (ruffle's `TableNativeFunction`).
pub const TableNativeFn = *const fn (
    vm: *anyopaque,
    this: Value,
    args: []const Value,
    index: u16,
) anyerror!Value;

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
    /// The clip this function was DEFINED in. SWF6+ calls are proper
    /// closures and use it; SWF5 calls are not and use `this`'s clip
    /// instead (ruffle function.rs:295-334).
    base_clip: ObjectHandle = 0,
    /// That clip's PATH, kept because ruffle stores the base clip as a
    /// `MovieClipReference` and re-resolves it on every call. Remove the
    /// clip and the reference goes dead; put a clip back at the same
    /// path and the function's `_parent` comes back to life with it
    /// (corpus function_base_clip_readded).
    base_clip_path: strings.AvmString = &.{},
};

pub const FunctionKind = union(enum) {
    native: NativeFn,
    /// A numbered slot in an ASnative category — see `TableNativeFn`.
    table_native: struct { f: TableNativeFn, index: u16 },
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
    /// A non-clip display object that is still scriptable — buttons and
    /// text fields. Ruffle gives object1 to those two and to MovieClip,
    /// but NOT to graphics or static text.
    display: *anyopaque,
    /// `super`: the same `this`, viewed with `depth` layers of prototype
    /// peeled off (ruffle object/super_object.rs).
    super_obj: struct { this: ObjectHandle, depth: u8 },
    /// A display object whose instance is GONE. The script reference
    /// survives it (AVM1 objects outlive the display list), so the pointer
    /// has to be cut, but the object must still remember what it was: a
    /// removed clip stops receiving broadcasts and timer callbacks, and
    /// `.none` would make it indistinguishable from a plain object.
    removed_display,
    /// A `Date`: milliseconds since the Unix epoch, UTC (NaN = invalid).
    date: f64,
    /// A `TextFormat`'s value struct, owned by the VM arena. Opaque here
    /// so the object model keeps no dependency on the text module.
    text_format: *anyopaque,
    /// A `NetStream`'s playback state, owned by the VM arena. Opaque
    /// for the same reason as the others.
    net_stream: *anyopaque,
    /// A `BitmapData`'s pixel buffer, owned by the VM arena. Opaque so
    /// the object model keeps no dependency on the bitmap module.
    bitmap_data: *anyopaque,
    /// One node of an XML tree, and the document-level state an `XML`
    /// adds on top of its root. A document object carries `xml_doc` and
    /// answers to every node accessor through its root, so the two are
    /// resolved together (`globals/xml.zig` `nodeOf`).
    xml_node: *anyopaque,
    xml_doc: *anyopaque,
    /// flash.geom.Transform — a live view of the display object whose AVM1
    /// handle this holds. A handle rather than a pointer so a removed clip
    /// simply stops resolving, like every other retained reference.
    transform: ObjectHandle,
};

pub const ScriptObject = struct {
    proto: Value = .undefined_value,
    /// In ruffle `__proto__` is not a synthesized accessor — it is a real
    /// entry in the property map, inserted at construction with
    /// DontEnum|DontDelete (script_object.rs:145). We keep the proto in a
    /// field and carry only its ATTRIBUTES here, which is enough for the
    /// one thing content can observe: `ASSetPropFlags` clearing DontDelete
    /// makes `delete o.__proto__` succeed (corpus object_prototypes).
    proto_attrs: Attributes = .{ .dont_enum = true, .dont_delete = true },
    props: std.ArrayList(Property) = .empty,
    native: NativeInfo = .none,
    /// Marks scope objects created by With (barrier rules differ slightly).
    is_with_scope: bool = false,
    /// A scope node whose VALUES live on another object: `with (o)` pushes
    /// a node onto the chain but every lookup, assignment and definition
    /// inside it goes to `o` — including a clip's children and display
    /// properties. Ruffle models this as `Scope { class: With, values: o }`
    /// (scope.rs:26); we keep the node so the chain stays a list of nodes
    /// nobody else aliases.
    scope_values: ObjectHandle = 0,
    /// AS2 interfaces this PROTOTYPE implements, as their prototypes
    /// (ActionImplements). `instanceof` must walk these as well as the
    /// prototype chain.
    interfaces: []const ObjectHandle = &.{},
    /// Has `implements` run on this object at all? An EMPTY list still
    /// counts — ruffle's `get_or_insert` locks the slot on the first
    /// call, so a later `implements` is ignored even when the first
    /// named nothing usable (corpus interface_implements_op).
    interfaces_set: bool = false,
    /// `new X()` uses this native constructor's RETURN VALUE rather than
    /// the fresh instance. Ruffle marks the handful of classes declared
    /// with a separate constructor half; the rest answer `this` whatever
    /// the native returned, which is what lets most native constructors
    /// return undefined so `super()` in a subclass does too
    /// (corpus native_subclasses vs bitmap_data_max_size_swf9).
    ctor_propagates: bool = false,
    /// Scope-chain parent link (scope objects only; 0 = none).
    scope_parent: ObjectHandle = 0,
    /// `Object.prototype.watch` registrations. Almost always empty.
    watchers: []Watcher = &.{},

    pub fn findWatcher(self: *const ScriptObject, name: strings.AvmString, cs: bool) ?*Watcher {
        for (self.watchers) |*w| {
            const match = if (cs) strings.eql(w.key, name) else strings.eqlIgnoreCase(w.key, name);
            if (match) return w;
        }
        return null;
    }

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
    /// Serial for `Property.gen`. Never reused, so a deleted-and-recreated
    /// property is a DIFFERENT property to the recursion limit.
    next_prop_gen: u32 = 1,
    arena: std.mem.Allocator,
    slots: std.ArrayList(ScriptObject) = .empty,
    /// Needed here because reads must honour the ASSetPropFlags version
    /// gate (ruffle filters in get_local_stored, not just on enumeration).
    swf_version: u8 = 6,
    /// Set when a prototype chain walk hit the depth cap — i.e. the chain
    /// is a cycle. Flash treats that as a hard stack overflow and abandons
    /// the running action, so the interpreter checks and bails rather than
    /// quietly reporting "not found" (corpus watch_proto_recursion stops
    /// mid-handler). Cleared by the interpreter when it acts on it.
    chain_overflow: bool = false,
    /// Slots the collector handed back, newest first. `create` takes from
    /// here before growing, which is what stops the table climbing
    /// forever in a movie that makes objects every frame (gc.zig).
    free_list: std.ArrayList(ObjectHandle) = .empty,

    pub fn init(arena: std.mem.Allocator) Objects {
        return .{ .arena = arena };
    }

    pub fn create(self: *Objects) !ObjectHandle {
        if (self.free_list.pop()) |h| {
            self.slots.items[h - 1] = .{};
            return h;
        }
        try self.slots.append(self.arena, .{});
        return @intCast(self.slots.items.len); // 1-based
    }

    pub fn createWith(self: *Objects, obj: ScriptObject) !ObjectHandle {
        if (self.free_list.pop()) |h| {
            self.slots.items[h - 1] = obj;
            return h;
        }
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

    /// A property plus the object that OWNS it. The owner matters for the
    /// per-property recursion budget: ruffle keys it on the Property's
    /// identity, so every instance inheriting one accessor shares a single
    /// budget rather than getting one each.
    pub const Located = struct { owner: ObjectHandle, prop: *Property };

    /// Find a property slot anywhere on the proto chain, for READING: a
    /// version-gated property is skipped and the search continues UP the
    /// chain, so a hidden own property lets the prototype's show through
    /// (ruffle filters inside get_local_stored, per object).
    pub fn findChained(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?*Property {
        return (self.findChainedLocated(h, name, cs) orelse return null).prop;
    }

    pub fn findChainedLocated(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?Located {
        var current = h;
        var depth: u32 = 0;
        while (depth < 256) : (depth += 1) {
            if (depth == 255) self.chain_overflow = true;
            if (self.findOwn(current, name, cs)) |p| {
                if (!versionHidden(p.attrs, self.swf_version)) return .{ .owner = current, .prop = p };
            }
            const proto = self.get(current).proto;
            if (proto != .object) return null;
            if (isDisplay(self.get(proto.object).native)) return null;
            current = proto.object;
        }
        return null;
    }

    /// A display object reached AS someone's prototype contributes nothing:
    /// the chain ends there. Inferred from corpus super_edge_cases, whose
    /// recorded Flash output cannot see `_root.__proto__` or
    /// `_root.__constructor__` through `obj.__proto__ = _root`. It does not
    /// affect a clip's OWN lookups, which start at the clip itself.
    fn isDisplay(n: NativeInfo) bool {
        return n == .clip or n == .display or n == .removed_display;
    }

    /// How many prototype hops from `h` to the object that owns `name`
    /// (0 = own property). `super` inside a method must start from THAT
    /// object, not from `this`, or it re-finds the same method.
    pub fn protoDepth(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?u8 {
        var current = h;
        var depth: u8 = 0;
        while (depth < 255) : (depth += 1) {
            if (self.findOwn(current, name, cs)) |p| {
                if (!versionHidden(p.attrs, self.swf_version)) return depth;
            }
            const proto = self.get(current).proto;
            if (proto != .object) return null;
            current = proto.object;
        }
        return null;
    }

    /// Same walk WITHOUT the version gate — writes must still find (and
    /// honour the accessors of) a gated slot rather than shadowing it.
    pub fn findChainedForWrite(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?*Property {
        return (self.findChainedForWriteLocated(h, name, cs) orelse return null).prop;
    }

    pub fn findChainedForWriteLocated(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?Located {
        var current = h;
        var depth: u32 = 0;
        while (depth < 256) : (depth += 1) {
            if (self.findOwn(current, name, cs)) |p| return .{ .owner = current, .prop = p };
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
        // A version-gated property reads as ABSENT, so the proto chain (and
        // then the display object) shows through — ruffle script_object.rs
        // `.filter(|p| p.allow_swf_version(...))` inside get_local_stored.
        if (versionHidden(o.props.items[i].attrs, self.swf_version)) return null;
        return o.props.items[i].value;
    }

    /// Proto-chain read (ES3 [[Get]]), depth-capped against cycles.
    pub fn getChained(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) ?Value {
        var current = h;
        var depth: u32 = 0;
        while (depth < 256) : (depth += 1) {
            if (depth == 255) self.chain_overflow = true;
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
            // Overwriting a property CLEARS its SWF-version gate (ruffle
            // property.rs `set_data`), so a member hidden by
            // `ASSetPropFlags` becomes visible again the moment script
            // assigns to it — corpus as_set_prop_flags_version.
            p.attrs.version_bits = 0;
            return;
        }
        const key = try self.arena.dupe(u16, name);
        self.next_prop_gen +%= 1;
        try o.props.append(self.arena, .{ .key = key, .value = v, .gen = self.next_prop_gen });
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
            o.props.items[i] = .{
                .key = o.props.items[i].key,
                .value = v,
                .attrs = attrs,
                .gen = o.props.items[i].gen,
            };
            return;
        }
        const key = try self.arena.dupe(u16, name);
        self.next_prop_gen +%= 1;
        try o.props.append(self.arena, .{ .key = key, .value = v, .attrs = attrs, .gen = self.next_prop_gen });
    }

    /// delete — false when absent or DontDelete.
    pub fn deleteOwn(self: *Objects, h: ObjectHandle, name: strings.AvmString, cs: bool) bool {
        const o = self.get(h);
        // `__proto__` is a real (normally undeletable) map entry in ruffle;
        // an object without a proto never had the entry at all.
        const is_proto = if (cs)
            strings.eql(name, strings.ascii("__proto__"))
        else
            strings.eqlIgnoreCase(name, strings.ascii("__proto__"));
        if (is_proto) {
            if (o.proto == .undefined_value) return false;
            if (o.proto_attrs.dont_delete) return false;
            o.proto = .undefined_value;
            return true;
        }
        const i = o.find(name, cs) orelse return false;
        if (o.props.items[i].attrs.dont_delete) return false;
        _ = o.props.orderedRemove(i);
        return true;
    }

    /// Drop every deletable own property. `loadMovie` does this to its
    /// target before the new movie's code runs, so variables written by
    /// the OLD movie are gone while ones written by the incoming
    /// `onLoad` handlers survive (corpus loadmovie_var_persistence).
    pub fn clearDeletable(self: *Objects, h: ObjectHandle) void {
        const o = self.get(h);
        var i: usize = 0;
        while (i < o.props.items.len) {
            if (o.props.items[i].attrs.dont_delete) {
                i += 1;
            } else {
                _ = o.props.orderedRemove(i);
            }
        }
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
