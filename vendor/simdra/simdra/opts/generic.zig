//! Generic SIMD backend — portable `@Vector(N)` implementations.
//! Lowered to NEON v128 ops on aarch64, AVX/SSE on x86_64, and v128 on
//! WebAssembly. This is the fallback when no arch-specific backend is
//! selected, the WASM target, and the byte-equality reference for the
//! arch-tuned backends.
//!
//! Chunk size = 16 u32 = 64 bytes = 16 RGBA pixels. Chosen wide so AVX-512
//! targets get a full register; smaller-width archs lower it to multiple
//! ops per chunk (4 NEON v128 ops, 2 AVX2 ops). Tune per-kernel locally if
//! a different lane count is faster on the targeted backend.

const std = @import("std");

pub const ChunkSize = 16;
pub const Chunk = @Vector(ChunkSize, u32);

pub fn fillU32(dst: []u32, value: u32) void {
    const chunk: Chunk = @splat(value);
    var i: usize = 0;
    while (i + ChunkSize <= dst.len) : (i += ChunkSize) {
        dst[i..][0..ChunkSize].* = chunk;
    }
    while (i < dst.len) : (i += 1) {
        dst[i] = value;
    }
}

pub fn copyU32(dst: []u32, src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i + ChunkSize <= dst.len) : (i += ChunkSize) {
        const chunk: Chunk = src[i..][0..ChunkSize].*;
        dst[i..][0..ChunkSize].* = chunk;
    }
    while (i < dst.len) : (i += 1) {
        dst[i] = src[i];
    }
}

// Pixel-level u32 RGBA → f16 RGBA conversion with /255 normalization.
// One source pixel produces four f16 components; `dst.len` must be 4*src.len.
//
// Generic backend keeps this scalar — vectorizing the f16 cast requires
// hardware FP16 (ARMv8.2-A FP16 ext, AVX-512 F16C) which the LLVM WASM
// target rejects with "Invalid cast". The aarch64 backend overrides this
// kernel with a `@Vector(8, f16)` implementation that lowers to `fcvtn`.
pub const Float16ChunkPixels = 1;

// blendSrcOverU32 — Porter-Duff src_over for a SOLID source color over an
// existing RGBA8 destination row. Source color is **non-premultiplied** RGBA
// (HTML5 / Canvas convention). Internally we premultiply src.rgb by src.a
// once, then run the standard Porter-Duff formula:
//
//   dst' = src_premult + dst * (1 - src.a / 255)
//   where src_premult.rgb = src.rgb * src.a / 255 ; src_premult.a = src.a
//
// Per-channel u8 math, vectorized 8 pixels (32 channels) at a time. Lane plan:
//
//   dst_v        : @Vector(8, u32)         // 8 RGBA pixels packed
//   dst_b        : @Vector(32, u8)  = bitCast(dst_v)
//   dst_w        : @Vector(32, u16) = widen      // need u16 for x*inv_sa headroom
//   src_premult  : @Vector(32, u16) = splat per-channel premultiplied src bytes
//   inv_sa       : @Vector(32, u16) = splat (255 - src.a)
//   prod         : dst_w * inv_sa
//   div          : (prod + 0x80) >> 8            // fast x/255 ≈ (x + 128) >> 8 (off ≤1/256)
//   blended      : src_premult + div, narrowed back to u8
//
// LLVM lowers to NEON `umull` + `uxtl` + `fadd` chain, or AVX2 `vpmullw` +
// `vpunpck` chain. Tail processed scalar to keep the kernel simple.
pub const SrcOverChunkPixels = 8;

pub fn blendSrcOverU32(dst: []u32, src_color: u32) void {
    const sa: u32 = (src_color >> 24) & 0xFF;
    if (sa == 0) return; // fully transparent source — no-op
    if (sa == 0xFF) { // fully opaque source — direct fill (premultiplied = raw bytes)
        fillU32(dst, src_color);
        return;
    }
    // Use the proper Porter-Duff Co = co_premult / αo formula via pdScalar
    // so transparent / partially-transparent dst (e.g. when called inside a
    // composite-layer's scratch buffer) gets the correct non-premultiplied
    // output. The previous vectorized path assumed `da=1` and produced
    // premultiplied output for non-opaque dst — visually wrong inside a
    // composite layer. Re-add a SIMD fast path here when a profile shows
    // it pays for the opaque-dst common case.
    for (dst) |*p| p.* = srcOverScalarPD(src_color, p.*);
}

// blendSrcOverCovU32 — Porter-Duff src_over with a SOLID source color and a
// PER-PIXEL u8 coverage row. Used by glyph rasterization (alpha row from
// stb_truetype as coverage) and by analytic-edge anti-aliased path filling.
//
// Coverage modulates source.a per pixel before the standard src_over blend:
//
//     a_eff = sa * cov[i] / 255
//     src_eff.rgb = src.rgb * a_eff / 255       (premultiplied)
//     dst' = src_eff + dst * (1 - a_eff / 255)
//
// Scalar today; vectorize when this kernel shows up on a profile (the
// outer per-pixel work is identical to blendSrcOverU32 with cov layered on).
/// `x * y / 255`, exactly, in shifts. The bare `(x*y + 128) >> 8` is a
/// unit short at the top — 255*255 lands on 254 — and that is visible
/// whenever a FULLY covered pixel goes through the coverage path, which
/// is what a clip mask makes every masked pixel do.
inline fn mul255(x: u32, y: u32) u32 {
    const t: u32 = x * y + 0x80;
    return (t + (t >> 8)) >> 8;
}

pub fn blendSrcOverCovU32(dst: []u32, src_color: u32, coverage: []const u8) void {
    std.debug.assert(dst.len == coverage.len);
    const sa: u32 = (src_color >> 24) & 0xFF;
    if (sa == 0) return;

    const sr: u32 = src_color & 0xFF;
    const sg: u32 = (src_color >> 8) & 0xFF;
    const sb: u32 = (src_color >> 16) & 0xFF;

    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const cov: u32 = coverage[i];
        if (cov == 0) continue;
        const a_eff: u32 = mul255(sa, cov);
        if (a_eff == 0) continue;
        const inv_a: u32 = 255 - a_eff;
        const r_eff: u32 = mul255(sr, a_eff);
        const g_eff: u32 = mul255(sg, a_eff);
        const b_eff: u32 = mul255(sb, a_eff);
        const dst_p = dst[i];
        const dr: u32 = dst_p & 0xFF;
        const dg: u32 = (dst_p >> 8) & 0xFF;
        const db: u32 = (dst_p >> 16) & 0xFF;
        const da: u32 = (dst_p >> 24) & 0xFF;
        const r: u32 = r_eff + mul255(dr, inv_a);
        const g: u32 = g_eff + mul255(dg, inv_a);
        const b: u32 = b_eff + mul255(db, inv_a);
        const a: u32 = a_eff + mul255(da, inv_a);
        dst[i] = r | (g << 8) | (b << 16) | (a << 24);
    }
}

// blendAddU32 — saturating per-channel add of a SOLID source color into an
// existing RGBA8 destination row. Maps to HTML5 `globalCompositeOperation =
// "lighter"` and Love2D `setBlendMode("add")`.
//
//   dst' = sat(src + dst)   per channel, clamped at 0xFF
//
// Vectorized 8 pixels (32 channels) at a time using Zig's `+|` saturating
// vector add — lowers to `vqaddq.u8` (NEON) / `vpaddusb` (AVX2).
pub fn blendAddU32(dst: []u32, src_color: u32) void {
    const sa: u32 = (src_color >> 24) & 0xFF;
    if (sa == 0) return; // fully transparent source — no contribution

    const N = SrcOverChunkPixels;
    const components = N * 4;
    const Pixels = @Vector(N, u32);
    const Bytes = @Vector(components, u8);

    // Build per-channel src vector (R, G, B, A repeated N times).
    var src_arr: [components]u8 = undefined;
    const sR: u8 = @intCast(src_color & 0xFF);
    const sG: u8 = @intCast((src_color >> 8) & 0xFF);
    const sB: u8 = @intCast((src_color >> 16) & 0xFF);
    const sA: u8 = @intCast(sa);
    {
        var k: usize = 0;
        while (k < N) : (k += 1) {
            src_arr[k * 4 + 0] = sR;
            src_arr[k * 4 + 1] = sG;
            src_arr[k * 4 + 2] = sB;
            src_arr[k * 4 + 3] = sA;
        }
    }
    const src_v: Bytes = src_arr;

    var i: usize = 0;
    while (i + N <= dst.len) : (i += N) {
        const dst_pix: Pixels = dst[i..][0..N].*;
        const dst_b: Bytes = @bitCast(dst_pix);
        const sum: Bytes = dst_b +| src_v; // saturating per-lane add
        const result_pix: Pixels = @bitCast(sum);
        dst[i..][0..N].* = result_pix;
    }

    // Scalar tail.
    while (i < dst.len) : (i += 1) {
        dst[i] = blendAddScalar(src_color, dst[i]);
    }
}

