//! `flash.net.FileReference` and `flash.net.FileReferenceList`.
//!
//! Three operations, each a dialog followed (sometimes) by a transfer:
//! `browse` picks a file, `download` picks a destination and then fetches
//! into it, `upload` posts the picked file's bytes as multipart form data.
//! Every one of them reports through the object's OWN listener list, and
//! the exact event sequence is the whole of what the corpus measures — in
//! particular `onProgress` still fires after an HTTP error, but only when
//! the error happened after the connection was up.
//!
//! `core/` runs no dialogs and does no I/O. The class asks the Player,
//! which asks the frontend and calls back at the end of the tick. The
//! file's METADATA lives on the object as hidden properties (so the
//! getters are ordinary lookups); its BYTES live on the Player, because
//! only `upload` needs them and a Value cannot hold them.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/file_reference.rs,
//! file_reference_list.rs, and loader.rs (`select_file_dialog_avm1`,
//! `download_file_dialog`, `upload_file` — the three event sequences).

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const decl = @import("decl.zig");
const loader = @import("loader.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const AvmString = strings.AvmString;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;

/// Where the picked file's metadata is parked. Hidden and undeletable, so
/// the getters find it and script cannot remove it.
const NAME = "_fr_name";
const TYPE = "_fr_type";
const SIZE = "_fr_size";
const CREATOR = "_fr_creator";
const CREATED = "_fr_created";
const MODIFIED = "_fr_modified";

pub fn install(vm: *Vm, net: ObjectHandle) !void {
    const singletons = @import("singletons.zig");
    {
        const proto = try vm.objects.create();
        vm.objects.get(proto).proto = .{ .object = vm.object_proto };
        try decl.property(vm, proto, "name", getName, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "type", getType, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "size", getSize, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "creator", getCreator, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "creationDate", getCreated, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "modificationDate", getModified, null, .{ .dont_enum = true });
        try decl.property(vm, proto, "postData", getPostData, setPostData, .{ .dont_enum = true });
        try method(vm, proto, "browse", browse, .{ .dont_enum = true });
        try method(vm, proto, "upload", upload, .{ .dont_enum = true });
        try method(vm, proto, "download", download, .{ .dont_enum = true });
        try method(vm, proto, "cancel", cancel, .{ .dont_enum = true });
        try singletons.makeBroadcaster(vm, proto);
        vm.filereference_proto = proto;
        try classUnder(vm, net, "FileReference", ctorRef, proto);
    }
    {
        const proto = try vm.objects.create();
        vm.objects.get(proto).proto = .{ .object = vm.object_proto };
        try method(vm, proto, "browse", browseList, .{ .dont_enum = true });
        try method(vm, proto, "cancel", cancel, .{ .dont_enum = true });
        try singletons.makeBroadcaster(vm, proto);
        try classUnder(vm, net, "FileReferenceList", ctorList, proto);
    }
}

fn classUnder(
    vm: *Vm,
    ns: ObjectHandle,
    comptime name: []const u8,
    f: object_mod.NativeFn,
    proto: ObjectHandle,
) !void {
    const ctor = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, hidden, false);
    try vm.objects.putWithAttrs(ns, S(name), .{ .object = ctor }, .{}, false);
}

fn ctorRef(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn ctorList(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn slot(vm: *Vm, this: Value, comptime name: []const u8) Value {
    if (this != .object) return .undefined_value;
    return vm.objects.getOwn(this.object, S(name), false) orelse .undefined_value;
}

fn getName(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, NAME);
}
fn getType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, TYPE);
}
fn getSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, SIZE);
}
fn getCreator(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, CREATOR);
}
fn getCreated(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, CREATED);
}
fn getModified(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, MODIFIED);
}

fn getPostData(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return slot(vmOf(p), this, "_fr_postdata");
}

fn setPostData(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try vm.objects.putWithAttrs(this.object, S("_fr_postdata"), arg(args, 0), hidden, false);
    return .undefined_value;
}

fn cancel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

/// The metadata half of ruffle's `init_from_file_selection`, called by the
/// Player once a dialog has answered.
pub fn applySelection(
    vm: *Vm,
    obj: ObjectHandle,
    name: []const u8,
    file_type: ?[]const u8,
    size: ?u64,
) !void {
    const a = vm.arena();
    try vm.objects.putWithAttrs(obj, S(NAME), .{
        .string = try strings.fromSwf(a, name, 8),
    }, hidden, false);
    try vm.objects.putWithAttrs(obj, S(TYPE), if (file_type) |t| .{
        .string = try strings.fromSwf(a, t, 8),
    } else .undefined_value, hidden, false);
    try vm.objects.putWithAttrs(obj, S(SIZE), if (size) |n| .{
        .number = @floatFromInt(n),
    } else .undefined_value, hidden, false);
    // The test backend reports no creator and no timestamps, and the
    // corpus reads all three back as undefined.
    try vm.objects.putWithAttrs(obj, S(CREATOR), .undefined_value, hidden, false);
    try vm.objects.putWithAttrs(obj, S(CREATED), .undefined_value, hidden, false);
    try vm.objects.putWithAttrs(obj, S(MODIFIED), .undefined_value, hidden, false);
}

pub fn isInitialised(vm: *Vm, obj: ObjectHandle) bool {
    return vm.objects.getOwn(obj, S(NAME), false) != null;
}

pub fn nameOf(vm: *Vm, obj: ObjectHandle) ?AvmString {
    const v = vm.objects.getOwn(obj, S(NAME), false) orelse return null;
    return if (v == .string) v.string else null;
}

