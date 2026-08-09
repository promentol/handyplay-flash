//! flash.geom — Point, Rectangle, Matrix, ColorTransform, Transform.
//!
//! The first four are pure value classes: their state lives in ordinary
//! `x`/`a`/`redMultiplier`/… properties that script can read, write and
//! enumerate, exactly as in Flash. Nothing here caches them, so
//! `new Matrix(); m.a = 3; m.toString()` works even though `a` was never
//! declared.
//!
//! `Transform` is the odd one out: it is a LIVE VIEW of a display object.
//! Reading `t.matrix` builds a fresh Matrix from the clip's current
//! placement, and assigning one writes through. Two consequences the corpus
//! checks: `t.matrix == t.matrix` is false (each read is a new object), and
//! `t.matrix.tx = 999` changes nothing (you mutated the copy).
//!
//! Reference: reference/ruffle/core/src/avm1/globals/{point,rectangle,
//! matrix,color_transform,transform}.rs.

const std = @import("std");
const swf = @import("../../swf/swf.zig");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage = @import("../stage_object.zig");
const decl = @import("decl.zig");
const display_object = @import("../../display/display_object.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const Matrix = swf.reader.Matrix;
const ColorTransform = swf.reader.ColorTransform;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;

const twipsFromPixels = display_object.twipsFromPixels;
const pixelsFromTwips = display_object.pixelsFromTwips;

/// `flash` itself is VERSION_8-gated on _global; everything under it is
/// declared with no flags, exactly as ruffle's tables have it.
pub fn install(vm: *Vm) !void {
    const flash = try decl.namespace(vm, "flash", decl.ver(.{ .dont_enum = true }, decl.V8));
    try @import("filters.zig").install(vm, flash);
    const display = try decl.subObject(vm, flash, "display", .{});
    try @import("bitmap_data.zig").install(vm, display);
    // `flash.net`'s classes are BROADCASTERS, and the shared broadcaster
    // functions do not exist until singletons.zig has run — so the
    // namespace is made here and filled from there.
    vm.flash_net = try decl.subObject(vm, flash, "net", .{});
    try @import("external.zig").install(vm, flash);
    const geom = try decl.subObject(vm, flash, "geom", .{});

    vm.point_proto = try protoUnder(vm, geom, "Point", ctorPoint);
    try decl.property(vm, vm.point_proto, "length", pointLength, null, .{ .read_only = true });
    try method(vm, vm.point_proto, "clone", pointClone, .{});
    try method(vm, vm.point_proto, "offset", pointOffset, .{});
    try method(vm, vm.point_proto, "equals", pointEquals, .{});
    try method(vm, vm.point_proto, "subtract", pointSubtract, .{});
    try method(vm, vm.point_proto, "add", pointAdd, .{});
    try method(vm, vm.point_proto, "normalize", pointNormalize, .{});
    try method(vm, vm.point_proto, "toString", pointToString, .{});
    const point_ctor = try ctorOf(vm, vm.point_proto);
    try method(vm, point_ctor, "distance", pointDistance, .{});
    try method(vm, point_ctor, "polar", pointPolar, .{});
    try method(vm, point_ctor, "interpolate", pointInterpolate, .{});

    vm.rectangle_proto = try protoUnder(vm, geom, "Rectangle", ctorRectangle);
    try method(vm, vm.rectangle_proto, "clone", rectClone, .{});
    try method(vm, vm.rectangle_proto, "setEmpty", rectSetEmpty, .{});
    try method(vm, vm.rectangle_proto, "isEmpty", rectIsEmpty, .{});
    try decl.property(vm, vm.rectangle_proto, "left", rectGetLeft, rectSetLeft, .{});
    try decl.property(vm, vm.rectangle_proto, "right", rectGetRight, rectSetRight, .{});
    try decl.property(vm, vm.rectangle_proto, "top", rectGetTop, rectSetTop, .{});
    try decl.property(vm, vm.rectangle_proto, "bottom", rectGetBottom, rectSetBottom, .{});
    try decl.property(vm, vm.rectangle_proto, "topLeft", rectGetTopLeft, rectSetTopLeft, .{});
    try decl.property(vm, vm.rectangle_proto, "bottomRight", rectGetBottomRight, rectSetBottomRight, .{});
    try decl.property(vm, vm.rectangle_proto, "size", rectGetSize, rectSetSize, .{});
    try method(vm, vm.rectangle_proto, "inflate", rectInflate, .{});
    try method(vm, vm.rectangle_proto, "inflatePoint", rectInflatePoint, .{});
    try method(vm, vm.rectangle_proto, "offset", rectOffset, .{});
    try method(vm, vm.rectangle_proto, "offsetPoint", rectOffsetPoint, .{});
    try method(vm, vm.rectangle_proto, "contains", rectContains, .{});
    try method(vm, vm.rectangle_proto, "containsPoint", rectContainsPoint, .{});
    try method(vm, vm.rectangle_proto, "containsRectangle", rectContainsRectangle, .{});
    try method(vm, vm.rectangle_proto, "intersection", rectIntersection, .{});
    try method(vm, vm.rectangle_proto, "intersects", rectIntersects, .{});
    try method(vm, vm.rectangle_proto, "union", rectUnion, .{});
    try method(vm, vm.rectangle_proto, "equals", rectEquals, .{});
    try method(vm, vm.rectangle_proto, "toString", rectToString, .{});

    vm.matrix_proto = try protoUnder(vm, geom, "Matrix", ctorMatrix);
    try method(vm, vm.matrix_proto, "toString", matrixToString, .{});
    try method(vm, vm.matrix_proto, "clone", matrixClone, .{});
    try method(vm, vm.matrix_proto, "identity", matrixIdentity, .{});
    try method(vm, vm.matrix_proto, "concat", matrixConcat, .{});
    try method(vm, vm.matrix_proto, "invert", matrixInvert, .{});
    try method(vm, vm.matrix_proto, "translate", matrixTranslate, .{});
    try method(vm, vm.matrix_proto, "scale", matrixScale, .{});
    try method(vm, vm.matrix_proto, "rotate", matrixRotate, .{});
    try method(vm, vm.matrix_proto, "createBox", matrixCreateBox, .{});
    try method(vm, vm.matrix_proto, "createGradientBox", matrixCreateGradientBox, .{});
    try method(vm, vm.matrix_proto, "transformPoint", matrixTransformPoint, .{});
    try method(vm, vm.matrix_proto, "deltaTransformPoint", matrixDeltaTransformPoint, .{});

    // DECLARATION ORDER IS OBSERVABLE. Every one of the eight components
    // is a virtual property on the PROTOTYPE, not a field on the instance
    // — `for (var k in ColorTransform.prototype)` walks all eleven, and
    // AVM1 enumerates newest-first, so this list is ruffle's read
    // backwards (corpus color_transform).
    vm.colortransform_proto = try protoUnder(vm, geom, "ColorTransform", ctorColorTransform);
    inline for (CT_DECL_ORDER) |i| {
        try decl.property(vm, vm.colortransform_proto, CT_KEYS[i], CT_GETTERS[i], CT_SETTERS[i], .{});
    }
    try decl.property(vm, vm.colortransform_proto, "rgb", ctGetRgb, ctSetRgb, .{});
    try method(vm, vm.colortransform_proto, "concat", ctConcat, .{});
    try method(vm, vm.colortransform_proto, "toString", ctToString, .{});

    vm.transform_proto = try protoUnder(vm, geom, "Transform", ctorTransform);
    try decl.property(vm, vm.transform_proto, "matrix", trGetMatrix, trSetMatrix, decl.ver(.{}, decl.V8));
    try decl.property(vm, vm.transform_proto, "concatenatedMatrix", trGetConcatMatrix, null, decl.ver(.{}, decl.V8));
    try decl.property(vm, vm.transform_proto, "colorTransform", trGetColorTransform, trSetColorTransform, decl.ver(.{}, decl.V8));
    try decl.property(vm, vm.transform_proto, "concatenatedColorTransform", trGetConcatColorTransform, null, decl.ver(.{}, decl.V8));
    try decl.property(vm, vm.transform_proto, "pixelBounds", trGetPixelBounds, null, decl.ver(.{}, decl.V8));
}

/// A class hung off `flash.geom` rather than off `_global`.
fn protoUnder(
    vm: *Vm,
    ns: ObjectHandle,
    comptime name: []const u8,
    f: object_mod.NativeFn,
) !ObjectHandle {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    const ctor = try vm.newNativeFn(f);
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, hidden, false);
    try vm.objects.putWithAttrs(ns, S(name), .{ .object = ctor }, .{}, false);
    return proto;
}

