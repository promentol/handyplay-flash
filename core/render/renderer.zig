//! Display-list renderer: walks the clip tree back-to-front and draws
//! distilled shape paths through simdra. Coordinates flow as twips with
//! the combined (stage ∘ placement chain) matrix set as the canvas CTM —
//! the ÷20 twips→px conversion lives in the stage scale.
//!
//! M2 scope: shapes with solid/linear/radial/focal-gradient fills and
//! solid strokes; cxform via simdra's per-paint ColorTransform (identical
//! layout to the parsed CXFORM). Bitmap fills/text/buttons arrive in M4,
//! morphs/masks in M7 (mask objects are skipped rather than drawn).
//!
//! Gradient geometry: SWF gradients live in a 32768×32768-twip "gradient
//! square" (±16384) mapped by the style's matrix; simdra gradients sample
//! in device space, so the gradient-space anchor points are pushed through
//! the full combined matrix here.

const std = @import("std");
const simdra = @import("simdra");
const swf = @import("../swf/swf.zig");
const shape_utils = @import("shape_utils.zig");
const canvas_mod = @import("canvas.zig");
const display_object = @import("../display/display_object.zig");
const movie_clip = @import("../display/movie_clip.zig");
const drawing = @import("../display/drawing.zig");
const library = @import("../display/library.zig");
const text_mod = @import("../display/text.zig");
const edit_text = @import("../display/edit_text.zig");
const display_font = @import("../display/font.zig");
const edit_text_device = @import("../display/device_font.zig");
const text_layout = @import("../display/text_layout.zig");
const bounds_mod = @import("../display/bounds.zig");
const bitmap_decode = @import("../bitmap/decode.zig");
const bitmap_data = @import("../bitmap/data.zig");
const bitmap_pixels = @import("../bitmap/pixels.zig");
const bitmap_ops = @import("../bitmap/operations.zig");

pub const Error = std.mem.Allocator.Error || error{OutOfMemory};

/// f64 affine in twip space; device = (a·x + c·y + tx, b·x + d·y + ty).
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,

    pub fn concat(p: Transform, m: swf.reader.Matrix) Transform {
        const ctx: f64 = @floatFromInt(m.tx);
        const cty: f64 = @floatFromInt(m.ty);
        return .{
            .a = p.a * m.a + p.c * m.b,
            .b = p.b * m.a + p.d * m.b,
            .c = p.a * m.c + p.c * m.d,
            .d = p.b * m.c + p.d * m.d,
            .tx = p.a * ctx + p.c * cty + p.tx,
            .ty = p.b * ctx + p.d * cty + p.ty,
        };
    }

    pub fn apply(t: Transform, x: f64, y: f64) [2]f64 {
        return .{ t.a * x + t.c * y + t.tx, t.b * x + t.d * y + t.ty };
    }
};

const concatCxform = swf.reader.ColorTransform.concat;

fn toSimdraCxform(t: swf.reader.ColorTransform) simdra.SmPaint.ColorTransform {
    return .{ .mult = t.mult, .add = t.add };
}

