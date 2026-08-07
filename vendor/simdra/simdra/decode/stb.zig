//! decode/stb.zig — image-bytes → SmBitmap via stb_image.
//!
//! Forces 4-channel RGBA output (`STBI_rgb_alpha`); auto-detects the input
//! format (PNG / JPEG / BMP / GIF first frame; HDR / PSD / PIC / PNM / TGA
//! were stripped at build time in `utils/stb_image.c`). Decoded bytes come
//! back from libc-malloc; we copy into the caller's allocator via
//! `SmBitmap.createFromBufferWithAllocator` and free the stb buffer
//! immediately, keeping SmBitmap's single-allocator ownership story.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

const c = @cImport({
    @cInclude("simdra/utils/stb_image.h");
});

pub const DecodeError = error{DecodeFailed} || SmBitmap.CtorError;
pub const InfoError = error{InfoFailed};

/// Header-only metadata read — no pixel decode. Wraps `stbi_info_from_memory`
/// + `stbi_is_16_bit_from_memory`, which are stb_image's public fast-path
/// APIs for inspecting image dimensions / channel count / bit depth without
/// allocating a full RGBA buffer. `channels` is the **source** channel count
/// (1 = grey, 2 = grey+alpha, 3 = RGB, 4 = RGBA), not our forced 4-channel
/// decode output.
pub const ImageInfo = struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
};

pub fn peekInfo(bytes: []const u8) InfoError!ImageInfo {
    if (bytes.len == 0) return error.InfoFailed;

    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    if (c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch) == 0) {
        return error.InfoFailed;
    }
    if (w <= 0 or h <= 0 or ch < 1 or ch > 4) return error.InfoFailed;

    const is16 = c.stbi_is_16_bit_from_memory(bytes.ptr, @intCast(bytes.len));
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = @intCast(ch),
        .bits_per_sample = if (is16 != 0) 16 else 8,
    };
}

pub fn decodeImage(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!SmBitmap {
    if (bytes.len == 0) return error.DecodeFailed;

    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const stb_buf = c.stbi_load_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &w,
        &h,
        &ch,
        4,
    );
    if (stb_buf == null) return error.DecodeFailed;
    defer c.stbi_image_free(stb_buf);
    if (w <= 0 or h <= 0) return error.DecodeFailed;

    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const total: usize = @as(usize, width) * @as(usize, height) * 4;

    const src_ptr: [*]const u8 = @ptrCast(stb_buf);
    return SmBitmap.createFromBufferWithAllocator(
        allocator,
        src_ptr[0..total],
        width,
        height,
        .{ .colorSpace = .srgb, .pixelFormat = .rgba_unorm8 },
    );
}
