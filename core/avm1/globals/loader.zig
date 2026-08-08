//! The script side of loading: `LoadVars`, the form-urlencoded codec every
//! loader shares, and the completion handlers the Player calls when bytes
//! come back.
//!
//! The seam itself is `runtime.Host.fetch`. Nothing here does I/O — a load
//! is a `FetchRequest` posted to the Player, which asks the frontend for
//! the bytes and calls back into `complete*` at the END of the tick. That
//! delay is the whole reason `LoadVars.loaded` is observably false right
//! after `load()` returns, and why `loadvariables2` has to poll.
//!
//! Two DIFFERENT percent-encodings live here and must not be conflated:
//! `escape()` (in globals.zig) spares only alphanumerics and writes a
//! space as `%20`, while a request BODY is
//! `application/x-www-form-urlencoded` — it spares `*-._` as well and
//! writes a space as `+`. `LoadVars.toString` uses the first,
//! `sendAndLoad` the second, and the corpus checks both byte for byte.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/load_vars.rs and
//! core/src/loader.rs (`load_form_into_object`, `load_form_into_load_vars`).

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage = @import("../stage_object.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const FetchRequest = runtime.FetchRequest;
const AvmString = strings.AvmString;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    try method(vm, proto, "load", lvLoad, hidden);
    try method(vm, proto, "send", lvSend, hidden);
    try method(vm, proto, "sendAndLoad", lvSendAndLoad, hidden);
    try method(vm, proto, "decode", lvDecode, hidden);
    try method(vm, proto, "getBytesLoaded", lvGetBytesLoaded, hidden);
    try method(vm, proto, "getBytesTotal", lvGetBytesTotal, hidden);
    try method(vm, proto, "toString", lvToString, hidden);
    try decl.value(vm, proto, "contentType", .{ .string = S("application/x-www-form-urlencoded") }, hidden);
    try method(vm, proto, "onLoad", noop, hidden);
    try method(vm, proto, "onData", onData, hidden);
    try method(vm, proto, "addRequestHeader", noop, hidden);
    vm.loadvars_proto = proto;
    _ = try decl.class(vm, "LoadVars", lvCtor, proto, .{ .dont_enum = true });
}

fn lvCtor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

// --- the form-urlencoded codec ---------------------------------------------

/// The `application/x-www-form-urlencoded` serialiser's unreserved set.
/// NOT the same as `escape()`'s, which keeps alphanumerics only.
fn isFormSafe(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
        (b >= 'a' and b <= 'z') or b == '*' or b == '-' or b == '.' or b == '_';
}

pub fn appendFormEscaped(a: std.mem.Allocator, out: *std.ArrayList(u8), s: AvmString) !void {
    try appendFormEscapedBytes(a, out, try strings.toUtf8(a, s));
}

fn appendFormEscapedBytes(a: std.mem.Allocator, out: *std.ArrayList(u8), utf8: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (utf8) |b| {
        if (isFormSafe(b)) {
            try out.append(a, b);
        } else if (b == ' ') {
            try out.append(a, '+');
        } else {
            try out.append(a, '%');
            try out.append(a, hex[(b >> 4) & 0xF]);
            try out.append(a, hex[b & 0xF]);
        }
    }
}

/// Percent-decode one component, `+` meaning space. Returns raw BYTES —
/// the caller decides the text encoding, which depends on the SWF version.
fn percentDecode(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '+') {
            try out.append(a, ' ');
        } else if (c == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch {
                try out.append(a, c);
                continue;
            };
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch {
                try out.append(a, c);
                continue;
            };
            try out.append(a, @as(u8, hi) * 16 + lo);
            i += 2;
        } else {
            try out.append(a, c);
        }
    }
    return out.toOwnedSlice(a);
}

/// Split a query string and assign every pair onto `target`. A pair with
/// no `=` has an empty value; both halves are percent-decoded first, then
/// read in the movie's text encoding (Latin-1 below SWF6).
pub fn decodeInto(vm: *Vm, target: ObjectHandle, body: []const u8) !void {
    const a = vm.arena();
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k_raw = if (eq) |i| pair[0..i] else pair;
        const v_raw = if (eq) |i| pair[i + 1 ..] else "";
        const k = try strings.fromSwf(a, try percentDecode(a, k_raw), vm.swf_version);
        const v = try strings.fromSwf(a, try percentDecode(a, v_raw), vm.swf_version);
        try vm.setProperty(target, k, .{ .string = v }, .{ .object = target });
    }
}