inline fn blendAddScalar(src: u32, dst: u32) u32 {
    const sr = src & 0xFF;
    const sg = (src >> 8) & 0xFF;
    const sb = (src >> 16) & 0xFF;
    const sa = (src >> 24) & 0xFF;
    const dr = dst & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = (dst >> 16) & 0xFF;
    const da = (dst >> 24) & 0xFF;
    const r: u32 = @min(@as(u32, 0xFF), dr + sr);
    const g: u32 = @min(@as(u32, 0xFF), dg + sg);
    const b: u32 = @min(@as(u32, 0xFF), db + sb);
    const a: u32 = @min(@as(u32, 0xFF), da + sa);
    return r | (g << 8) | (b << 16) | (a << 24);
}

// =============================================================================
// Full HTML5 globalCompositeOperation set — W3C Compositing & Blending L1.
// =============================================================================
//
// Three families:
//   • Porter-Duff: parametrized by (Fa, Fb) factor pair. One scalar evaluator
//     `pdScalar`, one factor function per operator. 11 modes.
//   • Separable blend: per-channel blend function `B(Cb, Cs)` combined with
//     Porter-Duff source-over. 11 modes.
//   • Non-separable blend: HSL-shape RGB triple manipulation. 4 modes.
//
// Channel layout: u32 holds R in bits 0-7, G in 8-15, B in 16-23, A in 24-31
// (matches the rest of simdra's pixel storage). Storage is non-premultiplied.
//
// Per-pixel arithmetic uses `(x + 128) >> 8` as the fast x/255 approximation,
// accurate within ±1/256. Row kernels loop over scalar — vectorize hot ones
// (multiply / screen / overlay) when a profile shows it pays.

// Exact x/255 (integer divide). The familiar `(x + 128) >> 8` approximation
// is fine for a single multiply step but its ±1-LSB error compounds when the
// Porter-Duff pipeline does premult → weighted-sum → un-premult, drifting
// the output by 2-3 LSB per pixel. Keep it exact here; LLVM lowers to
// multiply-by-reciprocal so the cost is negligible.
inline fn d255(x: u32) u32 { return x / 255; }
inline fn channelR(p: u32) u32 { return p & 0xFF; }
inline fn channelG(p: u32) u32 { return (p >> 8) & 0xFF; }
inline fn channelB(p: u32) u32 { return (p >> 16) & 0xFF; }
inline fn channelA(p: u32) u32 { return (p >> 24) & 0xFF; }
inline fn packRGBA(r: u32, g: u32, b: u32, a: u32) u32 {
    return r | (g << 8) | (b << 16) | (a << 24);
}

// ---- Unified blend evaluator (Porter-Duff + separable blend) -------------
//
// One envelope handles channel extraction, per-channel premult-output via
// a comptime-supplied `coOf`, then u64-widened un-premultiply and pack.
// Each mode's BlendKernel supplies:
//   • aoOf(sa, da)              → output alpha (0..255)
//   • coOf(cs, cb, sa, da)      → one channel's premultiplied output (0..255)
//
// Porter-Duff form (Fa, Fb factor pair):
//   αo  = Fa·αs + Fb·αb
//   co  = Fa·αs·Cs + Fb·αb·Cb               (premult result, per channel)
//
// Separable-blend form (B = per-channel blend function):
//   αo  = αs + αb·(1 - αs)                  (source-over alpha)
//   co  = (1 - αb)·αs·Cs + (1 - αs)·αb·Cb + αs·αb·B(Cb, Cs)
//
// Both are byte-equal to the pre-unification pdScalar/sepScalar (verified
// per `npm test`'s 47 visual scenes). Non-separable HSL blend lives below;
// it has a different un-premult shape (float throughout) and is not
// expressible through this envelope.

const FactorFn = fn (sa: u32, da: u32) u32;
const ChannelFn = fn (cb: u32, cs: u32) u32;

const BlendKernel = struct {
    /// Output alpha 0..255 from src/dst non-premultiplied alphas.
    aoOf: *const fn (sa: u32, da: u32) u32,
    /// Premultiplied output for one channel (0..255). Non-premult inputs.
    coOf: *const fn (cs: u32, cb: u32, sa: u32, da: u32) u32,
};

inline fn blendScalar(src: u32, dst: u32, comptime k: BlendKernel) u32 {
    const sa = channelA(src); const da = channelA(dst);
    const ao = k.aoOf(sa, da);
    if (ao == 0) return 0;

    const sr = channelR(src); const sg = channelG(src); const sb = channelB(src);
    const dr = channelR(dst); const dg = channelG(dst); const db = channelB(dst);

    const rp = k.coOf(sr, dr, sa, da);
    const gp = k.coOf(sg, dg, sa, da);
    const bp = k.coOf(sb, db, sa, da);

    // Un-premultiply: Co = Cp · 255 / αo. u64-widened to avoid the boundary
    // 255×255 + 127 overflow that Zig 0.15 flags on u32.
    const ao64: u64 = ao;
    const half: u64 = ao64 >> 1;
    const ro = @as(u32, @intCast(@min(@as(u64, 255), (@as(u64, rp) * 255 + half) / ao64)));
    const go = @as(u32, @intCast(@min(@as(u64, 255), (@as(u64, gp) * 255 + half) / ao64)));
    const bo = @as(u32, @intCast(@min(@as(u64, 255), (@as(u64, bp) * 255 + half) / ao64)));
    return packRGBA(ro, go, bo, ao);
}

// ---- Porter-Duff kernels --------------------------------------------------

// Factor functions per W3C spec.
fn faOne(sa: u32, da: u32) u32 { _ = sa; _ = da; return 255; }
fn faZero(sa: u32, da: u32) u32 { _ = sa; _ = da; return 0; }
fn faSa(sa: u32, da: u32) u32 { _ = da; return sa; }
fn faDa(sa: u32, da: u32) u32 { _ = sa; return da; }
fn faInvSa(sa: u32, da: u32) u32 { _ = da; return 255 - sa; }
fn faInvDa(sa: u32, da: u32) u32 { _ = sa; return 255 - da; }

fn pdKernel(comptime fa: FactorFn, comptime fb: FactorFn) BlendKernel {
    return .{
        .aoOf = struct {
            fn ao(sa: u32, da: u32) u32 {
                return @min(@as(u32, 255), d255(sa * fa(sa, da)) + d255(da * fb(sa, da)));
            }
        }.ao,
        .coOf = struct {
            fn co(cs: u32, cb: u32, sa: u32, da: u32) u32 {
                const csp = d255(cs * sa);
                const cbp = d255(cb * da);
                return @min(@as(u32, 255), d255(csp * fa(sa, da)) + d255(cbp * fb(sa, da)));
            }
        }.co,
    };
}

// Per-operator scalar wrappers. Naming mirrors W3C spec.
fn srcOverScalarPD(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faOne, faInvSa)); }
fn srcInScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faDa, faZero)); }
fn srcOutScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faInvDa, faZero)); }
fn srcAtopScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faDa, faInvSa)); }
fn dstOverScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faInvDa, faOne)); }
fn dstInScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faZero, faSa)); }
fn dstOutScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faZero, faInvSa)); }
fn dstAtopScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faInvDa, faSa)); }
fn xorScalar(src: u32, dst: u32) u32 { return blendScalar(src, dst, pdKernel(faInvDa, faInvSa)); }

// ---- Separable-blend kernels ----------------------------------------------

