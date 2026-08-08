//! A DEVICE font: a face the movie did not embed.
//!
//! Flash asks the operating system for these, so the bytes have to come
//! from the host — `core/` does no I/O. The player takes a TTF through
//! `Options.device_font` and every unresolved face resolves to it, which
//! is exactly the shape ruffle's `ui.load_device_font` seam has and what
//! its conformance harness does with a bundled Noto Sans subset.
//!
//! With no device font registered, an unresolved face measures zero and
//! draws nothing — still the right answer for a machine with the font
//! missing, and what the whole corpus except four dirs expects.
//!
//! The face is exposed in EM UNITS, not pixels: a text field scales per
//! span, exactly as it does for an embedded `DefineFont`, so the same
//! `ascent * height / scale` arithmetic serves both.
//!
//! Reference: reference/ruffle/core/src/font.rs (FontFileData / the
//! `FontFace` glyph source) and tests/framework/src/backends/ui.rs.

const std = @import("std");
const simdra = @import("simdra");
const shape = @import("../swf/shape.zig");
const swf_reader = @import("../swf/reader.zig");

pub const DeviceFont = struct {
    face: simdra.SmFont,
    /// EM units per em — the denominator an embedded font gets from its
    /// tag version (1024 or 20480).
    units_per_em: f64,
    ascent: i32,
    descent: i32,
    /// Outlines are expensive to extract; each is built once.
    outlines: std.AutoHashMapUnmanaged(i32, []Segment) = .empty,
    gpa: std.mem.Allocator,

    /// One drawing step of an outline, in EM units with y DOWN — the SWF
    /// convention, so the flip out of TrueType's y-up happens once here.
    pub const Segment = struct {
        pub const Kind = enum { move, line, quad };
        kind: Kind,
        x: f32,
        y: f32,
        cx: f32 = 0,
        cy: f32 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, ttf: []const u8) !DeviceFont {
        // The size is irrelevant — everything below reads UNSCALED — but
        // SmFont insists on a positive one.
        var face = try simdra.SmFont.fromBytesWithAllocator(gpa, ttf, 12.0);
        errdefer face.release();
        const m = face.vMetricsUnscaled();
        return .{
            .face = face,
            .units_per_em = m.units_per_em,
            .ascent = m.ascent,
            // TrueType's descent is NEGATIVE below the baseline; Flash's
            // is a positive distance.
            .descent = -m.descent,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *DeviceFont) void {
        var it = self.outlines.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.outlines.deinit(self.gpa);
        self.face.release();
    }

    /// Zero when the face has no glyph for this character — the caller
    /// then treats it as missing, exactly as with an embedded font.
    pub fn glyphIndex(self: *const DeviceFont, code: u16) ?i32 {
        const g = self.face.glyphIndexFor(code);
        return if (g == 0) null else g;
    }

    pub fn advance(self: *const DeviceFont, glyph: i32) i32 {
        return self.face.glyphAdvanceUnscaled(glyph);
    }

    pub fn kerning(self: *const DeviceFont, left: i32, right: i32) i32 {
        return self.face.glyphKernUnscaled(left, right);
    }

    /// The glyph's contours, cached. Cubics are split into two quadratics
    /// — the SWF path model has no cubic, and a TrueType face only emits
    /// them for CFF outlines anyway.
    pub fn outline(self: *DeviceFont, glyph: i32) []const Segment {
        if (self.outlines.get(glyph)) |cached| return cached;
        const verts = self.face.glyphOutline(self.gpa, glyph) catch return &.{};
        defer self.gpa.free(verts);

        var out: std.ArrayList(Segment) = .empty;
        var last: [2]f32 = .{ 0, 0 };
        for (verts) |v| {
            const x: f32 = @floatFromInt(v.x);
            const y: f32 = -@as(f32, @floatFromInt(v.y));
            switch (v.kind) {
                .move => out.append(self.gpa, .{ .kind = .move, .x = x, .y = y }) catch return &.{},
                .line => out.append(self.gpa, .{ .kind = .line, .x = x, .y = y }) catch return &.{},
                .quad => out.append(self.gpa, .{
                    .kind = .quad,
                    .x = x,
                    .y = y,
                    .cx = @floatFromInt(v.cx),
                    .cy = -@as(f32, @floatFromInt(v.cy)),
                }) catch return &.{},
                .cubic => {
                    const c1: [2]f32 = .{ @floatFromInt(v.cx), -@as(f32, @floatFromInt(v.cy)) };
                    const c2: [2]f32 = .{ @floatFromInt(v.cx1), -@as(f32, @floatFromInt(v.cy1)) };
                    const mid: [2]f32 = .{
                        (last[0] + 3 * c1[0] + 3 * c2[0] + x) / 8,
                        (last[1] + 3 * c1[1] + 3 * c2[1] + y) / 8,
                    };
                    out.append(self.gpa, .{
                        .kind = .quad,
                        .x = mid[0],
                        .y = mid[1],
                        .cx = (last[0] + 3 * c1[0]) / 4,
                        .cy = (last[1] + 3 * c1[1]) / 4,
                    }) catch return &.{};
                    out.append(self.gpa, .{
                        .kind = .quad,
                        .x = x,
                        .y = y,
                        .cx = (x + 3 * c2[0]) / 4,
                        .cy = (y + 3 * c2[1]) / 4,
                    }) catch return &.{};
                },
            }
            last = .{ x, y };
        }
        const owned = out.toOwnedSlice(self.gpa) catch return &.{};
        self.outlines.put(self.gpa, glyph, owned) catch return owned;
        return owned;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "a face that will not parse is an error, not a crash" {
    try testing.expectError(error.InvalidFont, DeviceFont.init(testing.allocator, "not a font"));
}
