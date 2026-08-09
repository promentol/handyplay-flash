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
const case_tables = @import("../case_tables.zig");
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
    try method(vm, vm.array_proto, "sortOn", arrSortOn, hidden);

    // --- String.prototype -------------------------------------------------
    try method(vm, vm.string_proto, "toString", strToString, hidden);
    try method(vm, vm.string_proto, "valueOf", strToString, hidden);
    try method(vm, vm.string_proto, "charAt", strCharAt, hidden);
    try method(vm, vm.string_proto, "charCodeAt", strCharCodeAt, hidden);
    try method(vm, vm.string_proto, "toUpperCase", strToUpper, hidden);
    try method(vm, vm.string_proto, "concat", strConcat, hidden);
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
    const array_class = try decl.class(vm, "Array", ctorArray, vm.array_proto, attrs);
    // The sort option bits live on the class, and content passes them by
    // name rather than by number.
    inline for (.{
        .{ "CASEINSENSITIVE", SORT_CASE_INSENSITIVE },
        .{ "DESCENDING", SORT_DESCENDING },
        .{ "UNIQUESORT", SORT_UNIQUE },
        .{ "RETURNINDEXEDARRAY", SORT_RETURN_INDEXED },
        .{ "NUMERIC", SORT_NUMERIC },
    }) |c| {
        try vm.objects.putWithAttrs(array_class, S(c[0]), .{ .number = @floatFromInt(c[1]) }, frozen, false);
    }
    try @import("xml.zig").install(vm, attrs);
    try @import("loader.zig").install(vm);
    try @import("socket.zig").install(vm);
    try @import("sound.zig").install(vm);
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
    // Every Math method is READ_ONLY in ruffle math.rs, and every one is
    // the SAME function under a different ASnative index. Declaration
    // order is ruffle's; for-in reports it backwards.
    inline for (.{
        .{ "abs", math_index.ABS },     .{ "min", math_index.MIN },
        .{ "max", math_index.MAX },     .{ "sin", math_index.SIN },
        .{ "cos", math_index.COS },     .{ "atan2", math_index.ATAN2 },
        .{ "tan", math_index.TAN },     .{ "exp", math_index.EXP },
        .{ "log", math_index.LOG },     .{ "sqrt", math_index.SQRT },
        .{ "round", math_index.ROUND }, .{ "random", math_index.RANDOM },
        .{ "floor", math_index.FLOOR }, .{ "ceil", math_index.CEIL },
        .{ "atan", math_index.ATAN },   .{ "asin", math_index.ASIN },
        .{ "acos", math_index.ACOS },   .{ "pow", math_index.POW },
    }) |e| {
        try decl.tableMethod(vm, math, e[0], mathMethod, e[1], frozen);
    }

    // --- global functions + constants -------------------------------------
    try method(vm, vm.globals, "isNaN", globalIsNan, attrs);
    try method(vm, vm.globals, "isFinite", globalIsFinite, attrs);
    try method(vm, vm.globals, "parseInt", globalParseInt, attrs);
    try method(vm, vm.globals, "parseFloat", globalParseFloat, attrs);
    try method(vm, vm.globals, "getTimer", globalGetTimer, attrs);
    try method(vm, vm.globals, "ASSetPropFlags", globalAsSetPropFlags, attrs);
    try method(vm, vm.globals, "ASnative", globalAsNative, attrs);
    try decl.tableMethod(vm, vm.globals, "ASSetNative", asSetNativeMethod, 0, attrs);
    try decl.tableMethod(vm, vm.globals, "ASSetNativeAccessor", asSetNativeMethod, 1, attrs);
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
        // The SWF8 block. Unlike MovieClip's, Button's members carry NO
        // attribute flags at all — they enumerate and delete like ordinary
        // properties (ruffle globals/button.rs PROTO_DECLS). `tabEnabled`
        // is deliberately absent: it is not a built-in Button property.
        const mc_globals = @import("movie_clip.zig");
        try decl.property(vm, btn_proto, "blendMode", mc_globals.getBlendMode, mc_globals.setBlendMode, ver(.{ .read_only = true }, decl.V8));
        try decl.property(vm, btn_proto, "filters", mc_globals.getFilters, mc_globals.setFilters, ver(.{ .read_only = true }, decl.V8));
        try decl.value(vm, btn_proto, "cacheAsBitmap", .{ .boolean = false }, ver(.{ .read_only = true }, decl.V8));
        try decl.value(vm, btn_proto, "scale9Grid", .undefined_value, ver(.{ .read_only = true }, decl.V8));
        try decl.property(vm, btn_proto, "tabIndex", mc_globals.getTabIndex, mc_globals.setTabIndex, ver(.{}, decl.V6));
        _ = try decl.class(vm, "Button", ctorMovieClip, btn_proto, attrs);

        try @import("text_field.zig").install(vm);
    }

    try @import("geom.zig").install(vm);
    try @import("date.zig").install(vm);
    try @import("singletons.zig").install(vm);
    try @import("stubs.zig").install(vm);
    try @import("selection.zig").install(vm);
    try @import("text_format.zig").install(vm);
    try @import("text_snapshot.zig").install(vm);

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
    // Both are ACCESSORS because SWF4 has neither: `NaN` and `Infinity`
    // read as undefined there, which is why `x == NaN` is true for a
    // SWF4 zero — both sides coerce to 0 (corpus equals_swf4).
    try decl.property(vm, vm.globals, "Infinity", globalInfinity, null, attrs);
    try decl.property(vm, vm.globals, "NaN", globalNan, null, attrs);
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