fn sepAo(sa: u32, da: u32) u32 {
    return @min(@as(u32, 255), sa + d255(da * (255 - sa)));
}

fn sepKernel(comptime B: ChannelFn) BlendKernel {
    return .{
        .aoOf = sepAo,
        .coOf = struct {
            fn co(cs: u32, cb: u32, sa: u32, da: u32) u32 {
                const inv_sa: u32 = 255 - sa;
                const inv_da: u32 = 255 - da;
                const t1 = d255(inv_da * sa);
                const t2 = d255(inv_sa * da);
                const t3 = d255(sa * da);
                return @min(@as(u32, 255), d255(t1 * cs) + d255(t2 * cb) + d255(t3 * B(cb, cs)));
            }
        }.co,
    };
}

// Per-channel blend functions B(Cb, Cs). Inputs in 0..255.
fn bMultiply(cb: u32, cs: u32) u32 { return d255(cb * cs); }
fn bScreen(cb: u32, cs: u32) u32 { return cb + cs - d255(cb * cs); }
fn bDarken(cb: u32, cs: u32) u32 { return @min(cb, cs); }
fn bLighten(cb: u32, cs: u32) u32 { return @max(cb, cs); }
fn bDifference(cb: u32, cs: u32) u32 {
    return if (cb > cs) cb - cs else cs - cb;
}
fn bExclusion(cb: u32, cs: u32) u32 {
    return cb + cs - 2 * d255(cb * cs);
}
fn bColorDodge(cb: u32, cs: u32) u32 {
    if (cb == 0) return 0;
    if (cs == 255) return 255;
    // min(1, Cb / (1 - Cs))   (in unit space)
    const num = cb * 255;
    const denom = 255 - cs;
    return @min(@as(u32, 255), num / denom);
}
fn bColorBurn(cb: u32, cs: u32) u32 {
    if (cb == 255) return 255;
    if (cs == 0) return 0;
    // 1 - min(1, (1 - Cb) / Cs)   (in unit space)
    const num = (255 - cb) * 255;
    const ratio = @min(@as(u32, 255), num / cs);
    return 255 - ratio;
}
fn bHardLight(cb: u32, cs: u32) u32 {
    // Cs ≤ 0.5: multiply(Cb, 2·Cs); else screen(Cb, 2·Cs - 1).
    if (cs <= 127) return d255(cb * (cs * 2));
    const cs2 = cs * 2 - 255; // 0..255
    return cb + cs2 - d255(cb * cs2);
}
fn bOverlay(cb: u32, cs: u32) u32 { return bHardLight(cs, cb); } // hard-light with args swapped
fn bSoftLight(cb: u32, cs: u32) u32 {
    // W3C definition uses real arithmetic; do it in floats then convert back.
    const Cb = @as(f64, @floatFromInt(cb)) / 255.0;
    const Cs = @as(f64, @floatFromInt(cs)) / 255.0;
    var result: f64 = 0;
    if (Cs <= 0.5) {
        result = Cb - (1 - 2 * Cs) * Cb * (1 - Cb);
    } else {
        const D = if (Cb <= 0.25)
            ((16 * Cb - 12) * Cb + 4) * Cb
        else
            @sqrt(Cb);
        result = Cb + (2 * Cs - 1) * (D - Cb);
    }
    if (result < 0) result = 0;
    if (result > 1) result = 1;
    return @intFromFloat(@round(result * 255));
}

// ---- Non-separable (HSL-style) blend core ---------------------------------
//
// Operates on the entire RGB triple. The W3C spec defines:
//   Lum(C) = 0.3*Cr + 0.59*Cg + 0.11*Cb
//   Sat(C) = max(C) - min(C)
//   ClipColor(C):
//       L = Lum(C); n = min(C); x = max(C)
//       if (n < 0)  C = L + ((C - L) * L) / (L - n)
//       if (x > 1)  C = L + ((C - L) * (1 - L)) / (x - L)
//   SetLum(C, l):  d = l - Lum(C); C += d; return ClipColor(C)
//   SetSat(C, s):  scale midchannel; max=s, min=0
//
//   Hue:        SetLum(SetSat(Cs, Sat(Cb)), Lum(Cb))
//   Saturation: SetLum(SetSat(Cb, Sat(Cs)), Lum(Cb))
//   Color:      SetLum(Cs, Lum(Cb))
//   Luminosity: SetLum(Cb, Lum(Cs))
//
// Done in floats per pixel — the 4 modes are rare enough that the f64 cost
// is fine for v1.

const RGB = struct { r: f64, g: f64, b: f64 };

inline fn lum(c: RGB) f64 { return 0.30 * c.r + 0.59 * c.g + 0.11 * c.b; }
inline fn satRgb(c: RGB) f64 {
    return @max(@max(c.r, c.g), c.b) - @min(@min(c.r, c.g), c.b);
}

fn clipColor(c: RGB) RGB {
    const L = lum(c);
    const n = @min(@min(c.r, c.g), c.b);
    const x = @max(@max(c.r, c.g), c.b);
    var out = c;
    if (n < 0) {
        const denom = L - n;
        if (denom != 0) {
            out.r = L + ((out.r - L) * L) / denom;
            out.g = L + ((out.g - L) * L) / denom;
            out.b = L + ((out.b - L) * L) / denom;
        }
    }
    if (x > 1) {
        const denom = x - L;
        if (denom != 0) {
            out.r = L + ((out.r - L) * (1 - L)) / denom;
            out.g = L + ((out.g - L) * (1 - L)) / denom;
            out.b = L + ((out.b - L) * (1 - L)) / denom;
        }
    }
    return out;
}

fn setLum(c: RGB, target: f64) RGB {
    const d = target - lum(c);
    return clipColor(.{ .r = c.r + d, .g = c.g + d, .b = c.b + d });
}

fn setSat(c: RGB, s: f64) RGB {
    // Find min/mid/max channels and rescale: max → s, mid → s*(mid-min)/(max-min), min → 0.
    var rs = c.r; var gs = c.g; var bs = c.b;
    // Sort by value while keeping track of which channel is which.
    // 6-case branch — readable and exhaustive.
    var min_v: f64 = undefined; var mid_v: f64 = undefined; var max_v: f64 = undefined;
    var min_i: u8 = 0; var mid_i: u8 = 1; var max_i: u8 = 2;
    if (rs >= gs and rs >= bs) {
        max_v = rs; max_i = 0;
        if (gs >= bs) { mid_v = gs; mid_i = 1; min_v = bs; min_i = 2; }
        else { mid_v = bs; mid_i = 2; min_v = gs; min_i = 1; }
    } else if (gs >= rs and gs >= bs) {
        max_v = gs; max_i = 1;
        if (rs >= bs) { mid_v = rs; mid_i = 0; min_v = bs; min_i = 2; }
        else { mid_v = bs; mid_i = 2; min_v = rs; min_i = 0; }
    } else {
        max_v = bs; max_i = 2;
        if (rs >= gs) { mid_v = rs; mid_i = 0; min_v = gs; min_i = 1; }
        else { mid_v = gs; mid_i = 1; min_v = rs; min_i = 0; }
    }
    const out_min: f64 = 0;
    var out_mid: f64 = 0;
    var out_max: f64 = 0;
    if (max_v > min_v) {
        out_mid = (mid_v - min_v) * s / (max_v - min_v);
        out_max = s;
    }
    rs = 0; gs = 0; bs = 0;
    switch (min_i) { 0 => rs = out_min, 1 => gs = out_min, 2 => bs = out_min, else => unreachable }
    switch (mid_i) { 0 => rs = out_mid, 1 => gs = out_mid, 2 => bs = out_mid, else => unreachable }
    switch (max_i) { 0 => rs = out_max, 1 => gs = out_max, 2 => bs = out_max, else => unreachable }
    return .{ .r = rs, .g = gs, .b = bs };
}

