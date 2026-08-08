//! Built-in classes and functions installed into _global at VM creation.
//! M3 scope: the ES3 core needed by the conformance corpus — Object,
//! Function, Array, String, Number, Boolean, Math, the global coercion
//! functions, getTimer. MovieClip methods land with the display glue (M4);
//! Date/Key/Mouse/Sound later.
//!
//! Reference: ruffle core/src/avm1/globals/*.rs + ECMA-262 3rd ed.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const object_mod = @import("../object.zig");
const runtime = @import("../runtime.zig");
const decl = @import("decl.zig");
const timers_mod = @import("../timers.zig");

const Value = runtime.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;

/// Ruffle's flag set for a built-in member (`DONT_ENUM | DONT_DELETE`) and
/// its read-only variant, plus the version gates — see globals/decl.zig.
const hidden = decl.hidden;
const frozen = decl.frozen;
const ver = decl.ver;

pub fn install(vm: *Vm) !void {
    const cs = false; // built-ins install case-preserving; lookup handles case
    vm.globals = try vm.objects.create();

    // Prototypes first (bare objects; Object.prototype has no proto).
    vm.object_proto = try vm.objects.create();
    vm.function_proto = try vm.objects.create();
    vm.objects.get(vm.function_proto).proto = .{ .object = vm.object_proto };
    vm.array_proto = try vm.objects.create();
    vm.objects.get(vm.array_proto).proto = .{ .object = vm.object_proto };
    vm.string_proto = try vm.objects.create();
    vm.objects.get(vm.string_proto).proto = .{ .object = vm.object_proto };
    vm.number_proto = try vm.objects.create();
    vm.objects.get(vm.number_proto).proto = .{ .object = vm.object_proto };
    vm.boolean_proto = try vm.objects.create();
    vm.objects.get(vm.boolean_proto).proto = .{ .object = vm.object_proto };

    // `_global` itself and the class bindings on it are DONT_ENUM only —
    // ruffle globals.rs's top-level table deliberately leaves them
    // deletable (`delete Object` is legal ActionScript).
    const attrs: object_mod.Attributes = .{ .dont_enum = true };

    // --- Object.prototype -------------------------------------------------
    try method(vm, vm.object_proto, "hasOwnProperty", objHasOwnProperty, ver(hidden, decl.V6));
    try method(vm, vm.object_proto, "toString", objToString, hidden);
    try method(vm, vm.object_proto, "toLocaleString", objToString, hidden);
    try method(vm, vm.object_proto, "valueOf", objValueOf, hidden);
    try method(vm, vm.object_proto, "isPropertyEnumerable", objIsPropEnum, ver(hidden, decl.V6));
    try method(vm, vm.object_proto, "isPrototypeOf", objIsPrototypeOf, ver(hidden, decl.V6));
    try method(vm, vm.object_proto, "addProperty", objAddProperty, ver(hidden, decl.V6));
    try method(vm, vm.object_proto, "watch", objWatch, ver(hidden, decl.V6));
    try method(vm, vm.object_proto, "unwatch", objUnwatch, ver(hidden, decl.V6));

    // --- Function.prototype ----------------------------------------------
    try method(vm, vm.function_proto, "call", fnCall, hidden);
    try method(vm, vm.function_proto, "apply", fnApply, hidden);

    // --- Array ------------------------------------------------------------
    try method(vm, vm.array_proto, "push", arrPush, hidden);
    try method(vm, vm.array_proto, "pop", arrPop, hidden);
    try method(vm, vm.array_proto, "shift", arrShift, hidden);
    try method(vm, vm.array_proto, "join", arrJoin, hidden);
    try method(vm, vm.array_proto, "toString", arrToString, hidden);
    try method(vm, vm.array_proto, "concat", arrConcat, hidden);
    try method(vm, vm.array_proto, "slice", arrSlice, hidden);
    try method(vm, vm.array_proto, "unshift", arrUnshift, hidden);
    try method(vm, vm.array_proto, "reverse", arrReverse, hidden);
    try method(vm, vm.array_proto, "splice", arrSplice, hidden);
    try method(vm, vm.array_proto, "sort", arrSort, hidden);

    // --- String.prototype -------------------------------------------------
    try method(vm, vm.string_proto, "toString", strToString, hidden);
    try method(vm, vm.string_proto, "valueOf", strToString, hidden);
    try method(vm, vm.string_proto, "charAt", strCharAt, hidden);
    try method(vm, vm.string_proto, "charCodeAt", strCharCodeAt, hidden);
    try method(vm, vm.string_proto, "toUpperCase", strToUpper, hidden);
    try method(vm, vm.string_proto, "toLowerCase", strToLower, hidden);
    try method(vm, vm.string_proto, "indexOf", strIndexOf, hidden);
    try method(vm, vm.string_proto, "lastIndexOf", strLastIndexOf, hidden);
    try method(vm, vm.string_proto, "substring", strSubstring, hidden);
    try method(vm, vm.string_proto, "substr", strSubstr, hidden);
    try method(vm, vm.string_proto, "slice", strSlice, hidden);
    try method(vm, vm.string_proto, "split", strSplit, hidden);

    // --- Number.prototype -------------------------------------------------
    try method(vm, vm.number_proto, "toString", numToString, hidden);
    try method(vm, vm.number_proto, "valueOf", numValueOf, hidden);

    // --- Boolean.prototype ------------------------------------------------
    try method(vm, vm.boolean_proto, "toString", boolToString, hidden);
    try method(vm, vm.boolean_proto, "valueOf", boolValueOf, hidden);

    // --- Constructors -----------------------------------------------------
    const object_class = try decl.class(vm, "Object", ctorObject, vm.object_proto, attrs);
    try method(vm, object_class, "registerClass", objRegisterClass, frozen);
    _ = try decl.class(vm, "Function", ctorFunction, vm.function_proto, ver(attrs, decl.V6));
    _ = try decl.class(vm, "Array", ctorArray, vm.array_proto, attrs);
    const string_class = try decl.class(vm, "String", ctorString, vm.string_proto, attrs);
    const number_class = try decl.class(vm, "Number", ctorNumber, vm.number_proto, attrs);
    _ = try decl.class(vm, "Boolean", ctorBoolean, vm.boolean_proto, attrs);
    try method(vm, string_class, "fromCharCode", strFromCharCode, hidden);
    try constNum(vm, number_class, "MAX_VALUE", std.math.floatMax(f64));
    try constNum(vm, number_class, "MIN_VALUE", 5e-324);
    try constNum(vm, number_class, "NaN", std.math.nan(f64));
    try constNum(vm, number_class, "POSITIVE_INFINITY", std.math.inf(f64));
    try constNum(vm, number_class, "NEGATIVE_INFINITY", -std.math.inf(f64));

    // --- Math -------------------------------------------------------------
    const math = try decl.namespace(vm, "Math", attrs);
    try constNum(vm, math, "PI", std.math.pi);
    try constNum(vm, math, "E", std.math.e);
    try constNum(vm, math, "LN10", @log(10.0));
    try constNum(vm, math, "LN2", @log(2.0));
    try constNum(vm, math, "LOG10E", 1.0 / @log(10.0));
    try constNum(vm, math, "LOG2E", 1.0 / @log(2.0));
    try constNum(vm, math, "SQRT1_2", @sqrt(0.5));
    try constNum(vm, math, "SQRT2", @sqrt(2.0));
    // Every Math method is READ_ONLY in ruffle math.rs.
    try method(vm, math, "abs", mathAbs, frozen);
    try method(vm, math, "floor", mathFloor, frozen);
    try method(vm, math, "ceil", mathCeil, frozen);
    try method(vm, math, "round", mathRound, frozen);
    try method(vm, math, "sqrt", mathSqrt, frozen);
    try method(vm, math, "pow", mathPow, frozen);
    try method(vm, math, "min", mathMin, frozen);
    try method(vm, math, "max", mathMax, frozen);
    try method(vm, math, "random", mathRandom, frozen);
    try method(vm, math, "sin", mathSin, frozen);
    try method(vm, math, "cos", mathCos, frozen);
    try method(vm, math, "tan", mathTan, frozen);
    try method(vm, math, "atan", mathAtan, frozen);
    try method(vm, math, "atan2", mathAtan2, frozen);
    try method(vm, math, "asin", mathAsin, frozen);
    try method(vm, math, "acos", mathAcos, frozen);
    try method(vm, math, "exp", mathExp, frozen);
    try method(vm, math, "log", mathLog, frozen);

    // --- global functions + constants -------------------------------------
    try method(vm, vm.globals, "isNaN", globalIsNan, attrs);
    try method(vm, vm.globals, "isFinite", globalIsFinite, attrs);
    try method(vm, vm.globals, "parseInt", globalParseInt, attrs);
    try method(vm, vm.globals, "parseFloat", globalParseFloat, attrs);
    try method(vm, vm.globals, "getTimer", globalGetTimer, attrs);
    try method(vm, vm.globals, "ASSetPropFlags", globalAsSetPropFlags, attrs);
    try method(vm, vm.globals, "ASnative", globalAsNative, attrs);
    try method(vm, vm.globals, "escape", globalEscape, attrs);
    try method(vm, vm.globals, "unescape", globalUnescape, attrs);
    try method(vm, vm.globals, "updateAfterEvent", globalNoop, attrs);
    try method(vm, vm.globals, "setInterval", globalSetInterval, attrs);
    try method(vm, vm.globals, "setTimeout", globalSetTimeout, attrs);
    try method(vm, vm.globals, "clearInterval", globalClearInterval, attrs);
    try method(vm, vm.globals, "clearTimeout", globalClearInterval, attrs);

    // --- MovieClip ---------------------------------------------------------
    // The prototype has to exist before anything else touches it: clip
    // objects chain to it and content routinely does
    // `MovieClip.prototype.foo = function(){}` expecting every clip to
    // inherit it.
    {
        const mc_proto = try vm.objects.create();
        vm.objects.get(mc_proto).proto = .{ .object = vm.object_proto };
        vm.movieclip_proto = mc_proto;
        _ = try decl.class(vm, "MovieClip", ctorMovieClip, mc_proto, attrs);
        try @import("movie_clip.zig").install(vm);
    }

    // --- Button / TextField -------------------------------------------------
    // The other two scriptable display kinds. Their real surfaces are M4-C
    // and M4-D; what they need NOW is to exist and to carry `getDepth`,
    // which ruffle serves to all three from one `globals::get_depth`.
    // Button's members carry NO attribute flags at all in ruffle's table —
    // they enumerate and delete like ordinary properties.
    {
        const btn_proto = try vm.objects.create();
        vm.objects.get(btn_proto).proto = .{ .object = vm.object_proto };
        vm.button_proto = btn_proto;
        try decl.value(vm, btn_proto, "useHandCursor", .{ .boolean = true }, .{});
        try decl.value(vm, btn_proto, "enabled", .{ .boolean = true }, .{});
        try decl.method(vm, btn_proto, "getDepth", @import("movie_clip.zig").getDepth, ver(.{}, decl.V6));
        _ = try decl.class(vm, "Button", ctorMovieClip, btn_proto, attrs);

        const tf_proto = try vm.objects.create();
        vm.objects.get(tf_proto).proto = .{ .object = vm.object_proto };
        vm.textfield_proto = tf_proto;
        try decl.method(vm, tf_proto, "getDepth", @import("movie_clip.zig").getDepth, ver(frozen, decl.V6));
        _ = try decl.class(vm, "TextField", ctorMovieClip, tf_proto, attrs);
    }

    try @import("geom.zig").install(vm);
    try @import("date.zig").install(vm);
    try @import("singletons.zig").install(vm);

    // --- Error ------------------------------------------------------------
    {
        const error_proto = try vm.objects.create();
        vm.objects.get(error_proto).proto = .{ .object = vm.object_proto };
        // ruffle error.rs declares all three with NO flags at all — they
        // enumerate and delete like ordinary properties.
        try method(vm, error_proto, "toString", errorToString, .{});
        try vm.objects.putWithAttrs(error_proto, S("name"), .{ .string = S("Error") }, .{}, cs);
        try vm.objects.putWithAttrs(error_proto, S("message"), .{ .string = S("Error") }, .{}, cs);
        _ = try decl.class(vm, "Error", ctorError, error_proto, attrs);
    }
    try vm.objects.putWithAttrs(vm.globals, S("Infinity"), .{ .number = std.math.inf(f64) }, attrs, cs);
    try vm.objects.putWithAttrs(vm.globals, S("NaN"), .{ .number = std.math.nan(f64) }, attrs, cs);
    try vm.objects.putWithAttrs(vm.globals, S("_global"), .{ .object = vm.globals }, attrs, cs);
    // Flash's own globals.as uses `o` as a scratch alias while building the
    // table and, at the end, sets it to null instead of deleting it. So in
    // EVERY movie `o` exists and is null (ruffle globals.rs, corpus `o`).
    try vm.objects.putWithAttrs(vm.globals, S("o"), .null_value, .{}, cs);
}

