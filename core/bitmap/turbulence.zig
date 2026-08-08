//! The Perlin generator behind `BitmapData.perlinNoise`.
//!
//! A port of the C reference implementation of SVG's `feTurbulence`,
//! which is what Flash uses — the same lattice, the same Park–Miller
//! generator seeding it, the same stitching arithmetic. `octave_offsets`
//! is Flash's addition on top.
//!
//! A leaf module: `std` only. `core/bitmap/operations.zig` drives it.
//!
//! Reference: reference/ruffle/core/src/bitmap/turbulence.rs, itself a
//! port of https://www.w3.org/TR/SVG11/filters.html#feTurbulenceElement.

const std = @import("std");

// Park & Miller, CACM 31(10) p. 1195: r = (a * r) mod m, split through
// q and r so the intermediate never leaves 32 bits. The same generator
// `noise()` uses, seeded differently.
const RAND_M: i64 = 2147483647; // 2^31 - 1
const RAND_A: i64 = 16807; // 7^5, a primitive root of m
const RAND_Q: i64 = 127773; // m / a
const RAND_R: i64 = 2836; // m % a

fn setupSeed(seed_in: i64) i64 {
    var seed = seed_in;
    if (seed <= 0) seed = -@rem(seed, RAND_M - 1) + 1;
    if (seed > RAND_M - 1) seed = RAND_M - 1;
    return seed;
}

fn random(seed: i64) i64 {
    var result = RAND_A * @rem(seed, RAND_Q) - RAND_R * @divTrunc(seed, RAND_Q);
    if (result <= 0) result += RAND_M;
    return result;
}

const B_SIZE: usize = 0x100;
const BM: i32 = 0xFF;
/// A large power of two added to every coordinate so the lattice index
/// is positive before the mask, which is what makes negative positions
/// work without a branch.
const PERLIN_N: i32 = 0x1000;

fn sCurve(t: f64) f64 {
    return t * t * (3.0 - 2.0 * t);
}

fn lerp(t: f64, a: f64, b: f64) f64 {
    return a + t * (b - a);
}

/// How a tile wraps onto itself, when `perlinNoise` is asked to stitch.
const StitchInfo = struct {
    width: i32,
    height: i32,
    wrap_x: i32,
    wrap_y: i32,
};

