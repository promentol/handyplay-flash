//! `XMLSocket` — a raw TCP stream framed by NUL bytes.
//!
//! The wire format is the whole of it: every message the movie sends is
//! its string form followed by a zero byte, and every message it receives
//! is whatever arrived up to the next zero byte. Segmentation is NOT the
//! server's business — one `Send` of "One\0Two\0Three\0" is three
//! messages, and "Hello" followed later by "World!\0" is one (corpus
//! xml_socket_segmented pins both directions of that).
//!
//! `core/` opens no sockets. The class hands host/port to the Player,
//! which hands them to the frontend; replies come back a tick later
//! through `Player.socket_poll`, which is why `onConnect` never fires
//! inside the `connect()` call.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/xml_socket.rs and
//! core/src/socket.rs (`update_sockets`, whose AVM1 arm owns the framing).

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    try decl.property(vm, proto, "timeout", getTimeout, setTimeout, .{});
    try method(vm, proto, "close", close, .{});
    try method(vm, proto, "connect", connect, .{});
    try method(vm, proto, "send", send, .{});
    try method(vm, proto, "onConnect", noop, hidden);
    try method(vm, proto, "onClose", noop, hidden);
    try method(vm, proto, "onData", onData, hidden);
    try method(vm, proto, "onXML", noop, hidden);
    _ = try decl.class(vm, "XMLSocket", ctor, proto, .{ .dont_enum = true });
}

fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // The default is 20 seconds. Nothing here honours it — there is no
    // real connection to time out — but content reads it back.
    try vm.objects.putWithAttrs(this.object, S("_timeout"), .{ .number = 20000 }, .{ .dont_enum = true }, false);
    // What `super()` evaluates to in a subclass: undefined, not the
    // instance (corpus native_subclasses).
    return .undefined_value;
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn getTimeout(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.objects.getOwn(this.object, S("_timeout"), false) orelse .undefined_value;
}

fn setTimeout(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const n = try vm.toNumber(arg(args, 0));
    const clamped: f64 = @floatFromInt(value_mod.toUint32(n));
    try vm.objects.putWithAttrs(this.object, S("_timeout"), .{ .number = clamped }, .{ .dont_enum = true }, false);
    return .undefined_value;
}

/// `connect(host, port)`. A null or undefined host means the movie's own,
/// which for a local file is "localhost". The call always reports success:
/// connecting is asynchronous, so at this point nothing is known.
fn connect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const host_arg = arg(args, 0);
    const host = if (host_arg == .null_value or host_arg == .undefined_value)
        try defaultHost(vm)
    else
        try vm.toStringValue(host_arg);
    const port: u16 = @truncate(value_mod.toUint32(try vm.toNumber(arg(args, 1))));
    const h = vm.host;
    const f = h.socket_connect orelse return .{ .boolean = true };
    f(h.ctx orelse return .{ .boolean = true }, this.object, try strings.toUtf8(vm.arena(), host), port);
    return .{ .boolean = true };
}

/// The movie's own domain. A `file:` URL — and anything without a
/// recognisable domain — is "localhost".
fn defaultHost(vm: *Vm) !strings.AvmString {
    const url = vm.movie_url;
    const scheme_end = indexOfSlice(url, S("://")) orelse return S("localhost");
    if (strings.eqlIgnoreCase(url[0..scheme_end], S("file"))) return S("localhost");
    const rest = url[scheme_end + 3 ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != '/' and rest[end] != ':') end += 1;
    return if (end == 0) S("localhost") else rest[0..end];
}

fn indexOfSlice(hay: []const u16, needle: []const u16) ?usize {
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u16, hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn send(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    const utf8 = try strings.toUtf8(vm.arena(), s);
    const framed = try vm.arena().alloc(u8, utf8.len + 1);
    @memcpy(framed[0..utf8.len], utf8);
    framed[utf8.len] = 0;
    const h = vm.host;
    const f = h.socket_send orelse return .undefined_value;
    f(h.ctx orelse return .undefined_value, this.object, framed);
    return .undefined_value;
}

fn close(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const h = vm.host;
    const f = h.socket_close orelse return .undefined_value;
    f(h.ctx orelse return .undefined_value, this.object);
    return .undefined_value;
}

/// The default `onData`: build an XML document from the message and hand
/// it to `onXML`. Content replaces this when it wants the raw text.
fn onData(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const ctor_v = vm.objects.getChained(vm.globals, S("XMLSocket"), vm.case_sensitive);
    _ = ctor_v;
    const xml_ctor = vm.objects.getChained(vm.globals, S("XML"), vm.case_sensitive) orelse
        return .undefined_value;
    const doc = try vm.construct(xml_ctor, args[0..@min(args.len, 1)]);
    try @import("loader.zig").callMethod(vm, this.object, S("onXML"), &.{doc});
    return .undefined_value;
}
