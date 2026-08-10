//! Display-tree bounding boxes, in twips.
//!
//! Ports ruffle's `bounds_with_transform` (core/src/display_object.rs) under
//! `BoundsMode::Script` — the flavour AVM1 sees through `_width`/`_height`,
//! `getBounds` and object hit-testing. An absent box is `null` rather than
//! ruffle's `Rectangle::INVALID` sentinel, so an empty clip can never leak
//! 0x7ffffff into a trace.
//!
//! Two flavours matter and they are easy to confuse:
//!   • `local`  — includes the object's OWN matrix (what `_width` reports)
//!   • `self`   — with an identity matrix (what setting `_width` scales)

const std = @import("std");
const swf = @import("../swf/swf.zig");
const display_object = @import("display_object.zig");
const shape_utils = @import("../render/shape_utils.zig");
const library = @import("library.zig");
const text_mod = @import("text.zig");

const DisplayObject = display_object.DisplayObject;
const Rectangle = swf.reader.Rectangle;
const Matrix = swf.reader.Matrix;

/// Inherent bounds of the character itself, children EXCLUDED, untransformed.
/// Containers have none of their own.
fn morphBounds(lib: ?*const library.Library, id: u16) ?Rectangle {
    const l = lib orelse return null;
    const ch = l.getConstPtr(id) orelse return null;
    return switch (ch.*) {
        .morph_shape => |m| m.start_bounds,
        else => null,
    };
}

pub fn selfBounds(obj: *const DisplayObject) ?Rectangle {
    return selfBoundsIn(obj, null);
}

/// Where the object actually IS — ruffle's `BoundsMode::Engine`, the
/// flavour the renderer and the MOUSE use. It differs from the script
/// flavour on exactly one kind: a morph shape is somewhere between its
/// two declared boxes, at its placement's ratio, while `getBounds` keeps
/// answering with the start shape however far the tween has gone.
pub fn engineSelfBounds(obj: *const DisplayObject, lib: ?*const library.Library) ?Rectangle {
    if (obj.kind == .morph_shape) return morphEngineBounds(lib, obj.kind.morph_shape, obj.ratio);
    return selfBoundsIn(obj, lib);
}

/// The tag declares both end shapes' bounds, so the tween's box needs no
/// edges — which is the only reason a morph can be hit at all before M7
/// decodes them. What it CANNOT do is tell the inside of the shape from
/// the corner of its box; that precision waits for the edges.
fn morphEngineBounds(lib: ?*const library.Library, id: u16, ratio: u16) ?Rectangle {
    const l = lib orelse return null;
    const ch = l.getConstPtr(id) orelse return null;
    const m = switch (ch.*) {
        .morph_shape => |ms| ms,
        else => return null,
    };
    const t: f64 = @as(f64, @floatFromInt(ratio)) / 65535.0;
    return .{
        .xmin = lerpTwips(m.start_bounds.xmin, m.end_bounds.xmin, t),
        .xmax = lerpTwips(m.start_bounds.xmax, m.end_bounds.xmax, t),
        .ymin = lerpTwips(m.start_bounds.ymin, m.end_bounds.ymin, t),
        .ymax = lerpTwips(m.start_bounds.ymax, m.end_bounds.ymax, t),
    };
}

fn morphData(lib: ?*const library.Library, id: u16) ?*const swf.morph.MorphShape {
    const l = lib orelse return null;
    const ch = l.getConstPtr(id) orelse return null;
    return switch (ch.*) {
        .morph_shape => |m| m.data,
        else => null,
    };
}

fn lerpTwips(a: i32, b: i32, t: f64) i32 {
    const av: f64 = @floatFromInt(a);
    const bv: f64 = @floatFromInt(b);
    return @intFromFloat(@round(av + (bv - av) * t));
}

/// A masker is tested from ITS OWN place in the tree, not the masked
/// object's — the two need not be siblings.
fn maskParentToGlobal(obj: *const DisplayObject) Matrix {
    var m: Matrix = .identity;
    var parent = obj.parent;
    while (parent) |p| {
        const placement = p.placement orelse break;
        m = placement.matrix.mul(m);
        parent = p.parent;
    }
    return m;
}

/// `boundsWithTransform` in the ENGINE flavour, children included.
pub fn engineBoundsWithTransform(
    obj: *const DisplayObject,
    m: Matrix,
    lib: ?*const library.Library,
) ?Rectangle {
    var acc: ?Rectangle = if (engineSelfBounds(obj, lib)) |b| m.transformRect(b) else null;
    for (childrenOf(obj)) |child| {
        const child_box = engineBoundsWithTransform(child, m.mul(child.matrix), lib) orelse continue;
        acc = if (acc) |a| unionRect(a, child_box) else child_box;
    }
    return acc;
}

