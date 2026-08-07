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
        // Buttons need their state records (M4-C) and bitmaps their decoded
        // size (M4-E); morph shapes stay undecoded until M7. Ruffle reports
        // the start shape for a morph under BoundsMode::Script — a known gap.
        .button, .bitmap, .morph_shape => null,
        .clip => null,
    };
}

/// Bounds of `obj` including its children, everything pushed through `m`.
pub fn boundsWithTransform(obj: *const DisplayObject, m: Matrix) ?Rectangle {
    var acc: ?Rectangle = if (selfBounds(obj)) |b| m.transformRect(b) else null;
    if (obj.kind == .clip) {
        for (obj.kind.clip.children.items) |child| {
            const child_box = boundsWithTransform(child, m.mul(child.matrix)) orelse continue;
            acc = if (acc) |a| unionRect(a, child_box) else child_box;
        }
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

pub fn unionRect(a: Rectangle, b: Rectangle) Rectangle {
    return .{
        .xmin = @min(a.xmin, b.xmin),
        .xmax = @max(a.xmax, b.xmax),
        .ymin = @min(a.ymin, b.ymin),
        .ymax = @max(a.ymax, b.ymax),
    };
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