/// The constructor a prototype was installed with.
fn ctorOf(vm: *Vm, proto: ObjectHandle) !ObjectHandle {
    const v = vm.objects.getOwn(proto, S("constructor"), vm.case_sensitive) orelse
        unreachable;
    return v.object;
}

// --- small helpers -------------------------------------------------------------

fn numArg(vm: *Vm, args: []const Value, i: usize) !f64 {
    if (i >= args.len) return 0;
    return vm.toNumber(args[i]);
}

/// Like `numArg`, but a MISSING argument is undefined → NaN, not zero.
/// The geom classes almost all take this reading.
fn numArgNan(vm: *Vm, args: []const Value, i: usize) !f64 {
    if (i >= args.len) return std.math.nan(f64);
    return vm.toNumber(args[i]);
}

fn getNum(vm: *Vm, h: ObjectHandle, comptime name: []const u8) !f64 {
    return vm.toNumber(try vm.getProperty(h, S(name), .{ .object = h }));
}

fn setNum(vm: *Vm, h: ObjectHandle, comptime name: []const u8, n: f64) !void {
    try vm.setProperty(h, S(name), .{ .number = n }, .{ .object = h });
}

/// The `(a=1, b=0, …)` forms every geom class prints. Each component goes
/// through the ordinary number→string rules, so 0.5 prints as "0.5" and an
/// integral value drops its fraction.
fn formatFields(
    vm: *Vm,
    h: ObjectHandle,
    comptime labels: []const []const u8,
    comptime keys: []const []const u8,
) !Value {
    var out: std.ArrayList(u16) = .empty;
    const a = vm.arena();
    try out.append(a, '(');
    inline for (labels, keys, 0..) |label, key, i| {
        if (i != 0) try out.appendSlice(a, S(", "));
        try out.appendSlice(a, S(label));
        try out.append(a, '=');
        const v = try vm.getProperty(h, S(key), .{ .object = h });
        try out.appendSlice(a, try vm.toStringValue(v));
    }
    try out.append(a, ')');
    return .{ .string = try out.toOwnedSlice(a) };
}

// --- Point ----------------------------------------------------------------------

/// Every Point is built by CALLING the constructor, so the property
/// insertion order (`y` then `x`) is the same wherever it comes from.
pub fn newPoint(vm: *Vm, x: f64, y: f64) !Value {
    return pointFrom(vm, &.{ .{ .number = x }, .{ .number = y } });
}

fn pointFrom(vm: *Vm, args: []const Value) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.point_proto };
    _ = try ctorPoint(@ptrCast(vm), .{ .object = h }, args);
    return .{ .object = h };
}

/// The arguments are stored VERBATIM — `new Point(1)` leaves `y`
/// undefined, and `new Point({}, 2)` keeps the object. Only the
/// zero-argument form fills in numbers. `y` goes in first, which is what
/// `for (var k in pt)` reports (corpus point).
fn ctorPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (args.len == 0) {
        try vm.setProperty(this.object, S("y"), .{ .number = 0 }, this);
        try vm.setProperty(this.object, S("x"), .{ .number = 0 }, this);
    } else {
        try vm.setProperty(this.object, S("y"), arg(args, 1), this);
        try vm.setProperty(this.object, S("x"), arg(args, 0), this);
    }
    return this;
}

/// `{x, y}` read off any object as numbers. A non-object (or a missing
/// component) yields NaN, which then poisons the arithmetic — that is the
/// documented result, not a defaulted zero.
fn valueToPoint(vm: *Vm, v: Value) ![2]f64 {
    if (v != .object) return .{ std.math.nan(f64), std.math.nan(f64) };
    return .{
        try getNum(vm, v.object, "x"),
        try getNum(vm, v.object, "y"),
    };
}