/// Ruffle's `Object::get_keys(include_hidden = false)`: prototype keys
/// first (minus the ones the object shadows), then own keys MOST RECENT
/// FIRST — Flash's iteration order, not insertion order — then display
/// children. `for..in` observes the same sequence in reverse, because the
/// SWF pops what the opcode pushed.
pub fn enumKeys(vm: *Vm, h: ObjectHandle, out: *std.ArrayList(AvmString)) !void {
    try collectKeys(vm, h, out, 0);
}

fn collectKeys(vm: *Vm, h: ObjectHandle, out: *std.ArrayList(AvmString), depth: u32) !void {
    if (depth > 64) return;
    const a = vm.arena();
    const proto = vm.objects.get(h).proto;
    if (proto == .object) {
        var inherited: std.ArrayList(AvmString) = .empty;
        try collectKeys(vm, proto.object, &inherited, depth + 1);
        for (inherited.items) |k| {
            if (vm.objects.hasOwn(h, k, vm.case_sensitive)) continue;
            try out.append(a, k);
        }
    }
    const o = vm.objects.get(h);
    var i = o.props.items.len;
    while (i > 0) {
        i -= 1;
        const p = o.props.items[i];
        if (p.attrs.dont_enum) continue;
        try out.append(a, p.key);
    }
    try stage.enumerateKeys(vm, h, out);
}

/// Every enumerable property of `obj`, stringified, in enumeration order.
/// A property whose getter throws contributes the literal "undefined"
/// rather than aborting the request.
pub fn formPairs(vm: *Vm, obj: ObjectHandle) ![]const runtime.NavigateRequest.Pair {
    const a = vm.arena();
    var keys: std.ArrayList(AvmString) = .empty;
    try enumKeys(vm, obj, &keys);
    var out: std.ArrayList(runtime.NavigateRequest.Pair) = .empty;
    for (keys.items) |k| {
        const raw = vm.getProperty(obj, k, .{ .object = obj }) catch Value.undefined_value;
        const v = vm.toStringValue(raw) catch S("undefined");
        try out.append(a, .{
            .key = try strings.toUtf8(a, k),
            .value = try strings.toUtf8(a, v),
        });
    }
    return out.toOwnedSlice(a);
}

/// The same pairs as one `application/x-www-form-urlencoded` string.
pub fn formValues(vm: *Vm, obj: ObjectHandle) ![]const u8 {
    const a = vm.arena();
    const pairs = try formPairs(vm, obj);
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |kv, i| {
        if (i != 0) try out.append(a, '&');
        try appendFormEscapedBytes(a, &out, kv.key);
        try out.append(a, '=');
        try appendFormEscapedBytes(a, &out, kv.value);
    }
    return out.toOwnedSlice(a);
}

/// `Activation::object_into_request`. A GET folds the variables into the
/// query string (with `&` when the URL already has a `?`); a POST puts
/// them in the body; `.none` sends nothing at all.
pub fn buildRequest(
    vm: *Vm,
    url: AvmString,
    send_from: ?ObjectHandle,
    m: FetchRequest.Method,
    target: FetchRequest.Target,
) !FetchRequest {
    const a = vm.arena();
    const url_utf8 = try strings.toUtf8(a, url);
    const obj = send_from orelse return .{ .url = url_utf8, .target = target };
    switch (m) {
        .none => return .{ .url = url_utf8, .target = target },
        .get => {
            const q = try formValues(vm, obj);
            const sep: []const u8 = if (std.mem.indexOfScalar(u8, url_utf8, '?') == null) "?" else "&";
            return .{
                .url = try std.mem.concat(a, u8, &.{ url_utf8, sep, q }),
                .method = .get,
                .target = target,
            };
        },
        .post => return .{
            .url = url_utf8,
            .method = .post,
            .body = try formValues(vm, obj),
            .target = target,
        },
    }
}

pub fn spawn(vm: *Vm, req: FetchRequest) void {
    const h = vm.host;
    const f = h.fetch orelse return;
    f(h.ctx orelse return, req);
}

// --- LoadVars --------------------------------------------------------------

