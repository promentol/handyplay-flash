//! The boot shell: an ad, then a LEGEND of what the pad became.
//!
//!   ad  ->  controls  ->  play
//!
//! It does not EDIT anything. A core that draws its own remapper ends up
//! fighting the frontend — RetroArch already remaps physical buttons to
//! RetroPad ids, and two remappers composed multiplicatively is a support
//! problem, not a feature. What the frontend cannot do is know which keys
//! THIS movie reads, and that is fixed by re-declaring the core options
//! after load with the surveyed keys as their values (see core.zig), not
//! by drawing menus here.
//!
//! **Drawn in the project's own visual language**, not in pixel art: an
//! indigo gradient, the rounded-square mark with its orange-to-purple
//! sweep, drifting circles and real anti-aliased type — the same picture
//! `samples/hello` renders through the Flash engine. A 3x5 bitmap font
//! came first and looked like a debug overlay, which is the wrong first
//! impression for the one screen every player sees.
//!
//! The type is Poppins Medium (SIL OFL, `vendor/fonts/`), embedded in the
//! core and rasterised through simdra's stb_truetype binding. It has to
//! be embedded: RetroArch ships no font a core may use, and a system font
//! is not ours to distribute.

const std = @import("std");
const simdra = @import("simdra");

const SmFont = simdra.SmFont;
const FONT_TTF = @embedFile("font");
const alloc = std.heap.c_allocator;

// --- palette ---------------------------------------------------------------
//
// Lifted from the sample render: a deep indigo field, the mark's warm
// sweep, and one accent that everything live uses.

pub const BG_TOP: u32 = 0xFF16123A;
pub const BG_MID: u32 = 0xFF241A4D;
pub const BG_BOTTOM: u32 = 0xFF100E28;
pub const FG: u32 = 0xFFF2F4FA;
pub const DIM: u32 = 0xFF8A90AC;
pub const ACCENT: u32 = 0xFFFF9A3C;
pub const RULE: u32 = 0xFFFFFFFF;

const MARK_A: u32 = 0xFFFFA23C; // orange, top-left
const MARK_B: u32 = 0xFFF2508F; // pink, middle
const MARK_C: u32 = 0xFFA855F7; // purple, bottom-right

/// The circles that float around the mark, as (x, y, r) in fractions of
/// the stage — the same arrangement as the sample.
const Bubble = struct { x: f32, y: f32, r: f32, color: u32 };
const BUBBLES = [_]Bubble{
    .{ .x = 0.27, .y = 0.34, .r = 0.055, .color = 0xFF4FA3F7 },
    .{ .x = 0.19, .y = 0.48, .r = 0.032, .color = 0xFF2BB8A3 },
    .{ .x = 0.72, .y = 0.28, .r = 0.042, .color = 0xFFA855F7 },
    .{ .x = 0.79, .y = 0.45, .r = 0.026, .color = 0xFFD9A87C },
    .{ .x = 0.83, .y = 0.60, .r = 0.048, .color = 0xFFE0678F },
    .{ .x = 0.20, .y = 0.68, .r = 0.028, .color = 0xFFD9A87C },
};

// --- painting ----------------------------------------------------------------

fn chan(c: u32, comptime shift: u5) f32 {
    return @floatFromInt((c >> shift) & 0xFF);
}

fn mix(a: u32, b: u32, t: f32) u32 {
    const k = std.math.clamp(t, 0, 1);
    const r = chan(a, 16) + (chan(b, 16) - chan(a, 16)) * k;
    const g = chan(a, 8) + (chan(b, 8) - chan(a, 8)) * k;
    const bl = chan(a, 0) + (chan(b, 0) - chan(a, 0)) * k;
    return 0xFF000000 |
        (@as(u32, @intFromFloat(r)) << 16) |
        (@as(u32, @intFromFloat(g)) << 8) |
        @as(u32, @intFromFloat(bl));
}