fn pointToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    if (this != .object) return .undefined_value;
    return formatFields(vmOf(p), this.object, &.{ "x", "y" }, &.{ "x", "y" });
}

fn pointClone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return pointFrom(vm, &.{
        try vm.getProperty(this.object, S("x"), this),
        try vm.getProperty(this.object, S("y"), this),
    });
}

/// Component-wise VALUE equality, not numeric: two undefined components
/// are equal, and `"1"` never equals `1`.
fn pointEquals(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const other = arg(args, 0);
    if (other != .object) return .{ .boolean = false };
    const ax = try vm.getProperty(this.object, S("x"), this);
    const ay = try vm.getProperty(this.object, S("y"), this);
    const bx = try vm.getProperty(other.object, S("x"), other);
    const by = try vm.getProperty(other.object, S("y"), other);
    return .{ .boolean = vm.strictEquals(ax, bx) and vm.strictEquals(ay, by) };
}

fn pointOffset(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, this);
    try setNum(vm, this.object, "x", pt[0] + try numArgNan(vm, args, 0));
    try setNum(vm, this.object, "y", pt[1] + try numArgNan(vm, args, 1));
    return .undefined_value;
}

fn pointAdd(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return pointCombine(p, this, args, 1);
}

fn pointSubtract(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return pointCombine(p, this, args, -1);
}

fn pointCombine(p: *anyopaque, this: Value, args: []const Value, sign: f64) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const a = try valueToPoint(vm, this);
    const b = try valueToPoint(vm, arg(args, 0));
    return newPoint(vm, a[0] + sign * b[0], a[1] + sign * b[1]);
}

fn pointLength(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, this);
    return .{ .number = @sqrt(pt[0] * pt[0] + pt[1] * pt[1]) };
}

/// Scale the point to the given length. A zero-length point has no
/// direction, so Flash MULTIPLIES instead of dividing — both components
/// stay zero rather than becoming NaN. An infinite length does nothing.
fn pointNormalize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const cur: f64 = try vm.toNumber(try vm.getProperty(this.object, S("length"), this));
    if (!std.math.isFinite(cur)) return .undefined_value;
    const pt = try valueToPoint(vm, this);
    const target = try numArgNan(vm, args, 0);
    const x = if (cur == 0) pt[0] * target else pt[0] / cur * target;
    const y = if (cur == 0) pt[1] * target else pt[1] / cur * target;
    try setNum(vm, this.object, "x", x);
    try setNum(vm, this.object, "y", y);
    return .undefined_value;
}

/// `Point.distance(a, b)` is defined as `a.subtract(b).length` — it goes
/// through the SCRIPT method, so a plain `{x, y}` object with no
/// `subtract` returns undefined rather than a number.
fn pointDistance(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len < 2) return .{ .number = std.math.nan(f64) };
    const a = arg(args, 0);
    if (a != .object) return .undefined_value;
    const sub = try vm.getProperty(a.object, S("subtract"), a);
    if (!vm.isCallable(sub)) return .undefined_value;
    const delta = try vm.callFunction(sub, a, args[1..2]);
    if (delta != .object) return .undefined_value;
    return vm.getProperty(delta.object, S("length"), delta);
}

fn pointPolar(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const len = try numArgNan(vm, args, 0);
    const angle = try numArgNan(vm, args, 1);
    return newPoint(vm, len * @cos(angle), len * @sin(angle));
}

/// Note the direction: `f = 0` is the SECOND point, `f = 1` the first.
fn pointInterpolate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    if (args.len < 3) return newPoint(vm, std.math.nan(f64), std.math.nan(f64));
    const a = try valueToPoint(vm, arg(args, 0));
    const b = try valueToPoint(vm, arg(args, 1));
    const f = try numArgNan(vm, args, 2);
    return newPoint(vm, b[0] - (b[0] - a[0]) * f, b[1] - (b[1] - a[1]) * f);
}

// --- Rectangle --------------------------------------------------------------------

/// Every Rectangle is built by CALLING the constructor, so its four
/// properties always land in the same order.
pub fn newRectangle(vm: *Vm, x: f64, y: f64, w: f64, h: f64) !Value {
    return rectFrom(vm, &.{
        .{ .number = x }, .{ .number = y }, .{ .number = w }, .{ .number = h },
    });
}

fn rectFrom(vm: *Vm, args: []const Value) !Value {
    const o = try vm.objects.create();
    vm.objects.get(o).proto = .{ .object = vm.rectangle_proto };
    _ = try ctorRectangle(@ptrCast(vm), .{ .object = o }, args);
    return .{ .object = o };
}

/// Verbatim arguments again — `new Rectangle(1)` has a numeric `x` and
/// three undefined components, and every derived reading (`right`,
/// `size`, `isEmpty`) then reports NaN rather than pretending zero.
fn ctorRectangle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (args.len == 0) {
        inline for (.{ "height", "width", "y", "x" }) |k| {
            try vm.setProperty(this.object, S(k), .{ .number = 0 }, this);
        }
    } else {
        inline for (.{ "x", "y", "width", "height" }, 0..) |k, i| {
            try vm.setProperty(this.object, S(k), arg(args, i), this);
        }
    }
    return this;
}

/// The four stored components as numbers.
const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

fn rectOf(vm: *Vm, h: ObjectHandle) !Rect {
    return .{
        .x = try getNum(vm, h, "x"),
        .y = try getNum(vm, h, "y"),
        .w = try getNum(vm, h, "width"),
        .h = try getNum(vm, h, "height"),
    };
}

/// The same four read off an ARGUMENT: anything that is not an object at
/// all reads as NaN throughout.
fn rectArg(vm: *Vm, v: Value) !Rect {
    if (v != .object) {
        const nan = std.math.nan(f64);
        return .{ .x = nan, .y = nan, .w = nan, .h = nan };
    }
    return rectOf(vm, v.object);
}

fn rectToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    if (this != .object) return .undefined_value;
    return formatFields(
        vmOf(p),
        this.object,
        &.{ "x", "y", "w", "h" },
        &.{ "x", "y", "width", "height" },
    );
}

fn rectClone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    var vals: [4]Value = undefined;
    inline for (.{ "x", "y", "width", "height" }, 0..) |k, i| {
        vals[i] = try vm.getProperty(this.object, S(k), this);
    }
    return rectFrom(vm, &vals);
}

