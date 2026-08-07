//! General SWF bit/byte reader over the decompressed movie payload.
//!
//! Byte reads are little-endian and always byte-aligned; bit reads are
//! MSB-first within bytes and accumulate until `byteAlign` (any byte-level
//! read realigns first, matching ruffle's reader model). All reads bounds-
//! check and return `error.OutOfBounds` — real SWFs lie about lengths.
//!
//! References: reference/ruffle/swf/src/{extensions.rs,read.rs} (de-facto
//! binary spec), open-flash swf/primitives.md. LE32_FLOAT64 is the
//! byte-swapped double encoding used by AVM1 ActionPush type 6 (Ruffle
//! errata: byte order `45670123`, i.e. two little-endian u32 words with
//! the HIGH word first).

const std = @import("std");

pub const Error = error{OutOfBounds};

pub const TWIPS_PER_PX = 20;

/// Stage/shape bounds in twips.
pub const Rectangle = struct {
    xmin: i32 = 0,
    xmax: i32 = 0,
    ymin: i32 = 0,
    ymax: i32 = 0,

    pub fn width(r: Rectangle) i32 {
        return r.xmax - r.xmin;
    }
    pub fn height(r: Rectangle) i32 {
        return r.ymax - r.ymin;
    }
};

/// 2×3 affine. a/b/c/d are 16.16 fixed converted to f64; tx/ty are twips.
pub const Matrix = struct {
    a: f64 = 1.0,
    b: f64 = 0.0,
    c: f64 = 0.0,
    d: f64 = 1.0,
    tx: i32 = 0,
    ty: i32 = 0,

    pub const identity: Matrix = .{};
};

/// SWF CXFORM. Multipliers are raw signed 8.8 fixed (256 = 1.0) and adds
/// are [-255, 255] — byte-compatible with simdra's SmPaint.ColorTransform
/// ([r, g, b, a] order).
pub const ColorTransform = struct {
    mult: [4]i16 = .{ 256, 256, 256, 256 },
    add: [4]i16 = .{ 0, 0, 0, 0 },

    pub fn isIdentity(t: ColorTransform) bool {
        return std.meta.eql(t, .{});
    }
};

