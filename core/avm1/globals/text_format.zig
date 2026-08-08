//! The AVM1 `TextFormat` class.
//!
//! Nineteen properties, every one of them TRI-STATE: `null`/`undefined` in
//! stores "unset", and an unset property reads back as `null` with a
//! `typeof` of `"null"`. Corpus `text_format` traces that for all of them.
//!
//! The numeric coercions are version-dependent and pinned by
//! `text_format_rounding_swf7` / `_swf8`: below SWF8 a value goes through
//! ToInt32, from SWF8 on it is rounded HALF TO EVEN. Margins, indent and
//! leading additionally clamp at zero below SWF8 (and margins clamp at
//! both versions).
//!
//! Reference: reference/ruffle/core/src/avm1/globals/text_format.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const format = @import("../../text/format.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const TextFormat = format.TextFormat;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const hidden = decl.hidden;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.textformat_proto = proto;

    // Declaration ORDER is an ABI: enumeration is reverse-insertion, and
    // the corpus prints the whole prototype.
    try decl.method(vm, proto, "getTextExtent", getTextExtent, hidden);
    try prop(vm, proto, "font", getFont, setFont);
    try prop(vm, proto, "size", getSize, setSize);
    try prop(vm, proto, "color", getColor, setColor);
    try prop(vm, proto, "url", getUrl, setUrl);
    try prop(vm, proto, "target", getTarget, setTarget);
    try prop(vm, proto, "bold", getBold, setBold);
    try prop(vm, proto, "italic", getItalic, setItalic);
    try prop(vm, proto, "underline", getUnderline, setUnderline);
    try prop(vm, proto, "align", getAlign, setAlign);
    try prop(vm, proto, "leftMargin", getLeftMargin, setLeftMargin);
    try prop(vm, proto, "rightMargin", getRightMargin, setRightMargin);
    try prop(vm, proto, "indent", getIndent, setIndent);
    try prop(vm, proto, "leading", getLeading, setLeading);
    try prop(vm, proto, "blockIndent", getBlockIndent, setBlockIndent);
    try prop(vm, proto, "tabStops", getTabStops, setTabStops);
    try prop(vm, proto, "bullet", getBullet, setBullet);
    try prop(vm, proto, "display", getDisplay, setDisplay);
    try prop(vm, proto, "kerning", getKerning, setKerning);
    try prop(vm, proto, "letterSpacing", getLetterSpacing, setLetterSpacing);

    _ = try decl.class(vm, "TextFormat", construct, proto, hidden);
}

/// Every TextFormat property is a plain enumerable accessor — ruffle's
/// table carries no attribute flags on them at all.
fn prop(
    vm: *Vm,
    target: ObjectHandle,
    comptime name: []const u8,
    get: object_mod.NativeFn,
    set: object_mod.NativeFn,
) !void {
    try decl.property(vm, target, name, get, set, .{});
}

/// `new TextFormat(font, size, color, bold, italic, underline, url,
/// target, align, leftMargin, rightMargin, indent, leading)`.
fn construct(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const tf = try attach(vm, this.object);
    try applyFont(vm, tf, arg(args, 0));
    // The CONSTRUCTOR coerces its numbers with a plain ToInt32 — no
    // version split and no clamping, unlike the setters of the same
    // properties (ruffle `get_arg_as_i32`).
    tf.size = try ctorInt(vm, arg(args, 1));
    try applyColor(vm, tf, arg(args, 2));
    tf.bold = optBool(vm, arg(args, 3));
    tf.italic = optBool(vm, arg(args, 4));
    tf.underline = optBool(vm, arg(args, 5));
    tf.url = try optString(vm, arg(args, 6));
    tf.target = try optString(vm, arg(args, 7));
    try applyAlign(vm, tf, arg(args, 8));
    tf.left_margin = try ctorInt(vm, arg(args, 9));
    tf.right_margin = try ctorInt(vm, arg(args, 10));
    tf.indent = try ctorInt(vm, arg(args, 11));
    tf.leading = try ctorInt(vm, arg(args, 12));
    return this;
}

/// The format behind a TextFormat object, created on construction and
/// owned by the VM arena.
fn ctorInt(vm: *Vm, v: Value) !?f64 {
    if (isUnset(v)) return null;
    return @floatFromInt(value_mod.toInt32(try vm.toNumber(v)));
}

fn attach(vm: *Vm, h: ObjectHandle) !*TextFormat {
    const tf = try vm.arena().create(TextFormat);
    tf.* = format.defaultFormat();
    vm.objects.get(h).native = .{ .text_format = tf };
    return tf;
}

/// A fresh `TextFormat` object carrying a COPY of `tf` — what
/// `getTextFormat` and `getNewTextFormat` hand back. The copy matters:
/// mutating the returned object must not reach back into the field.
pub fn newObject(vm: *Vm, tf: TextFormat) !ObjectHandle {
    const h = try vm.objects.create();
    vm.objects.get(h).proto = .{ .object = vm.textformat_proto };
    const owned = try attach(vm, h);
    owned.* = tf;
    return h;
}

