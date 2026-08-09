//! `TextField.variable` — the two-way link between a field and a timeline
//! variable.
//!
//! The binding is stored on the TARGET object, not on the field: a write
//! to `_root.myVar` has only the target in hand, and it has to find every
//! field watching that name. The field remembers who it bound to so the
//! link can be torn down again.
//!
//! Both directions exist and they are NOT symmetric:
//!
//!   - variable → field goes through the ordinary property-write path and
//!     assigns the field's HTML text;
//!   - field → variable runs on every text write, behind a re-entrancy
//!     guard, and CAN fire a virtual setter on the target — the opposite
//!     direction cannot.
//!
//! A field whose path does not resolve yet joins the UNBOUND list and is
//! retried whenever anything else binds, which is how a field placed
//! before its target clip still ends up connected.
//!
//! Reference: reference/ruffle/core/src/display_object/edit_text.rs
//! (`try_bind_text_field_variable`, `propagate_text_binding`) and
//! core/src/display_object.rs (`Avm1TextFieldBinding`).

const std = @import("std");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");
const activation = @import("activation.zig");
const stage_object = @import("stage_object.zig");
const display_object = @import("../display/display_object.zig");
const movie_clip = @import("../display/movie_clip.zig");
const edit_text = @import("../display/edit_text.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const DisplayObject = display_object.DisplayObject;
const S = strings.ascii;

/// Fields whose `variable` has not resolved yet. Owned by the VM's arena
/// the way the rest of the interpreter's side tables are.
pub const Unbound = std.ArrayList(*DisplayObject);

/// Bind `obj`'s variable if it can be resolved. Returns false when the
/// path does not exist yet — the caller then parks the field.
///
/// `set_initial` is true only at creation: the property WINS if it
/// already exists (the field takes its text), otherwise the field's own
/// non-empty text seeds the property.
pub fn bind(vm: *Vm, obj: *DisplayObject, set_initial: bool) !bool {
    if (obj.kind != .edit_text) return true;
    const et = obj.kind.edit_text;
    const path = et.variable orelse return true;
    if (et.bound_to != null) return true;

    const target_clip = timelineOf(obj) orelse return false;
    const start = try stage_object.clipObject(vm, target_clip);
    const ctx = stage_object.displayCtxOf(vm) orelse return false;
    const root = if (vm.root_object == .object) vm.root_object.object else start;

    const hit = try activation.Activation.resolveVariablePath(vm, root, start, path) orelse
        return false;

    if (set_initial) {
        if (vm.objects.getChained(hit.obj, hit.name, vm.case_sensitive)) |v| {
            const s = try vm.toStringValue(v);
            try setBound(vm, ctx, et, s);
        } else if (et.text.items.len > 0) {
            // Seeding is skipped for an EMPTY field — and an HTML field is
            // often born holding an empty `<p>`, which does not count as
            // empty.
            const text = try vm.arena().dupe(u16, et.text.items);
            try vm.setProperty(hit.obj, hit.name, .{ .string = text }, .{ .object = hit.obj });
        }
    }

    // Only a DISPLAY object can carry a binding: a plain object's writes
    // are never notified, so the field stays unbound against one.
    const t = stage_object.targetOf(vm, hit.obj) orelse return false;
    et.bound_to = @ptrCast(t.obj);
    try t.obj.text_bindings.append(ctx.gpa, .{
        .field = obj,
        .name = try ctx.gpa.dupe(u16, hit.name),
    });
    return true;
}

/// A field inside a button binds against the button's TIMELINE, not the
/// button (ruffle walks past every avm1 button parent).
fn timelineOf(obj: *DisplayObject) ?*movie_clip.MovieClip {
    var parent = obj.parent;
    while (parent) |c| {
        if (c.owner_button) |b| {
            parent = b.parent;
            continue;
        }
        return c;
    }
    return null;
}

/// Retry everything on the unbound list — called whenever a new field
/// appears, because the object it was waiting for may have just arrived.
pub fn retryUnbound(vm: *Vm) !void {
    var i: usize = 0;
    while (i < vm.unbound_text_fields.items.len) {
        const field = vm.unbound_text_fields.items[i];
        // A field that has since been removed drops off the list.
        const gone = field.removed or field.kind != .edit_text;
        if (gone or try bind(vm, field, false)) {
            _ = vm.unbound_text_fields.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

/// A field has just been placed: make it a broadcaster, bind it, and give
/// every other waiting field another chance.
pub fn onFieldCreated(vm: *Vm, obj: *DisplayObject) !void {
    if (!try bind(vm, obj, true)) {
        try vm.unbound_text_fields.append(vm.arena(), obj);
    }
    try retryUnbound(vm);
}

/// The field's text changed from the script side — push it out to the
/// variable. Re-entrant writes are dropped rather than looping.
pub fn propagate(vm: *Vm, obj: *DisplayObject) !void {
    if (obj.kind != .edit_text) return;
    const et = obj.kind.edit_text;
    if (et.firing_binding) return;
    const path = et.variable orelse return;
    const parent = timelineOf(obj) orelse return;
    et.firing_binding = true;
    defer et.firing_binding = false;

    const start = try stage_object.clipObject(vm, parent);
    const root = if (vm.root_object == .object) vm.root_object.object else start;
    const hit = try activation.Activation.resolveVariablePath(vm, root, start, path) orelse return;
    const text = try vm.arena().dupe(u16, et.text.items);
    try vm.setProperty(hit.obj, hit.name, .{ .string = text }, .{ .object = hit.obj });
}

/// A property was written on a display object: update any field bound to
/// that name. Case folding follows the movie's, like every other lookup.
pub fn notify(vm: *Vm, target: *DisplayObject, name: strings.AvmString, v: Value) !void {
    if (target.text_bindings.items.len == 0) return;
    const ctx = stage_object.displayCtxOf(vm) orelse return;
    for (target.text_bindings.items) |b| {
        const same = if (vm.case_sensitive)
            strings.eql(b.name, name)
        else
            strings.eqlIgnoreCase(b.name, name);
        if (!same) continue;
        if (b.field.kind != .edit_text) continue;
        const et = b.field.kind.edit_text;
        // The guard is the FIELD's: a write that came from this same
        // field's propagate must not bounce back.
        if (et.firing_binding) continue;
        try setBound(vm, ctx, et, try vm.toStringValue(v));
    }
}

/// A write through the BINDING is an HTML write: an html field parses the
/// markup, a plain one takes it verbatim (ruffle `set_html_text`). The
/// early return on an unchanged value is ruffle's too, and observable —
/// not every set of spans round-trips through HTML, so re-parsing an
/// identical string can still change the field.
fn setBound(
    vm: *Vm,
    ctx: *movie_clip.Context,
    et: *edit_text.EditText,
    s: []const u16,
) !void {
    const current = et.htmlText(vm.arena()) catch null;
    if (current) |c| {
        if (strings.eql(c, s)) return;
    }
    try et.setHtml(ctx.gpa, s, vm.swf_version);
}

/// Drop `field`'s link, wherever it points, and take it off the unbound
/// list. Ruffle's `clear_binding` plus the `retain` beside it.
pub fn clearBinding(vm: *Vm, field: *DisplayObject) void {
    const ctx = stage_object.displayCtxOf(vm) orelse return;
    if (field.kind == .edit_text) {
        const et = field.kind.edit_text;
        if (et.bound_to) |ptr| {
            const target: *DisplayObject = @ptrCast(@alignCast(ptr));
            var i: usize = 0;
            while (i < target.text_bindings.items.len) {
                if (target.text_bindings.items[i].field == field) {
                    ctx.gpa.free(target.text_bindings.items[i].name);
                    _ = target.text_bindings.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
            et.bound_to = null;
        }
    }
    var i: usize = 0;
    while (i < vm.unbound_text_fields.items.len) {
        if (vm.unbound_text_fields.items[i] == field) {
            _ = vm.unbound_text_fields.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

/// The object is leaving the display list: every field bound to it goes
/// back on the unbound list rather than pointing at freed memory.
pub fn unregister(vm: *Vm, target: *DisplayObject) !void {
    if (target.text_bindings.items.len == 0) return;
    const ctx = stage_object.displayCtxOf(vm) orelse return;
    for (target.text_bindings.items) |b| {
        if (b.field.kind == .edit_text) b.field.kind.edit_text.bound_to = null;
        if (!b.field.removed) try vm.unbound_text_fields.append(vm.arena(), b.field);
        ctx.gpa.free(b.name);
    }
    target.text_bindings.clearRetainingCapacity();
}
