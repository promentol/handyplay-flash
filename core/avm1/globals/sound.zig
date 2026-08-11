//! The AVM1 `Sound` class.
//!
//! There is no audio here yet (M6 owns playback), and almost none of this
//! class needs it: what content actually reads back is the SOUND
//! TRANSFORM, and that lives on the owning display object, not on the
//! Sound. Two `Sound` objects pointed at the same clip see each other's
//! volume; a Sound built with no target reads and writes the GLOBAL
//! transform instead. `new Sound(mc)` stores mc's PATH, not the clip, and
//! re-resolves it on every call — so a Sound whose owner has been removed
//! stops answering, and starts again if a clip reappears there.
//!
//! Three quirks that look like bugs and are not:
//!   • `pan` is DERIVED from the two diagonal-free channels, with an
//!     `abs()` in it that makes `setPan(200)` read back as 0.
//!   • `setVolume`/`setPan` use Flash's OTHER f64→i32 rule
//!     (`value.clampToI32`), so NaN and anything out of range become
//!     i32::MIN rather than saturating.
//!   • `lr` means RIGHT-to-left and `rl` means LEFT-to-right, in both
//!     `getTransform` and `setTransform`. The names are backwards and the
//!     corpus pins them.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/sound.rs and
//! core/src/display_object.rs (`SoundTransform`).

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage = @import("../stage_object.zig");
const mp3 = @import("../../codecs/mp3.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const AvmString = strings.AvmString;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const frozen = decl.frozen;
const ver = decl.ver;

/// The owner's target PATH, as the constructor was given it. Absent means
/// "the global sound", which is a different thing from a path that no
/// longer resolves.
const TARGET = "_snd_target";
/// Milliseconds, or undefined when nothing is attached.
const DURATION = "_snd_duration";
const POSITION = "_snd_position";
/// Has a sound been attached or loaded? `position` reads undefined until
/// one has, even though `duration` does not.
const LOADED = "_snd_loaded";
/// A `loadSound` is in flight. A `start()` during that window is not
/// dropped — ruffle queues the play and runs it when the bytes land.
const LOADING = "_snd_loading";
const QUEUED = "_snd_queued";
/// `loadSound(url, true)`. A streaming sound auto-plays as soon as it has
/// loaded, without anyone calling `start`.
const STREAMING = "_snd_streaming";
/// The character id `attachSound` resolved, or the handle the Player gave
/// back for a `loadSound`. Zero means nothing to play.
const HANDLE = "_snd_handle";

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    const m = frozen;
    try decl.method(vm, proto, "getPan", getPan, m);
    try decl.method(vm, proto, "getTransform", getTransform, m);
    try decl.method(vm, proto, "getVolume", getVolume, m);
    try decl.method(vm, proto, "setPan", setPan, m);
    try decl.method(vm, proto, "setTransform", setTransform, m);
    try decl.method(vm, proto, "setVolume", setVolume, m);
    try decl.method(vm, proto, "stop", stop, m);
    try decl.method(vm, proto, "attachSound", attachSound, m);
    try decl.method(vm, proto, "start", start, m);
    try decl.method(vm, proto, "getDuration", getDuration, ver(m, decl.V6));
    try decl.method(vm, proto, "setDuration", noop, ver(m, decl.V6));
    try decl.method(vm, proto, "getPosition", getPosition, ver(m, decl.V6));
    try decl.method(vm, proto, "setPosition", noop, ver(m, decl.V6));
    try decl.method(vm, proto, "loadSound", loadSound, ver(m, decl.V6));
    try decl.method(vm, proto, "getBytesLoaded", oneFn, ver(m, decl.V6));
    try decl.method(vm, proto, "getBytesTotal", oneFn, ver(m, decl.V6));
    vm.sound_proto = proto;
    _ = try decl.class(vm, "Sound", ctor, proto, .{ .dont_enum = true });
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

/// `getBytesLoaded`/`getBytesTotal` are stubs in ruffle too, and both
/// answer 1 rather than 0 — content divides by them.
fn oneFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .number = 1 };
}

