//! `NetStream` — playing an FLV, as far as a SCRIPT can tell.
//!
//! Nothing is decoded here. What a movie observes of a stream is its
//! STATUS: `play` starts one, the buffer fills, script tags reach the
//! object as method calls (`onMetaData`), the playhead runs out and the
//! stream stops. Those events, in that order, are the whole of what the
//! corpus records, and they need framing and a clock — not a codec.
//!
//! The clock is ruffle's (core/src/streams.rs `NetStream::tick`): every
//! tick advances `stream_time` by the elapsed milliseconds and consumes
//! every tag whose timestamp has passed. Running out of tags with the
//! download already finished is the END: Buffer.Flush, then Play.Stop,
//! then Buffer.Empty, and the stream pauses itself.
//!
//! A seek is QUEUED, never immediate: `seek()` only records the offset
//! and the next tick executes it, which is why `Seek.Notify` lands after
//! whatever else the frame that asked for it traced.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const decl = @import("decl.zig");
const flv = @import("../../flv.zig");
const screen_video = @import("../../codecs/screen_video.zig");
const bitmap_data = @import("../../bitmap/data.zig");
const pixels = @import("../../bitmap/pixels.zig");
const amf = @import("../amf.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;
const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;

/// One stream's playback state, owned by the VM arena and reached from
/// its script object's native slot.
pub const Stream = struct {
    obj: ObjectHandle,
    /// The FLV bytes as they have arrived.
    buffer: []const u8 = &.{},
    /// A download is still expected. Ruffle keeps this as
    /// `expected_length`, and it is what tells the end of the video from
    /// a stall: running dry while it is true is a BUFFER problem, while
    /// it is false is the end.
    downloading: bool = false,
    playing: bool = false,
    /// Parse cursor into `buffer` — the back pointer of the next tag.
    offset: usize = 0,
    header_read: bool = false,
    /// Milliseconds of stream consumed.
    stream_time: f64 = 0,
    queued_seek: ?f64 = null,
    /// `bufferTime`, in seconds. Flash's default is a tenth of a second.
    buffer_time: f64 = 0.1,
    /// The most recent decoded video frame, as a pixel buffer the
    /// renderer can blit. Owned with the player's gpa and replaced on
    /// every frame that decodes.
    frame: ?*bitmap_data.BitmapData = null,
    /// The raw frame behind it, kept because an inter-frame is a DELTA
    /// against the previous one.
    raw: ?screen_video.Frame = null,
};

/// The stream a value names, as an opaque pointer for the display list.
pub fn streamPtrOf(vm: *Vm, v: Value) ?*anyopaque {
    const s = streamOf(vm, v) orelse return null;
    return @ptrCast(s);
}

/// The frame a video display object should be showing, or null.
pub fn frameOf(source: *anyopaque) ?*const bitmap_data.BitmapData {
    const s: *Stream = @ptrCast(@alignCast(source));
    return s.frame;
}

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    inline for (.{
        .{ "play", play },
        .{ "pause", pause },
        .{ "seek", seek },
        .{ "close", close },
    }) |pair| {
        try method(vm, proto, pair[0], pair[1], hidden);
    }
    // The rest of the surface exists and answers undefined — publishing,
    // peer connections and the audio/video attachments are each their
    // own workstream.
    inline for (.{
        "publish",     "receiveAudio",    "receiveVideo", "onPeerConnect",
        "attachAudio", "attachVideo",     "send",         "setBufferTime",
        "getInfo",     "checkPolicyFile",
    }) |name| {
        try method(vm, proto, name, noop, hidden);
    }
    // The properties a player component polls to decide whether it has
    // anything to show (ruffle avm1/globals/netstream.rs).
    try decl.property(vm, proto, "bytesLoaded", getBytesLoaded, null, .{});
    try decl.property(vm, proto, "bytesTotal", getBytesTotal, null, .{});
    try decl.property(vm, proto, "time", getTime, null, .{});
    try decl.property(vm, proto, "bufferLength", getBufferLength, null, .{});
    try decl.property(vm, proto, "bufferTime", getBufferTime, setBufferTime, .{});
    _ = try decl.class(vm, "NetStream", ctor, proto, .{ .dont_enum = true });
}

fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const s = try vm.arena().create(Stream);
    s.* = .{ .obj = this.object };
    vm.objects.get(this.object).native = .{ .net_stream = @ptrCast(s) };
    try vm.net_streams.append(vm.gpa, s);
    return .undefined_value;
}

fn getBytesLoaded(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const s = streamOf(vmOf(p), this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(s.buffer.len) };
}

/// The total is what the DOWNLOAD promised. Until it finishes there is
/// nothing better than what has arrived, which is also what ruffle
/// reports for a stream with no declared length.
fn getBytesTotal(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const s = streamOf(vmOf(p), this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(s.buffer.len) };
}

