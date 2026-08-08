//! AsBroadcaster and the objects built on it — Key, Mouse, Stage — plus
//! System and Color.
//!
//! AsBroadcaster is the listener protocol the rest of AVM1 is wired with:
//! `initialize(obj)` bolts `_listeners`, `addListener`, `removeListener`
//! and `broadcastMessage` onto any object, and Key/Mouse/Stage are just
//! ordinary objects that have had it done to them. Nothing about it is
//! privileged, which is why content can and does broadcast its own events.
//!
//! Reference: reference/ruffle/core/src/avm1/globals/{as_broadcaster,key,
//! mouse,stage,system,system_security,color}.rs.

const std = @import("std");
const swf = @import("../../swf/swf.zig");
const strings = @import("../string.zig");
const value_mod = @import("../value.zig");
const runtime = @import("../runtime.zig");
const object_mod = @import("../object.zig");
const stage_object = @import("../stage_object.zig");
const decl = @import("decl.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const ObjectHandle = runtime.ObjectHandle;
const S = strings.ascii;

const vmOf = decl.vmOf;
const arg = decl.arg;
const method = decl.method;
const hidden = decl.hidden;
const frozen = decl.frozen;

pub fn install(vm: *Vm) !void {
    // --- AsBroadcaster -------------------------------------------------------
    // It is a FUNCTION (`typeof AsBroadcaster` is "function") that also
    // carries the four members, so `new AsBroadcaster()` yields a plain
    // object and `AsBroadcaster.initialize(x)` works.
    // ONE function object each, shared by every broadcaster: Flash's
    // `Key.addListener == Mouse.addListener` is true.
    vm.bc_add_listener = try vm.newNativeFn(bcAddListener);
    vm.bc_remove_listener = try vm.newNativeFn(bcRemoveListener);
    vm.bc_broadcast_message = try vm.newNativeFn(bcBroadcastMessage);
    const bc = try vm.newNativeFn(bcCtor);
    // Its own prototype object, NOT Object.prototype — otherwise every
    // plain object would answer true to `instanceof AsBroadcaster`.
    const bc_proto = try vm.objects.create();
    vm.objects.get(bc_proto).proto = .{ .object = vm.object_proto };
    try vm.objects.putWithAttrs(bc, S("prototype"), .{ .object = bc_proto }, hidden, false);
    try vm.objects.putWithAttrs(vm.globals, S("AsBroadcaster"), .{ .object = bc }, .{ .dont_enum = true }, false);
    try method(vm, bc, "initialize", bcInitialize, hidden);
    // AsBroadcaster carries the SAME three function objects it hands out,
    // so `Key.addListener == AsBroadcaster.addListener` holds.
    try makeBroadcasterMethods(vm, bc);

    // --- Key -----------------------------------------------------------------
    const key = try decl.namespace(vm, "Key", .{ .dont_enum = true });
    vm.key_object = key;
    try makeBroadcaster(vm, key);
    try decl.constNum(vm, key, "BACKSPACE", 8);
    try decl.constNum(vm, key, "TAB", 9);
    try decl.constNum(vm, key, "ENTER", 13);
    try decl.constNum(vm, key, "SHIFT", 16);
    try decl.constNum(vm, key, "CONTROL", 17);
    try decl.constNum(vm, key, "ALT", 18);
    try decl.constNum(vm, key, "CAPSLOCK", 20);
    try decl.constNum(vm, key, "ESCAPE", 27);
    try decl.constNum(vm, key, "SPACE", 32);
    try decl.constNum(vm, key, "PGUP", 33);
    try decl.constNum(vm, key, "PGDN", 34);
    try decl.constNum(vm, key, "END", 35);
    try decl.constNum(vm, key, "HOME", 36);
    try decl.constNum(vm, key, "LEFT", 37);
    try decl.constNum(vm, key, "UP", 38);
    try decl.constNum(vm, key, "RIGHT", 39);
    try decl.constNum(vm, key, "DOWN", 40);
    try decl.constNum(vm, key, "INSERT", 45);
    try decl.constNum(vm, key, "DELETEKEY", 46);
    try method(vm, key, "getAscii", keyGetAscii, frozen);
    try method(vm, key, "getCode", keyGetCode, frozen);
    try method(vm, key, "isDown", keyIsDown, frozen);
    try method(vm, key, "isToggled", keyIsToggled, frozen);

    // --- Mouse ---------------------------------------------------------------
    const mouse = try decl.namespace(vm, "Mouse", .{ .dont_enum = true });
    vm.mouse_object = mouse;
    try makeBroadcaster(vm, mouse);
    try method(vm, mouse, "show", mouseShow, frozen);
    try method(vm, mouse, "hide", mouseHide, frozen);
    try method(vm, mouse, "setTrailer", noop, frozen);
    try method(vm, mouse, "setTrailerPosition", noop, frozen);
    try method(vm, mouse, "setTrailerMode", noop, frozen);

    // --- Stage ---------------------------------------------------------------
    const stage = try decl.namespace(vm, "Stage", .{ .dont_enum = true });
    vm.stage_object_handle = stage;
    try makeBroadcaster(vm, stage);
    try decl.property(vm, stage, "width", stageWidth, null, .{});
    try decl.property(vm, stage, "height", stageHeight, null, .{});
    try decl.property(vm, stage, "align", stageGetAlign, stageSetAlign, .{});
    try decl.property(vm, stage, "scaleMode", stageGetScaleMode, stageSetScaleMode, .{});
    try decl.property(vm, stage, "showMenu", stageGetShowMenu, stageSetShowMenu, .{});
    try decl.property(vm, stage, "displayState", stageGetDisplayState, stageSetDisplayState, .{});

    // --- System --------------------------------------------------------------
    const system = try decl.namespace(vm, "System", .{ .dont_enum = true });
    try decl.property(vm, system, "useCodepage", sysGetUseCodepage, sysSetUseCodepage, .{});
    try decl.property(vm, system, "exactSettings", sysGetExactSettings, sysSetExactSettings, decl.ver(.{}, decl.V6));
    try method(vm, system, "setClipboard", noop, .{});
    try method(vm, system, "showSettings", noop, .{});
    try method(vm, system, "onStatus", noop, .{});
    // System.IME is a broadcaster with a fixed, disabled profile.
    const ime = try decl.subObject(vm, system, "IME", .{});
    try makeBroadcaster(vm, ime);
    inline for (.{
        "UNKNOWN",                "KOREAN",            "JAPANESE_KATAKANA_HALF",
        "JAPANESE_KATAKANA_FULL", "JAPANESE_HIRAGANA", "CHINESE",
        "ALPHANUMERIC_HALF",      "ALPHANUMERIC_FULL",
    }) |name| {
        try decl.constStr(vm, ime, name, name);
    }
    try method(vm, ime, "getEnabled", falseFn, frozen);
    try method(vm, ime, "setEnabled", falseFn, frozen);
    try method(vm, ime, "getConversionMode", imeUnknown, frozen);
    try method(vm, ime, "setConversionMode", falseFn, frozen);
    try method(vm, ime, "setCompositionString", falseFn, frozen);
    try method(vm, ime, "doConversion", falseFn, frozen);
    try method(vm, ime, "onIMEComposition", noop, frozen);

    const security = try decl.subObject(vm, system, "security", .{});
    try decl.property(vm, security, "sandboxType", secSandboxType, null, .{});
    try method(vm, security, "allowDomain", noop, .{});
    try method(vm, security, "allowInsecureDomain", noop, .{});
    try method(vm, security, "loadPolicyFile", noop, .{});
    const caps = try decl.subObject(vm, system, "capabilities", .{});
    try installCapabilities(vm, caps);
    // Flash exposes the same object twice, capitalised differently.
    try vm.objects.putWithAttrs(system, S("Capabilities"), .{ .object = caps }, .{}, false);

    // --- MovieClipLoader ------------------------------------------------------
    // Loading needs I/O, which `core/` does not do, so the methods are
    // honest stubs — `loadClip` reports failure rather than pretending.
    // The class exists now because it is a BROADCASTER, and content (and
    // the corpus) checks that its listener protocol is the shared one.
    {
        const mcl_proto = try vm.objects.create();
        vm.objects.get(mcl_proto).proto = .{ .object = vm.object_proto };
        try makeBroadcaster(vm, mcl_proto);
        try method(vm, mcl_proto, "loadClip", falseFn, hidden);
        try method(vm, mcl_proto, "unloadClip", falseFn, hidden);
        try method(vm, mcl_proto, "getProgress", noop, hidden);
        const mcl = try decl.class(vm, "MovieClipLoader", mclCtor, mcl_proto, .{ .dont_enum = true });
        // Ruffle initialises the PROTOTYPE, so the statics resolve through
        // it; mirror that by exposing the same shared functions here.
        try makeBroadcasterMethods(vm, mcl);
    }

    // --- Color ---------------------------------------------------------------
    const color_proto = try vm.objects.create();
    vm.objects.get(color_proto).proto = .{ .object = vm.object_proto };
    try method(vm, color_proto, "setRGB", colorSetRgb, frozen);
    try method(vm, color_proto, "getRGB", colorGetRgb, frozen);
    try method(vm, color_proto, "setTransform", colorSetTransform, frozen);
    try method(vm, color_proto, "getTransform", colorGetTransform, frozen);
    _ = try decl.class(vm, "Color", colorCtor, color_proto, .{ .dont_enum = true });
}

/// A fresh MovieClipLoader listens to ITSELF (ruffle movie_clip_loader.rs
/// constructor seeds `_listeners` with `this`).
fn mclCtor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    const list = try vm.newArray();
    try vm.arraySet(list, 0, this);
    try vm.setArrayLength(list, 1);
    try vm.objects.putWithAttrs(this.object, S("_listeners"), .{ .object = list }, .{ .dont_enum = true }, false);
    return this;
}

