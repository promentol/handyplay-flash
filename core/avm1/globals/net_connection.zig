//! `NetConnection` — Flash Remoting over AMF0.
//!
//! `connect(url)` remembers where to POST; `call(command, responder,
//! ...args)` builds one AMF0 PACKET and sends it. The packet is
//!
//!     u16 version (0)   u16 header count (0)   u16 message count (1)
//!     <string> command  <string> "/N"          u32 body length
//!     <AMF0 strict array of the arguments>
//!
//! where N counts the calls made on this connection, 1-based. The
//! response never arrives here: Flash Remoting needs a real server, and
//! what the corpus checks is the bytes that go out (`amf_*`).
//!
//! A connection with a NULL url is LOCAL — `call` on it sends nothing.

const std = @import("std");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const strings = @import("../string.zig");
const amf = @import("../amf.zig");
const decl = @import("decl.zig");
const value_mod = @import("../value.zig");

const Vm = runtime.Vm;
const Value = runtime.Value;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;
const method = decl.method;
const hidden = decl.hidden;
const arg = decl.arg;

fn vmOf(p: *anyopaque) *Vm {
    return @ptrCast(@alignCast(p));
}

/// The connection object behind `this`. A subclass that forwards with
/// `super.call.apply(super, arguments)` hands us the SUPER view, which
/// owns no state of its own — the state is on the instance it wraps
/// (corpus netconnection_send_remote).
fn selfOf(vm: *Vm, this: Value) ObjectHandle {
    if (this != .object) return 0;
    var h = this.object;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        const n = vm.objects.get(h).native;
        if (n != .super_obj) return h;
        h = n.super_obj.this;
    }
    return h;
}

/// Where the connection state lives. Hidden own slots, like the Sound
/// class uses — the script side sees only the methods.
const URL = "_nc_url";
const CALLS = "_nc_calls";
const CONNECTED = "_nc_open";

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    try method(vm, proto, "connect", connect, hidden);
    try method(vm, proto, "close", close, hidden);
    try method(vm, proto, "call", call, hidden);
    try method(vm, proto, "addHeader", addHeader, hidden);
    _ = try decl.class(vm, "NetConnection", ctor, proto, .{ .dont_enum = true });
}

fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

/// Connecting REPLACES whatever was there, closing it first — which is
/// why a second `connect(null)` reports Closed and then Success.
/// A local connection (null, undefined, or no argument at all) succeeds
/// immediately and says so; Flash Remoting over http(s) says nothing
/// until a call is answered, so a remote `connect` is silent. Any other
/// URL scheme is not a connection at all.
fn connect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = selfOf(vm, this);
    if (self == 0) return .undefined_value;
    const a0 = arg(args, 0);
    const local = args.len == 0 or a0 == .undefined_value or a0 == .null_value;
    var url: Value = .null_value;
    if (!local) {
        const s = try vm.toStringThrowing(a0);
        if (!isHttp(s)) return .undefined_value; // unsupported scheme: no connection
        url = .{ .string = s };
    }
    try closeCurrent(vm, self, false);
    // A new connection starts with no headers — they belong to the
    // connection, not to the object (corpus netconnection_send_remote's
    // last test sends a header-free packet after reconnecting).
    var hi = vm.net_headers.items.len;
    while (hi > 0) {
        hi -= 1;
        if (vm.net_headers.items[hi].conn == self) _ = vm.net_headers.orderedRemove(hi);
    }
    try vm.objects.putWithAttrs(self, S(URL), url, hidden, vm.case_sensitive);
    try vm.objects.putWithAttrs(self, S(CONNECTED), .{ .boolean = true }, hidden, vm.case_sensitive);
    try vm.objects.putWithAttrs(self, S(CALLS), .{ .number = 0 }, hidden, vm.case_sensitive);
    if (local) try status(vm, self, "NetConnection.Connect.Success");
    return .undefined_value;
}

fn isHttp(s: strings.AvmString) bool {
    return prefixed(s, "http://") or prefixed(s, "https://");
}

fn prefixed(s: strings.AvmString, comptime p: []const u8) bool {
    if (s.len < p.len) return false;
    return strings.eqlIgnoreCase(s[0..p.len], S(p));
}

fn close(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = args;
    const self = selfOf(vm, this);
    if (self == 0) return .undefined_value;
    try closeCurrent(vm, self, true);
    return .undefined_value;
}

