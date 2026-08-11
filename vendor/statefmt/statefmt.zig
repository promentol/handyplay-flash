//! The save-state container format shared by every Handyplay core.
//!
//! One structure, used recursively: a blob is a `Header` followed by sections,
//! and a section is a `Header` followed by its payload. The header IS the
//! section frame — `magic` doubles as the tag and `total_size` as the skip
//! distance — so there is no second framing layer to keep in agreement.
//!
//! Why self-describing at all. The alternative, a bare magic+version pair over
//! a positional stream, has no resync point: one misread field silently
//! reinterprets everything after it, and every change anywhere invalidates the
//! whole blob, which pushes subsystems into inventing private version bytes.
//! Recording each section's own version and the sizes of the structs it wrote
//! makes staleness self-detecting — change a struct and old blobs start being
//! rejected on their own, rather than parsing into the wrong fields.
//!
//! ## Delta-friendliness (rewind)
//!
//! A libretro frontend implements rewind by XOR-ing each state against the
//! previous one and compressing the near-zero result. That constrains layout,
//! and the constraints are load-bearing rather than cosmetic:
//!
//!   D1  Fixed-size sections first, variable-size last. A section that changes
//!       size shifts every offset after it, turning a near-zero delta into
//!       dense noise. This is a rule about section ORDER, enforced by whoever
//!       writes the section list, not by this module.
//!   D2  16-byte relative alignment. `headerSize` and `totalSize` round up to
//!       16, so sections begin at matching offsets in both blobs and a delta
//!       can be taken in wide words. `SectionWriter` does this for you.
//!   D3  No indeterminate bytes. Every byte must be a deterministic function of
//!       VM state, or two snapshots of identical state XOR to garbage. This
//!       module zero-fills every pad byte it introduces; callers own the rest
//!       (notably: never `@memcpy` a non-`extern` struct, whose padding is
//!       `undefined`, and zero any tail between the written length and the
//!       size the frontend asked for).
//!   D4  Constant serialize size across a run.
//!
//! There is no I/O and no allocation here — callers supply the memory, exactly
//! like the cores' own primitives.

const std = @import("std");

/// Which core wrote a blob. Recorded alongside `magic` because a section's
/// magic identifies the *subsystem* and says nothing about its origin; on a
/// nested blob (a renderer snapshot inside a core's state) the two differ.
pub const Format = enum(u32) {
    invalid = 0,
    java_core = 1,
    mophun_core = 2,
    mre_core = 3,
    mrp_core = 4,
    exen_core = 5,
    neongl = 6,
    // 7..15 reserved for future cores.
    _,
};

/// Section payloads start on a 16-byte boundary relative to the blob start, so
/// a rewind delta can be taken in wide words (D2). Only RELATIVE alignment is
/// required — two blobs need matching offsets, not any particular absolute
/// address, which is the frontend's to arrange if it wants the SIMD win.
pub const ALIGN: usize = 16;

pub fn alignUp(n: usize) usize {
    return std.mem.alignForward(usize, n, ALIGN);
}

/// Build a FourCC tag from a 4-byte string, read little-endian so a hex dump
/// shows the characters in order.
pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// The fixed 48-byte prefix carried by every blob and every section.
///
/// Fixed and universal is the point: it is what lets a reader skip a section it
/// has never heard of without understanding anything about it. Format-specific
/// fields go in a tail INSIDE `header_size` — never by growing this struct.
pub const Header = extern struct {
    /// FourCC LE — the envelope's core tag, or the section's subsystem tag.
    magic: u32,
    /// Per-section. Exact-equality check; there are no ranges and no
    /// migrations, so a mismatch is refused outright rather than half-read.
    version: u32,
    /// `SIZE` + the format-specific tail. Exact-equality check: growth is
    /// meant to consume `reserved`, not to extend the header.
    header_size: u32,
    /// Header + payload + padding — the skip distance, and the truncation
    /// check.
    total_size: u32,
    /// Which core wrote this (`Format`).
    format: u32,
    /// Capability claims about this blob that a reader MUST honour. Unknown
    /// bits are refused. Contrast with tags, which are payload framing: an
    /// unknown TAG is skipped by length, an unknown BIT is fatal. A bit is for
    /// something that makes silently skipping wrong.
    features: u32,
    /// `layoutHash` of the types this section dumps verbatim, or 0 for a
    /// section that writes nothing verbatim.
    ///
    /// A first-class field rather than a tail convention, because it is the
    /// one piece of metadata every section may need and its whole value is
    /// that nobody has to remember it: a reader expecting a fingerprint and
    /// handed a blob without one must see a mismatch, not a zero it skips.
    layout: u32,
    /// Zero. Keeps `reserved` 16-byte aligned within the header.
    pad: u32,
    /// Zero. A future field consumes one of these without touching
    /// `header_size` — and because a non-zero value is refused, an old reader
    /// rejects a new writer instead of ignoring a field it needed.
    reserved: [4]u32,

    pub const SIZE: usize = @sizeOf(Header);

    comptime {
        std.debug.assert(SIZE == 48);
        std.debug.assert(SIZE % ALIGN == 0); // payload starts aligned (D2)
        std.debug.assert(@alignOf(Header) == 4);
    }
};

