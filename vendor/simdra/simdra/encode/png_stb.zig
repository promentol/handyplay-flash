//! encode/png_stb.zig — PNG encoder backed by stb_image_write.
//!
//! Produces real-DEFLATE PNGs (typically 3–10× smaller than the
//! stored-block output of `encode/png.zig`). Selected via the comptime
//! switch in `encode/encoder.zig`.
//!
//! stb writes through a callback-style "write to function" entry point,
//! so we capture into an `SmList(u8)` allocated from the caller and hand
//! the trimmed slice back. Non-allocating callers should not call this
//! directly — go through `encode/encoder.zig`'s `encodePng`.

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

    const stride: c_int = @intCast(@as(usize, width) * 4);
    const ok = c.stbi_write_png_to_func(
        writeCallback,
        @ptrCast(&capture),
        @intCast(width),
        @intCast(height),
        4,
        rgba.ptr,
        stride,
    );

    if (capture.err) |e| return e;
    if (ok == 0) return error.EncodeFailed;

    return shrinkToFit(allocator, &capture.list);
}

// stb's PNG compression level lives on a process-wide global
// (`stbi_write_png_compression_level`, default 8). To expose a per-call
// option to JS we serialize concurrent encodes on a Zig-side mutex, swap
// the global, encode, then restore. With the WASM target single-threaded
// today this is effectively a no-op; the mutex is here for the native
// path (`npm test`) where node-zigar's WorkQueue can call us from
// pthreads, and for any future SharedArrayBuffer-backed multi-thread WASM.
//
// We go through tiny C accessors in `utils/stb_image.c` (`simdra_*`)
// rather than `c.stbi_write_png_compression_level = ...` directly. Zig's
// `@cImport` translates the extern variable declaration, but writes
// through the resulting Zig binding don't always reach the underlying C
// symbol on the WASM target. Calling a function in the same TU as the
// variable definition sidesteps the issue.
extern fn simdra_get_png_compression_level() c_int;
extern fn simdra_set_png_compression_level(level: c_int) void;

var png_level_mutex: std.Thread.Mutex = .{};

pub fn encodeWithLevel(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
    level: u8,
) EncodeError![]u8 {
    png_level_mutex.lock();
    defer png_level_mutex.unlock();

    const prev = simdra_get_png_compression_level();
    simdra_set_png_compression_level(@intCast(level));
    defer simdra_set_png_compression_level(prev);

    return encode(allocator, rgba, width, height);
}

fn shrinkToFit(allocator: std.mem.Allocator, list: *SmList(u8)) ![]u8 {
    if (list.cap == list.len) {
        const out = list.ptr[0..list.len];
        list.cap = 0;
        list.len = 0;
        return out;
    }
    const shrunk = try allocator.realloc(list.ptr[0..list.cap], list.len);
    list.cap = 0;
    list.len = 0;
    return shrunk;
}