/// A NaN dimension counts as empty, which is how a partly-built
/// rectangle reports itself.
fn rectIsEmpty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r = try rectOf(vm, this.object);
    return .{ .boolean = r.w <= 0 or r.h <= 0 or std.math.isNan(r.w) or std.math.isNan(r.h) };
}

fn rectSetEmpty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    inline for (.{ "x", "y", "width", "height" }) |k| try setNum(vm, this.object, k, 0);
    return .undefined_value;
}

/// Component-wise VALUE equality, and the other side must actually be a
/// Rectangle — a matching `{x, y, width, height}` is not equal to one.
fn rectEquals(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .{ .boolean = false };
    inline for (.{ "x", "y", "width", "height" }) |k| {
        const a = try vm.getProperty(this.object, S(k), this);
        const b = try vm.getProperty(other.object, S(k), other);
        if (!vm.strictEquals(a, b)) return .{ .boolean = false };
    }
    // …and the other side must BE a Rectangle: a plain object with the
    // same four numbers is not equal to one.
    var cur = vm.objects.get(other.object).proto;
    var depth: u32 = 0;
    while (cur == .object and depth < 256) : (depth += 1) {
        if (cur.object == vm.rectangle_proto) return .{ .boolean = true };
        cur = vm.objects.get(cur.object).proto;
    }
    return .{ .boolean = false };
}

fn rectContains(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return containsXY(vm, this.object, try numArgNan(vm, args, 0), try numArgNan(vm, args, 1));
}

fn rectContainsPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, arg(args, 0));
    return containsXY(vm, this.object, pt[0], pt[1]);
}

fn containsXY(vm: *Vm, h: ObjectHandle, x: f64, y: f64) !Value {
    if (std.math.isNan(x) or std.math.isNan(y)) return .undefined_value;
    const r = try rectOf(vm, h);
    return .{ .boolean = x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h };
}

fn rectContainsRectangle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .undefined_value;
    const a = try rectOf(vm, this.object);
    const b = try rectOf(vm, other.object);
    if (std.math.isNan(b.x) or std.math.isNan(b.y) or
        std.math.isNan(b.x + b.w) or std.math.isNan(b.y + b.h)) return .undefined_value;
    return .{ .boolean = b.x >= a.x and b.x + b.w <= a.x + a.w and
        b.y >= a.y and b.y + b.h <= a.y + a.h };
}

fn rectIntersects(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .{ .boolean = false };
    const a = try rectOf(vm, this.object);
    const b = try rectOf(vm, other.object);
    return .{ .boolean = a.x < b.x + b.w and a.x + a.w > b.x and
        a.y < b.y + b.h and a.y + a.h > b.y };
}

/// NaN is CONTAGIOUS here rather than ignored: if either edge is NaN the
/// union edge is NaN, this side first.
fn rectUnion(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const a = try rectOf(vm, this.object);
    const b = try rectArg(vm, arg(args, 0));
    const left = nanFirst(a.x, b.x, false);
    const top = nanFirst(a.y, b.y, false);
    const right = nanFirst(a.x + a.w, b.x + b.w, true);
    const bottom = nanFirst(a.y + a.h, b.y + b.h, true);
    return newRectangle(vm, left, top, right - left, bottom - top);
}

fn nanFirst(a: f64, b: f64, take_max: bool) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    return if (take_max) @max(a, b) else @min(a, b);
}

/// Any NaN anywhere collapses the intersection to the empty rectangle,
/// as does a non-overlap.
fn rectIntersection(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const a = try rectOf(vm, this.object);
    const b = try rectArg(vm, arg(args, 0));
    // The NaN test is on the INPUTS: `@max` quietly ignores a NaN
    // operand, so testing the result would let a missing argument
    // through as "the whole of this rectangle".
    const bad = for ([_]f64{
        a.x, a.y, a.x + a.w, a.y + a.h, b.x, b.y, b.x + b.w, b.y + b.h,
    }) |v| {
        if (std.math.isNan(v)) break true;
    } else false;
    var left = @max(a.x, b.x);
    var top = @max(a.y, b.y);
    var right = @min(a.x + a.w, b.x + b.w);
    var bottom = @min(a.y + a.h, b.y + b.h);
    if (bad or right <= left or bottom <= top) {
        left = 0;
        top = 0;
        right = 0;
        bottom = 0;
    }
    return newRectangle(vm, left, top, right - left, bottom - top);
}

fn rectOffset(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return offsetBy(vm, this.object, try numArgNan(vm, args, 0), try numArgNan(vm, args, 1));
}

fn rectOffsetPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, arg(args, 0));
    return offsetBy(vm, this.object, pt[0], pt[1]);
}

fn offsetBy(vm: *Vm, h: ObjectHandle, dx: f64, dy: f64) !Value {
    const r = try rectOf(vm, h);
    try setNum(vm, h, "x", r.x + dx);
    try setNum(vm, h, "y", r.y + dy);
    return .undefined_value;
}

fn rectInflate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return inflateBy(vm, this.object, try numArgNan(vm, args, 0), try numArgNan(vm, args, 1));
}

fn rectInflatePoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, arg(args, 0));
    return inflateBy(vm, this.object, pt[0], pt[1]);
}

fn inflateBy(vm: *Vm, h: ObjectHandle, dx: f64, dy: f64) !Value {
    const r = try rectOf(vm, h);
    try setNum(vm, h, "x", r.x - dx);
    try setNum(vm, h, "y", r.y - dy);
    try setNum(vm, h, "width", r.w + dx * 2);
    try setNum(vm, h, "height", r.h + dy * 2);
    return .undefined_value;
}

/// `left` and `top` are ALIASES for `x` and `y` that keep the opposite
/// edge fixed: moving the left edge changes the width to compensate.
/// They pass the new value through verbatim, so assigning a string
/// leaves `x` a string while `width` goes NaN.
fn rectGetLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.getProperty(this.object, S("x"), this);
}

fn rectSetLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const v = arg(args, 0);
    const old = try getNum(vm, this.object, "x");
    const w = try getNum(vm, this.object, "width");
    try vm.setProperty(this.object, S("x"), v, this);
    try setNum(vm, this.object, "width", w + (old - try vm.toNumber(v)));
    return .undefined_value;
}

