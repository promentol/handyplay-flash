//! `flash.external.ExternalInterface`.
//!
//! The bridge itself needs a host — a browser to call into — but the
//! MARSHALLING does not, and it is nearly all of the class: the
//! underscore-prefixed helpers that turn AVM1 values into the XML the
//! plugin protocol speaks, and back. They are ordinary, script-visible
//! methods, and the corpus exercises them directly.
//!
//! Two rules recur and are easy to get wrong. An EMPTY result from the
//! string helpers is `null`, not `""` — and a missing argument is `null`
//! too, while an explicit `undefined` is the four-letter string. And
//! `_argumentsToXML` starts at index ONE: the first element of an
//! `arguments` object is the callee's own name, which never crosses.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/external_interface.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const AvmString = strings.AvmString;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;

/// Every member is DONT_ENUM | DONT_DELETE | READ_ONLY and SWF8-gated,
/// except `call`, which has no version gate.
const frozen8 = decl.ver(decl.frozen, decl.V8);

pub fn install(vm: *Vm, flash: ObjectHandle) !void {
    const ns = try decl.subObject(vm, flash, "external", .{});
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    const ctor = try vm.newNativeFn(noop);
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, decl.hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, decl.hidden, false);
    try vm.objects.putWithAttrs(ns, S("ExternalInterface"), .{ .object = ctor }, .{}, false);

    // The members live on the CONSTRUCTOR — `ExternalInterface` is used as
    // a namespace, never instantiated.
    try decl.method(vm, ctor, "_initJS", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_objectID", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_addCallback", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_evalJS", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_callOut", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_escapeXML", escapeXml, frozen8);
    try decl.method(vm, ctor, "_unescapeXML", unescapeXml, frozen8);
    try decl.method(vm, ctor, "_jsQuoteString", jsQuoteString, frozen8);
    try decl.method(vm, ctor, "_useSetReturnValueHack", undefinedFn, frozen8);
    try decl.property(vm, ctor, "available", getAvailable, null, frozen8);
    try decl.method(vm, ctor, "addCallback", falseFn, frozen8);
    try decl.method(vm, ctor, "call", callFn, decl.frozen);
    try decl.method(vm, ctor, "_callIn", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_arrayToXML", arrayToXml, frozen8);
    try decl.method(vm, ctor, "_argumentsToXML", argumentsToXml, frozen8);
    try decl.method(vm, ctor, "_objectToXML", objectToXml, frozen8);
    try decl.method(vm, ctor, "_toXML", toXml, frozen8);
    try decl.method(vm, ctor, "_objectToAS", objectToAs, frozen8);
    try decl.method(vm, ctor, "_arrayToAS", arrayToAs, frozen8);
    try decl.method(vm, ctor, "_toAS", toAs, frozen8);
    try decl.method(vm, ctor, "_argumentsToAS", argumentsToAs, frozen8);
    try decl.method(vm, ctor, "_arrayToJS", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_objectToJS", undefinedFn, frozen8);
    try decl.method(vm, ctor, "_toJS", undefinedFn, frozen8);
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn undefinedFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn falseFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .boolean = false };
}

/// There is no browser here, so the bridge is never available and `call`
/// answers null without asking anybody.
fn getAvailable(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .boolean = false };
}

fn callFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .null_value;
}

// --- the string helpers ----------------------------------------------------

/// The shared argument rule: a MISSING argument is null; anything else,
/// including an explicit `undefined`, is stringified.
fn stringArg(vm: *Vm, args: []const Value) !?AvmString {
    if (args.len == 0) return null;
    return try vm.toStringValue(args[0]);
}

fn orNull(vm: *Vm, out: []const u16) !Value {
    _ = vm;
    return if (out.len == 0) .null_value else .{ .string = out };
}