/// Tear down whatever connection the object holds. An EXPLICIT close of
/// a Flash Remoting connection gets a second, empty status event on top
/// — ruffle's comment is "I have no idea why, but a NetConnection
/// receives a second and nonsensical event on close", and the AVM1 form
/// of it calls `onStatus` with NO arguments at all.
fn closeCurrent(vm: *Vm, h: ObjectHandle, explicit: bool) !void {
    const c = vm.objects.getOwn(h, S(CONNECTED), vm.case_sensitive) orelse return;
    if (c != .boolean or !c.boolean) return;
    const url = vm.objects.getOwn(h, S(URL), vm.case_sensitive) orelse Value.null_value;
    const remote = url == .string;
    try vm.objects.putWithAttrs(h, S(CONNECTED), .{ .boolean = false }, hidden, vm.case_sensitive);
    try vm.objects.putWithAttrs(h, S(URL), .null_value, hidden, vm.case_sensitive);
    try status(vm, h, "NetConnection.Connect.Closed");
    if (explicit and remote) {
        const f = try vm.getProperty(h, S("onStatus"), .{ .object = h });
        if (vm.isCallable(f)) _ = vm.callFunction(f, .{ .object = h }, &.{}) catch {};
    }
}

/// `onStatus({level: "status", code: ...})`.
fn status(vm: *Vm, h: ObjectHandle, comptime code: []const u8) !void {
    const f = try vm.getProperty(h, S("onStatus"), .{ .object = h });
    if (!vm.isCallable(f)) return;
    const ev = try vm.newObject();
    try vm.setProperty(ev, S("level"), .{ .string = S("status") }, .{ .object = ev });
    try vm.setProperty(ev, S("code"), .{ .string = S(code) }, .{ .object = ev });
    _ = vm.callFunction(f, .{ .object = h }, &.{.{ .object = ev }}) catch {};
}

/// `addHeader(name, mustUnderstand, value)`. Headers persist on the
/// connection and ride at the front of every packet; adding the same
/// name twice REPLACES the first (corpus netconnection_send_remote adds
/// "Duplicate" twice and sends it once).
fn addHeader(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = selfOf(vm, this);
    if (self == 0 or args.len == 0) return .undefined_value;
    const name = try vm.toStringThrowing(args[0]);
    // The defaults are not "undefined": an absent mustUnderstand is
    // TRUE and an absent value is NULL.
    const must = if (args.len > 1)
        value_mod.toBoolean(args[1], vm.swf_version)
    else
        true;
    var body: std.ArrayList(u8) = .empty;
    var w: amf.Writer = .{ .vm = vm, .out = &body };
    defer w.deinit();
    try w.value(if (args.len > 2) args[2] else .null_value);
    for (vm.net_headers.items) |*h| {
        if (h.conn == self and strings.eql(h.name, name)) {
            h.must_understand = must;
            h.payload = try vm.arena().dupe(u8, body.items);
            return .undefined_value;
        }
    }
    try vm.net_headers.append(vm.arena(), .{
        .conn = self,
        .name = try vm.arena().dupe(u16, name),
        .must_understand = must,
        .payload = try vm.arena().dupe(u8, body.items),
    });
    return .undefined_value;
}

fn call(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const self = selfOf(vm, this);
    if (self == 0) return .undefined_value;
    const c = vm.objects.getOwn(self, S(CONNECTED), vm.case_sensitive) orelse
        return .undefined_value;
    if (c != .boolean or !c.boolean) return .undefined_value;
    const url_v = vm.objects.getOwn(self, S(URL), vm.case_sensitive) orelse
        return .undefined_value;
    // A LOCAL connection has nowhere to send to.
    if (url_v != .string) return .undefined_value;

    const command = try vm.toStringThrowing(arg(args, 0));
    const responder = arg(args, 1);

    var body: std.ArrayList(u8) = .empty;
    var w: amf.Writer = .{ .vm = vm, .out = &body };
    defer w.deinit();
    const call_args = if (args.len > 2) args[2..] else args[0..0];
    try body.append(vm.arena(), amf.Marker.STRICT_ARRAY);
    try appendU32(vm, &body, @intCast(call_args.len));
    for (call_args) |v| try w.value(v);

    try vm.net_messages.append(vm.arena(), .{
        .conn = self,
        .command = try vm.arena().dupe(u16, command),
        .responder = if (responder == .object) responder.object else 0,
        .payload = try vm.arena().dupe(u8, body.items),
    });
    return .undefined_value;
}

