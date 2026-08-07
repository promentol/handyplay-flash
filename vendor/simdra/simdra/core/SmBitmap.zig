//! SmBitmap — owning RGBA pixel buffer + metadata. Mirrors Skia's `SkBitmap`.
//! Returned by `SmCanvas.getImageData(...)` and the `SmBitmap.createBlank` /
//! `SmBitmap.createFromBuffer` static factories.
//!
//! `data` is raw bytes. When pixelFormat == .rgba_float16 the JS side should
//! wrap it as a Float16Array; for .rgba_unorm8 it is a Uint8 view of RGBA.
//!
//! The HTML5 `ImageData` class is a JS-side shim around this struct (in
//! `src/index.ts`). Static factories live here as plain `pub fn` (no self)
//! so both the JS `new ImageData(...)` dispatcher and the SmCanvas
//! `ctx.createImageData(...)` augmentation delegate to the same code.
//!
//! ## Allocator (post-A2)
//!
//! SmBitmap does NOT store an `std.mem.Allocator` field — zigar's WASM
//! marshalling can't preserve the vtable function pointers across the JS
//! boundary, and SmBitmap is a return type for `getImageData` that has to
//! survive that round-trip. The caller tracks which allocator created the
//! bitmap and frees it via `releaseWithAllocator(allocator, bmp)`. The
//! JS-binding `release(bmp)` defaults to `page_allocator`, matching the
//! provenance of the JS-callable factories.
//!
//! Pure-Zig callers that constructed via `*WithAllocator` factories should
//! free via `releaseWithAllocator` with the matching allocator.

const std = @import("std");
const types = @import("types.zig");
const simd = @import("../opts/simd.zig");
const decode_stb = @import("../decode/stb.zig");
const encoder = @import("../encode/encoder.zig");
const resampler = @import("../effects/SmResampler.zig");
const trim_mod = @import("../effects/SmTrim.zig");
const composite_mod = @import("../effects/SmComposite.zig");
const channel_mod = @import("../effects/SmChannel.zig");
const transform_mod = @import("../effects/SmTransform.zig");
const convolve_mod = @import("../effects/SmConvolve.zig");
const morphology_mod = @import("../effects/SmMorphology.zig");
const tone_mod = @import("../effects/SmTone.zig");
const histogram_mod = @import("../effects/SmHistogram.zig");
const hsv_mod = @import("../effects/SmHsv.zig");
const exif_mod = @import("../decode/exif.zig");
const SmPaint = @import("SmPaint.zig");

const SmBitmap = @This();

pub const FromSurfaceError = error{IndexSize} || std.mem.Allocator.Error;
pub const EncodeError = error{ UnsupportedPixelFormat, EncodeFailed } || std.mem.Allocator.Error;

data: []u8,
width: u32,
height: u32,
colorSpace: types.ColorSpace = .srgb,
pixelFormat: types.PixelFormat = .rgba_unorm8,

pub const CtorError = error{ IndexSize, InvalidState } || std.mem.Allocator.Error;

inline fn bytesPerPixel(format: types.PixelFormat) usize {
    return switch (format) {
        .rgba_unorm8 => 4,
        .rgba_float16 => 8,
    };
}

/// release(bitmap) — JS-binding free using `page_allocator`. Matches the
/// allocator used by `createBlank` / `createFromBuffer` (the JS-callable
/// factories). Static (first arg is `SmBitmap` by value, not `*Self`), so
/// the JS-side finalization registry can free without a Canvas reference.
pub fn release(bitmap: SmBitmap) void {
    std.heap.page_allocator.free(bitmap.data);
}

/// releaseWithAllocator — pure-Zig free for bitmaps constructed via
/// `*WithAllocator` factories or `fromSurfacePixels(allocator, ...)`. The
/// caller is responsible for matching allocator-at-creation to allocator-
/// at-release.
pub fn releaseWithAllocator(allocator: std.mem.Allocator, bitmap: SmBitmap) void {
    allocator.free(bitmap.data);
}

/// Allocate a fresh transparent-black SmBitmap with the given dimensions.
/// JS-binding entry point (uses `page_allocator`). Backs both
/// `new ImageData(w, h)` and `ctx.createImageData(w, h)`.
pub fn createBlank(width: u32, height: u32, settings: types.BitmapSettings) CtorError!SmBitmap {
    return createBlankWithAllocator(std.heap.page_allocator, width, height, settings);
}