pub const Renderer = struct {
    /// Distilled-path cache, keyed by character id. Allocated from the
    /// movie arena (lives exactly as long as the shapes it references).
    cache: std.AutoHashMapUnmanaged(u16, []shape_utils.DrawPath) = .empty,
    /// The same, for GLYPHS. A separate map because the key is
    /// `(font_id, glyph_index)` and a font id would collide with a shape's
    /// character id in the map above.
    glyph_cache: std.AutoHashMapUnmanaged(u64, []shape_utils.DrawPath) = .empty,
    arena: std.mem.Allocator,
    /// Needed to resolve a text record's font id. Assigned by the Player
    /// AFTER construction — `Renderer.init` runs inside the Player's own
    /// struct literal, where `&self.movie` is not yet valid.
    lib: ?*const library.Library = null,
    /// The field that currently has FOCUS, if any. A caret needs it and
    /// so does the selection colour. Set by the Player each frame.
    focused_field: ?*const edit_text.EditText = null,
    /// Milliseconds since the movie started, for the caret's blink.
    now_ms: f64 = 0,
    /// Text layout is version-dependent (wrapping, alignment), so the
    /// renderer needs the movie's version to rebuild a stale one.
    swf_version: u8 = 8,
    /// The DISPLAY allocator, not the movie arena: a field's layout is
    /// owned by the field and freed when it is, so it must come from the
    /// same place everything else the field owns does.
    display_gpa: ?std.mem.Allocator = null,
    /// The movie-level JPEGTables (8) stream, which `DefineBits` needs
    /// spliced in front of its own scan data. Set by the Player.
    jpeg_tables: ?[]const u8 = null,
    /// Bitmap characters, decoded ONCE. A null value is a character that
    /// failed to decode — remembered so a broken image is not re-decoded
    /// on every frame it appears in.
    bitmaps: std.AutoHashMapUnmanaged(u16, ?bitmap_decode.Image) = .empty,
    /// Ready-to-sample patterns, keyed by character id plus the two style
    /// bits that change how the texels are read. The transform is set per
    /// use; the pixels are shared.
    patterns: std.AutoHashMapUnmanaged(u64, simdra.SmPattern) = .empty,
    /// The stage transform of the frame being drawn. A `setMask` target
    /// is reached from outside the walk, so its own place in the tree has
    /// to be measured from here.
    stage_t: Transform = .{},

    pub fn init(movie_arena: std.mem.Allocator) Renderer {
        return .{ .arena = movie_arena };
    }

    /// Where a bitmap's pixels come from. A library character is decoded
    /// once and never changes; a script `BitmapData` is live and may have
    /// been written since the last frame, so its pattern is refreshed on
    /// every use.
    pub const BitmapSource = union(enum) {
        character: u16,
        live: *const bitmap_data.BitmapData,
    };

    /// A character's pixels, decoded once. Null when the id is not a
    /// bitmap or the payload would not decode.
    fn decodedBitmap(self: *Renderer, id: u16) ?*const bitmap_decode.Image {
        const gop = self.bitmaps.getOrPut(self.arena, id) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = blk: {
                const lib = self.lib orelse break :blk null;
                const ch = lib.characters.get(id) orelse break :blk null;
                const bmp = switch (ch) {
                    .bitmap => |b| b,
                    else => break :blk null,
                };
                break :blk bitmap_decode.decode(self.arena, bmp, self.jpeg_tables) catch null;
            };
        }
        return if (gop.value_ptr.*) |*img| img else null;
    }

    fn sizeOfSource(self: *Renderer, src: BitmapSource) ?[2]u32 {
        return switch (src) {
            .character => |id| if (self.decodedBitmap(id)) |img| .{ img.width, img.height } else null,
            .live => |bd| if (bd.width == 0 or bd.height == 0) null else .{ bd.width, bd.height },
        };
    }

    /// The pattern for a bitmap fill, keyed by its source and the two
    /// style bits that change how the texels are read. Library pixels are
    /// uploaded once; live ones are re-read every time, because script
    /// may have painted into the buffer between frames.
    fn pattern(self: *Renderer, src: BitmapSource, repeating: bool, smoothed: bool) Error!?*simdra.SmPattern {
        const base: u64 = switch (src) {
            .character => |id| id,
            .live => |bd| @intFromPtr(bd),
        };
        const key = (base << 2) |
            (@as(u64, @intFromBool(repeating)) << 1) |
            @intFromBool(smoothed);
        const size = self.sizeOfSource(src) orelse return null;

        const gop = try self.patterns.getOrPut(self.arena, key);
        errdefer _ = self.patterns.remove(key);
        // A live buffer can be resized (or disposed and rebuilt) under a
        // pattern that was cached for the old dimensions.
        const stale = gop.found_existing and
            (gop.value_ptr.width != size[0] or gop.value_ptr.height != size[1]);
        if (!gop.found_existing or stale) {
            if (stale) gop.value_ptr.deinit();
            const blank = try self.arena.alloc(u8, @as(usize, size[0]) * size[1] * 4);
            defer self.arena.free(blank);
            @memset(blank, 0);
            gop.value_ptr.* = simdra.SmPattern.createWithAllocator(
                self.arena,
                blank,
                size[0],
                size[1],
                if (repeating) .repeat else .no_repeat,
            ) catch {
                _ = self.patterns.remove(key);
                return null;
            };
            gop.value_ptr.setFilter(if (smoothed) .bilinear else .nearest);
        }

        switch (src) {
            .character => |id| if (!gop.found_existing or stale) {
                const img = self.decodedBitmap(id) orelse return null;
                if (img.premultiplied) {
                    // A pattern samples STRAIGHT RGBA, so a tag that
                    // stored premultiplied colour has to be converted.
                    //
                    // `Color`'s channel NAMES do not line up here: the
                    // bytes are R,G,B,A and `fromArgb` reads the low byte
                    // as `.b`, so `.b` holds R and `.r` holds B. Only
                    // `.a` has to be right, because the un-premultiply
                    // applies one factor to all three — and it is.
                    for (0..@as(usize, size[0]) * size[1]) |i| {
                        const u = bitmap_pixels.Color.fromArgb(
                            std.mem.readInt(u32, img.rgba[i * 4 ..][0..4], .little),
                        ).toUnmultiplied();
                        gop.value_ptr.data[i * 4 + 0] = u.b;
                        gop.value_ptr.data[i * 4 + 1] = u.g;
                        gop.value_ptr.data[i * 4 + 2] = u.r;
                        gop.value_ptr.data[i * 4 + 3] = u.a;
                    }
                } else {
                    @memcpy(gop.value_ptr.data, img.rgba);
                }
            },
            // Storage is premultiplied and a pattern samples straight
            // RGBA, so every pixel converts on the way out.
            .live => |bd| for (bd.data, 0..) |c, i| {
                const u = c.toUnmultiplied();
                gop.value_ptr.data[i * 4 + 0] = u.r;
                gop.value_ptr.data[i * 4 + 1] = u.g;
                gop.value_ptr.data[i * 4 + 2] = u.b;
                gop.value_ptr.data[i * 4 + 3] = if (bd.transparency) u.a else 255;
            },
        }
        return gop.value_ptr;
    }

    /// One source texel, in Flash's PREMULTIPLIED storage form.
    fn sourceTexel(src: BitmapSource, img: ?*const bitmap_decode.Image, i: usize) bitmap_pixels.Color {
        return switch (src) {
            .live => |bd| bd.data[i],
            .character => blk: {
                const im = img.?;
                const c = bitmap_pixels.Color.rgba(
                    im.rgba[i * 4 + 0],
                    im.rgba[i * 4 + 1],
                    im.rgba[i * 4 + 2],
                    im.rgba[i * 4 + 3],
                );
                break :blk if (im.premultiplied) c else c.toPremultipliedTruncating();
            },
        };
    }

    /// Flash BLITS a bitmap that lands square on the pixel grid, and its
    /// blend is not the rasteriser's: it composites PREMULTIPLIED values
    /// with a truncating divide, where a pattern fill un-premultiplies
    /// into straight RGBA, blends, and un-premultiplies again. The two
    /// disagree by a unit, which a tolerance-zero image test sees.
    ///
    /// Returns false when any of the conditions fail, and the caller
    /// falls back to the general path.
    fn blitBitmap(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        src: BitmapSource,
        size: [2]u32,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) bool {
        // One device pixel per texel, axis-aligned, on whole pixels, with
        // nothing else the canvas would have to apply.
        if (t.b != 0 or t.c != 0) return false;
        if (t.a * 20 != 1 or t.d * 20 != 1) return false;
        if (@floor(t.tx) != t.tx or @floor(t.ty) != t.ty) return false;
        if (!cx.isIdentity()) return false;
        if (ctx.clip_mask != null or ctx.alpha != 0xFF) return false;
        if (ctx.blendMode != .src_over) return false;

        const img: ?*const bitmap_decode.Image = switch (src) {
            .character => |id| self.decodedBitmap(id) orelse return false,
            .live => null,
        };
        const dst_w: i64 = ctx.surface.width;
        const dst_h: i64 = ctx.surface.height;
        const ox: i64 = @intFromFloat(t.tx);
        const oy: i64 = @intFromFloat(t.ty);

        var y: i64 = 0;
        while (y < size[1]) : (y += 1) {
            const dy = oy + y;
            if (dy < 0 or dy >= dst_h) continue;
            var x: i64 = 0;
            while (x < size[0]) : (x += 1) {
                const dx = ox + x;
                if (dx < 0 or dx >= dst_w) continue;
                const s = sourceTexel(src, img, @intCast(y * @as(i64, size[0]) + x));
                if (s.a == 0) continue;
                const slot = &ctx.pixels[@intCast(dy * dst_w + dx)];
                if (s.a == 255) {
                    slot.* = s.toArgb();
                    continue;
                }
                // The surface holds STRAIGHT colour, so a translucent
                // destination converts around the blend. The stage is
                // opaque, where both conversions are the identity.
                const d = bitmap_pixels.Color.fromArgb(slot.*);
                const under = if (d.a == 255) d else d.toPremultiplied(true);
                const out = bitmap_ops.blendOverSaturating(under, s);
                slot.* = (if (out.a == 255) out else out.toUnmultiplied()).toArgb();
            }
        }
        return true;
    }

    /// A bitmap placed DIRECTLY on the display list — no shape, no fill
    /// style. Flash draws it as its own pixel rectangle at one twip-scaled
    /// pixel per texel, which is the same job as a bitmap fill over a
    /// box the size of the image.
    fn renderBitmap(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        src: BitmapSource,
        smoothing: bool,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        const size = self.sizeOfSource(src) orelse return;
        if (self.blitBitmap(ctx, src, size, t, cx)) return;
        const pat = try self.pattern(src, false, smoothing) orelse return;
        pat.setTransform(t.a * 20, t.b * 20, t.c * 20, t.d * 20, t.tx, t.ty);

        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(toSimdraCxform(cx));
        ctx.setFillPattern(pat);
        boxPath(ctx, 0, 0, @as(f64, @floatFromInt(size[0])) * 20, @as(f64, @floatFromInt(size[1])) * 20);
        ctx.fill(.nonzero);
    }

    fn distilledGlyph(
        self: *Renderer,
        font_id: u16,
        glyph_index: u32,
        glyph: *const swf.font_text.Glyph,
    ) Error![]shape_utils.DrawPath {
        const key = (@as(u64, font_id) << 32) | glyph_index;
        const gop = try self.glyph_cache.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            const shape = swf.font_text.glyphShape(glyph);
            gop.value_ptr.* = try shape_utils.distill(self.arena, &shape);
        }
        return gop.value_ptr.*;
    }

    fn distilled(self: *Renderer, id: u16, shape: *const swf.shape.Shape) Error![]shape_utils.DrawPath {
        const gop = try self.cache.getOrPut(self.arena, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = try shape_utils.distill(self.arena, shape);
        }
        return gop.value_ptr.*;
    }

    /// Render one frame: clear to the background, then walk the tree.
    /// `root_placement` carries the root clip's own transform — the root
    /// has no parent to hold it, but `_root._x`/`_alpha`/`_visible` are
    /// writable, so it is applied here between the stage and the tree.
    pub fn renderFrame(
        self: *Renderer,
        canvas: *canvas_mod.Canvas,
        root: *const movie_clip.MovieClip,
        root_placement: *const display_object.DisplayObject,
        /// `_level1` and up, HIGHEST FIRST — the Player's own order.
        levels: []const *display_object.DisplayObject,
        background: swf.reader.Color,
        stage: Transform,
    ) !void {
        // Opaque background (logical RGBA → surface order fill).
        const bg = background | 0xFF000000;
        simdra.simd.fillU32(canvas.surface.pixels, simdra.simd.swizzleRB(bg));
        if (!root_placement.visible) return;
        self.stage_t = stage;
        const ctx = try canvas.ctx();
        try self.renderClip(
            ctx,
            root,
            stage.concat(root_placement.matrix),
            root_placement.color_transform,
        );
        // `_level1` and up sit ON TOP of the root, lowest level first.
        var i = levels.len;
        while (i > 0) {
            i -= 1;
            const lv = levels[i];
            if (!lv.visible) continue;
            try self.renderObject(ctx, lv, stage.concat(lv.matrix), lv.color_transform);
        }
        ctx.setColorTransform(.{}); // leave ctx state clean
    }

    /// SWF blend-mode number → simdra. The numbering is PlaceObject3's
    /// and `BitmapData.draw` takes the same set, so this is the one place
    /// the mapping lives. `layer` is source-over until compositing layers
    /// exist; every other mode simdra implements outright, including the
    /// four Flash-only ones.
    pub fn blendModeFromSwf(n: u8) simdra.SmPaint.BlendMode {
        return switch (n) {
            3 => .multiply,
            4 => .screen,
            5 => .lighten,
            6 => .darken,
            7 => .difference,
            8 => .add,
            9 => .flash_subtract,
            10 => .flash_invert,
            11 => .flash_alpha,
            12 => .flash_erase,
            13 => .overlay,
            14 => .hard_light,
            else => .src_over,
        };
    }

    /// What `BitmapData.draw` was handed.
    pub const DrawSource = union(enum) {
        object: *const display_object.DisplayObject,
        bitmap: *const bitmap_data.BitmapData,
    };

    /// `BitmapData.draw`: render a source into the target's pixels through
    /// an off-screen canvas the size of the target.
    ///
    /// The object's OWN placement matrix is not applied — Flash draws the
    /// source as though it sat at the origin, and `t` is the caller's
    /// matrix alone. `t` maps the source's twips to destination PIXELS,
    /// so it already carries the ÷20 the stage transform normally does.
    ///
    /// simdra surfaces hold STRAIGHT RGBA and a BitmapData holds
    /// premultiplied, so the target's pixels convert on the way in and
    /// back on the way out. The canvas is seeded with them rather than
    /// cleared, because a draw composites over what is already there.
    pub fn drawObjectInto(
        self: *Renderer,
        gpa: std.mem.Allocator,
        dst: *bitmap_data.BitmapData,
        source: DrawSource,
        t: Transform,
        cx: swf.reader.ColorTransform,
        clip: ?[4]i32,
        blend: simdra.SmPaint.BlendMode,
    ) !void {
        if (dst.width == 0 or dst.height == 0) return;
        var canvas = try canvas_mod.Canvas.init(gpa, dst.width, dst.height);
        defer canvas.deinit();
        for (canvas.surface.pixels, dst.data) |*out, c| out.* = c.toUnmultiplied().toArgb();

        const ctx = try canvas.ctx();
        if (clip) |c| {
            ctx.save();
            ctx.setTransform(1, 0, 0, 1, 0, 0);
            ctx.beginPath();
            ctx.rect(@floatFromInt(c[0]), @floatFromInt(c[1]), @floatFromInt(c[2]), @floatFromInt(c[3]));
            ctx.clip(.nonzero);
        }
        ctx.blendMode = blend;
        switch (source) {
            .object => |obj| try self.renderObject(ctx, obj, t, cx),
            // A bitmap source under a blend mode: the blit path cannot
            // help, so it goes through the pattern like any other fill.
            .bitmap => |bd| try self.renderBitmap(ctx, .{ .live = bd }, false, t, cx),
        }
        ctx.blendMode = .src_over;
        if (clip != null) ctx.restore();
        ctx.setColorTransform(.{});

        for (canvas.surface.pixels, dst.data) |px, *c| {
            c.* = bitmap_pixels.Color.fromArgb(px).toPremultiplied(dst.transparency);
        }
    }

    /// One display object, WITHOUT its own placement matrix — the caller
    /// supplies the transform. `renderClip`'s per-child arm and this are
    /// the same dispatch; keeping it callable on its own is what lets
    /// `BitmapData.draw` render an object that is not on the stage.
    fn renderObject(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        obj: *const display_object.DisplayObject,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        switch (obj.kind) {
            .shape => |sh| try self.renderShape(ctx, obj.character_id, sh, t, cx),
            .clip => |mc| try self.renderClip(ctx, mc, t, cx),
            // A button draws its current state's children and nothing
            // else — the hit records are invisible by definition.
            .button => |b| try self.renderClip(ctx, &b.container, t, cx),
            .text => |txt| try self.renderText(ctx, txt, t, cx),
            .edit_text => |et| try self.renderEditText(ctx, et, t, cx),
            .bitmap => |b| try self.renderBitmap(ctx, .{ .character = b.id }, false, t, cx),
            .attached_bitmap => |b| try self.renderBitmap(ctx, .{ .live = b.data }, b.smoothing, t, cx),
            .morph_shape => {}, // M7
            .video => {}, // no decoder yet
        }
    }

    fn renderClip(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        clip: *const movie_clip.MovieClip,
        parent_t: Transform,
        parent_cx: swf.reader.ColorTransform,
    ) Error!void {
        // Script-drawn geometry sits UNDER every child of the same clip.
        if (clip.drawing) |*d| try self.renderDrawing(ctx, @constCast(d), parent_t, parent_cx);
        const children = clip.children.items;
        var i: usize = 0;
        while (i < children.len) : (i += 1) {
            const child = children[i];
            // A CLIPPING LAYER: it is never drawn itself, and everything
            // below it down to `clip_depth` is drawn through its shape.
            // The run ends at the first child past that depth, so a
            // masker whose range is empty simply disappears.
            if (child.clip_depth != 0) {
                const end = maskRunEnd(children, i, child.clip_depth);
                if (end == i + 1) continue;
                ctx.save();
                defer ctx.restore();
                try self.clipToMask(ctx, child, parent_t.concat(child.matrix));
                for (children[i + 1 .. end]) |masked| {
                    if (!masked.visible) continue;
                    try self.renderObject(
                        ctx,
                        masked,
                        parent_t.concat(masked.matrix),
                        concatCxform(parent_cx, masked.color_transform),
                    );
                }
                i = end - 1;
                continue;
            }
            if (!child.visible) continue;
            // A clip someone else is masked BY is not drawn on its own —
            // being a mask is all it does.
            if (child.maskee != null) continue;
            const t = parent_t.concat(child.matrix);
            const cx = concatCxform(parent_cx, child.color_transform);
            // `setMask` says the same thing from the other side, and the
            // mask can live anywhere in the tree — so it is measured from
            // the stage rather than from here.
            if (child.mask) |m| {
                ctx.save();
                defer ctx.restore();
                try self.clipToMask(ctx, m, self.worldOf(m));
                try self.renderObject(ctx, child, t, cx);
                continue;
            }
            try self.renderObject(ctx, child, t, cx);
        }
    }

    /// One past the last child this masker covers.
    fn maskRunEnd(
        children: []const *display_object.DisplayObject,
        start: usize,
        clip_depth: u16,
    ) usize {
        var end = start + 1;
        while (end < children.len and children[end].depth <= @as(i32, clip_depth)) : (end += 1) {}
        return end;
    }

    /// The stage-space transform of an object reached from OUTSIDE the
    /// walk — a `setMask` target, which need not be anywhere near the
    /// object it masks.
    fn worldOf(self: *const Renderer, obj: *const display_object.DisplayObject) Transform {
        var chain: [32]swf.reader.Matrix = undefined;
        var n: usize = 0;
        var parent = obj.parent;
        while (parent) |pc| : (parent = pc.parent) {
            const placement = pc.placement orelse break;
            if (n == chain.len) break;
            chain[n] = placement.matrix;
            n += 1;
        }
        var t = self.stage_t;
        while (n > 0) {
            n -= 1;
            t = t.concat(chain[n]);
        }
        return t.concat(obj.matrix);
    }

    /// Narrow the canvas's clip to everything the masker FILLS. Flash's
    /// masks are shape-exact and ignore strokes: what is painted through
    /// is the union of the mask's fill geometry, whatever it is made of.
    ///
    /// The subpaths are transformed here rather than through the CTM,
    /// because a mask can be a whole sprite whose children each carry a
    /// matrix of their own — and a clip takes ONE path.
    fn clipToMask(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        masker: *const display_object.DisplayObject,
        t: Transform,
    ) Error!void {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.beginPath();
        var any = false;
        try self.addMaskGeometry(ctx, masker, t, &any);
        // A mask with no geometry hides everything it covers.
        if (!any) ctx.rect(0, 0, 0, 0);
        ctx.clip(.nonzero);
    }

    fn addMaskGeometry(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        obj: *const display_object.DisplayObject,
        t: Transform,
        any: *bool,
    ) Error!void {
        switch (obj.kind) {
            .shape => |sh| addFillPaths(ctx, try self.distilled(obj.character_id, sh), t, any),
            .clip => |mc| {
                if (mc.drawing) |*d| addFillPaths(ctx, d.paths.items, t, any);
                for (mc.children.items) |child| {
                    try self.addMaskGeometry(ctx, child, t.concat(child.matrix), any);
                }
            },
            .button => |b| for (b.container.children.items) |child| {
                try self.addMaskGeometry(ctx, child, t.concat(child.matrix), any);
            },
            // A field, a bitmap or a morph masks through its BOX — the
            // cheapest thing that is never smaller than the truth.
            .edit_text, .bitmap, .attached_bitmap, .text, .morph_shape => {
                const box = bounds_mod.engineSelfBounds(obj, self.lib) orelse return;
                const c0 = t.apply(@floatFromInt(box.xmin), @floatFromInt(box.ymin));
                const c1 = t.apply(@floatFromInt(box.xmax), @floatFromInt(box.ymin));
                const c2 = t.apply(@floatFromInt(box.xmax), @floatFromInt(box.ymax));
                const c3 = t.apply(@floatFromInt(box.xmin), @floatFromInt(box.ymax));
                ctx.moveTo(c0[0], c0[1]);
                ctx.lineTo(c1[0], c1[1]);
                ctx.lineTo(c2[0], c2[1]);
                ctx.lineTo(c3[0], c3[1]);
                ctx.closePath();
                any.* = true;
            },
            .video => {},
        }
    }

    fn renderShape(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        id: u16,
        shape: *const swf.shape.Shape,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        try self.drawPaths(ctx, try self.distilled(id, shape), t, cx);
    }

    /// Static text: one distilled glyph per entry, tinted by the record's
    /// colour. The tag's own matrix wraps the whole run, and each glyph
    /// carries the size scale and the pen position
    /// (ruffle display_object/text.rs:135-185).
    fn renderText(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        text: *const swf.font_text.Text,
        parent_t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        const lib = self.lib orelse return;
        const base = parent_t.concat(text.matrix);
        var walker = text_mod.Walker.init(text, lib);
        while (walker.next()) |g| {
            const paths = try self.distilledGlyph(g.font.id, g.index, g.glyph);
            try self.drawPaths(
                ctx,
                paths,
                base.concat(g.matrix),
                concatCxform(cx, text_mod.colorAsMult(g.color)),
            );
        }
    }

    /// A text field: its background and border first, then the laid-out
    /// glyphs, each placed by the line it belongs to.
    ///
    /// The layout origin is the inside of the GUTTER, and the box's own
    /// `bounds.xmin/ymin` shift it again — a tag's field is not anchored
    /// at its placement matrix.
    fn renderEditText(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        et: *edit_text.EditText,
        parent_t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        const lib = self.lib orelse return;
        const gpa = self.display_gpa orelse return;
        et.ensureLayout(gpa, lib, self.swf_version) catch return;
        et.applyAutosizeBounds();

        if (et.background or et.border) try self.drawFieldBox(ctx, et, parent_t, cx);

        // Text is CLIPPED to the field's box: a line too long for the
        // field is cut off, not spilled across the stage.
        ctx.save();
        defer ctx.restore();
        ctx.setTransform(parent_t.a, parent_t.b, parent_t.c, parent_t.d, parent_t.tx, parent_t.ty);
        boxPath(
            ctx,
            @floatFromInt(et.bounds.xmin),
            @floatFromInt(et.bounds.ymin),
            @floatFromInt(et.bounds.xmax),
            @floatFromInt(et.bounds.ymax),
        );
        ctx.clip(.nonzero);

        const gutter: f32 = @floatFromInt(edit_text.GUTTER);
        const ox: f32 = @as(f32, @floatFromInt(et.bounds.xmin)) + gutter;
        const oy: f32 = @as(f32, @floatFromInt(et.bounds.ymin)) + gutter;
        // Scrolling moves the text, not the box.
        const scroll_y: f32 = if (et.scroll >= 1 and et.scroll - 1 < et.layout.lines.len)
            @floatFromInt(et.layout.lines[et.scroll - 1].bounds.y)
        else
            0;
        const scroll_x: f32 = @floatCast(et.hscroll * @as(f64, swf.reader.TWIPS_PER_PX));

        // The selection sits UNDER the glyphs; the caret goes over them.
        self.drawSelection(ctx, et, parent_t, ox, oy, scroll_x, scroll_y);
        self.drawCaret(ctx, et, parent_t, ox, oy, scroll_x, scroll_y);

        for (et.layout.lines) |line| {
            for (line.boxes) |b| {
                if (b.font.isNone()) continue;
                const params: display_font.Params = .{
                    .height = b.size,
                    .letter_spacing = b.letter_spacing,
                    .kerning = b.kerning,
                };
                // Boxes are positioned by their TOP; a glyph sits on the
                // baseline, which is one ascent down from it.
                const baseline: f32 = @floatFromInt(b.bounds.y + b.font.ascent(b.size));
                const bx: f32 = @floatFromInt(b.bounds.x);
                var painter: GlyphPainter = .{
                    .r = self,
                    .ctx = ctx,
                    .base = parent_t,
                    .cx = concatCxform(cx, text_mod.colorAsMult(rgbToSwf(b.color))),
                    .font_id = if (b.font.swf_font) |f| f.id else 0,
                    .device = b.font.device,
                    .origin_x = ox + bx - scroll_x,
                    .origin_y = oy + baseline - scroll_y,
                };
                const glyph_text = if (b.is_bullet) &BULLET else self.fieldText(et, b);
                _ = b.font.evaluate(glyph_text, params, &painter) catch {};
                if (painter.err) |e| return e;
                if (b.underline) self.drawUnderline(ctx, b, line, parent_t, ox, oy, scroll_x, scroll_y);
            }
        }
    }

    const BULLET = [_]u16{0x2022};

    /// A one-pixel rule under the run, half a descent below the baseline.
    fn drawUnderline(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        b: text_layout.Box,
        line: text_layout.Line,
        t: Transform,
        ox: f32,
        oy: f32,
        scroll_x: f32,
        scroll_y: f32,
    ) void {
        _ = self;
        const y: f32 = @floatFromInt(b.bounds.y + b.font.ascent(b.size) + @divTrunc(line.descent, 2));
        const x0: f64 = ox + @as(f32, @floatFromInt(b.bounds.x)) - scroll_x;
        const x1: f64 = x0 + @as(f64, @floatFromInt(b.bounds.w));
        const yy: f64 = oy + y - scroll_y;
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.beginPath();
        ctx.moveTo(x0, yy);
        ctx.lineTo(x1, yy);
        setSolid(ctx, edit_text.swfFromRgb(b.color, 255), false);
        ctx.setLineWidth(1);
        ctx.stroke();
    }

    /// The selection's background: BLACK while the field has focus, grey
    /// when it does not, and nothing at all for a bare caret.
    fn drawSelection(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        et: *const edit_text.EditText,
        t: Transform,
        ox: f32,
        oy: f32,
        scroll_x: f32,
        scroll_y: f32,
    ) void {
        const sel = et.selection orelse return;
        if (sel.isCaret()) return;
        const focused = self.focused_field == et;
        if (!focused) return;
        const start = sel.start();
        const end = sel.end();
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(.{});
        for (et.layout.lines) |line| {
            if (end <= line.start or start >= line.end) continue;
            const lo = @max(start, line.start);
            const hi = @min(end, line.end);
            const x0 = et.caretXAt(line, lo) orelse continue;
            const x1 = et.caretXAt(line, hi) orelse line.bounds.x + line.bounds.w;
            if (x1 <= x0) continue;
            // The leading is covered only when the selection runs PAST
            // the end of the line.
            const extra: i32 = if (hi == line.end) line.leading else 0;
            const px0: f64 = ox + @as(f32, @floatFromInt(x0)) - scroll_x;
            const px1: f64 = ox + @as(f32, @floatFromInt(x1)) - scroll_x;
            const py0: f64 = oy + @as(f32, @floatFromInt(line.bounds.y)) - scroll_y;
            const py1: f64 = py0 + @as(f64, @floatFromInt(line.bounds.h + extra));
            ctx.beginPath();
            ctx.moveTo(px0, py0);
            ctx.lineTo(px1, py0);
            ctx.lineTo(px1, py1);
            ctx.lineTo(px0, py1);
            ctx.closePath();
            setSolid(ctx, 0xFF000000, true);
            ctx.fill(.nonzero);
        }
    }

    /// A one-pixel bar at the caret, blinking on a one-second cycle: ON
    /// for the first half, off for the second (ruffle `blinks_now`).
    fn drawCaret(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        et: *const edit_text.EditText,
        t: Transform,
        ox: f32,
        oy: f32,
        scroll_x: f32,
        scroll_y: f32,
    ) void {
        // Only an EDITABLE focused field blinks a caret.
        if (self.focused_field != et or et.read_only) return;
        const cycle = 1000.0;
        if (@mod(self.now_ms, cycle) * 2 >= cycle) return;
        const c = et.caretBox() orelse return;
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(.{});
        const x: f64 = ox + @as(f32, @floatFromInt(c.x)) - scroll_x;
        const y0: f64 = oy + @as(f32, @floatFromInt(c.y)) - scroll_y;
        const y1: f64 = y0 + @as(f64, @floatFromInt(c.h));
        ctx.beginPath();
        ctx.moveTo(x, y0);
        ctx.lineTo(x, y1);
        const col = et.spans.list.items;
        const rgb = if (col.len > 0) col[0].font.color else 0;
        setSolid(ctx, edit_text.swfFromRgb(rgb, 255), false);
        ctx.setLineWidth(1);
        ctx.stroke();
    }

    fn fieldText(self: *Renderer, et: *const edit_text.EditText, b: text_layout.Box) []const u16 {
        _ = self;
        const t = et.text.items;
        const end = @min(b.end, t.len);
        const start = @min(b.start, end);
        return t[start..end];
    }

    /// One glyph at a time, each scaled from EM units and translated to
    /// its pen position.
    const GlyphPainter = struct {
        r: *Renderer,
        ctx: *simdra.SmCanvas,
        base: Transform,
        cx: swf.reader.ColorTransform,
        font_id: u16,
        /// Set instead of `font_id` when the face came from the HOST.
        device: ?*edit_text_device.DeviceFont = null,
        origin_x: f32,
        origin_y: f32,
        err: ?Error = null,

        pub fn glyph(self: *GlyphPainter, p: display_font.Placed) !void {
            if (self.err != null) return;
            if (self.device) |d| {
                if (p.device_glyph) |gi| self.deviceGlyph(d, gi, p);
                return;
            }
            const g = p.glyph orelse return;
            const m: swf.reader.Matrix = .{
                .a = p.scale,
                .b = 0,
                .c = 0,
                .d = p.scale,
                .tx = @intFromFloat(self.origin_x + @as(f32, @floatFromInt(p.x))),
                .ty = @intFromFloat(self.origin_y),
            };
            const idx = self.r.glyphIndexOf(self.font_id, g);
            const paths = self.r.distilledGlyph(self.font_id, idx, g) catch |e| {
                self.err = e;
                return;
            };
            self.r.drawPaths(self.ctx, paths, self.base.concat(m), self.cx) catch |e| {
                self.err = e;
            };
        }

        /// A device glyph has no `DrawPath` IR behind it: the outline
        /// comes straight from the face in EM units and is pathed here,
        /// under a transform that scales it to the span's size.
        fn deviceGlyph(
            self: *GlyphPainter,
            d: *edit_text_device.DeviceFont,
            gi: i32,
            p: display_font.Placed,
        ) void {
            const segs = d.outline(gi);
            if (segs.len == 0) return;
            const m: swf.reader.Matrix = .{
                .a = p.scale,
                .b = 0,
                .c = 0,
                .d = p.scale,
                .tx = @intFromFloat(self.origin_x + @as(f32, @floatFromInt(p.x))),
                .ty = @intFromFloat(self.origin_y),
            };
            const t = self.base.concat(m);
            self.ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
            self.ctx.setColorTransform(toSimdraCxform(self.cx));
            self.ctx.beginPath();
            for (segs) |sg| switch (sg.kind) {
                .move => self.ctx.moveTo(sg.x, sg.y),
                .line => self.ctx.lineTo(sg.x, sg.y),
                .quad => self.ctx.quadraticCurveTo(sg.cx, sg.cy, sg.x, sg.y),
            };
            self.ctx.closePath();
            // Glyph outlines are NON-ZERO wound, like an embedded font's.
            self.ctx.setFillStyle(255, 255, 255, 255);
            self.ctx.fill(.nonzero);
        }
    };

    /// The cache is keyed by INDEX, and a resolved glyph is a pointer into
    /// the font's array, so the index is a subtraction.
    fn glyphIndexOf(self: *Renderer, font_id: u16, g: *const swf.font_text.Glyph) u32 {
        const lib = self.lib orelse return 0;
        const f = lib.getFont(font_id) orelse return 0;
        const base = @intFromPtr(f.glyphs.ptr);
        const here = @intFromPtr(g);
        if (here < base) return 0;
        return @intCast((here - base) / @sizeOf(swf.font_text.Glyph));
    }

    /// Script colours are 0xRRGGBB; the engine packs ABGR.
    fn rgbToSwf(rgb: u32) u32 {
        return edit_text.swfFromRgb(rgb, 255);
    }

    /// The field's box: a filled background and/or a one-pixel border.
    ///
    /// Drawn in TWIPS under the field's own CTM, like every other path —
    /// the canvas transform is what carries twips to pixels, so points
    /// pre-multiplied here would be transformed a second time.
    fn drawFieldBox(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        et: *const edit_text.EditText,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        _ = self;
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(toSimdraCxform(cx));
        const x0: f64 = @floatFromInt(et.bounds.xmin);
        const y0: f64 = @floatFromInt(et.bounds.ymin);
        const x1: f64 = @floatFromInt(et.bounds.xmax);
        const y1: f64 = @floatFromInt(et.bounds.ymax);

        if (et.background) {
            boxPath(ctx, x0, y0, x1, y1);
            setSolid(ctx, et.background_color, true);
            ctx.fill(.nonzero);
        }
        if (et.border) {
            setSolid(ctx, et.border_color, false);
            // A hairline: one DEVICE pixel however the field is scaled,
            // and drawn INSIDE the box rather than astride its edge —
            // Flash's border covers the field's own first and last pixel
            // column, not half a pixel of the background behind it
            // (corpus frame_size_translated_positive). Inset by half a
            // pixel in DEVICE space, which is where the width is
            // measured: each edge covers the pixel that STARTS at its
            // coordinate, so a 20x10 field paints 21x11 pixels. A rotated
            // field has no such grid and keeps the plain stroke.
            ctx.setLineWidth(1);
            const axis_aligned = t.b == 0 and t.c == 0;
            if (axis_aligned) {
                const p0 = t.apply(x0, y0);
                const p1 = t.apply(x1, y1);
                ctx.setTransform(1, 0, 0, 1, 0, 0);
                boxPath(
                    ctx,
                    @min(p0[0], p1[0]) + 0.5,
                    @min(p0[1], p1[1]) + 0.5,
                    @max(p0[0], p1[0]) + 0.5,
                    @max(p0[1], p1[1]) + 0.5,
                );
                ctx.stroke();
                ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
            } else {
                boxPath(ctx, x0, y0, x1, y1);
                ctx.stroke();
            }
        }
    }

    /// Script drawing-API geometry. Subpaths still open (no `endFill` yet)
    /// must draw too, so they are emitted after the committed ones.
    fn renderDrawing(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        d: *drawing.Drawing,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        try self.drawPaths(ctx, d.paths.items, t, cx);
        var open: [2]shape_utils.DrawPath = undefined;
        var n: usize = 0;
        if (d.fill) |f| if (f.commands.items.len > 1) {
            open[n] = .{ .fill = .{ .style = f.style, .commands = f.commands.items, .winding = .even_odd } };
            n += 1;
        };
        if (d.line) |l| if (l.commands.items.len > 1) {
            open[n] = .{ .stroke = .{
                .style = l.style,
                // Still pending, but a loop is a loop — a square drawn
                // and never `endFill`ed still joins at its corner.
                .is_closed = drawing.pathIsClosed(l.commands.items),
                .commands = l.commands.items,
            } };
            n += 1;
        };
        try self.drawPaths(ctx, open[0..n], t, cx);
    }

    fn drawPaths(
        self: *Renderer,
        ctx: *simdra.SmCanvas,
        paths: []const shape_utils.DrawPath,
        t: Transform,
        cx: swf.reader.ColorTransform,
    ) Error!void {
        if (paths.len == 0) return;
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(toSimdraCxform(cx));
        for (paths) |path| {
            switch (path) {
                .fill => |f| {
                    buildPath(ctx, f.commands);
                    var grad: ?simdra.SmGradient = null;
                    defer if (grad) |*g| g.deinit();
                    try applyFillStyle(self, ctx, f.style, t, &grad);
                    ctx.fill(switch (f.winding) {
                        .even_odd => .evenodd,
                        .non_zero => .nonzero,
                    });
                },
                .stroke => |s| {
                    buildPath(ctx, s.commands);
                    // Stroke geometry is in twips under the CTM, but line
                    // width is in DEVICE px for simdra — convert, honoring
                    // Flash's 1px hairline minimum.
                    const scale = @sqrt(@abs(t.a * t.d - t.b * t.c));
                    const width_px = @max(1.0, @as(f64, @floatFromInt(s.style.width)) * scale);
                    switch (s.style.fill) {
                        .solid => |c| ctx.setStrokeStyle(
                            @truncate(c & 0xFF),
                            @truncate((c >> 8) & 0xFF),
                            @truncate((c >> 16) & 0xFF),
                            @truncate((c >> 24) & 0xFF),
                        ),
                        else => {}, // gradient/bitmap strokes: M7
                    }
                    ctx.setLineWidth(width_px);
                    ctx.setLineCap(switch (s.style.start_cap) {
                        .round => .round,
                        .none => .butt,
                        .square, .invalid => .square,
                    });
                    ctx.setLineJoin(switch (s.style.join) {
                        .round => .round,
                        .bevel => .bevel,
                        .miter, .invalid => .miter,
                    });
                    if (s.style.join == .miter and s.style.miter_limit > 0) {
                        ctx.setMiterLimit(s.style.miter_limit);
                    }
                    ctx.stroke();
                },
            }
        }
    }
};