/// `new Sound(target)`. The argument is coerced to a STRING path right
/// here and never looked at again as an object; null and undefined both
/// mean "the global sound".
fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return this;
    const t = arg(args, 0);
    if (t != .null_value and t != .undefined_value) {
        // A THROWING `toString` on the target escapes the constructor —
        // the corpus catches the uncaught-exception warning and finds the
        // Sound half-built (sound_owner_tostring_fail).
        const path = try vm.toStringThrowing(t);
        try vm.objects.putWithAttrs(this.object, S(TARGET), .{ .string = path }, decl.hidden, false);
    }
    return this;
}

/// The hidden slots are DONT_DELETE, so a flag is cleared by writing
/// false rather than by deleting it.
fn setFlag(vm: *Vm, obj: ObjectHandle, comptime name: []const u8, on: bool) !void {
    try vm.objects.putWithAttrs(obj, S(name), .{ .boolean = on }, decl.hidden, false);
}

fn queuedCount(vm: *Vm, obj: ObjectHandle) f64 {
    const v = vm.objects.getOwn(obj, S(QUEUED), false) orelse return 0;
    return if (v == .number) v.number else 0;
}

fn flag(vm: *Vm, obj: ObjectHandle, comptime name: []const u8) bool {
    const v = vm.objects.getOwn(obj, S(name), false) orelse return false;
    return v == .boolean and v.boolean;
}

fn isSound(vm: *Vm, this: Value) bool {
    if (this != .object) return false;
    // Any object built by this constructor carries the prototype; the
    // target slot is optional, so identity comes from the chain.
    return vm.objects.getChained(this.object, S("getVolume"), vm.case_sensitive) != null;
}

/// The path the constructor was handed, or null for the global sound.
fn targetPath(vm: *Vm, this: Value) ?AvmString {
    if (this != .object) return null;
    const v = vm.objects.getOwn(this.object, S(TARGET), false) orelse return null;
    return if (v == .string) v.string else null;
}

/// The clip this Sound speaks for. Null means either "global" (no target
/// at all) or "the target does not resolve", and the two are told apart
/// by `targetPath` — the second answers undefined to everything.
fn owner(vm: *Vm, this: Value) ?stage.Target {
    const path = targetPath(vm, this) orelse return null;
    const act = @import("../activation.zig").Activation;
    const start_clip = act.baseClipForNative(vm) orelse
        (if (vm.root_object == .object) vm.root_object.object else return null);
    const h = act.resolveTargetForNative(vm, start_clip, path) catch return null;
    return stage.targetOf(vm, h orelse return null);
}

/// Does this Sound have something to speak for at all?
fn hasOwner(vm: *Vm, this: Value) bool {
    if (targetPath(vm, this) == null) return true; // global
    return owner(vm, this) != null;
}

fn transformOf(vm: *Vm, this: Value) ?runtime.SoundTransform {
    if (targetPath(vm, this) == null) return vm.global_sound_transform;
    const t = owner(vm, this) orelse return null;
    return t.obj.sound_transform;
}

fn setTransformOf(vm: *Vm, this: Value, st: runtime.SoundTransform) void {
    if (targetPath(vm, this) == null) {
        vm.global_sound_transform = st;
    } else if (owner(vm, this)) |t| {
        t.obj.sound_transform = st;
    } else return;
    // A volume change during playback is heard immediately — Flash does
    // not wait for the next `start()`.
    if (this == .object) {
        if (vm.host.sound_transform) |f| {
            if (vm.host.ctx) |c| {
                f(c, this.object, @floatFromInt(st.volume), @floatFromInt(st.pan()));
            }
        }
    }
}

fn getVolume(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const st = transformOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(st.volume) };
}

fn setVolume(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    // A MISSING argument is zero, not undefined — `setVolume()` mutes
    // rather than setting i32::MIN (ruffle `unwrap_or(&0.into())`).
    const n = value_mod.clampToI32(try vm.toNumber(if (args.len == 0) Value{ .number = 0 } else args[0]));
    var st = transformOf(vm, this) orelse return .undefined_value;
    st.volume = n;
    setTransformOf(vm, this, st);
    return .undefined_value;
}

fn getPan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const st = transformOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(st.pan()) };
}

fn setPan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    const n = value_mod.clampToI32(try vm.toNumber(if (args.len == 0) Value{ .number = 0 } else args[0]));
    var st = transformOf(vm, this) orelse return .undefined_value;
    st.setPan(n);
    setTransformOf(vm, this, st);
    return .undefined_value;
}

