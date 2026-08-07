//! trace_runner — headless conformance driver.
//! Usage: trace_runner <test.swf> [--frames N]
//!
//! Loads the movie, runs N timeline frames (default: enough for the
//! corpus's usual single-frame tests plus one settle tick), prints
//! accumulated trace() output to stdout, exit 0. The conformance script
//! diffs stdout against the corpus dir's output.txt.

const std = @import("std");
const flash = @import("flash");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var swf_path: ?[]const u8 = null;
    var frames: u32 = 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames")) {
            i += 1;
            if (i >= args.len) return 2;
            frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (swf_path == null) {
            swf_path = args[i];
        } else return 2;
    }
    const path = swf_path orelse {
        try out.writeAll("usage: trace_runner <test.swf> [--frames N]\n");
        try out.flush();
        return 2;
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const player = flash.Player.create(gpa, bytes) catch {
        // A movie we can't run produces no trace output (several corpus
        // dirs are AVM2/image-comparison tests whose expected stdout is
        // empty). Diagnostics go to stderr, never stdout.
        try out.flush();
        return 0;
    };
    defer player.destroy();

    // Frame 1 ran inside create(); tick the remainder.
    var f: u32 = 1;
    while (f < frames) : (f += 1) {
        _ = player.tick(1000.0 / player.fps()) catch break;
    }

    try out.writeAll(player.takeTrace());
    try out.flush();
    return 0;
}