/// The FILL subpaths of a distilled shape, pushed through `t` into
/// device space and appended to whatever the canvas path already holds.
fn addFillPaths(
    ctx: *simdra.SmCanvas,
    paths: []const shape_utils.DrawPath,
    t: Transform,
    any: *bool,
) void {
    for (paths) |path| {
        const f = switch (path) {
            .fill => |x| x,
            .stroke => continue,
        };
        for (f.commands) |cmd| switch (cmd) {
            .move_to => |pt| {
                const p = t.apply(@floatFromInt(pt.x), @floatFromInt(pt.y));
                ctx.moveTo(p[0], p[1]);
            },
            .line_to => |pt| {
                const p = t.apply(@floatFromInt(pt.x), @floatFromInt(pt.y));
                ctx.lineTo(p[0], p[1]);
            },
            .quad_to => |q| {
                const c = t.apply(@floatFromInt(q.cx), @floatFromInt(q.cy));
                const a = t.apply(@floatFromInt(q.ax), @floatFromInt(q.ay));
                ctx.quadraticCurveTo(c[0], c[1], a[0], a[1]);
            },
        };
        if (f.commands.len > 0) {
            ctx.closePath();
            any.* = true;
        }
    }
}

fn buildPath(ctx: *simdra.SmCanvas, commands: []const shape_utils.DrawCommand) void {
    ctx.beginPath();
    for (commands) |cmd| switch (cmd) {
        .move_to => |p| ctx.moveTo(@floatFromInt(p.x), @floatFromInt(p.y)),
        .line_to => |p| ctx.lineTo(@floatFromInt(p.x), @floatFromInt(p.y)),
        .quad_to => |q| ctx.quadraticCurveTo(
            @floatFromInt(q.cx),
            @floatFromInt(q.cy),
            @floatFromInt(q.ax),
            @floatFromInt(q.ay),
        ),
    };
}