fn rectGetTop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return vm.getProperty(this.object, S("y"), this);
}

fn rectSetTop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const v = arg(args, 0);
    const old = try getNum(vm, this.object, "y");
    const h = try getNum(vm, this.object, "height");
    try vm.setProperty(this.object, S("y"), v, this);
    try setNum(vm, this.object, "height", h + (old - try vm.toNumber(v)));
    return .undefined_value;
}

fn rectGetRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r = try rectOf(vm, this.object);
    return .{ .number = r.x + r.w };
}

fn rectSetRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const right = try numArgNan(vm, args, 0);
    try setNum(vm, this.object, "width", right - try getNum(vm, this.object, "x"));
    return .undefined_value;
}

fn rectGetBottom(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r = try rectOf(vm, this.object);
    return .{ .number = r.y + r.h };
}

fn rectSetBottom(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const bottom = try numArgNan(vm, args, 0);
    try setNum(vm, this.object, "height", bottom - try getNum(vm, this.object, "y"));
    return .undefined_value;
}

/// `size` is a Point of (width, height) — built fresh on every read, so
/// mutating it does nothing to the rectangle.
fn rectGetSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return pointFrom(vm, &.{
        try vm.getProperty(this.object, S("width"), this),
        try vm.getProperty(this.object, S("height"), this),
    });
}

fn rectSetSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const src = arg(args, 0);
    var w: Value = .undefined_value;
    var h: Value = .undefined_value;
    if (src == .object) {
        w = try vm.getProperty(src.object, S("x"), src);
        h = try vm.getProperty(src.object, S("y"), src);
    }
    try vm.setProperty(this.object, S("width"), w, this);
    try vm.setProperty(this.object, S("height"), h, this);
    return .undefined_value;
}

fn rectGetTopLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    return pointFrom(vm, &.{
        try vm.getProperty(this.object, S("x"), this),
        try vm.getProperty(this.object, S("y"), this),
    });
}

/// Like `left`/`top` together: the opposite corner stays put.
fn rectSetTopLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const src = arg(args, 0);
    var nx: Value = .undefined_value;
    var ny: Value = .undefined_value;
    if (src == .object) {
        nx = try vm.getProperty(src.object, S("x"), src);
        ny = try vm.getProperty(src.object, S("y"), src);
    }
    const r = try rectOf(vm, this.object);
    try vm.setProperty(this.object, S("x"), nx, this);
    try vm.setProperty(this.object, S("y"), ny, this);
    try setNum(vm, this.object, "width", r.w + (r.x - try vm.toNumber(nx)));
    try setNum(vm, this.object, "height", r.h + (r.y - try vm.toNumber(ny)));
    return .undefined_value;
}

fn rectGetBottomRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r = try rectOf(vm, this.object);
    return newPoint(vm, r.x + r.w, r.y + r.h);
}

/// Note the swap: Flash reads the point's x into the WIDTH against `x`,
/// and its y into the HEIGHT against `y`. Ruffle names the locals
/// `bottom`/`right`/`top`/`left` crosswise for exactly this reason.
fn rectSetBottomRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const pt = try valueToPoint(vm, arg(args, 0));
    try setNum(vm, this.object, "width", pt[0] - try getNum(vm, this.object, "x"));
    try setNum(vm, this.object, "height", pt[1] - try getNum(vm, this.object, "y"));
    return .undefined_value;
}

// --- Matrix ----------------------------------------------------------------------

const MATRIX_KEYS = [_][]const u8{ "a", "b", "c", "d", "tx", "ty" };

pub fn newMatrix(vm: *Vm, m: Matrix) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.matrix_proto };
    try setNum(vm, h, "a", m.a);
    try setNum(vm, h, "b", m.b);
    try setNum(vm, h, "c", m.c);
    try setNum(vm, h, "d", m.d);
    try setNum(vm, h, "tx", pixelsFromTwips(m.tx));
    try setNum(vm, h, "ty", pixelsFromTwips(m.ty));
    return .{ .object = h };
}

/// Read the six fields back out. Translation is in PIXELS on the script
/// side and twips inside.
/// A `flash.geom.Matrix` object's six numbers. `tx`/`ty` are PIXELS on
/// the script side and twips inside, so they convert here.
pub fn matrixOf(vm: *Vm, h: ObjectHandle) !Matrix {
    return .{
        .a = @floatCast(try getNum(vm, h, "a")),
        .b = @floatCast(try getNum(vm, h, "b")),
        .c = @floatCast(try getNum(vm, h, "c")),
        .d = @floatCast(try getNum(vm, h, "d")),
        .tx = twipsFromPixels(try getNum(vm, h, "tx")),
        .ty = twipsFromPixels(try getNum(vm, h, "ty")),
    };
}

/// `new Matrix()` with no arguments is the IDENTITY, not all-zeroes.
fn ctorMatrix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    if (args.len == 0) {
        try storeIdentity(vm, this.object);
        return this;
    }
    // Present arguments are stored VERBATIM and absent ones are not
    // stored at all — `new Matrix(1)` leaves b..ty undefined, and an
    // object argument stays an object until something coerces it.
    inline for (MATRIX_KEYS, 0..) |k, i| {
        if (i < args.len) try vm.setProperty(this.object, S(k), args[i], this);
    }
    return this;
}

fn storeIdentity(vm: *Vm, h: ObjectHandle) !void {
    try setNum(vm, h, "a", 1);
    try setNum(vm, h, "b", 0);
    try setNum(vm, h, "c", 0);
    try setNum(vm, h, "d", 1);
    try setNum(vm, h, "tx", 0);
    try setNum(vm, h, "ty", 0);
}

fn matrixToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    if (this != .object) return .undefined_value;
    return formatFields(vmOf(p), this.object, &MATRIX_KEYS, &MATRIX_KEYS);
}

fn matrixClone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // Clone runs the CONSTRUCTOR over the six raw values, so a component
    // that is not a number survives as itself.
    var vals: [MATRIX_KEYS.len]Value = undefined;
    inline for (MATRIX_KEYS, 0..) |k, i| {
        vals[i] = try vm.getProperty(this.object, S(k), this);
    }
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.matrix_proto };
    _ = try ctorMatrix(p, .{ .object = h }, &vals);
    return .{ .object = h };
}