/// `new Object(v)` BOXES a primitive rather than ignoring it: the result
/// is a Number, String or Boolean object, and it traces as the value it
/// wraps. Only undefined and null give a plain object.
fn ctorObject(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const a0 = arg(args, 0);
    switch (a0) {
        .object => return a0,
        .undefined_value, .null_value => {},
        else => return boxPrimitive(vm, a0),
    }
    if (vm.in_construct > 0 and this == .object) return this;
    // Called as a FUNCTION rather than with `new`, `Object()` gives a
    // BARE object — no prototype, so it has no `toString` and traces as
    // the type tag rather than "[object Object]".
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .undefined_value;
    return .{ .object = h };
}

/// A primitive in its wrapper object, with the matching prototype so the
/// class's own methods are reachable.
pub fn boxPrimitive(vm: *Vm, v: Value) !Value {
    const h = try vm.objects.create();
    switch (v) {
        .number => |n| {
            vm.objects.get(h).proto = .{ .object = vm.number_proto };
            vm.objects.get(h).native = .{ .boxed_number = n };
        },
        .string => |str| {
            vm.objects.get(h).proto = .{ .object = vm.string_proto };
            vm.objects.get(h).native = .{ .boxed_string = str };
            try vm.objects.putWithAttrs(h, S("length"), .{ .number = @floatFromInt(str.len) }, .{ .dont_enum = true, .dont_delete = true }, vm.case_sensitive);
        },
        .boolean => |b| {
            vm.objects.get(h).proto = .{ .object = vm.boolean_proto };
            vm.objects.get(h).native = .{ .boxed_bool = b };
        },
        else => vm.objects.get(h).proto = .{ .object = vm.object_proto },
    }
    return .{ .object = h };
}

fn ctorFunction(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn objHasOwnProperty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    // NO argument is false; an explicit `undefined` is the string
    // "undefined" and may well be a real key.
    if (args.len == 0) return .{ .boolean = false };
    const name = try vm.toStringValue(args[0]);
    // `__proto__` is a real entry in ruffle's property map rather than a
    // synthesized accessor, so an object that HAS a prototype owns the
    // property too (corpus has_own_property).
    const is_proto = if (vm.case_sensitive)
        strings.eql(name, S("__proto__"))
    else
        strings.eqlIgnoreCase(name, S("__proto__"));
    if (is_proto and vm.objects.get(this.object).proto == .object) return .{ .boolean = true };
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

/// An UNDEFINED or NULL `this` argument is replaced by the global
/// object; a primitive is boxed (corpus funky_function_calls).
fn callThis(vm: *Vm, args: []const Value) !Value {
    const v = arg(args, 0);
    return switch (v) {
        .object => v,
        // A primitive is BOXED and passed through; only undefined and
        // null fall back to the global object.
        .number, .string, .boolean => try boxPrimitive(vm, v),
        else => .{ .object = vm.globals },
    };
}

fn fnCall(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const rest = if (args.len > 1) args[1..] else args[0..0];
    return vm.callFunction(this, try callThis(vm, args), rest);
}

fn fnApply(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const call_this = try callThis(vm, args);
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
    // A single NUMBER is a length, whatever it is — including a negative
    // or fractional one, which is stored as given and read back as given.
    // Only a genuine Number counts: `new Array("3")` is a one-element
    // array holding the string.
    if (args.len == 1 and args[0] == .number) {
        try vm.setArrayLengthRaw(arr, @floatFromInt(value_mod.toInt32(args[0].number)));
        return .{ .object = arr };
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

/// Delete the element and then set it, so the property lands at the END
/// of the object's property list. Array reordering is OBSERVABLE through
/// `for..in`, which walks that list, and every Flash array mutator moves
/// elements this way rather than overwriting in place.
fn arrayReset(vm: *Vm, h: ObjectHandle, index: u32, v: Value) !void {
    _ = vm.objects.deleteOwn(h, try arrayKey(vm, index), vm.case_sensitive);
    try vm.arraySet(h, index, v);
}

fn arrayDelete(vm: *Vm, h: ObjectHandle, index: u32) !void {
    _ = vm.objects.deleteOwn(h, try arrayKey(vm, index), vm.case_sensitive);
}

fn arrayKey(vm: *Vm, index: u32) !strings.AvmString {
    var buf: [12]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;
    const wide = try vm.arena().alloc(u16, ascii.len);
    for (ascii, wide) |c, *w| w.* = c;
    return wide;
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
        const v = try indexGet(vm, this.object, i);
        try arrayReset(vm, this.object, i - 1, v);
    }
    try arrayDelete(vm, this.object, len - 1);
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
        // Shift right, back to front, each element deleted and re-set.
        var i: u32 = len;
        while (i > 0) : (i -= 1) {
            const v = try indexGet(vm, this.object, i - 1);
            try arrayReset(vm, this.object, i - 1 + n, v);
        }
        for (args, 0..) |v, k| try arrayReset(vm, this.object, @intCast(k), v);
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
        const upper = len - 1 - i;
        const a = try indexGet(vm, this.object, i);
        const b = try indexGet(vm, this.object, upper);
        // BOTH deleted before either is set, so the pair moves to the
        // end of the property list together.
        try arrayDelete(vm, this.object, i);
        try arrayDelete(vm, this.object, upper);
        try vm.arraySet(this.object, i, b);
        try vm.arraySet(this.object, upper, a);
    }
    return this;
}

/// `splice(start, deleteCount, …items)`.
///
/// Three ways to get UNDEFINED rather than an array back, all of them
/// checked before anything is moved: no `start` at all, an explicit
/// `undefined` for either of the first two arguments, or a negative
/// delete count. A missing `deleteCount` means "to the end", which is
/// not the same as passing undefined.
fn arrSplice(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (args.len == 0 or args[0] == .undefined_value) return .undefined_value;

    const len: i64 = @intCast(vm.arrayLength(this.object));
    var start: i64 = value_mod.toInt32(try vm.toNumber(args[0]));
    if (start < 0) start = @max(0, len + start);
    start = @min(start, len);

    var delete_count: i64 = undefined;
    if (args.len > 1) {
        if (args[1] == .undefined_value) return .undefined_value;
        delete_count = @min(@as(i64, value_mod.toInt32(try vm.toNumber(args[1]))), len - start);
    } else {
        delete_count = len - start;
    }
    if (delete_count < 0) return .undefined_value;

    const removed = try vm.newArray();
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        try vm.arraySet(removed, @intCast(i), try indexGet(vm, this.object, @intCast(start + i)));
    }
    try vm.setArrayLength(removed, @intCast(delete_count));

    const inserted: i64 = @intCast(if (args.len > 2) args.len - 2 else 0);
    // Growing walks BACKWARDS and shrinking forwards, so a move never
    // lands on a slot it still has to read.
    if (inserted > delete_count) {
        var k: i64 = len - 1;
        while (k >= start + delete_count) : (k -= 1) {
            try spliceMove(vm, this.object, k, k - delete_count + inserted);
        }
    } else {
        var k: i64 = start + delete_count;
        while (k < len) : (k += 1) {
            try spliceMove(vm, this.object, k, k - delete_count + inserted);
        }
    }

    var j: i64 = 0;
    while (j < inserted) : (j += 1) {
        try vm.arraySet(this.object, @intCast(start + j), args[@intCast(2 + j)]);
    }
    try vm.setArrayLength(this.object, @intCast(@max(0, len - delete_count + inserted)));
    return .{ .object = removed };
}