/// `selfBounds`, with the library available — a MORPH shape needs it to
/// reach the bounds its tag declared.
pub fn selfBoundsIn(obj: *const DisplayObject, lib: ?*const library.Library) ?Rectangle {
    if (obj.kind == .morph_shape) return morphBounds(lib, obj.kind.morph_shape);
    return switch (obj.kind) {
        .shape => |s| s.bounds,
        .text => |t| t.bounds,
        .edit_text => |et| et.bounds,
        // A bitmap's box is its pixel size in twips, whether the pixels
        // came from a tag or from script.
        .bitmap => |b| pixelBox(b.width, b.height),
        .attached_bitmap => |b| pixelBox(b.data.width, b.data.height),
        // A video's box is the size its STREAM DECLARED, not the size of
        // whatever frame happens to be decoded — the tag is authoritative
        // and the frames are scaled into it. Without this a component
        // that sizes itself from `_width` divides by zero and lands on a
        // degenerate matrix, so nothing draws at all.
        .video => |id| videoBox(lib, id),
        // A button's geometry is entirely its state children, like a
        // clip's is its own. Morph shapes stay undecoded until M7 —
        // ruffle reports the start shape for a morph under
        // BoundsMode::Script, a known gap.
        .button, .morph_shape => null,
        // A clip's own geometry is whatever the drawing API put there
        // (ruffle MovieClip::self_bounds -> drawing.self_bounds).
        .clip => |mc| if (mc.drawing) |d| d.bounds else null,
    };
}

/// The declared frame size of a `DefineVideoStream`, in twips.
pub fn videoBox(lib: ?*const library.Library, id: u16) ?Rectangle {
    const l = lib orelse return null;
    const ch = l.getConstPtr(id) orelse return null;
    return switch (ch.*) {
        .video => |v| pixelBox(v.width, v.height),
        else => null,
    };
}

/// A w×h pixel image occupies w*20 × h*20 twips from the origin. A
/// zero-sized one has no box at all rather than a degenerate point.
fn pixelBox(w: u32, h: u32) ?Rectangle {
    if (w == 0 or h == 0) return null;
    return .{
        .xmin = 0,
        .ymin = 0,
        .xmax = @intCast(w * 20),
        .ymax = @intCast(h * 20),
    };
}

/// Bounds of `obj` including its children, everything pushed through `m`.
pub fn boundsWithTransform(obj: *const DisplayObject, m: Matrix) ?Rectangle {
    return boundsWithTransformIn(obj, m, null);
}

pub fn boundsWithTransformIn(
    obj: *const DisplayObject,
    m: Matrix,
    lib: ?*const library.Library,
) ?Rectangle {
    var acc: ?Rectangle = if (selfBoundsIn(obj, lib)) |b| m.transformRect(b) else null;
    for (childrenOf(obj)) |child| {
        const child_box = boundsWithTransformIn(child, m.mul(child.matrix), lib) orelse continue;
        acc = if (acc) |a| unionRect(a, child_box) else child_box;
    }
    return acc;
}

/// In the PARENT's coordinate space — `_width` / `_height` read this.
pub fn localBounds(obj: *const DisplayObject) ?Rectangle {
    return boundsWithTransform(obj, obj.matrix);
}

/// In the object's OWN space — setting `_width` / `_height` scales this.
pub fn ownBounds(obj: *const DisplayObject) ?Rectangle {
    return boundsWithTransform(obj, .identity);
}

pub fn ownBoundsIn(obj: *const DisplayObject, lib: ?*const library.Library) ?Rectangle {
    return boundsWithTransformIn(obj, .identity, lib);
}

/// The children a container contributes to bounds and hit tests. A
/// button's are its CURRENT state's — the hit records are a separate list
/// and never count towards `_width`.
pub fn childrenOf(obj: *const DisplayObject) []const *DisplayObject {
    return switch (obj.kind) {
        .clip => |mc| mc.children.items,
        .button => |b| b.container.children.items,
        else => &.{},
    };
}

pub fn unionRect(a: Rectangle, b: Rectangle) Rectangle {
    return .{
        .xmin = @min(a.xmin, b.xmin),
        .xmax = @max(a.xmax, b.xmax),
        .ymin = @min(a.ymin, b.ymin),
        .ymax = @max(a.ymax, b.ymax),
    };
}

pub fn contains(r: Rectangle, x: i32, y: i32) bool {
    return x >= r.xmin and x <= r.xmax and y >= r.ymin and y <= r.ymax;
}

pub fn intersects(a: Rectangle, b: Rectangle) bool {
    return a.xmin <= b.xmax and b.xmin <= a.xmax and a.ymin <= b.ymax and b.ymin <= a.ymax;
}

// --- hit testing -------------------------------------------------------------