/// Everything queued this tick, as ONE packet:
///
///     u16 version   u16 header count   <headers>   u16 message count
///     <messages>
///
/// A header is `name`, a mustUnderstand byte, a u32 length and its
/// value; a message is the command, the `/N` response URI, a u32 length
/// and its argument array.
pub fn flush(vm: *Vm) !void {
    if (vm.net_messages.items.len == 0) return;
    const batch = try vm.arena().dupe(runtime.NetMessage, vm.net_messages.items);
    vm.net_messages.clearRetainingCapacity();
    const conn = batch[0].conn;
    const url_v = vm.objects.getOwn(conn, S(URL), vm.case_sensitive) orelse return;
    if (url_v != .string) return;
    const a = vm.arena();

    var headers: std.ArrayList(runtime.NetHeader) = .empty;
    for (vm.net_headers.items) |h| {
        if (h.conn == conn) try headers.append(a, h);
    }

    var packet: std.ArrayList(u8) = .empty;
    try packet.appendSlice(a, &.{ 0, 0 }); // version
    try appendU16(vm, &packet, @intCast(headers.items.len));
    for (headers.items) |h| {
        try appendString(vm, &packet, try strings.toUtf8(a, h.name));
        try packet.append(a, if (h.must_understand) 1 else 0);
        try appendU32(vm, &packet, @intCast(h.payload.len));
        try packet.appendSlice(a, h.payload);
    }
    try appendU16(vm, &packet, @intCast(batch.len));
    vm.net_inflight.clearRetainingCapacity();
    for (batch, 1..) |m, i| {
        try appendString(vm, &packet, try strings.toUtf8(a, m.command));
        var resp_buf: [16]u8 = undefined;
        try appendString(vm, &packet, std.fmt.bufPrint(&resp_buf, "/{d}", .{i}) catch "/1");
        try appendU32(vm, &packet, @intCast(m.payload.len));
        try packet.appendSlice(a, m.payload);
        try vm.net_inflight.append(a, m.responder);
    }

    if (vm.host.fetch) |f| {
        f(vm.host.ctx.?, .{
            .url = try strings.toUtf8(a, url_v.string),
            .method = .post,
            .body = packet.items,
            .mime = "application/x-amf",
            .target = .{ .net_connection = conn },
        });
    }
}

/// The reply. Each message names its responder and method in one URI:
/// `/1/onResult` means "call `onResult` on the responder of call 1".
/// A request that failed outright calls the CONNECTION's `onStatus`
/// with no arguments at all.
pub fn completeCall(vm: *Vm, conn: ObjectHandle, body: ?[]const u8) !void {
    const bytes = body orelse {
        const f = try vm.getProperty(conn, S("onStatus"), .{ .object = conn });
        if (vm.isCallable(f)) _ = vm.callFunction(f, .{ .object = conn }, &.{}) catch {};
        return;
    };
    var r: amf.Reader = .{ .vm = vm, .bytes = bytes };
    defer r.deinit();
    _ = readU16(&r); // version
    const header_count = readU16(&r);
    var i: u16 = 0;
    while (i < header_count) : (i += 1) {
        _ = readStr(&r);
        _ = readByte(&r);
        const len = readU32(&r);
        r.pos = @min(r.pos + len, bytes.len);
    }
    const message_count = readU16(&r);
    i = 0;
    while (i < message_count) : (i += 1) {
        const target = readStr(&r);
        _ = readStr(&r); // response uri, empty in a reply
        _ = readU32(&r); // body length; the value knows its own size
        const v = try r.value();
        try dispatch(vm, target, v);
    }
}

/// `/1/onResult` → the responder of call 1, method `onResult`.
fn dispatch(vm: *Vm, target: []const u8, v: Value) !void {
    const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return;
    if (slash == 0) return;
    var head = target[0..slash];
    while (head.len > 0 and head[0] == '/') head = head[1..];
    const index = std.fmt.parseInt(u32, head, 10) catch return;
    if (index == 0 or index > vm.net_inflight.items.len) return;
    const responder = vm.net_inflight.items[index - 1];
    if (responder == 0) return;
    const name = try strings.fromSwf(vm.arena(), target[slash + 1 ..], 8);
    const f = try vm.getProperty(responder, name, .{ .object = responder });
    if (!vm.isCallable(f)) return;
    _ = vm.callFunction(f, .{ .object = responder }, &.{v}) catch {};
}

fn readByte(r: *amf.Reader) u8 {
    if (r.pos >= r.bytes.len) return 0;
    defer r.pos += 1;
    return r.bytes[r.pos];
}

fn readU16(r: *amf.Reader) u16 {
    return (@as(u16, readByte(r)) << 8) | readByte(r);
}

fn readU32(r: *amf.Reader) u32 {
    var v: u32 = 0;
    for (0..4) |_| v = (v << 8) | readByte(r);
    return v;
}

fn readStr(r: *amf.Reader) []const u8 {
    const n = readU16(r);
    const end = @min(r.pos + n, r.bytes.len);
    defer r.pos = end;
    return r.bytes[r.pos..end];
}

fn appendU16(vm: *Vm, out: *std.ArrayList(u8), v: u16) !void {
    try out.append(vm.arena(), @intCast(v >> 8));
    try out.append(vm.arena(), @intCast(v & 0xFF));
}

fn appendU32(vm: *Vm, out: *std.ArrayList(u8), v: u32) !void {
    var i: u5 = 4;
    while (i > 0) {
        i -= 1;
        try out.append(vm.arena(), @intCast((v >> (@as(u5, i) * 8)) & 0xFF));
    }
}

fn appendString(vm: *Vm, out: *std.ArrayList(u8), s: []const u8) !void {
    const n: u16 = @intCast(@min(s.len, 65535));
    try appendU16(vm, out, n);
    try out.appendSlice(vm.arena(), s[0..n]);
}