/// Seconds, not milliseconds — the only place the stream clock is
/// exposed in the units a script expects.
fn getTime(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const s = streamOf(vmOf(p), this) orelse return .undefined_value;
    return .{ .number = s.stream_time / 1000.0 };
}

fn getBufferLength(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const s = streamOf(vmOf(p), this) orelse return .undefined_value;
    return .{ .number = s.buffer_time };
}

fn getBufferTime(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const s = streamOf(vmOf(p), this) orelse return .undefined_value;
    return .{ .number = s.buffer_time };
}

fn setBufferTime(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = streamOf(vm, this) orelse return .undefined_value;
    s.buffer_time = try vm.toNumber(arg(args, 0));
    return .undefined_value;
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn streamOf(vm: *Vm, v: Value) ?*Stream {
    if (v != .object) return null;
    return switch (vm.objects.get(v.object).native) {
        .net_stream => |ptr| @ptrCast(@alignCast(ptr)),
        else => null,
    };
}

// --- the script surface ----------------------------------------------------

/// `play(name)` starts a download and playback at once. Play.Start fires
/// straight away — before a single byte has arrived.
fn play(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = streamOf(vm, this) orelse return .undefined_value;
    const first = arg(args, 0);
    if (first != .undefined_value and first != .null_value) {
        const url = try strings.toUtf8(vm.arena(), try vm.toStringValue(first));
        s.buffer = &.{};
        s.offset = 0;
        s.header_read = false;
        s.stream_time = 0;
        s.downloading = true;
        @import("loader.zig").spawn(vm, .{
            .url = url,
            .target = .{ .net_stream = s.obj },
        });
    }
    s.playing = true;
    try status(vm, s, "NetStream.Play.Start");
    return .undefined_value;
}

/// `pause()` with no argument TOGGLES; with one, its truthiness decides.
/// Only the explicit pause announces itself.
fn pause(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = streamOf(vm, this) orelse return .undefined_value;
    if (args.len == 0 or args[0] == .undefined_value) {
        s.playing = !s.playing;
        return .undefined_value;
    }
    if (value_mod.toBoolean(args[0], vm.swf_version)) {
        s.playing = false;
        try statusWith(vm, s, "NetStream.Pause.Notify", "Pausing");
    } else {
        s.playing = true;
    }
    return .undefined_value;
}

/// Seconds in, milliseconds inside. The seek itself happens on the next
/// tick — this only remembers it.
fn seek(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = streamOf(vm, this) orelse return .undefined_value;
    s.queued_seek = try vm.toNumber(arg(args, 0)) * 1000.0;
    return .undefined_value;
}

fn close(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const s = streamOf(vm, this) orelse return .undefined_value;
    s.playing = false;
    s.buffer = &.{};
    s.offset = 0;
    s.header_read = false;
    s.downloading = false;
    return .undefined_value;
}

// --- the player's side -----------------------------------------------------

/// The download finished. Ruffle fires Buffer.Full the moment data
/// lands, whatever the buffer time says.
pub fn completeLoad(vm: *Vm, obj: ObjectHandle, data: ?[]const u8) !void {
    const s = streamOf(vm, .{ .object = obj }) orelse return;
    s.downloading = false;
    const body = data orelse return;
    s.buffer = body;
    try status(vm, s, "NetStream.Buffer.Full");
}

/// One tick of every live stream, `dt` milliseconds long.
pub fn tickAll(vm: *Vm, dt_ms: f64) !void {
    // By index: a handler can start another stream mid-walk.
    var i: usize = 0;
    while (i < vm.net_streams.items.len) : (i += 1) {
        try tickOne(vm, vm.net_streams.items[i], dt_ms);
    }
}

fn tickOne(vm: *Vm, s: *Stream, dt_ms: f64) !void {
    if (s.queued_seek) |offset| {
        s.queued_seek = null;
        try executeSeek(vm, s, offset);
    }
    if (!s.playing) return;
    if (!s.header_read) {
        const header = flv.parseHeader(s.buffer) orelse return;
        s.offset = header.data_offset;
        s.header_read = true;
    }
    const max_time = s.stream_time + dt_ms;
    var underrun = false;
    while (true) {
        const tag = flv.parseTag(s.buffer, s.offset) orelse {
            underrun = true;
            break;
        };
        // A tag whose time has not come yet ends the pass, and does NOT
        // count as running dry.
        if (@as(f64, @floatFromInt(tag.timestamp)) >= max_time) break;
        s.offset = tag.end;
        switch (tag.kind) {
            .script => try dispatchScript(vm, s, tag.data),
            .video => decodeVideo(vm, s, tag.data),
            else => {},
        }
    }
    s.stream_time = max_time;
    if (!underrun) return;
    // Out of tags. Whether that is the end of the video or a stall is
    // the download's business, not the buffer's.
    const end_of_video = !s.downloading;
    try status(vm, s, "NetStream.Buffer.Flush");
    if (end_of_video) try status(vm, s, "NetStream.Play.Stop");
    try status(vm, s, "NetStream.Buffer.Empty");
    if (end_of_video) s.playing = false;
}

/// A seek announces itself even when it changes nothing, and then snaps
/// the playhead to the first tag at or after the new time.
fn executeSeek(vm: *Vm, s: *Stream, offset: f64) !void {
    try status(vm, s, "NetStream.Seek.Notify");
    if (s.stream_time == offset) return;
    const header = flv.parseHeader(s.buffer) orelse return;
    s.header_read = true;
    s.stream_time = offset;
    s.offset = header.data_offset;
    while (flv.parseTag(s.buffer, s.offset)) |tag| {
        if (@as(f64, @floatFromInt(tag.timestamp)) >= offset) break;
        s.offset = tag.end;
    }
}

/// A script tag is an AMF0 name and an AMF0 value, and the name IS the
/// method: `onMetaData` in the file becomes `ns.onMetaData(value)`.
fn dispatchScript(vm: *Vm, s: *Stream, data: []const u8) !void {
    var reader: amf.Reader = .{ .vm = vm, .bytes = data };
    defer reader.deinit();
    const name = try reader.value();
    if (name != .string) return;
    const payload = try reader.value();
    const fn_value = vm.getProperty(s.obj, name.string, .{ .object = s.obj }) catch return;
    if (fn_value != .object) return;
    _ = vm.callFunction(fn_value, .{ .object = s.obj }, &.{payload}) catch {
        vm.pending_throw = .undefined_value;
    };
}

/// One video tag. The first byte is the frame type and the codec; only
/// SCREEN VIDEO (3) decodes today, and anything else leaves the last
/// frame standing rather than blanking the picture.
fn decodeVideo(vm: *Vm, s: *Stream, data: []const u8) void {
    if (data.len < 2) return;
    const codec = data[0] & 0x0F;
    if (codec != 3) return;
    const decoded = screen_video.decode(vm.gpa, data[1..], s.raw) catch return;
    if (s.raw) |*old| old.deinit(vm.gpa);
    s.raw = decoded;
    // The renderer wants premultiplied pixels; a decoded frame is opaque,
    // so the conversion is a repack.
    const bd = s.frame orelse blk: {
        const fresh = vm.gpa.create(bitmap_data.BitmapData) catch return;
        fresh.* = bitmap_data.BitmapData.init(vm.gpa, decoded.width, decoded.height, false, 0) catch {
            vm.gpa.destroy(fresh);
            return;
        };
        s.frame = fresh;
        break :blk fresh;
    };
    if (bd.width != decoded.width or bd.height != decoded.height) return;
    for (bd.data, 0..) |*px, i| {
        px.* = pixels.Color.rgba(
            decoded.rgba[i * 4 + 0],
            decoded.rgba[i * 4 + 1],
            decoded.rgba[i * 4 + 2],
            255,
        );
    }
}

// --- status events ---------------------------------------------------------

fn status(vm: *Vm, s: *Stream, code: []const u8) !void {
    // The ORDER matters: `for..in` walks own properties newest first, so
    // the pair ruffle inserts first is the one the script prints last
    // (ruffle `trigger_status_event` passes [code, level] and the corpus
    // records "level" then "code").
    try fireStatus(vm, s, &.{
        .{ "code", code },
        .{ "level", "status" },
    });
}

/// `onStatus` gets ONE argument: an object carrying `code` and `level`,
/// plus a `description` for the events that have one.
fn statusWith(vm: *Vm, s: *Stream, code: []const u8, description: []const u8) !void {
    try fireStatus(vm, s, &.{
        .{ "description", description },
        .{ "level", "status" },
        .{ "code", code },
    });
}

fn fireStatus(vm: *Vm, s: *Stream, pairs: []const [2][]const u8) !void {
    const handler = vm.getProperty(s.obj, S("onStatus"), .{ .object = s.obj }) catch return;
    const info = try vm.newObject();
    const a = vm.arena();
    for (pairs) |pair| {
        try vm.setProperty(
            info,
            try strings.fromSwf(a, pair[0], 8),
            .{ .string = try strings.fromSwf(a, pair[1], 8) },
            .{ .object = info },
        );
    }
    if (handler != .object) return;
    _ = vm.callFunction(handler, .{ .object = s.obj }, &.{.{ .object = info }}) catch {
        vm.pending_throw = .undefined_value;
    };
}