/// Does `point` (STAGE space, twips) land inside `obj`'s bounding box?
/// `parent_to_global` is the matrix taking the object's PARENT space to
/// stage space, so the object's own matrix is applied here.
pub fn hitTestBounds(obj: *const DisplayObject, point: [2]i32, parent_to_global: Matrix) bool {
    return hitTestBoundsIn(obj, point, parent_to_global, null);
}

pub fn hitTestBoundsIn(
    obj: *const DisplayObject,
    point: [2]i32,
    parent_to_global: Matrix,
    lib: ?*const library.Library,
) bool {
    const box = boundsWithTransformIn(obj, parent_to_global.mul(obj.matrix), lib) orelse return false;
    return contains(box, point[0], point[1]);
}

/// Which objects a hit test is allowed to see (ruffle `HitTestOptions`).
/// The defaults are `AVM_HIT_TEST`, what `MovieClip.hitTest(x, y, true)`
/// asks for: masks are honoured, and an INVISIBLE clip is still hit —
/// only the mouse skips those, which is `MOUSE_PICK`.
pub const HitOptions = struct {
    /// An object used as a mask is not hit itself, and a masked object is
    /// hit only where its mask covers it.
    skip_mask: bool = true,
    skip_invisible: bool = false,
};

pub const MOUSE_PICK: HitOptions = .{ .skip_mask = true, .skip_invisible = true };

/// Shape-exact hit test: the point must land on actual drawn geometry, not
/// merely inside the bounding box.
///
/// Characters we cannot rasterise yet (bitmaps, morph shapes) fall back
/// to their bounding box.
/// `lib` is needed only to resolve a static text's FONT; pass null and
/// text falls back to its box.
pub fn hitTestShape(
    obj: *const DisplayObject,
    point: [2]i32,
    parent_to_global: Matrix,
    lib: ?*const library.Library,
) bool {
    return hitTestShapeOpts(obj, point, parent_to_global, lib, .{});
}

