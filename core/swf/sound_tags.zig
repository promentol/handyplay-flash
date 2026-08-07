//! Sound tags — parse now (M1), play in M6. Sample data stays as raw
//! slices into the movie buffer; decoding is core/codecs/'s job.
//!
//! Layout: reference/ruffle/swf/src/read.rs read_define_sound /
//! read_sound_format / read_sound_info + SWF19.

const std = @import("std");
const rdr = @import("reader.zig");

pub const Error = rdr.Error || std.mem.Allocator.Error;

pub const AudioCompression = enum(u4) {
    uncompressed_unknown_endian = 0,
    adpcm = 1,
    mp3 = 2,
    uncompressed = 3,
    nellymoser_16khz = 4,
    nellymoser_8khz = 5,
    nellymoser = 6,
    speex = 11,
    _,
};

pub const SoundFormat = struct {
    compression: AudioCompression,
    /// 5512, 11025, 22050 or 44100 Hz.
    sample_rate: u16,
    is_16_bit: bool,
    is_stereo: bool,
};

fn parseFormat(r: *rdr.Reader) Error!SoundFormat {
    const b = try r.readU8();
    const rates = [4]u16{ 5512, 11025, 22050, 44100 };
    return .{
        .compression = @enumFromInt(@as(u4, @intCast(b >> 4))),
        .sample_rate = rates[(b >> 2) & 0b11],
        .is_16_bit = (b & 0b10) != 0,
        .is_stereo = (b & 0b01) != 0,
    };
}

/// DefineSound (14).
pub const Sound = struct {
    id: u16,
    format: SoundFormat,
    num_samples: u32,
    data: []const u8,
};

pub fn parseSound(body: []const u8) Error!Sound {
    var r = rdr.Reader.init(body);
    return .{
        .id = try r.readU16(),
        .format = try parseFormat(&r),
        .num_samples = try r.readU32(),
        .data = r.readRest(),
    };
}

/// SoundStreamHead (18) / SoundStreamHead2 (45).
pub const StreamHead = struct {
    /// Advisory playback format (ignored by players).
    playback: SoundFormat,
    /// The actual stream encoding.
    stream: SoundFormat,
    /// Average samples per SoundStreamBlock (per frame).
    samples_per_block: u16,
    /// MP3 only: initial seek/latency in samples.
    latency_seek: i16 = 0,
};

pub fn parseStreamHead(body: []const u8) Error!StreamHead {
    var r = rdr.Reader.init(body);
    const playback = try parseFormat(&r);
    const stream = try parseFormat(&r);
    var h: StreamHead = .{
        .playback = playback,
        .stream = stream,
        .samples_per_block = try r.readU16(),
    };
    if (stream.compression == .mp3 and r.remaining() >= 2) {
        h.latency_seek = try r.readI16();
    }
    return h;
}

/// SOUNDINFO — shared by StartSound (15) and PlaceObject2 clip events.
pub const SoundEnvelopePoint = struct {
    /// Position in 44.1kHz samples.
    sample: u32,
    left: u16,
    right: u16,
};

pub const SoundInfo = struct {
    /// Stop this sound instead of starting it.
    sync_stop: bool,
    /// Don't start if already playing.
    sync_no_multiple: bool,
    in_sample: ?u32 = null,
    out_sample: ?u32 = null,
    num_loops: u16 = 1,
    envelope: []SoundEnvelopePoint = &.{},
};

pub fn parseSoundInfo(allocator: std.mem.Allocator, r: *rdr.Reader) Error!SoundInfo {
    const flags = try r.readU8();
    var info: SoundInfo = .{
        .sync_stop = (flags & 0b100000) != 0,
        .sync_no_multiple = (flags & 0b010000) != 0,
    };
    if ((flags & 0b0001) != 0) info.in_sample = try r.readU32();
    if ((flags & 0b0010) != 0) info.out_sample = try r.readU32();
    if ((flags & 0b0100) != 0) info.num_loops = try r.readU16();
    if ((flags & 0b1000) != 0) {
        const n = try r.readU8();
        const env = try allocator.alloc(SoundEnvelopePoint, n);
        for (env) |*p| {
            p.* = .{
                .sample = try r.readU32(),
                .left = try r.readU16(),
                .right = try r.readU16(),
            };
        }
        info.envelope = env;
    }
    return info;
}

/// StartSound (15).
pub const StartSound = struct { id: u16, info: SoundInfo };

pub fn parseStartSound(allocator: std.mem.Allocator, body: []const u8) Error!StartSound {
    var r = rdr.Reader.init(body);
    const id = try r.readU16();
    return .{ .id = id, .info = try parseSoundInfo(allocator, &r) };
}

// --- Tests -----------------------------------------------------------------

test "DefineSound format byte and StartSound with loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // format 0b0010_11_1_1: mp3, 44100, 16-bit, stereo.
    const body = [_]u8{ 3, 0, 0b0010_1111, 0x10, 0x27, 0, 0, 0xFF, 0xFB };
    const s = try parseSound(&body);
    try std.testing.expectEqual(AudioCompression.mp3, s.format.compression);
    try std.testing.expectEqual(@as(u16, 44100), s.format.sample_rate);
    try std.testing.expect(s.format.is_16_bit and s.format.is_stereo);
    try std.testing.expectEqual(@as(u32, 10000), s.num_samples);
    try std.testing.expectEqual(@as(usize, 2), s.data.len);

    // StartSound: id 3, has_loops, 4 loops.
    const ss_body = [_]u8{ 3, 0, 0b0100, 4, 0 };
    const ss = try parseStartSound(a, &ss_body);
    try std.testing.expectEqual(@as(u16, 4), ss.info.num_loops);
    try std.testing.expect(!ss.info.sync_stop);
}

test "SoundStreamHead with mp3 latency" {
    // playback: uncompressed 22050 16 mono; stream: mp3 22050 16 stereo;
    // 1152 samples/block; latency 26.
    const body = [_]u8{ 0b0011_10_1_0, 0b0010_10_1_1, 0x80, 0x04, 26, 0 };
    const h = try parseStreamHead(&body);
    try std.testing.expectEqual(AudioCompression.mp3, h.stream.compression);
    try std.testing.expectEqual(@as(u16, 22050), h.stream.sample_rate);
    try std.testing.expectEqual(@as(u16, 1152), h.samples_per_block);
    try std.testing.expectEqual(@as(i16, 26), h.latency_seek);
}
