//! Sorenson Spark — FLV video codec 2, an H.263 baseline with its own
//! picture header.
//!
//! What Sorenson changed from ITU-T H.263 is only the front of the frame:
//! the PTYPE record is replaced by a version field stolen from the GOB
//! number, a picture size that can be custom in 8 or 16 bits, and a
//! deblocking flag. Everything after — MCBPC, CBPY, the coefficient VLC,
//! the dequantiser, the IDCT — is the standard, and this file is a
//! transcription of it against `reference/h263-rs`, which is the decoder
//! ruffle uses and therefore the behaviour we have to match.
//!
//! Three details are worth knowing before changing anything here:
//!
//!   • The DEQUANTISED level is not the coefficient. `quant * (2|level|+1)`
//!     with an even-quantiser parity correction, clipped to ±2047 — get
//!     the parity wrong and every quantiser 2, 4, 6 … block drifts.
//!   • The IDCT is FLOAT, and its rounding (`x/4 + sign(x)*0.5`, truncated)
//!     is part of the bitstream's meaning, not an implementation detail.
//!   • Chroma is never interpolated on output. One chroma sample paints
//!     four pixels, because that is what Flash Player does.
//!
//! The deblocking filter (Annex J, as a post-process) is here too: a
//! Sorenson picture asks for it in its own header, and the corpus frame
//! does.

const std = @import("std");
const tables = @import("h263_tables.zig");

const McbpcNode = tables.McbpcNode;
const MbKind = tables.MbKind;

pub const Error = std.mem.Allocator.Error || error{Corrupt};

/// A decoded frame, RGBA8888, straight alpha, fully opaque.
pub const Frame = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.* = undefined;
    }
};

/// The YUV picture a P-frame predicts from. Planes are CROPPED to the
/// picture size, not rounded up to the macroblock grid — motion vectors
/// that point outside clamp to the edge.
const Planes = struct {
    width: usize,
    height: usize,
    chroma_width: usize,
    chroma_height: usize,
    y: []u8,
    cb: []u8,
    cr: []u8,

    fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Planes {
        const cw = (width + 1) / 2;
        const ch = (height + 1) / 2;
        const y = try gpa.alloc(u8, width * height);
        errdefer gpa.free(y);
        const cb = try gpa.alloc(u8, cw * ch);
        errdefer gpa.free(cb);
        const cr = try gpa.alloc(u8, cw * ch);
        @memset(y, 0);
        @memset(cb, 0);
        @memset(cr, 0);
        return .{
            .width = width,
            .height = height,
            .chroma_width = cw,
            .chroma_height = ch,
            .y = y,
            .cb = cb,
            .cr = cr,
        };
    }

    fn deinit(self: *Planes, gpa: std.mem.Allocator) void {
        gpa.free(self.y);
        gpa.free(self.cb);
        gpa.free(self.cr);
        self.* = undefined;
    }
};

/// Holds the reference picture between frames. An I-frame discards it; a
/// disposable P-frame decodes against it without replacing it.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    reference: ?Planes = null,

    pub fn init(gpa: std.mem.Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.reference) |*r| r.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn decode(self: *Decoder, data: []const u8) Error!Frame {
        return decodePicture(self, data);
    }
};

// --- bitstream --------------------------------------------------------------

const Bits = struct {
    data: []const u8,
    pos: usize = 0, // in BITS

    fn read(self: *Bits, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (self.pos + n > self.data.len * 8) return error.Corrupt;
        var out: u32 = 0;
        var left = n;
        while (left > 0) : (left -= 1) {
            const byte = self.data[self.pos >> 3];
            const bit = @as(u3, @intCast(7 - (self.pos & 7)));
            out = (out << 1) | ((byte >> bit) & 1);
            self.pos += 1;
        }
        return out;
    }

    fn readSigned(self: *Bits, n: u6) Error!i16 {
        const raw = try self.read(n);
        const sign_bit = @as(u32, 1) << @as(u5, @intCast(n - 1));
        if (raw & sign_bit != 0) {
            return @intCast(@as(i32, @intCast(raw)) - (@as(i32, 1) << @as(u5, @intCast(n))));
        }
        return @intCast(raw);
    }

    fn atEnd(self: *const Bits) bool {
        return self.pos >= self.data.len * 8;
    }
};

fn walkMcbpc(bits: *Bits, table: []const McbpcNode) Error!McbpcNode {
    var i: usize = 0;
    while (true) {
        if (i >= table.len) return error.Corrupt;
        switch (table[i]) {
            .fork => |f| i = f[try bits.read(1)],
            else => return table[i],
        }
    }
}