/// The receiver's format, or null when `this` is not a TextFormat (a read
/// on the prototype itself, say).
pub fn formatOf(vm: *Vm, this: Value) ?*TextFormat {
    if (this != .object) return null;
    return switch (vm.objects.get(this.object).native) {
        .text_format => |tf| @ptrCast(@alignCast(tf)),
        else => null,
    };
}

// --- coercions ----------------------------------------------------------------

fn isUnset(v: Value) bool {
    return v == .undefined_value or v == .null_value;
}

fn optBool(vm: *Vm, v: Value) ?bool {
    if (isUnset(v)) return null;
    return value_mod.toBoolean(v, vm.swf_version);
}

fn optString(vm: *Vm, v: Value) !?[]const u16 {
    if (isUnset(v)) return null;
    return try vm.toStringValue(v);
}

/// ruffle `round_to_even`: half-to-even, with anything non-finite or out
/// of range landing on i32::MIN.
fn roundToEven(n: f64) f64 {
    if (!std.math.isFinite(n)) return @floatFromInt(std.math.minInt(i32));
    const r = @round(n);
    const out = if (@abs(n - @trunc(n)) == 0.5 and @mod(r, 2) != 0)
        r - std.math.sign(n)
    else
        r;
    if (out > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return @floatFromInt(std.math.minInt(i32));
    }
    return out;
}

/// The shared numeric rule: ToInt32 below SWF8, half-to-even above it.
/// `clamp_zero` is set for the margins, which never go negative.
fn optNum(vm: *Vm, v: Value, clamp_zero: bool) !?f64 {
    if (isUnset(v)) return null;
    if (vm.swf_version < 8) {
        const n: f64 = @floatFromInt(value_mod.toInt32(try vm.toNumber(v)));
        return if (clamp_zero) @max(n, 0) else n;
    }
    const n = try vm.toNumber(v);
    return roundToEven(if (clamp_zero) @max(n, 0) else n);
}

fn applyFont(vm: *Vm, tf: *TextFormat, v: Value) !void {
    if (isUnset(v)) {
        tf.font = null;
        return;
    }
    const s = try vm.toStringValue(v);
    // Flash truncates the face name at 64 characters.
    tf.font = if (s.len > 64) s[0..64] else s;
}

fn applySize(vm: *Vm, tf: *TextFormat, v: Value) !void {
    tf.size = try optNum(vm, v, false);
}

fn applyColor(vm: *Vm, tf: *TextFormat, v: Value) !void {
    if (isUnset(v)) {
        tf.color = null;
        return;
    }
    tf.color = value_mod.toUint32(try vm.toNumber(v));
}

fn applyAlign(vm: *Vm, tf: *TextFormat, v: Value) !void {
    // Note: an unrecognised value — and undefined/null — leaves the
    // current alignment ALONE rather than clearing it.
    if (isUnset(v)) return;
    const s = try vm.toStringValue(v);
    const names = [_]struct { []const u16, format.Align }{
        .{ S("left"), .left },
        .{ S("center"), .center },
        .{ S("right"), .right },
        .{ S("justify"), .justify },
    };
    for (names) |n| {
        if (strings.eqlIgnoreCase(s, n[0])) {
            tf.text_align = n[1];
            return;
        }
    }
}

// --- accessors ----------------------------------------------------------------

/// Every getter follows the same shape: no format behind `this` (a read on
/// the prototype) is `undefined`, an unset field is `null`.
fn getter(comptime field: []const u8, comptime conv: fn (*Vm, anytype) anyerror!Value) object_mod.NativeFn {
    return struct {
        fn f(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            _ = args;
            const vm = vmOf(p);
            const tf = formatOf(vm, this) orelse return .undefined_value;
            const v = @field(tf, field);
            if (v == null) return .null_value;
            return conv(vm, v.?);
        }
    }.f;
}

fn asNumber(vm: *Vm, v: anytype) anyerror!Value {
    _ = vm;
    return .{ .number = switch (@TypeOf(v)) {
        u32 => @floatFromInt(v),
        else => v,
    } };
}

fn asBool(vm: *Vm, v: anytype) anyerror!Value {
    _ = vm;
    return .{ .boolean = v };
}

fn asString(vm: *Vm, v: anytype) anyerror!Value {
    _ = vm;
    return .{ .string = v };
}

const getFont = getter("font", asString);
const getSize = getter("size", asNumber);
const getColor = getter("color", asNumber);
const getUrl = getter("url", asString);
const getTarget = getter("target", asString);
const getBold = getter("bold", asBool);
const getItalic = getter("italic", asBool);
const getUnderline = getter("underline", asBool);
const getLeftMargin = getter("left_margin", asNumber);
const getRightMargin = getter("right_margin", asNumber);
const getIndent = getter("indent", asNumber);
const getLeading = getter("leading", asNumber);
const getBlockIndent = getter("block_indent", asNumber);
const getBullet = getter("bullet", asBool);
const getKerning = getter("kerning", asBool);
const getLetterSpacing = getter("letter_spacing", asNumber);