fn falseFn(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .boolean = false };
}

fn imeUnknown(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .{ .string = S("UNKNOWN") };
}

fn noop(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = this;
    _ = args;
    return .undefined_value;
}

// --- AsBroadcaster --------------------------------------------------------------

/// Bolt the listener protocol onto `target`. All four members are
/// DONT_ENUM | DONT_DELETE, including `_listeners` — content reads it but
/// `for..in` must not.
pub fn makeBroadcaster(vm: *Vm, target: ObjectHandle) !void {
    const list = try vm.newArray();
    try vm.objects.putWithAttrs(target, S("_listeners"), .{ .object = list }, hidden, false);
    try makeBroadcasterMethods(vm, target);
}

fn makeBroadcasterMethods(vm: *Vm, target: ObjectHandle) !void {
    try vm.objects.putWithAttrs(target, S("broadcastMessage"), .{ .object = vm.bc_broadcast_message }, hidden, false);
    try vm.objects.putWithAttrs(target, S("addListener"), .{ .object = vm.bc_add_listener }, hidden, false);
    try vm.objects.putWithAttrs(target, S("removeListener"), .{ .object = vm.bc_remove_listener }, hidden, false);
}

fn bcCtor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return this;
}

fn bcInitialize(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const target = arg(args, 0);
    if (target != .object) return .undefined_value;
    try makeBroadcaster(vm, target.object);
    return .undefined_value;
}

