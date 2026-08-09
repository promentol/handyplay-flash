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
pub fn selfBounds(obj: *const DisplayObject) ?Rectangle {
    return switch (obj.kind) {
        .shape => |s| s.bounds,
        .text => |t| t.bounds,
        .edit_text => |et| et.bounds,
        // A bitmap's box is its pixel size in twips, whether the pixels
        // came from a tag or from script.
        .bitmap => |b| pixelBox(b.width, b.height),
        .attached_bitmap => |b| pixelBox(b.data.width, b.data.height),
        // A button's geometry is entirely its state children, like a
        // clip's is its own. Morph shapes stay undecoded until M7 —
        // ruffle reports the start shape for a morph under
        // BoundsMode::Script, a known gap.
        .button, .morph_shape, .video => null,
        // A clip's own geometry is whatever the drawing API put there
        // (ruffle MovieClip::self_bounds -> drawing.self_bounds).
        .clip => |mc| if (mc.drawing) |d| d.bounds else null,
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
    var acc: ?Rectangle = if (selfBounds(obj)) |b| m.transformRect(b) else null;
    for (childrenOf(obj)) |child| {
        const child_box = boundsWithTransform(child, m.mul(child.matrix)) orelse continue;
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
    const box = boundsWithTransform(obj, parent_to_global.mul(obj.matrix)) orelse return false;
    return contains(box, point[0], point[1]);
}

/// Shape-exact hit test: the point must land on actual drawn geometry, not
/// merely inside the bounding box. Invisible objects never hit — Flash's
/// AVM_HIT_TEST options skip them (ruffle `HitTestOptions::AVM_HIT_TEST`
/// sets SKIP_INVISIBLE).
///
/// Characters we cannot rasterise yet (buttons, bitmaps, morph shapes)
/// fall back to their bounding box, which is `null` for those kinds today
/// and so reports a miss — the same answer the renderer gives.
/// `lib` is needed only to resolve a static text's FONT; pass null and
/// text falls back to its box.
pub fn hitTestShape(
    obj: *const DisplayObject,
    point: [2]i32,
    parent_to_global: Matrix,
    lib: ?*const library.Library,
) bool {
    if (!obj.visible) return false;
    const to_global = parent_to_global.mul(obj.matrix);
    const inv = to_global.invert() orelse return false;
    const local = inv.transformPoint(point[0], point[1]);
    switch (obj.kind) {
        // A video with no decoded frame has nothing to hit.
        .video => return false,
        .shape => |s| return shape_utils.shapeHitTest(s, .{ .x = local[0], .y = local[1] }, to_global),
        .clip => |mc| {
            if (mc.drawing) |*d| {
                if (d.hitTest(.{ .x = local[0], .y = local[1] }, to_global)) return true;
            }
            for (mc.children.items) |child| {
                if (hitTestShape(child, point, to_global, lib)) return true;
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
                if (hitTestShape(child, point, to_global, lib)) return true;
            }
            return false;
        },
        // STATIC text is hit GLYPH BY GLYPH: the gap between two letters
        // is not part of it, so a click there falls through to whatever
        // is behind (ruffle text.rs:191-257). Without a library to
        // resolve the font, the box has to stand in.
        .text => |txt| {
            const box = selfBounds(obj) orelse return false;
            if (!contains(box, local[0], local[1])) return false;
            const l = lib orelse return true;
            // The tag's own matrix wraps the run, so the point comes back
            // out of it before the per-glyph walk.
            const inv_text = txt.matrix.invert() orelse return false;
            const p = inv_text.transformPoint(local[0], local[1]);
            var w = text_mod.Walker.init(txt, l);
            while (w.next()) |g| {
                const gi = g.matrix.invert() orelse continue;
                const gp = gi.transformPoint(p[0], p[1]);
                const gs = swf.font_text.glyphShape(g.glyph);
                if (shape_utils.shapeHitTest(&gs, .{ .x = gp[0], .y = gp[1] }, to_global)) return true;
            }
            return false;
        },
        // A field's box IS its geometry — Flash hit-tests the rectangle,
        // not the glyphs. A bitmap is the same: its box, not its opaque
        // pixels. Morph shapes land in M7.
        .edit_text, .bitmap, .attached_bitmap, .morph_shape => {
            const box = selfBounds(obj) orelse return false;
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