fn walkCbpy(bits: *Bits) Error![4]bool {
    var i: usize = 0;
    while (true) {
        if (i >= tables.cbpy_table.len) return error.Corrupt;
        switch (tables.cbpy_table[i]) {
            .fork => |f| i = f[try bits.read(1)],
            .valid => |v| return v,
            .invalid => return error.Corrupt,
        }
    }
}

fn walkMvd(bits: *Bits) Error!i16 {
    var i: usize = 0;
    while (true) {
        if (i >= tables.mvd_table.len) return error.Corrupt;
        switch (tables.mvd_table[i]) {
            .fork => |f| i = f[try bits.read(1)],
            .halfpel => |h| return h,
            .invalid => return error.Corrupt,
        }
    }
}

fn walkTcoef(bits: *Bits) Error!tables.TcoefNode {
    var i: usize = 0;
    while (true) {
        if (i >= tables.tcoef_table.len) return error.Corrupt;
        switch (tables.tcoef_table[i]) {
            .fork => |f| i = f[try bits.read(1)],
            .invalid => return error.Corrupt,
            else => return tables.tcoef_table[i],
        }
    }
}

// --- picture header ---------------------------------------------------------

const PictureType = enum { intra, inter, disposable_inter };

const Header = struct {
    version: u32,
    temporal_reference: u32,
    width: usize,
    height: usize,
    picture_type: PictureType,
    deblock: bool,
    quantizer: u8,
};

fn parseHeader(bits: *Bits) Error!Header {
    if (try bits.read(17) != 1) return error.Corrupt;
    const version = try bits.read(5);
    const temporal_reference = try bits.read(8);

    var width: usize = 0;
    var height: usize = 0;
    switch (try bits.read(3)) {
        0 => {
            width = try bits.read(8);
            height = try bits.read(8);
        },
        1 => {
            width = try bits.read(16);
            height = try bits.read(16);
        },
        2 => {
            width = 352;
            height = 288;
        },
        3 => {
            width = 176;
            height = 144;
        },
        4 => {
            width = 128;
            height = 96;
        },
        5 => {
            width = 320;
            height = 240;
        },
        6 => {
            width = 160;
            height = 120;
        },
        else => return error.Corrupt,
    }
    if (width == 0 or height == 0) return error.Corrupt;

    const picture_type: PictureType = switch (try bits.read(2)) {
        0 => .intra,
        1 => .inter,
        2 => .disposable_inter,
        else => return error.Corrupt,
    };
    const deblock = try bits.read(1) == 1;
    const quantizer: u8 = @intCast(try bits.read(5));

    // PEI: each set bit says another byte of extra information follows.
    while (try bits.read(1) == 1) _ = try bits.read(8);

    return .{
        .version = version,
        .temporal_reference = temporal_reference,
        .width = width,
        .height = height,
        .picture_type = picture_type,
        .deblock = deblock,
        .quantizer = quantizer,
    };
}

// --- coefficients -----------------------------------------------------------

/// Zig-zag order as (x, y), H.263 Figure 7.
const DEZIGZAG = [64][2]u8{
    .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 1 }, .{ 2, 0 }, .{ 3, 0 }, .{ 2, 1 },
    .{ 1, 2 }, .{ 0, 3 }, .{ 0, 4 }, .{ 1, 3 }, .{ 2, 2 }, .{ 3, 1 }, .{ 4, 0 }, .{ 5, 0 },
    .{ 4, 1 }, .{ 3, 2 }, .{ 2, 3 }, .{ 1, 4 }, .{ 0, 5 }, .{ 0, 6 }, .{ 1, 5 }, .{ 2, 4 },
    .{ 3, 3 }, .{ 4, 2 }, .{ 5, 1 }, .{ 6, 0 }, .{ 7, 0 }, .{ 6, 1 }, .{ 5, 2 }, .{ 4, 3 },
    .{ 3, 4 }, .{ 2, 5 }, .{ 1, 6 }, .{ 0, 7 }, .{ 1, 7 }, .{ 2, 6 }, .{ 3, 5 }, .{ 4, 4 },
    .{ 5, 3 }, .{ 6, 2 }, .{ 7, 1 }, .{ 7, 2 }, .{ 6, 3 }, .{ 5, 4 }, .{ 4, 5 }, .{ 3, 6 },
    .{ 2, 7 }, .{ 3, 7 }, .{ 4, 6 }, .{ 5, 5 }, .{ 6, 4 }, .{ 7, 3 }, .{ 7, 4 }, .{ 6, 5 },
    .{ 5, 6 }, .{ 4, 7 }, .{ 5, 7 }, .{ 6, 6 }, .{ 7, 5 }, .{ 7, 6 }, .{ 6, 7 }, .{ 7, 7 },
};

/// One 8x8 block of dequantised coefficients. The two degenerate shapes
/// are kept apart because their arithmetic is shorter, not merely faster:
/// a DC-only block skips the transform entirely and rounds once.
const DctBlock = union(enum) {
    zero,
    dc: f32,
    full: [8][8]f32,
};

