const std = @import("std");
const flash = @import("flash");
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var movie = try flash.swf.movie.load(gpa, bytes);
    defer movie.deinit();
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    var it = movie.lib.characters.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .text => |t| {
            try out.print("Text id={d} bounds=({d},{d},{d},{d}) m=[{d:.3} {d:.3} {d:.3} {d:.3} {d} {d}]\n", .{
                t.id, t.bounds.xmin, t.bounds.ymin, t.bounds.xmax, t.bounds.ymax,
                t.matrix.a, t.matrix.b, t.matrix.c, t.matrix.d, t.matrix.tx, t.matrix.ty,
            });
            for (t.records) |r| {
                try out.print("  rec font={?d} h={?d} color={?x} x={?d} y={?d} glyphs={d}\n", .{
                    r.font_id, r.height, r.color, r.x_offset, r.y_offset, r.glyphs.len,
                });
                if (r.glyphs.len > 0) try out.print("    first: idx={d} adv={d}\n", .{ r.glyphs[0].index, r.glyphs[0].advance });
            }
        },
        .font => |f| try out.print("Font id={d} v={d} glyphs={d} layout={} first_records={d}\n", .{
            f.id, f.version, f.glyphs.len, f.layout != null,
            if (f.glyphs.len > 0) f.glyphs[0].records.len else 0,
        }),
        else => {},
    };
    try out.flush();
    return 0;
}