fn listenersOf(vm: *Vm, this: Value) ?ObjectHandle {
    if (this != .object) return null;
    const v = vm.objects.getChained(this.object, S("_listeners"), vm.case_sensitive) orelse return null;
    return if (v == .object) v.object else null;
}

/// Re-adding a listener that is already registered REPLACES it in place
/// rather than appending, so it keeps its position in the broadcast order.
fn bcAddListener(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const listener = arg(args, 0);
    const list = listenersOf(vm, this) orelse return .{ .boolean = true };
    const len = vm.arrayLength(list);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const existing = try elementAt(vm, list, i);
        if (try vm.abstractEquals(existing, listener)) {
            try vm.arraySet(list, i, listener);
            return .{ .boolean = true };
        }
    }
    try vm.arraySet(list, len, listener);
    try vm.setArrayLength(list, len + 1);
    return .{ .boolean = true };
}

fn bcRemoveListener(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const listener = arg(args, 0);
    const list = listenersOf(vm, this) orelse return .{ .boolean = false };
    const len = vm.arrayLength(list);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const existing = try elementAt(vm, list, i);
        if (!try vm.abstractEquals(existing, listener)) continue;
        // Shift the tail down; `splice` would do the same and this avoids
        // depending on Array.prototype still being the real one.
        var j = i;
        while (j + 1 < len) : (j += 1) {
            try vm.arraySet(list, j, try elementAt(vm, list, j + 1));
        }
        _ = vm.objects.deleteOwn(list, try indexName(vm, len - 1), vm.case_sensitive);
        try vm.setArrayLength(list, len - 1);
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn bcBroadcastMessage(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    // A MISSING argument gives up (returns undefined); an argument that
    // merely IS undefined coerces like any other value — "undefined" above
    // SWF6, "" below it (ruffle as_broadcaster.rs:136, UndefinedAs::Some).
    if (args.len == 0) return .undefined_value;
    const name = try vm.toStringValue(args[0]);
    _ = try broadcast(vm, this, name, if (args.len > 1) args[1..] else &.{});
    return .{ .boolean = true };
}

/// Call `name` on every listener, in order. Returns whether there were any
/// — that is how the engine's own broadcasts (onMouseMove and friends) know
/// whether anything is listening.
pub fn broadcast(vm: *Vm, target: Value, name: strings.AvmString, args: []const Value) !bool {
    const list = listenersOf(vm, target) orelse return false;
    const len = vm.arrayLength(list);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const listener = try elementAt(vm, list, i);
        if (listener != .object) continue;
        // A clip that has been removed stops receiving broadcasts even
        // though the listener list still holds it — the same rule timers
        // follow (ruffle: every member read on a removed display object is
        // undefined). Corpus string_paths_keyevents expects silence.
        if (stage_object.isRemovedClip(vm, listener.object)) continue;
        // An EMPTY method name calls the listener ITSELF as a function —
        // `broadcastMessage("")`, and every broadcast below SWF7 whose
        // event name coerced away (ruffle as_broadcaster.rs:160).
        const f = if (name.len == 0)
            listener
        else
            try vm.getProperty(listener.object, name, listener);
        if (!vm.isCallable(f)) continue;
        _ = vm.callFunction(f, listener, args) catch |e| {
            if (e == error.Avm1Thrown) vm.pending_throw = .undefined_value;
        };
    }
    return len > 0;
}