/// An INTRA block's DC is a fixed 8-bit code, and two of its values are
/// illegal (H.263 Table 15). 255 means 1024, everything else is `v << 3`.
fn intraDcLevel(v: u8) ?i16 {
    if (v == 0 or v == 128) return null;
    if (v == 0xFF) return 1024;
    return @as(i16, v) << 3;
}

/// Read one block's coefficients and place them, dezigzagged and
/// dequantised, into `out`.
fn decodeBlock(
    bits: *Bits,
    version: u32,
    is_intra: bool,
    has_coefficients: bool,
    quant: u8,
    out: *DctBlock,
) Error!void {
    var dc_level: ?i16 = null;
    if (is_intra) {
        const raw: u8 = @intCast(try bits.read(8));
        dc_level = intraDcLevel(raw) orelse return error.Corrupt;
    }

    var block: [8][8]f32 = @splat(@splat(0));
    var any_coefficient = false;
    var zigzag: usize = 0;
    if (dc_level) |dc| {
        block[0][0] = @floatFromInt(dc);
        zigzag = 1;
    }

    var more = has_coefficients;
    while (more) {
        const node = try walkTcoef(bits);
        var run: u32 = 0;
        var level: i32 = 0;
        var last = false;
        switch (node) {
            .escape => {
                // Sorenson version 1 picks the level width with a flag;
                // plain H.263 always spends 8 bits.
                const width: u6 = if (version == 1)
                    (if (try bits.read(1) == 1) @as(u6, 11) else 7)
                else
                    8;
                last = try bits.read(1) == 1;
                run = try bits.read(6);
                const l = try bits.readSigned(width);
                if (l == 0) return error.Corrupt;
                level = l;
            },
            .run => |r| {
                last = r.last;
                run = r.run;
                const sign = try bits.read(1);
                level = if (sign == 1) -@as(i32, r.level) else @as(i32, r.level);
            },
            else => return error.Corrupt,
        }

        zigzag += run;
        if (zigzag >= DEZIGZAG.len) {
            // Ruffle abandons the block rather than the picture.
            out.* = shapeOf(block, any_coefficient, dc_level != null);
            return;
        }
        const zz = DEZIGZAG[zigzag];
        // H.263 6.2.1: the reconstruction level, with the parity of even
        // quantisers pulled back by one.
        const magnitude = @as(i32, quant) * ((2 * @as(i32, @intCast(@abs(level)))) + 1);
        const parity: i32 = if (quant % 2 == 1) 0 else -1;
        const signed = std.math.sign(level) * (magnitude + parity);
        const value: f32 = @floatFromInt(std.math.clamp(signed, -2048, 2047));
        block[zz[1]][zz[0]] = value;
        zigzag += 1;
        if (value != 0) any_coefficient = true;

        more = !last;
    }

    out.* = shapeOf(block, any_coefficient, dc_level != null);
}

fn shapeOf(block: [8][8]f32, any_ac: bool, has_dc: bool) DctBlock {
    if (!any_ac) {
        if (!has_dc or block[0][0] == 0) return .zero;
        return .{ .dc = block[0][0] };
    }
    return .{ .full = block };
}

// --- inverse DCT ------------------------------------------------------------

/// cos(pi * (x + 0.5) * f / 8), with the DC row pre-scaled by 1/sqrt(2).
/// Kept as the f32 constants the reference computes so the rounding at
/// `x/4 + 0.5` lands on the same side.
const BASIS: [8][8]f32 = .{
    .{ 0.70710677, 0.70710677, 0.70710677, 0.70710677, 0.70710677, 0.70710677, 0.70710677, 0.70710677 },
    .{ 0.98078525, 0.8314696, 0.5555702, 0.19509023, -0.19509032, -0.55557036, -0.83146966, -0.9807853 },
    .{ 0.9238795, 0.38268343, -0.38268352, -0.9238796, -0.9238795, -0.38268313, 0.3826836, 0.92387956 },
    .{ 0.8314696, -0.19509032, -0.9807853, -0.55557, 0.55557007, 0.98078525, 0.19509007, -0.8314698 },
    .{ 0.70710677, -0.70710677, -0.70710665, 0.707107, 0.70710677, -0.70710725, -0.70710653, 0.7071068 },
    .{ 0.5555702, -0.9807853, 0.19509041, 0.83146936, -0.8314698, -0.19508928, 0.9807853, -0.55557007 },
    .{ 0.38268343, -0.9238795, 0.92387974, -0.3826839, -0.38268384, 0.9238793, -0.92387974, 0.3826839 },
    .{ 0.19509023, -0.55557, 0.83146936, -0.9807852, 0.98078525, -0.83147013, 0.55557114, -0.19508967 },
};