pub const Turbulence = struct {
    lattice_selector: [B_SIZE + B_SIZE + 2]i32,
    /// One gradient table per COLOUR CHANNEL — four independent noise
    /// fields drawn from one seeded stream.
    gradient: [4][B_SIZE + B_SIZE + 2][2]f64,

    pub fn fromSeed(seed_in: i64) Turbulence {
        var self: Turbulence = .{
            .lattice_selector = @splat(0),
            .gradient = @splat(@splat(@splat(0))),
        };
        var seed = setupSeed(seed_in);

        for (0..4) |k| {
            for (0..B_SIZE) |i| {
                self.lattice_selector[i] = @intCast(i);
                for (0..2) |j| {
                    seed = random(seed);
                    self.gradient[k][i][j] = @as(f64, @floatFromInt(
                        @rem(seed, @as(i64, B_SIZE + B_SIZE)) - @as(i64, B_SIZE),
                    )) / @as(f64, B_SIZE);
                }
                const g = &self.gradient[k][i];
                const s = @sqrt(g[0] * g[0] + g[1] * g[1]);
                g[0] /= s;
                g[1] /= s;
            }
        }
        // Fisher-Yates over the lattice, continuing the SAME stream.
        var i: usize = B_SIZE - 1;
        while (i >= 1) : (i -= 1) {
            const k = self.lattice_selector[i];
            seed = random(seed);
            const j: usize = @intCast(@rem(seed, @as(i64, B_SIZE)));
            self.lattice_selector[i] = self.lattice_selector[j];
            self.lattice_selector[j] = k;
        }
        // Duplicate the table so an index can run two past the end
        // without wrapping arithmetic in the inner loop.
        for (0..B_SIZE + 2) |n| {
            self.lattice_selector[B_SIZE + n] = self.lattice_selector[n];
            for (0..4) |k| {
                for (0..2) |j| self.gradient[k][B_SIZE + n][j] = self.gradient[k][n][j];
            }
        }
        return self;
    }

    fn noise2(self: *const Turbulence, channel: usize, vx: f64, vy: f64, stitch: ?StitchInfo) f64 {
        const tx = vx + @as(f64, PERLIN_N);
        var bx0: i32 = @intFromFloat(tx);
        var bx1: i32 = bx0 + 1;
        const rx0 = tx - @as(f64, @floatFromInt(@as(i32, @intFromFloat(tx))));
        const rx1 = rx0 - 1.0;

        const ty = vy + @as(f64, PERLIN_N);
        var by0: i32 = @intFromFloat(ty);
        var by1: i32 = by0 + 1;
        const ry0 = ty - @as(f64, @floatFromInt(@as(i32, @intFromFloat(ty))));
        const ry1 = ry0 - 1.0;

        if (stitch) |st| {
            if (bx0 >= st.wrap_x) bx0 -= st.width;
            if (bx1 >= st.wrap_x) bx1 -= st.width;
            if (by0 >= st.wrap_y) by0 -= st.height;
            if (by1 >= st.wrap_y) by1 -= st.height;
        }

        bx0 &= BM;
        bx1 &= BM;
        by0 &= BM;
        by1 &= BM;

        const i = self.lattice_selector[@intCast(bx0)];
        const j = self.lattice_selector[@intCast(bx1)];
        const b00 = self.lattice_selector[@intCast(i + by0)];
        const b10 = self.lattice_selector[@intCast(j + by0)];
        const b01 = self.lattice_selector[@intCast(i + by1)];
        const b11 = self.lattice_selector[@intCast(j + by1)];

        const sx = sCurve(rx0);
        const sy = sCurve(ry0);

        var q = self.gradient[channel][@intCast(b00)];
        const ua = rx0 * q[0] + ry0 * q[1];
        q = self.gradient[channel][@intCast(b10)];
        const va = rx1 * q[0] + ry0 * q[1];
        const a = lerp(sx, ua, va);

        q = self.gradient[channel][@intCast(b01)];
        const ub = rx0 * q[0] + ry1 * q[1];
        q = self.gradient[channel][@intCast(b11)];
        const vb = rx1 * q[0] + ry1 * q[1];
        const b = lerp(sx, ub, vb);

        return lerp(sy, a, b);
    }

    /// Sum `num_octaves` octaves at one point. `fractal_sum` keeps the
    /// signed noise; otherwise each octave's magnitude is taken, which is
    /// the "turbulence" of the name.
    pub fn turbulence(
        self: *const Turbulence,
        channel: usize,
        point: [2]f64,
        base_freq_in: [2]f64,
        num_octaves: usize,
        fractal_sum: bool,
        do_stitching: bool,
        tile_pos: [2]f64,
        tile_size: [2]f64,
        octave_offsets: []const [2]f64,
    ) f64 {
        var base_freq = base_freq_in;
        var stitch: ?StitchInfo = null;
        if (do_stitching) {
            // A tile only joins itself if its frequency divides the tile
            // exactly, so each axis snaps to whichever neighbouring whole
            // number of cycles it is nearer to in RATIO terms.
            if (base_freq[0] != 0.0) {
                const lo = @floor(tile_size[0] * base_freq[0]) / tile_size[0];
                const hi = @ceil(tile_size[0] * base_freq[0]) / tile_size[0];
                base_freq[0] = if (base_freq[0] / lo < hi / base_freq[0]) lo else hi;
            }
            if (base_freq[1] != 0.0) {
                // NOT a typo: the low frequency for Y is computed from the
                // X base frequency. The reference implementation does this
                // and Flash inherits it.
                const lo = @floor(tile_size[1] * base_freq[0]) / tile_size[1];
                const hi = @ceil(tile_size[1] * base_freq[1]) / tile_size[1];
                base_freq[1] = if (base_freq[1] / lo < hi / base_freq[1]) lo else hi;
            }
            const w: i32 = @intFromFloat(tile_size[0] * base_freq[0] + 0.5);
            const h: i32 = @intFromFloat(tile_size[1] * base_freq[1] + 0.5);
            stitch = .{
                .width = w,
                .height = h,
                .wrap_x = @as(i32, @intFromFloat(tile_pos[0] * base_freq[0])) + PERLIN_N + w,
                .wrap_y = @as(i32, @intFromFloat(tile_pos[1] * base_freq[1])) + PERLIN_N + h,
            };
        }

        var sum: f64 = 0.0;
        var ratio: f64 = 1.0;
        for (0..num_octaves) |octave| {
            const offset = octave_offsets[octave];
            const vx = (point[0] + offset[0]) * base_freq[0] * ratio;
            const vy = (point[1] + offset[1]) * base_freq[1] * ratio;
            const n = self.noise2(channel, vx, vy, stitch);
            sum += (if (fractal_sum) n else @abs(n)) / ratio;
            ratio *= 2.0;
            if (stitch) |*st| {
                // Subtracting PERLIN_N before the doubling and adding it
                // back after simplifies to subtracting it once.
                st.width *= 2;
                st.wrap_x = 2 * st.wrap_x - PERLIN_N;
                st.height *= 2;
                st.wrap_y = 2 * st.wrap_y - PERLIN_N;
            }
        }
        return sum;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the Park-Miller stream is the one the reference specifies" {
    // "the algorithm should produce the result 1043618065 as the 10,000th
    // generated number if the original seed is 1" — the reference's own
    // self-test, and the thing that has to be right before any pixel is.
    var seed: i64 = 1;
    for (0..10000) |_| seed = random(seed);
    try testing.expectEqual(@as(i64, 1043618065), seed);
}

test "a non-positive seed is reflected into range" {
    try testing.expectEqual(@as(i64, 1), setupSeed(0));
    try testing.expectEqual(@as(i64, 6), setupSeed(-5));
    try testing.expectEqual(RAND_M - 1, setupSeed(RAND_M));
}

test "the lattice duplicates onto itself" {
    const t = Turbulence.fromSeed(42);
    for (0..B_SIZE + 2) |i| {
        try testing.expectEqual(t.lattice_selector[i], t.lattice_selector[B_SIZE + i]);
    }
    // Every gradient is a unit vector.
    for (0..4) |k| {
        for (0..B_SIZE) |i| {
            const g = t.gradient[k][i];
            try testing.expectApproxEqAbs(@as(f64, 1.0), @sqrt(g[0] * g[0] + g[1] * g[1]), 1e-9);
        }
    }
}