/// The three bookkeeping properties every LoadVars fetch resets. They are
/// created hidden the first time and merely overwritten afterwards, so a
/// script that made `loaded` enumerable keeps it that way.
pub fn resetProgress(vm: *Vm, obj: ObjectHandle) !void {
    const fields = [_]struct { name: AvmString, v: Value }{
        .{ .name = S("_bytesLoaded"), .v = .{ .number = 0 } },
        .{ .name = S("_bytesTotal"), .v = .undefined_value },
        .{ .name = S("loaded"), .v = .{ .boolean = false } },
    };
    for (fields) |f| {
        if (vm.objects.hasChained(obj, f.name, vm.case_sensitive)) {
            try vm.setProperty(obj, f.name, f.v, .{ .object = obj });
        } else {
            try vm.objects.putWithAttrs(obj, f.name, f.v, hidden, vm.case_sensitive);
        }
    }
}

fn lvLoad(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const url = try vm.toStringValue(args[0]);
    spawn(vm, try buildRequest(vm, url, null, .none, .{ .load_vars = this.object }));
    try resetProgress(vm, this.object);
    return .{ .boolean = true };
}

fn lvSendAndLoad(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const url = try vm.toStringValue(arg(args, 0));
    // The RECEIVER is the second argument; `this` only supplies the data.
    // Anything that is not an object fails the call outright.
    const target = arg(args, 1);
    if (target != .object) return .{ .boolean = false };
    const m = FetchRequest.Method.fromName(try vm.toStringValue(arg(args, 2))) orelse .post;
    spawn(vm, try buildRequest(vm, url, this.object, m, .{ .load_vars = target.object }));
    try resetProgress(vm, target.object);
    return .{ .boolean = true };
}

/// `send` does not fetch: it navigates the browser, which for us means the
/// request is logged and nothing else happens.
fn lvSend(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const url = try vm.toStringValue(args[0]);
    const window = if (args.len > 1) try vm.toStringValue(args[1]) else S("");
    const m = FetchRequest.Method.fromName(try vm.toStringValue(arg(args, 2))) orelse .post;
    try navigate(vm, url, window, m, try formPairs(vm, this.object));
    return .{ .boolean = true };
}

/// An `fscommand:` URL, split into the command (returned) and — at the
/// call site — the target string, which carries the ARGUMENTS. The prefix
/// match is case-insensitive.
pub fn fsCommandOf(url: AvmString) ?AvmString {
    const prefix = S("fscommand:");
    if (url.len < prefix.len) return null;
    if (!strings.eqlIgnoreCase(url[0..prefix.len], prefix)) return null;
    return url[prefix.len..];
}

/// `navigate_to_url_normalized`: a leading `_` is optional and `blank` in
/// any case becomes `_blank`; every other target is passed through as
/// written (corpus geturl_target_normalize walks all fourteen spellings).
pub fn normalizeTarget(t: []const u8) []const u8 {
    const stripped = if (t.len > 0 and t[0] == '_') t[1..] else t;
    if (std.ascii.eqlIgnoreCase(stripped, "blank")) return "_blank";
    return t;
}

pub fn navigate(
    vm: *Vm,
    url: AvmString,
    target: AvmString,
    m: FetchRequest.Method,
    vars: []const runtime.NavigateRequest.Pair,
) !void {
    const h = vm.host;
    const f = h.navigate orelse return;
    const a = vm.arena();
    f(h.ctx orelse return, .{
        .url = try strings.toUtf8(a, url),
        .target = normalizeTarget(try strings.toUtf8(a, target)),
        .method = m,
        .vars = if (m == .none) &.{} else vars,
    });
}

fn lvDecode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const s = try vm.toStringValue(args[0]);
    try decodeInto(vm, this.object, try strings.toUtf8(vm.arena(), s));
    return .undefined_value;
}

fn lvGetBytesLoaded(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.getProperty(this.object, S("_bytesLoaded"), this);
}

fn lvGetBytesTotal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.getProperty(this.object, S("_bytesTotal"), this);
}

fn lvToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .{ .string = S("") };
    const a = vm.arena();
    var keys: std.ArrayList(AvmString) = .empty;
    try enumKeys(vm, this.object, &keys);
    var out: std.ArrayList(u16) = .empty;
    for (keys.items, 0..) |k, i| {
        if (i != 0) try out.append(a, '&');
        // `escape()`'s encoding here, NOT the form-urlencoded one: a space
        // comes out `%20` and `*-._` are escaped too (corpus
        // loadvars_tostring pins every punctuation mark).
        const v = try vm.toStringThrowing(try vm.getProperty(this.object, k, this));
        try appendEscaped(a, &out, k);
        try out.append(a, '=');
        try appendEscaped(a, &out, v);
    }
    return .{ .string = try out.toOwnedSlice(a) };
}

