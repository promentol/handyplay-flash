//! The AVM1 virtual machine: object table, shared value stack, global
//! registers, constant pools, scope objects, prototypes, deterministic
//! clock/rng, trace sink — plus the coercions that touch the object graph
//! (ToPrimitive via valueOf/toString) and the function-call machinery
//! (DefineFunction locals, DefineFunction2 register preloading in the
//! canonical order this/arguments/super/_root/_parent/_global).
//!
//! References: ruffle core/src/avm1/{runtime,activation,function}.rs,
//! open-flash avm1/actions (esp. define-function2.md).

const std = @import("std");
const rdr = @import("../swf/reader.zig");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const object_mod = @import("object.zig");
const opcodes = @import("opcodes.zig");

pub const Value = value_mod.Value;
pub const ObjectHandle = value_mod.ObjectHandle;
const S = strings.ascii;

pub const Error = error{OutOfMemory};

/// A `throw` in flight. Carried as a Zig error so it unwinds every
/// intermediate frame for free — the value itself rides on
/// `Vm.pending_throw`. Ruffle uses `Error::ThrownValue` the same way.
pub const Thrown = error{Avm1Thrown};

/// Host hooks the display layer installs (movie control, clip variables).
/// All optional so the pure VM runs standalone in tests.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// gotoFrame(target_clip_native, frame_1based, and_play)
    goto_frame: ?*const fn (ctx: *anyopaque, clip: *anyopaque, frame: u16, play: bool) void = null,
    goto_label: ?*const fn (ctx: *anyopaque, clip: *anyopaque, label: []const u16, play: bool) bool = null,
    set_playing: ?*const fn (ctx: *anyopaque, clip: *anyopaque, playing: bool) void = null,
    next_prev: ?*const fn (ctx: *anyopaque, clip: *anyopaque, delta: i2) void = null,
    /// The focus moved: the HOVER follows it, with the roll events that
    /// implies (ruffle focus_tracker.rs `roll_over`). `obj` is the new
    /// focus's display object, null when the focus was cleared.
    /// `run_now` drains the queue before returning, which a KEY-driven
    /// move does and a programmatic one does not.
    focus_roll: ?*const fn (ctx: *anyopaque, obj: ?*anyopaque, run_now: bool) void = null,
};

/// Stage render quality — `_quality` / `_highquality` read and write it.
pub const Quality = enum { low, medium, high, best };

