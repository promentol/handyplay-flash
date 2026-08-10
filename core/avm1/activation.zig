//! One AVM1 call frame + the action dispatch — the Ruffle-style LINEAR
//! interpreter: a byte reader over the action slice; If/Jump seek the
//! reader (offsets are signed, relative to after the action, and may land
//! mid-action); running off the end is an implicit return; a shared budget
//! guards runaway scripts.
//!
//! Per-action semantics follow open-flash avm1/actions/*.md (with its
//! Adobe corrections) and ruffle activation.rs; version quirks (SWF4
//! numeric ops, `#ERROR#` division, v4 boolean-as-number) mirrored.

const std = @import("std");
const rdr = @import("../swf/reader.zig");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const object_mod = @import("object.zig");
const opcodes = @import("opcodes.zig");
const runtime = @import("runtime.zig");
const stage = @import("stage_object.zig");
const movie_clip_mod = @import("../display/movie_clip.zig");
const loader = @import("globals/loader.zig");

const Value = runtime.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

pub const Flow = union(enum) {
    next,
    return_value: Value,
    thrown: Value,
};

pub const Activation = struct {
    vm: *Vm,
    code: []const u8,
    r: rdr.Reader,
    this: Value,
    scope: ObjectHandle,
    /// DefineFunction2 local registers ([] = use the VM's 4 globals).
    local_registers: []Value = &.{},
    /// The clip whose bytecode this is. Fixed for the activation.
    base_clip: ObjectHandle = 0,
    /// Where movie control and variables go, changed by SetTarget.
    /// `null` means a SetTarget path FAILED, which is a THIRD state
    /// distinct from "no SetTarget in effect" (== base_clip): control ops
    /// then do nothing while variables fall through to _root.
    /// Ruffle's `target_clip: Option<DisplayObject>`.
    target_clip: ?ObjectHandle = null,
    /// The timeline (ruffle ScopeClass::Target) node this activation was
    /// built with — the tail of the scope chain. SetTarget substitutes
    /// `target_clip` for it during lookup; see `scopeObject`.
    timeline_scope: ObjectHandle = 0,
    constant_pool: u32,
    swf_version: u8,
    /// The function object this frame is running, or 0 for timeline code
    /// — `arguments.caller` is the CALLER's callee.
    callee: ObjectHandle = 0,
    /// Was this frame entered as a CONSTRUCTOR call? `ASnative(2, 0)`
    /// reports it.
    is_constructor: bool = false,

    pub fn init(vm: *Vm, code: []const u8, this: Value, scope: ObjectHandle, pool: u32) Activation {
        const base: ObjectHandle = if (this == .object) this.object else 0;
        return .{
            .vm = vm,
            .code = code,
            .r = rdr.Reader.init(code),
            .this = this,
            .scope = scope,
            .base_clip = base,
            .target_clip = base,
            .timeline_scope = timelineScopeOf(vm, scope),
            .constant_pool = pool,
            .swf_version = vm.swf_version,
        };
    }

    /// The Target-class scope: the tail of the `scope_parent` chain.
    /// Timeline code passes the clip object directly as its scope;
    /// `Vm.callAvm1` chains a fresh local onto the captured scope, so the
    /// clip is always at the bottom.
    fn timelineScopeOf(vm: *Vm, scope: ObjectHandle) ObjectHandle {
        var cur = scope;
        while (cur != 0) {
            const next = vm.objects.get(cur).scope_parent;
            if (next == 0) return cur;
            cur = next;
        }
        return scope;
    }

    pub fn run(self: *Activation) anyerror!Flow {
        const outer = self.vm.current_activation;
        self.vm.current_activation = @ptrCast(self);
        defer self.vm.current_activation = outer;
        while (true) {
            if (self.vm.halted) return .next;
            if (self.vm.budget == 0) {
                self.vm.halted = true;
                return .next;
            }
            self.vm.budget -= 1;
            // A cyclic prototype chain is a hard stack overflow in Flash.
            // It aborts the WHOLE action, not just the frame that hit it —
            // corpus watch_proto_recursion traces one line and stops, with
            // the statements after the offending read never running. So it
            // travels as a Zig error and unwinds every activation.
            if (self.vm.objects.chain_overflow) {
                self.vm.objects.chain_overflow = false;
                return error.Avm1StackOverflow;
            }
            const before_pos = self.r.pos;
            _ = before_pos;
            const action = (opcodes.readAction(&self.r) catch return .next) orelse return .next;
            const flow = try self.exec(action);
            if (flow != .next) return flow;
        }
    }

    /// Run a nested slice (With / Try bodies) in a child frame sharing
    /// this frame's state but its own reader (and possibly scope).
    fn runSlice(self: *Activation, code: []const u8, scope: ObjectHandle) anyerror!Flow {
        var child = Activation.init(self.vm, code, self.this, scope, self.constant_pool);
        child.local_registers = self.local_registers;
        // A `with {}` or `try {}` body inside a tellTarget stays targeted.
        child.base_clip = self.base_clip;
        child.target_clip = self.target_clip;
        child.timeline_scope = self.timeline_scope;
        const flow = try child.run();
        self.constant_pool = child.constant_pool; // pool changes persist
        self.target_clip = child.target_clip; // SetTarget inside persists
        return flow;
    }

    // --- stack + register helpers ----------------------------------------

    fn push(self: *Activation, v: Value) !void {
        try self.vm.pushStack(v);
    }
    fn pop(self: *Activation) Value {
        return self.vm.popStack();
    }
    fn popNumber(self: *Activation) !f64 {
        return self.vm.toNumber(self.pop());
    }
    fn popString(self: *Activation) !strings.AvmString {
        return self.vm.toStringValue(self.pop());
    }

    /// A register index PAST the function's own count falls through to
    /// the four GLOBAL registers — it is not undefined, and writing it
    /// is visible after the function returns (corpus register_underflow).
    fn getRegister(self: *Activation, idx: u8) Value {
        if (idx < self.local_registers.len) return self.local_registers[idx];
        return if (idx < 4) self.vm.registers[idx] else .undefined_value;
    }

    fn setRegister(self: *Activation, idx: u8, v: Value) void {
        if (idx < self.local_registers.len) {
            self.local_registers[idx] = v;
            return;
        }
        if (idx < 4) self.vm.registers[idx] = v;
    }

    fn swfStr(self: *Activation, bytes: []const u8) !strings.AvmString {
        return strings.fromSwf(self.vm.arena(), bytes, self.swf_version);
    }

    fn boolResult(self: *Activation, b: bool) Value {
        // A BOOLEAN even in SWF4, where the type has no literal: ruffle
        // marks every one of these "diverges from spec: returns a boolean
        // even in SWF 4". It only shows through `typeof` and `===`,
        // because a SWF4 boolean stringifies as "1"/"0" anyway (corpus
        // swf4_actions_bool).
        _ = self;
        return .{ .boolean = b };
    }

    // --- variable paths ---------------------------------------------------

    /// A text field's `variable` split into the object holding it and the
    /// property name — ruffle `resolve_variable_path`, run from nothing.
    ///
    /// The RIGHT-MOST `:` or `.` divides the two; with neither, the whole
    /// string is a property on `start` itself.
    pub fn resolveVariablePath(
        vm: *Vm,
        root: ObjectHandle,
        start: ObjectHandle,
        path: strings.AvmString,
    ) anyerror!?struct { obj: ObjectHandle, name: strings.AvmString } {
        var sep: ?usize = null;
        for (path, 0..) |c, i| {
            if (c == ':' or c == '.') sep = i;
        }
        const at = sep orelse return .{ .obj = start, .name = path };
        var act = Activation.init(vm, &.{}, .{ .object = start }, start, 0);
        const target = try act.resolveTargetPath(root, start, path[0..at], true, true) orelse
            return null;
        return .{ .obj = target, .name = path[at + 1 ..] };
    }

    /// `asfunction:` — call the function a text field's link names, in a
    /// scope rooted at the field's own timeline.
    ///
    /// `this` is the object the NAME resolved against when it was a path
    /// (`text1.callback` runs with text1 as `this`) and the timeline
    /// otherwise — ruffle's `call_with_default_this`.
    pub fn callNamed(
        vm: *Vm,
        start: ObjectHandle,
        name: strings.AvmString,
        args: []const Value,
    ) anyerror!void {
        if (name.len == 0) return;
        var act = Activation.init(vm, &.{}, .{ .object = start }, start, 0);
        const hit = try act.getVariableHit(name) orelse return;
        if (!vm.isCallable(hit.value)) return;
        // The scope hit's OWNER is `this`. A name that only `_global`
        // provides has no scope object behind it, and there `_global`
        // itself is the receiver — corpus asfunction traces
        // `this == _global` for a function declared there.
        const this: Value = if (hit.owner != 0)
            .{ .object = hit.owner }
        else if (vm.objects.hasOwn(vm.globals, name, vm.case_sensitive))
            .{ .object = vm.globals }
        else
            .{ .object = start };
        _ = try vm.callFunction(hit.value, this, args);
    }

    /// Resolve a TARGET PATH to an object, walking the DISPLAY tree.
    /// Ports ruffle activation.rs:2562-2676. This is a different animal
    /// from GetMember: children are resolved before ordinary properties,
    /// and the delimiter set changes as the path is consumed.
    ///
    /// `first_element` allows `this`/`_root`/`_levelN` at the head only;
    /// `handle_this` enables the `this` keyword at all.
    /// A TARGET PATH from a native method, resolved against the clip the
    /// call is running in. Natives hold only the `Vm`, so they reach the
    /// running frame through `current_activation`.
    /// The CALLING frame's variable bag, for the natives that submit it as
    /// form data (`MovieClip.getURL` with a method, and the `getURL`
    /// opcode). In timeline code this is the clip itself.
    /// The defining clip's dot path, captured when a function is created.
    /// Empty when there is no clip — a function defined inside another
    /// function inherits its enclosing base clip and its path with it.
    fn baseClipPath(self: *Activation) !strings.AvmString {
        if (self.base_clip == 0) return &.{};
        const t = stage.targetOf(self.vm, self.base_clip) orelse return &.{};
        const clip = t.clip orelse return &.{};
        return stage.dotPathOf(self.vm, @ptrCast(clip));
    }

    /// Re-resolve a function's base clip when the one it captured is gone.
    /// Ruffle keeps it as a path, not a pointer, so a clip removed and put
    /// back at the same place revives every closure that named it.
    /// Null when the reference is DEAD — the clip was removed and
    /// nothing has taken its place at that path. Ruffle's
    /// `resolve_reference(...).unwrap_or(this_do)` then falls back to
    /// `this`'s clip, which is why a function outlives its definer with
    /// a different base (corpus function_base_clip_removed).
    pub fn liveBaseClip(vm: *runtime.Vm, handle: ObjectHandle, path: strings.AvmString) ?ObjectHandle {
        if (handle != 0 and stage.targetOf(vm, handle) != null) return handle;
        if (path.len == 0) return null;
        const p = vm.current_activation orelse return null;
        const act: *Activation = @ptrCast(@alignCast(p));
        const root = act.rootHandle();
        const found = act.resolveTargetPath(root, root, path, true, false) catch return null;
        return found;
    }

    /// The function object the CALLER is running, as a value: an
    /// `arguments` object reports it as `caller`, and NULL — not
    /// undefined — when the caller is timeline code (corpus arguments).
    pub fn callerCallee(vm: *runtime.Vm) Value {
        const p = vm.current_activation orelse return .null_value;
        const act: *Activation = @ptrCast(@alignCast(p));
        if (act.callee == 0) return .null_value;
        return .{ .object = act.callee };
    }

    /// Was the innermost BYTECODE frame entered as a constructor call?
    /// Native frames are transparent — they have no activation — so a
    /// `valueOf` called from inside a constructor still answers yes
    /// (corpus asnew).
    pub fn inConstructorCall(vm: *runtime.Vm) bool {
        const p = vm.current_activation orelse return false;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.is_constructor;
    }

    /// The CALLER's `this`. A function that PRELOADS `this` into a
    /// register (or suppresses it) does not get a `this` of its own —
    /// the name inherits the caller's, which is why a constructor whose
    /// body preloads `this` sees the new object in r1 but the caller's
    /// timeline under the name (corpus this_swf5/this_swf6).
    pub fn callerThis(vm: *runtime.Vm, fallback: Value) Value {
        const p = vm.current_activation orelse return fallback;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.this;
    }

    /// The SWF version of the frame doing the calling. Ruffle decides
    /// closure-vs-not from `activation.swf_version()`, not from a global:
    /// a SWF5 frame calling a SWF6 function gets the SWF5 rule even
    /// though the VM last ran SWF6 code.
    pub fn callerSwfVersion(vm: *runtime.Vm) u8 {
        const p = vm.current_activation orelse return vm.swf_version;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.swf_version;
    }

    /// The CALLER's target clip, or the root. A SWF5 call is not a
    /// closure: it adopts `this`'s clip, and when `this` is not a display
    /// object at all, this is what it falls back to.
    pub fn callerTargetClip(vm: *runtime.Vm) ObjectHandle {
        const p = vm.current_activation orelse
            return if (vm.root_object == .object) vm.root_object.object else 0;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.targetClipOrRoot();
    }

    /// The clip the running script BELONGS to (not the one it is
    /// targeting). `System.security.sandboxType` answers for the base
    /// clip's movie, so a loaded SWF reports its own origin.
    pub fn baseClipForNative(vm: *runtime.Vm) ?ObjectHandle {
        const p = vm.current_activation orelse return null;
        const act: *Activation = @ptrCast(@alignCast(p));
        return if (act.base_clip == 0) null else act.base_clip;
    }

    pub fn localsForNative(vm: *runtime.Vm) ?ObjectHandle {
        const p = vm.current_activation orelse return null;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.localScope();
    }

    pub fn resolveTargetForNative(vm: *runtime.Vm, start: ObjectHandle, path: strings.AvmString) anyerror!?ObjectHandle {
        const p = vm.current_activation orelse return null;
        const act: *Activation = @ptrCast(@alignCast(p));
        return act.resolveTargetPath(act.rootHandle(), start, path, true, false);
    }

    fn resolveTargetPath(
        self: *Activation,
        root: ObjectHandle,
        start: ObjectHandle,
        path_in: strings.AvmString,
        first_in: bool,
        handle_this: bool,
    ) anyerror!?ObjectHandle {
        var path = path_in;
        var first_element = first_in;
        // An empty path is the start object itself.
        if (path.len == 0) return start;

        // `this`, `_root` and the `.`/`:` delimiters are SWF5+. SWF4 paths
        // are markedly more restrictive.
        const is_swf5 = self.swf_version >= 5;

        // A leading `/` is absolute: `/bar` means `_root.bar`.
        var object: ObjectHandle = start;
        var is_slash_path = false;
        if (path.len > 0 and path[0] == '/') {
            path = path[1..];
            first_element = false;
            object = root;
            is_slash_path = true;
        }

        while (path.len > 0) {
            // Any number of leading `:` are the same as none.
            if (is_swf5) {
                // `foo`, `:foo` and `:::foo` are all the same. Trimming
                // the tail to EMPTY does not end the walk, though — the
                // step below then looks up the empty name and fails, so
                // `clip1.clip2/clip4::` resolves to nothing rather than
                // to clip4 (corpus path_string).
                while (path.len > 0 and path[0] == ':') path = path[1..];
            }

            var val: Value = .undefined_value;
            const prefix = path[0..@min(3, path.len)];
            if (startsWith(prefix, "..") and
                (prefix.len == 2 or prefix[2] == '/' or (is_swf5 and prefix[2] == ':')))
            {
                // SWF4-style `_parent`.
                if (path.len > 2 and path[2] == '/') is_slash_path = true;
                path = if (path.len > 3) path[3..] else path[path.len..];
                const t = stage.targetOf(self.vm, object) orelse return null;
                const parent = t.parent() orelse return null; // parent of root
                val = .{ .object = try stage.clipObject(self.vm, parent) };
            } else {
                // Step to the next delimiter. `:` and `.` are SWF5+, and
                // once a `/` has appeared `.` is no longer a delimiter.
                var pos: usize = 0;
                while (pos < path.len) : (pos += 1) {
                    const c = path[pos];
                    if (is_swf5 and c == ':') break;
                    if (is_swf5 and c == '.' and !is_slash_path) break;
                    if (c == '/') {
                        is_slash_path = true;
                        break;
                    }
                }
                const name = path[0..pos];
                path = if (pos + 1 <= path.len) path[@min(pos + 1, path.len)..] else path[path.len..];

                if (is_swf5 and handle_this and strings.eql(name, S("this"))) {
                    val = self.this;
                } else if (is_swf5 and first_element and strings.eql(name, S("_root"))) {
                    val = self.vm.root_object;
                } else if (first_element and stage.parseLevel(self.vm, name) != null) {
                    val = stage.parseLevel(self.vm, name).?;
                } else {
                    // DISPLAY CHILDREN FIRST, then ordinary properties —
                    // the reverse of GetMember. A child with no scriptable
                    // object resolves to its parent instead of nothing.
                    val = blk: {
                        if (stage.targetOf(self.vm, object)) |t| {
                            if (t.clip) |container| {
                                if (stage.childByName(container, name, self.vm.case_sensitive)) |child| {
                                    // RAW handles here, not `displayValue`:
                                    // path resolution is internal and must
                                    // work at SWF4, where a display object
                                    // has no value representation.
                                    if (!stage.isScriptable(child.kind)) break :blk .{ .object = object };
                                    break :blk .{ .object = try stage.handleOf(self.vm, child) };
                                }
                            }
                        }
                        break :blk try self.memberGet(.{ .object = object }, name);
                    };
                }
            }

            // `this`/`_root` are only meaningful at the head.
            first_element = false;

            if (val != .object) return null;
            object = val.object;
        }
        return object;
    }

    /// The rightmost `:` — or `.` at SWF5+ — splits a variable path into
    /// (target path, variable name). RIGHTMOST is load-bearing: `a.b.c`
    /// targets `a.b` and reads `c`.
    fn variableSeparator(self: *Activation, name: strings.AvmString) ?usize {
        var i = name.len;
        while (i > 0) {
            i -= 1;
            const c = name[i];
            if (c == ':' or (self.swf_version >= 5 and c == '.')) return i;
        }
        return null;
    }

    fn containsSlash(name: strings.AvmString) bool {
        for (name) |c| {
            if (c == '/') return true;
        }
        return false;
    }

    /// ruffle activation.rs:2738-2793. Note each candidate scope gets its
    /// own shot at the target path, and a scope only wins if the resolved
    /// object actually HAS the variable.
    fn getVariable(self: *Activation, name: strings.AvmString) !Value {
        const hit = try self.getVariableHit(name) orelse return .undefined_value;
        return hit.value;
    }

    /// getVariable, keeping the object a path resolved AGAINST — a call
    /// through a path runs with that object as `this`, which is what makes
    /// `"_root.mc.gotoAndStop"(4)` move mc (ruffle activation.rs:2769).
    fn getVariableHit(self: *Activation, name: strings.AvmString) !?ScopeHit {
        const root = self.rootHandle();
        if (self.variableSeparator(name)) |sep| {
            const path = name[0..sep];
            const var_name = name[sep + 1 ..];
            if (path.len == 0) return null;
            var cur = self.scope;
            while (cur != 0) {
                const node = self.scopeObject(cur);
                if (try self.resolveTargetPath(root, node, path, true, true)) |obj| {
                    if (try self.hasVariable(obj, var_name)) {
                        const v = try self.memberGet(.{ .object = obj }, var_name);
                        return .{ .value = v, .owner = obj };
                    }
                }
                cur = self.vm.objects.get(cur).scope_parent;
            }
            // `_global` is the LAST scope in ruffle's chain, so a dotted
            // path that fails everywhere else is tried against it — which
            // is what makes `a.b.c` find `_global.a.b.c` when the
            // timeline's own `a.b` is a string (corpus
            // get_variable_in_scope). Our chain ends before it, because a
            // clip's scope node has no parent.
            if (try self.resolveTargetPath(root, self.vm.globals, path, true, true)) |obj| {
                if (try self.hasVariable(obj, var_name)) {
                    const v = try self.memberGet(.{ .object = obj }, var_name);
                    return .{ .value = v, .owner = obj };
                }
            }
            return null;
        }

        // No trailing variable, but it can still be a slash path (SWF5+;
        // SWF4 always requires the trailing variable).
        if (self.swf_version >= 5 and containsSlash(name)) {
            var cur = self.scope;
            while (cur != 0) {
                const node = self.scopeObject(cur);
                if (try self.resolveTargetPath(root, node, name, false, false)) |obj| {
                    return .{ .value = .{ .object = obj }, .owner = 0 };
                }
                cur = self.vm.objects.get(cur).scope_parent;
            }
            if (try self.resolveTargetPath(root, self.vm.globals, name, false, false)) |obj| {
                return .{ .value = .{ .object = obj }, .owner = 0 };
            }
        }

        // A plain old variable name: the scope chain, as normal.
        return try self.scopeLookupHit(name);
    }

    /// Does `obj` expose `name` — as an own/inherited property, a display
    /// property, a child, or a path property?
    fn hasVariable(self: *Activation, obj: ObjectHandle, name: strings.AvmString) !bool {
        if (self.vm.objects.getChained(obj, name, self.vm.case_sensitive) != null) return true;
        return (try stage.resolveMember(self.vm, obj, name)) != null;
    }

    /// ruffle activation.rs:2818-2870. Unlike the read path, a scope wins
    /// as soon as its target path resolves — the variable need not exist.
    fn setVariable(self: *Activation, name: strings.AvmString, v: Value) !void {
        if (name.len == 0) return;
        // `this` is assignable from SWF5 on.
        if (self.swf_version >= 5 and strings.eql(name, S("this"))) {
            self.this = v;
            return;
        }
        const root = self.rootHandle();
        if (self.variableSeparator(name)) |sep| {
            const path = name[0..sep];
            const var_name = name[sep + 1 ..];
            var cur = self.scope;
            while (cur != 0) {
                const node = self.scopeObject(cur);
                if (try self.resolveTargetPath(root, node, path, true, true)) |obj| {
                    try self.memberSet(.{ .object = obj }, var_name, v);
                    return;
                }
                cur = self.vm.objects.get(cur).scope_parent;
            }
            // The write side ends at `_global` too — see the read path.
            if (try self.resolveTargetPath(root, self.vm.globals, path, true, true)) |obj| {
                try self.memberSet(.{ .object = obj }, var_name, v);
            }
            return;
        }
        try self.scopeAssign(name, v);
    }

    fn startsWith(haystack: strings.AvmString, comptime needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return strings.eql(haystack[0..needle.len], S(needle));
    }

    /// Vm.scopeGet, but each scope object that is a clip also exposes its
    /// children, `_parent`/`_root` and the display properties — timeline
    /// code says bare `_x` and bare `myClip`, not `this._x`.
    fn scopeLookup(self: *Activation, name: strings.AvmString) !?Value {
        return (try self.scopeLookupHit(name) orelse return null).value;
    }

    /// A scope-chain hit plus the object that PROVIDED it. Ruffle returns
    /// `CallableValue::Callable(locals_cell, v)` from every scope
    /// resolution (scope.rs:145-150), and a bare `f()` calls with that
    /// object as `this` — which is how `with (mc) { foo() }` runs foo with
    /// `this` = mc. `owner` is 0 for the two hits that have no scope
    /// object behind them: the `this` keyword and the _global fallback.
    const ScopeHit = struct { value: Value, owner: ObjectHandle };

    fn scopeLookupHit(self: *Activation, name: strings.AvmString) !?ScopeHit {
        const cs = self.vm.case_sensitive;
        // `this` is resolved BEFORE the scope chain from SWF5 on
        // (ruffle Activation::resolve:2925-2936). Timeline code has no
        // `this` binding to find otherwise — only function locals do —
        // so `this._name` reads undefined without this.
        if (self.swf_version >= 5) {
            // Below SWF6 the match is case-sensitive only inside a
            // function's local scope; timeline code is insensitive.
            // …and only in a LOCAL scope. A `with {}` body is its own
            // scope class, not a local one, so `tHiS` matches inside it
            // even at SWF5 (corpus this_swf5).
            const this_cs = if (self.swf_version <= 5)
                self.scope != self.timeline_scope and
                    self.scope != 0 and
                    !self.vm.objects.get(self.scope).is_with_scope
            else
                cs;
            const hit = if (this_cs)
                strings.eql(name, S("this"))
            else
                strings.eqlIgnoreCase(name, S("this"));
            if (hit) return .{ .value = self.this, .owner = 0 };
        }
        var cur = self.scope;
        while (cur != 0) {
            const node = self.scopeObject(cur);
            // Same three-step order as memberGet, per scope object.
            if (self.vm.objects.getOwn(node, name, cs) != null) {
                const v = try self.vm.getProperty(node, name, .{ .object = node });
                return .{ .value = v, .owner = node };
            }
            if (try stage.resolveMember(self.vm, node, name)) |v| {
                return .{ .value = v, .owner = node };
            }
            if (self.vm.objects.getChained(node, name, cs) != null) {
                const v = try self.vm.getProperty(node, name, .{ .object = node });
                return .{ .value = v, .owner = node };
            }
            cur = self.vm.objects.get(cur).scope_parent;
        }
        // Through `getProperty`, so an ACCESSOR on `_global` runs — `NaN`
        // and `Infinity` are accessors because SWF4 has neither.
        const gh = self.vm.globals;
        if (self.vm.objects.findOwn(gh, name, cs) == null and
            !self.vm.objects.hasChained(gh, name, cs)) return null;
        return .{ .value = try self.vm.getProperty(gh, name, .{ .object = gh }), .owner = 0 };
    }

    /// Vm.scopeSet's counterpart to `scopeLookup`: a bare `_x = 10` in
    /// timeline code has to reach the clip's display property, not define
    /// a plain variable that shadows it forever.
    fn scopeAssign(self: *Activation, name: strings.AvmString, v: Value) !void {
        const cs = self.vm.case_sensitive;
        var cur = self.scope;
        var bottom = self.scopeObject(self.scope);
        while (cur != 0) {
            const node = self.scopeObject(cur);
            // The scope chain is searched with a full HAS-PROPERTY, not an
            // own-property test: ruffle's `Scope::set` asks
            // `has_property`, so a name whose accessor lives on the
            // object's PROTOTYPE is set on that object through the
            // setter. A component whose class declares `contentPath` as
            // an addProperty pair depends on it — a bare
            // `contentPath = "x"` in an onClipEvent(construct) has to
            // reach the setter, not shadow it with a plain property.
            if (self.vm.objects.hasOwn(node, name, cs) or
                self.vm.objects.findChainedForWriteLocated(node, name, cs) != null)
            {
                return self.storeInScope(node, name, v);
            }
            if (try stage.assignMember(self.vm, node, name, v)) return;
            bottom = node;
            cur = self.vm.objects.get(cur).scope_parent;
        }
        try self.storeInScope(bottom, name, v);
    }

    /// A timeline variable is an ordinary property of the clip's object, so
    /// a `watch` on the clip applies to it — but only take the accessor-
    /// aware path when something is actually watching.
    fn storeInScope(self: *Activation, node: ObjectHandle, name: strings.AvmString, v: Value) !void {
        // A scope write is a full `set`, so a VIRTUAL property on the
        // scope object runs its setter: `with (o) { prop = 2 }` where
        // `o.prop` is an addProperty pair calls that setter (corpus with).
        // …and the accessor may be inherited, which is the same reason
        // `scopeAssign` walks the prototype chain.
        const virtual = if (self.vm.objects.findChainedForWriteLocated(node, name, self.vm.case_sensitive)) |loc|
            loc.prop.setter != 0 or loc.prop.getter != 0
        else
            false;
        if (self.vm.objects.get(node).watchers.len == 0 and !virtual) {
            try self.vm.objects.put(node, name, v, self.vm.case_sensitive);
            // A timeline variable is where text-field bindings live, so
            // the fast path has to notify too.
            if (stage.targetOf(self.vm, node)) |t| {
                try @import("text_binding.zig").notify(self.vm, t.obj, name, v);
            }
            return;
        }
        return self.vm.setProperty(node, name, v, .{ .object = node });
    }

    // --- member access ----------------------------------------------------

    fn memberGet(self: *Activation, target: Value, name: strings.AvmString) !Value {
        switch (target) {
            .object => |h| {
                // `super` owns nothing. Every read starts at the object
                // ruffle's chain walk starts at — `SuperObject::proto()`,
                // one layer ABOVE where super's methods live — with the
                // original `this` (script_object.rs:724-730). That is why
                // `super.__proto__` lands two layers up: `__proto__` is a
                // stored property found on that start object, not on super.
                if (self.vm.objects.get(h).native == .super_obj) {
                    if (strings.eqlIgnoreCase(name, S("__proto__"))) {
                        const start = self.vm.superProto(h);
                        if (start != .object) return .undefined_value;
                        return self.vm.protoValue(start.object);
                    }
                    return self.vm.getProperty(h, name, target);
                }
                // `__proto__` is a live accessor, not a stored property.
                if (strings.eqlIgnoreCase(name, S("__proto__"))) {
                    return self.vm.objects.get(h).proto;
                }
                // OWN properties win, then the display fallback, then the
                // PROTOTYPE chain. The fallback sits between them because
                // ruffle applies it per object inside get_local_stored —
                // which is what stops a polluted `MovieClip.prototype._root`
                // from shadowing the real one (corpus issue_768).
                if (self.vm.objects.getOwn(h, name, self.vm.case_sensitive) == null) {
                    if (try stage.resolveMember(self.vm, h, name)) |v| return v;
                }
                return self.vm.getProperty(h, name, target);
            },
            // A read on a PRIMITIVE boxes it first, `length` included,
            // and boxing goes through `_global` — so monkey-patching
            // `_global.String` changes what `"world".length` answers
            // (corpus coerce_to_object_monkeypatch).
            .string, .number, .boolean => return self.boxedMemberGet(target, name),
            else => return .undefined_value,
        }
    }

    fn boxedMemberGet(self: *Activation, target: Value, name: strings.AvmString) !Value {
        const boxed = try @import("globals/globals.zig").boxPrimitive(self.vm, target);
        if (boxed != .object) return .undefined_value;
        // The box is the receiver for a getter, but `this` for a METHOD
        // call is still substituted by the caller.
        return self.vm.getProperty(boxed.object, name, boxed);
    }

    fn memberSet(self: *Activation, target: Value, name: strings.AvmString, v: Value) !void {
        if (target != .object) return;
        const h = target.object;
        if (strings.eqlIgnoreCase(name, S("__proto__"))) {
            // Whatever is assigned is STORED, even a number: `obj.__proto__
            // = 123` reads back as 123 with typeof "number". Only an object
            // participates in the chain walk, which already checks
            // (corpus object_prototypes). Ruffle reaches this through the
            // ordinary property machinery, so a `watch("__proto__")` fires
            // and may rewrite the value on its way past.
            // Compute BEFORE taking the pointer: the watcher can create
            // objects, and `objects.get` hands out a pointer into a list
            // that reallocates when it grows.
            const stored = try self.vm.applyWatchers(h, name, v, target);
            self.vm.objects.get(h).proto = stored;
            return;
        }
        // A display property name writes through to the clip; anything
        // else is an ordinary put on the clip's own ScriptObject.
        if (try stage.assignMember(self.vm, h, name, v)) return;
        // An array's `length`/index linkage lives in `Vm.setProperty`,
        // with the watchers and virtual properties that a write to
        // either has to pass through first.
        try self.vm.setProperty(h, name, v, target);
    }

    // --- dispatch ---------------------------------------------------------

    fn exec(self: *Activation, action: opcodes.Action) anyerror!Flow {
        switch (action) {
            .simple => |op| return self.execSimple(op),
            .push => |raw| {
                var it = opcodes.PushIterator.init(raw);
                while (it.next()) |pv| {
                    const v: Value = switch (pv) {
                        .string => |s| .{ .string = try self.swfStr(s) },
                        .float => |f| .{ .number = f },
                        .null_value => .null_value,
                        .undefined_value => .undefined_value,
                        .register => |idx| self.getRegister(idx),
                        .boolean => |b| .{ .boolean = b },
                        .double => |d| .{ .number = d },
                        .int => |u| .{ .number = @floatFromInt(u) },
                        .const8 => |idx| self.poolValue(idx),
                        .const16 => |idx| self.poolValue(idx),
                    };
                    try self.push(v);
                }
            },
            .jump => |off| self.seek(off),
            .if_op => |off| {
                const cond = value_mod.toBoolean(self.pop(), self.swf_version);
                if (cond) self.seek(off);
            },
            .constant_pool => |cp| {
                try self.loadConstantPool(cp.count, cp.raw);
            },
            .store_register => |idx| {
                // Value stays on the stack.
                const v = self.pop();
                try self.push(v);
                self.setRegister(idx, v);
            },
            .define_function => |f| {
                const fn_obj = try self.vm.newAvm1Fn(.{
                    .body = f.body,
                    .param_count = f.param_count,
                    .params_raw = f.params_raw,
                    .with_registers = false,
                    .scope = self.scope,
                    .constant_pool = self.constant_pool,
                    .swf_version = self.swf_version,
                    .base_clip = self.base_clip,
                    .base_clip_path = try self.baseClipPath(),
                });
                if (f.name.len > 0) {
                    // A NAMED function definition is a `var` too, path
                    // and all: `function /:f1() {}` defines `f1` on the
                    // root (corpus define_local_with_paths).
                    const name = try self.swfStr(f.name);
                    try self.defineLocal(name, .{ .object = fn_obj });
                } else {
                    try self.push(.{ .object = fn_obj });
                }
            },
            .define_function2 => |f| {
                const fn_obj = try self.vm.newAvm1Fn(.{
                    .body = f.body,
                    .param_count = f.param_count,
                    .params_raw = f.params_raw,
                    .with_registers = true,
                    .register_count = f.register_count,
                    .flags = f.flags,
                    .scope = self.scope,
                    .constant_pool = self.constant_pool,
                    .swf_version = self.swf_version,
                    .base_clip = self.base_clip,
                    .base_clip_path = try self.baseClipPath(),
                });
                if (f.name.len > 0) {
                    // A NAMED function definition is a `var` too, path
                    // and all: `function /:f1() {}` defines `f1` on the
                    // root (corpus define_local_with_paths).
                    const name = try self.swfStr(f.name);
                    try self.defineLocal(name, .{ .object = fn_obj });
                } else {
                    try self.push(.{ .object = fn_obj });
                }
            },
            .with_op => |w| {
                const target = self.pop();
                // `with(undefined)` and `with(null)` SKIP the body; every
                // other primitive is BOXED, so `with("STRING") { length }`
                // reads 6 (corpus with).
                if (target == .undefined_value or target == .null_value) return .next;
                const boxed = if (target == .object)
                    target
                else
                    try @import("globals/globals.zig").boxPrimitive(self.vm, target);
                const with_scope = try self.vm.newScope(self.scope);
                self.vm.objects.get(with_scope).is_with_scope = true;
                self.vm.objects.get(with_scope).scope_values = boxed.object;
                const flow = try self.runSlice(w.body, with_scope);
                if (flow != .next) return flow;
            },
            .try_op => |t| {
                // Flash restores the value stack to its pre-try depth
                // before the catch runs (ruffle activation.rs:2230,2236);
                // a throw mid-expression otherwise leaves operands behind.
                const stack_depth = self.vm.stack.items.len;
                var flow = self.runSlice(t.try_body, self.scope) catch |e| blk: {
                    if (e != error.Avm1Thrown) return e;
                    break :blk Flow{ .thrown = self.vm.pending_throw };
                };
                if (flow == .thrown and t.has_catch) {
                    const caught = flow.thrown;
                    if (self.vm.stack.items.len > stack_depth) {
                        self.vm.stack.shrinkRetainingCapacity(stack_depth);
                    }
                    if (t.catch_in_register) {
                        self.setRegister(t.catch_register, caught);
                    } else {
                        const name = try self.swfStr(t.catch_name);
                        try self.vm.scopeDefineLocal(self.localScope(), name, caught);
                    }
                    flow = self.runSlice(t.catch_body, self.scope) catch |e| blk: {
                        if (e != error.Avm1Thrown) return e;
                        break :blk Flow{ .thrown = self.vm.pending_throw };
                    };
                }
                if (t.has_finally) {
                    const fin = try self.runSlice(t.finally_body, self.scope);
                    if (fin != .next) return fin; // finally overrides
                }
                // Still thrown after the catch (no catch, or the catch
                // RETHREW): keep unwinding, so an enclosing try — here or
                // in a calling function — still sees it.
                if (flow == .thrown) {
                    self.vm.pending_throw = flow.thrown;
                    return error.Avm1Thrown;
                }
                if (flow != .next) return flow;
            },
            .goto_frame => |frame| self.hostGotoFrame(frame + 1, null),
            .goto_frame2 => |g| {
                // The ONE control op that falls back to the root when the
                // target is invalid — everything else silently no-ops
                // (ruffle action_goto_frame_2 uses target_clip_or_root,
                // action_play/stop/goto_frame use target_clip). This is
                // what makes `tellTarget('bogus'){gotoAndPlay(2)}` move
                // _root; corpus tell_target_invalid.
                const clip = self.clipOrRoot();
                const v = self.pop();
                // The operand is 1-BASED here (unlike GotoFrame 0x81).
                // The number-vs-label split and the wrap arithmetic are
                // shared with MovieClip.gotoAndPlay/gotoAndStop; a STRING
                // operand is a full variable path and may redirect the goto
                // to another clip entirely (corpus goto_frame_number's
                // `GotoFrame2 "/:3"`).
                switch (try stage.frameArg(self.vm, v)) {
                    .number => |n| if (clip) |c| stage.gotoFrameNumber(
                        self.vm,
                        @ptrCast(@alignCast(c)),
                        n,
                        g.scene_offset,
                        g.set_playing,
                    ),
                    .label => |s| {
                        const start = self.targetClipOrRoot();
                        if (try self.resolveFramePath(start, s)) |hit| {
                            if (hit.target.clip) |mc| {
                                if (hit.frame) |f| {
                                    stage.gotoFrameNumber(self.vm, mc, @intCast(f), g.scene_offset, g.set_playing);
                                }
                            }
                        }
                    },
                }
            },
            .goto_label => |label| self.hostGotoLabel(try self.swfStr(label), null),
            .set_target => |t| try self.setTarget(try self.swfStr(t)),
            // Everything a movie already holds IS loaded — there is no
            // streaming here — but a frame number past Flash's 16000-frame
            // ceiling is never loaded, and the guarded actions are then
            // SKIPPED. The count is in ACTIONS, not bytes.
            .wait_for_frame => |w| {
                if (w.frame > 16000) self.skipActions(w.skip_count);
            },
            // The dynamic form differs in three ways: the ceiling is
            // 16001 rather than 16000, a value that is not a whole number
            // goes through its STRING form and lands on frame 0 if that
            // will not parse either, and the frame wraps into an i32 — so
            // 2147483649 is negative, and loaded.
            .wait_for_frame2 => |w| {
                const v = self.pop();
                var frame: i32 = 0;
                if (v == .number and std.math.isFinite(v.number) and v.number == @trunc(v.number)) {
                    frame = value_mod.toInt32(v.number);
                } else {
                    const str = try self.vm.toStringValue(v);
                    const n = value_mod.stringToNumber(str, self.vm.swf_version);
                    if (std.math.isFinite(n) and n == @trunc(n)) frame = value_mod.toInt32(n);
                }
                if (frame == std.math.minInt(i32)) frame = std.math.maxInt(i32);
                if (frame > 16001) self.skipActions(w.skip_count);
            },
            // The STATIC form: both strings are in the tag, so there is no
            // stack traffic and no variables to send. It can still load a
            // level (`getURL("x.swf", "_level1")`), and its level test is
            // strictly `len > 6` — a bare "_level" is just a window name.
            .get_url => |u| {
                const url = try self.swfStr(u.url);
                const target = try self.swfStr(u.target);
                // A `_levelN` target makes this a movie load, not a
                // navigation. Note the bound: the static form needs
                // something AFTER "_level", where GetURL2 accepts a bare
                // "_level" as level 0.
                if (target.len > 6 and strings.eql(target[0..6], S("_level"))) {
                    const n = value_mod.stringToNumber(target[6..], self.swf_version);
                    if (std.math.isNan(n) or n != @trunc(n)) return .next;
                    const id = value_mod.toInt32(n);
                    if (url.len == 0) {
                        // Only unload a level that already exists —
                        // creating one just to empty it would leave a
                        // level behind that never held anything.
                        if (self.existingLevel(id)) |dest| self.unloadMovie(dest);
                    } else if (self.levelHandle(id)) |dest| {
                        loader.spawn(self.vm, .{
                            .url = try strings.toUtf8(self.vm.arena(), url),
                            .target = .{ .movie = .{ .clip = dest } },
                        });
                    }
                    return .next;
                }
                if (loader.fsCommandOf(url) != null) return .next;
                try loader.navigate(self.vm, url, target, .none, &.{});
            },
            .get_url2 => |g| try self.getUrl2(g.is_load_vars, g.is_target_sprite, switch (g.send_vars_method) {
                1 => .get,
                2 => .post,
                else => .none,
            }),
            .strict_mode => {},
            .unknown => {},
        }
        return .next;
    }

    /// `GetURL2` — five different statements share this one opcode, and
    /// which one you wrote is recovered from two flag bits plus the SHAPE
    /// of the target: `loadVariables`, `loadVariablesNum`, `loadMovie`,
    /// `loadMovieNum`, `unloadMovie*` and plain `getURL` all land here.
    ///
    /// The subtle rule is the LoadVariables demotion. With neither
    /// `is_target_sprite` nor a `_levelN` target, a `loadVariables` whose
    /// target resolves to anything other than the movie's own root is not
    /// a load at all — Flash opens the URL in the browser instead.
    ///
    /// Reference: ruffle activation.rs `action_get_url_2`.
    fn getUrl2(
        self: *Activation,
        is_load_vars: bool,
        is_target_sprite: bool,
        method: runtime.FetchRequest.Method,
    ) !void {
        const target_val = self.pop();
        const target = try self.vm.toStringValue(target_val);
        const url_val = self.pop();
        const url = try self.vm.toStringValue(url_val);

        // `fscommand:` hijacks the URL entirely — the TARGET becomes the
        // command's arguments and nothing is fetched or navigated.
        if (loader.fsCommandOf(url) != null) return;

        // `_levelN`: a target that names a level bypasses path resolution
        // entirely. A bare "_level" (nothing after it) is level 0; a
        // suffix that will not parse is not a level at all.
        const level_target: i32 = blk: {
            if (target.len < 6 or !strings.eql(target[0..6], S("_level"))) break :blk -1;
            const n = value_mod.stringToNumber(target[6..], self.swf_version);
            if (std.math.isNan(n)) break :blk if (target.len == 6) 0 else -1;
            break :blk value_mod.toInt32(n);
        };

        var clip_target: ?ObjectHandle = null;
        if (level_target > -1) {
            clip_target = self.levelHandle(level_target);
        } else if (is_load_vars or is_target_sprite) {
            clip_target = if (target_val == .object and stage.targetOf(self.vm, target_val.object) != null)
                target_val.object
            else
                try self.resolveTargetPath(self.rootHandle(), self.targetClipOrRoot(), target, true, false);
        }

        if (is_load_vars) {
            var really_loads = true;
            if (!is_target_sprite and level_target <= -1) {
                // Demoted to a navigation unless the target IS the root.
                really_loads = target_val == .object and clip_target != null and
                    clip_target.? == self.rootHandle();
            }
            if (really_loads) {
                if (clip_target) |dest| {
                    const req = try loader.buildRequest(
                        self.vm,
                        url,
                        self.localScope(),
                        method,
                        .{ .form = dest },
                    );
                    loader.spawn(self.vm, req);
                }
                return;
            }
        } else if (is_target_sprite) {
            // `loadMovie`, `unloadMovie` or `unloadMovieNum`.
            if (url.len == 0) {
                // A blank URL on a movie load IS the unload.
                if (clip_target) |dest| self.unloadMovie(dest);
            } else {
                // The level has to exist before the load can name it.
                if (clip_target == null and level_target > -1) {
                    clip_target = self.levelHandle(level_target);
                }
                if (clip_target) |dest| {
                    loader.spawn(self.vm, try loader.buildRequest(
                        self.vm,
                        url,
                        self.localScope(),
                        method,
                        .{ .movie = .{ .clip = dest } },
                    ));
                }
            }
            return;
        } else if (level_target > -1) {
            // `loadMovieNum`. It sends no variables, whatever the method
            // bits say — ruffle builds a bare GET here.
            if (clip_target == null) clip_target = self.levelHandle(level_target);
            if (clip_target) |dest| {
                if (url.len == 0) {
                    self.unloadMovie(dest);
                } else {
                    loader.spawn(self.vm, try loader.buildRequest(
                        self.vm,
                        url,
                        null,
                        .none,
                        .{ .movie = .{ .clip = dest } },
                    ));
                }
            }
            return;
        }

        // `getURL`. With no send method the locals are not gathered at all.
        const vars: []const runtime.NavigateRequest.Pair = if (method == .none)
            &.{}
        else
            try loader.formPairs(self.vm, self.localScope());
        try loader.navigate(self.vm, url, target, method, vars);
    }

    /// `_levelN`'s clip object, created if this is the first mention of
    /// that level. Level 0 is the root and always exists.
    fn levelHandle(self: *Activation, id: i32) ?ObjectHandle {
        if (id == 0) {
            return if (self.vm.root_object == .object) self.vm.root_object.object else null;
        }
        const h = self.vm.host;
        const f = h.level orelse return null;
        const obj = f(h.ctx orelse return null, id);
        return if (obj == 0) null else obj;
    }

    /// The level's object if it has already been created, WITHOUT making
    /// one. `unloadMovieNum` on a level nobody loaded does nothing at all.
    fn existingLevel(self: *Activation, id: i32) ?ObjectHandle {
        if (id == 0) {
            return if (self.vm.root_object == .object) self.vm.root_object.object else null;
        }
        for (self.vm.levels.items) |lv| {
            if (lv.id == id) return lv.obj;
        }
        return null;
    }

    fn unloadMovie(self: *Activation, clip: ObjectHandle) void {
        const h = self.vm.host;
        const f = h.unload_movie orelse return;
        f(h.ctx orelse return, clip);
    }

    /// Decode and discard `n` actions. `WaitForFrame` counts ACTIONS, so
    /// the bytes cannot simply be added up.
    fn skipActions(self: *Activation, n: u8) void {
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const a = opcodes.readAction(&self.r) catch return;
            if (a == null) return;
        }
    }

    fn execSimple(self: *Activation, op: opcodes.OpCode) anyerror!Flow {
        switch (op) {
            // --- SWF4 arithmetic (numeric semantics) -----------------------
            // Add/Multiply/Less pop BOTH operands and only then coerce,
            // LEFT first — whereas Subtract/Divide/Equals coerce as they
            // pop, i.e. right first. Ruffle mirrors that inconsistency
            // faithfully (action_add:619 vs action_subtract:2128) and it
            // is observable through valueOf side effects.
            .add => {
                const rhs = self.pop();
                const lhs = self.pop();
                const a = try self.vm.toNumber(lhs);
                const b = try self.vm.toNumber(rhs);
                try self.push(.{ .number = a + b });
            },
            .subtract => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(.{ .number = a - b });
            },
            .multiply => {
                const rhs = self.pop();
                const lhs = self.pop();
                const a = try self.vm.toNumber(lhs);
                const b = try self.vm.toNumber(rhs);
                try self.push(.{ .number = a * b });
            },
            .divide => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                if (b == 0 and self.swf_version < 5) {
                    try self.push(.{ .string = S("#ERROR#") });
                } else {
                    try self.push(.{ .number = a / b });
                }
            },
            .modulo => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(.{ .number = ecmaMod(a, b) });
            },
            .equals => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(self.boolResult(a == b));
            },
            .less => {
                const rhs = self.pop();
                const lhs = self.pop();
                const a = try self.vm.toNumber(lhs);
                const b = try self.vm.toNumber(rhs);
                try self.push(self.boolResult(a < b));
            },
            // Both read their operands as BOOLEANS, not numbers: an
            // object is true without its `valueOf` ever running, and NaN
            // is false rather than "not zero" (corpus logical_ops_swf8,
            // swf4_actions_coercion_order).
            .and_op => {
                const b = self.pop();
                const a = self.pop();
                const ba = value_mod.toBoolean(a, self.swf_version);
                const bb = value_mod.toBoolean(b, self.swf_version);
                try self.push(self.boolResult(ba and bb));
            },
            .or_op => {
                const b = self.pop();
                const a = self.pop();
                const ba = value_mod.toBoolean(a, self.swf_version);
                const bb = value_mod.toBoolean(b, self.swf_version);
                try self.push(self.boolResult(ba or bb));
            },
            .not => {
                if (self.swf_version < 5) {
                    const a = try self.popNumber();
                    try self.push(self.boolResult(a == 0));
                } else {
                    const a = value_mod.toBoolean(self.pop(), self.swf_version);
                    try self.push(.{ .boolean = !a });
                }
            },
            .to_integer => {
                // ECMA ToInt32, which WRAPS and turns NaN into 0 — not a
                // plain truncation (corpus action_to_integer).
                const n = try self.popNumber();
                try self.push(.{ .number = @floatFromInt(value_mod.toInt32(n)) });
            },
            .random_number => {
                const max = try self.popNumber();
                const m: i64 = if (std.math.isNan(max) or max <= 0) 0 else @intFromFloat(@min(max, 2147483647));
                const v: f64 = if (m <= 0) 0 else @floatFromInt(self.vm.rng.random().intRangeLessThan(i64, 0, m));
                try self.push(.{ .number = v });
            },
            .get_time => try self.push(.{ .number = self.vm.now_ms }),

            // --- SWF4 strings ---------------------------------------------
            .string_equals => {
                const b = try self.popString();
                const a = try self.popString();
                try self.push(self.boolResult(strings.eql(a, b)));
            },
            .string_less => {
                const b = try self.popString();
                const a = try self.popString();
                try self.push(self.boolResult(strings.order(a, b) == .lt));
            },
            .string_greater => {
                const b = try self.popString();
                const a = try self.popString();
                try self.push(.{ .boolean = strings.order(a, b) == .gt });
            },
            .string_add => {
                const b = try self.popString();
                const a = try self.popString();
                try self.push(.{ .string = try strings.concat(self.vm.arena(), a, b) });
            },
            .string_length, .mb_string_length => {
                const s = try self.popString();
                try self.push(.{ .number = @floatFromInt(s.len) });
            },
            // SWF4 `substring`. Both arguments WRAP into an i32 first,
            // so 4294967303 is 7 — and the index is 1-BASED. A negative
            // length, or one that would run past the end, takes the rest
            // of the string.
            .string_extract, .mb_string_extract => {
                const count = value_mod.toInt32(try self.popNumber());
                const index = value_mod.toInt32(try self.popNumber());
                const s = try self.popString();
                const start: usize = if (index >= 1) @intCast(index - 1) else 0;
                if (start >= s.len) {
                    try self.push(.{ .string = S("") });
                } else {
                    var end: usize = s.len;
                    if (count >= 0) {
                        const want = start + @as(usize, @intCast(count));
                        if (want <= s.len) end = want;
                    }
                    try self.push(.{ .string = s[@min(start, end)..end] });
                }
            },
            // `ord`/`mbord` read one UTF-16 CODE UNIT, and a unit that
            // is half a surrogate pair is not a character — it reports
            // U+FFFD rather than the raw unit, so `ord("😋")` is 65533.
            .char_to_ascii, .mb_char_to_ascii => {
                const s = try self.popString();
                const unit: u16 = if (s.len > 0) s[0] else 0;
                const code: u16 = if (unit >= 0xD800 and unit <= 0xDFFF) 0xFFFD else unit;
                try self.push(.{ .number = @floatFromInt(code) });
            },
            // `chr`/`mbchr` on ZERO give the EMPTY string, not a NUL
            // character; a code unit that is half a surrogate pair is
            // not a character and becomes U+FFFD (SWF6 and up — below
            // that the unit is a byte and passes through).
            .ascii_to_char, .mb_ascii_to_char => {
                const n = try self.popNumber();
                const unit = value_mod.toUint16(n);
                if (unit == 0) {
                    try self.push(.{ .string = S("") });
                } else {
                    const out = try self.vm.arena().alloc(u16, 1);
                    out[0] = if (self.vm.swf_version >= 6 and unit >= 0xD800 and unit <= 0xDFFF)
                        0xFFFD
                    else
                        unit;
                    try self.push(.{ .string = out });
                }
            },

            // --- stack ----------------------------------------------------
            .pop => _ = self.pop(),
            .push_duplicate => {
                const v = self.pop();
                try self.push(v);
                try self.push(v);
            },
            .stack_swap => {
                const a = self.pop();
                const b = self.pop();
                try self.push(a);
                try self.push(b);
            },

            // --- variables ------------------------------------------------
            .get_variable => {
                const name = try self.popString();
                try self.push(try self.getVariable(name));
            },
            .set_variable => {
                const v = self.pop();
                const name = try self.popString();
                try self.setVariable(name, v);
            },
            .define_local => {
                const v = self.pop();
                const name = try self.popString();
                try self.defineLocal(name, v);
            },
            .define_local2 => {
                const name = try self.popString();
                // The existence test walks the PROTOTYPE chain, so a name
                // the prototype already carries is left alone.
                if (!self.inLocalScope() and self.variableSeparator(name) != null) {
                    const cur = try self.getVariable(name);
                    if (cur == .undefined_value) try self.setVariable(name, .undefined_value);
                } else if (self.vm.objects.getChained(self.localScope(), name, self.vm.case_sensitive) == null) {
                    try self.defineLocal(name, .undefined_value);
                }
            },
            .delete => {
                const name = try self.popString();
                const target = self.pop();
                if (target == .object) {
                    try self.push(.{ .boolean = self.vm.objects.deleteOwn(target.object, name, self.vm.case_sensitive) });
                } else {
                    try self.push(.{ .boolean = false });
                }
            },
            .delete2 => {
                // Errata: also pushes a success bool.
                const name = try self.popString();
                var deleted = false;
                // A PATH deletes on the object the path names, not on the
                // scope chain: `delete o.a` removes `a` from `o`. Only a
                // bare name walks the scopes (corpus delete2).
                if (self.variableSeparator(name)) |sep| {
                    const target = try self.getVariable(name[0..sep]);
                    if (target == .object) {
                        deleted = self.vm.objects.deleteOwn(
                            target.object,
                            name[sep + 1 ..],
                            self.vm.case_sensitive,
                        );
                    } else if (target != .null_value and target != .undefined_value) {
                        try self.vm.traceLine(S("Parameters of primitive types are no longer coerced into the required type - Object."));
                    }
                } else {
                    var cur = self.scope;
                    while (cur != 0 and !deleted) {
                        deleted = self.vm.objects.deleteOwn(self.scopeObject(cur), name, self.vm.case_sensitive);
                        cur = self.vm.objects.get(cur).scope_parent;
                    }
                }
                try self.push(.{ .boolean = deleted });
            },

            // --- ES3 ops --------------------------------------------------
            .add2 => {
                const b = try self.vm.toPrimitiveAddThrowing(self.pop());
                const a = try self.vm.toPrimitiveAddThrowing(self.pop());
                if (a == .string or b == .string) {
                    const sa = try self.vm.toStringThrowing(a);
                    const sb = try self.vm.toStringThrowing(b);
                    try self.push(.{ .string = try strings.concat(self.vm.arena(), sa, sb) });
                } else {
                    // `to_primitive` may hand back an OBJECT — a `valueOf`
                    // that returns one — and the numeric coercion then
                    // calls `valueOf` a SECOND time. The corpus counts the
                    // calls (add2's objValue3).
                    const na = try self.vm.toNumberThrowing(a);
                    const nb = try self.vm.toNumberThrowing(b);
                    try self.push(.{ .number = na + nb });
                }
            },
            // Both push the comparison's result VERBATIM, undefined
            // included: `undefined > 400` is undefined, not false, and
            // the corpus traces it (sound_start_stop, lessthan2).
            .less2 => {
                const b = self.pop();
                const a = self.pop();
                try self.push(try self.vm.abstractLess(a, b));
            },
            .greater => {
                const b = self.pop();
                const a = self.pop();
                try self.push(try self.vm.abstractLess(b, a));
            },
            .equals2 => {
                const b = self.pop();
                const a = self.pop();
                try self.push(.{ .boolean = try self.vm.abstractEquals(a, b) });
            },
            .strict_equals => {
                const b = self.pop();
                const a = self.pop();
                try self.push(.{ .boolean = self.vm.strictEquals(a, b) });
            },
            .to_number => {
                const n = try self.popNumber();
                try self.push(.{ .number = n });
            },
            .to_string => {
                const s = try self.popString();
                try self.push(.{ .string = s });
            },
            .type_of => {
                const v = self.pop();
                try self.push(.{ .string = self.vm.typeOf(v) });
            },
            .increment => {
                const n = try self.popNumber();
                try self.push(.{ .number = n + 1 });
            },
            .decrement => {
                const n = try self.popNumber();
                try self.push(.{ .number = n - 1 });
            },

            // --- bitwise --------------------------------------------------
            .bit_and => try self.bitOp(.and_op),
            .bit_or => try self.bitOp(.or_op),
            .bit_xor => try self.bitOp(.xor_op),
            .bit_lshift => try self.shiftOp(.left),
            .bit_rshift => try self.shiftOp(.right_signed),
            .bit_urshift => try self.shiftOp(.right_unsigned),

            // --- objects --------------------------------------------------
            .get_member => {
                const name = try self.popString();
                const target = self.pop();
                try self.push(try self.memberGet(target, name));
            },
            .set_member => {
                const v = self.pop();
                const name = try self.popString();
                const target = self.pop();
                try self.memberSet(target, name, v);
            },
            // A count outside 0..i32::MAX pops NOTHING and pushes
            // undefined — the elements already on the stack stay there
            // (corpus init_array_invalid).
            .init_array => {
                const n = try self.popNumber();
                if (std.math.isNan(n) or n < 0 or n > 2147483647) {
                    try self.push(.undefined_value);
                } else {
                    const count: usize = @intFromFloat(n);
                    const arr = try self.vm.newArray();
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try self.vm.arraySet(arr, @intCast(i), self.pop());
                    }
                    try self.push(.{ .object = arr });
                }
            },
            .init_object => {
                const n = try self.popNumber();
                if (std.math.isNan(n) or n < 0 or n > 2147483647) {
                    try self.push(.undefined_value);
                } else {
                    const count: usize = @intFromFloat(n);
                    const obj = try self.vm.newObject();
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const v = self.pop();
                        const key = try self.popString();
                        // A full `set`, not a raw put: an object literal
                        // may name `__proto__`, and that reparents the
                        // literal (ruffle action_init_object -> set).
                        try self.memberSet(.{ .object = obj }, key, v);
                    }
                    try self.push(.{ .object = obj });
                }
            },
            .enumerate => {
                const name = try self.popString();
                const target = try self.getVariable(name);
                // UNDEFINED, not null, is the end-of-enumeration sentinel
                // (ruffle activation.rs:1041). Enumerating a non-object
                // leaves just the sentinel, and the SWF traces it.
                try self.push(.undefined_value);
                if (target == .object) try self.pushEnumKeys(target.object);
            },
            .enumerate2 => {
                const target = self.pop();
                try self.push(.undefined_value);
                if (target == .object) try self.pushEnumKeys(target.object);
            },
            .instance_of => {
                const ctor = self.pop();
                const obj = self.pop();
                try self.push(.{ .boolean = try self.valueInstanceOf(obj, ctor) });
            },
            .implements_op => {
                // Pops the constructor, a count, then that many interface
                // constructors; their PROTOTYPES are recorded on the
                // implementing constructor's prototype. SWF7+ only
                // (ruffle activation.rs:1502-1548).
                const ctor = self.pop();
                const count_v = self.pop();
                var count: usize = 0;
                if (count_v.isPrimitive()) {
                    const n = try self.vm.toNumber(count_v);
                    if (!std.math.isNan(n) and n > 0) count = @intFromFloat(@min(n, 255));
                }
                count = @min(count, self.vm.stack.items.len);
                var list: std.ArrayList(ObjectHandle) = .empty;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const iface = self.pop();
                    if (iface != .object) continue;
                    const ip = self.vm.objects.getChained(iface.object, S("prototype"), self.vm.case_sensitive) orelse continue;
                    if (ip != .object) continue;
                    // A DISPLAY OBJECT is not an interface: Flash keeps a
                    // clip as its own kind of value, and only a plain
                    // object counts here.
                    const n = self.vm.objects.get(ip.object).native;
                    if (n == .clip or n == .display or n == .removed_display) continue;
                    try list.append(self.vm.arena(), ip.object);
                }
                if (count > 0 and self.swf_version >= 7 and ctor == .object) {
                    const cp = self.vm.objects.getChained(ctor.object, S("prototype"), self.vm.case_sensitive) orelse Value.undefined_value;
                    // ONCE. Ruffle's `set_interfaces` is a
                    // `get_or_insert`, so a second `implements` on the
                    // same class is ignored outright rather than
                    // replacing the first (corpus
                    // interface_implements_op).
                    if (cp == .object and !self.vm.objects.get(cp.object).interfaces_set) {
                        self.vm.objects.get(cp.object).interfaces = try list.toOwnedSlice(self.vm.arena());
                        self.vm.objects.get(cp.object).interfaces_set = true;
                    }
                }
            },
            .cast_op => {
                const obj = self.pop();
                const ctor = self.pop();
                // "For some reason, FP does this useless extra coercion"
                // — a primitive left operand is BOXED and the box thrown
                // away, so a monkey-patched String constructor runs
                // (corpus instanceof_coercions).
                if (obj != .object) {
                    _ = try @import("globals/globals.zig").boxPrimitive(self.vm, obj);
                }
                try self.push(if (try self.valueInstanceOf(obj, ctor)) obj else .null_value);
            },
            .extends_op => {
                const superclass = self.pop();
                const subclass = self.pop();
                if (subclass == .object and superclass == .object) {
                    const proto = try self.vm.objects.create();
                    const super_proto = self.vm.objects.getChained(superclass.object, S("prototype"), self.vm.case_sensitive) orelse Value.undefined_value;
                    self.vm.objects.get(proto).proto = super_proto;
                    try self.vm.objects.putWithAttrs(proto, S("constructor"), superclass, .{ .dont_enum = true }, self.vm.case_sensitive);
                    try self.vm.objects.putWithAttrs(proto, S("__constructor__"), superclass, .{ .dont_enum = true }, self.vm.case_sensitive);
                    try self.vm.objects.putWithAttrs(subclass.object, S("prototype"), .{ .object = proto }, .{ .dont_enum = true, .dont_delete = true }, self.vm.case_sensitive);
                }
            },

            // --- calls ----------------------------------------------------
            .call_function => {
                const name = try self.popString();
                const args = try self.popArgs();
                const hit = try self.getVariableHit(name);
                const f = if (hit) |h| h.value else Value.undefined_value;
                // The scope object that provided the name is `this` for the
                // call (ruffle CallableValue::Callable) — inside a `with`
                // that is the with target, not the enclosing `this`.
                const call_this: Value = if (hit) |h|
                    (if (h.owner != 0) Value{ .object = h.owner } else self.this)
                else
                    self.this;
                // A bare `super(...)` reaches here when the compiler kept
                // it as a named variable rather than a register.
                const r = if (isSuper(self.vm, f))
                    try self.vm.callSuper(f.object, args)
                else
                    try self.vm.callFunction(f, call_this, args);
                try self.push(r);
                if (self.baseClipGone()) return .{ .return_value = .undefined_value };
            },
            .call_method => {
                const name_v = self.pop();
                const target = self.pop();
                const args = try self.popArgs();
                // A method call on undefined/null pushes undefined and
                // continues WITHOUT the removed-base-clip check below —
                // which is why `blah.f()` on a removed clip runs the next
                // statement but `obj.f()` does not (ruffle
                // action_call_method's early return, activation.rs:823).
                if (target == .undefined_value or target == .null_value) {
                    try self.push(.undefined_value);
                    return .next;
                }
                // ruffle action_call_method: undefined ⇒ "", otherwise
                // COERCE (an object whose toString yields "" also selects
                // the call-as-function path).
                const name: strings.AvmString = if (name_v == .undefined_value)
                    S("")
                else
                    try self.vm.toStringValue(name_v);
                const result = if (isSuper(self.vm, target)) blk: {
                    // `super()` constructs; `super.m()` dispatches upward.
                    break :blk if (name.len == 0)
                        try self.vm.callSuper(target.object, args)
                    else
                        try self.vm.callSuperMethod(target.object, name, args);
                } else if (name.len == 0)
                    try self.vm.callFunction(target, .undefined_value, args)
                else blk: {
                    const m = try self.memberGet(target, name);
                    // The callee's `super` starts at the prototype level
                    // that actually owns this method — but never at the
                    // object itself: a method stored directly on `this`
                    // still gets a `super` one layer up, or `super` would
                    // find that same method and recurse (ruffle
                    // object.rs:299 `depth.max(1)`).
                    if (target == .object) {
                        const d = self.vm.objects.protoDepth(target.object, name, self.vm.case_sensitive) orelse 0;
                        self.vm.super_depth = @max(d, 1);
                    }
                    break :blk try self.vm.callFunction(m, target, args);
                };
                try self.push(result);
                if (self.baseClipGone()) return .{ .return_value = .undefined_value };
            },
            .new_object => {
                const name = try self.popString();
                const args = try self.popArgs();
                const ctor = self.vm.scopeGet(self.scope, name) orelse Value.undefined_value;
                try self.push(try self.vm.construct(ctor, args));
                if (self.baseClipGone()) return .{ .return_value = .undefined_value };
            },
            .new_method => {
                const name_v = self.pop();
                const target = self.pop();
                const args = try self.popArgs();
                // Same early return as CallMethod — see there.
                if (target == .undefined_value or target == .null_value) {
                    try self.push(.undefined_value);
                    return .next;
                }
                const name: strings.AvmString = if (name_v == .undefined_value)
                    S("")
                else
                    try self.vm.toStringValue(name_v);
                const ctor: Value = if (name.len == 0)
                    target
                else
                    try self.memberGet(target, name);
                try self.push(try self.vm.construct(ctor, args));
                if (self.baseClipGone()) return .{ .return_value = .undefined_value };
            },
            .return_op => return .{ .return_value = self.pop() },
            .throw => {
                self.vm.pending_throw = self.pop();
                return error.Avm1Thrown;
            },

            // --- misc -----------------------------------------------------
            .trace => {
                // trace ALWAYS prints "undefined" even in SWF <= 6, where
                // undefined otherwise coerces to "" (ruffle
                // activation.rs action_trace).
                const v = self.pop();
                if (v == .undefined_value) {
                    try self.vm.traceLine(S("undefined"));
                } else {
                    // A `toString` that throws still gets a LINE — the
                    // fallback text — and then the throw carries on
                    // (corpus coerce_to_primitive_resolve).
                    const s = self.vm.toStringThrowing(v) catch |e| {
                        try self.vm.traceLine(S("[type Object]"));
                        return e;
                    };
                    try self.vm.traceLine(s);
                }
            },
            .target_path => {
                // The DOT path (`_level0.mc.child`) — NOT `_target`'s
                // slash form. Anything that isn't a display object, a
                // string path included, gives undefined.
                const v = self.pop();
                if (stage.targetOfValue(self.vm, v)) |t| {
                    try self.push(.{ .string = try stage.dotPath(self.vm, t) });
                } else {
                    try self.push(.undefined_value);
                }
            },
            .set_target2 => {
                const v = self.pop();
                // Everything is invalid once the base clip is gone.
                if (self.base_clip != 0 and stage.targetOf(self.vm, self.base_clip) == null) {
                    self.target_clip = null;
                } else if (v == .undefined_value) {
                    // SWF<=6 treats an undefined target as "back to base";
                    // SWF7+ nulls it (corpus tell_target_invalid_swf6).
                    if (self.swf_version > 6) self.target_clip = null else self.setTargetClip(self.base_clip);
                } else {
                    // Note this coerces even a clip to a string first, so
                    // a plain object's toString runs and is observable.
                    try self.setTarget(try self.vm.toStringValue(v));
                }
            },
            .get_property => {
                const index = try self.popNumber();
                // NOT popString: an operand that already IS a clip must
                // short-circuit, and otherwise its toString is observable.
                const path = self.pop();
                const target = try self.resolveDisplayTarget(path);
                const prop = propertyIndex(index);
                if (target != null and prop != null) {
                    try self.push(try stage.getByIndex(self.vm, target.?, prop.?));
                } else {
                    try self.push(.undefined_value);
                }
            },
            .set_property => {
                const v = self.pop();
                const index = try self.popNumber();
                const path = self.pop();
                const target = try self.resolveDisplayTarget(path);
                const prop = propertyIndex(index);
                if (prop) |i| {
                    const read_only = stage.PROPERTIES[i].set == null;
                    if (target == null or read_only) {
                        // Coerce anyway — valueOf/toString are observable
                        // even though the write goes nowhere.
                        _ = try stage.actionPropertyCoerce(self.vm, i, v);
                    } else {
                        try stage.setByIndex(self.vm, target.?, i, v);
                    }
                }
            },
            .clone_sprite => {
                // Pops depth, the NEW NAME, then the source path.
                const depth = value_mod.toInt32(try self.popNumber());
                const name = try self.popString();
                const source = self.pop();
                if (try self.resolveDisplayTarget(source)) |t| {
                    _ = try stage.cloneSprite(self.vm, t, name, depth, .undefined_value);
                }
            },
            .remove_sprite => {
                const target = self.pop();
                if (try self.resolveDisplayTarget(target)) |t| {
                    if (try stage.removeDisplayObject(self.vm, t)) {
                        // If that killed our own target, fall back to the
                        // base clip — which setTargetClip nulls in turn if
                        // the base is gone too (ruffle activation.rs:1859).
                        if (self.target_clip) |h| {
                            if (stage.targetOf(self.vm, h) == null) {
                                self.setTargetClip(self.base_clip);
                            }
                        }
                    }
                }
            },
            .start_drag => {
                // The operands come off in this order regardless of whether
                // the target resolves, and the constraint rectangle is
                // popped y_max, x_max, y_min, x_min.
                const target = self.pop();
                // The TARGET is resolved (and so coerced to a string)
                // BEFORE the numbers are popped — the corpus watches the
                // order of the valueOf/toString calls
                // (swf4_actions_coercion_order).
                //
                // `allow_empty = true` here, unlike hitTest/getBounds: a
                // bare `startDrag()` drags the current target clip.
                const t = if (stage.targetOfValue(self.vm, target)) |dt|
                    dt
                else blk: {
                    const s = try self.vm.toStringValue(target);
                    const start = self.targetClipOrRoot();
                    if (s.len == 0) break :blk stage.targetOf(self.vm, start);
                    const h = try self.resolveTargetPath(self.rootHandle(), start, s, true, false);
                    break :blk if (h) |hh| stage.targetOf(self.vm, hh) else null;
                };
                const lock_center = (try self.popNumber()) == 1;
                const constrain = (try self.popNumber()) == 1;
                var rect: ?[4]f64 = null;
                if (constrain) {
                    const y_max = try self.popNumber();
                    const x_max = try self.popNumber();
                    const y_min = try self.popNumber();
                    const x_min = try self.popNumber();
                    rect = .{ x_min, y_min, x_max, y_max };
                }
                if (t) |dt| stage.startDrag(self.vm, dt, lock_center, rect);
            },
            .end_drag => stage.stopDrag(self.vm),
            .play => self.hostSetPlaying(true),
            .stop => self.hostSetPlaying(false),
            .next_frame => self.hostNextPrev(1),
            .previous_frame => self.hostNextPrev(-1),
            .toggle_quality, .stop_sounds => {},
            .call => {
                // Runs a frame's DoActions INLINE, without moving the
                // playhead (ruffle action_call:755-794). A Number is a
                // frame on the current target; anything else is coerced to
                // a string and resolved as a variable path, whose tail is
                // tried as a frame NUMBER before falling back to a label.
                const v = self.pop();
                var target: ?stage.Target = null;
                var frame: ?u16 = null;
                if (v == .number) {
                    target = stage.targetOf(self.vm, self.targetClipOrRoot());
                    const n = value_mod.toUint32(v.number);
                    frame = if (n <= 65535) @intCast(n) else null;
                } else {
                    const path = try self.vm.toStringValue(v);
                    if (try self.resolveFramePath(self.targetClipOrRoot(), path)) |hit| {
                        target = hit.target;
                        frame = hit.frame;
                    }
                }
                if (target) |t| {
                    if (t.clip) |clip| {
                        if (frame) |f| try self.runFrameActions(clip, f);
                    }
                }
                // The called frame may have removed us.
                if (self.baseClipGone()) return .{ .return_value = .undefined_value };
            },
            .fs_command2 => {
                const n = try self.popNumber();
                const count: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(n);
                var i: usize = 0;
                while (i < count) : (i += 1) _ = self.pop();
                try self.push(.{ .number = -1 });
            },
            else => {},
        }
        return .next;
    }

    // --- op helpers -------------------------------------------------------

    fn popArgs(self: *Activation) ![]Value {
        const n = try self.popNumber();
        const count: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(@min(n, 255));
        const args = try self.vm.arena().alloc(Value, count);
        for (args) |*a| a.* = self.pop();
        return args;
    }

    const BitKind = enum { and_op, or_op, xor_op };
    fn bitOp(self: *Activation, kind: BitKind) !void {
        const b = value_mod.toInt32(try self.popNumber());
        const a = value_mod.toInt32(try self.popNumber());
        const r: i32 = switch (kind) {
            .and_op => a & b,
            .or_op => a | b,
            .xor_op => a ^ b,
        };
        try self.push(.{ .number = @floatFromInt(r) });
    }

    const ShiftKind = enum { left, right_signed, right_unsigned };
    fn shiftOp(self: *Activation, kind: ShiftKind) !void {
        const shift: u5 = @intCast(value_mod.toUint32(try self.popNumber()) & 31);
        const a = try self.popNumber();
        switch (kind) {
            .left => {
                const v = value_mod.toInt32(a) << shift;
                try self.push(.{ .number = @floatFromInt(v) });
            },
            .right_signed => {
                const v = value_mod.toInt32(a) >> shift;
                try self.push(.{ .number = @floatFromInt(v) });
            },
            // SWF8 and SWF9 ONLY: the shift is unsigned but the result
            // is a signed i32, so `4294967295 >>> 0` is -1 there and
            // 4294967295 at every other version. Two corpus dirs run the
            // same source at 8 and at 17 to pin it.
            .right_unsigned => {
                const u = value_mod.toUint32(a) >> shift;
                const signed = self.vm.swf_version >= 8 and self.vm.swf_version <= 9;
                const n: f64 = if (signed)
                    @floatFromInt(@as(i32, @bitCast(u)))
                else
                    @floatFromInt(u);
                try self.push(.{ .number = n });
            },
        }
    }

    /// for..in enumerates own AND inherited properties (Flash walks the
    /// whole __proto__ chain), skipping DontEnum, version-gated, and
    /// names already emitted by a nearer object (shadowing).
    fn pushEnumKeys(self: *Activation, h: ObjectHandle) !void {
        var seen: std.ArrayList(strings.AvmString) = .empty;
        defer seen.deinit(self.vm.arena());

        // Display children come LAST in the enumeration, so they are pushed
        // FIRST — the SWF pops these, making trace order the reverse of push
        // order. `enumerateKeys` already yields highest-depth-first, and
        // pushing in that order pops them back the same way.
        var kids: std.ArrayList([]const u16) = .empty;
        defer kids.deinit(self.vm.arena());
        try stage.enumerateKeys(self.vm, h, &kids);
        var ki = kids.items.len;
        while (ki > 0) {
            ki -= 1;
            try self.push(.{ .string = kids.items[ki] });
        }

        var current: Value = .{ .object = h };
        var depth: u32 = 0;
        while (current == .object and depth < 64) : (depth += 1) {
            const o = self.vm.objects.get(current.object);
            var i: usize = 0;
            while (i < o.props.items.len) : (i += 1) {
                const p = o.props.items[i];
                // Only DontEnum hides a key. A VERSION-gated property
                // still enumerates — it just reads back as undefined
                // (ruffle `get_keys` filters on `is_enumerable` alone;
                // corpus textsnapshot_props_swf5 lists all nine methods
                // at SWF5 and then reads every one as undefined).
                if (p.attrs.dont_enum) continue;
                var dup = false;
                for (seen.items) |k| {
                    const same = if (self.vm.case_sensitive)
                        strings.eql(k, p.key)
                    else
                        strings.eqlIgnoreCase(k, p.key);
                    if (same) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                try seen.append(self.vm.arena(), p.key);
                try self.push(.{ .string = p.key });
            }
            current = o.proto;
        }
    }

    /// AS2 added interfaces, so this cannot just walk the prototype chain:
    /// every step of the chain carries its own interface tree, which must
    /// be searched too (ruffle object.rs is_instance_of:325-352).
    /// `obj instanceof class`. A primitive `obj` is false WITHOUT
    /// coercing anything; otherwise the CLASS is coerced to an object
    /// (boxing a primitive class, which the corpus hears) and so is its
    /// prototype.
    fn valueInstanceOf(self: *Activation, obj: Value, class: Value) !bool {
        if (obj != .object) return false;
        // A clip that has been REMOVED is no longer an instance of
        // anything — its reference is dead before the class is even
        // looked at (but after it is coerced).
        const n = self.vm.objects.get(obj.object).native;
        const is_display = n == .clip or n == .display or n == .removed_display;
        const dead = is_display and stage.targetOf(self.vm, obj.object) == null;
        const boxing = @import("globals/globals.zig");
        const cls = if (class == .object) class else try boxing.boxPrimitive(self.vm, class);
        if (cls != .object) return false;
        // A dead clip as the CLASS resolves to nothing either — ruffle
        // coerces it through the same path-reference machinery.
        const cls_n = self.vm.objects.get(cls.object).native;
        if ((cls_n == .clip or cls_n == .display or cls_n == .removed_display) and
            stage.targetOf(self.vm, cls.object) == null) return false;
        // The RAW own slot: ruffle's `Object::prototype` "ignores
        // getters, __proto__, and SWF version attributes", so an
        // inherited `prototype` does not count and a version-gated one
        // still does.
        const o = self.vm.objects.get(cls.object);
        const idx = o.find(S("prototype"), self.vm.case_sensitive) orelse return false;
        const proto_v = o.props.items[idx].value;
        const proto = if (proto_v == .object) proto_v else try boxing.boxPrimitive(self.vm, proto_v);
        if (proto != .object or dead) return false;
        // The interface-aware chain walk lives in `instanceOf`; reuse it
        // by handing it the already-coerced pair.
        return self.instanceOfProto(obj.object, proto.object);
    }

    fn instanceOf(self: *Activation, obj: Value, ctor: Value) bool {
        if (obj != .object or ctor != .object) return false;
        const proto = self.vm.objects.getChained(ctor.object, S("prototype"), self.vm.case_sensitive) orelse return false;
        if (proto != .object) return false;
        return self.instanceOfProto(obj.object, proto.object);
    }

    fn instanceOfProto(self: *Activation, obj_h: ObjectHandle, proto_h: ObjectHandle) bool {
        var stack: std.ArrayList(ObjectHandle) = .empty;
        defer stack.deinit(self.vm.arena());
        var cur = self.vm.protoValue(obj_h);
        var depth: u32 = 0;
        while (cur == .object and depth < 256) : (depth += 1) {
            stack.append(self.vm.arena(), cur.object) catch return false;
            while (stack.pop()) |iface| {
                if (iface == proto_h) return true;
                for (self.vm.objects.get(iface).interfaces) |i| {
                    stack.append(self.vm.arena(), i) catch return false;
                }
            }
            cur = self.vm.protoValue(cur.object);
        }
        return false;
    }

    fn poolValue(self: *Activation, idx: u16) Value {
        const pools = self.vm.pools.items;
        if (self.constant_pool < pools.len) {
            const pool = pools[self.constant_pool];
            if (idx < pool.len) return .{ .string = pool[idx] };
        }
        return .undefined_value;
    }

    fn loadConstantPool(self: *Activation, count: u16, raw: []const u8) !void {
        var list = try self.vm.arena().alloc(strings.AvmString, count);
        var r = rdr.Reader.init(raw);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const bytes = r.readString() catch "";
            list[i] = try self.swfStr(bytes);
        }
        try self.vm.pools.append(self.vm.gpa, list);
        const idx: u32 = @intCast(self.vm.pools.items.len - 1);
        self.vm.active_pool = idx;
        self.constant_pool = idx;
    }

    fn seek(self: *Activation, offset: i16) void {
        const target = @as(i64, @intCast(self.r.pos)) + offset;
        if (target < 0) {
            self.r.pos = 0;
        } else if (target > self.code.len) {
            self.r.pos = self.code.len;
        } else {
            self.r.pos = @intCast(target);
        }
        self.r.byteAlign();
    }

    /// SetTarget("") retargets to the base clip. Any other path resolves
    /// through the DISPLAY tree; failure sets `target_clip = null` at every
    /// SWF version, which makes movie control silently no-op while
    /// variables fall back to _root. ruffle activation.rs:3060-3089.
    /// ruffle `set_target_clip`: "The target should revert to `None` if the
    /// clip is removed." Resetting to a base clip that has since been
    /// destroyed must therefore yield the FAILED state, not a dangling
    /// target — corpus target_clip_removed.
    fn setTargetClip(self: *Activation, h: ?ObjectHandle) void {
        if (h) |handle| {
            if (self.vm.objects.get(handle).native == .clip and
                stage.targetOf(self.vm, handle) == null)
            {
                self.target_clip = null;
                return;
            }
        }
        self.target_clip = h;
    }

    fn setTarget(self: *Activation, path: strings.AvmString) !void {
        if (path.len == 0) {
            self.setTargetClip(self.base_clip);
            return;
        }
        const root = self.rootHandle();
        const resolved = try self.resolveTargetPath(root, self.base_clip, path, true, false);
        // Every property is invalid once the base clip has been removed.
        const base_removed = self.base_clip != 0 and
            stage.targetOf(self.vm, self.base_clip) == null;
        if (!base_removed) {
            if (resolved) |h| {
                if (stage.targetOf(self.vm, h) != null) {
                    self.setTargetClip(h);
                    return;
                }
            }
        }
        self.target_clip = null;
    }

    /// Variables and StartDrag: an invalid target reads from _root.
    fn targetClipOrRoot(self: *Activation) ObjectHandle {
        if (self.target_clip) |h| return h;
        return if (self.vm.root_object == .object) self.vm.root_object.object else 0;
    }

    /// SetTarget2's re-scope: an invalid target falls back to the BASE
    /// clip, not the root.
    fn targetClipOrBaseClip(self: *Activation) ObjectHandle {
        return self.target_clip orelse self.base_clip;
    }

    fn rootHandle(self: *Activation) ObjectHandle {
        return if (self.vm.root_object == .object) self.vm.root_object.object else 0;
    }

    /// Substitute the retarget when a scope walk reaches the timeline
    /// node. Ruffle clones the chain with the Target scope's object
    /// swapped (`Scope::new_target_scope`); our chain nodes ARE the
    /// objects, so cloning would mean mutating state that closures share.
    /// Substituting on the way past is equivalent and side-effect free.
    /// The innermost scope for DEFINING things. Inside a function this is
    /// the local scope; in timeline code it is the (possibly retargeted)
    /// timeline scope — `tellTarget(x) { var n = 1 }` defines n on x, and
    /// reading it back must find it there.
    /// Is there a LOCAL scope between here and the timeline? Ruffle walks
    /// the chain and stops at the first Local (yes) or Target (no); a
    /// `with` scope is neither and is walked through.
    fn inLocalScope(self: *Activation) bool {
        var node = self.scope;
        while (node != 0) {
            if (node == self.timeline_scope) return false;
            if (!self.vm.objects.get(node).is_with_scope) return true;
            node = self.vm.objects.get(node).scope_parent;
        }
        return false;
    }

    /// `var name = value`. Outside a function a dotted or colon path is a
    /// path ASSIGNMENT, not a local named with dots. Otherwise the write
    /// lands on the innermost non-`with` scope — unless the `with` target
    /// already owns the name, in which case it belongs to the target —
    /// and it goes through `setProperty`, so virtual setters anywhere on
    /// the prototype chain run (corpus define_local, with_variable_scopes).
    fn defineLocal(self: *Activation, name: strings.AvmString, v: Value) !void {
        if (!self.inLocalScope() and self.variableSeparator(name) != null) {
            return self.setVariable(name, v);
        }
        var node = self.scope;
        while (node != 0 and self.vm.objects.get(node).is_with_scope) {
            const target = self.scopeObject(node);
            if (self.vm.objects.hasOwn(target, name, self.vm.case_sensitive)) break;
            node = self.vm.objects.get(node).scope_parent;
        }
        const target = self.scopeObject(if (node != 0) node else self.scope);
        try self.vm.setProperty(target, name, v, .{ .object = target });
        self.vm.notifyTextBinding(target, name, v) catch {};
    }

    fn localScope(self: *Activation) ObjectHandle {
        return self.scopeObject(self.scope);
    }

    fn scopeObject(self: *Activation, node: ObjectHandle) ObjectHandle {
        const values = self.vm.objects.get(node).scope_values;
        if (values != 0) return values;
        if (node != self.timeline_scope or self.timeline_scope == 0) return node;
        const t = self.targetClipOrRoot();
        return if (t != 0) t else node;
    }

    const FrameHit = struct { target: stage.Target, frame: ?u16 };

    /// `"/clip:label"` — split at the rightmost separator exactly as
    /// getVariable does, resolve the head as a target path, then read the
    /// tail as a frame number first and a label second.
    fn resolveFramePath(self: *Activation, start: ObjectHandle, path: strings.AvmString) !?FrameHit {
        const root = self.rootHandle();
        var head: strings.AvmString = path;
        var tail: strings.AvmString = path;
        if (self.variableSeparator(path)) |sep| {
            head = path[0..sep];
            tail = path[sep + 1 ..];
        } else {
            head = path[0..0];
        }
        const h = try self.resolveTargetPath(root, start, head, true, true) orelse return null;
        const t = stage.targetOf(self.vm, h) orelse return null;
        const clip = t.clip orelse return null;
        if (stage.strictFrameNumber(tail)) |n| {
            const u = value_mod.toUint32(@floatFromInt(n));
            return .{ .target = t, .frame = if (u <= 65535) @intCast(u) else null };
        }
        return .{ .target = t, .frame = stage.frameLabel(self.vm, clip, tail) };
    }

    /// Execute every DoAction on `frame` right now, with `clip` as the
    /// base clip — the same activation shape Player.runOneFrame builds.
    fn runFrameActions(self: *Activation, clip: *movie_clip_mod.MovieClip, frame: u16) !void {
        if (self.vm.call_depth >= self.vm.max_call_depth) return;
        var codes: std.ArrayList([]const u8) = .empty;
        defer codes.deinit(self.vm.arena());
        try stage.frameActions(clip, frame, &codes, self.vm.arena());
        if (codes.items.len == 0) return;
        const clip_obj = try stage.clipObject(self.vm, clip);
        self.vm.call_depth += 1;
        defer self.vm.call_depth -= 1;
        for (codes.items) |code| {
            var act = Activation.init(self.vm, code, .{ .object = clip_obj }, clip_obj, self.constant_pool);
            _ = try act.run();
        }
    }

    /// GetProperty/SetProperty's target operand. An empty path means "the
    /// current target clip"; anything else resolves as a target path.
    /// A missing target yields null and the op pushes undefined.
    fn resolveDisplayTarget(self: *Activation, path: Value) !?stage.Target {
        // A value that already is a clip is used directly.
        if (stage.targetOfValue(self.vm, path)) |t| return t;
        const s = try self.vm.toStringValue(path);
        if (s.len == 0) {
            const h = self.target_clip orelse return null;
            return stage.targetOf(self.vm, h);
        }
        const resolved = try self.resolveTargetPath(self.rootHandle(), self.targetClipOrRoot(), s, true, false) orelse
            return null;
        return stage.targetOf(self.vm, resolved);
    }

    // --- host bridges (movie control) -------------------------------------

    /// Movie control acts on the target clip ONLY. A failed SetTarget
    /// leaves `target_clip` null and every control op silently does
    /// nothing — unlike variables, which fall back to _root.
    fn currentClip(self: *Activation) ?*anyopaque {
        const h = self.target_clip orelse return null;
        const t = stage.targetOf(self.vm, h) orelse return null;
        return @ptrCast(t.clip);
    }

    /// A script whose OWN clip has been removed stops where it is. Ruffle
    /// checks this after every call-shaped action (`continue_if_base_clip_
    /// exists`, activation.rs:3052) rather than per instruction, so the
    /// statement that did the removing completes and the next call does
    /// not happen — corpus removed_clip_halts_script traces the difference.
    fn baseClipGone(self: *Activation) bool {
        return self.base_clip != 0 and stage.targetOf(self.vm, self.base_clip) == null;
    }

    /// GotoFrame2's target: the retarget, else the root.
    fn clipOrRoot(self: *Activation) ?*anyopaque {
        const t = stage.targetOf(self.vm, self.targetClipOrRoot()) orelse return null;
        return @ptrCast(t.clip);
    }

    fn hostGoto(self: *Activation, clip: ?*anyopaque, frame: u16, play: ?bool) void {
        const host = self.vm.host;
        const c = clip orelse return;
        if (host.goto_frame) |f| f(host.ctx.?, c, frame, play orelse false);
    }

    fn hostGotoLabelOn(self: *Activation, clip: ?*anyopaque, label: strings.AvmString, play: ?bool) void {
        const host = self.vm.host;
        const c = clip orelse return;
        if (host.goto_label) |f| _ = f(host.ctx.?, c, label, play orelse false);
    }

    fn hostGotoFrame(self: *Activation, frame: u16, play: ?bool) void {
        self.hostGoto(self.currentClip(), frame, play);
    }

    fn hostGotoLabel(self: *Activation, label: strings.AvmString, play: ?bool) void {
        self.hostGotoLabelOn(self.currentClip(), label, play);
    }

    fn hostSetPlaying(self: *Activation, playing: bool) void {
        const host = self.vm.host;
        const clip = self.currentClip() orelse return;
        if (host.set_playing) |f| f(host.ctx.?, clip, playing);
    }

    fn hostNextPrev(self: *Activation, delta: i2) void {
        const host = self.vm.host;
        const clip = self.currentClip() orelse return;
        if (host.next_prev) |f| f(host.ctx.?, clip, delta);
    }
};

