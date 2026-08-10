//! SmCanvas — 2D drawing primitives that operate on an SmSurface's pixel
//! buffer. Mirrors Skia's `SkCanvas`. The HTML5 `CanvasRenderingContext2D`
//! class lives JS-side as a re-export of this struct; the JS class
//! `Canvas` (HTML5 HTMLCanvasElement) wraps an SmSurface, NOT this — distinct
//! concepts that share a name across layers. Constructed via
//! `SmSurface.getCanvas()`, not directly.
//!
//! Drawing pipeline (Skia-style):
//!
//!   draw* method
//!     ↓
//!   builds SmPaint from ctx state (or takes one explicitly)
//!     ↓
//!   SmScan emits row spans (y, x_lo, x_hi[, coverage])
//!     ↓
//!   SmBlitter.blitRow writes pixels per row
//!     ↓
//!   simd.* kernel (SIMD per N pixels)

const std = @import("std");
const types = @import("types.zig");
const simd = @import("../opts/simd.zig");
const SmBitmap = @import("SmBitmap.zig");
const SmPath = @import("SmPath.zig");
const SmPaint = @import("SmPaint.zig");
const SmMatrix = @import("SmMatrix.zig");
const SmScan = @import("SmScan.zig");
const SmBlitter = @import("SmBlitter.zig");
const SmFont = @import("SmFont.zig");
const SmSurface = @import("SmSurface.zig");
const SmTextRun = @import("SmTextRun.zig");
const SmGradient = @import("../effects/SmGradient.zig");
const SmPattern = @import("../effects/SmPattern.zig");
const SmList = @import("../utils/SmList.zig").SmList;

const SmCanvas = @This();

/// One frame of saved state, captured by `save()` and restored by `restore()`.
/// Captures everything that can be mutated through context-level setters.
/// Future state (clip mask) lands here as features arrive.
///
/// `lineDash` is a freshly-allocated owning slice on save; restore() takes
/// ownership back, freeing the live storage in line_dash_storage first.
/// Empty slice means "no dash" (matches the default).
pub const StateFrame = struct {
    transform: SmMatrix,
    fillStyle: SmPaint.Shader,
    strokeStyle: SmPaint.Shader,
    lineWidth: f64,
    lineCap: SmPaint.LineCap,
    lineJoin: SmPaint.LineJoin,
    miterLimit: f64,
    lineDash: []f64,
    lineDashOffset: f64,
    /// Snapshot of `clip_mask` at save time (deep-copied), or `null` if
    /// no clip was active. Owned by the frame; freed on `restore()` after
    /// the contents are swapped back into `clip_mask`.
    clipMask: ?[]u8,
    alpha: u8,
    blendMode: SmPaint.BlendMode,
    cxform: SmPaint.ColorTransform,
    imageSmoothingEnabled: bool,
    imageSmoothingQuality: u8,
    shadowBlur: f64,
    shadowColor: u32,
    shadowOffsetX: f64,
    shadowOffsetY: f64,
    /// Snapshot of the filter chain. Verbs and params are owning slices
    /// (allocated on save, freed on restore).
    filterVerbs: []u8,
    filterParams: []f64,
};

/// Filter-op opcode tags. Each verb consumes a fixed number of param
/// floats — see `filterParamCount`.
pub const FilterOp = enum(u8) {
    blur = 0,        // 1 param: sigma (px)
    brightness = 1,  // 1 param: factor
    contrast = 2,    // 1 param: factor
};

inline fn filterParamCount(op: FilterOp) u8 {
    return switch (op) {
        .blur, .brightness, .contrast => 1,
    };
}

pub const StateStack = SmList(StateFrame);

/// Owning surface — back-reference. `width`, `height`, `colorSpace` read
/// through this so they cannot desync. `surface.pixels` is the canonical
/// pixel buffer; `self.pixels` below is the live render target (usually
/// `surface.pixels`, but swapped to a scratch buffer during a composite
/// layer — see `beginCompositeLayer`).
surface: *SmSurface,
pixels: []u32,
fillStyle: SmPaint.Shader = .{ .solid = 0xFF000000 },
strokeStyle: SmPaint.Shader = .{ .solid = 0xFF000000 },
/// HTML5 `lineWidth` in canvas pixels. WebIDL `unrestricted double`.
/// JS-side guard rejects non-finite / non-positive before reaching here.
lineWidth: f64 = 1,
/// HTML5 `lineCap`. Default `'butt'`.
lineCap: SmPaint.LineCap = .butt,
/// HTML5 `lineJoin`. Default `'miter'`.
lineJoin: SmPaint.LineJoin = .miter,
/// HTML5 `miterLimit`. Default 10.
miterLimit: f64 = 10.0,
/// HTML5 `setLineDash` storage. Empty list means "solid stroke" (default).
/// Per spec, odd-length arrays passed to `setLineDash` are doubled before
/// landing here, so this list is always even-length. Field is internal —
/// JS reads through `getLineDash()` and writes through `setLineDash()`.
line_dash_storage: SmList(f64) = .{},
/// HTML5 `lineDashOffset`. Default 0. camelCase so node-zigar exposes it
/// to JS as `ctx[ZIG].lineDashOffset` — the JS getter reads it directly.
lineDashOffset: f64 = 0,
/// Global alpha modulator (0..255). Multiplies into source.a when paints
/// are constructed in fillRect/strokeRect/etc. JS `ctx.globalAlpha` (float
/// 0..1) wraps this through a getter/setter in `src/index.ts`.
alpha: u8 = 0xFF,
/// Default blend mode for new paints built by fillRect/strokeRect/etc.
/// JS `ctx.globalCompositeOperation` (HTML5 string) wraps this through a
/// getter/setter in `src/index.ts`.
blendMode: SmPaint.BlendMode = .src_over,
/// Color transform for new paints (simdra extension — SWF CXFORM shape).
/// Identity by default; no HTML5 surface. Folded/carried exactly like
/// `alpha` — see `paintFromShader`. Saved/restored with the state stack.
cxform: SmPaint.ColorTransform = .{},
/// Current transformation matrix (CTM). Mirrors HTML5's CTM and Skia's
/// `SkCanvas` matrix. Identity by default. Modified by `translate / rotate
/// / scale / transform / setTransform / resetTransform`. Saved/restored
/// by `save / restore`.
current_transform: SmMatrix = .{},
/// Saved-state stack. Pushed on `save()`, popped on `restore()`.
state_stack: StateStack = .{},
/// Shared path-encoding state. beginPath() clears it; path methods append
/// opcodes. Freed in deinit() before SmSurface calls destroy(self).
path: SmPath,
/// Scratch pixel buffer for layer-composite blend modes (src-in, src-out,
/// dst-in, dst-atop, copy). Allocated lazily on first use, freed in deinit.
/// See `beginCompositeLayer` for the rendering protocol.
scratch_pixels: ?[]u32 = null,
/// Active clip region as a per-pixel binary mask (0xFF = visible, 0x00 =
/// clipped). `null` = no clip (fast path everywhere). Allocated lazily on
/// first `clip()` call; size is always `surface.width * surface.height`.
/// Each `clip()` intersects the existing region with the new path mask,
/// matching HTML5 monotone-restrictive clip semantics. Saved and restored
/// by `save()` / `restore()` (deep-copy snapshots into `StateFrame`).
clip_mask: ?[]u8 = null,
/// HTML5 `imageSmoothingEnabled`. Default true — drawImage uses bilinear
/// sampling. When false, drawImage uses nearest-neighbor (blocky scale-up).
imageSmoothingEnabled: bool = true,
/// HTML5 `imageSmoothingQuality` — advisory hint encoded as 0=low / 1=med
/// / 2=high. Today only acts as on/off (any value uses bilinear); the
/// distinction is reserved for higher-order kernels (Mitchell-Netravali, etc.).
imageSmoothingQuality: u8 = 0,
/// HTML5 `shadowBlur` — Gaussian blur radius in canvas pixels. Default 0
/// (no blur). Spec interprets the value as a "blur effect amount", not a
/// strict sigma; we use sigma = blur / 2 (matches Chromium/Skia).
shadowBlur: f64 = 0,
/// HTML5 `shadowColor` — packed RGBA. Default transparent black (alpha
/// 0). Shadows render only when the alpha is non-zero AND at least one
/// of `shadowBlur`/`shadowOffsetX`/`shadowOffsetY` is non-zero.
shadowColor: u32 = 0,
/// HTML5 `shadowOffsetX` / `shadowOffsetY` — translation of the shadow
/// from the shape, in canvas pixels.
shadowOffsetX: f64 = 0,
shadowOffsetY: f64 = 0,
/// Scratch RGBA buffer used by `beginShadowLayer` / `endShadowLayer`.
/// Allocated lazily; freed in `deinit`. Distinct from `scratch_pixels`
/// (which the layer-composite pipeline uses for non-row-friendly
/// blend modes — both can be active at the same time during a draw).
shadow_scratch: ?[]u32 = null,
/// Scratch alpha mask buffer for the shadow blur pass. Same lifecycle.
shadow_alpha: ?[]u8 = null,
/// Second alpha buffer for the blur ping-pong.
shadow_alpha_b: ?[]u8 = null,
/// Filter chain (HTML5 `ctx.filter`). Each verb consumes a fixed number
/// of param floats — see `FilterOp` + `filterParamCount`. Empty list
/// means no filter (default).
filter_verbs: SmList(u8) = .{},
filter_params: SmList(f64) = .{},
/// Scratch RGBA buffer for `beginFilterLayer` / `endFilterLayer`.
filter_scratch: ?[]u32 = null,
/// Auxiliary u8 scratch for the filter blur kernel — needs 5×canvas-pixels
/// of u8 storage (4 channel buffers + 1 blur ping-pong). Allocated lazily.
filter_blur_scratch: ?[]u8 = null,
/// AA path-fill row accumulator. Holds per-pixel coverage in [0, 1] across
/// the 8 sub-y-sample sweep before being packed to u8 in `aa_coverage`.
/// Sized to `surface.width`. Lazily allocated, freed in `deinit`.
/// Antialias path coverage. False renders one sample per pixel, which
/// is what Flash's "low" quality does — see `SmPaint.antialias`.
antialias: bool = true,
aa_accum: ?[]f32 = null,
/// AA path-fill u8 coverage row, fed to `SmBlitter.blitRow`. Sized to
/// `surface.width`. Lazily allocated, freed in `deinit`.
aa_coverage: ?[]u8 = null,

/// Construct a fresh SmCanvas bound to `surface`. Inherits the surface's
/// allocator into the embedded SmPath; SmList allocations use it via
/// `self.surface.getAllocator()`. Called by `SmSurface.getCanvas` (the only
/// constructor path — SmCanvas is not directly JS-creatable).
pub fn initFromSurface(surface: *SmSurface) SmCanvas {
    return .{
        .surface = surface,
        .pixels = surface.pixels,
        .path = .{ .allocator = surface.getAllocator() },
    };
}

/// Called by SmSurface.resize after the surface's pixel buffer has been
/// reallocated to new dimensions. Re-points `pixels` at the new buffer,
/// drops every dimension-bound lazy scratch (so the next use re-allocs at
/// the new size), and calls `reset()` to wipe state to HTML5 defaults
/// (transform, paint, path, state stack, filters).
pub fn adoptResizedSurface(self: *SmCanvas) void {
    const allocator = self.surface.getAllocator();
    self.pixels = self.surface.pixels;

    if (self.scratch_pixels) |s| {
        allocator.free(s);
        self.scratch_pixels = null;
    }
    if (self.shadow_scratch) |s| {
        allocator.free(s);
        self.shadow_scratch = null;
    }
    if (self.shadow_alpha) |s| {
        allocator.free(s);
        self.shadow_alpha = null;
    }
    if (self.shadow_alpha_b) |s| {
        allocator.free(s);
        self.shadow_alpha_b = null;
    }
    if (self.filter_scratch) |s| {
        allocator.free(s);
        self.filter_scratch = null;
    }
    if (self.filter_blur_scratch) |s| {
        allocator.free(s);
        self.filter_blur_scratch = null;
    }
    if (self.aa_accum) |s| {
        allocator.free(s);
        self.aa_accum = null;
    }
    if (self.aa_coverage) |s| {
        allocator.free(s);
        self.aa_coverage = null;
    }

    // `reset()` frees `clip_mask`, drains the state stack (including each
    // frame's owned snapshots), clears the filter chain, resets every state
    // field to its default, and zero-fills the (new) pixel buffer.
    self.reset();
}

