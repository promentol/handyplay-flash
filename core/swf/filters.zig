//! FILTERLIST skipping (SWF8: DefineButton2 records, PlaceObject3).
//! M1 policy: filters are out of render scope, but their bytes sit in the
//! middle of structures we DO parse — so they must be skipped exactly.
//! Sizes per SWF19 §Filters. Full decoding arrives with the filter
//! milestone (simdra has the primitives: blur/shadow/colorMatrix/convolve).

const std = @import("std");
const rdr = @import("reader.zig");

pub const Error = rdr.Error || error{InvalidFilter};

/// Skip one FILTERLIST (count byte + filters). Returns the filter count.
pub fn skipList(r: *rdr.Reader) Error!u8 {
    const n = try r.readU8();
    for (0..n) |_| try skipOne(r);
    return n;
}

fn skipOne(r: *rdr.Reader) Error!void {
    const id = try r.readU8();
    switch (id) {
        0 => try r.skip(23), // DropShadow: rgba + blurX/Y + angle + distance + strength + flags
        1 => try r.skip(9), // Blur: blurX/Y + flags(passes)
        2 => try r.skip(15), // Glow: rgba + blurX/Y + strength + flags
        3 => try r.skip(27), // Bevel: 2×rgba + blurX/Y + angle + distance + strength + flags
        4, 7 => { // GradientGlow / GradientBevel
            const num = try r.readU8();
            try r.skip(@as(usize, num) * 5 + 19); // n×rgba + n×ratio + geometry
        },
        5 => { // Convolution
            const mx = try r.readU8();
            const my = try r.readU8();
            try r.skip(8 + @as(usize, mx) * @as(usize, my) * 4 + 5); // divisor+bias + matrix + rgba + flags
        },
        6 => try r.skip(80), // ColorMatrix: 20×f32
        else => return Error.InvalidFilter,
    }
}

test "skip a mixed filter list" {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const ta = std.testing.allocator;
    try b.append(ta, 3); // 3 filters
    try b.append(ta, 1); // blur
    try b.appendSlice(ta, &(.{0} ** 9));
    try b.append(ta, 4); // gradient glow, 2 colors
    try b.append(ta, 2);
    try b.appendSlice(ta, &(.{0} ** (2 * 5 + 19)));
    try b.append(ta, 6); // color matrix
    try b.appendSlice(ta, &(.{0} ** 80));
    try b.appendSlice(ta, &.{ 0xAA, 0xBB }); // trailing sentinel

    var r = rdr.Reader.init(b.items);
    const n = try skipList(&r);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqual(@as(u8, 0xAA), try r.readU8());
}