pub const Canvas = struct {
    px: []u32,
    w: u32,
    h: u32,

    pub fn init(px: []u32, w: u32, h: u32) Canvas {
        return .{ .px = px, .w = w, .h = h };
    }

    fn blend(self: Canvas, x: i32, y: i32, color: u32, a: f32) void {
        if (a <= 0) return;
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i: usize = @intCast(y * @as(i32, @intCast(self.w)) + x);
        self.px[i] = if (a >= 1) color | 0xFF000000 else mix(self.px[i], color, a);
    }

    /// The field everything else sits on: indigo, lighter through the
    /// middle so the mark has something to stand against.
    pub fn background(self: Canvas) void {
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(1, self.h - 1)));
            const color = if (t < 0.5)
                mix(BG_TOP, BG_MID, t * 2)
            else
                mix(BG_MID, BG_BOTTOM, (t - 0.5) * 2);
            @memset(self.px[y * self.w ..][0..self.w], color);
        }
    }

    pub fn rect(self: Canvas, x: f32, y: f32, w: f32, h: f32, color: u32, a: f32) void {
        if (w <= 0 or h <= 0) return;
        var yy: i32 = @intFromFloat(@floor(y));
        const y1: i32 = @intFromFloat(@ceil(y + h));
        while (yy < y1) : (yy += 1) {
            var xx: i32 = @intFromFloat(@floor(x));
            const x1: i32 = @intFromFloat(@ceil(x + w));
            while (xx < x1) : (xx += 1) self.blend(xx, yy, color, a);
        }
    }

    pub fn circle(self: Canvas, cx: f32, cy: f32, r: f32, color: u32, a: f32) void {
        if (r <= 0) return;
        var yy: i32 = @intFromFloat(@floor(cy - r - 1));
        const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
        while (yy < y1) : (yy += 1) {
            var xx: i32 = @intFromFloat(@floor(cx - r - 1));
            const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
            while (xx < x1) : (xx += 1) {
                const dx = @as(f32, @floatFromInt(xx)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(yy)) + 0.5 - cy;
                // Coverage from the distance to the edge: one pixel of
                // feather is all an edge this size needs.
                const cov = std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
                self.blend(xx, yy, color, cov * a);
            }
        }
    }

    /// Signed distance to a rounded square centred on the origin.
    fn roundedBox(px: f32, py: f32, half: f32, radius: f32) f32 {
        const qx = @abs(px) - (half - radius);
        const qy = @abs(py) - (half - radius);
        const ax = @max(qx, 0);
        const ay = @max(qy, 0);
        return @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - radius;
    }

    /// The handyplay-flash mark: a rounded square under a warm diagonal sweep,
    /// with a smaller rounded square knocked out of the middle.
    pub fn mark(self: Canvas, cx: f32, cy: f32, size: f32, a: f32) void {
        if (size <= 1) return;
        const half = size / 2;
        const radius = size * 0.30;
        const hole = size * 0.30;
        const hole_radius = hole * 0.20;

        var yy: i32 = @intFromFloat(@floor(cy - half - 1));
        const y1: i32 = @intFromFloat(@ceil(cy + half + 1));
        while (yy < y1) : (yy += 1) {
            var xx: i32 = @intFromFloat(@floor(cx - half - 1));
            const x1: i32 = @intFromFloat(@ceil(cx + half + 1));
            while (xx < x1) : (xx += 1) {
                const px = @as(f32, @floatFromInt(xx)) + 0.5 - cx;
                const py = @as(f32, @floatFromInt(yy)) + 0.5 - cy;
                const outer = roundedBox(px, py, half, radius);
                if (outer > 0.5) continue;
                const inner = roundedBox(px, py, hole / 2, hole_radius);
                // Inside the outer shape AND outside the hole, both edges
                // feathered by the same half-pixel.
                const cov = std.math.clamp(0.5 - outer, 0, 1) *
                    std.math.clamp(inner + 0.5, 0, 1);
                if (cov <= 0) continue;
                // The sweep runs corner to corner, orange to purple.
                const t = std.math.clamp((px + py) / (size * 1.2) + 0.5, 0, 1);
                const color = if (t < 0.5)
                    mix(MARK_A, MARK_B, t * 2)
                else
                    mix(MARK_B, MARK_C, (t - 0.5) * 2);
                self.blend(xx, yy, color, cov * a);
            }
        }
    }

    pub fn hline(self: Canvas, x: f32, y: f32, w: f32, color: u32, a: f32) void {
        self.rect(x, y, w, @max(1, @as(f32, @floatFromInt(self.h)) / 400), color, a);
    }
};

