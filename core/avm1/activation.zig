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
        while (true) {
            if (self.vm.halted) return .next;
            if (self.vm.budget == 0) {
                self.vm.halted = true;
                return .next;
            }
            self.vm.budget -= 1;
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

    fn getRegister(self: *Activation, idx: u8) Value {
        if (self.local_registers.len > 0) {
            return if (idx < self.local_registers.len) self.local_registers[idx] else .undefined_value;
        }
        return if (idx < 4) self.vm.registers[idx] else .undefined_value;
    }

    fn setRegister(self: *Activation, idx: u8, v: Value) void {
        if (self.local_registers.len > 0) {
            if (idx < self.local_registers.len) self.local_registers[idx] = v;
            return;
        }
        if (idx < 4) self.vm.registers[idx] = v;
    }

    fn swfStr(self: *Activation, bytes: []const u8) !strings.AvmString {
        return strings.fromSwf(self.vm.arena(), bytes, self.swf_version);
    }

    fn boolResult(self: *Activation, b: bool) Value {
        // SWF4 pushes 1/0 numbers for logical results; SWF5+ booleans.
        if (self.swf_version < 5) return .{ .number = if (b) 1 else 0 };
        return .{ .boolean = b };
    }

    // --- variable paths ---------------------------------------------------

    /// Resolve a TARGET PATH to an object, walking the DISPLAY tree.
    /// Ports ruffle activation.rs:2562-2676. This is a different animal
    /// from GetMember: children are resolved before ordinary properties,
    /// and the delimiter set changes as the path is consumed.
    ///
    /// `first_element` allows `this`/`_root`/`_levelN` at the head only;
    /// `handle_this` enables the `this` keyword at all.
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
                while (path.len > 0 and path[0] == ':') path = path[1..];
                if (path.len == 0) break;
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
                const parent = t.clip.parent orelse return null; // parent of root
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
                            if (stage.childByName(t.clip, name, self.vm.case_sensitive)) |child| {
                                if (child.kind == .clip) {
                                    break :blk .{ .object = try stage.clipObject(self.vm, child.kind.clip) };
                                }
                                break :blk .{ .object = object };
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
        const root = self.rootHandle();
        if (self.variableSeparator(name)) |sep| {
            const path = name[0..sep];
            const var_name = name[sep + 1 ..];
            if (path.len == 0) return .undefined_value;
            var cur = self.scope;
            while (cur != 0) {
                const node = self.scopeObject(cur);
                if (try self.resolveTargetPath(root, node, path, true, true)) |obj| {
                    if (try self.hasVariable(obj, var_name)) {
                        return try self.memberGet(.{ .object = obj }, var_name);
                    }
                }
                cur = self.vm.objects.get(cur).scope_parent;
            }
            return .undefined_value;
        }

        // No trailing variable, but it can still be a slash path (SWF5+;
        // SWF4 always requires the trailing variable).
        if (self.swf_version >= 5 and containsSlash(name)) {
            var cur = self.scope;
            while (cur != 0) {
                const node = self.scopeObject(cur);
                if (try self.resolveTargetPath(root, node, name, false, false)) |obj| {
                    return .{ .object = obj };
                }
                cur = self.vm.objects.get(cur).scope_parent;
            }
        }

        // A plain old variable name: the scope chain, as normal.
        return try self.scopeLookup(name) orelse .undefined_value;
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
        const cs = self.vm.case_sensitive;
        // `this` is resolved BEFORE the scope chain from SWF5 on
        // (ruffle Activation::resolve:2925-2936). Timeline code has no
        // `this` binding to find otherwise — only function locals do —
        // so `this._name` reads undefined without this.
        if (self.swf_version >= 5) {
            // Below SWF6 the match is case-sensitive only inside a
            // function's local scope; timeline code is insensitive.
            const this_cs = if (self.swf_version <= 5)
                self.scope != self.timeline_scope
            else
                cs;
            const hit = if (this_cs)
                strings.eql(name, S("this"))
            else
                strings.eqlIgnoreCase(name, S("this"));
            if (hit) return self.this;
        }
        var cur = self.scope;
        while (cur != 0) {
            const node = self.scopeObject(cur);
            if (self.vm.objects.getChained(node, name, cs)) |_| {
                return try self.vm.getProperty(node, name, .{ .object = node });
            }
            if (try stage.resolveMember(self.vm, node, name)) |v| return v;
            cur = self.vm.objects.get(cur).scope_parent;
        }
        return self.vm.objects.getChained(self.vm.globals, name, cs);
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
            if (self.vm.objects.hasOwn(node, name, cs)) {
                try self.vm.objects.put(node, name, v, cs);
                return;
            }
            if (try stage.assignMember(self.vm, node, name, v)) return;
            bottom = node;
            cur = self.vm.objects.get(cur).scope_parent;
        }
        try self.vm.objects.put(bottom, name, v, cs);
    }

    // --- member access ----------------------------------------------------

    fn memberGet(self: *Activation, target: Value, name: strings.AvmString) !Value {
        switch (target) {
            .object => |h| {
                // `__proto__` is a live accessor, not a stored property.
                if (strings.eqlIgnoreCase(name, S("__proto__"))) {
                    return self.vm.objects.get(h).proto;
                }
                // A clip's own (and inherited) members win; only when
                // there is no binding at all do path props, children and
                // display props get a look in.
                if (self.vm.objects.getChained(h, name, self.vm.case_sensitive) == null) {
                    if (try stage.resolveMember(self.vm, h, name)) |v| return v;
                }
                return self.vm.getProperty(h, name, target);
            },
            .string => |s| {
                if (strings.eqlIgnoreCase(name, S("length"))) {
                    return .{ .number = @floatFromInt(s.len) };
                }
                // Methods via String.prototype on a temp box (M4 full box).
                if (self.vm.string_proto != 0) {
                    if (self.vm.objects.getChained(self.vm.string_proto, name, self.vm.case_sensitive)) |m| {
                        return m;
                    }
                }
                return .undefined_value;
            },
            .number => {
                if (self.vm.number_proto != 0) {
                    if (self.vm.objects.getChained(self.vm.number_proto, name, self.vm.case_sensitive)) |m| {
                        return m;
                    }
                }
                return .undefined_value;
            },
            .boolean => {
                if (self.vm.boolean_proto != 0) {
                    if (self.vm.objects.getChained(self.vm.boolean_proto, name, self.vm.case_sensitive)) |m| {
                        return m;
                    }
                }
                return .undefined_value;
            },
            else => return .undefined_value,
        }
    }

    fn memberSet(self: *Activation, target: Value, name: strings.AvmString, v: Value) !void {
        if (target != .object) return;
        const h = target.object;
        if (strings.eqlIgnoreCase(name, S("__proto__"))) {
            self.vm.objects.get(h).proto = if (v == .object) v else .undefined_value;
            return;
        }
        // A display property name writes through to the clip; anything
        // else is an ordinary put on the clip's own ScriptObject.
        if (try stage.assignMember(self.vm, h, name, v)) return;
        const o = self.vm.objects.get(h);
        if (o.native == .array) {
            // Numeric keys maintain length.
            if (parseArrayIndex(name)) |idx| {
                try self.vm.arraySet(h, idx, v);
                return;
            }
            if (strings.eqlIgnoreCase(name, S("length"))) {
                const n = try self.vm.toNumber(v);
                if (!std.math.isNan(n) and n >= 0) {
                    try self.vm.setArrayLength(h, @intFromFloat(@min(n, 4294967295.0)));
                }
                return;
            }
        }
        try self.vm.setProperty(h, name, v, target);
    }

    fn parseArrayIndex(name: strings.AvmString) ?u32 {
        if (name.len == 0 or name.len > 10) return null;
        var acc: u64 = 0;
        for (name) |c| {
            if (c < '0' or c > '9') return null;
            acc = acc * 10 + (c - '0');
            if (acc > 4294967294) return null;
        }
        return @intCast(acc);
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
                });
                if (f.name.len > 0) {
                    const name = try self.swfStr(f.name);
                    try self.vm.scopeDefineLocal(self.localScope(), name, .{ .object = fn_obj });
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
                });
                if (f.name.len > 0) {
                    const name = try self.swfStr(f.name);
                    try self.vm.scopeDefineLocal(self.localScope(), name, .{ .object = fn_obj });
                } else {
                    try self.push(.{ .object = fn_obj });
                }
            },
            .with_op => |w| {
                const target = self.pop();
                const with_scope = try self.vm.newScope(self.scope);
                self.vm.objects.get(with_scope).is_with_scope = true;
                if (target == .object) {
                    self.vm.objects.get(with_scope).proto = target;
                }
                const flow = try self.runSlice(w.body, with_scope);
                if (flow != .next) return flow;
            },
            .try_op => |t| {
                var flow = try self.runSlice(t.try_body, self.scope);
                if (flow == .thrown and t.has_catch) {
                    const caught = flow.thrown;
                    if (t.catch_in_register) {
                        self.setRegister(t.catch_register, caught);
                    } else {
                        const name = try self.swfStr(t.catch_name);
                        try self.vm.scopeDefineLocal(self.localScope(), name, caught);
                    }
                    flow = try self.runSlice(t.catch_body, self.scope);
                }
                if (t.has_finally) {
                    const fin = try self.runSlice(t.finally_body, self.scope);
                    if (fin != .next) return fin; // finally overrides
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
                // The operand is 1-BASED here (unlike GotoFrame 0x81), and
                // only an INTEGER number is a direct index — anything else
                // is coerced to a string and looked up as a label, which is
                // how `gotoAndPlay("3")` and `gotoAndPlay("intro")` both
                // work. ruffle globals/movie_clip.rs goto_frame:1109-1157.
                var target: ?i32 = null;
                var label: ?strings.AvmString = null;
                if (v == .number and std.math.isFinite(v.number) and @rem(v.number, 1) == 0) {
                    target = value_mod.toInt32(v.number);
                } else {
                    const s = try self.vm.toStringValue(v);
                    if (strictFrameNumber(s)) |n| target = n else label = s;
                }
                if (label) |s| {
                    self.hostGotoLabelOn(clip, s, g.set_playing);
                } else if (target) |n| {
                    const f = n +% @as(i32, g.scene_offset);
                    // Gotoing <= 0 has no effect; past the end clamps.
                    if (f > 0) self.hostGoto(clip, @intCast(@min(f, 65535)), g.set_playing);
                }
            },
            .goto_label => |label| self.hostGotoLabel(try self.swfStr(label), null),
            .set_target => |t| try self.setTarget(try self.swfStr(t)),
            .wait_for_frame => {}, // everything is always loaded
            .wait_for_frame2 => {
                _ = self.pop();
            },
            .get_url => {}, // network: out of scope
            .get_url2 => {
                _ = self.pop(); // target
                _ = self.pop(); // url
            },
            .strict_mode => {},
            .unknown => {},
        }
        return .next;
    }

    fn execSimple(self: *Activation, op: opcodes.OpCode) anyerror!Flow {
        switch (op) {
            // --- SWF4 arithmetic (numeric semantics) -----------------------
            .add => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(.{ .number = a + b });
            },
            .subtract => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(.{ .number = a - b });
            },
            .multiply => {
                const b = try self.popNumber();
                const a = try self.popNumber();
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
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(self.boolResult(a < b));
            },
            .and_op => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(self.boolResult(a != 0 and b != 0));
            },
            .or_op => {
                const b = try self.popNumber();
                const a = try self.popNumber();
                try self.push(self.boolResult(a != 0 or b != 0));
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
                const n = try self.popNumber();
                try self.push(.{ .number = @trunc(n) });
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
            .string_extract, .mb_string_extract => {
                const count = try self.popNumber();
                const index = try self.popNumber();
                const s = try self.popString();
                // 1-based start; out-of-range clamps to empty.
                const start_i: i64 = @intFromFloat(@max(1, index));
                const start: usize = @intCast(@min(@as(i64, @intCast(s.len)) + 1, start_i));
                const avail = s.len + 1 - start;
                const cnt: usize = if (std.math.isNan(count) or count < 0)
                    avail
                else
                    @min(avail, @as(usize, @intFromFloat(count)));
                try self.push(.{ .string = s[start - 1 ..][0..cnt] });
            },
            .char_to_ascii, .mb_char_to_ascii => {
                const s = try self.popString();
                try self.push(.{ .number = if (s.len > 0) @floatFromInt(s[0]) else 0 });
            },
            .ascii_to_char, .mb_ascii_to_char => {
                const n = try self.popNumber();
                const out = try self.vm.arena().alloc(u16, 1);
                out[0] = value_mod.toUint16(n);
                try self.push(.{ .string = out });
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
                try self.vm.scopeDefineLocal(self.localScope(), name, v);
            },
            .define_local2 => {
                const name = try self.popString();
                const sc = self.localScope();
                if (!self.vm.objects.hasOwn(sc, name, self.vm.case_sensitive)) {
                    try self.vm.scopeDefineLocal(sc, name, .undefined_value);
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
                var cur = self.scope;
                var deleted = false;
                while (cur != 0 and !deleted) {
                    deleted = self.vm.objects.deleteOwn(self.scopeObject(cur), name, self.vm.case_sensitive);
                    cur = self.vm.objects.get(cur).scope_parent;
                }
                try self.push(.{ .boolean = deleted });
            },

            // --- ES3 ops --------------------------------------------------
            .add2 => {
                const b = try self.vm.toPrimitiveAdd(self.pop());
                const a = try self.vm.toPrimitiveAdd(self.pop());
                if (a == .string or b == .string) {
                    const sa = try self.vm.toStringValue(a);
                    const sb = try self.vm.toStringValue(b);
                    try self.push(.{ .string = try strings.concat(self.vm.arena(), sa, sb) });
                } else {
                    const na = value_mod.toNumberPrimitive(a, self.swf_version);
                    const nb = value_mod.toNumberPrimitive(b, self.swf_version);
                    try self.push(.{ .number = na + nb });
                }
            },
            .less2 => {
                const b = self.pop();
                const a = self.pop();
                const r = try self.vm.abstractLess(a, b);
                try self.push(if (r == .undefined_value) .{ .boolean = false } else r);
            },
            .greater => {
                const b = self.pop();
                const a = self.pop();
                const r = try self.vm.abstractLess(b, a);
                try self.push(if (r == .undefined_value) .{ .boolean = false } else r);
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
            .init_array => {
                const n = try self.popNumber();
                const count: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(n);
                const arr = try self.vm.newArray();
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try self.vm.arraySet(arr, @intCast(i), self.pop());
                }
                try self.push(.{ .object = arr });
            },
            .init_object => {
                const n = try self.popNumber();
                const count: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(n);
                const obj = try self.vm.newObject();
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const v = self.pop();
                    const key = try self.popString();
                    try self.vm.objects.put(obj, key, v, self.vm.case_sensitive);
                }
                try self.push(.{ .object = obj });
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
                try self.push(.{ .boolean = self.instanceOf(obj, ctor) });
            },
            .cast_op => {
                const obj = self.pop();
                const ctor = self.pop();
                try self.push(if (self.instanceOf(obj, ctor)) obj else .null_value);
            },
            .implements_op => {
                // ctor implements N interfaces: recorded but unused in M3.
                const ctor = self.pop();
                _ = ctor;
                const n = try self.popNumber();
                const count: usize = if (std.math.isNan(n) or n < 0) 0 else @intFromFloat(n);
                var i: usize = 0;
                while (i < count) : (i += 1) _ = self.pop();
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
                    try self.vm.objects.putWithAttrs(subclass.object, S("prototype"), .{ .object = proto }, .{ .dont_enum = true }, self.vm.case_sensitive);
                }
            },

            // --- calls ----------------------------------------------------
            .call_function => {
                const name = try self.popString();
                const args = try self.popArgs();
                const f = self.vm.scopeGet(self.scope, name) orelse Value.undefined_value;
                const r = try self.vm.callFunction(f, self.this, args);
                try self.push(r);
            },
            .call_method => {
                const name_v = self.pop();
                const target = self.pop();
                const args = try self.popArgs();
                // ruffle action_call_method: undefined ⇒ "", otherwise
                // COERCE (an object whose toString yields "" also selects
                // the call-as-function path).
                const name: strings.AvmString = if (name_v == .undefined_value)
                    S("")
                else
                    try self.vm.toStringValue(name_v);
                const result = if (name.len == 0)
                    try self.vm.callFunction(target, .undefined_value, args)
                else blk: {
                    const m = try self.memberGet(target, name);
                    break :blk try self.vm.callFunction(m, target, args);
                };
                try self.push(result);
            },
            .new_object => {
                const name = try self.popString();
                const args = try self.popArgs();
                const ctor = self.vm.scopeGet(self.scope, name) orelse Value.undefined_value;
                try self.push(try self.vm.construct(ctor, args));
            },
            .new_method => {
                const name_v = self.pop();
                const target = self.pop();
                const args = try self.popArgs();
                const name: strings.AvmString = if (name_v == .undefined_value)
                    S("")
                else
                    try self.vm.toStringValue(name_v);
                const ctor: Value = if (name.len == 0)
                    target
                else
                    try self.memberGet(target, name);
                try self.push(try self.vm.construct(ctor, args));
            },
            .return_op => return .{ .return_value = self.pop() },
            .throw => return .{ .thrown = self.pop() },

            // --- misc -----------------------------------------------------
            .trace => {
                // trace ALWAYS prints "undefined" even in SWF <= 6, where
                // undefined otherwise coerces to "" (ruffle
                // activation.rs action_trace).
                const v = self.pop();
                const s = if (v == .undefined_value)
                    S("undefined")
                else
                    try self.vm.toStringValue(v);
                try self.vm.traceLine(s);
            },
            .target_path => {
                // The DOT path (`_level0.mc.child`) — NOT `_target`'s
                // slash form. Anything that isn't a display object, a
                // string path included, gives undefined.
                const v = self.pop();
                if (stage.targetOfValue(self.vm, v)) |t| {
                    try self.push(.{ .string = try stage.dotPath(self.vm, t.clip) });
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
                    self.target_clip = if (self.swf_version > 6) null else self.base_clip;
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
                _ = self.pop();
                _ = self.pop();
                _ = self.pop();
            },
            .remove_sprite => _ = self.pop(),
            .start_drag => {
                _ = self.pop(); // target
                const lock = try self.popNumber();
                _ = lock;
                const constrain = try self.popNumber();
                if (constrain != 0) {
                    _ = self.pop();
                    _ = self.pop();
                    _ = self.pop();
                    _ = self.pop();
                }
            },
            .end_drag => {},
            .play => self.hostSetPlaying(true),
            .stop => self.hostSetPlaying(false),
            .next_frame => self.hostNextPrev(1),
            .previous_frame => self.hostNextPrev(-1),
            .toggle_quality, .stop_sounds => {},
            .call => _ = self.pop(), // frame call: M4
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
            .right_unsigned => {
                const v = value_mod.toUint32(a) >> shift;
                try self.push(.{ .number = @floatFromInt(v) });
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
                if (p.attrs.dont_enum) continue;
                if (object_mod.versionHidden(p.attrs, self.swf_version)) continue;
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

    fn instanceOf(self: *Activation, obj: Value, ctor: Value) bool {
        if (obj != .object or ctor != .object) return false;
        const proto = self.vm.objects.getChained(ctor.object, S("prototype"), self.vm.case_sensitive) orelse return false;
        if (proto != .object) return false;
        var cur = self.vm.objects.get(obj.object).proto;
        var depth: u32 = 0;
        while (cur == .object and depth < 256) : (depth += 1) {
            if (cur.object == proto.object) return true;
            cur = self.vm.objects.get(cur.object).proto;
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
    fn setTarget(self: *Activation, path: strings.AvmString) !void {
        if (path.len == 0) {
            self.target_clip = self.base_clip;
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
                    self.target_clip = h;
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
    fn localScope(self: *Activation) ObjectHandle {
        return self.scopeObject(self.scope);
    }

    fn scopeObject(self: *Activation, node: ObjectHandle) ObjectHandle {
        if (node != self.timeline_scope or self.timeline_scope == 0) return node;
        const t = self.targetClipOrRoot();
        return if (t != 0) t else node;
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

/// A frame operand that is a STRING is a frame number only when the whole
/// string parses; otherwise it is a label. Ruffle uses Rust's strict
/// `parse()` here, so "3x" is a label, not frame 3.
fn strictFrameNumber(s: strings.AvmString) ?i32 {
    if (s.len == 0 or s.len > 32) return null;
    var buf: [32]u8 = undefined;
    for (s, 0..) |c, i| {
        if (c > 0x7F) return null;
        buf[i] = @intCast(c);
    }
    const n = std.fmt.parseFloat(f64, buf[0..s.len]) catch return null;
    return value_mod.toInt32(n);
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
    try testing.expectEqual(@as(?i32, 3), strictFrameNumber(S_("3")));
    try testing.expectEqual(@as(?i32, -2), strictFrameNumber(S_("-2")));
    try testing.expectEqual(@as(?i32, 3), strictFrameNumber(S_("3.7"))); // truncated
    // ...anything with trailing junk is a LABEL, not frame 3.
    try testing.expectEqual(@as(?i32, null), strictFrameNumber(S_("3x")));
    try testing.expectEqual(@as(?i32, null), strictFrameNumber(S_("intro")));
    try testing.expectEqual(@as(?i32, null), strictFrameNumber(S_("")));
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
