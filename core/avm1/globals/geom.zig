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
    try method(vm, vm.point_proto, "toString", pointToString, .{});
    try method(vm, vm.point_proto, "clone", pointClone, .{});
    try method(vm, vm.point_proto, "equals", pointEquals, .{});
    try method(vm, vm.point_proto, "offset", pointOffset, .{});
    try method(vm, vm.point_proto, "add", pointAdd, .{});
    try method(vm, vm.point_proto, "subtract", pointSubtract, .{});
    try method(vm, vm.point_proto, "normalize", pointNormalize, .{});
    try decl.property(vm, vm.point_proto, "length", pointLength, null, .{ .read_only = true });

    vm.rectangle_proto = try protoUnder(vm, geom, "Rectangle", ctorRectangle);
    try method(vm, vm.rectangle_proto, "toString", rectToString, .{});
    try method(vm, vm.rectangle_proto, "clone", rectClone, .{});
    try method(vm, vm.rectangle_proto, "isEmpty", rectIsEmpty, .{});
    try method(vm, vm.rectangle_proto, "setEmpty", rectSetEmpty, .{});
    try method(vm, vm.rectangle_proto, "equals", rectEquals, .{});
    try method(vm, vm.rectangle_proto, "contains", rectContains, .{});
    try method(vm, vm.rectangle_proto, "offset", rectOffset, .{});
    try method(vm, vm.rectangle_proto, "inflate", rectInflate, .{});
    try decl.property(vm, vm.rectangle_proto, "left", rectGetLeft, rectSetLeft, .{});
    try decl.property(vm, vm.rectangle_proto, "top", rectGetTop, rectSetTop, .{});
    try decl.property(vm, vm.rectangle_proto, "right", rectGetRight, rectSetRight, .{});
    try decl.property(vm, vm.rectangle_proto, "bottom", rectGetBottom, rectSetBottom, .{});

    vm.matrix_proto = try protoUnder(vm, geom, "Matrix", ctorMatrix);
    try method(vm, vm.matrix_proto, "toString", matrixToString, .{});
    try method(vm, vm.matrix_proto, "clone", matrixClone, .{});
    try method(vm, vm.matrix_proto, "identity", matrixIdentity, .{});
    try method(vm, vm.matrix_proto, "concat", matrixConcat, .{});
    try method(vm, vm.matrix_proto, "invert", matrixInvert, .{});
    try method(vm, vm.matrix_proto, "translate", matrixTranslate, .{});
    try method(vm, vm.matrix_proto, "scale", matrixScale, .{});
    try method(vm, vm.matrix_proto, "rotate", matrixRotate, .{});
    try method(vm, vm.matrix_proto, "transformPoint", matrixTransformPoint, .{});
    try method(vm, vm.matrix_proto, "deltaTransformPoint", matrixDeltaTransformPoint, .{});

    vm.colortransform_proto = try protoUnder(vm, geom, "ColorTransform", ctorColorTransform);
    try method(vm, vm.colortransform_proto, "toString", ctToString, .{});
    try method(vm, vm.colortransform_proto, "concat", ctConcat, .{});
    try decl.property(vm, vm.colortransform_proto, "rgb", ctGetRgb, ctSetRgb, .{});

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

// --- small helpers -------------------------------------------------------------

fn numArg(vm: *Vm, args: []const Value, i: usize) !f64 {
    if (i >= args.len) return 0;
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

pub fn newPoint(vm: *Vm, x: f64, y: f64) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.point_proto };
    try setNum(vm, h, "x", x);
    try setNum(vm, h, "y", y);
    return .{ .object = h };
}

fn ctorPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try setNum(vm, this.object, "x", try numArg(vm, args, 0));
    try setNum(vm, this.object, "y", try numArg(vm, args, 1));
    return this;
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
    return newPoint(vm, try getNum(vm, this.object, "x"), try getNum(vm, this.object, "y"));
}

fn pointEquals(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .{ .boolean = false };
    return .{ .boolean = (try getNum(vm, this.object, "x")) == (try getNum(vm, other.object, "x")) and
        (try getNum(vm, this.object, "y")) == (try getNum(vm, other.object, "y")) };
}

fn pointOffset(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try setNum(vm, this.object, "x", (try getNum(vm, this.object, "x")) + (try numArg(vm, args, 0)));
    try setNum(vm, this.object, "y", (try getNum(vm, this.object, "y")) + (try numArg(vm, args, 1)));
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
    const other = arg(args, 0);
    var ox: f64 = 0;
    var oy: f64 = 0;
    if (other == .object) {
        ox = try getNum(vm, other.object, "x");
        oy = try getNum(vm, other.object, "y");
    }
    return newPoint(
        vm,
        (try getNum(vm, this.object, "x")) + sign * ox,
        (try getNum(vm, this.object, "y")) + sign * oy,
    );
}

