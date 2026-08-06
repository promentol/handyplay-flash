//! swfinfo — print a SWF file's outer header and movie header.
//! Usage: swfinfo <file.swf> [more.swf ...]

const std = @import("std");
const swf = @import("swf");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try out.writeAll("usage: swfinfo <file.swf> [more.swf ...]\n");
        try out.flush();
        return error.MissingArgument;
    }

    var failures: usize = 0;
    for (args[1..]) |path| {
        printOne(gpa, io, out, path) catch |err| {
            try out.print("{s}: error: {t}\n", .{ path, err });
            failures += 1;
        };
    }
    try out.flush();
    if (failures != 0) return error.SwfInfoFailed;
}

fn printOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    path: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(bytes);

    var movie = try swf.decompress.decompress(gpa, bytes);
    defer movie.deinit(gpa);
    const h = try swf.header.parse(movie.body);

    try out.print("{s}\n", .{path});
    try out.print("  compression:    {s}\n", .{movie.compression.name()});
    try out.print("  swf version:    {d}\n", .{movie.version});
    try out.print("  file length:    {d} bytes declared ({d} on disk, {d} payload)\n", .{
        movie.declared_length, bytes.len, movie.body.len,
    });
    try out.print("  stage:          {d}x{d} px ({d}x{d} twips, origin {d},{d})\n", .{
        h.widthPx(),    h.heightPx(),
        h.widthTwips(), h.heightTwips(),
        h.xmin,         h.ymin,
    });
    try out.print("  frame rate:     {d:.2} fps\n", .{h.frame_rate});
    try out.print("  frame count:    {d}\n", .{h.frame_count});
}
