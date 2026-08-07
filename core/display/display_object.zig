//! A placed display-list entry: one character instance at a depth, with
//! its placement state (matrix/cxform/ratio/name/clipDepth). Children of a
//! timeline live in MovieClip.children, kept depth-sorted.
//!
//! This is also where scripted transforms live. AVM1 exposes `_xscale`,
//! `_yscale` and `_rotation`, which are not stored in a SWF matrix — they
//! are a DECOMPOSITION of it. Ruffle caches that decomposition rather than
//! re-deriving it per read (core/src/display_object.rs cache_scale_rotation)
//! and so do we: the cache is what makes `_xscale = 20` read back as
//! exactly 20 instead of 19.999999999999996, and what lets Flash report a
//! NaN scale while still multiplying the matrix by 0.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const strings = @import("../avm1/string.zig");
const library = @import("library.zig");
const movie_clip = @import("movie_clip.zig");

pub const DisplayObject = struct {
    character_id: u16,
    /// SWF tags only ever use 0..65535, but SCRIPTS address a much wider
    /// range (ruffle's Depth is i32) — `remove_movie_clip` exercises
    /// "wacky depths" well past u16. Timeline depths are promoted on the
    /// way in; only clip_depth stays a raw tag field.
    depth: i32,
    /// Non-zero: this object masks depths (depth, clip_depth].
    clip_depth: u16 = 0,
    matrix: swf.reader.Matrix = .identity,
    color_transform: swf.reader.ColorTransform = .{},
    /// Instance name as UCS-2, OWNED by this object (script can overwrite
    /// it via `_name`, so it cannot stay a slice into the movie buffer).
    name: ?[]const u16 = null,
    /// Morph ratio (0-65535).
    ratio: u16 = 0,
    visible: bool = true,
    /// PlaceObject3 blend byte (0/1 = normal).
    blend_mode: u8 = 0,
    /// `onClipEvent(...)` bodies from the placing tag. Like `name` and
    /// `clip_depth`, these are taken only at INITIAL placement.
    clip_actions: []const swf.place.ClipAction = &.{},
    /// Frame number (1-based) this object was placed on — goto rewind uses
    /// it to decide survival.
    place_frame: u16 = 0,
    kind: Kind,

    /// True once AVM1 has moved this object. Ruffle's apply_place_object
    /// then skips the timeline's placement entirely, so a PlaceObject2 on
    /// a later frame can't undo a script's `_x`.
    transformed_by_script: bool = false,
    /// `kind` was heap-allocated by us and must be freed. False for the
    /// synthetic root placement, whose clip the Player owns.
    owns_kind: bool = true,
    /// The timeline this instance sits in. Set for EVERY kind, unlike
    /// `MovieClip.parent`, so a button or text field can build its path.
    parent: ?*movie_clip.MovieClip = null,
    /// Lazily-created AVM1 object (0 = none). Clips keep theirs on the
    /// MovieClip; buttons and text fields keep theirs here.
    avm_object: u32 = 0,
    /// `setMask` link. Stored now so scripts can read it back; the
    /// renderer starts honouring it with clipDepth masks in M7.
    mask: ?*DisplayObject = null,
    /// Off the display list but possibly still script-referenced. Clips
    /// carry the same flag on their MovieClip; buttons and text fields
    /// need it here or a removed one keeps reading as a live object.
    removed: bool = false,

    // Decomposed transform cache — valid only while `sr_cached`.
    // Scales are PERCENT (100 = 1.0), stored exactly as ActionScript set
    // them; the /100 happens only when rebuilding the matrix. Ruffle's
    // Percent type does the same, and it is what makes `_xscale = 28`
    // read back as 28 rather than 28.000000000000004.
    scale_x: f64 = 100,
    scale_y: f64 = 100,
    rotation_deg: f64 = 0,
    skew_rad: f64 = 0,
    sr_cached: bool = false,

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
        if (self.name) |n| gpa.free(n);
        if (self.owns_kind) switch (self.kind) {
            .clip => |mc| {
                mc.deinit(gpa);
                gpa.destroy(mc);
            },
            else => {},
        };
        self.* = undefined;
    }

    pub fn setName(self: *DisplayObject, gpa: std.mem.Allocator, n: ?[]const u16) !void {
        const copy = if (n) |s| try gpa.dupe(u16, s) else null;
        if (self.name) |old| gpa.free(old);
        self.name = copy;
    }

    pub fn setNameFromSwf(self: *DisplayObject, gpa: std.mem.Allocator, bytes: []const u8, swf_version: u8) !void {
        const wide = try strings.fromSwf(gpa, bytes, swf_version);
        if (self.name) |old| gpa.free(old);
        self.name = wide;
    }

    // --- transform accessors (ruffle display_object.rs:443-652) -----------

    /// Whole-matrix replacement (timeline placement, Transform.matrix).
    /// Invalidates the decomposition; the per-component setters below must
    /// NOT use this, they maintain the cache themselves.
    pub fn setMatrix(self: *DisplayObject, m: swf.reader.Matrix) void {
        self.matrix = m;
        self.sr_cached = false;
    }

    pub fn setX(self: *DisplayObject, twips: i32) void {
        self.matrix.tx = twips;
        self.transformed_by_script = true;
    }

    pub fn setY(self: *DisplayObject, twips: i32) void {
        self.matrix.ty = twips;
        self.transformed_by_script = true;
    }

    /// Derive scale/rotation/skew from a/b/c/d, once, lazily. The x-axis
    /// becomes <a,b> and the y-axis <c,d>; skew is the signed angle between
    /// them and is not exposed to ActionScript, only remembered.
    pub fn cacheScaleRotation(self: *DisplayObject) void {
        if (self.sr_cached) return;
        const m = self.matrix;
        const rotation_x = std.math.atan2(m.b, m.a);
        const rotation_y = std.math.atan2(-m.c, m.d);
        self.rotation_deg = std.math.radiansToDegrees(rotation_x);
        self.scale_x = @sqrt(m.a * m.a + m.b * m.b) * 100.0;
        self.scale_y = @sqrt(m.c * m.c + m.d * m.d) * 100.0;
        self.skew_rad = rotation_y - rotation_x;
        self.sr_cached = true;
    }

    pub fn scaleX(self: *DisplayObject) f64 {
        self.cacheScaleRotation();
        return self.scale_x;
    }

    pub fn scaleY(self: *DisplayObject) f64 {
        self.cacheScaleRotation();
        return self.scale_y;
    }

    pub fn rotation(self: *DisplayObject) f64 {
        self.cacheScaleRotation();
        return self.rotation_deg;
    }

    /// `percent` is 100 = unscaled. A NaN is REPORTED back to
    /// ActionScript but treated as 0 when rebuilding the matrix — Flash
    /// really does behave this way (ruffle set_scale_x comment).
    pub fn setScaleX(self: *DisplayObject, percent: f64) void {
        self.transformed_by_script = true;
        self.cacheScaleRotation();
        self.scale_x = percent;
        const v = if (std.math.isNan(percent)) 0 else percent / 100.0;
        const rot = self.rotationRadiansForMatrix();
        self.matrix.a = @floatCast(@cos(rot) * v);
        self.matrix.b = @floatCast(@sin(rot) * v);
    }

    pub fn setScaleY(self: *DisplayObject, percent: f64) void {
        self.transformed_by_script = true;
        self.cacheScaleRotation();
        self.scale_y = percent;
        const v = if (std.math.isNan(percent)) 0 else percent / 100.0;
        const rot = self.rotationRadiansForMatrix() + self.skew_rad;
        self.matrix.c = @floatCast(-@sin(rot) * v);
        self.matrix.d = @floatCast(@cos(rot) * v);
    }

    /// `degrees` is stored verbatim (so a NaN reads back as NaN), but a NaN
    /// leaves the matrix completely alone rather than zeroing it.
    pub fn setRotation(self: *DisplayObject, degrees: f64) void {
        self.transformed_by_script = true;
        self.cacheScaleRotation();
        self.rotation_deg = degrees;
        if (std.math.isNan(degrees)) return;
        const rad = std.math.degreesToRadians(degrees);
        const sx = if (std.math.isNan(self.scale_x)) 0 else self.scale_x / 100.0;
        const sy = if (std.math.isNan(self.scale_y)) 0 else self.scale_y / 100.0;
        self.matrix.a = @floatCast(sx * @cos(rad));
        self.matrix.b = @floatCast(sx * @sin(rad));
        self.matrix.c = @floatCast(sy * -@sin(rad + self.skew_rad));
        self.matrix.d = @floatCast(sy * @cos(rad + self.skew_rad));
    }

    fn rotationRadiansForMatrix(self: *const DisplayObject) f64 {
        if (std.math.isNan(self.rotation_deg)) return 0;
        return std.math.degreesToRadians(self.rotation_deg);
    }

    /// Unit alpha (1.0 = opaque), from the cxform's 8.8-fixed multiplier.
    pub fn alpha(self: *const DisplayObject) f64 {
        return @as(f64, @floatFromInt(self.color_transform.mult[3])) / 256.0;
    }

    pub fn setAlpha(self: *DisplayObject, value: f64) void {
        self.transformed_by_script = true;
        self.color_transform.mult[3] = fixed8FromF64(value);
    }
};

