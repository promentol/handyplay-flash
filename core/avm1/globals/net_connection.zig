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

/// Where the connection state lives. Hidden own slots, like the Sound
/// class uses — the script side sees only the methods.
const URL = "_nc_url";
const CALLS = "_nc_calls";

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

fn connect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const a0 = arg(args, 0);
    // `connect(null)` is a LOCAL connection: it works, but nothing is
    // ever sent anywhere.
    const url: Value = if (a0 == .string) a0 else .null_value;
    try vm.objects.putWithAttrs(this.object, S(URL), url, hidden, vm.case_sensitive);
    try vm.objects.putWithAttrs(this.object, S(CALLS), .{ .number = 0 }, hidden, vm.case_sensitive);
    return .{ .boolean = true };
}

fn close(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = args;
    if (this != .object) return .undefined_value;
    try vm.objects.putWithAttrs(this.object, S(URL), .null_value, hidden, vm.case_sensitive);
    return .undefined_value;
}

fn addHeader(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn call(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const url_v = vm.objects.getOwn(this.object, S(URL), vm.case_sensitive) orelse
        return .undefined_value;
    if (url_v != .string) return .undefined_value;
    const url = try strings.toUtf8(vm.arena(), url_v.string);

    const command = try vm.toStringThrowing(arg(args, 0));
    const seq: u32 = blk: {
        const v = vm.objects.getOwn(this.object, S(CALLS), vm.case_sensitive) orelse
            Value{ .number = 0 };
        const n: u32 = @intFromFloat(@max(0, try vm.toNumber(v)));
        try vm.objects.putWithAttrs(
            this.object,
            S(CALLS),
            .{ .number = @floatFromInt(n + 1) },
            hidden,
            vm.case_sensitive,
        );
        break :blk n + 1;
    };

    // The ARGUMENTS, as one strict array — the responder (args[1]) is
    // not part of the packet.
    var body: std.ArrayList(u8) = .empty;
    var w: amf.Writer = .{ .vm = vm, .out = &body };
    defer w.deinit();
    const call_args = if (args.len > 2) args[2..] else args[0..0];
    try body.append(vm.arena(), amf.Marker.STRICT_ARRAY);
    try appendU32(vm, &body, @intCast(call_args.len));
    for (call_args) |v| try w.value(v);

    var packet: std.ArrayList(u8) = .empty;
    const a = vm.arena();
    try packet.appendSlice(a, &.{ 0, 0, 0, 0, 0, 1 }); // version, 0 headers, 1 message
    try appendString(vm, &packet, try strings.toUtf8(a, command));
    var resp_buf: [16]u8 = undefined;
    try appendString(vm, &packet, std.fmt.bufPrint(&resp_buf, "/{d}", .{seq}) catch "/1");
    try appendU32(vm, &packet, @intCast(body.items.len));
    try packet.appendSlice(a, body.items);

    if (vm.host.fetch) |f| {
        f(vm.host.ctx.?, .{
            .url = url,
            .method = .post,
            .body = packet.items,
            .mime = "application/x-amf",
            .target = .discard,
        });
    }
    return .undefined_value;
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
    try out.append(vm.arena(), @intCast(n >> 8));
    try out.append(vm.arena(), @intCast(n & 0xFF));
    try out.appendSlice(vm.arena(), s[0..n]);
}
