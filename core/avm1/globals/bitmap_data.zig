//! `flash.display.BitmapData` — a scriptable pixel buffer.
//!
//! It hangs off `flash.display`, not `_global`, and it is the half of
//! workstream E the corpus actually measures: 28 of the 29 bitmap dirs
//! exercise this class and never touch a SWF bitmap tag.
//!
//! Two things the constructor does that look like edge cases and are the
//! test's whole point: fewer than two arguments — or a size that fails
//! `isSizeValid` — yields `undefined` rather than an object, and the fill
//! colour comes back CHANGED, because it round-trips through
//! premultiplication (0xAABBCCDD reads as 0xAABBCCDC).
//!
//! Reference: reference/ruffle/core/src/avm1/globals/bitmap_data.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const pixels = @import("../../bitmap/pixels.zig");
const data_mod = @import("../../bitmap/data.zig");
const ops = @import("../../bitmap/operations.zig");
const decl = @import("decl.zig");
const geom = @import("geom.zig");
const stage = @import("../stage_object.zig");
const bitmap_decode = @import("../../bitmap/decode.zig");
const renderer_mod = @import("../../render/renderer.zig");
const swf_mod = @import("../../swf/swf.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const BitmapData = data_mod.BitmapData;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

pub fn install(vm: *Vm, display_ns: ObjectHandle) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.bitmapdata_proto = proto;

    const m = ver(decl.hidden, decl.V8);
    try decl.method(vm, proto, "getPixel", getPixel, m);
    try decl.method(vm, proto, "setPixel", setPixel, m);
    try decl.method(vm, proto, "getPixel32", getPixel32, m);
    try decl.method(vm, proto, "setPixel32", setPixel32, m);
    try decl.method(vm, proto, "dispose", dispose, m);
    try decl.method(vm, proto, "clone", clone, m);
    try decl.method(vm, proto, "fillRect", fillRect, m);
    try decl.method(vm, proto, "floodFill", floodFill, m);
    try decl.method(vm, proto, "colorTransform", colorTransform, m);
    try decl.method(vm, proto, "scroll", scroll, m);
    try decl.method(vm, proto, "noise", noise, m);
    try decl.method(vm, proto, "getColorBoundsRect", getColorBoundsRect, m);
    try decl.method(vm, proto, "compare", compare, m);
    try decl.method(vm, proto, "copyChannel", copyChannel, m);
    try decl.method(vm, proto, "merge", merge, m);
    try decl.method(vm, proto, "threshold", threshold, m);
    try decl.method(vm, proto, "hitTest", hitTest, m);
    try decl.method(vm, proto, "pixelDissolve", pixelDissolve, m);
    try decl.method(vm, proto, "copyPixels", copyPixels, m);
    try decl.method(vm, proto, "paletteMap", paletteMap, m);
    try decl.method(vm, proto, "perlinNoise", perlinNoise, m);
    try decl.method(vm, proto, "applyFilter", applyFilter, m);
    try decl.method(vm, proto, "generateFilterRect", generateFilterRect, m);
    try decl.method(vm, proto, "draw", draw, m);

    const p = ver(.{ .read_only = true }, decl.V8);
    try decl.property(vm, proto, "width", getWidth, null, p);
    try decl.property(vm, proto, "height", getHeight, null, p);
    try decl.property(vm, proto, "transparent", getTransparent, null, p);
    try decl.property(vm, proto, "rectangle", getRectangle, null, p);

    const ctor = try vm.newNativeFn(construct);
    // The channel constants live on the CONSTRUCTOR, and unusually they
    // carry no property flags at all — they enumerate and they can be
    // written over.
    inline for (.{ "RED", "GREEN", "BLUE", "ALPHA" }, .{ 1, 2, 4, 8 }) |name, bit| {
        try vm.objects.putWithAttrs(ctor, S(name ++ "_CHANNEL"), .{ .number = bit }, .{}, false);
    }
    try decl.method(vm, ctor, "loadBitmap", loadBitmap, ver(decl.hidden, decl.V8));
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, decl.hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, decl.hidden, false);
    try vm.objects.putWithAttrs(display_ns, S("BitmapData"), .{ .object = ctor }, .{}, false);
}