/// Packed RGBA (R in byte 0 — simdra/logical order). RGB reads get A=255.
pub const Color = u32;

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    /// Bit accumulator state; valid only between bit reads.
    bit_buf: u8 = 0,
    bit_count: u3 = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    /// Discard any partially-consumed byte (bit reads leave one pending).
    pub fn byteAlign(self: *Reader) void {
        self.bit_count = 0;
        self.bit_buf = 0;
    }

    // --- byte-level reads (auto-realign) ---------------------------------

    pub fn readSlice(self: *Reader, n: usize) Error![]const u8 {
        self.byteAlign();
        if (self.remaining() < n) return Error.OutOfBounds;
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    /// Everything from the cursor to the end (e.g. a tag's trailing blob).
    pub fn readRest(self: *Reader) []const u8 {
        self.byteAlign();
        const s = self.data[self.pos..];
        self.pos = self.data.len;
        return s;
    }

    pub fn skip(self: *Reader, n: usize) Error!void {
        _ = try self.readSlice(n);
    }

    pub fn readU8(self: *Reader) Error!u8 {
        return (try self.readSlice(1))[0];
    }

    pub fn readU16(self: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try self.readSlice(2))[0..2], .little);
    }

    pub fn readI16(self: *Reader) Error!i16 {
        return @bitCast(try self.readU16());
    }

    pub fn readU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.readSlice(4))[0..4], .little);
    }

    pub fn readI32(self: *Reader) Error!i32 {
        return @bitCast(try self.readU32());
    }

    /// FIXED8 — 8.8 signed fixed point (frame rates, morph ratios…).
    pub fn readFixed8(self: *Reader) Error!f32 {
        return @as(f32, @floatFromInt(try self.readI16())) / 256.0;
    }

    /// FIXED — 16.16 signed fixed point.
    pub fn readFixed16(self: *Reader) Error!f64 {
        return @as(f64, @floatFromInt(try self.readI32())) / 65536.0;
    }

    pub fn readF32(self: *Reader) Error!f32 {
        return @bitCast(try self.readU32());
    }

    /// LE32_FLOAT64 — the AVM1 double encoding: two little-endian u32
    /// words, HIGH word first (Ruffle errata "45670123", NOT plain LE).
    pub fn readF64Swapped(self: *Reader) Error!f64 {
        const hi = try self.readU32();
        const lo = try self.readU32();
        const bits = (@as(u64, hi) << 32) | @as(u64, lo);
        return @bitCast(bits);
    }

    /// Null-terminated string; returns the raw bytes WITHOUT the
    /// terminator. Encoding is SWF-version-dependent (≥6 UTF-8, <6
    /// ANSI/Shift-JIS) — callers transcode at their boundary (ADR D1).
    pub fn readString(self: *Reader) Error![]const u8 {
        self.byteAlign();
        const nul = std.mem.indexOfScalarPos(u8, self.data, self.pos, 0) orelse
            return Error.OutOfBounds;
        const s = self.data[self.pos..nul];
        self.pos = nul + 1;
        return s;
    }

    /// RGB triple → packed with alpha 255.
    pub fn readRgb(self: *Reader) Error!Color {
        const s = try self.readSlice(3);
        return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (0xFF << 24);
    }

    /// RGBA quad → packed.
    pub fn readRgba(self: *Reader) Error!Color {
        const s = try self.readSlice(4);
        return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
    }

    // --- bit-level reads (MSB-first) -------------------------------------

    pub fn readBit(self: *Reader) Error!bool {
        return (try self.readUb(1)) != 0;
    }

    /// UB[n] — unsigned big-endian bit field, n ≤ 32.
    pub fn readUb(self: *Reader, n: u6) Error!u32 {
        var v: u32 = 0;
        var left = n;
        while (left > 0) : (left -= 1) {
            if (self.bit_count == 0) {
                if (self.pos >= self.data.len) return Error.OutOfBounds;
                self.bit_buf = self.data[self.pos];
                self.pos += 1;
                self.bit_count = 7;
                v = (v << 1) | ((self.bit_buf >> 7) & 1);
                continue;
            }
            self.bit_count -= 1;
            v = (v << 1) | ((self.bit_buf >> self.bit_count) & 1);
        }
        return v;
    }

    /// SB[n] — signed (two's complement) bit field.
    pub fn readSb(self: *Reader, n: u6) Error!i32 {
        if (n == 0) return 0;
        const raw = try self.readUb(n);
        const shift: u5 = @intCast(32 - @as(u32, n));
        return @as(i32, @bitCast(raw << shift)) >> shift;
    }

    /// FB[n] — signed 16.16 fixed-point bit field as f64.
    pub fn readFb(self: *Reader, n: u6) Error!f64 {
        return @as(f64, @floatFromInt(try self.readSb(n))) / 65536.0;
    }

    // --- composite structures --------------------------------------------

    /// RECT — nbits:UB[5] then 4×SB[nbits] (twips). Realigns after.
    pub fn readRectangle(self: *Reader) Error!Rectangle {
        self.byteAlign();
        const nbits: u6 = @intCast(try self.readUb(5));
        const r: Rectangle = .{
            .xmin = try self.readSb(nbits),
            .xmax = try self.readSb(nbits),
            .ymin = try self.readSb(nbits),
            .ymax = try self.readSb(nbits),
        };
        self.byteAlign();
        return r;
    }

    /// MATRIX — optional scale (FB), optional rotate/skew (FB), translate
    /// (SB twips, always present). Realigns after.
    pub fn readMatrix(self: *Reader) Error!Matrix {
        self.byteAlign();
        var m: Matrix = .identity;
        if (try self.readBit()) {
            const n: u6 = @intCast(try self.readUb(5));
            m.a = try self.readFb(n);
            m.d = try self.readFb(n);
        }
        if (try self.readBit()) {
            const n: u6 = @intCast(try self.readUb(5));
            m.b = try self.readFb(n);
            m.c = try self.readFb(n);
        }
        const n: u6 = @intCast(try self.readUb(5));
        m.tx = try self.readSb(n);
        m.ty = try self.readSb(n);
        self.byteAlign();
        return m;
    }

    /// CXFORM / CXFORMWITHALPHA — has_add:1, has_mult:1, nbits:UB[4], then
    /// mult terms (signed 8.8 raw) and add terms, RGB(+A). Realigns after.
    pub fn readColorTransform(self: *Reader, has_alpha: bool) Error!ColorTransform {
        self.byteAlign();
        const has_add = try self.readBit();
        const has_mult = try self.readBit();
        const nbits: u6 = @intCast(try self.readUb(4));
        var t: ColorTransform = .{};
        const channels: usize = if (has_alpha) 4 else 3;
        if (has_mult) {
            for (0..channels) |i| t.mult[i] = @intCast(try self.readSb(nbits));
        }
        if (has_add) {
            for (0..channels) |i| t.add[i] = @intCast(try self.readSb(nbits));
        }
        self.byteAlign();
        return t;
    }
};

