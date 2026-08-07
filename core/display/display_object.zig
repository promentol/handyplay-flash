//! A placed display-list entry: one character instance at a depth, with
//! its placement state (matrix/cxform/ratio/name/clipDepth). Children of a
//! timeline live in MovieClip.children, kept depth-sorted.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const library = @import("library.zig");
const movie_clip = @import("movie_clip.zig");

pub const DisplayObject = struct {
    character_id: u16,
    depth: u16,
    /// Non-zero: this object masks depths (depth, clip_depth].
    clip_depth: u16 = 0,
    matrix: swf.reader.Matrix = .identity,
    color_transform: swf.reader.ColorTransform = .{},
    name: ?[]const u8 = null,
    /// Morph ratio (0-65535).
    ratio: u16 = 0,
    visible: bool = true,
    /// PlaceObject3 blend byte (0/1 = normal).
    blend_mode: u8 = 0,
    /// Frame number (1-based) this object was placed on — goto rewind uses
    /// it to decide survival.
    place_frame: u16 = 0,
    kind: Kind,

    pub const Kind = union(enum) {
        /// Static characters render straight from the (frozen) library.
        shape: *const swf.shape.Shape,
        morph_shape: u16, // character id; decoded in M7
        text: *const swf.font_text.Text,
        edit_text: *const swf.font_text.EditText,
        button: *const swf.button.Button,
        bitmap: u16, // character id; decoded pixels cached in M4
        /// Sprites instantiate their own timeline.
        clip: *movie_clip.MovieClip,
    };

    pub fn deinit(self: *DisplayObject, gpa: std.mem.Allocator) void {
        switch (self.kind) {
            .clip => |mc| {
                mc.deinit(gpa);
                gpa.destroy(mc);
            },
            else => {},
        }
        self.* = undefined;
    }
};