/// An in-progress `startDrag`. The dragged object follows the mouse until
/// `stopDrag`; the Player re-applies it on every pointer move.
pub const Drag = struct {
    /// The dragged display object's AVM1 handle (so a removed clip simply
    /// stops resolving instead of dangling).
    target: ObjectHandle,
    /// `lockCenter`: the object centres on the pointer rather than keeping
    /// the grab offset.
    lock_center: bool,
    /// Optional constraint rectangle, in twips, in the PARENT's space.
    bounds: ?rdr.Rectangle = null,
    /// Grab offset in twips (pointer → object origin), in the parent's space.
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

/// `_droptarget` is a STORED property, not a live query: ruffle recomputes
/// it inside `update_drag` and leaves the last answer on the clip after
/// `stopDrag` (movie_clip.rs drop_target). Only one clip can be dragged at
/// a time, so one slot suffices — reads from any other clip are empty.
pub const DropTarget = struct {
    clip: ?*anyopaque = null,
    path: []const u16 = &.{},
};

/// 2001-02-03T04:05:06 at +05:45 == 2001-02-02T22:20:06Z == 981152406000 ms.
pub const MOCK_EPOCH_MS: f64 = 981152406000;

pub const ClassEntry = struct { name: strings.AvmString, ctor: ObjectHandle };

pub const Vm = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    objects: object_mod.Objects,
    stack: std.ArrayList(Value) = .empty,
    /// The 4 global registers (StoreRegister / Push register outside fn2).
    registers: [4]Value = @splat(.undefined_value),
    /// Decoded constant pools; functions capture the pool index active at
    /// definition time.
    pools: std.ArrayList([]const strings.AvmString) = .empty,
    active_pool: u32 = 0,
    swf_version: u8,
    case_sensitive: bool,
    /// _global and the system prototypes.
    globals: ObjectHandle = 0,
    object_proto: ObjectHandle = 0,
    function_proto: ObjectHandle = 0,
    array_proto: ObjectHandle = 0,
    string_proto: ObjectHandle = 0,
    number_proto: ObjectHandle = 0,
    boolean_proto: ObjectHandle = 0,
    /// MovieClip.prototype — clip objects chain to it, so script can hang
    /// methods there and every clip inherits them.
    movieclip_proto: ObjectHandle = 0,
    /// Button.prototype / TextField.prototype. The other two scriptable
    /// display kinds; their full surfaces land in M4-C and M4-D, but the
    /// prototypes must exist now so `getDepth` and friends resolve.
    button_proto: ObjectHandle = 0,
    textfield_proto: ObjectHandle = 0,
    /// Text fields whose `variable` has not resolved yet (M4-D7).
    unbound_text_fields: std.ArrayList(*@import("../display/display_object.zig").DisplayObject) = .empty,
    /// flash.geom prototypes. Held here because the engine constructs these
    /// objects itself (`mc.transform`, `Color.getTransform`, `getBounds`),
    /// not only via `new`.
    point_proto: ObjectHandle = 0,
    rectangle_proto: ObjectHandle = 0,
    matrix_proto: ObjectHandle = 0,
    colortransform_proto: ObjectHandle = 0,
    transform_proto: ObjectHandle = 0,
    date_proto: ObjectHandle = 0,
    /// Bottom scope for timeline code (the current target clip's variable
    /// object; a plain object in pure-VM tests).
    root_scope: ObjectHandle = 0,
    /// The root movie object exposed as _root/_level0.
    root_object: Value = .undefined_value,
    /// Deterministic frame clock (ms since start), advanced by the player.
    now_ms: f64 = 0,
    /// Wall clock at movie start, as Unix epoch milliseconds, and the local
    /// zone's offset in minutes. `Date` reads `epoch_ms + now_ms`.
    ///
    /// The defaults are ruffle's test mock: 2001-02-03 04:05:06 local in a
    /// +05:45 zone that has never used DST (core/src/locale.rs picks Nepal
    /// for exactly that reason), so the conformance runner is deterministic
    /// with no flag. Frontends override both via `Player.setClock`.
    epoch_ms: f64 = MOCK_EPOCH_MS,
    tz_offset_min: i32 = 345,
    rng: std.Random.DefaultPrng,
    /// Per-frame action budget (recursion/time guard, ScriptLimits-ish).
    budget: u32 = 5_000_000,
    call_depth: u32 = 0,
    max_call_depth: u32 = 256,
    halted: bool = false,
    host: Host = .{},
    /// Stage state the display-property table reads and writes. Not part
    /// of any clip, so it lives here rather than behind a Host hook.
    quality: Quality = .high,
    sound_buf_time: i32 = 5,
    stage_focus_rect: bool = true,
    /// Mouse position in stage pixels; the frontend writes it via
    /// `Player.mouseMove`.
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_buttons: u8 = 0,
    mouse_hidden: bool = false,
    /// Key state, indexed by Flash key code. `toggled` flips on each press
    /// of the lock keys; Flash reads the real OS state but nothing else can
    /// be observed from inside the player.
    keys_down: [256]bool = @splat(false),
    keys_toggled: [256]bool = @splat(false),
    last_key_code: i32 = 0,
    last_key_char: i32 = 0,
    /// The singletons, so the engine can broadcast to them directly.
    key_object: ObjectHandle = 0,
    /// The three broadcaster functions, created ONCE and shared by every
    /// broadcaster — `Key.addListener == Mouse.addListener` is true in
    /// Flash and the corpus checks it.
    bc_add_listener: ObjectHandle = 0,
    bc_remove_listener: ObjectHandle = 0,
    bc_broadcast_message: ObjectHandle = 0,
    mouse_object: ObjectHandle = 0,
    stage_object_handle: ObjectHandle = 0,
    /// Stage state `Stage.*` reads and writes. The dimensions are the
    /// viewport's, which for us is the movie's own stage box.
    stage_width: u32 = 0,
    stage_height: u32 = 0,
    /// 0 showAll, 1 noBorder, 2 exactFit, 3 noScale.
    stage_scale_mode: u2 = 0,
    stage_align_left: bool = false,
    stage_align_right: bool = false,
    stage_align_top: bool = false,
    stage_align_bottom: bool = false,
    stage_show_menu: bool = true,
    stage_full_screen: bool = false,
    /// The VIEWPORT: the window area the movie is presented in, in device
    /// pixels, plus the HiDPI factor. Defaults to the movie's own stage
    /// box at 1:1, which is what every frontend but the conformance
    /// runner uses.
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    viewport_scale: f64 = 1.0,
    /// The view matrix's scale and letterbox offset — stage space to
    /// device pixels. Recomputed whenever the scale mode or the viewport
    /// changes (ruffle Stage::build_matrices).
    view_scale_x: f64 = 1.0,
    view_scale_y: f64 = 1.0,
    view_tx: f64 = 0,
    view_ty: f64 = 0,
    /// The movie's own stage box in pixels, for the matrices above.
    movie_width: f64 = 0,
    movie_height: f64 = 0,
    /// The screen `System.capabilities.screenResolution*` reports.
    screen_width: u32 = 1920,
    screen_height: u32 = 1080,
    use_codepage: bool = false,
    exact_settings: bool = true,
    /// `FileAttributes.UseNetwork` — the only thing that separates the two
    /// local sandboxes.
    use_network_sandbox: bool = false,
    /// The active `startDrag`, if any.
    drag: ?Drag = null,
    /// Latched by `getBounds`/`getRect` the first time either runs in a
    /// SWF8+ context. Once on, an empty box in an identical coordinate
    /// space reports the 0x8000000-twip "invalid" sentinel instead of
    /// zeroes (ruffle Avm1::get_use_new_invalid_bounds_value). It is a
    /// PLAYER-wide latch, not per-call, which is why it lives here.
    use_new_invalid_bounds: bool = false,
    /// SWF version of the ROOT movie — `getBounds`'s latch consults it even
    /// when the running code is older. Set by the Player.
    root_swf_version: u8 = 0,
    /// What `_url` reports. The Player sets it from the path it loaded;
    /// `core/` does no I/O and never derives it itself.
    movie_url: strings.AvmString = &.{},
    /// The innermost running `Activation`, or null outside interpretation.
    /// Native methods need it for the ONE thing they cannot do themselves:
    /// resolve a target path, which depends on the caller's `this` and
    /// scope (`MovieClip.gotoAndStop("/other:5")` really does redirect the
    /// goto to another clip). activation.zig owns the cast back.
    current_activation: ?*anyopaque = null,
    /// The tick's `movie_clip.Context`, valid only while the Player is
    /// inside runOneFrame. Scripts that create or destroy clips need it;
    /// stage_object.zig is the one file allowed to cast it back. Null in
    /// pure-VM tests, where every such operation no-ops.
    display_ctx: ?*anyopaque = null,
    /// trace() output collects here as UTF-8 lines.
    trace_buf: std.ArrayList(u8) = .empty,
    /// The value of the `throw` currently unwinding, paired with
    /// `error.Avm1Thrown`.
    pending_throw: Value = .undefined_value,
    /// Prototype depth the NEXT call's `super` should start from. A plain
    /// method call is 0; `super.m()` sets 1 so the chain walks upward
    /// instead of recursing forever.
    super_depth: u8 = 0,
    /// Watcher invocations currently on the stack, as (object, name-hash)
    /// keys. Flash caps recursion PER PROPERTY at 65 nested calls rather
    /// than by total stack depth (ruffle activation.rs
    /// is_over_property_recursion_limit), and the two watch_recursion tests
    /// measure exactly how deep it gets.
    property_call_stack: std.ArrayList(u64) = .empty,
    /// The last `_droptarget` computed for the dragged clip.
    drop_target: DropTarget = .{},
    /// The focused display object's AVM1 handle (0 = nothing focused).
    /// One tracker for the whole player, like ruffle's `focus_tracker`.
    focus: ObjectHandle = 0,
    /// The `Selection` singleton, whose listeners hear `onSetFocus`.
    selection_object: ObjectHandle = 0,
    /// `TextFormat.prototype`.
    textformat_proto: ObjectHandle = 0,
    /// `TextSnapshot.prototype`.
    textsnapshot_proto: ObjectHandle = 0,
    /// Is the focus HIGHLIGHT active? It follows the focus, and any mouse
    /// activity below SWF9 clears it. Key handlers (`btn.onKeyDown`) only
    /// fire for a focused object whose highlight is active — ruffle
    /// `should_fire_event_handlers`, Flash issue #2120.
    focus_highlight: bool = false,
    /// setInterval/setTimeout registrations, ticked by the Player after
    /// each frame's action drain.
    timers: @import("timers.zig").Timers = .{},
    /// `Object.registerClass` symbol -> constructor. Small and rarely
    /// written, so a list beats a map; lookup obeys the movie's case rule.
    class_registry: std.ArrayList(ClassEntry) = .empty,
    /// Non-zero while inside `construct` — native constructors box their
    /// argument only for `new X()`, and coerce for a plain `X()` call
    /// (ruffle globals/{number,string,boolean}.rs split those paths).
    in_construct: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, swf_version: u8) Error!*Vm {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        const self = try gpa.create(Vm);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .objects = .{ .arena = arena_state.allocator(), .swf_version = swf_version },
            .swf_version = swf_version,
            .case_sensitive = swf_version >= 7,
            .rng = std.Random.DefaultPrng.init(0x5EED),
        };
        try @import("globals/globals.zig").install(self);
        self.root_scope = try self.newObject();
        self.root_object = .{ .object = self.root_scope };
        // _root / _level0 resolve to the root scope in pure-VM mode.
        try self.objects.put(self.globals, S("_root"), self.root_object, self.case_sensitive);
        try self.objects.put(self.globals, S("_level0"), self.root_object, self.case_sensitive);
        return self;
    }

    pub fn destroy(self: *Vm) void {
        const gpa = self.gpa;
        self.stack.deinit(gpa);
        self.pools.deinit(gpa);
        self.property_call_stack.deinit(gpa);
        self.timers.deinit(gpa);
        self.trace_buf.deinit(gpa);
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
        gpa.destroy(self);
    }

    pub fn keyDown(self: *const Vm, code: i32) bool {
        if (code < 0 or code > 255) return false;
        return self.keys_down[@intCast(code)];
    }

    pub fn keyToggled(self: *const Vm, code: i32) bool {
        if (code < 0 or code > 255) return false;
        return self.keys_toggled[@intCast(code)];
    }

    pub fn arena(self: *Vm) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    // --- objects ---------------------------------------------------------

    pub fn newObject(self: *Vm) Error!ObjectHandle {
        const h = try self.objects.create();
        if (self.object_proto != 0) {
            self.objects.get(h).proto = .{ .object = self.object_proto };
        }
        return h;
    }

    pub fn newArray(self: *Vm) Error!ObjectHandle {
        const h = try self.objects.create();
        self.objects.get(h).native = .array;
        if (self.array_proto != 0) {
            self.objects.get(h).proto = .{ .object = self.array_proto };
        }
        try self.objects.putWithAttrs(h, S("length"), .{ .number = 0 }, .{ .dont_enum = true, .dont_delete = true }, self.case_sensitive);
        return h;
    }

    pub fn newNativeFn(self: *Vm, f: object_mod.NativeFn) Error!ObjectHandle {
        const h = try self.objects.create();
        self.objects.get(h).native = .{ .function = .{ .native = f } };
        if (self.function_proto != 0) {
            self.objects.get(h).proto = .{ .object = self.function_proto };
        }
        return h;
    }

    pub fn newAvm1Fn(self: *Vm, f: object_mod.Avm1Function) Error!ObjectHandle {
        const h = try self.objects.create();
        self.objects.get(h).native = .{ .function = .{ .avm1 = f } };
        if (self.function_proto != 0) {
            self.objects.get(h).proto = .{ .object = self.function_proto };
        }
        // Every function gets a fresh .prototype whose constructor is it.
        const proto = try self.newObject();
        try self.objects.putWithAttrs(proto, S("constructor"), .{ .object = h }, .{ .dont_enum = true }, self.case_sensitive);
        try self.objects.putWithAttrs(h, S("prototype"), .{ .object = proto }, .{ .dont_enum = true }, self.case_sensitive);
        return h;
    }

    pub fn isCallable(self: *Vm, v: Value) bool {
        if (v != .object) return false;
        return self.objects.get(v.object).native == .function;
    }

    // --- array helpers ---------------------------------------------------

    pub fn arraySet(self: *Vm, h: ObjectHandle, index: u32, v: Value) Error!void {
        var buf: [12]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;
        var wide: [12]u16 = undefined;
        for (key, 0..) |c, i| wide[i] = c;
        try self.objects.put(h, wide[0..key.len], v, self.case_sensitive);
        const len = self.arrayLength(h);
        if (index + 1 > len) try self.setArrayLength(h, index + 1);
    }

    pub fn arrayLength(self: *Vm, h: ObjectHandle) u32 {
        const v = self.objects.getOwn(h, S("length"), self.case_sensitive) orelse return 0;
        const n = value_mod.toNumberPrimitive(v, self.swf_version);
        if (std.math.isNan(n) or n < 0) return 0;
        return @intFromFloat(@min(n, 4294967295.0));
    }

    pub fn setArrayLength(self: *Vm, h: ObjectHandle, len: u32) Error!void {
        try self.objects.putWithAttrs(h, S("length"), .{ .number = @floatFromInt(len) }, .{ .dont_enum = true, .dont_delete = true }, self.case_sensitive);
    }

    // --- coercions touching the object graph ------------------------------

    /// `obj.name()` the way ruffle's `ExecutionReason::Special` calls run:
    /// resolved through the prototype chain, `undefined` when the property
    /// is not callable, and never propagating an error to the caller.
    fn callSpecial(self: *Vm, v: Value, name: strings.AvmString) Error!Value {
        // getProperty, not getChained: a `super` view owns nothing and has
        // no prototype of its own, so a raw chain walk finds no toString
        // and `trace(super)` degrades to "[type Object]" instead of
        // "[object Object]" (corpus clip_constructors).
        const m = self.getProperty(v.object, name, v) catch Value.undefined_value;
        if (!self.isCallable(m)) return .undefined_value;
        return self.callFunction(m, v, &.{}) catch Value.undefined_value;
    }

    fn isDisplayValue(self: *Vm, v: Value) bool {
        if (v != .object) return false;
        return switch (self.objects.get(v.object).native) {
            .clip, .display, .removed_display => true,
            else => false,
        };
    }

    /// ruffle `Value::to_primitive_num` (value.rs:198). NOT ES3's
    /// ToPrimitive: an object calls ONLY `valueOf`, and whatever comes back
    /// is the answer — including another object, which then coerces to NaN
    /// or blocks a comparison. There is no `toString` fallback.
    ///
    /// Display objects are exempt (`as_display_object().is_none()`), which
    /// is what lets `"x " + mc` reach toStringValue's path special-case.
    pub fn toPrimitiveNum(self: *Vm, v: Value) Error!Value {
        if (v != .object) return v;
        switch (self.objects.get(v.object).native) {
            .clip, .display, .removed_display => return v,
            else => {},
        }
        return self.callSpecial(v, S("valueOf"));
    }

    /// ruffle `Value::to_primitive` (value.rs:221) — the Add2 coercion.
    /// Calls `valueOf` (or `toString`, for a Date above SWF5) and, when
    /// that yields a non-primitive, falls back to the OBJECT ITSELF rather
    /// than trying the other method. That is load-bearing for ordering: the
    /// operand's `toString` must fire in Add2's string phase, not here
    /// (corpus object_string_coerce_swf5/swf6).
    pub fn toPrimitiveAdd(self: *Vm, v: Value) Error!Value {
        if (v != .object) return v;
        const is_date = self.objects.get(v.object).native == .date;
        const name: strings.AvmString = if (self.swf_version > 5 and is_date)
            S("toString")
        else
            S("valueOf");
        const r = try self.callSpecial(v, name);
        return if (r.isPrimitive()) r else v;
    }

    pub fn toNumber(self: *Vm, v: Value) Error!f64 {
        const p = try self.toPrimitiveNum(v);
        return value_mod.toNumberPrimitive(p, self.swf_version);
    }

    pub fn toStringValue(self: *Vm, v: Value) Error!strings.AvmString {
        switch (v) {
            // ruffle value.rs coerce_to_string: SWF < 7 stringifies
            // undefined as "", and SWF < 5 uses "1"/"0" for booleans.
            .undefined_value => return if (self.swf_version < 7) S("") else S("undefined"),
            .null_value => return S("null"),
            .boolean => |b| {
                if (self.swf_version < 5) return if (b) S("1") else S("0");
                return if (b) S("true") else S("false");
            },
            .number => |n| {
                var buf: [40]u8 = undefined;
                const s = value_mod.numberToStringBuf(&buf, n);
                const wide = try self.arena().alloc(u16, s.len);
                for (s, 0..) |c, i| wide[i] = c;
                return wide;
            },
            .string => |s| return s,
            .object => |h| {
                // Display objects are special-cased to their DOT path, and
                // it wins over any user toString (ruffle value.rs:325
                // checks as_display_object before dispatching toString).
                switch (self.objects.get(h).native) {
                    .clip => |c| return @import("stage_object.zig").dotPathOf(self, c),
                    .display => |d| return @import("stage_object.zig").dotPathOfDisplay(self, d),
                    // A String object never has toString() called on it.
                    .boxed_string => |s| return s,
                    else => {},
                }
                // ruffle value.rs:327 — ONE call to `toString`. A result
                // that is not a string (including an object, and including
                // no callable toString at all) is the type tag; there is no
                // valueOf fallback and no re-coercion of the result.
                const r = try self.callSpecial(v, S("toString"));
                if (r == .string) return r.string;
                return switch (self.objects.get(h).native) {
                    .function => S("[type Function]"),
                    else => S("[type Object]"),
                };
            },
        }
    }

    pub fn typeOf(self: *Vm, v: Value) strings.AvmString {
        return switch (v) {
            .object => |h| switch (self.objects.get(h).native) {
                .function => S("function"),
                .clip => S("movieclip"),
                else => S("object"),
            },
            .undefined_value => S("undefined"),
            .null_value => S("null"),
            .boolean => S("boolean"),
            .number => S("number"),
            .string => S("string"),
        };
    }

    /// ES3 §11.9.3 abstract equality (Equals2), incl. object arms.
    pub fn abstractEquals(self: *Vm, a: Value, b: Value) Error!bool {
        // Same-type fast paths.
        if (@as(std.meta.Tag(Value), a) == @as(std.meta.Tag(Value), b)) {
            if (self.clipPath(a)) |pa| {
                if (self.clipPath(b)) |pb| return strings.eql(pa, pb);
            }
            return switch (a) {
                .undefined_value, .null_value => true,
                // PLAYER-SPECIFIC (ruffle): NaN == NaN is true in FP7+.
                .number => |x| x == b.number or (std.math.isNan(x) and std.math.isNan(b.number)),
                .string => |x| strings.eql(x, b.string),
                .boolean => |x| x == b.boolean,
                .object => |x| x == b.object,
            };
        }
        // null == undefined.
        if ((a == .null_value and b == .undefined_value) or
            (a == .undefined_value and b == .null_value)) return true;
        // number vs string / boolean folding.
        if (a == .boolean) return self.abstractEquals(.{ .number = if (a.boolean) 1 else 0 }, b);
        if (b == .boolean) return self.abstractEquals(a, .{ .number = if (b.boolean) 1 else 0 });
        if (a == .number and b == .string) {
            return a.number == value_mod.stringToNumber(b.string, self.swf_version);
        }
        if (a == .string and b == .number) {
            return value_mod.stringToNumber(a.string, self.swf_version) == b.number;
        }
        // primitive vs object → ToPrimitive(object).
        if (a == .object and b != .object) {
            const p = try self.toPrimitiveNum(a);
            if (p == .object or p == .undefined_value) return false;
            return self.abstractEquals(p, b);
        }
        if (b == .object and a != .object) {
            const p = try self.toPrimitiveNum(b);
            if (p == .object or p == .undefined_value) return false;
            return self.abstractEquals(a, p);
        }
        return false;
    }

    /// ES3 §11.8.5 abstract relational (Less2/Greater): returns
    /// undefined when incomparable (NaN involved).
    pub fn abstractLess(self: *Vm, a: Value, b: Value) Error!Value {
        // A non-display object surviving `valueOf` makes the comparison
        // false outright — `{} < {}` is false, not undefined (ruffle
        // value.rs:496-503).
        const pa = try self.toPrimitiveNum(a);
        if (pa == .object and !self.isDisplayValue(pa)) return .{ .boolean = false };
        const pb = try self.toPrimitiveNum(b);
        if (pb == .object and !self.isDisplayValue(pb)) return .{ .boolean = false };
        if (pa == .string and pb == .string) {
            return .{ .boolean = strings.order(pa.string, pb.string) == .lt };
        }
        const na = value_mod.toNumberPrimitive(pa, self.swf_version);
        const nb = value_mod.toNumberPrimitive(pb, self.swf_version);
        if (std.math.isNan(na) or std.math.isNan(nb)) return .undefined_value;
        return .{ .boolean = na < nb };
    }

    /// Two MovieClip values compare by PATH, not by identity. Every stage
    /// object pushed onto the AVM1 stack is wrapped in a path-based
    /// `MovieClipReference` (ruffle activation.rs `stack_push`), and both
    /// `==` and `===` compare those by path (value.rs:114). Distinct
    /// objects normally have distinct paths, so this only shows up when a
    /// goto rewind leaves two same-named instances alive at once — which
    /// is exactly what corpus rewind_depth checks.
    fn clipPath(self: *Vm, v: Value) ?strings.AvmString {
        if (v != .object) return null;
        const n = self.objects.get(v.object).native;
        if (n != .clip) return null;
        const p = @import("stage_object.zig").dotPathOf(self, n.clip) catch return null;
        return if (p.len == 0) null else p;
    }

    pub fn strictEquals(self: *Vm, a: Value, b: Value) bool {
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
        if (self.clipPath(a)) |pa| {
            if (self.clipPath(b)) |pb| return strings.eql(pa, pb);
        }
        return switch (a) {
            .undefined_value, .null_value => true,
            // PLAYER-SPECIFIC (same quirk as abstract equality): AVM1
            // reports NaN === NaN as true.
            .number => |x| x == b.number or (std.math.isNan(x) and std.math.isNan(b.number)),
            .string => |x| strings.eql(x, b.string),
            .boolean => |x| x == b.boolean,
            .object => |x| x == b.object,
        };
    }

    /// Property read honoring addProperty getters (proto-chain aware).
    pub fn getProperty(self: *Vm, h: ObjectHandle, name: strings.AvmString, this: Value) anyerror!Value {
        var start = h;
        var recv = this;
        // `super` owns nothing: a read on it resolves from the base
        // prototype's own prototype, against the ORIGINAL `this` — which
        // it substitutes for whatever the caller passed (ruffle
        // object.rs:161-168, `get_opt`).
        if (self.objects.get(h).native == .super_obj) {
            const p = self.superProto(h);
            if (p != .object) return .undefined_value;
            start = p.object;
            recv = .{ .object = self.objects.get(h).native.super_obj.this };
        }
        const loc = self.objects.findChainedLocated(start, name, self.case_sensitive) orelse
            return .undefined_value;
        if (loc.prop.getter != 0) {
            const getter = loc.prop.getter;
            if (self.enterPropertyCall(loc.owner, name)) |_| {
                defer self.leavePropertyCall();
                return self.callFunction(.{ .object = getter }, recv, &.{});
            }
            // Over the per-property limit Flash falls back to LOCAL
            // resolution — the shadow data slot every write leaves behind
            // even when a setter ran (ruffle object.rs:452-457).
            return self.objects.findOwn(loc.owner, name, self.case_sensitive).?.value;
        }
        return loc.prop.value;
    }

    /// The prototype of `h` as the chain walk sees it. A `super` in the
    /// middle of a chain contributes its OWN base prototype, not the
    /// nothing it stores (ruffle script_object.rs:724-727).
    pub fn protoValue(self: *Vm, h: ObjectHandle) Value {
        if (self.objects.get(h).native == .super_obj) return self.superProto(h);
        const p = self.objects.get(h).proto;
        // A display object reached AS a prototype ends the chain — see
        // Objects.findChained.
        if (p == .object) {
            const n = self.objects.get(p.object).native;
            if (n == .clip or n == .display) return .undefined_value;
        }
        return p;
    }

    const PROPERTY_RECURSION_LIMIT = 65;

    fn propertyKey(h: ObjectHandle, name: strings.AvmString) u64 {
        var hash: u32 = 2166136261;
        for (name) |c| {
            hash ^= c;
            hash *%= 16777619;
        }
        return (@as(u64, h) << 32) | hash;
    }

    /// Claim a slot on the per-property recursion stack. Null means the
    /// limit is reached and the call must be SKIPPED — Flash does not warn,
    /// it simply stops descending. Getters, setters and watchers for the
    /// same property share one budget, which is what the two
    /// `watch_recursion` tests measure.
    fn enterPropertyCall(self: *Vm, h: ObjectHandle, name: strings.AvmString) ?void {
        const key = propertyKey(h, name);
        var same: usize = 0;
        for (self.property_call_stack.items) |k| {
            if (k == key) same += 1;
        }
        if (same >= PROPERTY_RECURSION_LIMIT) return null;
        self.property_call_stack.append(self.gpa, key) catch return null;
        return {};
    }

    fn leavePropertyCall(self: *Vm) void {
        _ = self.property_call_stack.pop();
    }

    /// The watcher hook for callers that do their own storing — the
    /// `__proto__` write is an engine action, not an ordinary put, but a
    /// `watch("__proto__")` still sees it and can rewrite the value.
    pub fn applyWatchers(self: *Vm, h: ObjectHandle, name: strings.AvmString, v: Value, this: Value) anyerror!Value {
        if (self.objects.get(h).watchers.len == 0) return v;
        return self.callWatcher(h, name, v, this);
    }

    /// Run the watcher registered for `name` on `h`, if any, and return the
    /// value it wants stored — the callback's RETURN VALUE replaces the
    /// assignment, which is what lets a watcher veto or rewrite a write.
    /// A throw out of the watcher stores undefined and keeps unwinding.
    fn callWatcher(self: *Vm, h: ObjectHandle, name: strings.AvmString, v: Value, this: Value) anyerror!Value {
        const w = (self.objects.get(h).findWatcher(name, self.case_sensitive) orelse return v).*;
        if (!self.isCallable(.{ .object = w.callback })) return v;

        // Over the limit the call is simply skipped and the plain write
        // goes ahead unchanged; Flash does not report it (ruffle
        // script_object.rs call_watcher swallows PropertyRecursionLimit).
        // The watcher shares one budget with the property's getter and
        // setter, and the frame must be PUSHED for the duration of the
        // call — a watcher that rewrites its own property is exactly the
        // recursion this counts (corpus watch_recursion_swf7).
        if (self.enterPropertyCall(h, name) == null) return v;
        defer self.leavePropertyCall();

        // The STORED value, not the getter's — ruffle calls `get_stored`.
        const old = self.objects.getChained(h, name, self.case_sensitive) orelse Value.undefined_value;
        return self.callFunction(
            .{ .object = w.callback },
            this,
            &.{ .{ .string = name }, old, v, w.user_data },
        ) catch |e| {
            if (e == error.Avm1Thrown) {
                // The watcher throwing stores undefined, then rethrows.
                try self.objects.put(h, name, .undefined_value, self.case_sensitive);
            }
            return e;
        };
    }

    /// Property write honoring addProperty setters (proto-chain aware:
    /// an inherited accessor intercepts writes to the child).
    pub fn setProperty(self: *Vm, h: ObjectHandle, name: strings.AvmString, v_in: Value, this: Value) anyerror!void {
        if (name.len == 0) return;
        const v = if (self.objects.get(h).watchers.len == 0)
            v_in
        else
            try self.callWatcher(h, name, v_in, this);
        // An INHERITED virtual property intercepts the write entirely:
        // the setter runs (a getter-only one just swallows it) and nothing
        // is stored on the receiver. An OWN one is different — ruffle's
        // `set_local` calls the setter and then stores the value anyway,
        // leaving a shadow that a getter over the recursion limit reads
        // back (ruffle object.rs:232-260, script_object.rs:317-329).
        if (self.objects.findOwn(h, name, self.case_sensitive) == null) {
            if (self.objects.findChainedForWriteLocated(h, name, self.case_sensitive)) |loc| {
                // A version-HIDDEN accessor does not count as virtual, so
                // the write falls through and defines a plain property
                // that shadows it. `textfield_props_swf6` pins that: the
                // five SWF8 members take the assignment while the other
                // thirty swallow it (ruffle `has_own_virtual` ANDs
                // `is_virtual()` with `allow_swf_version`).
                const gated = object_mod.versionHidden(loc.prop.attrs, self.objects.swf_version);
                if (!gated and (loc.prop.getter != 0 or loc.prop.setter != 0)) {
                    const setter = loc.prop.setter;
                    if (setter != 0) {
                        if (self.enterPropertyCall(loc.owner, name)) |_| {
                            defer self.leavePropertyCall();
                            _ = try self.callFunction(.{ .object = setter }, this, &.{v});
                        }
                    }
                    return;
                }
            }
            // The magic display properties are dispatched by the STORAGE
            // primitive in ruffle (script_object.rs set_local:278-292), not
            // by the interpreter, so `attachMovie(..., {_x: 10})` and every
            // other engine-side write reaches `_x` rather than defining a
            // plain property that shadows it (corpus issue_2084).
            if (try @import("stage_object.zig").assignMember(self, h, name, v)) return;
        } else if (self.objects.findOwn(h, name, self.case_sensitive).?.setter != 0) {
            const setter = self.objects.findOwn(h, name, self.case_sensitive).?.setter;
            if (self.enterPropertyCall(h, name)) |_| {
                defer self.leavePropertyCall();
                _ = try self.callFunction(.{ .object = setter }, this, &.{v});
            }
        }
        try self.objects.put(h, name, v, self.case_sensitive);
        // A text field bound to this property mirrors the new value
        // (ruffle stage_object.rs `notify_property_change`, run after
        // `set_local`).
        try notifyTextBinding(self, h, name, v);
    }

    /// Split out so the hot path stays a single branch: only a DISPLAY
    /// object can carry bindings, and almost none of them do.
    fn notifyTextBinding(self: *Vm, h: ObjectHandle, name: strings.AvmString, v: Value) !void {
        const t = @import("stage_object.zig").targetOf(self, h) orelse return;
        try @import("text_binding.zig").notify(self, t.obj, name, v);
    }

    // --- scope objects ----------------------------------------------------

    /// Scope chains are ScriptObjects linked by `scope_parent`.
    pub fn newScope(self: *Vm, parent: ObjectHandle) Error!ObjectHandle {
        const h = try self.objects.create(); // NO object proto on scopes
        self.objects.get(h).scope_parent = parent;
        return h;
    }

    pub fn scopeGet(self: *Vm, scope: ObjectHandle, name: strings.AvmString) ?Value {
        var cur = scope;
        while (cur != 0) {
            if (self.objects.getChained(cur, name, self.case_sensitive)) |v| return v;
            cur = self.objects.get(cur).scope_parent;
        }
        // Finally _global.
        return self.objects.getChained(self.globals, name, self.case_sensitive);
    }

    /// SetVariable semantics: overwrite an existing binding anywhere on
    /// the chain, else define on the BOTTOM (target/timeline) scope.
    pub fn scopeSet(self: *Vm, scope: ObjectHandle, name: strings.AvmString, v: Value) anyerror!void {
        var cur = scope;
        var bottom = scope;
        while (cur != 0) {
            if (self.objects.hasOwn(cur, name, self.case_sensitive)) {
                return self.storeInScope(cur, name, v);
            }
            bottom = cur;
            cur = self.objects.get(cur).scope_parent;
        }
        return self.storeInScope(bottom, name, v);
    }

    /// A timeline variable is an ordinary property of the clip's object, so
    /// `watch` applies to it too — but only pay for the accessor-aware path
    /// when something is actually watching.
    fn storeInScope(self: *Vm, h: ObjectHandle, name: strings.AvmString, v: Value) anyerror!void {
        if (self.objects.get(h).watchers.len == 0) {
            return self.objects.put(h, name, v, self.case_sensitive);
        }
        return self.setProperty(h, name, v, .{ .object = h });
    }

    /// DefineLocal: always on the innermost scope.
    pub fn scopeDefineLocal(self: *Vm, scope: ObjectHandle, name: strings.AvmString, v: Value) Error!void {
        try self.objects.put(scope, name, v, self.case_sensitive);
        // `var theVar = …` at the top level of a timeline defines on the
        // CLIP, so a field bound to that name sees it (corpus
        // textfield_variable's last block).
        notifyTextBinding(self, scope, name, v) catch {};
    }

    // --- function calls ---------------------------------------------------

    pub fn callFunction(self: *Vm, callee: Value, this: Value, args: []const Value) anyerror!Value {
        if (!self.isCallable(callee)) return .undefined_value;
        if (self.call_depth >= self.max_call_depth) {
            self.halted = true;
            return .undefined_value;
        }
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const fk = self.objects.get(callee.object).native.function;
        switch (fk) {
            .native => |f| return f(@ptrCast(self), this, args),
            .avm1 => |f| return self.callAvm1(callee.object, f, this, args),
        }
    }

    // --- Object.registerClass ---------------------------------------------

    /// Register (ctor != 0) or unregister a class for an export symbol.
    pub fn registerClass(self: *Vm, name: strings.AvmString, ctor: ObjectHandle) Error!void {
        for (self.class_registry.items, 0..) |e, i| {
            if (self.nameMatches(e.name, name)) {
                if (ctor == 0) {
                    _ = self.class_registry.orderedRemove(i);
                } else {
                    self.class_registry.items[i].ctor = ctor;
                }
                return;
            }
        }
        if (ctor == 0) return;
        const key = try self.arena().dupe(u16, name);
        try self.class_registry.append(self.arena(), .{ .name = key, .ctor = ctor });
    }

    pub fn registeredClass(self: *Vm, name: strings.AvmString) ?ObjectHandle {
        for (self.class_registry.items) |e| {
            if (self.nameMatches(e.name, name)) return e.ctor;
        }
        return null;
    }

    fn nameMatches(self: *Vm, a: strings.AvmString, b: strings.AvmString) bool {
        return if (self.case_sensitive) strings.eql(a, b) else strings.eqlIgnoreCase(a, b);
    }

    /// Run a constructor against an object that already exists — what a
    /// registered class does to a clip the timeline placed. Ruffle's
    /// `construct_on_existing`: define `__constructor__`, call with `super`
    /// starting one prototype up, and IGNORE the return value.
    pub fn constructOnExisting(self: *Vm, ctor: ObjectHandle, obj: ObjectHandle) anyerror!void {
        const c: Value = .{ .object = ctor };
        if (!self.isCallable(c)) return;
        try self.objects.putWithAttrs(obj, S("__constructor__"), c, .{ .dont_enum = true }, self.case_sensitive);
        if (self.swf_version < 7) {
            try self.objects.putWithAttrs(obj, S("constructor"), c, .{ .dont_enum = true }, self.case_sensitive);
        }
        self.in_construct += 1;
        defer self.in_construct -= 1;
        _ = try self.callWithSuperDepth(c, .{ .object = obj }, &.{}, 1);
    }

    /// `new` semantics: fresh object with ctor.prototype, ctor invoked
    /// with it as this; object result overrides.
    pub fn construct(self: *Vm, ctor: Value, args: []const Value) anyerror!Value {
        if (!self.isCallable(ctor)) return .undefined_value;
        self.in_construct += 1;
        defer self.in_construct -= 1;
        const obj = try self.objects.create();
        const proto = self.objects.getChained(ctor.object, S("prototype"), self.case_sensitive) orelse
            Value{ .object = self.object_proto };
        self.objects.get(obj).proto = if (proto == .object) proto else .{ .object = self.object_proto };
        try self.objects.putWithAttrs(obj, S("__constructor__"), ctor, .{ .dont_enum = true }, self.case_sensitive);
        // Below SWF7 `constructor` is defined on the INSTANCE as well, not
        // just inherited from the prototype (ruffle define_constructor_props).
        if (self.swf_version < 7) {
            try self.objects.putWithAttrs(obj, S("constructor"), ctor, .{ .dont_enum = true }, self.case_sensitive);
        }
        const this: Value = .{ .object = obj };
        // A constructor frame's `super` starts at depth 1, i.e. at
        // `this.__proto__` — which is exactly where ActionExtends put the
        // SUPERCLASS's __constructor__. Starting at 0 would find the
        // instance's own and call the same constructor again
        // (ruffle construct_on_existing passes 1).
        const r = try self.callWithSuperDepth(ctor, this, args, 1);
        // Ruffle propagates the return value ONLY for native constructors
        // (function.rs:709 "Propagate the return value only for native
        // constructors") — a bytecode constructor's `return 5` is ignored,
        // but `new Transform()` with no clip really is undefined.
        if (self.objects.get(ctor.object).native.function == .native) return r;
        return if (r == .object) r else this;
    }

    /// A `super` view of `this` with `depth` prototype layers removed.
    pub fn newSuper(self: *Vm, this: ObjectHandle, depth: u8) Error!ObjectHandle {
        const h = try self.objects.create();
        self.objects.get(h).native = .{ .super_obj = .{ .this = this, .depth = depth } };
        return h;
    }

    /// `this` walked up `depth` prototypes — where `super` starts looking.
    pub fn superBaseProto(self: *Vm, s: @TypeOf(@as(object_mod.NativeInfo, undefined).super_obj)) ?ObjectHandle {
        var cur: Value = .{ .object = s.this };
        var i: u8 = 0;
        while (i < s.depth) : (i += 1) {
            const p = self.protoValue(cur.object);
            if (p != .object) return null;
            cur = p;
        }
        return cur.object;
    }

    /// `super.__proto__` is the base prototype's OWN prototype — one more
    /// layer up than `this.__proto__` (ruffle SuperObject::proto:68-73).
    pub fn superProto(self: *Vm, h: ObjectHandle) Value {
        const s = self.objects.get(h).native.super_obj;
        const base = self.superBaseProto(s) orelse return .undefined_value;
        return self.objects.get(base).proto;
    }

    /// Calling `super(...)` runs the base prototype's `__constructor__`
    /// against the ORIGINAL `this`, one prototype layer deeper
    /// (ruffle super_object.rs:77-105).
    pub fn callSuper(self: *Vm, h: ObjectHandle, args: []const Value) anyerror!Value {
        const s = self.objects.get(h).native.super_obj;
        const base = self.superBaseProto(s) orelse return .undefined_value;
        // `get_opt(.., call_resolve_fn = false)`: an addProperty getter for
        // `__constructor__` IS honoured, but a `__resolve` fallback is not
        // (ruffle super_object.rs:82-86).
        const ctor = try self.getProperty(base, S("__constructor__"), .{ .object = base });
        if (!self.isCallable(ctor)) return .undefined_value;
        return self.callWithSuperDepth(ctor, .{ .object = s.this }, args, s.depth +| 1);
    }

    /// `super.method(...)`: resolve from ABOVE the base prototype and run
    /// it with the original `this` (super_object.rs:107-136).
    pub fn callSuperMethod(self: *Vm, h: ObjectHandle, name: strings.AvmString, args: []const Value) anyerror!Value {
        const s = self.objects.get(h).native.super_obj;
        const base = self.superBaseProto(s) orelse return .undefined_value;
        const above = self.objects.get(base).proto;
        if (above != .object) return .undefined_value;
        const this: Value = .{ .object = s.this };
        const m = try self.getProperty(above.object, name, this);
        if (!self.isCallable(m)) return .undefined_value;
        // The callee's own `super` starts below wherever the method was
        // actually found, not just below us — `self.depth + depth + 1`
        // (super_object.rs:120-126).
        const found = self.objects.protoDepth(above.object, name, self.case_sensitive) orelse 0;
        return self.callWithSuperDepth(m, this, args, s.depth +| found +| 1);
    }

    /// Like callFunction, but the callee's own `super` starts one layer
    /// further down — that is what makes a three-deep chain terminate.
    fn callWithSuperDepth(self: *Vm, callee: Value, this: Value, args: []const Value, depth: u8) anyerror!Value {
        const prev = self.super_depth;
        self.super_depth = depth;
        defer self.super_depth = prev;
        return self.callFunction(callee, this, args);
    }

    fn callAvm1(self: *Vm, callee: ObjectHandle, f: object_mod.Avm1Function, this: Value, args: []const Value) anyerror!Value {
        const activation = @import("activation.zig");
        // Consume the pending super depth: it belongs to THIS frame only.
        const depth = self.super_depth;
        self.super_depth = 0;
        // Fresh local scope chained to the captured definition scope.
        const local = try self.newScope(f.scope);

        // Local registers (fn2) — r0 unused by preloads; slots r1.. get the
        // preloaded values in canonical order.
        var registers: []Value = &.{};
        if (f.with_registers and f.register_count > 0) {
            registers = try self.arena().alloc(Value, f.register_count);
            @memset(registers, .undefined_value);
        }
        var next_reg: u8 = 1;

        const fl = f.flags;
        const preload = f.with_registers;
        // this
        if (preload and fl.preload_this) {
            if (next_reg < registers.len) registers[next_reg] = this;
            next_reg += 1;
        }
        if (!(preload and fl.suppress_this)) {
            try self.objects.putWithAttrs(local, S("this"), this, .{ .dont_enum = true, .dont_delete = true }, self.case_sensitive);
        }
        // arguments
        const wants_arguments = !preload or (!fl.suppress_arguments or fl.preload_arguments);
        var args_val: Value = .undefined_value;
        if (wants_arguments) {
            const arr = try self.newArray();
            for (args, 0..) |av, i| try self.arraySet(arr, @intCast(i), av);
            try self.objects.putWithAttrs(arr, S("callee"), .{ .object = callee }, .{ .dont_enum = true }, self.case_sensitive);
            args_val = .{ .object = arr };
        }
        if (preload and fl.preload_arguments) {
            if (next_reg < registers.len) registers[next_reg] = args_val;
            next_reg += 1;
        }
        if (!(preload and fl.suppress_arguments)) {
            if (wants_arguments) {
                try self.objects.putWithAttrs(local, S("arguments"), args_val, .{ .dont_enum = true, .dont_delete = true }, self.case_sensitive);
            }
        }
        // `super` exists only when there is a `this` to view through, and
        // is a REGISTER when preloaded, otherwise a local VARIABLE
        // (ruffle function.rs:235-249). We need both forms — corpus
        // as2_super_via_manual_prototype uses the variable.
        if (!fl.suppress_super and this == .object) {
            const zuper = try self.newSuper(this.object, depth);
            if (preload and fl.preload_super) {
                if (next_reg < registers.len) registers[next_reg] = .{ .object = zuper };
            } else if (!preload or !fl.preload_super) {
                try self.objects.putWithAttrs(local, S("super"), .{ .object = zuper }, .{ .dont_enum = true, .dont_delete = true }, self.case_sensitive);
            }
        }
        if (preload and fl.preload_super) next_reg += 1;
        // _root/_parent/_global preloads.
        if (preload and fl.preload_root) {
            if (next_reg < registers.len) registers[next_reg] = self.root_object;
            next_reg += 1;
        }
        if (preload and fl.preload_parent) {
            if (next_reg < registers.len) {
                const stage = @import("stage_object.zig");
                registers[next_reg] = if (this == .object)
                    try stage.parentOf(self, this.object)
                else
                    .undefined_value;
            }
            next_reg += 1;
        }
        if (preload and fl.preload_global) {
            if (next_reg < registers.len) registers[next_reg] = .{ .object = self.globals };
            next_reg += 1;
        }

        // Parameters: register-bound or named locals.
        var it = opcodes.ParamIterator.init(f.params_raw, f.with_registers);
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) {
            const av: Value = if (i < args.len) args[i] else .undefined_value;
            if (f.with_registers and p.register != 0) {
                if (p.register < registers.len) registers[p.register] = av;
            } else {
                const name = try strings.fromSwf(self.arena(), p.name, f.swf_version);
                try self.objects.put(local, name, av, self.case_sensitive);
            }
        }

        var act = activation.Activation.init(self, f.body, this, local, f.constant_pool);
        act.local_registers = registers;
        // SWF6+ functions are CLOSURES: they carry the base clip from
        // where they were defined. SWF5 functions are not — they adopt
        // `this`'s clip, which Activation.init already derived.
        // ruffle function.rs:303-310.
        if (self.swf_version >= 6 and f.base_clip != 0) {
            act.base_clip = f.base_clip;
            act.target_clip = f.base_clip;
        }
        // A throw propagates as error.Avm1Thrown, so an outer try/catch
        // in a CALLING function still sees it.
        const flow = try act.run();
        return switch (flow) {
            .return_value => |v| v,
            // A throw that reached the top of the callee keeps going.
            .thrown => |v| {
                self.pending_throw = v;
                return error.Avm1Thrown;
            },
            else => .undefined_value,
        };
    }

    // --- misc -------------------------------------------------------------

    pub fn traceLine(self: *Vm, s: strings.AvmString) Error!void {
        const utf8 = strings.toUtf8(self.arena(), s) catch return;
        try self.trace_buf.appendSlice(self.gpa, utf8);
        try self.trace_buf.append(self.gpa, '\n');
    }

    pub fn pushStack(self: *Vm, v: Value) Error!void {
        try self.stack.append(self.gpa, v);
    }

    pub fn popStack(self: *Vm) Value {
        return self.stack.pop() orelse .undefined_value;
    }
};

test {
    _ = @import("activation.zig");
}
