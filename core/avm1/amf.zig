//! AMF0 serialisation — the wire format `NetConnection.call`,
//! `LocalConnection.send` and `SharedObject.flush` all speak.
//!
//! Only the WRITE half lives here; nothing in the corpus reads AMF back
//! yet. The rules that are not in the spec, and that the corpus pins:
//!
//!   * Functions are SKIPPED entirely — not written as undefined, just
//!     absent from the object's property list.
//!   * A getter is written as `undefined` WITHOUT being called. Flash
//!     never evaluates accessors while serialising.
//!   * Properties come out in reverse enumeration order, which is
//!     insertion order, and `ASSetPropFlags` does not hide them.
//!   * A display object is `undefined`.
//!   * An object whose CONSTRUCTOR has a name registered through
//!     `Object.registerClass` is a TYPED object carrying that name. The
//!     constructor is found by reading `constructor` (own, and only when
//!     it is not an accessor) and falling back to the hidden
//!     `__constructor__` — attributes are ignored.
//!   * The same object seen twice is a REFERENCE to the first sighting.

const std = @import("std");
const runtime = @import("runtime.zig");
const object_mod = @import("object.zig");
const strings = @import("string.zig");
const value_mod = @import("value.zig");

const Vm = runtime.Vm;
const Value = runtime.Value;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

pub const Marker = struct {
    pub const NUMBER: u8 = 0x00;
    pub const BOOLEAN: u8 = 0x01;
    pub const STRING: u8 = 0x02;
    pub const OBJECT: u8 = 0x03;
    pub const NULL: u8 = 0x05;
    pub const UNDEFINED: u8 = 0x06;
    pub const REFERENCE: u8 = 0x07;
    pub const ECMA_ARRAY: u8 = 0x08;
    pub const OBJECT_END: u8 = 0x09;
    pub const STRICT_ARRAY: u8 = 0x0A;
    pub const DATE: u8 = 0x0B;
    pub const LONG_STRING: u8 = 0x0C;
    pub const XML: u8 = 0x0F;
    pub const TYPED_OBJECT: u8 = 0x10;
};