fn ctorMovieClip(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

const method = decl.method;
const constNum = decl.constNum;

/// `setInterval(fn, ms, ...args)` or `setInterval(obj, "name", ms, ...args)`.
/// The first argument decides which: a FUNCTION takes the interval second,
/// an ordinary object takes a method name second and the interval third.
/// An `undefined` interval creates nothing and returns undefined — content
/// uses that to feature-test.
fn globalSetInterval(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return createTimer(p, this, args, false);
}

fn globalSetTimeout(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return createTimer(p, this, args, true);
}

fn createTimer(p: *anyopaque, this: Value, args: []const Value, is_timeout: bool) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const first = arg(args, 0);
    if (first != .object) return .undefined_value;

    var callback: timers_mod.Callback = undefined;
    var interval_arg: Value = .undefined_value;
    var rest: []const Value = &.{};
    if (vm.isCallable(first)) {
        callback = .{ .func = first.object };
        interval_arg = arg(args, 1);
        rest = if (args.len > 2) args[2..] else &.{};
    } else {
        callback = .{ .method = .{
            .this = first.object,
            .name = try vm.toStringValue(arg(args, 1)),
        } };
        interval_arg = arg(args, 2);
        rest = if (args.len > 3) args[3..] else &.{};
    }
    if (interval_arg == .undefined_value) return .undefined_value;
    const interval = value_mod.toInt32(try vm.toNumber(interval_arg));

    const params = try vm.arena().dupe(Value, rest);
    const id = try vm.timers.add(vm.gpa, callback, params, interval, is_timeout);
    return .{ .number = @floatFromInt(id) };
}

