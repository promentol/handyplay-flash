//! The AVM1 `TextField` class — 35 properties and 8 methods.
//!
//! Declaration ORDER is an ABI here more than anywhere else: enumeration is
//! reverse-insertion and `textfield_props_swf5..8` print the whole list
//! four times over. The methods go first, then the SWF8 render block, then
//! everything else, and the corpus's enumeration is that list backwards.
//!
//! Two shapes of member, and the difference is observable:
//!
//!   - the METHODS carry `DONT_ENUM | DONT_DELETE` (and `getDepth` is
//!     read-only besides), so they never appear in `for..in`;
//!   - the PROPERTIES carry no flags at all — they enumerate, they can be
//!     deleted off the prototype, and a write to a getter-only one (there
//!     are six) is simply dropped.
//!
//! `tabEnabled` is deliberately NOT here: unlike MovieClip's it is not a
//! built-in TextField property, which is why `tab_ordering_tabbable` can
//! set it as a plain field and still not get tabbing.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/text_field.rs.

const std = @import("std");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage = @import("../stage_object.zig");
const decl = @import("decl.zig");
const mc_globals = @import("movie_clip.zig");
const text_format = @import("text_format.zig");
const edit_text_mod = @import("../../display/edit_text.zig");
const text_binding = @import("../text_binding.zig");
const format_mod = @import("../../text/format.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const EditText = edit_text_mod.EditText;
const TextFormat = format_mod.TextFormat;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const hidden = decl.hidden;
const frozen = decl.frozen;
const ver = decl.ver;

pub fn install(vm: *Vm) !void {
    const proto = try vm.objects.create();
    vm.objects.get(proto).proto = .{ .object = vm.object_proto };
    vm.textfield_proto = proto;

    try decl.method(vm, proto, "replaceSel", replaceSel, ver(hidden, decl.V6));
    try decl.method(vm, proto, "getTextFormat", getTextFormatFn, ver(hidden, decl.V6));
    try decl.method(vm, proto, "setTextFormat", setTextFormatFn, ver(hidden, decl.V6));
    try decl.method(vm, proto, "removeTextField", removeTextField, ver(hidden, decl.V6));
    try decl.method(vm, proto, "getNewTextFormat", getNewTextFormat, ver(hidden, decl.V6));
    try decl.method(vm, proto, "setNewTextFormat", setNewTextFormat, ver(hidden, decl.V6));
    try decl.method(vm, proto, "getDepth", mc_globals.getDepth, ver(frozen, decl.V6));
    try decl.method(vm, proto, "replaceText", replaceText, ver(hidden, decl.V7));

    // The SWF8 render block. These still ENUMERATE below SWF8 — the
    // version gate hides them from reads, not from `for..in`.
    try v8(vm, proto, "gridFitType", getGridFitType, setGridFitType);
    try v8(vm, proto, "antiAliasType", getAntiAliasType, setAntiAliasType);
    try v8(vm, proto, "thickness", getThickness, setThickness);
    try v8(vm, proto, "sharpness", getSharpness, setSharpness);
    try decl.property(vm, proto, "filters", getFilters, setFilters, ver(.{ .dont_delete = true }, decl.V8));

    try prop(vm, proto, "scroll", getScroll, setScroll);
    try ro(vm, proto, "maxscroll", getMaxscroll);
    try prop(vm, proto, "borderColor", getBorderColor, setBorderColor);
    try prop(vm, proto, "backgroundColor", getBackgroundColor, setBackgroundColor);
    try prop(vm, proto, "textColor", getTextColor, setTextColor);
    try prop(vm, proto, "tabIndex", getTabIndex, setTabIndex);
    try prop(vm, proto, "autoSize", getAutoSize, setAutoSize);
    try prop(vm, proto, "text", getText, setText);
    try prop(vm, proto, "type", getType, setType);
    try prop(vm, proto, "htmlText", getHtmlText, setHtmlText);
    try prop(vm, proto, "variable", getVariable, setVariable);
    try prop(vm, proto, "hscroll", getHscroll, setHscroll);
    try ro(vm, proto, "maxhscroll", getMaxhscroll);
    try prop(vm, proto, "maxChars", getMaxChars, setMaxChars);
    try prop(vm, proto, "embedFonts", getEmbedFonts, setEmbedFonts);
    try prop(vm, proto, "html", getHtml, setHtml);
    try prop(vm, proto, "border", getBorder, setBorder);
    try prop(vm, proto, "background", getBackground, setBackground);
    try prop(vm, proto, "wordWrap", getWordWrap, setWordWrap);
    try prop(vm, proto, "password", getPassword, setPassword);
    try prop(vm, proto, "multiline", getMultiline, setMultiline);
    try prop(vm, proto, "selectable", getSelectable, setSelectable);
    try ro(vm, proto, "length", getLength);
    try ro(vm, proto, "bottomScroll", getBottomScroll);
    try ro(vm, proto, "textWidth", getTextWidth);
    try ro(vm, proto, "textHeight", getTextHeight);
    try prop(vm, proto, "restrict", getRestrict, setRestrict);
    try prop(vm, proto, "condenseWhite", getCondenseWhite, setCondenseWhite);
    try prop(vm, proto, "mouseWheelEnabled", getMouseWheelEnabled, setMouseWheelEnabled);
    try prop(vm, proto, "styleSheet", getStyleSheet, setStyleSheet);

    _ = try decl.class(vm, "TextField", identityCtor, proto, hidden);
}

/// Every display-object class shares one: `new TextField()` yields a bare
/// object with the prototype attached and nothing else.
fn identityCtor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, args };
    return this;
}