/// colorMatrixU32 — apply a 4×5 color matrix to a row of straight-alpha
/// pixels in LOGICAL RGBA lane order (the Flash ColorMatrixFilter layout,
/// row-major [r-row, g-row, b-row, a-row], each row = 4 channel weights +
/// 1 offset in 0–255 units):
///   out.c = clamp(m[c][0]·R + m[c][1]·G + m[c][2]·B + m[c][3]·A + m[c][4])
/// This is the filter-layer primitive Flash's ColorMatrixFilter (and
/// hue-rotate / saturate / sepia CSS filters) build on; blur, convolution,
/// and shadow primitives already exist elsewhere in this module set.
pub fn colorMatrixU32(row: []u32, m: *const [20]f32) void {
    for (row) |*p| {
        const c = p.*;
        const in = [4]f32{
            @floatFromInt(c & 0xFF),
            @floatFromInt((c >> 8) & 0xFF),
            @floatFromInt((c >> 16) & 0xFF),
            @floatFromInt((c >> 24) & 0xFF),
        };
        var out: u32 = 0;
        inline for (0..4) |ch| {
            const base = ch * 5;
            const v = m[base] * in[0] + m[base + 1] * in[1] +
                m[base + 2] * in[2] + m[base + 3] * in[3] + m[base + 4];
            const clamped: u32 = @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
            out |= clamped << (8 * ch);
        }
        p.* = out;
    }
}

// ---- Flash (SWF) blend modes ---------------------------------------------
//
// PlaceObject3 modes with no HTML5 / Porter-Duff equivalent. Straight-alpha
// formulas matching Flash Player behavior (Ruffle's model):
//   subtract: out.rgb = max(dst.rgb − src.rgb·sa, 0), out.a = da
//   invert:   out.rgb = lerp(dst.rgb, 255 − dst.rgb, sa), out.a = da
//   alpha:    out.rgb = dst.rgb, out.a = da·sa        (masking; needs layer)
//   erase:    out.rgb = dst.rgb, out.a = da·(1 − sa)  (inverse masking)
// All four are R/G/B-symmetric → no Bgra variants needed.

fn flashSubtractScalar(src: u32, dst: u32) u32 {
    const sa = channelA(src);
    if (sa == 0) return dst;
    var out: u32 = channelA(dst) << 24;
    inline for (0..3) |i| {
        const shift = 8 * i;
        const s = (src >> shift) & 0xFF;
        const d = (dst >> shift) & 0xFF;
        const eff = (s * sa + 0x80) >> 8;
        const v = if (d > eff) d - eff else 0;
        out |= v << shift;
    }
    return out;
}

fn flashInvertScalar(src: u32, dst: u32) u32 {
    const sa = channelA(src);
    if (sa == 0) return dst;
    var out: u32 = channelA(dst) << 24;
    inline for (0..3) |i| {
        const shift = 8 * i;
        const d = (dst >> shift) & 0xFF;
        const inv = 255 - d;
        // lerp(d, inv, sa/255) with round-to-nearest.
        const v = (d * (255 - sa) + inv * sa + 127) / 255;
        out |= v << shift;
    }
    return out;
}

fn flashAlphaScalar(src: u32, dst: u32) u32 {
    const sa = channelA(src);
    const da = channelA(dst);
    const a = (da * sa + 127) / 255;
    return (dst & 0x00FFFFFF) | (a << 24);
}

fn flashEraseScalar(src: u32, dst: u32) u32 {
    const sa = channelA(src);
    const da = channelA(dst);
    const a = (da * (255 - sa) + 127) / 255;
    return (dst & 0x00FFFFFF) | (a << 24);
}

const NonSepKind = enum { hue, saturation, color, luminosity };

inline fn nonSepBlendChannels(comptime kind: NonSepKind, cb: RGB, cs: RGB) RGB {
    return switch (kind) {
        .hue => setLum(setSat(cs, satRgb(cb)), lum(cb)),
        .saturation => setLum(setSat(cb, satRgb(cs)), lum(cb)),
        .color => setLum(cs, lum(cb)),
        .luminosity => setLum(cb, lum(cs)),
    };
}

/// Swap the R and B bytes of a packed pixel (RGBA8888 ⇄ BGRA8888 lane
/// permutation). G and A stay put in both layouts.
pub inline fn swizzleRB(c: u32) u32 {
    return (c & 0xFF00FF00) | ((c & 0x000000FF) << 16) | ((c >> 16) & 0x000000FF);
}

/// Bulk R↔B swizzle copy — the RGBA⇄BGRA boundary conversion kernel
/// (encoders, getImageData/putImageData on BGRA surfaces). `dst` and `src`
/// must be equal length; `dst == src` aliasing is fine (pure per-element).
pub fn swizzleRBCopyU32(dst: []u32, src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    const N = 16;
    const V = @Vector(N, u32);
    var i: usize = 0;
    while (i + N <= src.len) : (i += N) {
        const v: V = src[i..][0..N].*;
        const out = (v & @as(V, @splat(0xFF00FF00))) |
            ((v & @as(V, @splat(0x000000FF))) << @as(@Vector(N, u5), @splat(16))) |
            ((v >> @as(@Vector(N, u5), @splat(16))) & @as(V, @splat(0x000000FF)));
        dst[i..][0..N].* = out;
    }
    while (i < src.len) : (i += 1) dst[i] = swizzleRB(src[i]);
}

inline fn nonSepScalar(src: u32, dst: u32, comptime kind: NonSepKind, comptime swap_rb: bool) u32 {
    if (swap_rb) {
        // BGRA destination: fold both operands to logical RGBA so lum()'s
        // (0.30, 0.59, 0.11) coefficients hit the right channels, then
        // fold the result back to surface order. satRgb/setSat are
        // permutation-invariant; only lum-dependent math cares.
        return swizzleRB(nonSepScalarRgba(swizzleRB(src), swizzleRB(dst), kind));
    }
    return nonSepScalarRgba(src, dst, kind);
}

inline fn nonSepScalarRgba(src: u32, dst: u32, comptime kind: NonSepKind) u32 {
    const sa = channelA(src); const da = channelA(dst);
    const inv_sa: u32 = 255 - sa;
    const ao = @min(@as(u32, 255), sa + d255(da * inv_sa));
    if (ao == 0) return 0;

    const cs: RGB = .{
        .r = @as(f64, @floatFromInt(channelR(src))) / 255.0,
        .g = @as(f64, @floatFromInt(channelG(src))) / 255.0,
        .b = @as(f64, @floatFromInt(channelB(src))) / 255.0,
    };
    const cb: RGB = .{
        .r = @as(f64, @floatFromInt(channelR(dst))) / 255.0,
        .g = @as(f64, @floatFromInt(channelG(dst))) / 255.0,
        .b = @as(f64, @floatFromInt(channelB(dst))) / 255.0,
    };
    const blended = nonSepBlendChannels(kind, cb, cs);

    // Composite using the same source-over formula as separable blend.
    const sa_f = @as(f64, @floatFromInt(sa)) / 255.0;
    const da_f = @as(f64, @floatFromInt(da)) / 255.0;
    const inv_sa_f = 1.0 - sa_f;
    const inv_da_f = 1.0 - da_f;

    const cor = inv_da_f * sa_f * cs.r + inv_sa_f * da_f * cb.r + sa_f * da_f * blended.r;
    const cog = inv_da_f * sa_f * cs.g + inv_sa_f * da_f * cb.g + sa_f * da_f * blended.g;
    const cob = inv_da_f * sa_f * cs.b + inv_sa_f * da_f * cb.b + sa_f * da_f * blended.b;

    const ao_f = @as(f64, @floatFromInt(ao)) / 255.0;
    const ro = @min(@as(u32, 255), @as(u32, @intFromFloat(@round(@max(@as(f64, 0), cor) / ao_f * 255.0))));
    const go = @min(@as(u32, 255), @as(u32, @intFromFloat(@round(@max(@as(f64, 0), cog) / ao_f * 255.0))));
    const bo = @min(@as(u32, 255), @as(u32, @intFromFloat(@round(@max(@as(f64, 0), cob) / ao_f * 255.0))));
    return packRGBA(ro, go, bo, ao);
}

// ---- Row kernels ----------------------------------------------------------
// Trivial loop over a single scalar fn — vectorize hot ones if profiling
// shows it pays. Each kernel takes a SOLID source color + a dst row.

fn rowOf(comptime scalar: fn (u32, u32) u32) fn (dst: []u32, src_color: u32) void {
    return struct {
        fn run(dst: []u32, src_color: u32) void {
            for (dst) |*p| p.* = scalar(src_color, p.*);
        }
    }.run;
}