/// The buffer behind a receiver, or null when it is not a BitmapData —
/// or has been disposed, which every member treats the same way.
pub fn dataOf(vm: *Vm, this: Value) ?*BitmapData {
    if (this != .object) return null;
    return switch (vm.objects.get(this.object).native) {
        .bitmap_data => |ptr| blk: {
            const bd: *BitmapData = @ptrCast(@alignCast(ptr));
            break :blk if (bd.disposed) null else bd;
        },
        else => null,
    };
}

fn construct(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    // A width alone is not enough, and the answer is UNDEFINED rather
    // than a zero-sized object — `instanceof` fails on it too.
    if (args.len < 2) return .undefined_value;
    const width = try toU32(vm, args[0]);
    const height = try toU32(vm, args[1]);
    // An explicitly passed `undefined` is COERCED, not defaulted — only
    // an ABSENT argument falls back (ruffle's `UndefinedAs::Some`). So
    // `new BitmapData(5, 6, undefined)` is OPAQUE, where `new
    // BitmapData(5, 6)` is transparent.
    const transparency = if (args.len > 2)
        value_mod.toBoolean(args[2], vm.swf_version)
    else
        true;
    const fill = if (args.len > 3) try toU32(vm, args[3]) else 0xFFFF_FFFF;

    if (!pixels.isSizeValid(vm.swf_version, width, height)) return .undefined_value;

    const bd = try vm.arena().create(BitmapData);
    bd.* = try BitmapData.init(vm.gpa, width, height, transparency, fill);
    vm.objects.get(this.object).native = .{ .bitmap_data = @ptrCast(bd) };
    return this;
}

fn toU32(vm: *Vm, v: Value) !u32 {
    return @bitCast(value_mod.toInt32(try vm.toNumber(v)));
}

/// Coordinates are UNSIGNED, so a negative one wraps to an enormous
/// positive and lands out of bounds rather than before the origin.
fn coord(vm: *Vm, v: Value) !i64 {
    return @as(i64, try toU32(vm, v));
}

/// Every pixel member answers -1 — not undefined — when it is short of
/// arguments or the receiver is not a live BitmapData.
const BAD: Value = .{ .number = -1 };

// --- properties ----------------------------------------------------------------

/// A DISPOSED bitmap reports -1, not 0 — the object outlives its pixels
/// and says so.
fn getWidth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .number = @floatFromInt(bd.width) };
}

fn getHeight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .number = @floatFromInt(bd.height) };
}

fn getTransparent(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    return .{ .boolean = bd.transparency };
}

/// A `flash.geom.Rectangle` at the origin. A fresh one every read.
fn getRectangle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return disposedOr(vm, this);
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.rectangle_proto };
    try vm.objects.put(h, S("x"), .{ .number = 0 }, false);
    try vm.objects.put(h, S("y"), .{ .number = 0 }, false);
    try vm.objects.put(h, S("width"), .{ .number = @floatFromInt(bd.width) }, false);
    try vm.objects.put(h, S("height"), .{ .number = @floatFromInt(bd.height) }, false);
    return .{ .object = h };
}

/// -1 when the receiver IS a BitmapData that has been disposed;
/// undefined when it never was one at all.
fn disposedOr(vm: *Vm, this: Value) Value {
    if (this != .object) return .undefined_value;
    return switch (vm.objects.get(this.object).native) {
        .bitmap_data => .{ .number = -1 },
        else => .undefined_value,
    };
}

// --- regions ------------------------------------------------------------------

/// A `flash.geom.Rectangle` argument. Any object with all four of x, y,
/// width and height counts — Flash does not check the class — and one
/// missing property makes the whole call a no-op.
fn rectArg(vm: *Vm, v: Value) !?[4]i32 {
    if (v != .object) return null;
    const o = v.object;
    inline for (.{ "x", "y", "width", "height" }) |k| {
        if (vm.objects.getChained(o, S(k), vm.case_sensitive) == null) return null;
    }
    var out: [4]i32 = undefined;
    inline for (.{ "x", "y", "width", "height" }, 0..) |k, i| {
        const got = vm.objects.getChained(o, S(k), vm.case_sensitive) orelse return null;
        out[i] = value_mod.toInt32(try vm.toNumber(got));
    }
    return out;
}