fn matrixIdentity(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    if (this != .object) return .undefined_value;
    try storeIdentity(vmOf(p), this.object);
    return .undefined_value;
}

/// `m.concat(n)` post-multiplies: the result applies `m` first, then `n`.
fn matrixConcat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .undefined_value;
    const a = try rawMatrix(vm, this.object);
    const b = try rawMatrix(vm, other.object);
    try storeRaw(vm, this.object, .{
        .a = b.a * a.a + b.c * a.b,
        .b = b.b * a.a + b.d * a.b,
        .c = b.a * a.c + b.c * a.d,
        .d = b.b * a.c + b.d * a.d,
        .tx = b.a * a.tx + b.c * a.ty + b.tx,
        .ty = b.b * a.tx + b.d * a.ty + b.ty,
    });
    return .undefined_value;
}

fn matrixInvert(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const m = try rawMatrix(vm, this.object);
    const det = m.a * m.d - m.b * m.c;
    if (det == 0) {
        // Flash leaves a singular matrix with a zeroed linear part and the
        // translation negated.
        try storeRaw(vm, this.object, .{ .a = 0, .b = 0, .c = 0, .d = 0, .tx = -m.tx, .ty = -m.ty });
        return .undefined_value;
    }
    try storeRaw(vm, this.object, .{
        .a = m.d / det,
        .b = -m.b / det,
        .c = -m.c / det,
        .d = m.a / det,
        .tx = (m.c * m.ty - m.d * m.tx) / det,
        .ty = (m.b * m.tx - m.a * m.ty) / det,
    });
    return .undefined_value;
}

fn matrixTranslate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try setNum(vm, this.object, "tx", (try getNum(vm, this.object, "tx")) + (try numArg(vm, args, 0)));
    try setNum(vm, this.object, "ty", (try getNum(vm, this.object, "ty")) + (try numArg(vm, args, 1)));
    return .undefined_value;
}

fn matrixScale(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const sx = try numArg(vm, args, 0);
    const sy = try numArg(vm, args, 1);
    const m = try rawMatrix(vm, this.object);
    try storeRaw(vm, this.object, .{
        .a = m.a * sx,
        .b = m.b * sy,
        .c = m.c * sx,
        .d = m.d * sy,
        .tx = m.tx * sx,
        .ty = m.ty * sy,
    });
    return .undefined_value;
}

fn matrixRotate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const t = try numArg(vm, args, 0);
    const cs = @cos(t);
    const sn = @sin(t);
    const m = try rawMatrix(vm, this.object);
    try storeRaw(vm, this.object, .{
        .a = m.a * cs - m.b * sn,
        .b = m.a * sn + m.b * cs,
        .c = m.c * cs - m.d * sn,
        .d = m.c * sn + m.d * cs,
        .tx = m.tx * cs - m.ty * sn,
        .ty = m.tx * sn + m.ty * cs,
    });
    return .undefined_value;
}

/// `createBox` builds a rotate+scale+translate matrix. The rotation is
/// NOT optional despite the docs: leaving it out makes every component
/// NaN, because `cos(undefined)` is NaN.
fn matrixCreateBox(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try storeBox(
        vm,
        this.object,
        try numArgNan(vm, args, 0),
        try numArgNan(vm, args, 1),
        try numArgNan(vm, args, 2),
        try numArg(vm, args, 3),
        try numArg(vm, args, 4),
    );
    return .undefined_value;
}

/// The gradient form scales by 1/1638.4 (a 1638.4-pixel square is the
/// unit gradient) and centres the box on the translation. Here the
/// rotation IS optional.
fn matrixCreateGradientBox(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const w = try numArgNan(vm, args, 0);
    const h = try numArgNan(vm, args, 1);
    try storeBox(
        vm,
        this.object,
        w / 1638.4,
        h / 1638.4,
        try numArg(vm, args, 2),
        try numArg(vm, args, 3) + w / 2.0,
        try numArg(vm, args, 4) + h / 2.0,
    );
    return .undefined_value;
}

/// Ruffle's `create_box_with_rotation`, down to the f32 rounding: the
/// render matrix is f32, so `200 / 1638.4` comes back out as
/// 0.1220703125 and not the f64 value.
fn storeBox(vm: *Vm, h: ObjectHandle, sx: f64, sy: f64, rot: f64, tx: f64, ty: f64) !void {
    const r: f32 = @floatCast(rot);
    const fsx: f32 = @floatCast(sx);
    const fsy: f32 = @floatCast(sy);
    try storeRaw(vm, h, .{
        .a = @cos(r) * fsx,
        .b = @sin(r) * fsy,
        .c = -@sin(r) * fsx,
        .d = @cos(r) * fsy,
        .tx = pixelsFromTwips(twipsFromPixels(tx)),
        .ty = pixelsFromTwips(twipsFromPixels(ty)),
    });
}

fn matrixTransformPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return matrixApply(p, this, args, true);
}

fn matrixDeltaTransformPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return matrixApply(p, this, args, false);
}

fn matrixApply(p: *anyopaque, this: Value, args: []const Value, translate: bool) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const m = try rawMatrix(vm, this.object);
    // A missing point is undefined, whose x and y are NaN — the call
    // still returns a Point, just a NaN one.
    const pt = try valueToPoint(vm, arg(args, 0));
    return newPoint(
        vm,
        m.a * pt[0] + m.c * pt[1] + (if (translate) m.tx else 0),
        m.b * pt[0] + m.d * pt[1] + (if (translate) m.ty else 0),
    );
}

/// The six fields as plain f64 — the script side has no twips and no f32.
const RawMatrix = struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

fn rawMatrix(vm: *Vm, h: ObjectHandle) !RawMatrix {
    return .{
        .a = try getNum(vm, h, "a"),
        .b = try getNum(vm, h, "b"),
        .c = try getNum(vm, h, "c"),
        .d = try getNum(vm, h, "d"),
        .tx = try getNum(vm, h, "tx"),
        .ty = try getNum(vm, h, "ty"),
    };
}

