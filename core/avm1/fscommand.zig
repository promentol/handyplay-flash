//! `fscommand` and `fscommand2` — the seam a movie talks to its DEVICE
//! through.
//!
//! Two entry points, one table. `fscommand("cmd", "args")` arrives as a
//! `getURL` whose URL is `FSCommand:cmd` and whose TARGET is a single
//! argument string; `fscommand2` is opcode 0x2D, takes any number of
//! arguments and RETURNS a value. Neither is in the SWF specification's
//! action list and 0x2D is not in ruffle's opcode table either — the
//! shapes here come from disassembling the Flash Lite games in `games/`.
//!
//! **Nothing here ACTS.** The command is recognised, recorded and handed
//! to the host, which decides. That is not fastidiousness: ruffle's own
//! test framework ends every one of its 679 movies with
//! `fscommand("quit")`, so a core that quit on its own would truncate the
//! entire conformance corpus. Ruffle draws the line in the same place
//! (`core/src/avm1/fscommand.rs` forwards; only the desktop host acts).
//!
//! Three families of command, and which one you are in decides how the
//! answer comes back:
//!
//!   • ACTIONS — `SetSoftKeys`, `SetQuality`, `Quit` … — return 0.
//!   • NUMERIC getters — `GetBatteryLevel` … — return the number, and the
//!     script assigns it: `battery = fscommand2("GetBatteryLevel")`.
//!   • STRING getters — `GetDevice` … — take the NAME OF A VARIABLE as
//!     their argument, write the string into it, and return 0.
//!
//! Unknown commands return -1, which is Flash Lite's "not supported" and
//! what this whole file used to return for everything.

const std = @import("std");
const strings = @import("string.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");
const date = @import("globals/date.zig");

const Value = value_mod.Value;
const Vm = runtime.Vm;
const AvmString = strings.AvmString;
const S = strings.ascii;

/// What the host is told about every call, whether or not it acts on it.
pub const Call = struct {
    /// As written by the movie — `SetSoftkeys` and `SetSoftKeys` both
    /// occur in the wild, so a host comparing names should fold case.
    name: []const u8,
    args: []const []const u8,
    /// `.command` is `fscommand`, `.command2` is opcode 0x2D. A host may
    /// care: only the second can return a value.
    kind: enum { command, command2 },
    /// What we answered. -1 means nothing recognised the command.
    result: f64,
};

/// Flash Lite's answers to the questions a movie can ask about the
/// handset. Everything here is a POLITE FICTION except the clock, which
/// comes from the same deterministic source `Date` uses.
pub const DeviceInfo = struct {
    battery: i32 = 80,
    max_battery: i32 = 100,
    signal: i32 = 75,
    max_signal: i32 = 100,
    volume: i32 = 50,
    max_volume: i32 = 100,
    /// Bytes. Flash Lite reported these in bytes and games print them.
    total_memory: i32 = 8 * 1024 * 1024,
    free_memory: i32 = 4 * 1024 * 1024,
    /// 0 = battery, 1 = external power.
    power_source: i32 = 0,
    /// 1 = connected.
    network_connected: i32 = 1,
    device: []const u8 = "handyplay-flash",
    device_id: []const u8 = "0",
    platform: []const u8 = "handyplay-flash",
    language: []const u8 = "en",
    network_name: []const u8 = "handyplay-flash",
    /// The CONNECTION's name, which on a handset was the APN and not the
    /// operator — a different question from `GetNetworkName`, and the
    /// games ask both.
    network_connection_name: []const u8 = "handyplay-flash",
    network_generation: []const u8 = "none",
    /// `GetNetworkStatus`: 1 is "registered with the home network", the
    /// only state a player with no radio can honestly claim to be in.
    network_status: i32 = 1,
    /// `GetSoftKeyLocation`: 0 means the strip is at the BOTTOM of the
    /// screen, which is where this player draws it.
    soft_key_location: i32 = 0,
};