/// A HOLE stays a hole: moving an absent element deletes the
/// destination rather than writing undefined into it.
fn spliceMove(vm: *Vm, h: ObjectHandle, from: i64, to: i64) !void {
    const key = try arrayKey(vm, @intCast(from));
    if (vm.objects.hasOwn(h, key, vm.case_sensitive)) {
        try vm.arraySet(h, @intCast(to), try indexGet(vm, h, @intCast(from)));
    } else {
        try arrayDelete(vm, h, @intCast(to));
    }
}

/// `Array.sort` option bits, also exposed on the class itself.
const SORT_CASE_INSENSITIVE: i32 = 1;
const SORT_DESCENDING: i32 = 2;
const SORT_UNIQUE: i32 = 4;
const SORT_RETURN_INDEXED: i32 = 8;
const SORT_NUMERIC: i32 = 16;

const SortCtx = struct {
    vm: *Vm,
    compare: ?Value,
    options: i32,
    /// `sortOn` only: the property names to compare, in precedence
    /// order, each with its own option bits.
    fields: []const strings.AvmString = &.{},
    field_options: []const i32 = &.{},

    fn has(self: SortCtx, bit: i32) bool {
        return (self.options & bit) != 0;
    }

    /// -1, 0 or 1. A custom comparator's return is used as given; the
    /// built-in one compares as STRINGS unless both sides are numbers
    /// and NUMERIC was asked for.
    fn order(self: SortCtx, a: Value, b: Value) !i32 {
        if (self.fields.len > 0) {
            if (a == .object and b == .object) {
                for (self.fields, 0..) |name, i| {
                    // OWN properties only — `__proto__` is a field name
                    // like any other here, not the prototype link.
                    const av = fieldOf(self.vm, a.object, name);
                    const bv = fieldOf(self.vm, b.object, name);
                    const sub: SortCtx = .{ .vm = self.vm, .compare = null, .options = self.field_options[i] };
                    const r = try sub.order(av, bv);
                    if (r != 0) return r;
                }
                return 0;
            }
            const plain: SortCtx = .{ .vm = self.vm, .compare = null, .options = self.options };
            return plain.order(a, b);
        }
        if (self.compare) |f| {
            const r = try self.vm.callFunction(f, .undefined_value, &.{ a, b });
            const n = try self.vm.toNumber(r);
            if (std.math.isNan(n)) return 0;
            return if (n < 0) -1 else if (n > 0) @as(i32, 1) else 0;
        }
        var result: i32 = 0;
        if (self.has(SORT_NUMERIC) and a == .number and b == .number) {
            if (std.math.isNan(a.number) or std.math.isNan(b.number)) {
                result = 0;
            } else {
                result = if (a.number < b.number) -1 else if (a.number > b.number) @as(i32, 1) else 0;
            }
        } else {
            const sa = try self.vm.toStringValue(a);
            const sb = try self.vm.toStringValue(b);
            const ord = if (self.has(SORT_CASE_INSENSITIVE))
                orderIgnoreCase(sa, sb)
            else
                strings.order(sa, sb);
            result = switch (ord) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
        return if (self.has(SORT_DESCENDING)) -result else result;
    }
};

/// Case folding for SORTING, which reaches past ASCII: Flash folds the
/// Latin-1 supplement and Latin Extended-A as well, so `HËLLO` and
/// `hëllo` compare equal. Property lookup's folding stays ASCII-only —
/// that is a different rule and `strings.foldCase` owns it.
fn foldForSort(c: u16) u16 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    // The supplement's uppercase block, minus the multiplication sign
    // sitting in the middle of it.
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 0x20;
    // Extended-A pairs an uppercase EVEN unit with its lowercase
    // successor, twice over with a gap in the middle.
    if ((c >= 0x100 and c <= 0x137) or (c >= 0x14A and c <= 0x177)) {
        return if (c % 2 == 0) c + 1 else c;
    }
    if (c >= 0x139 and c <= 0x148) return if (c % 2 == 1) c + 1 else c;
    if (c >= 0x179 and c <= 0x17E) return if (c % 2 == 1) c + 1 else c;
    return c;
}