fn pointLength(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const x = try getNum(vm, this.object, "x");
    const y = try getNum(vm, this.object, "y");
    return .{ .number = @sqrt(x * x + y * y) };
}

/// Scale the point to the given length. A zero-length point cannot be
/// pointed anywhere, so it is left alone.
fn pointNormalize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const x = try getNum(vm, this.object, "x");
    const y = try getNum(vm, this.object, "y");
    const len = @sqrt(x * x + y * y);
    if (len == 0) return .undefined_value;
    const target = try numArg(vm, args, 0);
    try setNum(vm, this.object, "x", x * target / len);
    try setNum(vm, this.object, "y", y * target / len);
    return .undefined_value;
}

// --- Rectangle --------------------------------------------------------------------

pub fn newRectangle(vm: *Vm, x: f64, y: f64, w: f64, h: f64) !Value {
    const o = try vm.objects.create();
    vm.objects.get(o).proto = .{ .object = vm.rectangle_proto };
    try setNum(vm, o, "x", x);
    try setNum(vm, o, "y", y);
    try setNum(vm, o, "width", w);
    try setNum(vm, o, "height", h);
    return .{ .object = o };
}

fn ctorRectangle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try setNum(vm, this.object, "x", try numArg(vm, args, 0));
    try setNum(vm, this.object, "y", try numArg(vm, args, 1));
    try setNum(vm, this.object, "width", try numArg(vm, args, 2));
    try setNum(vm, this.object, "height", try numArg(vm, args, 3));
    return this;
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
    return newRectangle(
        vm,
        try getNum(vm, this.object, "x"),
        try getNum(vm, this.object, "y"),
        try getNum(vm, this.object, "width"),
        try getNum(vm, this.object, "height"),
    );
}

fn rectIsEmpty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const w = try getNum(vm, this.object, "width");
    const h = try getNum(vm, this.object, "height");
    return .{ .boolean = !(w > 0 and h > 0) };
}

fn rectSetEmpty(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    inline for (.{ "x", "y", "width", "height" }) |k| try setNum(vm, this.object, k, 0);
    return .undefined_value;
}

fn rectEquals(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const other = arg(args, 0);
    if (this != .object or other != .object) return .{ .boolean = false };
    inline for (.{ "x", "y", "width", "height" }) |k| {
        if ((try getNum(vm, this.object, k)) != (try getNum(vm, other.object, k))) {
            return .{ .boolean = false };
        }
    }
    return .{ .boolean = true };
}

fn rectContains(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const x = try numArg(vm, args, 0);
    const y = try numArg(vm, args, 1);
    const rx = try getNum(vm, this.object, "x");
    const ry = try getNum(vm, this.object, "y");
    return .{ .boolean = x >= rx and y >= ry and
        x < rx + (try getNum(vm, this.object, "width")) and
        y < ry + (try getNum(vm, this.object, "height")) };
}

fn rectOffset(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try setNum(vm, this.object, "x", (try getNum(vm, this.object, "x")) + (try numArg(vm, args, 0)));
    try setNum(vm, this.object, "y", (try getNum(vm, this.object, "y")) + (try numArg(vm, args, 1)));
    return .undefined_value;
}

fn rectInflate(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const dx = try numArg(vm, args, 0);
    const dy = try numArg(vm, args, 1);
    try setNum(vm, this.object, "x", (try getNum(vm, this.object, "x")) - dx);
    try setNum(vm, this.object, "y", (try getNum(vm, this.object, "y")) - dy);
    try setNum(vm, this.object, "width", (try getNum(vm, this.object, "width")) + 2 * dx);
    try setNum(vm, this.object, "height", (try getNum(vm, this.object, "height")) + 2 * dy);
    return .undefined_value;
}

fn rectGetLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return .{ .number = try getNum(vmOf(p), this.object, "x") };
}

/// Moving an edge keeps the OPPOSITE edge fixed, so the size changes.
fn rectSetLeft(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const v = try numArg(vm, args, 0);
    const right = (try getNum(vm, this.object, "x")) + (try getNum(vm, this.object, "width"));
    try setNum(vm, this.object, "x", v);
    try setNum(vm, this.object, "width", right - v);
    return .undefined_value;
}

fn rectGetTop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return .{ .number = try getNum(vmOf(p), this.object, "y") };
}

fn rectSetTop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const v = try numArg(vm, args, 0);
    const bottom = (try getNum(vm, this.object, "y")) + (try getNum(vm, this.object, "height"));
    try setNum(vm, this.object, "y", v);
    try setNum(vm, this.object, "height", bottom - v);
    return .undefined_value;
}