fn getTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const st = transformOf(vm, this) orelse return .undefined_value;
    const out = try vm.newObject();
    // `lr` is RIGHT-to-left and `rl` is LEFT-to-right. Backwards, and
    // both directions of the API agree on it.
    try vm.setProperty(out, S("ll"), .{ .number = @floatFromInt(st.left_to_left) }, .{ .object = out });
    try vm.setProperty(out, S("lr"), .{ .number = @floatFromInt(st.right_to_left) }, .{ .object = out });
    try vm.setProperty(out, S("rr"), .{ .number = @floatFromInt(st.right_to_right) }, .{ .object = out });
    try vm.setProperty(out, S("rl"), .{ .number = @floatFromInt(st.left_to_right) }, .{ .object = out });
    return .{ .object = out };
}

fn setTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    const src = arg(args, 0);
    if (src != .object) return .undefined_value;
    var st = transformOf(vm, this) orelse return .undefined_value;
    const o = src.object;
    if (vm.objects.hasOwn(o, S("ll"), vm.case_sensitive)) {
        st.left_to_left = value_mod.toInt32(try vm.toNumber(try vm.getProperty(o, S("ll"), src)));
    }
    if (vm.objects.hasOwn(o, S("rl"), vm.case_sensitive)) {
        st.left_to_right = value_mod.toInt32(try vm.toNumber(try vm.getProperty(o, S("rl"), src)));
    }
    if (vm.objects.hasOwn(o, S("lr"), vm.case_sensitive)) {
        st.right_to_left = value_mod.toInt32(try vm.toNumber(try vm.getProperty(o, S("lr"), src)));
    }
    if (vm.objects.hasOwn(o, S("rr"), vm.case_sensitive)) {
        st.right_to_right = value_mod.toInt32(try vm.toNumber(try vm.getProperty(o, S("rr"), src)));
    }
    setTransformOf(vm, this, st);
    return .undefined_value;
}

/// `attachSound(name)` — a library sound by export name. Nothing plays,
/// but the DURATION is real: it comes from the tag's sample count.
fn attachSound(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    const name = try vm.toStringValue(arg(args, 0));
    const clip = if (owner(vm, this)) |t| t.clip else null;
    const id = try stage.exportedCharacter(vm, clip, name) orelse return .undefined_value;
    const ms = stage.soundDurationMs(vm, clip, id) orelse return .undefined_value;
    try vm.objects.putWithAttrs(this.object, S(DURATION), .{ .number = ms }, decl.hidden, false);
    try vm.objects.putWithAttrs(this.object, S(HANDLE), .{ .number = @floatFromInt(id) }, decl.hidden, false);
    try vm.objects.putWithAttrs(this.object, S(POSITION), .{ .number = 0 }, decl.hidden, false);
    try vm.objects.putWithAttrs(this.object, S(LOADED), .{ .boolean = true }, decl.hidden, false);
    try defineLiveProps(vm, this.object);
    return .undefined_value;
}

/// `position` and `duration` are not on the prototype: ruffle adds them
/// to the INSTANCE the first time a sound lands on it, which is why they
/// read undefined on a bare `new Sound()`.
fn defineLiveProps(vm: *Vm, obj: ObjectHandle) !void {
    // BOTH or NEITHER, and the test is an OR: ruffle installs the pair
    // whenever EITHER is missing. Setting only `position` before the load
    // therefore loses it — the accessor lands on top — while setting both
    // keeps both, which is exactly what the corpus walks through
    // (sound_duration_position_props, places -2, -1 and 0).
    const has_d = vm.objects.hasChained(obj, S("duration"), vm.case_sensitive);
    const has_p = vm.objects.hasChained(obj, S("position"), vm.case_sensitive);
    if (has_d and has_p) return;
    try decl.property(vm, obj, "duration", getDuration, null, decl.hidden);
    try decl.property(vm, obj, "position", getPosition, null, decl.hidden);
}

pub fn getDuration(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    return vm.objects.getOwn(this.object, S(DURATION), false) orelse .undefined_value;
}

pub fn getPosition(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    // Unlike `duration`, position needs a sound actually attached.
    if (!flag(vm, this.object, LOADED)) return .undefined_value;
    // While something is playing the mixer knows; once it has stopped the
    // stored value is the last thing anyone saw.
    if (vm.host.sound_position) |f| {
        if (vm.host.ctx) |c| {
            const ms = f(c, this.object);
            if (ms >= 0) return .{ .number = @round(ms) };
        }
    }
    return vm.objects.getOwn(this.object, S(POSITION), false) orelse .undefined_value;
}