pub const Error = error{
    BadMagic,
    BadVersion,
    BadFormat,
    /// `header_size` disagrees with what this build writes.
    BadHeaderSize,
    /// `total_size` runs past the end of the buffer, or is smaller than the
    /// header it claims.
    Truncated,
    /// `features` names a capability this build cannot honour.
    UnknownFeature,
    /// A reserved word was non-zero: written by something newer than us.
    ReservedSet,
    /// A layout fingerprint disagrees with the running build.
    LayoutMismatch,
};

/// What a reader expects to find. Everything here is checked for exact
/// equality except `features`, which is checked for subset.
pub const Expect = struct {
    magic: u32,
    version: u32 = 1,
    format: Format,
    /// Bits this build knows how to honour. A blob claiming anything outside
    /// this set is refused.
    features_known: u32 = 0,
    /// `layoutHash` of the types this section dumps verbatim; 0 if none.
    layout: u32 = 0,
    /// This build's format-specific tail. Must be a multiple of `ALIGN`, so
    /// that `header_size` uniquely determines the tail size — otherwise two
    /// different tails round to the same header and a reader can mistake one
    /// for the other. Pad with unused words rather than picking an odd size.
    tail_bytes: usize = 0,

    pub fn headerSize(self: Expect) usize {
        std.debug.assert(self.tail_bytes % ALIGN == 0);
        return Header.SIZE + self.tail_bytes;
    }
};

/// Validate `buf`'s leading header against `exp` and return it.
///
/// Applies every rule in one place so no caller can implement four of the five:
/// identity (magic/version/format/header_size), truncation, unknown features,
/// and non-zero reserved words.
pub fn parse(buf: []const u8, exp: Expect) Error!Header {
    if (buf.len < Header.SIZE) return Error.Truncated;
    const h = readHeader(buf);

    if (h.magic != exp.magic) return Error.BadMagic;
    if (h.version != exp.version) return Error.BadVersion;
    if (h.format != @intFromEnum(exp.format)) return Error.BadFormat;
    if (h.header_size != exp.headerSize()) return Error.BadHeaderSize;
    if (h.layout != exp.layout) return Error.LayoutMismatch;

    // Ordering matters: reject a header that claims more than it can have
    // before anyone uses `total_size` as a length.
    if (h.total_size < h.header_size) return Error.Truncated;
    if (h.total_size > buf.len) return Error.Truncated;

    if (h.features & ~exp.features_known != 0) return Error.UnknownFeature;
    if (h.pad != 0) return Error.ReservedSet;
    for (h.reserved) |r| if (r != 0) return Error.ReservedSet;

    return h;
}

/// The payload of a blob whose header has already been parsed: everything
/// between the header and `total_size`. Trailing bytes past `total_size` are
/// tolerated — a frontend padding a state out to a constant serialize size
/// (D4) produces exactly that.
pub fn payload(buf: []const u8, h: Header) []const u8 {
    return buf[h.header_size..h.total_size];
}

fn readHeader(buf: []const u8) Header {
    return .{
        .magic = rd(buf, 0),
        .version = rd(buf, 4),
        .header_size = rd(buf, 8),
        .total_size = rd(buf, 12),
        .format = rd(buf, 16),
        .features = rd(buf, 20),
        .layout = rd(buf, 24),
        .pad = rd(buf, 28),
        .reserved = .{ rd(buf, 32), rd(buf, 36), rd(buf, 40), rd(buf, 44) },
    };
}