/// `clearInterval` and `clearTimeout` are the same function in Flash.
fn globalClearInterval(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    _ = vm.timers.remove(value_mod.toInt32(try vm.toNumber(arg(args, 0))));
    return .undefined_value;
}

/// A built-in that exists so scripts can call it, and does nothing
/// (`updateAfterEvent` — meaningful only for a real display refresh).
fn globalNoop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

// --- Object ------------------------------------------------------------------

fn ctorObject(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const a0 = arg(args, 0);
    if (a0 == .object) return a0;
    if (vm.in_construct > 0 and this == .object) return this;
    return .{ .object = try vm.newObject() };
}

fn ctorFunction(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn objHasOwnProperty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const name = try vm.toStringValue(arg(args, 0));
    return .{ .boolean = vm.objects.hasOwn(this.object, name, vm.case_sensitive) };
}

fn objIsPropEnum(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const name = try vm.toStringValue(arg(args, 0));
    const o = vm.objects.get(this.object);
    const i = o.find(name, vm.case_sensitive) orelse return .{ .boolean = false };
    const attrs = o.props.items[i].attrs;
    if (object_mod.versionHidden(attrs, vm.swf_version)) return .{ .boolean = false };
    return .{ .boolean = !attrs.dont_enum };
}

fn objToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this == .object and vm.objects.get(this.object).native == .function) {
        return .{ .string = S("[type Function]") };
    }
    return .{ .string = S("[object Object]") };
}

fn objValueOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

/// `a.isPrototypeOf(b)` — is `a` anywhere on `b`'s prototype chain? Uses
/// `Vm.protoValue` so it obeys the same chain rules as everything else
/// (a `super` contributes its base proto; a display object ends the chain).
/// `obj.watch(name, callback, userData)` — intercept writes to `name`.
/// The watch lives beside the properties, not on one: it can be installed
/// before the property exists and survives `delete`.
fn objWatch(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const callback = arg(args, 1);
    if (!vm.isCallable(callback)) return .{ .boolean = false };
    const name = try vm.toStringValue(args[0]);
    const o = vm.objects.get(this.object);
    if (o.findWatcher(name, vm.case_sensitive)) |w| {
        w.callback = callback.object;
        w.user_data = arg(args, 2);
        return .{ .boolean = true };
    }
    const grown = try vm.arena().alloc(object_mod.Watcher, o.watchers.len + 1);
    @memcpy(grown[0..o.watchers.len], o.watchers);
    grown[o.watchers.len] = .{
        .key = try vm.arena().dupe(u16, name),
        .callback = callback.object,
        .user_data = arg(args, 2),
    };
    o.watchers = grown;
    return .{ .boolean = true };
}

