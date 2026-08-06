//! SWF decoding layer — pure decoding, zero interpretation.
//! Module root; see docs/ARCHITECTURE.md §swf for the contract.

pub const decompress = @import("decompress.zig");
pub const header = @import("header.zig");

// M1: reader.zig (bit/byte reader: UB/SB/FB, RECT, MATRIX, CXFORM, strings,
//     LE32_FLOAT64), tags.zig (scanner + TagCode), shape.zig, place.zig,
//     font_text.zig, button.zig, bitmap_tags.zig, sound_tags.zig, movie.zig.
// M7: morph.zig.

test {
    @import("std").testing.refAllDecls(@This());
}