pub fn deinit(self: *SmCanvas) void {
    self.path.deinit();
    // Free any line-dash + clip-mask + filter snapshots still on the stack.
    for (self.state_stack.ptr[0..self.state_stack.len]) |frame| {
        if (frame.lineDash.len > 0) self.surface.getAllocator().free(frame.lineDash);
        if (frame.clipMask) |m| self.surface.getAllocator().free(m);
        if (frame.filterVerbs.len > 0) self.surface.getAllocator().free(frame.filterVerbs);
        if (frame.filterParams.len > 0) self.surface.getAllocator().free(frame.filterParams);
    }
    self.state_stack.deinit(self.surface.getAllocator());
    self.line_dash_storage.deinit(self.surface.getAllocator());
    self.filter_verbs.deinit(self.surface.getAllocator());
    self.filter_params.deinit(self.surface.getAllocator());
    if (self.clip_mask) |m| {
        self.surface.getAllocator().free(m);
        self.clip_mask = null;
    }
    if (self.scratch_pixels) |s| {
        self.surface.getAllocator().free(s);
        self.scratch_pixels = null;
    }
    if (self.shadow_scratch) |s| {
        self.surface.getAllocator().free(s);
        self.shadow_scratch = null;
    }
    if (self.shadow_alpha) |s| {
        self.surface.getAllocator().free(s);
        self.shadow_alpha = null;
    }
    if (self.shadow_alpha_b) |s| {
        self.surface.getAllocator().free(s);
        self.shadow_alpha_b = null;
    }
    if (self.filter_scratch) |s| {
        self.surface.getAllocator().free(s);
        self.filter_scratch = null;
    }
    if (self.filter_blur_scratch) |s| {
        self.surface.getAllocator().free(s);
        self.filter_blur_scratch = null;
    }
    if (self.aa_accum) |s| {
        self.surface.getAllocator().free(s);
        self.aa_accum = null;
    }
    if (self.aa_coverage) |s| {
        self.surface.getAllocator().free(s);
        self.aa_coverage = null;
    }
}

/// ensureAaScratch — lazy allocator for the AA path fill scratches.
/// Returns null if the canvas has zero pixels or allocation fails — in
/// either case `fill()` / `stroke()` no-op rather than crash.
fn ensureAaScratch(self: *SmCanvas) ?struct { accum: []f32, cov: []u8 } {
    const w: usize = self.surface.width;
    if (w == 0) return null;
    const allocator = self.surface.getAllocator();
    if (self.aa_accum == null or self.aa_accum.?.len < w) {
        if (self.aa_accum) |s| allocator.free(s);
        self.aa_accum = allocator.alloc(f32, w) catch {
            self.aa_accum = null;
            return null;
        };
    }
    if (self.aa_coverage == null or self.aa_coverage.?.len < w) {
        if (self.aa_coverage) |s| allocator.free(s);
        self.aa_coverage = allocator.alloc(u8, w) catch {
            self.aa_coverage = null;
            return null;
        };
    }
    return .{ .accum = self.aa_accum.?, .cov = self.aa_coverage.? };
}

/// isPointInPath(self, x, y, fill_rule) — HTML5 hit-test against the
/// current path. The query point is in canvas user-space; we apply the
/// inverse of the CTM... wait — paths in simdra are stored CANVAS-space
/// (each `lineTo` etc. transforms via `current_transform` at append
/// time). So the path's edges are already canvas-space. The query point
/// is also canvas-space (HTML5 §canvas-2d-is-point-in-path takes the
/// argument in CSS pixels of the canvas). Hence: NO inverse transform —
/// just walk the canvas-space edges against the canvas-space (x, y).
pub fn isPointInPath(self: *SmCanvas, x: f64, y: f64, fill_rule: SmScan.FillRule) bool {
    return self.pathContainsPoint(&self.path, x, y, fill_rule);
}

/// isPointInPathExternal(self, path, x, y, fill_rule) — same as
/// `isPointInPath` but tests against an external Path2D. Path2D paths
/// are NOT canvas-space (they were built without applying the CTM); the
/// query point is canvas-space, so we transform the query point back to
/// path-space by inverse-applying the CTM.
pub fn isPointInPathExternal(
    self: *SmCanvas,
    path: *const SmPath,
    x: f64,
    y: f64,
    fill_rule: SmScan.FillRule,
) bool {
    var inv = self.current_transform;
    _ = inv.invertSelf();
    if (!std.math.isFinite(inv.a)) return false;
    const q = inv.applyToPoint(x, y);
    return self.pathContainsPoint(path, q[0], q[1], fill_rule);
}

fn pathContainsPoint(
    self: *SmCanvas,
    path: *const SmPath,
    x: f64,
    y: f64,
    fill_rule: SmScan.FillRule,
) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    var edges: SmScan.EdgeBuf = .{};
    defer edges.deinit(self.surface.getAllocator());
    SmScan.flattenPathToFillEdges(self.surface.getAllocator(), path, &edges) catch return false;
    return SmScan.pointInEdges(edges.ptr[0..edges.len], x, y, fill_rule);
}

/// isPointInStroke(self, x, y) — HTML5 hit-test against the inflated
/// outline of the current path with the active stroke state. Walks the
/// same outline-emission path that `stroke()` uses.
pub fn isPointInStroke(self: *SmCanvas, x: f64, y: f64) bool {
    return self.pathStrokeContainsPoint(&self.path, x, y);
}

pub fn isPointInStrokeExternal(self: *SmCanvas, path: *const SmPath, x: f64, y: f64) bool {
    var inv = self.current_transform;
    _ = inv.invertSelf();
    if (!std.math.isFinite(inv.a)) return false;
    const q = inv.applyToPoint(x, y);
    return self.pathStrokeContainsPoint(path, q[0], q[1]);
}

fn pathStrokeContainsPoint(self: *SmCanvas, path: *const SmPath, x: f64, y: f64) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    var edges: SmScan.EdgeBuf = .{};
    defer edges.deinit(self.surface.getAllocator());
    SmScan.flattenPathToStrokeEdges(
        self.surface.getAllocator(),
        path,
        &edges,
        self.lineWidth,
        self.lineCap,
        self.lineJoin,
        self.miterLimit,
        self.line_dash_storage.ptr[0..self.line_dash_storage.len],
        self.lineDashOffset,
    ) catch return false;
    // Stroke outlines use nonzero (the donut polygon is CCW outer + CW inner).
    return SmScan.pointInEdges(edges.ptr[0..edges.len], x, y, .nonzero);
}

/// reset() — HTML5 `ctx.reset()`. Drops all state back to defaults: clears
/// the path, drains the save/restore stack, frees any active clip mask
/// and dash snapshot storage, and clears the surface to transparent black.
/// `pixels` itself is owned by SmSurface and is not freed.
pub fn reset(self: *SmCanvas) void {
    const allocator = self.surface.getAllocator();
    // Drain saved frames, freeing each frame's owned snapshots.
    for (self.state_stack.ptr[0..self.state_stack.len]) |frame| {
        if (frame.lineDash.len > 0) allocator.free(frame.lineDash);
        if (frame.clipMask) |m| allocator.free(m);
        if (frame.filterVerbs.len > 0) allocator.free(frame.filterVerbs);
        if (frame.filterParams.len > 0) allocator.free(frame.filterParams);
    }
    self.state_stack.len = 0;
    if (self.clip_mask) |m| {
        allocator.free(m);
        self.clip_mask = null;
    }
    self.line_dash_storage.len = 0;
    self.filter_verbs.len = 0;
    self.filter_params.len = 0;
    self.path.clear();
    // Reset every state field to its struct default.
    self.fillStyle = .{ .solid = 0xFF000000 };
    self.strokeStyle = .{ .solid = 0xFF000000 };
    self.lineWidth = 1;
    self.lineCap = .butt;
    self.lineJoin = .miter;
    self.miterLimit = 10.0;
    self.lineDashOffset = 0;
    self.alpha = 0xFF;
    self.blendMode = .src_over;
    self.cxform = .{};
    self.current_transform = .{};
    self.imageSmoothingEnabled = true;
    self.imageSmoothingQuality = 0;
    self.shadowBlur = 0;
    self.shadowColor = 0;
    self.shadowOffsetX = 0;
    self.shadowOffsetY = 0;
    // Clear the canvas to transparent black per spec.
    simd.fillU32(self.pixels, 0);
}

pub const GetImageDataError = SmBitmap.FromSurfaceError;

/// setColorTransform(t) — simdra extension (SWF CXFORM). Applies to every
/// subsequently constructed paint (fills, strokes, text, drawImage) until
/// changed; pass `.{}` (identity) to disable. Saved/restored with the
/// state stack; reset() clears it. No HTML5 surface.
pub fn setColorTransform(self: *SmCanvas, t: SmPaint.ColorTransform) void {
    self.cxform = t;
}

pub fn setFillStyle(self: *SmCanvas, r: u8, g: u8, b: u8, a: u8) void {
    self.fillStyle = .{ .solid = types.packRGBA(r, g, b, a) };
}

pub fn setStrokeStyle(self: *SmCanvas, r: u8, g: u8, b: u8, a: u8) void {
    self.strokeStyle = .{ .solid = types.packRGBA(r, g, b, a) };
}

/// Set fillStyle to a CanvasGradient. The pointer must outlive every
/// subsequent fill/stroke call until a new style is set — the JS layer
/// holds the source `CanvasGradient` reference for as long as it's the
/// active style, so the Zig-side pointer stays valid.
pub fn setFillGradient(self: *SmCanvas, g: *const SmGradient) void {
    self.fillStyle = .{ .gradient = g };
}

pub fn setStrokeGradient(self: *SmCanvas, g: *const SmGradient) void {
    self.strokeStyle = .{ .gradient = g };
}

/// Set fillStyle to a CanvasPattern. Same lifetime rule as gradients.
pub fn setFillPattern(self: *SmCanvas, p: *const SmPattern) void {
    self.fillStyle = .{ .pattern = p };
}

pub fn setStrokePattern(self: *SmCanvas, p: *const SmPattern) void {
    self.strokeStyle = .{ .pattern = p };
}

pub fn setLineWidth(self: *SmCanvas, w: f64) void {
    self.lineWidth = w;
}

pub fn setLineCap(self: *SmCanvas, c: SmPaint.LineCap) void {
    self.lineCap = c;
}

pub fn setLineJoin(self: *SmCanvas, j: SmPaint.LineJoin) void {
    self.lineJoin = j;
}

pub fn setMiterLimit(self: *SmCanvas, m: f64) void {
    self.miterLimit = m;
}

/// setLineDash(segments) — HTML5 setter. Validates per spec (all entries
/// finite and >= 0); on any invalid entry the entire call is silently
/// ignored. Odd-length arrays are doubled before storing per HTML5 spec.
pub fn setLineDash(self: *SmCanvas, segments: []const f64) void {
    for (segments) |s| {
        if (!std.math.isFinite(s) or s < 0) return;
    }
    self.line_dash_storage.len = 0;
    self.line_dash_storage.appendSlice(self.surface.getAllocator(), segments) catch return;
    if ((segments.len & 1) == 1) {
        self.line_dash_storage.appendSlice(self.surface.getAllocator(), segments) catch return;
    }
}

/// getLineDash() — read-only view onto the stored dash array. JS layer
/// copies the result into a fresh `number[]` so consumer mutations don't
/// affect ctx state.
pub fn getLineDash(self: *const SmCanvas) []const f64 {
    return self.line_dash_storage.ptr[0..self.line_dash_storage.len];
}

pub fn setLineDashOffset(self: *SmCanvas, o: f64) void {
    if (!std.math.isFinite(o)) return;
    self.lineDashOffset = o;
}

// --- Transforms (HTML5 CTM) ----------------------------------------------
//
// Per the HTML5 spec, path-building methods (moveTo, lineTo, …) apply the
// CTM at the moment of the call — the path stores the already-transformed
// points. Drawing methods (drawRect, drawTriangle, drawImage) apply the CTM
// at draw time. `save / restore` push/pop transform + style state.

/// translate(tx, ty) — post-multiply CTM by translation matrix.
pub fn translate(self: *SmCanvas, tx: f64, ty: f64) void {
    _ = self.current_transform.translateSelf(tx, ty);
}

/// rotate(angle) — post-multiply CTM by rotation matrix. Angle in **radians**
/// per HTML5 spec (note: `SmMatrix.rotateSelf` takes degrees per the WebIDL
/// DOMMatrix shape — we convert here).
pub fn rotate(self: *SmCanvas, angle_radians: f64) void {
    const angle_degrees = angle_radians * (180.0 / std.math.pi);
    _ = self.current_transform.rotateSelf(angle_degrees);
}

