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
        return;
    }
    const t = owner(vm, this) orelse return;
    t.obj.sound_transform = st;
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
    try vm.objects.putWithAttrs(this.object, S(POSITION), .{ .number = 0 }, decl.hidden, false);
    try vm.objects.putWithAttrs(this.object, S(LOADED), .{ .boolean = true }, decl.hidden, false);
    try defineLiveProps(vm, this.object);
    return .undefined_value;
}

/// `position` and `duration` are not on the prototype: ruffle adds them
/// to the INSTANCE the first time a sound lands on it, which is why they
/// read undefined on a bare `new Sound()`.
fn defineLiveProps(vm: *Vm, obj: ObjectHandle) !void {
    if (vm.objects.hasOwn(obj, S("duration"), vm.case_sensitive)) return;
    try decl.property(vm, obj, "duration", getDuration, null, decl.hidden);
    try decl.property(vm, obj, "position", getPosition, null, decl.hidden);
}

fn getDuration(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    return vm.objects.getOwn(this.object, S(DURATION), false) orelse .undefined_value;
}

fn getPosition(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
    if (!hasOwner(vm, this)) return .undefined_value;
    // Unlike `duration`, position needs a sound actually attached.
    if (!flag(vm, this.object, LOADED)) return .undefined_value;
    return vm.objects.getOwn(this.object, S(POSITION), false) orelse .undefined_value;
}

/// Playback is M6. What survives without it is the COMPLETION: with no
/// audio device the sound is over as soon as it starts, so `onSoundComplete`
/// fires on the next tick — which is what the corpus records.
fn start(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
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
    const h = vm.host;
    if (h.sound_complete) |f| f(h.ctx orelse return .undefined_value, this.object);
    return .undefined_value;
}

fn stop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (!isSound(vm, this)) return .undefined_value;
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
        try l.callMethod(vm, obj, S("onLoad"), &.{.{ .boolean = false }});
        return;
    };
    try vm.objects.putWithAttrs(obj, S(LOADED), .{ .boolean = true }, decl.hidden, false);
    try vm.objects.putWithAttrs(obj, S(POSITION), .{ .number = 0 }, decl.hidden, false);
    if (mp3DurationMs(bytes)) |ms| {
        try vm.objects.putWithAttrs(obj, S(DURATION), .{ .number = ms }, decl.hidden, false);
    }
    try defineLiveProps(vm, obj);
    // A play that arrived while the bytes were still coming runs now.
    const queued = queuedCount(vm, obj);
    try vm.objects.putWithAttrs(obj, S(QUEUED), .{ .number = 0 }, decl.hidden, false);
    try setFlag(vm, obj, LOADING, false);
    const h = vm.host;
    var k: f64 = 0;
    while (k < queued) : (k += 1) {
        if (h.sound_complete) |f| {
            if (h.ctx) |c| f(c, obj);
        }
    }
    // ID3 first: Flash has the tag before it has a decoder.
    if (try id3Object(vm, bytes)) |tag| {
        try vm.objects.putWithAttrs(obj, S("id3"), .{ .object = tag }, .{ .dont_enum = true }, false);
        try l.callMethod(vm, obj, S("onID3"), &.{});
    }
    try l.callMethod(vm, obj, S("onLoad"), &.{.{ .boolean = true }});
}

