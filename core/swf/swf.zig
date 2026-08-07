//! SWF decoding layer — pure decoding, zero interpretation.
//! Module root; see docs/ARCHITECTURE.md §swf for the contract.

pub const decompress = @import("decompress.zig");
pub const header = @import("header.zig");
pub const reader = @import("reader.zig");
pub const tags = @import("tags.zig");
pub const shape = @import("shape.zig");
pub const font_text = @import("font_text.zig");
pub const filters = @import("filters.zig");
pub const button = @import("button.zig");
pub const bitmap_tags = @import("bitmap_tags.zig");
pub const sound_tags = @import("sound_tags.zig");
pub const place = @import("place.zig");
pub const movie = @import("movie.zig");

// M7: morph.zig (DefineMorphShape decoding; raw bodies captured by movie).

test {
    @import("std").testing.refAllDecls(@This());
}