fn objUnwatch(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const name = try vm.toStringValue(args[0]);
    const o = vm.objects.get(this.object);
    for (o.watchers, 0..) |w, i| {
        const match = if (vm.case_sensitive)
            strings.eql(w.key, name)
        else
            strings.eqlIgnoreCase(w.key, name);
        if (!match) continue;
        const shrunk = try vm.arena().alloc(object_mod.Watcher, o.watchers.len - 1);
        @memcpy(shrunk[0..i], o.watchers[0..i]);
        @memcpy(shrunk[i..], o.watchers[i + 1 ..]);
        o.watchers = shrunk;
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

/// `Object.registerClass(symbol, ctor)` — bind an ExportAssets symbol to a
/// constructor, so every future instance of that character is built from it.
/// `null`/`undefined` unregisters. Anything that is not a function returns
/// false and changes nothing (ruffle globals/object.rs register_class).
fn objRegisterClass(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len < 2) return .{ .boolean = false };
    const ctor = args[1];
    const handle: runtime.ObjectHandle = switch (ctor) {
        .null_value, .undefined_value => 0,
        .object => |h| if (vm.isCallable(ctor)) h else return .{ .boolean = false },
        else => return .{ .boolean = false },
    };
    const name = try vm.toStringValue(args[0]);
    try vm.registerClass(name, handle);
    return .{ .boolean = true };
}

fn objIsPrototypeOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const subject = arg(args, 0);
    if (subject != .object) return .{ .boolean = false };
    var cur = vm.protoValue(subject.object);
    var depth: u32 = 0;
    while (cur == .object and depth < 256) : (depth += 1) {
        if (cur.object == this.object) return .{ .boolean = true };
        cur = vm.protoValue(cur.object);
    }
    return .{ .boolean = false };
}

// --- Function ----------------------------------------------------------------

fn fnCall(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const call_this = arg(args, 0);
    const rest = if (args.len > 1) args[1..] else args[0..0];
    return vm.callFunction(this, call_this, rest);
}

fn fnApply(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const call_this = arg(args, 0);
    var call_args: []Value = &.{};
    const a1 = arg(args, 1);
    if (a1 == .object) {
        const n = vm.arrayLength(a1.object);
        call_args = try vm.arena().alloc(Value, n);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            call_args[i] = try indexGet(vm, a1.object, i);
        }
    }
    return vm.callFunction(this, call_this, call_args);
}

/// Array element read — OWN properties only. Flash's array methods do not
/// inherit indices through the prototype chain (corpus:
/// array_prototyping traces `undefined,undefined,undefined` for an object
/// whose __proto__ is a populated array).
fn indexGet(vm: *Vm, h: ObjectHandle, index: u32) !Value {
    var buf: [12]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;
    var wide: [12]u16 = undefined;
    for (key, 0..) |c, i| wide[i] = c;
    return vm.objects.getOwn(h, wide[0..key.len], vm.case_sensitive) orelse .undefined_value;
}

// --- Array -------------------------------------------------------------------

fn ctorArray(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = this;
    const arr = try vm.newArray();
    if (args.len == 1 and args[0] == .number) {
        const n = args[0].number;
        if (n >= 0 and n == @trunc(n)) {
            try vm.setArrayLength(arr, @intFromFloat(n));
            return .{ .object = arr };
        }
    }
    for (args, 0..) |v, i| try vm.arraySet(arr, @intCast(i), v);
    return .{ .object = arr };
}

fn arrPush(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    var len = vm.arrayLength(this.object);
    for (args) |v| {
        try vm.arraySet(this.object, len, v);
        len += 1;
    }
    return .{ .number = @floatFromInt(len) };
}

fn arrPop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len = vm.arrayLength(this.object);
    if (len == 0) return .undefined_value;
    const v = try indexGet(vm, this.object, len - 1);
    var buf: [12]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{len - 1}) catch unreachable;
    var wide: [12]u16 = undefined;
    for (key, 0..) |c, i| wide[i] = c;
    _ = vm.objects.deleteOwn(this.object, wide[0..key.len], vm.case_sensitive);
    try vm.setArrayLength(this.object, len - 1);
    return v;
}

fn arrShift(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len = vm.arrayLength(this.object);
    if (len == 0) return .undefined_value;
    const first = try indexGet(vm, this.object, 0);
    var i: u32 = 1;
    while (i < len) : (i += 1) {
        try vm.arraySet(this.object, i - 1, try indexGet(vm, this.object, i));
    }
    var buf: [12]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{len - 1}) catch unreachable;
    var wide: [12]u16 = undefined;
    for (key, 0..) |c, k| wide[k] = c;
    _ = vm.objects.deleteOwn(this.object, wide[0..key.len], vm.case_sensitive);
    try vm.setArrayLength(this.object, len - 1);
    return first;
}

fn joinImpl(vm: *Vm, h: ObjectHandle, sep: strings.AvmString) anyerror!Value {
    const len = vm.arrayLength(h);
    var out: std.ArrayList(u16) = .empty;
    const a = vm.arena();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try out.appendSlice(a, sep);
        // Every element goes through the ordinary string coercion, with no
        // special case: `null` always spells itself out, and only
        // `undefined` is version-dependent (empty below SWF7). Suppressing
        // null too made `[a, b, null].join()` lose a field.
        try out.appendSlice(a, try vm.toStringValue(try indexGet(vm, h, i)));
    }
    return .{ .string = try out.toOwnedSlice(a) };
}

fn arrJoin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const sep: strings.AvmString = if (args.len > 0 and args[0] != .undefined_value)
        try vm.toStringValue(args[0])
    else
        S(",");
    return joinImpl(vm, this.object, sep);
}

fn arrToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return joinImpl(vm, this.object, S(","));
}

fn arrUnshift(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len = vm.arrayLength(this.object);
    const n: u32 = @intCast(args.len);
    if (n > 0) {
        // Shift right, back to front.
        var i: u32 = len;
        while (i > 0) : (i -= 1) {
            try vm.arraySet(this.object, i - 1 + n, try indexGet(vm, this.object, i - 1));
        }
        for (args, 0..) |v, k| try vm.arraySet(this.object, @intCast(k), v);
    }
    try vm.setArrayLength(this.object, len + n);
    return .{ .number = @floatFromInt(len + n) };
}