/// An MP3's length, by walking its frame headers. Only the fields the
/// duration needs are decoded — bitrate and sample rate per frame, since
/// a VBR file changes both.
fn mp3DurationMs(bytes: []const u8) ?f64 {
    const BITRATES_V1_L3 = [_]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    const BITRATES_V2_L3 = [_]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
    const RATES_V1 = [_]u32{ 44100, 48000, 32000, 0 };
    const RATES_V2 = [_]u32{ 22050, 24000, 16000, 0 };
    const RATES_V25 = [_]u32{ 11025, 12000, 8000, 0 };

    var i: usize = skipId3(bytes);
    var samples: f64 = 0;
    var rate: u32 = 0;
    var frames: u32 = 0;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF or (bytes[i + 1] & 0xE0) != 0xE0) {
            i += 1;
            continue;
        }
        const ver_bits = (bytes[i + 1] >> 3) & 0b11;
        const layer_bits = (bytes[i + 1] >> 1) & 0b11;
        if (ver_bits == 1 or layer_bits == 0) {
            i += 1;
            continue;
        }
        const bitrate_idx = (bytes[i + 2] >> 4) & 0xF;
        const rate_idx = (bytes[i + 2] >> 2) & 0b11;
        const is_v1 = ver_bits == 3;
        const bitrate = 1000 * (if (is_v1) BITRATES_V1_L3[bitrate_idx] else BITRATES_V2_L3[bitrate_idx]);
        rate = switch (ver_bits) {
            3 => RATES_V1[rate_idx],
            2 => RATES_V2[rate_idx],
            else => RATES_V25[rate_idx],
        };
        if (bitrate == 0 or rate == 0) {
            i += 1;
            continue;
        }
        const per_frame: u32 = if (is_v1) 1152 else 576;
        const padding: u32 = (bytes[i + 2] >> 1) & 1;
        const len = per_frame / 8 * bitrate / rate + padding;
        if (len == 0) break;
        samples += @floatFromInt(per_frame);
        frames += 1;
        i += len;
    }
    if (frames == 0 or rate == 0) return null;
    return @round(samples * 1000.0 / @as(f64, @floatFromInt(rate)));
}

fn skipId3(bytes: []const u8) usize {
    if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return 0;
    // A syncsafe 28-bit size, seven bits per byte.
    const size: usize = (@as(usize, bytes[6] & 0x7F) << 21) |
        (@as(usize, bytes[7] & 0x7F) << 14) |
        (@as(usize, bytes[8] & 0x7F) << 7) |
        @as(usize, bytes[9] & 0x7F);
    return @min(10 + size, bytes.len);
}

/// The ID3v2 text frames, under the names Flash exposes them by. Only the
/// text frames matter — Flash's `id3` object is a flat bag of strings.
fn id3Object(vm: *Vm, bytes: []const u8) !?ObjectHandle {
    if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return null;
    const version = bytes[3];
    const end = skipId3(bytes);
    const out = try vm.objects.create();
    vm.objects.get(out).proto = .{ .object = vm.object_proto };
    // v2.2 uses three-character frame ids and three-byte sizes; v2.3+
    // uses four of each.
    const id_len: usize = if (version <= 2) 3 else 4;
    const header: usize = if (version <= 2) 6 else 10;
    var i: usize = 10;
    while (i + header <= end) {
        const id = bytes[i .. i + id_len];
        if (id[0] == 0) break;
        var size: usize = 0;
        for (bytes[i + id_len ..][0 .. header - id_len - (if (version <= 2) @as(usize, 0) else 2)]) |b| {
            size = (size << 8) | b;
        }
        i += header;
        if (size == 0 or i + size > end) break;
        var text = bytes[i .. i + size];
        i += size;
        // The first byte is the text encoding; 0 is Latin-1 and 1 is
        // UTF-16 with a BOM. Anything else we read as Latin-1 too.
        if (text.len == 0) continue;
        const enc = text[0];
        text = text[1..];
        while (text.len > 0 and text[text.len - 1] == 0) text = text[0 .. text.len - 1];
        const s = if (enc == 1) try utf16Bom(vm, text) else try strings.fromSwf(vm.arena(), text, 5);
        if (id3Name(id)) |name| {
            try vm.objects.put(out, name, .{ .string = s }, false);
        }
    }
    return out;
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

/// Flash's own names for the ID3 frames it surfaces. The raw four-letter
/// ids are exposed as well, which is why both go on the object.
fn id3Name(id: []const u8) ?AvmString {
    const table = .{
        .{ "TALB", "album" },   .{ "TCOM", "comment" }, .{ "TCON", "genre" },
        .{ "TIT2", "songname" }, .{ "TPE1", "artist" },  .{ "TRCK", "track" },
        .{ "TYER", "year" },    .{ "TAL", "album" },    .{ "TCM", "comment" },
        .{ "TCO", "genre" },    .{ "TT2", "songname" }, .{ "TP1", "artist" },
        .{ "TRK", "track" },    .{ "TYE", "year" },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, id, e[0])) return S(e[1]);
    }
    return null;
}
