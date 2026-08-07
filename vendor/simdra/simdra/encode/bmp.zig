//! encode/bmp.zig — BMP encoder backed by stb_image_write.
//!
//! Always passes `comp=4` to stb. stb's BMP encoder writes a 32-bit BMP
//! V4 header (BI_BITFIELDS, with explicit RGBA masks) for `comp=4` —
//! this preserves alpha and avoids a packed-3-byte repack of our RGBA
//! pixel buffer. Same callback-capture pattern as `encode/png_stb.zig`.

const std = @import("std");
const SmList = @import("../utils/SmList.zig").SmList;

const c = @cImport({
    @cInclude("simdra/utils/stb_image_write.h");
});

pub const EncodeError = error{EncodeFailed} || std.mem.Allocator.Error;

const Capture = struct {
    list: SmList(u8) = .{},
    allocator: std.mem.Allocator,
    err: ?std.mem.Allocator.Error = null,
};

fn writeCallback(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const cap: *Capture = @ptrCast(@alignCast(ctx orelse return));
    if (cap.err != null) return;
    const bytes_ptr: [*]const u8 = @ptrCast(data orelse return);
    const sz: usize = @intCast(size);
    cap.list.appendSlice(cap.allocator, bytes_ptr[0..sz]) catch |e| {
        cap.err = e;
    };
}

pub fn encode(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) EncodeError![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * @as(usize, height) * 4);

    var capture: Capture = .{ .allocator = allocator };
    errdefer capture.list.deinit(allocator);

    const ok = c.stbi_write_bmp_to_func(
        writeCallback,
        @ptrCast(&capture),
        @intCast(width),
        @intCast(height),
        4,
        rgba.ptr,
    );

    if (capture.err) |e| return e;
    if (ok == 0) return error.EncodeFailed;

    if (capture.list.cap == capture.list.len) {
        const out = capture.list.ptr[0..capture.list.len];
        capture.list.cap = 0;
        capture.list.len = 0;
        return out;
    }
    const shrunk = try allocator.realloc(
        capture.list.ptr[0..capture.list.cap],
        capture.list.len,
    );
    capture.list.cap = 0;
    capture.list.len = 0;
    return shrunk;
}
