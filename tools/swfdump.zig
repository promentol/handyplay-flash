//! swfdump — structured tag dump with a stable, diffable text format.
//! Usage: swfdump <file.swf> [more.swf ...]
//!
//! Walks the raw tag stream (recursing into DefineSprite) and prints one
//! line per tag with decoded fields for in-scope tags. Per-tag decode
//! errors are reported inline and are NOT fatal (tolerance policy); only
//! container-level failures (not a SWF / LZMA) fail the file. Unlike the
//! player, swfdump does not reject AVM2 movies — it is a parser tool.

const std = @import("std");
const flash = @import("flash");
const swf = flash.swf;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try out.writeAll("usage: swfdump <file.swf> [more.swf ...]\n");
        try out.flush();
        return 2;
    }

    var failures: u8 = 0;
    for (args[1..]) |path| {
        dumpFile(gpa, io, out, path) catch |err| {
            try out.print("{s}: FATAL: {t}\n", .{ path, err });
            failures = 1;
        };
    }
    try out.flush();
    return failures;
}

fn dumpFile(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(bytes);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var dec = try swf.decompress.decompress(a, bytes);
    const h = try swf.header.parse(dec.body);
    try out.print("# {s}\n", .{path});
    try out.print("swf v{d} {s} {d}x{d}px {d:.2}fps {d} frames\n", .{
        dec.version,  dec.compression.name(),
        h.widthPx(),  h.heightPx(),
        h.frame_rate, h.frame_count,
    });
    try dumpStream(a, out, dec.body[h.tags_offset..], dec.version, 0);
}

fn indent(out: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try out.writeAll("  ");
}

fn dumpStream(
    a: std.mem.Allocator,
    out: *std.Io.Writer,
    stream: []const u8,
    swf_version: u8,
    depth: usize,
) anyerror!void {
    var it = swf.tags.TagIterator.init(stream);
    while (it.next()) |tag| {
        try indent(out, depth);
        try out.print("{s}", .{tag.code.name()});
        if (tag.code == .end) {
            try out.writeAll("\n");
            break;
        }
        dumpTag(a, out, tag, swf_version, depth) catch |err| {
            try out.print(" !decode-error {t}", .{err});
        };
        if (tag.truncated) try out.writeAll(" !truncated");
        try out.writeAll("\n");
    }
}

fn dumpMatrix(out: *std.Io.Writer, m: swf.reader.Matrix) !void {
    try out.print(" matrix=[{d:.3} {d:.3} {d:.3} {d:.3} {d} {d}]", .{ m.a, m.b, m.c, m.d, m.tx, m.ty });
}

fn dumpCxform(out: *std.Io.Writer, t: swf.reader.ColorTransform) !void {
    try out.print(" cxform=[*{d} {d} {d} {d} +{d} {d} {d} {d}]", .{
        t.mult[0], t.mult[1], t.mult[2], t.mult[3],
        t.add[0],  t.add[1],  t.add[2],  t.add[3],
    });
}

fn fillName(f: swf.shape.FillStyle) []const u8 {
    return switch (f) {
        .solid => "solid",
        .linear_gradient => "linear",
        .radial_gradient => "radial",
        .focal_gradient => "focal",
        .bitmap => "bitmap",
    };
}