/// ruffle Fixed8::from_f64 — TRUNCATES toward zero, saturates, NaN → 0.
fn fixed8FromF64(n: f64) i16 {
    if (std.math.isNan(n)) return 0;
    const scaled = @trunc(n * 256.0);
    if (scaled >= 32767.0) return 32767;
    if (scaled <= -32768.0) return -32768;
    return @intFromFloat(scaled);
}

/// ruffle Twips::from_pixels — also TRUNCATES (`as i32`), does not round.
/// `_x = 1.234` is 24 twips, not 25.
pub fn twipsFromPixels(px: f64) i32 {
    if (std.math.isNan(px)) return 0;
    const t = @trunc(px * @as(f64, swf.reader.TWIPS_PER_PX));
    if (t >= 2147483647.0) return std.math.maxInt(i32);
    if (t <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(t);
}

pub fn pixelsFromTwips(twips: i32) f64 {
    return @as(f64, @floatFromInt(twips)) / @as(f64, swf.reader.TWIPS_PER_PX);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn bareObject() DisplayObject {
    return .{ .character_id = 0, .depth = 1, .kind = .{ .morph_shape = 0 } };
}

test "twips/fixed8 conversions truncate like Flash" {
    // Truncation, not rounding: 1.234px * 20 = 24.68 -> 24 twips.
    try testing.expectEqual(@as(i32, 24), twipsFromPixels(1.234));
    try testing.expectEqual(@as(i32, 30), twipsFromPixels(1.5));
    try testing.expectEqual(@as(i32, -24), twipsFromPixels(-1.234));
    try testing.expectEqual(@as(i32, 0), twipsFromPixels(std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 1.5), pixelsFromTwips(30));

    var o = bareObject();
    o.setAlpha(0.5);
    try testing.expectEqual(@as(i16, 128), o.color_transform.mult[3]);
    try testing.expectEqual(@as(f64, 0.5), o.alpha());
    o.setAlpha(std.math.nan(f64));
    try testing.expectEqual(@as(i16, 0), o.color_transform.mult[3]);
}

test "scale/rotation cache round-trips exactly" {
    var o = bareObject();
    // A pure decomposition of the rebuilt matrix would drift; the cache
    // must hand back the value that was set, bit for bit.
    var pct: f64 = 20;
    while (pct <= 420) : (pct += 2) {
        o.setScaleX(pct);
        try testing.expectEqual(pct, o.scaleX());
    }
    o.setRotation(180);
    try testing.expectEqual(@as(f64, 180), o.rotation());
    // Rotation preserves scale, and scale preserves rotation.
    try testing.expectApproxEqAbs(@as(f64, 420), o.scaleX(), 1e-10);
    o.setScaleY(200);
    try testing.expectEqual(@as(f64, 180), o.rotation());
    try testing.expectEqual(@as(f64, 200), o.scaleY());
}

test "NaN scale reports back but zeroes the matrix; NaN rotation is inert" {
    var o = bareObject();
    o.setScaleX(std.math.nan(f64));
    try testing.expect(std.math.isNan(o.scaleX()));
    try testing.expectEqual(@as(f64, 0), o.matrix.a);
    try testing.expectEqual(@as(f64, 0), o.matrix.b);

    var p = bareObject();
    p.matrix = .{ .a = 3, .d = 3 };
    p.setRotation(std.math.nan(f64));
    try testing.expect(std.math.isNan(p.rotation()));
    try testing.expectEqual(@as(f64, 3), p.matrix.a); // untouched
}

test "setMatrix invalidates the cache, setX does not" {
    var o = bareObject();
    o.setScaleX(200);
    try testing.expectEqual(@as(f64, 200), o.scaleX());
    o.setX(100);
    try testing.expectEqual(@as(f64, 200), o.scaleX()); // translation is orthogonal
    try testing.expect(o.transformed_by_script);
    o.setMatrix(.{ .a = 3, .d = 3 });
    try testing.expectEqual(@as(f64, 300), o.scaleX()); // re-derived
}
