//! aarch64 / NEON-tuned SIMD backend.
//!
//! The dispatcher in `simd.zig` selects this file on aarch64 builds. Tune
//! kernels in place; any kernel not listed here just inherits from the
//! generic backend via the explicit re-exports at the bottom.
//!
//! Suggested tuning order (highest impact first):
//!
//!   1. blendOver (when alpha-aware fill arrives) — `vmlal_u8` for 8-lane
//!      `(u16) acc += a*b`, or FP16 `vfmaq_f16` on Apple Silicon.
//!   2. sampleLinearGrad / sampleRadialGrad — when CanvasGradient samplers
//!      stop being stubs, do per-pixel weight blends with `udot.4s.16b`
//!      (dotprod ext) for 4×u8 dot per cycle.
//!   3. copyU32ToFloat16Norm — already vectorized below; tune chunk size /
//!      load-store sequencing for the M-series ports if benchmarking
//!      shows it pays.
//!   4. adler32 / crc32 in png.zig — NEON has dedicated `crc32cb` and
//!      `vshlq` reductions for adler.
//!
//! Apple Silicon (and any ARMv8.4-A) has FP16 + dotprod always available,
//! so you can assume them at comptime when implementing new kernels:
//!
//!     const has_fp16 = comptime std.Target.aarch64.featureSetHas(
//!         builtin.cpu.features, .fp16);
//!     const has_dot  = comptime std.Target.aarch64.featureSetHas(
//!         builtin.cpu.features, .dotprod);
//!
//! For instructions LLVM emits suboptimally, drop to `asm volatile`. Keep
//! a byte-equal diff against the generic backend in tests so arch-specific
//! bugs surface immediately.

const generic = @import("generic.zig");

// --- u32 RGBA → f16 RGBA with /255 normalization ---------------------------
// Lane plan per chunk (N = 8 pixels):
//   src   : @Vector(8, u32)               // 8 RGBA pixels packed
//   bytes : @Vector(32, u8)  = @bitCast   // R0,G0,B0,A0,R1,G1,B1,A1,...
//   wide  : @Vector(32, f32) = @floatFromInt   // → NEON `uxtl` + `ucvtf`
//   norm  : wide * splat(1/255)
//   half  : @Vector(32, f16) = @floatCast      // → NEON `fcvtn` (FP16 ext)
// Replaces the scalar generic version one-to-one — `raster.zig` doesn't
// know which path it gets.
pub const Float16ChunkPixels = 8;

pub fn copyU32ToFloat16Norm(dst: []f16, src: []const u32) void {
    const std = @import("std");
    std.debug.assert(dst.len == src.len * 4);
    const N = Float16ChunkPixels;
    const components = N * 4;
    const inv_255_v: @Vector(components, f32) = @splat(@as(f32, 1.0 / 255.0));

    var i: usize = 0;
    while (i + N <= src.len) : (i += N) {
        const px: @Vector(N, u32) = src[i..][0..N].*;
        const bytes: @Vector(components, u8) = @bitCast(px);
        const wide: @Vector(components, f32) = @floatFromInt(bytes);
        const norm = wide * inv_255_v;
        const half: @Vector(components, f16) = @floatCast(norm);
        dst[i * 4 ..][0..components].* = half;
    }

    // Scalar tail for the final < N pixels.
    const inv_255: f32 = 1.0 / 255.0;
    while (i < src.len) : (i += 1) {
        const px = src[i];
        const r: u8 = @truncate(px);
        const g: u8 = @truncate(px >> 8);
        const b: u8 = @truncate(px >> 16);
        const a: u8 = @truncate(px >> 24);
        const base = i * 4;
        dst[base + 0] = @floatCast(@as(f32, @floatFromInt(r)) * inv_255);
        dst[base + 1] = @floatCast(@as(f32, @floatFromInt(g)) * inv_255);
        dst[base + 2] = @floatCast(@as(f32, @floatFromInt(b)) * inv_255);
        dst[base + 3] = @floatCast(@as(f32, @floatFromInt(a)) * inv_255);
    }
}

// --- Inherited from generic (no NEON-specific tuning yet) ------------------

pub const ChunkSize = generic.ChunkSize;
pub const Chunk = generic.Chunk;
pub const SrcOverChunkPixels = generic.SrcOverChunkPixels;

pub const fillU32 = generic.fillU32;
pub const copyU32 = generic.copyU32;
pub const blendSrcOverU32 = generic.blendSrcOverU32;
pub const blendSrcOverCovU32 = generic.blendSrcOverCovU32;
pub const blendAddU32 = generic.blendAddU32;