const GRADIENT_HALF: f64 = 16384.0; // gradient square is ±16384 twips

/// A flat colour. `Color` is packed ABGR and the canvas wants the four
/// channels apart; the colour TRANSFORM is the canvas's own state, set
/// alongside the CTM, so it is not applied here.
fn setSolid(ctx: *simdra.SmCanvas, c: u32, fill: bool) void {
    const r: u8 = @truncate(c & 0xFF);
    const g: u8 = @truncate((c >> 8) & 0xFF);
    const b: u8 = @truncate((c >> 16) & 0xFF);
    const a: u8 = @truncate((c >> 24) & 0xFF);
    if (fill) {
        ctx.setFillStyle(r, g, b, a);
    } else {
        ctx.setStrokeStyle(r, g, b, a);
    }
}

fn boxPath(ctx: *simdra.SmCanvas, x0: f64, y0: f64, x1: f64, y1: f64) void {
    ctx.beginPath();
    ctx.moveTo(@floatCast(x0), @floatCast(y0));
    ctx.lineTo(@floatCast(x1), @floatCast(y0));
    ctx.lineTo(@floatCast(x1), @floatCast(y1));
    ctx.lineTo(@floatCast(x0), @floatCast(y1));
    ctx.closePath();
}

fn applyFillStyle(
    self: *Renderer,
    ctx: *simdra.SmCanvas,
    style: *const swf.shape.FillStyle,
    t: Transform,
    grad_out: *?simdra.SmGradient,
) Error!void {
    switch (style.*) {
        .solid => |c| ctx.setFillStyle(
            @truncate(c & 0xFF),
            @truncate((c >> 8) & 0xFF),
            @truncate((c >> 16) & 0xFF),
            @truncate((c >> 24) & 0xFF),
        ),
        .linear_gradient => |g| {
            grad_out.* = try buildGradient(ctx, g, t, .linear, 0);
            ctx.setFillGradient(&grad_out.*.?);
        },
        .radial_gradient => |g| {
            grad_out.* = try buildGradient(ctx, g, t, .radial, 0);
            ctx.setFillGradient(&grad_out.*.?);
        },
        .focal_gradient => |fg| {
            grad_out.* = try buildGradient(ctx, fg.gradient, t, .radial, fg.focal_point);
            ctx.setFillGradient(&grad_out.*.?);
        },
        .bitmap => |b| {
            const src: Renderer.BitmapSource = if (b.live) |ptr|
                .{ .live = @ptrCast(@alignCast(ptr)) }
            else
                .{ .character = b.id };
            if (try self.pattern(src, b.is_repeating, b.is_smoothed)) |pat| {
                // The pattern samples in DEVICE space, so its forward
                // matrix is the whole chain: texel → bitmap twips (20 per
                // pixel) → shape twips (the style matrix) → device.
                const full = t.concat(b.matrix);
                pat.setTransform(full.a * 20, full.b * 20, full.c * 20, full.d * 20, full.tx, full.ty);
                ctx.setFillPattern(pat);
            } else {
                // A character that is missing or would not decode. Mid
                // gray, so a broken image is visible rather than absent.
                ctx.setFillStyle(128, 128, 128, 255);
            }
        },
    }
}

