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
/// `load(url)` starts a fetch and answers true straight away — false
/// only when there was no url to fetch. What arrives is handed to the
/// object's OWN `parse` (so an override sees it), and `onLoad` hears
/// whether that returned true (corpus stylesheet_load).
fn load(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object or args.len == 0) return .{ .boolean = false };
    const url = try vm.toStringThrowing(args[0]);
    const f = vm.host.fetch orelse return .{ .boolean = false };
    f(vm.host.ctx.?, .{
        .url = try strings.toUtf8(vm.arena(), url),
        .method = .none,
        .target = .{ .stylesheet = this.object },
    });
    return .{ .boolean = true };
}

pub fn completeLoad(vm: *Vm, h: ObjectHandle, body: ?[]const u8) !void {
    const this: Value = .{ .object = h };
    var success: Value = .{ .boolean = false };
    if (body) |bytes| {
        const text = try strings.fromSwf(vm.arena(), bytes, 8);
        const parse = try vm.getProperty(h, S("parse"), this);
        if (vm.isCallable(parse)) {
            vm.call_special = true;
            success = vm.callFunction(parse, this, &.{.{ .string = text }}) catch
                Value{ .boolean = false };
        }
    }
    const on_load = try vm.getProperty(h, S("onLoad"), this);
    if (vm.isCallable(on_load)) {
        vm.call_special = true;
        _ = vm.callFunction(on_load, this, &.{success}) catch {};
    }
}

/// CSS property names → a `TextFormat`. Everything unrecognised is
/// ignored, and the result starts from `kerning: false` rather than an
/// empty format.
fn transform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const style = arg(args, 0);
    if (style == .undefined_value or style == .null_value) return .null_value;

    // `TextFormat::default()` with kerning forced off — and the default
    // is not empty: `display` starts at BLOCK, so a rule that names no
    // display still reports one (corpus stylesheet_transform).
    var tf: TextFormat = format_mod.defaultFormat();
    tf.kerning = false;
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
            if (value_mod.toBoolean(v, vm.swf_version)) {
                tf.font = try parseFontList(vm, try vm.toStringValue(v));
            }
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
            // letterSpacing keeps the parse as an f64, so an unparseable
            // one stays NaN where fontSize's i32 coercion would make it
            // zero.
            if (value_mod.toBoolean(v, vm.swf_version)) tf.letter_spacing = try suffixedFloat(vm, v);
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

/// A CSS font list, comma-separated. Only LEADING spaces are stripped
/// from each name — the trailing ones stay, and so do the ones inside —
/// and the three generic families map onto Flash's device names. Empty
/// entries vanish, so the separators do not survive as written.
fn parseFontList(vm: *Vm, input: []const u16) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    var pos: usize = 0;
    while (pos < input.len) {
        while (pos < input.len and input[pos] == ' ') pos += 1;
        const start = pos;
        while (pos < input.len and input[pos] != ',') pos += 1;
        var value = input[start..pos];
        if (pos < input.len) pos += 1;
        if (strings.eql(value, S("mono"))) {
            value = S("_typewriter");
        } else if (strings.eql(value, S("sans-serif"))) {
            value = S("_sans");
        } else if (strings.eql(value, S("serif"))) {
            value = S("_serif");
        }
        if (value.len == 0) continue;
        if (out.items.len > 0) try out.append(vm.arena(), ',');
        try out.appendSlice(vm.arena(), value);
    }
    return out.items;
}

fn get(vm: *Vm, o: ObjectHandle, comptime name: []const u8) ?Value {
    const v = vm.objects.getChained(o, S(name), vm.case_sensitive) orelse return null;
    return if (v == .undefined_value) null else v;
}