// --- Tests -----------------------------------------------------------------

test "byte reads: ints, fixed points, floats" {
    var r = Reader.init(&.{
        0x2A, // u8
        0x34, 0x12, // u16
        0x00, 0x18, // fixed8 = 24.0
        0x00, 0x80, 0x01, 0x00, // fixed16 = 1.5
        0x78, 0x56, 0x34, 0x12, // u32
    });
    try std.testing.expectEqual(@as(u8, 0x2A), try r.readU8());
    try std.testing.expectEqual(@as(u16, 0x1234), try r.readU16());
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), try r.readFixed8(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try r.readFixed16(), 0.00001);
    try std.testing.expectEqual(@as(u32, 0x12345678), try r.readU32());
    try std.testing.expect(r.atEnd());
    try std.testing.expectError(Error.OutOfBounds, r.readU8());
}

test "LE32_FLOAT64: high word first (errata 45670123)" {
    // 1.0 = 0x3FF0000000000000: high word 0x3FF00000 (LE: 00 00 F0 3F)
    // encoded FIRST, then low word 0x00000000.
    var r = Reader.init(&.{ 0x00, 0x00, 0xF0, 0x3F, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(f64, 1.0), try r.readF64Swapped());
    // -2.5 = 0xC004000000000000.
    var r2 = Reader.init(&.{ 0x00, 0x00, 0x04, 0xC0, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(f64, -2.5), try r2.readF64Swapped());
}

test "strings and colors" {
    var r = Reader.init("hi\x00" ++ [_]u8{ 10, 20, 30 } ++ [_]u8{ 1, 2, 3, 4 });
    try std.testing.expectEqualStrings("hi", try r.readString());
    try std.testing.expectEqual(@as(u32, 10 | (20 << 8) | (30 << 16) | (0xFF << 24)), try r.readRgb());
    try std.testing.expectEqual(@as(u32, 1 | (2 << 8) | (3 << 16) | (4 << 24)), try r.readRgba());
    var r2 = Reader.init("no-nul");
    try std.testing.expectError(Error.OutOfBounds, r2.readString());
}

test "bit reads are MSB-first and byteAlign realigns" {
    // 0b101_0011_1 , 0b1000_0000
    var r = Reader.init(&.{ 0b10100111, 0b10000000 });
    try std.testing.expectEqual(@as(u32, 0b101), try r.readUb(3));
    try std.testing.expectEqual(@as(u32, 0b0011), try r.readUb(4));
    try std.testing.expectEqual(@as(u32, 0b11), try r.readUb(2)); // crosses byte
    r.byteAlign();
    try std.testing.expect(r.atEnd());
    // SB sign extension: 4-bit -3 = 0b1101.
    var r2 = Reader.init(&.{0b11010000});
    try std.testing.expectEqual(@as(i32, -3), try r2.readSb(4));
}

test "RECT roundtrip (ruffle fixture shape)" {
    // 550x400 px stage: nbits=15, (0, 11000, 0, 8000) — same as header.zig.
    var buf: [9]u8 = @splat(0);
    writeBits(&buf, &.{ .{ 15, 5 }, .{ 0, 15 }, .{ 11000, 15 }, .{ 0, 15 }, .{ 8000, 15 } });
    var r = Reader.init(&buf);
    const rect = try r.readRectangle();
    try std.testing.expectEqual(@as(i32, 11000), rect.xmax);
    try std.testing.expectEqual(@as(i32, 8000), rect.ymax);
    try std.testing.expectEqual(@as(i32, 550), @divTrunc(rect.width(), TWIPS_PER_PX));
}

test "MATRIX: identity, translate-only, scale (ruffle test_data fixtures)" {
    // Identity: no scale bit, no rotate bit, ntranslate=0 → 7 bits → 1 byte.
    var r = Reader.init(&.{0b0_0_00000_0});
    const id = try r.readMatrix();
    try std.testing.expectEqual(Matrix.identity, id);

    // Ruffle fixture: [0b0_0_00001_0, 0b0_0000000] → translate nbits=1,
    // tx=0, ty=0 (still identity values).
    var r2 = Reader.init(&.{ 0b0_0_00001_0, 0b0_0000000 });
    const m2 = try r2.readMatrix();
    try std.testing.expectEqual(@as(i32, 0), m2.tx);
    try std.testing.expectEqual(@as(f64, 1.0), m2.a);

    // Scale 1.5×0.5: has_scale=1, nbits=18, a=0x18000, d=0x08000,
    // then no rotate, ntranslate=0.
    var buf: [10]u8 = @splat(0);
    writeBits(&buf, &.{
        .{ 1, 1 }, .{ 18, 5 }, .{ 0x18000, 18 }, .{ 0x08000, 18 },
        .{ 0, 1 }, .{ 0, 5 },
    });
    var r3 = Reader.init(&buf);
    const m3 = try r3.readMatrix();
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), m3.a, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), m3.d, 1e-9);
    try std.testing.expectEqual(@as(f64, 0.0), m3.b);
}