/// scale(sx, sy) — post-multiply CTM by scaling matrix.
pub fn scale(self: *SmCanvas, sx: f64, sy: f64) void {
    _ = self.current_transform.scaleSelf(sx, sy);
}

/// transform(a, b, c, d, e, f) — post-multiply CTM by the given 6-component
/// affine matrix. Mirrors HTML5 `ctx.transform(...)`.
pub fn transform(self: *SmCanvas, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    var m: SmMatrix = .{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f };
    _ = self.current_transform.multiplySelf(&m);
}

/// setTransform(a, b, c, d, e, f) — replace CTM with the given matrix.
pub fn setTransform(self: *SmCanvas, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self.current_transform = .{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f };
}

/// resetTransform() — reset CTM to identity.
pub fn resetTransform(self: *SmCanvas) void {
    self.current_transform = .{};
}

/// getTransform() — return a copy of the current CTM.
pub fn getTransform(self: *const SmCanvas) SmMatrix {
    return self.current_transform;
}

/// save() — push current style + transform onto the state stack.
/// Snapshots `line_dash_storage` into a freshly-allocated owning slice so
/// nested mutations don't affect saved frames.
pub fn save(self: *SmCanvas) void {
    const allocator = self.surface.getAllocator();
    var saved_dash: []f64 = &.{};
    if (self.line_dash_storage.len > 0) {
        if (allocator.alloc(f64, self.line_dash_storage.len)) |buf| {
            @memcpy(buf, self.line_dash_storage.ptr[0..self.line_dash_storage.len]);
            saved_dash = buf;
        } else |_| {}
    }
    var saved_clip: ?[]u8 = null;
    if (self.clip_mask) |m| {
        if (allocator.alloc(u8, m.len)) |buf| {
            @memcpy(buf, m);
            saved_clip = buf;
        } else |_| {}
    }
    var saved_filter_verbs: []u8 = &.{};
    if (self.filter_verbs.len > 0) {
        if (allocator.alloc(u8, self.filter_verbs.len)) |buf| {
            @memcpy(buf, self.filter_verbs.ptr[0..self.filter_verbs.len]);
            saved_filter_verbs = buf;
        } else |_| {}
    }
    var saved_filter_params: []f64 = &.{};
    if (self.filter_params.len > 0) {
        if (allocator.alloc(f64, self.filter_params.len)) |buf| {
            @memcpy(buf, self.filter_params.ptr[0..self.filter_params.len]);
            saved_filter_params = buf;
        } else |_| {}
    }
    self.state_stack.append(allocator, .{
        .transform = self.current_transform,
        .fillStyle = self.fillStyle,
        .strokeStyle = self.strokeStyle,
        .lineWidth = self.lineWidth,
        .lineCap = self.lineCap,
        .lineJoin = self.lineJoin,
        .miterLimit = self.miterLimit,
        .lineDash = saved_dash,
        .lineDashOffset = self.lineDashOffset,
        .clipMask = saved_clip,
        .alpha = self.alpha,
        .blendMode = self.blendMode,
        .cxform = self.cxform,
        .imageSmoothingEnabled = self.imageSmoothingEnabled,
        .imageSmoothingQuality = self.imageSmoothingQuality,
        .shadowBlur = self.shadowBlur,
        .shadowColor = self.shadowColor,
        .shadowOffsetX = self.shadowOffsetX,
        .shadowOffsetY = self.shadowOffsetY,
        .filterVerbs = saved_filter_verbs,
        .filterParams = saved_filter_params,
    }) catch {
        if (saved_dash.len > 0) allocator.free(saved_dash);
        if (saved_clip) |b| allocator.free(b);
        if (saved_filter_verbs.len > 0) allocator.free(saved_filter_verbs);
        if (saved_filter_params.len > 0) allocator.free(saved_filter_params);
    };
}

/// restore() — pop the most-recent saved frame back into ctx state. No-op
/// if the stack is empty (matches HTML5 spec). Frees the popped frame's
/// dash snapshot after copying its contents back into live storage.
pub fn restore(self: *SmCanvas) void {
    if (self.state_stack.len == 0) return;
    const allocator = self.surface.getAllocator();
    self.state_stack.len -= 1;
    const frame = self.state_stack.ptr[self.state_stack.len];
    self.current_transform = frame.transform;
    self.fillStyle = frame.fillStyle;
    self.strokeStyle = frame.strokeStyle;
    self.lineWidth = frame.lineWidth;
    self.lineCap = frame.lineCap;
    self.lineJoin = frame.lineJoin;
    self.miterLimit = frame.miterLimit;
    self.lineDashOffset = frame.lineDashOffset;
    self.line_dash_storage.len = 0;
    if (frame.lineDash.len > 0) {
        self.line_dash_storage.appendSlice(allocator, frame.lineDash) catch {};
        allocator.free(frame.lineDash);
    }
    // Swap the saved clip mask back in; free the previously-active mask.
    if (self.clip_mask) |m| allocator.free(m);
    self.clip_mask = frame.clipMask;
    self.alpha = frame.alpha;
    self.blendMode = frame.blendMode;
    self.cxform = frame.cxform;
    self.imageSmoothingEnabled = frame.imageSmoothingEnabled;
    self.imageSmoothingQuality = frame.imageSmoothingQuality;
    self.shadowBlur = frame.shadowBlur;
    self.shadowColor = frame.shadowColor;
    self.shadowOffsetX = frame.shadowOffsetX;
    self.shadowOffsetY = frame.shadowOffsetY;
    // Restore filter chain — copy the snapshot back into live storage,
    // then free the snapshot.
    self.filter_verbs.len = 0;
    self.filter_params.len = 0;
    if (frame.filterVerbs.len > 0) {
        self.filter_verbs.appendSlice(allocator, frame.filterVerbs) catch {};
        allocator.free(frame.filterVerbs);
    }
    if (frame.filterParams.len > 0) {
        self.filter_params.appendSlice(allocator, frame.filterParams) catch {};
        allocator.free(frame.filterParams);
    }
}

/// Multiply a paint color's alpha channel by `globalAlpha`. Used by
/// fillRect/strokeRect/etc. when constructing a paint from ctx state.
inline fn applyAlphaModulation(color: u32, modulator: u8) u32 {
    if (modulator == 0xFF) return color;
    const a: u32 = (color >> 24) & 0xFF;
    const new_a: u32 = (a * @as(u32, modulator) + 0x80) >> 8;
    return (color & 0x00FFFFFF) | (new_a << 24);
}

/// Build a fill SmPaint from the current ctx state. Folds `self.alpha` into
/// the source color eagerly for `.solid` shaders (keeps the SIMD fast path
/// bit-exact); for `.gradient` / `.pattern` the alpha modulator rides along
/// on `paint.global_alpha` and is applied per-pixel by `SmBlitter`.
fn paintForFill(self: *const SmCanvas) SmPaint {
    var p = paintFromShader(self.fillStyle, .fill, 0, self.alpha, self.blendMode, self.cxform, self.surface.color_type);
    p.antialias = self.antialias;
    return p;
}

/// Build a stroke SmPaint from the current ctx state.
fn paintForStroke(self: *const SmCanvas) SmPaint {
    var p = paintFromShader(self.strokeStyle, .stroke, self.lineWidth, self.alpha, self.blendMode, self.cxform, self.surface.color_type);
    p.antialias = self.antialias;
    return p;
}

inline fn paintFromShader(
    shader: SmPaint.Shader,
    style: SmPaint.Style,
    stroke_width: f64,
    alpha: u8,
    blend_mode: SmPaint.BlendMode,
    cxform: SmPaint.ColorTransform,
    dst_color_type: types.ColorType,
) SmPaint {
    return switch (shader) {
        .solid => |c| .{
            // Fold order matches the blitter's per-pixel order: color
            // transform first, then the alpha modulator. Emit identity
            // cxform so the folded color is never transformed again.
            // The solid color stays LOGICAL RGBA — `resolveSolid` does the
            // late lane fold per `dst_color_type`.
            .shader = .{ .solid = applyAlphaModulation(
                if (cxform.isIdentity()) c else cxform.apply(c),
                alpha,
            ) },
            .style = style,
            .stroke_width = stroke_width,
            .blend_mode = blend_mode,
            .global_alpha = 0xFF,
            .dst_color_type = dst_color_type,
        },
        .gradient, .pattern => .{
            .shader = shader,
            .style = style,
            .stroke_width = stroke_width,
            .blend_mode = blend_mode,
            .global_alpha = alpha,
            .cxform = cxform,
            .dst_color_type = dst_color_type,
        },
    };
}

// ---------------------------------------------------------------------------
// Composite layers — for the 5 non-row-friendly composite modes.
// ---------------------------------------------------------------------------
//
// W3C Compositing & Blending L1 says: "the shape is drawn as a separate
// layer, then that layer is composited with the canvas using the operator."
// For most modes, that's equivalent to row-wise blit (pixels outside the
// shape's bbox stay unchanged because the formula reduces to `dst` there).
// But five modes — copy, src-in, src-out, dst-in, dst-atop — have a
// formula that yields `transparent` (or some non-dst value) outside the
// shape's region, so a row-wise blit through the bbox alone is wrong.
//
// For those, every public draw method opens a `CompositeLayer`: redirects
// `self.pixels` to a cleared scratch buffer, sets the blend mode to
// src_over for the duration of the draw (so the scratch records the shape
// as a normal source-over composite onto transparent), then on close
// composites scratch → canvas across the WHOLE canvas using the user's
// real blend mode. `null` is the no-op layer for modes that blit row-wise.
//
// `clearRect` does NOT open a layer — it uses a hardcoded `.src` paint and
// bypasses composite mode per HTML5 spec.

const CompositeLayer = struct {
    real_pixels: []u32,
    real_blend: SmPaint.BlendMode,
};

inline fn beginCompositeLayer(self: *SmCanvas) ?CompositeLayer {
    if (!self.blendMode.requiresLayerComposite()) return null;
    if (self.scratch_pixels == null or
        self.scratch_pixels.?.len != self.pixels.len) {
        if (self.scratch_pixels) |s| self.surface.getAllocator().free(s);
        self.scratch_pixels = self.surface.getAllocator().alloc(u32, self.pixels.len) catch return null;
    }
    const real = self.pixels;
    const real_blend = self.blendMode;
    self.pixels = self.scratch_pixels.?;
    self.blendMode = .src_over;
    simd.fillU32(self.pixels, 0);
    return .{ .real_pixels = real, .real_blend = real_blend };
}

inline fn endCompositeLayer(self: *SmCanvas, layer: ?CompositeLayer) void {
    const l = layer orelse return;
    // Scratch (current self.pixels) is the rendered shape on a transparent
    // background; composite it onto the real canvas using the user's mode.
    SmBlitter.blitFull(l.real_pixels, self.pixels, l.real_blend, self.surface.color_type);
    self.pixels = l.real_pixels;
    self.blendMode = l.real_blend;
}

// --- Shadow rendering pipeline ------------------------------------------
//
// `beginShadowLayer` switches `self.pixels` to a cleared scratch RGBA
// buffer and forces the inner draw to use src_over (so the shape lands
// cleanly on transparent). `endShadowLayer` extracts the alpha channel of
// that scratch, applies a Gaussian blur sized from `shadowBlur`,
// premultiplies the blurred mask by `shadowColor`, and composites it onto
// the real canvas at `(shadowOffsetX, shadowOffsetY)` using the user's
// blend mode. It then composites the original shape (still in the scratch
// buffer) onto the real canvas — also using the user's blend mode.
//
// Shape and shadow share the same blend mode against destination, which
// matches Chromium/Skia behavior. `globalAlpha` was already pre-modulated
// into the source paints during the inner draw, so it does not need to
// be re-applied at composite time.
//
// `clearRect` and `putImageData` skip the shadow pipeline entirely (per
// HTML5 §canvas-shadow-effect — "shadows are only drawn if [...] the
// shape is being drawn with the relevant fill or stroke style"; clears
// and pixel writes don't qualify).

const ShadowLayer = struct {
    real_pixels: []u32,
    real_blend: SmPaint.BlendMode,
};

pub fn shadowVisible(self: *const SmCanvas) bool {
    if (((self.shadowColor >> 24) & 0xFF) == 0) return false;
    return self.shadowBlur != 0 or
        self.shadowOffsetX != 0 or
        self.shadowOffsetY != 0;
}