fn idct1d(input: *const [8]f32, output: *[8]f32) void {
    output.* = @splat(0);
    for (0..8) |i| {
        var acc: f32 = 0;
        for (0..8) |freq| acc += input[freq] * BASIS[freq][i];
        output[i] = acc;
    }
}

fn signum(x: f32) f32 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}

/// Rust's `as i16` truncates toward zero and saturates; the +/-0.5 that
/// precedes it is what turns truncation into round-half-away-from-zero.
fn clipIdct(v: f32) i16 {
    const t = @trunc(v);
    if (t >= 32767) return 32767;
    if (t <= -32768) return -32768;
    return std.math.clamp(@as(i16, @intFromFloat(t)), -256, 255);
}

/// Transform a plane's worth of blocks and ADD them to `output`, which
/// already holds the motion-compensated prediction (zeroes for an intra
/// picture). Blocks that hang off the right or bottom edge are clipped,
/// because the plane is the picture's size and the grid is not.
fn idctPlane(
    levels: []const DctBlock,
    output: []u8,
    blk_per_line: usize,
    samples_per_line: usize,
) void {
    if (samples_per_line == 0) return;
    const out_height = output.len / samples_per_line;
    const blk_height = levels.len / blk_per_line;

    var intermediate: [8][8]f32 = @splat(@splat(0));
    var transformed: [8][8]f32 = @splat(@splat(0));

    var y_base: usize = 0;
    while (y_base < blk_height) : (y_base += 1) {
        var x_base: usize = 0;
        while (x_base < blk_per_line) : (x_base += 1) {
            const block_id = x_base + y_base * blk_per_line;
            if (block_id >= levels.len) continue;
            const xs: usize = @intCast(std.math.clamp(
                @as(isize, @intCast(samples_per_line)) - @as(isize, @intCast(x_base * 8)),
                0,
                8,
            ));
            const ys: usize = @intCast(std.math.clamp(
                @as(isize, @intCast(out_height)) - @as(isize, @intCast(y_base * 8)),
                0,
                8,
            ));

            switch (levels[block_id]) {
                .zero => {},
                .dc => |dc| {
                    // The extra 0.5 is BASIS[0][0]^2: a DC-only block would
                    // otherwise take the 1/sqrt(2) scaling twice.
                    const flat = clipIdct(dc * 0.5 / 4.0 + signum(dc) * 0.5);
                    for (0..ys) |y_off| {
                        for (0..xs) |x_off| {
                            const o = (x_base * 8 + x_off) + (y_base * 8 + y_off) * samples_per_line;
                            output[o] = addClamped(output[o], flat);
                        }
                    }
                },
                .full => |data| {
                    for (0..8) |row| {
                        idct1d(&data[row], &transformed[row]);
                        // Transposed on the way in, undone on the way out.
                        for (0..8) |i| intermediate[i][row] = transformed[row][i];
                    }
                    for (0..8) |row| idct1d(&intermediate[row], &transformed[row]);
                    for (0..xs) |x_off| {
                        for (0..ys) |y_off| {
                            const v = transformed[x_off][y_off];
                            const s = clipIdct(v / 4.0 + signum(v) * 0.5);
                            const o = (x_base * 8 + x_off) + (y_base * 8 + y_off) * samples_per_line;
                            output[o] = addClamped(output[o], s);
                        }
                    }
                },
            }
        }
    }
}

fn addClamped(base: u8, delta: i16) u8 {
    return @intCast(std.math.clamp(@as(i16, base) + delta, 0, 255));
}

// --- motion vectors ---------------------------------------------------------

const Mv = struct {
    x: i16 = 0, // half-pel
    y: i16 = 0,
};

fn medianOf(a: i16, b: i16, c: i16) i16 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// H.263 6.1.1: the candidate is the median of the vector to the left, the
/// one above, and the one above-right, with the edges of the picture
/// substituting zero or the left-hand candidate.
fn predictCandidate(
    predictors: []const [4]Mv,
    current: *const [4]Mv,
    mb_per_line: usize,
    index: usize,
) Mv {
    const current_mb = predictors.len;
    const col = current_mb % mb_per_line;
    const mv1: Mv = switch (index) {
        0, 2 => if (col == 0) .{} else predictors[current_mb - 1][index + 1],
        else => current[index - 1],
    };

    const line = current_mb / mb_per_line;
    const last_line_mb = (line -| 1) * mb_per_line + col;
    const mv2: Mv = switch (index) {
        0, 1 => if (line == 0)
            mv1
        else if (last_line_mb < predictors.len)
            predictors[last_line_mb][index + 2]
        else
            mv1,
        else => current[0],
    };

    const end_of_line = col == mb_per_line -| 1;
    const mv3: Mv = switch (index) {
        0, 1 => if (end_of_line)
            .{}
        else if (line == 0)
            mv1
        else if (last_line_mb + 1 < predictors.len)
            predictors[last_line_mb + 1][2]
        else
            mv1,
        else => current[1],
    };

    return .{
        .x = medianOf(mv1.x, mv2.x, mv3.x),
        .y = medianOf(mv1.y, mv2.y, mv3.y),
    };
}

