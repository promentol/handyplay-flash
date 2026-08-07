//! handyflash's vendored simdra root — the pure-Zig drawing core only.
//! Vendored from github.com/promentol/simdra (MIT, see LICENSE) at 0.2.0+
//! (commit 256b243). Differences from upstream's zig/simdra.zig entry:
//! no zigar/JS bindings, no async encode workers, no embedded default
//! font (handyflash renders SWF-embedded glyphs as shapes; SmFont/stb
//! remain available for a future device-font fallback).
//!
//! Re-vendor by copying zig/simdra/ from the simdra repo and keeping this
//! root file.

pub const SmSurface = @import("simdra/core/SmSurface.zig");
pub const SmCanvas = @import("simdra/core/SmCanvas.zig");
pub const SmBitmap = @import("simdra/core/SmBitmap.zig");
pub const SmMatrix = @import("simdra/core/SmMatrix.zig");
pub const SmPath = @import("simdra/core/SmPath.zig");
pub const SmPaint = @import("simdra/core/SmPaint.zig");
pub const SmScan = @import("simdra/core/SmScan.zig");
pub const SmBlitter = @import("simdra/core/SmBlitter.zig");
pub const SmGradient = @import("simdra/effects/SmGradient.zig");
pub const SmPattern = @import("simdra/effects/SmPattern.zig");
pub const SmFont = @import("simdra/core/SmFont.zig");
pub const simd = @import("simdra/opts/simd.zig");
pub const decode = @import("simdra/decode/stb.zig");

const types = @import("simdra/core/types.zig");
pub const ColorSpace = types.ColorSpace;
pub const PixelFormat = types.PixelFormat;
pub const ColorType = types.ColorType;
pub const BitmapSettings = types.BitmapSettings;
pub const packRGBA = types.packRGBA;