pub const blendSrcInU32 = rowOf(srcInScalar);
pub const blendSrcOutU32 = rowOf(srcOutScalar);
pub const blendSrcAtopU32 = rowOf(srcAtopScalar);
pub const blendDstOverU32 = rowOf(dstOverScalar);
pub const blendDstInU32 = rowOf(dstInScalar);
pub const blendDstOutU32 = rowOf(dstOutScalar);
pub const blendDstAtopU32 = rowOf(dstAtopScalar);
pub const blendXorU32 = rowOf(xorScalar);

fn rowOfSep(comptime B: ChannelFn) fn (dst: []u32, src_color: u32) void {
    return struct {
        fn run(dst: []u32, src_color: u32) void {
            for (dst) |*p| p.* = blendScalar(src_color, p.*, sepKernel(B));
        }
    }.run;
}

pub const blendMultiplyU32 = rowOfSep(bMultiply);
pub const blendScreenU32 = rowOfSep(bScreen);
pub const blendOverlayU32 = rowOfSep(bOverlay);
pub const blendDarkenU32 = rowOfSep(bDarken);
pub const blendLightenU32 = rowOfSep(bLighten);
pub const blendColorDodgeU32 = rowOfSep(bColorDodge);
pub const blendColorBurnU32 = rowOfSep(bColorBurn);
pub const blendHardLightU32 = rowOfSep(bHardLight);
pub const blendSoftLightU32 = rowOfSep(bSoftLight);
pub const blendDifferenceU32 = rowOfSep(bDifference);
pub const blendExclusionU32 = rowOfSep(bExclusion);

fn rowOfNonSep(comptime kind: NonSepKind, comptime swap_rb: bool) fn (dst: []u32, src_color: u32) void {
    return struct {
        fn run(dst: []u32, src_color: u32) void {
            for (dst) |*p| p.* = nonSepScalar(src_color, p.*, kind, swap_rb);
        }
    }.run;
}

pub const blendFlashSubtractU32 = rowOf(flashSubtractScalar);
pub const blendFlashInvertU32 = rowOf(flashInvertScalar);
pub const blendFlashAlphaU32 = rowOf(flashAlphaScalar);
pub const blendFlashEraseU32 = rowOf(flashEraseScalar);

pub const blendHueU32 = rowOfNonSep(.hue, false);
pub const blendSaturationU32 = rowOfNonSep(.saturation, false);
pub const blendColorU32 = rowOfNonSep(.color, false);
pub const blendLuminosityU32 = rowOfNonSep(.luminosity, false);

// BGRA-destination variants: identical math on logical channels, with the
// R↔B lane fold. Only these four blend modes are channel-asymmetric (lum).
pub const blendHueBgraU32 = rowOfNonSep(.hue, true);
pub const blendSaturationBgraU32 = rowOfNonSep(.saturation, true);
pub const blendColorBgraU32 = rowOfNonSep(.color, true);
pub const blendLuminosityBgraU32 = rowOfNonSep(.luminosity, true);

// ---- Coverage-aware row kernels ------------------------------------------
//
// Each kernel pre-modulates `src_color`'s alpha by per-pixel coverage,
// producing an effective per-pixel source, then runs the same per-mode
// blend formula as the non-coverage row kernels. Byte-equal output to the
// non-coverage path when every cov[i] == 0xFF, since `(sa * 255 + 0x80) >> 8`
// rounds back to `sa`.
//
// SmBlitter's coverage branch dispatches into one of these per blend mode.
// `src_over` / `src` / `copy` keep using the optimized `blendSrcOverCovU32`
// fast path above (vectorized via @Vector(N) coverage modulation); the
// other 23 modes route through these scalar loops, which are correctness-
// first today and tunable later.

inline fn modulateAlphaByCov(src_color: u32, cov_byte: u8) u32 {
    const sa: u32 = (src_color >> 24) & 0xFF;
    const eff_a: u32 = (sa * @as(u32, cov_byte) + 0x80) >> 8;
    return (src_color & 0x00FFFFFF) | (eff_a << 24);
}

fn rowOfCov(comptime k: BlendKernel) fn (dst: []u32, src_color: u32, cov: []const u8) void {
    return struct {
        fn run(dst: []u32, src_color: u32, cov: []const u8) void {
            std.debug.assert(dst.len == cov.len);
            for (dst, cov) |*p, c| {
                p.* = blendScalar(modulateAlphaByCov(src_color, c), p.*, k);
            }
        }
    }.run;
}

fn rowOfCovNonSep(comptime kind: NonSepKind, comptime swap_rb: bool) fn (dst: []u32, src_color: u32, cov: []const u8) void {
    return struct {
        fn run(dst: []u32, src_color: u32, cov: []const u8) void {
            std.debug.assert(dst.len == cov.len);
            for (dst, cov) |*p, c| {
                p.* = nonSepScalar(modulateAlphaByCov(src_color, c), p.*, kind, swap_rb);
            }
        }
    }.run;
}

// Porter-Duff coverage variants.
pub const blendSrcInCovU32 = rowOfCov(pdKernel(faDa, faZero));
pub const blendSrcOutCovU32 = rowOfCov(pdKernel(faInvDa, faZero));
pub const blendSrcAtopCovU32 = rowOfCov(pdKernel(faDa, faInvSa));
pub const blendDstOverCovU32 = rowOfCov(pdKernel(faInvDa, faOne));
pub const blendDstInCovU32 = rowOfCov(pdKernel(faZero, faSa));
pub const blendDstOutCovU32 = rowOfCov(pdKernel(faZero, faInvSa));
pub const blendDstAtopCovU32 = rowOfCov(pdKernel(faInvDa, faSa));
pub const blendXorCovU32 = rowOfCov(pdKernel(faInvDa, faInvSa));

// Separable blend coverage variants.
pub const blendMultiplyCovU32 = rowOfCov(sepKernel(bMultiply));
pub const blendScreenCovU32 = rowOfCov(sepKernel(bScreen));
pub const blendOverlayCovU32 = rowOfCov(sepKernel(bOverlay));
pub const blendDarkenCovU32 = rowOfCov(sepKernel(bDarken));
pub const blendLightenCovU32 = rowOfCov(sepKernel(bLighten));
pub const blendColorDodgeCovU32 = rowOfCov(sepKernel(bColorDodge));
pub const blendColorBurnCovU32 = rowOfCov(sepKernel(bColorBurn));
pub const blendHardLightCovU32 = rowOfCov(sepKernel(bHardLight));
pub const blendSoftLightCovU32 = rowOfCov(sepKernel(bSoftLight));
pub const blendDifferenceCovU32 = rowOfCov(sepKernel(bDifference));
pub const blendExclusionCovU32 = rowOfCov(sepKernel(bExclusion));

// Non-separable HSL coverage variants.
// Coverage wrapper over a plain scalar blend fn (coverage modulates the
// source alpha, exactly like rowOfCov does for kernel-shaped blends).
fn rowOfCovScalar(comptime scalar: fn (u32, u32) u32) fn (dst: []u32, src_color: u32, cov: []const u8) void {
    return struct {
        fn run(dst: []u32, src_color: u32, cov: []const u8) void {
            std.debug.assert(dst.len == cov.len);
            for (dst, cov) |*p, c| {
                p.* = scalar(modulateAlphaByCov(src_color, c), p.*);
            }
        }
    }.run;
}

pub const blendFlashSubtractCovU32 = rowOfCovScalar(flashSubtractScalar);
pub const blendFlashInvertCovU32 = rowOfCovScalar(flashInvertScalar);
pub const blendFlashAlphaCovU32 = rowOfCovScalar(flashAlphaScalar);
pub const blendFlashEraseCovU32 = rowOfCovScalar(flashEraseScalar);

pub const blendHueCovU32 = rowOfCovNonSep(.hue, false);
pub const blendSaturationCovU32 = rowOfCovNonSep(.saturation, false);
pub const blendColorCovU32 = rowOfCovNonSep(.color, false);
pub const blendLuminosityCovU32 = rowOfCovNonSep(.luminosity, false);
pub const blendHueCovBgraU32 = rowOfCovNonSep(.hue, true);
pub const blendSaturationCovBgraU32 = rowOfCovNonSep(.saturation, true);
pub const blendColorCovBgraU32 = rowOfCovNonSep(.color, true);
pub const blendLuminosityCovBgraU32 = rowOfCovNonSep(.luminosity, true);