/// A differential that leaves the restricted range means the OTHER entry
/// of H.263 Table 14 was meant — the range wraps rather than saturates.
fn halfpelDecode(predictor: i16, mvd: i16) i16 {
    const out = mvd + predictor;
    if (-32 <= out and out < 32) return out;
    const inverted: i16 = if (mvd > 0) mvd - 64 else if (mvd < 0) mvd + 64 else mvd;
    return inverted + predictor;
}

/// The chroma vector is the sum of the four luma vectors, divided by eight
/// and rounded to the nearest FULL pixel (H.263 6.1.1).
fn averageSumOfMvs(sum: i16) i16 {
    const whole = (sum >> 4) << 1;
    const frac = sum & 0x0F;
    if (frac <= 2) return whole;
    if (frac >= 14) return whole + 2;
    return whole + 1;
}

fn lerpParameters(hp: i16) struct { delta: i16, interp: bool } {
    if (@rem(hp, 2) == 0) return .{ .delta = @divTrunc(hp, 2), .interp = false };
    if (hp < 0) return .{ .delta = @divTrunc(hp, 2) - 1, .interp = true };
    return .{ .delta = @divTrunc(hp, 2), .interp = true };
}

fn readSample(plane: []const u8, per_row: usize, rows: usize, x: isize, y: isize) u8 {
    const cx: usize = @intCast(std.math.clamp(x, 0, @as(isize, @intCast(per_row -| 1))));
    const cy: usize = @intCast(std.math.clamp(y, 0, @as(isize, @intCast(rows -| 1))));
    return plane[cx + cy * per_row];
}

fn lerp(a: u8, b: u8, middle: bool) u8 {
    if (!middle) return a;
    return @intCast((@as(u16, a) + @as(u16, b) + 1) / 2);
}

/// Motion-compensate one 8x8 block from the reference plane into `target`.
fn gatherBlock(
    source: []const u8,
    per_row: usize,
    x0: usize,
    y0: usize,
    mv: Mv,
    target: []u8,
) void {
    const xp = lerpParameters(mv.x);
    const yp = lerpParameters(mv.y);
    const src_x = @as(isize, @intCast(x0)) + xp.delta;
    const src_y = @as(isize, @intCast(y0)) + yp.delta;
    const rows = source.len / per_row;
    const cols_i = std.math.clamp(@as(isize, @intCast(per_row)) - @as(isize, @intCast(x0)), 0, 8);
    const rows_i = std.math.clamp(@as(isize, @intCast(rows)) - @as(isize, @intCast(y0)), 0, 8);
    const cols: usize = @intCast(cols_i);
    const block_rows: usize = @intCast(rows_i);

    var j: usize = 0;
    while (j < block_rows) : (j += 1) {
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            const u = src_x + @as(isize, @intCast(i));
            const v = src_y + @as(isize, @intCast(j));
            const o = x0 + i + (y0 + j) * per_row;
            if (!xp.interp and !yp.interp) {
                target[o] = readSample(source, per_row, rows, u, v);
            } else if (xp.interp and yp.interp) {
                // Round ONCE, after summing all four taps.
                const s = @as(u16, readSample(source, per_row, rows, u, v)) +
                    @as(u16, readSample(source, per_row, rows, u + 1, v)) +
                    @as(u16, readSample(source, per_row, rows, u, v + 1)) +
                    @as(u16, readSample(source, per_row, rows, u + 1, v + 1));
                target[o] = @intCast((s + 2) / 4);
            } else {
                const top = lerp(
                    readSample(source, per_row, rows, u, v),
                    readSample(source, per_row, rows, u + 1, v),
                    xp.interp,
                );
                const bottom = lerp(
                    readSample(source, per_row, rows, u, v + 1),
                    readSample(source, per_row, rows, u + 1, v + 1),
                    xp.interp,
                );
                target[o] = lerp(top, bottom, yp.interp);
            }
        }
    }
}

// --- deblocking (Annex J, as a post-process) --------------------------------

/// Table J.2: quantiser to filter strength. Index 0 is never used.
const QUANT_TO_STRENGTH = [32]u8{
    0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 7,
    7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 12,
};

fn upDownRamp(x: i16, strength: i16) i16 {
    const magnitude: i16 = @intCast(@abs(x));
    const ramped: i16 = @max(magnitude - @max(2 * (magnitude - strength), 0), 0);
    const sign: i16 = std.math.sign(x);
    return sign * ramped;
}

