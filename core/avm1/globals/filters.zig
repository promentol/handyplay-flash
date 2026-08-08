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
const decl = @import("decl.zig");

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
    .{ .name = "colors", .kind = .any },
    .{ .name = "alphas", .kind = .any },
    .{ .name = "ratios", .kind = .any },
    .{ .name = "blurX", .kind = .blur, .default = 4 },
    .{ .name = "blurY", .kind = .blur, .default = 4 },
    .{ .name = "quality", .kind = .quality, .default = 1 },
    .{ .name = "strength", .kind = .strength, .default = 1 << 8 },
    .{ .name = "knockout", .kind = .boolean, .default = 0 },
    .{ .name = "type", .kind = .bevel_type, .default = 0 },
};

const CONVOLUTION: []const Prop = &.{
    .{ .name = "matrixX", .kind = .int, .default = 0 },
    .{ .name = "matrixY", .kind = .int, .default = 0 },
    .{ .name = "matrix", .kind = .any },
    .{ .name = "divisor", .kind = .number, .default = 1 },
    .{ .name = "bias", .kind = .number, .default = 0 },
    .{ .name = "preserveAlpha", .kind = .boolean, .default = 1 },
    .{ .name = "clamp", .kind = .boolean, .default = 1 },
    .{ .name = "color", .kind = .color, .default = 0 },
    .{ .name = "alpha", .kind = .alpha, .default = 0 },
};

const COLOR_MATRIX: []const Prop = &.{
    .{ .name = "matrix", .kind = .any },
};

const DISPLACEMENT: []const Prop = &.{
    .{ .name = "mapBitmap", .kind = .any },
    .{ .name = "mapPoint", .kind = .any },
    .{ .name = "componentX", .kind = .int, .default = 0 },
    .{ .name = "componentY", .kind = .int, .default = 0 },
    .{ .name = "scaleX", .kind = .number, .default = 0 },
    .{ .name = "scaleY", .kind = .number, .default = 0 },
    .{ .name = "mode", .kind = .any },
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
    inline for (CLASSES) |cls| {
        const proto = try vm.objects.create();
        vm.objects.get(proto).proto = .{ .object = if (base_proto != 0)
            base_proto
        else
            vm.object_proto };
        if (base_proto == 0) {
            try decl.method(vm, proto, "clone", clone, ver(decl.hidden, decl.V8));
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
            const state = try vm.newObject();
            try vm.objects.putWithAttrs(this.object, S(STATE), .{ .object = state }, decl.frozen, false);
            // Every property starts at its default and is then overwritten
            // by the matching constructor argument, in declaration order.
            inline for (cls.props, 0..) |prop, i| {
                try vm.objects.put(state, S(prop.name), .{ .number = prop.default }, false);
                if (i < args.len) try store(vm, state, prop, args[i]);
            }
            return this;
        }
    }.ctor;
}

/// `clone` — a filter of the same class with the same state. A bare
/// `BitmapFilter` has nothing to clone and answers undefined.
fn clone(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const state = stateOf(vm, this) orelse return .undefined_value;
    if (vm.objects.get(state).props.items.len == 0) return .undefined_value;
    const out = try vm.objects.create();
    vm.objects.get(out).proto = vm.objects.get(this.object).proto;
    const copy = try vm.newObject();
    for (vm.objects.get(state).props.items) |prop| {
        try vm.objects.put(copy, prop.key, prop.value, false);
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
            const raw = vm.objects.getChained(state, S(p.name), false) orelse
                return .undefined_value;
            return load(p, raw);
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
fn load(comptime p: Prop, raw: Value) Value {
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
        .any => raw,
        else => .{ .number = n },
    };
}

/// Script → storage.
fn store(vm: *Vm, state: ObjectHandle, comptime p: Prop, v: Value) !void {
    const stored: Value = switch (p.kind) {
        .any => v,
        .boolean => .{ .number = if (value_mod.toBoolean(v, vm.swf_version)) 1 else 0 },
        .bevel_type => blk: {
            const s = try vm.toStringValue(v);
            break :blk .{ .number = if (strings.eqlIgnoreCase(s, S("outer")))
                1
            else if (strings.eqlIgnoreCase(s, S("full")))
                2
            else
                0 };
        },
        .angle => blk: {
            const d = try vm.toNumber(v);
            break :blk .{ .number = @mod(d, 360.0) * std.math.pi / 180.0 };
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
