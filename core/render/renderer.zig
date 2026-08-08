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
    /// Text layout is version-dependent (wrapping, alignment), so the
    /// renderer needs the movie's version to rebuild a stale one.
    swf_version: u8 = 8,
    /// The DISPLAY allocator, not the movie arena: a field's layout is
    /// owned by the field and freed when it is, so it must come from the
    /// same place everything else the field owns does.
    display_gpa: ?std.mem.Allocator = null,

    pub fn init(movie_arena: std.mem.Allocator) Renderer {
        return .{ .arena = movie_arena };
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
        background: swf.reader.Color,
        stage: Transform,
    ) !void {
        // Opaque background (logical RGBA → surface order fill).
        const bg = background | 0xFF000000;
        simdra.simd.fillU32(canvas.surface.pixels, simdra.simd.swizzleRB(bg));
        if (!root_placement.visible) return;
        const ctx = try canvas.ctx();
        try self.renderClip(
            ctx,
            root,
            stage.concat(root_placement.matrix),
            root_placement.color_transform,
        );
        ctx.setColorTransform(.{}); // leave ctx state clean
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
        for (clip.children.items) |child| {
            if (!child.visible) continue;
            if (child.clip_depth != 0) continue; // M7: masks (skip the masker)
            const t = parent_t.concat(child.matrix);
            const cx = concatCxform(parent_cx, child.color_transform);
            switch (child.kind) {
                .shape => |s| try self.renderShape(ctx, child.character_id, s, t, cx),
                .clip => |mc| try self.renderClip(ctx, mc, t, cx),
                // A button draws its current state's children and nothing
                // else — the hit records are invisible by definition.
                .button => |b| try self.renderClip(ctx, &b.container, t, cx),
                .text => |txt| try self.renderText(ctx, txt, t, cx),
                .edit_text => |et| try self.renderEditText(ctx, et, t, cx),
                .morph_shape, .bitmap => {}, // M7
            }
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
            }
        }
    }

    const BULLET = [_]u16{0x2022};

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
            boxPath(ctx, x0, y0, x1, y1);
            setSolid(ctx, et.border_color, false);
            // A hairline: one DEVICE pixel however the field is scaled.
            ctx.setLineWidth(1);
            ctx.stroke();
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
            open[n] = .{ .stroke = .{ .style = l.style, .is_closed = false, .commands = l.commands.items } };
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
        _ = self;
        if (paths.len == 0) return;
        ctx.setTransform(t.a, t.b, t.c, t.d, t.tx, t.ty);
        ctx.setColorTransform(toSimdraCxform(cx));
        for (paths) |path| {
            switch (path) {
                .fill => |f| {
                    buildPath(ctx, f.commands);
                    var grad: ?simdra.SmGradient = null;
                    defer if (grad) |*g| g.deinit();
                    try applyFillStyle(ctx, f.style, t, &grad);
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
        .bitmap => {
            // M4: decoded bitmap → SmPattern. Placeholder: mid gray so
            // bitmap-filled shapes are visible rather than missing.
            ctx.setFillStyle(128, 128, 128, 255);
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
    for (g.records) |stop| {
        var buf: [40]u8 = undefined;
        const css = std.fmt.bufPrint(&buf, "rgba({d},{d},{d},{d:.4})", .{
            stop.color & 0xFF,
            (stop.color >> 8) & 0xFF,
            (stop.color >> 16) & 0xFF,
            @as(f64, @floatFromInt((stop.color >> 24) & 0xFF)) / 255.0,
        }) catch unreachable;
        grad.addColorStop(@as(f64, @floatFromInt(stop.ratio)) / 255.0, css) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {}, // Syntax/IndexSize can't occur for generated stops
        };
    }
    return grad;
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
    var ctx_: movie_clip.Context = .{ .gpa = gpa, .movie = &movie, .instance_counter = &counter };
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
    try renderer.renderFrame(&canvas, &root, &root_placement, 0x00FFFFFF, stage);

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