fn storeRaw(vm: *Vm, h: ObjectHandle, m: RawMatrix) !void {
    try setNum(vm, h, "a", m.a);
    try setNum(vm, h, "b", m.b);
    try setNum(vm, h, "c", m.c);
    try setNum(vm, h, "d", m.d);
    try setNum(vm, h, "tx", m.tx);
    try setNum(vm, h, "ty", m.ty);
}

// --- ColorTransform ----------------------------------------------------------------

/// The eight components in ARGUMENT order, which is also `toString`
/// order. The prototype declares them in a DIFFERENT order (see install).
const CT_KEYS = [_][]const u8{
    "redMultiplier",   "greenMultiplier", "blueMultiplier", "alphaMultiplier",
    "redOffset",       "greenOffset",     "blueOffset",     "alphaOffset",
};

/// Prototype DECLARATION order, as indices into `CT_KEYS`: alpha first
/// among the multipliers, then alpha first among the offsets.
const CT_DECL_ORDER = [_]usize{ 3, 0, 1, 2, 7, 4, 5, 6 };

/// Where the numbers actually live. The public names are accessors, so the
/// values need somewhere else to sit; a hidden own slot per instance is
/// ruffle's `NativeObject` payload in the shape this VM has.
const CT_SLOTS = [_][]const u8{
    "_ct_rm", "_ct_gm", "_ct_bm", "_ct_am",
    "_ct_ro", "_ct_go", "_ct_bo", "_ct_ao",
};

fn ctGetter(comptime i: usize) object_mod.NativeFn {
    return struct {
        fn f(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            _ = args;
            const vm = vmOf(p);
            if (this != .object) return .undefined_value;
            return .{ .number = try ctRead(vm, this.object, i) };
        }
    }.f;
}

fn ctSetter(comptime i: usize) object_mod.NativeFn {
    return struct {
        fn f(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            const vm = vmOf(p);
            if (this != .object) return .undefined_value;
            // The setter COERCES: `ct.redMultiplier = "Test123"` stores NaN,
            // it does not store the string.
            try ctWrite(vm, this.object, i, try numArg(vm, args, 0));
            return .undefined_value;
        }
    }.f;
}

const CT_GETTERS = blk: {
    var out: [8]object_mod.NativeFn = undefined;
    for (0..8) |i| out[i] = ctGetter(i);
    break :blk out;
};

const CT_SETTERS = blk: {
    var out: [8]?object_mod.NativeFn = undefined;
    for (0..8) |i| out[i] = ctSetter(i);
    break :blk out;
};

fn ctRead(vm: *Vm, h: ObjectHandle, comptime i: usize) !f64 {
    const v = vm.objects.getOwn(h, S(CT_SLOTS[i]), vm.case_sensitive) orelse
        return if (i < 4) 1 else 0;
    return vm.toNumber(v);
}

fn ctWrite(vm: *Vm, h: ObjectHandle, comptime i: usize, n: f64) !void {
    try vm.objects.putWithAttrs(h, S(CT_SLOTS[i]), .{ .number = n }, hidden, false);
}

pub fn newColorTransform(vm: *Vm, ct: ColorTransform) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.colortransform_proto };
    inline for (0..4) |i| {
        try ctWrite(vm, h, i, @as(f64, @floatFromInt(ct.mult[i])) / 256.0);
        try ctWrite(vm, h, i + 4, @floatFromInt(ct.add[i]));
    }
    return .{ .object = h };
}

fn ctorColorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // Fewer than eight arguments means the identity — Flash does not
    // partially apply them (ruffle color_transform.rs constructor).
    if (args.len >= 8) {
        inline for (0..8) |i| try ctWrite(vm, this.object, i, try numArg(vm, args, i));
    } else {
        // A single ColorTransform argument is COPIED; anything else (and
        // nothing at all) gives the identity.
        const src = arg(args, 0);
        const copy = args.len == 1 and src == .object and
            vm.objects.getOwn(src.object, S(CT_SLOTS[0]), vm.case_sensitive) != null;
        inline for (0..8) |i| {
            const v: f64 = if (copy)
                try ctRead(vm, src.object, i)
            else if (i < 4) 1 else 0;
            try ctWrite(vm, this.object, i, v);
        }
    }
    return this;
}

fn ctToString(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    if (this != .object) return .undefined_value;
    return formatFields(vmOf(p), this.object, &CT_KEYS, &CT_KEYS);
}

fn ctConcat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .undefined_value;
    inline for (0..4) |i| {
        const om = try getNum(vm, other.object, CT_KEYS[i]);
        const oa = try getNum(vm, other.object, CT_KEYS[i + 4]);
        const sm = try ctRead(vm, this.object, i);
        const sa = try ctRead(vm, this.object, i + 4);
        try ctWrite(vm, this.object, i + 4, oa * sm + sa);
        try ctWrite(vm, this.object, i, om * sm);
    }
    return .undefined_value;
}

/// The offsets packed as 0xRRGGBB; writing it also zeroes the multipliers,
/// which is how `new Color(mc).setRGB` is expressed in geom terms.
fn ctGetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r = value_mod.toInt32(try ctRead(vm, this.object, 4));
    const g = value_mod.toInt32(try ctRead(vm, this.object, 5));
    const b = value_mod.toInt32(try ctRead(vm, this.object, 6));
    return .{ .number = @floatFromInt(((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)) };
}

fn ctSetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const rgb = value_mod.toInt32(try numArg(vm, args, 0));
    try ctWrite(vm, this.object, 4, @floatFromInt((rgb >> 16) & 0xFF));
    try ctWrite(vm, this.object, 5, @floatFromInt((rgb >> 8) & 0xFF));
    try ctWrite(vm, this.object, 6, @floatFromInt(rgb & 0xFF));
    try ctWrite(vm, this.object, 0, 0);
    try ctWrite(vm, this.object, 1, 0);
    try ctWrite(vm, this.object, 2, 0);
    return .undefined_value;
}

/// Back to the engine's 8.8 fixed form. `Fixed8::from_f64` truncates.
pub fn colorTransformOf(vm: *Vm, h: ObjectHandle) !ColorTransform {
    var ct: ColorTransform = .{};
    inline for (0..4) |i| {
        ct.mult[i] = fixed8(try getNum(vm, h, CT_KEYS[i]));
        ct.add[i] = @intFromFloat(std.math.clamp(@trunc(try getNum(vm, h, CT_KEYS[i + 4])), -32768, 32767));
    }
    return ct;
}

