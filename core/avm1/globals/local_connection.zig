//! `LocalConnection` — a message bus between movies in the same player.
//!
//! `connect(name)` claims a name; `send(name, method, ...args)` finds
//! whoever claimed it and calls `receiver[method](...)`. The arguments
//! do NOT travel by reference: they are serialised to AMF0 and read back,
//! so the receiver gets copies. That round trip is the whole point of
//! the class's semantics and is what the corpus checks — a Date survives
//! as a Date, an XML document as an XML document, a display object
//! arrives as undefined, and a function arrives as an empty OBJECT,
//! because AMF has nowhere to put code.
//!
//! Delivery is asynchronous: ruffle queues the message and dispatches it
//! from the executor at the end of the tick.

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

const NAME = "_lc_name";

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    try method(vm, proto, "connect", connect, hidden);
    try method(vm, proto, "send", send, hidden);
    try method(vm, proto, "close", close, hidden);
    try method(vm, proto, "domain", domain, hidden);
    try method(vm, proto, "allowDomain", allowDomain, hidden);
    try method(vm, proto, "allowInsecureDomain", allowDomain, hidden);
    _ = try decl.class(vm, "LocalConnection", ctor, proto, .{ .dont_enum = true });
}

fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

/// A name can be claimed once, and a connection can claim only one:
/// a second `connect` on an already-connected object fails even for a
/// free name. The argument must be a STRING — Flash tests the type
/// rather than coercing — and may not contain a colon, which is the
/// separator in the internal key.
fn connect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0 or arg(args, 0) != .string) return .{ .boolean = false };
    const name = args[0].string;
    if (name.len == 0 or contains(name, ':')) return .{ .boolean = false };
    // Already connected? A DONT_DELETE slot cannot be deleted, so
    // `close` writes null rather than removing it.
    if (vm.objects.getOwn(this.object, S(NAME), vm.case_sensitive)) |v| {
        if (v == .string) return .{ .boolean = false };
    }
    const key = try connectionKey(vm, name);
    for (vm.local_connections.items) |c| {
        if (strings.eql(c.name, key)) return .{ .boolean = false };
    }
    try vm.local_connections.append(vm.arena(), .{ .name = key, .object = this.object });
    try vm.objects.putWithAttrs(this.object, S(NAME), .{ .string = name }, hidden, vm.case_sensitive);
    return .{ .boolean = true };
}

fn contains(s: strings.AvmString, c: u16) bool {
    for (s) |x| {
        if (x == c) return true;
    }
    return false;
}

/// The bus key. A name starting with `_` is global and used as-is
/// (lowercased); anything else is scoped to the movie's SUPERDOMAIN, so
/// `foo` becomes `com:foo`. Case never matters.
fn connectionKey(vm: *Vm, name: strings.AvmString) !strings.AvmString {
    return connectionKeyEx(vm, name, false);
}

/// `send` accepts a name that ALREADY carries a host — `localhost:channel`
/// — and leaves it alone. `connect` never sees one, because a colon is
/// rejected there.
fn connectionKeyEx(vm: *Vm, name: strings.AvmString, allow_explicit_host: bool) !strings.AvmString {
    var out: std.ArrayList(u16) = .empty;
    const a = vm.arena();
    const explicit = allow_explicit_host and contains(name, ':');
    if (!explicit and (name.len == 0 or name[0] != '_')) {
        const host = hostOf(vm.movie_url);
        try out.appendSlice(a, superDomain(host));
        try out.append(a, ':');
    }
    try out.appendSlice(a, name);
    for (out.items) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
    return out.toOwnedSlice(a);
}

/// Everything after the last dot: `a.b.com` is scoped to `com`.
fn superDomain(host: strings.AvmString) strings.AvmString {
    var i = host.len;
    while (i > 0) {
        i -= 1;
        if (host[i] == '.') return host[i + 1 ..];
    }
    return host;
}

fn close(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    var i = vm.local_connections.items.len;
    while (i > 0) {
        i -= 1;
        if (vm.local_connections.items[i].object == this.object) {
            _ = vm.local_connections.orderedRemove(i);
        }
    }
    try vm.objects.putWithAttrs(this.object, S(NAME), .null_value, hidden, vm.case_sensitive);
    return .undefined_value;
}