fn newRect(vm: *Vm, x: f64, y: f64, w: f64, h: f64) !Value {
    const h2 = try vm.objects.create();
    vm.objects.get(h2).proto = .{ .object = vm.rectangle_proto };
    try vm.objects.put(h2, S("x"), .{ .number = x }, false);
    try vm.objects.put(h2, S("y"), .{ .number = y }, false);
    try vm.objects.put(h2, S("width"), .{ .number = w }, false);
    try vm.objects.put(h2, S("height"), .{ .number = h }, false);
    return .{ .object = h2 };
}

// --- operations ----------------------------------------------------------------

fn fillRect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const r = try rectArg(vm, args[0]) orelse return BAD;
    ops.fillRect(bd, r[0], r[1], r[2], r[3], try toU32(vm, args[1]));
    return .{ .number = 0 };
}

fn floodFill(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    // 1 when it actually filled, 0 when it refused — replacing a colour
    // with itself is the refusal.
    const filled = try ops.floodFill(vm.gpa, bd, try coord(vm, args[0]), try coord(vm, args[1]), try toU32(vm, args[2]));
    return .{ .number = if (filled) 1 else 0 };
}

fn scroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    ops.scroll(bd, value_mod.toInt32(try vm.toNumber(args[0])), value_mod.toInt32(try vm.toNumber(args[1])));
    return .{ .number = 0 };
}

/// `noise(seed, low, high, channels, grayScale)` — everything past the
/// seed has a default, and the channel mask defaults to RGB without alpha.
fn noise(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 1) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const seed = value_mod.toInt32(try vm.toNumber(args[0]));
    const low: u8 = if (args.len > 1) clampByte(try vm.toNumber(args[1])) else 0;
    // A high BELOW the low is raised to it rather than producing an empty
    // range, so `noise(s, 10, 2, …)` paints a constant 10.
    const high: u8 = @max(low, if (args.len > 2) clampByte(try vm.toNumber(args[2])) else 255);
    const mask: u32 = if (args.len > 3) try toU32(vm, args[3]) else 7;
    const gray = args.len > 4 and value_mod.toBoolean(args[4], vm.swf_version);
    ops.noise(bd, seed, low, high, ops.Channels.fromBits(mask), gray);
    return .{ .number = 0 };
}

fn clampByte(n: f64) u8 {
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(n), 0, 255));
}

fn getColorBoundsRect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const mask = try toU32(vm, args[0]);
    const color = try toU32(vm, args[1]);
    const find = if (args.len > 2) value_mod.toBoolean(args[2], vm.swf_version) else true;
    const r = ops.colorBoundsRect(bd, find, mask, color);
    return newRect(vm, @floatFromInt(r[0]), @floatFromInt(r[1]), @floatFromInt(r[2]), @floatFromInt(r[3]));
}

/// A colour transform arrives as a `flash.geom.ColorTransform`, whose
/// properties are the four multipliers and the four offsets.
fn colorTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    // -2 is "that was not a rectangle" and -3 "that was not a
    // ColorTransform". The rectangle is duck-typed — any object with the
    // four properties will do — but the transform must be a real one.
    const r = try rectArg(vm, args[0]) orelse return .{ .number = -2 };
    if (args[1] != .object) return .{ .number = -3 };
    const o = args[1].object;
    if (!geom.isColorTransformNominal(vm, o)) return .{ .number = -3 };
    var ct: ops.ColorTransform = .{};
    inline for (.{ "redMultiplier", "greenMultiplier", "blueMultiplier", "alphaMultiplier" }, 0..) |k, i| {
        if (vm.objects.getChained(o, S(k), vm.case_sensitive)) |v| ct.mult[i] = try vm.toNumber(v);
    }
    inline for (.{ "redOffset", "greenOffset", "blueOffset", "alphaOffset" }, 0..) |k, i| {
        if (vm.objects.getChained(o, S(k), vm.case_sensitive)) |v| ct.add[i] = try vm.toNumber(v);
    }
    ops.colorTransform(bd, @max(r[0], 0), @max(r[1], 0), @as(i64, r[0]) + r[2], @as(i64, r[1]) + r[3], ct);
    // -1 on SUCCESS. Not a typo: colorTransform is the one mutator that
    // reports the same value it uses for failure.
    return BAD;
}