test "CXFORM: identity, mult-only, add+mult with alpha" {
    // Empty: has_add=0, has_mult=0, nbits=0 → 6 bits → one byte.
    var r = Reader.init(&.{0});
    try std.testing.expect((try r.readColorTransform(true)).isIdentity());

    // mult-only RGB: has_add=0 has_mult=1 nbits=10 (256 = +1.0 needs the
    // sign bit clear in a SIGNED field, so 10 bits), mult=(128, 256, 511).
    var buf: [8]u8 = @splat(0);
    writeBits(&buf, &.{
        .{ 0, 1 },    .{ 1, 1 },    .{ 10, 4 },
        .{ 128, 10 }, .{ 256, 10 }, .{ 511, 10 },
    });
    var r2 = Reader.init(&buf);
    const t2 = try r2.readColorTransform(false);
    try std.testing.expectEqual(@as(i16, 128), t2.mult[0]);
    try std.testing.expectEqual(@as(i16, 256), t2.mult[1]);
    try std.testing.expectEqual(@as(i16, 511), t2.mult[2]);
    try std.testing.expectEqual(@as(i16, 256), t2.mult[3]); // untouched default
    try std.testing.expectEqual(@as(i16, 0), t2.add[0]);

    // add+mult RGBA, nbits=10: mult all 256, adds (100, -100, 0, 255).
    var buf3: [16]u8 = @splat(0);
    const neg100: u32 = @as(u32, @bitCast(@as(i32, -100))) & 0x3FF;
    writeBits(&buf3, &.{
        .{ 1, 1 },    .{ 1, 1 },    .{ 10, 4 },
        .{ 256, 10 }, .{ 256, 10 }, .{ 256, 10 },
        .{ 256, 10 }, .{ 100, 10 }, .{ neg100, 10 },
        .{ 0, 10 },   .{ 255, 10 },
    });
    var r3 = Reader.init(&buf3);
    const t3 = try r3.readColorTransform(true);
    try std.testing.expectEqual(@as(i16, 100), t3.add[0]);
    try std.testing.expectEqual(@as(i16, -100), t3.add[1]);
    try std.testing.expectEqual(@as(i16, 255), t3.add[3]);
    try std.testing.expectEqual(@as(i16, 256), t3.mult[0]);
}

/// Test helper: MSB-first bit packer, (value, nbits) pairs.
fn writeBits(buf: []u8, fields: []const struct { u32, u6 }) void {
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