/// The value `sortOn` compares for one field. A boxed String carries a
/// `length` that is computed rather than stored, and content sorts on
/// it; everything else is an own property or nothing.
fn fieldOf(vm: *Vm, h: ObjectHandle, name: strings.AvmString) Value {
    if (vm.objects.getOwn(h, name, vm.case_sensitive)) |v| return v;
    if (strings.eql(name, S("length"))) {
        if (vm.objects.get(h).native == .boxed_string) {
            return .{ .number = @floatFromInt(vm.objects.get(h).native.boxed_string.len) };
        }
    }
    return .undefined_value;
}

fn orderIgnoreCase(a: strings.AvmString, b: strings.AvmString) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = foldForSort(ca);
        const lb = foldForSort(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Flash's own quicksort, ported move for move. It is UNSTABLE and its
/// pivot is always the leftmost element, so the permutation it leaves
/// equal elements in is observable — a stable sort produces a different
/// array from the same input (corpus array_sort).
fn qsort(ctx: SortCtx, idx: []i32, vals: []Value) !void {
    if (vals.len < 2) return;
    var stack: std.ArrayList([2]usize) = .empty;
    defer stack.deinit(ctx.vm.arena());
    try stack.append(ctx.vm.arena(), .{ 0, vals.len - 1 });

    while (stack.pop()) |range| {
        const low = range[0];
        const high = range[1];
        if (low >= high) continue;
        const pivot = vals[low];
        var left = low + 1;
        var right = high;
        while (true) {
            while (left < right and (try ctx.order(pivot, vals[left])) > 0) left += 1;
            while (right > low and (try ctx.order(pivot, vals[right])) <= 0) right -= 1;
            if (left >= right) break;
            std.mem.swap(Value, &vals[left], &vals[right]);
            std.mem.swap(i32, &idx[left], &idx[right]);
        }
        std.mem.swap(Value, &vals[low], &vals[right]);
        std.mem.swap(i32, &idx[low], &idx[right]);
        try stack.append(ctx.vm.arena(), .{ right + 1, high });
        if (right > 0) try stack.append(ctx.vm.arena(), .{ low, right - 1 });
    }
}

/// `sortOn(field)` / `sortOn(field, options)` / `sortOn([fields],
/// [options])`. Fields are compared IN ORDER, each with its own options,
/// and the first difference decides. An element that is not an object
/// falls back to comparing the elements themselves.
///
/// Unlike `sort`, DESCENDING is folded into the comparison rather than
/// applied by reversing afterwards.
fn arrSortOn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (args.len == 0) return .undefined_value;

    var names: std.ArrayList(strings.AvmString) = .empty;
    var opts: std.ArrayList(i32) = .empty;
    const a = vm.arena();

    const first = args[0];
    if (first == .object and vm.objects.get(first.object).native == .array) {
        const n = vm.arrayLength(first.object);
        if (n == 0) return this;
        // An options ARRAY is honoured only when it is exactly as long as
        // the field list. A mismatch is not an error and not a partial
        // application — every field falls back to NO options, which is
        // how `sortOn(["a","b"], [DESCENDING])` sorts ascending.
        const per_field = args.len > 1 and args[1] == .object and
            vm.objects.get(args[1].object).native == .array and
            vm.arrayLength(args[1].object) == n;
        const shared: i32 = if (!per_field and args.len > 1 and args[1].isPrimitive())
            value_mod.toInt32(try vm.toNumber(args[1]))
        else
            0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try names.append(a, try vm.toStringValue(try indexGet(vm, first.object, i)));
            const o: i32 = if (per_field)
                value_mod.toInt32(try vm.toNumber(try indexGet(vm, args[1].object, i)))
            else
                shared;
            try opts.append(a, o);
        }
    } else {
        try names.append(a, try vm.toStringValue(first));
        // A single field takes its options only from a NUMBER.
        try opts.append(a, if (args.len > 1 and args[1] == .number)
            value_mod.toInt32(args[1].number)
        else
            0);
    }

    const len = vm.arrayLength(this.object);
    const vals = try a.alloc(Value, len);
    const idx = try a.alloc(i32, len);
    var k: u32 = 0;
    while (k < len) : (k += 1) {
        vals[k] = try indexGet(vm, this.object, k);
        idx[k] = @intCast(k);
    }

    const ctx: SortCtx = .{
        .vm = vm,
        .compare = null,
        .options = if (opts.items.len > 0) opts.items[0] else 0,
        .fields = names.items,
        .field_options = opts.items,
    };
    try qsort(ctx, idx, vals);

    const main_options = if (opts.items.len > 0) opts.items[0] else 0;
    if ((main_options & SORT_UNIQUE) != 0) {
        var j: usize = 1;
        while (j < vals.len) : (j += 1) {
            if ((try ctx.order(vals[j - 1], vals[j])) == 0) return .{ .number = 0 };
        }
    }
    if ((main_options & SORT_RETURN_INDEXED) != 0) {
        const out = try vm.newArray();
        for (idx, 0..) |v, m| try vm.arraySet(out, @intCast(m), .{ .number = @floatFromInt(v) });
        return .{ .object = out };
    }
    for (vals, 0..) |v, m| try vm.arraySet(this.object, @intCast(m), v);
    return this;
}