// `add` (HTML5 'lighter') uses saturating per-channel add. The non-coverage
// kernel sums raw RGB without alpha-premultiplying; the coverage variant
// scales the source's R/G/B (not just A) by per-pixel coverage so partial
// edges contribute proportionally less.
pub fn blendAddCovU32(dst: []u32, src_color: u32, cov: []const u8) void {
    std.debug.assert(dst.len == cov.len);
    const sr: u32 = src_color & 0xFF;
    const sg: u32 = (src_color >> 8) & 0xFF;
    const sb: u32 = (src_color >> 16) & 0xFF;
    const sa: u32 = (src_color >> 24) & 0xFF;
    for (dst, cov) |*p, c| {
        const cov_u: u32 = @as(u32, c);
        const er: u32 = (sr * cov_u + 0x80) >> 8;
        const eg: u32 = (sg * cov_u + 0x80) >> 8;
        const eb: u32 = (sb * cov_u + 0x80) >> 8;
        const ea: u32 = (sa * cov_u + 0x80) >> 8;
        const dst_p = p.*;
        const dr: u32 = dst_p & 0xFF;
        const dg: u32 = (dst_p >> 8) & 0xFF;
        const db: u32 = (dst_p >> 16) & 0xFF;
        const da: u32 = (dst_p >> 24) & 0xFF;
        const r: u32 = @min(@as(u32, 0xFF), dr + er);
        const g: u32 = @min(@as(u32, 0xFF), dg + eg);
        const b: u32 = @min(@as(u32, 0xFF), db + eb);
        const a: u32 = @min(@as(u32, 0xFF), da + ea);
        p.* = r | (g << 8) | (b << 16) | (a << 24);
    }
}

inline fn blendSrcOverScalar(src: u32, dst: u32) u32 {
    const sa: u32 = (src >> 24) & 0xFF;
    const inv_sa: u32 = 255 - sa;
    // Premultiply src.rgb (HTML5 stores non-premultiplied colors).
    const sr: u32 = ((src & 0xFF) * sa + 0x80) >> 8;
    const sg: u32 = (((src >> 8) & 0xFF) * sa + 0x80) >> 8;
    const sb: u32 = (((src >> 16) & 0xFF) * sa + 0x80) >> 8;
    const dr: u32 = dst & 0xFF;
    const dg: u32 = (dst >> 8) & 0xFF;
    const db: u32 = (dst >> 16) & 0xFF;
    const da: u32 = (dst >> 24) & 0xFF;
    // (x * inv_sa + 128) >> 8 — fast x/255 within ±1.
    const r = sr + ((dr * inv_sa + 0x80) >> 8);
    const g = sg + ((dg * inv_sa + 0x80) >> 8);
    const b = sb + ((db * inv_sa + 0x80) >> 8);
    const a = sa + ((da * inv_sa + 0x80) >> 8);
    return r | (g << 8) | (b << 16) | (a << 24);
}

// boxBlurAlphaH — single-pass horizontal box blur over an u8 alpha buffer.
// Rolling-sum O(n) per row. `radius` is one-sided (window = 2*radius+1).
// Edge pixels clamp via repetition (we count them as if the row were
// extended by the edge value — matches Skia's SkBlurMaskFilter).
pub fn boxBlurAlphaH(dst: []u8, src: []const u8, w: u32, h: u32, radius: u32) void {
    std.debug.assert(dst.len == @as(usize, w) * @as(usize, h));
    std.debug.assert(src.len == dst.len);
    if (w == 0 or h == 0) return;
    if (radius == 0) {
        @memcpy(dst, src);
        return;
    }
    const window: u32 = 2 * radius + 1;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row_off = @as(usize, y) * @as(usize, w);
        const src_row = src[row_off..][0..w];
        const dst_row = dst[row_off..][0..w];
        var sum: u32 = 0;
        // Prime the rolling sum: count of `radius+1` left-edge pixels and
        // `radius` more from the start.
        const first: u32 = src_row[0];
        sum += first * (radius + 1);
        var i: u32 = 1;
        while (i <= radius and i < w) : (i += 1) sum += src_row[i];
        // Pad if the row is shorter than the radius.
        if (radius + 1 > w) sum += first * (radius + 1 - w);
        i = 0;
        while (i < w) : (i += 1) {
            dst_row[i] = @intCast(sum / window);
            // Add right neighbor (clamp at edge).
            const right_idx = @min(i + radius + 1, w - 1);
            const right_val: u32 = src_row[right_idx];
            sum += right_val;
            // Drop left neighbor (clamp at edge).
            const left_idx = if (i >= radius) i - radius else 0;
            const left_val: u32 = src_row[left_idx];
            sum -= left_val;
        }
    }
}

// boxBlurAlphaV — single-pass vertical box blur. Mirror of boxBlurAlphaH.
pub fn boxBlurAlphaV(dst: []u8, src: []const u8, w: u32, h: u32, radius: u32) void {
    std.debug.assert(dst.len == @as(usize, w) * @as(usize, h));
    std.debug.assert(src.len == dst.len);
    if (w == 0 or h == 0) return;
    if (radius == 0) {
        @memcpy(dst, src);
        return;
    }
    const window: u32 = 2 * radius + 1;
    var x: u32 = 0;
    while (x < w) : (x += 1) {
        var sum: u32 = 0;
        const first: u32 = src[@as(usize, x)];
        sum += first * (radius + 1);
        var i: u32 = 1;
        while (i <= radius and i < h) : (i += 1) sum += src[@as(usize, i) * @as(usize, w) + @as(usize, x)];
        if (radius + 1 > h) sum += first * (radius + 1 - h);
        i = 0;
        while (i < h) : (i += 1) {
            dst[@as(usize, i) * @as(usize, w) + @as(usize, x)] = @intCast(sum / window);
            const right_idx = @min(i + radius + 1, h - 1);
            sum += src[@as(usize, right_idx) * @as(usize, w) + @as(usize, x)];
            const left_idx = if (i >= radius) i - radius else 0;
            sum -= src[@as(usize, left_idx) * @as(usize, w) + @as(usize, x)];
        }
    }
}

// gaussianBlurAlpha — three-pass box blur ≈ Gaussian. Uses the
// well-known three-iteration approximation (Wells '86). `sigma` is the
// target Gaussian standard deviation in pixels; we derive a per-pass box
// radius from it. Uses two scratch buffers internally — caller provides
// `scratch` (must be at least w*h bytes). Result lands in `dst`.
pub fn gaussianBlurAlpha(
    dst: []u8,
    src: []const u8,
    scratch: []u8,
    w: u32,
    h: u32,
    sigma: f64,
) void {
    std.debug.assert(dst.len == @as(usize, w) * @as(usize, h));
    std.debug.assert(src.len == dst.len);
    std.debug.assert(scratch.len >= dst.len);
    if (sigma <= 0) {
        @memcpy(dst, src);
        return;
    }
    // Wells: r = floor((sqrt(12σ²/3 + 1) - 1) / 2) — split into 3 passes.
    const ideal = @sqrt(12.0 * sigma * sigma / 3.0 + 1.0);
    const r_f = @max(0.0, (ideal - 1.0) / 2.0);
    const radius: u32 = @intFromFloat(@round(r_f));
    if (radius == 0) {
        @memcpy(dst, src);
        return;
    }
    // Three passes: H/V alternated. Buffers ping-pong src→scratch→dst→scratch
    // so the final result ends in `dst`.
    boxBlurAlphaH(dst, src, w, h, radius);
    boxBlurAlphaV(scratch[0..src.len], dst, w, h, radius);
    boxBlurAlphaH(dst, scratch[0..src.len], w, h, radius);
    boxBlurAlphaV(scratch[0..src.len], dst, w, h, radius);
    boxBlurAlphaH(dst, scratch[0..src.len], w, h, radius);
    boxBlurAlphaV(scratch[0..src.len], dst, w, h, radius);
    @memcpy(dst, scratch[0..src.len]);
}