fn getStr(vm: *Vm, o: ObjectHandle, comptime name: []const u8) ?[]const u16 {
    const v = get(vm, o, name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Every numeric CSS value goes through `parseInt`, not `Number` — the
/// value is STRINGIFIED first, so `fontSize: true` parses "true" and
/// comes out as nothing. Leading whitespace of any kind is skipped, and
/// a `px`/`pt` suffix simply ends the digits.
fn suffixedFloat(vm: *Vm, v: Value) !f64 {
    const n = try suffixedIntOrNan(vm, v);
    return n;
}

fn suffixedInt(vm: *Vm, v: Value) !i32 {
    const n = try suffixedIntOrNan(vm, v);
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(std.math.clamp(n, -2147483648.0, 2147483647.0));
}

fn suffixedIntOrNan(vm: *Vm, v: Value) !f64 {
    const s = try vm.toStringValue(v);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
        s[i] == '\r' or s[i] == 0x0B or s[i] == 0x0C)) i += 1;
    var sign: i64 = 1;
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
    if (digits == 0) return std.math.nan(f64);
    return @as(f64, @floatFromInt(sign)) * @as(f64, @floatFromInt(n));
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

/// `selector { prop: value; … }`, repeated — ruffle's `CssStream`, whose
/// rules are more particular than they look:
///
///   * A space INSIDE a selector or a property name is an ERROR, one
///     before it is skipped, and one after a property name is KEPT as
///     part of the name (until the colon).
///   * A property VALUE keeps its trailing space: `kerning: 5 ;` is the
///     string "5 ".
///   * `/* … */` comments are skipped anywhere whitespace is.
///   * Any error abandons the WHOLE sheet: nothing is applied and the
///     call answers false (corpus stylesheet).
const Css = struct {
    src: []const u16,
    pos: usize = 0,

    const Error = error{Malformed};

    fn peek(self: *const Css) ?u16 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn isWs(c: u16) bool {
        return c == ' ' or c == '\n' or c == '\r' or c == '\t';
    }

    fn skipWsAndComments(self: *Css) bool {
        var found = false;
        while (true) {
            if (self.skipComment()) {
                found = true;
                continue;
            }
            const c = self.peek() orelse break;
            if (!isWs(c)) break;
            self.pos += 1;
            found = true;
        }
        return found;
    }

    fn skipComment(self: *Css) bool {
        if (self.pos + 1 >= self.src.len) return false;
        if (!(self.src[self.pos] == '/' and self.src[self.pos + 1] == '*')) return false;
        self.pos += 2;
        while (self.pos + 1 < self.src.len) {
            if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                self.pos += 2;
                return true;
            }
            self.pos += 1;
        }
        self.pos = self.src.len;
        return false; // EOF without a close
    }

    fn consumeUntilAny(self: *Css, set: []const u16) []const u16 {
        const start = self.pos;
        outer: while (self.pos < self.src.len) {
            for (set) |x| {
                if (self.src[self.pos] == x) break :outer;
            }
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }

    fn parseSelectors(self: *Css, out: *std.ArrayList([]const u16), a: std.mem.Allocator) !void {
        while (true) {
            _ = self.skipWsAndComments();
            const name = self.consumeUntilAny(&.{ '{', ',', ' ', '\n', '\r', '\t' });
            if (name.len > 0) try out.append(a, name);
            _ = self.skipWsAndComments();
            const c = self.peek() orelse return Error.Malformed;
            if (c == '{') {
                self.pos += 1;
                if (out.items.len == 0) try out.append(a, &.{});
                return;
            }
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            return Error.Malformed; // a space inside a selector name
        }
    }

    const Prop = struct { key: []const u16, value: []const u16 };

    fn parseProperties(self: *Css, out: *std.ArrayList(Prop), a: std.mem.Allocator) !void {
        main: while (true) {
            _ = self.skipWsAndComments();
            const first = self.peek() orelse return;
            if (first == '}') {
                self.pos += 1;
                return;
            }
            const name_start = self.pos;
            var name = self.consumeUntilAny(&.{ ':', ' ', '\n', '\r', '\t' });
            if (self.skipWsAndComments()) {
                const next = self.peek();
                if (next != null and next.? == ':') {
                    // Trailing spaces belong to the NAME.
                    name = self.src[name_start..self.pos];
                } else if (next != null) {
                    return Error.Malformed; // a space inside a property name
                }
            }
            if (self.peek()) |c| {
                if (c != ':') unreachable;
                self.pos += 1;
            } else return Error.Malformed;

            _ = self.skipWsAndComments();
            const value_start = self.pos;
            var value = self.consumeUntilAny(&.{ ';', ':', '}' });
            while (true) {
                const c = self.peek() orelse return Error.Malformed;
                if (c == ':') {
                    // A second colon: the value runs to the end of the
                    // LINE, if there is one.
                    self.pos = value_start;
                    const possible = self.consumeUntilAny(&.{ '\n', '\r' });
                    if (self.peek()) |nl| {
                        if (nl == '\n' or nl == '\r') {
                            self.pos += 1;
                            try out.append(a, .{ .key = name, .value = possible });
                            continue :main;
                        }
                    }
                    self.pos = value_start;
                    value = self.consumeUntilAny(&.{ ';', '}' });
                    continue;
                }
                if (c == ';') {
                    self.pos += 1;
                    try out.append(a, .{ .key = name, .value = value });
                    continue :main;
                }
                if (c == '}') {
                    self.pos += 1;
                    // The last value in a block stops at a newline.
                    var end = value.len;
                    for (value, 0..) |ch, idx| {
                        if (ch == '\n' or ch == '\r') {
                            end = idx;
                            break;
                        }
                    }
                    try out.append(a, .{ .key = name, .value = value[0..end] });
                    return;
                }
                unreachable;
            }
        }
    }
};

fn parseCss(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .{ .boolean = false };
    const src = try vm.toStringValue(arg(args, 0));
    const a = vm.arena();

    // Parse the WHOLE sheet first: one error and nothing is applied.
    const Rule = struct { selectors: [][]const u16, props: []Css.Prop };
    var rules: std.ArrayList(Rule) = .empty;
    var s: Css = .{ .src = src };
    while (true) {
        _ = s.skipWsAndComments();
        if (s.peek() == null) break;
        var sels: std.ArrayList([]const u16) = .empty;
        s.parseSelectors(&sels, a) catch return .{ .boolean = false };
        var props: std.ArrayList(Css.Prop) = .empty;
        s.parseProperties(&props, a) catch return .{ .boolean = false };
        try rules.append(a, .{
            .selectors = try sels.toOwnedSlice(a),
            .props = try props.toOwnedSlice(a),
        });
    }

    for (rules.items) |rule| {
        const style = try vm.newObject();
        for (rule.props) |prop| {
            const key = try camelCase(vm, prop.key);
            // A property with an EMPTY name parses fine and then goes
            // nowhere — `a{:}` yields a style object with nothing in it.
            if (key.len == 0) continue;
            try vm.objects.put(style, key, .{ .string = prop.value }, vm.case_sensitive);
        }
        for (rule.selectors) |sel| {
            if (sel.len == 0) continue;
            _ = try setStyle(p, this, &.{ .{ .string = sel }, .{ .object = style } });
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
        if (c == '-' and !upper) {
            upper = true;
            continue;
        }
        // The character after a dash is UPPERCASED — including a second
        // dash, whose uppercase is itself, so `a--b` keeps one dash
        // while `a-b` loses it (corpus stylesheet).
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