/// `start(offset, loops)`. The mixer does the playing; what happens here
/// is only the bookkeeping — which sound, from where, how many times, and
/// under whose name the completion will come back.
fn start(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    if (!flag(vm, this.object, LOADED)) {
        // Still loading: remember the play rather than dropping it.
        if (flag(vm, this.object, LOADING)) {
            // A COUNT, not a flag: ruffle keeps a vector of queued plays
            // and runs every one of them when the bytes land.
            try vm.objects.putWithAttrs(
                this.object,
                S(QUEUED),
                .{ .number = queuedCount(vm, this.object) + 1 },
                decl.hidden,
                false,
            );
        }
        return .undefined_value;
    }
    const offset = if (args.len > 0) try vm.toNumber(args[0]) else 0;
    const total = if (args.len > 1) try vm.toNumber(args[1]) else 1;
    try playNow(vm, this.object, offset, total);
    return .undefined_value;
}

/// Ask the Player for an instance. Shared by `start` and by the queued
/// plays a `loadSound` releases.
fn playNow(vm: *Vm, obj: ObjectHandle, offset_secs: f64, total_plays: f64) !void {
    const h = vm.host;
    const f = h.sound_play orelse return;
    const ctx = h.ctx orelse return;
    const handle = handleOf(vm, obj);
    if (handle == 0) return;
    const st = transformOfHandle(vm, obj);
    // Flash counts TOTAL plays and treats anything under one as one.
    const repeats: f64 = if (std.math.isNan(total_plays) or total_plays <= 1) 0 else total_plays - 1;
    f(ctx, .{
        .owner = obj,
        .handle = handle,
        .offset_secs = if (std.math.isFinite(offset_secs) and offset_secs > 0) offset_secs else 0,
        .loops = @intFromFloat(@min(repeats, 65535)),
        .volume = st[0],
        .pan = st[1],
    });
}

fn handleOf(vm: *Vm, obj: ObjectHandle) u32 {
    const v = vm.objects.getOwn(obj, S(HANDLE), false) orelse return 0;
    if (v != .number or !std.math.isFinite(v.number) or v.number < 0) return 0;
    return @intFromFloat(v.number);
}

/// The object's volume and pan as plain numbers, for the mixer.
fn transformOfHandle(vm: *Vm, obj: ObjectHandle) [2]f64 {
    const st = transformOf(vm, .{ .object = obj }) orelse return .{ 100, 0 };
    return .{ @floatFromInt(st.volume), @floatFromInt(st.pan()) };
}

/// `stop()` — with no argument, everything this object started; with a
/// linkage name, that sound wherever it is playing. A stopped sound does
/// NOT report completion (corpus sound_start_stop expects silence).
fn stop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    const h = vm.host;
    const f = h.sound_stop orelse return .undefined_value;
    const ctx = h.ctx orelse return .undefined_value;
    _ = args;
    f(ctx, this.object);
    return .undefined_value;
}

/// `loadSound(url, isStreaming)`. The bytes come back through the same
/// seam every other load uses; an MP3's duration and its ID3 tag are read
/// off them when they arrive.
fn loadSound(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    if (args.len == 0) return .undefined_value;
    const url = try vm.toStringValue(args[0]);
    try setFlag(vm, this.object, STREAMING, value_mod.toBoolean(arg(args, 1), vm.swf_version));
    // A second `loadSound` DISCARDS whatever was queued against the
    // first — ruffle's `set_is_loading` throws the queue away.
    try setFlag(vm, this.object, LOADING, true);
    try vm.objects.putWithAttrs(this.object, S(QUEUED), .{ .number = 0 }, decl.hidden, false);
    const l = @import("loader.zig");
    l.spawn(vm, .{
        .url = try strings.toUtf8(vm.arena(), url),
        .target = .{ .sound = this.object },
    });
    return .undefined_value;
}