fn getAlign(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const tf = formatOf(vmOf(p), this) orelse return .undefined_value;
    const a = tf.text_align orelse return .null_value;
    return .{ .string = switch (a) {
        .left => S("left"),
        .center => S("center"),
        .right => S("right"),
        .justify => S("justify"),
    } };
}

fn getDisplay(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const tf = formatOf(vmOf(p), this) orelse return .undefined_value;
    const d = tf.display orelse return .null_value;
    return .{ .string = switch (d) {
        .block => S("block"),
        .inline_text => S("inline"),
        .none => S("none"),
    } };
}

fn getTabStops(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const tf = formatOf(vm, this) orelse return .undefined_value;
    const stops = tf.tab_stops orelse return .null_value;
    const arr = try vm.newArray();
    for (stops, 0..) |s, i| {
        try vm.objects.put(arr, try indexName(vm, @intCast(i)), .{ .number = s }, false);
    }
    try vm.setArrayLength(arr, @intCast(stops.len));
    return .{ .object = arr };
}

/// Array element keys are their decimal index.
fn indexName(vm: *Vm, i: u32) !strings.AvmString {
    var buf: [16]u8 = undefined;
    const ascii = try std.fmt.bufPrint(&buf, "{d}", .{i});
    const wide = try vm.arena().alloc(u16, ascii.len);
    for (ascii, wide) |c, *w| w.* = c;
    return wide;
}

fn setFont(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| try applyFont(vm, tf, arg(args, 0));
    return .undefined_value;
}

fn setSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| try applySize(vm, tf, arg(args, 0));
    return .undefined_value;
}

fn setColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| try applyColor(vm, tf, arg(args, 0));
    return .undefined_value;
}

fn setUrl(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.url = try optString(vm, arg(args, 0));
    return .undefined_value;
}

fn setTarget(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.target = try optString(vm, arg(args, 0));
    return .undefined_value;
}

fn setBold(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.bold = optBool(vm, arg(args, 0));
    return .undefined_value;
}

fn setItalic(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.italic = optBool(vm, arg(args, 0));
    return .undefined_value;
}

fn setUnderline(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.underline = optBool(vm, arg(args, 0));
    return .undefined_value;
}

fn setAlign(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| try applyAlign(vm, tf, arg(args, 0));
    return .undefined_value;
}

fn setLeftMargin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.left_margin = try optNum(vm, arg(args, 0), true);
    return .undefined_value;
}

fn setRightMargin(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.right_margin = try optNum(vm, arg(args, 0), true);
    return .undefined_value;
}

fn setIndent(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.indent = try optNum(vm, arg(args, 0), vm.swf_version < 8);
    return .undefined_value;
}

fn setLeading(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.leading = try optNum(vm, arg(args, 0), vm.swf_version < 8);
    return .undefined_value;
}

fn setBlockIndent(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.block_indent = try optNum(vm, arg(args, 0), vm.swf_version < 8);
    return .undefined_value;
}

fn setBullet(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.bullet = optBool(vm, arg(args, 0));
    return .undefined_value;
}

/// Unlike every other setter, an unset value here means BLOCK rather than
/// "no value" (ruffle set_display).
fn setDisplay(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const tf = formatOf(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (isUnset(v)) {
        tf.display = .block;
        return .undefined_value;
    }
    const s = try vm.toStringValue(v);
    tf.display = if (strings.eql(s, S("inline")))
        .inline_text
    else if (strings.eql(s, S("none")))
        .none
    else
        .block;
    return .undefined_value;
}

fn setKerning(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (formatOf(vm, this)) |tf| tf.kerning = optBool(vm, arg(args, 0));
    return .undefined_value;
}

fn setLetterSpacing(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const tf = formatOf(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    tf.letter_spacing = if (isUnset(v)) null else try vm.toNumber(v);
    return .undefined_value;
}

/// Anything that is not an object clears the stops; an object is read as
/// an array and every element rounded half-to-even.
fn setTabStops(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const tf = formatOf(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v != .object) {
        tf.tab_stops = null;
        return .undefined_value;
    }
    const n = vm.arrayLength(v.object);
    const stops = try vm.arena().alloc(f64, n);
    for (stops, 0..) |*s, i| {
        const el = vm.objects.getChained(v.object, try indexName(vm, @intCast(i)), vm.case_sensitive) orelse
            Value.undefined_value;
        s.* = roundToEven(try vm.toNumber(el));
    }
    tf.tab_stops = stops;
    return .undefined_value;
}

/// Needs a laid-out text field to measure with, which arrives in D6.
fn getTextExtent(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .undefined_value;
}
