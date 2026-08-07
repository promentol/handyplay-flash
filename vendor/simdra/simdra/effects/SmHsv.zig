//! effects/SmHsv.zig — RGB↔HSV round-trip + sharp's `modulate`.
//!
//! Backs sharp's `modulate({ brightness, saturation, hue, lightness })`.
//!
//! HSV space:
//!   H ∈ [0, 360) degrees
//!   S ∈ [0, 1]
//!   V ∈ [0, 255] — kept in 8-bit range so brightness and lightness
//!                  ops are intuitive (sharp's `lightness: 50` adds 50
//!                  units of luma).
//!
//! ## Divergence from sharp
//!
//! Sharp's hue rotation runs in the LCh derived from CIE Lab —
//! perceptually uniform; cyan rotated by 180° lands at a true red.
//! Simdra's pipeline is RGBA8 sRGB only, so we approximate by
//! rotating in HSV. The two differ slightly on saturated edges
//! (HSV-cyan rotated 180° lands at HSV-red, which is the same RGB
//! coords but a different perceptual point on the chroma circle).
//! Documented as 🟡 in COMPATIBILITY.md.

const std = @import("std");
const SmBitmap = @import("../core/SmBitmap.zig");

pub const Error = error{
    Empty,
    UnsupportedPixelFormat,
    InvalidArgument,
} || std.mem.Allocator.Error;

inline fn allocBitmap(width: u32, height: u32) Error!SmBitmap {
    const allocator = std.heap.page_allocator;
    const data = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    return .{
        .data = data,
        .width = width,
        .height = height,
        .colorSpace = .srgb,
        .pixelFormat = .rgba_unorm8,
    };
}

inline fn check(src: SmBitmap) Error!void {
    if (src.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    if (src.width == 0 or src.height == 0) return error.Empty;
}

inline fn clipU8FromF64(f: f64) u8 {
    if (f < 0) return 0;
    if (f > 255) return 255;
    return @intFromFloat(@round(f));
}

/// rgbToHsv — convert an 8-bit RGB triple to (H ∈ [0, 360),
/// S ∈ [0, 1], V ∈ [0, 255]).
pub fn rgbToHsv(r: u8, g: u8, b: u8) struct { h: f64, s: f64, v: f64 } {
    const rf: f64 = @floatFromInt(r);
    const gf: f64 = @floatFromInt(g);
    const bf: f64 = @floatFromInt(b);
    const max = @max(rf, @max(gf, bf));
    const min = @min(rf, @min(gf, bf));
    const delta = max - min;
    const v = max;
    const s: f64 = if (max <= 0) 0 else delta / max;
    var h: f64 = 0;
    if (delta > 0) {
        if (max == rf) {
            h = (gf - bf) / delta;
        } else if (max == gf) {
            h = (bf - rf) / delta + 2.0;
        } else {
            h = (rf - gf) / delta + 4.0;
        }
        h *= 60.0;
        if (h < 0) h += 360.0;
    }
    return .{ .h = h, .s = s, .v = v };
}

/// hsvToRgb — inverse of `rgbToHsv`. `h` is folded into [0, 360).
pub fn hsvToRgb(h_in: f64, s: f64, v: f64) struct { r: u8, g: u8, b: u8 } {
    var h = @mod(h_in, 360.0);
    if (h < 0) h += 360.0;
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(h / 60.0, 2.0) - 1.0));
    const m = v - c;
    var rf: f64 = 0;
    var gf: f64 = 0;
    var bf: f64 = 0;
    if (h < 60) {
        rf = c; gf = x; bf = 0;
    } else if (h < 120) {
        rf = x; gf = c; bf = 0;
    } else if (h < 180) {
        rf = 0; gf = c; bf = x;
    } else if (h < 240) {
        rf = 0; gf = x; bf = c;
    } else if (h < 300) {
        rf = x; gf = 0; bf = c;
    } else {
        rf = c; gf = 0; bf = x;
    }
    return .{
        .r = clipU8FromF64(rf + m),
        .g = clipU8FromF64(gf + m),
        .b = clipU8FromF64(bf + m),
    };
}

/// modulate(src, brightness, saturation, hue_deg, lightness) — apply
/// the four sharp adjustments in HSV. `brightness` and `saturation`
/// are multipliers (1.0 = identity); `hue_deg` rotates H in degrees;
/// `lightness` is added to V (luminance) after the brightness multiply,
/// matching sharp's "additive" semantic. α is preserved untouched.
pub fn modulate(
    src: SmBitmap,
    brightness: f64,
    saturation: f64,
    hue_deg: f64,
    lightness: f64,
) Error!SmBitmap {
    try check(src);
    if (!std.math.isFinite(brightness) or brightness < 0) return error.InvalidArgument;
    if (!std.math.isFinite(saturation) or saturation < 0) return error.InvalidArgument;
    if (!std.math.isFinite(hue_deg)) return error.InvalidArgument;
    if (!std.math.isFinite(lightness)) return error.InvalidArgument;

    // Fast path: every parameter is identity. Skip the per-pixel
    // RGB↔HSV round-trip (which is branchy and not vectorised) and
    // copy through directly. Also covers `modulate()` no-args from
    // microsharp, which fills in default 1/1/0/0.
    if (brightness == 1.0 and saturation == 1.0 and hue_deg == 0.0 and lightness == 0.0) {
        return src.extract(0, 0, src.width, src.height) catch |e| switch (e) {
            error.OutOfBounds => unreachable,
            else => |x| return x,
        };
    }

    const out = try allocBitmap(src.width, src.height);
    errdefer std.heap.page_allocator.free(out.data);

    var p: usize = 0;
    while (p < src.data.len) : (p += 4) {
        const r = src.data[p + 0];
        const g = src.data[p + 1];
        const b = src.data[p + 2];
        var hsv = rgbToHsv(r, g, b);
        hsv.v = hsv.v * brightness + lightness;
        if (hsv.v < 0) hsv.v = 0;
        if (hsv.v > 255) hsv.v = 255;
        hsv.s *= saturation;
        if (hsv.s < 0) hsv.s = 0;
        if (hsv.s > 1) hsv.s = 1;
        hsv.h += hue_deg;
        const rgb = hsvToRgb(hsv.h, hsv.s, hsv.v);
        out.data[p + 0] = rgb.r;
        out.data[p + 1] = rgb.g;
        out.data[p + 2] = rgb.b;
        out.data[p + 3] = src.data[p + 3];
    }
    return out;
}