fn arrReverse(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len = vm.arrayLength(this.object);
    if (len < 2) return this;
    var i: u32 = 0;
    while (i < len / 2) : (i += 1) {
        const a = try indexGet(vm, this.object, i);
        const b = try indexGet(vm, this.object, len - 1 - i);
        try vm.arraySet(this.object, i, b);
        try vm.arraySet(this.object, len - 1 - i, a);
    }
    return this;
}

fn arrSplice(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .undefined_value;
    const len: i64 = @intCast(vm.arrayLength(this.object));
    var start: i64 = @intFromFloat(@trunc(try vm.toNumber(args[0])));
    if (start < 0) start = @max(0, len + start);
    start = @min(start, len);
    var delete_count: i64 = if (args.len > 1)
        @intFromFloat(@trunc(try vm.toNumber(args[1])))
    else
        len - start;
    delete_count = @max(0, @min(delete_count, len - start));
    // Removed elements come back as a new array.
    const removed = try vm.newArray();
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        try vm.arraySet(removed, @intCast(i), try indexGet(vm, this.object, @intCast(start + i)));
    }
    const inserted: i64 = @intCast(if (args.len > 2) args.len - 2 else 0);
    const new_len = len - delete_count + inserted;
    // Copy the tail into place (grow: back-to-front; shrink: front-to-back).
    if (inserted > delete_count) {
        var k: i64 = len - 1;
        while (k >= start + delete_count) : (k -= 1) {
            try vm.arraySet(this.object, @intCast(k + inserted - delete_count), try indexGet(vm, this.object, @intCast(k)));
        }
    } else if (inserted < delete_count) {
        var k: i64 = start + delete_count;
        while (k < len) : (k += 1) {
            try vm.arraySet(this.object, @intCast(k + inserted - delete_count), try indexGet(vm, this.object, @intCast(k)));
        }
    }
    var j: i64 = 0;
    while (j < inserted) : (j += 1) {
        try vm.arraySet(this.object, @intCast(start + j), args[@intCast(2 + j)]);
    }
    try vm.setArrayLength(this.object, @intCast(@max(0, new_len)));
    return .{ .object = removed };
}

fn arrSort(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len = vm.arrayLength(this.object);
    if (len < 2) return this;
    // Gather, insertion-sort (stable, small arrays), write back. Custom
    // comparator supported; default is string comparison (ES3).
    const items = try vm.arena().alloc(Value, len);
    var i: u32 = 0;
    while (i < len) : (i += 1) items[i] = try indexGet(vm, this.object, i);
    const cmp_fn = arg(args, 0);
    const has_cmp = vm.isCallable(cmp_fn);
    var a: usize = 1;
    while (a < items.len) : (a += 1) {
        const key = items[a];
        var b: usize = a;
        while (b > 0) : (b -= 1) {
            const ord = if (has_cmp) blk: {
                const r = try vm.callFunction(cmp_fn, .undefined_value, &.{ items[b - 1], key });
                break :blk try vm.toNumber(r);
            } else blk: {
                const sa = try vm.toStringValue(items[b - 1]);
                const sk = try vm.toStringValue(key);
                break :blk switch (strings.order(sa, sk)) {
                    .lt => @as(f64, -1),
                    .eq => 0,
                    .gt => 1,
                };
            };
            if (ord <= 0) break;
            items[b] = items[b - 1];
        }
        items[b] = key;
    }
    for (items, 0..) |v, k| try vm.arraySet(this.object, @intCast(k), v);
    return this;
}

fn arrConcat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const out = try vm.newArray();
    var n: u32 = 0;
    if (this == .object) {
        const len = vm.arrayLength(this.object);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            try vm.arraySet(out, n, try indexGet(vm, this.object, i));
            n += 1;
        }
    }
    for (args) |v| {
        if (v == .object and vm.objects.get(v.object).native == .array) {
            const len = vm.arrayLength(v.object);
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                try vm.arraySet(out, n, try indexGet(vm, v.object, i));
                n += 1;
            }
        } else {
            try vm.arraySet(out, n, v);
            n += 1;
        }
    }
    return .{ .object = out };
}

fn arrSlice(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const len: i64 = @intCast(vm.arrayLength(this.object));
    var start: i64 = if (args.len > 0) @intFromFloat(try vm.toNumber(args[0])) else 0;
    var end: i64 = if (args.len > 1 and args[1] != .undefined_value) @intFromFloat(try vm.toNumber(args[1])) else len;
    if (start < 0) start = @max(0, len + start);
    if (end < 0) end = @max(0, len + end);
    start = @min(start, len);
    end = @min(end, len);
    const out = try vm.newArray();
    var n: u32 = 0;
    var i = start;
    while (i < end) : (i += 1) {
        try vm.arraySet(out, n, try indexGet(vm, this.object, @intCast(i)));
        n += 1;
    }
    return .{ .object = out };
}

// --- String ------------------------------------------------------------------

fn thisString(vm: *Vm, this: Value) anyerror!strings.AvmString {
    return vm.toStringValue(this);
}

fn ctorString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s: strings.AvmString = if (args.len > 0) try vm.toStringValue(args[0]) else S("");
    if (vm.in_construct > 0 and this == .object) {
        vm.objects.get(this.object).native = .{ .boxed_string = s };
        return this;
    }
    return .{ .string = s };
}

fn strToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this == .object) {
        switch (vm.objects.get(this.object).native) {
            .boxed_string => |s| return .{ .string = s },
            else => {},
        }
    }
    return .{ .string = try vm.toStringValue(this) };
}

fn strCharAt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const i = try vm.toNumber(arg(args, 0));
    if (std.math.isNan(i) or i < 0 or i >= @as(f64, @floatFromInt(s.len))) {
        return .{ .string = S("") };
    }
    const idx: usize = @intFromFloat(i);
    return .{ .string = s[idx .. idx + 1] };
}

fn strCharCodeAt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const i = try vm.toNumber(arg(args, 0));
    if (std.math.isNan(i) or i < 0 or i >= @as(f64, @floatFromInt(s.len))) {
        return .{ .number = std.math.nan(f64) };
    }
    return .{ .number = @floatFromInt(s[@intFromFloat(i)]) };
}

