//! Uncompressed SWF sound data — formats 0 and 3.
//!
//! The difference between them is only ENDIANNESS, and only for 16-bit:
//! format 3 is little-endian, format 0 is "the platform's", which in
//! practice means little-endian too (ruffle decodes both the same way,
//! `decoders.rs`). 8-bit samples are unsigned and biased by 128 in both.
//!
//! Worth having despite being trivial: 20 of the 36 games stream their
//! background music as uncompressed PCM, so this is the codec that plays
//! the most seconds of audio in the whole corpus.

const std = @import("std");

/// Interleaved signed 16-bit, which is what the mixer takes.
pub fn decode(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    is_16_bit: bool,
) std.mem.Allocator.Error![]i16 {
    if (is_16_bit) {
        const n = bytes.len / 2;
        const out = try gpa.alloc(i16, n);
        for (out, 0..) |*s, i| {
            s.* = std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little);
        }
        return out;
    }
    const out = try gpa.alloc(i16, bytes.len);
    for (out, bytes) |*s, b| {
        // 0..255 around a midpoint of 128, scaled to the 16-bit range.
        s.* = (@as(i16, b) - 128) * 256;
    }
    return out;
}

test "8-bit samples are unsigned around 128" {
    const out = try decode(std.testing.allocator, &.{ 128, 255, 0 }, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(i16, &.{ 0, 32512, -32768 }, out);
}

test "16-bit samples are little-endian" {
    const out = try decode(std.testing.allocator, &.{ 0x00, 0x80, 0xFF, 0x7F }, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(i16, &.{ -32768, 32767 }, out);
}