// --- type ----------------------------------------------------------------------
//
// One SmFont per size, cached because building one parses the whole face.

const FontSlot = struct { size: f64 = 0, font: ?SmFont = null };
var slots: [4]FontSlot = @splat(.{});

fn fontAt(size_in: f64) ?*SmFont {
    const size = @round(@max(6, size_in));
    for (&slots) |*s| {
        if (s.font != null and s.size == size) return &s.font.?;
    }
    for (&slots) |*s| {
        if (s.font != null) continue;
        s.font = SmFont.fromBytesWithAllocator(alloc, FONT_TTF, size) catch return null;
        s.size = size;
        return &s.font.?;
    }
    // All four taken: recycle the first rather than grow without bound.
    slots[0].font.?.release();
    slots[0].font = SmFont.fromBytesWithAllocator(alloc, FONT_TTF, size) catch return null;
    slots[0].size = size;
    return &slots[0].font.?;
}

pub fn textWidth(size: f64, s: []const u8) f64 {
    const f = fontAt(size) orelse return 0;
    return f.measureWidth(s);
}

/// Draw `s` with its left edge at `x` and its BASELINE at `y`.
pub fn text(c: Canvas, x: f64, y: f64, size: f64, color: u32, a: f32, s: []const u8) void {
    const f = fontAt(size) orelse return;
    var pen = x;
    var prev: u32 = 0;
    for (s) |ch| {
        const cp: u32 = ch;
        if (prev != 0) pen += f.kernAdvance(prev, cp);
        prev = cp;
        const gi = f.glyphIndexFor(cp);
        if (gi != 0) {
            if (f.rasterizeGlyph(gi)) |bm| {
                const ox = @round(pen) + @as(f64, @floatFromInt(bm.offsetX));
                const oy = @round(y) + @as(f64, @floatFromInt(bm.offsetY));
                var row: u32 = 0;
                while (row < bm.height) : (row += 1) {
                    var col: u32 = 0;
                    while (col < bm.width) : (col += 1) {
                        const cov = @as(f32, @floatFromInt(bm.pixels[row * bm.width + col])) / 255.0;
                        if (cov <= 0) continue;
                        c.blend(
                            @intFromFloat(ox + @as(f64, @floatFromInt(col))),
                            @intFromFloat(oy + @as(f64, @floatFromInt(row))),
                            color,
                            cov * a,
                        );
                    }
                }
                pen += bm.advanceX;
                continue;
            } else |_| {}
        }
        pen += f.glyphAdvanceWidth(gi);
    }
}

pub fn centered(c: Canvas, y: f64, size: f64, color: u32, a: f32, s: []const u8) void {
    const w = textWidth(size, s);
    text(c, (@as(f64, @floatFromInt(c.w)) - w) / 2, y, size, color, a, s);
}

/// Ascent to descent plus the gap, for stacking lines.
pub fn lineHeight(size: f64) f64 {
    const f = fontAt(size) orelse return size * 1.3;
    const m = f.getMetrics();
    return m.ascent - m.descent + m.lineGap;
}

// --- the shell ------------------------------------------------------------------

pub const State = enum { ad, controls, play };

/// One line of the legend: the PAD BUTTON's own name, and what it sends.
///
/// libretro never tells a core what the physical controller calls its
/// buttons — only the RetroPad abstraction — so "A", "L2", "START" is as
/// close to the real thing as exists, and it is the vocabulary the
/// frontend's own menus use anyway.
pub const Row = struct {
    label: []const u8,
    key: []const u8,
    bound: bool,
};

/// The only input the shell has: "go on".
pub const Input = struct {
    accept: bool = false,
};

pub const Act = enum { none, done };