fn prop(
    vm: *Vm,
    target: ObjectHandle,
    comptime name: []const u8,
    get: object_mod.NativeFn,
    set: object_mod.NativeFn,
) !void {
    try decl.property(vm, target, name, get, set, .{});
}

/// A getter with no setter. The write is DROPPED rather than shadowing —
/// `o.length = "test"` still reads back undefined.
fn ro(vm: *Vm, target: ObjectHandle, comptime name: []const u8, get: object_mod.NativeFn) !void {
    try decl.property(vm, target, name, get, null, .{});
}

fn v8(
    vm: *Vm,
    target: ObjectHandle,
    comptime name: []const u8,
    get: object_mod.NativeFn,
    set: object_mod.NativeFn,
) !void {
    try decl.property(vm, target, name, get, set, ver(.{}, decl.V8));
}

// --- the receiver ------------------------------------------------------------

/// `this` as a live text field, or null. Every member of this class opens
/// with it, and returning null means `undefined` — which is exactly what
/// `new TextField()` (a bare object with no display object behind it)
/// gets for all 43 members.
fn etOf(vm: *Vm, this: Value) ?*EditText {
    const t = stage.targetOfValue(vm, this) orelse return null;
    if (t.obj.kind != .edit_text) return null;
    return t.obj.kind.edit_text;
}

/// The allocator the field's owned strings live in — the DISPLAY one, not
/// the VM arena, because the field outlives any single activation.
fn gpaOf(vm: *Vm) ?std.mem.Allocator {
    const ctx = stage.displayCtxOf(vm) orelse return null;
    return ctx.gpa;
}

fn boolArg(vm: *Vm, args: []const Value) bool {
    return value_mod.toBoolean(arg(args, 0), vm.swf_version);
}

/// The field with its layout up to date and any pending autosize box
/// applied. Every measurement and every geometry read goes through this.
fn laidOut(vm: *Vm, this: Value) ?*EditText {
    const et = etOf(vm, this) orelse return null;
    const ctx = stage.displayCtxOf(vm) orelse return et;
    et.ensureLayout(ctx.gpa, &ctx.movie.lib, ctx.movie.swf_version) catch {};
    et.applyAutosizeBounds();
    return et;
}

// --- text --------------------------------------------------------------------

fn getText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    // A COPY: an AVM1 string is immutable, and handing out the field's
    // own buffer would let a later edit rewrite a value already stored
    // in a variable.
    return .{ .string = try vm.arena().dupe(u16, et.text.items) };
}

fn setText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    if (t.obj.kind != .edit_text) return .undefined_value;
    const et = t.obj.kind.edit_text;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    try et.setText(gpa, s);
    try text_binding.propagate(vm, t.obj);
    return .undefined_value;
}

/// The field's contents rendered back OUT as markup — which is not the
/// markup that went in: the writer always emits a `<P>` and a
/// fully-specified first `<FONT>`.
fn getHtmlText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    // A field that is not HTML reports its PLAIN text here; only an HTML
    // one serialises (ruffle `html_text`).
    if (!et.html) return .{ .string = try vm.arena().dupe(u16, et.text.items) };
    return .{ .string = try et.htmlText(vm.arena()) };
}