fn dumpTag(
    a: std.mem.Allocator,
    out: *std.Io.Writer,
    tag: swf.tags.Tag,
    swf_version: u8,
    depth: usize,
) !void {
    switch (tag.code) {
        .define_shape, .define_shape2, .define_shape3, .define_shape4 => {
            const v: u8 = switch (tag.code) {
                .define_shape => 1,
                .define_shape2 => 2,
                .define_shape3 => 3,
                else => 4,
            };
            const s = try swf.shape.parse(a, tag.body, .{ .swf_version = swf_version, .shape_version = v });
            try out.print(" id={d} bounds=({d},{d},{d},{d}) fills={d} lines={d} records={d}", .{
                s.id,               s.bounds.xmin, s.bounds.ymin,
                s.bounds.xmax,      s.bounds.ymax, s.styles.fills.len,
                s.styles.lines.len, s.records.len,
            });
            for (s.styles.fills) |f| try out.print(" fill:{s}", .{fillName(f)});
        },
        .define_morph_shape, .define_morph_shape2 => {
            const v: u8 = if (tag.code == .define_morph_shape) 1 else 2;
            if (swf.morph.parse(a, tag.body, swf_version, v)) |m| {
                try out.print(
                    " id={d} start=({d},{d},{d},{d}) end=({d},{d},{d},{d}) fills={d} lines={d} records={d}/{d}",
                    .{
                        m.id,                     m.start_bounds.xmin, m.start_bounds.ymin,
                        m.start_bounds.xmax,      m.start_bounds.ymax, m.end_bounds.xmin,
                        m.end_bounds.ymin,        m.end_bounds.xmax,   m.end_bounds.ymax,
                        m.start_styles.fills.len, m.start_styles.lines.len,
                        m.start_records.len,      m.end_records.len,
                    },
                );
            } else |err| {
                try out.print(" UNDECODABLE ({s})", .{@errorName(err)});
            }
        },
        .place_object => {
            const po = try swf.place.parsePlace1(tag.body);
            try out.print(" id={d} depth={d}", .{ po.action.place, po.depth });
            if (po.matrix) |m| try dumpMatrix(out, m);
        },
        .place_object2, .place_object3 => {
            const v: u8 = if (tag.code == .place_object2) 2 else 3;
            const po = try swf.place.parsePlace23(a, tag.body, v, swf_version);
            switch (po.action) {
                .place => |id| try out.print(" place={d}", .{id}),
                .replace => |id| try out.print(" replace={d}", .{id}),
                .modify => try out.writeAll(" modify"),
            }
            try out.print(" depth={d}", .{po.depth});
            if (po.matrix) |m| try dumpMatrix(out, m);
            if (po.color_transform) |t| try dumpCxform(out, t);
            if (po.ratio) |x| try out.print(" ratio={d}", .{x});
            if (po.name) |n| try out.print(" name=\"{s}\"", .{n});
            if (po.clip_depth) |d| try out.print(" clip_depth={d}", .{d});
            if (po.blend_mode) |m| try out.print(" blend={d}", .{m});
            if (po.had_filters) try out.writeAll(" filters");
            if (po.clip_actions.len > 0) try out.print(" clip_actions={d}", .{po.clip_actions.len});
        },
        .remove_object, .remove_object2 => {
            const v: u8 = if (tag.code == .remove_object) 1 else 2;
            const ro = try swf.place.parseRemove(tag.body, v);
            if (ro.id) |id| try out.print(" id={d}", .{id});
            try out.print(" depth={d}", .{ro.depth});
        },
        .set_background_color => {
            var r = swf.reader.Reader.init(tag.body);
            const c = try r.readRgb();
            try out.print(" #{x:0>2}{x:0>2}{x:0>2}", .{ c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF });
        },
        .do_action, .do_init_action => try out.print(" bytes={d}", .{tag.body.len}),
        .frame_label => {
            var r = swf.reader.Reader.init(tag.body);
            try out.print(" \"{s}\"", .{r.readString() catch tag.body});
        },
        .define_sprite => {
            var r = swf.reader.Reader.init(tag.body);
            const id = try r.readU16();
            const frames = try r.readU16();
            try out.print(" id={d} frames={d}\n", .{ id, frames });
            try dumpStream(a, out, tag.body[4..], swf_version, depth + 1);
            return; // nested stream printed its own lines
        },
        .define_font => {
            const f = try swf.font_text.parseFont1(a, tag.body, swf_version);
            try out.print(" id={d} glyphs={d}", .{ f.id, f.glyphs.len });
        },
        .define_font2, .define_font3 => {
            const v: u8 = if (tag.code == .define_font2) 2 else 3;
            const f = try swf.font_text.parseFont2(a, tag.body, v, swf_version);
            try out.print(" id={d} \"{s}\" glyphs={d}{s}{s}{s}", .{
                f.id,                           f.name,                             f.glyphs.len,
                if (f.is_bold) " bold" else "", if (f.is_italic) " italic" else "", if (f.layout != null) " layout" else "",
            });
        },
        .define_font_info, .define_font_info2 => {
            const v: u8 = if (tag.code == .define_font_info) 1 else 2;
            const info = try swf.font_text.parseFontInfo(a, tag.body, v);
            try out.print(" font={d} \"{s}\" codes={d}", .{ info.font_id, info.name, info.codes.len });
        },
        .define_text, .define_text2 => {
            const v: u8 = if (tag.code == .define_text) 1 else 2;
            const t = try swf.font_text.parseText(a, tag.body, v);
            try out.print(" id={d} records={d}", .{ t.id, t.records.len });
        },
        .define_edit_text => {
            const et = try swf.font_text.parseEditText(tag.body);
            try out.print(" id={d} var=\"{s}\"", .{ et.id, et.variable_name });
            if (et.font_id) |f| try out.print(" font={d} height={d}", .{ f, et.height });
            if (et.is_html) try out.writeAll(" html");
            if (et.multiline) try out.writeAll(" multiline");
            if (et.initial_text) |t| try out.print(" text=\"{s}\"", .{t});
        },
        .define_button => {
            const btn = try swf.button.parseButton1(a, tag.body);
            try out.print(" id={d} records={d} actions={d}", .{ btn.id, btn.records.len, btn.actions.len });
        },
        .define_button2 => {
            const btn = try swf.button.parseButton2(a, tag.body);
            try out.print(" id={d} records={d} cond_actions={d}", .{ btn.id, btn.records.len, btn.actions.len });
        },
        .define_bits => {
            const bmp = try swf.bitmap_tags.parseBits(tag.body);
            try out.print(" id={d} jpeg={d}B", .{ bmp.id, bmp.jpeg_data.len });
        },
        .define_bits_jpeg2 => {
            const bmp = try swf.bitmap_tags.parseJpeg2(tag.body);
            try out.print(" id={d} data={d}B", .{ bmp.id, bmp.data.len });
        },
        .define_bits_jpeg3 => {
            const bmp = try swf.bitmap_tags.parseJpeg3(tag.body);
            try out.print(" id={d} data={d}B alpha={d}B", .{ bmp.id, bmp.data.len, bmp.alpha_zlib.len });
        },
        .define_bits_lossless, .define_bits_lossless2 => {
            const v: u8 = if (tag.code == .define_bits_lossless) 1 else 2;
            const bmp = try swf.bitmap_tags.parseLossless(tag.body, v);
            try out.print(" id={d} {d}x{d} format={d}", .{
                bmp.id, bmp.width, bmp.height, @intFromEnum(bmp.format),
            });
        },
        .define_sound => {
            const s = try swf.sound_tags.parseSound(tag.body);
            try out.print(" id={d} {t} {d}Hz{s}{s} samples={d} data={d}B", .{
                s.id,                                           s.format.compression,
                s.format.sample_rate,                           if (s.format.is_16_bit) " 16bit" else " 8bit",
                if (s.format.is_stereo) " stereo" else " mono", s.num_samples,
                s.data.len,
            });
        },
        .start_sound => {
            const ss = try swf.sound_tags.parseStartSound(a, tag.body);
            try out.print(" id={d} loops={d}", .{ ss.id, ss.info.num_loops });
        },
        .sound_stream_head, .sound_stream_head2 => {
            const sh = try swf.sound_tags.parseStreamHead(tag.body);
            try out.print(" {t} {d}Hz samples/block={d}", .{
                sh.stream.compression, sh.stream.sample_rate, sh.samples_per_block,
            });
        },
        .sound_stream_block, .jpeg_tables => try out.print(" bytes={d}", .{tag.body.len}),
        .export_assets => {
            var r = swf.reader.Reader.init(tag.body);
            const n = try r.readU16();
            for (0..n) |_| {
                const id = try r.readU16();
                try out.print(" {d}=\"{s}\"", .{ id, try r.readString() });
            }
        },
        .file_attributes => {
            var r = swf.reader.Reader.init(tag.body);
            const flags = try r.readU32();
            if ((flags & (1 << 3)) != 0) try out.writeAll(" AS3");
            if ((flags & (1 << 6)) != 0) try out.writeAll(" gpu");
            if ((flags & (1 << 4)) != 0) try out.writeAll(" metadata");
        },
        .show_frame => {},
        else => {
            if (std.mem.eql(u8, tag.code.name(), "Unknown")) {
                try out.print("({d})", .{tag.rawCode()});
            }
            if (tag.body.len > 0) try out.print(" bytes={d}", .{tag.body.len});
        },
    }
}
