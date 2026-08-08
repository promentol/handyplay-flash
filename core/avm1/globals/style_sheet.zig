//! `TextField.StyleSheet` — CSS for a text field.
//!
//! Almost all of the state is ordinary script-visible properties: the raw
//! style objects live on `_css` and the `TextFormat`s they transform into
//! live on `_styles`, both plain Arrays used as maps. `getStyleNames` is
//! literally `_css`'s key list, which is why it comes back in
//! reverse-insertion order like any other enumeration.
//!
//! `setStyle` calls `transform` THROUGH the object, so content that
//! overrides the method changes what gets stored. The lowercased selector
//! also goes into a hidden side table, which is what the HTML parser
//! matches against — an interpreter-free callback, so `core/text` never
//! learns what a StyleSheet is.
//!
//! `transform` maps the CSS property names onto `TextFormat`'s: a `#RRGGBB`
//! colour, `fontSize` through `parseInt` (so "12px" works), `fontWeight`
//! and `fontStyle` onto bold/italic, `textDecoration` onto underline. It
//! starts from `kerning: false` rather than an empty format.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/style_sheet.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const format_mod = @import("../../text/format.zig");
const text_format = @import("text_format.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const TextFormat = format_mod.TextFormat;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const ver = decl.ver;

/// Where the lowercased selector → TextFormat map hangs. Hidden from
/// enumeration and from `delete`: it is engine state, not content's.
const NATIVE = "__styles";

pub fn install(vm: *Vm, textfield_ctor: ObjectHandle) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.stylesheet_proto = proto;

    const flags = ver(decl.frozen, decl.V7);
    try decl.method(vm, proto, "setStyle", setStyle, flags);
    try decl.method(vm, proto, "clear", clear, flags);
    try decl.method(vm, proto, "getStyleNames", getStyleNames, flags);
    try decl.method(vm, proto, "load", load, flags);
    try decl.method(vm, proto, "getStyle", getStyle, flags);
    try decl.method(vm, proto, "transform", transform, flags);
    try decl.method(vm, proto, "parseCSS", parseCss, flags);
    try decl.method(vm, proto, "parse", parseCss, flags);

    const ctor = try vm.newNativeFn(construct);
    try vm.objects.putWithAttrs(ctor, S("prototype"), .{ .object = proto }, decl.hidden, false);
    try vm.objects.putWithAttrs(proto, S("constructor"), .{ .object = ctor }, decl.hidden, false);
    // It lives on the TextField CONSTRUCTOR, not on _global.
    try vm.objects.putWithAttrs(
        textfield_ctor,
        S("StyleSheet"),
        .{ .object = ctor },
        ver(decl.hidden, decl.V7),
        false,
    );
}

fn construct(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return this;
    try vm.objects.putWithAttrs(this.object, S(NATIVE), .{ .object = try vm.newObject() }, decl.frozen, false);
    return this;
}

/// Is `h` a StyleSheet? Only one with the side table counts, so a plain
/// object assigned to `styleSheet` resolves nothing.
pub fn nativeOf(vm: *Vm, h: ObjectHandle) ?ObjectHandle {
    const v = vm.objects.getChained(h, S(NATIVE), false) orelse return null;
    return if (v == .object) v.object else null;
}

/// The HTML parser's callback. `ctx` is the Vm and `sheet` the object.
pub fn lookup(ctx: *anyopaque, sheet: u32, selector: []const u16) ?TextFormat {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const native = nativeOf(vm, sheet) orelse return null;
    const v = vm.objects.getChained(native, selector, false) orelse return null;
    const tf = text_format.formatOf(vm, v) orelse return null;
    return tf.*;
}

// --- the methods ---------------------------------------------------------------

/// A flat copy through `_global.Object` — the stored style must not alias
/// the object content handed in.
fn shallowCopy(vm: *Vm, v: Value) !Value {
    if (v != .object) return .null_value;
    const out = try vm.newObject();
    const keys = try ownKeys(vm, v.object);
    for (keys) |k| {
        const val = vm.objects.getChained(v.object, k, vm.case_sensitive) orelse continue;
        try vm.objects.put(out, k, val, vm.case_sensitive);
    }
    return .{ .object = out };
}

/// The object's own enumerable keys in INSERTION order — what ruffle's
/// `get_keys` yields. AVM1's `for..in` sees them backwards only because
/// the SWF pops what the opcode pushed.
fn ownKeys(vm: *Vm, h: ObjectHandle) ![]const []const u16 {
    var out: std.ArrayList([]const u16) = .empty;
    for (vm.objects.get(h).props.items) |prop| {
        if (prop.attrs.dont_enum) continue;
        try out.append(vm.arena(), prop.key);
    }
    return out.items;
}