pub fn createBlankWithAllocator(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    settings: types.BitmapSettings,
) CtorError!SmBitmap {
    if (width == 0 or height == 0) return error.IndexSize;
    const bpp = bytesPerPixel(settings.pixelFormat);
    const data = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * bpp);
    @memset(data, 0);
    return .{
        .data = data,
        .width = width,
        .height = height,
        .colorSpace = settings.colorSpace,
        .pixelFormat = settings.pixelFormat,
    };
}

/// Allocate a SmBitmap populated from `src` bytes. `height == null` means
/// "derive from data length and width". Bytes are copied so the result is
/// owned by us and releaseable via `releaseImageData(...)`.
/// JS-binding entry point — backs `new ImageData(data, w, h?, settings?)`.
pub fn createFromBuffer(
    src: []const u8,
    width: u32,
    height: ?u32,
    settings: types.BitmapSettings,
) CtorError!SmBitmap {
    return createFromBufferWithAllocator(std.heap.page_allocator, src, width, height, settings);
}

pub fn createFromBufferWithAllocator(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: ?u32,
    settings: types.BitmapSettings,
) CtorError!SmBitmap {
    if (width == 0) return error.IndexSize;
    const bpp = bytesPerPixel(settings.pixelFormat);
    const row_bytes = @as(usize, width) * bpp;
    if (src.len == 0 or src.len % row_bytes != 0) return error.InvalidState;
    const derived: u32 = @intCast(src.len / row_bytes);
    if (height) |h| {
        if (h == 0) return error.IndexSize;
        if (@as(usize, h) * row_bytes != src.len) return error.InvalidState;
    }
    const final_h = height orelse derived;
    const buf = try allocator.alloc(u8, src.len);
    @memcpy(buf, src);
    return .{
        .data = buf,
        .width = width,
        .height = final_h,
        .colorSpace = settings.colorSpace,
        .pixelFormat = settings.pixelFormat,
    };
}

/// decode(bytes) — JS-binding factory using `page_allocator`. Auto-detects
/// PNG / JPEG / BMP / GIF (first frame); always emits 8-bit RGBA. Other
/// formats were stripped at C build time. See `decode/stb.zig`.
pub fn decode(bytes: []const u8) decode_stb.DecodeError!SmBitmap {
    return decode_stb.decodeImage(std.heap.page_allocator, bytes);
}

/// peekInfo(bytes) — header-only metadata read; no pixel decode, no
/// allocation. Wraps stb_image's `stbi_info_from_memory` +
/// `stbi_is_16_bit_from_memory` public fast-path APIs. Returns the
/// **source** channel count (1/2/3/4), not our forced-RGBA decode output.
/// Static (no `*Self`) so node-zigar binds it as `SmBitmap.peekInfo(...)`.
pub const ImageInfo = decode_stb.ImageInfo;
pub fn peekInfo(bytes: []const u8) decode_stb.InfoError!ImageInfo {
    return decode_stb.peekInfo(bytes);
}

/// decodeWithAllocator — pure-Zig variant for callers with their own
/// allocator (tests, embedded uses, the sharp-shaped binding's pipeline).
pub fn decodeWithAllocator(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) decode_stb.DecodeError!SmBitmap {
    return decode_stb.decodeImage(allocator, bytes);
}

/// encodePng() — JS-binding entry point using `page_allocator`. Returns an
/// owned slice the caller is responsible for freeing.
pub fn encodePng(self: SmBitmap) EncodeError![]u8 {
    return self.encodePngWithAllocator(std.heap.page_allocator);
}