pub const blendSrcInU32 = generic.blendSrcInU32;
pub const blendSrcOutU32 = generic.blendSrcOutU32;
pub const blendSrcAtopU32 = generic.blendSrcAtopU32;
pub const blendDstOverU32 = generic.blendDstOverU32;
pub const blendDstInU32 = generic.blendDstInU32;
pub const blendDstOutU32 = generic.blendDstOutU32;
pub const blendDstAtopU32 = generic.blendDstAtopU32;
pub const blendXorU32 = generic.blendXorU32;
pub const blendMultiplyU32 = generic.blendMultiplyU32;
pub const blendScreenU32 = generic.blendScreenU32;
pub const blendOverlayU32 = generic.blendOverlayU32;
pub const blendDarkenU32 = generic.blendDarkenU32;
pub const blendLightenU32 = generic.blendLightenU32;
pub const blendColorDodgeU32 = generic.blendColorDodgeU32;
pub const blendColorBurnU32 = generic.blendColorBurnU32;
pub const blendHardLightU32 = generic.blendHardLightU32;
pub const blendSoftLightU32 = generic.blendSoftLightU32;
pub const blendDifferenceU32 = generic.blendDifferenceU32;
pub const blendExclusionU32 = generic.blendExclusionU32;
pub const blendHueU32 = generic.blendHueU32;
pub const blendSaturationU32 = generic.blendSaturationU32;
pub const blendColorU32 = generic.blendColorU32;
pub const blendLuminosityU32 = generic.blendLuminosityU32;

// Coverage variants — one per non-fast-path blend mode.
pub const blendSrcInCovU32 = generic.blendSrcInCovU32;
pub const blendSrcOutCovU32 = generic.blendSrcOutCovU32;
pub const blendSrcAtopCovU32 = generic.blendSrcAtopCovU32;
pub const blendDstOverCovU32 = generic.blendDstOverCovU32;
pub const blendDstInCovU32 = generic.blendDstInCovU32;
pub const blendDstOutCovU32 = generic.blendDstOutCovU32;
pub const blendDstAtopCovU32 = generic.blendDstAtopCovU32;
pub const blendXorCovU32 = generic.blendXorCovU32;
pub const blendAddCovU32 = generic.blendAddCovU32;
pub const blendMultiplyCovU32 = generic.blendMultiplyCovU32;
pub const blendScreenCovU32 = generic.blendScreenCovU32;
pub const blendOverlayCovU32 = generic.blendOverlayCovU32;
pub const blendDarkenCovU32 = generic.blendDarkenCovU32;
pub const blendLightenCovU32 = generic.blendLightenCovU32;
pub const blendColorDodgeCovU32 = generic.blendColorDodgeCovU32;
pub const blendColorBurnCovU32 = generic.blendColorBurnCovU32;
pub const blendHardLightCovU32 = generic.blendHardLightCovU32;
pub const blendSoftLightCovU32 = generic.blendSoftLightCovU32;
pub const blendDifferenceCovU32 = generic.blendDifferenceCovU32;
pub const blendExclusionCovU32 = generic.blendExclusionCovU32;
pub const blendHueCovU32 = generic.blendHueCovU32;
pub const blendSaturationCovU32 = generic.blendSaturationCovU32;
pub const blendColorCovU32 = generic.blendColorCovU32;
pub const blendLuminosityCovU32 = generic.blendLuminosityCovU32;

// BGRA-destination non-separable variants + R/B swizzle (color-type support).
pub const blendHueBgraU32 = generic.blendHueBgraU32;
pub const blendSaturationBgraU32 = generic.blendSaturationBgraU32;
pub const blendColorBgraU32 = generic.blendColorBgraU32;
pub const blendLuminosityBgraU32 = generic.blendLuminosityBgraU32;
pub const blendHueCovBgraU32 = generic.blendHueCovBgraU32;
pub const blendSaturationCovBgraU32 = generic.blendSaturationCovBgraU32;
pub const blendColorCovBgraU32 = generic.blendColorCovBgraU32;
pub const blendLuminosityCovBgraU32 = generic.blendLuminosityCovBgraU32;
pub const swizzleRB = generic.swizzleRB;
pub const swizzleRBCopyU32 = generic.swizzleRBCopyU32;

// Flash (SWF) blend modes — subtract/invert/alpha/erase (PlaceObject3).
pub const blendFlashSubtractU32 = generic.blendFlashSubtractU32;
pub const blendFlashInvertU32 = generic.blendFlashInvertU32;
pub const blendFlashAlphaU32 = generic.blendFlashAlphaU32;
pub const blendFlashEraseU32 = generic.blendFlashEraseU32;
pub const blendFlashSubtractCovU32 = generic.blendFlashSubtractCovU32;
pub const blendFlashInvertCovU32 = generic.blendFlashInvertCovU32;
pub const blendFlashAlphaCovU32 = generic.blendFlashAlphaCovU32;
pub const blendFlashEraseCovU32 = generic.blendFlashEraseCovU32;
pub const colorMatrixU32 = generic.colorMatrixU32;

pub const sampleImageNearestRow = generic.sampleImageNearestRow;
pub const sampleImageBilinearRow = generic.sampleImageBilinearRow;
pub const NearestSampleChunkPixels = generic.NearestSampleChunkPixels;

pub const boxBlurAlphaH = generic.boxBlurAlphaH;
pub const boxBlurAlphaV = generic.boxBlurAlphaV;
pub const gaussianBlurAlpha = generic.gaussianBlurAlpha;
pub const gaussianBlurU32 = generic.gaussianBlurU32;
pub const brightnessU32 = generic.brightnessU32;
pub const contrastU32 = generic.contrastU32;