fn mapOf(vm: *Vm, this: Value, comptime name: []const u8) !ObjectHandle {
    if (vm.objects.getChained(this.object, S(name), false)) |v| {
        if (v == .object) return v.object;
    }
    const h = try vm.newArray();
    try vm.objects.put(this.object, S(name), .{ .object = h }, false);
    return h;
}

fn setStyle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const css = try mapOf(vm, this, "_css");
    const styles = try mapOf(vm, this, "_styles");
    const name = try vm.toStringValue(arg(args, 0));
    const object = arg(args, 1);

    try vm.objects.put(css, name, try shallowCopy(vm, object), vm.case_sensitive);
    // Through the OBJECT, so an overridden `transform` is honoured.
    const tf_value = blk: {
        const f = vm.objects.getChained(this.object, S("transform"), vm.case_sensitive) orelse
            break :blk Value.undefined_value;
        if (!vm.isCallable(f)) break :blk Value.undefined_value;
        break :blk try vm.callFunction(f, this, &.{try shallowCopy(vm, object)});
    };
    try vm.objects.put(styles, name, tf_value, vm.case_sensitive);

    if (nativeOf(vm, this.object)) |native| {
        if (tf_value == .object and text_format.formatOf(vm, tf_value) != null) {
            const lower = try vm.arena().dupe(u16, name);
            for (lower) |*c| {
                if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
            }
            try vm.objects.put(native, lower, tf_value, false);
        }
    }
    return .undefined_value;
}

fn getStyle(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const css = try mapOf(vm, this, "_css");
    const name = try vm.toStringValue(arg(args, 0));
    const v = vm.objects.getChained(css, name, vm.case_sensitive) orelse .undefined_value;
    return shallowCopy(vm, v);
}

fn getStyleNames(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const css = try mapOf(vm, this, "_css");
    const keys = try ownKeys(vm, css);
    const arr = try vm.newArray();
    for (keys, 0..) |k, i| try vm.arraySet(arr, @intCast(i), .{ .string = k });
    return .{ .object = arr };
}

fn clear(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try vm.objects.put(this.object, S("_styles"), .{ .object = try vm.newArray() }, false);
    try vm.objects.put(this.object, S("_css"), .{ .object = try vm.newArray() }, false);
    if (nativeOf(vm, this.object)) |_| {
        try vm.objects.putWithAttrs(this.object, S(NATIVE), .{ .object = try vm.newObject() }, decl.frozen, false);
    }
    return .undefined_value;
}

/// Fetching a sheet over the network needs the loader (M5); until then it
/// reports the failure honestly rather than pretending to start.
fn load(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .{ .boolean = false };
}

/// CSS property names → a `TextFormat`. Everything unrecognised is
/// ignored, and the result starts from `kerning: false` rather than an
/// empty format.
fn transform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const style = arg(args, 0);
    if (style == .undefined_value or style == .null_value) return .null_value;

    var tf: TextFormat = .{ .kerning = false };
    if (style == .object) {
        const o = style.object;
        if (getStr(vm, o, "color")) |c| tf.color = parseColor(c);
        if (get(vm, o, "display")) |v| {
            const d = try vm.toStringValue(v);
            tf.display = if (strings.eql(d, S("none")))
                .none
            else if (strings.eql(d, S("inline")))
                .inline_text
            else
                .block;
        }
        if (get(vm, o, "fontFamily")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.font = try vm.toStringValue(v);
        }
        if (get(vm, o, "fontSize")) |v| {
            const n = try suffixedInt(vm, v);
            if (n > 0) tf.size = @floatFromInt(n);
        }
        if (get(vm, o, "fontStyle")) |v| {
            const st = try vm.toStringValue(v);
            if (strings.eql(st, S("normal"))) tf.italic = false;
            if (strings.eql(st, S("italic"))) tf.italic = true;
        }
        if (get(vm, o, "fontWeight")) |v| {
            const w = try vm.toStringValue(v);
            if (strings.eql(w, S("normal"))) tf.bold = false;
            if (strings.eql(w, S("bold"))) tf.bold = true;
        }
        if (get(vm, o, "kerning")) |v| {
            tf.kerning = if (v == .string and strings.eql(v.string, S("true")))
                true
            else
                (try suffixedInt(vm, v)) != 0;
        }
        if (get(vm, o, "leading")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.leading = @floatFromInt(try suffixedInt(vm, v));
        }
        if (get(vm, o, "letterSpacing")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.letter_spacing = @floatFromInt(try suffixedInt(vm, v));
        }
        if (get(vm, o, "marginLeft")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.left_margin = @floatFromInt(@max(try suffixedInt(vm, v), 0));
        }
        if (get(vm, o, "marginRight")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.right_margin = @floatFromInt(@max(try suffixedInt(vm, v), 0));
        }
        if (get(vm, o, "textAlign")) |v| {
            const a = try vm.toStringValue(v);
            if (strings.eqlIgnoreCase(a, S("left"))) tf.text_align = .left;
            if (strings.eqlIgnoreCase(a, S("center"))) tf.text_align = .center;
            if (strings.eqlIgnoreCase(a, S("right"))) tf.text_align = .right;
            if (strings.eqlIgnoreCase(a, S("justify"))) tf.text_align = .justify;
        }
        if (get(vm, o, "textDecoration")) |v| {
            const d = try vm.toStringValue(v);
            if (strings.eql(d, S("none"))) tf.underline = false;
            if (strings.eql(d, S("underline"))) tf.underline = true;
        }
        if (get(vm, o, "textIndent")) |v| {
            if (value_mod.toBoolean(v, vm.swf_version)) tf.indent = @floatFromInt(try suffixedInt(vm, v));
        }
    }
    return .{ .object = try text_format.newObject(vm, tf) };
}