/// `sort()`, `sort(options)`, `sort(compareFn)` or `sort(compareFn,
/// options)`. Anything else in the first slot — `undefined`, a boolean,
/// a string — returns UNDEFINED without touching the array.
fn arrSort(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;

    var compare: ?Value = null;
    var options: i32 = 0;
    if (args.len > 0) {
        switch (args[0]) {
            .object => {
                compare = args[0];
                if (args.len > 1 and args[1] == .number) options = value_mod.toInt32(args[1].number);
            },
            .number => |n| {
                options = if (args.len > 1 and args[1] == .number)
                    value_mod.toInt32(args[1].number)
                else
                    value_mod.toInt32(n);
            },
            else => return .undefined_value,
        }
    }
    var ctx: SortCtx = .{ .vm = vm, .compare = compare, .options = options };

    const len = vm.arrayLength(this.object);
    const vals = try vm.arena().alloc(Value, len);
    const idx = try vm.arena().alloc(i32, len);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        vals[i] = try indexGet(vm, this.object, i);
        idx[i] = @intCast(i);
    }

    // DESCENDING is applied by REVERSING afterwards, not by flipping the
    // comparison — which matters because the sort is unstable.
    const descending = ctx.has(SORT_DESCENDING);
    ctx.options &= ~SORT_DESCENDING;
    try qsort(ctx, idx, vals);
    if (descending) {
        std.mem.reverse(Value, vals);
        std.mem.reverse(i32, idx);
    }

    // UNIQUESORT abandons everything and answers 0 when two elements
    // compare equal — with the BUILT-IN comparison, whatever comparator
    // was used to order them.
    if ((options & SORT_UNIQUE) != 0) {
        const plain: SortCtx = .{ .vm = vm, .compare = null, .options = ctx.options };
        var k: usize = 1;
        while (k < vals.len) : (k += 1) {
            if ((try plain.order(vals[k - 1], vals[k])) == 0) return .{ .number = 0 };
        }
    }

    // RETURNINDEXEDARRAY leaves the array alone and hands back the
    // permutation instead.
    if ((options & SORT_RETURN_INDEXED) != 0) {
        const out = try vm.newArray();
        for (idx, 0..) |v, k| try vm.arraySet(out, @intCast(k), .{ .number = @floatFromInt(v) });
        return .{ .object = out };
    }
    for (vals, 0..) |v, k| try vm.arraySet(this.object, @intCast(k), v);
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
        // A REAL own property, not a virtual one: `hasOwnProperty`
        // reports it, `for..in` does not, assigning to it sticks, and
        // deleting it does nothing (corpus boxed_primitives).
        try vm.objects.putWithAttrs(
            this.object,
            S("length"),
            .{ .number = @floatFromInt(s.len) },
            .{ .dont_enum = true, .dont_delete = true },
            vm.case_sensitive,
        );
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

/// The index WRAPS into an i32 first, so 4294967297 is 1. A negative
/// one, or one past the end, is the empty string. The result is one CODE
/// UNIT, which may be half a surrogate pair.
fn strCharAt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const i = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    if (i < 0 or i >= s.len) return .{ .string = S("") };
    const idx: usize = @intCast(i);
    return .{ .string = s[idx .. idx + 1] };
}

/// `concat` stringifies EVERY argument, including null and undefined,
/// and appends them all.
fn strConcat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    var out: std.ArrayList(u16) = .empty;
    const a = vm.arena();
    try out.appendSlice(a, try thisString(vm, this));
    for (args) |v| try out.appendSlice(a, try vm.toStringValue(v));
    return .{ .string = try out.toOwnedSlice(a) };
}

/// The index WRAPS into an i32 first. Out of range is NaN — except at
/// SWF5 exactly, where it is ZERO.
fn strCharCodeAt(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const i = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    const out_of_range: Value = if (vm.swf_version == 5)
        .{ .number = 0 }
    else
        .{ .number = std.math.nan(f64) };
    if (i < 0) return .{ .number = std.math.nan(f64) };
    if (i >= s.len) return out_of_range;
    return .{ .number = @floatFromInt(s[@intCast(i)]) };
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
    for (s, 0..) |c, i| out[i] = case_tables.toUpper(c);
    return .{ .string = out };
}

fn strToLower(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const out = try vm.arena().alloc(u16, s.len);
    for (s, 0..) |c, i| out[i] = case_tables.toLower(c);
    return .{ .string = out };
}