/// Where a command's answer goes. The caller — `fscommand2`'s opcode arm
/// or the `fscommand:` URL sites — turns this into whatever it needs.
pub const Outcome = union(enum) {
    /// Push this (or, for plain `fscommand`, discard it).
    number: f64,
    /// Write `text` into the variable named `into`, then answer 0.
    variable: struct { into: AvmString, text: []const u8 },
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Case-insensitive because the games are: `SetSoftKeys` and
/// `SetSoftkeys`, `High` and `high`, appear in the same corpus.
pub fn dispatch(vm: *Vm, name: []const u8, args: []const []const u8) Outcome {
    const d = &vm.device;

    // --- the numbers a handset knows about itself -------------------------
    if (eq(name, "GetBatteryLevel")) return num(d.battery);
    if (eq(name, "GetMaxBatteryLevel")) return num(d.max_battery);
    if (eq(name, "GetSignalLevel")) return num(d.signal);
    if (eq(name, "GetMaxSignalLevel")) return num(d.max_signal);
    if (eq(name, "GetVolumeLevel")) return num(d.volume);
    if (eq(name, "GetMaxVolumeLevel")) return num(d.max_volume);
    if (eq(name, "GetPowerSource")) return num(d.power_source);
    if (eq(name, "GetTotalPlayerMemory")) return num(d.total_memory);
    if (eq(name, "GetFreePlayerMemory")) return num(d.free_memory);
    if (eq(name, "GetTotalObjectMemory")) return num(d.total_memory);
    if (eq(name, "GetFreeObjectMemory")) return num(d.free_memory);
    if (eq(name, "GetNetworkConnectStatus")) return num(d.network_connected);
    if (eq(name, "GetNetworkRequestStatus")) return num(0);
    if (eq(name, "GetNetworkStatus")) return num(d.network_status);
    if (eq(name, "GetSoftKeyLocation")) return num(d.soft_key_location);
    // Flash Lite reports the offset the way `Date` does not: LOCAL minus
    // UTC, so a zone ahead of UTC is positive.
    if (eq(name, "GetTimeZoneOffset")) return num(vm.tz_offset_min);

    // --- the clock, on `Date`'s deterministic one -------------------------
    if (eq(name, "GetTimeHours") or eq(name, "GetTimeMinutes") or
        eq(name, "GetTimeSeconds") or eq(name, "GetDateYear") or
        eq(name, "GetDateMonth") or eq(name, "GetDateDay") or
        eq(name, "GetDateWeekday"))
    {
        const t = date.localNow(vm);
        if (eq(name, "GetTimeHours")) return num(t.hours);
        if (eq(name, "GetTimeMinutes")) return num(t.minutes);
        if (eq(name, "GetTimeSeconds")) return num(t.seconds);
        if (eq(name, "GetDateYear")) return num(t.year);
        // Flash Lite counts months from ONE, unlike `Date`.
        if (eq(name, "GetDateMonth")) return num(t.month + 1);
        if (eq(name, "GetDateDay")) return num(t.date);
        return num(t.weekday);
    }

    // --- the locale strings, formatted from the same clock ----------------
    // en-US shapes, because `GetLanguage` says "en". A real handset asked
    // its own locale database; there is none here to ask.
    if (eq(name, "GetLocaleLongDate") or eq(name, "GetLocaleShortDate") or
        eq(name, "GetLocaleTime"))
    {
        const t = date.localNow(vm);
        const a = vm.arena();
        const formatted: ?[]const u8 = if (eq(name, "GetLocaleShortDate"))
            std.fmt.allocPrint(a, "{d}/{d}/{d}", .{ t.month + 1, t.date, t.year }) catch null
        else if (eq(name, "GetLocaleLongDate"))
            std.fmt.allocPrint(a, "{s}, {s} {d}, {d}", .{
                WEEKDAYS[@intCast(@mod(t.weekday, 7))],
                MONTHS[@intCast(@mod(t.month, 12))],
                t.date,
                t.year,
            }) catch null
        else blk: {
            const h12: i32 = if (@mod(t.hours, 12) == 0) 12 else @mod(t.hours, 12);
            // Unsigned, or the zero fill pads a SIGN into the minutes.
            const mins: u32 = @intCast(@mod(t.minutes, 60));
            break :blk std.fmt.allocPrint(a, "{d}:{d:0>2} {s}", .{
                h12, mins, if (t.hours < 12) "AM" else "PM",
            }) catch null;
        };
        if (formatted) |f| {
            if (args.len == 0) return num(0);
            return .{ .variable = .{ .into = latin1(vm, args[0]), .text = f } };
        }
        return num(0);
    }

    // --- the strings, which go into a variable the caller names -----------
    const text: ?[]const u8 =
        if (eq(name, "GetDevice")) d.device
        else if (eq(name, "GetDeviceID")) d.device_id
        else if (eq(name, "GetPlatform")) d.platform
        else if (eq(name, "GetLanguage")) d.language
        else if (eq(name, "GetNetworkName")) d.network_name
        else if (eq(name, "GetNetworkConnectionName")) d.network_connection_name
        else if (eq(name, "GetNetworkGeneration")) d.network_generation
        else null;
    if (text) |t| {
        // No variable to write into is not an error: the command still
        // succeeded, it just had nowhere to put the answer.
        if (args.len == 0) return num(0);
        return .{ .variable = .{ .into = latin1(vm, args[0]), .text = t } };
    }

    // --- actions ----------------------------------------------------------
    // Everything the host might act on, plus the ones that are honestly
    // nothing on a desktop. They all report SUCCESS, because a game that
    // is told `StartVibrate` failed may decide it is on a broken handset.
    if (eq(name, "FullScreen") or eq(name, "SetQuality") or
        eq(name, "SetSoftKeys") or eq(name, "ResetSoftKeys") or
        eq(name, "StartVibrate") or eq(name, "StopVibrate") or
        eq(name, "ExtendBacklightDuration") or eq(name, "SetInputTextType") or
        eq(name, "SetFocusRectColor") or
        eq(name, "Quit") or eq(name, "Escape") or
        // The classic desktop set, which only reaches here through plain
        // `fscommand`.
        eq(name, "allowscale") or eq(name, "showmenu") or
        eq(name, "trapallkeys") or eq(name, "exec"))
    {
        return num(0);
    }

    return num(-1);
}

const WEEKDAYS = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const MONTHS = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

fn num(n: anytype) Outcome {
    return .{ .number = @floatFromInt(n) };
}

/// A command argument is a plain name; widening it is all the caller
/// needs to feed it back into the variable machinery.
fn latin1(vm: *Vm, s: []const u8) AvmString {
    const out = vm.arena().alloc(u16, s.len) catch return S("");
    for (s, out) |c, *o| o.* = c;
    return out;
}

test "the command families answer in the right shape" {
    // A table test needs a Vm, which these unit tests do not build; the
    // shapes are covered by tests/as2/fscommand2 end to end. What CAN be
    // checked here is the case folding the games depend on.
    try std.testing.expect(eq("SetSoftkeys", "SetSoftKeys"));
    try std.testing.expect(eq("HIGH", "high"));
    try std.testing.expect(!eq("GetDevice", "GetDeviceID"));
}