/// A frame reference resolved from a STRING, for callers that have no
/// Activation of their own — `MovieClip.gotoAndPlay/gotoAndStop`, whose
/// argument is a full variable path and can therefore redirect the goto to
/// a completely different clip (`clip.gotoAndStop("/:5")` moves _root).
/// `start` is the clip the method was called on, which is where a relative
/// path is anchored.
///
/// Null when no Activation is running (pure-VM tests) or the path does not
/// resolve; the caller then falls back to a plain label lookup.
pub fn framePathFromNative(
    vm: *Vm,
    start: ObjectHandle,
    path: strings.AvmString,
) !?struct { clip: *movie_clip_mod.MovieClip, frame: ?u16 } {
    const p = vm.current_activation orelse return null;
    const act: *Activation = @ptrCast(@alignCast(p));
    const hit = try act.resolveFramePath(start, path) orelse return null;
    return .{ .clip = hit.target.clip orelse return null, .frame = hit.frame };
}

/// Resolve a method ARGUMENT that names a display object — either the
/// object itself or a target path string (`getBounds('/clip')`,
/// `hitTest('../upper')`). Ports ruffle's `resolve_target_display_object`
/// with `allow_empty = false`, which is what makes `hitTest('')` false
/// rather than a clip testing against itself. Needs the running Activation
/// for the same reason `framePathFromNative` does.
///
/// Note the flags: `first_element = true`, `handle_this = false` — a target
/// argument may start with `_root`/`_levelN` but `this` is not a keyword
/// here, unlike in a variable path.
pub fn targetFromNative(vm: *Vm, start_in: ObjectHandle, v: Value) !?stage.Target {
    if (stage.targetOfValue(vm, v)) |t| return t;
    const s = try vm.toStringValue(v);
    if (s.len == 0) return null;
    const p = vm.current_activation orelse return null;
    const act: *Activation = @ptrCast(@alignCast(p));
    // `start_in == 0` means "anchor at the caller's target clip" rather
    // than at the object the method was called on — which is what
    // `setMask` does (ruffle passes `target_clip_or_root`).
    const start = if (start_in != 0) start_in else act.targetClipOrRoot();
    const h = try act.resolveTargetPath(act.rootHandle(), start, s, true, false) orelse return null;
    return stage.targetOf(vm, h);
}