/// Sizes that differ report a NEGATIVE CODE rather than a bitmap, and two
/// identical bitmaps report 0 — only a real difference yields an object.
fn compare(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 1) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    // A second argument that is not a live BitmapData is -2, where a
    // bad RECEIVER is -1. The codes are per-function, not a convention.
    const other = dataOf(vm, arg(args, 0)) orelse return .{ .number = -2 };
    const r = try ops.compare(vm.gpa, bd, other);
    switch (r) {
        .different_width => return .{ .number = -3 },
        .different_height => return .{ .number = -4 },
        .same => return .{ .number = 0 },
        .diff => |d| {
            const out = try vm.objects.create();
            vm.objects.get(out).proto = .{ .object = vm.bitmapdata_proto };
            const copy = try vm.arena().create(BitmapData);
            copy.* = d;
            vm.objects.get(out).native = .{ .bitmap_data = @ptrCast(copy) };
            return .{ .object = out };
        },
    }
}

// --- pixels ---------------------------------------------------------------------

fn getPixel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    return .{ .number = @floatFromInt(bd.getPixel(try coord(vm, args[0]), try coord(vm, args[1]))) };
}

fn getPixel32(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 2) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    // SIGNED: an alpha above 0x7F makes the ARGB word negative in AVM1.
    const raw = bd.getPixel32(try coord(vm, args[0]), try coord(vm, args[1]));
    return .{ .number = @floatFromInt(@as(i32, @bitCast(raw))) };
}

fn setPixel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    bd.setPixel(try coord(vm, args[0]), try coord(vm, args[1]), try toU32(vm, args[2]));
    // ZERO, not undefined — both setters report success as a number.
    return .{ .number = 0 };
}

fn setPixel32(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    bd.setPixel32(try coord(vm, args[0]), try coord(vm, args[1]), try toU32(vm, args[2]));
    return .{ .number = 0 };
}

fn dispose(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return BAD;
    bd.dispose(vm.gpa);
    return .undefined_value;
}

fn clone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return BAD;
    const out = try vm.objects.create();
    vm.objects.get(out).proto = .{ .object = vm.bitmapdata_proto };
    const copy = try vm.arena().create(BitmapData);
    copy.* = try BitmapData.init(vm.gpa, bd.width, bd.height, bd.transparency, 0);
    @memcpy(copy.data, bd.data);
    vm.objects.get(out).native = .{ .bitmap_data = @ptrCast(copy) };
    return .{ .object = out };
}

// --- source → destination -----------------------------------------------------

/// Every source→destination member distinguishes "not a BitmapData at
/// all" from "a BitmapData that was disposed", and reports them as
/// DIFFERENT codes — so the plain `dataOf` null is not enough here.
const BitmapArg = union(enum) {
    valid: *BitmapData,
    disposed,
    not_bitmap,
};

fn bitmapArg(vm: *Vm, v: Value) BitmapArg {
    if (v != .object) return .not_bitmap;
    return switch (vm.objects.get(v.object).native) {
        .bitmap_data => |ptr| blk: {
            const bd: *BitmapData = @ptrCast(@alignCast(ptr));
            break :blk if (bd.disposed) .disposed else .{ .valid = bd };
        },
        else => .not_bitmap,
    };
}

/// A destination corner. Unlike a rectangle argument this is never
/// rejected — a missing `x` simply reads as zero.
fn destPoint(vm: *Vm, v: Value) ![2]i32 {
    if (v != .object) return .{ 0, 0 };
    var out: [2]i32 = .{ 0, 0 };
    inline for (.{ "x", "y" }, 0..) |k, i| {
        if (vm.objects.getChained(v.object, S(k), vm.case_sensitive)) |got| {
            out[i] = value_mod.toInt32(try vm.toNumber(got));
        }
    }
    return out;
}

fn copyChannel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 5) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);
    ops.copyChannel(bd, src, dp, r, value_mod.toInt32(try vm.toNumber(args[3])), value_mod.toInt32(try vm.toNumber(args[4])));
    return BAD;
}

fn merge(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    // Six, not seven: the alpha multiplier is optional even though the
    // documentation says otherwise.
    if (args.len < 6) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);
    var mult: [4]i32 = .{ 0, 0, 0, 0xFF };
    inline for (0..3) |i| mult[i] = value_mod.toInt32(try vm.toNumber(args[3 + i]));
    if (args.len > 6) mult[3] = value_mod.toInt32(try vm.toNumber(args[6]));
    ops.merge(bd, src, dp, r, mult);
    return BAD;
}