pub const Shell = struct {
    state: State = .ad,
    ticks: u32 = 0,
    ad_frames: u32 = 90,
    /// What the player should press, in the frontend's own vocabulary.
    accept_name: []const u8 = "A",

    /// The legend ignores input this long, so the press that skipped the
    /// ad cannot skip the legend too.
    const GRACE: u32 = 12;

    pub fn enter(self: *Shell, state: State) void {
        self.state = state;
        self.ticks = 0;
    }

    pub fn update(self: *Shell, in: Input) Act {
        self.ticks += 1;
        switch (self.state) {
            .ad => {
                // Skippable, and it ends on its own — an ad nobody can
                // get past is a bug report, not a business model.
                if (in.accept or self.ticks >= self.ad_frames) self.enter(.controls);
                return .none;
            },
            .controls => {
                if (in.accept and self.ticks > GRACE) {
                    self.enter(.play);
                    return .done;
                }
                return .none;
            },
            .play => return .done,
        }
    }

    pub fn draw(self: *const Shell, c: Canvas, rows: []const Row) void {
        switch (self.state) {
            .ad => self.drawAd(c),
            .controls => self.drawControls(c, rows),
            .play => {},
        }
    }

    fn ease(t: f32) f32 {
        const k = std.math.clamp(t, 0, 1);
        return 1 - (1 - k) * (1 - k) * (1 - k);
    }

    // --- the ad -------------------------------------------------------------

    fn drawAd(self: *const Shell, c: Canvas) void {
        c.background();
        const w: f32 = @floatFromInt(c.w);
        const h: f32 = @floatFromInt(c.h);
        const t = @as(f32, @floatFromInt(self.ticks));
        const life = ease(t / @as(f32, @floatFromInt(@max(1, self.ad_frames / 3))));

        // The circles drift in and bob: alive, without anything moving
        // fast enough to be noise.
        for (BUBBLES, 0..) |b, i| {
            const bob = @sin(t * 0.045 + @as(f32, @floatFromInt(i))) * h * 0.012;
            c.circle(b.x * w, b.y * h + bob, b.r * h * life, b.color, 0.85 * life);
        }

        c.mark(w / 2, h * 0.40, h * 0.26 * life, life);
        centered(c, h * 0.70, @max(11.0, @as(f64, h) * 0.115), FG, life, "handyplay-flash");

        // A bar that means something: it is the ad's own clock. The movie
        // finished parsing before this screen drew its first frame.
        const p = @as(f32, @floatFromInt(@min(self.ticks, self.ad_frames))) /
            @as(f32, @floatFromInt(self.ad_frames));
        const bar_w = w * 0.42;
        const bar_h = @max(2.0, h * 0.008);
        const bar_x = (w - bar_w) / 2;
        const bar_y = h * 0.80;
        c.rect(bar_x, bar_y, bar_w, bar_h, 0xFFFFFFFF, 0.14);
        c.rect(bar_x, bar_y, bar_w * p, bar_h, ACCENT, 0.95);

        var buf: [48]u8 = undefined;
        const hint = std.fmt.bufPrint(&buf, "PRESS {s} TO SKIP", .{self.accept_name}) catch "SKIP";
        centered(c, h * 0.93, @max(8.0, @as(f64, h) * 0.040), DIM, 0.9, hint);
    }

    // --- the controls legend --------------------------------------------------

    fn drawControls(self: *const Shell, c: Canvas, rows: []const Row) void {
        c.background();
        const w: f64 = @floatFromInt(c.w);
        const h: f64 = @floatFromInt(c.h);
        const fw: f32 = @floatCast(w);
        const fh: f32 = @floatCast(h);

        // A quiet version of the ad's furniture, so the two screens are
        // recognisably the same product.
        for (BUBBLES) |b| {
            c.circle(b.x * fw, b.y * fh, b.r * fh * 0.6, b.color, 0.12);
        }

        const title_size = @max(11.0, h * 0.075);
        const mark_size = title_size * 1.1;
        const pad = w * 0.06;
        const title_base = h * 0.14;
        c.mark(
            @floatCast(pad + mark_size / 2),
            @floatCast(title_base - title_size * 0.34),
            @floatCast(mark_size),
            1.0,
        );
        text(c, pad + mark_size * 1.4, title_base, title_size, FG, 1.0, "CONTROLS");

        const foot_size = @max(8.0, h * 0.042);
        const top = title_base + h * 0.05;
        const footer = h - lineHeight(foot_size) * 2.2;

        // One column or two, whichever leaves the type BIGGER: a 450x300
        // movie reads better split, a 176x208 phone stage has the height
        // for one column and no width to spare.
        const avail = footer - top;
        const per_one = avail / @as(f64, @floatFromInt(@max(1, rows.len)));
        const per_two = avail / @as(f64, @floatFromInt(@max(1, (rows.len + 1) / 2)));
        const cols: usize = if (rows.len > 8 and per_one * 0.62 < 11.0 and w > 240) 2 else 1;
        const per_col = (rows.len + cols - 1) / cols;
        const step = if (cols == 2) per_two else per_one;
        const size = @max(7.0, @min(step * 0.62, h * 0.05));
        // A gutter between the columns, or the left column's KEY sits
        // against the right column's LABEL and the eye joins them.
        const gutter = if (cols == 2) pad * 0.9 else 0;
        const col_w = (w - pad * 2 - gutter) / @as(f64, @floatFromInt(cols));

        for (rows, 0..) |r, i| {
            const col = i / per_col;
            const row = i % per_col;
            const x0 = pad + @as(f64, @floatFromInt(col)) * (col_w + gutter);
            const y = top + (@as(f64, @floatFromInt(row)) + 0.8) * step;
            const a: f32 = if (r.bound) 1.0 else 0.4;
            text(c, x0, y, size, FG, a, r.label);
            const kw = textWidth(size, r.key);
            text(c, x0 + col_w - kw, y, size, if (r.bound) ACCENT else DIM, a, r.key);
            if (row + 1 < per_col) {
                c.hline(@floatCast(x0), @floatCast(y + step * 0.3), @floatCast(col_w), RULE, 0.10);
            }
        }

        c.hline(@floatCast(pad), @floatCast(footer), @floatCast(w - pad * 2), RULE, 0.18);
        centered(c, footer + lineHeight(foot_size) * 0.95, foot_size, DIM, 0.9, "CHANGE THESE IN CORE OPTIONS");

        var buf: [48]u8 = undefined;
        const go = std.fmt.bufPrint(&buf, "PRESS {s} TO PLAY", .{self.accept_name}) catch "PLAY";
        const pulse: f32 = 0.62 + 0.38 * @sin(@as(f32, @floatFromInt(self.ticks)) * 0.11);
        centered(c, footer + lineHeight(foot_size) * 1.95, foot_size, FG, pulse, go);
    }
};

/// The pointer, drawn over the movie once it is playing. Outlined, so it
/// stays visible over both a white menu and a black night level.
pub fn drawCursor(c: Canvas, x: f64, y: f64, dim: bool) void {
    const s: f32 = @max(7.0, @as(f32, @floatFromInt(c.w)) / 55.0);
    const fx: f32 = @floatCast(x);
    const fy: f32 = @floatCast(y);
    const fill: u32 = if (dim) 0xFFB8BECE else 0xFFFFFFFF;
    const ink: u32 = 0xFF14141C;
    // An arrow as scanlines: the hypotenuse gets its coverage from the
    // fractional width, which is enough to keep the edge smooth.
    var row: f32 = 0;
    while (row < s) : (row += 1) {
        const width = s * 0.60 * (1 - row / s);
        c.rect(fx, fy + row, width + 1.6, 1, ink, 0.92);
        c.rect(fx + 1, fy + row, @max(0, width - 0.4), 1, fill, 0.96);
    }
    c.rect(fx + s * 0.20, fy + s * 0.55, s * 0.20, s * 0.45, ink, 0.92);
    c.rect(fx + s * 0.25, fy + s * 0.55, s * 0.11, s * 0.38, fill, 0.96);
}