/// No pattern at all is UNDEFINED, not -1. A start index past the end
/// of the string is -1 rather than a clamped search from the end.
fn strIndexOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const s = try thisString(vm, this);
    const needle = try vm.toStringValue(args[0]);
    var from: usize = 0;
    if (args.len > 1 and args[1] != .undefined_value) {
        const f = value_mod.toInt32(try vm.toNumber(args[1]));
        from = @intCast(@max(f, 0));
    }
    if (from > s.len) return .{ .number = -1 };
    if (needle.len == 0) return .{ .number = @floatFromInt(from) };
    if (std.mem.indexOfPos(u16, s, from, needle)) |i| {
        return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

/// The start index is where the MATCH may end, not where it may begin —
/// the pattern's own length is added to it before the search. A negative
/// one bails out at -1 without searching.
fn strLastIndexOf(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const s = try thisString(vm, this);
    const needle = try vm.toStringValue(args[0]);
    var limit: usize = s.len;
    if (args.len > 1 and args[1] != .undefined_value) {
        const n = value_mod.toInt32(try vm.toNumber(args[1]));
        if (n < 0) return .{ .number = -1 };
        limit = @as(usize, @intCast(n)) + needle.len;
    }
    const window = if (limit <= s.len) s[0..limit] else s;
    if (std.mem.lastIndexOf(u16, window, needle)) |i| {
        return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

fn strSubstring(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    // No arguments at all is UNDEFINED, not the whole string.
    if (args.len == 0) return .undefined_value;
    const s = try thisString(vm, this);
    var a: i64 = stringIndex(value_mod.toInt32(try vm.toNumber(args[0])), s.len);
    var b: i64 = if (args.len > 1 and args[1] != .undefined_value)
        stringIndex(value_mod.toInt32(try vm.toNumber(args[1])), s.len)
    else
        @intCast(s.len);
    if (a > b) std.mem.swap(i64, &a, &b);
    return .{ .string = s[@intCast(a)..@intCast(b)] };
}

fn strSlice(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const s = try thisString(vm, this);
    const a: i64 = wrappingIndex(value_mod.toInt32(try vm.toNumber(args[0])), s.len);
    const b: i64 = if (args.len > 1 and args[1] != .undefined_value)
        wrappingIndex(value_mod.toInt32(try vm.toNumber(args[1])), s.len)
    else
        @intCast(s.len);
    if (a >= b) return .{ .string = S("") };
    return .{ .string = s[@intCast(a)..@intCast(b)] };
}

/// The second argument is a LENGTH, but a negative one is not clamped to
/// zero: `start + length` becomes a WRAPPING end index, so
/// `"hello world".substr(0, -1)` is "hello worl".
fn strSubstr(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len == 0) return .undefined_value;
    const s = try thisString(vm, this);
    const start = wrappingIndex(value_mod.toInt32(try vm.toNumber(args[0])), s.len);
    const count: i64 = if (args.len > 1 and args[1] != .undefined_value)
        value_mod.toInt32(try vm.toNumber(args[1]))
    else
        @intCast(s.len);
    const end = wrappingIndex(@truncate(start + count), s.len);
    if (start >= end) return .{ .string = S("") };
    return .{ .string = s[@intCast(start)..@intCast(end)] };
}

/// A CLAMPING index: negative is the start of the string, and anything
/// past the end is the end. `substring` uses this.
fn stringIndex(i: i32, len: usize) i64 {
    if (i < 0) return 0;
    return @min(@as(i64, i), @as(i64, @intCast(len)));
}

/// A WRAPPING index: negative counts BACK from the end. `slice` and
/// `substr` use this — which is why `substr(0, -1)` is the whole string
/// bar its last character rather than the empty one.
fn wrappingIndex(i: i32, len: usize) i64 {
    const l: i64 = @intCast(len);
    if (i < 0) return @max(0, l + @as(i64, i));
    return @min(@as(i64, i), l);
}

fn clampIndex(n: f64, len: usize) i64 {
    if (std.math.isNan(n) or n < 0) return 0;
    return @intFromFloat(@min(n, @as(f64, @floatFromInt(len))));
}

/// `split(delimiter, limit)`.
///
/// Two SWF5-only quirks: the default delimiter there is a COMMA rather
/// than "no split at all", and an EMPTY delimiter behaves the way
/// undefined does at later versions. An empty delimiter otherwise splits
/// into single characters WITHOUT the leading and trailing empties a
/// naive split produces.
fn strSplit(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try thisString(vm, this);
    const arr = try vm.newArray();

    const limit: usize = blk: {
        if (args.len < 2 or args[1] == .undefined_value) break :blk std.math.maxInt(usize);
        break :blk @intCast(@max(value_mod.toInt32(try vm.toNumber(args[1])), 0));
    };
    const is_swf5 = vm.swf_version == 5;

    var sep: ?strings.AvmString = null;
    if (args.len == 0 or args[0] == .undefined_value) {
        if (is_swf5) sep = S(",");
    } else {
        const got = try vm.toStringValue(args[0]);
        if (!(is_swf5 and got.len == 0)) sep = got;
    }

    const delim = sep orelse {
        // No delimiter: the whole string, as one element — and the limit
        // does not apply.
        try vm.arraySet(arr, 0, .{ .string = s });
        return .{ .object = arr };
    };

    var n: u32 = 0;
    if (delim.len == 0) {
        for (s) |c| {
            if (n >= limit) break;
            const one = try vm.arena().alloc(u16, 1);
            one[0] = c;
            try vm.arraySet(arr, n, .{ .string = one });
            n += 1;
        }
        try vm.setArrayLength(arr, n);
        return .{ .object = arr };
    }
    var it = std.mem.splitSequence(u16, s, delim);
    while (it.next()) |part| {
        if (n >= limit) break;
        try vm.arraySet(arr, n, .{ .string = part });
        n += 1;
    }
    try vm.setArrayLength(arr, n);
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
    // As a FUNCTION with no argument at all, `Boolean()` is undefined —
    // not `false`, which is what coercing the missing argument would give
    // (ruffle boolean.rs boolean_function).
    if (args.len == 0) return .undefined_value;
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

/// The ASnative INDEX of every Math method. These are not decoration:
/// `ASnative(200, 17)` IS `Math.pow`, and the corpus calls it that way.
pub const math_index = struct {
    pub const ABS: u16 = 0;
    pub const MIN: u16 = 1;
    pub const MAX: u16 = 2;
    pub const SIN: u16 = 3;
    pub const COS: u16 = 4;
    pub const ATAN2: u16 = 5;
    pub const TAN: u16 = 6;
    pub const EXP: u16 = 7;
    pub const LOG: u16 = 8;
    pub const SQRT: u16 = 9;
    pub const ROUND: u16 = 10;
    pub const RANDOM: u16 = 11;
    pub const FLOOR: u16 = 12;
    pub const CEIL: u16 = 13;
    pub const ATAN: u16 = 14;
    pub const ASIN: u16 = 15;
    pub const ACOS: u16 = 16;
    pub const POW: u16 = 17;
};

/// ONE function for the whole of Math, keyed by ASnative index — which is
/// how Flash really implements it, and the only way `ASnative(200, n)`
/// can work for every n.
///
/// Two rules apply before the index is looked at. Every Math method
/// coerces its FIRST TWO arguments whether or not it uses them, so a
/// `valueOf` on either runs and the corpus counts the calls — including
/// for `Math.random`, which uses neither. And below SWF7 the ARITY is
/// checked: a call with too few arguments is NaN before the method is
/// reached. An index nobody defines is NaN as well, unlike most ASnative
/// categories, which answer undefined.
pub fn mathMethod(p: *anyopaque, this: Value, args: []const Value, index: u16) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const I = math_index;
    const nan = std.math.nan(f64);

    // A `valueOf` that throws stops the call here, and the SECOND
    // argument is never coerced (corpus math_swf6 "Math.min({throw A},
    // {throw B})" reports only A).
    const x = try vm.toNumberThrowing(arg(args, 0));
    const y = try vm.toNumberThrowing(arg(args, 1));

    if (vm.swf_version <= 6) {
        const valid = switch (index) {
            I.RANDOM => true,
            I.MIN, I.MAX => args.len == 0 or args.len >= 2,
            // `Math.pow(1)` is the one single-argument call that passes:
            // the answer would be 1 whatever the exponent.
            I.POW => args.len >= 2 or (args.len == 1 and x == 1.0),
            I.ATAN2 => args.len >= 2,
            else => args.len >= 1,
        };
        if (!valid) return .{ .number = nan };
    }

    const r: f64 = switch (index) {
        I.ABS => @abs(x),
        // With NO arguments min/max are the identity for the operation;
        // with one, the missing second is NaN and a NaN in EITHER wins.
        I.MIN => if (args.len == 0)
            std.math.inf(f64)
        else if (std.math.isNan(x) or std.math.isNan(y)) nan else @min(x, y),
        I.MAX => if (args.len == 0)
            -std.math.inf(f64)
        else if (std.math.isNan(x) or std.math.isNan(y)) nan else @max(x, y),
        I.SIN => std.math.sin(x),
        I.COS => std.math.cos(x),
        I.ATAN2 => std.math.atan2(x, y),
        I.TAN => @tan(x),
        I.EXP => @exp(x),
        I.LOG => @log(x),
        I.SQRT => @sqrt(x),
        // ES3 round-half-UP, not away from zero: round(-0.5) is 0.
        I.ROUND => if (std.math.isNan(x)) x else @floor(x + 0.5),
        I.RANDOM => vm.rng.random().float(f64),
        I.FLOOR => @floor(x),
        I.CEIL => @ceil(x),
        I.ATAN => std.math.atan(x),
        I.ASIN => std.math.asin(x),
        I.ACOS => std.math.acos(x),
        I.POW => std.math.pow(f64, x, y),
        else => nan,
    };
    return .{ .number = r };
}

// --- global functions --------------------------------------------------------

fn globalInfinity(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    if (vmOf(p).swf_version <= 4) return .undefined_value;
    return .{ .number = std.math.inf(f64) };
}

fn globalNan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    if (vmOf(p).swf_version <= 4) return .undefined_value;
    return .{ .number = std.math.nan(f64) };
}

fn globalIsNan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    // No argument at all is TRUE outright, not the coercion of undefined
    // — which below SWF7 would be zero, and a number. The mirror image of
    // `isFinite`'s bare-false (ruffle globals.rs is_nan/is_finite).
    if (args.len == 0) return .{ .boolean = true };
    return .{ .boolean = std.math.isNan(try vm.toNumber(args[0])) };
}