/// The filter reads two samples either side of a block edge. `shift`
/// selects arithmetic shift over truncating division — the reference has
/// a vector path that floors and a scalar tail that truncates, and they
/// disagree on negatives, so which one runs where is observable.
fn filterEdge(a: *u8, b: *u8, c: *u8, d: *u8, strength: u8, shift: bool) void {
    const a16: i16 = @intCast(a.*);
    const b16: i16 = @intCast(b.*);
    const c16: i16 = @intCast(c.*);
    const d16: i16 = @intCast(d.*);

    const raw = a16 - 4 * b16 + 4 * c16 - d16;
    const d_val: i16 = if (shift) raw >> 3 else @divTrunc(raw, 8);
    const d1 = upDownRamp(d_val, @intCast(strength));
    const half_d1: i16 = if (shift) d1 >> 1 else @divTrunc(d1, 2);
    const quarter: i16 = if (shift) (a16 - d16) >> 2 else @divTrunc(a16 - d16, 4);
    const lim = @abs(half_d1);
    const d2 = std.math.clamp(quarter, -@as(i16, @intCast(lim)), @as(i16, @intCast(lim)));

    a.* = @truncate(@as(u16, @bitCast(a16 - d2)));
    b.* = @intCast(std.math.clamp(b16 + d1, 0, 255));
    c.* = @intCast(std.math.clamp(c16 - d1, 0, 255));
    d.* = @truncate(@as(u16, @bitCast(d16 + d2)));
}

fn deblockPlane(plane: []u8, width: usize, strength: u8) void {
    if (strength == 0 or width == 0) return;
    const height = plane.len / width;

    // Horizontal edges first, as the spec requires.
    if (height >= 2) {
        var edge_y: usize = 8;
        while (edge_y <= height - 2) : (edge_y += 8) {
            const base = (edge_y - 2) * width;
            const whole = width - width % 8;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                filterEdge(
                    &plane[base + x],
                    &plane[base + width + x],
                    &plane[base + 2 * width + x],
                    &plane[base + 3 * width + x],
                    strength,
                    x < whole,
                );
            }
        }
    }

    // Vertical edges. The reference skips the first two columns so that
    // each 8-wide chunk carries the quartet in its second half.
    if (width >= 10) {
        const vector_rows = height - height % 8;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const row = y * width;
            var chunk: usize = 2;
            while (chunk + 8 <= width) : (chunk += 8) {
                filterEdge(
                    &plane[row + chunk + 4],
                    &plane[row + chunk + 5],
                    &plane[row + chunk + 6],
                    &plane[row + chunk + 7],
                    strength,
                    y < vector_rows,
                );
            }
        }
    }
}

// --- YUV to RGB -------------------------------------------------------------

/// BT.601, limited range expanded to full, in 16.16 fixed point — the
/// same constants as ruffle's `h263-rs-yuv`, because rounding differences
/// here are visible as off-by-one pixels everywhere.
fn yuvToRgba(y: u8, cb: u8, cr: u8, out: *[4]u8) void {
    const yy = (@as(i32, y) - 16) * 76309;
    const u = @as(i32, cb) - 128;
    const v = @as(i32, cr) - 128;
    const half: i32 = 32768;
    const r = (yy + v * 104597 + half) >> 16;
    const g = (yy + v * -53279 + u * -25675 + half) >> 16;
    const b = (yy + u * 132201 + half) >> 16;
    out[0] = @intCast(std.math.clamp(r, 0, 255));
    out[1] = @intCast(std.math.clamp(g, 0, 255));
    out[2] = @intCast(std.math.clamp(b, 0, 255));
    out[3] = 255;
}

/// 4:2:0 to RGBA with NO chroma interpolation: one chroma sample paints
/// all four of its pixels, which is what Flash Player does.
fn planesToRgba(gpa: std.mem.Allocator, p: *const Planes) Error![]u8 {
    const rgba = try gpa.alloc(u8, p.width * p.height * 4);
    for (0..p.height) |y| {
        const crow = (y / 2) * p.chroma_width;
        for (0..p.width) |x| {
            const c = crow + x / 2;
            yuvToRgba(
                p.y[y * p.width + x],
                p.cb[c],
                p.cr[c],
                rgba[(y * p.width + x) * 4 ..][0..4],
            );
        }
    }
    return rgba;
}

// --- the picture loop -------------------------------------------------------