inline fn ensureShadowBuffers(self: *SmCanvas) bool {
    const allocator = self.surface.getAllocator();
    const need = self.pixels.len;
    if (self.shadow_scratch == null or self.shadow_scratch.?.len != need) {
        if (self.shadow_scratch) |s| allocator.free(s);
        self.shadow_scratch = allocator.alloc(u32, need) catch return false;
    }
    if (self.shadow_alpha == null or self.shadow_alpha.?.len != need) {
        if (self.shadow_alpha) |s| allocator.free(s);
        self.shadow_alpha = allocator.alloc(u8, need) catch return false;
    }
    if (self.shadow_alpha_b == null or self.shadow_alpha_b.?.len != need) {
        if (self.shadow_alpha_b) |s| allocator.free(s);
        self.shadow_alpha_b = allocator.alloc(u8, need) catch return false;
    }
    return true;
}

inline fn beginShadowLayer(self: *SmCanvas) ?ShadowLayer {
    if (!self.shadowVisible()) return null;
    if (!self.ensureShadowBuffers()) return null;
    const real = self.pixels;
    const real_blend = self.blendMode;
    self.pixels = self.shadow_scratch.?;
    self.blendMode = .src_over;
    simd.fillU32(self.pixels, 0);
    return .{ .real_pixels = real, .real_blend = real_blend };
}

inline fn endShadowLayer(self: *SmCanvas, layer: ?ShadowLayer) void {
    const l = layer orelse return;
    const w: u32 = self.surface.width;
    const h: u32 = self.surface.height;
    const total = self.pixels.len;
    const alpha = self.shadow_alpha.?[0..total];
    const alpha_b = self.shadow_alpha_b.?[0..total];

    // Extract source alpha channel into a u8 mask.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        alpha[i] = @intCast((self.pixels[i] >> 24) & 0xFF);
    }
    // Blur in place; use alpha_b as scratch.
    // HTML5 spec: shadowBlur is the "blur radius". Chromium uses
    // sigma = blur / 2, which gives visually-matching falloff.
    const sigma = self.shadowBlur / 2.0;
    if (sigma > 0) {
        // gaussianBlurAlpha(dst, src, scratch, w, h, sigma) — destination
        // here is alpha (modify in place); src must be a separate buffer.
        @memcpy(alpha_b, alpha);
        simd.gaussianBlurAlpha(alpha, alpha_b, alpha_b, w, h, sigma);
    }

    // Composite the shadow onto real_pixels at the offset using a per-row
    // coverage blit. The shadow's per-pixel alpha is `(blurred_alpha *
    // shadow_color.alpha + 127)/255`. We fold that into the row's
    // coverage byte, and pass the shadow_color (RGB + opaque alpha) to
    // blitRow — blitRow's coverage path then multiplies the source's
    // alpha by coverage and runs the per-mode blend formula.
    const offset_x: i32 = @intFromFloat(@round(self.shadowOffsetX));
    const offset_y: i32 = @intFromFloat(@round(self.shadowOffsetY));
    const shadow_a: u8 = @intCast((self.shadowColor >> 24) & 0xFF);
    const shadow_color_full: u32 = (self.shadowColor & 0x00FFFFFF) | (@as(u32, 0xFF) << 24);
    var paint: SmPaint = .{
        .shader = .{ .solid = shadow_color_full },
        .style = .fill,
        .blend_mode = l.real_blend,
        .global_alpha = 0xFF,
        .stroke_width = 0,
        .dst_color_type = self.surface.color_type,
    };

    const cw_i: i32 = @intCast(w);
    const ch_i: i32 = @intCast(h);
    const allocator = self.surface.getAllocator();
    var y: i32 = 0;
    while (y < ch_i) : (y += 1) {
        const dst_y = y + offset_y;
        if (dst_y < 0 or dst_y >= ch_i) continue;
        const x_lo: i32 = @max(0, offset_x);
        const x_hi: i32 = @min(cw_i, cw_i + offset_x);
        if (x_hi <= x_lo) continue;
        const src_x_start: i32 = x_lo - offset_x;
        const span_n: u32 = @intCast(x_hi - x_lo);
        const src_row_off: usize = @as(usize, @intCast(y)) * @as(usize, w) + @as(usize, @intCast(src_x_start));
        const src_row = alpha[src_row_off..][0..span_n];
        // Modulate shadow_a into per-pixel coverage. Build a tiny scratch.
        var cov_buf: [256]u8 = undefined;
        const heap = if (span_n > cov_buf.len) (allocator.alloc(u8, span_n) catch null) else null;
        const cov_row: []u8 = if (heap) |hp| hp else cov_buf[0..span_n];
        defer if (heap) |hp| allocator.free(hp);
        var k: usize = 0;
        while (k < span_n) : (k += 1) {
            cov_row[k] = @intCast((@as(u16, src_row[k]) * @as(u16, shadow_a) + 127) / 255);
        }
        SmBlitter.blitRow(
            l.real_pixels,
            w,
            x_lo,
            dst_y,
            span_n,
            cov_row,
            &paint,
            if (self.clip_mask) |cm| cm else null,
        );
    }

    // Composite the original shape onto the real canvas using the user's
    // blend mode. The shape was rendered with src_over into shadow_scratch,
    // so its premultiplied alpha is intact — `blitFull` runs the per-mode
    // blend formula per pixel against the destination (which now has the
    // shadow on top).
    SmBlitter.blitFull(l.real_pixels, self.pixels, l.real_blend, self.surface.color_type);

    self.pixels = l.real_pixels;
    self.blendMode = l.real_blend;
}

// --- Filter chain (HTML5 `ctx.filter`) -----------------------------------
//
// `setFilterChain(verbs, params)` accepts the parsed CSS-filter chain from
// the JS layer (`parseCssFilter` in src/index.ts). `beginFilterLayer` /
// `endFilterLayer` wrap each shadowed/composited drawing operation so the
// shape lands in `filter_scratch`, then the per-op filters apply, then
// the result composites onto the real canvas using the user's blend mode.
//
// Pipeline ordering at every public draw entry point:
//   begin_filter [outermost — pixels = filter_scratch, src_over]
//     begin_shadow [pixels = shadow_scratch, src_over]
//       begin_composite [layer scratch_pixels for non-row-friendly modes]
//         draw shape
//       end_composite
//     end_shadow [shape with shadow now in filter_scratch]
//   end_filter [apply filter chain, composite onto real canvas]

pub fn setFilterChain(self: *SmCanvas, verbs: []const u8, params: []const f64) void {
    const allocator = self.surface.getAllocator();
    self.filter_verbs.len = 0;
    self.filter_params.len = 0;
    self.filter_verbs.appendSlice(allocator, verbs) catch {};
    self.filter_params.appendSlice(allocator, params) catch {};
}

pub fn filterVisible(self: *const SmCanvas) bool {
    return self.filter_verbs.len > 0;
}

const FilterLayer = struct {
    real_pixels: []u32,
    real_blend: SmPaint.BlendMode,
};

inline fn ensureFilterBuffers(self: *SmCanvas) bool {
    const allocator = self.surface.getAllocator();
    const need_pixels = self.pixels.len;
    if (self.filter_scratch == null or self.filter_scratch.?.len != need_pixels) {
        if (self.filter_scratch) |s| allocator.free(s);
        self.filter_scratch = allocator.alloc(u32, need_pixels) catch return false;
    }
    const need_blur: usize = need_pixels * 5;
    if (self.filter_blur_scratch == null or self.filter_blur_scratch.?.len < need_blur) {
        if (self.filter_blur_scratch) |s| allocator.free(s);
        self.filter_blur_scratch = allocator.alloc(u8, need_blur) catch return false;
    }
    return true;
}

inline fn beginFilterLayer(self: *SmCanvas) ?FilterLayer {
    if (!self.filterVisible()) return null;
    if (!self.ensureFilterBuffers()) return null;
    const real = self.pixels;
    const real_blend = self.blendMode;
    self.pixels = self.filter_scratch.?;
    self.blendMode = .src_over;
    simd.fillU32(self.pixels, 0);
    return .{ .real_pixels = real, .real_blend = real_blend };
}

inline fn endFilterLayer(self: *SmCanvas, layer: ?FilterLayer) void {
    const l = layer orelse return;
    const w: u32 = self.surface.width;
    const h: u32 = self.surface.height;
    const blur_scratch = self.filter_blur_scratch.?;

    // Walk the filter chain and apply each op in order to self.pixels (the
    // filter scratch). `pi` cursors through `filter_params`.
    var vi: usize = 0;
    var pi: usize = 0;
    while (vi < self.filter_verbs.len) {
        const op_byte = self.filter_verbs.ptr[vi];
        vi += 1;
        const op: FilterOp = @enumFromInt(op_byte);
        const n_params = filterParamCount(op);
        const params = self.filter_params.ptr[pi..][0..n_params];
        pi += n_params;
        switch (op) {
            .blur => {
                const sigma = params[0];
                if (sigma > 0) {
                    // gaussianBlurU32 requires src != dst; copy then blur back.
                    const total = self.pixels.len;
                    if (blur_scratch.len >= total * 5) {
                        // Reuse one slot of the blur scratch as src buffer.
                        // Layout: 5 byte-buffers of `total`. Need a u32 src.
                        // Allocate a side buffer for the u32 src copy.
                        const allocator = self.surface.getAllocator();
                        const src_copy = allocator.alloc(u32, total) catch continue;
                        defer allocator.free(src_copy);
                        @memcpy(src_copy, self.pixels);
                        simd.gaussianBlurU32(self.pixels, src_copy, blur_scratch, w, h, sigma);
                    }
                }
            },
            .brightness => {
                simd.brightnessU32(self.pixels, params[0]);
            },
            .contrast => {
                simd.contrastU32(self.pixels, params[0]);
            },
        }
    }

    // Composite the filtered scratch onto the real canvas using the user's
    // blend mode. globalAlpha was pre-modulated into the source at draw
    // time, so no additional alpha pass is needed here.
    SmBlitter.blitFull(l.real_pixels, self.pixels, l.real_blend, self.surface.color_type);

    self.pixels = l.real_pixels;
    self.blendMode = l.real_blend;
}

// --- Paths ---------------------------------------------------------------

pub fn beginPath(self: *SmCanvas) void {
    self.path.clear();
}

pub fn closePath(self: *SmCanvas) void {
    self.path.closePath();
}

pub fn moveTo(self: *SmCanvas, x: f64, y: f64) void {
    const p = self.current_transform.applyToPoint(x, y);
    self.path.moveTo(p[0], p[1]);
}

pub fn lineTo(self: *SmCanvas, x: f64, y: f64) void {
    const p = self.current_transform.applyToPoint(x, y);
    self.path.lineTo(p[0], p[1]);
}

pub fn bezierCurveTo(
    self: *SmCanvas,
    cp1x: f64,
    cp1y: f64,
    cp2x: f64,
    cp2y: f64,
    x: f64,
    y: f64,
) void {
    const cp1 = self.current_transform.applyToPoint(cp1x, cp1y);
    const cp2 = self.current_transform.applyToPoint(cp2x, cp2y);
    const p = self.current_transform.applyToPoint(x, y);
    self.path.bezierCurveTo(cp1[0], cp1[1], cp2[0], cp2[1], p[0], p[1]);
}

pub fn quadraticCurveTo(self: *SmCanvas, cpx: f64, cpy: f64, x: f64, y: f64) void {
    const cp = self.current_transform.applyToPoint(cpx, cpy);
    const p = self.current_transform.applyToPoint(x, y);
    self.path.quadraticCurveTo(cp[0], cp[1], p[0], p[1]);
}

/// arc(cx, cy, r, startAngle, endAngle, counterclockwise) — flatten a
/// circular arc to line segments and append to the current path. CTM is
/// applied per-vertex via `self.lineTo` (so a non-uniform CTM correctly
/// turns the arc into an elliptical path on the canvas). Mirrors HTML5
/// `ctx.arc(...)`.
pub fn arc(
    self: *SmCanvas,
    cx: f64,
    cy: f64,
    r: f64,
    start_angle: f64,
    end_angle: f64,
    ccw: bool,
) void {
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(r) or
        !std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) return;
    if (r < 0) return;
    if (r == 0) {
        self.lineTo(cx, cy);
        return;
    }
    const sweep = SmPath.normalizeSweep(start_angle, end_angle, ccw);
    const n = SmPath.arcSegmentCount(r, sweep);
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const a = start_angle + t * sweep;
        self.lineTo(cx + r * @cos(a), cy + r * @sin(a));
    }
}