fn rectGetRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    return .{ .number = (try getNum(vm, this.object, "x")) + (try getNum(vm, this.object, "width")) };
}

fn rectSetRight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const v = try numArg(vm, args, 0);
    try setNum(vm, this.object, "width", v - (try getNum(vm, this.object, "x")));
    return .undefined_value;
}

fn rectGetBottom(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    return .{ .number = (try getNum(vm, this.object, "y")) + (try getNum(vm, this.object, "height")) };
}

fn rectSetBottom(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const v = try numArg(vm, args, 0);
    try setNum(vm, this.object, "height", v - (try getNum(vm, this.object, "y")));
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
    try setNum(vm, this.object, "a", try numArg(vm, args, 0));
    try setNum(vm, this.object, "b", try numArg(vm, args, 1));
    try setNum(vm, this.object, "c", try numArg(vm, args, 2));
    try setNum(vm, this.object, "d", try numArg(vm, args, 3));
    try setNum(vm, this.object, "tx", try numArg(vm, args, 4));
    try setNum(vm, this.object, "ty", try numArg(vm, args, 5));
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
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.matrix_proto };
    inline for (MATRIX_KEYS) |k| try setNum(vm, h, k, try getNum(vm, this.object, k));
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

fn matrixTransformPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return matrixApply(p, this, args, true);
}

fn matrixDeltaTransformPoint(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    return matrixApply(p, this, args, false);
}

fn matrixApply(p: *anyopaque, this: Value, args: []const Value, translate: bool) anyerror!Value {
    const vm = vmOf(p);
    const pt = arg(args, 0);
    if (this != .object or pt != .object) return .undefined_value;
    const m = try rawMatrix(vm, this.object);
    const x = try getNum(vm, pt.object, "x");
    const y = try getNum(vm, pt.object, "y");
    return newPoint(
        vm,
        m.a * x + m.c * y + (if (translate) m.tx else 0),
        m.b * x + m.d * y + (if (translate) m.ty else 0),
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

const CT_KEYS = [_][]const u8{
    "redMultiplier",   "greenMultiplier", "blueMultiplier", "alphaMultiplier",
    "redOffset",       "greenOffset",     "blueOffset",     "alphaOffset",
};

pub fn newColorTransform(vm: *Vm, ct: ColorTransform) !Value {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.colortransform_proto };
    inline for (0..4) |i| {
        try setNum(vm, h, CT_KEYS[i], @as(f64, @floatFromInt(ct.mult[i])) / 256.0);
        try setNum(vm, h, CT_KEYS[i + 4], @floatFromInt(ct.add[i]));
    }
    return .{ .object = h };
}

fn ctorColorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // Fewer than eight arguments means the identity — Flash does not
    // partially apply them (ruffle color_transform.rs constructor).
    if (args.len >= 8) {
        inline for (CT_KEYS, 0..) |k, i| try setNum(vm, this.object, k, try numArg(vm, args, i));
    } else {
        inline for (0..4) |i| {
            try setNum(vm, this.object, CT_KEYS[i], 1);
            try setNum(vm, this.object, CT_KEYS[i + 4], 0);
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
        const sm = try getNum(vm, this.object, CT_KEYS[i]);
        const sa = try getNum(vm, this.object, CT_KEYS[i + 4]);
        try setNum(vm, this.object, CT_KEYS[i + 4], oa * sm + sa);
        try setNum(vm, this.object, CT_KEYS[i], om * sm);
    }
    return .undefined_value;
}

/// The offsets packed as 0xRRGGBB; writing it also zeroes the multipliers,
/// which is how `new Color(mc).setRGB` is expressed in geom terms.
fn ctGetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const r: i32 = @intFromFloat(@trunc(try getNum(vm, this.object, "redOffset")));
    const g: i32 = @intFromFloat(@trunc(try getNum(vm, this.object, "greenOffset")));
    const b: i32 = @intFromFloat(@trunc(try getNum(vm, this.object, "blueOffset")));
    return .{ .number = @floatFromInt(((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)) };
}

fn ctSetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const rgb = value_mod.toInt32(try numArg(vm, args, 0));
    try setNum(vm, this.object, "redOffset", @floatFromInt((rgb >> 16) & 0xFF));
    try setNum(vm, this.object, "greenOffset", @floatFromInt((rgb >> 8) & 0xFF));
    try setNum(vm, this.object, "blueOffset", @floatFromInt(rgb & 0xFF));
    try setNum(vm, this.object, "redMultiplier", 0);
    try setNum(vm, this.object, "greenMultiplier", 0);
    try setNum(vm, this.object, "blueMultiplier", 0);
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