/// Deliberately does NOT propagate the variable binding: only writing
/// `text` notifies.
fn setHtmlText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    try et.setHtml(gpa, try vm.toStringValue(arg(args, 0)), vm.swf_version);
    return .undefined_value;
}

fn getLength(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(et.text.items.len) };
}

// --- flags -------------------------------------------------------------------

/// Every plain boolean member is the same three lines, so they are
/// generated from the field name.
fn boolPair(comptime field: []const u8) type {
    return struct {
        fn get(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            _ = args;
            const vm = vmOf(p);
            const et = etOf(vm, this) orelse return .undefined_value;
            return .{ .boolean = @field(et, field) };
        }
        fn set(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            const vm = vmOf(p);
            const et = etOf(vm, this) orelse return .undefined_value;
            @field(et, field) = boolArg(vm, args);
            et.dirty = true;
            return .undefined_value;
        }
    };
}

const getBorder = boolPair("border").get;
const setBorder = boolPair("border").set;
const getBackground = boolPair("background").get;
const setBackground = boolPair("background").set;
const getWordWrap = boolPair("word_wrap").get;
const setWordWrap = boolPair("word_wrap").set;
const getPassword = boolPair("password").get;
const setPassword = boolPair("password").set;
const getMultiline = boolPair("multiline").get;
const setMultiline = boolPair("multiline").set;
const getSelectable = boolPair("selectable").get;
const setSelectable = boolPair("selectable").set;
const getHtml = boolPair("html").get;
const setHtml = boolPair("html").set;
const getCondenseWhite = boolPair("condense_white").get;
const setCondenseWhite = boolPair("condense_white").set;
const getMouseWheelEnabled = boolPair("mouse_wheel_enabled").get;
const setMouseWheelEnabled = boolPair("mouse_wheel_enabled").set;

/// The SWF flag is `useOutlines` and script's is `embedFonts`; ruffle
/// stores the NEGATION (`is_device_font`) and both accessors invert.
const getEmbedFonts = boolPair("use_outlines").get;
const setEmbedFonts = boolPair("use_outlines").set;

/// `type` is "input" when the field is editable, and `read_only` is the
/// negation of that.
fn getType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .string = if (et.read_only) S("dynamic") else S("input") };
}

/// Anything other than "input" or "dynamic" (either case) does NOTHING —
/// it does not fall back to dynamic.
fn setType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    if (strings.eqlIgnoreCase(s, S("input"))) {
        et.read_only = false;
    } else if (strings.eqlIgnoreCase(s, S("dynamic"))) {
        et.read_only = true;
    }
    et.dirty = true;
    return .undefined_value;
}

// --- colours -----------------------------------------------------------------

/// The colour members all read as RGB and write with a FIXED alpha —
/// 255 for the box colours, 0 for the text (ruffle `Color::from_rgb`).
fn rgbOf(swf_color: u32) f64 {
    return @floatFromInt(edit_text_mod.rgbFromSwf(swf_color));
}

fn getBorderColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = rgbOf(et.border_color) };
}

fn setBorderColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    et.border_color = edit_text_mod.swfFromRgb(try toU32(vm, arg(args, 0)), 255);
    return .undefined_value;
}

fn getBackgroundColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = rgbOf(et.background_color) };
}

fn setBackgroundColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    et.background_color = edit_text_mod.swfFromRgb(try toU32(vm, arg(args, 0)), 255);
    return .undefined_value;
}

/// `textColor` is the NEW-text format's colour — unset reads undefined,
/// and setting it recolours the whole existing text as well.
fn getTextColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const c = et.default_format.color orelse return .undefined_value;
    return .{ .number = @floatFromInt(c & 0x00FF_FFFF) };
}

fn setTextColor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    // Alpha ZERO, not 255: ruffle builds `Color::from_rgb(rgb, 0)` here
    // and the renderer supplies the opacity. Both the existing text and
    // the next character typed take the new colour.
    const rgb = (try toU32(vm, arg(args, 0))) & 0x00FF_FFFF;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    et.default_format.color = rgb;
    try et.setFormatRange(gpa, 0, et.text.items.len, .{ .color = rgb });
    return .undefined_value;
}

fn toU32(vm: *Vm, v: Value) !u32 {
    return @bitCast(value_mod.toInt32(try vm.toNumber(v)));
}

