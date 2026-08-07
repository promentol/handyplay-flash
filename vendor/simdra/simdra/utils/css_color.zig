//! CSS color string parser for the canvas color properties.
//! Supports: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(), hsla(),
//! and the full CSS Color Level 4 named-color set.
//!
//! Returns a u32 packed as packRGBA(r, g, b, a):
//!   bits  0-7  → R
//!   bits  8-15 → G
//!   bits 16-23 → B
//!   bits 24-31 → A
//!
//! Returns null for any unrecognised or out-of-range input; the caller
//! (fillStyle / strokeStyle setters) must treat null as a no-op.

const std = @import("std");
const types = @import("../core/types.zig");

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn parse(s: []const u8) ?u32 {
    const t = trim(s);
    if (t.len == 0) return null;

    if (t[0] == '#') return parseHex(t[1..]);
    if (startsWith(t, "rgba(")) return parseRgba(t[5 .. t.len - 1]);
    if (startsWith(t, "rgb(")) return parseRgba(t[4 .. t.len - 1]);
    if (startsWith(t, "hsla(")) return parseHsla(t[5 .. t.len - 1]);
    if (startsWith(t, "hsl(")) return parseHsla(t[4 .. t.len - 1]);

    // Case-insensitive keyword matching — lower-case the input first.
    var lower_buf: [64]u8 = undefined;
    if (t.len > lower_buf.len) return null;
    for (t, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    return lookupNamed(lower_buf[0..t.len]);
}

// ---------------------------------------------------------------------------
// Hex forms
// ---------------------------------------------------------------------------

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

fn parseHex(s: []const u8) ?u32 {
    switch (s.len) {
        3 => { // #rgb → repeat each nibble
            const r = hexNibble(s[0]) orelse return null;
            const g = hexNibble(s[1]) orelse return null;
            const b = hexNibble(s[2]) orelse return null;
            return types.packRGBA(
                @as(u8, r) * 0x11,
                @as(u8, g) * 0x11,
                @as(u8, b) * 0x11,
                0xFF,
            );
        },
        4 => { // #rgba
            const r = hexNibble(s[0]) orelse return null;
            const g = hexNibble(s[1]) orelse return null;
            const b = hexNibble(s[2]) orelse return null;
            const a = hexNibble(s[3]) orelse return null;
            return types.packRGBA(
                @as(u8, r) * 0x11,
                @as(u8, g) * 0x11,
                @as(u8, b) * 0x11,
                @as(u8, a) * 0x11,
            );
        },
        6 => { // #rrggbb
            const r1 = hexNibble(s[0]) orelse return null;
            const r2 = hexNibble(s[1]) orelse return null;
            const g1 = hexNibble(s[2]) orelse return null;
            const g2 = hexNibble(s[3]) orelse return null;
            const b1 = hexNibble(s[4]) orelse return null;
            const b2 = hexNibble(s[5]) orelse return null;
            return types.packRGBA(
                (@as(u8, r1) << 4) | @as(u8, r2),
                (@as(u8, g1) << 4) | @as(u8, g2),
                (@as(u8, b1) << 4) | @as(u8, b2),
                0xFF,
            );
        },
        8 => { // #rrggbbaa
            const r1 = hexNibble(s[0]) orelse return null;
            const r2 = hexNibble(s[1]) orelse return null;
            const g1 = hexNibble(s[2]) orelse return null;
            const g2 = hexNibble(s[3]) orelse return null;
            const b1 = hexNibble(s[4]) orelse return null;
            const b2 = hexNibble(s[5]) orelse return null;
            const a1 = hexNibble(s[6]) orelse return null;
            const a2 = hexNibble(s[7]) orelse return null;
            return types.packRGBA(
                (@as(u8, r1) << 4) | @as(u8, r2),
                (@as(u8, g1) << 4) | @as(u8, g2),
                (@as(u8, b1) << 4) | @as(u8, b2),
                (@as(u8, a1) << 4) | @as(u8, a2),
            );
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// rgb() / rgba() — comma-separated integer or percentage channels.
// Strict mode: all three colour channels must be the same kind (int or %).
// Alpha (rgba only) is a 0–1 float or percentage; clamped to [0, 1].
// ---------------------------------------------------------------------------

/// Parse the content inside the parentheses (the closing ')' is already
/// stripped by the caller via the slice bounds).
fn parseRgba(inner: []const u8) ?u32 {
    // Verify the closing ')' was present: the caller passes
    // s[4..s.len-1] only when s ends with ')'; we must guard against
    // a string that ends without ')'.
    // (We actually check indirectly — the caller already sliced off the last
    // byte as ')'. If the original string didn't end with ')', the caller
    // already produced an out-of-bounds or len-1 underflow. Guard here by
    // requiring at least 1 character.)
    if (inner.len == 0) return null;

    // Split on commas.
    var parts: [4][]const u8 = undefined;
    var n_parts: usize = 0;
    var start: usize = 0;
    for (inner, 0..) |c, i| {
        if (c == ',') {
            if (n_parts >= 4) return null;
            parts[n_parts] = trim(inner[start..i]);
            n_parts += 1;
            start = i + 1;
        }
    }
    // Last segment.
    if (n_parts >= 4) return null;
    parts[n_parts] = trim(inner[start..]);
    n_parts += 1;

    if (n_parts != 3 and n_parts != 4) return null;

    // Detect channel kind from the first channel.
    const is_percent = endsWithPercent(parts[0]);

    // Parse R, G, B.
    const r = parseColorChannel(parts[0], is_percent) orelse return null;
    const g = parseColorChannel(parts[1], is_percent) orelse return null;
    const b = parseColorChannel(parts[2], is_percent) orelse return null;

    // Parse optional alpha.
    const a: u8 = if (n_parts == 4) blk: {
        const a_raw = parseAlpha(parts[3]) orelse return null;
        break :blk floatToU8(a_raw);
    } else 0xFF;

    return types.packRGBA(r, g, b, a);
}

/// Parse a single colour channel (R, G, or B).
/// `expect_pct` tells whether we expect a percentage suffix.
/// Returns a u8 (0-255) or null if invalid or out of range.
fn parseColorChannel(s: []const u8, expect_pct: bool) ?u8 {
    if (expect_pct) {
        if (!endsWithPercent(s)) return null;
        const num = trim(s[0 .. s.len - 1]);
        const v = parseFloat(num) orelse return null;
        if (v < 0.0 or v > 100.0) return null;
        return @intFromFloat(@round(v * 255.0 / 100.0));
    } else {
        if (endsWithPercent(s)) return null;
        const v = parseFloat(s) orelse return null;
        if (v < 0.0 or v > 255.0) return null;
        return @intFromFloat(@round(v));
    }
}

/// Parse an alpha value: 0–1 float or 0–100 percentage.  Clamped to [0, 1].
fn parseAlpha(s: []const u8) ?f64 {
    if (endsWithPercent(s)) {
        const num = trim(s[0 .. s.len - 1]);
        const v = parseFloat(num) orelse return null;
        return std.math.clamp(v / 100.0, 0.0, 1.0);
    } else {
        const v = parseFloat(s) orelse return null;
        return std.math.clamp(v, 0.0, 1.0);
    }
}

// ---------------------------------------------------------------------------
// hsl() / hsla()
// ---------------------------------------------------------------------------

fn parseHsla(inner: []const u8) ?u32 {
    if (inner.len == 0) return null;

    var parts: [4][]const u8 = undefined;
    var n_parts: usize = 0;
    var start: usize = 0;
    for (inner, 0..) |c, i| {
        if (c == ',') {
            if (n_parts >= 4) return null;
            parts[n_parts] = trim(inner[start..i]);
            n_parts += 1;
            start = i + 1;
        }
    }
    if (n_parts >= 4) return null;
    parts[n_parts] = trim(inner[start..]);
    n_parts += 1;

    if (n_parts != 3 and n_parts != 4) return null;

    // Hue: number in degrees (no % suffix required/allowed).
    if (endsWithPercent(parts[0])) return null;
    const h_raw = parseFloat(parts[0]) orelse return null;

    // Saturation: must be percentage.
    if (!endsWithPercent(parts[1])) return null;
    const s_raw_str = trim(parts[1][0 .. parts[1].len - 1]);
    const s_raw = parseFloat(s_raw_str) orelse return null;
    if (s_raw < 0.0 or s_raw > 100.0) return null;

    // Lightness: must be percentage.
    if (!endsWithPercent(parts[2])) return null;
    const l_raw_str = trim(parts[2][0 .. parts[2].len - 1]);
    const l_raw = parseFloat(l_raw_str) orelse return null;
    if (l_raw < 0.0 or l_raw > 100.0) return null;

    // Alpha.
    const a: u8 = if (n_parts == 4) blk: {
        const a_frac = parseAlpha(parts[3]) orelse return null;
        break :blk floatToU8(a_frac);
    } else 0xFF;

    // Normalise hue to [0, 360).
    var h = @mod(h_raw, 360.0);
    if (h < 0.0) h += 360.0;

    const s = s_raw / 100.0;
    const l = l_raw / 100.0;

    const rgb = hslToRgb(h, s, l);
    return types.packRGBA(rgb[0], rgb[1], rgb[2], a);
}

/// HSL → RGB conversion (CSS Color 3 §4.2.4 algorithm).
fn hslToRgb(h: f64, s: f64, l: f64) [3]u8 {
    if (s == 0.0) {
        const v = floatToU8(l);
        return .{ v, v, v };
    }

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;

    return .{
        hueToRgbChannel(p, q, h / 360.0 + 1.0 / 3.0),
        hueToRgbChannel(p, q, h / 360.0),
        hueToRgbChannel(p, q, h / 360.0 - 1.0 / 3.0),
    };
}

fn hueToRgbChannel(p: f64, q: f64, t_in: f64) u8 {
    var t = t_in;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;

    const v = if (t < 1.0 / 6.0)
        p + (q - p) * 6.0 * t
    else if (t < 1.0 / 2.0)
        q
    else if (t < 2.0 / 3.0)
        p + (q - p) * (2.0 / 3.0 - t) * 6.0
    else
        p;

    return floatToU8(v);
}

// ---------------------------------------------------------------------------
// Named colours — CSS Color Level 4 full set (148 entries), sorted
// alphabetically for binary search at runtime.
// ---------------------------------------------------------------------------

const NamedColor = struct { name: []const u8, rgba: u32 };

// All 148 CSS Color Level 4 named colours, sorted alphabetically.
// rgba stored as packRGBA(r, g, b, 0xff) — all named colours are fully opaque
// except "transparent" which is packRGBA(0, 0, 0, 0).
const named_colors = [_]NamedColor{
    .{ .name = "aliceblue", .rgba = types.packRGBA(0xF0, 0xF8, 0xFF, 0xFF) },
    .{ .name = "antiquewhite", .rgba = types.packRGBA(0xFA, 0xEB, 0xD7, 0xFF) },
    .{ .name = "aqua", .rgba = types.packRGBA(0x00, 0xFF, 0xFF, 0xFF) },
    .{ .name = "aquamarine", .rgba = types.packRGBA(0x7F, 0xFF, 0xD4, 0xFF) },
    .{ .name = "azure", .rgba = types.packRGBA(0xF0, 0xFF, 0xFF, 0xFF) },
    .{ .name = "beige", .rgba = types.packRGBA(0xF5, 0xF5, 0xDC, 0xFF) },
    .{ .name = "bisque", .rgba = types.packRGBA(0xFF, 0xE4, 0xC4, 0xFF) },
    .{ .name = "black", .rgba = types.packRGBA(0x00, 0x00, 0x00, 0xFF) },
    .{ .name = "blanchedalmond", .rgba = types.packRGBA(0xFF, 0xEB, 0xCD, 0xFF) },
    .{ .name = "blue", .rgba = types.packRGBA(0x00, 0x00, 0xFF, 0xFF) },
    .{ .name = "blueviolet", .rgba = types.packRGBA(0x8A, 0x2B, 0xE2, 0xFF) },
    .{ .name = "brown", .rgba = types.packRGBA(0xA5, 0x2A, 0x2A, 0xFF) },
    .{ .name = "burlywood", .rgba = types.packRGBA(0xDE, 0xB8, 0x87, 0xFF) },
    .{ .name = "cadetblue", .rgba = types.packRGBA(0x5F, 0x9E, 0xA0, 0xFF) },
    .{ .name = "chartreuse", .rgba = types.packRGBA(0x7F, 0xFF, 0x00, 0xFF) },
    .{ .name = "chocolate", .rgba = types.packRGBA(0xD2, 0x69, 0x1E, 0xFF) },
    .{ .name = "coral", .rgba = types.packRGBA(0xFF, 0x7F, 0x50, 0xFF) },
    .{ .name = "cornflowerblue", .rgba = types.packRGBA(0x64, 0x95, 0xED, 0xFF) },
    .{ .name = "cornsilk", .rgba = types.packRGBA(0xFF, 0xF8, 0xDC, 0xFF) },
    .{ .name = "crimson", .rgba = types.packRGBA(0xDC, 0x14, 0x3C, 0xFF) },
    .{ .name = "cyan", .rgba = types.packRGBA(0x00, 0xFF, 0xFF, 0xFF) },
    .{ .name = "darkblue", .rgba = types.packRGBA(0x00, 0x00, 0x8B, 0xFF) },
    .{ .name = "darkcyan", .rgba = types.packRGBA(0x00, 0x8B, 0x8B, 0xFF) },
    .{ .name = "darkgoldenrod", .rgba = types.packRGBA(0xB8, 0x86, 0x0B, 0xFF) },
    .{ .name = "darkgray", .rgba = types.packRGBA(0xA9, 0xA9, 0xA9, 0xFF) },
    .{ .name = "darkgreen", .rgba = types.packRGBA(0x00, 0x64, 0x00, 0xFF) },
    .{ .name = "darkgrey", .rgba = types.packRGBA(0xA9, 0xA9, 0xA9, 0xFF) },
    .{ .name = "darkkhaki", .rgba = types.packRGBA(0xBD, 0xB7, 0x6B, 0xFF) },
    .{ .name = "darkmagenta", .rgba = types.packRGBA(0x8B, 0x00, 0x8B, 0xFF) },
    .{ .name = "darkolivegreen", .rgba = types.packRGBA(0x55, 0x6B, 0x2F, 0xFF) },
    .{ .name = "darkorange", .rgba = types.packRGBA(0xFF, 0x8C, 0x00, 0xFF) },
    .{ .name = "darkorchid", .rgba = types.packRGBA(0x99, 0x32, 0xCC, 0xFF) },
    .{ .name = "darkred", .rgba = types.packRGBA(0x8B, 0x00, 0x00, 0xFF) },
    .{ .name = "darksalmon", .rgba = types.packRGBA(0xE9, 0x96, 0x7A, 0xFF) },
    .{ .name = "darkseagreen", .rgba = types.packRGBA(0x8F, 0xBC, 0x8F, 0xFF) },
    .{ .name = "darkslateblue", .rgba = types.packRGBA(0x48, 0x3D, 0x8B, 0xFF) },
    .{ .name = "darkslategray", .rgba = types.packRGBA(0x2F, 0x4F, 0x4F, 0xFF) },
    .{ .name = "darkslategrey", .rgba = types.packRGBA(0x2F, 0x4F, 0x4F, 0xFF) },
    .{ .name = "darkturquoise", .rgba = types.packRGBA(0x00, 0xCE, 0xD1, 0xFF) },
    .{ .name = "darkviolet", .rgba = types.packRGBA(0x94, 0x00, 0xD3, 0xFF) },
    .{ .name = "deeppink", .rgba = types.packRGBA(0xFF, 0x14, 0x93, 0xFF) },
    .{ .name = "deepskyblue", .rgba = types.packRGBA(0x00, 0xBF, 0xFF, 0xFF) },
    .{ .name = "dimgray", .rgba = types.packRGBA(0x69, 0x69, 0x69, 0xFF) },
    .{ .name = "dimgrey", .rgba = types.packRGBA(0x69, 0x69, 0x69, 0xFF) },
    .{ .name = "dodgerblue", .rgba = types.packRGBA(0x1E, 0x90, 0xFF, 0xFF) },
    .{ .name = "firebrick", .rgba = types.packRGBA(0xB2, 0x22, 0x22, 0xFF) },
    .{ .name = "floralwhite", .rgba = types.packRGBA(0xFF, 0xFA, 0xF0, 0xFF) },
    .{ .name = "forestgreen", .rgba = types.packRGBA(0x22, 0x8B, 0x22, 0xFF) },
    .{ .name = "fuchsia", .rgba = types.packRGBA(0xFF, 0x00, 0xFF, 0xFF) },
    .{ .name = "gainsboro", .rgba = types.packRGBA(0xDC, 0xDC, 0xDC, 0xFF) },
    .{ .name = "ghostwhite", .rgba = types.packRGBA(0xF8, 0xF8, 0xFF, 0xFF) },
    .{ .name = "gold", .rgba = types.packRGBA(0xFF, 0xD7, 0x00, 0xFF) },
    .{ .name = "goldenrod", .rgba = types.packRGBA(0xDA, 0xA5, 0x20, 0xFF) },
    .{ .name = "gray", .rgba = types.packRGBA(0x80, 0x80, 0x80, 0xFF) },
    .{ .name = "green", .rgba = types.packRGBA(0x00, 0x80, 0x00, 0xFF) },
    .{ .name = "greenyellow", .rgba = types.packRGBA(0xAD, 0xFF, 0x2F, 0xFF) },
    .{ .name = "grey", .rgba = types.packRGBA(0x80, 0x80, 0x80, 0xFF) },
    .{ .name = "honeydew", .rgba = types.packRGBA(0xF0, 0xFF, 0xF0, 0xFF) },
    .{ .name = "hotpink", .rgba = types.packRGBA(0xFF, 0x69, 0xB4, 0xFF) },
    .{ .name = "indianred", .rgba = types.packRGBA(0xCD, 0x5C, 0x5C, 0xFF) },
    .{ .name = "indigo", .rgba = types.packRGBA(0x4B, 0x00, 0x82, 0xFF) },
    .{ .name = "ivory", .rgba = types.packRGBA(0xFF, 0xFF, 0xF0, 0xFF) },
    .{ .name = "khaki", .rgba = types.packRGBA(0xF0, 0xE6, 0x8C, 0xFF) },
    .{ .name = "lavender", .rgba = types.packRGBA(0xE6, 0xE6, 0xFA, 0xFF) },
    .{ .name = "lavenderblush", .rgba = types.packRGBA(0xFF, 0xF0, 0xF5, 0xFF) },
    .{ .name = "lawngreen", .rgba = types.packRGBA(0x7C, 0xFC, 0x00, 0xFF) },
    .{ .name = "lemonchiffon", .rgba = types.packRGBA(0xFF, 0xFA, 0xCD, 0xFF) },
    .{ .name = "lightblue", .rgba = types.packRGBA(0xAD, 0xD8, 0xE6, 0xFF) },
    .{ .name = "lightcoral", .rgba = types.packRGBA(0xF0, 0x80, 0x80, 0xFF) },
    .{ .name = "lightcyan", .rgba = types.packRGBA(0xE0, 0xFF, 0xFF, 0xFF) },
    .{ .name = "lightgoldenrodyellow", .rgba = types.packRGBA(0xFA, 0xFA, 0xD2, 0xFF) },
    .{ .name = "lightgray", .rgba = types.packRGBA(0xD3, 0xD3, 0xD3, 0xFF) },
    .{ .name = "lightgreen", .rgba = types.packRGBA(0x90, 0xEE, 0x90, 0xFF) },
    .{ .name = "lightgrey", .rgba = types.packRGBA(0xD3, 0xD3, 0xD3, 0xFF) },
    .{ .name = "lightpink", .rgba = types.packRGBA(0xFF, 0xB6, 0xC1, 0xFF) },
    .{ .name = "lightsalmon", .rgba = types.packRGBA(0xFF, 0xA0, 0x7A, 0xFF) },
    .{ .name = "lightseagreen", .rgba = types.packRGBA(0x20, 0xB2, 0xAA, 0xFF) },
    .{ .name = "lightskyblue", .rgba = types.packRGBA(0x87, 0xCE, 0xFA, 0xFF) },
    .{ .name = "lightslategray", .rgba = types.packRGBA(0x77, 0x88, 0x99, 0xFF) },
    .{ .name = "lightslategrey", .rgba = types.packRGBA(0x77, 0x88, 0x99, 0xFF) },
    .{ .name = "lightsteelblue", .rgba = types.packRGBA(0xB0, 0xC4, 0xDE, 0xFF) },
    .{ .name = "lightyellow", .rgba = types.packRGBA(0xFF, 0xFF, 0xE0, 0xFF) },
    .{ .name = "lime", .rgba = types.packRGBA(0x00, 0xFF, 0x00, 0xFF) },
    .{ .name = "limegreen", .rgba = types.packRGBA(0x32, 0xCD, 0x32, 0xFF) },
    .{ .name = "linen", .rgba = types.packRGBA(0xFA, 0xF0, 0xE6, 0xFF) },
    .{ .name = "magenta", .rgba = types.packRGBA(0xFF, 0x00, 0xFF, 0xFF) },
    .{ .name = "maroon", .rgba = types.packRGBA(0x80, 0x00, 0x00, 0xFF) },
    .{ .name = "mediumaquamarine", .rgba = types.packRGBA(0x66, 0xCD, 0xAA, 0xFF) },
    .{ .name = "mediumblue", .rgba = types.packRGBA(0x00, 0x00, 0xCD, 0xFF) },
    .{ .name = "mediumorchid", .rgba = types.packRGBA(0xBA, 0x55, 0xD3, 0xFF) },
    .{ .name = "mediumpurple", .rgba = types.packRGBA(0x93, 0x70, 0xDB, 0xFF) },
    .{ .name = "mediumseagreen", .rgba = types.packRGBA(0x3C, 0xB3, 0x71, 0xFF) },
    .{ .name = "mediumslateblue", .rgba = types.packRGBA(0x7B, 0x68, 0xEE, 0xFF) },
    .{ .name = "mediumspringgreen", .rgba = types.packRGBA(0x00, 0xFA, 0x9A, 0xFF) },
    .{ .name = "mediumturquoise", .rgba = types.packRGBA(0x48, 0xD1, 0xCC, 0xFF) },
    .{ .name = "mediumvioletred", .rgba = types.packRGBA(0xC7, 0x15, 0x85, 0xFF) },
    .{ .name = "midnightblue", .rgba = types.packRGBA(0x19, 0x19, 0x70, 0xFF) },
    .{ .name = "mintcream", .rgba = types.packRGBA(0xF5, 0xFF, 0xFA, 0xFF) },
    .{ .name = "mistyrose", .rgba = types.packRGBA(0xFF, 0xE4, 0xE1, 0xFF) },
    .{ .name = "moccasin", .rgba = types.packRGBA(0xFF, 0xE4, 0xB5, 0xFF) },
    .{ .name = "navajowhite", .rgba = types.packRGBA(0xFF, 0xDE, 0xAD, 0xFF) },
    .{ .name = "navy", .rgba = types.packRGBA(0x00, 0x00, 0x80, 0xFF) },
    .{ .name = "oldlace", .rgba = types.packRGBA(0xFD, 0xF5, 0xE6, 0xFF) },
    .{ .name = "olive", .rgba = types.packRGBA(0x80, 0x80, 0x00, 0xFF) },
    .{ .name = "olivedrab", .rgba = types.packRGBA(0x6B, 0x8E, 0x23, 0xFF) },
    .{ .name = "orange", .rgba = types.packRGBA(0xFF, 0xA5, 0x00, 0xFF) },
    .{ .name = "orangered", .rgba = types.packRGBA(0xFF, 0x45, 0x00, 0xFF) },
    .{ .name = "orchid", .rgba = types.packRGBA(0xDA, 0x70, 0xD6, 0xFF) },
    .{ .name = "palegoldenrod", .rgba = types.packRGBA(0xEE, 0xE8, 0xAA, 0xFF) },
    .{ .name = "palegreen", .rgba = types.packRGBA(0x98, 0xFB, 0x98, 0xFF) },
    .{ .name = "paleturquoise", .rgba = types.packRGBA(0xAF, 0xEE, 0xEE, 0xFF) },
    .{ .name = "palevioletred", .rgba = types.packRGBA(0xDB, 0x70, 0x93, 0xFF) },
    .{ .name = "papayawhip", .rgba = types.packRGBA(0xFF, 0xEF, 0xD5, 0xFF) },
    .{ .name = "peachpuff", .rgba = types.packRGBA(0xFF, 0xDA, 0xB9, 0xFF) },
    .{ .name = "peru", .rgba = types.packRGBA(0xCD, 0x85, 0x3F, 0xFF) },
    .{ .name = "pink", .rgba = types.packRGBA(0xFF, 0xC0, 0xCB, 0xFF) },
    .{ .name = "plum", .rgba = types.packRGBA(0xDD, 0xA0, 0xDD, 0xFF) },
    .{ .name = "powderblue", .rgba = types.packRGBA(0xB0, 0xE0, 0xE6, 0xFF) },
    .{ .name = "purple", .rgba = types.packRGBA(0x80, 0x00, 0x80, 0xFF) },
    .{ .name = "rebeccapurple", .rgba = types.packRGBA(0x66, 0x33, 0x99, 0xFF) },
    .{ .name = "red", .rgba = types.packRGBA(0xFF, 0x00, 0x00, 0xFF) },
    .{ .name = "rosybrown", .rgba = types.packRGBA(0xBC, 0x8F, 0x8F, 0xFF) },
    .{ .name = "royalblue", .rgba = types.packRGBA(0x41, 0x69, 0xE1, 0xFF) },
    .{ .name = "saddlebrown", .rgba = types.packRGBA(0x8B, 0x45, 0x13, 0xFF) },
    .{ .name = "salmon", .rgba = types.packRGBA(0xFA, 0x80, 0x72, 0xFF) },
    .{ .name = "sandybrown", .rgba = types.packRGBA(0xF4, 0xA4, 0x60, 0xFF) },
    .{ .name = "seagreen", .rgba = types.packRGBA(0x2E, 0x8B, 0x57, 0xFF) },
    .{ .name = "seashell", .rgba = types.packRGBA(0xFF, 0xF5, 0xEE, 0xFF) },
    .{ .name = "sienna", .rgba = types.packRGBA(0xA0, 0x52, 0x2D, 0xFF) },
    .{ .name = "silver", .rgba = types.packRGBA(0xC0, 0xC0, 0xC0, 0xFF) },
    .{ .name = "skyblue", .rgba = types.packRGBA(0x87, 0xCE, 0xEB, 0xFF) },
    .{ .name = "slateblue", .rgba = types.packRGBA(0x6A, 0x5A, 0xCD, 0xFF) },
    .{ .name = "slategray", .rgba = types.packRGBA(0x70, 0x80, 0x90, 0xFF) },
    .{ .name = "slategrey", .rgba = types.packRGBA(0x70, 0x80, 0x90, 0xFF) },
    .{ .name = "snow", .rgba = types.packRGBA(0xFF, 0xFA, 0xFA, 0xFF) },
    .{ .name = "springgreen", .rgba = types.packRGBA(0x00, 0xFF, 0x7F, 0xFF) },
    .{ .name = "steelblue", .rgba = types.packRGBA(0x46, 0x82, 0xB4, 0xFF) },
    .{ .name = "tan", .rgba = types.packRGBA(0xD2, 0xB4, 0x8C, 0xFF) },
    .{ .name = "teal", .rgba = types.packRGBA(0x00, 0x80, 0x80, 0xFF) },
    .{ .name = "thistle", .rgba = types.packRGBA(0xD8, 0xBF, 0xD8, 0xFF) },
    .{ .name = "tomato", .rgba = types.packRGBA(0xFF, 0x63, 0x47, 0xFF) },
    .{ .name = "transparent", .rgba = types.packRGBA(0x00, 0x00, 0x00, 0x00) },
    .{ .name = "turquoise", .rgba = types.packRGBA(0x40, 0xE0, 0xD0, 0xFF) },
    .{ .name = "violet", .rgba = types.packRGBA(0xEE, 0x82, 0xEE, 0xFF) },
    .{ .name = "wheat", .rgba = types.packRGBA(0xF5, 0xDE, 0xB3, 0xFF) },
    .{ .name = "white", .rgba = types.packRGBA(0xFF, 0xFF, 0xFF, 0xFF) },
    .{ .name = "whitesmoke", .rgba = types.packRGBA(0xF5, 0xF5, 0xF5, 0xFF) },
    .{ .name = "yellow", .rgba = types.packRGBA(0xFF, 0xFF, 0x00, 0xFF) },
    .{ .name = "yellowgreen", .rgba = types.packRGBA(0x9A, 0xCD, 0x32, 0xFF) },
};

fn lookupNamed(lower: []const u8) ?u32 {
    // Binary search on the sorted table.
    var lo: usize = 0;
    var hi: usize = named_colors.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, lower, named_colors[mid].name);
        switch (cmp) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return named_colors[mid].rgba,
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Small float parser (no std.fmt.parseFloat dependency on old API shapes)
// ---------------------------------------------------------------------------

/// Parse a decimal float from a slice.  Accepts optional leading '-' or '+',
/// integer part, optional '.' and fractional part.  No exponent support needed
/// for CSS color values.
fn parseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    // Delegate to std.fmt.parseFloat which handles the full grammar.
    return std.fmt.parseFloat(f64, s) catch null;
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    // Case-insensitive compare for the prefix.
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return false;
    }
    // Also verify the string ends with ')'.
    return s[s.len - 1] == ')';
}

fn endsWithPercent(s: []const u8) bool {
    return s.len > 0 and s[s.len - 1] == '%';
}

/// Convert a 0.0–1.0 float to a u8 (0–255), clamped.
fn floatToU8(v: f64) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}