pub fn hitTestShapeOpts(
    obj: *const DisplayObject,
    point: [2]i32,
    parent_to_global: Matrix,
    lib: ?*const library.Library,
    opts: HitOptions,
) bool {
    // A mask is hit even while invisible — being a mask is what it is
    // FOR, so the flag says nothing about it (ruffle movie_clip.rs:2677).
    if (opts.skip_invisible and !obj.visible and obj.maskee == null) return false;
    // …and it is never hit AS ITSELF.
    if (opts.skip_mask and obj.maskee != null) return false;
    // A masked object exists only where its mask is. The mask lives
    // somewhere else in the tree, so it is tested from its own root.
    if (opts.skip_mask) {
        if (obj.mask) |m| {
            if (!hitTestShapeOpts(m, point, maskParentToGlobal(m), lib, .{
                .skip_mask = false,
                .skip_invisible = true,
            })) return false;
        }
    }
    const to_global = parent_to_global.mul(obj.matrix);
    const inv = to_global.invert() orelse return false;
    const local = inv.transformPoint(point[0], point[1]);
    switch (obj.kind) {
        // A video with no decoded frame has nothing to hit.
        .video => return false,
        .shape => |s| return shape_utils.shapeHitTest(s, .{ .x = local[0], .y = local[1] }, inv),
        .clip => |mc| {
            if (mc.drawing) |*d| {
                if (d.hitTest(.{ .x = local[0], .y = local[1] }, inv)) return true;
            }
            // A CLIPPING LAYER masks the depths below it, up to its
            // `clip_depth`: miss the layer and everything it covers is
            // skipped, hit it and they are all back in play. The layer
            // itself is never the answer (ruffle movie_clip.rs:2699).
            var clip_depth: i32 = 0;
            for (mc.children.items) |child| {
                if (child.clip_depth != 0) {
                    clip_depth = if (hitTestShapeOpts(child, point, to_global, lib, .{
                        .skip_mask = true,
                        .skip_invisible = true,
                    })) 0 else child.clip_depth;
                    continue;
                }
                if (child.depth < clip_depth) continue;
                if (hitTestShapeOpts(child, point, to_global, lib, opts)) return true;
            }
            return false;
        },
        // A button is hit through its HIT-AREA records when there are any,
        // and through what it is currently showing when there are not
        // (ruffle avm1_button.rs hit_area).
        .button => |b| {
            const list = if (b.hit_area.children.items.len > 0)
                b.hit_area.children.items
            else
                b.container.children.items;
            for (list) |child| {
                if (hitTestShapeOpts(child, point, to_global, lib, opts)) return true;
            }
            return false;
        },
        // STATIC text is hit GLYPH BY GLYPH: the gap between two letters
        // is not part of it, so a click there falls through to whatever
        // is behind (ruffle text.rs:191-257). Without a library to
        // resolve the font, the box has to stand in.
        .text => |txt| {
            // The gate is the box in STAGE space — the axis-aligned one
            // around the rotated text, which is looser than the rotated
            // box itself and is what ruffle tests (`world_bounds`).
            const box = selfBounds(obj) orelse return false;
            if (!contains(to_global.transformRect(box), point[0], point[1])) return false;
            const l = lib orelse return true;
            // "Advanced text rendering" — a CSMTextSettings tag with the
            // flashtype bit — stops the glyph walk before it starts: the
            // whole box is hit, gaps and all (ruffle text.rs:200).
            if (l.csm.get(txt.id)) |c| {
                if (c.use_advanced_rendering) return true;
            }
            // The tag's own matrix wraps the run, so the point comes back
            // out of it before the per-glyph walk.
            const inv_text = txt.matrix.invert() orelse return false;
            const p = inv_text.transformPoint(local[0], local[1]);
            var w = text_mod.Walker.init(txt, l);
            while (w.next()) |g| {
                const gi = g.matrix.invert() orelse continue;
                const gp = gi.transformPoint(p[0], p[1]);
                const gs = swf.font_text.glyphShape(g.glyph);
                if (shape_utils.shapeHitTest(&gs, .{ .x = gp[0], .y = gp[1] }, inv)) return true;
            }
            return false;
        },
        // A MORPH is gated on its interpolated box and then tested
        // against the tween's own outline, interpolated edge by edge as
        // the walk reaches it (ruffle morph_shape.rs:144).
        .morph_shape => |id| {
            const box = engineSelfBounds(obj, lib) orelse return false;
            if (!contains(box, local[0], local[1])) return false;
            const m = morphData(lib, id) orelse return true;
            return shape_utils.morphHitTest(m, obj.ratio, .{ .x = local[0], .y = local[1] }, inv);
        },
        // A field's box IS its geometry — Flash hit-tests the rectangle,
        // not the glyphs. A bitmap is the same: its box, not its opaque
        // pixels.
        .edit_text, .bitmap, .attached_bitmap => {
            const box = engineSelfBounds(obj, lib) orelse return false;
            return contains(box, local[0], local[1]);
        },
    }
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "union, empty containers, and nested child transforms" {
    const movie_clip = @import("movie_clip.zig");

    try testing.expectEqual(
        Rectangle{ .xmin = -5, .xmax = 10, .ymin = 0, .ymax = 8 },
        unionRect(
            .{ .xmin = 0, .xmax = 10, .ymin = 0, .ymax = 3 },
            .{ .xmin = -5, .xmax = 4, .ymin = 2, .ymax = 8 },
        ),
    );

    // An empty clip has no bounds at all — not a zero-sized box.
    var empty_clip = movie_clip.MovieClip.init(&.{});
    var empty: DisplayObject = .{
        .character_id = 0,
        .depth = 1,
        .kind = .{ .clip = &empty_clip },
        .owns_kind = false,
    };
    try testing.expectEqual(@as(?Rectangle, null), localBounds(&empty));

    // A clip containing one 100x40-twip shape, the child offset and the
    // parent scaled 2x: local bounds see both transforms, own bounds only
    // the child's.
    const shape: swf.shape.Shape = .{
        .version = 1,
        .id = 1,
        .bounds = .{ .xmin = 0, .xmax = 100, .ymin = 0, .ymax = 40 },
        .edge_bounds = .{ .xmin = 0, .xmax = 100, .ymin = 0, .ymax = 40 },
        .styles = .{ .fills = &.{}, .lines = &.{} },
        .records = &.{},
    };
    var child: DisplayObject = .{
        .character_id = 1,
        .depth = 1,
        .matrix = .{ .tx = 20, .ty = 0 },
        .kind = .{ .shape = &shape },
        .owns_kind = false,
    };
    var parent_clip = movie_clip.MovieClip.init(&.{});
    // Children here are stack objects, so free only the list itself.
    defer parent_clip.children.deinit(testing.allocator);
    try parent_clip.children.append(testing.allocator, &child);
    var parent: DisplayObject = .{
        .character_id = 0,
        .depth = 1,
        .matrix = .{ .a = 2, .d = 2 },
        .kind = .{ .clip = &parent_clip },
        .owns_kind = false,
    };
    const own = ownBounds(&parent).?;
    try testing.expectEqual(@as(i32, 20), own.xmin);
    try testing.expectEqual(@as(i32, 120), own.xmax);
    const local = localBounds(&parent).?;
    try testing.expectEqual(@as(i32, 40), local.xmin);
    try testing.expectEqual(@as(i32, 240), local.xmax);
    try testing.expectEqual(@as(i32, 80), local.height());
}