pub fn encodePngWithAllocator(self: SmBitmap, allocator: std.mem.Allocator) EncodeError![]u8 {
    if (self.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    return encoder.encodePng(allocator, self.data, self.width, self.height);
}

/// encodePngWithLevel(level) — PNG encode with stb's per-call compression
/// level (0..9). Wraps stb's process-global `stbi_write_png_compression_level`
/// in a Zig-side mutex so concurrent encodes from pthreads (native build)
/// don't see each other's level.
pub fn encodePngWithLevel(self: SmBitmap, level: u8) EncodeError![]u8 {
    return self.encodePngWithLevelWithAllocator(std.heap.page_allocator, level);
}

pub fn encodePngWithLevelWithAllocator(
    self: SmBitmap,
    allocator: std.mem.Allocator,
    level: u8,
) EncodeError![]u8 {
    if (self.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    return encoder.encodePngWithLevel(allocator, self.data, self.width, self.height, level);
}

/// encodeJpeg(quality) — JS-binding entry point using `page_allocator`.
/// `quality` is stb's 1–100 scale; the JS layer maps the HTML5 0.0–1.0
/// range. Returns an owned slice the caller is responsible for freeing.
pub fn encodeJpeg(self: SmBitmap, quality: u8) EncodeError![]u8 {
    return self.encodeJpegWithAllocator(std.heap.page_allocator, quality);
}

pub fn encodeJpegWithAllocator(
    self: SmBitmap,
    allocator: std.mem.Allocator,
    quality: u8,
) EncodeError![]u8 {
    if (self.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    return encoder.encodeJpeg(allocator, self.data, self.width, self.height, quality);
}

/// encodeBmp() — 32-bit BMP V4 with alpha mask (stb's `comp=4` path). No
/// options; BMP has no quality / compression knobs in stb_image_write.
pub fn encodeBmp(self: SmBitmap) EncodeError![]u8 {
    return self.encodeBmpWithAllocator(std.heap.page_allocator);
}

pub fn encodeBmpWithAllocator(self: SmBitmap, allocator: std.mem.Allocator) EncodeError![]u8 {
    if (self.pixelFormat != .rgba_unorm8) return error.UnsupportedPixelFormat;
    return encoder.encodeBmp(allocator, self.data, self.width, self.height);
}

// =============================================================================
// Pure-pixel ops backing microsharp's resize / extract / extend / trim
// =============================================================================
//
// These are bitmap-direct: no SmCanvas / SmSurface involved. Each
// produces a fresh page-allocated SmBitmap; the caller frees the
// previous bitmap via `release` (or relies on the JS finalizer).

pub const ResampleKernel = resampler.Kernel;
pub const ResampleError = resampler.Error;

/// resample(target_w, target_h, kernel) — separable filter resize.
/// Six kernels available: cubic, mitchell, lanczos2, lanczos3,
/// mks2013, mks2021. See `effects/SmResampler.zig`.
pub fn resample(
    self: SmBitmap,
    target_w: u32,
    target_h: u32,
    kernel: ResampleKernel,
) ResampleError!SmBitmap {
    return resampler.resample(std.heap.page_allocator, self, target_w, target_h, kernel);
}

pub const ExtractError = error{ Empty, OutOfBounds } || std.mem.Allocator.Error;

/// extract(left, top, width, height) — copy a sub-rectangle into a
/// freshly-allocated bitmap. Bounds-checked; throws OutOfBounds if the
/// rect doesn't fit entirely inside the source.
pub fn extract(
    self: SmBitmap,
    left: u32,
    top: u32,
    width: u32,
    height: u32,
) ExtractError!SmBitmap {
    if (self.pixelFormat != .rgba_unorm8) return error.OutOfBounds;
    if (width == 0 or height == 0) return error.Empty;
    if (left + width > self.width or top + height > self.height) return error.OutOfBounds;

    const allocator = std.heap.page_allocator;
    const out_data = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    errdefer allocator.free(out_data);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_off = (@as(usize, top + y)) * (@as(usize, self.width) * 4) + (@as(usize, left)) * 4;
        const dst_off = (@as(usize, y)) * (@as(usize, width) * 4);
        const len: usize = @as(usize, width) * 4;
        @memcpy(out_data[dst_off .. dst_off + len], self.data[src_off .. src_off + len]);
    }

    return .{
        .data = out_data,
        .width = width,
        .height = height,
        .colorSpace = self.colorSpace,
        .pixelFormat = .rgba_unorm8,
    };
}

pub const ExtendMode = enum(u8) {
    background,
    copy, // extrude edge pixels
    repeat, // tile
    mirror, // reflect
};

pub const ExtendError = error{Empty} || std.mem.Allocator.Error;

/// extend(top, right, bottom, left, mode, bg) — pad the image on each
/// edge using the requested fill mode. `bg_*` is consulted only when
/// `mode == .background`.
pub fn extend(
    self: SmBitmap,
    top: u32,
    right: u32,
    bottom: u32,
    left: u32,
    mode: ExtendMode,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
) ExtendError!SmBitmap {
    if (self.width == 0 or self.height == 0) return error.Empty;
    if (top == 0 and right == 0 and bottom == 0 and left == 0) {
        // Caller handles "no-op" — but produce a copy to keep ownership
        // semantics uniform.
        return self.extract(0, 0, self.width, self.height) catch |e| switch (e) {
            error.OutOfBounds, error.Empty => unreachable,
            else => |x| return x,
        };
    }

    const new_w: u32 = self.width + left + right;
    const new_h: u32 = self.height + top + bottom;

    const allocator = std.heap.page_allocator;
    const out_data = try allocator.alloc(u8, @as(usize, new_w) * @as(usize, new_h) * 4);
    errdefer allocator.free(out_data);

    // Seed the whole canvas with the background color when in
    // background mode; the inner copy below overwrites the source
    // region. For copy/repeat/mirror modes we fill every pixel below.
    if (mode == .background) {
        var i: usize = 0;
        while (i < out_data.len) : (i += 4) {
            out_data[i + 0] = bg_r;
            out_data[i + 1] = bg_g;
            out_data[i + 2] = bg_b;
            out_data[i + 3] = bg_a;
        }
    }

    // Copy the source into the centre.
    {
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src_off = (@as(usize, y)) * (@as(usize, self.width) * 4);
            const dst_off = (@as(usize, top + y)) * (@as(usize, new_w) * 4) + (@as(usize, left)) * 4;
            const row_len: usize = @as(usize, self.width) * 4;
            @memcpy(out_data[dst_off .. dst_off + row_len], self.data[src_off .. src_off + row_len]);
        }
    }

    if (mode != .background) {
        // For each output pixel outside the source rectangle, sample
        // from the source per the chosen mode.
        const sw_i: i64 = @intCast(self.width);
        const sh_i: i64 = @intCast(self.height);
        const left_i: i64 = @intCast(left);
        const top_i: i64 = @intCast(top);

        var y: u32 = 0;
        while (y < new_h) : (y += 1) {
            var x: u32 = 0;
            while (x < new_w) : (x += 1) {
                // Inside the source-mapped region: skip (already copied).
                if (x >= left and x < left + self.width and y >= top and y < top + self.height) {
                    x += self.width - 1; // jump to right edge of inner region
                    continue;
                }
                const fx: i64 = @as(i64, @intCast(x)) - left_i;
                const fy: i64 = @as(i64, @intCast(y)) - top_i;
                const sx: u32 = sampleEdgeCoord(fx, sw_i, mode);
                const sy: u32 = sampleEdgeCoord(fy, sh_i, mode);
                const src_off = (@as(usize, sy)) * (@as(usize, self.width) * 4) + (@as(usize, sx)) * 4;
                const dst_off = (@as(usize, y)) * (@as(usize, new_w) * 4) + (@as(usize, x)) * 4;
                @memcpy(out_data[dst_off .. dst_off + 4], self.data[src_off .. src_off + 4]);
            }
        }
    }

    return .{
        .data = out_data,
        .width = new_w,
        .height = new_h,
        .colorSpace = self.colorSpace,
        .pixelFormat = .rgba_unorm8,
    };
}

inline fn sampleEdgeCoord(coord: i64, dim: i64, mode: ExtendMode) u32 {
    return switch (mode) {
        .background => unreachable, // handled before this function
        .copy => @intCast(@max(0, @min(dim - 1, coord))),
        .repeat => blk: {
            // Wrap into [0, dim).
            var c = @mod(coord, dim);
            if (c < 0) c += dim;
            break :blk @intCast(c);
        },
        .mirror => blk: {
            // Reflect into [0, dim). Period is 2*dim - 2 (so the edges
            // aren't doubled).
            const period: i64 = 2 * dim - 2;
            if (period <= 0) break :blk @intCast(@max(0, @min(dim - 1, coord)));
            var c = @mod(coord, period);
            if (c < 0) c += period;
            if (c >= dim) c = period - c;
            break :blk @intCast(c);
        },
    };
}

pub const TrimRect = trim_mod.Rect;
pub const TrimError = trim_mod.Error;

/// findOpaqueBounds(bg, threshold) — bounding box of pixels that
/// differ from `bg` by more than `threshold` on any channel. Returns
/// `error.NoContent` when every pixel is within threshold of bg.
pub fn findOpaqueBounds(
    self: SmBitmap,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    bg_threshold: u8,
) TrimError!TrimRect {
    return trim_mod.findOpaqueBounds(self, bg_r, bg_g, bg_b, bg_a, bg_threshold);
}

pub const CropStrategy = trim_mod.Strategy;

/// contentBounds(target_w, target_h, strategy) — pick the
/// `target_w × target_h` window inside the bitmap that maximizes the
/// content score for the chosen strategy. Used by sharp's
/// `position: 'entropy' | 'attention'` cover-crop.
pub fn contentBounds(
    self: SmBitmap,
    target_w: u32,
    target_h: u32,
    strategy: CropStrategy,
) (TrimError || std.mem.Allocator.Error)!TrimRect {
    return trim_mod.contentBounds(std.heap.page_allocator, self, target_w, target_h, strategy);
}

pub const BlendMode = SmPaint.BlendMode;

/// composite(overlay, mode, dx, dy, tile) — draw `overlay` onto a copy
/// of `self` with the given blend mode and pixel offset (or tiled
/// across the base if `tile=true`). Returns a fresh page-allocated
/// SmBitmap; the caller releases it. Powers sharp's
/// `composite([{input, blend, gravity, top, left, tile}])`.
pub fn composite(
    self: SmBitmap,
    overlay: SmBitmap,
    mode: BlendMode,
    dx: i32,
    dy: i32,
    tile: bool,
) !SmBitmap {
    return composite_mod.composite(self, overlay, mode, dx, dy, tile);
}

pub const ChannelError = channel_mod.Error;
pub const BoolOp = channel_mod.BoolOp;

/// removeAlpha — return a copy with α forced to 255 on every pixel
/// (visibly equivalent to dropping the alpha channel).
pub fn removeAlpha(self: SmBitmap) ChannelError!SmBitmap {
    return channel_mod.removeAlpha(self);
}

/// greyscale — return a copy with R=G=B=L (Rec.601 luma); α preserved.
/// Backs sharp's `greyscale()` / `grayscale()`.
pub fn greyscale(self: SmBitmap) ChannelError!SmBitmap {
    return channel_mod.greyscale(self);
}

/// tint(r, g, b) — recolour with the given RGB tint while preserving
/// per-pixel luminance and alpha. Backs sharp's `tint(colour)`.
pub fn tint(self: SmBitmap, r: u8, g: u8, b: u8) ChannelError!SmBitmap {
    return channel_mod.tint(self, r, g, b);
}

/// setAlphaConstant(α) — return a copy with α set to a fixed byte.
/// Used by sharp's `ensureAlpha(α)` when called with an explicit level.
pub fn setAlphaConstant(self: SmBitmap, alpha: u8) ChannelError!SmBitmap {
    return channel_mod.setAlphaConstant(self, alpha);
}

/// extractChannel(channel) — return a greyscale-shaped bitmap (RGB =
/// the chosen source channel, α=255). `channel` ∈ {0=R, 1=G, 2=B, 3=A}.
pub fn extractChannel(self: SmBitmap, channel: u8) ChannelError!SmBitmap {
    return channel_mod.extractChannel(self, channel);
}

/// bandbool(op) — per-pixel bitwise R op G op B → broadcast to RGB,
/// α=255. `op` ∈ {.and, .or, .eor (XOR)}.
pub fn bandbool(self: SmBitmap, op: BoolOp) ChannelError!SmBitmap {
    return channel_mod.bandbool(self, op);
}

/// joinAlphaFromMask(mask) — return a copy of `self` with α replaced
/// by Rec.601 luma of `mask.RGB`. Powers sharp's `joinChannel(image)`
/// for the "use this image as the new alpha mask" use case.
pub fn joinAlphaFromMask(self: SmBitmap, mask: SmBitmap) ChannelError!SmBitmap {
    return channel_mod.joinAlphaFromMask(self, mask);
}

// ---- geometric (Phase 1: rotate / flip / flop / affine) -----------------

pub const TransformError = transform_mod.Error;
pub const Interpolator = transform_mod.Interpolator;

/// rotate90 — visual 90° CW. Output dims swap (h × w). Lossless.
pub fn rotate90(self: SmBitmap) TransformError!SmBitmap {
    return transform_mod.rotate90(self);
}

/// rotate180 — same dims. Lossless.
pub fn rotate180(self: SmBitmap) TransformError!SmBitmap {
    return transform_mod.rotate180(self);
}

/// rotate270 — visual 270° CW (= 90° CCW). Output dims swap. Lossless.
pub fn rotate270(self: SmBitmap) TransformError!SmBitmap {
    return transform_mod.rotate270(self);
}

/// flipH — mirror left↔right (sharp's `flop`).
pub fn flipH(self: SmBitmap) TransformError!SmBitmap {
    return transform_mod.flipHorizontal(self);
}

/// flipV — mirror top↔bottom (sharp's `flip`).
pub fn flipV(self: SmBitmap) TransformError!SmBitmap {
    return transform_mod.flipVertical(self);
}

/// rotateArbitrary — arbitrary-angle CW rotation about the source
/// centre with bg padding around the rotated content.
pub fn rotateArbitrary(
    self: SmBitmap,
    angle_deg: f64,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    interp: Interpolator,
) TransformError!SmBitmap {
    return transform_mod.rotateArbitrary(self, angle_deg, bg_r, bg_g, bg_b, bg_a, interp);
}

/// affine — sharp-shaped affine transform.
/// `F(x, y) = M·(x + idx, y + idy) + (odx, ody)` where
/// `M = [[m00, m01], [m10, m11]]`. Output bbox = forward-mapped AABB.
pub fn affine(
    self: SmBitmap,
    m00: f64,
    m01: f64,
    m10: f64,
    m11: f64,
    idx: f64,
    idy: f64,
    odx: f64,
    ody: f64,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
    interp: Interpolator,
) TransformError!SmBitmap {
    return transform_mod.affineTransform(
        self,
        m00,
        m01,
        m10,
        m11,
        idx,
        idy,
        odx,
        ody,
        bg_r,
        bg_g,
        bg_b,
        bg_a,
        interp,
    );
}

/// peekOrientation(bytes) — read the EXIF Orientation tag (1..8) from
/// JPEG APP1 / PNG eXIf. Returns 1 (no rotation) on any malformed /
/// missing input. Static (no `*Self`) — called against raw input
/// bytes before decode.
pub fn peekOrientation(bytes: []const u8) u8 {
    return exif_mod.readOrientation(bytes);
}

// ---- convolution / morphology (Phase 2) ---------------------------------

pub const ConvolveError = convolve_mod.Error;
pub const MorphologyError = morphology_mod.Error;
pub const BlurPrecision = convolve_mod.BlurPrecision;

/// blurBox3 — fast 3×3 box blur (sharp's `.blur()` no-args).
pub fn blurBox3(self: SmBitmap) ConvolveError!SmBitmap {
    return convolve_mod.blurBox3(self);
}

/// blurGaussian — separable Gaussian blur with the chosen precision.
/// `precision` ∈ {.integer, .float, .approximate}; `.approximate`
/// reuses the existing 3-pass box approximation.
pub fn blurGaussian(
    self: SmBitmap,
    sigma: f64,
    precision: BlurPrecision,
    min_amplitude: f64,
) ConvolveError!SmBitmap {
    return convolve_mod.blurGaussian(self, sigma, precision, min_amplitude);
}

/// convolve — generic kw × kh kernel (odd dims). Edge mode = clamp.
pub fn convolve(
    self: SmBitmap,
    kw: u32,
    kh: u32,
    kernel: []const f64,
    scale: f64,
    offset: f64,
) ConvolveError!SmBitmap {
    return convolve_mod.convolve(self, kw, kh, kernel, scale, offset);
}

/// sharpenFast — 3×3 unsharp kernel (sharp's `.sharpen()` no-args).
pub fn sharpenFast(self: SmBitmap) ConvolveError!SmBitmap {
    return convolve_mod.sharpenFast(self);
}

/// sharpenUSM — libvips USM with sigma + flat/jagged piecewise gain.
/// Per-channel in 8-bit sRGB (no LAB-L pipeline; documented 🟡).
pub fn sharpenUSM(
    self: SmBitmap,
    sigma: f64,
    m1: f64,
    m2: f64,
    x1: f64,
    y2: f64,
    y3: f64,
) ConvolveError!SmBitmap {
    return convolve_mod.sharpenUSM(self, sigma, m1, m2, x1, y2, y3);
}

/// dilate(width) — separable max-window expansion of the foreground.
pub fn dilate(self: SmBitmap, width: u32) MorphologyError!SmBitmap {
    return morphology_mod.dilate(self, width);
}

/// erode(width) — separable min-window shrinking of the foreground.
pub fn erode(self: SmBitmap, width: u32) MorphologyError!SmBitmap {
    return morphology_mod.erode(self, width);
}

/// median(size) — `size × size` median filter per RGB channel.
pub fn median(self: SmBitmap, size: u32) MorphologyError!SmBitmap {
    return morphology_mod.median(self, size);
}

// ---- tone / boolean (Phase 3) -------------------------------------------

pub const ToneError = tone_mod.Error;
pub const ToneBoolOp = tone_mod.BoolOp;

/// gamma(g_in, g_out) — single LUT `(in/255)^(g_in/g_out)·255`.
/// `g_in == g_out` is the no-op identity (sharp parity).
pub fn gamma(self: SmBitmap, g_in: f64, g_out: f64) ToneError!SmBitmap {
    return tone_mod.gamma(self, g_in, g_out);
}

/// negate(alpha) — `255 - C` per RGB channel; α negated when `alpha=true`.
pub fn negate(self: SmBitmap, alpha: bool) ToneError!SmBitmap {
    return tone_mod.negate(self, alpha);
}

/// linear(a, b) — per-channel `clip(a·C + b)`. Both arrays length 4.
pub fn linear(self: SmBitmap, a: [4]f64, b: [4]f64) ToneError!SmBitmap {
    return tone_mod.linear(self, a, b);
}

/// threshold(t, grey) — per-channel binarize. `grey=true` computes
/// Rec.601 luma first and broadcasts the threshold result.
pub fn threshold(self: SmBitmap, t: u8, grey: bool) ToneError!SmBitmap {
    return tone_mod.threshold(self, t, grey);
}

/// recomb(matrix) — 3×3 (RGB-only, α preserved) or 4×4 (full RGBA)
/// row-major colour-matrix multiply.
pub fn recomb(self: SmBitmap, matrix: []const f64) ToneError!SmBitmap {
    return tone_mod.recomb(self, matrix);
}

/// flatten(bg_r, bg_g, bg_b) — composite onto opaque background; α=255.
pub fn flatten(self: SmBitmap, bg_r: u8, bg_g: u8, bg_b: u8) ToneError!SmBitmap {
    return tone_mod.flatten(self, bg_r, bg_g, bg_b);
}

/// unflatten — every pixel where `R=G=B=255` gets α=0; others unchanged.
pub fn unflatten(self: SmBitmap) ToneError!SmBitmap {
    return tone_mod.unflatten(self);
}

/// booleanWith(operand, op) — bitwise AND/OR/EOR between two
/// equal-sized bitmaps across all four RGBA bands.
pub fn booleanWith(self: SmBitmap, operand: SmBitmap, op: ToneBoolOp) ToneError!SmBitmap {
    return tone_mod.booleanWith(self, operand, op);
}

// ---- histogram / HSV (Phase 4) ------------------------------------------

pub const HistogramError = histogram_mod.Error;
pub const HsvError = hsv_mod.Error;

/// normalise(lower_pct, upper_pct) — luma-percentile contrast stretch.
/// Sharp parity (default 1, 99). α preserved.
pub fn normalise(self: SmBitmap, lower_pct: f64, upper_pct: f64) HistogramError!SmBitmap {
    return histogram_mod.normalise(self, lower_pct, upper_pct);
}

/// clahe(tile_w, tile_h, max_slope) — Contrast-Limited Adaptive
/// Histogram Equalisation on luma; RGB scaled by newL/oldL.
pub fn clahe(
    self: SmBitmap,
    tile_w: u32,
    tile_h: u32,
    max_slope: f64,
) HistogramError!SmBitmap {
    return histogram_mod.clahe(self, tile_w, tile_h, max_slope);
}

/// modulate(brightness, saturation, hue_deg, lightness) — HSV-domain
/// adjustments. Approximates sharp's LCh hue rotation; α preserved.
pub fn modulate(
    self: SmBitmap,
    brightness: f64,
    saturation: f64,
    hue_deg: f64,
    lightness: f64,
) HsvError!SmBitmap {
    return hsv_mod.modulate(self, brightness, saturation, hue_deg, lightness);
}

/// fromSurfacePixels — construct a Bitmap holding a snapshot of a region of
/// some surface's u32 RGBA pixel buffer. Mirrors `SkBitmap::readPixels` +
/// `SkConvertPixels`: format conversion (`rgba_unorm8` ↔ `rgba_float16`)
/// happens here, and any out-of-bounds region comes back as transparent
/// black (zero).
///
/// Caller passes the allocator explicitly because SmCanvas.getImageData
/// (the only caller) has its surface's allocator on hand. Negative `sw` /
/// `sh` reflect the rectangle toward `-x` / `-y` per the HTML5 spec.
pub fn fromSurfacePixels(
    allocator: std.mem.Allocator,
    surface_pixels: []const u32,
    surface_w: u32,
    surface_h: u32,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    settings: types.BitmapSettings,
) FromSurfaceError!SmBitmap {
    return fromSurfacePixelsOrdered(allocator, surface_pixels, surface_w, surface_h, sx, sy, sw, sh, settings, .rgba8888);
}

/// Variant carrying the SOURCE surface's byte order. Bitmaps / ImageData
/// are always RGBA (WHATWG), so `.bgra8888` sources are lane-folded during
/// the copy. Additive — the original arity stays binding-frozen.
pub fn fromSurfacePixelsOrdered(
    allocator: std.mem.Allocator,
    surface_pixels: []const u32,
    surface_w: u32,
    surface_h: u32,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    settings: types.BitmapSettings,
    src_order: types.ColorType,
) FromSurfaceError!SmBitmap {
    if (sw == 0 or sh == 0) return error.IndexSize;

    const abs_w: u32 = @intCast(if (sw < 0) -sw else sw);
    const abs_h: u32 = @intCast(if (sh < 0) -sh else sh);
    const norm_x: i32 = if (sw < 0) sx + sw else sx;
    const norm_y: i32 = if (sh < 0) sy + sh else sy;

    const bpp = bytesPerPixel(settings.pixelFormat);
    const pixel_count: usize = @as(usize, abs_w) * @as(usize, abs_h);
    const data = try allocator.alloc(u8, pixel_count * bpp);
    @memset(data, 0); // out-of-bounds region stays zero (transparent black).

    // Intersect requested region with surface bounds.
    const cw: i32 = @intCast(surface_w);
    const ch: i32 = @intCast(surface_h);
    const x0 = @max(0, norm_x);
    const y0 = @max(0, norm_y);
    const x1 = @min(cw, norm_x + @as(i32, @intCast(abs_w)));
    const y1 = @min(ch, norm_y + @as(i32, @intCast(abs_h)));

    if (x0 < x1 and y0 < y1) {
        const copy_w: usize = @intCast(x1 - x0);
        var src_y: i32 = y0;
        while (src_y < y1) : (src_y += 1) {
            const src_row: usize = @intCast(src_y);
            const src_col: usize = @intCast(x0);
            const dst_row: usize = @intCast(src_y - norm_y);
            const dst_col: usize = @intCast(x0 - norm_x);

            const src_slice = surface_pixels[src_row * @as(usize, surface_w) + src_col ..][0..copy_w];
            switch (settings.pixelFormat) {
                .rgba_unorm8 => {
                    const dst_u32: [*]u32 = @ptrCast(@alignCast(data.ptr));
                    const dst_slice = (dst_u32 + dst_row * abs_w + dst_col)[0..copy_w];
                    switch (src_order) {
                        .rgba8888 => simd.copyU32(dst_slice, src_slice),
                        .bgra8888 => simd.swizzleRBCopyU32(dst_slice, src_slice),
                    }
                },
                .rgba_float16 => {
                    const dst_f16: [*]f16 = @ptrCast(@alignCast(data.ptr));
                    const dst_components_per_row: usize = @as(usize, abs_w) * 4;
                    const dst_offset = dst_row * dst_components_per_row + dst_col * 4;
                    const dst_slice = (dst_f16 + dst_offset)[0 .. copy_w * 4];
                    switch (src_order) {
                        .rgba8888 => simd.copyU32ToFloat16Norm(dst_slice, src_slice),
                        .bgra8888 => {
                            // Chunked swizzle → convert. Float16 readback of
                            // BGRA surfaces is rare; a stack scratch is fine.
                            var tmp: [64]u32 = undefined;
                            var off: usize = 0;
                            while (off < copy_w) {
                                const n = @min(tmp.len, copy_w - off);
                                simd.swizzleRBCopyU32(tmp[0..n], src_slice[off..][0..n]);
                                simd.copyU32ToFloat16Norm(dst_slice[off * 4 ..][0 .. n * 4], tmp[0..n]);
                                off += n;
                            }
                        },
                    }
                },
            }
        }
    }

    return .{
        .data = data,
        .width = abs_w,
        .height = abs_h,
        .colorSpace = settings.colorSpace,
        .pixelFormat = settings.pixelFormat,
    };
}