fn strFromCharCode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    var out = try vm.arena().alloc(u16, args.len);
    var n: usize = 0;
    for (args) |a| {
        const code = value_mod.toUint16(try vm.toNumber(a));
        if (code == 0) break; // Flash stops at NUL
        out[n] = code;
        n += 1;
    }
    return .{ .string = out[0..n] };
}

fn strToUpper(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const out = try vm.arena().alloc(u16, s.len);
    for (s, 0..) |c, i| out[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    return .{ .string = out };
}

fn strToLower(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const out = try vm.arena().alloc(u16, s.len);
    for (s, 0..) |c, i| out[i] = strings.foldCase(c);
    return .{ .string = out };
}

fn strIndexOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const needle = try vm.toStringValue(arg(args, 0));
    var from: usize = 0;
    if (args.len > 1) {
        const f = try vm.toNumber(args[1]);
        if (f > 0) from = @min(@as(usize, @intFromFloat(f)), s.len);
    }
    if (needle.len == 0) return .{ .number = @floatFromInt(from) };
    if (std.mem.indexOfPos(u16, s, from, needle)) |i| {
        return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

fn strLastIndexOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const needle = try vm.toStringValue(arg(args, 0));
    if (std.mem.lastIndexOf(u16, s, needle)) |i| {
        return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

fn strSubstring(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    var a: i64 = clampIndex(try vm.toNumber(arg(args, 0)), s.len);
    var b: i64 = if (args.len > 1 and args[1] != .undefined_value)
        clampIndex(try vm.toNumber(args[1]), s.len)
    else
        @intCast(s.len);
    if (a > b) std.mem.swap(i64, &a, &b);
    return .{ .string = s[@intCast(a)..@intCast(b)] };
}

fn strSlice(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const len: i64 = @intCast(s.len);
    var a: i64 = if (args.len > 0) @intFromFloat(@trunc(try vm.toNumber(args[0]))) else 0;
    var b: i64 = if (args.len > 1 and args[1] != .undefined_value) @intFromFloat(@trunc(try vm.toNumber(args[1]))) else len;
    if (a < 0) a = @max(0, len + a);
    if (b < 0) b = @max(0, len + b);
    a = @min(a, len);
    b = @min(b, len);
    if (a >= b) return .{ .string = S("") };
    return .{ .string = s[@intCast(a)..@intCast(b)] };
}

fn strSubstr(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const len: i64 = @intCast(s.len);
    var start: i64 = if (args.len > 0) @intFromFloat(@trunc(try vm.toNumber(args[0]))) else 0;
    if (start < 0) start = @max(0, len + start);
    start = @min(start, len);
    var count: i64 = if (args.len > 1 and args[1] != .undefined_value)
        @intFromFloat(@trunc(try vm.toNumber(args[1])))
    else
        len - start;
    count = @max(0, @min(count, len - start));
    return .{ .string = s[@intCast(start)..@intCast(start + count)] };
}

fn clampIndex(n: f64, len: usize) i64 {
    if (std.math.isNan(n) or n < 0) return 0;
    return @intFromFloat(@min(n, @as(f64, @floatFromInt(len))));
}

fn strSplit(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const arr = try vm.newArray();
    if (args.len == 0 or args[0] == .undefined_value) {
        try vm.arraySet(arr, 0, .{ .string = s });
        return .{ .object = arr };
    }
    const sep = try vm.toStringValue(args[0]);
    var n: u32 = 0;
    if (sep.len == 0) {
        for (s) |c| {
            const one = try vm.arena().alloc(u16, 1);
            one[0] = c;
            try vm.arraySet(arr, n, .{ .string = one });
            n += 1;
        }
        return .{ .object = arr };
    }
    var it = std.mem.splitSequence(u16, s, sep);
    while (it.next()) |part| {
        try vm.arraySet(arr, n, .{ .string = part });
        n += 1;
    }
    return .{ .object = arr };
}

// --- Number / Boolean --------------------------------------------------------

fn ctorNumber(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const n: f64 = if (args.len > 0) try vm.toNumber(args[0]) else 0;
    if (vm.in_construct > 0 and this == .object) {
        vm.objects.get(this.object).native = .{ .boxed_number = n };
        return this;
    }
    return .{ .number = n };
}

fn numToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    var n: f64 = 0;
    if (this == .object) {
        switch (vm.objects.get(this.object).native) {
            .boxed_number => |x| n = x,
            else => {},
        }
    } else if (this == .number) {
        n = this.number;
    }
    const radix: f64 = if (args.len > 0) try vm.toNumber(args[0]) else 10;
    if (radix != 10 and radix >= 2 and radix <= 36) {
        const i: i64 = @intFromFloat(@trunc(n));
        var buf: [72]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        _ = s;
        // Radix formatting for integers.
        var tmp: [72]u8 = undefined;
        var idx: usize = tmp.len;
        var v: u64 = @abs(i);
        const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        if (v == 0) {
            idx -= 1;
            tmp[idx] = '0';
        }
        while (v > 0) {
            idx -= 1;
            tmp[idx] = digits[@intCast(v % @as(u64, @intFromFloat(radix)))];
            v /= @intFromFloat(radix);
        }
        if (i < 0) {
            idx -= 1;
            tmp[idx] = '-';
        }
        const out = try vm.arena().alloc(u16, tmp.len - idx);
        for (tmp[idx..], 0..) |c, k| out[k] = c;
        return .{ .string = out };
    }
    return .{ .string = try vm.toStringValue(.{ .number = n }) };
}

fn numValueOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this == .object) {
        switch (vm.objects.get(this.object).native) {
            .boxed_number => |x| return .{ .number = x },
            else => {},
        }
    }
    return this;
}

fn ctorBoolean(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const b = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    if (vm.in_construct > 0 and this == .object) {
        vm.objects.get(this.object).native = .{ .boxed_bool = b };
        return this;
    }
    return .{ .boolean = b };
}

