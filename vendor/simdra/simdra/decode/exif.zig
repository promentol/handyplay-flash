//! decode/exif.zig — minimal EXIF Orientation reader.
//!
//! Backs sharp's `autoOrient()` and the no-args `rotate()` overload.
//! Scope is **only** TIFF tag 0x0112 (Orientation) on the IFD0 of the
//! EXIF block:
//!   * JPEG: scan APP1 markers for the `Exif\0\0` magic, then walk the
//!     attached TIFF directory.
//!   * PNG : look for an `eXIf` chunk, then walk the same TIFF
//!     directory format.
//!
//! Anything malformed / absent / unknown returns `1` (no rotation).
//! Bytes-only — no allocation, no stb dependency.
//!
//! Orientation values per the EXIF/TIFF spec (rev. 2.32, §A):
//!   1 = top-left              (no rotation)
//!   2 = top-right             (h-flip)
//!   3 = bottom-right          (180°)
//!   4 = bottom-left           (v-flip)
//!   5 = left-top              (transpose: 90° CCW + h-flip)
//!   6 = right-top             (90° CW)
//!   7 = right-bottom          (90° CW + h-flip)
//!   8 = left-bottom           (90° CCW)

const std = @import("std");

/// readOrientation(bytes) → 1..8. Returns 1 on any malformed input,
/// missing block, or unsupported container. Stable / safe to call on
/// arbitrary bytes — this is a header-only inspector with no
/// allocation.
pub fn readOrientation(bytes: []const u8) u8 {
    if (bytes.len < 8) return 1;
    // PNG: 89 50 4E 47 0D 0A 1A 0A.
    if (bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4e and bytes[3] == 0x47 and
        bytes[4] == 0x0d and bytes[5] == 0x0a and bytes[6] == 0x1a and bytes[7] == 0x0a)
    {
        return readPng(bytes);
    }
    // JPEG: starts with FF D8 FF.
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) {
        return readJpeg(bytes);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// JPEG APP1 / Exif scan
// ---------------------------------------------------------------------------

fn readJpeg(bytes: []const u8) u8 {
    // SOI consumed at sniff. Walk markers FF xx [len_hi len_lo payload...]
    // until we hit SOS (FF DA, no length-prefixed payload follows our
    // metadata window) or the buffer runs out.
    var i: usize = 2; // past SOI
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xff) return 1;
        // Skip fill bytes (FF FF).
        var marker = bytes[i + 1];
        var ms: usize = i + 2;
        while (marker == 0xff and ms < bytes.len) {
            marker = bytes[ms];
            ms += 1;
        }
        // Markers without length payloads: standalone (D0–D9, 01).
        if (marker == 0xd9 or marker == 0xda) return 1; // EOI / SOS — no more APPn metadata
        if (marker >= 0xd0 and marker <= 0xd7) {
            i = ms;
            continue;
        }
        if (marker == 0x01) {
            i = ms;
            continue;
        }
        // Length-prefixed segment.
        if (ms + 2 > bytes.len) return 1;
        const seg_len: usize = (@as(usize, bytes[ms]) << 8) | bytes[ms + 1];
        if (seg_len < 2) return 1;
        const payload_start = ms + 2;
        const payload_end = ms + seg_len;
        if (payload_end > bytes.len) return 1;
        if (marker == 0xe1 and payload_end - payload_start >= 6) {
            // APP1: check for `Exif\0\0` magic.
            const p = bytes[payload_start..payload_end];
            if (p.len >= 6 and p[0] == 'E' and p[1] == 'x' and p[2] == 'i' and
                p[3] == 'f' and p[4] == 0 and p[5] == 0)
            {
                return readTiff(p[6..]);
            }
        }
        i = payload_end;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// PNG eXIf chunk scan
// ---------------------------------------------------------------------------

fn readPng(bytes: []const u8) u8 {
    var i: usize = 8; // past PNG signature
    while (i + 12 <= bytes.len) {
        const len: usize =
            (@as(usize, bytes[i]) << 24) |
            (@as(usize, bytes[i + 1]) << 16) |
            (@as(usize, bytes[i + 2]) << 8) |
            @as(usize, bytes[i + 3]);
        if (i + 8 + len + 4 > bytes.len) return 1;
        const ctype = bytes[i + 4 .. i + 8];
        if (ctype[0] == 'e' and ctype[1] == 'X' and ctype[2] == 'I' and ctype[3] == 'f') {
            return readTiff(bytes[i + 8 .. i + 8 + len]);
        }
        if (ctype[0] == 'I' and ctype[1] == 'E' and ctype[2] == 'N' and ctype[3] == 'D') {
            return 1;
        }
        i += 8 + len + 4; // length + type + data + CRC32
    }
    return 1;
}

// ---------------------------------------------------------------------------
// TIFF IFD0 walk → Orientation tag (0x0112)
// ---------------------------------------------------------------------------
//
// TIFF header (8 bytes from `tiff` slice base):
//   bytes 0-1 : byte order — "II" (little endian) or "MM" (big endian)
//   bytes 2-3 : magic 0x002A
//   bytes 4-7 : offset to IFD0 (relative to TIFF base)
//
// Each IFD entry is 12 bytes:
//   bytes 0-1 : tag
//   bytes 2-3 : type (1=BYTE, 3=SHORT, 4=LONG, 7=UNDEFINED, ...)
//   bytes 4-7 : count
//   bytes 8-11: value (or offset to value if total size > 4 bytes)

fn readTiff(tiff: []const u8) u8 {
    if (tiff.len < 8) return 1;
    const le = tiff[0] == 'I' and tiff[1] == 'I';
    const be = tiff[0] == 'M' and tiff[1] == 'M';
    if (!le and !be) return 1;

    if (read16(tiff, 2, le) != 0x002a) return 1;
    const ifd_off: usize = read32(tiff, 4, le);
    if (ifd_off + 2 > tiff.len) return 1;

    const entry_count: usize = read16(tiff, ifd_off, le);
    const entries_start = ifd_off + 2;
    if (entries_start + entry_count * 12 > tiff.len) return 1;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = entries_start + i * 12;
        const tag = read16(tiff, e, le);
        if (tag == 0x0112) {
            const ftype = read16(tiff, e + 2, le);
            // Orientation is encoded as TIFF type 3 (SHORT) per the EXIF
            // spec, but defensively accept type 4 (LONG) and a single-byte
            // form too — saving from cameras gets messy.
            const value: u32 = switch (ftype) {
                3 => read16(tiff, e + 8, le),
                4 => read32(tiff, e + 8, le),
                1 => @as(u32, tiff[e + 8]),
                else => return 1,
            };
            if (value >= 1 and value <= 8) return @intCast(value);
            return 1;
        }
    }
    return 1;
}

inline fn read16(buf: []const u8, off: usize, le: bool) u32 {
    if (off + 2 > buf.len) return 0;
    return if (le)
        @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8)
    else
        (@as(u32, buf[off]) << 8) | @as(u32, buf[off + 1]);
}

inline fn read32(buf: []const u8, off: usize, le: bool) u32 {
    if (off + 4 > buf.len) return 0;
    return if (le)
        @as(u32, buf[off]) |
            (@as(u32, buf[off + 1]) << 8) |
            (@as(u32, buf[off + 2]) << 16) |
            (@as(u32, buf[off + 3]) << 24)
    else
        (@as(u32, buf[off]) << 24) |
            (@as(u32, buf[off + 1]) << 16) |
            (@as(u32, buf[off + 2]) << 8) |
            @as(u32, buf[off + 3]);
}
