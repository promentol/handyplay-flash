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
    /// SetTarget/tellTarget retarget: movie-control ops and unqualified
    /// variables act on this clip (ruffle base_clip vs target_clip). 0
    /// means "same as `this`".
    target_override: ObjectHandle = 0,
    constant_pool: u32,
    swf_version: u8,

    pub fn init(vm: *Vm, code: []const u8, this: Value, scope: ObjectHandle, pool: u32) Activation {
        return .{
            .vm = vm,
            .code = code,
            .r = rdr.Reader.init(code),
            .this = this,
            .scope = scope,
            .constant_pool = pool,
            .swf_version = vm.swf_version,
        };
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
        const flow = try child.run();
        self.constant_pool = child.constant_pool; // pool changes persist
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

    /// GetVariable with dot/slash path support: `a.b.c`, `_root.x`,
    /// `/mc/child:var`, `..`. Pure-VM fallback resolves path heads through
    /// the scope chain; clip traversal proper lands with the display glue.
    fn getVariable(self: *Activation, name: strings.AvmString) !Value {
        if (pathSeparator(name) == null) {
            return try self.scopeLookup(name) orelse .undefined_value;
        }
        var it = PathIter.init(name);
        var current: Value = .undefined_value;
        var first = true;
        while (it.next()) |part| {
            if (part.len == 0) {
                if (first) current = self.vm.root_object; // leading '/'
                first = false;
                continue;
            }
            if (first) {
                current = try self.scopeLookup(part) orelse return .undefined_value;
                first = false;
                continue;
            }
            current = try self.memberGet(current, part);
        }
        return current;
    }

    fn setVariable(self: *Activation, name: strings.AvmString, v: Value) !void {
        const sep = pathSeparator(name) orelse {
            try self.scopeAssign(name, v);
            return;
        };
        _ = sep;
        // path.member = value → resolve the container, set the last part.
        var last_start: usize = 0;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            const c = name[i];
            if (c == '.' or c == '/' or c == ':') last_start = i + 1;
        }
        if (last_start == 0 or last_start >= name.len) return;
        const container_path = trimTrailingSep(name[0 .. last_start - 1]);
        const member = name[last_start..];
        const container = try self.getVariable(container_path);
        if (container == .object) {
            try self.memberSet(container, member, v);
        }
    }

    /// Vm.scopeGet, but each scope object that is a clip also exposes its
    /// children, `_parent`/`_root` and the display properties — timeline
    /// code says bare `_x` and bare `myClip`, not `this._x`.
    fn scopeLookup(self: *Activation, name: strings.AvmString) !?Value {
        const cs = self.vm.case_sensitive;
        var cur = self.scope;
        while (cur != 0) {
            if (self.vm.objects.getChained(cur, name, cs)) |_| {
                return try self.vm.getProperty(cur, name, .{ .object = cur });
            }
            if (try stage.resolveMember(self.vm, cur, name)) |v| return v;
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
        var bottom = self.scope;
        while (cur != 0) {
            if (self.vm.objects.hasOwn(cur, name, cs)) {
                try self.vm.objects.put(cur, name, v, cs);
                return;
            }
            if (try stage.assignMember(self.vm, cur, name, v)) return;
            bottom = cur;
            cur = self.vm.objects.get(cur).scope_parent;
        }
        try self.vm.objects.put(bottom, name, v, cs);
    }

    fn pathSeparator(name: strings.AvmString) ?usize {
        for (name, 0..) |c, i| {
            if (c == '.' or c == '/' or c == ':') return i;
        }
        return null;
    }

    fn trimTrailingSep(name: strings.AvmString) strings.AvmString {
        if (name.len > 0 and (name[name.len - 1] == '/' or name[name.len - 1] == ':')) {
            return name[0 .. name.len - 1];
        }
        return name;
    }

    const PathIter = struct {
        s: strings.AvmString,
        pos: usize = 0,

        fn init(s: strings.AvmString) PathIter {
            return .{ .s = s };
        }

        fn next(self: *PathIter) ?strings.AvmString {
            if (self.pos > self.s.len) return null;
            const start = self.pos;
            var i = self.pos;
            while (i < self.s.len) : (i += 1) {
                const c = self.s[i];
                if (c == '.' or c == '/' or c == ':') break;
            }
            self.pos = i + 1;
            if (start == 0 and i == self.s.len and start == self.pos - 1) {}
            return self.s[start..i];
        }
    };

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
                    try self.vm.scopeDefineLocal(self.scope, name, .{ .object = fn_obj });
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
                    try self.vm.scopeDefineLocal(self.scope, name, .{ .object = fn_obj });
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
                        try self.vm.scopeDefineLocal(self.scope, name, caught);
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
                const v = self.pop();
                switch (v) {
                    .number => |n| self.hostGotoFrame(@intFromFloat(@max(1, n + 1 - @as(f64, @floatFromInt(g.scene_offset)))), g.set_playing),
                    .string => |s| self.hostGotoLabel(s, g.set_playing),
                    else => {},
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
                try self.vm.scopeDefineLocal(self.scope, name, v);
            },
            .define_local2 => {
                const name = try self.popString();
                if (!self.vm.objects.hasOwn(self.scope, name, self.vm.case_sensitive)) {
                    try self.vm.scopeDefineLocal(self.scope, name, .undefined_value);
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
                    deleted = self.vm.objects.deleteOwn(cur, name, self.vm.case_sensitive);
                    cur = self.vm.objects.get(cur).scope_parent;
                }
                try self.push(.{ .boolean = deleted });
            },

            // --- ES3 ops --------------------------------------------------
            .add2 => {
                const b = try self.vm.toPrimitive(self.pop(), .number);
                const a = try self.vm.toPrimitive(self.pop(), .number);
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
                try self.push(.null_value);
                if (target == .object) try self.pushEnumKeys(target.object);
            },
            .enumerate2 => {
                const target = self.pop();
                try self.push(.null_value);
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
                const v = self.pop();
                _ = v; // M4: real clip paths
                try self.push(.undefined_value);
            },
            .set_target2 => {
                const v = self.pop();
                if (v == .object and self.vm.objects.get(v.object).native == .clip) {
                    self.target_override = v.object;
                } else {
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

    /// SetTarget("") resets to the base clip. A path that resolves to a
    /// clip retargets; an INVALID path in SWF <= 6 leaves the target
    /// unchanged (execution continues — corpus tell_target_invalid_swf6),
    /// while SWF 7+ players null the target.
    fn setTarget(self: *Activation, path: strings.AvmString) !void {
        if (path.len == 0) {
            self.target_override = 0;
            return;
        }
        const resolved = try self.getVariable(path);
        if (resolved == .object and self.vm.objects.get(resolved.object).native == .clip) {
            self.target_override = resolved.object;
        } else if (self.swf_version >= 7) {
            self.target_override = 0;
        }
    }

    /// The clip movie-control ops act on: the SetTarget override when
    /// present, else `this`.
    fn targetValue(self: *Activation) Value {
        if (self.target_override != 0) return .{ .object = self.target_override };
        return self.this;
    }

    /// GetProperty/SetProperty's target operand. An empty path means "the
    /// current target clip"; anything else resolves as a variable path.
    /// A missing target yields null and the op pushes undefined.
    fn resolveDisplayTarget(self: *Activation, path: Value) !?stage.Target {
        // A value that already is a clip is used directly.
        if (stage.targetOfValue(self.vm, path)) |t| return t;
        const s = try self.vm.toStringValue(path);
        if (s.len == 0) return stage.targetOfValue(self.vm, self.targetValue());
        const resolved = try self.getVariable(s);
        return stage.targetOfValue(self.vm, resolved);
    }

    // --- host bridges (movie control) -------------------------------------

    fn currentClip(self: *Activation) ?*anyopaque {
        const t = self.targetValue();
        if (t == .object) {
            const native = self.vm.objects.get(t.object).native;
            if (native == .clip) return native.clip;
        }
        return null;
    }

    fn hostGotoFrame(self: *Activation, frame: u16, play: ?bool) void {
        const host = self.vm.host;
        const clip = self.currentClip() orelse return;
        if (host.goto_frame) |f| f(host.ctx.?, clip, frame, play orelse false);
    }

    fn hostGotoLabel(self: *Activation, label: strings.AvmString, play: ?bool) void {
        const host = self.vm.host;
        const clip = self.currentClip() orelse return;
        if (host.goto_label) |f| _ = f(host.ctx.?, clip, label, play orelse false);
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