fn threshold(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 5) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);
    const op = parseThresholdOp(try vm.toStringValue(arg(args, 3)));
    const value = try toU32(vm, args[4]);
    const colour = if (args.len > 5) try toU32(vm, args[5]) else 0;
    const mask = if (args.len > 6) try toU32(vm, args[6]) else 0xFFFF_FFFF;
    const copy_source = args.len > 7 and value_mod.toBoolean(args[7], vm.swf_version);
    const n = ops.threshold(bd, src, r, dp, op, value, colour, mask, copy_source);
    return .{ .number = @floatFromInt(n) };
}

/// Three overloads behind one name, told apart by what the third
/// argument IS: a BitmapData, a duck-typed point, or a duck-typed
/// rectangle. Anything else is -3. The properties are read as OWN ones
/// here — an inherited `x` does not make an object a point.
fn hitTest(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const top_left = try ownPoint(vm, args[0]) orelse return .{ .number = -2 };
    const source_threshold = clampByte(try vm.toNumber(args[1]));

    switch (bitmapArg(vm, args[2])) {
        .disposed => return .{ .number = -3 },
        .valid => |other| {
            const second = try ownPoint(vm, arg(args, 3)) orelse blk: {
                // An absent second point is the origin; a PRESENT but
                // malformed one is an error.
                if (args.len > 3) return .{ .number = -4 };
                break :blk [2]i32{ 0, 0 };
            };
            const second_threshold = if (args.len > 4) clampByte(try vm.toNumber(args[4])) else 0;
            return .{ .boolean = ops.hitTestBitmapData(bd, top_left, source_threshold, other, second, second_threshold) };
        },
        .not_bitmap => {},
    }

    if (args[2] != .object) return .{ .number = -3 };
    const o = args[2].object;
    const tx = vm.objects.getOwn(o, S("x"), vm.case_sensitive) orelse return .{ .number = -3 };
    const ty = vm.objects.getOwn(o, S("y"), vm.case_sensitive) orelse return .{ .number = -3 };
    const tw = vm.objects.getOwn(o, S("width"), vm.case_sensitive);
    const th = vm.objects.getOwn(o, S("height"), vm.case_sensitive);
    const point: [2]i32 = .{
        value_mod.toInt32(try vm.toNumber(tx)) -% top_left[0],
        value_mod.toInt32(try vm.toNumber(ty)) -% top_left[1],
    };
    if (tw == null and th == null) {
        return .{ .boolean = ops.hitTestPoint(bd, source_threshold, point[0], point[1]) };
    }
    if (tw == null or th == null) return .{ .number = -3 };
    const size: [2]i32 = .{
        value_mod.toInt32(try vm.toNumber(tw.?)),
        value_mod.toInt32(try vm.toNumber(th.?)),
    };
    return .{ .boolean = ops.hitTestRectangle(bd, source_threshold, point, size) };
}

/// An unrecognised operator is `<`, not an error.
fn parseThresholdOp(s: strings.AvmString) ops.ThresholdOp {
    if (strings.eql(s, S("=="))) return .eq;
    if (strings.eql(s, S("!="))) return .ne;
    if (strings.eql(s, S("<="))) return .le;
    if (strings.eql(s, S(">"))) return .gt;
    if (strings.eql(s, S(">="))) return .ge;
    return .lt;
}

fn ownPoint(vm: *Vm, v: Value) !?[2]i32 {
    if (v != .object) return null;
    const x = vm.objects.getOwn(v.object, S("x"), vm.case_sensitive) orelse return null;
    const y = vm.objects.getOwn(v.object, S("y"), vm.case_sensitive) orelse return null;
    return .{ value_mod.toInt32(try vm.toNumber(x)), value_mod.toInt32(try vm.toNumber(y)) };
}

fn pixelDissolve(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 4) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);
    const seed = value_mod.toInt32(try vm.toNumber(args[3]));
    // Without a pixel count there is nothing to do — and, notably, not
    // even the always-written pixel at the origin.
    if (args.len < 5) return .{ .number = 0 };
    const num = value_mod.toInt32(try vm.toNumber(args[4]));
    const fill = if (args.len > 5) try toU32(vm, args[5]) else 0;
    return .{ .number = @floatFromInt(ops.pixelDissolve(bd, src, r, dp, seed, num, fill)) };
}