fn boolToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this == .object) {
        switch (vm.objects.get(this.object).native) {
            .boxed_bool => |b| return .{ .string = if (b) S("true") else S("false") },
            else => {},
        }
    }
    return .{ .string = try vm.toStringValue(this) };
}

fn boolValueOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this == .object) {
        switch (vm.objects.get(this.object).native) {
            .boxed_bool => |b| return .{ .boolean = b },
            else => {},
        }
    }
    return this;
}

// --- Math --------------------------------------------------------------------

fn math1(p: *anyopaque, args: []const Value, comptime f: fn (f64) f64) anyerror!Value {
    const vm = vmOf(p);
    return .{ .number = f(try vm.toNumber(arg(args, 0))) };
}

fn mathAbs(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @abs(x);
        }
    }.f);
}
fn mathFloor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @floor(x);
        }
    }.f);
}
fn mathCeil(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @ceil(x);
        }
    }.f);
}
fn mathRound(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            if (std.math.isNan(x)) return x;
            return @floor(x + 0.5); // ES3: round-half-up (round(-0.5) = 0)
        }
    }.f);
}
fn mathSqrt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @sqrt(x);
        }
    }.f);
}
fn mathSin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return std.math.sin(x);
        }
    }.f);
}
fn mathCos(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return std.math.cos(x);
        }
    }.f);
}
fn mathTan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @tan(x);
        }
    }.f);
}
fn mathAtan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return std.math.atan(x);
        }
    }.f);
}
fn mathAsin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return std.math.asin(x);
        }
    }.f);
}
fn mathAcos(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return std.math.acos(x);
        }
    }.f);
}
fn mathExp(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @exp(x);
        }
    }.f);
}
fn mathLog(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, struct {
        fn f(x: f64) f64 {
            return @log(x);
        }
    }.f);
}

fn mathPow(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const a = try vm.toNumber(arg(args, 0));
    const b = try vm.toNumber(arg(args, 1));
    return .{ .number = std.math.pow(f64, a, b) };
}

fn mathAtan2(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const y = try vm.toNumber(arg(args, 0));
    const x = try vm.toNumber(arg(args, 1));
    return .{ .number = std.math.atan2(y, x) };
}

fn mathMin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len == 0) return .{ .number = std.math.inf(f64) };
    var best = try vm.toNumber(args[0]);
    for (args[1..]) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n) or std.math.isNan(best)) return .{ .number = std.math.nan(f64) };
        if (n < best) best = n;
    }
    return .{ .number = best };
}

fn mathMax(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len == 0) return .{ .number = -std.math.inf(f64) };
    var best = try vm.toNumber(args[0]);
    for (args[1..]) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n) or std.math.isNan(best)) return .{ .number = std.math.nan(f64) };
        if (n > best) best = n;
    }
    return .{ .number = best };
}

fn mathRandom(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .number = vm.rng.random().float(f64) };
}

// --- global functions --------------------------------------------------------

fn globalIsNan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    return .{ .boolean = std.math.isNan(try vm.toNumber(arg(args, 0))) };
}

fn globalIsFinite(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const n = try vm.toNumber(arg(args, 0));
    return .{ .boolean = !(std.math.isNan(n) or std.math.isInf(n)) };
}

fn globalParseFloat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    // parseFloat: longest valid prefix.
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    while (i < s.len and n < buf.len) : (i += 1) {
        const c = s[i];
        if (c > 0x7F) break;
        const ch: u8 = @intCast(c);
        if ((ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E') {
            buf[n] = ch;
            n += 1;
        } else break;
    }
    while (n > 0) {
        if (std.fmt.parseFloat(f64, buf[0..n])) |v| {
            return .{ .number = v };
        } else |_| n -= 1;
    }
    return .{ .number = std.math.nan(f64) };
}

fn globalParseInt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    var radix: u8 = 0;
    if (args.len > 1) {
        const r = try vm.toNumber(args[1]);
        if (r >= 2 and r <= 36) radix = @intFromFloat(r);
    }
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (radix == 0) {
        if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
            radix = 16;
            i += 2;
        } else radix = 10;
    } else if (radix == 16 and i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        i += 2;
    }
    var acc: f64 = 0;
    var any = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const d: u8 = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'z' => @intCast(c - 'a' + 10),
            'A'...'Z' => @intCast(c - 'A' + 10),
            else => break,
        };
        if (d >= radix) break;
        acc = acc * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
        any = true;
    }
    if (!any) return .{ .number = std.math.nan(f64) };
    return .{ .number = if (neg) -acc else acc };
}

fn globalGetTimer(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .number = @trunc(vm.now_ms) };
}

fn eqName(a: strings.AvmString, b: strings.AvmString, cs: bool) bool {
    return if (cs) strings.eql(a, b) else strings.eqlIgnoreCase(a, b);
}