const GradientKind = enum { linear, radial };

fn buildGradient(
    ctx: *simdra.SmCanvas,
    g: swf.shape.Gradient,
    t: Transform,
    kind: GradientKind,
    focal: f32,
) Error!simdra.SmGradient {
    _ = ctx;
    // Gradient-space anchors → twips (style matrix) → device (combined).
    const full = t.concat(g.matrix);
    var grad = switch (kind) {
        .linear => blk: {
            const p0 = full.apply(-GRADIENT_HALF, 0);
            const p1 = full.apply(GRADIENT_HALF, 0);
            break :blk simdra.SmGradient.linear(p0[0], p0[1], p1[0], p1[1]);
        },
        .radial => blk: {
            const center = full.apply(GRADIENT_HALF * focal, 0);
            const origin = full.apply(0, 0);
            const rim = full.apply(GRADIENT_HALF, 0);
            const r = @sqrt((rim[0] - origin[0]) * (rim[0] - origin[0]) +
                (rim[1] - origin[1]) * (rim[1] - origin[1]));
            break :blk simdra.SmGradient.radial(center[0], center[1], 0, origin[0], origin[1], r);
        },
    };
    grad.setSpread(switch (g.spread) {
        .pad, .invalid => .pad,
        .reflect => .reflect,
        .repeat => .repeat,
    });
    for (g.records, 0..) |stop, i| {
        const own = if (g.interpolation == .linear_rgb)
            lerpLinearRgb(stop.color, stop.color, 0)
        else
            stop.color;
        try addStop(&grad, @as(f64, @floatFromInt(stop.ratio)) / 255.0, own);
        if (i + 1 >= g.records.len) continue;
        const next = g.records[i + 1];
        // Flash interpolates a gradient in STRAIGHT alpha; simdra does it
        // in premultiplied, which is HTML5's rule and the right one for a
        // canvas — a transparent stop must not bleed its colour across the
        // edge. The two agree wherever the alpha is constant, and differ
        // sharply where it is not: a transparent RED fading into an opaque
        // BLUE goes through purple in Flash and through nothing at all in
        // premultiplied space. Sampling the span in straight alpha and
        // handing the samples over as stops gets Flash's curve back
        // without changing what simdra means (corpus
        // movieclip_begin_gradient_fill).
        const alpha_ramp = (stop.color >> 24) != (next.color >> 24);
        const linear = g.interpolation == .linear_rgb;
        if (!alpha_ramp and !linear) continue;
        if (next.ratio <= stop.ratio) continue;
        var k: u32 = 1;
        while (k < ALPHA_RAMP_SAMPLES) : (k += 1) {
            const frac = @as(f64, @floatFromInt(k)) / ALPHA_RAMP_SAMPLES;
            const pos = (@as(f64, @floatFromInt(stop.ratio)) * (1 - frac) +
                @as(f64, @floatFromInt(next.ratio)) * frac) / 255.0;
            const mixed = if (linear)
                lerpLinearRgb(stop.color, next.color, frac)
            else
                lerpStraight(stop.color, next.color, frac);
            try addStop(&grad, pos, mixed);
        }
    }
    return grad;
}