fn rd(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn wr(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

/// A comptime fingerprint over the types a section dumps verbatim.
///
/// The header records it so that changing such a struct invalidates old blobs
/// on its own, instead of the bytes parsing into the wrong fields — a failure
/// that is silent and produces plausible-looking wrong state. Names are hashed
/// as well as sizes, so a swap of two same-sized fields between structs is
/// caught even though the totals did not move.
///
/// This guards LAYOUT DRIFT only. It says nothing about padding: a non-`extern`
/// Zig struct has `undefined` padding bytes, and dumping one still violates D3
/// no matter how well fingerprinted it is. Those are two separate problems.
pub fn layoutHash(comptime types: anytype) u32 {
    const v = comptime blk: {
        var h = std.hash.Fnv1a_32.init();
        for (std.meta.fields(@TypeOf(types))) |f| {
            const T = @field(types, f.name);
            h.update(@typeName(T));
            h.update(&std.mem.toBytes(@as(u32, @sizeOf(T))));
            h.update(&std.mem.toBytes(@as(u32, @alignOf(T))));
        }
        break :blk h.final();
    };
    // 0 reads as "no fingerprint recorded"; fold it away so a real hash never
    // collides with that.
    return if (v == 0) 1 else v;
}

// ── writing ─────────────────────────────────────────────────────────────────

/// Writes a header + payload into a caller-supplied buffer, back-patching
/// `total_size` once the payload length is known.
///
/// Owns D2 and D3 so no caller has to remember them: every pad byte it
/// introduces — the header tail's rounding, and the payload's — is zero-filled.
pub const SectionWriter = struct {
    buf: []u8,
    /// Offset of this section's header within `buf`.
    start: usize,
    /// Write cursor, absolute within `buf`.
    pos: usize,
    header_size: usize,

    pub const WriteError = error{NoSpaceLeft};

    /// Reserve `exp`'s header at `start` and position the cursor at the
    /// payload. The header is fully written except `total_size`, which
    /// `finish` back-patches.
    pub fn begin(buf: []u8, start: usize, exp: Expect, features: u32) WriteError!SectionWriter {
        std.debug.assert(features & ~exp.features_known == 0);
        const hs = exp.headerSize();
        if (start + hs > buf.len) return error.NoSpaceLeft;

        const hdr = buf[start..][0..hs];
        @memset(hdr, 0); // pad + reserved words + any unused tail (D3)
        wr(hdr, 0, exp.magic);
        wr(hdr, 4, exp.version);
        wr(hdr, 8, @intCast(hs));
        // total_size patched by finish()
        wr(hdr, 16, @intFromEnum(exp.format));
        wr(hdr, 20, features);
        wr(hdr, 24, exp.layout);

        return .{ .buf = buf, .start = start, .pos = start + hs, .header_size = hs };
    }

    /// The format-specific tail, indexed from 0 — word `i` sits at
    /// `Header.SIZE + i*4`. Bounds-checked against the tail actually reserved.
    pub fn setTailWord(self: *SectionWriter, i: usize, v: u32) void {
        const off = Header.SIZE + i * 4;
        std.debug.assert(off + 4 <= self.header_size);
        wr(self.buf[self.start..], off, v);
    }

    pub fn write(self: *SectionWriter, bytes: []const u8) WriteError!void {
        if (self.pos + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    pub fn writeU32(self: *SectionWriter, v: u32) WriteError!void {
        if (self.pos + 4 > self.buf.len) return error.NoSpaceLeft;
        wr(self.buf, self.pos, v);
        self.pos += 4;
    }

    /// A payload region to fill in place — for the big ones (guest RAM, a
    /// framebuffer) where copying through `write` would double the traffic.
    pub fn reserve(self: *SectionWriter, n: usize) WriteError![]u8 {
        if (self.pos + n > self.buf.len) return error.NoSpaceLeft;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    /// Pad to `ALIGN`, back-patch `total_size`, and return the offset the next
    /// section starts at.
    pub fn finish(self: *SectionWriter) WriteError!usize {
        const end = alignUp(self.pos - self.start) + self.start;
        if (end > self.buf.len) return error.NoSpaceLeft;
        @memset(self.buf[self.pos..end], 0); // D3: padding is never garbage
        wr(self.buf[self.start..], 12, @intCast(end - self.start));
        self.pos = end;
        return end;
    }
};

// ── reading ─────────────────────────────────────────────────────────────────

/// Walks the sections of an already-validated envelope payload.
///
/// A section whose magic this build does not know is skipped by `total_size` —
/// that is what makes a tag safe to add later. Only the fixed 40-byte prefix is
/// touched to do it, so skipping needs no knowledge of the section at all.
pub const SectionReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub const Section = struct {
        magic: u32,
        version: u32,
        features: u32,
        layout: u32,
        header_size: u32,
        /// The whole section including its header — for `tailWord`.
        raw: []const u8,
        payload: []const u8,

        pub fn tailWord(self: Section, i: usize) ?u32 {
            const off = Header.SIZE + i * 4;
            if (off + 4 > self.header_size) return null;
            return rd(self.raw, off);
        }
    };

    /// The next section, or null at the end. Malformed framing is an error
    /// rather than a silent stop: a truncated tail means the blob is not what
    /// it claims, and treating it as "no more sections" would restore a
    /// partial state.
    pub fn next(self: *SectionReader) Error!?Section {
        if (self.pos >= self.buf.len) return null;
        // Trailing zero padding out to a constant serialize size (D4) is not a
        // section; a magic of 0 ends the walk.
        if (self.buf.len - self.pos < Header.SIZE) return Error.Truncated;
        const rest = self.buf[self.pos..];
        if (rd(rest, 0) == 0) return null;

        const h = readHeader(rest);
        if (h.header_size < Header.SIZE) return Error.BadHeaderSize;
        if (h.total_size < h.header_size) return Error.Truncated;
        if (h.total_size > rest.len) return Error.Truncated;
        if (h.pad != 0) return Error.ReservedSet;
        for (h.reserved) |r| if (r != 0) return Error.ReservedSet;

        const raw = rest[0..h.total_size];
        self.pos += h.total_size;
        return .{
            .magic = h.magic,
            .version = h.version,
            .features = h.features,
            .layout = h.layout,
            .header_size = h.header_size,
            .raw = raw,
            .payload = raw[h.header_size..],
        };
    }

    /// Validate a section found by `next` against what this build expects
    /// before reading its payload. Kept separate from `next` because the walk
    /// must be able to skip a section it cannot describe.
    pub fn check(s: Section, exp: Expect) Error!void {
        if (s.magic != exp.magic) return Error.BadMagic;
        if (s.version != exp.version) return Error.BadVersion;
        if (s.header_size != exp.headerSize()) return Error.BadHeaderSize;
        if (s.layout != exp.layout) return Error.LayoutMismatch;
        if (s.features & ~exp.features_known != 0) return Error.UnknownFeature;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_ENV: Expect = .{ .magic = tag("TEST"), .format = .java_core, .features_known = 0b11 };
const TEST_SEC: Expect = .{ .magic = tag("SECA"), .format = .java_core };

test "header is 48 bytes with the documented field offsets" {
    var buf = [_]u8{0} ** 64;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0b01);
    _ = try w.finish();

    try testing.expectEqual(@as(usize, 48), Header.SIZE);
    try testing.expectEqual(@as(u32, tag("TEST")), rd(&buf, 0));
    try testing.expectEqual(@as(u32, 1), rd(&buf, 4)); // version
    try testing.expectEqual(@as(u32, 48), rd(&buf, 8)); // header_size
    try testing.expectEqual(@as(u32, 48), rd(&buf, 12)); // total_size, empty payload
    try testing.expectEqual(@as(u32, 1), rd(&buf, 16)); // format = java_core
    try testing.expectEqual(@as(u32, 0b01), rd(&buf, 20)); // features
    try testing.expectEqual(@as(u32, 0), rd(&buf, 24)); // layout, none declared
    for (28..48) |off| try testing.expectEqual(@as(u8, 0), buf[off]); // pad + reserved
}

test "the header is itself 16-aligned so payloads start aligned (D2)" {
    var buf = [_]u8{0xAA} ** 128;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0);
    try w.write("hi"); // 2 bytes -> pads to 16
    const end = try w.finish();

    try testing.expectEqual(@as(usize, 0), Header.SIZE % ALIGN);
    try testing.expectEqual(@as(usize, 64), end); // 48 + align16(2)
    try testing.expectEqual(@as(u32, 64), rd(&buf, 12)); // total_size
    // The rounding pad after "hi" must be zeroed, not left as 0xAA (D3).
    for (50..64) |off| try testing.expectEqual(@as(u8, 0), buf[off]);
}

test "header_size uniquely determines the tail: a 16-byte tail is not mistaken for none" {
    var buf = [_]u8{0} ** 128;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0);
    const end = try w.finish();

    // Same magic/version/format, but this build expects a tail. Rounding used
    // to collapse both to one header_size, letting a fingerprint read as 0.
    try testing.expectError(Error.BadHeaderSize, parse(buf[0..end], .{
        .magic = TEST_ENV.magic,
        .format = .java_core,
        .features_known = TEST_ENV.features_known,
        .tail_bytes = ALIGN,
    }));
}

test "a declared layout fingerprint must match" {
    const V1 = extern struct { a: u32, b: u32 };
    const V2 = extern struct { a: u32, b: u32, c: u32 }; // the struct grew

    var buf = [_]u8{0} ** 128;
    const wrote: Expect = .{ .magic = tag("SECL"), .format = .exen_core, .layout = layoutHash(.{V1}) };
    var w = try SectionWriter.begin(&buf, 0, wrote, 0);
    try w.write("verbatim");
    const end = try w.finish();

    _ = try parse(buf[0..end], wrote);

    const reads: Expect = .{ .magic = tag("SECL"), .format = .exen_core, .layout = layoutHash(.{V2}) };
    try testing.expectError(Error.LayoutMismatch, parse(buf[0..end], reads));

    // And a blob with NO fingerprint must not satisfy a reader expecting one —
    // the whole point of making it a header field rather than a convention.
    var plain = [_]u8{0} ** 128;
    var pw = try SectionWriter.begin(&plain, 0, .{ .magic = tag("SECL"), .format = .exen_core }, 0);
    const pend = try pw.finish();
    try testing.expectError(Error.LayoutMismatch, parse(plain[0..pend], wrote));
}

test "parse accepts a well-formed header" {
    var buf = [_]u8{0} ** 128;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0b10);
    try w.write("payload!");
    const end = try w.finish();

    const h = try parse(buf[0..end], TEST_ENV);
    try testing.expectEqual(@as(u32, 0b10), h.features);
    try testing.expectEqualStrings("payload!", payload(buf[0..end], h)[0..8]);
}

test "parse rejects bad magic, version, format and header_size" {
    var buf = [_]u8{0} ** 128;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0);
    const end = try w.finish();

    try testing.expectError(Error.BadMagic, parse(buf[0..end], .{ .magic = tag("NOPE"), .format = .java_core }));
    try testing.expectError(Error.BadVersion, parse(buf[0..end], .{ .magic = TEST_ENV.magic, .version = 2, .format = .java_core }));
    try testing.expectError(Error.BadFormat, parse(buf[0..end], .{ .magic = TEST_ENV.magic, .format = .mre_core }));
    try testing.expectError(Error.BadHeaderSize, parse(buf[0..end], .{ .magic = TEST_ENV.magic, .format = .java_core, .tail_bytes = 32 }));
}

test "parse rejects truncation, unknown features and a set reserved word" {
    var buf = [_]u8{0} ** 128;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0b11);
    try w.write("xxxxxxxx");
    const end = try w.finish();

    try testing.expectError(Error.Truncated, parse(buf[0 .. end - 1], TEST_ENV));
    try testing.expectError(Error.Truncated, parse(buf[0..20], TEST_ENV));
    // features_known shrinks: the blob now claims a bit we cannot honour.
    try testing.expectError(Error.UnknownFeature, parse(buf[0..end], .{ .magic = TEST_ENV.magic, .format = .java_core, .features_known = 0b01 }));

    wr(&buf, 32, 1); // reserved[0]
    try testing.expectError(Error.ReservedSet, parse(buf[0..end], TEST_ENV));
    wr(&buf, 32, 0);
    wr(&buf, 28, 1); // pad
    try testing.expectError(Error.ReservedSet, parse(buf[0..end], TEST_ENV));
}