/// ellipse(...) — same as arc with separate rx, ry, and a rotation angle.
/// Mirrors HTML5 `ctx.ellipse(...)`.
pub fn ellipse(
    self: *SmCanvas,
    cx: f64,
    cy: f64,
    rx: f64,
    ry: f64,
    rotation: f64,
    start_angle: f64,
    end_angle: f64,
    ccw: bool,
) void {
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(rx) or !std.math.isFinite(ry) or
        !std.math.isFinite(rotation) or
        !std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) return;
    if (rx < 0 or ry < 0) return;
    if (rx == 0 or ry == 0) {
        self.lineTo(cx, cy);
        return;
    }
    const sweep = SmPath.normalizeSweep(start_angle, end_angle, ccw);
    const n = SmPath.arcSegmentCount(@max(rx, ry), sweep);
    const cos_rot = @cos(rotation);
    const sin_rot = @sin(rotation);
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const a = start_angle + t * sweep;
        const lx = rx * @cos(a);
        const ly = ry * @sin(a);
        self.lineTo(cx + lx * cos_rot - ly * sin_rot, cy + lx * sin_rot + ly * cos_rot);
    }
}

/// arcTo(x1, y1, x2, y2, r) — emit a line from current point to the
/// tangent point of the arc, then a circular arc to the second tangent
/// point. CTM-aware: tangent geometry is computed in user-space using
/// the inverse-transformed current point as P0; the resulting line + arc
/// are emitted through `self.lineTo` / `self.arc` so each generated
/// vertex flows through the CTM (matching how `arc()` handles non-uniform
/// CTMs by deforming arcs to ellipses).
pub fn arcTo(self: *SmCanvas, x1: f64, y1: f64, x2: f64, y2: f64, r: f64) void {
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1) or
        !std.math.isFinite(x2) or !std.math.isFinite(y2) or
        !std.math.isFinite(r)) return;
    if (r < 0) return;

    if (!self.path.subpath_open) {
        self.moveTo(x1, y1);
        return;
    }

    // Inverse-transform path.current_point (canvas-space) back to user-space.
    var inv = self.current_transform;
    _ = inv.invertSelf();
    if (!std.math.isFinite(inv.a)) {
        // Singular CTM — degrade to lineTo at the canvas-space P1.
        self.lineTo(x1, y1);
        return;
    }
    const p0u = inv.applyToPoint(self.path.current_point[0], self.path.current_point[1]);

    const ax = p0u[0] - x1;
    const ay = p0u[1] - y1;
    const bx = x2 - x1;
    const by = y2 - y1;
    const a_len = @sqrt(ax * ax + ay * ay);
    const b_len = @sqrt(bx * bx + by * by);

    if (a_len == 0 or b_len == 0 or r == 0) {
        self.lineTo(x1, y1);
        return;
    }

    const ux = ax / a_len;
    const uy = ay / a_len;
    const vx = bx / b_len;
    const vy = by / b_len;

    const cos_theta = ux * vx + uy * vy;
    const cross = ux * vy - uy * vx;
    if (@abs(cross) < 1e-12) {
        self.lineTo(x1, y1);
        return;
    }

    const sin_theta = @abs(cross);
    const tan_half = sin_theta / (1.0 + cos_theta);
    const d = r / tan_half;

    const t0x = x1 + ux * d;
    const t0y = y1 + uy * d;
    const t1x = x1 + vx * d;
    const t1y = y1 + vy * d;

    const cx_off = ux + vx;
    const cy_off = uy + vy;
    const bisector_len = @sqrt(cx_off * cx_off + cy_off * cy_off);
    const half_sin = @sqrt(@max(0.0, (1.0 - cos_theta) / 2.0));
    if (half_sin == 0 or bisector_len == 0) {
        self.lineTo(x1, y1);
        return;
    }
    const cdist = r / half_sin;
    const cx = x1 + (cx_off / bisector_len) * cdist;
    const cy = y1 + (cy_off / bisector_len) * cdist;

    const start_angle = std.math.atan2(t0y - cy, t0x - cx);
    const end_angle = std.math.atan2(t1y - cy, t1x - cx);
    const ccw = cross > 0;

    self.lineTo(t0x, t0y);
    self.arc(cx, cy, r, start_angle, end_angle, ccw);
}

/// roundRect(x, y, w, h, r_tl, r_tr, r_br, r_bl) — closed rounded
/// rectangular sub-path. JS layer normalizes the polymorphic `radii`
/// argument into four scalars and clamps negatives. CTM-aware via
/// `self.lineTo` + `self.arc` per-vertex application.
pub fn roundRect(
    self: *SmCanvas,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    r_tl: f64,
    r_tr: f64,
    r_br: f64,
    r_bl: f64,
) void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(w) or !std.math.isFinite(h) or
        !std.math.isFinite(r_tl) or !std.math.isFinite(r_tr) or
        !std.math.isFinite(r_br) or !std.math.isFinite(r_bl)) return;
    if (r_tl == 0 and r_tr == 0 and r_br == 0 and r_bl == 0) {
        self.rect(x, y, w, h);
        return;
    }
    if (w == 0 or h == 0) {
        self.moveTo(x, y);
        return;
    }
    var rtl = r_tl;
    var rtr = r_tr;
    var rbr = r_br;
    var rbl = r_bl;
    var ax = x;
    var ay = y;
    var aw = w;
    var ah = h;
    if (aw < 0) {
        ax += aw;
        aw = -aw;
        const t1 = rtl; rtl = rtr; rtr = t1;
        const t2 = rbl; rbl = rbr; rbr = t2;
    }
    if (ah < 0) {
        ay += ah;
        ah = -ah;
        const t1 = rtl; rtl = rbl; rbl = t1;
        const t2 = rtr; rtr = rbr; rbr = t2;
    }
    const top = rtl + rtr;
    const right = rtr + rbr;
    const bottom = rbl + rbr;
    const left = rtl + rbl;
    var radius_scale: f64 = 1.0;
    if (top > aw) radius_scale = @min(radius_scale, aw / top);
    if (bottom > aw) radius_scale = @min(radius_scale, aw / bottom);
    if (left > ah) radius_scale = @min(radius_scale, ah / left);
    if (right > ah) radius_scale = @min(radius_scale, ah / right);
    if (radius_scale < 1.0) {
        rtl *= radius_scale;
        rtr *= radius_scale;
        rbr *= radius_scale;
        rbl *= radius_scale;
    }

    const x0 = ax;
    const y0 = ay;
    const x1 = ax + aw;
    const y1 = ay + ah;

    self.moveTo(x0 + rtl, y0);
    self.lineTo(x1 - rtr, y0);
    if (rtr > 0) {
        self.arc(x1 - rtr, y0 + rtr, rtr, -std.math.pi / 2.0, 0.0, false);
    }
    self.lineTo(x1, y1 - rbr);
    if (rbr > 0) {
        self.arc(x1 - rbr, y1 - rbr, rbr, 0.0, std.math.pi / 2.0, false);
    }
    self.lineTo(x0 + rbl, y1);
    if (rbl > 0) {
        self.arc(x0 + rbl, y1 - rbl, rbl, std.math.pi / 2.0, std.math.pi, false);
    }
    self.lineTo(x0, y0 + rtl);
    if (rtl > 0) {
        self.arc(x0 + rtl, y0 + rtl, rtl, std.math.pi, 3.0 * std.math.pi / 2.0, false);
    }
    self.closePath();
}

pub fn rect(self: *SmCanvas, x: f64, y: f64, w: f64, h: f64) void {
    // Axis-aligned CTM (no rotation/skew): stay rectangular.
    if (self.current_transform.b == 0 and self.current_transform.c == 0) {
        const tx = self.current_transform.a * x + self.current_transform.e;
        const ty = self.current_transform.d * y + self.current_transform.f;
        const tw = self.current_transform.a * w;
        const th = self.current_transform.d * h;
        self.path.rect(tx, ty, tw, th);
        return;
    }
    // Rotated/skewed CTM: rect becomes a parallelogram — decompose to
    // moveTo + 3×lineTo + closePath, like SmPath.addPathTransform does.
    const tl = self.current_transform.applyToPoint(x, y);
    const tr = self.current_transform.applyToPoint(x + w, y);
    const br = self.current_transform.applyToPoint(x + w, y + h);
    const bl = self.current_transform.applyToPoint(x, y + h);
    self.path.moveTo(tl[0], tl[1]);
    self.path.lineTo(tr[0], tr[1]);
    self.path.lineTo(br[0], br[1]);
    self.path.lineTo(bl[0], bl[1]);
    self.path.closePath();
}

// --- Drawing primitives (Skia-style: take a SmPaint) ---------------------

/// drawRect(x, y, w, h, paint) — fill / stroke a rectangle per `paint.style`.
/// Mirrors `SkCanvas::drawRect(rect, paint)`. Applies the CTM:
///   • axis-aligned CTM (no rotation / skew) → fast path: transform corners,
///     stay rectangular, scanline fill via Blitter.
///   • rotated / skewed CTM → decompose to 2 transformed triangles.
/// Stroke under non-axis-aligned CTM is treated as 4 thin transformed rects;
/// proper rotated stroke joins land with T7 (path stroke).
pub fn drawRect(self: *SmCanvas, x: f64, y: f64, w: f64, h: f64, paint: *const SmPaint) void {
    if (self.current_transform.b == 0 and self.current_transform.c == 0) {
        // Axis-aligned CTM — transform corners, stay rectangular.
        const tx = self.current_transform.a * x + self.current_transform.e;
        const ty = self.current_transform.d * y + self.current_transform.f;
        const tw = self.current_transform.a * w;
        const th = self.current_transform.d * h;
        // Normalize for negative scale (flip axes).
        const nx: f64 = if (tw < 0) tx + tw else tx;
        const ny: f64 = if (th < 0) ty + th else ty;
        const nw: f64 = if (tw < 0) -tw else tw;
        const nh: f64 = if (th < 0) -th else th;
        drawRectAxisAligned(self, nx, ny, nw, nh, paint);
        return;
    }
    // Rotated / skewed CTM: build a single 4-vertex polygon and AA-fill it
    // through `fillPolygonF`. (The previous two-triangle decomposition would
    // leave a faint diagonal seam where each triangle's AA coverage stopped
    // — Skia treats the rect as one region with no internal edge, and now
    // we match that.)
    if (SmPaint.includesFill(paint.style)) {
        const tl = self.current_transform.applyToPoint(x, y);
        const tr = self.current_transform.applyToPoint(x + w, y);
        const br = self.current_transform.applyToPoint(x + w, y + h);
        const bl = self.current_transform.applyToPoint(x, y + h);
        // Copy-and-override so blend_mode / global_alpha (and any future
        // per-paint state) propagate — a bare `.{ .shader = …, .style = … }`
        // literal silently dropped them here.
        var fp = paint.*;
        fp.style = .fill;
        const aa = self.ensureAaScratch() orelse return;
        const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
        const verts = [_][2]f64{
            .{ tl[0], tl[1] }, .{ tr[0], tr[1] },
            .{ br[0], br[1] }, .{ bl[0], bl[1] },
        };
        SmScan.fillPolygonF(
            self.surface.getAllocator(),
            self.pixels,
            self.surface.width,
            self.surface.height,
            &verts,
            clip_mask,
            &fp,
            aa.accum,
            aa.cov,
        ) catch {};
    }
    if (SmPaint.includesStroke(paint.style)) {
        // Build a 4-vertex closed path from the CTM-applied corners and
        // route through the path-stroke pipeline. Honors lineCap, lineJoin,
        // miterLimit, setLineDash, lineDashOffset via the active ctx state.
        // strokePath takes a fill-shaped paint (it inflates the outline
        // polygon and fills it through the same scan pipeline).
        const tl = self.current_transform.applyToPoint(x, y);
        const tr = self.current_transform.applyToPoint(x + w, y);
        const br = self.current_transform.applyToPoint(x + w, y + h);
        const bl = self.current_transform.applyToPoint(x, y + h);
        const allocator = self.surface.getAllocator();
        var p = SmPath.emptyWithAllocator(allocator);
        defer p.deinit();
        p.moveTo(tl[0], tl[1]);
        p.lineTo(tr[0], tr[1]);
        p.lineTo(br[0], br[1]);
        p.lineTo(bl[0], bl[1]);
        p.closePath();
        // Copy-and-override (same rationale as the fill arm above).
        var sp = paint.*;
        sp.style = .fill;
        const aa = self.ensureAaScratch() orelse return;
        const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
        SmScan.strokePath(
            allocator,
            self.pixels,
            self.surface.width,
            self.surface.height,
            &p,
            self.lineWidth,
            self.lineCap,
            self.lineJoin,
            self.miterLimit,
            self.line_dash_storage.ptr[0..self.line_dash_storage.len],
            self.lineDashOffset,
            clip_mask,
            &sp,
            aa.accum,
            aa.cov,
        ) catch {};
    }
}