fn toI32(vm: *Vm, v: Value) !i32 {
    return value_mod.toInt32(try vm.toNumber(v));
}

// --- geometry and scrolling ---------------------------------------------------

fn getAutoSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .string = switch (et.autosize) {
        .none => S("none"),
        .left => S("left"),
        .center => S("center"),
        .right => S("right"),
    } };
}

/// A real BOOLEAN maps to left/none; anything else is stringified and
/// matched case-insensitively, with every miss meaning "none".
fn setAutoSize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v == .boolean) {
        et.autosize = if (v.boolean) .left else .none;
        return .undefined_value;
    }
    const s = try vm.toStringValue(v);
    et.autosize = if (strings.eqlIgnoreCase(s, S("left")))
        .left
    else if (strings.eqlIgnoreCase(s, S("center")))
        .center
    else if (strings.eqlIgnoreCase(s, S("right")))
        .right
    else
        .none;
    et.dirty = true;
    return .undefined_value;
}

fn getScroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(et.scroll) };
}

fn setScroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    const n = try vm.toNumber(arg(args, 0));
    // Derived experimentally: anything negative, NaN, or past this
    // absurd limit lands on line 1 rather than clamping normally.
    const OVERFLOW: f64 = 767100486418433.0;
    const lines: u32 = if (std.math.isNan(n) or n < 0 or n >= OVERFLOW)
        1
    else
        @intFromFloat(@trunc(n));
    et.scroll = std.math.clamp(lines, 1, maxScrollOf(et));
    return .undefined_value;
}

/// The first line that can be at the TOP of a fully scrolled window:
/// find where that window begins and take the first line at or below it.
fn maxScrollOf(et: *const EditText) u32 {
    const lines = et.layout.lines;
    if (lines.len == 0) return 1;
    const window = et.bounds.height() - edit_text_mod.GUTTER * 2;
    const target = et.layout.text_height - window;
    for (lines) |l| {
        if (l.bounds.y >= target) return @intCast(l.index + 1);
    }
    return @intCast(lines[lines.len - 1].index + 1);
}

fn getMaxscroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    return .{ .number = @floatFromInt(maxScrollOf(et)) };
}

/// The LAST line currently visible: the one before the first whose
/// bottom edge falls past the window (ruffle `bottom_scroll`).
fn getBottomScroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    const lines = et.layout.lines;
    if (lines.len == 0) return .{ .number = 1 };
    const top = if (et.scroll >= 1 and et.scroll - 1 < lines.len)
        lines[et.scroll - 1].bounds.y
    else
        0;
    const target = et.bounds.height() + top - edit_text_mod.GUTTER * 2;
    for (lines) |l| {
        if (l.bounds.y + l.bounds.h > target) return .{ .number = @floatFromInt(@max(l.index, 1)) };
    }
    return .{ .number = @floatFromInt(lines[lines.len - 1].index + 1) };
}

fn getHscroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = et.hscroll };
}

/// SWF8 and below simply clamp into `0..maxhscroll`; SWF9's rule is much
/// stranger and is not AVM1's problem.
fn setHscroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    const n: f64 = @floatFromInt(try toI32(vm, arg(args, 0)));
    et.hscroll = std.math.clamp(n, 0, maxHscrollOf(et));
    return .undefined_value;
}

/// Word-wrapped text never scrolls sideways; otherwise it is how far the
/// text overhangs the box — plus a quarter of a window for an INPUT
/// field, which gets extra room past the end.
fn maxHscrollOf(et: *const EditText) f64 {
    if (et.word_wrap) return 0;
    const window = @max(et.bounds.width() - edit_text_mod.GUTTER * 2, 0);
    var w = et.layout.text_width;
    if (!et.read_only) w += @divTrunc(window, 4);
    const over = w - window;
    if (over <= 0) return 0;
    return @floatFromInt(@divTrunc(over, 20));
}

fn getMaxhscroll(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    return .{ .number = maxHscrollOf(et) };
}

/// Measured text, gutter EXCLUDED — and truncated to whole pixels, not
/// rounded (ruffle `trunc_to_pixel`).
fn getTextWidth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    return .{ .number = truncPixels(et.layout.text_width) };
}

fn getTextHeight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = laidOut(vm, this) orelse return .undefined_value;
    return .{ .number = truncPixels(et.layout.text_height) };
}

fn truncPixels(t: i32) f64 {
    return @floatFromInt(@divTrunc(t, 20));
}