fn get(vm: *Vm, o: ObjectHandle, comptime name: []const u8) ?Value {
    const v = vm.objects.getChained(o, S(name), vm.case_sensitive) orelse return null;
    return if (v == .undefined_value) null else v;
}

fn getStr(vm: *Vm, o: ObjectHandle, comptime name: []const u8) ?[]const u16 {
    const v = get(vm, o, name) orelse return null;
    return if (v == .string) v.string else null;
}

/// `parseInt` semantics: leading digits win and a `px`/`pt` suffix is
/// simply ignored.
fn suffixedInt(vm: *Vm, v: Value) !i32 {
    if (v != .string) return value_mod.toInt32(try vm.toNumber(v));
    var i: usize = 0;
    const s = v.string;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var sign: i32 = 1;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s[i] == '-') sign = -1;
        i += 1;
    }
    var n: i64 = 0;
    var digits: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
        if (n > 0x7FFF_FFFF) n = 0x7FFF_FFFF;
        digits += 1;
    }
    if (digits == 0) return 0;
    return sign * @as(i32, @intCast(n));
}

/// `#RRGGBB`, exactly six hex digits — anything else is no colour at all.
fn parseColor(s: []const u16) ?u32 {
    if (s.len != 7 or s[0] != '#') return null;
    var rgb: u32 = 0;
    for (s[1..]) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        rgb = rgb * 16 + d;
    }
    return rgb;
}

/// `selector { prop: value; … }`, repeated. Comma-separated selectors are
/// each given the same rule; a malformed sheet answers false.
fn parseCss(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const src = try vm.toStringValue(arg(args, 0));
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and isSpace(src[i])) i += 1;
        const sel_start = i;
        while (i < src.len and src[i] != '{') i += 1;
        if (i >= src.len) break;
        const selectors = src[sel_start..i];
        i += 1;
        const body_start = i;
        while (i < src.len and src[i] != '}') i += 1;
        const body = src[body_start..@min(i, src.len)];
        if (i < src.len) i += 1;

        const style = try vm.newObject();
        var j: usize = 0;
        while (j < body.len) {
            const k_start = j;
            while (j < body.len and body[j] != ':' and body[j] != ';') j += 1;
            if (j >= body.len or body[j] == ';') {
                j += 1;
                continue;
            }
            const key = trim(body[k_start..j]);
            j += 1;
            const v_start = j;
            while (j < body.len and body[j] != ';') j += 1;
            const val = trim(body[v_start..j]);
            if (j < body.len) j += 1;
            if (key.len == 0) continue;
            try vm.objects.put(style, try camelCase(vm, key), .{ .string = val }, false);
        }

        var s: usize = 0;
        while (s <= selectors.len) {
            const start = s;
            while (s < selectors.len and selectors[s] != ',') s += 1;
            const one = trim(selectors[start..s]);
            s += 1;
            if (one.len == 0) continue;
            _ = try setStyle(p, this, &.{ .{ .string = one }, .{ .object = style } });
        }
    }
    return .{ .boolean = true };
}

/// `font-size` → `fontSize`. A dash is dropped and the letter after it
/// goes uppercase.
fn camelCase(vm: *Vm, s: []const u16) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    var upper = false;
    for (s) |c| {
        if (c == '-') {
            upper = true;
            continue;
        }
        try out.append(vm.arena(), if (upper and c >= 'a' and c <= 'z') c - 32 else c);
        upper = false;
    }
    return out.items;
}

fn isSpace(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn trim(s: []const u16) []const u16 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) a += 1;
    while (b > a and isSpace(s[b - 1])) b -= 1;
    return s[a..b];
}
