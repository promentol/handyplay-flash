//! `ContextMenu` and `ContextMenuItem`.
//!
//! There is no menu to show — these classes exist so that content can
//! BUILD one, read it back and copy it. Everything is ordinary
//! properties on the instance: the constructor writes them, `copy`
//! reads them and constructs a fresh object from what it found. No
//! state is hidden anywhere, which is why the corpus can rewrite any of
//! them and watch `copy` carry the change across.

const std = @import("std");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const decl = @import("decl.zig");

const Vm = runtime.Vm;
const Value = runtime.Value;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;
const method = decl.method;
const hidden = decl.hidden;
const arg = decl.arg;

fn vmOf(p: *anyopaque) *Vm {
    return @ptrCast(@alignCast(p));
}

/// The eight built-in menu entries, in the order the constructor writes
/// them — `for..in` reports the reverse.
const BUILT_IN = [_][]const u8{
    "print", "forward_back", "rewind", "loop", "play", "quality", "zoom", "save",
};

pub fn install(vm: *Vm) !void {
    const item_proto = try vm.objects.create();
    vm.objects.get(item_proto).proto = .{ .object = vm.object_proto };
    try method(vm, item_proto, "copy", itemCopy, hidden);
    vm.contextmenuitem_ctor = try decl.class(vm, "ContextMenuItem", ctorItem, item_proto, .{ .dont_enum = true });

    const menu_proto = try vm.objects.create();
    vm.objects.get(menu_proto).proto = .{ .object = vm.object_proto };
    try method(vm, menu_proto, "copy", menuCopy, hidden);
    try method(vm, menu_proto, "hideBuiltInItems", hideBuiltInItems, hidden);
    vm.contextmenu_ctor = try decl.class(vm, "ContextMenu", ctorMenu, menu_proto, .{ .dont_enum = true });
}

/// `new ContextMenuItem(caption, onSelect, separatorBefore, enabled,
/// visible)`. The three flags default to false, true, true — and the
/// callback is only written when one was PASSED, so a menu item with no
/// handler inherits whatever the prototype has.
fn ctorItem(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const h = this.object;
    const caption = try vm.toStringThrowing(arg(args, 0));
    try vm.setProperty(h, S("caption"), .{ .string = caption }, this);
    if (args.len > 1) try vm.setProperty(h, S("onSelect"), args[1], this);
    try vm.setProperty(h, S("separatorBefore"), .{ .boolean = flag(vm, args, 2, false) }, this);
    try vm.setProperty(h, S("enabled"), .{ .boolean = flag(vm, args, 3, true) }, this);
    try vm.setProperty(h, S("visible"), .{ .boolean = flag(vm, args, 4, true) }, this);
    return .undefined_value;
}

fn flag(vm: *Vm, args: []const Value, i: usize, dflt: bool) bool {
    if (i >= args.len) return dflt;
    return value_mod.toBoolean(args[i], vm.swf_version);
}

fn itemCopy(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const h = this.object;
    const caption = try vm.toStringThrowing(try vm.getProperty(h, S("caption"), this));
    const on_select = try vm.getProperty(h, S("onSelect"), this);
    const sep = value_mod.toBoolean(try vm.getProperty(h, S("separatorBefore"), this), vm.swf_version);
    const enabled = value_mod.toBoolean(try vm.getProperty(h, S("enabled"), this), vm.swf_version);
    const visible = value_mod.toBoolean(try vm.getProperty(h, S("visible"), this), vm.swf_version);
    return vm.construct(.{ .object = vm.contextmenuitem_ctor }, &.{
        .{ .string = caption },
        on_select,
        .{ .boolean = sep },
        .{ .boolean = enabled },
        .{ .boolean = visible },
    });
}

/// `new ContextMenu(onSelect)` — plus `builtInItems`, all eight true,
/// and an empty `customItems` array.
fn ctorMenu(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const h = this.object;
    try vm.setProperty(h, S("onSelect"), arg(args, 0), this);
    const built = try vm.newObject();
    inline for (BUILT_IN) |name| {
        try vm.setProperty(built, S(name), .{ .boolean = true }, .{ .object = built });
    }
    try vm.setProperty(h, S("builtInItems"), .{ .object = built }, this);
    const items = try vm.newArray();
    try vm.setProperty(h, S("customItems"), .{ .object = items }, this);
    return .undefined_value;
}

fn menuCopy(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const h = this.object;
    const on_select = try vm.getProperty(h, S("onSelect"), this);
    const copy = try vm.construct(.{ .object = vm.contextmenu_ctor }, &.{on_select});
    if (copy != .object) return copy;

    const src = try vm.getProperty(h, S("builtInItems"), this);
    const dst = try vm.getProperty(copy.object, S("builtInItems"), copy);
    if (src == .object and dst == .object) {
        // `save` first, then the rest — ruffle's order, which decides
        // the copy's enumeration.
        inline for (.{ "save", "zoom", "quality", "play", "loop", "rewind", "forward_back", "print" }) |name| {
            const v = try vm.getProperty(src.object, S(name), src);
            const b = value_mod.toBoolean(v, vm.swf_version);
            try vm.setProperty(dst.object, S(name), .{ .boolean = b }, dst);
        }
    }

    const items = try vm.getProperty(h, S("customItems"), this);
    const items_copy = try vm.getProperty(copy.object, S("customItems"), copy);
    if (items == .object and items_copy == .object) {
        const n = vm.arrayLength(items.object);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            var wide: [12]u16 = undefined;
            for (key, 0..) |c, k| wide[k] = c;
            const name = wide[0..key.len];
            const v = try vm.getProperty(items.object, name, items);
            try vm.arraySet(items_copy.object, i, v);
        }
    }
    return copy;
}

fn hideBuiltInItems(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const built = try vm.getProperty(this.object, S("builtInItems"), this);
    if (built != .object) return .undefined_value;
    // NOT `save`: Flash leaves it alone.
    inline for (.{ "zoom", "quality", "play", "loop", "rewind", "forward_back", "print" }) |name| {
        try vm.setProperty(built.object, S(name), .{ .boolean = false }, built);
    }
    return .undefined_value;
}