/// How finely an alpha ramp is resampled. The residual premultiplied
/// error inside one step is under a unit of colour at this density.
const ALPHA_RAMP_SAMPLES = 32;

fn lerpStraight(lo: swf.reader.Color, hi: swf.reader.Color, t: f64) swf.reader.Color {
    var out: u32 = 0;
    inline for (0..4) |ch| {
        const shift: u5 = @intCast(ch * 8);
        const a: f64 = @floatFromInt((lo >> shift) & 0xFF);
        const b: f64 = @floatFromInt((hi >> shift) & 0xFF);
        const v: u32 = @intFromFloat(@round(std.math.clamp(a * (1 - t) + b * t, 0, 255)));
        out |= v << shift;
    }
    return out;
}

/// `interpolationMethod = "linearRGB"`, exactly as the reference
/// renderer does it — and the round trip is LOSSY on purpose, which is
/// why it is visible on flat colours and not just on ramps. Each stop
/// channel becomes a linear-light BYTE (`srgb_to_linear(c) * 255`,
/// truncated), those bytes are what get interpolated, and the result is
/// read back as linear light on the way to an sRGB screen. A green of 20
/// survives that as 13.
fn lerpLinearRgb(lo: swf.reader.Color, hi: swf.reader.Color, t: f64) swf.reader.Color {
    var out: u32 = 0;
    inline for (0..3) |ch| {
        const shift: u5 = @intCast(ch * 8);
        const a = srgbToLinear(@as(f64, @floatFromInt((lo >> shift) & 0xFF)) / 255.0) * 255.0;
        const b = srgbToLinear(@as(f64, @floatFromInt((hi >> shift) & 0xFF)) / 255.0) * 255.0;
        const mixed = @trunc(std.math.clamp(a * (1 - t) + b * t, 0, 255));
        const back = linearToSrgb(mixed / 255.0) * 255.0;
        out |= @as(u32, @intFromFloat(@round(std.math.clamp(back, 0, 255)))) << shift;
    }
    // Alpha never goes through the colour space.
    const la: f64 = @floatFromInt((lo >> 24) & 0xFF);
    const ha: f64 = @floatFromInt((hi >> 24) & 0xFF);
    out |= @as(u32, @intFromFloat(@round(std.math.clamp(la * (1 - t) + ha * t, 0, 255)))) << 24;
    return out;
}