/// The Player calls this when a `loadSound` answers. An MP3 we cannot
/// decode still counts as loaded — the corpus only reads the duration
/// and the ID3 frames back.
pub fn completeLoad(vm: *Vm, obj: ObjectHandle, data: ?[]const u8) !void {
    const l = @import("loader.zig");
    const bytes = data orelse {
        try setFlag(vm, obj, LOADING, false);
        try l.callMethod(vm, obj, S("onLoad"), &.{.{ .boolean = false }});
        return;
    };
    try setFlag(vm, obj, LOADED, true);
    // The mixer takes the bytes now; an MP3 it cannot decode still counts
    // as loaded, because the corpus reads the duration and the ID3 frames
    // back either way.
    if (vm.host.sound_register) |reg| {
        if (vm.host.ctx) |c| {
            const handle = reg(c, bytes);
            try vm.objects.putWithAttrs(obj, S(HANDLE), .{ .number = @floatFromInt(handle) }, decl.hidden, false);
        }
    }
    try vm.objects.putWithAttrs(obj, S(POSITION), .{ .number = 0 }, decl.hidden, false);
    try defineLiveProps(vm, obj);
    // The order is ruffle's `load_sound_avm1` and it is observable: the
    // duration is ZERO while `onID3` runs and only becomes real before
    // `onLoad`, so a handler that prints both sees 0 and then 1045.
    try vm.objects.putWithAttrs(obj, S(DURATION), .{ .number = 0 }, decl.hidden, false);
    try loadId3(vm, obj, bytes);
    if (mp3.durationMs(bytes)) |ms| {
        try vm.objects.putWithAttrs(obj, S(DURATION), .{ .number = ms }, decl.hidden, false);
    }
    // A play that arrived while the bytes were still coming runs now.
    const queued = queuedCount(vm, obj);
    try vm.objects.putWithAttrs(obj, S(QUEUED), .{ .number = 0 }, decl.hidden, false);
    try setFlag(vm, obj, LOADING, false);
    try l.callMethod(vm, obj, S("onLoad"), &.{.{ .boolean = true }});
    // A streaming sound starts itself, AFTER onLoad.
    var plays = queued;
    if (flag(vm, obj, STREAMING)) plays += 1;
    var k: f64 = 0;
    while (k < plays) : (k += 1) try playNow(vm, obj, 0, 1);
}

/// The sound has finished: its position is now its whole duration, and
/// only then does the handler run.
pub fn finishPlay(vm: *Vm, obj: ObjectHandle) !void {
    if (vm.objects.getOwn(obj, S(DURATION), false)) |d| {
        try vm.objects.putWithAttrs(obj, S(POSITION), d, decl.hidden, false);
    }
    try @import("loader.zig").callMethod(vm, obj, S("onSoundComplete"), &.{});
}

/// Build the `id3` bag and hand it to `onID3`.
///
/// The object has NO PROTOTYPE, which is most of what the corpus checks:
/// with no `valueOf` to find, `"" + id3` comes out "undefined" while
/// `typeof` still says object, and `id3 == undefined` is true where
/// `===` is false.
///
/// Each frame contributes its ID3 1.0 ALIAS first and then its raw
/// four-letter id, so a `for..in` — which walks the list backwards —
/// reports the raw id ahead of the alias.
fn loadId3(vm: *Vm, sound: ObjectHandle, bytes: []const u8) !void {
    const l = @import("loader.zig");
    if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return;
    const version = bytes[3];
    const end = mp3.skipId3(bytes);
    // Bare: `vm.objects.create()` leaves the prototype unset, which is
    // exactly `Object::new_without_proto`.
    const id3 = try vm.objects.create();
    const id_len: usize = if (version <= 2) 3 else 4;
    const size_len: usize = if (version <= 2) 3 else 4;
    const flag_len: usize = if (version <= 2) 0 else 2;
    var i: usize = 10;
    while (i + id_len + size_len + flag_len <= end) {
        const id = bytes[i .. i + id_len];
        if (id[0] == 0) break;
        var size: usize = 0;
        for (bytes[i + id_len ..][0..size_len]) |b| size = (size << 8) | b;
        i += id_len + size_len + flag_len;
        if (size == 0 or i + size > end) break;
        const body = bytes[i .. i + size];
        i += size;
        const raw = try strings.fromSwf(vm.arena(), id, 5);
        if (std.mem.eql(u8, id, "COMM") or std.mem.eql(u8, id, "COM")) {
            const text = try commentText(vm, body);
            // The 2.0 slot aggregates every comment into an ARRAY; the
            // 1.0 alias keeps only the last one.
            const arr = blk: {
                const existing = vm.objects.getOwn(id3, raw, false) orelse break :blk try vm.newArray();
                break :blk if (existing == .object) existing.object else try vm.newArray();
            };
            const n = vm.arrayLength(arr);
            try vm.arraySet(arr, n, .{ .string = text });
            try vm.setArrayLength(arr, n + 1);
            try vm.objects.put(id3, S("comment"), .{ .string = text }, false);
            try vm.objects.put(id3, raw, .{ .object = arr }, false);
            continue;
        }
        if (id[0] != 'T') continue; // only text frames cross
        const text = try frameText(vm, body);
        if (id3Alias(id)) |alias| try vm.objects.put(id3, alias, .{ .string = text }, false);
        try vm.objects.put(id3, raw, .{ .string = text }, false);
    }
    // Script can have set `id3` itself, and then it keeps it.
    if (!vm.objects.hasChained(sound, S("id3"), vm.case_sensitive)) {
        try vm.objects.putWithAttrs(sound, S("id3"), .{ .object = id3 }, frozen, false);
    }
    // Flash always passes `true`, whatever the documentation says.
    try l.callMethod(vm, sound, S("onID3"), &.{.{ .boolean = true }});
}