fn globalIsFinite(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    // No argument at all is FALSE outright, not the coercion of
    // undefined — which below SWF7 would be zero, and finite.
    if (args.len == 0) return .{ .boolean = false };
    const n = try vm.toNumber(args[0]);
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

/// The ASnative CATEGORY table: Flash's builtins are numbered
/// `(category, index)` pairs, and `ASnative` hands back the slot as a
/// callable whether or not anything is defined there. An unknown
/// CATEGORY is undefined; an unknown index within a known category is a
/// live function that answers undefined (or, for Math, NaN).
fn nativeCategory(cat: u32) ?object_mod.TableNativeFn {
    return switch (cat) {
        4 => asSetNativeMethod,
        100 => globalMethod,
        103 => @import("date.zig").dateMethod,
        200 => mathMethod,
        1109 => @import("filters.zig").convolutionMethod,
        else => null,
    };
}

/// `ASnative(category, index)`. Exactly two arguments — one is
/// undefined, three is undefined. The index is taken as a u32 (so 4.5
/// truncates to 4 and 2^32+4 wraps to 4) and then narrowed to u16; an
/// index that will not fit becomes u16::MAX, which no category defines.
fn globalAsNative(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len != 2) return .undefined_value;
    const cat = try toU32(vm, args[0]);
    const idx = try toU32(vm, args[1]);
    const f = nativeCategory(cat) orelse return .undefined_value;
    const index: u16 = if (idx <= std.math.maxInt(u16)) @intCast(idx) else std.math.maxInt(u16);
    return .{ .object = try vm.newTableNativeFn(f, index) };
}