/// Is this value a `super` view rather than an ordinary object?
fn isSuper(vm: *Vm, v: Value) bool {
    return v == .object and vm.objects.get(v.object).native == .super_obj;
}


/// GetProperty/SetProperty's index operand. Non-finite or <= -1 is not a
/// property at all; everything else truncates toward zero, so -0.8 is
/// index 0 (`_x`) rather than an error.
fn propertyIndex(n: f64) ?usize {
    if (!std.math.isFinite(n) or n <= -1.0) return null;
    const i: usize = @intFromFloat(@max(n, 0));
    return if (i < stage.PROPERTIES.len) i else null;
}

fn ecmaMod(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b) or b == 0 or std.math.isInf(a)) return std.math.nan(f64);
    if (std.math.isInf(b)) return a;
    return @rem(a, b);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "frame operands: strict number-vs-label split" {
    const S_ = strings.ascii;
    // A fully-parsing string is a frame NUMBER...
    try testing.expectEqual(@as(?i32, 3), stage.strictFrameNumber(S_("3")));
    try testing.expectEqual(@as(?i32, -2), stage.strictFrameNumber(S_("-2")));
    try testing.expectEqual(@as(?i32, 3), stage.strictFrameNumber(S_("3.7"))); // truncated
    // ...anything with trailing junk is a LABEL, not frame 3.
    try testing.expectEqual(@as(?i32, null), stage.strictFrameNumber(S_("3x")));
    try testing.expectEqual(@as(?i32, null), stage.strictFrameNumber(S_("intro")));
    try testing.expectEqual(@as(?i32, null), stage.strictFrameNumber(S_("")));
}