/// A text frame's payload: one encoding byte, then the string.
fn frameText(vm: *Vm, body: []const u8) !AvmString {
    if (body.len == 0) return &.{};
    return decodeFrame(vm, body[0], body[1..]);
}

/// Encoding 1 is UTF-16 with a BOM, anything else Latin-1. The
/// TERMINATOR differs with it: a UTF-16 string ends in two NUL bytes,
/// and stripping them one at a time eats the high byte of the last
/// character.
fn decodeFrame(vm: *Vm, enc: u8, raw: []const u8) !AvmString {
    if (enc != 1) {
        var t = raw;
        while (t.len > 0 and t[t.len - 1] == 0) t = t[0 .. t.len - 1];
        return strings.fromSwf(vm.arena(), t, 5);
    }
    var t = raw;
    while (t.len >= 2 and t[t.len - 1] == 0 and t[t.len - 2] == 0) t = t[0 .. t.len - 2];
    return utf16Bom(vm, t);
}

/// A COMM frame: encoding, a three-byte language, a NUL-terminated
/// description, and then the comment itself.
fn commentText(vm: *Vm, body: []const u8) !AvmString {
    if (body.len < 4) return &.{};
    const enc = body[0];
    var rest = body[4..];
    // The description is NUL-terminated, and in UTF-16 that is a NUL
    // PAIR — on a two-byte boundary, so an odd stray zero is a low byte.
    if (enc == 1) {
        var k: usize = 0;
        while (k + 1 < rest.len) : (k += 2) {
            if (rest[k] == 0 and rest[k + 1] == 0) break;
        }
        rest = if (k + 1 < rest.len) rest[k + 2 ..] else rest[rest.len..];
    } else if (std.mem.indexOfScalar(u8, rest, 0)) |z| {
        rest = rest[z + 1 ..];
    }
    return decodeFrame(vm, enc, rest);
}

fn utf16Bom(vm: *Vm, raw: []const u8) !AvmString {
    var b = raw;
    var big = false;
    if (b.len >= 2 and b[0] == 0xFE and b[1] == 0xFF) {
        big = true;
        b = b[2..];
    } else if (b.len >= 2 and b[0] == 0xFF and b[1] == 0xFE) {
        b = b[2..];
    }
    const out = try vm.arena().alloc(u16, b.len / 2);
    for (out, 0..) |*u, k| {
        const lo = b[k * 2];
        const hi = b[k * 2 + 1];
        u.* = if (big) (@as(u16, lo) << 8) | hi else (@as(u16, hi) << 8) | lo;
    }
    return out;
}

/// The seven frames that also get an ID3 1.0 name. Everything else is
/// exposed under its raw id only (ruffle sound.rs `load_id3`).
fn id3Alias(id: []const u8) ?AvmString {
    const table = .{
        .{ "COMM", "comment" }, .{ "TALB", "album" },    .{ "TCON", "genre" },
        .{ "TIT2", "songname" }, .{ "TPE1", "artist" },  .{ "TRCK", "track" },
        .{ "TYER", "year" },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, id, e[0])) return S(e[1]);
    }
    return null;
}