/// ECMA ToUint32, which is what `ASnative` reads its arguments with —
/// NaN and infinities become 0.
fn toU32(vm: *Vm, v: Value) anyerror!u32 {
    return @bitCast(value_mod.toInt32(try vm.toNumberThrowing(v)));
}

/// ASnative category 100: the five loose functions on `_global`.
pub fn globalMethod(p: *anyopaque, this: Value, args: []const Value, index: u16) anyerror!Value {
    return switch (index) {
        0 => globalEscape(p, this, args),
        1 => globalUnescape(p, this, args),
        2 => globalParseInt(p, this, args),
        3 => globalParseFloat(p, this, args),
        4 => globalTrace(p, this, args),
        else => .undefined_value,
    };
}

/// `_global.trace`, which is NOT the `Trace` action: it coerces
/// undefined to "" at every version, where the action prints
/// "undefined" from SWF7 up.
fn globalTrace(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    try vm.traceLine(try vm.toStringValue(arg(args, 0)));
    return .undefined_value;
}


/// ASnative category 4: `ASSetNative` (0) and `ASSetNativeAccessor` (1),
/// the loaders Flash's own `globals.as` uses to wire the numbered slots
/// onto the prototypes. Both take
/// `(object, category, "a,b,c" , first_index)` and walk the comma list,
/// consuming one index per name — two per name for the accessor form,
/// getter then setter.
///
/// A name may carry a VERSION PREFIX digit ("6alpha", "10foo"): the
/// property is then gated to that SWF version and above. The prefix is
/// stripped from the name. An empty name still consumes its index.
pub fn asSetNativeMethod(p: *anyopaque, this: Value, args: []const Value, index: u16) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (index > 1) return .undefined_value;
    if (args.len < 3) return .undefined_value;
    const target = arg(args, 0);
    if (target != .object) return .undefined_value;
    const cat = try toU32(vm, args[1]);
    const props = try vm.toStringThrowing(args[2]);
    var minor: u32 = if (args.len > 3) try toU32(vm, args[3]) else 0;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= props.len) : (i += 1) {
        if (i != props.len and props[i] != ',') continue;
        var name = props[start..i];
        start = i + 1;
        const attrs = versionPrefix(&name);
        if (index == 0) {
            const f = try slotOf(vm, cat, minor);
            minor +%= 1;
            if (name.len == 0) continue;
            const had = vm.objects.findOwn(target.object, name, vm.case_sensitive) != null;
            try vm.setProperty(target.object, name, f, target);
            if (!had) {
                if (vm.objects.findOwn(target.object, name, vm.case_sensitive)) |prop| {
                    prop.attrs = attrs;
                }
            }
        } else {
            const getter = try slotOf(vm, cat, minor);
            minor +%= 1;
            const setter = try slotOf(vm, cat, minor);
            minor +%= 1;
            if (name.len == 0 or getter != .object) continue;
            try decl.putAccessor(
                vm,
                target.object,
                name,
                getter.object,
                if (setter == .object) setter.object else 0,
                attrs,
            );
        }
    }
    return .undefined_value;
}

/// Strip a leading version digit and report the gate it asks for.
fn versionPrefix(name: *strings.AvmString) object_mod.Attributes {
    const n = name.*;
    if (n.len == 0) return .{};
    const bits: u16 = switch (n[0]) {
        '6' => decl.V6,
        '7' => decl.V7,
        '8' => decl.V8,
        '9' => decl.V9,
        // A leading '1' is ALWAYS eaten, but only "10" is a gate: "11k"
        // loses its first digit and installs as "1k" ungated.
        '1' => {
            if (n.len >= 2 and n[1] == '0') {
                name.* = n[2..];
                return .{ .version_bits = decl.V10 };
            }
            name.* = n[1..];
            return .{};
        },
        else => 0,
    };
    if (bits == 0) return .{};
    name.* = n[1..];
    return .{ .version_bits = bits };
}

/// `ASnative(cat, index)` as a value, for the loaders above.
fn slotOf(vm: *Vm, cat: u32, idx: u32) !Value {
    const f = nativeCategory(cat) orelse return .undefined_value;
    const narrow: u16 = if (idx <= std.math.maxInt(u16)) @intCast(idx) else std.math.maxInt(u16);
    return .{ .object = try vm.newTableNativeFn(f, narrow) };
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
        // ONLY alphanumerics survive. ECMA-262 also spares `@*_+-./`;
        // Flash does not, and the corpus checks each of them.
        const keep = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z');
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
    // The setter argument must be PRESENT: an object installs it and an
    // explicit `null` means getter-only, but leaving it off — or passing
    // undefined — refuses the whole call.
    const setter_h: runtime.ObjectHandle = switch (setter) {
        .object => |h| h,
        .null_value => 0,
        else => return .{ .boolean = false },
    };
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
        // ENUMERABLE (ruffle passes `Attribute::empty()`): a `for..in`
        // that reaches the object — or anything with it on its prototype
        // chain — lists the virtual property alongside the plain ones.
        vm.objects.next_prop_gen +%= 1;
        try o.props.append(vm.arena(), .{
            .key = key,
            .value = .undefined_value,
            .getter = getter.object,
            .setter = setter_h,
            .gen = vm.objects.next_prop_gen,
        });
    }
    return .{ .boolean = true };
}