/// drawTriangle(..., paint) — fill a triangle. Applies the CTM to vertices
/// and routes through the AA polygon filler so diagonal edges are smooth
/// regardless of CTM (rotation, scale, sub-pixel translate). Stroke style
/// falls back to filled in the stroke color (outlined-triangle stroke is
/// served by the T7 path stroke through `ctx.stroke()`).
pub fn drawTriangle(
    self: *SmCanvas,
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    paint: *const SmPaint,
) void {
    const p0 = self.current_transform.applyToPoint(x0, y0);
    const p1 = self.current_transform.applyToPoint(x1, y1);
    const p2 = self.current_transform.applyToPoint(x2, y2);
    drawTriangleNoTransform(self, p0[0], p0[1], p1[0], p1[1], p2[0], p2[1], paint);
}

/// Internal: triangle fill via the AA polygon filler. Vertices are in
/// canvas-pixel space (no further CTM application). Used by drawTriangle
/// (post-CTM) and the legacy rotated-rect 2-triangle path (now superseded
/// by a single 4-vertex polygon — see `drawRect`). Coordinates are kept
/// at f64 through to the rasterizer so sub-pixel positioning gets correct
/// analytic-x partial-coverage on triangle boundaries.
fn drawTriangleNoTransform(
    self: *SmCanvas,
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
    paint: *const SmPaint,
) void {
    const aa = self.ensureAaScratch() orelse return;
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    const verts = [_][2]f64{ .{ x0, y0 }, .{ x1, y1 }, .{ x2, y2 } };
    SmScan.fillPolygonF(
        self.surface.getAllocator(),
        self.pixels,
        self.surface.width,
        self.surface.height,
        &verts,
        clip_mask,
        paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

/// True when every f64 coord is within ε of its nearest integer — used to
/// gate the binary-span fast path inside `fillRectSpan`. ε at `1e-9` is
/// deliberately loose to absorb the roundoff that creeps in through the
/// `current_transform.a * x + current_transform.e` chain when the inputs
/// are clean integers.
inline fn isIntegerAligned4(x: f64, y: f64, w: f64, h: f64) bool {
    const eps: f64 = 1e-9;
    return @abs(x - @round(x)) < eps and @abs(y - @round(y)) < eps and
        @abs(w - @round(w)) < eps and @abs(h - @round(h)) < eps;
}

/// Internal: axis-aligned rect fill+stroke via Scan + Blitter, with coords
/// already CTM-applied. Used by drawRect's axis-aligned fast path. Coords
/// are f64 — `fillRectSpan` branches on integer-alignment to route
/// fractional rects through `SmScan.fillPolygonF` (AA boundary cells)
/// while integer-aligned rects keep the binary blitRow fast path.
fn drawRectAxisAligned(
    self: *SmCanvas,
    x: f64, y: f64, w: f64, h: f64,
    paint: *const SmPaint,
) void {
    if (SmPaint.includesFill(paint.style)) {
        fillRectSpan(self, x, y, w, h, paint);
    }
    if (SmPaint.includesStroke(paint.style)) {
        const lw: f64 = paint.stroke_width;
        const half: f64 = lw / 2.0;
        // Copy-and-override so ALL per-paint state (blend_mode,
        // global_alpha, and any future fields) survives the
        // stroke-as-4-rects decomposition.
        var edge = paint.*;
        edge.style = .fill;
        fillRectSpan(self, x - half, y - half, w + lw, lw, &edge);
        fillRectSpan(self, x - half, y + h - half, w + lw, lw, &edge);
        fillRectSpan(self, x - half, y + half, lw, h - lw, &edge);
        fillRectSpan(self, x + w - half, y + half, lw, h - lw, &edge);
    }
}

/// Internal: fill an axis-aligned rect.
///
/// Fast path (binary `blitRow` per row): integer-aligned coords AND
/// non-`.src` blend mode (`.src` is `clearRect`, which HTML5 defines as
/// binary regardless of fractional input).
///
/// Slow path: build a 4-vertex polygon from the f64 corners and route
/// through `SmScan.fillPolygonF` so the partial-pixel boundary cells get
/// analytic-x AA coverage. Per the spec, `fillRect(10.5, 10.5, 100, 100)`
/// is supposed to render with half-coverage on the left/right/top/bottom
/// boundary cells — Skia and every browser do this.
fn fillRectSpan(
    self: *SmCanvas,
    x: f64, y: f64, w: f64, h: f64,
    paint: *const SmPaint,
) void {
    if (paint.blend_mode == .src or isIntegerAligned4(x, y, w, h)) {
        const r = SmScan.clipRect(
            self.surface.width,
            self.surface.height,
            @as(i32, @intFromFloat(@round(x))),
            @as(i32, @intFromFloat(@round(y))),
            @as(i32, @intFromFloat(@round(w))),
            @as(i32, @intFromFloat(@round(h))),
        ) orelse return;
        const n: u32 = @intCast(r.x1 - r.x0);
        const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
        var y_cur: i32 = r.y0;
        while (y_cur < r.y1) : (y_cur += 1) {
            SmBlitter.blitRow(self.pixels, self.surface.width, r.x0, y_cur, n, null, paint, clip_mask);
        }
        return;
    }
    // Fractional coords — AA path.
    if (w <= 0 or h <= 0) return;
    const aa = self.ensureAaScratch() orelse return;
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    const verts = [_][2]f64{
        .{ x, y },
        .{ x + w, y },
        .{ x + w, y + h },
        .{ x, y + h },
    };
    SmScan.fillPolygonF(
        self.surface.getAllocator(),
        self.pixels,
        self.surface.width,
        self.surface.height,
        &verts,
        clip_mask,
        paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

// --- Path drawing (T5: fill, no AA) --------------------------------------

/// fill() — rasterize the current path using the active fillStyle, alpha,
/// blend mode, and `fill_rule`. Path coordinates are already CTM-applied
/// at append time (per moveTo/lineTo/...), so no further transform is
/// needed here. Errors during scan-conversion (OOM while building the
/// edge list) are silently swallowed — matches the behavior of segment
/// emitters elsewhere in the codebase.
pub fn fill(self: *SmCanvas, fill_rule: SmScan.FillRule) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var paint = self.paintForFill();
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    const aa = self.ensureAaScratch() orelse return;
    SmScan.fillPath(
        self.surface.getAllocator(),
        self.pixels,
        self.surface.width,
        self.surface.height,
        &self.path,
        fill_rule,
        clip_mask,
        &paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

/// fillPathExternal(path, fill_rule) — rasterize an arbitrary `SmPath`
/// (typically a JS Path2D handle) with the active fill paint state.
/// Mirrors HTML5 `ctx.fill(path, fillRule?)`. Per spec, the current CTM
/// is applied to the supplied path at draw time (the internal `self.path`
/// is already canvas-space because `SmCanvas.moveTo` etc. bake the CTM
/// in at append; an external Path2D was built without that, so we apply
/// the CTM here via a transient copy).
pub fn fillPathExternal(self: *SmCanvas, path: *const SmPath, fill_rule: SmScan.FillRule) void {
    const allocator = self.surface.getAllocator();
    var transformed: SmPath = .{ .allocator = allocator };
    defer transformed.deinit();
    transformed.addPathTransform(path, &self.current_transform) catch return;

    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var paint = self.paintForFill();
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    const aa = self.ensureAaScratch() orelse return;
    SmScan.fillPath(
        allocator,
        self.pixels,
        self.surface.width,
        self.surface.height,
        &transformed,
        fill_rule,
        clip_mask,
        &paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

/// stroke() — outline the current path using `lineWidth`, `lineCap`,
/// `lineJoin`, `miterLimit`, `strokeStyle`, alpha, and blend mode.
/// Inflates the path to an outline polygon and fills it through the same
/// scanline pipeline as fill().
pub fn stroke(self: *SmCanvas) void {
    self.strokeInternal(&self.path);
}

/// strokePathExternal(path) — outline an arbitrary `SmPath` with the
/// current stroke paint state. Mirrors HTML5 `ctx.stroke(path)`. Per spec,
/// the current CTM is applied to the supplied path at draw time (see the
/// equivalent comment on `fillPathExternal`).
pub fn strokePathExternal(self: *SmCanvas, path: *const SmPath) void {
    const allocator = self.surface.getAllocator();
    var transformed: SmPath = .{ .allocator = allocator };
    defer transformed.deinit();
    transformed.addPathTransform(path, &self.current_transform) catch return;
    self.strokeInternal(&transformed);
}

fn strokeInternal(self: *SmCanvas, path: *const SmPath) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    // strokePath takes a fill-shaped paint (it inflates the outline polygon
    // and fills it through the same scan pipeline as fillPath).
    var paint = paintFromShader(self.strokeStyle, .fill, 0, self.alpha, self.blendMode, self.cxform, self.surface.color_type);
    paint.antialias = self.antialias;
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    const aa = self.ensureAaScratch() orelse return;
    SmScan.strokePath(
        self.surface.getAllocator(),
        self.pixels,
        self.surface.width,
        self.surface.height,
        path,
        self.lineWidth,
        self.lineCap,
        self.lineJoin,
        self.miterLimit,
        self.line_dash_storage.ptr[0..self.line_dash_storage.len],
        self.lineDashOffset,
        clip_mask,
        &paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

/// clip(fill_rule) — intersect the current clip region with the current
/// path's interior under `fill_rule`. Allocates the canvas-wide clip mask
/// lazily on first use. Subsequent clips multiplicatively narrow the
/// region per HTML5 spec — clip is monotonic.
pub fn clip(self: *SmCanvas, fill_rule: SmScan.FillRule) void {
    self.clipInternal(&self.path, fill_rule);
}

/// clipPath(path, fill_rule) — same as `clip` but with an explicit path.
/// Mirrors HTML5 `ctx.clip(path, fillRule?)`. Per spec, the current CTM
/// is applied to the supplied path at draw time.
pub fn clipPath(self: *SmCanvas, path: *const SmPath, fill_rule: SmScan.FillRule) void {
    const allocator = self.surface.getAllocator();
    var transformed: SmPath = .{ .allocator = allocator };
    defer transformed.deinit();
    transformed.addPathTransform(path, &self.current_transform) catch return;
    self.clipInternal(&transformed, fill_rule);
}

fn clipInternal(self: *SmCanvas, path: *const SmPath, fill_rule: SmScan.FillRule) void {
    if (path.verbs.len == 0) return;
    const allocator = self.surface.getAllocator();
    const total: usize = @as(usize, self.surface.width) * @as(usize, self.surface.height);
    if (total == 0) return;
    // Rasterize the new clip path into a fresh zeroed buffer.
    const new_mask = allocator.alloc(u8, total) catch return;
    @memset(new_mask, 0);
    SmScan.fillPathToCoverage(
        allocator,
        new_mask,
        self.surface.width,
        self.surface.height,
        path,
        fill_rule,
        self.antialias,
    ) catch {
        allocator.free(new_mask);
        return;
    };
    if (self.clip_mask) |existing| {
        // Intersect multiplicatively: `(a * b + 127) / 255`. For prior
        // binary masks (legacy save/restore frames or pre-AA-clip data)
        // this still returns 0/0xFF correctly. AA clip boundaries combine
        // with AA shape coverage downstream via the same formula in
        // `SmBlitter.blitRow`.
        for (0..total) |i| {
            const a: u16 = @intCast(new_mask[i]);
            const b: u16 = @intCast(existing[i]);
            new_mask[i] = @intCast((a * b + 127) / 255);
        }
        allocator.free(existing);
    }
    self.clip_mask = new_mask;
}

// --- HTML5-shaped sugar (build a SmPaint from current ctx state) ---------
//
// Each helper bundles ctx state (fillStyle/strokeStyle/lineWidth + alpha +
// blendMode) into an SmPaint and calls the Skia-style draw method. The
// CTM is applied inside drawRect / drawTriangle.

pub fn clearRect(self: *SmCanvas, x: f64, y: f64, w: f64, h: f64) void {
    // clearRect bypasses globalAlpha and blend mode per HTML5 spec —
    // it always writes transparent black with `src` (overwrite).
    // (Transparent black is order-invariant; dst_color_type set for form.)
    const p: SmPaint = .{ .shader = .{ .solid = 0 }, .style = .fill, .blend_mode = .src, .dst_color_type = self.surface.color_type };
    self.drawRect(x, y, w, h, &p);
}

pub fn fillRect(self: *SmCanvas, x: f64, y: f64, w: f64, h: f64) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var p = self.paintForFill();
    self.drawRect(x, y, w, h, &p);
}

pub fn strokeRect(self: *SmCanvas, x: f64, y: f64, w: f64, h: f64) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var p = self.paintForStroke();
    self.drawRect(x, y, w, h, &p);
}

pub fn fillTriangle(
    self: *SmCanvas,
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var p = self.paintForFill();
    self.drawTriangle(x0, y0, x1, y1, x2, y2, &p);
}

pub fn strokeTriangle(
    self: *SmCanvas,
    x0: f64, y0: f64,
    x1: f64, y1: f64,
    x2: f64, y2: f64,
) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    // Build a 3-vertex closed path from the CTM-applied vertices and route
    // through the path-stroke pipeline. Honors lineCap / lineJoin /
    // miterLimit / setLineDash / lineDashOffset just like ctx.stroke().
    const p0 = self.current_transform.applyToPoint(x0, y0);
    const p1 = self.current_transform.applyToPoint(x1, y1);
    const p2 = self.current_transform.applyToPoint(x2, y2);
    const allocator = self.surface.getAllocator();
    var path = SmPath.emptyWithAllocator(allocator);
    defer path.deinit();
    path.moveTo(p0[0], p0[1]);
    path.lineTo(p1[0], p1[1]);
    path.lineTo(p2[0], p2[1]);
    path.closePath();
    // strokePath takes a fill-shaped paint (it inflates the outline polygon
    // and fills it through the same scan pipeline as fillPath).
    var paint = paintFromShader(self.strokeStyle, .fill, 0, self.alpha, self.blendMode, self.cxform, self.surface.color_type);
    paint.antialias = self.antialias;
    const aa = self.ensureAaScratch() orelse return;
    const clip_mask: ?[]const u8 = if (self.clip_mask) |m| m else null;
    SmScan.strokePath(
        allocator,
        self.pixels,
        self.surface.width,
        self.surface.height,
        &path,
        self.lineWidth,
        self.lineCap,
        self.lineJoin,
        self.miterLimit,
        self.line_dash_storage.ptr[0..self.line_dash_storage.len],
        self.lineDashOffset,
        clip_mask,
        &paint,
        aa.accum,
        aa.cov,
    ) catch {};
}

// --- getImageData family -------------------------------------------------

/// getImageData(sx, sy, sw, sh) — default-settings form.
pub fn getImageData(
    self: *const SmCanvas,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
) GetImageDataError!SmBitmap {
    return SmBitmap.fromSurfacePixelsOrdered(self.surface.getAllocator(), self.pixels, self.surface.width, self.surface.height, sx, sy, sw, sh, .{}, self.surface.color_type);
}

/// getImageData(sx, sy, sw, sh, settings) — settings form.
///
/// Behavior:
///   * Throws IndexSize if sw == 0 or sh == 0.
///   * Negative sw/sh reflect the rectangle toward -x / -y.
///   * Pixels outside the surface come back as transparent black.
///   * Not affected by any transformation matrix (we have none).
pub fn getImageDataSettings(
    self: *const SmCanvas,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    settings: types.BitmapSettings,
) GetImageDataError!SmBitmap {
    return SmBitmap.fromSurfacePixelsOrdered(self.surface.getAllocator(), self.pixels, self.surface.width, self.surface.height, sx, sy, sw, sh, settings, self.surface.color_type);
}

// --- drawImage family (Skia drawImage / drawImageRect) -------------------
//
// Three Zig methods cover the WebIDL drawImage overload set. Each builds an
// inverse transform that maps canvas pixel → source pixel (combining
// CTM⁻¹ with the dst-rect-to-src-rect mapping), scans the dst rect's
// transformed bbox, and samples row-by-row through `simd.sampleImageNearestRow`.
//
// Step 1 scope: rgba_unorm8 source, nearest-neighbor sampling, no
// globalAlpha or blend integration (writes verbatim — `.src` semantics).
// Bilinear filtering and Blitter-integrated blending land later as separate
// kernels and a SmPaint source-kind.

/// drawImage(image, dx, dy) — paint the entire bitmap at (dx, dy) in
/// pre-CTM canvas coords, native size.
pub fn drawImageAt(self: *SmCanvas, bitmap: SmBitmap, dx: f64, dy: f64) void {
    self.drawImageScaledSub(
        bitmap,
        0, 0,
        @floatFromInt(bitmap.width),
        @floatFromInt(bitmap.height),
        dx, dy,
        @floatFromInt(bitmap.width),
        @floatFromInt(bitmap.height),
    );
}

/// drawImage(image, dx, dy, dw, dh) — paint entire bitmap, scaled into
/// the (dx, dy, dw, dh) dst rect.
pub fn drawImageScaled(
    self: *SmCanvas,
    bitmap: SmBitmap,
    dx: f64, dy: f64, dw: f64, dh: f64,
) void {
    self.drawImageScaledSub(
        bitmap,
        0, 0,
        @floatFromInt(bitmap.width),
        @floatFromInt(bitmap.height),
        dx, dy, dw, dh,
    );
}

/// drawImage(image, sx, sy, sw, sh, dx, dy, dw, dh) — paint a sub-rect of
/// the source bitmap into the (dx, dy, dw, dh) dst rect. Both rects are in
/// pre-CTM canvas coords; the CTM transforms the dst rect at draw time.
pub fn drawImageScaledSub(
    self: *SmCanvas,
    bitmap: SmBitmap,
    sx: f64, sy: f64, sw: f64, sh: f64,
    dx: f64, dy: f64, dw: f64, dh: f64,
) void {
    if (bitmap.pixelFormat != .rgba_unorm8) return;
    if (bitmap.width == 0 or bitmap.height == 0) return;
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;

    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    // Open a composite layer for non-row-friendly blend modes (src-in,
    // src-out, dst-in, dst-atop, copy) — they need to see the whole canvas
    // to produce the right "outside the shape" result. Inside the layer
    // self.blendMode is forced to src_over, so the sampled image lands on
    // a transparent scratch with src_over; endCompositeLayer composites
    // back through the user's actual mode via `blitFull`.
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);

    // ---- Build inv_transform: canvas pixel → source pixel. -------------
    // Forward: src_pixel → canvas_pixel = CTM(src_to_dst(src))
    //   src_to_dst maps (sx_p, sy_p) → (dx + (sx_p - sx)*dw/sw, dy + (sy_p - sy)*dh/sh)
    // Inverse: canvas_pixel → src_pixel = src_to_dst⁻¹(CTM⁻¹(canvas))
    //
    // Step a: invert CTM. Singular CTM → bail.
    var ctm_inv = self.current_transform;
    _ = ctm_inv.invertSelf();
    if (std.math.isNan(ctm_inv.a)) return;

    // Step b: src_to_dst⁻¹. The forward dst_from_src is scale(dw/sw, dh/sh)
    // followed by translate(dx - sx*dw/sw, dy - sy*dh/sh). Its inverse is
    // scale(sw/dw, sh/dh) followed by translate(sx - dx*sw/dw, sy - dy*sh/dh).
    const sw_dw = sw / dw;
    const sh_dh = sh / dh;
    var src_to_dst_inv = SmMatrix{
        .a = sw_dw,
        .b = 0,
        .c = 0,
        .d = sh_dh,
        .e = sx - dx * sw_dw,
        .f = sy - dy * sh_dh,
    };

    // Step c: compose. SmMatrix.multiplySelf(other) does self = self · other,
    // i.e. result.applyToPoint(p) == self.applyToPoint(other.applyToPoint(p)).
    // We want inv_transform.applyToPoint(canvas) == src_to_dst_inv(ctm_inv(canvas)),
    // so inv_transform = src_to_dst_inv * ctm_inv. Apply ctm_inv first.
    _ = src_to_dst_inv.multiplySelf(&ctm_inv);
    const inv = src_to_dst_inv;

    // ---- Compute bbox of CTM-transformed dst rect corners. -------------
    const c0 = self.current_transform.applyToPoint(dx, dy);
    const c1 = self.current_transform.applyToPoint(dx + dw, dy);
    const c2 = self.current_transform.applyToPoint(dx + dw, dy + dh);
    const c3 = self.current_transform.applyToPoint(dx, dy + dh);
    var bbox_x0 = @min(@min(c0[0], c1[0]), @min(c2[0], c3[0]));
    var bbox_y0 = @min(@min(c0[1], c1[1]), @min(c2[1], c3[1]));
    var bbox_x1 = @max(@max(c0[0], c1[0]), @max(c2[0], c3[0]));
    var bbox_y1 = @max(@max(c0[1], c1[1]), @max(c2[1], c3[1]));

    // ---- Clip bbox to canvas. ------------------------------------------
    const cw_f: f64 = @floatFromInt(self.surface.width);
    const ch_f: f64 = @floatFromInt(self.surface.height);
    bbox_x0 = @max(0, @floor(bbox_x0));
    bbox_y0 = @max(0, @floor(bbox_y0));
    bbox_x1 = @min(cw_f, @ceil(bbox_x1));
    bbox_y1 = @min(ch_f, @ceil(bbox_y1));
    if (bbox_x0 >= bbox_x1 or bbox_y0 >= bbox_y1) return;

    const dst_x0_i: i32 = @intFromFloat(bbox_x0);
    const dst_y0_i: i32 = @intFromFloat(bbox_y0);
    const dst_x1_i: i32 = @intFromFloat(bbox_x1);
    const dst_y1_i: i32 = @intFromFloat(bbox_y1);
    const row_len: usize = @intCast(dst_x1_i - dst_x0_i);

    const src_pixels: [*]const u32 = @ptrCast(@alignCast(bitmap.data.ptr));

    // ---- Scan rows; sample image into a row scratch, then composite. ---
    // Per-row src scratch buffer — small stack array for typical canvas
    // widths, heap fallback for wider rows. Mirrors the snapshot pattern
    // the legacy clip-aware drawImage used.
    const clip_mask = self.clip_mask;
    const allocator = self.surface.getAllocator();
    var stack_src: [1024]u32 = undefined;
    const heap_src: ?[]u32 = if (row_len > stack_src.len) (allocator.alloc(u32, row_len) catch null) else null;
    defer if (heap_src) |h| allocator.free(h);
    const src_buf: []u32 = if (heap_src) |h| h else stack_src[0..row_len];

    // Build a paint that carries the current ctx state. `blitRowFromSource`
    // ignores `paint.shader` (per-pixel src is in `src_buf`); it uses
    // `paint.blend_mode` and `paint.global_alpha` only. Inside the
    // composite layer (above), `self.blendMode` is `.src_over` for
    // non-row-friendly modes — the layer composites back via the user's
    // real mode, so per-pixel here always writes through src_over.
    const draw_paint: SmPaint = .{
        .shader = .{ .solid = 0 },
        .style = .fill,
        .blend_mode = self.blendMode,
        .global_alpha = self.alpha,
        .cxform = self.cxform, // tints sampled image rows per pixel
        .dst_color_type = self.surface.color_type,
    };

    var py: i32 = dst_y0_i;
    while (py < dst_y1_i) : (py += 1) {
        const row_off: usize =
            @as(usize, @intCast(py)) * @as(usize, self.surface.width) +
            @as(usize, @intCast(dst_x0_i));
        const dst_row = self.pixels[row_off..][0..row_len];

        // Zero the scratch — `sampleImageRow` skips out-of-source-rect
        // pixels rather than writing transparent, so prior-row residue
        // would leak otherwise.
        @memset(src_buf, 0);
        sampleImageRow(
            self.imageSmoothingEnabled,
            src_buf,
            src_pixels,
            bitmap.width,
            bitmap.height,
            sx, sy, sw, sh,
            inv.a, inv.b, inv.c, inv.d, inv.e, inv.f,
            dst_x0_i,
            py,
        );

        const clip_row: ?[]const u8 = if (clip_mask) |cm| cm[row_off..][0..row_len] else null;
        SmBlitter.blitRowFromSource(dst_row, src_buf, &draw_paint, clip_row);
    }
}

/// Pick between bilinear (smoothing on) and nearest (smoothing off) row
/// samplers. Tiny indirection so the two call sites stay symmetric.
inline fn sampleImageRow(
    smoothing: bool,
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
    if (smoothing) {
        simd.sampleImageBilinearRow(
            dst, src_pixels, src_w, src_h,
            src_rect_x, src_rect_y, src_rect_w, src_rect_h,
            inv_a, inv_b, inv_c, inv_d, inv_e, inv_f,
            x_start, y,
        );
    } else {
        simd.sampleImageNearestRow(
            dst, src_pixels, src_w, src_h,
            src_rect_x, src_rect_y, src_rect_w, src_rect_h,
            inv_a, inv_b, inv_c, inv_d, inv_e, inv_f,
            x_start, y,
        );
    }
}

// --- writePixels family (HTML5 putImageData) -----------------------------
//
// Mirrors Skia's `SkCanvas::writePixels`. Bypasses the CTM, globalAlpha,
// and blend mode per HTML5 putImageData spec — pixels are copied verbatim
// from the source bitmap to the canvas. JS exposes both forms as
// `ctx.putImageData(...)` via a 3-arg / 7-arg dispatcher in `src/index.ts`.

/// writePixels(bitmap, dx, dy) — copy the entire bitmap to canvas at (dx, dy).
/// Equivalent to `writePixelsDirty(bitmap, dx, dy, 0, 0, bitmap.width, bitmap.height)`.
pub fn writePixels(self: *SmCanvas, bitmap: SmBitmap, dx: i32, dy: i32) void {
    self.writePixelsDirty(
        bitmap,
        dx, dy,
        0, 0,
        @intCast(bitmap.width),
        @intCast(bitmap.height),
    );
}

/// writePixelsDirty(...) — copy a sub-rect (`dirty_x, dirty_y, dirty_w,
/// dirty_h`, in **bitmap-local** coords) of the source bitmap onto the
/// canvas, with the bitmap's (0,0) anchored at canvas (`dx`, `dy`).
/// Negative dirty dimensions reflect; dirty rect is clipped silently to
/// both bitmap and canvas bounds.
pub fn writePixelsDirty(
    self: *SmCanvas,
    bitmap: SmBitmap,
    dx: i32, dy: i32,
    dirty_x: i32, dirty_y: i32,
    dirty_w: i32, dirty_h: i32,
) void {
    // Step 1 only handles rgba_unorm8. Float16 needs the symmetric
    // `copyFloat16NormToU32` SIMD kernel — a future addition.
    if (bitmap.pixelFormat != .rgba_unorm8) return;
    if (bitmap.width == 0 or bitmap.height == 0) return;

    // Normalize negative dirty dims (HTML5 putImageData reflects them).
    var dx_lo = dirty_x;
    var dy_lo = dirty_y;
    var dx_hi = dirty_x + dirty_w;
    var dy_hi = dirty_y + dirty_h;
    if (dx_hi < dx_lo) {
        const t = dx_lo;
        dx_lo = dx_hi;
        dx_hi = t;
    }
    if (dy_hi < dy_lo) {
        const t = dy_lo;
        dy_lo = dy_hi;
        dy_hi = t;
    }

    // Intersect with bitmap bounds (in source / bitmap-local coords).
    const bw: i32 = @intCast(bitmap.width);
    const bh: i32 = @intCast(bitmap.height);
    const src_x0 = @max(0, dx_lo);
    const src_y0 = @max(0, dy_lo);
    const src_x1 = @min(bw, dx_hi);
    const src_y1 = @min(bh, dy_hi);
    if (src_x0 >= src_x1 or src_y0 >= src_y1) return;

    // Map to canvas coords; clamp to canvas bounds.
    const cw: i32 = @intCast(self.surface.width);
    const ch: i32 = @intCast(self.surface.height);
    const dst_x0_raw = dx + src_x0;
    const dst_y0_raw = dy + src_y0;
    const dst_x1_raw = dx + src_x1;
    const dst_y1_raw = dy + src_y1;
    const dst_x0 = @max(0, dst_x0_raw);
    const dst_y0 = @max(0, dst_y0_raw);
    const dst_x1 = @min(cw, dst_x1_raw);
    const dst_y1 = @min(ch, dst_y1_raw);
    if (dst_x0 >= dst_x1 or dst_y0 >= dst_y1) return;

    // If dst was clamped, advance src start to compensate.
    const src_x_start: i32 = src_x0 + (dst_x0 - dst_x0_raw);
    const src_y_start: i32 = src_y0 + (dst_y0 - dst_y0_raw);
    const copy_w: usize = @intCast(dst_x1 - dst_x0);
    const row_count: i32 = dst_y1 - dst_y0;

    const src_pixels: [*]const u32 = @ptrCast(@alignCast(bitmap.data.ptr));
    const src_stride: usize = bitmap.width;
    const dst_stride: usize = self.surface.width;

    var row: i32 = 0;
    while (row < row_count) : (row += 1) {
        const src_row_idx: usize = @intCast(src_y_start + row);
        const dst_row_idx: usize = @intCast(dst_y0 + row);
        const src_col: usize = @intCast(src_x_start);
        const dst_col: usize = @intCast(dst_x0);
        const src_slice = (src_pixels + src_row_idx * src_stride + src_col)[0..copy_w];
        const dst_slice = self.pixels[dst_row_idx * dst_stride + dst_col ..][0..copy_w];
        switch (self.surface.color_type) {
            // Bitmap bytes are RGBA (WHATWG); fold into surface order.
            .rgba8888 => simd.copyU32(dst_slice, src_slice),
            .bgra8888 => simd.swizzleRBCopyU32(dst_slice, src_slice),
        }
    }
}

// Free the backing buffer of a SmBitmap previously returned by getImageData.
// Required because node-zigar does not own this page-allocator allocation.
// The self parameter is unused; it only exists so node-zigar binds this as
// an instance method.
//
// Method name keeps the HTML5 spelling (`releaseImageData`) so JS callers can
// invoke it directly through the SmCanvas proxy without a wrapper.
pub fn releaseImageData(self: *const SmCanvas, bitmap: SmBitmap) void {
    self.surface.getAllocator().free(bitmap.data);
}

// --- Text drawing (Sm-prefixed primitive — HTML5 façade in src/index.ts) ---

/// drawText(text_utf8, x, y, font, paint) — rasterize each codepoint of
/// `text_utf8` through the font and composite alpha rows into the surface
/// via `SmBlitter.blitRow` with per-pixel coverage. The glyph alpha row
/// IS the coverage row — the same plumbing AA path-fills will use.
///
/// Coordinate convention: `(x, y)` is the pen position, with `y` on the
/// glyph baseline (HTML5 `'alphabetic'` baseline). The HTML5 surface in
/// `src/index.ts` adjusts `y` for `textBaseline` and `x` for `textAlign`
/// before calling.
///
/// CTM v1: only the translation component (`e`, `f`) of the current matrix
/// is applied to the pen — glyph bitmaps render axis-aligned at the font's
/// configured pixel size. Scale / rotation in the CTM are intentionally
/// dropped here (proper handling needs subpixel rasterization or path-
/// based glyphs; tracked as a follow-up).
pub fn drawText(
    self: *SmCanvas,
    text_utf8: []const u8,
    x: f64,
    y: f64,
    font: *SmFont,
    paint: *const SmPaint,
) void {
    self.drawTextWithSpacing(text_utf8, x, y, font, paint, 0, 0, false);
}

/// drawTextWithSpacing(text, x, y, font, paint, letter_px, word_px, kern)
/// — text drawing with CSS letter-spacing / word-spacing / kerning applied
/// at shaping time. Underlying rasterization is identical to `drawText`;
/// the spacing is encoded in the per-glyph `dx` offsets emitted by
/// `SmTextRun.shapeWithSpacing`.
pub fn drawTextWithSpacing(
    self: *SmCanvas,
    text_utf8: []const u8,
    x: f64,
    y: f64,
    font: *SmFont,
    paint: *const SmPaint,
    letter_spacing_px: f64,
    word_spacing_px: f64,
    kerning_on: bool,
) void {
    var run = SmTextRun.shapeWithSpacing(
        self.surface.getAllocator(),
        text_utf8,
        font,
        letter_spacing_px,
        word_spacing_px,
        kerning_on,
    ) catch return;
    defer run.deinit();
    self.drawTextRun(&run, x, y, font, paint);
}

/// drawTextRun(run, x, y, font, paint) — render a pre-shaped text run.
/// Splits the rendering loop out of `drawText` so the shaping output (an
/// `SmTextRun`) can be cached, transformed, or constructed bypass-shaping
/// (e.g. for SVG-glyph emit). Glyph rasterization happens here because the
/// glyph cache lives on `SmFont` and stays render-side.
pub fn drawTextRun(
    self: *SmCanvas,
    run: *const SmTextRun,
    x: f64,
    y: f64,
    font: *SmFont,
    paint: *const SmPaint,
) void {
    // Apply CTM translation only (see drawText docstring caveat).
    const m = self.current_transform;
    const pen_x0: f64 = m.a * x + m.c * y + m.e;
    const pen_y0: f64 = m.b * x + m.d * y + m.f;

    const cw: i32 = @intCast(self.surface.width);
    const ch: i32 = @intCast(self.surface.height);

    // Faux-italic shear: tan(12°). Standard CSS oblique-fallback angle
    // and what Chromium / Firefox apply when synthesising italic for a
    // family that has no italic face.
    const italic_shear: f64 = if (font.synth_italic) 0.21256 else 0;

    for (run.glyphs.items()) |g| {
        const bm = font.rasterizeGlyph(g.index) catch continue;
        if (bm.width == 0 or bm.height == 0) continue;

        const pen_x = pen_x0 + g.dx;
        const pen_y = pen_y0 + g.dy;
        const top_x: i32 = @as(i32, @intFromFloat(@floor(pen_x))) + bm.offsetX;
        const top_y: i32 = @as(i32, @intFromFloat(@floor(pen_y))) + bm.offsetY;

        var row: u32 = 0;
        while (row < bm.height) : (row += 1) {
            const dst_y: i32 = top_y + @as(i32, @intCast(row));
            if (dst_y < 0 or dst_y >= ch) continue;

            // For faux-italic we shift each row by the shear * distance from
            // baseline. `bm.offsetY + row` is the row's y in stb's
            // baseline-relative coords (negative = above baseline). We want
            // above-baseline rows to lean right → shift = -shear * (bm.offsetY + row).
            var row_top_x: i32 = top_x;
            if (italic_shear != 0) {
                const baseline_y: f64 = @floatFromInt(bm.offsetY + @as(i32, @intCast(row)));
                row_top_x += @as(i32, @intFromFloat(@round(-italic_shear * baseline_y)));
            }

            // Clip horizontally.
            const x_lo_world: i32 = @max(0, row_top_x);
            const x_hi_world: i32 = @min(cw, row_top_x + @as(i32, @intCast(bm.width)));
            if (x_hi_world <= x_lo_world) continue;
            const skip_left: u32 = @intCast(x_lo_world - row_top_x);
            const span_n: u32 = @intCast(x_hi_world - x_lo_world);

            const row_start: usize = @as(usize, row) * @as(usize, bm.width) + @as(usize, skip_left);
            const cov_slice = bm.pixels[row_start .. row_start + @as(usize, span_n)];

            SmBlitter.blitRow(
                self.pixels,
                self.surface.width,
                x_lo_world,
                dst_y,
                span_n,
                cov_slice,
                paint,
                if (self.clip_mask) |cm| cm else null,
            );
        }
    }
}

/// fillText(text, x, y, font) — HTML5 sugar that bundles the current
/// fillStyle / globalAlpha / globalCompositeOperation into a SmPaint and
/// delegates to `drawText`. Mirrors the `fillRect` ↔ `drawRect` shape.
pub fn fillText(self: *SmCanvas, text_utf8: []const u8, x: f64, y: f64, font: *SmFont) void {
    self.fillTextWithSpacing(text_utf8, x, y, font, 0, 0, false);
}

/// fillTextWithSpacing — HTML5 sugar that takes CSS letter-spacing /
/// word-spacing (in pixels) and a kerning toggle, then bundles the
/// current fill state into a SmPaint and delegates to
/// `drawTextWithSpacing`. The JS `CanvasRenderingContext2D.fillText`
/// dispatches here when any of those are non-default.
pub fn fillTextWithSpacing(
    self: *SmCanvas,
    text_utf8: []const u8,
    x: f64,
    y: f64,
    font: *SmFont,
    letter_spacing_px: f64,
    word_spacing_px: f64,
    kerning_on: bool,
) void {
    const filter = self.beginFilterLayer();
    defer self.endFilterLayer(filter);
    const shadow = self.beginShadowLayer();
    defer self.endShadowLayer(shadow);
    const layer = self.beginCompositeLayer();
    defer self.endCompositeLayer(layer);
    var paint = self.paintForFill();
    self.drawTextWithSpacing(
        text_utf8,
        x,
        y,
        font,
        &paint,
        letter_spacing_px,
        word_spacing_px,
        kerning_on,
    );
}
