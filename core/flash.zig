//! Umbrella module root (mirrors handyplay-oss exen.zig). Frontend-
//! agnostic, no I/O. The host seam (init/loadSwf/tick/framebuffer/input/
//! state — see docs/ARCHITECTURE.md) lands in M2 when display/render are
//! wired; until then this re-exports the parsing layers.

pub const swf = @import("swf/swf.zig");

pub const display = struct {
    pub const library = @import("display/library.zig");
    // M2: display_object.zig, movie_clip.zig; M4: button.zig, text.zig.
};

test {
    @import("std").testing.refAllDecls(@This());
}
