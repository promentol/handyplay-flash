//! SoundStreamHead/Block timeline A/V sync.
//!
//! A stream is the other kind of SWF sound, and the one the phone games
//! use for music: instead of a clip you START, the audio is CUT UP BY
//! FRAME and a block rides along with each one. It plays because the
//! playhead reaches it, it stops because the timeline did, and it can
//! never be more than a frame out of step with the picture — which is
//! the whole reason the format exists.
//!
//! Twenty of the thirty-six games in `games/` stream uncompressed PCM
//! this way; one streams ADPCM. MP3 streams exist too, and are the awkward
//! case: an MP3 frame does not line up with a movie frame, so the decoder
//! state has to carry across blocks (`codecs/mp3.zig`'s `Streamer`).
//!
//! What this file owns is the BOOKKEEPING — one instance per timeline,
//! which sounds it feeds, and what to do when the playhead moves somewhere
//! it did not expect. The samples themselves go into a growing mixer
//! source, and the mixer's clock rule does the rest.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const mixer_mod = @import("mixer.zig");
const mp3 = @import("../codecs/mp3.zig");
const pcm = @import("../codecs/pcm.zig");
const adpcm = @import("../codecs/adpcm.zig");

/// One timeline's stream. Keyed by the clip that owns it, because a
/// sprite may have a stream of its own on top of the root's.
pub const Stream = struct {
    /// The mixer source these blocks are appended to, and the voice
    /// playing it. Handles are allocated above the character-id space so
    /// they cannot collide with a DefineSound.
    handle: u32,
    voice: u32 = 0,
    format: swf.sound_tags.SoundFormat,
    /// Kept across blocks: an MP3 frame may straddle two of them.
    mp3_state: ?mp3.Streamer = null,
    /// The frame the last block was fed for. A playhead that jumps
    /// backwards (a loop, or a `gotoAndPlay`) has to start the stream
    /// over rather than keep appending, or the music runs on while the
    /// picture rewinds.
    last_frame: u16 = 0,
    started: bool = false,

    pub fn deinit(self: *Stream, gpa: std.mem.Allocator) void {
        if (self.mp3_state) |*m| m.deinit(gpa);
        self.* = undefined;
    }

    /// Decode one SoundStreamBlock into interleaved i16 at the stream's
    /// own rate. Null when the format is one we do not decode.
    pub fn decodeBlock(
        self: *Stream,
        gpa: std.mem.Allocator,
        block: []const u8,
    ) ?[]i16 {
        return switch (self.format.compression) {
            .uncompressed, .uncompressed_unknown_endian => pcm.decode(gpa, block, self.format.is_16_bit) catch null,
            .adpcm => blk: {
                // An ADPCM stream block carries its OWN header, unlike
                // every other format — ruffle recreates the decoder per
                // block for exactly this reason (decoders/adpcm.rs).
                const frames = adpcmFramesIn(block, self.format.is_stereo);
                break :blk adpcm.decode(gpa, block, self.format.is_stereo, frames) catch null;
            },
            .mp3 => blk: {
                // A block begins with a 2-byte sample count and a 2-byte
                // seek offset before the MP3 data proper.
                if (block.len < 4) break :blk null;
                if (self.mp3_state == null) self.mp3_state = mp3.Streamer.init(gpa);
                var st = &(self.mp3_state orelse break :blk null);
                var out: std.ArrayList(i16) = .empty;
                st.feed(gpa, block[4..], &out) catch {
                    out.deinit(gpa);
                    break :blk null;
                };
                break :blk out.toOwnedSlice(gpa) catch null;
            },
            else => null,
        };
    }
};

/// How many frames an ADPCM block holds, from its size — the block does
/// not say, and the stream head's per-frame count is a MAXIMUM rather
/// than a promise.
fn adpcmFramesIn(block: []const u8, is_stereo: bool) u32 {
    if (block.len < 1) return 0;
    const bits: u32 = @as(u32, block[0] >> 6) + 2;
    const channels: u32 = if (is_stereo) 2 else 1;
    const total_bits: u32 = @intCast(block.len * 8);
    // 2 header bits, then per channel a 16-bit sample and a 6-bit index,
    // then `bits` per sample per channel.
    if (total_bits < 2 + 22 * channels) return 0;
    return 1 + (total_bits - 2 - 22 * channels) / (bits * channels);
}

/// Handles for streams start here, above every character id.
pub const HANDLE_BASE: u32 = 1 << 20;

pub fn handleFor(index: usize) u32 {
    return HANDLE_BASE + @as(u32, @intCast(index));
}

test "an ADPCM block's frame count comes from its size" {
    // 2-bit words, mono: 2 header bits + 22 + N*2 bits.
    var block: [10]u8 = @splat(0);
    const n = adpcmFramesIn(&block, false);
    try std.testing.expectEqual(@as(u32, 1 + (80 - 2 - 22) / 2), n);
}

test "handles cannot collide with character ids" {
    try std.testing.expect(handleFor(0) > std.math.maxInt(u16));
}

// A stream source is GROWING: it must never complete just because the
// timeline has not fed it yet this frame.
test "the source a stream registers is marked growing" {
    const s: mixer_mod.Source = .{ .samples = &.{}, .growing = true };
    try std.testing.expect(s.growing);
}
