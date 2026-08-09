//! `flash.filters` — the ten filter classes, as AVM1 sees them.
//!
//! In AVM1 a filter is a property bag with typed coercions, and that is
//! what this file implements. The RASTERISATION (blur, glow, bevel) and
//! the PlaceObject3 filter list are M7; a filter set on a clip or a field
//! is stored and reported faithfully but does not yet change any pixels.
//!
//! The coercions are the whole content of the class:
//!
//!   - an ANGLE is stored in radians as `(degrees % 360).toRadians()` and
//!     read back in degrees, so `angle = 360` reads 0 and `361` reads 1;
//!   - a COLOUR keeps its alpha, because `color` and `alpha` are two
//!     views of one 32-bit value — writing the colour must not clear the
//!     transparency;
//!   - `alpha` is quantised to a BYTE, which is why 0.5 reads back as
//!     0.498039215686275;
//!   - `strength` is 8.8 fixed point clamped to 0..0xFF00, `quality`
//!     clamps to 0..15, and the blurs clamp to 0..255.
//!
//! State lives in a hidden sub-object rather than in the object's native
//! slot: `clone` is then a flat copy of it, and every filter class shares
//! one accessor pair driven by the table below.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/{bitmap,blur,glow,
//! drop_shadow,bevel,gradient,convolution,color_matrix,displacement_map}_filter.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const swf = @import("../../swf/swf.zig");
const decl = @import("decl.zig");
const geom = @import("geom.zig");
const bitmap_data = @import("bitmap_data.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

/// Where a filter keeps its state.
const STATE = "__filter";

/// How a property coerces on the way in and out.
const Kind = enum {
    /// A plain f64, unclamped.
    number,
    /// f64 clamped to 0..255 — the blurs.
    blur,
    /// Degrees in, radians stored, degrees out.
    angle,
    /// 0xRRGGBB. Stored apart from its alpha so writing one keeps the
    /// other.
    color,
    /// 0..1 quantised to a byte.
    alpha,
    /// i32 clamped to 0..15.
    quality,
    /// 8.8 fixed, clamped to 0..0xFF00.
    strength,
    /// i32, unclamped.
    int,
    boolean,
    /// A string from a fixed set, with a default when it matches none.
    bevel_type,
    /// `ColorMatrixFilter.matrix`: always exactly twenty numbers.
    color_matrix,
    /// A gradient filter's `colors` / `alphas` / `ratios`. Not three
    /// arrays — one list of records with three views onto it.
    gradient_colors,
    gradient_alphas,
    gradient_ratios,
    /// `ConvolutionFilter.matrix`: variable length, and never shorter
    /// than `matrixX * matrixY`.
    conv_matrix,
    /// `matrixX` / `matrixY`: 0..15, and each write re-pads the matrix.
    conv_dim,
    /// `DisplacementMapFilter.mapPoint`: an internal integer pair, read
    /// back as a fresh `flash.geom.Point`.
    map_point,
    /// A displacement scale: ±65535, through f32.
    scale,
    /// `DisplacementMapFilter.mode`, defaulting to `wrap`.
    displacement_mode,
    /// `DisplacementMapFilter.mapBitmap`: only a real BitmapData is
    /// accepted, and anything else leaves the old one in place.
    map_bitmap,
    /// Stored and returned as given.
    any,
};

const Prop = struct {
    name: []const u8,
    kind: Kind,
    /// The stored default, in STORAGE units (radians, bytes, 8.8 …).
    default: f64 = 0,
};

const Class = struct {
    name: []const u8,
    props: []const Prop,
};

/// ~45 degrees, the shared default for every angle.
const DEFAULT_ANGLE: f64 = 0.785398163;

const BLUR: []const Prop = &.{
    .{ .name = "blurX", .kind = .blur, .default = 4 },
    .{ .name = "blurY", .kind = .blur, .default = 4 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
};

const GLOW: []const Prop = &.{
    .{ .name = "color", .kind = .color, .default = 0xFF0000 },
    .{ .name = "alpha", .kind = .alpha, .default = 255 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
    .{ .name = "inner", .kind = .boolean, .default = 0 },
    .{ .name = "knockout", .kind = .boolean, .default = 0 },
    .{ .name = "blurX", .kind = .blur, .default = 6 },
    .{ .name = "blurY", .kind = .blur, .default = 6 },
    .{ .name = "strength", .kind = .strength, .default = 2 << 8 },
};

const DROP_SHADOW: []const Prop = &.{
    .{ .name = "distance", .kind = .number, .default = 4 },
    .{ .name = "angle", .kind = .angle, .default = DEFAULT_ANGLE },
    .{ .name = "color", .kind = .color, .default = 0 },
    .{ .name = "alpha", .kind = .alpha, .default = 255 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
    .{ .name = "inner", .kind = .boolean, .default = 0 },
    .{ .name = "knockout", .kind = .boolean, .default = 0 },
    .{ .name = "blurX", .kind = .blur, .default = 4 },
    .{ .name = "blurY", .kind = .blur, .default = 4 },
    .{ .name = "strength", .kind = .strength, .default = 1 << 8 },
    .{ .name = "hideObject", .kind = .boolean, .default = 0 },
};

const BEVEL: []const Prop = &.{
    .{ .name = "distance", .kind = .number, .default = 4 },
    .{ .name = "angle", .kind = .angle, .default = DEFAULT_ANGLE },
    .{ .name = "highlightColor", .kind = .color, .default = 0xFFFFFF },
    .{ .name = "highlightAlpha", .kind = .alpha, .default = 255 },
    .{ .name = "shadowColor", .kind = .color, .default = 0 },
    .{ .name = "shadowAlpha", .kind = .alpha, .default = 255 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
    .{ .name = "strength", .kind = .strength, .default = 1 << 8 },
    .{ .name = "knockout", .kind = .boolean, .default = 0 },
    .{ .name = "blurX", .kind = .blur, .default = 4 },
    .{ .name = "blurY", .kind = .blur, .default = 4 },
    .{ .name = "type", .kind = .bevel_type, .default = 0 },
};

const GRADIENT: []const Prop = &.{
    .{ .name = "distance", .kind = .number, .default = 4 },
    .{ .name = "angle", .kind = .angle, .default = DEFAULT_ANGLE },
    .{ .name = "colors", .kind = .gradient_colors },
    .{ .name = "alphas", .kind = .gradient_alphas },
    .{ .name = "ratios", .kind = .gradient_ratios },
    .{ .name = "blurX", .kind = .blur, .default = 4 },
    .{ .name = "blurY", .kind = .blur, .default = 4 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
    .{ .name = "strength", .kind = .strength, .default = 1 << 8 },
    .{ .name = "knockout", .kind = .boolean, .default = 0 },
    .{ .name = "type", .kind = .bevel_type, .default = 0 },
};

const CONVOLUTION: []const Prop = &.{
    .{ .name = "matrixX", .kind = .conv_dim, .default = 0 },
    .{ .name = "matrixY", .kind = .conv_dim, .default = 0 },
    .{ .name = "matrix", .kind = .conv_matrix },
    .{ .name = "divisor", .kind = .number, .default = 1 },
    .{ .name = "bias", .kind = .number, .default = 0 },
    .{ .name = "preserveAlpha", .kind = .boolean, .default = 1 },
    .{ .name = "clamp", .kind = .boolean, .default = 1 },
    .{ .name = "color", .kind = .color, .default = 0 },
    .{ .name = "alpha", .kind = .alpha, .default = 0 },
};

const COLOR_MATRIX: []const Prop = &.{
    .{ .name = "matrix", .kind = .color_matrix },
};

const DISPLACEMENT: []const Prop = &.{
    .{ .name = "mapBitmap", .kind = .map_bitmap },
    .{ .name = "mapPoint", .kind = .map_point },
    .{ .name = "componentX", .kind = .int, .default = 0 },
    .{ .name = "componentY", .kind = .int, .default = 0 },
    .{ .name = "scaleX", .kind = .scale, .default = 0 },
    .{ .name = "scaleY", .kind = .scale, .default = 0 },
    .{ .name = "mode", .kind = .displacement_mode, .default = 0 },
    .{ .name = "color", .kind = .color, .default = 0 },
    .{ .name = "alpha", .kind = .alpha, .default = 0 },
};

const CLASSES = [_]Class{
    .{ .name = "BitmapFilter", .props = &.{} },
    .{ .name = "DropShadowFilter", .props = DROP_SHADOW },
    .{ .name = "BlurFilter", .props = BLUR },
    .{ .name = "GlowFilter", .props = GLOW },
    .{ .name = "BevelFilter", .props = BEVEL },
    .{ .name = "GradientGlowFilter", .props = GRADIENT },
    .{ .name = "GradientBevelFilter", .props = GRADIENT },
    .{ .name = "ConvolutionFilter", .props = CONVOLUTION },
    .{ .name = "ColorMatrixFilter", .props = COLOR_MATRIX },
    .{ .name = "DisplacementMapFilter", .props = DISPLACEMENT },
};

pub fn install(vm: *Vm, flash_ns: ObjectHandle) !void {
    const filters = try decl.subObject(vm, flash_ns, "filters", .{});
    // BitmapFilter's prototype is the SUPER of every other filter's, so
    // `clone` is inherited rather than repeated.
    var base_proto: ObjectHandle = 0;
    inline for (CLASSES, 0..) |cls, cls_index| {
        const proto = try vm.objects.create();
        vm.objects.get(proto).proto = .{ .object = if (base_proto != 0)
            base_proto
        else
            vm.object_proto };
        if (base_proto == 0) {
            // ENUMERABLE, unlike almost every other native method: a
            // `for..in` over a filter lists `clone` alongside its
            // properties, which is how the corpus sees it.
            try decl.method(vm, proto, "clone", clone, ver(.{}, decl.V8));
            base_proto = proto;
        }
        inline for (cls.props) |p| {
            try decl.property(vm, proto, p.name, accessors(p).get, accessors(p).set, ver(.{}, decl.V8));
        }
        const ctor = try vm.newNativeFn(constructorFor(cls));
        try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, decl.hidden, false);
        try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, decl.hidden, false);
        try vm.objects.putWithAttrs(filters, S(cls.name), .{ .object = ctor }, .{}, false);
        if (comptime std.mem.eql(u8, cls.name, "ColorMatrixFilter")) vm.colormatrix_proto = proto;
        vm.filter_protos[cls_index] = proto;
    }
}

/// The state bag, created on demand so a filter built by `clone` — which
/// never runs a constructor — still has one.
fn stateOf(vm: *Vm, this: Value) ?ObjectHandle {
    if (this != .object) return null;
    const v = vm.objects.getChained(this.object, S(STATE), false) orelse return null;
    return if (v == .object) v.object else null;
}

fn constructorFor(comptime cls: Class) object_mod.NativeFn {
    return struct {
        fn ctor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            const vm = vmOf(p);
            if (this != .object) return this;
            // A SECOND construction on the same object changes nothing —
            // the native payload is already there. The arguments are
            // still evaluated, so a `valueOf` still runs and the corpus
            // still sees it (native_double_construct calls `super()`
            // twice and reads the FIRST call's numbers back).
            const already = vm.objects.findOwn(this.object, S(STATE), false) != null;
            const state = try vm.newObject();
            // Every property starts at its default and is then overwritten
            // by the matching constructor argument, in declaration order.
            if (comptime hasGradient(cls)) try gradInit(vm, state);
            inline for (cls.props, 0..) |prop, i| {
                if (comptime !isGradient(prop.kind)) {
                    try vm.objects.put(state, S(prop.name), try defaultOf(vm, prop), false);
                }
                if (i < args.len) try store(vm, state, prop, args[i]);
            }
            if (!already) {
                try vm.objects.putWithAttrs(this.object, S(STATE), .{ .object = state }, decl.frozen, false);
            }
            return this;
        }
    }.ctor;
}

fn hasGradient(comptime cls: Class) bool {
    for (cls.props) |p| if (isGradient(p.kind)) return true;
    return false;
}

/// A property's starting value. Everything is a number in storage units
/// except the colour matrix, whose default is the 4x5 IDENTITY — and
/// which a `null` or `undefined` constructor argument then leaves alone.
fn defaultOf(vm: *Vm, comptime p: Prop) !Value {
    // `mapBitmap` starts UNDEFINED, not zero — there is no bitmap yet.
    if (comptime p.kind == .map_bitmap) return .undefined_value;
    if (comptime p.kind == .conv_matrix) {
        const arr = try vm.newArray();
        try vm.setArrayLength(arr, 0);
        return .{ .object = arr };
    }
    if (p.kind != .color_matrix) return .{ .number = p.default };
    const arr = try vm.newArray();
    for (COLOR_MATRIX_IDENTITY, 0..) |n, i| {
        try vm.objects.put(arr, try indexName(vm, i), .{ .number = n }, false);
    }
    try vm.setArrayLength(arr, COLOR_MATRIX_LEN);
    return .{ .object = arr };
}

/// `clone` — a filter of the same class with the same state. A bare
/// `BitmapFilter` has nothing to clone and answers undefined.
fn clone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    return (try cloneFilter(vmOf(p), this)) orelse .undefined_value;
}

/// A filter of the same class holding the same state, or null when the
/// value is not a filter at all (a bare `BitmapFilter` has no state and
/// counts as one of those).
///
/// Array-valued state — a colour matrix, a convolution matrix, the
/// gradient records — is COPIED, not shared: two filters that alias one
/// array would write through each other.
pub fn cloneFilter(vm: *Vm, this: Value) !?Value {
    const state = stateOf(vm, this) orelse return null;
    if (vm.objects.get(state).props.items.len == 0) return null;
    const out = try vm.objects.create();
    vm.objects.get(out).proto = vm.objects.get(this.object).proto;
    const copy = try vm.newObject();
    const n = vm.objects.get(state).props.items.len;
    for (0..n) |i| {
        const prop = vm.objects.get(state).props.items[i];
        const v = if (prop.value == .object) try copyArray(vm, prop.value) else prop.value;
        try vm.objects.put(copy, prop.key, v, false);
    }
    try vm.objects.putWithAttrs(out, S(STATE), .{ .object = copy }, decl.frozen, false);
    return .{ .object = out };
}

fn accessors(comptime p: Prop) type {
    return struct {
        fn get(ptr: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            _ = args;
            const vm = vmOf(ptr);
            const state = stateOf(vm, this) orelse return .undefined_value;
            if (comptime isGradient(p.kind)) return gradView(vm, state, p.kind);
            if (comptime p.kind == .map_point) return loadMapPoint(vm, state);
            const raw = vm.objects.getChained(state, S(p.name), false) orelse
                return .undefined_value;
            return load(vm, p, raw);
        }
        fn set(ptr: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            const vm = vmOf(ptr);
            const state = stateOf(vm, this) orelse return .undefined_value;
            try store(vm, state, p, arg(args, 0));
            return .undefined_value;
        }
    };
}

/// Storage → script.
fn load(vm: *Vm, comptime p: Prop, raw: Value) !Value {
    const n = if (raw == .number) raw.number else 0;
    return switch (p.kind) {
        .angle => .{ .number = n * 180.0 / std.math.pi },
        .alpha => .{ .number = n / 255.0 },
        .strength => .{ .number = n / 256.0 },
        .boolean => .{ .boolean = n != 0 },
        .bevel_type => .{ .string = switch (@as(u2, @intFromFloat(@min(n, 2)))) {
            0 => S("inner"),
            1 => S("outer"),
            else => S("full"),
        } },
        // A FRESH array every read, like every other Flash accessor that
        // hands back a collection — mutating what you got does not reach
        // the filter.
        .color_matrix => blk: {
            if (raw != .object) break :blk .undefined_value;
            const out = try vm.newArray();
            for (0..COLOR_MATRIX_LEN) |i| {
                const got = vm.objects.getChained(raw.object, try indexName(vm, i), false) orelse
                    Value{ .number = std.math.nan(f64) };
                try vm.objects.put(out, try indexName(vm, i), got, false);
            }
            try vm.setArrayLength(out, COLOR_MATRIX_LEN);
            break :blk .{ .object = out };
        },
        .gradient_colors, .gradient_alphas, .gradient_ratios, .map_point => unreachable, // handled by the accessor
        .conv_matrix => try copyArray(vm, raw),
        .map_bitmap => raw,
        .displacement_mode => .{ .string = switch (@as(u2, @intFromFloat(std.math.clamp(n, 0, 3)))) {
            0 => S("wrap"),
            1 => S("clamp"),
            2 => S("ignore"),
            else => S("color"),
        } },
        .any => raw,
        else => .{ .number = n },
    };
}

const COLOR_MATRIX_LEN = 20;

// --- gradient records ---------------------------------------------------------
//
// A gradient filter does NOT hold three independent arrays. It holds one
// fixed list of sixteen (colour, alpha, ratio) records plus a count, and
// the three script properties are views onto its first `count` entries.
// The consequences are all observable: writing `colors` resizes the list
// but leaves the alphas and ratios that were already in those slots;
// writing `alphas` never resizes it; and writing `ratios` can only make
// it SHORTER.
const MAX_GRADIENT_COLORS = 16;
const GRAD_RGB = "__gradRgb";
const GRAD_ALPHA = "__gradAlpha";
const GRAD_RATIO = "__gradRatio";
const GRAD_COUNT = "__gradCount";

fn gradInit(vm: *Vm, state: ObjectHandle) !void {
    inline for (.{ GRAD_RGB, GRAD_ALPHA, GRAD_RATIO }) |key| {
        const arr = try vm.newArray();
        for (0..MAX_GRADIENT_COLORS) |i| {
            try vm.objects.put(arr, try indexName(vm, i), .{ .number = 0 }, false);
        }
        try vm.setArrayLength(arr, MAX_GRADIENT_COLORS);
        try vm.objects.put(state, S(key), .{ .object = arr }, false);
    }
    try vm.objects.put(state, S(GRAD_COUNT), .{ .number = 0 }, false);
}

fn gradBacking(vm: *Vm, state: ObjectHandle, comptime key: []const u8) ?ObjectHandle {
    const v = vm.objects.getChained(state, S(key), false) orelse return null;
    return if (v == .object) v.object else null;
}

fn gradCount(vm: *Vm, state: ObjectHandle) usize {
    const v = vm.objects.getChained(state, S(GRAD_COUNT), false) orelse return 0;
    if (v != .number) return 0;
    return @intFromFloat(std.math.clamp(v.number, 0, MAX_GRADIENT_COLORS));
}

fn gradSlot(vm: *Vm, state: ObjectHandle, comptime key: []const u8, i: usize) f64 {
    const arr = gradBacking(vm, state, key) orelse return 0;
    const v = vm.objects.getChained(arr, indexName(vm, i) catch return 0, false) orelse return 0;
    return if (v == .number) v.number else 0;
}

fn gradPut(vm: *Vm, state: ObjectHandle, comptime key: []const u8, i: usize, n: f64) !void {
    const arr = gradBacking(vm, state, key) orelse return;
    try vm.objects.put(arr, try indexName(vm, i), .{ .number = n }, false);
}

/// The `length` a setter sees. A STRING has one (and no elements, so its
/// entries read as zero); a plain number or boolean has none.
fn lengthOf(vm: *Vm, v: Value) !i64 {
    return switch (v) {
        .object => |h| value_mod.toInt32(try vm.toNumber(
            vm.objects.getChained(h, S("length"), false) orelse Value{ .number = 0 },
        )),
        .string => |str| @intCast(str.len),
        else => 0,
    };
}

fn elementOf(vm: *Vm, v: Value, i: usize) !Value {
    if (v != .object) return .undefined_value;
    return vm.objects.getChained(v.object, try indexName(vm, i), false) orelse .undefined_value;
}

fn gradView(vm: *Vm, state: ObjectHandle, comptime kind: Kind) !Value {
    const n = gradCount(vm, state);
    const out = try vm.newArray();
    for (0..n) |i| {
        const value: f64 = switch (kind) {
            .gradient_colors => gradSlot(vm, state, GRAD_RGB, i),
            .gradient_alphas => gradSlot(vm, state, GRAD_ALPHA, i) / 255.0,
            else => gradSlot(vm, state, GRAD_RATIO, i),
        };
        try vm.objects.put(out, try indexName(vm, i), .{ .number = value }, false);
    }
    try vm.setArrayLength(out, @intCast(n));
    return .{ .object = out };
}

// --- convolution matrix -------------------------------------------------------

const CONV_MAX_DIM = 15;

/// The matrix is only ever GROWN to `matrixX * matrixY`, never trimmed —
/// shrinking either dimension leaves the extra entries in place, and the
/// next growth reuses them.
fn convResize(vm: *Vm, state: ObjectHandle) !void {
    const arr = switch (vm.objects.getChained(state, S("matrix"), false) orelse return) {
        .object => |h| h,
        else => return,
    };
    const want: usize = @intFromFloat(numProp(vm, state, "matrixX") * numProp(vm, state, "matrixY"));
    const have: usize = @intCast(@max(value_mod.toInt32(try vm.toNumber(
        vm.objects.getChained(arr, S("length"), false) orelse Value{ .number = 0 },
    )), 0));
    if (want <= have) return;
    for (have..want) |i| {
        try vm.objects.put(arr, try indexName(vm, i), .{ .number = 0 }, false);
    }
    try vm.setArrayLength(arr, @intCast(want));
}

fn numProp(vm: *Vm, state: ObjectHandle, comptime name: []const u8) f64 {
    const v = vm.objects.getChained(state, S(name), false) orelse return 0;
    return if (v == .number) v.number else 0;
}

/// Every entry rounds through f32 and a missing one is NaN, so a STRING
/// — which has a length but no elements — fills the matrix with NaN.
fn convStoreMatrix(vm: *Vm, state: ObjectHandle, v: Value) !void {
    const len_raw = try lengthOf(vm, v);
    const len: usize = @intCast(@max(len_raw, 0));
    const arr = try vm.newArray();
    for (0..len) |i| {
        const n: f64 = @floatCast(@as(f32, @floatCast(try vm.toNumber(try elementOf(vm, v, i)))));
        try vm.objects.put(arr, try indexName(vm, i), .{ .number = n }, false);
    }
    try vm.setArrayLength(arr, @intCast(len));
    try vm.objects.put(state, S("matrix"), .{ .object = arr }, false);
    try convResize(vm, state);
}

/// A fresh copy every read.
fn copyArray(vm: *Vm, raw: Value) !Value {
    if (raw != .object) return .undefined_value;
    const len: usize = @intCast(@max(value_mod.toInt32(try vm.toNumber(
        vm.objects.getChained(raw.object, S("length"), false) orelse Value{ .number = 0 },
    )), 0));
    const out = try vm.newArray();
    for (0..len) |i| {
        const key = try indexName(vm, i);
        try vm.objects.put(out, key, vm.objects.getChained(raw.object, key, false) orelse .undefined_value, false);
    }
    try vm.setArrayLength(out, @intCast(len));
    return .{ .object = out };
}

// --- displacement map ---------------------------------------------------------

const MAP_POINT_X = "__mapX";
const MAP_POINT_Y = "__mapY";

/// A point with BOTH coordinates present, or the origin. They are read as
/// OWN properties — an inherited `x` does not make an object a point —
/// and a non-object resets it rather than being ignored.
/// The point is STORED even when reading it throws — a component whose
/// coercion threw lands as i32::MIN, the pair is written, and only then
/// does the throw carry on. Ruffle: "propagate possible errors, the
/// value is set regardless of those"
/// (corpus displacementmapfilter_mappoint_throw_error).
fn storeMapPoint(vm: *Vm, state: ObjectHandle, v: Value) !void {
    var x: f64 = 0;
    var y: f64 = 0;
    var ex: ?anyerror = null;
    var ey: ?anyerror = null;
    var thrown: ?anyerror = null;
    if (v == .object) {
        // The STORED value, own or inherited — an accessor is not run.
        const gx = vm.objects.getChained(v.object, S("x"), vm.case_sensitive);
        const gy = vm.objects.getChained(v.object, S("y"), vm.case_sensitive);
        // Each is coerced whether or not the other is there; the POINT
        // is only written when both are.
        const cx = if (gx) |g| component(vm, g, &ex) else 0;
        const vx = vm.pending_throw;
        const cy = if (gy) |g| component(vm, g, &ey) else 0;
        const vy = vm.pending_throw;
        if (gx != null and gy != null) {
            x = cx;
            y = cy;
        }
        // X's error wins, and its THROWN VALUE has to be put back — the
        // second coercion has already overwritten it.
        if (ex) |e| {
            thrown = e;
            vm.pending_throw = vx;
        } else if (ey) |e| {
            thrown = e;
            vm.pending_throw = vy;
        }
    }
    try vm.objects.put(state, S(MAP_POINT_X), .{ .number = x }, false);
    try vm.objects.put(state, S(MAP_POINT_Y), .{ .number = y }, false);
    if (thrown) |e| return e;
}

fn component(vm: *Vm, v: Value, thrown: *?anyerror) f64 {
    const n = vm.toNumberThrowing(v) catch |e| {
        if (thrown.* == null) thrown.* = e;
        return @floatFromInt(std.math.minInt(i32));
    };
    return @floatFromInt(value_mod.toInt32(n));
}

fn loadMapPoint(vm: *Vm, state: ObjectHandle) !Value {
    return geom.newPoint(vm, numProp(vm, state, MAP_POINT_X), numProp(vm, state, MAP_POINT_Y));
}

const DISPLACEMENT_MODES = [_][]const u8{ "wrap", "clamp", "ignore", "color" };

/// Rounds to nearest and SATURATES, so 1.5 is opaque and -0.5 is clear.
fn alphaByte(a: f64) f64 {
    if (!std.math.isFinite(a)) return 255;
    return std.math.clamp(@trunc(255.0 * a + 0.5), 0, 255);
}

fn gradStore(vm: *Vm, state: ObjectHandle, comptime kind: Kind, v: Value) !void {
    switch (kind) {
        .gradient_colors => {
            const len = try lengthOf(vm, v);
            const n: usize = @intCast(std.math.clamp(len, 0, MAX_GRADIENT_COLORS));
            try vm.objects.put(state, S(GRAD_COUNT), .{ .number = @floatFromInt(n) }, false);
            for (0..n) |i| {
                const rgb: u32 = @bitCast(value_mod.toInt32(try vm.toNumber(try elementOf(vm, v, i))));
                try gradPut(vm, state, GRAD_RGB, i, @floatFromInt(rgb & 0x00FF_FFFF));
            }
        },
        // Only a real object counts, and the count never moves. A slot
        // past the end of what was handed over becomes OPAQUE.
        .gradient_alphas => {
            if (v != .object) return;
            const len = try lengthOf(vm, v);
            for (0..gradCount(vm, state)) |i| {
                const a: f64 = if (@as(i64, @intCast(i)) < len)
                    alphaByte(try vm.toNumber(try elementOf(vm, v, i)))
                else
                    255;
                try gradPut(vm, state, GRAD_ALPHA, i, a);
            }
        },
        else => {
            if (v != .object) return;
            const len = try lengthOf(vm, v);
            const n = @min(@as(usize, @intCast(std.math.clamp(len, 0, MAX_GRADIENT_COLORS))), gradCount(vm, state));
            try vm.objects.put(state, S(GRAD_COUNT), .{ .number = @floatFromInt(n) }, false);
            for (0..n) |i| {
                const r = value_mod.toInt32(try vm.toNumber(try elementOf(vm, v, i)));
                try gradPut(vm, state, GRAD_RATIO, i, @floatFromInt(std.math.clamp(r, 0, 255)));
            }
        },
    }
}

/// The 4x5 identity: each channel takes itself and nothing else.
const COLOR_MATRIX_IDENTITY = [COLOR_MATRIX_LEN]f64{
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
};

fn indexName(vm: *Vm, i: usize) !strings.AvmString {
    var buf: [16]u8 = undefined;
    const ascii = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    const wide = try vm.arena().alloc(u16, ascii.len);
    for (ascii, wide) |c, *w| w.* = c;
    return wide;
}

/// Normalise whatever script offered into exactly twenty numbers.
///
/// Three different answers, none of them obvious: `null` and `undefined`
/// leave the matrix ALONE, any other non-object wipes it to NaN, and an
/// object is read element by element with NaN past its `length`. Entries
/// round through f32, which is visible in the traced values.
fn storeColorMatrix(vm: *Vm, state: ObjectHandle, v: Value) !void {
    if (v == .null_value or v == .undefined_value) return;

    const arr = try vm.newArray();
    if (v == .object) {
        const len = value_mod.toInt32(try vm.toNumber(
            vm.objects.getChained(v.object, S("length"), false) orelse Value{ .number = 0 },
        ));
        for (0..COLOR_MATRIX_LEN) |i| {
            var n = std.math.nan(f64);
            if (@as(i64, @intCast(i)) < len) {
                if (vm.objects.getChained(v.object, try indexName(vm, i), false)) |got| {
                    n = @floatCast(@as(f32, @floatCast(try vm.toNumber(got))));
                }
            }
            try vm.objects.put(arr, try indexName(vm, i), .{ .number = n }, false);
        }
    } else {
        for (0..COLOR_MATRIX_LEN) |i| {
            try vm.objects.put(arr, try indexName(vm, i), .{ .number = std.math.nan(f64) }, false);
        }
    }
    try vm.setArrayLength(arr, COLOR_MATRIX_LEN);
    try vm.objects.put(state, S("matrix"), .{ .object = arr }, false);
}

/// Script → storage.
fn isGradient(k: Kind) bool {
    return k == .gradient_colors or k == .gradient_alphas or k == .gradient_ratios;
}

fn store(vm: *Vm, state: ObjectHandle, comptime p: Prop, v: Value) !void {
    if (p.kind == .color_matrix) return storeColorMatrix(vm, state, v);
    if (comptime isGradient(p.kind)) return gradStore(vm, state, p.kind, v);
    if (comptime p.kind == .conv_matrix) return convStoreMatrix(vm, state, v);
    if (comptime p.kind == .map_point) return storeMapPoint(vm, state, v);
    // Silently KEEPS the previous bitmap rather than storing the value.
    if (comptime p.kind == .map_bitmap) {
        if (bitmap_data.dataOf(vm, v) == null) return;
        return vm.objects.put(state, S(p.name), v, false);
    }
    const stored: Value = switch (p.kind) {
        .color_matrix, .conv_matrix, .map_point, .map_bitmap => unreachable, // handled above
        .gradient_colors, .gradient_alphas, .gradient_ratios => unreachable,
        .conv_dim => .{ .number = @floatFromInt(std.math.clamp(value_mod.toInt32(try vm.toNumber(v)), 0, CONV_MAX_DIM)) },
        // ±65535 through f32, and a NaN clamps rather than passing.
        .scale => blk: {
            const n = try vm.toNumber(v);
            const c: f64 = if (std.math.isNan(n)) 65535 else std.math.clamp(n, -65535, 65535);
            break :blk .{ .number = @floatCast(@as(f32, @floatCast(c))) };
        },
        // Case SENSITIVE, and anything else is `wrap`.
        .displacement_mode => blk: {
            const str = try vm.toStringValue(v);
            var idx: f64 = 0;
            inline for (DISPLACEMENT_MODES, 0..) |name, i| {
                if (strings.eql(str, S(name))) idx = @floatFromInt(i);
            }
            break :blk .{ .number = idx };
        },
        .any => v,
        .boolean => .{ .number = if (value_mod.toBoolean(v, vm.swf_version)) 1 else 0 },
        // Case SENSITIVE, and anything unrecognised is `full` rather than
        // the constructor's own default — "INNER" is not "inner".
        .bevel_type => blk: {
            const s = try vm.toStringValue(v);
            break :blk .{ .number = if (strings.eql(s, S("inner")))
                0
            else if (strings.eql(s, S("outer")))
                1
            else
                2 };
        },
        // The remainder KEEPS ITS SIGN: -1 stays -1 rather than becoming
        // 359. Only whole turns come off.
        .angle => blk: {
            const d = try vm.toNumber(v);
            break :blk .{ .number = @rem(d, 360.0) * std.math.pi / 180.0 };
        },
        .alpha => blk: {
            const a = (try vm.toNumber(v)) * 255.0;
            break :blk .{ .number = @floor(std.math.clamp(a, 0, 255)) };
        },
        .strength => blk: {
            const s = (try vm.toNumber(v)) * 256.0;
            break :blk .{ .number = @floor(std.math.clamp(s, 0, 0xFF00)) };
        },
        .quality => .{ .number = @floatFromInt(std.math.clamp(value_mod.toInt32(try vm.toNumber(v)), 0, 15)) },
        .blur => .{ .number = std.math.clamp(try vm.toNumber(v), 0, 255) },
        .color => .{ .number = @floatFromInt(@as(u32, @bitCast(value_mod.toInt32(try vm.toNumber(v)))) & 0x00FF_FFFF) },
        .int => .{ .number = @floatFromInt(value_mod.toInt32(try vm.toNumber(v))) },
        .number => .{ .number = try vm.toNumber(v) },
    };
    try vm.objects.put(state, S(p.name), stored, false);
    if (comptime p.kind == .conv_dim) try convResize(vm, state);
}

/// Is this value a filter? A display object's `filters` setter keeps only
/// the elements that are, which is what makes a stray number vanish.
pub fn isFilter(vm: *Vm, v: Value) bool {
    return stateOf(vm, v) != null;
}

/// The twenty numbers of a `ColorMatrixFilter`, or null when the value is
/// not one. `applyFilter` is the only caller: it needs to tell a real
/// filter from a duck-typed object, and a matrix that is not twenty long
/// is not a filter Flash will apply.
///
/// Row-major, four rows of five: `out_i = m[i*5+0]*r + …[3]*a + m[i*5+4]`.
pub fn colorMatrixOf(vm: *Vm, v: Value) ?[20]f64 {
    if (v != .object) return null;
    var proto = vm.objects.get(v.object).proto;
    var guard: u8 = 0;
    const is_cmf = while (proto == .object and guard < 64) : (guard += 1) {
        if (proto.object == vm.colormatrix_proto) break true;
        proto = vm.objects.get(proto.object).proto;
    } else false;
    if (!is_cmf) return null;

    const state = stateOf(vm, v) orelse return null;
    const stored = vm.objects.getChained(state, S("matrix"), false) orelse return null;
    if (stored != .object) return null;

    var out: [20]f64 = @splat(0);
    for (&out, 0..) |*slot, i| {
        var buf: [8]u8 = undefined;
        const ascii = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        var wide: [8]u16 = undefined;
        for (ascii, wide[0..ascii.len]) |c, *w| w.* = c;
        const got = vm.objects.getChained(stored.object, wide[0..ascii.len], false) orelse return null;
        slot.* = vm.toNumber(got) catch return null;
    }
    return out;
}

// --- from a PlaceObject3 record -----------------------------------------------

/// Class indices into `CLASSES`, so a tag record can find its prototype
/// without a constructor to call.
const IDX_DROP_SHADOW = 1;
const IDX_BLUR = 2;
const IDX_GLOW = 3;
const IDX_BEVEL = 4;
const IDX_GRADIENT_GLOW = 5;
const IDX_GRADIENT_BEVEL = 6;
const IDX_CONVOLUTION = 7;
const IDX_COLOR_MATRIX = 8;

fn fixed16(n: i32) f64 {
    return @as(f64, @floatFromInt(n)) / 65536.0;
}

/// The engine packs a colour ABGR (red in the low byte, matching the
/// file's byte order); script reads 0xRRGGBB. Red and blue swap.
fn rgbOf(c: u32) f64 {
    const r = c & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = (c >> 16) & 0xFF;
    return @floatFromInt((r << 16) | (g << 8) | b);
}

fn alphaOf(c: u32) f64 {
    return @floatFromInt((c >> 24) & 0xFF);
}

fn newFilterObject(vm: *Vm, comptime index: usize) !struct { Value, ObjectHandle } {
    const out = try vm.objects.create();
    vm.objects.get(out).proto = .{ .object = vm.filter_protos[index] };
    const state = try vm.newObject();
    try vm.objects.putWithAttrs(out, S(STATE), .{ .object = state }, decl.frozen, false);
    inline for (CLASSES[index].props) |prop| {
        if (comptime !isGradient(prop.kind)) {
            try vm.objects.put(state, S(prop.name), try defaultOf(vm, prop), false);
        }
    }
    if (comptime hasGradient(CLASSES[index])) try gradInit(vm, state);
    return .{ .{ .object = out }, state };
}

fn put(vm: *Vm, state: ObjectHandle, comptime name: []const u8, n: f64) !void {
    try vm.objects.put(state, S(name), .{ .number = n }, false);
}

/// One PlaceObject3 filter record as the script object a `filters` read
/// hands back.
///
/// Every field converts here: lengths and the ANGLE (already in radians)
/// out of Fixed16, strength kept as its raw 8.8, the pass count out of
/// the flags byte — which for a bevel or gradient is four bits rather
/// than five, because `onTop` took one.
pub fn fromTag(vm: *Vm, f: swf.filters.Filter) !Value {
    const sf = swf.filters;
    switch (f) {
        .drop_shadow => |d| {
            const made = try newFilterObject(vm, IDX_DROP_SHADOW);
            const st = made[1];
            try put(vm, st, "distance", fixed16(d.distance));
            try put(vm, st, "angle", fixed16(d.angle));
            try put(vm, st, "color", rgbOf(d.color));
            try put(vm, st, "alpha", alphaOf(d.color));
            try put(vm, st, "quality", @floatFromInt(sf.passesOf(d.flags)));
            try put(vm, st, "inner", if ((d.flags & sf.INNER_SHADOW) != 0) 1 else 0);
            try put(vm, st, "knockout", if ((d.flags & sf.KNOCKOUT) != 0) 1 else 0);
            try put(vm, st, "blurX", fixed16(d.blur_x));
            try put(vm, st, "blurY", fixed16(d.blur_y));
            try put(vm, st, "strength", @floatFromInt(d.strength));
            // `hideObject` is the INVERSE of the tag's composite-source
            // bit, not a flag of its own.
            try put(vm, st, "hideObject", if ((d.flags & sf.COMPOSITE_SOURCE) != 0) 0 else 1);
            return made[0];
        },
        .blur => |b| {
            const made = try newFilterObject(vm, IDX_BLUR);
            const st = made[1];
            try put(vm, st, "blurX", fixed16(b.blur_x));
            try put(vm, st, "blurY", fixed16(b.blur_y));
            try put(vm, st, "quality", @floatFromInt(sf.blurPassesOf(b.flags)));
            return made[0];
        },
        .glow => |g| {
            const made = try newFilterObject(vm, IDX_GLOW);
            const st = made[1];
            try put(vm, st, "color", rgbOf(g.color));
            try put(vm, st, "alpha", alphaOf(g.color));
            try put(vm, st, "quality", @floatFromInt(sf.passesOf(g.flags)));
            try put(vm, st, "inner", if ((g.flags & sf.INNER_SHADOW) != 0) 1 else 0);
            try put(vm, st, "knockout", if ((g.flags & sf.KNOCKOUT) != 0) 1 else 0);
            try put(vm, st, "blurX", fixed16(g.blur_x));
            try put(vm, st, "blurY", fixed16(g.blur_y));
            try put(vm, st, "strength", @floatFromInt(g.strength));
            return made[0];
        },
        .bevel => |b| {
            const made = try newFilterObject(vm, IDX_BEVEL);
            const st = made[1];
            try put(vm, st, "distance", fixed16(b.distance));
            try put(vm, st, "angle", fixed16(b.angle));
            try put(vm, st, "highlightColor", rgbOf(b.highlight_color));
            try put(vm, st, "highlightAlpha", alphaOf(b.highlight_color));
            try put(vm, st, "shadowColor", rgbOf(b.shadow_color));
            try put(vm, st, "shadowAlpha", alphaOf(b.shadow_color));
            try put(vm, st, "quality", @floatFromInt(sf.bevelPassesOf(b.flags)));
            try put(vm, st, "strength", @floatFromInt(b.strength));
            try put(vm, st, "knockout", if ((b.flags & sf.KNOCKOUT) != 0) 1 else 0);
            try put(vm, st, "blurX", fixed16(b.blur_x));
            try put(vm, st, "blurY", fixed16(b.blur_y));
            try put(vm, st, "type", bevelTypeOf(b.flags));
            return made[0];
        },
        .gradient_glow => |g| return gradientFromTag(vm, IDX_GRADIENT_GLOW, g),
        .gradient_bevel => |g| return gradientFromTag(vm, IDX_GRADIENT_BEVEL, g),
        .convolution => |c| {
            const made = try newFilterObject(vm, IDX_CONVOLUTION);
            const st = made[1];
            try put(vm, st, "matrixX", @floatFromInt(c.cols));
            try put(vm, st, "matrixY", @floatFromInt(c.rows));
            const arr = try vm.newArray();
            for (c.matrix, 0..) |x, i| {
                try vm.objects.put(arr, try indexName(vm, i), .{ .number = @floatCast(x) }, false);
            }
            try vm.setArrayLength(arr, @intCast(c.matrix.len));
            try vm.objects.put(st, S("matrix"), .{ .object = arr }, false);
            try put(vm, st, "divisor", @floatCast(c.divisor));
            try put(vm, st, "bias", @floatCast(c.bias));
            try put(vm, st, "preserveAlpha", if ((c.flags & sf.CONV_PRESERVE_ALPHA) != 0) 1 else 0);
            try put(vm, st, "clamp", if ((c.flags & sf.CONV_CLAMP) != 0) 1 else 0);
            try put(vm, st, "color", rgbOf(c.default_color));
            try put(vm, st, "alpha", alphaOf(c.default_color));
            return made[0];
        },
        .color_matrix => |c| {
            const made = try newFilterObject(vm, IDX_COLOR_MATRIX);
            const arr = try vm.newArray();
            for (c.matrix, 0..) |x, i| {
                try vm.objects.put(arr, try indexName(vm, i), .{ .number = @floatCast(x) }, false);
            }
            try vm.setArrayLength(arr, COLOR_MATRIX_LEN);
            try vm.objects.put(made[1], S("matrix"), .{ .object = arr }, false);
            return made[0];
        },
    }
}

/// `onTop` wins over `inner`, and neither means `outer`.
fn bevelTypeOf(flags: u8) f64 {
    const sf = swf.filters;
    if ((flags & sf.ON_TOP) != 0) return 2;
    if ((flags & sf.INNER_SHADOW) != 0) return 0;
    return 1;
}

fn gradientFromTag(vm: *Vm, comptime index: usize, g: swf.filters.Filter.Gradient) !Value {
    const sf = swf.filters;
    const made = try newFilterObject(vm, index);
    const st = made[1];
    const n = @min(g.colors.len, MAX_GRADIENT_COLORS);
    try vm.objects.put(st, S(GRAD_COUNT), .{ .number = @floatFromInt(n) }, false);
    for (g.colors[0..n], 0..) |rec, i| {
        try gradPut(vm, st, GRAD_RGB, i, rgbOf(rec.color));
        try gradPut(vm, st, GRAD_ALPHA, i, alphaOf(rec.color));
        try gradPut(vm, st, GRAD_RATIO, i, @floatFromInt(rec.ratio));
    }
    try put(vm, st, "distance", fixed16(g.distance));
    try put(vm, st, "angle", fixed16(g.angle));
    try put(vm, st, "blurX", fixed16(g.blur_x));
    try put(vm, st, "blurY", fixed16(g.blur_y));
    try put(vm, st, "quality", @floatFromInt(sf.bevelPassesOf(g.flags)));
    try put(vm, st, "strength", @floatFromInt(g.strength));
    try put(vm, st, "knockout", if ((g.flags & sf.KNOCKOUT) != 0) 1 else 0);
    try put(vm, st, "type", bevelTypeOf(g.flags));
    return made[0];
}

/// ASnative category 1109: ConvolutionFilter. Index 0 is the
/// constructor and the rest run getter/setter in declaration order —
/// `alpha`'s getter is 17 because it is the ninth property.
pub fn convolutionMethod(p: *anyopaque, this: Value, args: []const Value, index: u16) anyerror!Value {
    const CLS = CLASSES[7];
    comptime std.debug.assert(std.mem.eql(u8, CLS.name, "ConvolutionFilter"));
    if (index == 0) return constructorFor(CLS)(p, this, args);
    const slot = (index - 1) / 2;
    const is_set = (index % 2) == 0;
    inline for (CONVOLUTION, 0..) |prop, i| {
        if (i == slot) {
            const acc = accessors(prop);
            return if (is_set) acc.set(p, this, args) else acc.get(p, this, args);
        }
    }
    return .undefined_value;
}
