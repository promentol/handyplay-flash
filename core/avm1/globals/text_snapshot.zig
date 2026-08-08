//! `TextSnapshot` — a read-only view of the STATIC text in a clip.
//!
//! `MovieClip.getTextSnapshot()` hands one back. Unlike most built-ins its
//! methods carry no attribute flags at all: they enumerate, they can be
//! shadowed by an instance property, and deleting that shadow uncovers the
//! prototype's again — which is exactly what `textsnapshot_props_swf5/6`
//! check.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/text_snapshot.rs and
//! core/src/display_object/text.rs:310-443.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const stage_object = @import("../stage_object.zig");
const text_walk = @import("../../display/text.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.textsnapshot_proto = proto;

    // No flags: enumerable, writable, deletable. Declaration order is
    // reversed by enumeration, and the corpus prints it.
    const v6 = ver(.{}, decl.V6);
    try decl.method(vm, proto, "getCount", getCount, v6);
    try decl.method(vm, proto, "setSelected", setSelected, v6);
    try decl.method(vm, proto, "getSelected", getSelected, v6);
    try decl.method(vm, proto, "getText", getText, v6);
    try decl.method(vm, proto, "getSelectedText", getSelectedText, v6);
    try decl.method(vm, proto, "hitTestTextNearPos", hitTestTextNearPos, v6);
    try decl.method(vm, proto, "findText", findText, v6);
    try decl.method(vm, proto, "setSelectColor", setSelectColor, v6);
    try decl.method(vm, proto, "getTextRunInfo", getTextRunInfo, v6);

    _ = try decl.class(vm, "TextSnapshot", construct, proto, decl.hidden);
}

/// `new TextSnapshot(clip)` — the clip arrives as the first argument, put
/// there by `MovieClip.getTextSnapshot`.
fn construct(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return this;
    const clip = arg(args, 0);
    if (clip == .object) {
        try vm.objects.putWithAttrs(this.object, S("__clip"), clip, decl.frozen, false);
    }
    return this;
}

/// The static-text runs directly under the snapshot's clip. Each
/// `DefineText` is one CHUNK: ruffle walks the render list of the target
/// ONLY (no recursion into child clips) and keeps the runs separate,
/// because `getText`'s `includeNewlines` joins them with a newline
/// (text.rs:348-366).
fn collect(vm: *Vm, this: Value, out: *std.ArrayList([]const u16)) !void {
    if (this != .object) return;
    const clip_v = vm.objects.getChained(this.object, S("__clip"), false) orelse return;
    const t = stage_object.targetOfValue(vm, clip_v) orelse return;
    const clip = t.clip orelse return;
    const ctx = stage_object.displayCtxOf(vm) orelse return;
    for (clip.children.items) |child| {
        if (child.kind != .text) continue;
        var chunk: std.ArrayList(u16) = .empty;
        var w = text_walk.Walker.init(child.kind.text, &ctx.movie.lib);
        while (w.next()) |g| {
            if (g.glyph.code != 0) try chunk.append(vm.arena(), g.glyph.code);
        }
        try out.append(vm.arena(), chunk.items);
    }
}

/// Every chunk concatenated, with an optional newline between them.
fn flatten(vm: *Vm, chunks: []const []const u16, newlines: bool) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    for (chunks, 0..) |c, i| {
        if (i > 0 and newlines) try out.append(vm.arena(), '\n');
        try out.appendSlice(vm.arena(), c);
    }
    return out.items;
}

fn totalLen(chunks: []const []const u16) usize {
    var n: usize = 0;
    for (chunks) |c| n += c.len;
    return n;
}

fn getCount(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    var chunks: std.ArrayList([]const u16) = .empty;
    try collect(vm, this, &chunks);
    return .{ .number = @floatFromInt(totalLen(chunks.items)) };
}

/// `getText(from, to [, includeNewlines])`. Fewer than two arguments — or
/// more than three — is `undefined`, not an empty string. The range is
/// clamped oddly and deliberately (ruffle text.rs:372): `from` to at most
/// count-1, `to` to at most count but never below `from + 1`, so an
/// inverted or out-of-range pair still yields one character.
fn getText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2 or args.len > 3) return .undefined_value;
    var chunks: std.ArrayList([]const u16) = .empty;
    try collect(vm, this, &chunks);
    const count = totalLen(chunks.items);
    if (count == 0) return .{ .string = S("") };

    const from = value_mod.toInt32(try vm.toNumber(args[0]));
    const to = value_mod.toInt32(try vm.toNumber(args[1]));
    const newlines = args.len > 2 and value_mod.toBoolean(args[2], vm.swf_version);
    const start = @min(nonNegative(from), count - 1);
    const end = @max(@min(nonNegative(to), count), start + 1);

    // Slice ACROSS chunks, inserting the separator only between two
    // chunks that both contribute.
    var out: std.ArrayList(u16) = .empty;
    var base: usize = 0;
    for (chunks.items) |c| {
        const lo = if (start > base) start - base else 0;
        const hi = if (end > base) @min(end - base, c.len) else 0;
        if (lo < hi) {
            if (out.items.len > 0 and newlines) try out.append(vm.arena(), '\n');
            try out.appendSlice(vm.arena(), c[lo..hi]);
        }
        base += c.len;
    }
    return .{ .string = out.items };
}

/// `usize::try_from(i32).unwrap_or_default()` — a negative index is 0.
fn nonNegative(v: i32) usize {
    return if (v < 0) 0 else @intCast(v);
}

fn getSelected(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .boolean = false };
}

fn getSelectedText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .string = S("") };
}

fn setSelected(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .undefined_value;
}

fn setSelectColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .undefined_value;
}

fn hitTestTextNearPos(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .number = -1 };
}

/// `findText(start, text, caseSensitive)` — EXACTLY three arguments, or
/// the answer is undefined rather than -1.
fn findText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len != 3) return .undefined_value;
    var chunks: std.ArrayList([]const u16) = .empty;
    try collect(vm, this, &chunks);
    const hay = try flatten(vm, chunks.items, false);
    const start = value_mod.toInt32(try vm.toNumber(args[0]));
    const needle = try vm.toStringValue(args[1]);
    const case_sensitive = value_mod.toBoolean(args[2], vm.swf_version);
    if (needle.len == 0 or start < 0) return .{ .number = -1 };
    var i: usize = @intCast(start);
    while (i + needle.len <= hay.len) : (i += 1) {
        const window = hay[i .. i + needle.len];
        const hit = if (case_sensitive)
            strings.eql(window, needle)
        else
            strings.eqlIgnoreCase(window, needle);
        if (hit) return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

fn getTextRunInfo(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ this, args };
    const vm = vmOf(p);
    return .{ .object = try vm.newArray() };
}