fn copyPixels(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 3) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);
    // Documented as defaulting to true; it is actually FALSE unless an
    // alpha bitmap was named, and the flag is only read at all when six
    // arguments were passed.
    const merge_alpha = args.len >= 6 and value_mod.toBoolean(args[5], vm.swf_version);

    if (args.len > 3) {
        if (bitmapArg(vm, args[3]) == .valid) {
            const alpha_bd = bitmapArg(vm, args[3]).valid;
            const ap = try destPoint(vm, arg(args, 4));
            ops.copyPixelsWithAlphaSource(bd, src, r, dp, alpha_bd, ap, if (args.len >= 6) merge_alpha else true);
            return .{ .number = 0 };
        }
    }
    ops.copyPixels(bd, src, r, dp, merge_alpha);
    return .{ .number = 0 };
}

fn paletteMap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    // Four, not three: without a red array the call does nothing at all.
    if (args.len < 4) return BAD;
    const bd = dataOf(vm, this) orelse return BAD;
    const src = switch (bitmapArg(vm, args[0])) {
        .valid => |s| s,
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    };
    const r = try rectArg(vm, args[1]) orelse return .{ .number = -4 };
    const dp = try destPoint(vm, args[2]);

    var tables: [4][256]u32 = undefined;
    inline for (.{ 3, 4, 5, 6 }, .{ 16, 8, 0, 24 }, 0..) |idx, shift, i| {
        try channelTable(vm, arg(args, idx), shift, &tables[i]);
    }
    ops.paletteMap(bd, src, r, dp, tables);
    return BAD;
}

/// A missing array is the IDENTITY for that channel — entry `i` is `i`
/// shifted into the channel's own byte, so the four sums reassemble the
/// original colour.
fn channelTable(vm: *Vm, v: Value, shift: u5, out: *[256]u32) !void {
    for (out, 0..) |*slot, i| {
        if (v == .object) {
            var buf: [16]u8 = undefined;
            const ascii = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            var wide: [16]u16 = undefined;
            for (ascii, wide[0..ascii.len]) |c, *w| w.* = c;
            const got = vm.objects.getChained(v.object, wide[0..ascii.len], vm.case_sensitive) orelse Value.undefined_value;
            slot.* = try toU32(vm, got);
        } else {
            slot.* = @as(u32, @intCast(i)) << shift;
        }
    }
}

/// The pixel work is not implemented: ruffle's own Perlin output does not
/// match Flash's (its `bitmap_data_thorough/perlinNoise` is a recorded
/// known failure), so there is nothing to port that would be right. The
/// argument contract IS implemented, because `bitmap_data` checks it.
fn perlinNoise(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (args.len < 6) return BAD;
    _ = dataOf(vm, this) orelse return BAD;
    return .{ .number = 0 };
}

/// Filters over a pixel buffer are M7 work — the AVM1 filter OBJECTS
/// landed in workstream D, but nothing applies them. An unbuildable
/// filter is -1, which is what this always reports.
fn applyFilter(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    _ = dataOf(vm, this) orelse return BAD;
    switch (bitmapArg(vm, arg(args, 0))) {
        .valid => {},
        .disposed => return .{ .number = -3 },
        .not_bitmap => return .{ .number = -2 },
    }
    return BAD;
}

fn generateFilterRect(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    _ = dataOf(vm, this) orelse return BAD;
    return .undefined_value;
}