fn decodePicture(dec: *Decoder, data: []const u8) Error!Frame {
    const gpa = dec.gpa;
    var bits: Bits = .{ .data = data };
    const header = try parseHeader(&bits);

    const mb_per_line = (header.width + 15) / 16;
    const mb_rows = (header.height + 15) / 16;
    const mb_count = mb_per_line * mb_rows;

    var picture = try Planes.init(gpa, header.width, header.height);
    errdefer picture.deinit(gpa);

    const luma_blocks = mb_count * 4;
    const chroma_blocks = mb_count;
    const levels = try gpa.alloc(DctBlock, luma_blocks + 2 * chroma_blocks);
    defer gpa.free(levels);
    @memset(levels, .zero);
    const luma_levels = levels[0..luma_blocks];
    const cb_levels = levels[luma_blocks..][0..chroma_blocks];
    const cr_levels = levels[luma_blocks + chroma_blocks ..][0..chroma_blocks];
    const luma_blk_per_line = mb_per_line * 2;

    const mb_kinds = try gpa.alloc(?MbKind, mb_count);
    defer gpa.free(mb_kinds);
    @memset(mb_kinds, null);
    const predictors = try gpa.alloc([4]Mv, mb_count);
    defer gpa.free(predictors);

    var quant = header.quantizer;
    var index: usize = 0;
    mb_loop: while (index < mb_count) {
        var mvs: [4]Mv = @splat(.{});
        const kind: MbKind = blk: {
            if (bits.atEnd()) break :mb_loop;
            // A P-picture may say a macroblock is unchanged; an I-picture
            // has no such bit and every macroblock is coded.
            if (header.picture_type != .intra) {
                const coded = bits.read(1) catch break :mb_loop;
                if (coded == 1) break :blk .inter; // uncoded: pure prediction
            }
            const table: []const McbpcNode = if (header.picture_type == .intra)
                &tables.mcbpc_i_table
            else
                &tables.mcbpc_p_table;
            const entry = walkMcbpc(&bits, table) catch break :mb_loop;
            switch (entry) {
                .stuffing => continue,
                .invalid, .fork => break :mb_loop,
                .valid => |v| {
                    const luma_pattern = walkCbpy(&bits) catch break :mb_loop;
                    const codes_luma: [4]bool = if (v.kind.isIntra())
                        luma_pattern
                    else
                        .{ !luma_pattern[0], !luma_pattern[1], !luma_pattern[2], !luma_pattern[3] };

                    if (v.kind.hasQuant()) {
                        const dq: i8 = switch (bits.read(2) catch break :mb_loop) {
                            0 => -1,
                            1 => -2,
                            2 => 1,
                            else => 2,
                        };
                        quant = @intCast(std.math.clamp(@as(i8, @intCast(quant)) + dq, 1, 31));
                    }

                    if (v.kind.isInter()) {
                        const count: usize = if (v.kind.hasFourVec()) 4 else 1;
                        for (0..count) |i| {
                            const pred = predictCandidate(predictors[0..index], &mvs, mb_per_line, i);
                            const dx = walkMvd(&bits) catch break :mb_loop;
                            const dy = walkMvd(&bits) catch break :mb_loop;
                            mvs[i] = .{
                                .x = halfpelDecode(pred.x, dx),
                                .y = halfpelDecode(pred.y, dy),
                            };
                        }
                        if (!v.kind.hasFourVec()) {
                            mvs[1] = mvs[0];
                            mvs[2] = mvs[0];
                            mvs[3] = mvs[0];
                        }
                    }

                    const mb_x = (index % mb_per_line) * 2;
                    const mb_y = (index / mb_per_line) * 2;
                    const is_intra = v.kind.isIntra();
                    const corners = [4][2]usize{
                        .{ mb_x, mb_y },
                        .{ mb_x + 1, mb_y },
                        .{ mb_x, mb_y + 1 },
                        .{ mb_x + 1, mb_y + 1 },
                    };
                    for (corners, codes_luma) |c, present| {
                        decodeBlock(
                            &bits,
                            header.version,
                            is_intra,
                            present,
                            quant,
                            &luma_levels[c[0] + c[1] * luma_blk_per_line],
                        ) catch break :mb_loop;
                    }
                    decodeBlock(&bits, header.version, is_intra, v.cb, quant, &cb_levels[index]) catch break :mb_loop;
                    decodeBlock(&bits, header.version, is_intra, v.cr, quant, &cr_levels[index]) catch break :mb_loop;
                    break :blk v.kind;
                },
            }
        };
        mb_kinds[index] = kind;
        predictors[index] = mvs;
        index += 1;
    }

    // A picture that ran out of bits leaves the rest as unchanged INTER
    // macroblocks with a zero vector.
    for (mb_kinds) |*k| {
        if (k.* == null) k.* = .inter;
    }

    // Motion compensation fills the prediction; the IDCT adds the residual.
    if (header.picture_type != .intra) {
        if (dec.reference) |*ref| {
            if (ref.width == picture.width and ref.height == picture.height) {
                for (mb_kinds, predictors, 0..) |k, mv, i| {
                    if (k.?.isIntra()) continue;
                    const x0 = (i % mb_per_line) * 16;
                    const y0 = (i / mb_per_line) * 16;
                    gatherBlock(ref.y, ref.width, x0, y0, mv[0], picture.y);
                    gatherBlock(ref.y, ref.width, x0 + 8, y0, mv[1], picture.y);
                    gatherBlock(ref.y, ref.width, x0, y0 + 8, mv[2], picture.y);
                    gatherBlock(ref.y, ref.width, x0 + 8, y0 + 8, mv[3], picture.y);
                    const chroma_mv: Mv = .{
                        .x = averageSumOfMvs(mv[0].x +% mv[1].x +% mv[2].x +% mv[3].x),
                        .y = averageSumOfMvs(mv[0].y +% mv[1].y +% mv[2].y +% mv[3].y),
                    };
                    const cx = (i % mb_per_line) * 8;
                    const cy = (i / mb_per_line) * 8;
                    gatherBlock(ref.cb, ref.chroma_width, cx, cy, chroma_mv, picture.cb);
                    gatherBlock(ref.cr, ref.chroma_width, cx, cy, chroma_mv, picture.cr);
                }
            }
        }
    }

    idctPlane(luma_levels, picture.y, luma_blk_per_line, picture.width);
    idctPlane(cb_levels, picture.cb, mb_per_line, picture.chroma_width);
    idctPlane(cr_levels, picture.cr, mb_per_line, picture.chroma_width);

    // The reference picture is the UNFILTERED one: deblocking is a
    // post-process on the way out, not a loop filter.
    if (header.picture_type == .intra) {
        if (dec.reference) |*r| {
            r.deinit(gpa);
            dec.reference = null;
        }
    }

    var shown = picture;
    var filtered: ?Planes = null;
    if (header.deblock and header.quantizer < QUANT_TO_STRENGTH.len) {
        const strength = QUANT_TO_STRENGTH[header.quantizer];
        if (strength > 0) {
            const copy = try Planes.init(gpa, picture.width, picture.height);
            @memcpy(copy.y, picture.y);
            @memcpy(copy.cb, picture.cb);
            @memcpy(copy.cr, picture.cr);
            deblockPlane(copy.y, copy.width, strength);
            deblockPlane(copy.cb, copy.chroma_width, strength);
            deblockPlane(copy.cr, copy.chroma_width, strength);
            filtered = copy;
            shown = copy;
        }
    }
    defer if (filtered) |*f| f.deinit(gpa);

    const rgba = try planesToRgba(gpa, &shown);
    errdefer gpa.free(rgba);

    if (header.picture_type != .disposable_inter) {
        if (dec.reference) |*r| r.deinit(gpa);
        dec.reference = picture;
    } else {
        picture.deinit(gpa);
    }

    return .{
        .width = @intCast(header.width),
        .height = @intCast(header.height),
        .rgba = rgba,
    };
}

