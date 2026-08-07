//! SIMD kernel facade — comptime-selects an arch-tuned backend with
//! identical signatures across implementations. Callers (`core/raster.zig`)
//! import this file only and never see the backend choice.
//!
//! Mirrors Skia's `SkOpts` dispatcher in `src/opts/`.
//!
//! Backend layout (`zig/simdra/opts/`):
//!
//!   generic.zig — portable `@Vector(N)` baseline. Used for WASM, x86 (no
//!                 separate backend yet), and the byte-equal correctness
//!                 reference for arch-tuned backends.
//!   neon.zig    — aarch64-tuned. Currently re-exports generic for most
//!                 kernels; tune individual kernels in place to replace
//!                 the baseline on aarch64 builds.
//!
//! Each backend exports the same kernel set with the same signatures.
//! `core/raster.zig` only ever imports this file (`../opts/simd.zig`) and
//! calls `simd.fillU32`, `simd.copyU32`, `simd.copyU32ToFloat16Norm`, ...
//! — the arch dispatch is invisible to it.

const builtin = @import("builtin");

const backend = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => @import("neon.zig"),
    // Future: .x86_64 => @import("x86.zig"),
    else => @import("generic.zig"),
};

// Re-export the kernel set. Add new kernels here whenever a backend grows
// one — this is the contract every backend must satisfy.
pub const ChunkSize = backend.ChunkSize;
pub const Chunk = backend.Chunk;
pub const Float16ChunkPixels = backend.Float16ChunkPixels;
pub const SrcOverChunkPixels = backend.SrcOverChunkPixels;

pub const fillU32 = backend.fillU32;
pub const copyU32 = backend.copyU32;
pub const copyU32ToFloat16Norm = backend.copyU32ToFloat16Norm;
pub const blendSrcOverU32 = backend.blendSrcOverU32;
pub const blendSrcOverCovU32 = backend.blendSrcOverCovU32;
pub const blendAddU32 = backend.blendAddU32;

// Full HTML5 globalCompositeOperation set.
pub const blendSrcInU32 = backend.blendSrcInU32;
pub const blendSrcOutU32 = backend.blendSrcOutU32;
pub const blendSrcAtopU32 = backend.blendSrcAtopU32;
pub const blendDstOverU32 = backend.blendDstOverU32;
pub const blendDstInU32 = backend.blendDstInU32;
pub const blendDstOutU32 = backend.blendDstOutU32;
pub const blendDstAtopU32 = backend.blendDstAtopU32;
pub const blendXorU32 = backend.blendXorU32;
pub const blendMultiplyU32 = backend.blendMultiplyU32;
pub const blendScreenU32 = backend.blendScreenU32;
pub const blendOverlayU32 = backend.blendOverlayU32;
pub const blendDarkenU32 = backend.blendDarkenU32;
pub const blendLightenU32 = backend.blendLightenU32;
pub const blendColorDodgeU32 = backend.blendColorDodgeU32;
pub const blendColorBurnU32 = backend.blendColorBurnU32;
pub const blendHardLightU32 = backend.blendHardLightU32;
pub const blendSoftLightU32 = backend.blendSoftLightU32;
pub const blendDifferenceU32 = backend.blendDifferenceU32;
pub const blendExclusionU32 = backend.blendExclusionU32;
pub const blendHueU32 = backend.blendHueU32;
pub const blendSaturationU32 = backend.blendSaturationU32;
pub const blendColorU32 = backend.blendColorU32;
pub const blendLuminosityU32 = backend.blendLuminosityU32;