fn indexName(vm: *Vm, i: u32) !strings.AvmString {
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
    const wide = try vm.arena().alloc(u16, s.len);
    for (s, 0..) |c, k| wide[k] = c;
    return wide;
}

fn elementAt(vm: *Vm, array: ObjectHandle, i: u32) !Value {
    const name = try indexName(vm, i);
    return vm.objects.getChained(array, name, vm.case_sensitive) orelse .undefined_value;
}

// --- Key ---------------------------------------------------------------------------

fn keyGetAscii(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).last_key_char) };
}

fn keyGetCode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).last_key_code) };
}

fn keyIsDown(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const code = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    return .{ .boolean = vm.keyDown(code) };
}

/// Caps/Num/Scroll Lock only. Flash reports the real OS state; we report
/// what the frontend has told us, which is a toggle flipped on each press.
fn keyIsToggled(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const code = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    return .{ .boolean = vm.keyToggled(code) };
}

// --- Mouse ---------------------------------------------------------------------------

fn mouseShow(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    vmOf(p).mouse_hidden = false;
    return .undefined_value;
}

fn mouseHide(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    vmOf(p).mouse_hidden = true;
    return .undefined_value;
}

// --- Stage -----------------------------------------------------------------------------

fn stageWidth(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).stage_width) };
}

fn stageHeight(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).stage_height) };
}

/// The alignment string is a SET of letters, re-emitted in canonical
/// order: writing "BR" reads back as "RB", and any letter anywhere in the
/// string counts — `Stage.align = true` stringifies to "true" and thereby
/// sets Top and Right.
fn stageGetAlign(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    var buf: [4]u16 = undefined;
    var n: usize = 0;
    // All four can be set at once — an oxymoronic "LTRB" is legal and
    // reads back verbatim — and the order is always L, T, R, B regardless
    // of how they were written.
    inline for (.{
        .{ vm.stage_align_left, 'L' },
        .{ vm.stage_align_top, 'T' },
        .{ vm.stage_align_right, 'R' },
        .{ vm.stage_align_bottom, 'B' },
    }) |e| {
        if (e[0]) {
            buf[n] = e[1];
            n += 1;
        }
    }
    return .{ .string = try vm.arena().dupe(u16, buf[0..n]) };
}