fn replaceAll(vm: *Vm, s: AvmString, from: AvmString, to: AvmString) !AvmString {
    const a = vm.arena();
    var out: std.ArrayList(u16) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (from.len > 0 and i + from.len <= s.len and std.mem.eql(u16, s[i .. i + from.len], from)) {
            try out.appendSlice(a, to);
            i += from.len;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn escapeXmlInner(vm: *Vm, s: AvmString) !AvmString {
    var r = try replaceAll(vm, s, S("&"), S("&amp;"));
    r = try replaceAll(vm, r, S("\""), S("&quot;"));
    r = try replaceAll(vm, r, S("'"), S("&apos;"));
    r = try replaceAll(vm, r, S("<"), S("&lt;"));
    r = try replaceAll(vm, r, S(">"), S("&gt;"));
    return r;
}

fn escapeXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try stringArg(vm, args) orelse return .null_value;
    return orNull(vm, try escapeXmlInner(vm, s));
}

fn unescapeXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try stringArg(vm, args) orelse return .null_value;
    // REVERSE order, and `&amp;` last — otherwise "&amp;lt;" would
    // unescape twice into "<".
    var r = try replaceAll(vm, s, S("&gt;"), S(">"));
    r = try replaceAll(vm, r, S("&lt;"), S("<"));
    r = try replaceAll(vm, r, S("&apos;"), S("'"));
    r = try replaceAll(vm, r, S("&quot;"), S("\""));
    r = try replaceAll(vm, r, S("&amp;"), S("&"));
    return orNull(vm, r);
}

fn jsQuoteString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try stringArg(vm, args) orelse return .null_value;
    return orNull(vm, try replaceAll(vm, s, S("\""), S("\\\"")));
}

// --- the XML serialisers ---------------------------------------------------

/// `length` as the serialisers see it: whatever the property coerces to,
/// clamped to a sane count. Zero for anything that is not an object.
fn lengthOf(vm: *Vm, v: Value) !u32 {
    // A STRING counts its characters. `_arrayToXML` boxes its argument
    // first, and a boxed string carries a `length` — which is why
    // `new String("hello")` serialises as five undefined elements, and
    // why the primitive does too.
    if (v == .string) return @intCast(@min(v.string.len, 4096));
    if (v != .object) return 0;
    switch (vm.objects.get(v.object).native) {
        .boxed_string => |s| return @intCast(@min(s.len, 4096)),
        else => {},
    }
    const raw = vm.getProperty(v.object, S("length"), v) catch Value.undefined_value;
    const n = try vm.toNumber(raw);
    if (!std.math.isFinite(n) or n <= 0) return 0;
    return @intFromFloat(@min(n, 4096));
}

fn elementAt(vm: *Vm, v: Value, i: u32) !Value {
    if (v != .object) return .undefined_value;
    var buf: [12]u8 = undefined;
    const name = try strings.fromSwf(
        vm.arena(),
        std.fmt.bufPrint(&buf, "{d}", .{i}) catch return .undefined_value,
        8,
    );
    return vm.getProperty(v.object, name, v) catch Value.undefined_value;
}

fn arrayToXmlInner(vm: *Vm, v: Value, out: *std.ArrayList(u16)) anyerror!void {
    const a = vm.arena();
    try out.appendSlice(a, S("<array>"));
    const n = try lengthOf(vm, v);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [12]u8 = undefined;
        const idx = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
        try out.appendSlice(a, S("<property id=\""));
        for (idx) |c| try out.append(a, c);
        try out.appendSlice(a, S("\">"));
        try toXmlInner(vm, try elementAt(vm, v, i), out);
        try out.appendSlice(a, S("</property>"));
    }
    try out.appendSlice(a, S("</array>"));
}

fn objectToXmlInner(vm: *Vm, v: Value, out: *std.ArrayList(u16)) anyerror!void {
    const a = vm.arena();
    try out.appendSlice(a, S("<object>"));
    if (v == .object) {
        // Own, ENUMERABLE properties, most recent first — Flash's
        // iteration order, the same one `for..in` shows.
        const o = vm.objects.get(v.object);
        var i = o.props.items.len;
        while (i > 0) {
            i -= 1;
            const props = vm.objects.get(v.object).props.items;
            if (i >= props.len) continue;
            const key = props[i].key;
            if (props[i].attrs.dont_enum) continue;
            const val = vm.getProperty(v.object, key, v) catch Value.undefined_value;
            try out.appendSlice(a, S("<property id=\""));
            try out.appendSlice(a, key);
            try out.appendSlice(a, S("\">"));
            try toXmlInner(vm, val, out);
            try out.appendSlice(a, S("</property>"));
        }
    }
    try out.appendSlice(a, S("</object>"));
}