/// The domain a connection lives in. With no movie URL there is no host,
/// and Flash says "localhost".
fn domain(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .string = hostOf(vm.movie_url) };
}

fn allowDomain(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn hostOf(url: strings.AvmString) strings.AvmString {
    // `scheme://host/rest` — everything between the `//` and the next `/`.
    var i: usize = 0;
    while (i + 1 < url.len) : (i += 1) {
        if (url[i] == '/' and url[i + 1] == '/') {
            const start = i + 2;
            var j = start;
            while (j < url.len and url[j] != '/') j += 1;
            if (j > start) return url[start..j];
            break;
        }
    }
    return S("localhost");
}

/// The six method names a `send` may not name: they are the class's own
/// interface, and Flash refuses rather than letting a message call them.
const RESERVED = [_][]const u8{ "send", "connect", "close", "allowDomain", "allowInsecureDomain", "domain" };

fn send(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len < 2) return .{ .boolean = false };
    // Both are type-TESTED, not coerced.
    if (arg(args, 0) != .string or arg(args, 1) != .string) return .{ .boolean = false };
    const name = args[0].string;
    const fn_name = args[1].string;
    if (name.len == 0 or fn_name.len == 0) return .{ .boolean = false };
    inline for (RESERVED) |r| {
        if (strings.eql(fn_name, S(r))) return .{ .boolean = false };
    }

    // AMF round trip: the receiver never sees the sender's objects.
    var body: std.ArrayList(u8) = .empty;
    var w: amf.Writer = .{ .vm = vm, .out = &body };
    defer w.deinit();
    const rest = if (args.len > 2) args[2..] else args[0..0];
    for (rest) |v| try w.value(v);

    // "There's two checks for is-connected": one HERE, whose result is
    // frozen into the message, and one at delivery. A listener that
    // appears in between does not get the message, and one that leaves
    // in between turns it into an error.
    const key = try connectionKeyEx(vm, name, true);
    var found = false;
    for (vm.local_connections.items) |c| {
        if (strings.eql(c.name, key)) found = true;
    }
    try vm.pending_local_sends.append(vm.arena(), .{
        .name = key,
        .method = try vm.arena().dupe(u16, fn_name),
        .payload = try vm.arena().dupe(u8, body.items),
        .count = @intCast(rest.len),
        .sender = this.object,
        .had_listener = found,
    });
    return .{ .boolean = true };
}

/// Deliver everything queued this tick. The Player calls it from
/// `finishTick`, alongside the other asynchronous work.
pub fn deliver(vm: *Vm) !void {
    while (vm.pending_local_sends.items.len > 0) {
        const msg = vm.pending_local_sends.orderedRemove(0);
        const target: ObjectHandle = blk: {
            for (vm.local_connections.items) |c| {
                if (strings.eql(c.name, msg.name)) break :blk c.object;
            }
            break :blk 0;
        };
        // The SENDER hears what happened, either way.
        if (msg.had_listener and target != 0) {
            try sendStatus(vm, msg.sender, "status");
        } else {
            try sendStatus(vm, msg.sender, "error");
        }
        if (target == 0 or !msg.had_listener) continue;
        var r: amf.Reader = .{ .vm = vm, .bytes = msg.payload };
        defer r.deinit();
        var call_args: std.ArrayList(Value) = .empty;
        var i: u32 = 0;
        while (i < msg.count) : (i += 1) {
            try call_args.append(vm.arena(), try r.value());
        }
        const f = try vm.getProperty(target, msg.method, .{ .object = target });
        if (!vm.isCallable(f)) continue;
        _ = vm.callFunction(f, .{ .object = target }, call_args.items) catch {};
    }
}

/// `onStatus({level: "status"|"error"})` on the SENDER.
fn sendStatus(vm: *Vm, obj: ObjectHandle, comptime level: []const u8) !void {
    const f = try vm.getProperty(obj, S("onStatus"), .{ .object = obj });
    if (!vm.isCallable(f)) return;
    const ev = try vm.newObject();
    try vm.setProperty(ev, S("level"), .{ .string = S(level) }, .{ .object = ev });
    _ = vm.callFunction(f, .{ .object = obj }, &.{.{ .object = ev }}) catch {};
}
