//! Mark-sweep over the object table (ADR D2).
//!
//! Objects are u32 handles into a slot table and nothing ever freed them,
//! so a movie that makes objects in an `onEnterFrame` grew the table
//! forever: `AntiMosquito` reached **448,996 slots in sixty frames**
//! (Snake, which makes almost none, sits at 1,882). That is a leak while
//! merely playing, and it is what made its save-state 36 MB — which is
//! how it was finally noticed.
//!
//! The design is the one the ADR called for. Roots are everything the
//! engine itself can still reach: the globals and prototypes, the operand
//! stack and registers, the display tree's script objects, timers, the
//! class registry, focus and drag, the broadcaster singletons. Marking
//! walks protos, properties (values AND accessors), scope chains,
//! interfaces, watchers and the handles inside native payloads. Sweeping
//! empties the unreachable slots and puts their indices on a FREE LIST,
//! so the table stops growing instead of merely stopping leaking.
//!
//! **The risk is a missed root**, which would recycle a live object and
//! alias it to a new one. That is why this runs only at a frame boundary
//! — no activation live, the stack cleared — and why the corpus is the
//! real test: 679 trace dirs and 195 save/restore dirs all have to stay
//! green.

const std = @import("std");
const runtime = @import("runtime.zig");
const object_mod = @import("object.zig");
const value_mod = @import("value.zig");

const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const Value = value_mod.Value;

pub const Stats = struct {
    live: u32 = 0,
    freed: u32 = 0,
    slots: u32 = 0,
};

/// One collection. `extra` carries the roots the VM cannot see for
/// itself — the display tree's `avm_object` handles, which the Player
/// gathers because it owns the tree.
pub fn collect(vm: *Vm, extra: []const ObjectHandle) Stats {
    const n = vm.objects.slots.items.len;
    if (n == 0) return .{};

    const gpa = vm.gpa;
    const marks = gpa.alloc(bool, n) catch return .{ .slots = @intCast(n) };
    defer gpa.free(marks);
    @memset(marks, false);

    var stack: std.ArrayList(ObjectHandle) = .empty;
    defer stack.deinit(gpa);

    var m: Marker = .{ .vm = vm, .marks = marks, .stack = &stack, .gpa = gpa };
    m.roots(extra);
    m.drain();

    // Sweep. The free list is REBUILT, never appended to: an index that
    // was already on it is still unreachable, so appending would put it
    // there twice and hand the same slot to two different `create`s.
    vm.objects.free_list.clearRetainingCapacity();
    var stats: Stats = .{ .slots = @intCast(n) };
    for (marks, 0..) |live, i| {
        if (live) {
            stats.live += 1;
            continue;
        }
        const slot = &vm.objects.slots.items[i];
        // Empty already means swept before, not newly freed.
        const was_used = slot.native != .none or slot.props.items.len != 0 or slot.proto != .undefined_value;
        if (was_used) {
            slot.props.clearAndFree(vm.objects.arena);
            slot.* = .{};
            stats.freed += 1;
        }
    }

    // Give the top of the table back. A dead slot cannot be reached by
    // definition, so nothing can hold a handle past the new end — and a
    // table that only ever grows is half the leak.
    var end = n;
    while (end > 0 and !marks[end - 1]) end -= 1;
    vm.objects.slots.shrinkRetainingCapacity(end);
    stats.slots = @intCast(end);

    for (marks[0..end], 0..) |live, i| {
        if (!live) vm.objects.free_list.append(gpa, @intCast(i + 1)) catch {};
    }
    return stats;
}

const Marker = struct {
    vm: *Vm,
    marks: []bool,
    stack: *std.ArrayList(ObjectHandle),
    gpa: std.mem.Allocator,

    fn push(self: *Marker, h: ObjectHandle) void {
        if (h == 0 or h > self.marks.len) return;
        if (self.marks[h - 1]) return;
        self.marks[h - 1] = true;
        self.stack.append(self.gpa, h) catch {};
    }

    fn pushValue(self: *Marker, v: Value) void {
        if (v == .object) self.push(v.object);
    }

    fn roots(self: *Marker, extra: []const ObjectHandle) void {
        const vm = self.vm;
        // Every prototype and singleton the VM holds by handle. Walked
        // by REFLECTION so a new one cannot be forgotten: any `u32` field
        // whose name ends in the shapes below is a handle.
        inline for (@typeInfo(Vm).@"struct".fields) |f| {
            if (f.type == ObjectHandle) self.push(@field(vm, f.name));
            if (f.type == [10]ObjectHandle) {
                for (@field(vm, f.name)) |h| self.push(h);
            }
        }
        self.pushValue(vm.root_object);
        self.pushValue(vm.pending_throw);
        for (vm.stack.items) |v| self.pushValue(v);
        for (vm.registers) |v| self.pushValue(v);
        for (vm.class_registry.items) |e| self.push(e.ctor);
        for (vm.levels.items) |lv| self.push(lv.obj);
        for (vm.external_callbacks.items) |cb| {
            self.push(cb.method);
            self.pushValue(cb.this);
        }
        for (vm.timers.list.items) |t| {
            switch (t.callback) {
                .func => |h| self.push(h),
                .method => |mm| self.push(mm.this),
            }
            for (t.params) |v| self.pushValue(v);
        }
        if (vm.drag) |d| self.push(d.target);
        for (extra) |h| self.push(h);
    }

    fn drain(self: *Marker) void {
        while (self.stack.pop()) |h| {
            const o = &self.vm.objects.slots.items[h - 1];
            self.pushValue(o.proto);
            for (o.props.items) |p| {
                self.pushValue(p.value);
                self.push(p.getter);
                self.push(p.setter);
            }
            self.push(o.scope_values);
            self.push(o.scope_parent);
            for (o.interfaces) |i| self.push(i);
            for (o.watchers) |w| {
                self.push(w.callback);
                self.pushValue(w.user_data);
            }
            switch (o.native) {
                .super_obj => |s| self.push(s.this),
                .transform => |t| self.push(t),
                .function => |f| switch (f) {
                    .avm1 => |a| {
                        self.push(a.scope);
                        self.push(a.base_clip);
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
};

test "an unreachable object is swept and its slot reused" {
    // The table is exercised through `Objects` alone: a full `Vm` needs
    // the globals installer, and what matters here is the free list.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var objs = object_mod.Objects.init(arena.allocator());
    defer objs.free_list.deinit(std.testing.allocator);

    const a = try objs.create();
    const b = try objs.create();
    try std.testing.expectEqual(@as(ObjectHandle, 1), a);
    try std.testing.expectEqual(@as(ObjectHandle, 2), b);

    // Hand slot 1 back; the next create must take it rather than grow.
    try objs.free_list.append(std.testing.allocator, a);
    const c = try objs.create();
    try std.testing.expectEqual(a, c);
    try std.testing.expectEqual(@as(usize, 2), objs.slots.items.len);
}
