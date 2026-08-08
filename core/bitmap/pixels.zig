//! The pixel model every bitmap operation runs on.
//!
//! A leaf module: `std` only. The AVM1 class lives in
//! `core/avm1/globals/bitmap_data.zig` and the operations in
//! `operations.zig`; both speak in terms of the `Color` below.
//!
//! **Storage is PREMULTIPLIED, the script view is not.** Every operation
//! has to say which form it wants: blending is correct only on
//! premultiplied values and a colour transform only on unmultiplied ones,
//! so `getPixel32` un-multiplies on the way out and `setPixel32`
//! multiplies on the way in.
//!
//! Un-multiplying is the part that looks wrong and is not: it is a
//! 256-entry LOOKUP TABLE, not a division. The table was brute-forced
//! against Flash (ruffle bitmap_data.rs, crediting
//! https://gist.github.com/pdewacht/614b428cd42c2052dc0fd292516c9f9f) and
//! a plain `c * 255 / a` is off by one across most of the range — which
//! the corpus notices, because it reads pixels back one at a time.
//!
//! Reference: reference/ruffle/core/src/bitmap/bitmap_data.rs and
//! core/src/bitmap.rs.

const std = @import("std");

/// ARGB, one byte per channel. Which of the two forms an instance holds
/// is the caller's business — the type cannot tell you.
pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn fromArgb(v: u32) Color {
        return @bitCast(v);
    }

    pub fn toArgb(self: Color) u32 {
        return @bitCast(self);
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn withAlpha(self: Color, a: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// An OPAQUE bitmap ignores the alpha it is handed and stores 255,
    /// which is why writing a translucent colour into one reads back
    /// solid.
    pub fn toPremultiplied(self: Color, transparency: bool) Color {
        const a: u32 = if (transparency) self.a else 255;
        return .{
            .r = @intCast((@as(u32, self.r) * a + 127) / 255),
            .g = @intCast((@as(u32, self.g) * a + 127) / 255),
            .b = @intCast((@as(u32, self.b) * a + 127) / 255),
            .a = @intCast(a),
        };
    }

    pub fn toUnmultiplied(self: Color) Color {
        const f = PREMUL_FACTOR[self.a];
        return .{
            .r = unmul(self.r, f),
            .g = unmul(self.g, f),
            .b = unmul(self.b, f),
            .a = self.a,
        };
    }
};

/// CLAMPED, not just cast. `perlinNoise` writes its output raw, so a
/// channel can exceed the alpha it is supposedly multiplied by — an
/// impossible premultiplied pixel — and reversing that overflows a byte.
/// Flash saturates, and `bitmap_data_thorough/perlinNoise` reads the
/// resulting 0xFFs back.
fn unmul(c: u8, factor: u32) u8 {
    return @intCast(@min((@as(u32, c) * factor + 0x8000) >> 16, 255));
}

/// Indexed by ALPHA. Brute-forced to reproduce Flash's own rounding when
/// premultiplication is reversed; do not replace it with arithmetic.
const PREMUL_FACTOR = [256]u32{
    0, 16678912, 8339456, 5559638, 4169728, 3335783, 2779819, 2386603,
    2086230, 1855488, 1667892, 1518251, 1391151, 1285234, 1193302, 1111928,
    1043895, 981113, 927744, 879275, 834621, 795535, 759126, 726358,
    695839, 668183, 642538, 618737, 596651, 576171, 555964, 538706,
    522104, 506319, 490557, 477321, 464038, 451353, 439544, 428244,
    417582, 407500, 397768, 388535, 379630, 371117, 363179, 355235,
    348050, 340965, 334052, 327038, 321269, 315077, 309159, 303586,
    298189, 293092, 287981, 283080, 278251, 273892, 269268, 265179,
    261087, 256971, 253160, 249322, 245508, 242164, 238575, 235245,
    231859, 228848, 225785, 222712, 219616, 216827, 213985, 211432,
    208835, 206075, 203750, 201196, 198895, 196223, 194301, 191987,
    189686, 187636, 185559, 183426, 181453, 179444, 177638, 175855,
    174054, 171948, 170489, 168695, 166889, 165365, 163519, 162045,
    160508, 158970, 157429, 156150, 154610, 153081, 151803, 150511,
    148986, 147709, 146420, 145116, 143868, 142586, 141545, 140277,
    139194, 137957, 136954, 135676, 134652, 133621, 132604, 131577,
    130552, 129527, 128508, 127476, 126451, 125432, 124670, 123645,
    122818, 121847, 121082, 120060, 119288, 118263, 117502, 116720,
    115967, 115195, 114424, 113655, 112893, 112125, 111356, 110563,
    109811, 109048, 108287, 107766, 107004, 106236, 105724, 104953,
    104434, 103676, 102904, 102375, 101879, 101119, 100604, 99834,
    99321, 98813, 98112, 97533, 97019, 96509, 95994, 95486,
    94713, 94185, 93689, 93179, 92667, 92149, 91643, 91129,
    90621, 90068, 89597, 89342, 88829, 88318, 87804, 87294,
    87034, 86523, 85994, 85499, 85245, 84732, 84222, 83956,
    83450, 82937, 82685, 82173, 81840, 81405, 80889, 80638,
    80127, 79862, 79354, 79103, 78590, 78332, 78077, 77565,
    77308, 76795, 76541, 76284, 75766, 75518, 75262, 74748,
    74493, 74238, 73691, 73470, 73214, 72959, 72447, 72189,
    71935, 71671, 71166, 70911, 70651, 70399, 70140, 69886,
    69615, 69116, 68861, 68603, 68350, 68093, 67839, 67576,
    67326, 67070, 66813, 66556, 66302, 66046, 65791, 65408,
};

/// Flash's own generator, and the reason `noise` and `pixelDissolve` are
/// exact-match tests rather than statistical ones: the sequence is fully
/// determined by the seed.
pub const LehmerRng = struct {
    x: u32,

    pub fn withSeed(seed: u32) LehmerRng {
        return .{ .x = seed };
    }

    /// X(k+1) = 16807 * X(k) mod 2147483647.
    pub fn next(self: *LehmerRng) u32 {
        self.x = @intCast((@as(u64, self.x) *% 16807) % 2147483647);
        return self.x;
    }

    /// INCLUSIVE of `hi` — the `+ 1` is Flash's, not a fencepost slip.
    pub fn range(self: *LehmerRng, lo: u8, hi: u8) u8 {
        return lo + @as(u8, @intCast(self.next() % (@as(u32, hi - lo) + 1)));
    }
};

/// The dimensions a BitmapData will accept. Zero is refused at every
/// version; the ceilings rise with it, and the last pair is undocumented
/// but reliable (ruffle bitmap.rs:26-49). `bitmap_data_max_size_swf9` and
/// `_swf10` exist to pin the two lower tiers.
pub fn isSizeValid(swf_version: u8, width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    if (swf_version <= 9) return width <= 2880 and height <= 2880;
    if (swf_version <= 12) {
        return width < 0x2000 and height < 0x2000 and
            @as(u64, width) * @as(u64, height) < 0x1000000;
    }
    return width <= 0x6666666 and height <= 0x6666666 and
        @as(u64, width) * @as(u64, height) < 0x20000000;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "premultiplying and un-premultiplying round-trip through Flash's table" {
    // Every alpha, a colour that survives the trip: the table exists
    // precisely so this holds where a divide would drift.
    var a: u32 = 1;
    while (a <= 255) : (a += 1) {
        const c = Color.rgba(255, 128, 0, @intCast(a));
        const round = c.toPremultiplied(true).toUnmultiplied();
        try testing.expectEqual(c.a, round.a);
        try testing.expect(round.r >= 254);
    }
}

test "an opaque bitmap stores 255 whatever it is handed" {
    const c = Color.rgba(200, 100, 50, 0);
    const p = c.toPremultiplied(false);
    try testing.expectEqual(@as(u8, 255), p.a);
    try testing.expectEqual(@as(u8, 200), p.r);
}

test "the Lehmer sequence is the one Flash uses" {
    var rng = LehmerRng.withSeed(1);
    try testing.expectEqual(@as(u32, 16807), rng.next());
    try testing.expectEqual(@as(u32, 282475249), rng.next());
    try testing.expectEqual(@as(u32, 1622650073), rng.next());
}

test "size limits move with the SWF version" {
    try testing.expect(!isSizeValid(8, 0, 10));
    try testing.expect(isSizeValid(9, 2880, 2880));
    try testing.expect(!isSizeValid(9, 2881, 1));
    try testing.expect(isSizeValid(10, 2881, 1));
    try testing.expect(!isSizeValid(10, 0x2000, 1));
}
