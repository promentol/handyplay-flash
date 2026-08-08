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

/// The three index queries all report -1 until there is a focused TEXT
/// FIELD to ask (M4-D); ruffle returns exactly that when the focus is not
/// an EditText, so the stub is the real answer for every other case.
fn getBeginIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .number = -1 };
}

fn getEndIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .number = -1 };
}

fn getCaretIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .number = -1 };
}

/// Needs a focused EditText to do anything (M4-D).
fn setSelection(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
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