test "GetProperty index operand" {
    // Non-finite or <= -1 is not a property; -0.8 truncates to _x.
    try testing.expectEqual(@as(?usize, 0), propertyIndex(-0.8));
    try testing.expectEqual(@as(?usize, null), propertyIndex(-1));
    try testing.expectEqual(@as(?usize, null), propertyIndex(std.math.nan(f64)));
    try testing.expectEqual(@as(?usize, null), propertyIndex(std.math.inf(f64)));
    try testing.expectEqual(@as(?usize, 11), propertyIndex(11));
    try testing.expectEqual(@as(?usize, null), propertyIndex(22));
}

test "variable paths split at the RIGHTMOST separator, version-gated" {
    const S_ = strings.ascii;
    const vm = try Vm.create(testing.allocator, 6);
    defer vm.destroy();
    var act = Activation.init(vm, &.{}, .undefined_value, 0, 0);

    // `a.b.c` targets `a.b` and reads `c` — not `a` then `b.c`.
    try testing.expectEqual(@as(?usize, 3), act.variableSeparator(S_("a.b.c")));
    try testing.expectEqual(@as(?usize, 1), act.variableSeparator(S_("a:b")));
    try testing.expectEqual(@as(?usize, 4), act.variableSeparator(S_("/a/b:c")));
    try testing.expectEqual(@as(?usize, null), act.variableSeparator(S_("/a/b")));

    // SWF4 has no `.` separator at all: `a.b` is one opaque name.
    act.swf_version = 4;
    try testing.expectEqual(@as(?usize, null), act.variableSeparator(S_("a.b.c")));
    try testing.expectEqual(@as(?usize, 1), act.variableSeparator(S_("a:b")));

    try testing.expect(Activation.containsSlash(S_("/a")));
    try testing.expect(!Activation.containsSlash(S_("a.b")));
}