/// `draw(source, matrix, colorTransform, blendMode, clipRect, smooth)`.
///
/// Two very different paths behind one name. A BitmapData source under a
/// matrix with no scale or skew is a plain BLIT — Flash does not go near
/// the renderer for it, and the result is not the same as one that did.
/// Anything else is a real render into an off-screen canvas.
///
/// Blend modes are not modelled; every mode draws as `normal`.
fn draw(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const bd = dataOf(vm, this) orelse return BAD;

    var m: swf_mod.reader.Matrix = .{};
    if (arg(args, 1) == .object) m = try geom.matrixOf(vm, args[1].object);
    // A colour transform must be a REAL one here, as it is everywhere
    // else on this class; a duck-typed object is silently ignored.
    var ct: ?ops.ColorTransform = null;
    if (arg(args, 2) == .object and geom.isColorTransformNominal(vm, args[2].object)) {
        var got: ops.ColorTransform = .{};
        inline for (.{ "redMultiplier", "greenMultiplier", "blueMultiplier", "alphaMultiplier" }, 0..) |k, i| {
            if (vm.objects.getChained(args[2].object, S(k), vm.case_sensitive)) |v| got.mult[i] = try vm.toNumber(v);
        }
        inline for (.{ "redOffset", "greenOffset", "blueOffset", "alphaOffset" }, 0..) |k, i| {
            if (vm.objects.getChained(args[2].object, S(k), vm.case_sensitive)) |v| got.add[i] = try vm.toNumber(v);
        }
        if (!got.isIdentity()) ct = got;
    }
    // The clip rectangle is in destination PIXELS, unlike every other
    // rectangle argument on this class, which are already pixels too —
    // but this one arrives through a geom.Rectangle in pixels and is NOT
    // converted to twips.
    const clip = try rectArg(vm, arg(args, 4));

    switch (bitmapArg(vm, arg(args, 0))) {
        .disposed => return .{ .number = -3 },
        .valid => |src| {
            // The blit path needs an unscaled, unskewed matrix; anything
            // else has to go through the renderer, and a BitmapData is
            // not a display object, so there is nothing to render.
            if (m.a != 1 or m.b != 0 or m.c != 0 or m.d != 1) return .undefined_value;
            ops.drawBitmapData(bd, src, @divFloor(m.tx, 20), @divFloor(m.ty, 20), clip, ct);
            return .undefined_value;
        },
        .not_bitmap => {},
    }

    const t = stage.targetOfValue(vm, arg(args, 0)) orelse return .{ .number = -2 };
    const r = rendererOf(vm) orelse return .undefined_value;
    // Twips in, destination PIXELS out — the ÷20 the stage transform
    // normally supplies has to come from here instead.
    const px = 1.0 / 20.0;
    const full: renderer_mod.Transform = (renderer_mod.Transform{
        .a = px,
        .d = px,
    }).concat(m);
    try r.drawObjectInto(vm.gpa, bd, t.obj, full, .{}, clip);
    return .undefined_value;
}

fn rendererOf(vm: *Vm) ?*renderer_mod.Renderer {
    const p = vm.renderer orelse return null;
    return @ptrCast(@alignCast(p));
}

/// `BitmapData.loadBitmap(exportName)` — a STATIC on the constructor,
/// not a member. It pulls a linkage-exported `DefineBits*` character out
/// of the library and decodes it into a fresh buffer; an unknown name,
/// a character that is not a bitmap, or a payload that will not decode
/// are all plain `undefined`.
///
/// The result is always TRANSPARENT even when the source has no alpha —
/// the decoder fills 255 for those, so the flag costs nothing and
/// matches what Flash reports.
fn loadBitmap(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const name = try vm.toStringValue(arg(args, 0));
    const id = try stage.exportedCharacter(vm, name) orelse return .undefined_value;
    const ctx = stage.displayCtxOf(vm) orelse return .undefined_value;
    const ch = ctx.movie.lib.characters.get(id) orelse return .undefined_value;
    const bmp = switch (ch) {
        .bitmap => |b| b,
        else => return .undefined_value,
    };
    var img = bitmap_decode.decode(vm.gpa, bmp, ctx.movie.jpeg_tables) catch return .undefined_value;
    defer img.deinit(vm.gpa);

    const bd = try vm.arena().create(BitmapData);
    bd.* = try BitmapData.init(vm.gpa, img.width, img.height, true, 0);
    // Decoded pixels are STRAIGHT; storage is premultiplied.
    for (bd.data, 0..) |*slot, i| {
        slot.* = pixels.Color.rgba(
            img.rgba[i * 4 + 0],
            img.rgba[i * 4 + 1],
            img.rgba[i * 4 + 2],
            img.rgba[i * 4 + 3],
        ).toPremultiplied(true);
    }

    const out = try vm.objects.create();
    vm.objects.get(out).proto = .{ .object = vm.bitmapdata_proto };
    vm.objects.get(out).native = .{ .bitmap_data = @ptrCast(bd) };
    return .{ .object = out };
}