/// `escape()`'s escaping, appended in place. Shared with globals.zig's
/// `escape` — kept here as well because `toString` needs it on a wide
/// string without a round trip through a Value.
fn appendEscaped(a: std.mem.Allocator, out: *std.ArrayList(u16), s: AvmString) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const keep = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z');
        if (keep) {
            try out.append(a, c);
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = if (c < 0x80) blk: {
            buf[0] = @intCast(c);
            break :blk @as(usize, 1);
        } else std.unicode.utf8Encode(c, &buf) catch 0;
        for (buf[0..n]) |b| {
            try out.append(a, '%');
            try out.append(a, hex[(b >> 4) & 0xF]);
            try out.append(a, hex[b & 0xF]);
        }
    }
}

/// `LoadVars.prototype.onData`: decode into `this`, flip `loaded`, then
/// hand `onLoad` the verdict. Content overrides this to see raw text,
/// which is why the default has to be an ordinary script-visible method.
fn onData(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const data = arg(args, 0);
    const success = data != .undefined_value and data != .null_value;
    if (success) {
        try callMethod(vm, this.object, S("decode"), &.{data});
        try vm.setProperty(this.object, S("loaded"), .{ .boolean = true }, this);
    }
    try callMethod(vm, this.object, S("onLoad"), &.{.{ .boolean = success }});
    return .undefined_value;
}

/// Call `obj.name(args)` if it resolves to something callable. A missing
/// handler is the normal case, not an error.
pub fn callMethod(vm: *Vm, obj: ObjectHandle, name: AvmString, args: []const Value) !void {
    const f = vm.objects.getChained(obj, name, vm.case_sensitive) orelse return;
    if (!vm.isCallable(f)) return;
    _ = vm.callFunction(f, .{ .object = obj }, args) catch |e| {
        if (e == error.Avm1Thrown) {
            vm.pending_throw = .undefined_value;
            return;
        }
        return e;
    };
}

// --- completion, called by the Player at the end of the tick ---------------

/// `loadVariables` into a display object or a bare object: the pairs are
/// assigned directly, then `onData` fires with NO arguments (unlike
/// LoadVars, which passes the text).
pub fn completeForm(vm: *Vm, obj: ObjectHandle, data: ?[]const u8) !void {
    if (data) |body| try decodeInto(vm, obj, body);
    try callMethod(vm, obj, S("onData"), &.{});
}

/// `LoadVars.load` / `sendAndLoad`. An EMPTY body counts as a failure —
/// `onData` gets undefined, so `loaded` stays false.
pub fn completeLoadVars(vm: *Vm, obj: ObjectHandle, data: ?[]const u8) !void {
    const a = vm.arena();
    var status: f64 = 0;
    var payload: Value = .undefined_value;
    if (data) |body| {
        status = 200;
        const len: f64 = @floatFromInt(body.len);
        try vm.setProperty(obj, S("_bytesTotal"), .{ .number = len }, .{ .object = obj });
        if (body.len > 0) {
            try vm.setProperty(obj, S("_bytesLoaded"), .{ .number = len }, .{ .object = obj });
            payload = .{ .string = try strings.fromSwf(a, body, vm.swf_version) };
        }
    }
    try callMethod(vm, obj, S("onHTTPStatus"), &.{.{ .number = status }});
    try callMethod(vm, obj, S("onData"), &.{payload});
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the form-urlencoded set is not escape()'s" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try appendFormEscaped(a, &out, S("[object Object]"));
    try testing.expectEqualStrings("%5Bobject+Object%5D", out.items);

    out.clearRetainingCapacity();
    // `*-._` survive here and do NOT survive `escape()`.
    try appendFormEscaped(a, &out, S("a*b-c.d_e f"));
    try testing.expectEqualStrings("a*b-c.d_e+f", out.items);
}

test "percent decoding accepts + as a space and leaves a broken escape alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("The test passed", try percentDecode(a, "The%20test%20passed"));
    try testing.expectEqualStrings("a b", try percentDecode(a, "a+b"));
    try testing.expectEqualStrings("100%", try percentDecode(a, "100%"));
    try testing.expectEqualStrings("%zz", try percentDecode(a, "%zz"));
}