fn stageSetAlign(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    vm.stage_align_left = false;
    vm.stage_align_right = false;
    vm.stage_align_top = false;
    vm.stage_align_bottom = false;
    for (s) |ch| switch (ch) {
        'l', 'L' => vm.stage_align_left = true,
        'r', 'R' => vm.stage_align_right = true,
        't', 'T' => vm.stage_align_top = true,
        'b', 'B' => vm.stage_align_bottom = true,
        else => {},
    };
    return .undefined_value;
}

const SCALE_MODES = [_][]const u16{
    S("showAll"), S("noBorder"), S("exactFit"), S("noScale"),
};

fn stageGetScaleMode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .string = SCALE_MODES[vmOf(p).stage_scale_mode] };
}

/// An unrecognised mode RESETS to showAll rather than leaving the current
/// one alone (ruffle: `parse().unwrap_or_default()`).
fn stageSetScaleMode(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    vm.stage_scale_mode = 0;
    for (SCALE_MODES, 0..) |name, i| {
        if (strings.eqlIgnoreCase(s, name)) {
            vm.stage_scale_mode = @intCast(i);
            return .undefined_value;
        }
    }
    return .undefined_value;
}

fn stageGetShowMenu(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .boolean = vmOf(p).stage_show_menu };
}

fn stageSetShowMenu(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    vm.stage_show_menu = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    return .undefined_value;
}

fn stageGetDisplayState(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .string = if (vmOf(p).stage_full_screen) S("fullScreen") else S("normal") };
}

/// Only the two exact names (case-insensitively) do anything; everything
/// else is ignored. Changing it broadcasts `onFullScreen` to Stage's
/// listeners.
fn stageSetDisplayState(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const s = try vm.toStringValue(arg(args, 0));
    const want: ?bool = if (strings.eqlIgnoreCase(s, S("fullscreen")))
        true
    else if (strings.eqlIgnoreCase(s, S("normal")))
        false
    else
        null;
    const target = want orelse return .undefined_value;
    if (target == vm.stage_full_screen) return .undefined_value;
    vm.stage_full_screen = target;
    _ = try broadcast(vm, this, S("onFullScreen"), &.{.{ .boolean = target }});
    return .undefined_value;
}

// --- System -----------------------------------------------------------------------------

fn sysGetUseCodepage(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .boolean = vmOf(p).use_codepage };
}

fn sysSetUseCodepage(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    vm.use_codepage = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    return .undefined_value;
}

fn sysGetExactSettings(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .boolean = vmOf(p).exact_settings };
}

fn sysSetExactSettings(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    const vm = vmOf(p);
    vm.exact_settings = value_mod.toBoolean(arg(args, 0), vm.swf_version);
    return .undefined_value;
}

/// We only ever play local files, so the choice is between the two LOCAL
/// sandboxes and it is the movie's own `FileAttributes.UseNetwork` bit that
/// decides (ruffle system_security.rs + SwfMovie::sandbox_type).
fn secSandboxType(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    const vm = vmOf(p);
    return .{ .string = if (vm.use_network_sandbox) S("localWithNetwork") else S("localWithFile") };
}