test "trailing bytes past total_size are tolerated (D4 padding)" {
    var buf = [_]u8{0} ** 256;
    var w = try SectionWriter.begin(&buf, 0, TEST_ENV, 0);
    try w.write("abc");
    _ = try w.finish();

    // The frontend pads out to a constant serialize size; parse sees the whole
    // buffer and must accept it.
    const h = try parse(&buf, TEST_ENV);
    try testing.expectEqual(@as(u32, 64), h.total_size);
}

test "section walk: an unknown section is skipped by total_size" {
    var buf = [_]u8{0} ** 512;
    var pos: usize = 0;

    var a = try SectionWriter.begin(&buf, pos, TEST_SEC, 0);
    try a.write("first");
    pos = try a.finish();

    // A section from a build we know nothing about.
    var x = try SectionWriter.begin(&buf, pos, .{ .magic = tag("WHAT"), .format = .java_core }, 0);
    try x.write("a payload of some length we cannot interpret");
    pos = try x.finish();

    var c = try SectionWriter.begin(&buf, pos, .{ .magic = tag("SECC"), .format = .java_core }, 0);
    try c.write("third");
    pos = try c.finish();

    var r = SectionReader{ .buf = buf[0..pos] };
    var seen: usize = 0;
    var found_third = false;
    while (try r.next()) |s| {
        seen += 1;
        if (s.magic == tag("SECC")) {
            found_third = true;
            try testing.expectEqualStrings("third", s.payload[0..5]);
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expect(found_third); // the unknown section did not desync the walk
}

test "section walk: every section offset is 16-aligned (D2)" {
    var buf = [_]u8{0} ** 512;
    var pos: usize = 0;
    for ([_][]const u8{ "a", "bb", "ccccccc", "d" ** 1 }) |body| {
        var w = try SectionWriter.begin(&buf, pos, TEST_SEC, 0);
        try w.write(body);
        pos = try w.finish();
        try testing.expectEqual(@as(usize, 0), pos % ALIGN);
    }

    var r = SectionReader{ .buf = buf[0..pos] };
    var off: usize = 0;
    while (try r.next()) |s| {
        try testing.expectEqual(@as(usize, 0), off % ALIGN);
        try testing.expectEqual(@as(usize, 0), s.header_size % ALIGN);
        off += s.raw.len;
    }
}

test "section walk: a truncated tail is an error, not a silent stop" {
    var buf = [_]u8{0} ** 256;
    var w = try SectionWriter.begin(&buf, 0, TEST_SEC, 0);
    try w.write("0123456789abcdef0123456789abcdef");
    const end = try w.finish();

    var r = SectionReader{ .buf = buf[0 .. end - 16] };
    try testing.expectError(Error.Truncated, r.next());
}

test "format-specific tail words round-trip" {
    var buf = [_]u8{0} ** 256;
    const exp: Expect = .{ .magic = tag("SECT"), .format = .exen_core, .tail_bytes = ALIGN };
    var w = try SectionWriter.begin(&buf, 0, exp, 0);
    w.setTailWord(0, 0xDEADBEEF);
    w.setTailWord(1, 12345);
    try w.write("body");
    const end = try w.finish();

    try testing.expectEqual(@as(u32, 64), rd(&buf, 8)); // 48 + 16

    var r = SectionReader{ .buf = buf[0..end] };
    const s = (try r.next()).?;
    try SectionReader.check(s, exp);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), s.tailWord(0).?);
    try testing.expectEqual(@as(u32, 12345), s.tailWord(1).?);
    try testing.expectEqual(@as(u32, 0), s.tailWord(3).?); // unused tail is zeroed
    try testing.expectEqual(@as(?u32, null), s.tailWord(4)); // past the tail
}

