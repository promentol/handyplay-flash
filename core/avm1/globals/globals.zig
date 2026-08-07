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

const Value = runtime.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

fn vmOf(p: *anyopaque) *Vm {
    return @ptrCast(@alignCast(p));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined_value;
}

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

    const attrs: object_mod.Attributes = .{ .dont_enum = true };

    // --- Object.prototype -------------------------------------------------
    try method(vm, vm.object_proto, "hasOwnProperty", objHasOwnProperty);
    try method(vm, vm.object_proto, "toString", objToString);
    try method(vm, vm.object_proto, "valueOf", objValueOf);
    try method(vm, vm.object_proto, "isPropertyEnumerable", objIsPropEnum);

    // --- Function.prototype ----------------------------------------------
    try method(vm, vm.function_proto, "call", fnCall);
    try method(vm, vm.function_proto, "apply", fnApply);

    // --- Array ------------------------------------------------------------
    try method(vm, vm.array_proto, "push", arrPush);
    try method(vm, vm.array_proto, "pop", arrPop);
    try method(vm, vm.array_proto, "shift", arrShift);
    try method(vm, vm.array_proto, "join", arrJoin);
    try method(vm, vm.array_proto, "toString", arrToString);
    try method(vm, vm.array_proto, "concat", arrConcat);
    try method(vm, vm.array_proto, "slice", arrSlice);

    // --- String.prototype -------------------------------------------------
    try method(vm, vm.string_proto, "toString", strToString);
    try method(vm, vm.string_proto, "valueOf", strToString);
    try method(vm, vm.string_proto, "charAt", strCharAt);
    try method(vm, vm.string_proto, "charCodeAt", strCharCodeAt);
    try method(vm, vm.string_proto, "toUpperCase", strToUpper);
    try method(vm, vm.string_proto, "toLowerCase", strToLower);
    try method(vm, vm.string_proto, "indexOf", strIndexOf);
    try method(vm, vm.string_proto, "lastIndexOf", strLastIndexOf);
    try method(vm, vm.string_proto, "substring", strSubstring);
    try method(vm, vm.string_proto, "substr", strSubstr);
    try method(vm, vm.string_proto, "slice", strSlice);
    try method(vm, vm.string_proto, "split", strSplit);

    // --- Number.prototype -------------------------------------------------
    try method(vm, vm.number_proto, "toString", numToString);
    try method(vm, vm.number_proto, "valueOf", numValueOf);

    // --- Boolean.prototype ------------------------------------------------
    try method(vm, vm.boolean_proto, "toString", boolToString);
    try method(vm, vm.boolean_proto, "valueOf", boolValueOf);

    // --- Constructors -----------------------------------------------------
    try ctor(vm, "Object", ctorObject, vm.object_proto);
    try ctor(vm, "Function", ctorFunction, vm.function_proto);
    try ctor(vm, "Array", ctorArray, vm.array_proto);
    try ctor(vm, "String", ctorString, vm.string_proto);
    try ctor(vm, "Number", ctorNumber, vm.number_proto);
    try ctor(vm, "Boolean", ctorBoolean, vm.boolean_proto);
    // String.fromCharCode static.
    if (vm.objects.getOwn(vm.globals, S("String"), cs)) |sv| {
        try method(vm, sv.object, "fromCharCode", strFromCharCode);
    }
    // Number statics.
    if (vm.objects.getOwn(vm.globals, S("Number"), cs)) |nv| {
        try constNum(vm, nv.object, "MAX_VALUE", std.math.floatMax(f64));
        try constNum(vm, nv.object, "MIN_VALUE", 5e-324);
        try constNum(vm, nv.object, "NaN", std.math.nan(f64));
        try constNum(vm, nv.object, "POSITIVE_INFINITY", std.math.inf(f64));
        try constNum(vm, nv.object, "NEGATIVE_INFINITY", -std.math.inf(f64));
    }

    // --- Math -------------------------------------------------------------
    const math = try vm.objects.create();
    vm.objects.get(math).proto = .{ .object = vm.object_proto };
    try vm.objects.putWithAttrs(vm.globals, S("Math"), .{ .object = math }, attrs, cs);
    try constNum(vm, math, "PI", std.math.pi);
    try constNum(vm, math, "E", std.math.e);
    try constNum(vm, math, "LN10", @log(10.0));
    try constNum(vm, math, "LN2", @log(2.0));
    try constNum(vm, math, "LOG10E", 1.0 / @log(10.0));
    try constNum(vm, math, "LOG2E", 1.0 / @log(2.0));
    try constNum(vm, math, "SQRT1_2", @sqrt(0.5));
    try constNum(vm, math, "SQRT2", @sqrt(2.0));
    try method(vm, math, "abs", mathAbs);
    try method(vm, math, "floor", mathFloor);
    try method(vm, math, "ceil", mathCeil);
    try method(vm, math, "round", mathRound);
    try method(vm, math, "sqrt", mathSqrt);
    try method(vm, math, "pow", mathPow);
    try method(vm, math, "min", mathMin);
    try method(vm, math, "max", mathMax);
    try method(vm, math, "random", mathRandom);
    try method(vm, math, "sin", mathSin);
    try method(vm, math, "cos", mathCos);
    try method(vm, math, "tan", mathTan);
    try method(vm, math, "atan", mathAtan);
    try method(vm, math, "atan2", mathAtan2);
    try method(vm, math, "asin", mathAsin);
    try method(vm, math, "acos", mathAcos);
    try method(vm, math, "exp", mathExp);
    try method(vm, math, "log", mathLog);

    // --- global functions + constants -------------------------------------
    try method(vm, vm.globals, "isNaN", globalIsNan);
    try method(vm, vm.globals, "isFinite", globalIsFinite);
    try method(vm, vm.globals, "parseInt", globalParseInt);
    try method(vm, vm.globals, "parseFloat", globalParseFloat);
    try method(vm, vm.globals, "getTimer", globalGetTimer);
    try vm.objects.putWithAttrs(vm.globals, S("Infinity"), .{ .number = std.math.inf(f64) }, attrs, cs);
    try vm.objects.putWithAttrs(vm.globals, S("NaN"), .{ .number = std.math.nan(f64) }, attrs, cs);
    try vm.objects.putWithAttrs(vm.globals, S("_global"), .{ .object = vm.globals }, attrs, cs);
}