// brightnessU32 — multiply each RGB channel by `factor`, alpha unchanged.
// `factor < 1.0` darkens, `factor > 1.0` brightens. Works on a packed
// premultiplied-or-straight RGBA buffer (the math is identical for both
// because alpha is unchanged); assumes straight RGBA to match the rest of
// the simdra pipeline.
pub fn brightnessU32(buf: []u32, factor: f64) void {
    const f255 = @max(0.0, factor);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const px = buf[i];
        const r: f64 = @floatFromInt(px & 0xFF);
        const g: f64 = @floatFromInt((px >> 8) & 0xFF);
        const b: f64 = @floatFromInt((px >> 16) & 0xFF);
        const a: u32 = (px >> 24) & 0xFF;
        const nr: u32 = @intFromFloat(@round(std.math.clamp(r * f255, 0.0, 255.0)));
        const ng: u32 = @intFromFloat(@round(std.math.clamp(g * f255, 0.0, 255.0)));
        const nb: u32 = @intFromFloat(@round(std.math.clamp(b * f255, 0.0, 255.0)));
        buf[i] = nr | (ng << 8) | (nb << 16) | (a << 24);
    }
}

// contrastU32 — per-pixel `(c - 128) * factor + 128`, clamped. `factor =
// 1.0` is identity; `factor > 1.0` increases contrast; `< 1.0` decreases.
pub fn contrastU32(buf: []u32, factor: f64) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const px = buf[i];
        const r: f64 = @floatFromInt(px & 0xFF);
        const g: f64 = @floatFromInt((px >> 8) & 0xFF);
        const b: f64 = @floatFromInt((px >> 16) & 0xFF);
        const a: u32 = (px >> 24) & 0xFF;
        const nr: u32 = @intFromFloat(@round(std.math.clamp((r - 128.0) * factor + 128.0, 0.0, 255.0)));
        const ng: u32 = @intFromFloat(@round(std.math.clamp((g - 128.0) * factor + 128.0, 0.0, 255.0)));
        const nb: u32 = @intFromFloat(@round(std.math.clamp((b - 128.0) * factor + 128.0, 0.0, 255.0)));
        buf[i] = nr | (ng << 8) | (nb << 16) | (a << 24);
    }
}

// gaussianBlurU32 — three-pass box blur on RGBA32 buffer. Per-channel,
// alpha-preserving (alpha is blurred too, but in straight-alpha space).
// `scratch` must be at least 4*w*h u32 (separate channel buffers stacked).
pub fn gaussianBlurU32(
    dst: []u32,
    src: []const u32,
    scratch: []u8,
    w: u32,
    h: u32,
    sigma: f64,
) void {
    std.debug.assert(dst.len == @as(usize, w) * @as(usize, h));
    std.debug.assert(src.len == dst.len);
    if (sigma <= 0) {
        @memcpy(dst, src);
        return;
    }
    const total = src.len;
    // scratch layout: 5 buffers of `total` bytes each.
    //   [0..total)         channel 0 (R)
    //   [total..2*total)   channel 1 (G)
    //   [2*total..3*total) channel 2 (B)
    //   [3*total..4*total) channel 3 (A)
    //   [4*total..5*total) blur scratch
    std.debug.assert(scratch.len >= total * 5);
    const ch_r = scratch[0..total];
    const ch_g = scratch[total..2 * total];
    const ch_b = scratch[2 * total .. 3 * total];
    const ch_a = scratch[3 * total .. 4 * total];
    const blur_scratch = scratch[4 * total .. 5 * total];
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const px = src[i];
        ch_r[i] = @intCast(px & 0xFF);
        ch_g[i] = @intCast((px >> 8) & 0xFF);
        ch_b[i] = @intCast((px >> 16) & 0xFF);
        ch_a[i] = @intCast((px >> 24) & 0xFF);
    }
    // gaussianBlurAlpha requires dst != src. Copy each channel into the
    // blur scratch then blur back into the channel buffer.
    @memcpy(blur_scratch, ch_r);
    gaussianBlurAlpha(ch_r, blur_scratch, blur_scratch, w, h, sigma);
    @memcpy(blur_scratch, ch_g);
    gaussianBlurAlpha(ch_g, blur_scratch, blur_scratch, w, h, sigma);
    @memcpy(blur_scratch, ch_b);
    gaussianBlurAlpha(ch_b, blur_scratch, blur_scratch, w, h, sigma);
    @memcpy(blur_scratch, ch_a);
    gaussianBlurAlpha(ch_a, blur_scratch, blur_scratch, w, h, sigma);
    i = 0;
    while (i < total) : (i += 1) {
        dst[i] = @as(u32, ch_r[i]) |
            (@as(u32, ch_g[i]) << 8) |
            (@as(u32, ch_b[i]) << 16) |
            (@as(u32, ch_a[i]) << 24);
    }
}

// sampleImageNearestRow — fill a row of `dst` pixels by inverse-transforming
// each canvas-pixel center to source-image coordinates and gathering the
// nearest source pixel.
//
// Coords: for canvas pixel (x_start + i, y), we apply the affine inverse
// transform (inv_a..inv_f) to the pixel center (x + 0.5, y + 0.5):
//
//   src_x = inv_a * px + inv_c * py + inv_e
//   src_y = inv_b * px + inv_d * py + inv_f
//
// Pixels whose source coordinate falls outside the source RECT
// (src_rect_x..src_rect_x+src_rect_w, src_rect_y..src_rect_y+src_rect_h)
// are SKIPPED — `dst[i]` is left untouched. This is what makes rotated
// drawImage paint a parallelogram inside an axis-aligned bbox without
// overwriting destination pixels outside the parallelogram.
//
// SIMD plan: coordinate math is vectorized (`@Vector(N, f64)` fma chain).
// Gather is scalar per lane — no portable SIMD gather across our targets.
// The bbox-then-gather pattern is the standard structure for image samplers
// on CPU; the vector coord compute is the meaningful SIMD win.
pub const NearestSampleChunkPixels = 8;

pub fn sampleImageNearestRow(
    dst: []u32,
    src_pixels: [*]const u32,
    src_w: u32,
    src_h: u32,
    src_rect_x: f64,
    src_rect_y: f64,
    src_rect_w: f64,
    src_rect_h: f64,
    inv_a: f64,
    inv_b: f64,
    inv_c: f64,
    inv_d: f64,
    inv_e: f64,
    inv_f: f64,
    x_start: i32,
    y: i32,
) void {
    const N = NearestSampleChunkPixels;
    const Vd = @Vector(N, f64);
    const py_v: Vd = @splat(@as(f64, @floatFromInt(y)) + 0.5);
    const inv_a_v: Vd = @splat(inv_a);
    const inv_b_v: Vd = @splat(inv_b);
    const inv_c_v: Vd = @splat(inv_c);
    const inv_d_v: Vd = @splat(inv_d);
    const inv_e_v: Vd = @splat(inv_e);
    const inv_f_v: Vd = @splat(inv_f);
    // Per-lane offsets within a chunk: pixel centers at i+0.5.
    const lane_offsets: Vd = .{ 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5 };

    const x_start_f: f64 = @floatFromInt(x_start);
    const src_rect_x1 = src_rect_x + src_rect_w;
    const src_rect_y1 = src_rect_y + src_rect_h;
    const src_w_i: i32 = @intCast(src_w);
    const src_h_i: i32 = @intCast(src_h);

    var i: usize = 0;
    while (i + N <= dst.len) : (i += N) {
        const i_v: Vd = @splat(@as(f64, @floatFromInt(i)));
        const px_v = @as(Vd, @splat(x_start_f)) + i_v + lane_offsets;
        const sx_v = inv_a_v * px_v + inv_c_v * py_v + inv_e_v;
        const sy_v = inv_b_v * px_v + inv_d_v * py_v + inv_f_v;
        // Per-lane scalar gather + bounds check. The lanes are read out
        // as ARRAYS: a vector cannot be indexed by a runtime value.
        const sx_lanes: [N]f64 = sx_v;
        const sy_lanes: [N]f64 = sy_v;
        var lane: usize = 0;
        while (lane < N) : (lane += 1) {
            const sx_f = sx_lanes[lane];
            const sy_f = sy_lanes[lane];
            if (sx_f < src_rect_x or sx_f >= src_rect_x1 or
                sy_f < src_rect_y or sy_f >= src_rect_y1) continue;
            const sx_int: i32 = @intFromFloat(@floor(sx_f));
            const sy_int: i32 = @intFromFloat(@floor(sy_f));
            if (sx_int < 0 or sy_int < 0 or sx_int >= src_w_i or sy_int >= src_h_i) continue;
            dst[i + lane] = src_pixels[@as(usize, @intCast(sy_int)) * @as(usize, src_w) + @as(usize, @intCast(sx_int))];
        }
    }

    // Scalar tail.
    while (i < dst.len) : (i += 1) {
        const px = x_start_f + @as(f64, @floatFromInt(i)) + 0.5;
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        const sx_f = inv_a * px + inv_c * py + inv_e;
        const sy_f = inv_b * px + inv_d * py + inv_f;
        if (sx_f < src_rect_x or sx_f >= src_rect_x1 or
            sy_f < src_rect_y or sy_f >= src_rect_y1) continue;
        const sx_int: i32 = @intFromFloat(@floor(sx_f));
        const sy_int: i32 = @intFromFloat(@floor(sy_f));
        if (sx_int < 0 or sy_int < 0 or sx_int >= src_w_i or sy_int >= src_h_i) continue;
        dst[i] = src_pixels[@as(usize, @intCast(sy_int)) * @as(usize, src_w) + @as(usize, @intCast(sx_int))];
    }
}