test "layoutHash distinguishes size, alignment and identity" {
    const A = extern struct { a: u32, b: u32 };
    const B = extern struct { a: u32, b: u32, c: u32 };
    const C = extern struct { a: u64 };

    try testing.expect(layoutHash(.{A}) != layoutHash(.{B}));
    try testing.expect(layoutHash(.{A}) != layoutHash(.{C})); // same size, different align
    try testing.expect(layoutHash(.{ A, B }) != layoutHash(.{ B, A })); // order is identity
    try testing.expectEqual(layoutHash(.{ A, B }), layoutHash(.{ A, B }));
    try testing.expect(layoutHash(.{A}) != 0);
}

test "determinism: identical state into differently-dirtied buffers is byte-identical (D3)" {
    var one = [_]u8{0x00} ** 256;
    var two = [_]u8{0xFF} ** 256;

    for ([_][]u8{ &one, &two }) |buf| {
        var pos: usize = 0;
        var a = try SectionWriter.begin(buf, pos, TEST_SEC, 0);
        try a.write("state");
        pos = try a.finish();
        var b = try SectionWriter.begin(buf, pos, .{ .magic = tag("SECB"), .format = .java_core, .tail_bytes = ALIGN }, 0);
        b.setTailWord(0, 7);
        try b.write("more");
        pos = try b.finish();
        // The frontend zeroes the tail out to a constant size (D4).
        @memset(buf[pos..], 0);
    }

    try testing.expectEqualSlices(u8, &one, &two);
}

test "begin refuses a buffer too small for the header" {
    var buf = [_]u8{0} ** 32;
    try testing.expectError(error.NoSpaceLeft, SectionWriter.begin(&buf, 0, TEST_ENV, 0));
}