// --- limits and bindings -------------------------------------------------------

/// Zero means "no limit" and reads back as NULL, not 0.
fn getMaxChars(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    if (et.max_chars == 0) return .null_value;
    return .{ .number = @floatFromInt(et.max_chars) };
}

fn setMaxChars(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    et.max_chars = try toI32(vm, arg(args, 0));
    return .undefined_value;
}

/// Unset reads NULL — one of the handful of AVM1 properties that does.
fn getVariable(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const v = et.variable orelse return .null_value;
    return .{ .string = try vm.arena().dupe(u16, v) };
}

fn setVariable(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    const v = arg(args, 0);
    const t = stage.targetOfValue(vm, this).?;
    // The old link goes first, wherever it pointed.
    text_binding.clearBinding(vm, t.obj);
    // Then the field is RESET to the text its tag was born with — not to
    // whatever it is showing (ruffle set_variable:863). That is why
    // re-pointing a field at a fresh variable puts the authored text back.
    var initial: []const u16 = &.{};
    var buf: [256]u16 = undefined;
    if (et.def) |d| if (d.initial_text) |it| {
        const n = @min(it.len, buf.len);
        for (it[0..n], 0..) |c, i| buf[i] = c;
        initial = buf[0..n];
    };
    try et.setText(gpa, initial);

    if (v == .undefined_value or v == .null_value) {
        try et.setVariable(gpa, null);
    } else {
        try et.setVariable(gpa, try vm.toStringValue(v));
    }
    if (!try text_binding.bind(vm, t.obj, true)) {
        try vm.unbound_text_fields.append(vm.arena(), t.obj);
    }
    return .undefined_value;
}

fn getRestrict(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const v = et.restrict orelse return .null_value;
    return .{ .string = try vm.arena().dupe(u16, v) };
}

/// The docs say an empty restrict forbids everything; AVM1 treats it as
/// null instead.
fn setRestrict(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v == .undefined_value or v == .null_value) {
        try et.setRestrict(gpa, null);
        return .undefined_value;
    }
    const s = try vm.toStringValue(v);
    try et.setRestrict(gpa, if (s.len == 0) null else s);
    return .undefined_value;
}

/// A field's `tabIndex` is a u32 where a clip's is an i32 — the same
/// stored value, reported unsigned. -4 reads back as 4294967292.
fn getTabIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const idx = t.obj.tab_index orelse return .undefined_value;
    return .{ .number = @floatFromInt(@as(u32, @bitCast(idx))) };
}

fn setTabIndex(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    if (v == .undefined_value or v == .null_value) {
        t.obj.tab_index = null;
        return .undefined_value;
    }
    // -1 is the spelling of "unset" whatever the object (ruffle
    // `set_tab_index`), so it never survives as a value.
    const n = try toI32(vm, v);
    t.obj.tab_index = if (n == -1) null else n;
    return .undefined_value;
}

// --- the SWF8 render block -------------------------------------------------------

fn getAntiAliasType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .string = if (et.advanced_rendering) S("advanced") else S("normal") };
}

/// Case SENSITIVE, and an unknown value is ignored rather than reset.
fn setAntiAliasType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    if (strings.eql(s, S("advanced"))) {
        et.advanced_rendering = true;
    } else if (strings.eql(s, S("normal"))) {
        et.advanced_rendering = false;
    }
    return .undefined_value;
}

fn getGridFitType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .string = switch (et.grid_fit) {
        .none => S("none"),
        .pixel => S("pixel"),
        .subpixel => S("subpixel"),
    } };
}

fn setGridFitType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    if (strings.eql(s, S("pixel"))) {
        et.grid_fit = .pixel;
    } else if (strings.eql(s, S("subpixel"))) {
        et.grid_fit = .subpixel;
    } else if (strings.eql(s, S("none"))) {
        et.grid_fit = .none;
    }
    return .undefined_value;
}

fn getThickness(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = et.thickness };
}

fn setThickness(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    et.thickness = asF32(try vm.toNumber(arg(args, 0)));
    return .undefined_value;
}

fn getSharpness(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .number = et.sharpness };
}

fn setSharpness(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    et.sharpness = asF32(try vm.toNumber(arg(args, 0)));
    return .undefined_value;
}

/// The render settings are f32 in the engine, and the narrowing is
/// observable on read-back.
fn asF32(n: f64) f64 {
    return @as(f64, @as(f32, @floatCast(n)));
}