/// A fixed profile. Everything here is a claim about the host, and a wrong
/// claim is worse than a conservative one: we advertise no encoders, no
/// streaming and no printing rather than pretending.
fn installCapabilities(vm: *Vm, caps: ObjectHandle) !void {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try decl.value(vm, caps, "hasAudio", t, .{});
    try decl.value(vm, caps, "hasMP3", t, .{});
    try decl.value(vm, caps, "hasAccessibility", f, .{});
    try decl.value(vm, caps, "hasAudioEncoder", f, .{});
    try decl.value(vm, caps, "hasVideoEncoder", f, .{});
    try decl.value(vm, caps, "hasEmbeddedVideo", f, .{});
    try decl.value(vm, caps, "hasStreamingAudio", f, .{});
    try decl.value(vm, caps, "hasStreamingVideo", f, .{});
    try decl.value(vm, caps, "hasPrinting", f, .{});
    try decl.value(vm, caps, "hasScreenBroadcast", f, .{});
    try decl.value(vm, caps, "hasScreenPlayback", f, .{});
    try decl.value(vm, caps, "hasTLS", t, .{});
    try decl.value(vm, caps, "hasIME", f, .{});
    try decl.value(vm, caps, "isDebugger", f, .{});
    try decl.value(vm, caps, "avHardwareDisable", f, .{});
    try decl.value(vm, caps, "localFileReadDisable", f, .{});
    try decl.value(vm, caps, "windowlessDisable", f, .{});
    try decl.value(vm, caps, "isEmbeddedInAcrobat", f, .{});
    try decl.value(vm, caps, "supports32BitProcesses", t, .{});
    try decl.value(vm, caps, "supports64BitProcesses", t, .{});
    try decl.constStr(vm, caps, "playerType", "StandAlone");
    try decl.constStr(vm, caps, "screenColor", "color");
    try decl.constStr(vm, caps, "manufacturer", "Adobe Macintosh");
    try decl.constStr(vm, caps, "os", "Mac OS 10.6");
    try decl.constStr(vm, caps, "cpuArchitecture", "x86");
    try decl.constStr(vm, caps, "language", "en");
    try decl.constStr(vm, caps, "version", "MAC 32,0,0,465");
    try decl.value(vm, caps, "pixelAspectRatio", .{ .number = 1 }, .{});
    try decl.value(vm, caps, "screenDPI", .{ .number = 72 }, .{});
    try decl.value(vm, caps, "maxLevelIDC", .{ .number = 5.1 }, .{});
    try decl.property(vm, caps, "screenResolutionX", capsScreenX, null, .{});
    try decl.property(vm, caps, "screenResolutionY", capsScreenY, null, .{});
}

fn capsScreenX(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).screen_width) };
}

fn capsScreenY(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = this;
    _ = args;
    return .{ .number = @floatFromInt(vmOf(p).screen_height) };
}

// --- Color -------------------------------------------------------------------------------

/// `new Color(mc)` keeps its subject in a plain `target` property — Flash
/// does, and content reads it.
fn colorCtor(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    if (this != .object) return .undefined_value;
    try vm.objects.put(this.object, S("target"), arg(args, 0), vm.case_sensitive);
    return this;
}

fn colorTarget(vm: *Vm, this: Value) ?stage_object.Target {
    if (this != .object) return null;
    const v = vm.objects.getChained(this.object, S("target"), vm.case_sensitive) orelse return null;
    return stage_object.targetOfValue(vm, v);
}

/// The RGB the clip is tinted TO: the offsets when the multipliers have
/// been zeroed by `setRGB`, otherwise whatever the offsets happen to be.
fn colorGetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = colorTarget(vm, this) orelse return .undefined_value;
    const ct = t.obj.color_transform;
    // No masking: the offsets are signed and a negative one really does
    // make the composite negative (ruffle color.rs get_rgb).
    const r: i32 = @as(i32, ct.add[0]) << 16;
    const g: i32 = @as(i32, ct.add[1]) << 8;
    const b: i32 = ct.add[2];
    return .{ .number = @floatFromInt(r | g | b) };
}

/// A flat tint: zero the colour multipliers and put the components in the
/// offsets. Alpha is left alone.
fn colorSetRgb(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = colorTarget(vm, this) orelse return .undefined_value;
    const rgb = value_mod.toInt32(try vm.toNumber(arg(args, 0)));
    var ct = t.obj.color_transform;
    ct.mult[0] = 0;
    ct.mult[1] = 0;
    ct.mult[2] = 0;
    ct.add[0] = @intCast((rgb >> 16) & 0xFF);
    ct.add[1] = @intCast((rgb >> 8) & 0xFF);
    ct.add[2] = @intCast(rgb & 0xFF);
    t.obj.color_transform = ct;
    t.obj.transformed_by_script = true;
    return .undefined_value;
}