// sampleImageBilinearRow — same shape as `sampleImageNearestRow` but with
// bilinear filtering (4-neighbor lerp) per output pixel. Used by drawImage
// when `imageSmoothingEnabled` is true. Same bbox skip-rule keeps rotated
// drawImages from spilling outside the destination parallelogram.
pub fn sampleImageBilinearRow(
    dst: []u32,
    src_pixels: [*]const u32,
    src_w: u32,
    src_h: u32,
    src_rect_x: f64,
    src_rect_y: f64,
    src_rect_w: f64,
    src_rect_h: f64,
    inv_a: f64,
    inv_b: f64,
    inv_c: f64,
    inv_d: f64,
    inv_e: f64,
    inv_f: f64,
    x_start: i32,
    y: i32,
) void {
    const x_start_f: f64 = @floatFromInt(x_start);
    const py_f: f64 = @as(f64, @floatFromInt(y)) + 0.5;
    const src_rect_x1 = src_rect_x + src_rect_w;
    const src_rect_y1 = src_rect_y + src_rect_h;
    const src_w_i: i32 = @intCast(src_w);
    const src_h_i: i32 = @intCast(src_h);

    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const px_f = x_start_f + @as(f64, @floatFromInt(i)) + 0.5;
        const sx_f = inv_a * px_f + inv_c * py_f + inv_e;
        const sy_f = inv_b * px_f + inv_d * py_f + inv_f;
        if (sx_f < src_rect_x or sx_f >= src_rect_x1 or
            sy_f < src_rect_y or sy_f >= src_rect_y1) continue;

        // Bilinear: shift by 0.5 so neighbor centers sit at integer offsets.
        const u = sx_f - 0.5;
        const v = sy_f - 0.5;
        const x0_i: i32 = @intFromFloat(@floor(u));
        const y0_i: i32 = @intFromFloat(@floor(v));
        const x1_i: i32 = x0_i + 1;
        const y1_i: i32 = y0_i + 1;
        const fx = u - @as(f64, @floatFromInt(x0_i));
        const fy = v - @as(f64, @floatFromInt(y0_i));

        // Clamp neighbor indices into the source bitmap. Falls back to
        // edge replication near the source border (matches Skia / Chrome).
        const x0c: i32 = @max(0, @min(x0_i, src_w_i - 1));
        const x1c: i32 = @max(0, @min(x1_i, src_w_i - 1));
        const y0c: i32 = @max(0, @min(y0_i, src_h_i - 1));
        const y1c: i32 = @max(0, @min(y1_i, src_h_i - 1));

        const p00 = src_pixels[@as(usize, @intCast(y0c)) * @as(usize, src_w) + @as(usize, @intCast(x0c))];
        const p10 = src_pixels[@as(usize, @intCast(y0c)) * @as(usize, src_w) + @as(usize, @intCast(x1c))];
        const p01 = src_pixels[@as(usize, @intCast(y1c)) * @as(usize, src_w) + @as(usize, @intCast(x0c))];
        const p11 = src_pixels[@as(usize, @intCast(y1c)) * @as(usize, src_w) + @as(usize, @intCast(x1c))];

        // Premul-aware bilinear: multiply each channel by alpha, lerp,
        // un-premultiply at the end. Avoids halo around transparent edges.
        const w00 = (1.0 - fx) * (1.0 - fy);
        const w10 = fx * (1.0 - fy);
        const w01 = (1.0 - fx) * fy;
        const w11 = fx * fy;

        var sum_pr: f64 = 0;
        var sum_pg: f64 = 0;
        var sum_pb: f64 = 0;
        var sum_a: f64 = 0;
        inline for (.{ .{ p00, w00 }, .{ p10, w10 }, .{ p01, w01 }, .{ p11, w11 } }) |pair| {
            const px = pair[0];
            const w = pair[1];
            const r: f64 = @floatFromInt(px & 0xFF);
            const g: f64 = @floatFromInt((px >> 8) & 0xFF);
            const b: f64 = @floatFromInt((px >> 16) & 0xFF);
            const a: f64 = @floatFromInt((px >> 24) & 0xFF);
            sum_pr += r * a / 255.0 * w;
            sum_pg += g * a / 255.0 * w;
            sum_pb += b * a / 255.0 * w;
            sum_a += a * w;
        }

        var out_r: f64 = 0;
        var out_g: f64 = 0;
        var out_b: f64 = 0;
        if (sum_a > 0) {
            out_r = sum_pr * 255.0 / sum_a;
            out_g = sum_pg * 255.0 / sum_a;
            out_b = sum_pb * 255.0 / sum_a;
        }
        const out_ru: u32 = @intFromFloat(@round(std.math.clamp(out_r, 0.0, 255.0)));
        const out_gu: u32 = @intFromFloat(@round(std.math.clamp(out_g, 0.0, 255.0)));
        const out_bu: u32 = @intFromFloat(@round(std.math.clamp(out_b, 0.0, 255.0)));
        const out_au: u32 = @intFromFloat(@round(std.math.clamp(sum_a, 0.0, 255.0)));
        dst[i] = out_ru | (out_gu << 8) | (out_bu << 16) | (out_au << 24);
    }
}

pub fn copyU32ToFloat16Norm(dst: []f16, src: []const u32) void {
    std.debug.assert(dst.len == src.len * 4);
    const inv_255: f32 = 1.0 / 255.0;
    var i: usize = 0;
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

test "colorMatrixU32: identity, invert-with-offset, luma grayscale" {
    const id: [20]f32 = .{
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
    };
    var row = [_]u32{ 0x80FF6420, 0x00000000, 0xFFFFFFFF };
    const orig = row;
    colorMatrixU32(&row, &id);
    try std.testing.expectEqualSlices(u32, &orig, &row);

    // RGB invert (alpha kept): out.c = −c + 255.
    const inv: [20]f32 = .{
        -1, 0,  0,  0, 255,
        0,  -1, 0,  0, 255,
        0,  0,  -1, 0, 255,
        0,  0,  0,  1, 0,
    };
    var px = [_]u32{100 | (150 << 8) | (200 << 16) | (77 << 24)};
    colorMatrixU32(&px, &inv);
    try std.testing.expectEqual(@as(u32, 155 | (105 << 8) | (55 << 16) | (77 << 24)), px[0]);

    // Rec.601 luma grayscale.
    const lw = [3]f32{ 0.299, 0.587, 0.114 };
    const gray_m: [20]f32 = .{
        lw[0], lw[1], lw[2], 0, 0,
        lw[0], lw[1], lw[2], 0, 0,
        lw[0], lw[1], lw[2], 0, 0,
        0,     0,     0,     1, 0,
    };
    var px2 = [_]u32{100 | (150 << 8) | (200 << 16) | (255 << 24)};
    colorMatrixU32(&px2, &gray_m);
    // 0.299·100 + 0.587·150 + 0.114·200 = 140.75 → 141 on all three channels.
    try std.testing.expectEqual(@as(u32, 141 | (141 << 8) | (141 << 16) | (255 << 24)), px2[0]);
}
