//! Tab ordering: the list the Tab key walks, and the rule that orders it.
//!
//! Two orders, and which one applies is decided by the CONTENT: the moment
//! any object in the tree carries a `tabIndex`, the order becomes CUSTOM
//! and everything without an index drops out of it entirely. Otherwise the
//! order is AUTOMATIC — a spatial sweep, not tree order.
//!
//! Reference: reference/ruffle/core/src/focus_tracker.rs (TabOrder,
//! CustomTabOrdering, AutomaticTabOrdering) and
//! display_object/container.rs `fill_tab_order`.

const std = @import("std");
const swf = @import("../swf/swf.zig");
const movie_clip = @import("movie_clip.zig");
const display_object = @import("display_object.zig");
const bounds = @import("bounds.zig");
const mouse = @import("mouse.zig");

const MovieClip = movie_clip.MovieClip;
const DisplayObject = display_object.DisplayObject;
const Context = movie_clip.Context;
const Error = movie_clip.Error;

pub const Order = struct {
    items: std.ArrayList(*DisplayObject) = .empty,
    /// Set once any member has a tabIndex; the list then holds ONLY
    /// indexed objects.
    is_custom: bool = false,

    pub fn deinit(self: *Order, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }

    fn add(self: *Order, gpa: std.mem.Allocator, obj: *DisplayObject) !void {
        const indexed = obj.tab_index != null;
        if (indexed and !self.is_custom) {
            // The first indexed object switches the whole list over and
            // evicts everyone without an index (ruffle add_object).
            self.is_custom = true;
            var kept: std.ArrayList(*DisplayObject) = .empty;
            for (self.items.items) |o| {
                if (o.tab_index != null) try kept.append(gpa, o);
            }
            self.items.deinit(gpa);
            self.items = kept;
        }
        if (indexed or !self.is_custom) try self.items.append(gpa, obj);
    }
};

/// Collect and sort the whole tree's tabbable objects.
pub fn build(ctx: *Context, root: *DisplayObject, gpa: std.mem.Allocator) Error!Order {
    var order: Order = .{};
    try fill(ctx, root, &order, gpa);
    sort(&order);
    return order;
}

/// Render-list order, depth first, children after their parent.
fn fill(ctx: *Context, obj: *DisplayObject, order: *Order, gpa: std.mem.Allocator) Error!void {
    if (!tabChildren(ctx, obj)) return;
    for (bounds.childrenOf(obj)) |child| {
        // An invisible object takes its whole subtree out of the order.
        if (!child.visible) continue;
        if (isTabbable(ctx, child)) try order.add(gpa, child);
        try fill(ctx, child, order, gpa);
    }
}

/// `tabChildren`, defaulting to true — false excludes the entire subtree.
fn tabChildren(ctx: *Context, obj: *DisplayObject) bool {
    return ctx.boolProperty(obj, "tabChildren") orelse true;
}

/// `tabEnabled`, whose DEFAULT depends on the kind: a button always, a
/// clip only in button mode or when it carries a tabIndex, a text field
/// only when it is editable.
pub fn isTabbable(ctx: *Context, obj: *DisplayObject) bool {
    // An explicit `tabEnabled` still cannot put a NON-EDITABLE field in
    // the order (ruffle is_tabbable ANDs the two).
    if (obj.kind == .edit_text and obj.kind.edit_text.read_only) return false;
    if (ctx.boolProperty(obj, "tabEnabled")) |b| return b;
    return switch (obj.kind) {
        .button => true,
        .clip => |mc| mouse.isButtonMode(ctx, mc) or obj.tab_index != null,
        // A text field is tabbable only when it is EDITABLE — a dynamic
        // field stays out of the order even with tabEnabled set
        // (ruffle edit_text.rs is_tabbable/tab_enabled_default, and
        // corpus tab_ordering_tabbable's table).
        .edit_text => |et| !et.read_only,
        else => false,
    };
}

fn sort(order: *Order) void {
    if (order.is_custom) {
        std.sort.insertion(*DisplayObject, order.items.items, {}, lessByIndex);
        return;
    }
    std.sort.insertion(*DisplayObject, order.items.items, {}, lessBySweep);
    // Objects that share a key are dropped, keeping the first — FP really
    // does skip them, however far apart they are.
    var out: usize = 0;
    var i: usize = 0;
    while (i < order.items.items.len) : (i += 1) {
        if (out > 0 and sweepKey(order.items.items[i]) == sweepKey(order.items.items[out - 1])) continue;
        order.items.items[out] = order.items.items[i];
        out += 1;
    }
    order.items.shrinkRetainingCapacity(out);
}

fn lessByIndex(_: void, a: *DisplayObject, b: *DisplayObject) bool {
    return (a.tab_index orelse 0) < (b.tab_index orelse 0);
}

/// The automatic order depends ONLY on the top-left corner of the object's
/// world bounds, ranked by `6y + x`: the next object tabbed to is the next
/// one touched by the line `y = -(x - p)/6`. Not "left to right, top to
/// bottom" — the next object to the right may sit slightly higher and
/// still come first (ruffle AutomaticTabOrdering).
fn sweepKey(obj: *DisplayObject) i64 {
    const box = bounds.boundsWithTransform(obj, worldMatrix(obj)) orelse
        return std.math.maxInt(i64);
    return @as(i64, box.ymin) * 6 + @as(i64, box.xmin);
}

fn lessBySweep(_: void, a: *DisplayObject, b: *DisplayObject) bool {
    return sweepKey(a) < sweepKey(b);
}

/// The object's own space → stage space. `DisplayObject.parent` is the
/// timeline that holds it, so the walk is up the placements.
fn worldMatrix(obj: *DisplayObject) swf.reader.Matrix {
    var m = obj.matrix;
    var parent = obj.parent;
    while (parent) |p| {
        const placement = p.placement orelse break;
        m = placement.matrix.mul(m);
        parent = p.parent;
    }
    return m;
}

/// The object after `current`, wrapping around. Null when nothing is
/// tabbable at all.
pub fn next(order: *const Order, current: ?*DisplayObject, reverse: bool) ?*DisplayObject {
    const items = order.items.items;
    if (items.len == 0) return null;
    const first = if (reverse) items[items.len - 1] else items[0];
    const cur = current orelse return first;
    for (items, 0..) |o, i| {
        if (o != cur) continue;
        if (reverse) {
            return if (i == 0) first else items[i - 1];
        }
        return if (i + 1 < items.len) items[i + 1] else first;
    }
    return first;
}
