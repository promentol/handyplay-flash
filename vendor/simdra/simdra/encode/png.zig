//! Minimal PNG encoder. Writes a color-type-6 (RGBA, 8 bits/channel) image with
//! zlib/DEFLATE using only stored (uncompressed) blocks. Output is larger than
//! a real zlib compressor would produce but is valid PNG readable everywhere,
//! and avoids depending on a specific std.compress API that shifts between Zig
//! versions.

const std = @import("std");

const MAX_STORED_BLOCK: usize = 65535;

pub fn encode(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * @as(usize, height) * 4);
    const stride: usize = @as(usize, width) * 4;
    const raw_len: usize = (stride + 1) * @as(usize, height);

    // Filtered raw stream: filter byte (0 = None) + scanline per row.
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            raw[y * (stride + 1)] = 0;
            @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], rgba[y * stride ..][0..stride]);
        }
    }

    const n_blocks: usize = if (raw_len == 0) 1 else (raw_len + MAX_STORED_BLOCK - 1) / MAX_STORED_BLOCK;
    const zlib_size: usize = 2 + n_blocks * 5 + raw_len + 4;
    const png_size: usize = 8 // signature
    + 4 + 4 + 13 + 4 // IHDR chunk
    + 4 + 4 + zlib_size + 4 // IDAT chunk
    + 4 + 4 + 4; // IEND chunk (empty data)

    const out = try allocator.alloc(u8, png_size);
    errdefer allocator.free(out);

    var w = Writer{ .buf = out, .off = 0 };

    w.bytes(&.{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression: zlib
    ihdr[11] = 0; // filter: adaptive
    ihdr[12] = 0; // interlace: none
    w.chunk("IHDR", &ihdr);

    // IDAT is built in place so we can hash the CRC over the final bytes.
    w.be32(@intCast(zlib_size));
    const idat_type_start = w.off;
    w.bytes("IDAT");

    // Zlib header: 0x78 0x01 passes FCHECK ((0x78*256 + 0x01) % 31 == 0).
    w.bytes(&.{ 0x78, 0x01 });

    if (raw_len == 0) {
        // Single empty final stored block.
        w.bytes(&.{ 0x01, 0x00, 0x00, 0xff, 0xff });
    } else {
        var i: usize = 0;
        while (i < raw_len) {
            const block_size: usize = @min(raw_len - i, MAX_STORED_BLOCK);
            const is_final = (i + block_size == raw_len);
            w.byte(if (is_final) 0x01 else 0x00);
            w.le16(@intCast(block_size));
            w.le16(~@as(u16, @intCast(block_size)));
            w.bytes(raw[i..][0..block_size]);
            i += block_size;
        }
    }

    w.be32(adler32(raw));

    const idat_end = w.off;
    var crc = std.hash.Crc32.init();
    crc.update(out[idat_type_start..idat_end]);
    w.be32(crc.final());

    w.chunk("IEND", &.{});

    std.debug.assert(w.off == out.len);
    return out;
}

const Writer = struct {
    buf: []u8,
    off: usize,

    fn byte(self: *Writer, b: u8) void {
        self.buf[self.off] = b;
        self.off += 1;
    }

    fn bytes(self: *Writer, data: []const u8) void {
        @memcpy(self.buf[self.off..][0..data.len], data);
        self.off += data.len;
    }

    fn be32(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.off..][0..4], v, .big);
        self.off += 4;
    }

    fn le16(self: *Writer, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.off..][0..2], v, .little);
        self.off += 2;
    }

    fn chunk(self: *Writer, chunk_type: *const [4]u8, data: []const u8) void {
        self.be32(@intCast(data.len));
        const crc_start = self.off;
        self.bytes(chunk_type);
        self.bytes(data);
        const crc_end = self.off;
        var crc = std.hash.Crc32.init();
        crc.update(self.buf[crc_start..crc_end]);
        self.be32(crc.final());
    }
};

fn adler32(data: []const u8) u32 {
    const MOD: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % MOD;
        b = (b + a) % MOD;
    }
    return (b << 16) | a;
}
