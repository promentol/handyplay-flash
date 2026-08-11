//! MP3, through the vendored minimp3 (`vendor/minimp3`, CC0) behind the
//! flat C shim in `mp3_impl.c`. The one dependency this project takes
//! (docs/DECISIONS.md), and the format that matters: of the 245 embedded
//! sounds across `games/`, every one is MP3.
//!
//! Two ways in, because SWF has two:
//!
//!   * `decodeAll` — a DefineSound is a whole clip sitting in the movie
//!     buffer, and the mixer wants plain PCM to resample from.
//!   * `Streamer` — SoundStreamBlocks arrive ONE FRAME AT A TIME and the
//!     bit reservoir carries across them, so the decoder state has to
//!     live between calls and leftover bytes have to be kept.
//!
//! `durationMs` decodes nothing: it walks the frame headers. That is on
//! purpose — it is what `Sound.getDuration()` has always answered and it
//! matches ruffle's numbers exactly (corpus
//! sound_duration_position_props expects 1045 for its noise.mp3), so it
//! must not start coming from a decoded sample count instead.

const std = @import("std");

/// Whether the C is compiled in (`-Dmp3`, default true). With it off,
/// every MP3 decodes to nothing and the player is silent where it would
/// have played — durations and completion timing are unaffected, since
/// those come from the header walk and the mixer's own clock.
pub const enabled: bool = @import("build_options").mp3_enabled;

extern fn hf_mp3_decode(
    buf: [*]const u8,
    len: usize,
    out_pcm: *?[*]i16,
    out_samples: *usize,
    out_channels: *c_int,
    out_hz: *c_int,
) c_int;
extern fn hf_mp3_free(pcm: ?[*]i16) void;
extern fn hf_mp3_state_size() usize;
extern fn hf_mp3_state_init(state: *anyopaque) void;
extern fn hf_mp3_decode_frame(
    state: *anyopaque,
    buf: [*]const u8,
    len: usize,
    pcm: [*]i16,
    out_samples: *c_int,
    out_channels: *c_int,
    out_hz: *c_int,
) c_int;

/// Interleaved signed 16-bit PCM, owned by the caller's allocator.
pub const Pcm = struct {
    samples: []i16,
    channels: u8,
    rate: u32,

    pub fn deinit(self: Pcm, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
    }

    /// Frames, not samples — a stereo clip has half as many.
    pub fn frames(self: Pcm) usize {
        return self.samples.len / @max(1, self.channels);
    }
};

/// Decode a whole clip. Null when the C is compiled out or the bytes are
/// not MP3 at all, which a movie is perfectly entitled to contain.
pub fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) ?Pcm {
    if (comptime !enabled) return null;
    if (bytes.len == 0) return null;
    var pcm: ?[*]i16 = null;
    var count: usize = 0;
    var channels: c_int = 0;
    var hz: c_int = 0;
    if (hf_mp3_decode(bytes.ptr, bytes.len, &pcm, &count, &channels, &hz) != 0) return null;
    const raw = pcm orelse return null;
    defer hf_mp3_free(raw);
    if (count == 0 or channels < 1 or hz < 1) return null;
    // Copied out of malloc: one owner for every buffer the mixer holds.
    const owned = gpa.dupe(i16, raw[0..count]) catch return null;
    return .{
        .samples = owned,
        .channels = @intCast(@min(channels, 2)),
        .rate = @intCast(hz),
    };
}

/// A decoder that survives between blocks. `feed` takes the next
/// SoundStreamBlock and appends whatever whole frames it yields.
pub const Streamer = struct {
    state: []u8 = &.{},
    /// Bytes from the last block that did not make a whole frame.
    tail: std.ArrayList(u8) = .empty,
    channels: u8 = 2,
    rate: u32 = 44100,

    pub fn init(gpa: std.mem.Allocator) ?Streamer {
        if (comptime !enabled) return null;
        const state = gpa.alignedAlloc(u8, .of(u64), hf_mp3_state_size()) catch return null;
        hf_mp3_state_init(@ptrCast(state.ptr));
        return .{ .state = state };
    }

    pub fn deinit(self: *Streamer, gpa: std.mem.Allocator) void {
        if (self.state.len != 0) gpa.free(self.state);
        self.tail.deinit(gpa);
        self.* = .{};
    }

    /// Decode `block`, appending interleaved samples to `out`.
    pub fn feed(
        self: *Streamer,
        gpa: std.mem.Allocator,
        block: []const u8,
        out: *std.ArrayList(i16),
    ) !void {
        if (comptime !enabled) return;
        if (self.state.len == 0) return;
        // Whatever was left over goes in front of the new bytes; the two
        // together are what a frame may straddle.
        try self.tail.appendSlice(gpa, block);
        var buf: [1152 * 2]i16 = undefined;
        var at: usize = 0;
        while (at < self.tail.items.len) {
            var samples: c_int = 0;
            var channels: c_int = 0;
            var hz: c_int = 0;
            const used = hf_mp3_decode_frame(
                @ptrCast(self.state.ptr),
                self.tail.items[at..].ptr,
                self.tail.items.len - at,
                &buf,
                &samples,
                &channels,
                &hz,
            );
            if (used <= 0) break; // needs more bytes
            at += @intCast(used);
            if (samples <= 0) continue; // a header or skipped junk
            if (channels > 0) self.channels = @intCast(@min(channels, 2));
            if (hz > 0) self.rate = @intCast(hz);
            const n: usize = @intCast(samples * @min(channels, 2));
            try out.appendSlice(gpa, buf[0..n]);
        }
        // Keep the remainder for the next block.
        if (at > 0) {
            const left = self.tail.items.len - at;
            std.mem.copyForwards(u8, self.tail.items[0..left], self.tail.items[at..]);
            self.tail.shrinkRetainingCapacity(left);
        }
    }
};

/// An MP3's length, by walking its frame headers. Only the fields the
/// duration needs are decoded — bitrate and sample rate per frame, since
/// a VBR file changes both.
pub fn durationMs(bytes: []const u8) ?f64 {
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

pub fn skipId3(bytes: []const u8) usize {
    if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return 0;
    // A syncsafe 28-bit size, seven bits per byte.
    const size: usize = (@as(usize, bytes[6] & 0x7F) << 21) |
        (@as(usize, bytes[7] & 0x7F) << 14) |
        (@as(usize, bytes[8] & 0x7F) << 7) |
        @as(usize, bytes[9] & 0x7F);
    return @min(10 + size, bytes.len);
}

test "an ID3 header is stepped over, not decoded" {
    var buf: [32]u8 = @splat(0);
    @memcpy(buf[0..3], "ID3");
    buf[9] = 10; // a ten-byte tag body
    try std.testing.expectEqual(@as(usize, 20), skipId3(&buf));
    try std.testing.expectEqual(@as(usize, 0), skipId3("no tag here"));
}

test "a file with no frame headers has no duration" {
    try std.testing.expect(durationMs("not an mp3 at all") == null);
}
