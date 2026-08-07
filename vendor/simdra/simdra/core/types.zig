//! Enums, settings structs, and small color helpers shared by the canvas modules.
//! Names mirror the WebIDL enums exposed by CanvasRenderingContext2D.

pub const ColorSpace = enum {
    srgb,
    display_p3,
};

pub const PixelFormat = enum {
    rgba_unorm8,
    rgba_float16,
};

/// Surface byte order — the SkColorType analog, scoped to `SmSurface`
/// (bitmaps / ImageData stay always-RGBA per WHATWG). `.bgra8888` swaps
/// the R and B lanes: memory bytes B,G,R,A — which is little-endian
/// `XRGB8888` when alpha is ignored, i.e. a zero-copy libretro present.
/// Append-only; explicit tags cross the JS binding as integers.
pub const ColorType = enum(u8) {
    rgba8888 = 0,
    bgra8888 = 1,
};

pub const BitmapSettings = struct {
    colorSpace: ColorSpace = .srgb,
    pixelFormat: PixelFormat = .rgba_unorm8,
};

pub const GetContextSettings = struct {
    alpha: bool = true,
    colorSpace: ColorSpace = .srgb,
    desynchronized: bool = false,
    willReadFrequently: bool = false,
};

pub inline fn packRGBA(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) |
        (@as(u32, g) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, a) << 24);
}