test "an intra DC code of zero or 128 is illegal" {
    try std.testing.expectEqual(@as(?i16, null), intraDcLevel(0));
    try std.testing.expectEqual(@as(?i16, null), intraDcLevel(128));
    try std.testing.expectEqual(@as(?i16, 1024), intraDcLevel(255));
    try std.testing.expectEqual(@as(?i16, 8), intraDcLevel(1));
}

test "half-pel lerp parameters round toward negative infinity" {
    try std.testing.expectEqual(@as(i16, 0), lerpParameters(0).delta);
    try std.testing.expect(!lerpParameters(0).interp);
    try std.testing.expectEqual(@as(i16, 1), lerpParameters(2).delta);
    try std.testing.expect(lerpParameters(3).interp);
    try std.testing.expectEqual(@as(i16, 1), lerpParameters(3).delta);
    try std.testing.expectEqual(@as(i16, -2), lerpParameters(-3).delta);
    try std.testing.expect(lerpParameters(-3).interp);
}

test "a motion differential that leaves the range wraps to the other entry" {
    // Predictor 30, differential +4: 34 is outside [-32, 32), so the
    // negative twin (-60) is what was meant.
    try std.testing.expectEqual(@as(i16, -30), halfpelDecode(30, 4));
    try std.testing.expectEqual(@as(i16, 20), halfpelDecode(16, 4));
}

test "the chroma vector rounds the sum of four toward the nearest pixel" {
    try std.testing.expectEqual(@as(i16, 0), averageSumOfMvs(2));
    try std.testing.expectEqual(@as(i16, 1), averageSumOfMvs(4));
    try std.testing.expectEqual(@as(i16, 2), averageSumOfMvs(15));
    try std.testing.expectEqual(@as(i16, 2), averageSumOfMvs(16));
}