/// One serialisation run. The reference table is per-packet: every
/// object written gets an index, and a second sighting writes that
/// index instead of the body.
pub const Writer = struct {
    vm: *Vm,
    out: *std.ArrayList(u8),
    /// Objects already written, in order — the index IS the AMF
    /// reference number.
    seen: std.ArrayList(ObjectHandle) = .empty,
    depth: u32 = 0,

    pub fn deinit(self: *Writer) void {
        self.seen.deinit(self.vm.arena());
    }

    fn a(self: *Writer) std.mem.Allocator {
        return self.vm.arena();
    }

    fn byte(self: *Writer, v: u8) !void {
        try self.out.append(self.a(), v);
    }

    fn u16be(self: *Writer, v: u16) !void {
        try self.out.append(self.a(), @intCast(v >> 8));
        try self.out.append(self.a(), @intCast(v & 0xFF));
    }

    fn u32be(self: *Writer, v: u32) !void {
        var i: u5 = 4;
        while (i > 0) {
            i -= 1;
            try self.out.append(self.a(), @intCast((v >> (@as(u5, i) * 8)) & 0xFF));
        }
    }

    fn f64be(self: *Writer, v: f64) !void {
        const bits: u64 = @bitCast(v);
        var i: u6 = 8;
        while (i > 0) {
            i -= 1;
            try self.out.append(self.a(), @intCast((bits >> (@as(u6, i) * 8)) & 0xFF));
        }
    }

    /// AMF strings are UTF-8 with a 16-bit length; past 65535 the
    /// LONG_STRING form takes a 32-bit one.
    fn writeStringBody(self: *Writer, s: []const u8) !void {
        try self.u16be(@intCast(@min(s.len, 65535)));
        try self.out.appendSlice(self.a(), s);
    }

    pub fn utf8(self: *Writer, w: strings.AvmString) ![]const u8 {
        return strings.toUtf8(self.a(), w);
    }

    /// A named element inside an object body: the key (bare string, no
    /// marker) then the value.
    fn element(self: *Writer, key: []const u8, v: Value) !void {
        try self.writeStringBody(key);
        try self.value(v);
    }

    pub fn value(self: *Writer, v: Value) anyerror!void {
        if (self.depth > 128) return self.byte(Marker.UNDEFINED);
        switch (v) {
            .undefined_value => try self.byte(Marker.UNDEFINED),
            .null_value => try self.byte(Marker.NULL),
            .boolean => |b| {
                try self.byte(Marker.BOOLEAN);
                try self.byte(if (b) 1 else 0);
            },
            .number => |n| {
                try self.byte(Marker.NUMBER);
                try self.f64be(n);
            },
            .string => |s| {
                const bytes = try self.utf8(s);
                if (bytes.len > 65535) {
                    try self.byte(Marker.LONG_STRING);
                    try self.u32be(@intCast(bytes.len));
                    try self.out.appendSlice(self.a(), bytes);
                } else {
                    try self.byte(Marker.STRING);
                    try self.writeStringBody(bytes);
                }
            },
            .object => |h| try self.objectValue(h),
        }
    }

    fn objectValue(self: *Writer, h: ObjectHandle) anyerror!void {
        const vm = self.vm;
        switch (vm.objects.get(h).native) {
            // A display object is not data.
            .clip, .display, .removed_display => return self.byte(Marker.UNDEFINED),
            // A function is skipped by the caller; reached directly it is
            // undefined.
            .function => return self.byte(Marker.UNDEFINED),
            .date => |ms| {
                try self.byte(Marker.DATE);
                try self.f64be(ms);
                // The timezone field is always zero — Flash writes UTC.
                try self.u16be(0);
                return;
            },
            else => {},
        }
        // A repeat sighting is a reference.
        for (self.seen.items, 0..) |seen, i| {
            if (seen == h) {
                try self.byte(Marker.REFERENCE);
                try self.u16be(@intCast(i));
                return;
            }
        }
        try self.seen.append(self.a(), h);
        self.depth += 1;
        defer self.depth -= 1;

        if (vm.objects.get(h).native == .array) return self.arrayValue(h);

        if (try className(vm, h)) |name| {
            try self.byte(Marker.TYPED_OBJECT);
            try self.writeStringBody(name);
        } else {
            try self.byte(Marker.OBJECT);
        }
        try self.properties(h);
        try self.u16be(0);
        try self.byte(Marker.OBJECT_END);
    }

    /// An array with only numeric keys is a STRICT array — dense, holes
    /// padded with undefined. One non-numeric key anywhere makes it an
    /// ECMA array instead, which carries both halves.
    fn arrayValue(self: *Writer, h: ObjectHandle) anyerror!void {
        const vm = self.vm;
        var length: u32 = vm.arrayLength(h);
        var custom = false;
        var keys: std.ArrayList(strings.AvmString) = .empty;
        try @import("globals/loader.zig").enumKeys(vm, h, &keys);
        for (keys.items) |k| {
            if (numericKey(k)) |idx| {
                if (idx + 1 > length) length = idx + 1;
            } else custom = true;
        }
        if (custom) {
            try self.byte(Marker.ECMA_ARRAY);
            try self.u32be(length);
            try self.properties(h);
            try self.u16be(0);
            try self.byte(Marker.OBJECT_END);
            return;
        }
        try self.byte(Marker.STRICT_ARRAY);
        try self.u32be(length);
        var i: u32 = 0;
        while (i < length) : (i += 1) {
            var buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            var wide: [12]u16 = undefined;
            for (key, 0..) |c, j| wide[j] = c;
            const name = wide[0..key.len];
            const v = vm.getProperty(h, name, .{ .object = h }) catch Value.undefined_value;
            try self.value(v);
        }
    }

    /// Every enumerable property, newest LAST — `enumKeys` reports
    /// newest first and Flash writes the reverse.
    fn properties(self: *Writer, h: ObjectHandle) anyerror!void {
        const vm = self.vm;
        var keys: std.ArrayList(strings.AvmString) = .empty;
        try @import("globals/loader.zig").enumKeys(vm, h, &keys);
        var i = keys.items.len;
        while (i > 0) {
            i -= 1;
            const key = keys.items[i];
            const v = try self.propertyValue(h, key);
            // Functions are absent entirely, rather than undefined.
            if (v == .object and vm.objects.get(v.object).native == .function) continue;
            try self.element(try self.utf8(key), v);
        }
    }

    /// The value as AMF sees it: an ACCESSOR is undefined and is never
    /// called, and a read that throws is undefined too.
    fn propertyValue(self: *Writer, h: ObjectHandle, key: strings.AvmString) !Value {
        const vm = self.vm;
        if (vm.objects.findChainedLocated(h, key, vm.case_sensitive)) |loc| {
            if (loc.prop.getter != 0) return .undefined_value;
        }
        return vm.getProperty(h, key, .{ .object = h }) catch Value.undefined_value;
    }
};

fn numericKey(k: strings.AvmString) ?u32 {
    if (k.len == 0 or k.len > 10) return null;
    var n: u64 = 0;
    for (k) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > std.math.maxInt(u32)) return null;
    }
    return @intCast(n);
}

/// The registered class name for an object, or null for an anonymous
/// one. `constructor` wins when the object owns one that is NOT an
/// accessor; otherwise the hidden `__constructor__` is read through the
/// prototype chain. Attributes — including a version gate — are ignored.
fn className(vm: *Vm, h: ObjectHandle) !?[]const u8 {
    var ctor: Value = .undefined_value;
    const o = vm.objects.get(h);
    if (o.find(S("constructor"), vm.case_sensitive)) |i| {
        if (o.props.items[i].getter == 0) ctor = o.props.items[i].value;
    } else {
        var cur: Value = .{ .object = h };
        var depth: u32 = 0;
        while (cur == .object and depth < 255) : (depth += 1) {
            const co = vm.objects.get(cur.object);
            if (co.find(S("__constructor__"), vm.case_sensitive)) |i| {
                if (co.props.items[i].getter == 0) ctor = co.props.items[i].value;
                break;
            }
            cur = vm.protoValue(cur.object);
        }
    }
    if (ctor != .object) return null;
    const name = vm.classNameOf(ctor.object) orelse return null;
    return try strings.toUtf8(vm.arena(), name);
}