fn fixed8(n: f64) i16 {
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(n * 256.0), -32768, 32767));
}

/// Was this object MADE by `ColorTransform`? `BitmapData.colorTransform`
/// rejects a duck-typed stand-in even though it accepts one for the
/// rectangle, so the two checks cannot be the same one.
pub fn isColorTransformNominal(vm: *Vm, h: ObjectHandle) bool {
    var proto = vm.objects.get(h).proto;
    var guard: u8 = 0;
    while (proto == .object and guard < 64) : (guard += 1) {
        if (proto.object == vm.colortransform_proto) return true;
        proto = vm.objects.get(proto.object).proto;
    }
    return false;
}

/// Is this object shaped like a ColorTransform? Assignment to
/// `transform.colorTransform` only happens for a real one.
fn isColorTransform(vm: *Vm, h: ObjectHandle) bool {
    inline for (CT_KEYS) |k| {
        if (!vm.objects.hasChained(h, S(k), vm.case_sensitive)) return false;
    }
    return true;
}

// --- Transform ------------------------------------------------------------------

fn ctorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // `new Transform()` with no clip is not an object at all.
    const t = stage.targetOfValue(vm, arg(args, 0)) orelse return .undefined_value;
    const handle = if (t.clip) |c| c.avm_object else t.obj.avm_object;
    vm.objects.get(this.object).native = .{ .transform = handle };
    return this;
}

/// The display object a Transform views, or null once it has been removed.
fn transformTarget(vm: *Vm, this: Value) ?stage.Target {
    if (this != .object) return null;
    const n = vm.objects.get(this.object).native;
    if (n != .transform) return null;
    return stage.targetOf(vm, n.transform);
}

/// Build a Transform for `clip` — what `mc.transform` returns. A fresh
/// object every time, so `mc.transform == mc.transform` is false.
pub fn newTransform(vm: *Vm, handle: ObjectHandle) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.transform_proto };
    vm.objects.get(h).native = .{ .transform = handle };
    return .{ .object = h };
}

fn trGetMatrix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    return newMatrix(vm, t.obj.matrix);
}

/// Only an object carrying all six matrix fields AS OWN PROPERTIES writes
/// through; `t.matrix = {}` is silently dropped (ruffle set_matrix).
fn trSetMatrix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v != .object) return .undefined_value;
    inline for (MATRIX_KEYS) |k| {
        if (!vm.objects.hasOwn(v.object, S(k), vm.case_sensitive)) return .undefined_value;
    }
    t.obj.setMatrix(try matrixOf(vm, v.object));
    t.obj.transformed_by_script = true;
    return .undefined_value;
}

fn trGetConcatMatrix(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    return newMatrix(vm, stage.localToGlobalMatrix(t));
}

fn trGetColorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    return newColorTransform(vm, t.obj.color_transform);
}

fn trSetColorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v != .object or !isColorTransform(vm, v.object)) return .undefined_value;
    t.obj.color_transform = try colorTransformOf(vm, v.object);
    t.obj.transformed_by_script = true;
    return .undefined_value;
}

fn trGetConcatColorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    return newColorTransform(vm, stage.concatenatedColorTransform(t));
}

/// The clip's bounds in STAGE space. An object with no geometry reports a
/// rectangle of zeroes here rather than the 0x7ffffff sentinel getBounds
/// uses (ruffle transform.rs GET_PIXEL_BOUNDS).
fn trGetPixelBounds(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = transformTarget(vm, this) orelse return .undefined_value;
    const box = stage.worldBounds(t) orelse return newRectangle(vm, 0, 0, 0, 0);
    return newRectangle(
        vm,
        pixelsFromTwips(box.xmin),
        pixelsFromTwips(box.ymin),
        pixelsFromTwips(box.width()),
        pixelsFromTwips(box.height()),
    );
}

/// `mc.transform = other` copies the matrix and colour transform across —
/// it does not alias the source clip.
pub fn assignTransform(vm: *Vm, dest: stage.Target, v: Value) !void {
    const src = transformTarget(vm, v) orelse return;
    dest.obj.setMatrix(src.obj.matrix);
    dest.obj.color_transform = src.obj.color_transform;
    dest.obj.transformed_by_script = true;
}

// --- Tests --------------------------------------------------------------------

const testing = std.testing;

test "geom value classes stringify exactly as Flash does" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();

    const m = try newMatrix(vm, .identity);
    const ms = try vm.toStringValue(try vm.callFunction(
        try vm.getProperty(m.object, S("toString"), m),
        m,
        &.{},
    ));
    try testing.expect(strings.eql(ms, S("(a=1, b=0, c=0, d=1, tx=0, ty=0)")));

    const ct = try newColorTransform(vm, .{});
    const cs = try vm.toStringValue(try vm.callFunction(
        try vm.getProperty(ct.object, S("toString"), ct),
        ct,
        &.{},
    ));
    try testing.expect(strings.eql(cs, S(
        "(redMultiplier=1, greenMultiplier=1, blueMultiplier=1, alphaMultiplier=1, " ++
            "redOffset=0, greenOffset=0, blueOffset=0, alphaOffset=0)",
    )));

    const r = try newRectangle(vm, 1, 2, 3, 4);
    const rs = try vm.toStringValue(try vm.callFunction(
        try vm.getProperty(r.object, S("toString"), r),
        r,
        &.{},
    ));
    try testing.expect(strings.eql(rs, S("(x=1, y=2, w=3, h=4)")));
}

test "a Matrix round-trips through twips without drifting" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();
    const src: Matrix = .{ .a = 2, .b = 0, .c = 0, .d = 2, .tx = 1420, .ty = -60 };
    const v = try newMatrix(vm, src);
    // 1420 twips is 71px on the script side...
    try testing.expectEqual(@as(f64, 71), try getNum(vm, v.object, "tx"));
    // ...and comes back as the same twips.
    const back = try matrixOf(vm, v.object);
    try testing.expectEqual(src.tx, back.tx);
    try testing.expectEqual(src.ty, back.ty);
    try testing.expectEqual(src.a, back.a);
}