fn method(vm: *Vm, target: ObjectHandle, comptime name: []const u8, f: object_mod.NativeFn) !void {
    const h = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(target, S(name), .{ .object = h }, .{ .dont_enum = true }, false);
}

fn ctor(vm: *Vm, comptime name: []const u8, f: object_mod.NativeFn, proto: ObjectHandle) !void {
    const h = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(h, S("prototype"), .{ .object = proto }, .{ .dont_enum = true }, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = h }, .{ .dont_enum = true }, false);
    try vm.objects.putWithAttrs(vm.globals, S(name), .{ .object = h }, .{ .dont_enum = true }, false);
}

fn constNum(vm: *Vm, target: ObjectHandle, comptime name: []const u8, n: f64) !void {
    try vm.objects.putWithAttrs(target, S(name), .{ .number = n }, .{ .dont_enum = true, .read_only = true, .dont_delete = true }, false);
}

// --- Object ------------------------------------------------------------------

fn ctorObject(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const a0 = arg(args, 0);
    if (a0 == .object) return a0;
    if (this == .object) return this;
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
    return .{ .boolean = !o.props.items[i].attrs.dont_enum };
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

fn indexGet(vm: *Vm, h: ObjectHandle, index: u32) !Value {
    var buf: [12]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{index}) catch unreachable;
    var wide: [12]u16 = undefined;
    for (key, 0..) |c, i| wide[i] = c;
    return vm.objects.getChained(h, wide[0..key.len], vm.case_sensitive) orelse .undefined_value;
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
        const v = try indexGet(vm, h, i);
        if (v != .undefined_value and v != .null_value) {
            try out.appendSlice(a, try vm.toStringValue(v));
        }
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
    if (this == .object) {
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
    if (this == .object) {
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
    if (this == .object) {
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
    return math1(p, args, std.math.sin);
}
fn mathCos(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, std.math.cos);
}
fn mathTan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, std.math.tan);
}
fn mathAtan(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, std.math.atan);
}
fn mathAsin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, std.math.asin);
}
fn mathAcos(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    return math1(p, args, std.math.acos);
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