/// ASSetPropFlags(obj, props, setFlags, clearFlags) — undocumented but
/// ubiquitous. props: null = ALL properties, else a comma-separated name
/// list (or a single name). Flag bits (ruffle property.rs Attribute):
/// 1 = DontEnum, 2 = DontDelete, 4 = ReadOnly.
fn globalAsSetPropFlags(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const target = arg(args, 0);
    if (target != .object) return .undefined_value;
    const h = target.object;
    const set_bits: u16 = @intFromFloat(@max(0, @min(65535, try vm.toNumber(arg(args, 2)))));
    const clear_bits: u16 = @intFromFloat(@max(0, @min(65535, try vm.toNumber(arg(args, 3)))));

    const applyAttrs = struct {
        fn f(a0: object_mod.Attributes, set: u16, clear: u16) object_mod.Attributes {
            var a = a0;
            if (set & 1 != 0) a.dont_enum = true;
            if (set & 2 != 0) a.dont_delete = true;
            if (set & 4 != 0) a.read_only = true;
            if (clear & 1 != 0) a.dont_enum = false;
            if (clear & 2 != 0) a.dont_delete = false;
            if (clear & 4 != 0) a.read_only = false;
            // Bits 3..15 are version gates — keep them verbatim.
            a.version_bits = (a.version_bits & ~clear) | (set & 0xFFF8);
            return a;
        }
    }.f;
    const apply = struct {
        fn f(o: *object_mod.ScriptObject, idx: usize, set: u16, clear: u16) void {
            o.props.items[idx].attrs = applyAttrs(o.props.items[idx].attrs, set, clear);
        }
    }.f;

    const props = arg(args, 1);
    const o = vm.objects.get(h);
    if (props == .null_value or props == .undefined_value) {
        var i: usize = 0;
        while (i < o.props.items.len) : (i += 1) apply(o, i, set_bits, clear_bits);
        if (o.proto != .undefined_value) o.proto_attrs = applyAttrs(o.proto_attrs, set_bits, clear_bits);
        return .undefined_value;
    }
    const list = try vm.toStringValue(props);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= list.len) : (i += 1) {
        if (i == list.len or list[i] == ',') {
            var name = list[start..i];
            // Trim ASCII spaces.
            while (name.len > 0 and name[0] == ' ') name = name[1..];
            while (name.len > 0 and name[name.len - 1] == ' ') name = name[0 .. name.len - 1];
            if (name.len > 0) {
                if (o.find(name, vm.case_sensitive)) |idx| {
                    apply(o, idx, set_bits, clear_bits);
                } else if (o.proto != .undefined_value and eqName(name, S("__proto__"), vm.case_sensitive)) {
                    o.proto_attrs = applyAttrs(o.proto_attrs, set_bits, clear_bits);
                }
            }
            start = i + 1;
        }
    }
    return .undefined_value;
}

/// ASnative(set, index) — returns a stub native function. Real dispatch
/// tables are out of scope; returning a callable keeps `typeof` and call
/// sites sane.
fn globalAsNative(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .object = try vm.newNativeFn(asNativeStub) };
}

fn asNativeStub(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

fn ctorError(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this == .object and args.len > 0 and args[0] != .undefined_value) {
        const msg = try vm.toStringValue(args[0]);
        try vm.objects.put(this.object, S("message"), .{ .string = msg }, vm.case_sensitive);
    }
    return this;
}

fn errorToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .{ .string = S("Error") };
    const msg = vm.objects.getChained(this.object, S("message"), vm.case_sensitive) orelse
        Value{ .string = S("Error") };
    return .{ .string = try vm.toStringValue(msg) };
}

/// escape() — RFC-1738-ish percent encoding (ruffle globals.rs escape:
/// alphanumerics and *_+-./ pass through, everything else %XX by UTF-8).
fn globalEscape(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    var out: std.ArrayList(u16) = .empty;
    const a = vm.arena();
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const keep = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or c == '*' or c == '_' or c == '+' or
            c == '-' or c == '.' or c == '/';
        if (keep) {
            try out.append(a, c);
        } else if (c < 0x80) {
            try out.append(a, '%');
            try out.append(a, hex[(c >> 4) & 0xF]);
            try out.append(a, hex[c & 0xF]);
        } else {
            // UTF-8 encode the code unit, percent-escaping each byte.
            var buf: [3]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch 0;
            for (buf[0..n]) |b| {
                try out.append(a, '%');
                try out.append(a, hex[(b >> 4) & 0xF]);
                try out.append(a, hex[b & 0xF]);
            }
        }
    }
    return .{ .string = try out.toOwnedSlice(a) };
}

fn globalUnescape(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    var bytes: std.ArrayList(u8) = .empty;
    const a = vm.arena();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(@intCast(@min(s[i + 1], 127)), 16) catch {
                try bytes.append(a, @intCast(@min(s[i], 255)));
                continue;
            };
            const lo = std.fmt.charToDigit(@intCast(@min(s[i + 2], 127)), 16) catch {
                try bytes.append(a, @intCast(@min(s[i], 255)));
                continue;
            };
            try bytes.append(a, hi * 16 + lo);
            i += 2;
        } else if (s[i] < 0x80) {
            try bytes.append(a, @intCast(s[i]));
        } else {
            var buf: [3]u8 = undefined;
            const n = std.unicode.utf8Encode(s[i], &buf) catch 0;
            try bytes.appendSlice(a, buf[0..n]);
        }
    }
    const decoded = std.unicode.utf8ToUtf16LeAlloc(a, bytes.items) catch blk: {
        const w = try a.alloc(u16, bytes.items.len);
        for (bytes.items, 0..) |b, k| w[k] = b;
        break :blk w;
    };
    return .{ .string = decoded };
}

/// Object.addProperty(name, getter, setter) — installs an accessor
/// property (ruffle globals/object.rs add_property). Returns a bool.
fn objAddProperty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const name = try vm.toStringValue(arg(args, 0));
    if (name.len == 0) return .{ .boolean = false };
    const getter = arg(args, 1);
    const setter = arg(args, 2);
    if (!vm.isCallable(getter)) return .{ .boolean = false };
    // setter may be null (getter-only) but must otherwise be callable.
    const setter_h: runtime.ObjectHandle = if (vm.isCallable(setter)) setter.object else 0;
    if (setter != .null_value and setter != .undefined_value and setter_h == 0) {
        return .{ .boolean = false };
    }
    const o = vm.objects.get(this.object);
    if (o.find(name, vm.case_sensitive)) |idx| {
        // The STORED value survives: ruffle's `Property::set_virtual` only
        // installs the accessors. `watch` then reports that stored value as
        // the old one, without ever calling the getter — corpus
        // watch_virtual_property_proto expects `old_val: 3`.
        o.props.items[idx].getter = getter.object;
        o.props.items[idx].setter = setter_h;
    } else {
        const key = try vm.arena().dupe(u16, name);
        try o.props.append(vm.arena(), .{
            .key = key,
            .value = .undefined_value,
            .attrs = .{ .dont_enum = true },
            .getter = getter.object,
            .setter = setter_h,
        });
    }
    return .{ .boolean = true };
}