// Coverage variants — one per blend mode that's not on the optimized
// `blendSrcOverCovU32` fast path. SmBlitter dispatches into these when
// `blitRow` is given a coverage row and the paint's blend mode is not
// `src` / `src_over` / `copy`.
pub const blendSrcInCovU32 = backend.blendSrcInCovU32;
pub const blendSrcOutCovU32 = backend.blendSrcOutCovU32;
pub const blendSrcAtopCovU32 = backend.blendSrcAtopCovU32;
pub const blendDstOverCovU32 = backend.blendDstOverCovU32;
pub const blendDstInCovU32 = backend.blendDstInCovU32;
pub const blendDstOutCovU32 = backend.blendDstOutCovU32;
pub const blendDstAtopCovU32 = backend.blendDstAtopCovU32;
pub const blendXorCovU32 = backend.blendXorCovU32;
pub const blendAddCovU32 = backend.blendAddCovU32;
pub const blendMultiplyCovU32 = backend.blendMultiplyCovU32;
pub const blendScreenCovU32 = backend.blendScreenCovU32;
pub const blendOverlayCovU32 = backend.blendOverlayCovU32;
pub const blendDarkenCovU32 = backend.blendDarkenCovU32;
pub const blendLightenCovU32 = backend.blendLightenCovU32;
pub const blendColorDodgeCovU32 = backend.blendColorDodgeCovU32;
pub const blendColorBurnCovU32 = backend.blendColorBurnCovU32;
pub const blendHardLightCovU32 = backend.blendHardLightCovU32;
pub const blendSoftLightCovU32 = backend.blendSoftLightCovU32;
pub const blendDifferenceCovU32 = backend.blendDifferenceCovU32;
pub const blendExclusionCovU32 = backend.blendExclusionCovU32;
pub const blendHueCovU32 = backend.blendHueCovU32;
pub const blendSaturationCovU32 = backend.blendSaturationCovU32;
pub const blendColorCovU32 = backend.blendColorCovU32;
pub const blendLuminosityCovU32 = backend.blendLuminosityCovU32;

// BGRA-destination non-separable variants + R/B swizzle (color-type support).
pub const blendHueBgraU32 = backend.blendHueBgraU32;
pub const blendSaturationBgraU32 = backend.blendSaturationBgraU32;
pub const blendColorBgraU32 = backend.blendColorBgraU32;
pub const blendLuminosityBgraU32 = backend.blendLuminosityBgraU32;
pub const blendHueCovBgraU32 = backend.blendHueCovBgraU32;
pub const blendSaturationCovBgraU32 = backend.blendSaturationCovBgraU32;
pub const blendColorCovBgraU32 = backend.blendColorCovBgraU32;
pub const blendLuminosityCovBgraU32 = backend.blendLuminosityCovBgraU32;
pub const swizzleRB = backend.swizzleRB;
pub const swizzleRBCopyU32 = backend.swizzleRBCopyU32;

// Flash (SWF) blend modes — subtract/invert/alpha/erase (PlaceObject3).
pub const blendFlashSubtractU32 = backend.blendFlashSubtractU32;
pub const blendFlashInvertU32 = backend.blendFlashInvertU32;
pub const blendFlashAlphaU32 = backend.blendFlashAlphaU32;
pub const blendFlashEraseU32 = backend.blendFlashEraseU32;
pub const blendFlashSubtractCovU32 = backend.blendFlashSubtractCovU32;
pub const blendFlashInvertCovU32 = backend.blendFlashInvertCovU32;
pub const blendFlashAlphaCovU32 = backend.blendFlashAlphaCovU32;
pub const blendFlashEraseCovU32 = backend.blendFlashEraseCovU32;
pub const colorMatrixU32 = backend.colorMatrixU32;

pub const sampleImageNearestRow = backend.sampleImageNearestRow;
pub const sampleImageBilinearRow = backend.sampleImageBilinearRow;
pub const NearestSampleChunkPixels = backend.NearestSampleChunkPixels;

pub const boxBlurAlphaH = backend.boxBlurAlphaH;
pub const boxBlurAlphaV = backend.boxBlurAlphaV;
pub const gaussianBlurAlpha = backend.gaussianBlurAlpha;
pub const gaussianBlurU32 = backend.gaussianBlurU32;
pub const brightnessU32 = backend.brightnessU32;
pub const contrastU32 = backend.contrastU32;