fn getFilters(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    _ = etOf(vm, this) orelse return .undefined_value;
    return .{ .object = try vm.newArray() };
}

fn setFilters(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = .{ p, this, args };
    return .undefined_value;
}

fn getStyleSheet(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    if (et.style_sheet == 0) return .undefined_value;
    return .{ .object = et.style_sheet };
}

fn setStyleSheet(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const v = arg(args, 0);
    et.style_sheet = if (v == .object) v.object else 0;
    return .undefined_value;
}

// --- methods -------------------------------------------------------------------

fn removeTextField(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    if (t.obj.kind != .edit_text) return .undefined_value;
    _ = try stage.removeDisplayObject(vm, t);
    return .undefined_value;
}

/// `getNewTextFormat()` — the format the NEXT character typed would take.
fn getNewTextFormat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    return .{ .object = try text_format.newObject(vm, et.default_format) };
}

fn setNewTextFormat(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const tf = text_format.formatOf(vm, arg(args, 0)) orelse return .undefined_value;
    et.default_format = tf.*;
    return .undefined_value;
}

/// `getTextFormat([begin[, end]])` — no arguments means the whole field,
/// one means that single character.
fn getTextFormatFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    if (args.len >= 1) {
        const len = et.text.items.len;
        const from: usize = @intCast(@as(u32, @bitCast(try toI32(vm, args[0]))));
        const to: usize = if (args.len >= 2)
            @intCast(@as(u32, @bitCast(try toI32(vm, args[1]))))
        else
            from + 1;
        return .{ .object = try text_format.newObject(vm, et.formatRange(@min(from, len), @min(to, len))) };
    }
    return .{ .object = try text_format.newObject(vm, et.formatRange(0, et.text.items.len)) };
}

/// This writes the SPANS, never the new-text format — which is why
/// `setTextFormat({color: grey})` leaves `textColor` where it was
/// (corpus textfield_properties).
fn setTextFormatFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    // The format is the LAST argument whatever the arity — (fmt),
    // (begin, fmt) and (begin, end, fmt) are all legal, and each arity
    // means a different range.
    if (args.len == 0 or args.len > 3) return .undefined_value;
    const tf = text_format.formatOf(vm, args[args.len - 1]) orelse return .undefined_value;
    const len = et.text.items.len;
    var from: usize = 0;
    var to: usize = len;
    if (args.len >= 2) {
        from = @intCast(@as(u32, @bitCast(try toI32(vm, args[0]))));
        to = if (args.len == 3)
            @intCast(@as(u32, @bitCast(try toI32(vm, args[1]))))
        else
            from + 1;
    }
    try et.setFormatRange(gpa, @min(from, len), @min(to, len), tf.*);
    return .undefined_value;
}

/// `replaceText(from, to, text)` — indices are truncated f64s, and an
/// inverted or out-of-range pair simply clamps.
fn replaceText(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const et = etOf(vm, this) orelse return .undefined_value;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    const from = try vm.toNumber(arg(args, 0));
    const to = try vm.toNumber(arg(args, 1));
    const s = try vm.toStringValue(arg(args, 2));
    try et.replaceRange(gpa, clampIndex(from, et.text.items.len), clampIndex(to, et.text.items.len), s);
    return .undefined_value;
}

/// `replaceSel(text)` swaps the SELECTION for `text` and leaves the caret
/// after it. A field that has never been focused has no selection, and
/// then the insertion goes at position zero.
fn replaceSel(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = stage.targetOfValue(vm, this) orelse return .undefined_value;
    if (t.obj.kind != .edit_text) return .undefined_value;
    const et = t.obj.kind.edit_text;
    const gpa = gpaOf(vm) orelse return .undefined_value;
    const s = try vm.toStringValue(arg(args, 0));
    const sel = et.selection orelse edit_text_mod.Selection.at(0);
    try et.replaceRange(gpa, sel.start(), sel.end(), s);
    et.setSelection(edit_text_mod.Selection.at(sel.start() + s.len));
    try text_binding.propagate(vm, t.obj);
    return .undefined_value;
}

fn clampIndex(n: f64, len: usize) usize {
    if (std.math.isNan(n) or n <= 0) return 0;
    const t = @trunc(n);
    if (t >= @as(f64, @floatFromInt(len))) return len;
    return @intFromFloat(t);
}