fn toXmlInner(vm: *Vm, v: Value, out: *std.ArrayList(u16)) anyerror!void {
    const a = vm.arena();
    switch (v) {
        .undefined_value => try out.appendSlice(a, S("<undefined/>")),
        .null_value => try out.appendSlice(a, S("<null/>")),
        .boolean => |b| try out.appendSlice(a, if (b) S("<true/>") else S("<false/>")),
        .number => {
            try out.appendSlice(a, S("<number>"));
            try out.appendSlice(a, try vm.toStringValue(v));
            try out.appendSlice(a, S("</number>"));
        },
        .string => |s| {
            // The escape helper returns NULL for an empty result, and
            // `_toXML` stringifies whatever it gets back — so the empty
            // string serialises as `<string>null</string>`. Flash's, and
            // pinned by external_interface_toxml_array.
            const esc = try escapeXmlInner(vm, s);
            try out.appendSlice(a, S("<string>"));
            try out.appendSlice(a, if (esc.len == 0) S("null") else esc);
            try out.appendSlice(a, S("</string>"));
        },
        .object => |h| {
            // Anything with an OWN `length` is an array — including
            // `new String("hello")`, which duly serialises as five
            // undefined elements.
            const boxed_string = vm.objects.get(h).native == .boxed_string;
            if (boxed_string or vm.objects.hasOwn(h, S("length"), vm.case_sensitive)) {
                try arrayToXmlInner(vm, v, out);
            } else if (vm.objects.get(h).native == .function) {
                try out.appendSlice(a, S("<null/>"));
            } else {
                try objectToXmlInner(vm, v, out);
            }
        },
    }
}

fn arrayToXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    var out: std.ArrayList(u16) = .empty;
    try arrayToXmlInner(vm, arg(args, 0), &out);
    return .{ .string = out.items };
}

/// Index ONE, not zero: an `arguments` object leads with the callee.
fn argumentsToXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const a = vm.arena();
    const v = arg(args, 0);
    var out: std.ArrayList(u16) = .empty;
    try out.appendSlice(a, S("<arguments>"));
    const n = try lengthOf(vm, v);
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        try toXmlInner(vm, try elementAt(vm, v, i), &out);
    }
    try out.appendSlice(a, S("</arguments>"));
    return .{ .string = out.items };
}

fn objectToXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    var out: std.ArrayList(u16) = .empty;
    try objectToXmlInner(vm, arg(args, 0), &out);
    return .{ .string = out.items };
}

fn toXml(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    var out: std.ArrayList(u16) = .empty;
    try toXmlInner(vm, arg(args, 0), &out);
    return .{ .string = out.items };
}

// --- the XML deserialisers -------------------------------------------------

/// Ruffle stubs the three container forms: they build an empty Object or
/// Array and go no further. The corpus records that, so matching it means
/// stopping in the same place.
fn objectToAs(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .object = try vm.newObject() };
}

fn arrayToAs(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .object = try vm.newArray() };
}

fn argumentsToAs(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .object = try vm.newArray() };
}

/// `_toAS(node)` reads the node's TAG to decide the type, then its first
/// child for the payload. The container tags are stubs, as above.
fn toAs(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const v = arg(args, 0);
    if (v != .object) return .undefined_value;
    const raw = vm.getProperty(v.object, S("nodeName"), v) catch Value.undefined_value;
    const name: AvmString = switch (raw) {
        .string => |s| s,
        .object => |h| switch (vm.objects.get(h).native) {
            .boxed_string => |s| s,
            else => return .undefined_value,
        },
        else => return .undefined_value,
    };
    if (strings.eql(name, S("null"))) return .null_value;
    if (strings.eql(name, S("true"))) return .{ .boolean = true };
    if (strings.eql(name, S("false"))) return .{ .boolean = false };
    if (strings.eql(name, S("string")) or strings.eql(name, S("number"))) {
        const child = vm.getProperty(v.object, S("firstChild"), v) catch Value.undefined_value;
        const text = try vm.toStringValue(child);
        if (strings.eql(name, S("string"))) return .{ .string = text };
        return .{ .number = value_mod.stringToNumber(text, vm.swf_version) };
    }
    return .undefined_value;
}
