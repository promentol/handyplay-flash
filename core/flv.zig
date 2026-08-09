//! FLV — the container a `NetStream` plays.
//!
//! A nine-byte header, then a flat list of tags, each preceded by the
//! size of the one before it (a back pointer for reverse seeking, which
//! nothing here uses). A tag carries a type, a millisecond timestamp and
//! its payload: audio (8), video (9) or SCRIPT DATA (18).
//!
//! Only the framing is decoded. Audio and video payloads are handed on
//! as bytes for the decoders to worry about; the script payload is an
//! AMF0 name followed by an AMF0 value, which is how `onMetaData`
//! reaches the movie.
//!
//! Layout reference: reference/ruffle/flv/src/{header,tag}.rs.

const std = @import("std");

pub const Header = struct {
    version: u8,
    has_audio: bool,
    has_video: bool,
    /// Where the tag list starts. Usually 9, but the field is explicit
    /// so a file may reserve more.
    data_offset: u32,
};

pub const TagKind = enum(u8) { audio = 8, video = 9, script = 18, _ };

pub const Tag = struct {
    kind: TagKind,
    /// Milliseconds. The extended byte is the HIGH one, which is what
    /// lets a stream run past 4.6 hours.
    timestamp: u32,
    data: []const u8,
    /// Where the next tag's back pointer begins.
    end: usize,
};

pub fn parseHeader(bytes: []const u8) ?Header {
    if (bytes.len < 9) return null;
    if (!std.mem.eql(u8, bytes[0..3], "FLV")) return null;
    const flags = bytes[4];
    return .{
        .version = bytes[3],
        .has_audio = (flags & 0b100) != 0,
        .has_video = (flags & 0b001) != 0,
        .data_offset = std.mem.readInt(u32, bytes[5..9], .big),
    };
}

/// The tag at `pos`, which points at its four-byte back pointer. Null at
/// the end of the data — including a tag whose payload is not all here
/// yet, since a stream can be read while it downloads.
pub fn parseTag(bytes: []const u8, pos: usize) ?Tag {
    if (pos + 15 > bytes.len) return null;
    const p = pos + 4; // skip the previous tag's size
    const kind = bytes[p];
    const size = readU24(bytes[p + 1 ..]);
    const ts_low = readU24(bytes[p + 4 ..]);
    const ts_high: u32 = bytes[p + 7];
    const start = p + 11;
    const end = start + size;
    if (end > bytes.len) return null;
    return .{
        .kind = @enumFromInt(kind),
        .timestamp = (ts_high << 24) | ts_low,
        .data = bytes[start..end],
        .end = end,
    };
}

fn readU24(b: []const u8) u32 {
    return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
}

test "header and tag framing" {
    // FLV 1, video only, header 9 bytes; one script tag of 3 bytes at
    // timestamp 0x010203.
    const bytes = [_]u8{
        'F', 'L', 'V', 1, 0x01, 0, 0, 0, 9,
        0,   0,   0,   0, // previous tag size
        18, 0, 0, 3, 0x02, 0x03, 0x04, 0x01, 0, 0, 0,
        0xAA, 0xBB, 0xCC,
    };
    const h = parseHeader(&bytes).?;
    try std.testing.expectEqual(@as(u32, 9), h.data_offset);
    try std.testing.expect(h.has_video and !h.has_audio);
    const tag = parseTag(&bytes, h.data_offset).?;
    try std.testing.expectEqual(TagKind.script, tag.kind);
    try std.testing.expectEqual(@as(u32, 0x01020304), tag.timestamp);
    try std.testing.expectEqual(@as(usize, 3), tag.data.len);
    try std.testing.expect(parseTag(&bytes, tag.end) == null);
}