/// The `{ra, rb, ga, gb, ba, bb, aa, ab}` shape: `?a` are PERCENTAGES of
/// the 8.8 multiplier, `?b` the raw offsets.
fn colorGetTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    _ = args;
    const vm = vmOf(p);
    const t = colorTarget(vm, this) orelse return .undefined_value;
    const ct = t.obj.color_transform;
    const h = try vm.newObject();
    const mult_keys = [_][]const u16{ S("ra"), S("ga"), S("ba"), S("aa") };
    const add_keys = [_][]const u16{ S("rb"), S("gb"), S("bb"), S("ab") };
    inline for (0..4) |i| {
        const pct = @as(f64, @floatFromInt(ct.mult[i])) / 256.0 * 100.0;
        try vm.objects.put(h, mult_keys[i], .{ .number = pct }, vm.case_sensitive);
        try vm.objects.put(h, add_keys[i], .{ .number = @floatFromInt(ct.add[i]) }, vm.case_sensitive);
    }
    return .{ .object = h };
}

/// Only the keys actually present are applied — a partial object leaves the
/// rest of the transform untouched.
fn colorSetTransform(p: *anyopaque, this: Value, args: []const Value) anyerror!Value {
    const vm = vmOf(p);
    const t = colorTarget(vm, this) orelse return .undefined_value;
    const src = arg(args, 0);
    if (src != .object) return .undefined_value;
    var ct = t.obj.color_transform;
    const mult_keys = [_][]const u16{ S("ra"), S("ga"), S("ba"), S("aa") };
    const add_keys = [_][]const u16{ S("rb"), S("gb"), S("bb"), S("ab") };
    inline for (0..4) |i| {
        // OWN properties only — an inherited `ra` is ignored — and both
        // conversions WRAP as i16 rather than clamping, so an out-of-range
        // percentage comes back out the other side.
        if (vm.objects.getOwn(src.object, mult_keys[i], vm.case_sensitive)) |v| {
            ct.mult[i] = wrapI16(try vm.toNumber(v) * 256.0 / 100.0);
        }
        if (vm.objects.getOwn(src.object, add_keys[i], vm.case_sensitive)) |v| {
            ct.add[i] = wrapI16(try vm.toNumber(v));
        }
    }
    t.obj.color_transform = ct;
    t.obj.transformed_by_script = true;
    return .undefined_value;
}

/// ECMA ToInt32 then truncate — ruffle's `f64_to_wrapping_i16`.
fn wrapI16(n: f64) i16 {
    return @truncate(value_mod.toInt32(n));
}

// --- Tests --------------------------------------------------------------------------------

const testing = std.testing;

test "AsBroadcaster: add replaces in place, remove closes the gap" {
    const vm = try Vm.create(testing.allocator, 8);
    defer vm.destroy();
    const target = try vm.newObject();
    try makeBroadcaster(vm, target);
    const tv: Value = .{ .object = target };

    const a: Value = .{ .object = try vm.newObject() };
    const b: Value = .{ .object = try vm.newObject() };
    _ = try bcAddListener(@ptrCast(vm), tv, &.{a});
    _ = try bcAddListener(@ptrCast(vm), tv, &.{b});
    const list = listenersOf(vm, tv).?;
    try testing.expectEqual(@as(u32, 2), vm.arrayLength(list));

    // Re-adding keeps the position rather than appending a duplicate.
    _ = try bcAddListener(@ptrCast(vm), tv, &.{a});
    try testing.expectEqual(@as(u32, 2), vm.arrayLength(list));
    try testing.expectEqual(a.object, (try elementAt(vm, list, 0)).object);

    _ = try bcRemoveListener(@ptrCast(vm), tv, &.{a});
    try testing.expectEqual(@as(u32, 1), vm.arrayLength(list));
    try testing.expectEqual(b.object, (try elementAt(vm, list, 0)).object);
    // Removing something that was never there is false, not an error.
    const again = try bcRemoveListener(@ptrCast(vm), tv, &.{a});
    try testing.expect(!again.boolean);

    // `_listeners` must not turn up in `for..in`.
    const slot = vm.objects.findOwn(target, S("_listeners"), false).?;
    try testing.expect(slot.attrs.dont_enum and slot.attrs.dont_delete);
}