fn srgbToLinear(c: f64) f64 {
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(c: f64) f64 {
    if (c <= 0.0031308) return c * 12.92;
    return 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

fn addStop(grad: *simdra.SmGradient, pos: f64, color: swf.reader.Color) Error!void {
    var buf: [40]u8 = undefined;
    const css = std.fmt.bufPrint(&buf, "rgba({d},{d},{d},{d:.4})", .{
        color & 0xFF,
        (color >> 8) & 0xFF,
        (color >> 16) & 0xFF,
        @as(f64, @floatFromInt((color >> 24) & 0xFF)) / 255.0,
    }) catch unreachable;
    grad.addColorStop(pos, css) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {}, // Syntax/IndexSize can't occur for generated stops
    };
}

// --- Tests -----------------------------------------------------------------

test "render a placed square shape through the full pipeline" {
    const gpa = std.testing.allocator;
    // Movie: 10x10px stage, DefineShape red 200x200-twip square at origin,
    // PlaceObject2 at depth 1, ShowFrame.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, &.{ 0x08, 0x0C, 0x80, 0x00, 12, 1, 0 });
    // rect nbits=9: hand-pack via known-good square shape body from
    // shape.zig's test — reuse the swfdump-verified corpus square instead:
    // simplest is a synthetic body identical to the M1 fixture.
    payload.clearRetainingCapacity();
    // header: rect nbits=9 (0,200,0,200 twips = 10x10 px)
    var rect: [6]u8 = @splat(0);
    packBits(&rect, &.{ .{ 9, 5 }, .{ 0, 9 }, .{ 200, 9 }, .{ 0, 9 }, .{ 200, 9 } });
    try payload.appendSlice(gpa, rect[0..6]);
    try payload.appendSlice(gpa, &.{ 0, 12, 1, 0 }); // fps 12, 1 frame
    // DefineShape body (id 7): same construction as shape.zig's test.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &.{ 7, 0 });
    try body.appendSlice(gpa, rect[0..6]);
    try body.appendSlice(gpa, &.{ 1, 0x00, 255, 0, 0, 0, 0x11 });
    var rec: [32]u8 = @splat(0);
    const neg200: u32 = @as(u32, @bitCast(@as(i32, -200))) & 0x1FF;
    packBits(&rec, &.{
        .{ 0b00101, 6 },     .{ 0, 5 },      .{ 1, 1 },
        .{ 0b11_0111_1, 7 }, .{ 200, 9 },    .{ 0, 9 },
        .{ 0b11_0111_1, 7 }, .{ 0, 9 },      .{ 200, 9 },
        .{ 0b11_0111_1, 7 }, .{ neg200, 9 }, .{ 0, 9 },
        .{ 0b11_0111_1, 7 }, .{ 0, 9 },      .{ neg200, 9 },
        .{ 0, 6 },
    });
    try body.appendSlice(gpa, &rec);
    try appendTag(gpa, &payload, 2, body.items);
    try appendTag(gpa, &payload, 26, &.{ 2, 1, 0, 7, 0 }); // place id 7 depth 1
    try appendTag(gpa, &payload, 1, "");
    try appendTag(gpa, &payload, 0, "");

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "FWS\x06");
    var len4: [4]u8 = undefined;
    std.mem.writeInt(u32, &len4, @intCast(payload.items.len + 8), .little);
    try file.appendSlice(gpa, &len4);
    try file.appendSlice(gpa, payload.items);

    var movie = try swf.movie.load(gpa, file.items);
    defer movie.deinit();

    var counter: u32 = 0;
    var ctx_: movie_clip.Context = .{ .gpa = gpa, .movie = &movie, .root_movie = &movie, .instance_counter = &counter };
    defer ctx_.deinit(gpa);
    var root = movie_clip.MovieClip.init(movie.frames);
    defer root.deinit(gpa);
    try root.runFrame(&ctx_);

    var canvas = try canvas_mod.Canvas.init(gpa, 10, 10);
    defer canvas.deinit();
    var renderer = Renderer.init(movie.allocator());
    const stage: Transform = .{ .a = 1.0 / 20.0, .d = 1.0 / 20.0 };
    var root_placement: display_object.DisplayObject = .{
        .character_id = 0,
        .depth = 0,
        .kind = .{ .clip = &root },
        .owns_kind = false,
    };
    try renderer.renderFrame(&canvas, &root, &root_placement, &.{}, 0x00FFFFFF, stage);

    // Whole 10x10 canvas should be red (surface order BGRA: R in byte 2).
    // ±2 LSB tolerance absorbs the AA coverage rounding (same tolerance
    // simdra's own napi-parity suite uses).
    const px = canvas.pixels();
    for ([_]usize{ 0, 55, 99 }) |i| {
        const r = (px[i] >> 16) & 0xFF;
        const g = (px[i] >> 8) & 0xFF;
        const b = px[i] & 0xFF;
        try std.testing.expect(r >= 253);
        try std.testing.expect(g <= 2 and b <= 2);
    }
}

fn appendTag(gpa: std.mem.Allocator, list: *std.ArrayList(u8), code: u16, body: []const u8) !void {
    if (body.len >= 0x3F) {
        const cl: u16 = (code << 6) | 0x3F;
        try list.append(gpa, @truncate(cl));
        try list.append(gpa, @truncate(cl >> 8));
        var len4: [4]u8 = undefined;
        std.mem.writeInt(u32, &len4, @intCast(body.len), .little);
        try list.appendSlice(gpa, &len4);
    } else {
        const cl: u16 = (code << 6) | @as(u16, @intCast(body.len));
        try list.append(gpa, @truncate(cl));
        try list.append(gpa, @truncate(cl >> 8));
    }
    try list.appendSlice(gpa, body);
}

fn packBits(buf: []u8, fields: []const struct { u32, u6 }) void {
    var bit: usize = 0;
    for (fields) |f| {
        var i: u6 = f[1];
        while (i > 0) {
            i -= 1;
            const b: u1 = @intCast((f[0] >> @as(u5, @intCast(i))) & 1);
            buf[bit / 8] |= @as(u8, b) << @intCast(7 - (bit % 8));
            bit += 1;
        }
    }
}
