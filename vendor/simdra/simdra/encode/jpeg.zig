//! encode/jpeg.zig — JPEG encoder backed by stb_image_write.
//!
//! `quality` is stb's 1–100 scale (mapped from HTML5's 0.0–1.0 in the JS
//! layer; Zig stays HTML5-free). Same callback-capture pattern as
//! `encode/png_stb.zig` — see comments there.

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
    quality: u8,
) EncodeError![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * @as(usize, height) * 4);
    const q: c_int = @intCast(@max(@as(u8, 1), @min(@as(u8, 100), quality)));

    var capture: Capture = .{ .allocator = allocator };
    errdefer capture.list.deinit(allocator);

    const ok = c.stbi_write_jpg_to_func(
        writeCallback,
        @ptrCast(&capture),
        @intCast(width),
        @intCast(height),
        4,
        rgba.ptr,
        q,
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