/// Deliver one event to every listener, with the FileReference itself as
/// the first argument. Unlike MovieClipLoader this does NOT route through
/// `broadcastMessage`: ruffle calls `broadcast_internal`, which walks
/// `_listeners` and invokes the handler on each one directly.
pub fn fire(vm: *Vm, obj: ObjectHandle, name: AvmString, extra: []const Value) !void {
    const a = vm.arena();
    const args = try a.alloc(Value, extra.len + 1);
    args[0] = .{ .object = obj };
    @memcpy(args[1..], extra);
    const list = vm.objects.getChained(obj, S("_listeners"), vm.case_sensitive) orelse return;
    if (list != .object) return;
    const n = vm.arrayLength(list.object);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [12]u8 = undefined;
        const idx = try strings.fromSwf(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue, 8);
        const entry = vm.getProperty(list.object, idx, .{ .object = list.object }) catch continue;
        if (entry != .object) continue;
        try loader.callMethod(vm, entry.object, name, args);
    }
}

// --- the browse filter argument --------------------------------------------

/// One filter field, read as an OWN property only. A getter installed by
/// `Object.addProperty` is honoured; one that THROWS makes the field
/// count as missing, which is not the same as a `toString` that throws —
/// that one propagates out of `browse` entirely.
fn filterField(vm: *Vm, obj: ObjectHandle, comptime name: []const u8) ?Value {
    if (!vm.objects.hasOwn(obj, S(name), vm.case_sensitive)) return null;
    return vm.getProperty(obj, S(name), .{ .object = obj }) catch null;
}

/// Parse `browse`'s argument. `null` means "do not open a dialog, return
/// false"; an empty slice means "open with no filters at all", which is
/// what a missing argument does.
fn parseFilters(vm: *Vm, args: []const Value) !?[]const runtime.FileFilter {
    if (args.len == 0) return &.{};
    if (args[0] != .object) return null;
    const array = args[0].object;
    const n = vm.arrayLength(array);
    if (n == 0) return null;
    const a = vm.arena();
    var out: std.ArrayList(runtime.FileFilter) = .empty;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [12]u8 = undefined;
        const idx = try strings.fromSwf(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch return null, 8);
        const elem = vm.getProperty(array, idx, .{ .object = array }) catch Value.undefined_value;
        if (elem != .object) return null;
        const desc_v = filterField(vm, elem.object, "description") orelse return null;
        const ext_v = filterField(vm, elem.object, "extension") orelse return null;
        const mac_v = filterField(vm, elem.object, "macType");
        const desc = try vm.toStringThrowing(desc_v);
        const ext = try vm.toStringThrowing(ext_v);
        if (mac_v) |m| _ = try vm.toStringThrowing(m);
        if (desc.len == 0 or ext.len == 0) return null;
        try out.append(a, .{
            .description = try strings.toUtf8(a, desc),
            .extension = try strings.toUtf8(a, ext),
        });
    }
    return out.items;
}

fn browse(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const filters = try parseFilters(vm, args) orelse return .{ .boolean = false };
    const h = vm.host;
    const f = h.file_dialog orelse return .{ .boolean = false };
    f(h.ctx orelse return .{ .boolean = false }, .{
        .obj = this.object,
        .what = .{ .browse = filters },
    });
    return .{ .boolean = true };
}

fn browseList(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const filters = try parseFilters(vm, args) orelse return .{ .boolean = false };
    const h = vm.host;
    const f = h.file_dialog orelse return .{ .boolean = false };
    f(h.ctx orelse return .{ .boolean = false }, .{
        .obj = this.object,
        .what = .{ .browse_multi = filters },
    });
    return .{ .boolean = true };
}

/// `download(url, fileName)`. The URL must PARSE — a bare word or a `@`
/// is rejected without opening anything — and with no explicit name the
/// last path component is used.
fn download(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const url = try vm.toStringValue(args[0]);
    const url_utf8 = try strings.toUtf8(vm.arena(), url);
    if (!isAbsoluteUrl(url_utf8)) return .{ .boolean = false };
    const name = if (args.len > 1)
        try strings.toUtf8(vm.arena(), try vm.toStringValue(args[1]))
    else
        lastPathSegment(url_utf8);
    const h = vm.host;
    const f = h.file_dialog orelse return .{ .boolean = false };
    f(h.ctx orelse return .{ .boolean = false }, .{
        .obj = this.object,
        .what = .{ .download = .{ .url = url_utf8, .name = name } },
    });
    return .{ .boolean = true };
}

/// `upload(url)`. Nothing to upload without a prior `browse`, and only
/// http(s) destinations are allowed.
fn upload(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (!isInitialised(vm, this.object)) return .{ .boolean = false };
    if (args.len == 0) return .{ .boolean = false };
    const url = try strings.toUtf8(vm.arena(), try vm.toStringValue(args[0]));
    if (!isAbsoluteUrl(url)) return .{ .boolean = false };
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .{ .boolean = false };
    }
    const h = vm.host;
    const f = h.file_dialog orelse return .{ .boolean = false };
    f(h.ctx orelse return .{ .boolean = false }, .{
        .obj = this.object,
        .what = .{ .upload = url },
    });
    return .{ .boolean = true };
}

/// `Url::parse` succeeds only on an ABSOLUTE URL — a scheme, then `:`.
/// "baddomain" and "@" both fail, which is what makes `download` return
/// false for them without ever opening a dialog.
fn isAbsoluteUrl(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

fn lastPathSegment(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOfScalar(u8, s, '?')) |q| s = s[0..q];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}
