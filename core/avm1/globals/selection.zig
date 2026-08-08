//! The `Selection` singleton: who has focus, and (with EditText, in M4-D)
//! what is selected inside it.
//!
//! It is a broadcaster like Key and Mouse — content adds a listener and
//! hears `onSetFocus(oldFocus, newFocus)` on every focus change. The
//! tracker itself lives in avm1/stage_object.zig, because moving the focus
//! runs handlers ON DISPLAY OBJECTS.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/selection.rs and
//! core/src/focus_tracker.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const stage_object = @import("../stage_object.zig");
const activation = @import("../activation.zig");
const singletons = @import("singletons.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const frozen = decl.frozen;

pub fn install(vm: *Vm) !void {
    const sel = try vm.objects.create();
    vm.objects.get(sel).proto = .{ .object = vm.object_proto };
    vm.selection_object = sel;
    try singletons.makeBroadcaster(vm, sel);
    try method(vm, sel, "getBeginIndex", getBeginIndex, frozen);
    try method(vm, sel, "getEndIndex", getEndIndex, frozen);
    try method(vm, sel, "getCaretIndex", getCaretIndex, frozen);
    try method(vm, sel, "getFocus", getFocus, frozen);
    try method(vm, sel, "setFocus", setFocus, frozen);
    try method(vm, sel, "setSelection", setSelection, frozen);
    try vm.objects.putWithAttrs(vm.globals, S("Selection"), .{ .object = sel }, decl.hidden, false);
}

/// All three index queries answer -1 unless the focus is a TEXT FIELD
/// with a selection. AVM1 clears a field's selection when it loses focus,
/// so an unfocused field has none even if it was selected a moment ago.
fn getBeginIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ this, args };
    const et = stage_object.focusedField(vmOf(p)) orelse return .{ .number = -1 };
    const sel = et.selection orelse return .{ .number = -1 };
    return .{ .number = @floatFromInt(sel.start()) };
}

fn getEndIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ this, args };
    const et = stage_object.focusedField(vmOf(p)) orelse return .{ .number = -1 };
    const sel = et.selection orelse return .{ .number = -1 };
    return .{ .number = @floatFromInt(sel.end()) };
}

/// The CARET is `to` — where the selection ended, which may be either
/// edge depending on which way it was dragged.
fn getCaretIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ this, args };
    const et = stage_object.focusedField(vmOf(p)) orelse return .{ .number = -1 };
    const sel = et.selection orelse return .{ .number = -1 };
    return .{ .number = @floatFromInt(sel.to) };
}

/// `setSelection(start, end)` on the focused field. A missing `end` means
/// "to the end"; both clamp at zero below and at the text length above.
fn setSelection(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const et = stage_object.focusedField(vm) orelse return .undefined_value;
    const start = @max(value_mod.toInt32(try vm.toNumber(args[0])), 0);
    const end = if (args.len > 1)
        @max(value_mod.toInt32(try vm.toNumber(args[1])), 0)
    else
        std.math.maxInt(i32);
    et.setSelection(.{ .from = @intCast(start), .to = @intCast(end) });
    return .undefined_value;
}

fn getFocus(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ this, args };
    return stage_object.focusPath(vmOf(p));
}

/// `setFocus(target)` — an object or a target path. Returns whether the
/// focus actually moved there: a missing argument is false, null clears
/// the focus and is true, and an object that cannot take focus is false
/// (ruffle globals/selection.rs set_focus).
fn setFocus(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len == 0) return .{ .boolean = false };
    const v = args[0];
    if (v == .undefined_value or v == .null_value) {
        try stage_object.setFocus(vm, 0);
        return .{ .boolean = true };
    }
    // 0 anchors the path at the CALLER's target clip, which is what
    // ruffle's `target_clip_or_root` start does.
    const t = try activation.targetFromNative(vm, 0, v) orelse return .{ .boolean = false };
    const handle = try stage_object.handleOf(vm, t.obj);
    if (!stage_object.isFocusable(vm, handle)) return .{ .boolean = false };
    try stage_object.setFocus(vm, handle);
    return .{ .boolean = true };
}
